bundle exec rspec spec/unit/outputs/elasticsearch/cache_optimization_spec.rb -fdrequire 'spec_helper'
require 'logstash/outputs/elasticsearch'

describe "Dynamic ILM Cache Optimization" do
  let(:options) do
    {
      "hosts" => ["localhost:9200"],
      "ilm_enabled" => true,
      "ilm_rollover_alias" => "%{[container_name]}",
      "ilm_policy" => "%{[container_name]}-ilm-policy",
      "ilm_auto_create_policy" => true,
      "ilm_auto_create_template" => true
    }
  end
  
  let(:output) { LogStash::Outputs::ElasticSearch.new(options) }
  
  before do
    allow(output).to receive(:client).and_return(client)
    allow(output).to receive(:logger).and_return(logger)
    output.register
  end
  
  let(:client) { double("client") }
  let(:logger) { double("logger") }
  
  describe "field-based cache" do
    it "builds cache key from raw field values" do
      event = LogStash::Event.new("container_name" => "dotcms")
      
      cache_key = output.send(:build_raw_cache_key, event)
      
      expect(cache_key).to include("container_name")
      expect(cache_key).to include("dotcms")
    end
    
    it "extracts field references from sprintf patterns" do
      pattern = "%{[container_name]}"
      fields = output.send(:extract_field_references, pattern)
      
      expect(fields).to eq(["[container_name]"])
    end
    
    it "handles multiple field references" do
      pattern = "%{[kubernetes][namespace]}-%{[container]}"
      fields = output.send(:extract_field_references, pattern)
      
      expect(fields).to eq(["[kubernetes][namespace]", "[container]"])
    end
  end
  
  describe "cache performance" do
    let(:event1) { LogStash::Event.new("container_name" => "dotcms") }
    let(:event2) { LogStash::Event.new("container_name" => "dotcms") }
    let(:event3) { LogStash::Event.new("container_name" => "api") }
    
    before do
      # Mock client methods
      allow(client).to receive(:ilm_policy_exists?).and_return(false)
      allow(client).to receive(:ilm_policy_put)
      allow(client).to receive(:rollover_alias_exists?).and_return(false)
      allow(client).to receive(:rollover_alias_put)
      allow(client).to receive(:template_put)
      allow(logger).to receive(:info)
      allow(logger).to receive(:debug)
    end
    
    it "caches first event and skips sprintf on second identical event" do
      # First event - should call sprintf
      expect(event1).to receive(:sprintf).at_least(:once).and_call_original
      output.send(:ensure_dynamic_ilm_alias, event1)
      
      # Second event with same field value - should NOT call sprintf (cache hit)
      expect(event2).not_to receive(:sprintf)
      output.send(:ensure_dynamic_ilm_alias, event2)
    end
    
    it "processes new container on cache miss" do
      # First container
      output.send(:ensure_dynamic_ilm_alias, event1)
      
      # Different container - cache miss, should process
      expect(event3).to receive(:sprintf).at_least(:once).and_call_original
      output.send(:ensure_dynamic_ilm_alias, event3)
    end
    
    it "maintains two-level cache (field + resolved)" do
      # Process first event
      output.send(:ensure_dynamic_ilm_alias, event1)
      
      # Check both caches are populated
      field_cache = output.instance_variable_get(:@dynamic_ilm_field_cache)
      resolved_cache = output.instance_variable_get(:@dynamic_ilm_aliases_created)
      
      expect(field_cache).not_to be_empty
      expect(resolved_cache).not_to be_empty
    end
  end
  
  describe "template creation optimization" do
    let(:event) { LogStash::Event.new("container_name" => "test") }
    
    before do
      allow(client).to receive(:ilm_policy_exists?).and_return(true)
      allow(client).to receive(:rollover_alias_exists?).and_return(false)
      allow(client).to receive(:rollover_alias_put)
      allow(logger).to receive(:info)
      allow(logger).to receive(:debug)
    end
    
    it "does not call template_exists? on cache hit" do
      # Create template first time
      allow(client).to receive(:template_put)
      output.send(:create_dynamic_index_template, "test", "test-policy")
      
      # Second call should hit cache and NOT call template_exists?
      expect(client).not_to receive(:template_exists?)
      output.send(:create_dynamic_index_template, "test", "test-policy")
    end
    
    it "handles template already exists error gracefully" do
      error = LogStash::Outputs::ElasticSearch::HttpClient::Pool::BadResponseCodeError.new(
        400, "", "", "resource_already_exists_exception"
      )
      
      allow(client).to receive(:template_put).and_raise(error)
      
      # Should not raise, should cache the template
      expect {
        output.send(:create_dynamic_index_template, "test", "test-policy")
      }.not_to raise_error
      
      # Check it was cached
      templates = output.instance_variable_get(:@dynamic_templates_created)
      expect(templates).to include("logstash-test")
    end
  end
  
  describe "performance benchmark" do
    it "measures cache hit performance" do
      events = 1000.times.map { LogStash::Event.new("container_name" => "dotcms") }
      
      # Mock all client calls
      allow(client).to receive(:ilm_policy_exists?).and_return(false)
      allow(client).to receive(:ilm_policy_put)
      allow(client).to receive(:rollover_alias_exists?).and_return(false)
      allow(client).to receive(:rollover_alias_put)
      allow(client).to receive(:template_put)
      allow(logger).to receive(:info)
      allow(logger).to receive(:debug)
      
      # First event - cache miss
      start_time = Time.now
      output.send(:ensure_dynamic_ilm_alias, events[0])
      first_time = Time.now - start_time
      
      # Remaining 999 events - cache hits
      start_time = Time.now
      events[1..-1].each do |event|
        output.send(:ensure_dynamic_ilm_alias, event)
      end
      cached_time = Time.now - start_time
      avg_cached = cached_time / 999.0
      
      puts "\nPerformance Results:"
      puts "First event (cache miss): #{(first_time * 1000).round(2)}ms"
      puts "Cached events (999): #{(cached_time * 1000).round(2)}ms total"
      puts "Average per cached event: #{(avg_cached * 1000000).round(2)}µs"
      
      # Cache hits should be much faster than first event
      expect(avg_cached).to be < (first_time / 10.0)
    end
  end
end
