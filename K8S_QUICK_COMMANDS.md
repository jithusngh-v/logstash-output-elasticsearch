# Quick Command Reference - Kubernetes ILM Policy Deployment

## Deploy ILM Policy ConfigMap

```bash
# Development (1 day retention)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: logstash-ilm-policy
  namespace: elastic-search
data:
  ilm-policy.json: |
    {"policy":{"phases":{"hot":{"min_age":"0ms","actions":{"rollover":{"max_age":"1d"},"set_priority":{"priority":100}}},"delete":{"min_age":"1d","actions":{"delete":{"delete_searchable_snapshot":true}}}}}}
EOF
```

## Update StatefulSet (Quick Patch)

```bash
# Add ILM_POLICY_PATH environment variable
kubectl set env statefulset/logstash-logstash-test \
  ILM_POLICY_PATH=/usr/share/logstash/config/ilm-policy.json \
  -n elastic-search

# OR manually patch (for volume mount):
kubectl edit statefulset logstash-logstash-test -n elastic-search
```

**Add these sections:**

Under `spec.template.spec.containers[0].env`:

```yaml
- name: ILM_POLICY_PATH
  value: "/usr/share/logstash/config/ilm-policy.json"
```

Under `spec.template.spec.containers[0].volumeMounts`:

```yaml
- mountPath: /usr/share/logstash/config/ilm-policy.json
  name: ilm-policy
  subPath: ilm-policy.json
  readOnly: true
```

Under `spec.template.spec.volumes`:

```yaml
- name: ilm-policy
  configMap:
    defaultMode: 420
    name: logstash-ilm-policy
```

## Verification Commands

```bash
# Check pod is running
kubectl get pods -n elastic-search -l app=logstash-logstash

# Check env var
kubectl exec logstash-logstash-test-0 -n elastic-search -c logstash -- env | grep ILM

# Check file is mounted
kubectl exec logstash-logstash-test-0 -n elastic-search -c logstash -- cat /usr/share/logstash/config/ilm-policy.json

# Check logs for policy loading
kubectl logs -f logstash-logstash-test-0 -n elastic-search -c logstash | grep "ILM policy"

# Check created policies in ES
kubectl exec -it eck-es-es-default-0 -n elastic-search -- curl -s "localhost:9200/_ilm/policy/*?pretty"

# Check created indices
kubectl exec -it eck-es-es-default-0 -n elastic-search -- curl -s "localhost:9200/_cat/indices?v"

# Check created templates
kubectl exec -it eck-es-es-default-0 -n elastic-search -- curl -s "localhost:9200/_index_template/logstash-*?pretty"
```

## Restart Logstash

```bash
# Restart to pick up new policy
kubectl rollout restart statefulset logstash-logstash-test -n elastic-search

# Watch restart
kubectl rollout status statefulset logstash-logstash-test -n elastic-search

# Or delete pod (StatefulSet will recreate)
kubectl delete pod logstash-logstash-test-0 -n elastic-search
```

## Update Policy

```bash
# Edit existing ConfigMap
kubectl edit configmap logstash-ilm-policy -n elastic-search

# OR apply new version
kubectl apply -f updated-policy.yaml

# Then restart Logstash
kubectl rollout restart statefulset logstash-logstash-test -n elastic-search
```

## Troubleshooting

```bash
# Get recent logs
kubectl logs --tail=100 logstash-logstash-test-0 -n elastic-search -c logstash

# Follow logs
kubectl logs -f logstash-logstash-test-0 -n elastic-search -c logstash

# Check for errors
kubectl logs logstash-logstash-test-0 -n elastic-search -c logstash | grep -i error

# Check Logstash stats
kubectl exec logstash-logstash-test-0 -n elastic-search -c logstash -- curl -s localhost:9600/_node/stats?pretty

# Describe pod for events
kubectl describe pod logstash-logstash-test-0 -n elastic-search

# Check ConfigMap
kubectl get configmap logstash-ilm-policy -n elastic-search -o yaml
```

## Complete Apply (All at Once)

```bash
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: logstash-ilm-policy
  namespace: elastic-search
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
---
# Then update your StatefulSet with the volume mount and env var
# (Use kubectl edit or apply full statefulset YAML)
EOF
```
