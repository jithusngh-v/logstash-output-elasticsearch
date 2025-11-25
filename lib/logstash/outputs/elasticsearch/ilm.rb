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
        
        # Check if policy exists (for custom policies)
        if resolved_policy && resolved_policy != DEFAULT_POLICY
          unless client.ilm_policy_exists?(resolved_policy)
            raise LogStash::ConfigurationError, 
                  "ILM policy '#{resolved_policy}' does not exist. Please create it first using: PUT _ilm/policy/#{resolved_policy}"
          end
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
              'index.lifecycle.name' => resolved_policy || DEFAULT_POLICY,
              'index.lifecycle.rollover_alias' => resolved_alias
            }
          }
          
          logger.info("Creating dynamic ILM rollover alias", 
                     :alias => resolved_alias, 
                     :policy => resolved_policy || DEFAULT_POLICY,
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
          },
          'settings' => {
              'index.lifecycle.name' => ilm_policy,
              'index.lifecycle.rollover_alias' => ilm_rollover_alias
          }
      }
    end

    def policy_payload
      policy_path = ::File.expand_path(ILM_POLICY_PATH, ::File.dirname(__FILE__))
      LogStash::Json.load(::IO.read(policy_path))
    end
  end
end; end; end
