# Custom Template Examples

## 📚 Ready-to-Use Template Examples

Copy these templates directly to your ConfigMap!

---

## 1️⃣ Basic Template (Minimal Configuration)

**Use case:** Simple logging with default settings

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
        "@version": { "type": "keyword" },
        "message": { "type": "text" }
      }
    }
  }
}
```

---

## 2️⃣ High-Performance Template (Your Current Use Case)

**Use case:** High-throughput Kafka logging with fast deletion

```json
{
  "priority": 350,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 1,
        "number_of_replicas": 0,
        "refresh_interval": "10s",
        "codec": "best_compression",
        "translog": {
          "durability": "async",
          "sync_interval": "15s",
          "flush_threshold_size": "512mb"
        },
        "max_result_window": 50000,
        "routing": {
          "allocation": {
            "include": {
              "_tier_preference": "data_hot,data_content"
            }
          }
        }
      }
    },
    "mappings": {
      "dynamic_templates": [
        {
          "message_field": {
            "path_match": "message",
            "match_mapping_type": "string",
            "mapping": {
              "type": "text",
              "norms": false,
              "index_options": "freqs"
            }
          }
        },
        {
          "string_fields": {
            "match": "*",
            "match_mapping_type": "string",
            "mapping": {
              "type": "text",
              "norms": false,
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
        "component": { "type": "keyword" },
        "log": {
          "type": "text",
          "norms": false
        },
        "json": {
          "type": "object",
          "dynamic": true
        },
        "kubernetes": {
          "properties": {
            "pod_name": { "type": "keyword" },
            "namespace": { "type": "keyword" },
            "container_name": { "type": "keyword" },
            "labels": {
              "type": "object",
              "dynamic": true
            }
          }
        }
      }
    }
  }
}
```

---

## 3️⃣ Storage-Optimized Template (Cost Reduction)

**Use case:** Long-term storage with maximum compression

```json
{
  "priority": 300,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 1,
        "number_of_replicas": 1,
        "refresh_interval": "30s",
        "codec": "best_compression",
        "store": {
          "type": "hybridfs"
        },
        "merge": {
          "policy": {
            "max_merged_segment": "5gb",
            "segments_per_tier": 10
          }
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

## 4️⃣ Search-Optimized Template (Fast Queries)

**Use case:** Real-time log analysis and searching

```json
{
  "priority": 400,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 2,
        "number_of_replicas": 1,
        "refresh_interval": "1s",
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
              "ignore_above": 1024
            }
          }
        }
      ],
      "properties": {
        "@timestamp": { 
          "type": "date",
          "format": "strict_date_optional_time||epoch_millis"
        },
        "log_level": { 
          "type": "keyword",
          "normalizer": "lowercase"
        },
        "service": { "type": "keyword" },
        "trace_id": { "type": "keyword" },
        "span_id": { "type": "keyword" },
        "user_id": { "type": "keyword" },
        "duration_ms": { "type": "long" },
        "status_code": { "type": "short" }
      }
    }
  }
}
```

---

## 5️⃣ dotCMS-Specific Template

**Use case:** Optimized for dotCMS container logs

```json
{
  "priority": 350,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 1,
        "number_of_replicas": 0,
        "refresh_interval": "10s",
        "codec": "best_compression"
      }
    },
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date" },
        "@version": { "type": "keyword" },
        "container_name": { 
          "type": "keyword",
          "ignore_above": 64
        },
        "time": { 
          "type": "keyword",
          "ignore_above": 32
        },
        "log_level": { 
          "type": "keyword",
          "normalizer": "lowercase"
        },
        "component": { 
          "type": "keyword",
          "ignore_above": 256
        },
        "log_message": { 
          "type": "text",
          "norms": false,
          "fields": {
            "keyword": {
              "type": "keyword",
              "ignore_above": 512
            }
          }
        },
        "full_timestamp": { "type": "date" },
        "json": {
          "properties": {
            "Service": { "type": "keyword" }
          }
        },
        "tags": { "type": "keyword" }
      }
    }
  }
}
```

---

## 6️⃣ Multi-Service Template (General Purpose)

**Use case:** Works for all your containers

```json
{
  "priority": 320,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 1,
        "number_of_replicas": 0,
        "refresh_interval": "5s",
        "codec": "best_compression"
      }
    },
    "mappings": {
      "dynamic_templates": [
        {
          "strings_as_text_with_keyword": {
            "match_mapping_type": "string",
            "match": "*",
            "unmatch": "*_id",
            "mapping": {
              "type": "text",
              "norms": false,
              "fields": {
                "keyword": {
                  "type": "keyword",
                  "ignore_above": 256
                }
              }
            }
          }
        },
        {
          "id_fields_as_keywords": {
            "match_mapping_type": "string",
            "match": "*_id",
            "mapping": {
              "type": "keyword",
              "ignore_above": 64
            }
          }
        },
        {
          "timestamp_fields_as_date": {
            "match_mapping_type": "string",
            "match_pattern": "regex",
            "match": ".*timestamp.*|.*_at$|.*_time$",
            "mapping": {
              "type": "date",
              "ignore_malformed": true
            }
          }
        }
      ],
      "properties": {
        "@timestamp": { "type": "date" },
        "@version": { "type": "keyword" },
        "container_name": { "type": "keyword" },
        "log_level": { "type": "keyword" },
        "kubernetes": {
          "properties": {
            "pod_name": { "type": "keyword" },
            "namespace": { "type": "keyword" },
            "container_name": { "type": "keyword" },
            "pod_ip": { "type": "ip" },
            "host": { "type": "keyword" }
          }
        },
        "json": {
          "type": "object",
          "dynamic": true
        }
      }
    }
  }
}
```

---

## 7️⃣ Debug Template (Troubleshooting)

**Use case:** Maximum visibility for debugging

```json
{
  "priority": 100,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 1,
        "number_of_replicas": 0,
        "refresh_interval": "1s"
      }
    },
    "mappings": {
      "dynamic": true,
      "_source": {
        "enabled": true
      },
      "properties": {
        "@timestamp": { "type": "date" },
        "raw_log": { 
          "type": "text",
          "index": true,
          "store": true
        }
      }
    }
  }
}
```

---

## 🎯 Kubernetes ConfigMap: Complete Example

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: logstash-templates
  namespace: elastic
data:
  # ILM Policy (your current config)
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
  
  # Custom Template (CHOOSE ONE FROM ABOVE)
  index-template.json: |-
    {
      "priority": 350,
      "template": {
        "settings": {
          "index": {
            "number_of_shards": 1,
            "number_of_replicas": 0,
            "refresh_interval": "10s",
            "codec": "best_compression",
            "translog": {
              "durability": "async",
              "sync_interval": "15s"
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
                  "norms": false,
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
            "json": {
              "type": "object",
              "dynamic": true
            }
          }
        }
      }
    }
  
  # Logstash Pipeline
  logstash.conf: |-
    input {
      kafka {
        bootstrap_servers => "10.50.0.199:9092"
        topics => ["develk"]
        group_id => "logstash"
        enable_auto_commit => false
        consumer_threads => 8
        max_poll_records => 10000
        # ... rest of your config
      }
    }
    
    filter {
      # ... your filters
    }
    
    output {
      elasticsearch {
        hosts => ["eck-es-hot:9200"]
        user => "${ES_USER}"
        password => "${ES_PASSWORD}"
        ecs_compatibility => "disabled"
        ssl_enabled => false
        ilm_enabled => true
        ilm_rollover_alias => "%{[container_name]}"
        ilm_pattern => "000001"
        ilm_policy => "%{[container_name]}-ilm-policy"
        ilm_auto_create_policy => true
        ilm_policy_fallback => "common-ilm-policy"
        ilm_auto_create_template => true
      }
    }
```

---

## 🚀 Quick Deployment

### Apply ConfigMap
```bash
kubectl apply -f logstash-configmap.yaml -n elastic
```

### Update Deployment to Mount Template
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
        env:
        - name: ILM_POLICY_PATH
          value: "/usr/share/logstash/config/ilm-policy.json"
        - name: ILM_TEMPLATE_PATH
          value: "/usr/share/logstash/config/index-template.json"
        
        volumeMounts:
        - name: templates
          mountPath: /usr/share/logstash/config/ilm-policy.json
          subPath: ilm-policy.json
        - name: templates
          mountPath: /usr/share/logstash/config/index-template.json
          subPath: index-template.json
        - name: pipeline
          mountPath: /usr/share/logstash/pipeline/logstash.conf
          subPath: logstash.conf
      
      volumes:
      - name: templates
        configMap:
          name: logstash-templates
      - name: pipeline
        configMap:
          name: logstash-templates
```

### Restart Logstash
```bash
kubectl rollout restart deployment/logstash -n elastic
```

### Verify
```bash
# Check logs
kubectl logs -f deployment/logstash -n elastic | grep -i template

# Should see:
# [INFO] Loading custom ILM template from environment variable
# [INFO] Successfully loaded custom ILM template
```

---

## 📊 Choosing the Right Template

| Priority | Template | Use Case | Shards | Replicas | Compression |
|----------|----------|----------|--------|----------|-------------|
| **High** | #2 High-Performance | Your current use case | 1 | 0 | ✅ Best |
| Medium | #6 Multi-Service | General logging | 1 | 0 | ✅ Best |
| Medium | #4 Search-Optimized | Real-time analysis | 2 | 1 | ❌ None |
| Low | #3 Storage-Optimized | Long-term storage | 1 | 1 | ✅ Best |
| Debug | #7 Debug | Troubleshooting | 1 | 0 | ❌ None |

### Recommendations

**Your Environment:**
- Kafka input with 10,000 events/batch
- Multiple containers (dotcms, services, etc.)
- 1-day deletion policy
- Need fast writes

**Best Template:** #2 High-Performance Template
- Optimized for high throughput
- Async translog for speed
- Best compression for storage
- No replicas (matches your ILM policy)

---

**Created:** December 30, 2025  
**Purpose:** Ready-to-use template examples for custom ILM templates
