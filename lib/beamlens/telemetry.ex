defmodule Beamlens.Telemetry do
  @moduledoc """
  Telemetry events emitted by BeamLens.

  All events include a `trace_id` for correlating events within a single agent run.

  ## Agent Events

  * `[:beamlens, :agent, :start]` - Agent run starting
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{trace_id: String.t(), node: String.t()}`

  * `[:beamlens, :agent, :stop]` - Agent run completed
    - Measurements: `%{duration: integer}` (native units)
    - Metadata: `%{trace_id: String.t(), node: String.t(), status: atom(),
                   analysis: HealthAnalysis.t(), tool_count: integer}`

  * `[:beamlens, :agent, :exception]` - Agent run failed
    - Measurements: `%{duration: integer}`
    - Metadata: `%{trace_id: String.t(), node: String.t(), error: term()}`

  ## LLM Call Events

  * `[:beamlens, :llm, :call_start]` - LLM call starting
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{trace_id: String.t(), iteration: integer, context_size: integer}`

  * `[:beamlens, :llm, :call_stop]` - LLM call completed
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{trace_id: String.t(), iteration: integer,
                   tool_selected: String.t(), intent: String.t()}`

  * `[:beamlens, :llm, :call_error]` - LLM call failed
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{trace_id: String.t(), iteration: integer, error: term()}`

  ## Tool Events

  * `[:beamlens, :tool, :start]` - Tool execution starting
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{trace_id: String.t(), iteration: integer,
                   tool_name: String.t(), intent: String.t()}`

  * `[:beamlens, :tool, :stop]` - Tool execution completed
    - Measurements: `%{duration: integer}`
    - Metadata: `%{trace_id: String.t(), iteration: integer, tool_name: String.t()}`

  * `[:beamlens, :tool, :exception]` - Tool execution failed
    - Measurements: `%{duration: integer}`
    - Metadata: `%{trace_id: String.t(), iteration: integer,
                   tool_name: String.t(), error: term()}`

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
  @spec event_names() :: [[atom()]]
  def event_names do
    [
      [:beamlens, :agent, :start],
      [:beamlens, :agent, :stop],
      [:beamlens, :agent, :exception],
      [:beamlens, :llm, :call_start],
      [:beamlens, :llm, :call_stop],
      [:beamlens, :llm, :call_error],
      [:beamlens, :tool, :start],
      [:beamlens, :tool, :stop],
      [:beamlens, :tool, :exception],
      [:beamlens, :schedule, :triggered],
      [:beamlens, :schedule, :skipped],
      [:beamlens, :schedule, :completed],
      [:beamlens, :schedule, :failed]
    ]
  end

  @doc """
  Generates a unique trace ID for an agent run.
  """
  @spec generate_trace_id() :: String.t()
  def generate_trace_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  @doc """
  Executes a span for agent run with telemetry events.
  """
  @spec span(map(), (-> {result, map(), map()})) :: result when result: term()
  def span(metadata, fun) do
    :telemetry.span([:beamlens, :agent], metadata, fun)
  end

  @doc """
  Executes a tool with telemetry span events.

  Emits `:start`, `:stop`, and `:exception` events for the tool execution.
  """
  @spec tool_span(map(), (-> result)) :: result when result: term()
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
        metadata
      )

      result
    rescue
      exception ->
        :telemetry.execute(
          [:beamlens, :tool, :exception],
          %{duration: System.monotonic_time() - start_time},
          Map.put(metadata, :error, exception)
        )

        reraise exception, __STACKTRACE__
    end
  end

  @doc """
  Attaches a default logging handler to all BeamLens telemetry events.

  ## Options

  - `:level` - Log level to use (default: `:debug`)
  """
  @spec attach_default_logger(keyword()) :: :ok | {:error, :already_exists}
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
  @spec detach_default_logger() :: :ok | {:error, :not_found}
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
    measurements
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join(" ")
  end
end
