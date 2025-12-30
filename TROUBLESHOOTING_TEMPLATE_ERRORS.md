# Troubleshooting Template Creation Errors

## 🔍 Understanding the Pipeline Flow

Your dynamic ILM implementation follows this **strict order**:

```
For Each Event:
  │
  ├─ STEP 1: Ensure ILM Policy Exists
  │   ├─ Check if policy exists
  │   ├─ Create if missing (if ilm_auto_create_policy=true)
  │   └─ Log: "Successfully created ILM policy" or "ILM policy already exists"
  │
  ├─ STEP 2: Ensure Template Exists
  │   ├─ Check cache first
  │   ├─ Check Elasticsearch
  │   ├─ Create if missing (if ilm_auto_create_template=true)
  │   └─ Log: "Successfully created dynamic index template"
  │
  └─ STEP 3: Ensure Rollover Alias Exists
      ├─ Check if alias exists
      ├─ Create if missing
      └─ Log: "Creating dynamic ILM rollover alias"
```

---

## ❌ Common Template Creation Errors

### Error 1: HTTP 400 - "Malformed escape pair"

**Log Example:**

```
Failed to install template {:message=>"Malformed escape pair at index 17: /_index_template/%{[container_name]}"}
```

**Cause:** Trying to use sprintf pattern in URL during initial template installation.

**Solution:** This error is from the **default template** installation, not your dynamic templates. It can be safely ignored if you're using dynamic ILM with sprintf patterns.

---

### Error 2: HTTP 400 - Template Creation Failed

**Log Example:**

```
Failed to create dynamic index template
{:template=>"logstash-erma-connector-commonconfig-mappings",
 :error=>"Got response code '400' contacting Elasticsearch..."}
```

**Possible Causes:**

#### A. Template Name Too Long

Elasticsearch has limits on template names:

- **Maximum length**: 255 characters
- **Your failing templates**:
  - `logstash-erma-connector-commonconfig-mappings` (49 chars) ✅
  - `logstash-erma-connector-commonconfig-translations` (52 chars) ✅
  - `logstash-uibackend` (19 chars) ✅

So length is NOT the issue.

#### B. Index Pattern Conflict

Multiple templates with overlapping index patterns can conflict.

**Check:**

```bash
# List all existing templates
curl -X GET "http://elastic:password@eck-es-http:9200/_index_template?pretty"

# Check specific template
curl -X GET "http://elastic:password@eck-es-http:9200/_index_template/logstash-uibackend?pretty"
```

#### C. Invalid Template Payload

The template structure might be invalid for your Elasticsearch version.

---

## 🔧 Diagnostic Steps

### Step 1: Check What Elasticsearch Says

With the improved error logging, you'll now see the **actual Elasticsearch error** in logs:

```ruby
logger.error("Failed to create dynamic index template",
           :template => template_name,
           :alias => resolved_alias,
           :policy => policy_name,
           :error => error_details,              # <-- DETAILED ERROR
           :response_code => e.response_code)
```

Look for logs like:

```
[ERROR] Failed to create dynamic index template
        {:template=>"logstash-uibackend",
         :alias=>"uibackend",
         :policy=>"uibackend-ilm-policy",
         :error=>"index template [logstash-uibackend] already exists",  # <-- THIS!
         :response_code=>400}
```

### Step 2: Manually Check Template in Elasticsearch

```bash
# Check if template exists
curl -X GET "http://elastic:password@eck-es-http:9200/_index_template/logstash-uibackend?pretty"

# If it exists, check its configuration
# Compare with what Logstash is trying to create
```

### Step 3: Check Template Payload

Enable debug logging to see what payload is being sent:

```ruby
# In your Logstash config
output {
  elasticsearch {
    # ... your config ...
    logger_level => "debug"
  }
}
```

You'll see:

```
[DEBUG] Template payload
        {:template=>"logstash-uibackend",
         :index_patterns=>["uibackend-*"],
         :policy=>"uibackend-ilm-policy"}
```

### Step 4: Check for Existing Conflicting Templates

```bash
# List all templates matching pattern
curl -X GET "http://elastic:password@eck-es-http:9200/_index_template/*uibackend*?pretty"

# List all templates matching pattern for commonconfig
curl -X GET "http://elastic:password@eck-es-http:9200/_index_template/*commonconfig*?pretty"
```

---

## 🎯 Most Likely Causes for Your 3 Failing Templates

Based on your logs, these 3 templates are failing:

1. `logstash-erma-connector-commonconfig-mappings`
2. `logstash-erma-connector-commonconfig-translations`
3. `logstash-uibackend`

### Hypothesis 1: Templates Already Exist from Previous Run

If you ran Logstash before, these templates might already exist in Elasticsearch.

**Test:**

```bash
curl -X GET "http://elastic:password@eck-es-http:9200/_index_template/logstash-uibackend"
```

**If exists, two options:**

A. **Delete and recreate:**

```bash
curl -X DELETE "http://elastic:password@eck-es-http:9200/_index_template/logstash-uibackend"
curl -X DELETE "http://elastic:password@eck-es-http:9200/_index_template/logstash-erma-connector-commonconfig-mappings"
curl -X DELETE "http://elastic:password@eck-es-http:9200/_index_template/logstash-erma-connector-commonconfig-translations"
```

B. **Let Logstash skip (it already exists):**
The code already handles this - if template exists, it won't recreate.

### Hypothesis 2: Index Pattern Conflict

Maybe `uibackend-*` pattern conflicts with another template.

**Check:**

```bash
# Get all templates and check for overlapping patterns
curl -X GET "http://elastic:password@eck-es-http:9200/_index_template?pretty" | grep -A 5 "uibackend"
```

### Hypothesis 3: Elasticsearch Version Compatibility

Your ES is 8.8.0, so it should use `_index_template` API (not `_template`).

**Verify:**

```ruby
# Check log output for:
[INFO] Creating dynamic index template
       {:template=>"logstash-uibackend",
        :endpoint=>"_index_template"}  # <-- Should be _index_template for ES 8.x
```

---

## ✅ What's Working Correctly

These templates were created successfully:

- ✅ `logstash-erma-connector-regulatoryconfig`
- ✅ `logstash-erma-connector-notifv2`
- ✅ `logstash-erma-connector-betplaced`
- ✅ `logstash-erma-connector-fb`
- ✅ `logstash-erma-connector-pra`
- ✅ `logstash-erma-connector-commonconfig` (but **-mappings** and **-translations** failed)
- ✅ `logstash-erma-connector-ptl`
- ✅ `logstash-uibackend-promotion`
- ✅ `logstash-erma-connector-bogeligibilityconfig`
- ✅ `logstash-erma-connector-bettor`
- ✅ `logstash-uibackend-betrisks`
- ✅ `logstash-e3fcontentadapterbg`
- ✅ `logstash-erma-connector-conf`
- ✅ `logstash-erma-connector-dynamictemplates`

**Success Rate: 14/17 = 82%**

---

## 🔍 Next Steps

1. **Restart Logstash** with the improved error logging
2. **Check the new error logs** - they will now show the actual Elasticsearch error
3. **Run the diagnostic commands** above for the 3 failing templates
4. **Share the detailed error** from the new logs

---

## 📋 Quick Diagnostic Commands

```bash
# 1. Check if templates exist
curl -X GET "http://elastic:password@eck-es-http:9200/_index_template/logstash-uibackend?pretty"
curl -X GET "http://elastic:password@eck-es-http:9200/_index_template/logstash-erma-connector-commonconfig-mappings?pretty"
curl -X GET "http://elastic:password@eck-es-http:9200/_index_template/logstash-erma-connector-commonconfig-translations?pretty"

# 2. List all templates
curl -X GET "http://elastic:password@eck-es-http:9200/_index_template?pretty"

# 3. Check for index pattern conflicts
curl -X GET "http://elastic:password@eck-es-http:9200/_index_template?pretty" | grep -E "(index_patterns|logstash)" | head -50

# 4. Delete failing templates (if you want to recreate)
curl -X DELETE "http://elastic:password@eck-es-http:9200/_index_template/logstash-uibackend"
curl -X DELETE "http://elastic:password@eck-es-http:9200/_index_template/logstash-erma-connector-commonconfig-mappings"
curl -X DELETE "http://elastic:password@eck-es-http:9200/_index_template/logstash-erma-connector-commonconfig-translations"

# 5. Check ILM policies
curl -X GET "http://elastic:password@eck-es-http:9200/_ilm/policy?pretty" | grep -E "(policy_id|phases)"
```

---

## 🎯 Expected Behavior After Fix

After restarting with improved logging, you'll see one of these:

### Scenario A: Template Already Exists

```
[INFO] Attempting to create dynamic index template
       {:alias=>"uibackend", :policy=>"uibackend-ilm-policy"}
[INFO] Template already exists in Elasticsearch, skipping creation
       {:template=>"logstash-uibackend"}
```

### Scenario B: Template Created Successfully

```
[INFO] Creating dynamic index template
       {:template=>"logstash-uibackend", :alias=>"uibackend"}
[INFO] Installing Elasticsearch template {:name=>"logstash-uibackend"}
[INFO] Successfully created dynamic index template {:template=>"logstash-uibackend"}
```

### Scenario C: Detailed Error

```
[ERROR] Failed to create dynamic index template
        {:template=>"logstash-uibackend",
         :alias=>"uibackend",
         :policy=>"uibackend-ilm-policy",
         :error=>"index_patterns [uibackend-*] matches indices which are managed by composable template [.some-other-template] at the same or higher priority [100]",
         :response_code=>400}
```

---

## 🚀 The Good News

Even if 3 templates fail to create, **your events will still be indexed**! The error handling is non-blocking:

```ruby
rescue => e
  logger.error("Failed to create dynamic index template", ...)
  # Don't fail the event if template creation fails
  # The index will still be created, just without the template
end
```

So the **pipeline continues** and data flows normally.

---

## Summary

✅ **Pipeline flow is correct:** Policy → Template → Alias  
✅ **Most templates (82%) are working**  
✅ **Error handling is non-blocking**  
❓ **3 templates failing** - need to see detailed Elasticsearch error  
🔧 **Improved logging** will show root cause

**Action:** Restart Logstash and check the new detailed error logs!
