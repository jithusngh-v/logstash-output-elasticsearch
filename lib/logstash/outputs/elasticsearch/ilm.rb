require 'concurrent'

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
      # If no alias configured or it doesn't contain sprintf, return as-is
      return @ilm_rollover_alias if @ilm_rollover_alias.nil? || !@ilm_rollover_alias.match(/%{.*?}/)
      
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
      # If no policy configured or it doesn't contain sprintf, return as-is
      return @ilm_policy if @ilm_policy.nil? || !@ilm_policy.match(/%{.*?}/)
      
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

    # Pre-validate and ensure dynamic ILM infrastructure exists
    # Called ONCE per unique alias at batch-processing time, NOT per event
    # Returns true if alias is ready, false if it should be sent to DLQ
    def ensure_dynamic_ilm_alias_batch(resolved_alias, resolved_policy)
      return true unless ilm_in_use? && ilm_has_sprintf?
      
      # Fast path: already validated and created
      alias_key = "#{resolved_alias}:#{resolved_policy}"
      return true if dynamic_alias_ready?(alias_key)
      
      # Slow path: need to create (only happens once per unique alias)
      create_dynamic_ilm_infrastructure(resolved_alias, resolved_policy, alias_key)
    rescue => e
      # Don't crash the pipeline - log and return false to route to DLQ
      logger.error("Failed to ensure dynamic ILM infrastructure - event will be routed to DLQ", 
                  :alias => resolved_alias, 
                  :policy => resolved_policy,
                  :error => e.message,
                  :error_class => e.class.name)
      false
    end

    # Fast, lock-free check if alias is ready
    def dynamic_alias_ready?(alias_key)
      @dynamic_ilm_aliases_ready ||= Concurrent::Map.new
      !!@dynamic_ilm_aliases_ready[alias_key]
    end

    # Mark alias as ready (thread-safe, lock-free)
    def mark_alias_ready(alias_key)
      @dynamic_ilm_aliases_ready ||= Concurrent::Map.new
      @dynamic_ilm_aliases_ready[alias_key] = true
    end

    # Create dynamic ILM infrastructure (template + alias + policy check)
    # Uses single lock for initialization, but caching prevents repeated calls
    def create_dynamic_ilm_infrastructure(resolved_alias, resolved_policy, alias_key)
      @dynamic_ilm_creation_lock ||= Mutex.new
      
      @dynamic_ilm_creation_lock.synchronize do
        # Double-check: another thread may have created it
        return true if dynamic_alias_ready?(alias_key)
        
        # Cardinality protection: prevent runaway alias creation
        check_alias_cardinality!
        
        # Step 1: Create template (if not exists)
        ensure_dynamic_ilm_template(resolved_alias, resolved_policy)
        
        # Step 2: Verify policy exists
        verify_ilm_policy_exists(resolved_policy)
        
        # Step 3: Create alias (idempotent)
        create_rollover_alias(resolved_alias, resolved_policy)
        
        # Step 4: Mark as ready
        mark_alias_ready(alias_key)
        
        logger.info("Dynamic ILM infrastructure ready", 
                   :alias => resolved_alias, 
                   :policy => resolved_policy || DEFAULT_POLICY)
        
        true
      end
    end

    # Cardinality protection: prevent cluster state explosion
    def check_alias_cardinality!
      @dynamic_ilm_aliases_ready ||= Concurrent::Map.new
      max_aliases = @dynamic_ilm_max_aliases || 1000  # Configurable limit
      
      if @dynamic_ilm_aliases_ready.size >= max_aliases
        raise LogStash::ConfigurationError, 
              "Dynamic ILM alias limit reached (#{max_aliases}). " +
              "This prevents cluster state explosion. " +
              "Check your sprintf pattern for high cardinality fields."
      end
    end

    # Verify ILM policy exists (fail fast if missing)
    def verify_ilm_policy_exists(resolved_policy)
      return if !resolved_policy || resolved_policy == DEFAULT_POLICY
      
      unless client.ilm_policy_exists?(resolved_policy)
        raise LogStash::ConfigurationError, 
              "ILM policy '#{resolved_policy}' does not exist in Elasticsearch. " +
              "Create it first: PUT _ilm/policy/#{resolved_policy}"
      end
    end

    # Create rollover alias (idempotent - safe to call multiple times)
    def create_rollover_alias(resolved_alias, resolved_policy)
      return if client.rollover_alias_exists?(resolved_alias)
      
      target = "#{resolved_alias}-#{@ilm_pattern}"
      payload = {
        'aliases' => {
          resolved_alias => {
            'is_write_index' => true
          }
        },
        'settings' => {
          'index.lifecycle.name' => resolved_policy || DEFAULT_POLICY,
          'index.lifecycle.rollover_alias' => resolved_alias
        }
      }
      
      logger.info("Creating dynamic ILM rollover alias", 
                 :alias => resolved_alias, 
                 :policy => resolved_policy || DEFAULT_POLICY,
                 :target => target)
      
      client.rollover_alias_put(target, payload)
    rescue ::LogStash::Outputs::ElasticSearch::HttpClient::Pool::BadResponseCodeError => e
      # If alias was created by another node/worker between check and create, that's fine
      if e.response_code == 400 && e.message =~ /resource_already_exists/i
        logger.debug("Alias already exists (race condition with another node)", 
                    :alias => resolved_alias)
        return
      end
      raise
    end

    # Create a template specific to this alias to avoid field mapping conflicts
    # This is crucial when different containers have different field schemas
    # Idempotent: safe to call multiple times
    def ensure_dynamic_ilm_template(resolved_alias, resolved_policy)
      @dynamic_ilm_templates_created ||= Concurrent::Map.new
      
      # Fast path: already created
      return if @dynamic_ilm_templates_created[resolved_alias]
      
      # Use logstash-{container_name} naming pattern for templates
      template_name = "logstash-#{resolved_alias}"
      index_pattern = "#{resolved_alias}-*"
      template_endpoint = TemplateManager.template_endpoint(self)
      
      # Check if template already exists (maybe created manually or by another instance)
      if client.template_exists?(template_endpoint, template_name)
        logger.debug("Template already exists, skipping creation", 
                    :template => template_name)
        @dynamic_ilm_templates_created[resolved_alias] = true
        return
      end
      
      # Build template with ILM settings
      template = build_dynamic_template(index_pattern, resolved_policy)
      
      logger.info("Creating dynamic ILM template for container-specific mappings", 
                 :template_name => template_name,
                 :index_pattern => index_pattern,
                 :policy => resolved_policy || DEFAULT_POLICY)
      
      # Install the template
      TemplateManager.install(client, template_endpoint, template_name, template, true)
      
      @dynamic_ilm_templates_created[resolved_alias] = true
    rescue ::LogStash::Outputs::ElasticSearch::HttpClient::Pool::BadResponseCodeError => e
      # If template creation fails due to "already exists", that's fine (race condition)
      if e.response_code == 400 && e.message =~ /resource_already_exists/i
        logger.debug("Template already exists (race condition)", 
                    :template => template_name)
        @dynamic_ilm_templates_created[resolved_alias] = true
        return
      end
      
      logger.error("Failed to create dynamic ILM template", 
                  :template => template_name,
                  :error => e.message)
      raise
    end
    
    # Build a template for dynamic ILM with container-specific pattern
    def build_dynamic_template(index_pattern, resolved_policy)
      template = if @template
        # User provided custom template - use it
        TemplateManager.read_template_file(@template)
      else
        # Use default template based on ES version
        TemplateManager.load_default_template(maximum_seen_major_version, ecs_compatibility)
      end
      
      # Set index pattern for this specific container
      template.delete('template') if template.include?('template') && maximum_seen_major_version == 7
      template['index_patterns'] = [index_pattern]
      
      # Add ILM settings
      settings = TemplateManager.resolve_template_settings(self, template)
      settings.update({
        'index.lifecycle.name' => resolved_policy || DEFAULT_POLICY,
        'index.lifecycle.rollover_alias' => index_pattern.gsub(/-\*$/, '')  # Remove trailing -*
      })
      
      template
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
          }
      }
    end

    def policy_payload
      policy_path = ::File.expand_path(ILM_POLICY_PATH, ::File.dirname(__FILE__))
      LogStash::Json.load(::IO.read(policy_path))
    end
  end
end; end; end
