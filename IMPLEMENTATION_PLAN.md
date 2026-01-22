# Statistical Anomaly Detection Implementation Plan

## Overview

Implement a self-learning anomaly detection system using pure Elixir statistical methods (z-scores, percentiles, exponential moving averages) with **runtime-passable configuration** via the supervision tree.

## Architecture Design

### 1. Monitor Skill (Beamlens.Skill.Monitor)

Implements the `Beamlens.Skill` behaviour with callbacks for accessing anomaly detection status.

**Callbacks:**
- `monitor_anomalies()` - Returns current detected anomalies
- `monitor_baselines()` - Returns learned baselines for all metrics
- `monitor_status()` - Returns detector state (learning, active, cooldown)

**Integration:**
- Optional skill, added to supervision tree when enabled
- Passes configuration to child GenServers at startup
- Reads from Detector and BaselineStore GenServers

### 2. Detector GenServer (Beamlens.Skill.Monitor.Detector)

Coordinates the collection and analysis loop. State machine with three states:

**States:**
- `:learning` - Collecting baseline data during learning period
- `:active` - Actively detecting anomalies using learned baselines
- `:cooldown` - Waiting after escalation before resuming detection

**Responsibilities:**
- Periodic collection loop (configurable interval)
- Calls skill snapshots to gather metrics
- Stores metrics in MetricStore
- Analyzes metrics using statistical functions
- Manages state transitions (learning → active → cooldown → active)
- Escalates to Coordinator when anomalies detected

**Configuration (passed via start_link opts):**
```elixir
[
  collection_interval_ms: 30_000,
  learning_duration_ms: :timer.hours(2),
  z_threshold: 3.0,
  consecutive_required: 3,
  cooldown_ms: :timer.minutes(15),
  metric_store: MetricStore_pid,
  baseline_store: BaselineStore_pid
]
```

### 3. MetricStore GenServer (Beamlens.Skill.Monitor.MetricStore)

ETS ring buffer for time-series metric data.

**Storage:**
- ETS table (`:set`) for efficient lookups
- Ring buffer using `:queue` for time-ordered samples
- Configurable history window

**Data Structure:**
```elixir
%{
  timestamp: integer,  # Unix ms
  skill: atom,         # :beam, :ets, :system, etc.
  metric: atom,        # :memory_mb, :total_memory_mb, :table_count, etc.
  value: float
}
```

**API:**
- `add_sample(skill, metric, value)` - Add a metric sample
- `get_samples(skill, metric, since_ms)` - Get samples since timestamp
- `get_latest(skill, metric)` - Get most recent sample
- `clear(skill, metric)` - Clear samples for specific metric

**Configuration:**
```elixir
[
  history_minutes: 60,  # Keep 60 minutes of data
  sample_interval_ms: 30_000  # Expected sampling rate for size calculation
]
```

### 4. BaselineStore GenServer (Beamlens.Skill.Monitor.BaselineStore)

DETS disk-backed storage + ETS cache for learned baselines.

**Storage Strategy:**
- DETS for persistent storage (survives restarts)
- ETS table (`:set`) for fast read access
- Async writes to DETS (non-blocking)

**Data Structure:**
```elixir
%{
  skill: atom,
  metric: atom,
  mean: float,
  std_dev: float,
  percentile_50: float,
  percentile_95: float,
  percentile_99: float,
  sample_count: integer,
  last_updated: integer  # Unix ms
}
```

**API:**
- `get_baseline(skill, metric)` - Get baseline from ETS cache
- `update_baseline(skill, metric, samples)` - Calculate and store baseline
- `rebaseline(skill, metric)` - Force recalculation from MetricStore
- `clear(skill, metric)` - Clear baseline

**Baseline Calculation:**
- Pure statistical functions (Statistics module)
- Calculate mean, std_dev, percentiles from samples
- Update ETS cache immediately
- Async write to DETS

**Configuration:**
```elixir
[
  dets_file: "priv/beamlens_baselines.dets",
  ets_table: :beamlens_baselines,
  auto_save_interval_ms: :timer.minutes(5)
]
```

### 5. Statistical Functions (Beamlens.Skill.Monitor.Statistics)

Pure functions for statistical analysis.

**Functions:**
- `mean(samples)` - Arithmetic mean
- `std_dev(samples, mean)` - Population standard deviation
- `z_score(value, mean, std_dev)` - Z-score calculation
- `percentile(samples, p)` - Nth percentile (0-100)
- `ema(samples, alpha)` - Exponential moving average

**Detection Functions:**
- `detect_anomaly(value, baseline, z_threshold)` - Returns true if |z_score| > threshold
- `calculate_baseline(samples)` - Returns baseline map with all statistics

### 6. Monitor Supervisor (Beamlens.Skill.Monitor.Supervisor)

Dynamic supervisor for Monitor components.

**Children (started in order):**
1. MetricStore
2. BaselineStore
3. Detector

**Configuration Flow:**
```elixir
# In Beamlens.Supervisor
def monitor_child(skills) do
  if Beamlens.Skill.Monitor in skills do
    monitor_opts = Application.get_env(:beamlens, :monitor, [])

    [
      {Beamlens.Skill.Monitor.Supervisor, monitor_opts}
    ]
  else
    []
  end
end

# Monitor Supervisor passes opts to children
def init(opts) do
  children = [
    {Beamlens.Skill.Monitor.MetricStore, opts},
    {Beamlens.Skill.Monitor.BaselineStore, opts},
    {Beamlens.Skill.Monitor.Detector, opts}
  ]

  Supervisor.init(children, strategy: :one_for_one)
end
```

## Implementation Order

### Phase 1: Foundation (No persistence yet)
1. Create `Statistics` module with pure functions
2. Create `MetricStore` GenServer with ETS ring buffer
3. Write tests for Statistics and MetricStore

### Phase 2: Baseline Learning
4. Create `BaselineStore` GenServer with ETS only (no DETS yet)
5. Create `Detector` GenServer with learning state
6. Implement collection loop (read-only snapshots)
7. Implement baseline calculation from MetricStore data
8. Write tests for learning workflow

### Phase 3: Anomaly Detection
9. Implement active detection state in Detector
10. Add z-score anomaly detection
11. Add consecutive anomaly counting
12. Implement cooldown state machine
13. Write tests for detection workflow

### Phase 4: Persistence
14. Add DETS storage to BaselineStore
15. Load baselines from DETS on startup
16. Implement async DETS writes
17. Write tests for persistence

### Phase 5: Integration
18. Create `Monitor` skill module
19. Implement skill callbacks (snapshots, docs)
20. Add Monitor to Beamlens.Supervisor
21. Add Coordinator escalation on anomaly detection
22. Write integration tests

### Phase 6: Polish
23. Run full test suite
24. Update CHANGELOG.md
25. Verify zero production impact

## Runtime Configuration Design

**User's Application:**
```elixir
defmodule MyApp.Application do
  def start(_type, _args) do
    monitor_opts = [
      enabled: true,
      collection_interval_ms: :timer.seconds(30),
      learning_duration_ms: :timer.hours(2),
      z_threshold: 3.0,
      consecutive_required: 3,
      cooldown_ms: :timer.minutes(15),
      history_minutes: 60
    ]

    children = [
      {Beamlens,
       skills: [Beamlens.Skill.Beam, Beamlens.Skill.Monitor],
       monitor: monitor_opts}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

**Beamlens.Supervisor extracts and passes to Monitor.Supervisor:**
```elixir
def init(opts) do
  skills = Keyword.get(opts, :skills, [])
  monitor_opts = Keyword.get(opts, :monitor, [])

  children = [
    # ... other children ...
    monitor_child(skills, monitor_opts)
  ]
end

defp monitor_child(skills, monitor_opts) do
  if Beamlens.Skill.Monitor in skills do
    enabled = Keyword.get(monitor_opts, :enabled, false)

    if enabled do
      [{Beamlens.Skill.Monitor.Supervisor, monitor_opts}]
    else
      []
    end
  else
    []
  end
end
```

## Key Design Decisions

### 1. Runtime Configuration via Supervision Tree
✅ Configuration passed as opts to `start_link`
✅ Each child GenServer extracts relevant opts
✅ No compile-time config dependencies
✅ Multiple instances possible with different configs

### 2. ETS Ring Buffer for Metrics
✅ Efficient time-series storage
✅ Automatic cleanup of old data
✅ Fast queries for baseline calculation
✅ ~5MB memory footprint (24h @ 30s, 7 skills × 5 metrics)

### 3. DETS for Baseline Persistence
✅ Survives application restarts
✅ Avoids re-learning on every deploy
✅ Async writes = non-blocking
✅ ETS cache for fast reads

### 4. Pure Statistical Functions
✅ No ML dependencies
✅ Easy to test
✅ Z-scores, percentiles, EMA
✅ Standard statistical methods

### 5. State Machine for Detector
✅ Learning period builds baselines
✅ Active detection with z-scores
✅ Cooldown prevents alert spam
✅ Continuous learning with EMA updates

### 6. Zero Production Impact
✅ All reads from existing skill snapshots
✅ Async DETS writes
✅ Optional feature (opt-in)
✅ Minimal memory footprint

## Testing Strategy

### Unit Tests
- Statistics module: pure functions
- MetricStore: ETS operations, ring buffer logic
- BaselineStore: baseline calculation, ETS/DETS operations
- Detector state machine: learning, active, cooldown transitions

### Integration Tests
- Full learning workflow
- Anomaly detection with Coordinator escalation
- Persistence across restarts
- Multiple skill monitoring

### Test Data
- Deterministic test fixtures
- No Process.sleep (use deterministic timing)
- Mock time if needed (via System time stubbing)

## Complexity Estimate

12-16 hours total:
- Phase 1 (Foundation): 2-3 hours
- Phase 2 (Baseline Learning): 3-4 hours
- Phase 3 (Anomaly Detection): 3-4 hours
- Phase 4 (Persistence): 1-2 hours
- Phase 5 (Integration): 2-2 hours
- Phase 6 (Polish): 1-1 hours

## Success Criteria

✅ Configuration passable at runtime via supervision tree
✅ Learns deployment-specific baselines
✅ Detects anomalies using z-scores
✅ Escalates to Coordinator
✅ Survives restarts (DETS persistence)
✅ Zero production impact
✅ All tests pass
✅ CHANGELOG.md updated
