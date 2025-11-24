# Template Creation: Why Dynamic Creation Doesn't Work

## Comparison: Alias Creation (Works) vs Template Creation (Doesn't Work)

### ✅ What We DO: Dynamic Alias Creation

```ruby
# In ilm.rb - This WORKS perfectly
def ensure_dynamic_ilm_alias(event)
  resolved_alias = resolve_ilm_rollover_alias(event)
  # e.g., "logs-prod" from "logs-%{[environment]}"
  
  # Cache check
  alias_key = "#{resolved_alias}:#{resolved_policy}"
  return if @dynamic_ilm_aliases_created.include?(alias_key)
  
  # Create alias pointing to first index
  target = "<#{resolved_alias}-000001>"
  payload = {
    'aliases' => { resolved_alias => { 'is_write_index' => true } },
    'settings' => {
      'index.lifecycle.name' => resolved_policy,
      'index.lifecycle.rollover_alias' => resolved_alias
    }
  }
  
  client.rollover_alias_put(target, payload)
  @dynamic_ilm_aliases_created.add(alias_key)
end
```

**Result:** 
- Event with `environment: "prod"` → Creates `logs-prod` alias ✅
- Event with `environment: "dev"` → Creates `logs-dev` alias ✅
- 100 different environments → 100 aliases ✅ (expected and fine!)

---

### ❌ What We DON'T DO: Dynamic Template Creation (Would Fail)

```ruby
# HYPOTHETICAL CODE - DO NOT USE!
def ensure_dynamic_template(event)
  resolved_alias = resolve_ilm_rollover_alias(event)
  # e.g., "logs-prod" from "logs-%{[environment]}"
  
  # Create template for this specific alias
  template_name = "template-#{resolved_alias}"
  template = {
    "index_patterns" => ["#{resolved_alias}-*"],  # ⚠️ Problem starts here
    "template" => {
      "settings" => { "number_of_shards" => 1 },
      "mappings" => { /* ... */ }
    }
  }
  
  client.template_put(template_name, template)
end
```

**Result:**
- Event with `environment: "prod"` → Creates `template-logs-prod` with pattern `logs-prod-*` ✅
- Event with `environment: "dev"` → Creates `template-logs-dev` with pattern `logs-dev-*` ✅
- 100 different environments → **100 templates!** ❌ (cluster state explosion)

**Why this is terrible:**
1. Each template adds ~10-50KB to cluster state
2. Elasticsearch checks ALL templates on every index creation
3. Template updates require updating 100 separate documents
4. Priority conflicts become impossible to manage

---

## The Root Problem: Index Patterns Must Be Wildcards

### Understanding Index Patterns

When ILM triggers a rollover, Elasticsearch creates a new index with an incremented number:

```
Timeline:
Day 0:   logs-prod-000001  (initial)
Day 30:  logs-prod-000002  (after first rollover)
Day 60:  logs-prod-000003  (after second rollover)
Day 90:  logs-prod-000004  (after third rollover)
```

**The template must match ALL of these indices**, not just the first one!

### ❌ Bad: Specific Pattern Per Alias
```json
// Template created for logs-prod alias
{
  "index_patterns": ["logs-prod-*"],
  "template": { /* settings */ }
}

// Template created for logs-dev alias
{
  "index_patterns": ["logs-dev-*"],
  "template": { /* settings */ }
}

// Template created for logs-staging alias
{
  "index_patterns": ["logs-staging-*"],
  "template": { /* settings */ }
}
```
**Result:** 3 templates (multiply by number of environments)

### ✅ Good: One Wildcard Pattern
```json
// ONE template for all environments
{
  "index_patterns": ["logs-*-*"],  // Matches logs-prod-*, logs-dev-*, logs-staging-*
  "template": { /* settings */ }
}
```
**Result:** 1 template (constant regardless of environments)

---

## Real-World Scenario

### Company: AcmeCorp
**Services:** api, web, worker, scheduler (4 services)
**Environments:** dev, staging, prod (3 environments)
**Regions:** us-east, us-west, eu-central (3 regions)

### Configuration:
```ruby
ilm_rollover_alias => "logs-%{[service]}-%{[environment]}-%{[region]}"
```

### Dynamic Template Creation Approach (BAD):
```
Total combinations: 4 × 3 × 3 = 36

Templates created:
1. template-logs-api-dev-us-east     pattern: logs-api-dev-us-east-*
2. template-logs-api-dev-us-west     pattern: logs-api-dev-us-west-*
3. template-logs-api-dev-eu-central  pattern: logs-api-dev-eu-central-*
4. template-logs-api-staging-us-east pattern: logs-api-staging-us-east-*
...
36. template-logs-scheduler-prod-eu-central  pattern: logs-scheduler-prod-eu-central-*
```

**Problems:**
- ❌ 36 templates in cluster state
- ❌ Adding a new service? Must create 9 more templates
- ❌ Need to update mapping? Must update 36 templates
- ❌ Template priority conflicts hard to manage

### Wildcard Template Approach (GOOD):
```
Total templates: 1

Template created (manually, one time):
PUT _index_template/acme-logs
{
  "index_patterns": ["logs-*-*-*"],  // Matches ALL combinations
  "template": {
    "settings": { /* settings */ },
    "mappings": { /* mappings */ }
  }
}
```

**Benefits:**
- ✅ 1 template regardless of cardinality
- ✅ Adding new service? No template changes needed
- ✅ Update mapping? Update 1 template
- ✅ Clear priority (just one template to manage)

---

## What About Creating Just ONE Wildcard Template Dynamically?

### Could We Do This?

```ruby
def ensure_single_wildcard_template
  return if @wildcard_template_created
  
  @template_lock.synchronize do
    return if @wildcard_template_created
    
    # Convert "logs-%{[environment]}" → "logs-*"
    # Convert "logs-%{[service]}-%{[env]}" → "logs-*-*"
    wildcard_pattern = @ilm_rollover_alias.gsub(/%\{[^\}]+\}/, '*')
    
    template = {
      "index_patterns" => ["#{wildcard_pattern}-*"],
      "template" => {
        "settings" => { "number_of_shards" => @number_of_shards || 1 },
        "mappings" => load_default_mappings()
      }
    }
    
    client.template_put("logstash-dynamic-ilm", template)
    @wildcard_template_created = true
  end
end
```

### Pros:
- ✅ Only one template created
- ✅ Created automatically (no manual setup)
- ✅ Scales with cardinality

### Cons:
- ⚠️ **Template naming collision** - What if user already has a template named "logstash-dynamic-ilm"?
- ⚠️ **Limited customization** - Can only use default mappings, not custom ones
- ⚠️ **Priority conflicts** - May override user's existing templates unintentionally
- ⚠️ **No rollback** - If template is created wrong, affects all indices
- ⚠️ **Pattern extraction complexity** - What if pattern is `logs-%{[type][category]}`?

### Decision:
**Not worth the complexity and risks.** Better to:
1. Document the requirement clearly
2. Provide template examples
3. Let users create it properly (with their custom mappings/settings)
4. Validate at startup that template exists

---

## The Elasticsearch Way

### Official Elasticsearch Recommendation for Dynamic Indices

From Elasticsearch documentation on ILM:

> **Best Practice:** Create index templates with wildcard patterns that match your rollover alias naming convention.
> Do not create separate templates for each alias.

**Example from Elastic documentation:**
```json
PUT _index_template/my-data-stream-template
{
  "index_patterns": ["my-logs-*"],
  "data_stream": { },
  "template": {
    "settings": {
      "index.lifecycle.name": "my-policy"
    }
  }
}
```

Notice: **One template**, **wildcard pattern**, **multiple data streams match it**.

---

## What Actually Needs to Be Dynamic

| Component | Dynamic? | Why |
|-----------|----------|-----|
| **ILM Policy** | ✅ Yes | Different retention per tenant/environment |
| **Write Alias** | ✅ Yes | Route events to correct index stream |
| **Initial Index** | ✅ Yes | Created when alias is created |
| **Index Template** | ❌ No | One wildcard pattern covers all cases |

**Key Insight:** ILM policy assignment happens at the **index level** (during alias creation), not at the template level.

```ruby
# When we create the alias, we set the policy on the FIRST INDEX:
payload = {
  'settings' => {
    'index.lifecycle.name' => 'policy-prod',  # ← Dynamic per event!
    'index.lifecycle.rollover_alias' => 'logs-prod'
  }
}
```

The template just provides default **mappings and settings**. The ILM policy link is established via the alias creation, not via the template.

---

## Summary: The Answer

### Q: Why skip template creation instead of creating dynamically?

### A: Because templates and aliases serve different purposes:

**Aliases** (Dynamic):
- Specific routing endpoints
- One per unique event field combination
- Lightweight, designed for high cardinality
- **Analogy:** Individual street addresses

**Templates** (Static):
- Define structure for index families
- One wildcard pattern covers many aliases
- Heavy, stored in cluster state
- **Analogy:** Building codes that apply to entire neighborhoods

**The Code:**
```ruby
# This makes sense (low cardinality, lightweight)
@dynamic_ilm_aliases_created.add("logs-prod:policy-prod")
@dynamic_ilm_aliases_created.add("logs-dev:policy-dev")
# Result: 2 aliases in memory

# This doesn't make sense (same cardinality, heavyweight)
elasticsearch.templates["template-logs-prod"] = { /* 50KB template */ }
elasticsearch.templates["template-logs-dev"] = { /* 50KB template */ }
# Result: 2 × 50KB = 100KB in cluster state (multiply by 100 services = 5MB!)
```

**Conclusion:** One wildcard template + many dynamic aliases = Scalable architecture ✅
