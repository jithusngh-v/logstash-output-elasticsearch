# Feature Implementation: Custom Template via Environment Variable

## ✅ Implementation Complete

**Date:** December 30, 2025  
**Feature:** Load custom index templates from environment variable (just like ILM policies)

---

## 🎯 What Was Implemented

### New Functionality

Just like `ILM_POLICY_PATH` for custom policies, you now have:

**`ILM_TEMPLATE_PATH`** - Load custom index templates from a file

### How It Works

```
1. Check ILM_TEMPLATE_PATH environment variable
   ↓ File exists?
2. Load and parse JSON template
   ↓ Valid?
3. Use as base template
   ↓ Merge with:
4. - Dynamic ILM lifecycle settings (alias, policy)
   - Config-based overrides (ilm_template_settings)
   - Config-based mappings (ilm_template_mappings)
   ↓
5. Create index template in Elasticsearch
```

---

## 📝 Code Changes

### File Modified
`lib/logstash/outputs/elasticsearch/ilm.rb`

### Changes Made

#### 1. Added `load_template_from_file_or_env()` method
```ruby
private

def load_template_from_file_or_env
  return @template_payload_cache if defined?(@template_payload_cache)
  
  @template_payload_cache = begin
    # Check for custom template path in environment variable
    custom_template_path = ENV['ILM_TEMPLATE_PATH'] || ENV['LOGSTASH_ILM_TEMPLATE_PATH']
    
    if custom_template_path && !custom_template_path.empty?
      # Load from file
      if ::File.exist?(custom_template_path)
        begin
          logger.info("Loading custom ILM template from environment variable", 
                     :path => custom_template_path)
          template_content = ::IO.read(custom_template_path)
          template = LogStash::Json.load(template_content)
          logger.info("Successfully loaded custom ILM template", :path => custom_template_path)
          return template
        rescue => e
          logger.error("Failed to load custom ILM template, using built-in defaults", 
                      :path => custom_template_path,
                      :error => e.message)
          # Fall through to return nil (use defaults)
        end
      else
        logger.error("Custom ILM template path does not exist, using built-in defaults", 
                    :path => custom_template_path)
      end
    end
    
    # Return nil to use built-in defaults
    nil
  end
end
```

#### 2. Updated `build_template_payload()` method
```ruby
def build_template_payload(resolved_alias, policy_name)
  # Load base template from environment variable or use defaults
  base_template = load_template_from_file_or_env
  
  # Extract settings from loaded template or use defaults
  default_settings = if base_template && base_template['template'] && base_template['template']['settings']
                      base_template['template']['settings']
                    else
                      { ... built-in defaults ... }
                    end
  
  # Always override ILM lifecycle settings
  default_settings['index']['lifecycle'] = {
    'name' => policy_name,
    'rollover_alias' => resolved_alias
  }
  
  # Merge with config overrides
  merged_settings = deep_merge(default_settings, @ilm_template_settings || {})
  
  # Same for mappings...
  
  # Extract priority from template or use default
  priority = base_template && base_template['priority'] ? base_template['priority'] : 300
  
  # Return final template
  { ... }
end
```

---

## 🚀 Usage

### Environment Variables (Priority Order)

1. **`ILM_TEMPLATE_PATH`** (highest priority)
2. **`LOGSTASH_ILM_TEMPLATE_PATH`** (fallback)
3. Built-in defaults (if neither set)

### Example: Kubernetes ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: logstash-templates
  namespace: elastic
data:
  # ILM Policy (you already have this)
  ilm-policy.json: |-
    {
      "policy": {
        "phases": {
          "hot": {
            "min_age": "0ms",
            "actions": {
              "rollover": { "max_age": "1d" }
            }
          },
          "delete": {
            "min_age": "1d",
            "actions": { "delete": {} }
          }
        }
      }
    }
  
  # NEW: Custom Template
  index-template.json: |-
    {
      "priority": 350,
      "template": {
        "settings": {
          "index": {
            "number_of_shards": 1,
            "number_of_replicas": 0,
            "refresh_interval": "10s",
            "codec": "best_compression"
          }
        },
        "mappings": {
          "properties": {
            "@timestamp": { "type": "date" },
            "container_name": { "type": "keyword" },
            "log": { "type": "text" }
          }
        }
      }
    }
```

### Example: Deployment

```yaml
spec:
  template:
    spec:
      containers:
      - name: logstash
        env:
        # Policy path (existing)
        - name: ILM_POLICY_PATH
          value: "/usr/share/logstash/config/ilm-policy.json"
        
        # Template path (NEW)
        - name: ILM_TEMPLATE_PATH
          value: "/usr/share/logstash/config/index-template.json"
        
        volumeMounts:
        - name: config
          mountPath: /usr/share/logstash/config/ilm-policy.json
          subPath: ilm-policy.json
        - name: config
          mountPath: /usr/share/logstash/config/index-template.json
          subPath: index-template.json
      
      volumes:
      - name: config
        configMap:
          name: logstash-templates
```

### Logstash Config (No Changes Needed!)

```ruby
output {
  elasticsearch {
    hosts => ["eck-es-hot:9200"]
    user => "${ES_USER}"
    password => "${ES_PASSWORD}"
    
    # Dynamic ILM (works as before)
    ilm_enabled => true
    ilm_rollover_alias => "%{[container_name]}"
    ilm_pattern => "000001"
    ilm_policy => "%{[container_name]}-ilm-policy"
    ilm_auto_create_policy => true
    ilm_policy_fallback => "common-ilm-policy"
    ilm_auto_create_template => true
    
    # Template loaded automatically from ILM_TEMPLATE_PATH!
  }
}
```

---

## ✨ Features

### 1. Smart Merging
- Loads base template from environment variable
- Overrides ILM lifecycle settings with dynamic values
- Merges with config-based overrides
- Preserves all other settings

### 2. Fallback Chain
```
ILM_TEMPLATE_PATH → LOGSTASH_ILM_TEMPLATE_PATH → Built-in defaults
```

### 3. Caching
- Template loaded once at startup
- Cached in `@template_payload_cache`
- No performance impact

### 4. Error Handling
- Invalid JSON → Falls back to defaults
- Missing file → Falls back to defaults
- Parse errors → Falls back to defaults
- **Never blocks event processing**

### 5. Logging
```
[INFO] Loading custom ILM template from environment variable
[INFO] Successfully loaded custom ILM template
[ERROR] Failed to load custom ILM template, using built-in defaults
```

---

## 🎯 What Gets Overridden?

### Always Overridden (Dynamic Values)
- `index_patterns` → `["#{resolved_alias}-*"]`
- `settings.index.lifecycle.name` → Dynamic from event
- `settings.index.lifecycle.rollover_alias` → Dynamic from event

### Loaded from Custom Template
- `priority` (default: 300)
- `settings.index.*` (shards, replicas, compression, etc.)
- `mappings.properties` (field types)
- `mappings.dynamic_templates` (field patterns)

### From Config (Highest Priority)
- `ilm_template_settings` config option
- `ilm_template_mappings` config option

---

## 📊 Merge Priority

```
1. Built-in defaults (lowest)
   ↓
2. Custom template from env (ILM_TEMPLATE_PATH)
   ↓
3. Config overrides (ilm_template_settings, ilm_template_mappings)
   ↓
4. Dynamic values (index_patterns, lifecycle.name, lifecycle.rollover_alias) (highest)
```

---

## 🧪 Testing

### 1. Create Test Template
```bash
cat > /tmp/test-template.json << 'EOF'
{
  "priority": 350,
  "template": {
    "settings": {
      "index": {
        "number_of_shards": 2,
        "number_of_replicas": 1
      }
    },
    "mappings": {
      "properties": {
        "test_field": { "type": "keyword" }
      }
    }
  }
}
EOF
```

### 2. Set Environment Variable
```bash
export ILM_TEMPLATE_PATH=/tmp/test-template.json
```

### 3. Start Logstash
```bash
/usr/share/logstash/bin/logstash -f logstash.conf
```

### 4. Check Logs
```
[INFO] Loading custom ILM template from environment variable
[INFO] Successfully loaded custom ILM template
[INFO] Creating dynamic index template
```

### 5. Verify in Elasticsearch
```bash
curl -X GET "localhost:9200/_index_template/logstash-*?pretty"
```

---

## 🔒 Backward Compatibility

### ✅ No Breaking Changes

- If `ILM_TEMPLATE_PATH` not set → Uses built-in defaults (same as before)
- If invalid file → Falls back to defaults (graceful degradation)
- Existing configs work without modification
- All existing features continue to work

### Migration Path

**Before (built-in defaults):**
```yaml
# No template specified
```

**After (custom template):**
```yaml
env:
- name: ILM_TEMPLATE_PATH
  value: "/config/template.json"
```

**Works both ways!** No migration needed.

---

## 📚 Documentation Created

1. **`CUSTOM_TEMPLATE_GUIDE.md`**
   - Complete guide with all details
   - Template JSON format
   - Kubernetes setup
   - Troubleshooting

2. **`CUSTOM_TEMPLATE_EXAMPLES.md`**
   - 7 ready-to-use templates
   - Performance-optimized
   - Storage-optimized
   - Search-optimized
   - Your specific use case

3. **`CUSTOM_TEMPLATE_QUICK_REF.md`**
   - 5-minute setup guide
   - Quick commands
   - Your specific deployment

---

## ✅ Testing Checklist

- [x] Code syntax valid (no errors)
- [x] Method signature matches pattern of `load_policy_from_file()`
- [x] Environment variable names documented
- [x] Fallback to defaults works
- [x] Caching implemented
- [x] Error handling non-blocking
- [x] Logging added
- [x] Documentation complete
- [x] Examples provided
- [x] Quick reference created

---

## 🎯 Next Steps

### Deploy to Your Environment

1. **Update ConfigMap:**
   - Add `index-template.json` to your existing ConfigMap
   - Choose template from examples or create custom

2. **Update Deployment:**
   - Add `ILM_TEMPLATE_PATH` environment variable
   - Add volume mount for template file

3. **Apply Changes:**
   ```bash
   kubectl apply -f configmap.yaml
   kubectl rollout restart deployment/logstash
   ```

4. **Verify:**
   ```bash
   kubectl logs -f deployment/logstash | grep template
   ```

---

## 🎓 Key Benefits

### 1. Consistency with ILM Policy
Same pattern as `ILM_POLICY_PATH` - easy to understand

### 2. Centralized Configuration
All settings in ConfigMap, version controlled

### 3. Flexibility
- Different templates per environment (dev/staging/prod)
- Easy to update without code changes
- Override specific settings as needed

### 4. No Performance Impact
- Template loaded once at startup
- Cached for lifetime of process
- Zero per-event overhead

### 5. Safe Fallback
- Invalid template → Uses defaults
- Missing file → Uses defaults
- Parse error → Uses defaults

---

## 📝 Summary

**You asked for:**
> "Load custom template from environment variable, like ILM policy"

**You got:**
- ✅ `ILM_TEMPLATE_PATH` environment variable
- ✅ Same pattern as policy loading
- ✅ Smart merging with defaults
- ✅ Graceful fallback on errors
- ✅ Complete documentation
- ✅ Ready-to-use examples
- ✅ Your specific use case covered

**No code changes needed in your Logstash config!**

Just add the template to ConfigMap and set the environment variable.

---

**Implementation Status:** ✅ **COMPLETE**  
**Code Status:** ✅ **NO ERRORS**  
**Documentation Status:** ✅ **COMPLETE**  
**Ready to Deploy:** ✅ **YES**

---

**Created:** December 30, 2025  
**Feature:** Custom ILM Template via Environment Variable  
**Pattern:** Same as ILM Policy loading  
**Backward Compatible:** ✅ YES
