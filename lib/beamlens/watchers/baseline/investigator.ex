defmodule Beamlens.Watchers.Baseline.Investigator do
  @moduledoc """
  LLM-based investigation loop for watcher anomalies.

  After a watcher detects an anomaly and sends an alert, this module
  runs a tool-calling loop to investigate deeper and produce findings.

  Follows the same pattern as `Beamlens.Agent` - uses `SelectInvestigationTool`
  BAML function which is the investigation loop's equivalent of `SelectTool`.

  ## How it Works

  1. Takes alert and watcher's tools
  2. Creates initial context with alert as first message
  3. Calls `SelectInvestigationTool` BAML function
  4. Pattern matches on tool struct → executes tool → adds result to context → loops
  5. Pattern matches on `InvestigationComplete` → returns findings
  """

  require Logger

  alias Beamlens.Watchers.Baseline.Decision
  alias Beamlens.Watchers.Baseline.Decision.InvestigationComplete
  alias Puck.Context

  @default_max_iterations 5
  @default_timeout :timer.seconds(30)

  @doc """
  Investigates an anomaly using a tool-calling loop.

  Returns `{:ok, findings}` with `WatcherFindings` struct, or
  `{:error, reason}` on failure.

  ## Options

    * `:llm_client` - LLM client name to use
    * `:client_registry` - Client registry for dynamic client selection
    * `:timeout` - Timeout for each LLM call (default: 30s)
    * `:max_iterations` - Maximum tool calls before giving up (default: 5)
    * `:trace_id` - Correlation ID for telemetry
  """
  def investigate(alert, tools, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    trace_id = Keyword.get(opts, :trace_id)

    backend_config =
      %{
        function: "SelectInvestigationTool",
        args_format: :messages,
        path: Application.app_dir(:beamlens, "priv/baml_src")
      }
      |> maybe_add_client_config(opts)

    client =
      Puck.Client.new(
        {Puck.Backends.Baml, backend_config},
        hooks: Beamlens.Telemetry.Hooks
      )

    initial_message = Puck.Message.new(:user, build_alert_context(alert), %{alert: true})

    context =
      Context.new(
        messages: [initial_message],
        metadata: %{
          trace_id: trace_id,
          alert_id: alert.id,
          iteration: 0
        }
      )

    emit_telemetry(:start, %{trace_id: trace_id, alert_id: alert.id})
    loop(client, context, max_iterations, timeout, tools)
  end

  defp loop(_client, _context, 0, _timeout, _tools) do
    {:error, :max_iterations_exceeded}
  end

  defp loop(client, context, remaining, timeout, tools) do
    task =
      Task.async(fn ->
        Puck.call(client, [], context, output_schema: Decision.investigation_schema())
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, response, new_context}} ->
        handle_response(response.content, client, new_context, remaining, timeout, tools)

      {:ok, {:error, reason}} ->
        emit_telemetry(:error, %{trace_id: context.metadata.trace_id, reason: reason})
        {:error, reason}

      nil ->
        emit_telemetry(:timeout, %{trace_id: context.metadata.trace_id})
        {:error, :timeout}
    end
  end

  # Termination: InvestigationComplete
  defp handle_response(
         %InvestigationComplete{findings: findings},
         _client,
         context,
         _remaining,
         _timeout,
         _tools
       ) do
    emit_telemetry(:complete, %{
      trace_id: context.metadata.trace_id,
      anomaly_type: findings.anomaly_type,
      severity: findings.severity,
      confidence: findings.confidence
    })

    {:ok, findings}
  end

  # Tool selection: any struct with intent field
  defp handle_response(
         %{intent: intent} = tool_struct,
         client,
         context,
         remaining,
         timeout,
         tools
       ) do
    case find_tool(intent, tools) do
      {:ok, tool} ->
        execute_and_continue(tool, tool_struct, client, context, remaining, timeout, tools)

      :error ->
        Logger.warning("[BeamLens] Investigation selected unknown tool: #{intent}",
          trace_id: context.metadata.trace_id
        )

        {:error, {:unknown_tool, intent}}
    end
  end

  defp find_tool(intent, tools) do
    case Enum.find(tools, fn tool -> tool.intent == intent end) do
      nil -> :error
      tool -> {:ok, tool}
    end
  end

  defp execute_and_continue(tool, tool_struct, client, context, remaining, timeout, tools) do
    emit_telemetry(:tool_call, %{
      trace_id: context.metadata.trace_id,
      tool: tool.intent,
      iteration: context.metadata.iteration
    })

    params = Map.drop(tool_struct, [:intent, :__struct__])
    result = tool.execute.(params)

    case Jason.encode(result) do
      {:ok, encoded} ->
        new_context =
          context
          |> add_tool_message(encoded, %{tool: tool.intent})
          |> increment_iteration()

        loop(client, new_context, remaining - 1, timeout, tools)

      {:error, reason} ->
        {:error, {:encoding_failed, tool.intent, reason}}
    end
  end

  defp add_tool_message(context, content, metadata) do
    message = Puck.Message.new(:user, content, metadata)
    %{context | messages: context.messages ++ [message]}
  end

  defp increment_iteration(context) do
    put_in(context.metadata.iteration, context.metadata.iteration + 1)
  end

  defp build_alert_context(alert) do
    """
    [ALERT CONTEXT]
    Anomaly detected: #{alert.anomaly_type}
    Severity: #{alert.severity}
    Summary: #{alert.summary}
    Watcher: #{alert.watcher}
    Detected at: #{DateTime.to_iso8601(alert.detected_at)}
    """
  end

  defp maybe_add_client_config(config, opts) do
    llm_client = Keyword.get(opts, :llm_client)
    client_registry = Keyword.get(opts, :client_registry)

    cond do
      is_map(client_registry) -> Map.put(config, :client_registry, client_registry)
      llm_client != nil -> Map.put(config, :llm_client, llm_client)
      true -> config
    end
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:beamlens, :watcher, :investigation, event],
      %{system_time: System.system_time()},
      metadata
    )
  end
end
