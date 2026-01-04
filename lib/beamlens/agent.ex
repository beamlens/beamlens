defmodule Beamlens.Agent do
  @moduledoc """
  AI agent that analyzes BEAM health using a tool-calling loop.

  Built on [Strider](https://github.com/bradleygolden/strider), an Elixir
  library for composable LLM agent orchestration.

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
  2. Pattern matches on tool struct type to determine which tool was selected
  3. Executes the tool and adds result to context
  4. Repeats until agent selects `Done` with a HealthAnalysis

  Uses `Strider.Agent` for LLM configuration and `Strider.Context` for
  immutable conversation history management.
  """

  require Logger

  alias Strider.Context
  alias Beamlens.{CircuitBreaker, Telemetry, Tools}

  @default_max_iterations 10
  @default_timeout :timer.seconds(60)

  @doc """
  Run a health analysis using the agent loop.

  The agent will iteratively select tools to gather information,
  then generate a final health analysis.

  ## Options

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

    backend_config =
      [
        function: "SelectTool",
        path: "priv/baml_src",
        prefix: Beamlens.Baml,
        args_format: :messages
      ]
      |> maybe_add_client_config(llm_client, client_registry)

    agent =
      Strider.Agent.new(
        {Strider.Backends.Baml, backend_config},
        hooks: Beamlens.Telemetry.Hooks
      )

    context =
      Context.new(
        metadata: %{
          trace_id: trace_id,
          started_at: DateTime.utc_now(),
          node: Node.self(),
          iteration: 0,
          tool_count: 0
        }
      )

    loop(agent, context, max_iterations, timeout)
  end

  defp loop(_agent, context, 0, _timeout) do
    Logger.warning("[BeamLens] Agent reached max iterations without completing",
      trace_id: context.metadata.trace_id
    )

    {:error, :max_iterations_exceeded}
  end

  defp loop(agent, context, remaining, timeout) do
    case call_with_timeout(agent, context, timeout) do
      {:ok, response, new_context} ->
        Logger.debug("[BeamLens] Agent selected: #{inspect(response.content)}",
          trace_id: context.metadata.trace_id
        )

        execute_tool(response.content, agent, new_context, remaining - 1, timeout)

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

  defp call_with_timeout(agent, context, timeout) do
    if circuit_breaker_allows?() do
      execute_llm_call(agent, context, timeout)
    else
      Logger.warning("[BeamLens] Circuit breaker open, skipping LLM call",
        trace_id: context.metadata.trace_id
      )

      {:error, :circuit_open}
    end
  end

  defp execute_llm_call(agent, context, timeout) do
    task =
      Task.async(fn ->
        Strider.call(agent, [], context, output_schema: Tools.schema())
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

  defp execute_tool(%Tools.Done{analysis: analysis}, _agent, context, _remaining, _timeout) do
    Logger.info("[BeamLens] Agent completed with status: #{analysis.status}",
      trace_id: context.metadata.trace_id,
      tool_count: context.metadata.tool_count
    )

    {:ok, analysis}
  end

  defp execute_tool(%Tools.GetSystemInfo{intent: intent}, agent, context, remaining, timeout) do
    execute_and_continue(
      agent,
      context,
      "get_system_info",
      intent,
      &Beamlens.Collector.system_info/0,
      remaining,
      timeout
    )
  end

  defp execute_tool(%Tools.GetMemoryStats{intent: intent}, agent, context, remaining, timeout) do
    execute_and_continue(
      agent,
      context,
      "get_memory_stats",
      intent,
      &Beamlens.Collector.memory_stats/0,
      remaining,
      timeout
    )
  end

  defp execute_tool(%Tools.GetProcessStats{intent: intent}, agent, context, remaining, timeout) do
    execute_and_continue(
      agent,
      context,
      "get_process_stats",
      intent,
      &Beamlens.Collector.process_stats/0,
      remaining,
      timeout
    )
  end

  defp execute_tool(%Tools.GetSchedulerStats{intent: intent}, agent, context, remaining, timeout) do
    execute_and_continue(
      agent,
      context,
      "get_scheduler_stats",
      intent,
      &Beamlens.Collector.scheduler_stats/0,
      remaining,
      timeout
    )
  end

  defp execute_tool(%Tools.GetAtomStats{intent: intent}, agent, context, remaining, timeout) do
    execute_and_continue(
      agent,
      context,
      "get_atom_stats",
      intent,
      &Beamlens.Collector.atom_stats/0,
      remaining,
      timeout
    )
  end

  defp execute_tool(%Tools.GetPersistentTerms{intent: intent}, agent, context, remaining, timeout) do
    execute_and_continue(
      agent,
      context,
      "get_persistent_terms",
      intent,
      &Beamlens.Collector.persistent_terms/0,
      remaining,
      timeout
    )
  end

  defp execute_tool(unknown, _agent, context, _remaining, _timeout) do
    Logger.warning("[BeamLens] Unknown tool response: #{inspect(unknown)}",
      trace_id: context.metadata.trace_id
    )

    {:error, {:unknown_tool, unknown}}
  end

  defp execute_and_continue(agent, context, tool_name, intent, tool_fn, remaining, timeout) do
    trace_metadata = %{
      trace_id: context.metadata.trace_id,
      iteration: context.metadata.iteration,
      tool_name: tool_name,
      intent: intent || ""
    }

    result = Telemetry.tool_span(trace_metadata, tool_fn)

    Logger.debug("[BeamLens] Tool #{tool_name} returned: #{inspect(result)}",
      trace_id: context.metadata.trace_id
    )

    case Jason.encode(result) do
      {:ok, encoded} ->
        new_context =
          context
          |> add_tool_message(encoded, %{tool: tool_name})
          |> increment_iteration()
          |> increment_tool_count()

        loop(agent, new_context, remaining, timeout)

      {:error, reason} ->
        Logger.error("[BeamLens] Failed to encode tool result: #{inspect(reason)}",
          trace_id: context.metadata.trace_id,
          tool_name: tool_name
        )

        {:error, {:encoding_failed, tool_name, reason}}
    end
  end

  defp add_tool_message(context, content, metadata) do
    message = %Strider.Message{
      role: :tool,
      content: Strider.Content.wrap(content),
      metadata: metadata
    }

    %{context | messages: context.messages ++ [message]}
  end

  defp increment_iteration(context) do
    put_in(context.metadata.iteration, context.metadata.iteration + 1)
  end

  defp increment_tool_count(context) do
    put_in(context.metadata.tool_count, context.metadata.tool_count + 1)
  end

  defp maybe_add_client_config(config, nil, nil), do: config

  defp maybe_add_client_config(config, _llm_client, client_registry)
       when is_map(client_registry) do
    Keyword.put(config, :client_registry, client_registry)
  end

  defp maybe_add_client_config(config, llm_client, nil) do
    Keyword.put(config, :llm_client, llm_client)
  end
end
