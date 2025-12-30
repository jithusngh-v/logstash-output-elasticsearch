# Custom Template Quick Reference

## 🚀 TL;DR - 5 Minute Setup

### 1. Create Template JSON

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
        "container_name": { "type": "keyword" },
        "log": { "type": "text" }
      }
    }
  }
}
```

### 2. Add to ConfigMap

```yaml
data:
  index-template.json: |-
    { ... your template JSON ... }
```

### 3. Set Environment Variable

```yaml
env:
- name: ILM_TEMPLATE_PATH
  value: "/usr/share/logstash/config/index-template.json"
```

### 4. Mount ConfigMap

```yaml
volumeMounts:
- name: templates
  mountPath: /usr/share/logstash/config/index-template.json
  subPath: index-template.json
```

**Done!** ✅

---

## 📋 Environment Variables

| Variable | Purpose | Example |
|----------|---------|---------|
| `ILM_TEMPLATE_PATH` | Custom template path | `/config/template.json` |
| `LOGSTASH_ILM_TEMPLATE_PATH` | Alternative path | `/etc/logstash/template.json` |

---

## 🔍 Verify It's Working

### Check Logstash Logs
```bash
kubectl logs deployment/logstash -n elastic | grep template

# ✅ Success:
# [INFO] Loading custom ILM template from environment variable
# [INFO] Successfully loaded custom ILM template
# [INFO] Creating dynamic index template

# ❌ Failure:
# [ERROR] Failed to load custom ILM template
# [ERROR] using built-in defaults
```

### Check Elasticsearch
```bash
# List templates
curl -X GET "localhost:9200/_index_template/logstash-*?pretty"

# Check specific index settings
curl -X GET "localhost:9200/dotcms-000001/_settings?pretty"
```

---

## 🎯 Your Specific Use Case

### Current ConfigMap Structure

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: logstash-templates
  namespace: elastic
data:
  # ✅ You already have this
  ilm-policy.json: |-
    {
      "policy": {
        "phases": {
          "hot": {
            "min_age": "0ms",
            "actions": {
              "rollover": { "max_age": "1d" }
            }
          },
          "delete": {
            "min_age": "1d",
            "actions": {
              "delete": {}
            }
          }
        }
      }
    }
  
  # ✅ ADD THIS (recommended for your workload)
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
          "properties": {
            "@timestamp": { "type": "date" },
            "@version": { "type": "keyword" },
            "container_name": { "type": "keyword" },
            "log_level": { "type": "keyword" },
            "component": { "type": "keyword" },
            "log": { "type": "text" },
            "log_message": { "type": "text" },
            "json": {
              "type": "object",
              "dynamic": true
            }
          }
        }
      }
    }
  
  # ✅ You already have this
  logstash.conf: |-
    input { kafka { ... } }
    filter { ... }
    output {
      elasticsearch {
        ilm_enabled => true
        ilm_rollover_alias => "%{[container_name]}"
        ilm_policy => "%{[container_name]}-ilm-policy"
        ilm_auto_create_policy => true
        ilm_auto_create_template => true
      }
    }
```

### Update Deployment

```yaml
spec:
  template:
    spec:
      containers:
      - name: logstash
        env:
        # ✅ You already have this
        - name: ILM_POLICY_PATH
          value: "/usr/share/logstash/config/ilm-policy.json"
        
        # ✅ ADD THIS
        - name: ILM_TEMPLATE_PATH
          value: "/usr/share/logstash/config/index-template.json"
        
        volumeMounts:
        # ✅ You already have this
        - name: config
          mountPath: /usr/share/logstash/config/ilm-policy.json
          subPath: ilm-policy.json
        
        # ✅ ADD THIS
        - name: config
          mountPath: /usr/share/logstash/config/index-template.json
          subPath: index-template.json
```

---

## ⚡ Quick Commands

### Deploy Changes
```bash
# Apply ConfigMap
kubectl apply -f logstash-configmap.yaml -n elastic

# Restart Logstash
kubectl rollout restart deployment/logstash -n elastic

# Watch restart
kubectl rollout status deployment/logstash -n elastic
```

### Check Status
```bash
# Logs
kubectl logs -f deployment/logstash -n elastic | grep -i template

# Elasticsearch templates
kubectl exec -it deployment/logstash -n elastic -- \
  curl -X GET "eck-es-hot:9200/_index_template/logstash-*?pretty"
```

---

## 🔧 Troubleshooting

### Template Not Loading

**Check environment variable:**
```bash
kubectl exec deployment/logstash -n elastic -- env | grep TEMPLATE
```

**Check file exists:**
```bash
kubectl exec deployment/logstash -n elastic -- \
  cat /usr/share/logstash/config/index-template.json
```

**Validate JSON:**
```bash
kubectl exec deployment/logstash -n elastic -- \
  cat /usr/share/logstash/config/index-template.json | jq .
```

### Template Not Applied

**Check template exists in ES:**
```bash
kubectl exec deployment/logstash -n elastic -- \
  curl -X GET "eck-es-hot:9200/_index_template?pretty"
```

**Check index settings:**
```bash
kubectl exec deployment/logstash -n elastic -- \
  curl -X GET "eck-es-hot:9200/your-index-*/_settings?pretty"
```

---

## 📚 Full Documentation

- **Complete Guide:** `CUSTOM_TEMPLATE_GUIDE.md`
- **Template Examples:** `CUSTOM_TEMPLATE_EXAMPLES.md`
- **Deployment Guide:** `KUBERNETES_DEPLOYMENT_GUIDE.md`

---

**Created:** December 30, 2025  
**Type:** Quick Reference  
**Feature:** Custom ILM Template via Environment Variables
