# Eager loading makes it so that you can load all associated records for a
# set of objects in a single query, instead of a separate query for each object.
#
# Two separate implementations are provided.  .eager should be used most of the
# time, as it loads associated records using one query per association.  However,
# it does not allow you the ability to filter based on columns in associated tables.  .eager_graph loads
# all records in one query.  Using .eager_graph you can filter based on columns in associated
# tables.  However, .eager_graph can be much slower than .eager, especially if multiple
# *_to_many associations are joined.
#
# You can cascade the eager loading (loading associations' associations)
# with no limit to the depth of the cascades.  You do this by passing a hash to .eager or .eager_graph
# with the keys being associations of the current model and values being
# associations of the model associated with the current model via the key.
#  
# You cannot eagerly load an association with a block argument, as the block argument is
# evaluated in terms of a specific instance of the model, and no specific instance exists.
#
# The arguments can be symbols or hashes with symbol keys (for cascaded
# eager loading). Examples:
#
#  Album.eager(:artist).all
#  Album.eager_graph(:artist).all
#  Album.eager(:artist, :genre).all
#  Album.eager_graph(:artist, :genre).all
#  Album.eager(:artist).eager(:genre).all
#  Album.eager_graph(:artist).eager(:genre).all
#  Artist.eager(:albums=>:tracks).all
#  Artist.eager_graph(:albums=>:tracks).all
#  Artist.eager(:albums=>{:tracks=>:genre}).all
#  Artist.eager_graph(:albums=>{:tracks=>:genre}).all
module Sequel::Model::Associations::EagerLoading
  # Add the .eager! and .eager_graph! mutation methods to the dataset.
  def self.extended(obj)
    obj.def_mutation_method(:eager, :eager_graph)
  end

  # The preferred eager loading method.  Loads all associated records using one
  # query for each association.
  #
  # The basic idea for how it works is that the dataset is first loaded normally.
  # Then it goes through all associations that have been specified via .eager.
  # It loads each of those associations separately, then associates them back
  # to the original dataset via primary/foreign keys.  Due to the necessity of
  # all objects being present, you need to use .all to use eager loading, as it
  # can't work with .each.
  #
  # This implementation avoids the complexity of extracting an object graph out
  # of a single dataset, by building the object graph out of multiple datasets,
  # one for each association.  By using a separate dataset for each association,
  # it avoids problems such as aliasing conflicts and creating cartesian product
  # result sets if multiple *_to_many eager associations are requested.
  #
  # One limitation of using this method is that you cannot filter the dataset
  # based on values of columns in an associated table, since the associations are loaded
  # in separate queries.  To do that you need to load all associations in the
  # same query, and extract an object graph from the results of that query. If you
  # need to filter based on columns in associated tables, look at .eager_graph
  # or join the tables you need to filter on manually. 
  #
  # Each association's order, if definied, is respected. Eager also works
  # on a limited dataset.
  def eager(*associations)
    model = check_model
    opt = @opts[:eager]
    opt = opt ? opt.dup : {}
    associations.flatten.each do |association|
      case association
        when Symbol
          check_association(model, association)
          opt[association] = nil
        when Hash
          association.keys.each{|assoc| check_association(model, assoc)}
          opt.merge!(association)
        else raise(ArgumentError, 'Associations must be in the form of a symbol or hash')
      end
    end
    clone(:eager=>opt)
  end

  # The secondary eager loading method.  Loads all associations in a single query. This
  # method should only be used if you need to filter based on columns in associated tables.
  #
  # This method builds an object graph using the .graph method.  Then it uses the graph
  # to build the associations, and finally replaces the graph with a simple array
  # of model objects.
  #
  # Be very careful when using this with multiple *_to_many associations, as you can
  # create large cartesian products.  If you must graph multiple *_to_many associations,
  # make sure your filters are specific if you have a large database.
  # 
  # This does not respect each association's order, as all associations are loaded in
  # a single query.  If you want to order the results, you must manually call .order.
  #
  # eager_graph probably won't work the way you suspect with limit, unless you are
  # only graphing many_to_one associations.
  def eager_graph(*associations)
    model = check_model
    table_name = model.table_name
    ds = if @opts[:eager_graph]
      self
    else
      # Each of the following have a symbol key for the table alias, with the following values: 
      # :requirements - array of requirements for this association
      # :alias_association_type_map - the type of association for this association
      # :alias_association_name_map - the name of the association for this association
      clone(:eager_graph=>{:requirements=>{}, :master=>model.table_name, :alias_association_type_map=>{}, :alias_association_name_map=>{}, :reciprocals=>{}})
    end
    ds.eager_graph_associations(ds, model, table_name, [], *associations)
  end
  
  protected
    # Call graph on the association with the correct arguments,
    # update the eager_graph data structure, and recurse into
    # eager_graph_associations if there are any passed in associations
    # (which would be dependencies of the current association)
    #
    # Arguments:
    # * ds - Current dataset
    # * model - Current Model
    # * ta - table_alias used for the parent association
    # * requirements - an array, used as a stack for requirements
    # * r - association reflection for the current association
    # * *associations - any associations dependent on this one
    def eager_graph_association(ds, model, ta, requirements, r, *associations)
      klass = model.send(:associated_class, r)
      assoc_name = r[:name]
      assoc_table_alias = ds.eager_unique_table_alias(ds, assoc_name)
      ds = case assoc_type = r[:type]
      when :many_to_one
        ds.graph(klass, {klass.primary_key=>:"#{ta}__#{r[:key]}"}, :table_alias=>assoc_table_alias)
      when :one_to_many
        ds = ds.graph(klass, {r[:key]=>:"#{ta}__#{model.primary_key}"}, :table_alias=>assoc_table_alias)
        # We only load reciprocals for one_to_many associations, as other reciprocals don't make sense
        ds.opts[:eager_graph][:reciprocals][assoc_table_alias] = model.send(:reciprocal_association, r)
        ds
      when :many_to_many
        ds = ds.graph(r[:join_table], {r[:left_key]=>:"#{ta}__#{model.primary_key}"}, :select=>false, :table_alias=>ds.eager_unique_table_alias(ds, r[:join_table]))
        ds.graph(klass, {klass.primary_key=>r[:right_key]}, :table_alias=>assoc_table_alias)
      end
      eager_graph = ds.opts[:eager_graph]
      eager_graph[:requirements][assoc_table_alias] = requirements.dup
      eager_graph[:alias_association_name_map][assoc_table_alias] = assoc_name
      eager_graph[:alias_association_type_map][assoc_table_alias] = assoc_type
      ds = ds.eager_graph_associations(ds, klass, assoc_table_alias, requirements + [assoc_table_alias], *associations) unless associations.empty?
      ds
    end
  
    # Check the associations are valid for the given model.
    # Call eager_graph_association on each association.
    #
    # Arguments:
    # * ds - Current dataset
    # * model - Current Model
    # * ta - table_alias used for the parent association
    # * requirements - an array, used as a stack for requirements
    # * *associations - the associations to add to the graph
    def eager_graph_associations(ds, model, ta, requirements, *associations)
      return ds if associations.empty?
      associations.flatten.each do |association|
        ds = case association
        when Symbol
          ds.eager_graph_association(ds, model, ta, requirements, check_association(model, association))
        when Hash
          association.each do |assoc, assoc_assocs|
            ds = ds.eager_graph_association(ds, model, ta, requirements, check_association(model, assoc), assoc_assocs)
          end
          ds
        else raise(ArgumentError, 'Associations must be in the form of a symbol or hash')
        end
      end
      ds
    end

    # Build associations out of the array of returned object graphs.
    def eager_graph_build_associations(record_graphs)
      # Dup the tables that will be used, so that self is not modified.
      eager_graph = @opts[:eager_graph]
      master = eager_graph[:master]
      requirements = eager_graph[:requirements]
      alias_map = eager_graph[:alias_association_name_map]
      type_map = eager_graph[:alias_association_type_map]
      reciprocal_map = eager_graph[:reciprocals]

      # Make dependency map hash out of requirements array for each association.
      # This builds a tree of dependencies that will be used for recursion
      # to ensure that all parts of the object graph are loaded into the
      # appropriate subordinate association.
      dependency_map = {}
      # Sort the associations be requirements length, so that
      # requirements are added to the dependency hash before their
      # dependencies.
      requirements.sort_by{|a| a[1].length}.each do |ta, deps|
        if deps.empty?
          dependency_map[ta] = {}
        else
          deps = deps.dup
          hash = dependency_map[deps.shift]
          deps.each do |dep|
            hash = hash[dep]
          end
          hash[ta] = {}
        end
      end

      # This mapping is used to make sure that duplicate entries in the
      # result set are mapped to a single record.  For example, using a
      # single one_to_many association with 10 associated records,
      # the main object will appear in the object graph 10 times.
      # We map by primary key, if available, or by the object's entire values,
      # if not. The mapping must be per table, so create sub maps for each table
      # alias.
      records_map = {master=>{}}
      alias_map.keys.each{|ta| records_map[ta] = {}}

      # This will hold the final record set that we will be replacing the object graph with.
      records = []
      record_graphs.each do |record_graph|
        primary_record = record_graph[master]
        key = primary_record.pk || primary_record.values.sort_by{|x| x[0].to_s}
        if cached_pr = records_map[master][key]
          primary_record = cached_pr
        else
          records_map[master][key] = primary_record
          # Only add it to the list of records to return if it is a new record
          records.push(primary_record)
        end
        # Build all associations for the current object and it's dependencies
        eager_graph_build_associations_graph(dependency_map, alias_map, type_map, reciprocal_map, records_map, primary_record, record_graph)
      end

      # Remove duplicate records from all associations if this graph could possibly be a cartesian product
      eager_graph_make_associations_unique(records, dependency_map, alias_map, type_map) if type_map.reject{|k,v| v == :many_to_one}.length > 1
      
      # Replace the array of object graphs with an array of model objects
      record_graphs.replace(records)
    end

    # Creates a unique table alias that hasn't already been used in the query.
    # Will either be the table_alias itself or table_alias_N for some integer
    # N (starting at 0 and increasing until an unused one is found).
    def eager_unique_table_alias(ds, table_alias)
      if (graph = ds.opts[:graph]) && (table_aliases = graph[:table_aliases]) && (table_aliases.include?(table_alias))
        i = 0
        loop do
          ta = :"#{table_alias}_#{i}"
          return ta unless table_aliases[ta]
          i += 1
        end
      else
        table_alias
      end
    end
  
  private
    # Make sure a standard (non-polymorphic model) is used for this dataset, and return the model
    def check_model
      raise(ArgumentError, 'No model for this dataset') unless @opts[:models] && model = @opts[:models][nil]
      model
    end

    # Make sure the association is valid for this model, and return the association's reflection
    def check_association(model, association)
      raise(ArgumentError, 'Invalid association') unless reflection = model.association_reflection(association)
      raise(ArgumentError, 'Cannot eagerly load associations with block arguments') if reflection[:block]
      reflection
    end
  
    # Build associations for the current object.  This is called recursively
    # to build object's dependencies.
    def eager_graph_build_associations_graph(dependency_map, alias_map, type_map, reciprocal_map, records_map, current, record_graph)
      return if dependency_map.empty?
      # Don't clobber the instance variable array for *_to_many associations if it has already been setup
      dependency_map.keys.each do |ta|
        current.instance_variable_set("@#{alias_map[ta]}", []) unless type_map[ta] == :many_to_one || current.instance_variable_get("@#{alias_map[ta]}")
      end
      dependency_map.each do |ta, deps|
        rec = record_graph[ta]
        key = rec.pk || rec.values.sort_by{|x| x[0].to_s}
        if cached_rec = records_map[ta][key]
          rec = cached_rec
        else
          records_map[ta][rec.pk] = rec
        end
        ivar = "@#{alias_map[ta]}"
        case assoc_type = type_map[ta]
        when :many_to_one
          current.instance_variable_set(ivar, rec)
        else
          list = current.instance_variable_get(ivar)
          list.push(rec) 
          if (assoc_type == :one_to_many) && (reciprocal = reciprocal_map[ta])
            rec.instance_variable_set(reciprocal, current)
          end
        end
        # Recurse into dependencies of the current object
        eager_graph_build_associations_graph(deps, alias_map, type_map, reciprocal_map, records_map, rec, record_graph)
      end
    end

    # If the result set is the result of a cartesian product, then it is possible that
    # there a multiple records for each association when there should only be one.
    def eager_graph_make_associations_unique(records, dependency_map, alias_map, type_map)
      records.each do |record|
        dependency_map.each do |ta, deps|
          list = if type_map[ta] == :many_to_one
            item = record.send(alias_map[ta])
            [item] if item
          else
            list = record.send(alias_map[ta])
            list.uniq!
            # Recurse into dependencies
            list.each{|rec| eager_graph_make_associations_unique(rec, deps, alias_map, type_map)}
          end
        end
      end
    end

    # Eagerly load all specified associations 
    def eager_load(a)
      return if a.empty?
      # Current model class
      model = @opts[:models][nil]
      # All associations to eager load
      eager_assoc = @opts[:eager]
      # Key is foreign/primary key name symbol
      # Value is hash with keys being foreign/primary key values (generally integers)
      #  and values being an array of current model objects with that
      #  specific foreign/primary key
      key_hash = {}
      # array of attribute_values keys to monitor
      keys = []
      # Reflections for all associations to eager load
      reflections = eager_assoc.keys.collect{|assoc| model.association_reflection(assoc)}

      # Populate keys to monitor
      reflections.each do |reflection|
        key = reflection[:type] == :many_to_one ? reflection[:key] : model.primary_key
        next if key_hash[key]
        key_hash[key] = {}
        keys << key
      end
      
      # Associate each object with every key being monitored
      a.each do |r|
        keys.each do |key|
          ((key_hash[key][r[key]] ||= []) << r) if r[key]
        end
      end
      
      # Iterate through eager associations and assign instance variables
      # for the association for all model objects
      reflections.each do |reflection|
        assoc_class = model.send(:associated_class, reflection)
        assoc_name = reflection[:name]
        # Proc for setting cascaded eager loading
        cascade = Proc.new do |d|
          if c = eager_assoc[assoc_name]
            d = d.eager(c)
          end
          if c = reflection[:eager]
            d = d.eager(c)
          end
          d
        end
        case rtype = reflection[:type]
          when :many_to_one
            key = reflection[:key]
            h = key_hash[key]
            keys = h.keys
            # No records have the foreign key set for this association, so skip it
            next unless keys.length > 0
            ds = assoc_class.filter(assoc_class.primary_key=>keys)
            ds = cascade.call(ds)
            ds.all do |assoc_object|
              h[assoc_object.pk].each do |object|
                object.instance_variable_set(:"@#{assoc_name}", assoc_object)
              end
            end
          when :one_to_many, :many_to_many
            if rtype == :one_to_many
              fkey = key = reflection[:key]
              h = key_hash[model.primary_key]
              reciprocal = model.send(:reciprocal_association, reflection)
              ds = assoc_class.filter(key=>h.keys)
            else
              assoc_table = assoc_class.table_name
              left = reflection[:left_key]
              right = reflection[:right_key]
              right_pk = (reflection[:right_primary_key] || :"#{assoc_table}__#{assoc_class.primary_key}")
              join_table = reflection[:join_table]
              fkey = (reflection[:left_key_alias] ||= :"x_foreign_key_x")
              table_selection = (reflection[:select] ||= assoc_table.*)
              key_selection = (reflection[:left_key_select] ||= :"#{join_table}__#{left}___#{fkey}")
              h = key_hash[model.primary_key]
              ds = assoc_class.select(table_selection, key_selection).inner_join(join_table, right=>right_pk, left=>h.keys)
            end
            if order = reflection[:order]
              ds = ds.order(order)
            end
            ds = cascade.call(ds)
            ivar = :"@#{assoc_name}"
            h.values.each do |object_array|
              object_array.each do |object|
                object.instance_variable_set(ivar, [])
              end
            end
            ds.all do |assoc_object|
              fk = if rtype == :many_to_many
                assoc_object.values.delete(fkey)
              else
                assoc_object[fkey]
              end
              h[fk].each do |object|
                object.instance_variable_get(ivar) << assoc_object
                assoc_object.instance_variable_set(reciprocal, object) if reciprocal
              end
            end
        end
      end
    end

    # Build associations from the graph if .eager_graph was used, 
    # and/or load other associations if .eager was used.
    def post_load(all_records)
      eager_graph_build_associations(all_records) if @opts[:eager_graph]
      eager_load(all_records) if @opts[:eager]
    end
end
