defmodule Beamlens do
  @moduledoc """
  BeamLens - AI-powered BEAM VM health monitoring.

  An AI agent that periodically analyzes BEAM VM metrics and generates
  actionable health assessments using Claude. Safe by design: all operations
  are read-only with no side effects, and no sensitive data is exposed.

  ## Installation

  Add to your dependencies:

      {:beamlens, github: "bradleygolden/beamlens"}

  Set your API key (required by BAML):

      export ANTHROPIC_API_KEY=your-api-key

  ## Supervision Tree Setup

  Add BeamLens to your application's supervision tree:

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            # ... your other children ...
            {Task.Supervisor, name: Beamlens.TaskSupervisor},
            {Beamlens.Scheduler, beamlens_opts()}
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end

        defp beamlens_opts do
          [
            schedules: [
              [name: :default, cron: "*/5 * * * *"]
            ]
          ]
        end
      end

  ## Configuration Options

  Options passed to `Beamlens.Scheduler`:

    * `:schedules` - List of schedule configurations (see below)
    * `:agent_opts` - Global options passed to all agent runs

  Each schedule in `:schedules` accepts:

    * `:name` (required) - Unique atom identifying the schedule
    * `:cron` (required) - Cron expression string (e.g., `"*/5 * * * *"`)
    * `:agent_opts` - Per-schedule options that override global options

  ### Example Configuration

      [
        schedules: [
          [name: :frequent, cron: "*/5 * * * *"],
          [name: :nightly, cron: "0 2 * * *", agent_opts: [timeout: 300_000]]
        ],
        agent_opts: [
          timeout: 60_000,
          max_iterations: 10
        ]
      ]

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

  @doc """
  Manually trigger a health analysis.

  Returns `{:ok, analysis}` where analysis is the AI-generated health assessment.
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
end
