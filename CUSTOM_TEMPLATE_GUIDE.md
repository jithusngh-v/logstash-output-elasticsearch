# Custom ILM Template Configuration Guide

## 🎯 Overview

You can now provide **custom index templates** via environment variables, just like custom ILM policies. This allows you to customize:
- Index settings (shards, replicas, refresh interval, etc.)
- Field mappings and data types
- Dynamic templates for field mapping patterns
- Template priority

---

## 🚀 Quick Start

### Environment Variables

| Variable | Description | Priority |
|----------|-------------|----------|
| `ILM_TEMPLATE_PATH` | Path to custom template JSON file | High |
| `LOGSTASH_ILM_TEMPLATE_PATH` | Alternative path (checked if first not set) | Medium |
| *(none)* | Use built-in defaults | Low |

### How It Works

```
1. Check ILM_TEMPLATE_PATH
   ↓ Not set?
2. Check LOGSTASH_ILM_TEMPLATE_PATH
   ↓ Not set?
3. Use built-in default template
```

---

## 📝 Template JSON Format

### Minimal Template Structure

```json
{
  "priority": 300,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 1,
        "number_of_replicas": 0,
        "refresh_interval": "5s"
      }
    },
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date" },
        "message": { "type": "text" }
      }
    }
  }
}
```

### Full Template Structure

```json
{
  "priority": 300,
  "template": {
    "settings": {
      "index": {
        "lifecycle": {
          "name": "will-be-overridden-dynamically",
          "rollover_alias": "will-be-overridden-dynamically"
        },
        "number_of_shards": 2,
        "number_of_replicas": 1,
        "refresh_interval": "10s",
        "codec": "best_compression",
        "max_result_window": 100000,
        "routing": {
          "allocation": {
            "include": {
              "_tier_preference": "data_hot"
            }
          }
        }
      }
    },
    "mappings": {
      "dynamic_templates": [
        {
          "strings_as_keywords": {
            "match_mapping_type": "string",
            "mapping": {
              "type": "keyword",
              "ignore_above": 512
            }
          }
        }
      ],
      "properties": {
        "@timestamp": { "type": "date" },
        "@version": { "type": "keyword" },
        "container_name": { "type": "keyword" },
        "log": { 
          "type": "text",
          "fields": {
            "keyword": {
              "type": "keyword",
              "ignore_above": 256
            }
          }
        },
        "log_level": { "type": "keyword" },
        "component": { "type": "keyword" },
        "json": {
          "type": "object",
          "dynamic": true
        },
        "kubernetes": {
          "properties": {
            "pod_name": { "type": "keyword" },
            "namespace": { "type": "keyword" },
            "container_name": { "type": "keyword" }
          }
        }
      }
    }
  }
}
```

---

## 🔧 Kubernetes ConfigMap Setup

### Step 1: Create ConfigMap with Custom Template

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: logstash-templates
  namespace: elastic
data:
  # Your custom ILM policy (existing)
  ilm-policy.json: |-
    {
      "policy": {
        "phases": {
          "hot": {
            "min_age": "0ms",
            "actions": {
              "rollover": {
                "max_age": "1d"
              },
              "set_priority": {
                "priority": 100
              }
            }
          },
          "delete": {
            "min_age": "1d",
            "actions": {
              "delete": {
                "delete_searchable_snapshot": true
              }
            }
          }
        }
      }
    }
  
  # NEW: Your custom template
  index-template.json: |-
    {
      "priority": 350,
      "template": {
        "settings": {
          "index": {
            "number_of_shards": 2,
            "number_of_replicas": 1,
            "refresh_interval": "10s",
            "codec": "best_compression",
            "routing": {
              "allocation": {
                "include": {
                  "_tier_preference": "data_hot,data_warm,data_content"
                }
              }
            }
          }
        },
        "mappings": {
          "dynamic_templates": [
            {
              "strings_as_text_with_keyword": {
                "match_mapping_type": "string",
                "mapping": {
                  "type": "text",
                  "fields": {
                    "keyword": {
                      "type": "keyword",
                      "ignore_above": 512
                    }
                  }
                }
              }
            }
          ],
          "properties": {
            "@timestamp": { "type": "date" },
            "@version": { "type": "keyword" },
            "container_name": { "type": "keyword" },
            "log_level": { "type": "keyword" },
            "log": { "type": "text" },
            "component": { "type": "keyword" },
            "json": {
              "type": "object",
              "dynamic": true
            }
          }
        }
      }
    }
```

### Step 2: Mount ConfigMap in Logstash Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: logstash
  namespace: elastic
spec:
  template:
    spec:
      containers:
      - name: logstash
        image: docker.elastic.co/logstash/logstash:8.11.0
        env:
        # Existing ILM policy path
        - name: ILM_POLICY_PATH
          value: "/usr/share/logstash/config/ilm-policy.json"
        
        # NEW: Template path
        - name: ILM_TEMPLATE_PATH
          value: "/usr/share/logstash/config/index-template.json"
        
        # Elasticsearch credentials
        - name: ES_USER
          valueFrom:
            secretKeyRef:
              name: elastic-secret
              key: username
        - name: ES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: elastic-secret
              key: password
        
        volumeMounts:
        - name: config
          mountPath: /usr/share/logstash/config/ilm-policy.json
          subPath: ilm-policy.json
        - name: config
          mountPath: /usr/share/logstash/config/index-template.json
          subPath: index-template.json
        - name: pipeline
          mountPath: /usr/share/logstash/pipeline/logstash.conf
          subPath: logstash.conf
      
      volumes:
      - name: config
        configMap:
          name: logstash-templates
      - name: pipeline
        configMap:
          name: logstash-pipeline
```

### Step 3: Logstash Configuration

```ruby
output {
  elasticsearch {
    hosts => ["eck-es-hot:9200"]
    user => "${ES_USER}"
    password => "${ES_PASSWORD}"
    ecs_compatibility => "disabled"
    ssl_enabled => false
    
    # Dynamic ILM (no changes needed!)
    ilm_enabled => true
    ilm_rollover_alias => "%{[container_name]}"
    ilm_pattern => "000001"
    ilm_policy => "%{[container_name]}-ilm-policy"
    ilm_auto_create_policy => true
    ilm_policy_fallback => "common-ilm-policy"
    ilm_auto_create_template => true
    
    # Custom template will be loaded from ILM_TEMPLATE_PATH automatically!
  }
}
```

---

## 📋 Template Examples

### Example 1: Performance-Optimized Template

**Use case:** High-throughput logging with compression

```json
{
  "priority": 400,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 3,
        "number_of_replicas": 0,
        "refresh_interval": "30s",
        "codec": "best_compression",
        "translog": {
          "durability": "async",
          "sync_interval": "30s"
        }
      }
    },
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date" },
        "message": { "type": "text", "index": false }
      }
    }
  }
}
```

### Example 2: Search-Optimized Template

**Use case:** Fast queries with keyword fields

```json
{
  "priority": 350,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 1,
        "number_of_replicas": 1,
        "refresh_interval": "1s"
      }
    },
    "mappings": {
      "dynamic_templates": [
        {
          "strings_as_keywords": {
            "match_mapping_type": "string",
            "mapping": {
              "type": "keyword",
              "ignore_above": 1024
            }
          }
        }
      ],
      "properties": {
        "@timestamp": { "type": "date" },
        "log_level": { "type": "keyword" },
        "service": { "type": "keyword" }
      }
    }
  }
}
```

### Example 3: Minimal Storage Template

**Use case:** Reduce storage costs

```json
{
  "priority": 300,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 1,
        "number_of_replicas": 0,
        "codec": "best_compression",
        "store": {
          "type": "hybridfs"
        }
      }
    },
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date" },
        "message": { 
          "type": "text",
          "norms": false,
          "index_options": "freqs"
        }
      }
    }
  }
}
```

---

## 🔍 How Template Loading Works

### Priority Order

```
1. ILM_TEMPLATE_PATH environment variable
   ↓ File exists and valid JSON?
   ✅ Use custom template
   
2. LOGSTASH_ILM_TEMPLATE_PATH environment variable
   ↓ File exists and valid JSON?
   ✅ Use custom template
   
3. Built-in defaults
   ✅ Always available as fallback
```

### Template Merging

The plugin uses a **smart merging strategy**:

1. **Load base template** from environment or use defaults
2. **Override ILM settings** (lifecycle.name, lifecycle.rollover_alias) with dynamic values
3. **Merge with config settings** (ilm_template_settings, ilm_template_mappings)
4. **Generate index_patterns** dynamically based on resolved alias

### What Gets Overridden?

| Field | Source | Override? |
|-------|--------|-----------|
| `index_patterns` | Generated dynamically | ✅ Always |
| `settings.index.lifecycle.name` | Generated from event | ✅ Always |
| `settings.index.lifecycle.rollover_alias` | Generated from event | ✅ Always |
| `settings.index.*` (other) | Custom template or defaults | ❌ No |
| `mappings` | Custom template or defaults | ❌ No |
| `priority` | Custom template or default (300) | ❌ No |

---

## 🧪 Testing Your Custom Template

### Step 1: Create Test Template File

```bash
cat > /tmp/test-template.json << 'EOF'
{
  "priority": 350,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 2,
        "number_of_replicas": 1,
        "refresh_interval": "10s"
      }
    },
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date" },
        "test_field": { "type": "keyword" }
      }
    }
  }
}
EOF
```

### Step 2: Export Environment Variable

```bash
export ILM_TEMPLATE_PATH=/tmp/test-template.json
```

### Step 3: Start Logstash

```bash
/usr/share/logstash/bin/logstash -f /etc/logstash/conf.d/logstash.conf
```

### Step 4: Check Logs

Look for:
```
[INFO] Loading custom ILM template from environment variable
[INFO] Successfully loaded custom ILM template
```

### Step 5: Verify Template in Elasticsearch

```bash
# Check created template
curl -X GET "localhost:9200/_index_template/logstash-*?pretty"

# Verify settings
curl -X GET "localhost:9200/your-alias-*/_settings?pretty"

# Verify mappings
curl -X GET "localhost:9200/your-alias-*/_mapping?pretty"
```

---

## 🚨 Troubleshooting

### Template Not Loading

**Problem:** Logstash uses built-in defaults instead of custom template

**Checklist:**
1. ✅ Environment variable set correctly?
   ```bash
   echo $ILM_TEMPLATE_PATH
   ```

2. ✅ File exists and readable?
   ```bash
   ls -la $ILM_TEMPLATE_PATH
   cat $ILM_TEMPLATE_PATH
   ```

3. ✅ Valid JSON format?
   ```bash
   jq . $ILM_TEMPLATE_PATH
   ```

4. ✅ Check Logstash logs for errors
   ```bash
   kubectl logs -f logstash-pod-name -n elastic
   ```

### Invalid Template JSON

**Error:**
```
Failed to load custom ILM template from environment variable
```

**Solution:**
```bash
# Validate JSON syntax
jq . /path/to/template.json

# Check for common issues:
# - Missing quotes
# - Trailing commas
# - Invalid escape characters
```

### Template Not Applied to Indices

**Problem:** Indices created without custom settings

**Possible causes:**

1. **Template priority too low**
   - Increase `priority` in template (300-400 range)

2. **Index pattern doesn't match**
   - Check logs: `index_patterns => ["your-alias-*"]`
   - Verify alias name matches pattern

3. **Template created after index**
   - Delete test index and recreate
   ```bash
   DELETE /test-index
   ```

---

## 💡 Best Practices

### 1. Use Version Control

```bash
# Store templates in Git
git add templates/index-template.json
git commit -m "Add custom Elasticsearch template"
```

### 2. Test in Development First

```yaml
# dev-values.yaml
configMaps:
  - name: logstash-templates-dev
    data:
      index-template.json: |
        { "priority": 300, ... }
```

### 3. Document Template Changes

```json
{
  "priority": 350,
  "_meta": {
    "description": "Custom template for production logs",
    "author": "DevOps Team",
    "version": "2.0",
    "last_modified": "2025-12-30"
  },
  "template": { ... }
}
```

### 4. Monitor Template Usage

```bash
# Check which indices use your template
GET /_cat/indices?v&h=index,pri,rep,store.size

# Verify settings per index
GET /your-index-000001/_settings
```

### 5. Keep Templates Simple

- Start with minimal settings
- Add complexity incrementally
- Test each change
- Document why each setting is needed

---

## 📚 Environment Variable Reference

### Complete List

| Variable | Purpose | Example |
|----------|---------|---------|
| `ILM_POLICY_PATH` | Custom ILM policy JSON | `/config/ilm-policy.json` |
| `LOGSTASH_ILM_POLICY_PATH` | Alternative policy path | `/etc/logstash/policy.json` |
| `ILM_TEMPLATE_PATH` | Custom template JSON | `/config/index-template.json` |
| `LOGSTASH_ILM_TEMPLATE_PATH` | Alternative template path | `/etc/logstash/template.json` |

### Priority Order

1. `ILM_POLICY_PATH` / `ILM_TEMPLATE_PATH` (highest)
2. `LOGSTASH_ILM_POLICY_PATH` / `LOGSTASH_ILM_TEMPLATE_PATH`
3. Built-in defaults (fallback)

---

## 🎓 Advanced Usage

### Dynamic Settings per Container

You can still use config-based overrides:

```ruby
output {
  elasticsearch {
    ilm_template_settings => {
      "index" => {
        "number_of_shards" => 2  # Overrides template
      }
    }
  }
}
```

**Merge order:**
1. Load base template from env (or defaults)
2. Override ILM lifecycle settings
3. Merge with `ilm_template_settings` config

### Multiple Templates

Use different templates per environment:

```yaml
# Production
env:
- name: ILM_TEMPLATE_PATH
  value: "/config/prod-template.json"

# Staging
env:
- name: ILM_TEMPLATE_PATH
  value: "/config/staging-template.json"
```

---

## ✅ Checklist: Custom Template Setup

- [ ] Create template JSON file
- [ ] Validate JSON syntax with `jq`
- [ ] Add to ConfigMap
- [ ] Mount ConfigMap in deployment
- [ ] Set environment variable (`ILM_TEMPLATE_PATH`)
- [ ] Deploy Logstash
- [ ] Check logs for successful load
- [ ] Verify template in Elasticsearch
- [ ] Test with sample data
- [ ] Monitor index settings

---

## 🔗 Related Documentation

- `CUSTOM_TEMPLATE_EXAMPLES.md` - More template examples
- `FINAL_IMPLEMENTATION_SUMMARY.md` - Overall ILM feature documentation
- `KUBERNETES_DEPLOYMENT_GUIDE.md` - Full K8s deployment guide

---

**Created:** December 30, 2025  
**Version:** 1.0  
**Feature:** Custom ILM Template Support via Environment Variables
