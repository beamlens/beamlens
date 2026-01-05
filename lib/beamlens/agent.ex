defmodule Beamlens.Agent do
  @moduledoc """
  AI agent that analyzes BEAM health using a tool-calling loop.

  Built on [Puck](https://github.com/bradleygolden/puck), an Elixir
  framework for AI agents.

  Uses Claude Haiku via BAML to iteratively gather VM metrics and produce
  structured health assessments. The agent selects which tools to call
  and accumulates context until it generates a final analysis.

  ## Telemetry

  The agent emits telemetry events for observability. See `Beamlens.Telemetry`
  for the full list of events. All events include a `trace_id` that correlates
  the entire agent run and all its LLM calls and tool executions.

  ## Architecture

  The agent loop:
  1. Calls `SelectTool` BAML function with conversation history
  2. Finds the tool by intent from configured collectors
  3. Executes the tool via its bundled execute function
  4. Repeats until agent selects `Done` with a HealthAnalysis

  Uses `Puck.Client` for LLM configuration and `Puck.Context` for
  immutable conversation history management.
  """

  require Logger

  alias Beamlens.{CircuitBreaker, Telemetry, Tools}
  alias Beamlens.Events.{LLMCall, ToolCall}
  alias Puck.Context

  @default_max_iterations 10
  @default_timeout :timer.seconds(60)

  @doc """
  Run a health analysis using the agent loop.

  The agent will iteratively select tools to gather information,
  then generate a final health analysis.

  ## Options

    * `:collectors` - List of collector modules to use for gathering metrics.
      Defaults to configured collectors or `[Beamlens.Collectors.Beam]`.
    * `:client_registry` - Full LLM client configuration map. When provided,
      takes precedence and `:llm_client` is ignored. See example below.
    * `:llm_client` - LLM client name string (e.g., "Ollama"). Only used
      when `:client_registry` is not provided.
    * `:max_iterations` - Maximum tool calls before forcing completion (default: 10)
    * `:trace_id` - Correlation ID for telemetry (auto-generated if not provided)
    * `:timeout` - Timeout in milliseconds for each LLM call (default: 60000)

  ## Examples

      {:ok, analysis} = Beamlens.Agent.run()
      analysis.status
      #=> :healthy

      # Use a different preconfigured client
      {:ok, analysis} = Beamlens.Agent.run(llm_client: "Ollama")

      # Use multiple collectors
      {:ok, analysis} = Beamlens.Agent.run(
        collectors: [Beamlens.Collectors.Beam, MyApp.Collectors.Postgres]
      )

      # Custom LLM provider with full configuration
      {:ok, analysis} = Beamlens.Agent.run(
        client_registry: %{
          primary: "Bedrock",
          clients: [
            %{
              name: "Bedrock",
              provider: "aws-bedrock",
              options: %{model: "anthropic.claude-sonnet-4-5", region: "us-east-1"}
            }
          ]
        }
      )
  """
  def run(opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    llm_client = Keyword.get(opts, :llm_client)
    client_registry = Keyword.get(opts, :client_registry)
    trace_id = Keyword.get(opts, :trace_id, Telemetry.generate_trace_id())
    collectors = Keyword.get(opts, :collectors, default_collectors())

    tools = collect_tools(collectors)

    backend_config =
      %{
        function: "SelectTool",
        args_format: :messages,
        path: Application.app_dir(:beamlens, "priv/baml_src")
      }
      |> maybe_add_client_config(llm_client, client_registry)

    client =
      Puck.Client.new(
        {Puck.Backends.Baml, backend_config},
        hooks: Beamlens.Telemetry.Hooks
      )

    context =
      Context.new(
        metadata: %{
          trace_id: trace_id,
          started_at: DateTime.utc_now(),
          node: Node.self(),
          iteration: 0,
          tool_count: 0,
          events: []
        }
      )

    loop(client, context, max_iterations, timeout, tools)
  end

  defp collect_tools(collectors) do
    Enum.flat_map(collectors, & &1.tools())
  end

  defp loop(_client, context, 0, _timeout, _tools) do
    Logger.warning("[BeamLens] Agent reached max iterations without completing",
      trace_id: context.metadata.trace_id
    )

    {:error, :max_iterations_exceeded}
  end

  defp loop(client, context, remaining, timeout, tools) do
    case call_with_timeout(client, context, timeout) do
      {:ok, response, new_context} ->
        Logger.debug("[BeamLens] Agent selected: #{inspect(response.content)}",
          trace_id: context.metadata.trace_id
        )

        llm_event = %LLMCall{
          occurred_at: DateTime.utc_now(),
          iteration: context.metadata.iteration,
          tool_selected: response.content.intent
        }

        context_with_event = append_event(new_context, llm_event)

        execute_tool(response.content, client, context_with_event, remaining - 1, timeout, tools)

      {:error, :timeout} ->
        Logger.warning("[BeamLens] LLM call timed out after #{timeout}ms",
          trace_id: context.metadata.trace_id
        )

        {:error, :timeout}

      {:error, reason} = error ->
        Logger.warning("[BeamLens] SelectTool failed: #{inspect(reason)}",
          trace_id: context.metadata.trace_id
        )

        error
    end
  end

  defp call_with_timeout(client, context, timeout) do
    if circuit_breaker_allows?() do
      execute_llm_call(client, context, timeout)
    else
      Logger.warning("[BeamLens] Circuit breaker open, skipping LLM call",
        trace_id: context.metadata.trace_id
      )

      {:error, :circuit_open}
    end
  end

  defp execute_llm_call(client, context, timeout) do
    task =
      Task.async(fn ->
        Puck.call(client, [], context, output_schema: Tools.schema())
      end)

    result =
      case Task.yield(task, timeout) do
        {:ok, result} ->
          result

        nil ->
          case Task.shutdown(task, :brutal_kill) do
            {:ok, result} ->
              Logger.debug("[BeamLens] LLM completed just before shutdown",
                trace_id: context.metadata.trace_id
              )

              result

            nil ->
              {:error, :timeout}
          end
      end

    record_circuit_breaker_result(result)
    result
  end

  defp circuit_breaker_allows? do
    case Process.whereis(CircuitBreaker) do
      nil -> true
      _pid -> CircuitBreaker.allow?()
    end
  end

  defp record_circuit_breaker_result(result) do
    case Process.whereis(CircuitBreaker) do
      nil ->
        :ok

      _pid ->
        case result do
          {:ok, _response, _context} ->
            CircuitBreaker.record_success()

          {:error, reason} ->
            CircuitBreaker.record_failure(reason)
        end
    end
  end

  defp execute_tool(
         %Tools.Done{analysis: analysis},
         _client,
         context,
         _remaining,
         _timeout,
         _tools
       ) do
    analysis_with_events = %{analysis | events: context.metadata.events}

    Logger.info("[BeamLens] Agent completed with status: #{analysis.status}",
      trace_id: context.metadata.trace_id,
      tool_count: context.metadata.tool_count
    )

    {:ok, analysis_with_events}
  end

  defp execute_tool(%{intent: intent}, client, context, remaining, timeout, tools) do
    case find_tool(intent, tools) do
      {:ok, tool} ->
        execute_and_continue(client, context, tool, remaining, timeout, tools)

      :error ->
        Logger.warning("[BeamLens] Unknown tool: #{intent}",
          trace_id: context.metadata.trace_id
        )

        {:error, {:unknown_tool, intent}}
    end
  end

  defp execute_tool(unknown, _client, context, _remaining, _timeout, _tools) do
    Logger.warning("[BeamLens] Unknown tool response: #{inspect(unknown)}",
      trace_id: context.metadata.trace_id
    )

    {:error, {:unknown_tool, unknown}}
  end

  defp find_tool(intent, tools) do
    case Enum.find(tools, fn tool -> tool.intent == intent end) do
      nil -> :error
      tool -> {:ok, tool}
    end
  end

  defp execute_and_continue(client, context, tool, remaining, timeout, tools) do
    trace_metadata = %{
      trace_id: context.metadata.trace_id,
      iteration: context.metadata.iteration,
      tool_name: tool.intent,
      intent: tool.intent
    }

    Telemetry.emit_tool_start(trace_metadata)
    start_time = System.monotonic_time()

    result = tool.execute.()

    Logger.debug("[BeamLens] Tool #{tool.intent} returned: #{inspect(result)}",
      trace_id: context.metadata.trace_id
    )

    case Jason.encode(result) do
      {:ok, encoded} ->
        Telemetry.emit_tool_stop(trace_metadata, result, start_time)

        tool_event = %ToolCall{
          intent: tool.intent,
          occurred_at: DateTime.utc_now(),
          result: result
        }

        new_context =
          context
          |> append_event(tool_event)
          |> add_tool_message(encoded, %{tool: tool.intent})
          |> increment_iteration()
          |> increment_tool_count()

        loop(client, new_context, remaining, timeout, tools)

      {:error, reason} ->
        Telemetry.emit_tool_exception(trace_metadata, reason, start_time)

        Logger.error("[BeamLens] Failed to encode tool result: #{inspect(reason)}",
          trace_id: context.metadata.trace_id,
          tool_name: tool.intent
        )

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

  defp increment_tool_count(context) do
    put_in(context.metadata.tool_count, context.metadata.tool_count + 1)
  end

  defp append_event(context, event) do
    update_in(context.metadata.events, &(&1 ++ [event]))
  end

  defp default_collectors do
    Application.get_env(:beamlens, :collectors, [Beamlens.Collectors.Beam])
  end

  defp maybe_add_client_config(config, nil, nil), do: config

  defp maybe_add_client_config(config, _llm_client, client_registry)
       when is_map(client_registry) do
    Map.put(config, :client_registry, client_registry)
  end

  defp maybe_add_client_config(config, llm_client, nil) do
    Map.put(config, :llm_client, llm_client)
  end
end
