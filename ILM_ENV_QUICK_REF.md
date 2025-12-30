# ILM Policy Environment Variable - Quick Reference

## Environment Variables

| Variable                   | Description                                   |
| -------------------------- | --------------------------------------------- |
| `ILM_POLICY_PATH`          | Path to custom ILM policy JSON file (primary) |
| `LOGSTASH_ILM_POLICY_PATH` | Alternative name for the same purpose         |

## Quick Start

### 1. Create Your Policy File

```json
{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": { "max_age": "1d" },
          "set_priority": { "priority": 100 }
        }
      },
      "delete": {
        "min_age": "1d",
        "actions": {
          "delete": { "delete_searchable_snapshot": true }
        }
      }
    }
  }
}
```

### 2. Set Environment Variable

```bash
export ILM_POLICY_PATH=/path/to/your/policy.json
```

### 3. Run Logstash

```bash
# Automatically uses the policy from ILM_POLICY_PATH
/usr/share/logstash/bin/logstash -f logstash.conf
```

## Docker

```bash
docker run \
  -e ILM_POLICY_PATH=/config/policy.json \
  -v $(pwd)/my-policy.json:/config/policy.json \
  your-logstash-image
```

## Docker Compose

```yaml
services:
  logstash:
    image: your-logstash-image
    environment:
      - ILM_POLICY_PATH=/config/policy.json
    volumes:
      - ./policies/dev.json:/config/policy.json
```

## Kubernetes

```yaml
env:
  - name: ILM_POLICY_PATH
    value: "/config/ilm-policy.json"
volumeMounts:
  - name: ilm-policy
    mountPath: /config
volumes:
  - name: ilm-policy
    configMap:
      name: ilm-policy-configmap
```

## Behavior

| Scenario                   | Result                   |
| -------------------------- | ------------------------ |
| Env var set + file exists  | ✅ Uses custom policy    |
| Env var set + file missing | ⚠️ Falls back to default |
| Env var set + invalid JSON | ⚠️ Falls back to default |
| Env var not set            | ✅ Uses default policy   |

## Log Check

```bash
# Check what policy is being used
grep "ILM policy" /var/log/logstash/logstash-plain.log

# Should see one of:
# "Loading custom ILM policy from environment variable"
# "Loading default ILM policy"
```

## Verify in Elasticsearch

```bash
# Check the policy
GET _ilm/policy/your-alias-ilm-policy

# Check the index settings
GET your-alias-000001/_settings
```

## Common Issues

### File Not Found

```
[ERROR] Custom ILM policy path does not exist, falling back to default
```

**Fix**: Check file path and permissions

### Invalid JSON

```
[ERROR] Failed to load custom ILM policy, falling back to default
```

**Fix**: Validate JSON syntax with `jq`:

```bash
cat policy.json | jq .
```

### Policy Not Applied

```bash
# Check environment variable is set
env | grep ILM_POLICY_PATH

# Check Logstash can read the file
ls -la /path/to/policy.json
```

## Examples

See `lib/logstash/outputs/elasticsearch/examples/` for:

- `development-ilm-policy.json` (1d retention)
- `staging-ilm-policy.json` (7d retention)
- `production-ilm-policy.json` (30d retention)

## Default Policy Location

If no custom policy is specified:

```
lib/logstash/outputs/elasticsearch/default-ilm-policy.json
```

Current default: 1 day rollover, 1 day deletion
