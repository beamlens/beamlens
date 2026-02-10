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

  ## Strategy

  The coordinator delegates tool dispatch to a pluggable strategy module.
  The default strategy is `Beamlens.Coordinator.Strategy.AgentLoop`, which
  implements an iterative agentic loop with tool-calling. Pass `:strategy`
  to `start_link/1` or `run/2` to use a different strategy.

  See `Beamlens.Coordinator.Strategy` for how to implement custom strategies.

  ## Status

  Coordinator has a run status:
  - `:idle` - Waiting for invocation
  - `:running` - LLM loop is active
  """

  use GenServer

  alias Beamlens.Coordinator.{
    NotificationEntry,
    RunningOperator,
    Tools
  }

  alias Beamlens.Operator

  alias Beamlens.Coordinator.Status
  alias Beamlens.LLM.Utils
  alias Beamlens.Telemetry
  alias Puck.Context

  @default_strategy Beamlens.Coordinator.Strategy.AgentLoop

  defstruct [
    :name,
    :client,
    :client_registry,
    :context,
    :pending_task,
    :pending_trace_id,
    :caller,
    :skills,
    :caller_monitor_ref,
    :deadline_timer_ref,
    :scheduled_timer_ref,
    :strategy,
    max_iterations: 25,
    notifications: %{},
    iteration: 0,
    status: :idle,
    insights: [],
    operator_results: [],
    running_operators: %{},
    invocation_queue: :queue.new()
  ]

  @default_deadline 300_000

  @doc """
  Starts the coordinator process.

  ## Options

    * `:name` - Optional process name for registration (default: `nil`, no registration)
    * `:client_registry` - Optional LLM provider configuration map
    * `:puck_client` - Optional `Puck.Client` to use instead of BAML
    * `:compaction_max_tokens` - Token threshold for compaction (default: 50_000)
    * `:compaction_keep_last` - Messages to keep verbatim after compaction (default: 5)
    * `:strategy` - Strategy module for tool dispatch (default: `Beamlens.Coordinator.Strategy.AgentLoop`)

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
    * `:max_iterations` - Maximum iterations before stopping (default: 25)
    * `:timeout` - Timeout for the `GenServer.call` in milliseconds (default: 300_000)
    * `:deadline` - Server-side deadline in milliseconds (default: value of `:timeout`).
      When exceeded, the coordinator stops the investigation and returns
      `{:error, :deadline_exceeded}`. Unlike `:timeout`, this cancels the
      server-side work (stops operators, shuts down the LLM task).
    * `:skills` - List of skill atoms to make available (default: configured operators)
    * `:strategy` - Strategy module for tool dispatch (default: coordinator's configured strategy)

  ## Returns

    * `{:ok, result}` - Analysis completed successfully
    * `{:error, :deadline_exceeded}` - Server-side deadline expired
    * `{:error, :cancelled}` - Investigation was cancelled via `cancel/1`

  ## Result Structure

      %{
        insights: [Insight.t()],
        operator_results: [map()]
      }

  ## Examples

      # With specific skills (no pre-configuration needed)
      {:ok, result} = Beamlens.Coordinator.run(%{reason: "memory alert"},
        skills: [Beamlens.Skill.Beam, Beamlens.Skill.Ets, Beamlens.Skill.Os]
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
    timeout = Keyword.get(opts, :timeout, @default_deadline)
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

  @doc """
  Cancels a running investigation.

  If an investigation is running, it will be stopped and the caller will
  receive `{:error, :cancelled}`. If no investigation is running, this is a no-op.

  Returns `:ok` immediately.
  """
  def cancel(server) do
    GenServer.call(server, :cancel)
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
      max_iterations: Keyword.get(opts, :max_iterations, 25),
      notifications: initial_notifications,
      context: initial_context,
      skills: Keyword.get(opts, :skills),
      strategy: Keyword.get(opts, :strategy, @default_strategy),
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
  def terminate(_reason, state) do
    if match?(%Task{}, state.pending_task) do
      try do
        Task.shutdown(state.pending_task, :brutal_kill)
      catch
        _, _ -> :ok
      end
    end

    cancel_deadline_timer(state)
    cancel_scheduled_timer(state)
    demonitor_caller(state)
    :ok
  end

  @impl true
  def handle_continue(
        :loop,
        %{iteration: iteration, max_iterations: max} = state
      )
      when iteration >= max do
    emit_telemetry(:max_iterations_reached, state, %{iteration: iteration})

    running_operator_count = map_size(state.running_operators)
    unread_count = count_by_status(state.notifications, :unread)

    cond do
      running_operator_count > 0 ->
        running_skills =
          state.running_operators
          |> Map.values()
          |> Enum.map_join(", ", &inspect(&1.skill))

        error_message =
          "Max iterations (#{max}) reached but #{running_operator_count} operator(s) still running (#{running_skills}). " <>
            "Waiting for operators to complete before finishing."

        new_context = Utils.add_result(state.context, %{warning: error_message})
        {:noreply, %{state | context: new_context}}

      unread_count > 0 ->
        error_message =
          "Max iterations (#{max}) reached but #{unread_count} unread notification(s) remain. " <>
            "Finishing with unprocessed notifications."

        new_context = Utils.add_result(state.context, %{warning: error_message})
        finish(%{state | context: new_context})

      true ->
        finish(state)
    end
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
        state = %{state | context: new_context}
        dispatch_action(response.content, state)

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

        if should_finish_after_max_iterations?(new_state) do
          finish(new_state)
        else
          {:noreply, new_state}
        end
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{caller_monitor_ref: ref, status: :running} = state
      ) do
    cancel_invocation(state, :caller_down)
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

  def handle_info({:scheduled_reinvoke, reason}, %{status: :idle} = state) do
    emit_telemetry(:scheduled_reinvoke, state, %{reason: reason})

    new_state =
      state
      |> reset_investigation_fields()
      |> Map.merge(%{
        status: :running,
        context: build_initial_context(%{reason: reason}),
        deadline_timer_ref: Process.send_after(self(), :deadline_exceeded, @default_deadline)
      })

    {:noreply, new_state, {:continue, :loop}}
  end

  def handle_info({:scheduled_reinvoke, _reason}, state) do
    {:noreply, %{state | scheduled_timer_ref: nil}}
  end

  def handle_info(:continue_after_wait, state) do
    {:noreply, state, {:continue, :loop}}
  end

  def handle_info(:deadline_exceeded, %{status: :running} = state) do
    cancel_invocation(state, :deadline_exceeded)
  end

  def handle_info(:deadline_exceeded, state) do
    {:noreply, state}
  end

  def handle_info(:cancel_invocation, %{status: :running} = state) do
    cancel_invocation(state, :cancelled)
  end

  def handle_info(:cancel_invocation, state) do
    {:noreply, state}
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
    {caller_pid, _} = from
    caller_monitor_ref = Process.monitor(caller_pid)
    state = %{state | caller: from, caller_monitor_ref: caller_monitor_ref}

    if status == :running do
      {:noreply, state}
    else
      {:noreply, %{state | status: :running}, {:continue, :loop}}
    end
  end

  def handle_call({:invoke, context, notifications, opts}, from, %{status: :idle} = state) do
    deadline = Keyword.get(opts, :deadline, Keyword.get(opts, :timeout, @default_deadline))
    strategy = Keyword.get(opts, :strategy, state.strategy)
    state = prepare_invocation(state, context, notifications, from, deadline)
    {:noreply, %{state | status: :running, strategy: strategy}, {:continue, :loop}}
  end

  def handle_call({:invoke, context, notifications, opts}, from, %{status: :running} = state) do
    queue = :queue.in({from, context, notifications, opts}, state.invocation_queue)
    {:noreply, %{state | invocation_queue: queue}}
  end

  def handle_call(:cancel, _from, %{status: :running} = state) do
    send(self(), :cancel_invocation)
    {:reply, :ok, state}
  end

  def handle_call(:cancel, _from, state) do
    {:reply, :ok, state}
  end

  defp dispatch_action(content, state) do
    case ensure_parsed(content) do
      {:ok, parsed} ->
        case state.strategy.handle_action(parsed, state, state.pending_trace_id) do
          {:finish, new_state} -> finish(new_state)
          other -> other
        end

      {:error, reason} ->
        emit_telemetry(:invalid_intent, state, %{
          trace_id: state.pending_trace_id,
          reason: reason
        })

        error_message = "Invalid tool selection: #{inspect(reason)}"
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

  defp finish(state) do
    cancel_deadline_timer(state)
    demonitor_caller(state)

    if state.caller do
      result = %{
        insights: Enum.reverse(state.insights),
        operator_results: Enum.reverse(state.operator_results)
      }

      GenServer.reply(state.caller, {:ok, result})
    end

    dequeue_or_idle(%{state | caller: nil, caller_monitor_ref: nil, deadline_timer_ref: nil})
  end

  defp cancel_invocation(state, reason) do
    if match?(%Task{}, state.pending_task), do: Task.shutdown(state.pending_task, :brutal_kill)

    stop_all_operators(state.running_operators)

    cancel_deadline_timer(state)
    cancel_scheduled_timer(state)
    demonitor_caller(state)

    emit_telemetry(reason, state)

    if reason != :caller_down && state.caller do
      GenServer.reply(state.caller, {:error, reason})
    end

    dequeue_or_idle(%{
      state
      | pending_task: nil,
        pending_trace_id: nil,
        caller: nil,
        caller_monitor_ref: nil,
        deadline_timer_ref: nil,
        scheduled_timer_ref: nil
    })
  end

  defp dequeue_or_idle(state) do
    case :queue.out(state.invocation_queue) do
      {{:value, {next_caller, next_context, next_notifications, next_opts}}, remaining_queue} ->
        deadline =
          Keyword.get(next_opts, :deadline, Keyword.get(next_opts, :timeout, @default_deadline))

        strategy = Keyword.get(next_opts, :strategy, state.strategy)

        new_state =
          state
          |> prepare_invocation(next_context, next_notifications, next_caller, deadline)
          |> Map.put(:invocation_queue, remaining_queue)
          |> Map.put(:status, :running)
          |> Map.put(:strategy, strategy)

        {:noreply, new_state, {:continue, :loop}}

      {:empty, _} ->
        new_state =
          state
          |> reset_investigation_fields()
          |> Map.put(:status, :idle)
          |> Map.put(:deadline_timer_ref, nil)

        {:noreply, new_state}
    end
  end

  defp prepare_invocation(state, context, notifications, caller, deadline) do
    cancel_scheduled_timer(state)

    {caller_pid, _} = caller
    caller_monitor_ref = Process.monitor(caller_pid)
    deadline_timer_ref = Process.send_after(self(), :deadline_exceeded, deadline)

    initial_notifications =
      Enum.reduce(notifications, %{}, fn notification, acc ->
        Map.put(acc, notification.id, %NotificationEntry{
          notification: notification,
          status: :unread
        })
      end)

    state
    |> reset_investigation_fields()
    |> Map.merge(%{
      context: build_initial_context(context),
      caller: caller,
      caller_monitor_ref: caller_monitor_ref,
      deadline_timer_ref: deadline_timer_ref,
      notifications: initial_notifications
    })
  end

  defp reset_investigation_fields(state) do
    %{
      state
      | notifications: %{},
        insights: [],
        operator_results: [],
        running_operators: %{},
        iteration: 0,
        caller: nil,
        caller_monitor_ref: nil,
        scheduled_timer_ref: nil
    }
  end

  defp cancel_deadline_timer(%{deadline_timer_ref: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
  end

  defp cancel_deadline_timer(_state), do: :ok

  defp cancel_scheduled_timer(%{scheduled_timer_ref: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
  end

  defp cancel_scheduled_timer(_state), do: :ok

  defp demonitor_caller(%{caller_monitor_ref: ref}) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
  end

  defp demonitor_caller(_state), do: :ok

  defp stop_all_operators(running_operators) do
    Enum.each(running_operators, fn {pid, %{ref: ref}} ->
      Process.demonitor(ref, [:flush])

      try do
        Operator.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp merge_operator_notifications(notifications, operator_result) do
    Enum.reduce(operator_result.notifications, notifications, fn notification, acc ->
      Map.put(acc, notification.id, %NotificationEntry{
        notification: notification,
        status: :unread
      })
    end)
  end

  @doc false
  def start_operator(skill_string, context, running_operators) do
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

  @doc false
  def resolve_skill_module(skill_string) do
    module = String.to_existing_atom("Elixir." <> skill_string)

    case Operator.Supervisor.resolve_skill(module) do
      {:ok, ^module} -> module
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc false
  def find_operator_by_skill(running_operators, skill_module) do
    Enum.find(running_operators, fn {_pid, %{skill: s}} -> s == skill_module end)
  end

  defp find_operator_by_ref(running_operators, ref) do
    Enum.find(running_operators, fn {_pid, %{ref: r}} -> r == ref end)
  end

  defp should_finish_after_max_iterations?(state) do
    state.iteration >= state.max_iterations and
      map_size(state.running_operators) == 0
  end

  @doc false
  def filter_notifications(notifications, nil), do: notifications

  def filter_notifications(notifications, status) do
    notifications
    |> Enum.filter(fn {_, %{status: s}} -> s == status end)
    |> Map.new()
  end

  @doc false
  def update_notifications_status(notifications, ids, new_status) do
    Enum.reduce(ids, notifications, fn id, acc ->
      case Map.get(acc, id) do
        nil -> acc
        entry -> Map.put(acc, id, %{entry | status: new_status})
      end
    end)
  end

  @doc false
  def count_by_status(notifications, status) do
    Enum.count(notifications, fn {_, %{status: s}} -> s == status end)
  end

  defp ensure_parsed(%{__struct__: _} = struct), do: {:ok, struct}

  defp ensure_parsed(map) when is_map(map) do
    Zoi.parse(Tools.schema(), map)
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

  @doc false
  def emit_telemetry(event, state, extra \\ %{}) do
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
