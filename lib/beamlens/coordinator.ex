defmodule Beamlens.Coordinator do
  @moduledoc """
  GenServer that correlates notifications from operators into insights.

  ## Static Supervision

  The Coordinator is started as a static, always-running supervised process.
  It waits in `:idle` status until invoked, then runs its LLM loop.

  ## Notification States

  - `:unread` - New notification, not yet processed
  - `:acknowledged` - Currently being analyzed
  - `:resolved` - Processed (correlated into insight or dismissed)

  ## Running Analysis with `run/2`

  For one-shot analysis, use `run/2` which invokes the static coordinator:

      {:ok, result} = Beamlens.Coordinator.run(%{reason: "memory alert triggered"})

      # result contains:
      # %{insights: [...], operator_results: [...]}

  ## Status

  Coordinator has a run status:
  - `:idle` - Waiting for invocation
  - `:running` - LLM loop is active
  """

  use GenServer

  alias Beamlens.Coordinator.{Insight, NotificationEntry, RunningOperator, Tools}

  alias Beamlens.Coordinator.Tools.{
    Done,
    GetNotifications,
    GetOperatorStatuses,
    InvokeOperators,
    MessageOperator,
    ProduceInsight,
    Think,
    UpdateNotificationStatuses,
    Wait
  }

  alias Beamlens.Operator

  alias Beamlens.Coordinator.Status
  alias Beamlens.LLM.Utils
  alias Beamlens.Telemetry
  alias Puck.Context

  defstruct [
    :name,
    :client,
    :client_registry,
    :context,
    :pending_task,
    :pending_trace_id,
    :caller,
    :skills,
    max_iterations: 10,
    notifications: %{},
    iteration: 0,
    status: :idle,
    insights: [],
    operator_results: [],
    running_operators: %{},
    invocation_queue: :queue.new()
  ]

  @doc """
  Starts the coordinator process.

  ## Options

    * `:name` - Optional process name for registration (default: `nil`, no registration)
    * `:client_registry` - Optional LLM provider configuration map
    * `:puck_client` - Optional `Puck.Client` to use instead of BAML
    * `:compaction_max_tokens` - Token threshold for compaction (default: 50_000)
    * `:compaction_keep_last` - Messages to keep verbatim after compaction (default: 5)

  """
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Returns the current coordinator status.
  """
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc """
  Runs a one-shot coordinator analysis and returns results.

  Invokes the static coordinator and blocks until analysis is complete.
  Raises `ArgumentError` if the coordinator is not started.

  ## Arguments

    * `context` - Map with context for the investigation (e.g., `%{reason: "memory alert"}`)
    * `opts` - Options passed to coordinator

  ## Options

    * `:context` - Map with context (alternative to first argument)
    * `:notifications` - List of `Notification` structs to analyze (default: `[]`)
    * `:puck_client` - Optional `Puck.Client` to use instead of BAML
    * `:max_iterations` - Maximum iterations before stopping (default: 10)
    * `:timeout` - Timeout for await in milliseconds (default: 300_000)
    * `:skills` - List of skill atoms to make available (default: configured operators)

  ## Returns

    * `{:ok, result}` - Analysis completed successfully
    * `{:error, reason}` - Analysis failed

  ## Result Structure

      %{
        insights: [Insight.t()],
        operator_results: [map()]
      }

  ## Examples

      # With specific skills (no pre-configuration needed)
      {:ok, result} = Beamlens.Coordinator.run(%{reason: "memory alert"},
        skills: [Beamlens.Skill.Beam, Beamlens.Skill.Ets, Beamlens.Skill.System]
      )

      # Use all builtins when no operators configured
      {:ok, result} = Beamlens.Coordinator.run(%{reason: "health check"})

      # Context in opts
      {:ok, result} = Beamlens.Coordinator.run(context: %{reason: "memory alert"})

      # With existing notifications
      {:ok, result} = Beamlens.Coordinator.run(%{reason: "investigating spike"},
        notifications: existing_notifications
      )

      # With custom LLM provider
      {:ok, result} = Beamlens.Coordinator.run(%{reason: "health check"},
        client_registry: %{primary: "Ollama", clients: [...]}
      )

  """
  def run(opts) when is_list(opts) do
    {context, opts} = Keyword.pop(opts, :context, %{})
    run(context, opts)
  end

  def run(context) when is_map(context) do
    run(context, [])
  end

  @doc """
  Invokes the static coordinator process directly.

  Use this when you have a reference to the coordinator and want to run
  analysis on it. The coordinator queues the request if already running.
  """
  def run(pid, context, opts) when is_pid(pid) and is_map(context) and is_list(opts) do
    {notifications, opts} = Keyword.pop(opts, :notifications, [])
    timeout = Keyword.get(opts, :timeout, 300_000)
    GenServer.call(pid, {:invoke, context, notifications, opts}, timeout)
  end

  def run(context, opts) when is_map(context) and is_list(opts) do
    case Process.whereis(__MODULE__) do
      nil ->
        raise ArgumentError,
              "Coordinator not started. Add Beamlens to your supervision tree."

      pid ->
        run(pid, context, opts)
    end
  end

  @doc """
  Blocks until the coordinator completes its analysis.

  ## Returns

    * `{:ok, result}` - Analysis completed
    * `{:error, :already_awaiting}` - Another process is already awaiting

  """
  def await(server, timeout \\ 300_000) do
    GenServer.call(server, :await, timeout)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    client = build_puck_client(Keyword.get(opts, :client_registry), opts)

    initial_notifications =
      Keyword.get(opts, :initial_notifications, [])
      |> Enum.reduce(%{}, fn notification, acc ->
        Map.put(acc, notification.id, %NotificationEntry{
          notification: notification,
          status: :unread
        })
      end)

    initial_context = build_initial_context(Keyword.get(opts, :context))

    start_loop = Keyword.get(opts, :start_loop, false)

    state = %__MODULE__{
      name: Keyword.get(opts, :name),
      client: client,
      client_registry: Keyword.get(opts, :client_registry),
      max_iterations: Keyword.get(opts, :max_iterations, 10),
      notifications: initial_notifications,
      context: initial_context,
      skills: Keyword.get(opts, :skills),
      status: if(start_loop, do: :running, else: :idle)
    }

    emit_telemetry(:started, state)

    if start_loop do
      {:ok, state, {:continue, :loop}}
    else
      {:ok, state}
    end
  end

  @impl true
  def terminate(_reason, %{pending_task: %Task{} = task}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_continue(
        :loop,
        %{iteration: iteration, max_iterations: max} = state
      )
      when iteration >= max do
    emit_telemetry(:max_iterations_reached, state, %{iteration: iteration})
    finish(state)
  end

  def handle_continue(:loop, state) do
    trace_id = Telemetry.generate_trace_id()

    emit_telemetry(:iteration_start, state, %{
      trace_id: trace_id,
      iteration: state.iteration
    })

    context = %{
      state.context
      | metadata: Map.put(state.context.metadata || %{}, :trace_id, trace_id)
    }

    task =
      Beamlens.LLMTask.async(fn ->
        Puck.call(state.client, "Process notifications", context, output_schema: Tools.schema())
      end)

    {:noreply, %{state | pending_task: task, pending_trace_id: trace_id}}
  end

  @impl true
  def handle_info({ref, result}, %{pending_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | pending_task: nil}

    case result do
      {:ok, response, new_context} ->
        parsed = ensure_parsed(response.content)
        handle_action(parsed, %{state | context: new_context}, state.pending_trace_id)

      {:error, reason} ->
        emit_telemetry(:llm_error, state, %{trace_id: state.pending_trace_id, reason: reason})
        {:noreply, %{state | status: :idle, pending_trace_id: nil}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{pending_task: %Task{ref: ref}} = state) do
    emit_telemetry(:llm_error, state, %{
      trace_id: state.pending_trace_id,
      reason: {:task_crashed, reason}
    })

    {:noreply, %{state | pending_task: nil, pending_trace_id: nil, status: :idle}}
  end

  def handle_info({:operator_notification, pid, notification}, state) do
    case Map.get(state.running_operators, pid) do
      nil ->
        {:noreply, state}

      _info ->
        new_notifications =
          Map.put(state.notifications, notification.id, %NotificationEntry{
            notification: notification,
            status: :unread
          })

        emit_telemetry(:operator_notification_received, state, %{
          notification_id: notification.id,
          operator_pid: pid
        })

        new_state = %{state | notifications: new_notifications}

        if state.status == :running do
          {:noreply, new_state}
        else
          {:noreply, %{new_state | status: :running}, {:continue, :loop}}
        end
    end
  end

  def handle_info({:operator_complete, pid, skill, result}, state) do
    case Map.get(state.running_operators, pid) do
      nil ->
        {:noreply, state}

      %{ref: ref} ->
        Process.demonitor(ref, [:flush])

        emit_telemetry(:operator_complete, state, %{skill: skill, result: result})

        new_notifications = merge_operator_notifications(state.notifications, result)

        new_state = %{
          state
          | running_operators: Map.delete(state.running_operators, pid),
            notifications: new_notifications,
            operator_results: [Map.put(result, :skill, skill) | state.operator_results]
        }

        {:noreply, new_state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state)
      when not is_struct(state.pending_task, Task) or state.pending_task.ref != ref do
    case find_operator_by_ref(state.running_operators, ref) do
      nil ->
        {:noreply, state}

      {^pid, %{skill: skill}} ->
        emit_telemetry(:operator_crashed, state, %{skill: skill, reason: reason})

        new_state = %{state | running_operators: Map.delete(state.running_operators, pid)}

        {:noreply, new_state}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    case Map.get(state.running_operators, pid) do
      nil ->
        {:noreply, state}

      %{skill: skill, ref: ref} ->
        Process.demonitor(ref, [:flush])
        emit_telemetry(:operator_crashed, state, %{skill: skill, reason: reason})
        new_state = %{state | running_operators: Map.delete(state.running_operators, pid)}
        {:noreply, new_state}
    end
  end

  def handle_info(:continue_after_wait, state) do
    {:noreply, state, {:continue, :loop}}
  end

  def handle_info(msg, state) do
    emit_telemetry(:unexpected_message, state, %{message: inspect(msg)})
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %Status{
      running: state.status == :running,
      notification_count: map_size(state.notifications),
      unread_count: count_by_status(state.notifications, :unread),
      iteration: state.iteration
    }

    {:reply, status, state}
  end

  def handle_call(:await, _from, %{caller: caller} = state) when caller != nil do
    {:reply, {:error, :already_awaiting}, state}
  end

  def handle_call(:await, from, %{status: status} = state) do
    state = %{state | caller: from}

    if status == :running do
      {:noreply, state}
    else
      {:noreply, %{state | status: :running}, {:continue, :loop}}
    end
  end

  def handle_call({:invoke, context, notifications, _opts}, from, %{status: :idle} = state) do
    state = prepare_invocation(state, context, notifications, from)
    {:noreply, %{state | status: :running}, {:continue, :loop}}
  end

  def handle_call({:invoke, context, notifications, opts}, from, %{status: :running} = state) do
    queue = :queue.in({from, context, notifications, opts}, state.invocation_queue)
    {:noreply, %{state | invocation_queue: queue}}
  end

  defp handle_action(%GetNotifications{status: status}, state, trace_id) do
    notifications = filter_notifications(state.notifications, status)

    result =
      Enum.map(notifications, fn {id, %{notification: notification, status: s}} ->
        %{
          id: id,
          status: s,
          operator: notification.operator,
          anomaly_type: notification.anomaly_type,
          severity: notification.severity,
          summary: notification.summary,
          detected_at: notification.detected_at
        }
      end)

    emit_telemetry(:get_notifications, state, %{trace_id: trace_id, count: length(result)})

    new_context = Utils.add_result(state.context, result)

    new_state = %{
      state
      | context: new_context,
        iteration: state.iteration + 1,
        pending_trace_id: nil
    }

    {:noreply, new_state, {:continue, :loop}}
  end

  defp handle_action(
         %UpdateNotificationStatuses{notification_ids: ids, status: status, reason: reason},
         state,
         trace_id
       ) do
    new_notifications = update_notifications_status(state.notifications, ids, status)

    result = %{updated: ids, status: status}
    result = if reason, do: Map.put(result, :reason, reason), else: result

    emit_telemetry(:update_notification_statuses, state, %{
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

  defp handle_action(%ProduceInsight{} = tool, state, trace_id) do
    insight =
      Insight.new(%{
        notification_ids: tool.notification_ids,
        correlation_type: tool.correlation_type,
        summary: tool.summary,
        root_cause_hypothesis: tool.root_cause_hypothesis,
        confidence: tool.confidence
      })

    emit_telemetry(:insight_produced, state, %{
      trace_id: trace_id,
      insight: insight
    })

    new_notifications =
      update_notifications_status(state.notifications, tool.notification_ids, :resolved)

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

  defp handle_action(%Done{}, state, trace_id) do
    running_operator_count = map_size(state.running_operators)
    unread_count = count_by_status(state.notifications, :unread)

    cond do
      running_operator_count > 0 ->
        emit_telemetry(:done_rejected, state, %{
          trace_id: trace_id,
          running_operator_count: running_operator_count
        })

        running_skills =
          state.running_operators
          |> Map.values()
          |> Enum.map_join(", ", &inspect(&1.skill))

        error_message =
          "Cannot complete analysis: #{running_operator_count} operator(s) still running (#{running_skills}). " <>
            "You must wait for all operators to complete before calling done(). " <>
            "Use get_operator_statuses() to check their progress, or wait() to give them time."

        new_context = Utils.add_result(state.context, %{error: error_message})

        new_state = %{
          state
          | context: new_context,
            iteration: state.iteration + 1,
            pending_trace_id: nil
        }

        {:noreply, new_state, {:continue, :loop}}

      unread_count > 0 ->
        emit_telemetry(:done_rejected, state, %{trace_id: trace_id, unread_count: unread_count})

        error_message =
          "Cannot complete analysis: #{unread_count} unread notification(s) remain. " <>
            "You must acknowledge and process all notifications before calling done(). " <>
            "Use get_notifications(status: \"unread\") to see them."

        new_context = Utils.add_result(state.context, %{error: error_message})

        new_state = %{
          state
          | context: new_context,
            iteration: state.iteration + 1,
            pending_trace_id: nil
        }

        {:noreply, new_state, {:continue, :loop}}

      true ->
        emit_telemetry(:done, state, %{trace_id: trace_id, has_unread: false})
        finish(state)
    end
  end

  defp handle_action(%Think{thought: thought}, state, trace_id) do
    emit_telemetry(:think, state, %{trace_id: trace_id})

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

  defp handle_action(%InvokeOperators{skills: skills, context: context}, state, trace_id) do
    emit_telemetry(:invoke_operators, state, %{trace_id: trace_id, skills: skills})

    new_running =
      Enum.reduce(skills, state.running_operators, fn skill, acc ->
        start_operator(skill, context, acc)
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

  defp handle_action(%MessageOperator{skill: skill, message: message}, state, trace_id) do
    emit_telemetry(:message_operator, state, %{trace_id: trace_id, skill: skill})

    skill_module = resolve_skill_module(skill)

    result =
      case skill_module && find_operator_by_skill(state.running_operators, skill_module) do
        nil ->
          %{skill: skill, error: "operator not running"}

        {pid, _info} ->
          case Operator.message(pid, message) do
            {:ok, response} -> response
            {:error, reason} -> %{skill: skill, error: inspect(reason)}
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

  defp handle_action(%GetOperatorStatuses{}, state, trace_id) do
    emit_telemetry(:get_operator_statuses, state, %{trace_id: trace_id})

    statuses =
      Enum.map(state.running_operators, fn {pid, %{skill: skill, started_at: started_at}} ->
        if Process.alive?(pid) do
          status = Operator.status(pid)

          %{
            skill: skill,
            alive: true,
            state: status.state,
            iteration: status.iteration,
            running: status.running,
            started_at: started_at
          }
        else
          %{skill: skill, alive: false}
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

  defp handle_action(%Wait{ms: ms}, state, trace_id) do
    emit_telemetry(:wait, state, %{trace_id: trace_id, ms: ms})

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

  defp finish(state) do
    if state.caller do
      result = %{
        insights: Enum.reverse(state.insights),
        operator_results: Enum.reverse(state.operator_results)
      }

      GenServer.reply(state.caller, {:ok, result})
    end

    case :queue.out(state.invocation_queue) do
      {{:value, {next_caller, next_context, next_notifications, _next_opts}}, remaining_queue} ->
        new_state =
          state
          |> prepare_invocation(next_context, next_notifications, next_caller)
          |> Map.put(:invocation_queue, remaining_queue)
          |> Map.put(:status, :running)

        {:noreply, new_state, {:continue, :loop}}

      {:empty, _} ->
        new_state = %{
          state
          | status: :idle,
            caller: nil,
            notifications: %{},
            insights: [],
            operator_results: [],
            running_operators: %{},
            iteration: 0
        }

        {:noreply, new_state}
    end
  end

  defp prepare_invocation(state, context, notifications, caller) do
    initial_notifications =
      Enum.reduce(notifications, %{}, fn notification, acc ->
        Map.put(acc, notification.id, %NotificationEntry{
          notification: notification,
          status: :unread
        })
      end)

    initial_context = build_initial_context(context)

    %{
      state
      | context: initial_context,
        caller: caller,
        notifications: initial_notifications,
        insights: [],
        operator_results: [],
        running_operators: %{},
        iteration: 0
    }
  end

  defp merge_operator_notifications(notifications, operator_result) do
    Enum.reduce(operator_result.notifications, notifications, fn notification, acc ->
      Map.put(acc, notification.id, %NotificationEntry{
        notification: notification,
        status: :unread
      })
    end)
  end

  defp start_operator(skill_string, context, running_operators) do
    skill_module = resolve_skill_module(skill_string)

    case skill_module && Operator.Supervisor.resolve_skill(skill_module) do
      nil ->
        running_operators

      {:ok, ^skill_module} ->
        case Registry.lookup(Beamlens.OperatorRegistry, skill_module) do
          [{pid, _}] ->
            ref = Process.monitor(pid)
            Operator.run_async(pid, %{reason: context}, notify_pid: self())

            Map.put(running_operators, pid, %RunningOperator{
              skill: skill_module,
              ref: ref,
              started_at: DateTime.utc_now()
            })

          [] ->
            :telemetry.execute(
              [:beamlens, :coordinator, :operator_not_found],
              %{system_time: System.system_time()},
              %{skill: skill_module}
            )

            running_operators
        end

      {:error, _reason} ->
        running_operators
    end
  end

  defp resolve_skill_module(skill_string) do
    module = String.to_existing_atom("Elixir." <> skill_string)

    case Operator.Supervisor.resolve_skill(module) do
      {:ok, ^module} -> module
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp find_operator_by_skill(running_operators, skill_module) do
    Enum.find(running_operators, fn {_pid, %{skill: s}} -> s == skill_module end)
  end

  defp find_operator_by_ref(running_operators, ref) do
    Enum.find(running_operators, fn {_pid, %{ref: r}} -> r == ref end)
  end

  defp filter_notifications(notifications, nil), do: notifications

  defp filter_notifications(notifications, status) do
    notifications
    |> Enum.filter(fn {_, %{status: s}} -> s == status end)
    |> Map.new()
  end

  defp update_notifications_status(notifications, ids, new_status) do
    Enum.reduce(ids, notifications, fn id, acc ->
      case Map.get(acc, id) do
        nil -> acc
        entry -> Map.put(acc, id, %{entry | status: new_status})
      end
    end)
  end

  defp count_by_status(notifications, status) do
    Enum.count(notifications, fn {_, %{status: s}} -> s == status end)
  end

  defp ensure_parsed(%{__struct__: _} = struct), do: struct

  defp ensure_parsed(map) when is_map(map) do
    {:ok, parsed} = Zoi.parse(Tools.schema(), map)
    parsed
  end

  defp build_puck_client(client_registry, opts) when is_list(opts) do
    build_puck_client(client_registry, Map.new(opts))
  end

  defp build_puck_client(_client_registry, %{puck_client: %Puck.Client{} = client}) do
    client
  end

  defp build_puck_client(client_registry, opts) when is_map(opts) do
    skills = Map.get(opts, :skills)
    operator_descriptions = build_operator_descriptions(skills)
    available_skills = build_available_skills(skills)

    backend_config =
      %{
        function: "CoordinatorRun",
        args_format: :auto,
        args: fn messages ->
          %{
            messages: Utils.format_messages_for_baml(messages),
            operator_descriptions: operator_descriptions,
            available_skills: available_skills
          }
        end,
        path: Application.app_dir(:beamlens, "priv/baml_src")
      }
      |> Utils.maybe_add_client_registry(client_registry)

    Puck.Client.new(
      {Puck.Backends.Baml, backend_config},
      hooks: Beamlens.Telemetry.Hooks,
      auto_compaction: build_compaction_config(opts)
    )
  end

  defp build_available_skills(nil) do
    case Operator.Supervisor.configured_operators() do
      [] ->
        Operator.Supervisor.builtin_skills()
        |> Enum.map_join(", ", &module_name/1)

      operators ->
        Enum.map_join(operators, ", ", &module_name/1)
    end
  end

  defp build_available_skills(skills) when is_list(skills) do
    Enum.map_join(skills, ", ", &module_name/1)
  end

  defp build_operator_descriptions(nil) do
    case Application.get_env(:beamlens, :skills, nil) do
      nil ->
        build_descriptions_for_skills(Operator.Supervisor.builtin_skills())

      skills ->
        skills
        |> Enum.map(&Operator.Supervisor.resolve_skill/1)
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map_join("\n", fn {:ok, skill} ->
          "- #{module_name(skill)}: #{skill.description()}"
        end)
    end
  end

  defp build_operator_descriptions(skills) when is_list(skills) do
    build_descriptions_for_skills(skills)
  end

  defp build_descriptions_for_skills(skills) do
    skills
    |> Enum.map(&Operator.Supervisor.resolve_skill/1)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map_join("\n", fn {:ok, skill} ->
      "- #{module_name(skill)}: #{skill.description()}"
    end)
  end

  defp module_name(module) when is_atom(module) do
    module |> Module.split() |> Enum.join(".")
  end

  @doc false
  def build_initial_context(nil), do: Context.new()

  @doc false
  def build_initial_context(context) when is_map(context) and map_size(context) == 0,
    do: Context.new()

  @doc false
  def build_initial_context(context) when is_map(context) do
    message = format_initial_context_message(context)
    ctx = Context.new()
    %{ctx | messages: [Puck.Message.new(:user, message)]}
  end

  defp format_initial_context_message(context) do
    parts =
      Enum.flat_map(context, fn
        {:reason, reason} when is_binary(reason) -> ["Reason: #{reason}"]
        {:reason, reason} -> ["Reason: #{inspect(reason)}"]
        {key, value} when is_binary(value) -> ["#{key}: #{value}"]
        {key, value} -> ["#{key}: #{inspect(value)}"]
      end)

    case parts do
      [] -> "Analyze the system"
      _ -> Enum.join(parts, "\n")
    end
  end

  defp build_compaction_config(opts) when is_map(opts) do
    max_tokens = Map.get(opts, :compaction_max_tokens, 50_000)
    keep_last = Map.get(opts, :compaction_keep_last, 5)

    {:summarize,
     max_tokens: max_tokens, keep_last: keep_last, prompt: coordinator_compaction_prompt()}
  end

  defp coordinator_compaction_prompt do
    """
    Summarize this notification analysis session, preserving:
    - Notification IDs and their statuses (exact IDs required)
    - Correlations identified between notifications
    - Insights produced and their reasoning
    - Pending analysis or patterns being investigated
    - Any notifications still needing attention

    Be concise. This summary will be used to continue correlation analysis.
    """
  end

  defp emit_telemetry(event, state, extra \\ %{}) do
    :telemetry.execute(
      [:beamlens, :coordinator, event],
      %{system_time: System.system_time()},
      Map.merge(
        %{
          running: state.status == :running,
          notification_count: map_size(state.notifications)
        },
        extra
      )
    )
  end
end
