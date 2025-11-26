require 'set'

module LogStash; module Outputs; class ElasticSearch
  module Ilm

    ILM_POLICY_PATH = "default-ilm-policy.json"

    def setup_ilm
      # Skip setup if using dynamic (sprintf) ILM configuration
      return if ilm_has_sprintf?
      
      logger.warn("Overwriting supplied index #{@index} with rollover alias #{@ilm_rollover_alias}") unless default_index?(@index)
      @index = @ilm_rollover_alias
      maybe_create_rollover_alias
      maybe_create_ilm_policy
    end
    
    def ilm_has_sprintf?
      (@ilm_rollover_alias && @ilm_rollover_alias.match(/%{.*?}/)) ||
      (@ilm_policy && @ilm_policy.match(/%{.*?}/))
    end

    # Resolve ILM rollover alias for a specific event
    def resolve_ilm_rollover_alias(event)
      return @ilm_rollover_alias unless @ilm_rollover_alias
      resolved = event.sprintf(@ilm_rollover_alias)
      
      # Validate that the alias was properly resolved and is not empty
      if resolved.nil? || resolved.empty?
        raise EventMappingError, "ILM rollover alias resolved to empty string for pattern: #{@ilm_rollover_alias}"
      end
      
      # Check if sprintf pattern wasn't resolved (still contains placeholders)
      if resolved.match(/%{.*?}/)
        raise EventMappingError, "ILM rollover alias contains unresolved placeholders: #{resolved}"
      end
      
      resolved
    end
    
    # Resolve ILM policy name for a specific event
    def resolve_ilm_policy(event)
      return ilm_policy unless @ilm_policy
      resolved = event.sprintf(@ilm_policy)
      
      # Validate that the policy name was properly resolved and is not empty
      if resolved.nil? || resolved.empty?
        raise EventMappingError, "ILM policy resolved to empty string for pattern: #{@ilm_policy}"
      end
      
      # Check if sprintf pattern wasn't resolved (still contains placeholders)
      if resolved.match(/%{.*?}/)
        raise EventMappingError, "ILM policy contains unresolved placeholders: #{resolved}"
      end
      
      resolved
    end

    # Ensure dynamic ILM rollover alias exists for a specific event
    # This is called when using sprintf patterns in ilm_rollover_alias
    def ensure_dynamic_ilm_alias(event)
      return unless ilm_in_use? && ilm_has_sprintf?
      
      resolved_alias = resolve_ilm_rollover_alias(event)
      resolved_policy = resolve_ilm_policy(event) if @ilm_policy
      
      # Thread-safe check and create
      @dynamic_ilm_aliases_lock ||= Mutex.new
      @dynamic_ilm_aliases_created ||= Set.new
      
      alias_key = "#{resolved_alias}:#{resolved_policy}"
      
      return if @dynamic_ilm_aliases_created.include?(alias_key)      
      @dynamic_ilm_aliases_lock.synchronize do
        # Double-check inside the lock
        return if @dynamic_ilm_aliases_created.include?(alias_key)
        
        # Determine which policy to use
        policy_to_use = resolved_policy
        
        # Ensure policy exists (create if missing for custom policies)
        if resolved_policy && resolved_policy != DEFAULT_POLICY
          unless client.ilm_policy_exists?(resolved_policy)
            if @ilm_auto_create_policy
              logger.warn("ILM policy '#{resolved_policy}' does not exist. Creating with default configuration.", 
                         :alias => resolved_alias,
                         :policy => resolved_policy)
              begin
                # Create policy with default configuration
                client.ilm_policy_put(resolved_policy, policy_payload)
                logger.info("Successfully created ILM policy", :policy => resolved_policy)
              rescue => policy_error
                # If creation fails and fallback is configured, use fallback
                if @ilm_policy_fallback
                  logger.warn("Failed to create ILM policy '#{resolved_policy}', using fallback policy '#{@ilm_policy_fallback}'",
                             :error => policy_error.message,
                             :alias => resolved_alias)
                  policy_to_use = @ilm_policy_fallback
                  # Update alias_key to reflect the actual policy being used
                  alias_key = "#{resolved_alias}:#{policy_to_use}"
                  # Check if this combination already exists
                  return if @dynamic_ilm_aliases_created.include?(alias_key)
                else
                  raise LogStash::ConfigurationError, 
                        "Failed to create ILM policy '#{resolved_policy}': #{policy_error.message}. " +
                        "Please create it manually using: PUT _ilm/policy/#{resolved_policy}"
                end
              end
            elsif @ilm_policy_fallback
              # Auto-creation disabled but fallback configured
              logger.warn("ILM policy '#{resolved_policy}' does not exist and auto-creation is disabled. Using fallback policy '#{@ilm_policy_fallback}'",
                         :alias => resolved_alias)
              policy_to_use = @ilm_policy_fallback
              # Update alias_key to reflect the actual policy being used
              alias_key = "#{resolved_alias}:#{policy_to_use}"
              # Check if this combination already exists
              return if @dynamic_ilm_aliases_created.include?(alias_key)
            else
              raise LogStash::ConfigurationError, 
                    "ILM policy '#{resolved_policy}' does not exist and auto-creation is disabled. " +
                    "Please create it first using: PUT _ilm/policy/#{resolved_policy} or set ilm_auto_create_policy => true or configure ilm_policy_fallback"
            end
          end        
        end
          # Create index template if auto-creation is enabled and template doesn't exist
        if @ilm_auto_create_template
          logger.info("Attempting to create dynamic index template", 
                     :alias => resolved_alias,
                     :policy => policy_to_use || DEFAULT_POLICY,
                     :auto_create_enabled => @ilm_auto_create_template)
          create_dynamic_index_template(resolved_alias, policy_to_use || DEFAULT_POLICY)
        else
          logger.debug("Template auto-creation is disabled", :auto_create_template => @ilm_auto_create_template)
        end
        
        # Create the rollover alias if it doesn't exist
        unless client.rollover_alias_exists?(resolved_alias)
          target = "<#{resolved_alias}-#{ilm_pattern}>"
          payload = {
            'aliases' => {
              resolved_alias => {
                'is_write_index' => true
              }
            },
            'settings' => {
              'index.lifecycle.name' => policy_to_use || DEFAULT_POLICY,
              'index.lifecycle.rollover_alias' => resolved_alias
            }
          }
          
          logger.info("Creating dynamic ILM rollover alias", 
                     :alias => resolved_alias, 
                     :policy => policy_to_use || DEFAULT_POLICY,
                     :target => target)
          
          client.rollover_alias_put(target, payload)
        end
        
        @dynamic_ilm_aliases_created.add(alias_key)
      end
    rescue => e
      logger.error("Failed to create dynamic ILM alias", 
                  :alias => resolved_alias, 
                  :policy => resolved_policy,
                  :error => e.message,
                  :backtrace => e.backtrace.first(5))
      raise
    end

    def ilm_in_use?
      return @ilm_actually_enabled if defined?(@ilm_actually_enabled)
      @ilm_actually_enabled =
        begin
          if serverless?
            raise LogStash::ConfigurationError, "Invalid ILM configuration `ilm_enabled => true`. " +
              "Serverless Elasticsearch cluster does not support Index Lifecycle Management." if @ilm_enabled.to_s == 'true'
            @logger.info("ILM auto configuration (`ilm_enabled => auto` or unset) resolved to `false`. "\
              "Serverless Elasticsearch cluster does not support Index Lifecycle Management.") if @ilm_enabled == 'auto'
            false
          elsif @ilm_enabled == 'auto'
            ilm_alias_set?
          elsif @ilm_enabled.to_s == 'true'
            ilm_alias_set?
          else
            false
          end
        end
    end

    private

    def ilm_alias_set?
      default_index?(@index) || !default_rollover_alias?(@ilm_rollover_alias)
    end

    def default_index?(index)
      index == @default_index
    end

    def default_rollover_alias?(rollover_alias)
      rollover_alias == default_ilm_rollover_alias
    end

    def ilm_policy_default?
      ilm_policy == LogStash::Outputs::ElasticSearch::DEFAULT_POLICY
    end

    def maybe_create_ilm_policy
      if ilm_policy_default?
        client.ilm_policy_put(ilm_policy, policy_payload) unless client.ilm_policy_exists?(ilm_policy)
      else
        raise LogStash::ConfigurationError, "The specified ILM policy #{ilm_policy} does not exist on your Elasticsearch instance" unless client.ilm_policy_exists?(ilm_policy)
      end
    end

    def maybe_create_rollover_alias
            client.rollover_alias_put(rollover_alias_target, rollover_alias_payload) unless client.rollover_alias_exists?(ilm_rollover_alias)
    end

    def rollover_alias_target
      "<#{ilm_rollover_alias}-#{ilm_pattern}>"
    end

    def rollover_alias_payload
      {
          'aliases' => {
              ilm_rollover_alias =>{
                  'is_write_index' =>  true
              }
          },          'settings' => {
              'index.lifecycle.name' => ilm_policy,
              'index.lifecycle.rollover_alias' => ilm_rollover_alias
          }
      }
    end
    
    def policy_payload
      @policy_payload_cache ||= load_policy_from_file
    end

    private

    def load_policy_from_file
      # Check for custom ILM policy path in environment variable
      custom_policy_path = ENV['ILM_POLICY_PATH'] || ENV['LOGSTASH_ILM_POLICY_PATH']
      
      if custom_policy_path && !custom_policy_path.empty?
        # Custom policy path provided via environment variable
        if ::File.exist?(custom_policy_path)
          begin
            logger.info("Loading custom ILM policy from environment variable", 
                       :path => custom_policy_path,
                       :env_var => custom_policy_path == ENV['ILM_POLICY_PATH'] ? 'ILM_POLICY_PATH' : 'LOGSTASH_ILM_POLICY_PATH')
            policy_content = ::IO.read(custom_policy_path)
            policy = LogStash::Json.load(policy_content)
            logger.info("Successfully loaded custom ILM policy", :path => custom_policy_path)
            return policy
          rescue => e
            logger.error("Failed to load custom ILM policy from environment variable, falling back to default", 
                        :path => custom_policy_path,
                        :error => e.message,
                        :backtrace => e.backtrace.first(3))
            # Fall through to default policy
          end
        else
          logger.error("Custom ILM policy path specified in environment variable does not exist, falling back to default", 
                      :path => custom_policy_path,
                      :env_var => custom_policy_path == ENV['ILM_POLICY_PATH'] ? 'ILM_POLICY_PATH' : 'LOGSTASH_ILM_POLICY_PATH')
          # Fall through to default policy
        end
      end
      
      # Load default policy
      default_policy_path = ::File.expand_path(ILM_POLICY_PATH, ::File.dirname(__FILE__))
      begin
        logger.info("Loading default ILM policy", :path => default_policy_path)
        policy_content = ::IO.read(default_policy_path)
        policy = LogStash::Json.load(policy_content)
        logger.debug("Successfully loaded default ILM policy")
        return policy
      rescue => e
        logger.error("Failed to load default ILM policy file", 
                    :path => default_policy_path,
                    :error => e.message)
        raise LogStash::ConfigurationError, 
              "Cannot load ILM policy: #{e.message}. " +
              "Please ensure the default policy file exists at #{default_policy_path} " +
              "or provide a valid custom policy path via ILM_POLICY_PATH or LOGSTASH_ILM_POLICY_PATH environment variable."
      end
    end

    public

    # Create index template for dynamic alias with caching
    def create_dynamic_index_template(resolved_alias, policy_name)
      @dynamic_templates_created ||= Set.new
        # Cache key for template
      template_name = "logstash-#{resolved_alias}"
      
      # Fast path - already created
      if @dynamic_templates_created.include?(template_name)
        logger.debug("Template already created in this session", :template => template_name)
        return
      end
      
      # Check if template already exists in Elasticsearch
      if template_exists?(template_name)
        logger.info("Template already exists in Elasticsearch, skipping creation", :template => template_name)
        @dynamic_templates_created.add(template_name)
        return
      end
      
      logger.info("Creating dynamic index template",
                 :template => template_name,
                 :alias => resolved_alias,
                 :policy => policy_name)
      
      begin        # Build template payload with your custom settings
        template_payload = build_template_payload(resolved_alias, policy_name)
        
        # Use _index_template endpoint (ES 7.8+) or _template for older versions
        template_endpoint = use_index_template_api? ? '_index_template' : '_template'
        
        # Create the template
        client.template_put(template_endpoint, template_name, template_payload)
        
        # Cache it
        @dynamic_templates_created.add(template_name)
          logger.info("Successfully created dynamic index template", :template => template_name)
      rescue => e
        logger.error("Failed to create dynamic index template",
                   :template => template_name,
                   :error => e.message,
                   :backtrace => e.backtrace.first(5))
        # Don't fail the event if template creation fails
        # The index will still be created, just without the template
      end
    end

    # Build index template payload matching your Python script requirements
    def build_template_payload(resolved_alias, policy_name)
      # Default settings matching your requirements
      default_settings = {
        'index' => {
          'lifecycle' => {
            'name' => policy_name,
            'rollover_alias' => resolved_alias
          },
          'routing' => {
            'allocation' => {
              'include' => {
                '_tier_preference' => 'data_content'
              }
            }
          },
          'refresh_interval' => '5s',
          'number_of_shards' => 1,
          'number_of_replicas' => 0
        }
      }
      
      # Deep merge with custom settings if provided
      merged_settings = deep_merge(default_settings, @ilm_template_settings || {})
      
      # Default mappings matching your requirements
      default_mappings = {
        'dynamic_templates' => [
          {
            'message_field' => {
              'path_match' => 'message',
              'match_mapping_type' => 'string',
              'mapping' => {
                'type' => 'text',
                'norms' => false
              }
            }
          },
          {
            'string_fields' => {
              'match' => '*',
              'match_mapping_type' => 'string',
              'mapping' => {
                'type' => 'text',
                'norms' => false,
                'fields' => {
                  'keyword' => {
                    'type' => 'keyword',
                    'ignore_above' => 256
                  }
                }
              }
            }
          }
        ],
        'properties' => {
          '@timestamp' => { 'type' => 'date' },
          '@version' => { 'type' => 'keyword' },
          'geoip' => {
            'dynamic' => true,
            'properties' => {
              'ip' => { 'type' => 'ip' },
              'latitude' => { 'type' => 'half_float' },
              'longitude' => { 'type' => 'half_float' },
              'location' => { 'type' => 'geo_point' }
            }
          }
        }
      }
      
      # Deep merge with custom mappings if provided
      merged_mappings = deep_merge(default_mappings, @ilm_template_mappings || {})
      
      # Return complete template payload
      {
        'index_patterns' => ["#{resolved_alias}-*"],
        'template' => {
          'settings' => merged_settings,
          'mappings' => merged_mappings,
          'aliases' => {}
        },
        'priority' => 300,
        '_meta' => {
          'description' => 'Dynamically created template for ILM-managed index',
          'created_by' => 'logstash-output-elasticsearch',
          'created_at' => Time.now.utc.iso8601
        }
      }
    end    
    # Check if template exists
    def template_exists?(template_name)
      begin
        template_endpoint = use_index_template_api? ? '_index_template' : '_template'
        # Return the actual result from template_exists?
        client.template_exists?(template_endpoint, template_name)
      rescue ::LogStash::Outputs::ElasticSearch::HttpClient::Pool::NotFoundError
        false
      rescue => e
        logger.warn("Error checking template existence", 
                   :template => template_name,
                   :error => e.message)
        false
      end
    end

    # Check if we should use the new _index_template API (ES 7.8+)
    def use_index_template_api?
      @use_index_template_api ||= begin
        maximum_seen_major_version >= 8 || (maximum_seen_major_version == 7 && client.last_es_version >= '7.8.0')
      end
    end

    def maximum_seen_major_version
      @maximum_seen_major_version ||= client.maximum_seen_major_version || 0
    end

    # Deep merge two hashes
    def deep_merge(hash1, hash2)
      result = hash1.dup
      hash2.each do |key, value|
        if result[key].is_a?(Hash) && value.is_a?(Hash)
          result[key] = deep_merge(result[key], value)
        else
          result[key] = value
        end
      end
      result
    end
  end
end; end; end
