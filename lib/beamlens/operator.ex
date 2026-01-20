defmodule Beamlens.Operator do
  @moduledoc """
  Operator for LLM-driven BEAM monitoring.

  ## Static Supervision

  Operators are started as static, always-running supervised processes.
  They wait in `:idle` status until invoked, then run their LLM loop.

  ## Running Analysis with `run/2`

  For scheduled or triggered analysis (e.g., Oban workers):

      {:ok, notifications} = Beamlens.Operator.run(Beamlens.Skill.Beam, %{reason: "high memory detected"})

      # With custom LLM provider
      {:ok, notifications} = Beamlens.Operator.run(Beamlens.Skill.Beam, %{reason: "high memory"},
        client_registry: custom_registry
      )

  The LLM investigates and calls `done()` when finished, returning the
  notifications generated during analysis.

  ## State Model

  Operators maintain one of four health states:
  - `:healthy` - Everything is normal
  - `:observing` - Something looks off, gathering more data
  - `:warning` - Elevated concern, but not critical
  - `:critical` - Active issue requiring immediate attention

  ## Status

  Operators have a run status:
  - `:idle` - Waiting for invocation
  - `:running` - LLM loop is active
  """

  use GenServer

  alias Beamlens.LLM.Utils
  alias Beamlens.Operator.{CompletionResult, Notification, Snapshot, Status, Tools}
  alias Beamlens.Skill.Base, as: BaseSkill
  alias Beamlens.Telemetry

  alias Beamlens.Operator.Tools.{
    Execute,
    GetNotifications,
    GetSnapshot,
    GetSnapshots,
    SendNotification,
    SetState,
    TakeSnapshot,
    Think,
    Wait
  }

  alias Puck.Context
  alias Puck.Sandbox.Eval

  @max_llm_retries 3

  defstruct [
    :name,
    :skill,
    :client,
    :client_registry,
    :context,
    :max_iterations,
    :caller,
    :pending_task,
    :pending_trace_id,
    :notify_pid,
    notifications: [],
    snapshots: [],
    iteration: 0,
    state: :healthy,
    status: :idle,
    llm_retry_count: 0,
    invocation_queue: :queue.new()
  ]

  @doc """
  Starts an operator process.

  ## Options

    * `:name` - Optional process name for registration
    * `:skill` - Required module implementing `Beamlens.Skill`
    * `:client_registry` - Optional LLM provider configuration map
    * `:puck_client` - Optional `Puck.Client` to use instead of BAML
    * `:start_loop` - Whether to start the LLM loop on init (default: `false`)
    * `:context` - Map with context to pass to the LLM
    * `:max_iterations` - Maximum LLM iterations before returning (default: 10)
    * `:compaction_max_tokens` - Token threshold for compaction (default: 50_000)
    * `:compaction_keep_last` - Messages to keep verbatim after compaction (default: 5)
    * `:notify_pid` - PID to receive real-time notifications and completion messages

  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the current operator status.

  Returns a map with:
    * `:operator` - Domain atom (e.g., `:beam`)
    * `:state` - Current state (`:healthy`, `:observing`, `:warning`, `:critical`)
    * `:iteration` - Current iteration count
    * `:running` - Boolean indicating if the loop is active

  """
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc """
  Sends a message to the operator and receives an LLM-generated response.

  The coordinator's LLM generates a custom prompt, and the operator's LLM
  responds using its full conversation context. Useful for LLM-to-LLM
  communication where the coordinator needs to understand what the operator
  is observing.

  Returns `{:ok, response}` with:
    * `:skill` - The operator's skill ID
    * `:state` - Current operator state
    * `:iteration` - Current iteration count
    * `:response` - The LLM-generated response content

  """
  def message(server, prompt, timeout \\ 30_000) do
    GenServer.call(server, {:message, prompt}, timeout)
  end

  @doc """
  Stops the operator process.
  """
  def stop(server) do
    GenServer.stop(server)
  end

  @doc """
  Runs analysis using the static operator for the given skill.

  The operator must be configured in your Beamlens supervision tree.
  Raises `ArgumentError` if the operator is not started.

  The LLM investigates and calls `done()` when finished, returning the
  notifications generated during analysis.

  ## Arguments

    * `skill` - Module implementing `Beamlens.Skill`, or atom for built-in skill
    * `context` - Map with context for the investigation (e.g., `%{reason: "high memory"}`)
    * `opts` - Options

  ## Options

    * `:context` - Map with context (alternative to second argument)
    * `:client_registry` - LLM provider configuration map (default: `%{}`)
    * `:puck_client` - Optional `Puck.Client` to use instead of BAML
    * `:max_iterations` - Maximum LLM iterations before returning (default: 10)
    * `:timeout` - Timeout for awaiting completion (default: `:infinity`)

  ## Returns

    * `{:ok, notifications}` - List of notifications sent during this run
    * `{:error, reason}` - If the skill couldn't be resolved or LLM failed

  ## Examples

      # Context as second argument
      {:ok, notifications} = Beamlens.Operator.run(:beam, %{reason: "high memory"})

      # Context in opts
      {:ok, notifications} = Beamlens.Operator.run(:beam, context: %{reason: "high memory"})

      # With custom LLM provider
      {:ok, notifications} = Beamlens.Operator.run(:beam, %{reason: "investigating"},
        client_registry: %{primary: "Ollama", clients: [...]}
      )

  """
  def run(skill, opts) when is_list(opts) do
    {context, opts} = Keyword.pop(opts, :context, %{})
    run(skill, context, opts)
  end

  def run(skill, context) when is_map(context) do
    run(skill, context, [])
  end

  @doc """
  Invokes an existing operator process directly.

  Use this when you have a reference to a static operator and want to run
  analysis on it. The operator queues the request if already running.
  """
  def run(pid, context, opts) when is_pid(pid) and is_map(context) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    GenServer.call(pid, {:invoke, context, opts}, timeout)
  end

  def run(skill, context, opts) when is_map(context) and is_list(opts) do
    with {:ok, skill_module} <- resolve_skill(skill) do
      case Registry.lookup(Beamlens.OperatorRegistry, skill_module) do
        [{pid, _}] ->
          run(pid, context, opts)

        [] ->
          raise ArgumentError,
                "Operator for #{inspect(skill_module)} not started. " <>
                  "Add it to the :skills list in your Beamlens config."
      end
    end
  end

  @doc """
  Runs an operator asynchronously with notification callbacks.

  The caller will receive messages:
  - `{:operator_notification, pid, notification}` for each notification
  - `{:operator_complete, pid, skill, completion_result}` when done

  Returns `:ok` immediately after queuing the invocation.
  """
  def run_async(pid, context, opts \\ []) when is_pid(pid) do
    GenServer.cast(pid, {:invoke_async, context, opts})
  end

  @doc """
  Awaits completion for an operator.
  """
  def await(server, timeout \\ :infinity) do
    GenServer.call(server, :await, timeout)
  end

  defp resolve_skill(skill_module) when is_atom(skill_module) do
    Beamlens.Operator.Supervisor.resolve_skill(skill_module)
  end

  defp prepare_invocation(state, context, caller) do
    run_context =
      if is_map(context) and map_size(context) > 0 do
        Context.new(metadata: %{iteration: 0})
        |> Utils.add_result(%{context: context})
      else
        Context.new(metadata: %{iteration: 0})
      end

    %{
      state
      | context: run_context,
        caller: caller,
        notifications: [],
        snapshots: [],
        iteration: 0,
        state: :healthy,
        llm_retry_count: 0
    }
  end

  @impl true
  def init(opts) do
    skill = Keyword.fetch!(opts, :skill)
    name = Keyword.get(opts, :name)
    client_registry = Keyword.get(opts, :client_registry)
    max_iterations = Keyword.get(opts, :max_iterations, 10)
    start_loop = Keyword.get(opts, :start_loop, false)
    run_context = Keyword.get(opts, :context, %{})
    notify_pid = Keyword.get(opts, :notify_pid)
    client = build_puck_client(skill, client_registry, opts)

    context =
      if map_size(run_context) > 0 do
        Context.new(metadata: %{iteration: 0})
        |> Utils.add_result(%{context: run_context})
      else
        Context.new(metadata: %{iteration: 0})
      end

    state = %__MODULE__{
      name: name,
      skill: skill,
      client: client,
      client_registry: client_registry,
      context: context,
      max_iterations: max_iterations,
      notify_pid: notify_pid,
      iteration: 0,
      state: :healthy,
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
  def handle_continue(
        :loop,
        %{iteration: iteration, max_iterations: max} = state
      )
      when iteration >= max do
    finish(state, {:ok, state.notifications})
  end

  def handle_continue(:loop, state) do
    trace_id = Telemetry.generate_trace_id()

    emit_telemetry(:iteration_start, state, %{
      trace_id: trace_id,
      iteration: state.iteration,
      operator_state: state.state
    })

    input = build_input(state.state)
    context = %{state.context | metadata: Map.put(state.context.metadata, :trace_id, trace_id)}

    task =
      Beamlens.LLMTask.async(fn ->
        Puck.call(state.client, input, context, output_schema: Tools.schema())
      end)

    {:noreply, %{state | pending_task: task, pending_trace_id: trace_id}}
  end

  @impl true
  def handle_info({ref, result}, %{pending_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | pending_task: nil}

    case result do
      {:ok, response, new_context} ->
        state = %{state | context: new_context, llm_retry_count: 0}
        handle_action(response.content, state, state.pending_trace_id)

      {:error, reason} ->
        handle_llm_error(state, reason)
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{pending_task: %Task{ref: ref}} = state) do
    handle_llm_error(state, {:task_crashed, reason})
  end

  def handle_info(:continue_loop, state) do
    if state.status == :running do
      {:noreply, state, {:continue, :loop}}
    else
      {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    emit_telemetry(:unexpected_message, state, %{message: inspect(msg)})
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %Status{
      operator: state.skill,
      state: state.state,
      iteration: state.iteration,
      running: state.status == :running
    }

    {:reply, status, state}
  end

  def handle_call({:message, prompt}, _from, state) do
    result =
      case Puck.call(state.client, prompt, state.context,
             output_schema: message_response_schema()
           ) do
        {:ok, response, _new_context} ->
          {:ok,
           %{
             skill: state.skill,
             state: state.state,
             iteration: state.iteration,
             response: response.content
           }}

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, result, state}
  end

  def handle_call(:await, _from, %{caller: caller} = state)
      when not is_nil(caller) do
    {:reply, {:error, :already_waiting}, state}
  end

  def handle_call(:await, from, %{status: status} = state) do
    state = %{state | caller: from}

    if status == :running do
      {:noreply, state}
    else
      {:noreply, %{state | status: :running}, {:continue, :loop}}
    end
  end

  def handle_call({:invoke, context, _opts}, from, %{status: :idle} = state) do
    state = prepare_invocation(state, context, from)
    {:noreply, %{state | status: :running}, {:continue, :loop}}
  end

  def handle_call({:invoke, context, opts}, from, %{status: :running} = state) do
    queue = :queue.in({from, context, opts}, state.invocation_queue)
    {:noreply, %{state | invocation_queue: queue}}
  end

  @impl true
  def handle_cast({:invoke_async, context, opts}, %{status: :idle} = state) do
    notify_pid = Keyword.get(opts, :notify_pid)
    state = prepare_invocation(state, context, nil)
    state = %{state | notify_pid: notify_pid}
    {:noreply, %{state | status: :running}, {:continue, :loop}}
  end

  def handle_cast({:invoke_async, context, opts}, %{status: :running} = state) do
    queue = :queue.in({nil, context, opts}, state.invocation_queue)
    {:noreply, %{state | invocation_queue: queue}}
  end

  @impl true
  def terminate(_reason, %{pending_task: %Task{} = task} = _state) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp handle_llm_error(state, reason) do
    new_retry_count = state.llm_retry_count + 1

    emit_telemetry(:llm_error, state, %{
      trace_id: state.pending_trace_id,
      reason: reason,
      retry_count: new_retry_count,
      will_retry: new_retry_count < @max_llm_retries
    })

    if new_retry_count < @max_llm_retries do
      delay = :timer.seconds(round(:math.pow(2, new_retry_count - 1)))
      Process.send_after(self(), :continue_loop, delay)

      {:noreply,
       %{state | pending_task: nil, pending_trace_id: nil, llm_retry_count: new_retry_count}}
    else
      state = %{
        state
        | pending_task: nil,
          pending_trace_id: nil,
          status: :idle,
          llm_retry_count: 0
      }

      finish(state, {:error, {:llm_error, reason}})
    end
  end

  defp handle_action(%SetState{state: new_state, reason: reason}, state, trace_id) do
    emit_telemetry(:state_change, state, %{
      trace_id: trace_id,
      from: state.state,
      to: new_state,
      reason: reason
    })

    new_state = %{state | state: new_state, iteration: state.iteration + 1, pending_trace_id: nil}
    {:noreply, new_state, {:continue, :loop}}
  end

  defp handle_action(
         %SendNotification{
           type: type,
           summary: summary,
           severity: severity,
           snapshot_ids: snapshot_ids
         },
         state,
         trace_id
       ) do
    case resolve_snapshots(snapshot_ids, state.snapshots) do
      {:ok, snapshots} ->
        notification = build_notification(state, type, summary, severity, snapshots)

        emit_telemetry(:notification_sent, state, %{
          trace_id: trace_id,
          notification: notification
        })

        if state.notify_pid do
          send(state.notify_pid, {:operator_notification, self(), notification})
        end

        new_state = %{
          state
          | notifications: state.notifications ++ [notification],
            iteration: state.iteration + 1,
            pending_trace_id: nil
        }

        {:noreply, new_state, {:continue, :loop}}

      {:error, reason} ->
        emit_telemetry(:notification_failed, state, %{trace_id: trace_id, reason: reason})

        new_context = Utils.add_result(state.context, %{error: reason})

        new_state = %{
          state
          | context: new_context,
            iteration: state.iteration + 1,
            pending_trace_id: nil
        }

        {:noreply, new_state, {:continue, :loop}}
    end
  end

  defp handle_action(%GetNotifications{}, state, trace_id) do
    notifications = state.notifications

    emit_telemetry(:get_notifications, state, %{
      trace_id: trace_id,
      count: length(notifications)
    })

    new_context = Utils.add_result(state.context, notifications)

    new_state = %{
      state
      | context: new_context,
        iteration: state.iteration + 1,
        pending_trace_id: nil
    }

    {:noreply, new_state, {:continue, :loop}}
  end

  defp handle_action(%TakeSnapshot{}, state, trace_id) do
    data = collect_snapshot(state)
    snapshot = Snapshot.new(data)

    emit_telemetry(:take_snapshot, state, %{trace_id: trace_id, snapshot_id: snapshot.id})

    new_context = Utils.add_result(state.context, snapshot)

    new_state = %{
      state
      | context: new_context,
        snapshots: state.snapshots ++ [snapshot],
        iteration: state.iteration + 1,
        pending_trace_id: nil
    }

    {:noreply, new_state, {:continue, :loop}}
  end

  defp handle_action(%GetSnapshot{id: id}, state, trace_id) do
    emit_telemetry(:get_snapshot, state, %{trace_id: trace_id, snapshot_id: id})

    result =
      case Enum.find(state.snapshots, fn s -> s.id == id end) do
        nil -> %{error: "snapshot_not_found", id: id}
        snapshot -> snapshot
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

  defp handle_action(%GetSnapshots{limit: limit, offset: offset}, state, trace_id) do
    offset = offset || 0
    snapshots = Enum.drop(state.snapshots, offset)

    snapshots =
      if limit do
        Enum.take(snapshots, limit)
      else
        snapshots
      end

    emit_telemetry(:get_snapshots, state, %{trace_id: trace_id, count: length(snapshots)})

    new_context = Utils.add_result(state.context, snapshots)

    new_state = %{
      state
      | context: new_context,
        iteration: state.iteration + 1,
        pending_trace_id: nil
    }

    {:noreply, new_state, {:continue, :loop}}
  end

  defp handle_action(%Execute{code: lua_code}, state, trace_id) do
    emit_telemetry(:execute_start, state, %{trace_id: trace_id, code: lua_code})

    result =
      case Eval.eval(:lua, lua_code, callbacks: merged_callbacks(state.skill)) do
        {:ok, result} ->
          emit_telemetry(:execute_complete, state, %{
            trace_id: trace_id,
            code: lua_code,
            result: result
          })

          result

        {:error, reason} ->
          emit_telemetry(:execute_error, state, %{
            trace_id: trace_id,
            code: lua_code,
            reason: reason
          })

          %{error: inspect(reason)}
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

  defp handle_action(%Wait{ms: ms}, state, trace_id) do
    emit_telemetry(:wait, state, %{trace_id: trace_id, ms: ms})
    Process.send_after(self(), :continue_loop, ms)

    fresh_context = Context.new(metadata: %{iteration: state.iteration + 1})

    new_state = %{
      state
      | context: fresh_context,
        iteration: state.iteration + 1,
        pending_trace_id: nil
    }

    {:noreply, new_state}
  end

  defp handle_action(%Tools.Done{}, state, trace_id) do
    emit_telemetry(:done, state, %{trace_id: trace_id})
    finish(state, {:ok, state.notifications})
  end

  defp handle_action(%Think{thought: thought}, state, trace_id) do
    emit_telemetry(:think, state, %{trace_id: trace_id, thought: thought})

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

  defp collect_snapshot(state) do
    state.skill.snapshot()
  end

  defp build_input(operator_state) do
    "Current state: #{operator_state}"
  end

  defp build_notification(state, type, summary, severity, snapshots) do
    Notification.new(%{
      operator: state.skill,
      anomaly_type: type,
      severity: severity,
      summary: summary,
      snapshots: snapshots
    })
  end

  defp resolve_snapshots([], _stored_snapshots) do
    {:error, "snapshot_ids required: must reference at least one snapshot"}
  end

  defp resolve_snapshots(ids, stored_snapshots) when is_list(ids) do
    snapshot_map = Map.new(stored_snapshots, fn s -> {s.id, s} end)
    {found, missing} = Enum.split_with(ids, &Map.has_key?(snapshot_map, &1))

    if missing == [] do
      {:ok, Enum.map(found, &Map.fetch!(snapshot_map, &1))}
    else
      {:error, "snapshots not found: #{Enum.join(missing, ", ")}"}
    end
  end

  defp build_puck_client(skill, client_registry, opts) when is_list(opts) do
    build_puck_client(skill, client_registry, Map.new(opts))
  end

  defp build_puck_client(_skill, _client_registry, %{puck_client: %Puck.Client{} = client}) do
    client
  end

  defp build_puck_client(skill, client_registry, opts) when is_map(opts) do
    system_prompt = skill.system_prompt()
    callback_docs = skill.callback_docs() <> "\n" <> BaseSkill.callback_docs()

    backend_config =
      %{
        function: "OperatorRun",
        args_format: :auto,
        args: fn messages ->
          %{
            messages: Utils.format_messages_for_baml(messages),
            system_prompt: system_prompt,
            callback_docs: callback_docs
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

  defp build_compaction_config(opts) when is_map(opts) do
    max_tokens = Map.get(opts, :compaction_max_tokens, 50_000)
    keep_last = Map.get(opts, :compaction_keep_last, 5)

    {:summarize,
     max_tokens: max_tokens, keep_last: keep_last, prompt: operator_compaction_prompt()}
  end

  defp operator_compaction_prompt do
    """
    Summarize this monitoring session, preserving:
    - What anomalies or concerns were detected
    - Current system state and trend direction
    - Snapshot IDs referenced (preserve exact IDs)
    - Key metric values that informed decisions
    - Any notifications sent and their reasons

    Be concise. This summary will be used to continue monitoring.
    """
  end

  defp emit_telemetry(event, state, extra \\ %{}) do
    :telemetry.execute(
      [:beamlens, :operator, event],
      %{system_time: System.system_time()},
      Map.merge(
        %{operator: state.skill},
        extra
      )
    )
  end

  defp merged_callbacks(skill) do
    Map.merge(BaseSkill.callbacks(), skill.callbacks())
  end

  defp message_response_schema do
    Zoi.object(%{
      summary: Zoi.string(),
      findings: Zoi.nullish(Zoi.list(Zoi.string())),
      concerns: Zoi.nullish(Zoi.list(Zoi.string()))
    })
  end

  defp finish(state, result) do
    if state.notify_pid do
      completion_result = %CompletionResult{
        state: state.state,
        notifications: Enum.reverse(state.notifications),
        snapshots: Enum.reverse(state.snapshots)
      }

      send(state.notify_pid, {:operator_complete, self(), state.skill, completion_result})
    end

    if state.caller do
      GenServer.reply(state.caller, result)
    end

    case :queue.out(state.invocation_queue) do
      {{:value, {next_caller, next_context, next_opts}}, remaining_queue} ->
        notify_pid = Keyword.get(next_opts, :notify_pid)

        new_state =
          state
          |> prepare_invocation(next_context, next_caller)
          |> Map.put(:invocation_queue, remaining_queue)
          |> Map.put(:notify_pid, notify_pid)
          |> Map.put(:status, :running)

        {:noreply, new_state, {:continue, :loop}}

      {:empty, _} ->
        new_state = %{
          state
          | status: :idle,
            caller: nil,
            notify_pid: nil,
            notifications: [],
            snapshots: [],
            iteration: 0,
            state: :healthy
        }

        {:noreply, new_state}
    end
  end
end
