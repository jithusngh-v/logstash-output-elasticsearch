# Dynamic ILM Setup Guide

## ⚠️ Critical Prerequisites for Production Use

When using **dynamic ILM** (sprintf patterns in `ilm_rollover_alias` or `ilm_policy`), you **must** manually configure Elasticsearch index templates **before** starting Logstash. The plugin cannot automatically create templates for dynamic patterns.

---

## Why Manual Template Setup is Required

### The Problem

Dynamic patterns like `logs-%{[environment]}` resolve differently for each event:
- Event with `environment=prod` → `logs-prod`
- Event with `environment=dev` → `logs-dev`

When ILM performs a rollover:
1. **First index** (`logs-prod-000001`): Works ✅ - Created by Logstash with ILM settings
2. **Second index** (`logs-prod-000002`): **BREAKS** ❌ - Created by ILM without template

Without an index template matching `logs-*`, the rolled-over index won't have:
- ILM policy association
- Proper field mappings
- Index settings

### The Solution

Create a **wildcard index template** in Elasticsearch that matches **all** possible dynamic alias patterns.

---

## Production Setup Instructions

### Step 1: Disable Logstash Template Management

**In your Logstash pipeline configuration:**

```ruby
output {
  elasticsearch {
    hosts => ["localhost:9200"]
    ilm_enabled => true
    ilm_rollover_alias => "logs-%{[environment]}"
    ilm_policy => "policy-%{[retention_days]}"
    
    # CRITICAL: Disable automatic template management
    manage_template => false
  }
}
```

### Step 2: Create ILM Policies in Elasticsearch

Create all ILM policies that your events might reference:

```bash
# Policy for 7-day retention (dev)
PUT _ilm/policy/policy-7
{
  "policy": {
    "phases": {
      "hot": {
        "actions": {
          "rollover": {
            "max_age": "1d",
            "max_primary_shard_size": "50gb"
          }
        }
      },
      "delete": {
        "min_age": "7d",
        "actions": { "delete": {} }
      }
    }
  }
}

# Policy for 30-day retention (staging)
PUT _ilm/policy/policy-30
{
  "policy": {
    "phases": {
      "hot": {
        "actions": {
          "rollover": {
            "max_age": "7d",
            "max_primary_shard_size": "50gb"
          }
        }
      },
      "warm": {
        "min_age": "15d",
        "actions": {
          "allocate": { "number_of_replicas": 1 }
        }
      },
      "delete": {
        "min_age": "30d",
        "actions": { "delete": {} }
      }
    }
  }
}

# Policy for 90-day retention (prod)
PUT _ilm/policy/policy-90
{
  "policy": {
    "phases": {
      "hot": {
        "actions": {
          "rollover": {
            "max_age": "30d",
            "max_primary_shard_size": "50gb"
          }
        }
      },
      "warm": {
        "min_age": "30d",
        "actions": {
          "allocate": { "require": { "data": "warm" } }
        }
      },
      "cold": {
        "min_age": "60d",
        "actions": {
          "allocate": { "require": { "data": "cold" } }
        }
      },
      "delete": {
        "min_age": "90d",
        "actions": { "delete": {} }
      }
    }
  }
}
```

### Step 3: Create Component Template (Optional but Recommended)

```bash
PUT _component_template/dynamic-logs-settings
{
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 1,
      "codec": "best_compression"
    },
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date" },
        "message": { "type": "text" },
        "environment": { "type": "keyword" },
        "service": { "type": "keyword" },
        "level": { "type": "keyword" }
      }
    }
  }
}
```

### Step 4: Create Wildcard Index Template

**This is the CRITICAL step** that prevents rollover failures.

#### Option A: Simple Wildcard (Matches all dynamic aliases)

```bash
PUT _index_template/dynamic-logs-template
{
  "index_patterns": ["logs-*"],
  "data_stream": {},
  "composed_of": ["dynamic-logs-settings"],
  "priority": 500,
  "template": {
    "settings": {
      "index.lifecycle.name": "policy-30",  # Default policy
      "index.lifecycle.rollover_alias": "logs-default"  # Placeholder
    }
  }
}
```

**Note**: The `index.lifecycle.rollover_alias` in the template is a placeholder. The actual alias is set by Logstash when creating the first index.

#### Option B: Pattern-Specific Templates (Better control)

```bash
# Template for environment-based logs
PUT _index_template/logs-by-environment
{
  "index_patterns": ["logs-prod-*", "logs-staging-*", "logs-dev-*"],
  "composed_of": ["dynamic-logs-settings"],
  "priority": 500,
  "template": {
    "settings": {}
  }
}

# Template for service-specific logs
PUT _index_template/logs-by-service
{
  "index_patterns": ["service-*-logs-*"],
  "composed_of": ["dynamic-logs-settings"],
  "priority": 500,
  "template": {
    "settings": {}
  }
}
```

### Step 5: Grant Required Elasticsearch Permissions

The Logstash service account needs these permissions:

```json
{
  "cluster": [
    "manage_ilm",
    "monitor"
  ],
  "indices": [
    {
      "names": ["logs-*", "service-*"],
      "privileges": ["create_index", "write", "manage", "view_index_metadata"]
    }
  ]
}
```

**Key points:**
- `manage` privilege is required for creating aliases
- Patterns must cover **all** possible dynamic alias names

---

## Multi-Instance Logstash Configuration

### Race Condition Prevention

When running multiple Logstash nodes, the plugin automatically handles race conditions:

```ruby
# No configuration changes needed - handled automatically
# Both nodes processing the first "prod" event simultaneously:
# - Node A: Creates logs-prod alias ✅
# - Node B: Receives "already exists" error → Ignores and continues ✅
```

The plugin catches `resource_already_exists_exception` and treats it as success.

### Monitoring Multiple Instances

Enable Logstash monitoring to track alias creations across your cluster:

```ruby
output {
  elasticsearch {
    # ...existing config...
  }
}

# In logstash.yml
xpack.monitoring.enabled: true
xpack.monitoring.elasticsearch.hosts: ["http://elasticsearch:9200"]
```

---

## Validation and Testing

### Step 1: Test with Sample Events

Create test events with different field values:

```bash
# Send test events via stdin
bin/logstash -e '
input { stdin { codec => json } }
output {
  elasticsearch {
    hosts => ["localhost:9200"]
    ilm_enabled => true
    ilm_rollover_alias => "logs-%{[environment]}"
    ilm_policy => "policy-%{[retention_days]}"
    manage_template => false
  }
}
'

# Input (paste each line):
{"message": "test prod", "environment": "prod", "retention_days": "90"}
{"message": "test dev", "environment": "dev", "retention_days": "7"}
{"message": "test staging", "environment": "staging", "retention_days": "30"}
```

### Step 2: Verify Alias Creation

```bash
GET _cat/aliases/logs-*?v

# Expected output:
# alias       index              filter routing.index routing.search is_write_index
# logs-prod   logs-prod-000001   -      -             -              true
# logs-dev    logs-dev-000001    -      -             -              true
# logs-staging logs-staging-000001 -    -             -              true
```

### Step 3: Verify ILM Policy Association

```bash
GET logs-prod-000001/_settings

# Expected output should include:
{
  "logs-prod-000001": {
    "settings": {
      "index": {
        "lifecycle": {
          "name": "policy-90",
          "rollover_alias": "logs-prod"
        }
      }
    }
  }
}
```

### Step 4: Test Rollover

```bash
# Manually trigger rollover to test
POST logs-prod/_rollover

# Verify new index has ILM settings
GET logs-prod-000002/_settings

# Should still have:
# "index.lifecycle.name": "policy-90"
# "index.lifecycle.rollover_alias": "logs-prod"
```

---

## Troubleshooting

### Problem: "ILM policy 'policy-X' does not exist"

**Cause:** Event referenced a policy that hasn't been created.

**Solution:**
```bash
# Create the missing policy
PUT _ilm/policy/policy-X
{
  "policy": { ... }
}
```

### Problem: Rolled-over indices missing ILM settings

**Cause:** Index template not matching the alias pattern.

**Diagnosis:**
```bash
# Check which template matches your index pattern
GET _index_template/_simulate_index/logs-prod-000002

# If no match, create/update template
```

**Solution:**
```bash
# Ensure template pattern is broad enough
PUT _index_template/dynamic-logs-template
{
  "index_patterns": ["logs-*"],  # Must match ALL dynamic aliases
  ...
}
```

### Problem: "resource_already_exists_exception" flooding logs

**Cause:** Multiple Logstash instances starting simultaneously.

**Solution:** This is expected and handled automatically. To reduce log noise:

```ruby
# In logstash.yml
log.level: info  # Hide debug-level race condition messages
```

### Problem: Memory growth with high cardinality

**Symptom:** Logstash heap usage growing indefinitely.

**Cause:** Unbounded cache of alias:policy combinations.

**Monitoring:**
```bash
# Check Logstash JVM heap
GET /_node/stats/jvm?pretty

# In Logstash logs, look for:
# "Creating dynamic ILM rollover alias" messages
# Count unique combinations
```

**Mitigation strategies:**
1. **Reduce cardinality**: Use enums/fixed values instead of UUIDs
2. **Increase heap**: Adjust JVM settings in `jvm.options`
3. **Shard differently**: Use separate pipelines for high-cardinality sources

---

## Migration from Static to Dynamic ILM

### Scenario: Existing static ILM pipeline → Want to add dynamic routing

**Current configuration:**
```ruby
output {
  elasticsearch {
    ilm_enabled => true
    ilm_rollover_alias => "logs-static"
    ilm_policy => "logs-policy"
  }
}
```

**Migration steps:**

1. **Create new index templates** (see Step 4 above)

2. **Update configuration** with sprintf patterns:
```ruby
output {
  elasticsearch {
    ilm_enabled => true
    ilm_rollover_alias => "logs-%{[environment]}"
    ilm_policy => "policy-%{[retention_days]}"
    manage_template => false  # ADD THIS
  }
}
```

3. **Add fields to events** (in filter section):
```ruby
filter {
  mutate {
    add_field => {
      "environment" => "prod"  # Or from existing field
      "retention_days" => "90"
    }
  }
}
```

4. **Restart Logstash** with new configuration

5. **Verify** both old and new indices coexist:
```bash
GET _cat/aliases?v
# Should show:
# logs-static (old, still active)
# logs-prod (new, from dynamic config)
```

6. **Decommission old alias** after transition period

---

## Alternative: Use Data Streams (Recommended for ES 7.9+)

If you're on Elasticsearch 7.9+, **Data Streams** natively support dynamic routing without these complications:

```ruby
output {
  elasticsearch {
    data_stream => true
    data_stream_type => "logs"
    data_stream_dataset => "%{[service_name]}"  # Native sprintf support!
    data_stream_namespace => "%{[environment]}"
  }
}
```

**Advantages over dynamic ILM:**
- Automatic template management
- Built-in ILM integration
- No manual template setup required
- Simpler configuration

**See:** https://www.elastic.co/guide/en/elasticsearch/reference/current/data-streams.html

---

## Configuration Examples by Use Case

### Use Case 1: Multi-Tenant SaaS Application

```ruby
output {
  elasticsearch {
    hosts => ["localhost:9200"]
    ilm_enabled => true
    ilm_rollover_alias => "tenant-%{[customer_id]}-logs"
    ilm_policy => "policy-%{[subscription_tier]}"
    manage_template => false
  }
}
```

**Elasticsearch setup:**
```bash
# Create policies: policy-free, policy-pro, policy-enterprise
# Create template matching "tenant-*-logs-*"
PUT _index_template/tenant-logs
{
  "index_patterns": ["tenant-*-logs-*"],
  "priority": 500,
  "composed_of": ["dynamic-logs-settings"]
}
```

### Use Case 2: Microservices with Service-Specific Retention

```ruby
output {
  elasticsearch {
    hosts => ["localhost:9200"]
    ilm_enabled => true
    ilm_rollover_alias => "service-%{[service_name]}-logs"
    ilm_policy => "policy-30"  # Static policy, dynamic alias
    manage_template => false
  }
}
```

**Elasticsearch setup:**
```bash
PUT _index_template/microservices-logs
{
  "index_patterns": ["service-*-logs-*"],
  "priority": 500,
  "template": {
    "settings": {
      "index.lifecycle.name": "policy-30"
    }
  }
}
```

### Use Case 3: Environment-Based Routing with Geo-Replication

```ruby
output {
  elasticsearch {
    hosts => ["localhost:9200"]
    ilm_enabled => true
    ilm_rollover_alias => "logs-%{[environment]}-%{[region]}"
    ilm_policy => "policy-%{[environment]}"
    manage_template => false
  }
}
```

**Event example:**
```json
{
  "message": "API request",
  "environment": "prod",
  "region": "us-east",
  "@timestamp": "2025-11-24T10:00:00Z"
}
```

**Result:** Alias `logs-prod-us-east` with policy `policy-prod`

---

## Performance Considerations

### Cache Efficiency

**Memory usage:** ~100 bytes per unique alias:policy combination

**Example calculations:**
- 10 environments × 5 services = 50 combinations = **5KB**
- 100 tenants × 3 tiers = 300 combinations = **30KB**
- 1000 microservices = 1000 combinations = **100KB**

### Alias Creation Overhead

**First event per alias:**
- Pattern resolution: <1ms
- Elasticsearch API call: 50-200ms
- Lock contention: 1-10ms (multi-instance only)

**Subsequent events:**
- Cache lookup: <0.1ms
- No Elasticsearch calls

### Throughput Impact

**Steady-state:** <0.1% overhead compared to static ILM

**Startup/warmup:**
- High cardinality (100+ aliases): Initial 10-30 seconds of elevated latency
- Low cardinality (<10 aliases): No noticeable impact

---

## Security Best Practices

### Least Privilege Principle

Grant only the minimum required permissions:

```json
{
  "cluster": ["manage_ilm"],
  "indices": [
    {
      "names": ["logs-prod-*"],
      "privileges": ["create_index", "write"]
    },
    {
      "names": ["logs-dev-*"],
      "privileges": ["create_index", "write", "delete"]
    }
  ]
}
```

### Audit Logging

Enable Elasticsearch audit logging to track alias creations:

```yaml
# elasticsearch.yml
xpack.security.audit.enabled: true
xpack.security.audit.logfile.events.include: ["index_event"]
```

---

## Summary Checklist

Before deploying dynamic ILM to production:

- [ ] Created all required ILM policies in Elasticsearch
- [ ] Created wildcard index template matching all possible patterns
- [ ] Set `manage_template => false` in Logstash config
- [ ] Granted `manage_ilm` and `create_index` permissions
- [ ] Tested with sample events from all expected field values
- [ ] Verified rolled-over indices retain ILM settings
- [ ] Configured monitoring for heap usage and alias creation failures
- [ ] Documented expected cardinality and memory requirements
- [ ] Set up alerts for missing policy errors
- [ ] Validated multi-instance behavior (if applicable)

---

**Document Version:** 1.0  
**Last Updated:** November 24, 2025  
**Plugin Version:** Compatible with logstash-output-elasticsearch 11.x+
