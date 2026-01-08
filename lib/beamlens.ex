defmodule Beamlens do
  @moduledoc """
  BeamLens - AI-powered BEAM VM health monitoring.

  An orchestrator-workers architecture where specialized **watchers** autonomously
  monitor BEAM VM metrics on cron schedules, detect anomalies using LLM-based
  baseline learning, and investigate deeper when issues are found.

  ## Architecture

  ```
  ┌─────────────────────────────────────────────────────────────┐
  │                      Watcher (Autonomous)                   │
  │  1. Collect snapshot on cron schedule                       │
  │  2. AnalyzeBaseline → ContinueObserving | Alert | Healthy   │
  │  3. If Alert: push to AlertQueue, run InvestigateAnomaly    │
  │  4. Produce WatcherFindings with root cause & recommendations│
  └─────────────────────────────────────────────────────────────┘
                              │
                              ▼
              ┌────────────────────────┐
              │      AlertHandler      │
              │  - receives alerts     │
              │  - correlates findings │
              │  - orchestrates AI     │
              └────────────────────────┘
  ```

  ## Installation

  Add to your dependencies:

      {:beamlens, "~> 0.1.0"}

  ## Supervision Tree Setup

  Add BeamLens to your application's supervision tree:

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            {Beamlens, watchers: [{:beam, "*/5 * * * *"}]}
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end

  ## Configuration Options

  Options passed to `Beamlens`:

    * `:watchers` - List of watcher configurations (see below)
    * `:client_registry` - LLM provider configuration (see below)
    * `:alert_handler` - Alert handler options:
      * `:trigger` - `:on_alert` (auto-run) or `:manual` (default: `:on_alert`)
    * `:circuit_breaker` - Circuit breaker options (see below)

  ### LLM Provider Configuration

  By default, BeamLens uses Anthropic (requires `ANTHROPIC_API_KEY` env var).
  Configure a custom provider via `:client_registry`:

      {Beamlens,
        watchers: [{:beam, "*/5 * * * *"}],
        client_registry: %{
          primary: "Ollama",
          clients: [
            %{
              name: "Ollama",
              provider: "openai-generic",
              options: %{base_url: "http://localhost:11434/v1", model: "qwen3:4b"}
            }
          ]
        }}

  Supported providers include: `anthropic`, `openai`, `openai-generic` (Ollama),
  `aws-bedrock`, `google-ai`, `azure-openai`, and more.

  ### Watcher Configuration

  Watchers can be specified using tuple shorthand or full keyword lists:

      # Built-in BEAM watcher
      {:beam, "*/5 * * * *"}

      # Custom watcher
      [name: :postgres, watcher_module: MyApp.Watchers.Postgres,
       cron: "*/10 * * * *", config: [repo: MyApp.Repo]]

  ### Example Configuration

      {Beamlens,
        watchers: [
          {:beam, "*/1 * * * *"},
          [name: :postgres, watcher_module: MyApp.Watchers.Postgres,
           cron: "*/5 * * * *", config: [repo: MyApp.Repo]]
        ],
        alert_handler: [
          trigger: :on_alert
        ],
        circuit_breaker: [
          enabled: true
        ]}

  ## Manual Usage

      # Trigger a specific watcher manually
      :ok = Beamlens.trigger_watcher(:beam)

      # Investigate pending alerts (correlate findings across watchers)
      {:ok, analysis} = Beamlens.investigate()

  ## Runtime API

      # List all running watchers
      Beamlens.list_watchers()

      # Check for pending alerts
      Beamlens.pending_alerts?()

      # Trigger specific watcher
      Beamlens.trigger_watcher(:beam)

  ## Telemetry Events

  BeamLens emits telemetry events for observability. See `Beamlens.Telemetry`
  for the full list of events.
  """

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc false
  def start_link(opts) do
    Beamlens.Supervisor.start_link(opts)
  end

  @doc """
  Investigates pending watcher alerts using the agent's tool-calling loop.

  Takes all alerts from the queue and runs an investigation to correlate
  findings and analyze deeper.

  Returns `{:ok, analysis}` if alerts were processed,
  `{:ok, :no_alerts}` if no alerts were pending.

  ## Options

    * `:trace_id` - Correlation ID for telemetry (auto-generated if not provided)
  """
  def investigate(opts \\ []) do
    Beamlens.AlertHandler.investigate(Beamlens.AlertHandler, opts)
  end

  @doc """
  Lists all running watchers with their status.

  Returns a list of maps with watcher information including:
    * `:name` - Watcher name
    * `:watcher` - Domain being monitored
    * `:cron` - Cron schedule
    * `:next_run_at` - Next scheduled run
    * `:last_run_at` - Last run time
    * `:run_count` - Number of times the watcher has run
  """
  defdelegate list_watchers(), to: Beamlens.Watchers.Supervisor

  @doc """
  Triggers an immediate check for a specific watcher.

  Useful for testing or manual intervention.

  Returns `:ok` on success, `{:error, :not_found}` if watcher doesn't exist.
  """
  defdelegate trigger_watcher(name), to: Beamlens.Watchers.Supervisor

  @doc """
  Gets the status of a specific watcher.

  Returns `{:ok, status}` on success, `{:error, :not_found}` if watcher doesn't exist.
  """
  defdelegate watcher_status(name), to: Beamlens.Watchers.Supervisor

  @doc """
  Checks if there are pending alerts to investigate.
  """
  defdelegate pending_alerts?(), to: Beamlens.AlertQueue, as: :pending?

  @doc """
  Returns the current circuit breaker state.

  ## Example

      Beamlens.circuit_breaker_state()
      #=> %{
      #=>   state: :closed,
      #=>   failure_count: 0,
      #=>   success_count: 0,
      #=>   failure_threshold: 5,
      #=>   reset_timeout: 30000,
      #=>   success_threshold: 2,
      #=>   last_failure_at: nil,
      #=>   last_failure_reason: nil
      #=> }
  """
  defdelegate circuit_breaker_state(), to: Beamlens.CircuitBreaker, as: :get_state

  @doc """
  Resets the circuit breaker to closed state.

  Use with caution - primarily for manual recovery after resolving issues.
  """
  defdelegate reset_circuit_breaker(), to: Beamlens.CircuitBreaker, as: :reset
end
