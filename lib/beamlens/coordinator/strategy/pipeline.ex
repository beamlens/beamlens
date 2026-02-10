defmodule Beamlens.Coordinator.Strategy.Pipeline do
  @moduledoc """
  Decomposed classify-gather-synthesize strategy for the coordinator.

  Replaces the iterative agent loop with three focused stages:

    1. **Classify** — Single LLM call to determine intent and select skills
    2. **Gather** — Invoke operators with focused context, await completion
    3. **Synthesize** — Single LLM call to produce a human-readable answer

  This strategy uses fewer, more focused LLM calls compared to `AgentLoop`,
  making it faster and cheaper for straightforward queries.

      Beamlens.Coordinator.run(%{reason: "What OS is running?"}, strategy: Pipeline)

  """

  @behaviour Beamlens.Coordinator.Strategy

  alias Beamlens.Coordinator
  alias Beamlens.Coordinator.{Insight, NotificationView}
  alias Beamlens.Coordinator.Strategy.Pipeline.Tools, as: PipelineTools
  alias Beamlens.Coordinator.Strategy.Pipeline.Tools.{ClassifyResult, SynthesizeResult}
  alias Beamlens.LLM.Utils

  @gather_poll_ms 500

  @impl true
  def continue_loop(%{strategy_state: nil} = state, trace_id) do
    Coordinator.emit_telemetry(:pipeline_classify_start, state, %{trace_id: trace_id})

    query = extract_query(state.context)
    available_skills = Coordinator.build_operator_descriptions(state.skills)

    client =
      build_pipeline_client(
        "PipelineClassify",
        %{query: query, available_skills: available_skills},
        state.client_registry
      )

    task =
      Beamlens.LLMTask.async(fn ->
        Puck.call(client, query, Puck.Context.new(),
          output_schema: PipelineTools.classify_schema()
        )
      end)

    {:noreply,
     %{state | strategy_state: :classifying, pending_task: task, pending_trace_id: trace_id}}
  end

  def continue_loop(%{strategy_state: :gathering} = state, trace_id) do
    if map_size(state.running_operators) == 0 do
      start_synthesize(state, trace_id)
    else
      Process.send_after(self(), :continue_after_wait, @gather_poll_ms)
      {:noreply, %{state | pending_trace_id: nil}}
    end
  end

  @impl true
  def handle_action(%ClassifyResult{} = result, state, trace_id) do
    Coordinator.emit_telemetry(:pipeline_classify_complete, state, %{
      trace_id: trace_id,
      intent: result.intent,
      skills: result.skills
    })

    new_running =
      Enum.reduce(result.skills, state.running_operators, fn skill, acc ->
        Coordinator.start_operator(skill, result.operator_context, acc)
      end)

    started_count = map_size(new_running) - map_size(state.running_operators)

    new_state = %{
      state
      | running_operators: new_running,
        strategy_state: :gathering,
        iteration: state.iteration + 1,
        pending_trace_id: nil
    }

    if started_count == 0 do
      {:noreply, new_state, {:continue, :loop}}
    else
      Process.send_after(self(), :continue_after_wait, @gather_poll_ms)
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_action(%SynthesizeResult{answer: answer}, state, trace_id) do
    Coordinator.emit_telemetry(:pipeline_synthesize_complete, state, %{
      trace_id: trace_id
    })

    notification_ids = Map.keys(state.notifications)

    insights =
      case notification_ids do
        [] ->
          state.insights

        [_ | _] ->
          insight =
            Insight.new(%{
              notification_ids: notification_ids,
              correlation_type: :symptomatic,
              summary: answer,
              matched_observations: extract_observations(state.notifications),
              hypothesis_grounded: false,
              confidence: :medium
            })

          [insight | state.insights]
      end

    new_notifications =
      Coordinator.update_notifications_status(
        state.notifications,
        notification_ids,
        :resolved
      )

    new_state = %{
      state
      | notifications: new_notifications,
        insights: insights,
        strategy_state: :done,
        iteration: state.iteration + 1,
        pending_trace_id: nil
    }

    {:finish, new_state}
  end

  defp start_synthesize(state, trace_id) do
    Coordinator.emit_telemetry(:pipeline_synthesize_start, state, %{trace_id: trace_id})

    query = extract_query(state.context)
    operator_data = build_operator_data(state.notifications)

    client =
      build_pipeline_client(
        "PipelineSynthesize",
        %{query: query, operator_data: operator_data},
        state.client_registry
      )

    task =
      Beamlens.LLMTask.async(fn ->
        Puck.call(client, query, Puck.Context.new(),
          output_schema: PipelineTools.synthesize_schema()
        )
      end)

    {:noreply,
     %{state | strategy_state: :synthesizing, pending_task: task, pending_trace_id: trace_id}}
  end

  defp extract_query(%Puck.Context{messages: []}) do
    "Analyze the system"
  end

  defp extract_query(%Puck.Context{messages: [first | _]}) do
    Utils.extract_text_content(first.content)
  end

  defp build_operator_data(notifications) do
    notifications
    |> Enum.map(fn {id, entry} ->
      id
      |> NotificationView.from_entry(entry)
      |> Map.from_struct()
      |> Map.take([:id, :operator, :severity, :context, :observation, :detected_at])
    end)
    |> Jason.encode!()
  end

  defp extract_observations(notifications) do
    notifications
    |> Map.values()
    |> Enum.map(fn %{notification: n} -> n.observation end)
  end

  defp build_pipeline_client(function, args, client_registry) do
    backend_config =
      %{
        function: function,
        args_format: :raw,
        args: args,
        path: Application.app_dir(:beamlens, "priv/baml_src")
      }
      |> Utils.maybe_add_client_registry(client_registry)

    Puck.Client.new({Puck.Backends.Baml, backend_config}, hooks: Beamlens.Telemetry.Hooks)
  end
end
