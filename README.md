**Note** This project is in early development but we are actively seeking feedback from early adopters.

# Beamlens

Adaptive runtime intelligence for the BEAM.
 
Move beyond static supervision. Give your application the capability to self-diagnose incidents, analyze traffic patterns, and optimize its own performance.

[DEMO VIDEO](https://screen.studio/share/w1qXNbUc)

**[Request free early access to the web dashboard here](https://forms.gle/1KDwTLTC1UNwhGbh7)**. The web dashboard will be **free**, I just want to get early feedback first before releasing to everyone.

## The Problem

OTP is a masterpiece of reliability, but it is static. You define pool sizes, timeouts, and supervision strategies at compile time (or config time).

But production is dynamic. User behavior changes. Traffic patterns shift. A configuration that worked yesterday might be a bottleneck today.

Standard monitoring tools show you what is happening (metrics), but they don't understand why. They cannot tell you that your user traffic has shifted from "write-heavy" to "read-heavy," requiring a different architecture. And they certainly can't fix the issues for you!

## The Solution

Beamlens is an adaptive runtime engine that lives inside your supervision tree. It's built on battle-hardened AI practices from the best known techniques in the industry. You wire it into your system and it performs deep analysis for you.

1. **Deep Context**: When triggered, it captures internal state that external monitors miss—ETS key distribution, process dictionary size, and scheduler utilization.

2. **Semantic Analysis**: It uses an LLM to interpret that raw data. Instead of just showing you a graph, it explains why the graph looks that way.

3. **Adaptive Feedback**: Over time, you can use these insights to optimize configurations or refactor bottlenecks based on actual production behavior.

## Features

* **Sandboxed Analysis**: All investigation logic runs in a restricted environment. The "brain" observes without interfering with the "body."

* **Privacy-First**: Telemetry data is processed within your infrastructure. You choose the LLM provider; your application state is never sent to Beamlens servers.

* **Extensible Skills**: Teach Beamlens to understand your domain. If you are building a video platform, give it a skill to analyze `ffmpeg` process metrics.

* **Low Overhead**: Operators wait idle until invoked. No LLM calls occur until you trigger analysis.

## The Result

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

This is just the start. See the full roadmap [here](https://github.com/orgs/beamlens/projects/1).

Future plans include:

- A web interface for easy access and visualization of insights - **[Request early access here](https://forms.gle/1KDwTLTC1UNwhGbh7)**
- Better integration with Phoenix and other frameworks and libraries
- Long term agent memory and state management
- Code integration to understand issues at a deeper level
- Continuous monitoring and alerting
- And more...

We're going towards a future where software systems become self-aware and self-healing. Wake up, let's make it happen on the BEAM!

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

**2. Select a [provider](docs/providers.md)** or use the default Anthropic one by setting your API key:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

```elixir
client registry = %{
  primary: "Anthropic",
  clients: [
    %{name: "Anthropic", provider: "anthropic",
      options: %{model: "claude-haiku-4-5-20251001"}}
  ]
}
```

**3. Run Beamlens** (from an alert handler, Oban job, or IEx):

```elixir
{:ok, result} = Beamlens.Coordinator.run(%{reason: "memory alert..."}, client_registry: client_registry)
```

## Testing

For deterministic tests without API keys, use `Puck.Test.mock_client/2` and pass
the client via `:puck_client`. This bypasses BAML and the provider registry.

```elixir
client =
  Puck.Test.mock_client([
    %Beamlens.Operator.Tools.TakeSnapshot{intent: "take_snapshot"},
    %Beamlens.Operator.Tools.Done{intent: "done"}
  ])

{:ok, pid} =
  Beamlens.Operator.start_link(
    skill: MyApp.Skill,
    start_loop: true,
    puck_client: client
  )
```

For dynamic responses (e.g., referencing snapshot IDs), use function responses.
See `Puck.Test` documentation for details.

**Note:** This example shows the unit testing pattern using `Puck.Test.mock_client/2`.
For integration tests with the full supervision tree, use `Operator.run/2` instead.

Live-tagged tests require a real provider. Set `BEAMLENS_TEST_PROVIDER` to `anthropic`, `openai`,
`google-ai`, or `ollama`. When set to `mock`, live tests are skipped.

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
# Fire-and-forget analysis with callbacks
Beamlens.Operator.run_async(pid, %{reason: "background check"}, notify_pid: self())

receive do
  {:operator_notification, _pid, notification} ->
    Logger.info("Got notification: #{notification.summary}")

  {:operator_complete, _pid, skill, result} ->
    Logger.info("#{skill} completed with state: #{result.state}")
end
```

**5. Automated Remediation (Advanced)**

Once you trust the diagnosis, you can authorize Beamlens to fix specific issues. This turns Beamlens from a passive observer into an active supervisor.

**Note:** This requires explicit opt-in via the callbacks function.

```elixir
defmodule MyApp.Skills.Healer do
  @behaviour Beamlens.Skill

  # Explicitly allow the operator to kill a process
  @impl Beamlens.Skill
  def callbacks do
    %{
      "kill_process" => fn pid_str ->
        Process.exit(pid(pid_str), :kill)
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
- **`Beamlens.Skill.Monitor`** — Statistical anomaly detection with auto-trigger capabilities
- **`Beamlens.Skill.Overload`** — Message queue overload analysis and bottleneck detection
- **`Beamlens.Skill.Ports`** — Port and socket monitoring
- **`Beamlens.Skill.Sup`** — Supervisor tree inspection
- **`Beamlens.Skill.System`** — OS-level metrics (CPU, memory, disk via `os_mon`)
- **`Beamlens.Skill.SystemMonitor`** — System event monitoring (long GC, large heap, etc.)
- **`Beamlens.Skill.Tracer`** — Process tracing for debugging

### Experimental Skills

These skills require optional dependencies:

- **`Beamlens.Skill.Ecto`** — Database monitoring (requires `ecto_psql_extras`)
- **`Beamlens.Skill.Exception`** — Exception tracking (requires `tower`)

## License

Apache-2.0
