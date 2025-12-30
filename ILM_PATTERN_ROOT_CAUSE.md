# 🚨 **FOUND THE ROOT CAUSE!** ILM Rollover Issue

## ❌ **The Critical Problem Identified**

Looking at your logs and code, I found the **root cause**:

### **Issue: `ilm_pattern` Contains Date Expression**

**From elasticsearch.rb line 241:**

```ruby
config :ilm_pattern, :validate => :string, :default => '{now/d}-000001'
```

**In your rollover alias creation (ilm.rb line 140):**

```ruby
target = "<#{resolved_alias}-#{ilm_pattern}>"
# This creates: "<uibackend-{now/d}-000001>"
```

---

## 🔍 **What This Means**

### **Expected Behavior:**

```
target = "<uibackend-000001>"  ✅ Simple numeric pattern
```

### **Actual Behavior:**

```
target = "<uibackend-{now/d}-000001>"  ❌ Date + numeric pattern
```

**Result:** When ILM tries to rollover, it's looking for a **date-based pattern** but your indices follow a **simple numeric pattern**.

---

## 🎯 **The Timeline Issue**

### **What Happens:**

1. **Day 1:** Index created as `uibackend-000001`
2. **Day 2:** ILM tries to rollover looking for pattern `uibackend-{now/d}-000001`
3. **Date changes:** `{now/d}` resolves to today's date
4. **Rollover fails:** Pattern doesn't match existing index name
5. **Result:** Keeps writing to old index `uibackend-000001`

---

## ⚠️ **Diagnostic Questions**

### **1. Check Your Index Names:**

```bash
# What are your actual index names?
curl -X GET "http://elastic:password@eck-es-http:9200/_cat/indices/uibackend-*?v&h=index,creation.date.string"
```

**Expected to see EITHER:**

```
# Simple numeric pattern (what you probably have):
uibackend-000001

# OR Date-based pattern (what ILM expects):
uibackend-2025.11.26-000001
uibackend-2025.11.27-000001
```

### **2. Check ILM Explain:**

```bash
# See what ILM is trying to do
curl -X GET "http://elastic:password@eck-es-http:9200/uibackend-000001/_ilm/explain?pretty"
```

**Look for:**

- Current step/phase
- Any rollover conditions
- Error messages about pattern matching

### **3. Check Rollover Alias Target:**

```bash
# See what target pattern is set
curl -X GET "http://elastic:password@eck-es-http:9200/_alias/uibackend?pretty"
```

---

## 🔧 **The Fix Options**

### **Option 1: Use Simple Numeric Pattern (Recommended)**

**Change your Logstash configuration:**

```ruby
output {
  elasticsearch {
    # ... other settings ...
    ilm_pattern => "000001"  # Remove the {now/d} part
    ilm_rollover_alias => "%{[container_name]}"
    ilm_policy => "%{[container_name]}-ilm-policy"
  }
}
```

**Result:** Creates indices like `uibackend-000001`, `uibackend-000002`, etc.

### **Option 2: Use Date-Based Pattern (Alternative)**

**Keep default `ilm_pattern` but ensure consistency:**

```ruby
output {
  elasticsearch {
    # ... other settings ...
    # Use default: ilm_pattern => "{now/d}-000001"
    ilm_rollover_alias => "%{[container_name]}"
    ilm_policy => "%{[container_name]}-ilm-policy"
  }
}
```

**Result:** Creates indices like `uibackend-2025.11.27-000001`, `uibackend-2025.11.28-000001`, etc.

---

## 🎯 **Why This Happened**

### **The Pattern Mismatch:**

1. **Your existing indices:** `uibackend-000001` (simple numeric)
2. **Default ilm_pattern:** `{now/d}-000001` (date + numeric)
3. **ILM expectation:** Date-based rollover
4. **Reality:** Simple numeric indices already exist

### **When ILM Tries to Rollover:**

- **Looks for:** `uibackend-{today's date}-000001`
- **Finds:** `uibackend-000001` (no date)
- **Result:** Pattern mismatch, rollover fails

---

## 🔧 **Immediate Fix Steps**

### **Step 1: Check Current State**

```bash
# 1. See your actual index names
curl -X GET "http://elastic:password@eck-es-http:9200/_cat/indices/uibackend-*?v"

# 2. Check what ILM is expecting
curl -X GET "http://elastic:password@eck-es-http:9200/uibackend-000001/_ilm/explain?pretty"

# 3. Check alias target
curl -X GET "http://elastic:password@eck-es-http:9200/_alias/uibackend?pretty"
```

### **Step 2: Quick Fix (Force Simple Pattern)**

**Update your Logstash config:**

```ruby
output {
  elasticsearch {
    hosts => ["eck-es-http:9200"]
    ilm_enabled => true
    ilm_rollover_alias => "%{[container_name]}"
    ilm_policy => "%{[container_name]}-ilm-policy"
    ilm_pattern => "000001"  # ✅ ADD THIS LINE - removes date component
    ilm_auto_create_policy => true
    ilm_auto_create_template => true
    user => "elastic"
    password => "${ELASTIC_PASSWORD}"
  }
}
```

### **Step 3: Restart Logstash**

The new pattern will be applied to new aliases created.

---

## ⚠️ **For Existing Indices (If Pattern Mismatch)**

### **If your indices are already created with wrong pattern:**

```bash
# 1. Manually rollover to fix the pattern
curl -X POST "http://elastic:password@eck-es-http:9200/uibackend/_rollover?pretty"

# 2. Or recreate the alias with correct target
curl -X DELETE "http://elastic:password@eck-es-http:9200/uibackend"

curl -X PUT "http://elastic:password@eck-es-http:9200/uibackend-000001" -H 'Content-Type: application/json' -d'
{
  "aliases": {
    "uibackend": {
      "is_write_index": true
    }
  },
  "settings": {
    "index.lifecycle.name": "uibackend-ilm-policy",
    "index.lifecycle.rollover_alias": "uibackend"
  }
}'
```

---

## 🎯 **Root Cause Summary**

**The Issue:** `ilm_pattern` default contains `{now/d}` (date expression) but your indices are created with simple numeric pattern.

**The Result:** ILM can't match the rollover pattern, so it never rolls over.

**The Fix:** Set `ilm_pattern => "000001"` to use simple numeric rollover.

---

## ❓ **Questions for You:**

1. **What do your actual index names look like?** (Run the first diagnostic command)
2. **Are you explicitly setting `ilm_pattern` in your Logstash config?**
3. **What does `_ilm/explain` show for the current index?**

**This is almost certainly the root cause!** The pattern mismatch prevents proper rollover. 🎯
