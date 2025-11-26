# Custom ILM Policy Configuration

This directory contains example ILM (Index Lifecycle Management) policy files for different environments.

## Usage

### Environment Variable Configuration

The Logstash Elasticsearch output plugin supports loading custom ILM policies via environment variables:

- `ILM_POLICY_PATH` - Primary environment variable
- `LOGSTASH_ILM_POLICY_PATH` - Alternative environment variable

### Docker Example

```bash
# Development environment
docker run -e ILM_POLICY_PATH=/config/development-ilm-policy.json \
  -v /path/to/your/policy:/config/development-ilm-policy.json \
  your-logstash-image

# Production environment
docker run -e ILM_POLICY_PATH=/config/production-ilm-policy.json \
  -v /path/to/your/policy:/config/production-ilm-policy.json \
  your-logstash-image
```

### Kubernetes ConfigMap Example

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ilm-policy-config
data:
  ilm-policy.json: |
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
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: logstash
spec:
  template:
    spec:
      containers:
        - name: logstash
          env:
            - name: ILM_POLICY_PATH
              value: "/config/ilm-policy.json"
          volumeMounts:
            - name: ilm-policy
              mountPath: /config
      volumes:
        - name: ilm-policy
          configMap:
            name: ilm-policy-config
```

## Example Policies

### Development (`development-ilm-policy.json`)

- **Rollover**: Every 1 day
- **Delete**: After 1 day
- **Use case**: Short retention for development/testing

### Staging (`staging-ilm-policy.json`)

- **Rollover**: Every 3 days
- **Delete**: After 7 days
- **Use case**: Moderate retention for staging environments

### Production (`production-ilm-policy.json`)

- **Rollover**: Every 7 days or 50GB
- **Warm phase**: After 7 days (shrink to 1 shard, priority 50)
- **Delete**: After 30 days
- **Use case**: Long retention with cost optimization

## Policy Structure

The policy file must be valid JSON with the following structure:

```json
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
```

## Fallback Behavior

If the custom policy path:

1. Is not set in environment variables
2. Points to a non-existent file
3. Contains invalid JSON

The plugin will automatically fall back to `default-ilm-policy.json` and log an appropriate error message.

## Logging

The plugin logs the following information:

```
[INFO] Loading custom ILM policy from environment variable {:path=>"/config/ilm-policy.json", :env_var=>"ILM_POLICY_PATH"}
[INFO] Successfully loaded custom ILM policy {:path=>"/config/ilm-policy.json"}
```

Or if falling back to default:

```
[ERROR] Custom ILM policy path specified in environment variable does not exist, falling back to default {:path=>"/config/invalid.json", :env_var=>"ILM_POLICY_PATH"}
[INFO] Loading default ILM policy {:path=>"/path/to/default-ilm-policy.json"}
```

## Testing Your Policy

You can validate your custom policy before deploying:

```bash
# Check JSON syntax
cat your-policy.json | jq .

# Test with Elasticsearch API
curl -X PUT "localhost:9200/_ilm/policy/test-policy?pretty" \
  -H 'Content-Type: application/json' \
  -d @your-policy.json
```

## Best Practices

1. **Version Control**: Store your policy files in version control
2. **Environment-Specific**: Use different policies for different environments
3. **Single Image**: Use the same Docker image across all environments
4. **Validation**: Always validate JSON syntax before deploying
5. **Monitoring**: Monitor ILM policy execution in Kibana
6. **Documentation**: Document retention requirements per environment

## Troubleshooting

### Policy Not Loading

Check Logstash logs for error messages:

```bash
grep "ILM policy" /var/log/logstash/logstash-plain.log
```

### Verify Environment Variable

```bash
# In Docker container
docker exec <container-id> env | grep ILM_POLICY_PATH

# In Kubernetes pod
kubectl exec <pod-name> -- env | grep ILM_POLICY_PATH
```

### File Permissions

Ensure Logstash can read the policy file:

```bash
ls -la /path/to/policy.json
# Should be readable by the logstash user
```
