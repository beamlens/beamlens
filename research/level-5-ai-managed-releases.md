# Level 5 AI-Managed Releases

Research into enabling "Dark Factory" style deployments where AI autonomously manages the release process—rolling out changes and rolling them back when issues are detected—without human code review.

## Background

Dan Shapiro's [Five Levels](https://simonwillison.net/2026/Jan/28/the-five-levels/) model describes progression from "spicy autocomplete" to fully autonomous software factories:

1. **Spicy autocomplete** - GitHub Copilot, copy/paste from ChatGPT
2. **Coding intern** - Unimportant snippets with full human review
3. **Junior developer** - Pair programming, reviewing every line
4. **Developer** - Most code AI-generated, human as full-time reviewer
5. **Engineering team** - Human as PM/manager, agents do the work
6. **Dark factory** - Black box that turns specs into software

Key characteristics of Level 5 teams (per Simon Willison):

> - Nobody reviews AI-produced code, ever. They don't even look at it.
> - The goal of the system is to prove that the system works. A huge amount of the coding agent work goes into testing and tooling and simulating related systems and running demos.
> - The role of the humans is to design that system - to find new patterns that can help the agents work more effectively and demonstrate that the software they are building is robust and effective.

## Why BEAM is Uniquely Suited

The BEAM has capabilities other runtimes don't:

| Capability | How It Enables Level 5 |
|------------|------------------------|
| **Hot code loading** | Update modules without restarts |
| **Process isolation** | New code runs in new processes; old continues |
| **Supervision trees** | Crash isolation + automatic restart |
| **`:sys` introspection** | Real-time process health observation |
| **Distributed Erlang** | Cluster-wide coordination |
| **Two-version code loading** | Old and new code coexist briefly |

## Architecture: Beamlens as Production Gate

```
┌─────────────────────────────────────────────────────────────────┐
│                    AI Code Generation Pipeline                   │
│  (Spec → Code → Tests → Simulations → Release Artifact)         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     PRODUCTION CLUSTER                           │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                    Beamlens Coordinator                      │ │
│  │   • Pre-flight baseline capture                              │ │
│  │   • Anomaly detection during rollout                        │ │
│  │   • Rollback trigger if issues detected                     │ │
│  │   • Proof generation ("system is healthy")                  │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                              │                                    │
│          ┌───────────────────┼───────────────────┐               │
│          ▼                   ▼                   ▼               │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐        │
│  │  Operator   │     │  Operator   │     │  Operator   │        │
│  │   (Beam)    │     │  (Logger)   │     │ (Exception) │        │
│  │ Memory/CPU  │     │ Error rates │     │  Crashes    │        │
│  └─────────────┘     └─────────────┘     └─────────────┘        │
│                                                                   │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐         │
│  │  Node 1  │  │  Node 2  │  │  Node 3  │  │  Node N  │         │
│  │ (canary) │  │ (stable) │  │ (stable) │  │ (stable) │         │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘         │
└─────────────────────────────────────────────────────────────────┘
```

### Deployment Flow

**Phase 1: Pre-flight Baseline**
- Beamlens captures current health across all 12 skills
- Anomaly detector's learned baselines serve as reference
- LLM assesses: "Is the system stable enough for deployment?"

**Phase 2: Canary Deploy (Process-Level, Not Node-Level)**
- Hot-load new code to a subset of processes, not entire nodes
- BEAM's two-version code loading allows old/new coexistence
- New requests route to new-code processes; existing requests complete on old

**Phase 3: LLM-Driven Observation Window**
- Beamlens operators actively monitor for:
  - Error rate deviation (Logger skill)
  - Memory pattern changes (Beam, ETS, Allocator skills)
  - Exception spikes (Exception skill)
  - Scheduler contention (Beam skill)
  - Baseline anomalies (Anomaly skill)
- Coordinator correlates across operators
- Decision: **expand** or **rollback**

**Phase 4: Automatic Rollback (if needed)**
- `:code.soft_purge/1` + `:code.load_file/1` to restore old module
- Or: `release_handler:install_release(OldVsn)` for full release rollback
- Beamlens confirms health restored

## Limitations: When Level 5 Won't Work

Hot code loading has significant constraints:

| Change Type | Auto-Deploy Safe? | Why |
|-------------|-------------------|-----|
| Pure function changes | ✅ Yes | No state involved |
| Stateless module changes | ✅ Yes | No coordination needed |
| New feature (additive) | ✅ Yes | Backward compatible |
| Bug fixes (same interface) | ✅ Yes | Drop-in replacement |
| GenServer logic (same state) | ✅ Yes | State shape unchanged |
| GenServer state shape change | ❌ No | Requires code_change/3, rollback lossy |
| Database schema change | ❌ No | Old/new code can't share DB |
| Message protocol change | ❌ No | Process communication breaks |
| Supervision tree change | ❌ No | Requires restart |
| Config changes | ❌ No | Read at startup |
| NIF changes | ❌ No | Loaded once per VM |
| Dependency upgrades | ❌ No | Affects all code atomically |

**Realistic estimate**: ~60-70% of typical application changes are safe for Level 5 auto-deploy.

## Patterns to Enable Level 5 for Hard Cases

### Pattern 1: Expand-Contract for Schema Migrations

Separate schema change from code change into multiple atomic deploys:

```
Traditional (breaks Level 5):
  Deploy 1: Migration + Code change (atomic, rollback impossible)

Expand-Contract (enables Level 5):
  Deploy 1: EXPAND   - Add new column (code ignores it)
  Deploy 2: MIGRATE  - Code writes to both old + new
  Deploy 3: BACKFILL - Data migration script
  Deploy 4: SWITCH   - Code reads from new, writes to new
  Deploy 5: CONTRACT - Remove old column

  Each deploy is independently rollback-able!
```

**Example: Renaming `name` to `first_name` + `last_name`**

```elixir
# Deploy 1: EXPAND - Add columns, code unchanged
defmodule AddNameColumns do
  def change do
    alter table(:users) do
      add :first_name, :string
      add :last_name, :string
    end
  end
end
# Rollback: safe, just removes empty columns

# Deploy 2: MIGRATE - Write to both
defmodule User do
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :first_name, :last_name])
    |> sync_name_fields()  # Writes to both old and new
  end
end
# Rollback: safe, old code just ignores new columns

# Deploy 3: BACKFILL - Data migration (can run async)
# Deploy 4: SWITCH - Read from new columns
# Deploy 5: CONTRACT - Remove old column
```

### Pattern 2: Versioned State for GenServers

Version your state and keep it backward-compatible:

```elixir
defmodule MyApp.Counter do
  use GenServer

  @state_version 2

  defstruct [:version, :count, :last_updated, :metadata]

  def init(_) do
    {:ok, %__MODULE__{
      version: @state_version,
      count: 0,
      last_updated: DateTime.utc_now(),
      metadata: %{}
    }}
  end

  def code_change(_old_vsn, state, _extra) do
    {:ok, migrate_state(state)}
  end

  # Migrations are additive, never destructive
  defp migrate_state(%{version: 1} = state) do
    state
    |> Map.put(:last_updated, DateTime.utc_now())
    |> Map.put(:version, 2)
    |> migrate_state()
  end

  defp migrate_state(%{version: 2} = state), do: state

  # Handle old state shapes gracefully (lazy migration)
  def handle_call(:get, _from, state) do
    state = migrate_state(state)
    {:reply, state.count, state}
  end
end
```

**Key principles:**
- Never remove fields - mark deprecated, ignore them
- Version tag in state - always know what shape you have
- Additive migrations - new fields get defaults
- Lazy migration - upgrade on access, not just in code_change

**Rollback works because:** Old code ignores extra fields. New code migrates old state on access.

### Pattern 3: Protocol Versioning for Messages

Version messages and handle multiple versions:

```elixir
defmodule MyApp.Worker do
  use GenServer

  # Handle both old and new message formats
  def handle_cast({:update, value}, state) do
    # V1 format - still supported
    do_update(value, %{}, state)
  end

  def handle_cast({:update, 2, value, metadata}, state) do
    # V2 format - current
    do_update(value, metadata, state)
  end

  defp do_update(value, metadata, state) do
    {:noreply, %{state | value: value, metadata: metadata}}
  end
end
```

**Rollback works because:** Both old and new code handle both message formats.

### Pattern 4: Graceful Handoff for Supervision Tree Changes

Design for handoff from the start:

```elixir
defmodule MyApp.Worker do
  use GenServer

  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    Registry.register(MyApp.WorkerRegistry, id, self())

    # Check for handoff from previous incarnation
    state = case :persistent_term.get({:worker_handoff, id}, nil) do
      nil -> initial_state(opts)
      handed_off ->
        :persistent_term.erase({:worker_handoff, id})
        handed_off
    end

    {:ok, state}
  end

  def terminate(:shutdown, state) do
    :persistent_term.put({:worker_handoff, state.id}, state)
    :ok
  end
end
```

**For tree restructuring, use multi-step deploys:**
1. Add new supervisor alongside old (both run)
2. New code starts children under new supervisor
3. Graceful shutdown of old supervisor (children hand off)
4. Remove old supervisor code

## Integration with fly_deploy

[fly_deploy](https://github.com/chrismccord/fly_deploy) provides hot code upgrades for Elixir on Fly.io:

| fly_deploy Feature | Level 5 Application |
|-------------------|---------------------|
| Suspend ALL before loading ANY | Prevents partial-upgrade races |
| `:sys.change_code/4` for state migration | Versioned state pattern |
| `startup_reapply_current/1` | Consistency after restarts |
| Forward-only (no rollback) | Must design rollback into patterns |
| Tarball distribution | Cluster-wide coordination |

**Gap fly_deploy doesn't fill:**
- No health observation during/after deploy
- No automatic rollback decision
- No multi-step deployment orchestration

**What beamlens adds:**
- Health observation before, during, after
- LLM-driven rollback decisions
- Multi-step expand-contract orchestration

## Proposed: Beamlens Release Skill

```elixir
defmodule Beamlens.Skill.Release do
  @moduledoc """
  Orchestrates deployments with health gates.
  """

  def callbacks do
    %{
      "capture_baseline" => &capture_baseline/1,
      "deploy_migration" => &deploy_migration/1,
      "hot_load_modules" => &hot_load_modules/1,
      "compare_to_baseline" => &compare_to_baseline/1,
      "rollback_migration" => &rollback_migration/1,
      "rollback_modules" => &rollback_modules/1,
      "get_cluster_versions" => &get_cluster_versions/1
    }
  end

  defp capture_baseline(_args) do
    %{
      timestamp: DateTime.utc_now(),
      memory: :erlang.memory(),
      error_rate: Beamlens.Skill.Logger.error_rate(),
      process_count: :erlang.system_info(:process_count)
    }
  end

  defp hot_load_modules(%{"modules" => modules, "tarball_url" => url}) do
    # fly_deploy style: suspend -> load -> code_change -> resume
    with {:ok, beam_files} <- download_and_extract(url),
         :ok <- suspend_affected_processes(modules),
         :ok <- load_modules(beam_files),
         :ok <- trigger_code_change(modules),
         :ok <- resume_processes(modules) do
      {:ok, %{loaded: modules}}
    end
  end

  defp compare_to_baseline(%{"baseline" => baseline}) do
    current = capture_baseline(%{})

    %{
      memory_delta: current.memory.total - baseline.memory.total,
      error_rate_delta: current.error_rate - baseline.error_rate,
      degraded: degraded?(baseline, current)
    }
  end
end
```

### LLM Operator Role

The Release operator's prompt guides autonomous deployment:

```
You are deploying version {{version}} to production.
This deploy contains: {{change_summary}}
Change type: {{change_type}}

Your goal is to PROVE the system remains healthy.

Available tools:
- capture_baseline(): snapshot current health
- deploy_migration(name): run an Ecto migration
- hot_load_modules(list): load new code
- compare_to_baseline(baseline): check for degradation
- rollback_migration(name): undo a migration
- rollback_modules(list): restore previous code
- invoke_operators(skills): get detailed analysis

Rules:
- Always capture baseline before any change
- Wait at least 5 minutes after code changes
- If error_rate increases >10%, rollback immediately
- If memory increases >20% and doesn't stabilize, investigate
- If any operator reports critical state, halt and rollback

Output PROOF when done:
- Baseline metrics
- Post-deploy metrics
- Delta analysis
- Operator health reports
- Decision rationale
```

## Open Questions

1. **Skill vs separate module?** Should Release be a skill or outside the skill system?
2. **Multi-node coordination?** Leader election for deploy orchestration?
3. **Existing tools?** Integration with Distillery, Mix releases?
4. **Rollback thresholds?** How aggressive? Configurable per-deploy?
5. **Change classification?** How does LLM know which changes are safe?

## References

- [The Five Levels - Simon Willison](https://simonwillison.net/2026/Jan/28/the-five-levels/)
- [fly_deploy - Chris McCord](https://github.com/chrismccord/fly_deploy)
- [Parallel Change / Expand-Contract - Martin Fowler](https://martinfowler.com/bliki/ParallelChange.html)
- [Expand/Contract Pattern - Pete Hodgson](https://blog.thepete.net/blog/2023/12/05/expand/contract-making-a-breaking-change-without-a-big-bang/)
- [Erlang Release Handling](https://www.erlang.org/doc/design_principles/release_handling.html)
- [Learn You Some Erlang - Relups](https://learnyousomeerlang.com/relups)
- [GenServer code_change - Elixir Docs](https://hexdocs.pm/elixir/GenServer.html)
