# Kubernetes Deployment Guide with ILM Policy ConfigMap

## Overview

This guide shows how to deploy Logstash with custom ILM policies using Kubernetes ConfigMaps, allowing you to use the same Docker image across all environments.

## Architecture

```
┌─────────────────────────────────────────┐
│  Kubernetes Pod                         │
│  ┌───────────────────────────────────┐  │
│  │ Logstash Container                │  │
│  │ ENV: ILM_POLICY_PATH=             │  │
│  │      /usr/share/logstash/config/  │  │
│  │      ilm-policy.json              │  │
│  │                                   │  │
│  │ /usr/share/logstash/config/      │  │
│  │   └── ilm-policy.json ◄───────┐  │  │
│  └───────────────────────────────│───┘  │
│                                  │      │
│  ┌───────────────────────────────┼───┐  │
│  │ Volume Mount                  │   │  │
│  │ (ConfigMap: logstash-ilm-policy) │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

## Prerequisites

1. **Build and push your Docker image** with the updated plugin
2. **Create the common fallback policy** in Elasticsearch (one-time setup)

### Create Common Fallback Policy (One-Time)

```bash
# Create the common-ilm-policy in Elasticsearch
kubectl exec -it eck-es-es-default-0 -n elastic-search -- curl -X PUT \
  "http://localhost:9200/_ilm/policy/common-ilm-policy?pretty" \
  -H 'Content-Type: application/json' \
  -d '{
    "policy": {
      "phases": {
        "hot": {
          "min_age": "0ms",
          "actions": {
            "rollover": {"max_age": "1d"},
            "set_priority": {"priority": 100}
          }
        },
        "delete": {
          "min_age": "1d",
          "actions": {"delete": {}}
        }
      }
    }
  }'
```

## Deployment Steps

### Step 1: Create ConfigMaps

#### Development Environment

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: logstash-ilm-policy
  namespace: elastic-search
  labels:
    environment: development
data:
  ilm-policy.json: |
    {
      "policy": {
        "phases": {
          "hot": {
            "min_age": "0ms",
            "actions": {
              "rollover": {"max_age": "1d"},
              "set_priority": {"priority": 100}
            }
          },
          "delete": {
            "min_age": "1d",
            "actions": {
              "delete": {"delete_searchable_snapshot": true}
            }
          }
        }
      }
    }
EOF
```

#### Staging Environment

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: logstash-ilm-policy
  namespace: elastic-search
  labels:
    environment: staging
data:
  ilm-policy.json: |
    {
      "policy": {
        "phases": {
          "hot": {
            "min_age": "0ms",
            "actions": {
              "rollover": {"max_age": "3d"},
              "set_priority": {"priority": 100}
            }
          },
          "delete": {
            "min_age": "7d",
            "actions": {
              "delete": {"delete_searchable_snapshot": true}
            }
          }
        }
      }
    }
EOF
```

#### Production Environment

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: logstash-ilm-policy
  namespace: elastic-search
  labels:
    environment: production
data:
  ilm-policy.json: |
    {
      "policy": {
        "phases": {
          "hot": {
            "min_age": "0ms",
            "actions": {
              "rollover": {
                "max_age": "7d",
                "max_size": "50gb"
              },
              "set_priority": {"priority": 100}
            }
          },
          "warm": {
            "min_age": "7d",
            "actions": {
              "set_priority": {"priority": 50},
              "shrink": {"number_of_shards": 1}
            }
          },
          "delete": {
            "min_age": "30d",
            "actions": {
              "delete": {"delete_searchable_snapshot": true}
            }
          }
        }
      }
    }
EOF
```

### Step 2: Update Your Logstash Pipeline ConfigMap

Ensure your pipeline configuration includes the dynamic ILM settings:

```bash
kubectl create configmap logstash-pipeline-test \
  --from-file=logstash.conf \
  --namespace=elastic-search \
  --dry-run=client -o yaml | kubectl apply -f -
```

**logstash.conf content:**

```ruby
input {
  kafka {
    bootstrap_servers => "kafka-broker:9092"
    topics => ["your-topic"]
    codec => json
    decorate_events => "basic"
    # ... other kafka settings
  }
}

filter {
  # Your filters here
  # Ensure container_name field is set
}

output {
  elasticsearch {
    hosts => ["eck-es-http:9200"]
    user => "${ES_USER}"
    password => "${ES_PASSWORD}"
    ecs_compatibility => "disabled"
    ssl_enabled => false
    
    # Dynamic ILM Configuration
    ilm_enabled => true
    ilm_rollover_alias => "%{[container_name]}"
    ilm_pattern => "000001"
    ilm_policy => "%{[container_name]}-ilm-policy"
    
    # Auto-create with safety net
    ilm_auto_create_policy => true
    ilm_policy_fallback => "common-ilm-policy"
    ilm_auto_create_template => true
    
    # Optional: Custom template settings
    ilm_template_settings => {
      "index" => {
        "number_of_shards" => 1
        "number_of_replicas" => 0
      }
    }
  }
}
```

### Step 3: Deploy the StatefulSet

```bash
kubectl apply -f kubernetes-deployment-example.yaml
```

Or use kubectl patch for existing StatefulSet:

```bash
# Add environment variable
kubectl patch statefulset logstash-logstash-test -n elastic-search --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "ILM_POLICY_PATH",
      "value": "/usr/share/logstash/config/ilm-policy.json"
    }
  }
]'

# Add volume mount
kubectl patch statefulset logstash-logstash-test -n elastic-search --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "mountPath": "/usr/share/logstash/config/ilm-policy.json",
      "name": "ilm-policy",
      "subPath": "ilm-policy.json",
      "readOnly": true
    }
  }
]'

# Add volume
kubectl patch statefulset logstash-logstash-test -n elastic-search --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "ilm-policy",
      "configMap": {
        "defaultMode": 420,
        "name": "logstash-ilm-policy"
      }
    }
  }
]'
```

## Verification

### 1. Check Pod is Running

```bash
kubectl get pods -n elastic-search -l app=logstash-logstash
```

### 2. Verify Environment Variable

```bash
kubectl exec -it logstash-logstash-test-0 -n elastic-search -- env | grep ILM_POLICY_PATH
# Should output: ILM_POLICY_PATH=/usr/share/logstash/config/ilm-policy.json
```

### 3. Verify File is Mounted

```bash
kubectl exec -it logstash-logstash-test-0 -n elastic-search -- cat /usr/share/logstash/config/ilm-policy.json
# Should show your policy JSON
```

### 4. Check Logstash Logs

```bash
kubectl logs -f logstash-logstash-test-0 -n elastic-search -c logstash | grep -i "ilm policy"
```

You should see:
```
[INFO] Loading custom ILM policy from environment variable {:path=>"/usr/share/logstash/config/ilm-policy.json", :env_var=>"ILM_POLICY_PATH"}
[INFO] Successfully loaded custom ILM policy {:path=>"/usr/share/logstash/config/ilm-policy.json"}
```

### 5. Verify in Elasticsearch

Once events are flowing:

```bash
# Check ILM policies created
kubectl exec -it eck-es-es-default-0 -n elastic-search -- \
  curl -s "http://localhost:9200/_ilm/policy/*ilm-policy?pretty"

# Check indices and aliases
kubectl exec -it eck-es-es-default-0 -n elastic-search -- \
  curl -s "http://localhost:9200/_cat/aliases?v"

# Check index templates
kubectl exec -it eck-es-es-default-0 -n elastic-search -- \
  curl -s "http://localhost:9200/_index_template/logstash-*?pretty"
```

## Updating the Policy

To update the ILM policy without rebuilding your Docker image:

```bash
# Edit the ConfigMap
kubectl edit configmap logstash-ilm-policy -n elastic-search

# Or apply a new version
kubectl apply -f updated-ilm-policy-configmap.yaml

# Restart Logstash to pick up changes
kubectl rollout restart statefulset logstash-logstash-test -n elastic-search

# Watch the rollout
kubectl rollout status statefulset logstash-logstash-test -n elastic-search
```

## Multi-Environment Setup

### Using Kustomize

Create a directory structure:

```
k8s/
├── base/
│   ├── kustomization.yaml
│   ├── statefulset.yaml
│   └── pipeline-configmap.yaml
├── overlays/
│   ├── development/
│   │   ├── kustomization.yaml
│   │   └── ilm-policy-configmap.yaml
│   ├── staging/
│   │   ├── kustomization.yaml
│   │   └── ilm-policy-configmap.yaml
│   └── production/
│       ├── kustomization.yaml
│       └── ilm-policy-configmap.yaml
```

**base/kustomization.yaml:**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - statefulset.yaml
  - pipeline-configmap.yaml
```

**overlays/development/kustomization.yaml:**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
bases:
  - ../../base
resources:
  - ilm-policy-configmap.yaml
namePrefix: dev-
namespace: elastic-search-dev
```

Deploy:
```bash
kubectl apply -k overlays/development/
kubectl apply -k overlays/staging/
kubectl apply -k overlays/production/
```

## Troubleshooting

### Policy Not Loading

**Check logs:**
```bash
kubectl logs logstash-logstash-test-0 -n elastic-search -c logstash | grep -A5 -B5 "ILM policy"
```

**Common issues:**
1. File not mounted: Check volume mounts
2. Wrong path: Verify `ILM_POLICY_PATH` matches mount path
3. Invalid JSON: Validate with `kubectl exec ... -- cat /usr/share/logstash/config/ilm-policy.json | jq .`

### Events Not Flowing

```bash
# Check Logstash stats
kubectl exec -it logstash-logstash-test-0 -n elastic-search -- \
  curl -s "http://localhost:9600/_node/stats/pipelines?pretty"

# Check for errors
kubectl logs --tail=100 logstash-logstash-test-0 -n elastic-search -c logstash | grep -i error
```

### Policies Not Created

```bash
# Check if auto-creation is enabled in your output
kubectl exec -it logstash-logstash-test-0 -n elastic-search -c logstash -- \
  cat /usr/share/logstash/pipeline/logstash.conf | grep ilm_auto_create

# Should show:
# ilm_auto_create_policy => true
# ilm_auto_create_template => true
```

## Best Practices

1. ✅ **Use ConfigMaps**: Store policies in ConfigMaps for easy updates
2. ✅ **Version Control**: Keep ConfigMaps in Git
3. ✅ **Environment Labels**: Label ConfigMaps with environment
4. ✅ **Common Fallback**: Always have a common-ilm-policy as fallback
5. ✅ **Monitor**: Watch Logstash logs during rollout
6. ✅ **Test First**: Test policy changes in development
7. ✅ **Document**: Keep README with retention requirements

## Complete Example Files

See `kubernetes-deployment-example.yaml` for a complete working example.
