defmodule Beamlens do
  @moduledoc """
  BeamLens - AI-powered BEAM VM health monitoring.

  An AI agent that periodically analyzes BEAM VM metrics and generates
  actionable health assessments using Claude. Safe by design: all operations
  are read-only with no side effects, and no sensitive data is exposed.

  ## Installation

  Add to your dependencies:

      {:beamlens, github: "bradleygolden/beamlens"}

  ## Supervision Tree Setup

  Add BeamLens to your application's supervision tree:

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            # ... your other children ...
            {Beamlens, schedules: [{:default, "*/5 * * * *"}]}
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end

  ## Configuration Options

  Options passed to `Beamlens`:

    * `:schedules` - List of schedule configurations (see below)
    * `:agent_opts` - Global options passed to all agent runs
    * `:circuit_breaker` - Circuit breaker options (see below)

  ### Circuit Breaker Configuration

  The circuit breaker prevents cascading failures when the LLM provider is unavailable:

      {Beamlens,
        schedules: [{:default, "*/5 * * * *"}],
        circuit_breaker: [
          failure_threshold: 5,   # Open after 5 consecutive failures
          reset_timeout: 30_000,  # Try half_open after 30 seconds
          success_threshold: 2    # Close after 2 successes in half_open
        ]}

  ### Schedule Configuration

  Schedules can be specified using tuple shorthand or full keyword lists:

      # Tuple shorthand: {name, cron_expression}
      {:default, "*/5 * * * *"}

      # Full keyword list for per-schedule options
      [name: :nightly, cron: "0 2 * * *", agent_opts: [timeout: 300_000]]

  ### Example Configuration

      {Beamlens,
        schedules: [
          {:frequent, "*/5 * * * *"},
          [name: :nightly, cron: "0 2 * * *", agent_opts: [timeout: 300_000]]
        ],
        agent_opts: [
          timeout: 60_000,
          max_iterations: 10
        ]}

  ## Manual Usage

  You can also run the agent manually without the scheduler:

      # Run analysis and get result
      {:ok, analysis} = Beamlens.run()

      # Run with options
      {:ok, analysis} = Beamlens.run(timeout: 120_000)

  ## Runtime API

  When using the scheduler, you can interact with schedules at runtime:

      # List all schedules
      Beamlens.list_schedules()

      # Get a specific schedule
      Beamlens.get_schedule(:default)

      # Trigger immediate run (outside of schedule)
      Beamlens.run_now(:default)

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
  Manually trigger a health analysis.

  Returns `{:ok, analysis}` on success, or `{:error, reason}` on failure.

  ## Options

  See `Beamlens.Agent.run/1` for available options.

  ## Possible Errors

    * `{:error, :max_iterations_exceeded}` - Agent did not complete within iteration limit
    * `{:error, :timeout}` - LLM call timed out
    * `{:error, :circuit_open}` - Circuit breaker is open due to consecutive failures
    * `{:error, {:unknown_tool, tool}}` - LLM returned unrecognized tool
    * `{:error, {:encoding_failed, tool_name, reason}}` - Tool result could not be JSON-encoded
  """
  defdelegate run(opts \\ []), to: Beamlens.Agent

  @doc """
  Returns all configured schedules.
  """
  defdelegate list_schedules(), to: Beamlens.Scheduler

  @doc """
  Returns a specific schedule by name, or nil if not found.
  """
  defdelegate get_schedule(name), to: Beamlens.Scheduler

  @doc """
  Triggers an immediate run for the given schedule.

  Returns `{:error, :already_running}` if the schedule is already executing.
  """
  defdelegate run_now(name), to: Beamlens.Scheduler

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
