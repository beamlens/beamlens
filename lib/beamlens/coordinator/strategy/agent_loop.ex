defmodule Beamlens.Coordinator.Strategy.AgentLoop do
  @moduledoc """
  Iterative agentic loop strategy for the coordinator.

  This is the default strategy that implements the original coordinator
  execution pattern: an iterative loop of up to N LLM iterations with
  tool-calling. The LLM selects tools, the strategy handles each tool
  action, and returns control to the coordinator loop.
  """

  @behaviour Beamlens.Coordinator.Strategy

  alias Beamlens.Coordinator
  alias Beamlens.Coordinator.{Insight, NotificationView, OperatorStatusView}

  alias Beamlens.Coordinator.Tools.{
    Done,
    GetNotifications,
    GetOperatorStatuses,
    InvokeOperators,
    MessageOperator,
    ProduceInsight,
    Schedule,
    Think,
    UpdateNotificationStatuses,
    Wait
  }

  alias Beamlens.LLM.Utils
  alias Beamlens.Operator

  @impl true
  def handle_action(%GetNotifications{status: status}, state, trace_id) do
    notifications = Coordinator.filter_notifications(state.notifications, status)

    result =
      Enum.map(notifications, fn {id, entry} ->
        NotificationView.from_entry(id, entry)
      end)

    Coordinator.emit_telemetry(:get_notifications, state, %{
      trace_id: trace_id,
      status: status,
      count: length(result)
    })

    new_context = Utils.add_result(state.context, result)

    new_state = %{
      state
      | context: new_context,
        iteration: state.iteration + 1,
        pending_trace_id: nil
    }

    {:noreply, new_state, {:continue, :loop}}
  end

  @impl true
  def handle_action(
        %UpdateNotificationStatuses{notification_ids: ids, status: status, reason: reason},
        state,
        trace_id
      ) do
    new_notifications = Coordinator.update_notifications_status(state.notifications, ids, status)

    result = %{updated: ids, status: status}
    result = if reason, do: Map.put(result, :reason, reason), else: result

    Coordinator.emit_telemetry(:update_notification_statuses, state, %{
      trace_id: trace_id,
      notification_ids: ids,
      status: status
    })

    new_context = Utils.add_result(state.context, result)

    new_state = %{
      state
      | notifications: new_notifications,
        context: new_context,
        iteration: state.iteration + 1,
        pending_trace_id: nil
    }

    {:noreply, new_state, {:continue, :loop}}
  end

  @impl true
  def handle_action(%ProduceInsight{} = tool, state, trace_id) do
    insight =
      Insight.new(%{
        notification_ids: tool.notification_ids,
        correlation_type: tool.correlation_type,
        summary: tool.summary,
        matched_observations: tool.matched_observations,
        hypothesis_grounded: tool.hypothesis_grounded,
        root_cause_hypothesis: tool.root_cause_hypothesis,
        confidence: tool.confidence
      })

    Coordinator.emit_telemetry(:insight_produced, state, %{
      trace_id: trace_id,
      insight: insight
    })

    new_notifications =
      Coordinator.update_notifications_status(
        state.notifications,
        tool.notification_ids,
        :resolved
      )

    new_context = Utils.add_result(state.context, %{insight_produced: insight.id})

    new_state = %{
      state
      | notifications: new_notifications,
        context: new_context,
        insights: [insight | state.insights],
        iteration: state.iteration + 1,
        pending_trace_id: nil
    }

    {:noreply, new_state, {:continue, :loop}}
  end

  @impl true
  def handle_action(%Done{}, state, trace_id) do
    running_operator_count = map_size(state.running_operators)
    unread_count = Coordinator.count_by_status(state.notifications, :unread)

    if running_operator_count > 0 do
      reject_with_running_operators(state, trace_id, :done_rejected, "complete analysis")
    else
      Coordinator.emit_telemetry(:done, state, %{
        trace_id: trace_id,
        has_unread: unread_count > 0,
        unread_count: unread_count
      })

      {:finish, state}
    end
  end

  @impl true
  def handle_action(%Think{thought: thought}, state, trace_id) do
    Coordinator.emit_telemetry(:think, state, %{trace_id: trace_id, thought: thought})

    result = %{thought: thought, recorded: true}
    new_context = Utils.add_result(state.context, result)

    new_state = %{
      state
      | context: new_context,
        iteration: state.iteration + 1,
        pending_trace_id: nil
    }

    {:noreply, new_state, {:continue, :loop}}
  end

  @impl true
  def handle_action(%InvokeOperators{skills: skills, context: context}, state, trace_id) do
    Coordinator.emit_telemetry(:invoke_operators, state, %{trace_id: trace_id, skills: skills})

    new_running =
      Enum.reduce(skills, state.running_operators, fn skill, acc ->
        Coordinator.start_operator(skill, context, acc)
      end)

    started_count = map_size(new_running) - map_size(state.running_operators)
    result = %{started: skills, count: started_count}
    new_context = Utils.add_result(state.context, result)

    new_state = %{
      state
      | running_operators: new_running,
        context: new_context,
        iteration: state.iteration + 1,
        pending_trace_id: nil
    }

    {:noreply, new_state, {:continue, :loop}}
  end

  @impl true
  def handle_action(%MessageOperator{skill: skill, message: message}, state, trace_id) do
    Coordinator.emit_telemetry(:message_operator, state, %{trace_id: trace_id, skill: skill})

    skill_module = Coordinator.resolve_skill_module(skill)

    result =
      case skill_module &&
             Coordinator.find_operator_by_skill(state.running_operators, skill_module) do
        nil ->
          %{skill: skill, error: "operator not running"}

        {pid, _info} ->
          try do
            case Operator.message(pid, message) do
              {:ok, response} -> response
              {:error, reason} -> %{skill: skill, error: inspect(reason)}
            end
          catch
            :exit, _ -> %{skill: skill, error: "operator timed out"}
          end
      end

    new_context = Utils.add_result(state.context, result)

    new_state = %{
      state
      | context: new_context,
        iteration: state.iteration + 1,
        pending_trace_id: nil
    }

    {:noreply, new_state, {:continue, :loop}}
  end

  @impl true
  def handle_action(%GetOperatorStatuses{}, state, trace_id) do
    Coordinator.emit_telemetry(:get_operator_statuses, state, %{trace_id: trace_id})

    statuses =
      Enum.map(state.running_operators, fn {pid, %{skill: skill, started_at: started_at}} ->
        try do
          status = Operator.status(pid)
          OperatorStatusView.alive(skill, status, started_at)
        catch
          :exit, _ -> OperatorStatusView.dead(skill)
        end
      end)

    new_context = Utils.add_result(state.context, statuses)

    new_state = %{
      state
      | context: new_context,
        iteration: state.iteration + 1,
        pending_trace_id: nil
    }

    {:noreply, new_state, {:continue, :loop}}
  end

  @impl true
  def handle_action(%Schedule{ms: ms, reason: reason}, state, trace_id) do
    if map_size(state.running_operators) > 0 do
      reject_with_running_operators(state, trace_id, :schedule_rejected, "schedule follow-up")
    else
      Coordinator.emit_telemetry(:schedule, state, %{
        trace_id: trace_id,
        ms: ms,
        reason: reason
      })

      timer_ref = Process.send_after(self(), {:scheduled_reinvoke, reason}, ms)

      {:finish, %{state | scheduled_timer_ref: timer_ref}}
    end
  end

  @impl true
  def handle_action(%Wait{ms: ms}, state, trace_id) do
    Coordinator.emit_telemetry(:wait, state, %{trace_id: trace_id, ms: ms})

    Process.send_after(self(), :continue_after_wait, ms)

    new_context = Utils.add_result(state.context, %{waited: ms})

    new_state = %{
      state
      | context: new_context,
        iteration: state.iteration + 1,
        pending_trace_id: nil
    }

    {:noreply, new_state}
  end

  defp reject_with_running_operators(state, trace_id, telemetry_event, action_name) do
    running_operator_count = map_size(state.running_operators)

    Coordinator.emit_telemetry(telemetry_event, state, %{
      trace_id: trace_id,
      running_operator_count: running_operator_count
    })

    running_skills =
      state.running_operators
      |> Map.values()
      |> Enum.map_join(", ", &inspect(&1.skill))

    error_message =
      "Cannot #{action_name}: #{running_operator_count} operator(s) still running (#{running_skills}). " <>
        "You must wait for all operators to complete before proceeding. " <>
        "Use get_operator_statuses() to check their progress, or wait() to give them time."

    new_context = Utils.add_result(state.context, %{error: error_message})

    new_state = %{
      state
      | context: new_context,
        iteration: state.iteration + 1,
        pending_trace_id: nil
    }

    {:noreply, new_state, {:continue, :loop}}
  end
end
