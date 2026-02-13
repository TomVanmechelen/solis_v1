  module Solis
  module Shape
    module Reader
      class CSV
        def self.read(dir, model_id, options = {})
          class << self
            def progress(i, data)
              if data.key?(:job_id) && data.key?(:store)
                job_id = data[:job_id]
                progress = data[:store]
                progress[job_id] = i
              end
            end

            def validate(csvs, prefixes = nil, metadata = nil)
              # raise "Please make sure the sheet contains '_PREFIXES', '_METADATA', '_ENTITIES' tabs" unless (%w[_PREFIXES _METADATA _ENTITIES] - csvs.keys).length == 0
              prefixes = csvs.key?('_PREFIXES') && prefixes.nil? ? csvs['_PREFIXES'] : prefixes
              metadata = csvs.key?('_METADATA') && metadata.nil? ? csvs['_METADATA'] : metadata

              raise "_PREFIXES tab must have ['base', 'prefix', 'uri'] as a header at row 1" unless (%w[base prefix uri] - prefixes.flat_map(&:keys).uniq).length == 0
              raise '_PREFIXES.base can only have one base URI' if prefixes.map { |m| m['base'] }.grep(/\*/).count != 1

              raise "_METADATA tab must have ['key', 'value'] as a header at row 1" unless (%w[key value] - metadata.flat_map(&:keys).uniq).length == 0

              if csvs.key?('_ENTITIES')
                entities = csvs['_ENTITIES']
                raise "_ENTITIES tab must have ['name', 'nameplural', 'description', 'subclassof', 'sameas'] as a header at row 1" unless (%w[name nameplural description subclassof sameas] - entities.flat_map(&:keys).uniq).length == 0

                entities.each do |entity|
                  raise "Plural not found for #{entity['name']}" if entity['nameplural'].nil? || entity['nameplural'].empty?
                end
              end

              csvs.each do |sheet_name, sheet|
                if sheet_name !~ /^_/
                  entities = csvs[sheet_name]
                  raise "#{sheet_name} tab must have ['Name', 'Description', 'MIN', 'MAX', 'sameAs', 'datatype'] as a header at row 1" unless (%w[name description min max sameas datatype] - entities.flat_map(&:keys).uniq).length == 0
                end
              end
            end

            def read_csvs(dir, model_id, options)
              data = nil
              prefixes = options[:prefixes] || nil
              metadata = options[:metadata] || nil
             
              header_cleaner = ->(h) { h&.to_s&.strip&.downcase&.gsub(/\s+/, '_') }

              cache_dir = ConfigFile.include?(:cache) ? ConfigFile[:cache] : '/tmp'
              cache_file = "#{cache_dir}/#{model_id}.json"

              if ::File.exist?(cache_file) && options[:from_cache]
                Solis::LOGGER.info("from cache #{cache_file}")
                data = JSON.parse(::File.read(cache_file), { symbolize_names: true })
                return data
              else
                Solis::LOGGER.info("from source #{model_id}")
                working_dir = ::File.join(dir, model_id)
                Solis::LOGGER.info("Read CSV's from #{working_dir}")

                unless Dir.exist?(working_dir)
                  Solis::LOGGER.error("#{working_dir} does not exists")
                  raise "#{working_dir} does not exists"
                end


                result = {}
                ::Dir.glob(::File.join(working_dir, '*.csv')).each do |file|
                  filename = ::File.basename(file, '.csv')
                  rows = ::CSV.read(file, headers: true, header_converters: header_cleaner)

                  normalized = rows.headers.uniq
                  warn "Duplicate headers after normalization in #{filename}" if normalized.size != rows.headers.size
                  
                  result[filename] = rows.map(&:to_h)
                end

                validate(result, prefixes, metadata)

              end
              result
            end

            def process_csv(model_id, csvs, options = { follow: true })
              entities = {}
              prefixes = {}
              ontology_metadata = {}

              csvs['_PREFIXES'].each do |e|
                prefixes.store(e['prefix'].to_sym, { uri: e['uri'], base: e['base'].eql?('*') })
              end
              csvs['_METADATA'].each { |e| ontology_metadata.store(e['key'].to_sym, e['value']) }

              base_uri = prefixes.select { |_k, v| v[:base] }.select { |s| !s.empty? }

              graph_prefix = base_uri.keys.first
              graph_uri = base_uri.values.first[:uri]

              csvs['_ENTITIES'].each do |e|

                top_class = e['name'].to_s
                top_sheet = csvs[top_class] || nil
                # if csvs[top_class].nil? && !(e['subclassof'].nil? || e['subclassof'].empty?)
                #   top_sheet = csvs[e['subclassof'].split(':').last.to_s] || nil
                # end
                # if prefixes[graph_prefix][:data].nil? || prefixes[graph_prefix][:data].empty?
                entity_data = parse_entity_data(e['name'].to_s, graph_prefix, graph_uri, top_sheet, { prefixes: prefixes, follow: options[:follow] })
                #  prefixes[graph_prefix][:data] = entity_data
                # else
                #  entity_data = prefixes[graph_prefix][:data]
                # end

                if entity_data.empty?
                  entity_data[:id] = {
                    datatype: 'xsd:string',
                    path: "#{graph_prefix}:id",
                    cardinality: { min: '1', max: '1' },
                    same_as: '',
                    description: 'systeem UUID'
                  }
                end

                entities.store(e['name'].to_sym, { description: e['description'],
                                                   order: e['order'],
                                                   plural: e['nameplural'],
                                                   label: e['name'].to_s.strip,
                                                   sub_class_of: e['subclassof'].nil? || e['subclassof'].empty? ? [] : [e['subclassof']],
                                                   same_as: e['sameas'],
                                                   properties: entity_data })
              end

              data = {
                entities: entities,
                ontologies: {
                  all: prefixes,
                  base: {
                    prefix: graph_prefix,
                    uri: graph_uri
                  }
                },
                metadata: ontology_metadata
              }

              cache_dir = ConfigFile.include?(:cache) ? ConfigFile[:cache] : '/tmp'
              ::File.open("#{::File.absolute_path(cache_dir)}/#{model_id}.json", 'wb') do |f|
                f.puts data.to_json
              end

              data
            rescue StandardError => e
              raise Solis::Error::GeneralError, e.message
            end
            
            def parse_entity_data(entity_name, graph_prefix, _graph_name, e, options = {})
              properties = {}
              return properties unless e&.any?

              e.select! { |d| d['name'].present? }
              e.each do |p|
                property_name = I18n.transliterate(p['name'].strip)
                next if property_name.empty?
                next if properties.key?(property_name)

                min_max = %w[min max].each_with_object({}) do |n, acc|
                  acc[n] = p.key?(n) && p[n] =~ /\d+/ ? p[n].to_i.to_s : ''
                end

                properties[property_name] = {
                  datatype: p['datatype'],
                  path: "#{graph_prefix}:#{property_name.classify}",
                  cardinality: { min: min_max['min'], max: min_max['max'] },
                  same_as: p['sameas'],
                  order: p['order'],
                  description: p['description']
                }
              end

              properties
            end


            def header(data)
              out = data[:ontologies][:all].map do |k, v|
                "@prefix #{k}: <#{v[:uri]}> ."
              end.join("\n")

              "#{out}\n"
            end

            
            def classify_qname(qname, all_prefixes)
              prefix, _ = qname.strip.split(':', 2)
              kind = (prefix == 'xsd') ? :datatype : :class
              [kind, qname_to_uri(qname, all_prefixes)]
            end

            def safe_builtin_vocab(prefix)
              RDF::Vocabulary.from_sym(prefix.to_s.upcase.to_sym)
            rescue NameError
              nil
            end

            def qname_to_uri(qname, all_prefixes)
              prefix, local = qname.strip.split(':', 2)
              return RDF::URI("#{@graph_uri}#{qname}") if local.nil? || local.empty?

              vocab = safe_builtin_vocab(prefix)
              return vocab[local.to_sym] if vocab

              base = all_prefixes[prefix.to_sym] || all_prefixes[prefix.to_s]
              raise ArgumentError, "Unsupported prefix: #{prefix} in #{qname}" unless base

              RDF::URI("#{base}#{local}")
            end

            def qname_to_label(qname, graph_prefix)
              prefix, local = qname.strip.split(':', 2)
              prefix.to_s == graph_prefix.to_s ? local : qname
            end

            def union_node(qnames, all_prefixes)
              kinds_uris = qnames.map { |q| classify_qname(q, all_prefixes) }
              kinds = kinds_uris.map(&:first).uniq
              raise ArgumentError, "Mixed kinds in union: #{qnames.inspect} -> #{kinds.inspect}" if kinds.size != 1

              uris = kinds_uris.map(&:last)
              key  = uris.map(&:to_s).sort.join('|')
              hash = Digest::SHA256.hexdigest(key)[0, 16]

              return [@union_cache[key][:node], []] if @union_cache.key?(key)

              list = RDF::List[*uris]
              triples = []
              
              if kinds == [:datatype]
                node_iri = RDF::Node("U-#{hash}")
                triples << [node_iri, RDF.type, RDF::Vocab::RDFS.Datatype]
                triples << [node_iri, RDF::Vocab::OWL.unionOf, list]
              else
                node_iri = RDF::URI("#{@graph_uri}U-#{hash}")
                node_label = qnames.map { |q| qname_to_label(q, @graph_prefix) }.join(' OR ')
                triples << [node_iri, RDF.type, RDF::Vocab::OWL.Class]
                triples << [node_iri, RDF::Vocab::OWL.unionOf, list]
                triples << [node_iri, RDF::Vocab::RDFS.label, RDF::Literal(node_label)]
                @union_cache[key] = { node: node_iri, triples: triples, list: list }
              end
              [node_iri, triples]
            end

            def build_schema(datas)

              classes = {}
              datatype_properties = {}
              object_properties = {}
              @union_cache = {}
              extra_triples = []

              @graph_prefix = datas.first[:ontologies][:base][:prefix]
              @graph_uri = datas.first[:ontologies][:base][:uri]
              all_prefixes = datas.first[:ontologies][:all].each_with_object({}) { |(k, v), acc| acc[k] = v[:uri] }
              
              external_classes = {}
              external_properties = {}

              datas.each do |data|
                data[:entities].each do |entity_name, metadata|
                  # Separate external classes (with qnames like prov:Activity) from local classes
                  if entity_name.to_s.include?(':')
                    external_classes[entity_name] = metadata
                  else
                    # Define the class for base namespace entities
                    classes[entity_name] = {
                      comment:     metadata[:description],
                      label:       entity_name.to_s,
                      type:        RDF::Vocab::OWL.Class,
                      subClassOf:  metadata[:sub_class_of] || []
                    }
                  end

                (metadata[:properties] || {}).each do |property, property_metadata|
                  attribute = property.to_s.strip
                  description = property_metadata[:description]
                  datatype = property_metadata[:datatype]
                  path_uri = qname_to_uri(attribute, all_prefixes)

                  # Separate external properties (with qnames) from local properties
                  if attribute.include?(':')
                    # Store external properties for later as triples
                    if !external_properties.key?(attribute)
                      external_properties[attribute] = {
                        description: description,
                        datatype: datatype,
                        property_metadata: property_metadata,
                        domains: []
                      }
                    end
                    
                    entity_uri = entity_name.to_s.include?(':') ? qname_to_uri(entity_name.to_s, all_prefixes) : RDF::URI("#{@graph_uri}#{entity_name}")
                    external_properties[attribute][:domains] << entity_uri
                  else
                    # Process local properties normally
                    schema_data = datatype_properties[attribute] || {}
                    domain = Array(schema_data[:domain])
                    entity_uri = entity_name.to_s.include?(':') ? qname_to_uri(entity_name.to_s, all_prefixes) : RDF::URI("#{@graph_uri}#{entity_name}")
                    domain << entity_uri
                    domain.uniq!

                    if datatype&.include?(',')
                      datatypes = datatype.split(',').map(&:strip)
                      begin
                        range_node, union_triples = union_node(datatypes, all_prefixes)
                      rescue ArgumentError => e
                        Solis::LOGGER.error("ERROR: creating union_node for Attribute: #{attribute}")
                        raise
                      end
                      datatype = range_node
                      extra_triples.concat(Array(union_triples))
                    elsif datatype&.present?
                      datatype = qname_to_uri(datatype, all_prefixes)
                    end

                    datatype_properties[attribute] = {
                      domain: domain,
                      comment: RDF::Literal(description.to_s, language: :en),
                      label: RDF::Literal(attribute.to_s, language: :en),
                      range: datatype,
                      type: RDF::RDFV.Property
                    }

                    datatype_properties[attribute]['owl:sameAs'] = property_metadata[:same_as] if property_metadata[:same_as]&.present?
                  end

                  card = property_metadata[:cardinality] || {}
                  subclass_data = Array(data[:entities][entity_name][:sub_class_of])
                  
                  %w[min max].each do |type|
                    value = card[type]
                    next unless value&.present?
                    
                    bnode = RDF::Node.new
                    subclass_data << bnode
                    extra_triples << [bnode, RDF.type, RDF::Vocab::OWL.Restriction]
                    extra_triples << [bnode, RDF::Vocab::OWL.onProperty, path_uri]
                    
                    cardinality_type = type == 'min' ? RDF::Vocab::OWL.minCardinality : RDF::Vocab::OWL.maxCardinality
                    extra_triples << [bnode, cardinality_type, RDF::Literal(value.to_i, datatype: RDF::Vocab::XSD.nonNegativeInteger)]
                  end
                  
                  data[:entities][entity_name][:sub_class_of] = subclass_data
                end
                end
              end

              # Build vocabulary/ontology
              Solis::LOGGER.info("Build vocabulary/ontology")
              lp = RDF::StrictVocabulary(@graph_uri)
              o = ::Class.new(lp) do
                classes.each { |k, v| term k.to_sym, v }
                object_properties.each { |k, v| property((k.is_a?(RDF::URI) ? k.value.to_sym : k.to_sym), v) }
                datatype_properties.each { |k, v| property((k.is_a?(RDF::URI) ? k.value.to_sym : k.to_sym), v) }
              end

              RDF::Vocabulary.register(@graph_prefix.to_sym, o, uri: @graph_uri)
              
              # Add external classes as direct RDF triples (not in vocabulary)
              external_classes.each do |entity_name, metadata|
                entity_uri = qname_to_uri(entity_name.to_s, all_prefixes)
                extra_triples << [entity_uri, RDF.type, RDF::Vocab::OWL.Class]
                extra_triples << [entity_uri, RDF::Vocab::RDFS.label, RDF::Literal(entity_name.to_s, language: :en)]
                extra_triples << [entity_uri, RDF::Vocab::RDFS.comment, RDF::Literal(metadata[:description].to_s, language: :en)] if metadata[:description]&.present?
                
                # Add subclass relationships
                Array(metadata[:sub_class_of]).each do |sub_class|
                  sub_uri = sub_class.to_s.include?(':') ? qname_to_uri(sub_class.to_s, all_prefixes) : RDF::URI("#{@graph_uri}#{sub_class}")
                  extra_triples << [entity_uri, RDF::Vocab::RDFS.subClassOf, sub_uri]
                end
              end

              # Add external properties as direct RDF triples (not in vocabulary)
              external_properties.each do |property_name, prop_data|
                property_uri = qname_to_uri(property_name.to_s, all_prefixes)
                extra_triples << [property_uri, RDF.type, RDF::Vocab::RDFS.property]
                extra_triples << [property_uri, RDF::Vocab::RDFS.label, RDF::Literal(property_name.to_s, language: :en)]
                extra_triples << [property_uri, RDF::Vocab::RDFS.comment, RDF::Literal(prop_data[:description].to_s, language: :en)] if prop_data[:description]&.present?
                
                # Add domain(s)
                prop_data[:domains].uniq.each do |domain_uri|
                  extra_triples << [property_uri, RDF::Vocab::RDFS.domain, domain_uri]
                end
                
                # Add range if specified
                if prop_data[:datatype]&.present?
                  datatype = prop_data[:datatype]
                  if datatype.include?(',')
                    datatypes = datatype.split(',').map(&:strip)
                    range_node, union_triples = union_node(datatypes, all_prefixes)
                    extra_triples << [property_uri, RDF::Vocab::RDFS.range, range_node]
                    extra_triples.concat(Array(union_triples))
                  else
                    range_uri = qname_to_uri(datatype, all_prefixes)
                    extra_triples << [property_uri, RDF::Vocab::RDFS.range, range_uri]
                  end
                end
              end
              
              Solis::LOGGER.info("Build triples graph")
              graph = RDF::Graph.new(base_uri: @graph_uri)
              graph.name = RDF::URI(@graph_uri)

              datas.each do |data|
                data[:entities]
                  .select { |_k, v| v[:same_as]&.present? }
                  .each do |k, v|
                    begin
                      target_uri = qname_to_uri(v[:same_as], all_prefixes)
                      graph << [target_uri, RDF::RDFV.type, RDF::Vocab::OWL.Class]
                      graph << [target_uri, RDF::Vocab::OWL.equivalentClass, o[k.to_sym]]
                    rescue StandardError => e
                      warn "Failed to resolve class same_as #{v[:same_as].inspect} for #{k}: #{e.message}"
                    end
                  end
              end

              Solis::LOGGER.info("Add vocabulary and restriction statements")
              o.to_enum.each_statement.with_index do |st, i|
                begin
                  graph << st
                rescue => e
                  warn "Failed at ##{i}: #{st.inspect}\n#{e.class}: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
                  break
                end
              end

              # Explicitly add the ontology as a named resource with its URI
              ontology_uri = RDF::URI(@graph_uri)
              graph << [ontology_uri, RDF.type, RDF::Vocab::OWL.Ontology]
              graph << [ontology_uri, RDF::Vocab::DC.title, RDF::Literal(datas.first[:metadata][:title].to_s)]
              graph << [ontology_uri, RDF::Vocab::DC.description, RDF::Literal(datas.first[:metadata][:description].to_s)]
              graph << [ontology_uri, RDF::Vocab::DC.creator, RDF::Literal(datas.first[:metadata][:author].to_s)]
              graph << [ontology_uri, RDF::Vocab::DC.date, RDF::Literal(Time.now.to_s)]
              graph << [ontology_uri, RDF::Vocab::OWL.versionInfo, RDF::Literal(datas.first[:metadata][:version].to_s)]

              Array(extra_triples).each { |s, p, o_term| graph << [s, p, o_term]; graph << o_term.each_statement if o_term.is_a?(RDF::List) }

              graph.dump(:ttl, prefixes: all_prefixes)

            rescue StandardError => e
              warn "#{e.class}: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
              raise
            end


            def build_inflections(datas)
              inflections = {}
              datas.each do |data|
                data[:entities].each do |entity, metadata|
                  inflections[entity] = metadata[:plural]
                  inflections[entity.to_s.underscore.to_sym] = metadata[:plural].underscore
                end
              end

              inflections.to_json
            rescue StandardError => e
              Solis::LOGGER.error("Error building inflections: #{e.message}")
              raise
            end
          end

          csv_data = read_csvs(dir, model_id, options)
          prefixes = csv_data['_PREFIXES']
          metadata = csv_data['_METADATA']

          options[:prefixes] = prefixes
          options[:metadata] = metadata
          
          csv_data['_PREFIXES'] ||= prefixes.select { |s| s['name'].present? }
          csv_data['_METADATA'] ||= metadata

          datas = if csv_data.key?('_PREFIXES')
                    [process_csv(model_id, csv_data)]
                  else
                    [csv_data]
                  end

        
          Solis::LOGGER.info('Generating SCHEMA')
          schema = build_schema(datas)
          Solis::LOGGER.info('Generating INFLECTIONS')
          inflections = build_inflections(datas)

          { inflections: inflections, schema: schema }
        end

      end
    end
  end
end
