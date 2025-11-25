# Quick Reference: When Does the Error Happen?

## Original Problem (Before Fix)

```
┌─────────────────────────────────────────────────────────────┐
│ Event 1: container_name = "erma-connector-fb"              │
│   ❌ Cache Miss                                             │
│   ❌ Policy "erma-connector-fb-ilm-policy" doesn't exist    │
│   ❌ ERROR THROWN                                           │
│   ❌ NOT CACHED (due to error)                              │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ Event 2: container_name = "erma-connector-fb"              │
│   ❌ Cache Miss (never was cached)                          │
│   ❌ Policy still doesn't exist                             │
│   ❌ ERROR THROWN AGAIN                                     │
│   ❌ NOT CACHED (due to error)                              │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ Event 3, 4, 5... (Same container)                          │
│   🔄 INFINITE LOOP OF ERRORS                                │
│   Every event checks → Fails → Not cached → Repeat         │
└─────────────────────────────────────────────────────────────┘
```

## After Fix (With `ilm_auto_create_policy => true`)

```
┌─────────────────────────────────────────────────────────────┐
│ Event 1: container_name = "erma-connector-fb"              │
│   ❌ Cache Miss                                             │
│   ❌ Policy "erma-connector-fb-ilm-policy" doesn't exist    │
│   ✅ AUTO-CREATE POLICY (uses default-ilm-policy.json)      │
│   ✅ Create rollover alias "erma-connector-fb"              │
│   ✅ CACHED: "erma-connector-fb:erma-connector-fb-ilm-policy"│
│   ⏱️  Time: ~100-200ms (one-time cost)                     │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ Event 2: container_name = "erma-connector-fb"              │
│   ✅ Cache Hit! (found in @dynamic_ilm_aliases_created)     │
│   ✅ Skip all validation and creation                       │
│   ✅ SUCCESS                                                 │
│   ⏱️  Time: <1ms (hash lookup only)                        │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ Events 3, 4, 5... 1000... (Same container)                 │
│   ✅ Cache Hit!                                              │
│   ✅ All future events are fast                             │
│   ⏱️  Time: <1ms per event                                 │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ Event N: container_name = "NEW-SERVICE"                    │
│   ❌ Cache Miss (new container)                             │
│   ✅ Auto-create policy for new service                     │
│   ✅ Create rollover alias                                  │
│   ✅ CACHED                                                  │
│   ⏱️  Time: ~100-200ms (one-time cost for new service)     │
└─────────────────────────────────────────────────────────────┘
```

## Key Points

### Cache Behavior
- **Cache Key**: `"{alias}:{policy}"` 
  - Example: `"erma-connector-fb:erma-connector-fb-ilm-policy"`
- **Storage**: Ruby `Set` in `@dynamic_ilm_aliases_created`
- **Scope**: Per Logstash output plugin instance
- **Persistence**: In-memory only (cleared on restart)

### When Validation Happens
✅ **Only on Cache Miss**:
1. First event for a new container name
2. After Logstash restart (cache cleared)
3. Never for cached aliases

❌ **Never on Cache Hit**:
- No policy check
- No alias check
- No API calls to Elasticsearch
- Just a fast hash lookup

### Performance by Event Type

| Event Type | Cache Status | Operations | Time |
|------------|--------------|------------|------|
| First event (new container) | Miss | Check policy → Create policy → Create alias → Cache | ~100-200ms |
| Subsequent events (same container) | Hit | Hash lookup only | <1ms |
| Different container (first time) | Miss | Check policy → Create policy → Create alias → Cache | ~100-200ms |
| Different container (subsequent) | Hit | Hash lookup only | <1ms |

### Example Timeline

```
Time | Event | Container | Cache | Action | Duration
-----|-------|-----------|-------|--------|----------
0ms  | #1    | fb        | Miss  | Create policy + alias | 150ms
150ms| #2    | fb        | HIT ✅ | None | 0.5ms
151ms| #3    | fb        | HIT ✅ | None | 0.5ms
152ms| #4    | templates | Miss  | Create policy + alias | 120ms
272ms| #5    | fb        | HIT ✅ | None | 0.5ms
273ms| #6    | templates | HIT ✅ | None | 0.5ms
274ms| #7    | fb        | HIT ✅ | None | 0.5ms
```

### With 3 Unique Containers Processing 10,000 Events

```
Total Events: 10,000
Unique Containers: 3

Cache Misses: 3 (one per container)
Cache Hits: 9,997

Total overhead:
- Cache miss operations: 3 × 150ms = 450ms
- Cache hit operations: 9,997 × 0.5ms = ~5 seconds
- Total: ~5.5 seconds for 10,000 events
- Average: 0.55ms per event

Compare to original (checking every event):
- 10,000 × 50ms (API call) = 500 seconds!
- Improvement: 100x faster!
```

## Configuration Impact

### Option 1: Auto-Create (Default)
```ruby
ilm_auto_create_policy => true
```
- ✅ Zero manual intervention
- ✅ New services work automatically
- ⚠️  All services use same retention (from default policy)
- ✅ Can customize policies after creation

### Option 2: Manual Control
```ruby
ilm_auto_create_policy => false
```
- ❌ Events fail until policies created
- ✅ Full control over each policy
- ✅ Custom retention per service
- ⚠️  Operational overhead

### Option 3: Common Policy
```ruby
ilm_policy => "common-ilm-policy"  # No sprintf
```
- ✅ No auto-creation needed
- ✅ Policy already exists
- ✅ Simplest management
- ⚠️  Same retention for all

## Monitoring

### Watch for Policy Creations
```bash
# Check Logstash logs
grep "Creating missing ILM policy" logstash.log
```

### Check Cache Size
```ruby
# In Ruby code
@dynamic_ilm_aliases_created.size
# Returns number of unique alias:policy combinations cached
```

### Verify Policy Exists
```bash
GET _ilm/policy/erma-connector-fb-ilm-policy
```

### Verify Alias Created
```bash
GET _alias/erma-connector-fb
```

### Check Index Settings
```bash
GET erma-connector-fb-*/_settings

# Should return:
{
  "erma-connector-fb-000001": {
    "settings": {
      "index": {
        "lifecycle": {
          "name": "erma-connector-fb-ilm-policy",
          "rollover_alias": "erma-connector-fb"
        }
      }
    }
  }
}
```
