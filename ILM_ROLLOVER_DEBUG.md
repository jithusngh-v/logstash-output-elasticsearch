# 🚨 ILM Rollover Not Working - Root Cause Analysis

## ❌ **The Problem**

- ILM policy configured with `1d hot, 1d cold`
- Indices **NOT rolling over** after 1 day
- Still writing to yesterday's index `<container_name>-000001`
- Should be creating `<container_name>-000002` today

---

## 🔍 **Potential Root Causes**

### **1. Policy vs Reality Mismatch ⚠️**

**Your Policy Says:** `1d hot, 1d cold`  
**Default Policy Says:** `max_age: "30d"` (from default-ilm-policy.json)

**❓ CLARIFYING QUESTIONS:**

1. **Are you using custom policy via `ILM_POLICY_PATH` environment variable?**
2. **What does your actual custom policy file contain?**
3. **Show me the logs:** `"Loading custom ILM policy from environment variable"` or `"Loading default ILM policy"`?

---

### **2. Index Settings Missing ILM Configuration ⚠️**

**The Issue:** Index might not have proper ILM settings attached.

**Check This:**

```bash
# Check if your indices have ILM settings
curl -X GET "http://elastic:password@eck-es-http:9200/uibackend-000001/_settings?pretty"
```

**Should See:**

```json
{
  "uibackend-000001": {
    "settings": {
      "index": {
        "lifecycle": {
          "name": "uibackend-ilm-policy",           ✅ Should be present
          "rollover_alias": "uibackend"             ✅ Should be present
        }
      }
    }
  }
}
```

---

### **3. Alias Not Set as Write Index ⚠️**

**The Issue:** Rollover only works if alias points to write index.

**Check This:**

```bash
# Check alias configuration
curl -X GET "http://elastic:password@eck-es-http:9200/_alias/uibackend?pretty"
```

**Should See:**

```json
{
  "uibackend-000001": {
    "aliases": {
      "uibackend": {
        "is_write_index": true    ✅ CRITICAL: Must be true!
      }
    }
  }
}
```

---

### **4. ILM Policy Not Applied or Wrong ⚠️**

**Check Policy:**

```bash
# Check if your custom policy exists
curl -X GET "http://elastic:password@eck-es-http:9200/_ilm/policy/uibackend-ilm-policy?pretty"
```

**Should See:**

```json
{
  "uibackend-ilm-policy": {
    "policy": {
      "phases": {
        "hot": {
          "min_age": "0ms",
          "actions": {
            "rollover": {
              "max_age": "1d"     ✅ Should be 1d, not 30d!
            }
          }
        }
      }
    }
  }
}
```

---

### **5. Index Age vs Creation Time ⚠️**

**The Issue:** ILM uses index **creation time**, not document timestamps.

**Check This:**

```bash
# Check when index was created
curl -X GET "http://elastic:password@eck-es-http:9200/uibackend-000001/_settings?pretty" | grep creation_date
```

**Calculate Age:**

- Creation timestamp (epoch) vs current time
- Must be > 24 hours for 1d rollover

---

### **6. ILM Service Not Running ⚠️**

**Check ILM Status:**

```bash
# Check if ILM is running
curl -X GET "http://elastic:password@eck-es-http:9200/_ilm/status?pretty"
```

**Should See:**

```json
{
  "operation_mode": "RUNNING"    ✅ Must be RUNNING, not STOPPED
}
```

---

### **7. Index Pattern in Template vs Reality ⚠️**

**The Issue:** Template pattern might not match actual indices.

**Your Template Pattern:** `uibackend-*`  
**Your Index Name:** `uibackend-000001` ✅ Should match

**Check Templates:**

```bash
curl -X GET "http://elastic:password@eck-es-http:9200/_index_template/logstash-uibackend?pretty"
```

---

## 🔧 **Diagnostic Commands**

### **Run These Now:**

```bash
# 1. Check ILM status
curl -X GET "http://elastic:password@eck-es-http:9200/_ilm/status"

# 2. Check specific policy
curl -X GET "http://elastic:password@eck-es-http:9200/_ilm/policy/uibackend-ilm-policy?pretty"

# 3. Check index settings
curl -X GET "http://elastic:password@eck-es-http:9200/uibackend-000001/_settings?pretty"

# 4. Check alias configuration
curl -X GET "http://elastic:password@eck-es-http:9200/_alias/uibackend?pretty"

# 5. Check ILM explain (WHY rollover not happening)
curl -X GET "http://elastic:password@eck-es-http:9200/uibackend-000001/_ilm/explain?pretty"

# 6. List all indices for this alias
curl -X GET "http://elastic:password@eck-es-http:9200/_cat/indices/uibackend-*?v&h=index,creation.date,creation.date.string,docs.count,pri.store.size"
```

---

## 🎯 **Most Likely Root Causes**

### **Hypothesis 1: Wrong Policy Applied**

Your custom policy has `1d` but default has `30d`. If default is being used, rollover won't happen for 30 days.

### **Hypothesis 2: Missing ILM Settings on Index**

Index created before ILM setup, so it doesn't have ILM settings.

### **Hypothesis 3: Alias Not Write Index**

If `is_write_index: false`, rollover won't trigger.

### **Hypothesis 4: ILM Service Stopped**

ILM daemon might be disabled in Elasticsearch.

---

## 🔍 **Investigation Priority**

### **Priority 1 (Most Critical):**

```bash
# Check ILM explain - shows EXACTLY why rollover not happening
curl -X GET "http://elastic:password@eck-es-http:9200/uibackend-000001/_ilm/explain?pretty"
```

**Look for:**

- `"phase": "hot"` - Should be in hot phase
- `"step": "check-rollover-ready"` - Should be checking rollover
- `"failed_step_retry_count"` - Should be 0 (no failures)
- Any error messages

### **Priority 2:**

```bash
# Check which policy is actually being used
curl -X GET "http://elastic:password@eck-es-http:9200/uibackend-000001/_settings?pretty" | grep -A 5 lifecycle
```

### **Priority 3:**

```bash
# Verify your custom policy exists and has 1d
curl -X GET "http://elastic:password@eck-es-http:9200/_ilm/policy/uibackend-ilm-policy?pretty"
```

---

## 🔧 **Potential Fixes**

### **Fix 1: Force Rollover (Emergency)**

```bash
# Manually trigger rollover NOW
curl -X POST "http://elastic:password@eck-es-http:9200/uibackend/_rollover?pretty"
```

### **Fix 2: Apply ILM to Existing Index**

```bash
# Add ILM settings to existing index
curl -X PUT "http://elastic:password@eck-es-http:9200/uibackend-000001/_settings" -H 'Content-Type: application/json' -d'
{
  "index": {
    "lifecycle": {
      "name": "uibackend-ilm-policy",
      "rollover_alias": "uibackend"
    }
  }
}'
```

### **Fix 3: Start ILM (if stopped)**

```bash
# Start ILM service
curl -X POST "http://elastic:password@eck-es-http:9200/_ilm/start"
```

---

## ❓ **Questions for You:**

1. **What's in your Logstash logs?** Look for:

   - `"Loading custom ILM policy from environment variable"`
   - `"Loading default ILM policy"`

2. **Do you have `ILM_POLICY_PATH` environment variable set?**

3. **When was the first index created?** (Run diagnostic command #6)

4. **What does `_ilm/explain` show?** (Most important!)

---

## 🎯 **Next Steps**

1. **Run the diagnostic commands above**
2. **Share the output** of `_ilm/explain` - this will show exactly why rollover isn't happening
3. **Show me your custom ILM policy file** (if using one)
4. **Check Logstash logs** for ILM policy loading messages

**The `_ilm/explain` command will give us the definitive answer!**

---

## 🚀 **Expected Resolution**

Once we identify the root cause, the fix will likely be:

- ✅ Apply correct 1d policy to existing indices
- ✅ Set proper alias write index
- ✅ Start ILM service if stopped
- ✅ Or manually rollover and let ILM take over

**Let's run those diagnostic commands first!** 🔍
