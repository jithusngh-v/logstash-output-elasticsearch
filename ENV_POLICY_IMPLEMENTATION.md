# Environment-Based ILM Policy Configuration - Implementation Summary

## Overview

Successfully implemented environment variable support for custom ILM policy configuration. This allows using the **same Docker image** across all environments (dev, staging, production) with different ILM policies.

## Changes Made

### 1. Modified `lib/logstash/outputs/elasticsearch/ilm.rb`

**Method: `policy_payload`**

- Changed from hardcoded policy to loading from file
- Added caching with `@policy_payload_cache`

**New Method: `load_policy_from_file`** (private)

- Checks for environment variables: `ILM_POLICY_PATH` or `LOGSTASH_ILM_POLICY_PATH`
- Loads custom policy if environment variable is set and file exists
- Falls back to `default-ilm-policy.json` if custom policy fails or is not specified
- Comprehensive error handling and logging

### 2. Updated `lib/logstash/outputs/elasticsearch/default-ilm-policy.json`

Changed from:

```json
{
  "policy": {
    "phases": {
      "hot": {
        "actions": {
          "rollover": {
            "max_size": "50gb",
            "max_age": "30d"
          }
        }
      }
    }
  }
}
```

To your requirements:

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

### 3. Created Example Policy Files

**Location**: `lib/logstash/outputs/elasticsearch/examples/`

- `development-ilm-policy.json` - 1 day retention
- `staging-ilm-policy.json` - 7 days retention
- `production-ilm-policy.json` - 30 days retention with warm phase
- `README.md` - Comprehensive documentation

## Usage Examples

### Docker Compose

```yaml
version: "3.8"
services:
  logstash-dev:
    image: your-logstash:latest
    environment:
      - ILM_POLICY_PATH=/config/development-ilm-policy.json
    volumes:
      - ./policies/dev-policy.json:/config/development-ilm-policy.json

  logstash-prod:
    image: your-logstash:latest
    environment:
      - ILM_POLICY_PATH=/config/production-ilm-policy.json
    volumes:
      - ./policies/prod-policy.json:/config/production-ilm-policy.json
```

### Kubernetes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: logstash
spec:
  template:
    spec:
      containers:
        - name: logstash
          image: your-logstash:latest
          env:
            - name: ILM_POLICY_PATH
              value: "/config/ilm-policy.json"
          volumeMounts:
            - name: ilm-policy
              mountPath: /config
      volumes:
        - name: ilm-policy
          configMap:
            name: ilm-policy-config-dev # or ilm-policy-config-prod
```

### Docker Run

```bash
# Development
docker run -e ILM_POLICY_PATH=/config/dev-policy.json \
  -v $(pwd)/dev-policy.json:/config/dev-policy.json \
  your-logstash:latest

# Production
docker run -e ILM_POLICY_PATH=/config/prod-policy.json \
  -v $(pwd)/prod-policy.json:/config/prod-policy.json \
  your-logstash:latest

# No environment variable = uses default policy
docker run your-logstash:latest
```

## Behavior Flow

```
┌─────────────────────────────────────┐
│  Logstash Starts                    │
└──────────┬──────────────────────────┘
           │
           ▼
┌─────────────────────────────────────┐
│  Check ILM_POLICY_PATH env var      │
└──────────┬──────────────────────────┘
           │
     ┌─────┴─────┐
     │           │
   YES           NO
     │           │
     ▼           ▼
┌─────────┐  ┌──────────────────────┐
│ File    │  │ Use default policy   │
│ exists? │  │ default-ilm-policy.  │
└────┬────┘  │ json                 │
     │       └──────────────────────┘
  ┌──┴──┐
  │     │
YES     NO
  │     │
  ▼     ▼
┌─────┐ ┌─────────────────────┐
│Load │ │ Log error & use     │
│file │ │ default policy      │
└──┬──┘ └─────────────────────┘
   │
   ▼
┌──────────────┐
│ Parse JSON   │
└──────┬───────┘
       │
   ┌───┴───┐
   │       │
 OK     ERROR
   │       │
   ▼       ▼
┌─────┐ ┌─────────────────────┐
│Use  │ │ Log error & use     │
│it   │ │ default policy      │
└─────┘ └─────────────────────┘
```

## Log Messages

### Success (Custom Policy)

```
[INFO] Loading custom ILM policy from environment variable {:path=>"/config/prod-policy.json", :env_var=>"ILM_POLICY_PATH"}
[INFO] Successfully loaded custom ILM policy {:path=>"/config/prod-policy.json"}
```

### Success (Default Policy)

```
[INFO] Loading default ILM policy {:path=>"/usr/share/logstash/.../default-ilm-policy.json"}
```

### Error (File Not Found)

```
[ERROR] Custom ILM policy path specified in environment variable does not exist, falling back to default {:path=>"/config/missing.json", :env_var=>"ILM_POLICY_PATH"}
[INFO] Loading default ILM policy {:path=>"/usr/share/logstash/.../default-ilm-policy.json"}
```

### Error (Invalid JSON)

```
[ERROR] Failed to load custom ILM policy from environment variable, falling back to default {:path=>"/config/invalid.json", :error=>"unexpected token at ...", :backtrace=>[...]}
[INFO] Loading default ILM policy {:path=>"/usr/share/logstash/.../default-ilm-policy.json"}
```

## Testing

### Test with Custom Policy

1. Create your policy file:

```bash
cat > /tmp/test-policy.json << 'EOF'
{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": {"max_age": "2d"},
          "set_priority": {"priority": 100}
        }
      },
      "delete": {
        "min_age": "2d",
        "actions": {
          "delete": {"delete_searchable_snapshot": true}
        }
      }
    }
  }
}
EOF
```

2. Run Logstash:

```bash
ILM_POLICY_PATH=/tmp/test-policy.json /usr/share/logstash/bin/logstash -f your-config.conf
```

3. Check logs for confirmation

### Test Fallback Behavior

```bash
# Test with non-existent file
ILM_POLICY_PATH=/tmp/doesnotexist.json /usr/share/logstash/bin/logstash -f your-config.conf

# Test with invalid JSON
echo "invalid json" > /tmp/bad.json
ILM_POLICY_PATH=/tmp/bad.json /usr/share/logstash/bin/logstash -f your-config.conf

# Test without environment variable (default)
/usr/share/logstash/bin/logstash -f your-config.conf
```

## Benefits

✅ **Single Docker Image**: Use the same image across all environments
✅ **Environment-Specific Policies**: Each environment can have different retention
✅ **No Rebuild Required**: Change policies without rebuilding images
✅ **Graceful Fallback**: Always falls back to default policy on errors
✅ **Comprehensive Logging**: Clear visibility of what policy is being used
✅ **Flexible Configuration**: Supports two environment variable names
✅ **Error Resilient**: Continues working even with configuration mistakes

## Verification

After deploying, verify the policy is being used:

```bash
# Check created policies in Elasticsearch
GET _ilm/policy/<your-alias>-ilm-policy

# Should show the policy from your custom file
```

## Next Steps

1. **Build and deploy** your updated Logstash plugin
2. **Create policy files** for each environment
3. **Update deployment configurations** with environment variables
4. **Test** in development first
5. **Monitor** ILM execution in Kibana

## Files Modified/Created

- ✏️ `lib/logstash/outputs/elasticsearch/ilm.rb`
- ✏️ `lib/logstash/outputs/elasticsearch/default-ilm-policy.json`
- ➕ `lib/logstash/outputs/elasticsearch/examples/development-ilm-policy.json`
- ➕ `lib/logstash/outputs/elasticsearch/examples/staging-ilm-policy.json`
- ➕ `lib/logstash/outputs/elasticsearch/examples/production-ilm-policy.json`
- ➕ `lib/logstash/outputs/elasticsearch/examples/README.md`

## Support

For troubleshooting, check:

1. Logstash logs for policy loading messages
2. File permissions on custom policy files
3. JSON syntax validation
4. Environment variable is set correctly
