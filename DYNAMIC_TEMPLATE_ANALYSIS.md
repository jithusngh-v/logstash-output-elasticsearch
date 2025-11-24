# Dynamic Template Creation Analysis

## Why We Skip Template Creation Instead of Creating Dynamically

### TL;DR
We **cannot** create templates per-event like we do with aliases because:
1. **Template patterns must be wildcards**, not specific aliases
2. **Template explosion** with high cardinality fields
3. **One wildcard template covers infinite aliases** (better design)

---

## The Template vs Alias Difference

### Aliases (What We Create Dynamically)
```
Event: {environment: "prod"}
→ Creates: logs-prod (write alias)
→ Points to: logs-prod-000001 (actual index)
```

**Characteristics:**
- ✅ **Specific**: One alias per unique value combination
- ✅ **Lightweight**: Just a pointer to indices
- ✅ **Dynamic-friendly**: Designed for runtime creation
- ✅ **Cacheable**: Set tracking prevents duplicate creation

### Templates (What We Can't Create Per-Event)
```
Template must define: "index_patterns": ["logs-prod-*"]
This matches: logs-prod-000001, logs-prod-000002, logs-prod-000003...
```

**Characteristics:**
- ❌ **Wildcard patterns**: Must match future indices (with rollover numbers)
- ❌ **Heavy**: Contains mappings, settings, analyzers
- ❌ **Cluster-wide**: Affects all nodes, stored in cluster state
- ❌ **Performance-sensitive**: Too many templates slow down index creation

---

## Why Dynamic Template Creation Fails

### Scenario: You Try to Create Templates Dynamically

```ruby
# Your config
ilm_rollover_alias => "logs-%{[service]}-%{[environment]}"

# First event from api-prod
event = { service: "api", environment: "prod" }
→ Resolve to: logs-api-prod
→ Create template with pattern: "logs-api-prod-*"  ✅ Works!

# Second event from web-dev
event = { service: "web", environment: "dev" }
→ Resolve to: logs-web-dev
→ Create template with pattern: "logs-web-dev-*"  ✅ Works!

# After 1 week...
→ You have 100 services × 3 environments = 300 templates! ❌
```

**Problems:**
1. **Template Explosion**: Each unique combination creates a new template
2. **Cluster State Bloat**: All templates stored in Elasticsearch cluster state
3. **Index Creation Slowdown**: ES must check hundreds of templates for each new index
4. **Maintenance Nightmare**: Updating mappings requires updating 300 templates

---

## The Correct Approach: One Wildcard Template

### Instead of N Templates, Create 1 Master Template

**In Elasticsearch (one-time setup):**
```json
PUT _index_template/dynamic-logs-master
{
  "index_patterns": ["logs-*-*"],  // Matches ALL: logs-api-prod-*, logs-web-dev-*, etc.
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 1
    },
    "mappings": {
      "properties": {
        "message": { "type": "text" },
        "service": { "type": "keyword" },
        "environment": { "type": "keyword" },
        "@timestamp": { "type": "date" }
      }
    }
  },
  "priority": 200
}
```

**Result:**
- ✅ **One template** covers infinite aliases
- ✅ **Zero runtime overhead** for template management
- ✅ **Standard Elasticsearch practice** (official recommendation)
- ✅ **ILM policy still dynamic** (set per alias during alias creation)

---

## What the Dynamic Code Actually Creates

### Current Implementation (Correct)

```ruby
# For each unique event field combination:
ensure_dynamic_ilm_alias(event)
  → Creates: Write Alias (logs-prod)
  → Creates: Initial Index (logs-prod-000001) with settings:
      - index.lifecycle.name: policy-prod
      - index.lifecycle.rollover_alias: logs-prod
  → Caches: "logs-prod:policy-prod" in Set

# Template is NOT created because:
# 1. It must already exist (manual setup)
# 2. OR you accept default ES behavior (no specific mappings)
```

**What happens during rollover?**
```
Day 1: logs-prod-000001 (matches template "logs-*-*")
Day 30: ILM triggers rollover
  → Creates: logs-prod-000002 (also matches template "logs-*-*")
  → Inherits: Same mappings/settings from template
  → Links to: Same ILM policy (from alias settings)
```

---

## Alternative: Could We Create One Template Dynamically?

### Yes, but only ONCE (not per-event)

```ruby
def ensure_wildcard_template_exists
  @template_creation_lock ||= Mutex.new
  return if @wildcard_template_created
  
  @template_creation_lock.synchronize do
    return if @wildcard_template_created
    
    # Extract base pattern from sprintf
    # "logs-%{[environment]}" → "logs-*"
    # "logs-%{[service]}-%{[env]}" → "logs-*-*"
    base_pattern = extract_wildcard_pattern(@ilm_rollover_alias)
    
    template = {
      "index_patterns" => ["#{base_pattern}-*"],
      "template" => {
        "settings" => {
          "number_of_shards" => @number_of_shards || 1
        },
        "mappings" => load_default_mappings()
      }
    }
    
    unless client.template_exists?("dynamic-ilm-wildcard")
      logger.info("Creating wildcard template for dynamic ILM", 
                 :pattern => "#{base_pattern}-*")
      client.template_put("dynamic-ilm-wildcard", template)
    end
    
    @wildcard_template_created = true
  end
end

def extract_wildcard_pattern(sprintf_pattern)
  # "logs-%{[environment]}" → "logs-*"
  # "tenant-%{[customer_id]}-logs" → "tenant-*-logs"
  sprintf_pattern.gsub(/%\{[^\}]+\}/, '*')
end
```

**This would work, BUT:**
1. ⚠️ **Generic pattern** may conflict with existing templates
2. ⚠️ **No customization** per environment (all get same mappings)
3. ⚠️ **Still requires user control** over mappings/settings
4. ✅ **Better to document** and let users create it properly

---

## Recommended Architecture

### 1. Pre-Deployment (DevOps/Admin)
```bash
# Create index template in Elasticsearch
PUT _index_template/app-logs
{
  "index_patterns": ["logs-*-*"],
  "template": {
    "settings": { /* your settings */ },
    "mappings": { /* your mappings */ }
  }
}

# Create ILM policies
PUT _ilm/policy/policy-prod { /* 365-day retention */ }
PUT _ilm/policy/policy-dev { /* 7-day retention */ }
```

### 2. Logstash Configuration
```ruby
output {
  elasticsearch {
    ilm_enabled => true
    ilm_rollover_alias => "logs-%{[service]}-%{[environment]}"
    ilm_policy => "policy-%{[environment]}"
    manage_template => false  # Template already exists!
  }
}
```

### 3. Runtime (Automatic)
```
Event arrives → Dynamic ILM code creates alias → Uses existing template ✅
```

---

## Summary: Why Skip vs Create

| Aspect | Create Per-Event Template | Skip & Use Wildcard |
|--------|--------------------------|---------------------|
| **Templates Created** | N (one per combination) | 1 (manual, one-time) |
| **Performance** | ❌ Degrades with cardinality | ✅ Constant |
| **Maintenance** | ❌ Update N templates | ✅ Update 1 template |
| **Flexibility** | ❌ All or nothing | ✅ Full control |
| **Elasticsearch Best Practice** | ❌ Anti-pattern | ✅ Recommended |
| **Code Complexity** | ❌ High (pattern extraction, cache, etc.) | ✅ Low (skip installation) |

---

## Conclusion

**The current implementation (skip template creation) is correct because:**
1. ✅ Aligns with Elasticsearch best practices
2. ✅ Avoids template explosion
3. ✅ Gives users full control over mappings
4. ✅ Maintains high performance regardless of cardinality
5. ✅ ILM policies remain dynamic (the actual requirement)

**The wildcard template approach is not optional magic—it's the ONLY scalable solution for dynamic ILM.**
