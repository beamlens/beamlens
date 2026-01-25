**Note** This project is in early development but we are actively seeking feedback from early adopters.

# Beamlens

Adaptive runtime intelligence for the BEAM.
 
Move beyond static supervision. Give your application the capability to self-diagnose incidents, analyze traffic patterns, and optimize its own performance.

<a href="https://screen.studio/share/w1qXNbUc" target="_blank"><img src="assets/demo.gif" alt="Demo" /></a>

**[Request free early access to the web dashboard here](https://forms.gle/1KDwTLTC1UNwhGbh7)**. The web dashboard will be **free**, I just want to get early feedback first before releasing to everyone.

## How It Works

Beamlens lives inside your supervision tree. When triggered, it captures runtime state that external monitors miss—ETS distributions, process heaps, scheduler utilization—and uses an LLM to explain *why* your metrics look the way they do.

- **Read-only**: All analysis is sandboxed. No side effects.
- **Privacy-first**: Data stays in your infrastructure. You choose the LLM provider.
- **Extensible**: Teach it your domain with custom skills.
- **Low overhead**: No LLM calls until you trigger analysis.

## Example

Beamlens translates opaque runtime metrics into semantic explanations.

```elixir
# You trigger an investigation when telemetry spikes
{:ok, result} = Beamlens.Coordinator.run(%{reason: "memory > 90%"})

# beamlens returns the specific root cause based on runtime introspection
result.insights
# => [
#      "Analysis: Process <0.450.0> (MyApp.ImageWorker) is holding 2.1GB binary heap.",
#      "Context: Correlates with 450 concurrent uploads in the last minute.",
#      "Root Cause: Worker pool exhausted; processes are not hibernating after large binary handling."
#    ]
```

## Roadmap

See the [project roadmap](https://github.com/orgs/beamlens/projects/1) for planned features including a web dashboard, Phoenix integration, and continuous monitoring.

## Installation

Add `beamlens` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:beamlens, "~> 0.2.0"}
  ]
end
```

## Quick Start

**1. Add to your supervision tree** in `application.ex`:

```elixir
def start(_type, _args) do
  children = [
    # ... your other children
    Beamlens
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

You can also configure which skills to enable:

```elixir
{Beamlens, skills: [
  Beamlens.Skill.Beam,
  {Beamlens.Skill.Anomaly, [enabled: true, collection_interval_ms: 60_000]}
]}
```

**2. Configure your LLM provider.** Set an API key for the default Anthropic provider:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

Or configure a custom [provider](docs/providers.md) in your supervision tree:

```elixir
{Beamlens, client_registry: %{
  primary: "Anthropic",
  clients: [
    %{name: "Anthropic", provider: "anthropic",
      options: %{model: "claude-haiku-4-5-20251001"}}
  ]
}}
```

**3. Run Beamlens** (from an alert handler, Oban job, or IEx):

```elixir
{:ok, result} = Beamlens.Coordinator.run(%{reason: "memory alert..."})
```

## Testing

Use `Puck.Test.mock_client/2` for deterministic tests without API keys. See `Puck.Test` module docs for details.

## Examples

**1. Triggering from Telemetry**

```elixir
# In your Telemetry handler
def handle_event([:my_app, :memory, :high], _measurements, _metadata, _config) do
  # Trigger an investigation immediately
  {:ok, result} = Beamlens.Coordinator.run(%{reason: "memory alert..."})

  # Log the insights
  Logger.error("Memory Alert Diagnosis: #{inspect(result.insights)}")
end
```

**2. Creating Custom Skills**

You can teach Beamlens to understand your specific business logic. For example, if you use a GenServer to batch requests, generic metrics won't help. You need a custom skill.

```elixir
defmodule MyApp.Skills.Batcher do
  @behaviour Beamlens.Skill
  
  # Shortened for brevity, see the Beamlens.Skill behaviour for full implementation details.

  @impl true
  def system_prompt do
    "You are checking the Batcher process. Watch for 'queue_size' > 5000."
  end

  @impl true
  def snapshot do
    %{
      queue_size: MyApp.Batcher.queue_size(),
      pending_jobs: MyApp.Batcher.pending_count()
    }
  end
end
```

**3. Periodic Health Checks (Optimization)**

You can schedule Beamlens to run periodically to spot trends before they become alerts.

```elixir
# In a scheduled job (e.g., Oban)
def perform(_job) do
  {:ok, result} = Beamlens.Coordinator.run(%{reason: "daily check..."})
  # Store insights for review
  MyApp.InsightStore.save(result)
end
```

**4. Fire-and-Forget Analysis**

Use `run_async/3` for background analysis with callbacks:

```elixir
# Look up the operator for a skill
[{pid, _}] = Registry.lookup(Beamlens.OperatorRegistry, Beamlens.Skill.Beam)

# Run asynchronously - returns immediately
Beamlens.Operator.run_async(pid, %{reason: "background check"}, notify_pid: self())

# Receive results when ready
receive do
  {:operator_complete, _pid, skill, result} ->
    Logger.info("#{skill} completed: #{inspect(result.insights)}")
end
```

**5. Custom Actions (Advanced)**

Skills can expose callbacks that the LLM can invoke. This allows Beamlens to take actions beyond read-only analysis—use with care.

```elixir
defmodule MyApp.Skills.PoolManager do
  @behaviour Beamlens.Skill

  # ... other callbacks (system_prompt, snapshot, etc.)

  @impl Beamlens.Skill
  def callbacks do
    %{
      # The LLM can request to resize a pool based on its analysis
      "resize_pool" => fn size_str ->
        MyApp.WorkerPool.resize(String.to_integer(size_str))
      end
    }
  end
end
```

## Built-in Skills

Beamlens includes skills for common BEAM runtime monitoring:

- **`Beamlens.Skill.Beam`** — BEAM VM health (memory, processes, schedulers, atoms, ports)
- **`Beamlens.Skill.Allocator`** — Memory allocator fragmentation monitoring
- **`Beamlens.Skill.Ets`** — ETS table monitoring (counts, memory, top tables)
- **`Beamlens.Skill.Gc`** — Garbage collection statistics
- **`Beamlens.Skill.Logger`** — Application log analysis (error rates, patterns)
- **`Beamlens.Skill.Anomaly`** — Statistical anomaly detection with auto-trigger capabilities
- **`Beamlens.Skill.Overload`** — Message queue overload analysis and bottleneck detection
- **`Beamlens.Skill.Ports`** — Port and socket monitoring
- **`Beamlens.Skill.Supervisor`** — Supervisor tree inspection
- **`Beamlens.Skill.Os`** — OS-level metrics (CPU, memory, disk via `os_mon`)
- **`Beamlens.Skill.VmEvents`** — System event monitoring (long GC, large heap, etc.)
- **`Beamlens.Skill.Tracer`** — Production-safe function tracing powered by Recon

### Experimental Skills

These skills require optional dependencies:

- **`Beamlens.Skill.Ecto`** — Database monitoring (requires `ecto_psql_extras`)
- **`Beamlens.Skill.Exception`** — Exception tracking (requires `tower`)

## License

Apache-2.0
