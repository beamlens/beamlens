defmodule Beamlens.Judge do
  @moduledoc """
  Reviews health analyses for accuracy and data support.

  The judge evaluates whether the agent's conclusions are justified by
  the collected metrics, checking for data sufficiency, threshold accuracy,
  and concern-data alignment.
  """

  require Logger

  alias Beamlens.Events.{JudgeCall, LLMCall, ToolCall}
  alias Beamlens.{HealthAnalysis, Telemetry}
  alias Puck.Context

  @default_timeout :timer.seconds(30)

  defmodule Feedback do
    @moduledoc false
    defstruct [:verdict, :confidence, :issues, :feedback]
  end

  def feedback_schema do
    Zoi.object(%{
      verdict: Zoi.enum(["accept", "retry"]),
      confidence: Zoi.enum(["high", "medium", "low"]),
      issues: Zoi.list(Zoi.string()),
      feedback: Zoi.string()
    })
    |> Zoi.transform(fn data ->
      {:ok,
       %Feedback{
         verdict: String.to_existing_atom(data.verdict),
         confidence: String.to_existing_atom(data.confidence),
         issues: data.issues,
         feedback: data.feedback
       }}
    end)
  end

  @doc """
  Review a health analysis for quality and accuracy.

  Takes a complete `HealthAnalysis` (with events attached) and evaluates
  whether the conclusions are supported by the collected data.

  ## Options

    * `:attempt` - The current attempt number (default: 1)
    * `:timeout` - Timeout in milliseconds (default: 30000)
    * `:llm_client` - LLM client name for the judge
    * `:client_registry` - Full LLM client configuration
    * `:trace_id` - Correlation ID for telemetry

  ## Returns

    * `{:ok, %JudgeCall{}}` - The judge's evaluation
    * `{:error, reason}` - If the judge call failed
  """
  def review(%HealthAnalysis{} = analysis, opts \\ []) do
    attempt = Keyword.get(opts, :attempt, 1)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    llm_client = Keyword.get(opts, :llm_client)
    client_registry = Keyword.get(opts, :client_registry)
    trace_id = Keyword.get(opts, :trace_id)

    event_trail = format_events(analysis.events)
    analysis_input = analysis_to_map(analysis)

    backend_config =
      %{
        function: "JudgeAnalysis",
        args_format: :raw,
        args: %{
          analysis: analysis_input,
          event_trail: event_trail,
          attempt: attempt
        },
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
          trace_id: trace_id || Telemetry.generate_trace_id(),
          operation: :judge,
          attempt: attempt
        }
      )

    trace_metadata = %{trace_id: trace_id, attempt: attempt}
    Telemetry.emit_judge_start(trace_metadata)
    start_time = System.monotonic_time()

    case call_with_timeout(client, context, timeout) do
      {:ok, response, _context} ->
        feedback = response.content

        judge_event = %JudgeCall{
          occurred_at: DateTime.utc_now(),
          attempt: attempt,
          verdict: feedback.verdict,
          confidence: feedback.confidence,
          issues: feedback.issues,
          feedback: feedback.feedback
        }

        Telemetry.emit_judge_stop(trace_metadata, judge_event, start_time)
        {:ok, judge_event}

      {:error, reason} = error ->
        Logger.warning("[BeamLens.Judge] Review failed: #{inspect(reason)}")
        Telemetry.emit_judge_exception(trace_metadata, reason, start_time)
        error
    end
  end

  defp call_with_timeout(client, context, timeout) do
    task =
      Task.async(fn ->
        Puck.call(client, [], context, output_schema: feedback_schema())
      end)

    case Task.yield(task, timeout) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end

  defp format_events(events) when is_list(events) do
    Enum.map_join(events, "\n", &format_event/1)
  end

  defp format_events(_), do: ""

  defp format_event(%LLMCall{} = e) do
    "[LLM] iteration=#{e.iteration} selected=#{e.tool_selected}"
  end

  defp format_event(%ToolCall{} = e) do
    result_json = Jason.encode!(e.result)
    "[TOOL] #{e.intent}: #{result_json}"
  end

  defp format_event(%JudgeCall{} = e) do
    "[JUDGE] attempt=#{e.attempt} verdict=#{e.verdict}"
  end

  defp format_event(_unknown), do: ""

  defp analysis_to_map(%HealthAnalysis{} = analysis) do
    %{
      status: to_string(analysis.status),
      summary: analysis.summary,
      concerns: analysis.concerns,
      recommendations: analysis.recommendations
    }
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
