defmodule Beamlens.Telemetry do
  @moduledoc """
  Telemetry events emitted by BeamLens.

  All events include a `trace_id` for correlating events within a single agent run.
  Events follow the standard `:start`, `:stop`, `:exception` lifecycle pattern
  used by Phoenix, Oban, and other Elixir libraries.

  ## Event Schema

  **Start events** include `%{system_time: integer}` measurement.

  **Stop events** include `%{duration: integer}` measurement (native time units).

  **Exception events** include `%{duration: integer}` measurement and metadata:
  `%{kind: :error | :throw | :exit, reason: term(), stacktrace: list()}`.

  ## Agent Events

  * `[:beamlens, :agent, :start]` - Agent run starting
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{trace_id: String.t(), node: atom()}`

  * `[:beamlens, :agent, :stop]` - Agent run completed
    - Measurements: `%{duration: integer}`
    - Metadata: `%{trace_id: String.t(), node: atom(), status: atom(),
                   analysis: HealthAnalysis.t()}`

  * `[:beamlens, :agent, :exception]` - Agent run failed
    - Measurements: `%{duration: integer}`
    - Metadata: `%{trace_id: String.t(), node: atom(),
                   kind: atom(), reason: term(), stacktrace: list()}`

  ## LLM Events

  * `[:beamlens, :llm, :start]` - LLM call starting
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{trace_id: String.t(), iteration: integer, context_size: integer}`

  * `[:beamlens, :llm, :stop]` - LLM call completed
    - Measurements: `%{duration: integer}`
    - Metadata: `%{trace_id: String.t(), iteration: integer,
                   tool_selected: String.t(), intent: String.t(), response: struct()}`

  * `[:beamlens, :llm, :exception]` - LLM call failed
    - Measurements: `%{duration: integer}`
    - Metadata: `%{trace_id: String.t(), iteration: integer,
                   kind: atom(), reason: term(), stacktrace: list()}`

  ## Tool Events

  * `[:beamlens, :tool, :start]` - Tool execution starting
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{trace_id: String.t(), iteration: integer,
                   tool_name: String.t(), intent: String.t()}`

  * `[:beamlens, :tool, :stop]` - Tool execution completed
    - Measurements: `%{duration: integer}`
    - Metadata: `%{trace_id: String.t(), iteration: integer,
                   tool_name: String.t(), intent: String.t(), result: map()}`

  * `[:beamlens, :tool, :exception]` - Tool execution failed
    - Measurements: `%{duration: integer}`
    - Metadata: `%{trace_id: String.t(), iteration: integer, tool_name: String.t(),
                   kind: atom(), reason: term(), stacktrace: list()}`

  ## Judge Events

  * `[:beamlens, :judge, :start]` - Judge review starting
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{trace_id: String.t(), attempt: integer}`

  * `[:beamlens, :judge, :stop]` - Judge review completed
    - Measurements: `%{duration: integer}`
    - Metadata: `%{trace_id: String.t(), attempt: integer, verdict: atom()}`

  * `[:beamlens, :judge, :exception]` - Judge review failed
    - Measurements: `%{duration: integer}`
    - Metadata: `%{trace_id: String.t(), attempt: integer,
                   kind: atom(), reason: term(), stacktrace: list()}`

  ## Schedule Events

  * `[:beamlens, :schedule, :triggered]` - Schedule triggered (timer or manual)
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{name: atom(), cron: String.t(), source: :scheduled | :manual}`

  * `[:beamlens, :schedule, :skipped]` - Schedule skipped (already running)
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{name: atom(), cron: String.t(), reason: :already_running}`

  * `[:beamlens, :schedule, :completed]` - Scheduled task completed successfully
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{name: atom(), cron: String.t(), reason: :normal}`

  * `[:beamlens, :schedule, :failed]` - Scheduled task crashed
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{name: atom(), cron: String.t(), reason: term()}`

  ## Watcher Events

  * `[:beamlens, :watcher, :started]` - Watcher server started
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{watcher: atom(), cron: String.t()}`

  * `[:beamlens, :watcher, :triggered]` - Watcher check triggered
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{watcher: atom(), cron: String.t(), source: :scheduled | :manual}`

  * `[:beamlens, :watcher, :skipped]` - Watcher check skipped (already running)
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{watcher: atom(), cron: String.t(), reason: :already_running, source: atom()}`

  * `[:beamlens, :watcher, :check_start]` - Watcher check starting
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{watcher: atom(), cron: String.t()}`

  * `[:beamlens, :watcher, :check_stop]` - Watcher check completed
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{watcher: atom(), cron: String.t()}`

  * `[:beamlens, :watcher, :baseline_collecting]` - Still collecting baseline observations
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{watcher: atom(), cron: String.t(), observation_count: integer,
                   min_required: integer}`

  * `[:beamlens, :watcher, :baseline_analysis_start]` - Baseline analysis starting
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{watcher: atom(), cron: String.t(), trace_id: String.t()}`

  * `[:beamlens, :watcher, :baseline_analysis_stop]` - Baseline analysis completed
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{watcher: atom(), cron: String.t(), trace_id: String.t(), success: boolean()}`

  * `[:beamlens, :watcher, :baseline_continue_observing]` - LLM decided to continue observing
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{watcher: atom(), cron: String.t(), trace_id: String.t(), confidence: atom()}`

  * `[:beamlens, :watcher, :baseline_anomaly_detected]` - Anomaly detected and reported
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{watcher: atom(), cron: String.t(), trace_id: String.t(), alert_id: String.t(),
                   severity: atom(), anomaly_type: String.t(), confidence: atom()}`

  * `[:beamlens, :watcher, :baseline_anomaly_suppressed]` - Anomaly detected but suppressed (cooldown)
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{watcher: atom(), cron: String.t(), trace_id: String.t(),
                   anomaly_type: String.t(), category: atom(), reason: :cooldown}`

  * `[:beamlens, :watcher, :baseline_healthy]` - System determined to be healthy
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{watcher: atom(), cron: String.t(), trace_id: String.t(),
                   confidence: atom(), summary: String.t()}`

  ## Watcher Investigation Events

  * `[:beamlens, :watcher, :investigation, :start]` - Investigation loop starting
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{trace_id: String.t(), alert_id: String.t()}`

  * `[:beamlens, :watcher, :investigation, :complete]` - Investigation completed with findings
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{trace_id: String.t(), anomaly_type: String.t(),
                   severity: atom(), confidence: atom()}`

  * `[:beamlens, :watcher, :investigation, :tool_call]` - Investigation tool executed
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{trace_id: String.t(), tool: String.t(), iteration: integer}`

  * `[:beamlens, :watcher, :investigation, :error]` - Investigation failed
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{trace_id: String.t(), reason: term()}`

  * `[:beamlens, :watcher, :investigation, :timeout]` - Investigation timed out
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{trace_id: String.t()}`

  ## Alert Handler Events

  * `[:beamlens, :alert_handler, :started]` - AlertHandler server started
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{trigger_mode: :on_alert | :manual}`

  * `[:beamlens, :alert_handler, :investigation, :complete]` - Investigation finished
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{status: atom()}`

  * `[:beamlens, :alert_handler, :investigation, :error]` - Investigation failed
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{reason: term()}`

  ## Example Handler

      :telemetry.attach(
        "beamlens-alerts",
        [:beamlens, :agent, :stop],
        fn _event, _measurements, %{status: :critical} = metadata, _config ->
          Logger.error("BeamLens critical: \#{metadata.analysis.summary}")
        end,
        nil
      )

  ## Attaching to All Events

      :telemetry.attach_many(
        "my-handler",
        Beamlens.Telemetry.event_names(),
        &MyHandler.handle_event/4,
        nil
      )
  """

  @doc """
  Returns all telemetry event names that can be emitted.
  """
  def event_names do
    [
      [:beamlens, :agent, :start],
      [:beamlens, :agent, :stop],
      [:beamlens, :agent, :exception],
      [:beamlens, :llm, :start],
      [:beamlens, :llm, :stop],
      [:beamlens, :llm, :exception],
      [:beamlens, :tool, :start],
      [:beamlens, :tool, :stop],
      [:beamlens, :tool, :exception],
      [:beamlens, :judge, :start],
      [:beamlens, :judge, :stop],
      [:beamlens, :judge, :exception],
      [:beamlens, :schedule, :triggered],
      [:beamlens, :schedule, :skipped],
      [:beamlens, :schedule, :completed],
      [:beamlens, :schedule, :failed],
      [:beamlens, :watcher, :started],
      [:beamlens, :watcher, :triggered],
      [:beamlens, :watcher, :skipped],
      [:beamlens, :watcher, :check_start],
      [:beamlens, :watcher, :check_stop],
      [:beamlens, :watcher, :baseline_collecting],
      [:beamlens, :watcher, :baseline_analysis_start],
      [:beamlens, :watcher, :baseline_analysis_stop],
      [:beamlens, :watcher, :baseline_continue_observing],
      [:beamlens, :watcher, :baseline_anomaly_detected],
      [:beamlens, :watcher, :baseline_anomaly_suppressed],
      [:beamlens, :watcher, :baseline_healthy],
      [:beamlens, :watcher, :investigation, :start],
      [:beamlens, :watcher, :investigation, :complete],
      [:beamlens, :watcher, :investigation, :tool_call],
      [:beamlens, :watcher, :investigation, :error],
      [:beamlens, :watcher, :investigation, :timeout],
      [:beamlens, :alert_handler, :started],
      [:beamlens, :alert_handler, :investigation, :complete],
      [:beamlens, :alert_handler, :investigation, :error],
      [:beamlens, :circuit_breaker, :state_change],
      [:beamlens, :circuit_breaker, :rejected]
    ]
  end

  @doc """
  Generates a unique trace ID for an agent run.
  """
  def generate_trace_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  @doc """
  Executes a span for agent run with telemetry events.
  """
  def span(metadata, fun) do
    :telemetry.span([:beamlens, :agent], metadata, fun)
  end

  @doc """
  Executes a tool with telemetry span events.

  Emits `:start`, `:stop`, and `:exception` events for the tool execution.
  """
  def tool_span(metadata, fun) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:beamlens, :tool, :start],
      %{system_time: System.system_time()},
      metadata
    )

    try do
      result = fun.()

      :telemetry.execute(
        [:beamlens, :tool, :stop],
        %{duration: System.monotonic_time() - start_time},
        Map.put(metadata, :result, result)
      )

      result
    rescue
      exception ->
        stacktrace = __STACKTRACE__

        :telemetry.execute(
          [:beamlens, :tool, :exception],
          %{duration: System.monotonic_time() - start_time},
          Map.merge(metadata, %{kind: :error, reason: exception, stacktrace: stacktrace})
        )

        reraise exception, stacktrace
    end
  end

  @doc """
  Emits a tool start event.
  """
  def emit_tool_start(metadata) do
    :telemetry.execute(
      [:beamlens, :tool, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits a tool stop event with the tool result and duration.

  `start_time` should be captured via `System.monotonic_time()` before tool execution.
  """
  def emit_tool_stop(metadata, result, start_time) do
    :telemetry.execute(
      [:beamlens, :tool, :stop],
      %{duration: System.monotonic_time() - start_time},
      Map.put(metadata, :result, result)
    )
  end

  @doc """
  Emits a tool exception event with duration and exception details.

  `start_time` should be captured via `System.monotonic_time()` before tool execution.
  `kind` is the exception type (`:error`, `:throw`, or `:exit`).
  `stacktrace` is the exception stacktrace.
  """
  def emit_tool_exception(metadata, error, start_time, kind \\ :error, stacktrace \\ []) do
    :telemetry.execute(
      [:beamlens, :tool, :exception],
      %{duration: System.monotonic_time() - start_time},
      Map.merge(metadata, %{kind: kind, reason: error, stacktrace: stacktrace})
    )
  end

  @doc """
  Emits a judge start event.
  """
  def emit_judge_start(metadata) do
    :telemetry.execute(
      [:beamlens, :judge, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits a judge stop event with the verdict and duration.

  `start_time` should be captured via `System.monotonic_time()` before judge call.
  """
  def emit_judge_stop(metadata, judge_event, start_time) do
    :telemetry.execute(
      [:beamlens, :judge, :stop],
      %{duration: System.monotonic_time() - start_time},
      Map.put(metadata, :verdict, judge_event.verdict)
    )
  end

  @doc """
  Emits a judge exception event with duration and exception details.

  `start_time` should be captured via `System.monotonic_time()` before judge call.
  """
  def emit_judge_exception(metadata, error, start_time, kind \\ :error, stacktrace \\ []) do
    :telemetry.execute(
      [:beamlens, :judge, :exception],
      %{duration: System.monotonic_time() - start_time},
      Map.merge(metadata, %{kind: kind, reason: error, stacktrace: stacktrace})
    )
  end

  @doc """
  Attaches a default logging handler to all BeamLens telemetry events.

  ## Options

  - `:level` - Log level to use (default: `:debug`)
  """
  def attach_default_logger(opts \\ []) do
    level = Keyword.get(opts, :level, :debug)

    :telemetry.attach_many(
      "beamlens-telemetry-default-logger",
      event_names(),
      &__MODULE__.log_event/4,
      %{level: level}
    )
  end

  @doc """
  Detaches the default logging handler.
  """
  def detach_default_logger do
    :telemetry.detach("beamlens-telemetry-default-logger")
  end

  @doc false
  def log_event(event, measurements, metadata, config) do
    require Logger

    level = Map.get(config, :level, :debug)
    event_name = Enum.join(event, ".")
    trace_id = Map.get(metadata, :trace_id, "unknown")

    Logger.log(level, fn ->
      "[#{event_name}] trace_id=#{trace_id} #{format_measurements(measurements)}"
    end)
  end

  defp format_measurements(measurements) do
    Enum.map_join(measurements, " ", fn {k, v} -> "#{k}=#{v}" end)
  end
end
