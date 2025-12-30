# Visual Guide: Custom Template Loading

## 🎨 Complete Template Loading Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    TEMPLATE LOADING FLOW                                 │
└─────────────────────────────────────────────────────────────────────────┘

Logstash Starts
      ↓
┌─────────────────────────────────────┐
│ Check ILM_TEMPLATE_PATH             │
│ ENV['ILM_TEMPLATE_PATH']            │
└─────────────────────────────────────┘
      ↓
   Set? ──────┬────── No
      │       │
     Yes      ↓
      │  ┌─────────────────────────────────────┐
      │  │ Check LOGSTASH_ILM_TEMPLATE_PATH    │
      │  │ ENV['LOGSTASH_ILM_TEMPLATE_PATH']   │
      │  └─────────────────────────────────────┘
      │       ↓
      │    Set? ──────┬────── No
      │       │       │
      │      Yes      ↓
      │       │  ┌──────────────────────┐
      └───────┴─→│ File exists?         │
                 └──────────────────────┘
                        ↓
                   Exists? ──────┬────── No
                        │        │
                       Yes       ↓
                        │   [Use Built-in Defaults]
                        ↓
                 ┌──────────────────────┐
                 │ Read file content    │
                 │ IO.read(path)        │
                 └──────────────────────┘
                        ↓
                 ┌──────────────────────┐
                 │ Parse JSON           │
                 │ LogStash::Json.load  │
                 └──────────────────────┘
                        ↓
                   Valid? ──────┬────── No (parse error)
                        │       │
                       Yes      ↓
                        │  [Use Built-in Defaults]
                        ↓
                 ┌──────────────────────┐
                 │ Cache template       │
                 │ @template_payload_cache = template│
                 └──────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────────────────────┐
│                      TEMPLATE BUILDING PHASE                             │
└─────────────────────────────────────────────────────────────────────────┘
                        ↓
         ┌──────────────────────────────────┐
         │ Event arrives with container_name │
         │ { "container_name": "dotcms" }    │
         └──────────────────────────────────┘
                        ↓
         ┌──────────────────────────────────┐
         │ Resolve dynamic values            │
         │ - alias: "dotcms"                 │
         │ - policy: "dotcms-ilm-policy"     │
         └──────────────────────────────────┘
                        ↓
         ┌──────────────────────────────────┐
         │ Load cached template              │
         │ base_template = load_template...  │
         └──────────────────────────────────┘
                        ↓
              Template loaded? ──┬── No (nil)
                        │        │
                       Yes       ↓
                        │   ┌────────────────────────┐
                        │   │ Use built-in settings: │
                        │   │ - shards: 1            │
                        │   │ - replicas: 0          │
                        │   │ - refresh: 5s          │
                        │   └────────────────────────┘
                        ↓
         ┌──────────────────────────────────┐
         │ Extract settings from template    │
         │ default_settings = template[...]  │
         └──────────────────────────────────┘
                        ↓
         ┌──────────────────────────────────┐
         │ OVERRIDE ILM lifecycle settings   │
         │ lifecycle.name = "dotcms-ilm..."  │
         │ lifecycle.rollover_alias = "dotcms"│
         └──────────────────────────────────┘
                        ↓
         ┌──────────────────────────────────┐
         │ Merge with config overrides       │
         │ deep_merge(default, @ilm_template_settings)│
         └──────────────────────────────────┘
                        ↓
         ┌──────────────────────────────────┐
         │ Extract mappings from template    │
         │ default_mappings = template[...]  │
         └──────────────────────────────────┘
                        ↓
         ┌──────────────────────────────────┐
         │ Merge with config overrides       │
         │ deep_merge(default, @ilm_template_mappings)│
         └──────────────────────────────────┘
                        ↓
         ┌──────────────────────────────────┐
         │ Generate index_patterns           │
         │ ["dotcms-*"]                      │
         └──────────────────────────────────┘
                        ↓
         ┌──────────────────────────────────┐
         │ Build final template payload      │
         │ {                                 │
         │   "index_patterns": ["dotcms-*"], │
         │   "template": {                   │
         │     "settings": merged_settings,  │
         │     "mappings": merged_mappings   │
         │   },                              │
         │   "priority": 300                 │
         │ }                                 │
         └──────────────────────────────────┘
                        ↓
         ┌──────────────────────────────────┐
         │ Create template in Elasticsearch  │
         │ PUT _index_template/logstash-dotcms│
         └──────────────────────────────────┘
                        ↓
                    ✅ Done!
```

---

## 📋 Configuration Sources Priority

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    MERGE PRIORITY (Low → High)                           │
└─────────────────────────────────────────────────────────────────────────┘

1. Built-in Defaults (Lowest Priority)
   ┌──────────────────────────────────────┐
   │ {                                    │
   │   "settings": {                      │
   │     "number_of_shards": 1,           │
   │     "number_of_replicas": 0,         │
   │     "refresh_interval": "5s"         │
   │   }                                  │
   │ }                                    │
   └──────────────────────────────────────┘
               ↓ Overridden by
   
2. Custom Template (ILM_TEMPLATE_PATH)
   ┌──────────────────────────────────────┐
   │ {                                    │
   │   "settings": {                      │
   │     "number_of_shards": 2,     ←---- OVERRIDE
   │     "codec": "best_compression" ←--- NEW
   │   }                                  │
   │ }                                    │
   └──────────────────────────────────────┘
               ↓ Overridden by

3. Config Overrides (ilm_template_settings)
   ┌──────────────────────────────────────┐
   │ ilm_template_settings => {           │
   │   "index" => {                       │
   │     "number_of_shards" => 3    ←---- OVERRIDE
   │   }                                  │
   │ }                                    │
   └──────────────────────────────────────┘
               ↓ Always overridden by

4. Dynamic Values (Highest Priority)
   ┌──────────────────────────────────────┐
   │ {                                    │
   │   "lifecycle": {                     │
   │     "name": "dotcms-ilm-policy", ←-- ALWAYS SET
   │     "rollover_alias": "dotcms"    ←- ALWAYS SET
   │   }                                  │
   │ }                                    │
   └──────────────────────────────────────┘

Final Result:
┌──────────────────────────────────────┐
│ {                                    │
│   "number_of_shards": 3,             │ ← From config
│   "codec": "best_compression",       │ ← From custom template
│   "refresh_interval": "5s",          │ ← From defaults
│   "lifecycle": {                     │
│     "name": "dotcms-ilm-policy",     │ ← Dynamic (always)
│     "rollover_alias": "dotcms"       │ ← Dynamic (always)
│   }                                  │
│ }                                    │
└──────────────────────────────────────┘
```

---

## 🎯 Your Deployment: Before vs After

### BEFORE (Built-in Defaults Only)

```
Kubernetes ConfigMap
┌────────────────────────────┐
│ data:                      │
│   ilm-policy.json: |       │  ← ILM policy
│     { ... }                │
│                            │
│   logstash.conf: |         │  ← Pipeline
│     output { ... }         │
└────────────────────────────┘
         ↓
Logstash Deployment
┌────────────────────────────┐
│ env:                       │
│ - ILM_POLICY_PATH: /...    │  ← Policy path only
│                            │
│ volumeMounts:              │
│ - /config/ilm-policy.json  │  ← Policy mount only
└────────────────────────────┘
         ↓
Result: Uses built-in template defaults
```

### AFTER (Custom Template)

```
Kubernetes ConfigMap
┌────────────────────────────┐
│ data:                      │
│   ilm-policy.json: |       │  ← ILM policy
│     { ... }                │
│                            │
│   index-template.json: |   │  ← ✨ NEW: Template
│     {                      │
│       "priority": 350,     │
│       "template": { ... }  │
│     }                      │
│                            │
│   logstash.conf: |         │  ← Pipeline
│     output { ... }         │
└────────────────────────────┘
         ↓
Logstash Deployment
┌────────────────────────────┐
│ env:                       │
│ - ILM_POLICY_PATH: /...    │  ← Policy path
│ - ILM_TEMPLATE_PATH: /...  │  ← ✨ NEW: Template path
│                            │
│ volumeMounts:              │
│ - /config/ilm-policy.json  │  ← Policy mount
│ - /config/index-template.json│ ← ✨ NEW: Template mount
└────────────────────────────┘
         ↓
Result: Uses your custom template!
```

---

## 🔍 Error Handling Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         ERROR SCENARIOS                                  │
└─────────────────────────────────────────────────────────────────────────┘

Scenario 1: File Not Found
   ILM_TEMPLATE_PATH set → File missing
                ↓
   [ERROR] Custom ILM template path does not exist
   [INFO] Using built-in defaults
                ↓
   Continue with defaults ✅

Scenario 2: Invalid JSON
   ILM_TEMPLATE_PATH set → File exists → Parse fails
                ↓
   [ERROR] Failed to load custom ILM template
   [ERROR] ... JSON parse error ...
   [INFO] Using built-in defaults
                ↓
   Continue with defaults ✅

Scenario 3: Missing Fields
   Template loaded → Missing 'template' key
                ↓
   Template considered invalid
                ↓
   Use built-in defaults ✅

Scenario 4: Environment Variable Not Set
   ILM_TEMPLATE_PATH not set
   LOGSTASH_ILM_TEMPLATE_PATH not set
                ↓
   [INFO] No custom template specified
                ↓
   Use built-in defaults ✅

All errors are NON-BLOCKING! ✅
Events continue to process even if template load fails!
```

---

## 📊 Comparison: Policy vs Template Loading

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    POLICY vs TEMPLATE LOADING                            │
├────────────────────────────────┬────────────────────────────────────────┤
│ ILM POLICY                     │ INDEX TEMPLATE                         │
├────────────────────────────────┼────────────────────────────────────────┤
│ ILM_POLICY_PATH                │ ILM_TEMPLATE_PATH                      │
│ LOGSTASH_ILM_POLICY_PATH       │ LOGSTASH_ILM_TEMPLATE_PATH             │
├────────────────────────────────┼────────────────────────────────────────┤
│ load_policy_from_file()        │ load_template_from_file_or_env()       │
├────────────────────────────────┼────────────────────────────────────────┤
│ @policy_payload_cache          │ @template_payload_cache                │
├────────────────────────────────┼────────────────────────────────────────┤
│ Used for ILM lifecycle         │ Used for index structure               │
│ (hot, warm, cold, delete)      │ (shards, replicas, mappings)           │
├────────────────────────────────┼────────────────────────────────────────┤
│ Fallback: default-ilm-policy   │ Fallback: built-in defaults            │
├────────────────────────────────┼────────────────────────────────────────┤
│ Error: Fall back to default    │ Error: Fall back to defaults           │
├────────────────────────────────┼────────────────────────────────────────┤
│ Non-blocking ✅                 │ Non-blocking ✅                         │
└────────────────────────────────┴────────────────────────────────────────┘

Same pattern, consistent behavior! 🎯
```

---

## 🚀 Quick Start Visual

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     3 STEPS TO CUSTOM TEMPLATE                           │
└─────────────────────────────────────────────────────────────────────────┘

Step 1: Create template.json
┌────────────────────────────────┐
│ {                              │
│   "priority": 350,             │
│   "template": {                │
│     "settings": { ... },       │
│     "mappings": { ... }        │
│   }                            │
│ }                              │
└────────────────────────────────┘

Step 2: Add to ConfigMap
┌────────────────────────────────┐
│ data:                          │
│   index-template.json: |-      │
│     { ... }                    │
└────────────────────────────────┘

Step 3: Set Environment Variable
┌────────────────────────────────┐
│ env:                           │
│ - name: ILM_TEMPLATE_PATH      │
│   value: /config/template.json │
└────────────────────────────────┘

Done! ✅
```

---

## 💡 Key Takeaways

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 1. Same pattern as ILM_POLICY_PATH ✅                                    │
│                                                                          │
│ 2. Environment variable based (ILM_TEMPLATE_PATH) ✅                     │
│                                                                          │
│ 3. Falls back to built-in defaults gracefully ✅                         │
│                                                                          │
│ 4. Smart merging with config overrides ✅                                │
│                                                                          │
│ 5. Always overrides ILM lifecycle settings ✅                            │
│                                                                          │
│ 6. Non-blocking error handling ✅                                        │
│                                                                          │
│ 7. Cached for performance ✅                                             │
│                                                                          │
│ 8. No code changes in pipeline config ✅                                 │
└─────────────────────────────────────────────────────────────────────────┘
```

---

**Created:** December 30, 2025  
**Purpose:** Visual guide for custom template loading feature  
**Status:** ✅ Implementation Complete
