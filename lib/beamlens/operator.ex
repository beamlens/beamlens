defmodule Beamlens.Operator do
  @moduledoc """
  Operator for LLM-driven BEAM monitoring.

  Provides two ways to run operators:

  - **`run/3`** - On-demand analysis that returns when the LLM calls `done()`
  - **GenServer** - Continuous monitoring that runs forever with `wait()` for pacing

  ## On-Demand Analysis with `run/3`

  For scheduled or triggered analysis (e.g., Oban workers):

      {:ok, notifications} = Beamlens.Operator.run(:beam, client_registry,
        context: %{reason: "high memory detected"}
      )

  The LLM investigates and calls `done()` when finished, returning the
  notifications generated during analysis.

  ## Continuous Monitoring with GenServer

  For always-on monitoring:

      {:ok, pid} = Beamlens.Operator.start_link(
        skill: Beamlens.Skill.Beam,
        client_registry: registry
      )

  The LLM controls timing via `wait()`:
  - Normal operation: wait(30000) -- 30 seconds
  - Elevated concern: wait(5000) -- 5 seconds
  - Critical monitoring: wait(1000) -- 1 second

  ## State Model

  Operators maintain one of four states:
  - `:healthy` - Everything is normal
  - `:observing` - Something looks off, gathering more data
  - `:warning` - Elevated concern, but not critical
  - `:critical` - Active issue requiring immediate attention
  """

  use GenServer

  alias Beamlens.LLM.Utils
  alias Beamlens.Operator.{Notification, Snapshot, Tools}
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
    :mode,
    :max_iterations,
    :caller,
    :pending_task,
    :pending_trace_id,
    notifications: [],
    snapshots: [],
    iteration: 0,
    state: :healthy,
    running: false,
    llm_retry_count: 0
  ]

  @doc """
  Starts an operator process.

  Defaults to `:on_demand` mode. For continuous monitoring, pass
  `mode: :continuous`.

  ## Options

    * `:name` - Optional process name for registration
    * `:skill` - Required module implementing `Beamlens.Skill`
    * `:client_registry` - Optional LLM provider configuration map
    * `:mode` - `:on_demand` or `:continuous` (default: `:on_demand`)
    * `:start_loop` - Whether to start the LLM loop on init (default: `true` for `:continuous`, `false` for `:on_demand`)
    * `:context` - Map with context to pass to the LLM
    * `:max_iterations` - Maximum LLM iterations before returning in on-demand mode (default: 10)
    * `:compaction_max_tokens` - Token threshold for compaction (default: 50_000)
    * `:compaction_keep_last` - Messages to keep verbatim after compaction (default: 5)

  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Returns the current operator status.

  Returns a map with:
    * `:operator` - Domain atom (e.g., `:beam`)
    * `:state` - Current state (`:healthy`, `:observing`, `:warning`, `:critical`)
    * `:running` - Boolean indicating if the loop is active

  """
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc """
  Stops the operator process.
  """
  def stop(server) do
    GenServer.stop(server)
  end

  @doc """
  Runs an on-demand analysis using the operator GenServer.

  The LLM investigates and calls `done()` when finished, returning the
  notifications generated during analysis.

  ## Arguments

    * `skill` - Module implementing `Beamlens.Skill`, or atom for built-in skill
    * `client_registry` - LLM provider configuration map
    * `opts` - Options

  ## Options

    * `:context` - Map with context to pass to the LLM (e.g., trigger reason)
    * `:max_iterations` - Maximum LLM iterations before returning (default: 10)
    * `:timeout` - Timeout for awaiting completion (default: `:infinity`)

  ## Returns

    * `{:ok, notifications}` - List of notifications sent during this run
    * `{:error, reason}` - If the skill couldn't be resolved or LLM failed

  ## Examples

      # Basic run
      {:ok, notifications} = Beamlens.Operator.run(:beam, client_registry())

      # With context
      {:ok, notifications} = Beamlens.Operator.run(:beam, client_registry(),
        context: %{reason: "high memory detected"}
      )

  ## Oban Integration

      defmodule MyApp.BeamlensWorker do
        use Oban.Worker, queue: :monitoring

        @impl true
        def perform(%{args: %{"skill" => skill_name, "reason" => reason}}) do
          skill = String.to_existing_atom(skill_name)
          {:ok, _notifications} = Beamlens.Operator.run(skill, client_registry(),
            context: %{reason: reason}
          )
          :ok
        end
      end

  """
  def run(skill, client_registry, opts \\ []) do
    with {:ok, {_name, skill_module}} <- resolve_skill(skill) do
      opts =
        opts
        |> Keyword.put(:skill, skill_module)
        |> Keyword.put(:client_registry, client_registry)
        |> Keyword.put(:mode, :on_demand)

      timeout = Keyword.get(opts, :timeout, :infinity)

      case start_link(opts) do
        {:ok, pid} -> await(pid, timeout)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Awaits completion for an on-demand operator.

  Returns `{:error, :not_on_demand}` for continuous operators.
  """
  def await(server, timeout \\ :infinity) do
    GenServer.call(server, :await, timeout)
  end

  defp resolve_skill(skill) when is_atom(skill) do
    case Beamlens.Operator.Supervisor.resolve_skill(skill) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, {:unknown_builtin_skill, _}} ->
        # Not a built-in skill, try as a custom skill module
        if function_exported?(skill, :id, 0) do
          {:ok, {skill.id(), skill}}
        else
          {:error, {:invalid_skill_module, skill}}
        end
    end
  end

  @impl true
  def init(opts) do
    skill = Keyword.fetch!(opts, :skill)
    name = Keyword.get(opts, :name)
    client_registry = Keyword.get(opts, :client_registry)
    mode = Keyword.get(opts, :mode, :on_demand)
    max_iterations = max_iterations(mode, opts)
    start_loop = Keyword.get(opts, :start_loop, mode == :continuous)
    run_context = Keyword.get(opts, :context, %{})
    client = build_puck_client(skill, client_registry, mode, opts)

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
      mode: mode,
      max_iterations: max_iterations,
      iteration: 0,
      state: :healthy,
      running: start_loop
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
        %{mode: :on_demand, iteration: iteration, max_iterations: max} = state
      )
      when iteration >= max do
    finish_on_demand(state, {:ok, state.notifications})
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
      Task.async(fn ->
        Puck.call(state.client, input, context, output_schema: Tools.schema(state.mode))
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
    if state.running do
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
    status = %{
      operator: state.skill.id(),
      state: state.state,
      running: state.running
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:await, _from, %{mode: :continuous} = state) do
    {:reply, {:error, :not_on_demand}, state}
  end

  def handle_call(:await, _from, %{mode: :on_demand, caller: caller} = state)
      when not is_nil(caller) do
    {:reply, {:error, :already_waiting}, state}
  end

  def handle_call(:await, from, %{mode: :on_demand, running: running} = state) do
    state = %{state | caller: from}

    if running do
      {:noreply, state}
    else
      {:noreply, %{state | running: true}, {:continue, :loop}}
    end
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
          running: false,
          llm_retry_count: 0
      }

      case state.mode do
        :on_demand -> finish_on_demand(state, {:error, {:llm_error, reason}})
        :continuous -> {:noreply, state}
      end
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

  defp handle_action(%Tools.Done{}, %{mode: :on_demand} = state, trace_id) do
    emit_telemetry(:done, state, %{trace_id: trace_id})
    finish_on_demand(state, {:ok, state.notifications})
  end

  defp handle_action(%Tools.Done{}, state, trace_id) do
    emit_telemetry(:unexpected_tool, state, %{trace_id: trace_id, tool: "done"})
    new_state = %{state | iteration: state.iteration + 1, pending_trace_id: nil}
    {:noreply, new_state, {:continue, :loop}}
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
      operator: state.skill.id(),
      anomaly_type: type,
      severity: severity,
      summary: summary,
      snapshots: snapshots
    })
  end

  defp resolve_snapshots([], _stored_snapshots) do
    {:error, "snapshot_ids required: notifications must reference at least one snapshot"}
  end

  defp resolve_snapshots(ids, stored_snapshots) do
    snapshot_map = Map.new(stored_snapshots, fn s -> {s.id, s} end)
    {found, missing} = Enum.split_with(ids, &Map.has_key?(snapshot_map, &1))

    if missing == [] do
      {:ok, Enum.map(found, &Map.fetch!(snapshot_map, &1))}
    else
      {:error, "snapshots not found: #{Enum.join(missing, ", ")}"}
    end
  end

  defp build_puck_client(skill, client_registry, mode, opts) do
    system_prompt = skill.system_prompt()
    callback_docs = skill.callback_docs() <> "\n" <> BaseSkill.callback_docs()

    backend_config =
      %{
        function: baml_function(mode),
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

  defp build_compaction_config(opts) do
    max_tokens = Keyword.get(opts, :compaction_max_tokens, 50_000)
    keep_last = Keyword.get(opts, :compaction_keep_last, 5)

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
        %{operator: state.skill.id()},
        extra
      )
    )
  end

  defp merged_callbacks(skill) do
    Map.merge(BaseSkill.callbacks(), skill.callbacks())
  end

  defp baml_function(:continuous), do: "OperatorLoop"
  defp baml_function(:on_demand), do: "OperatorRun"

  defp max_iterations(:on_demand, opts) do
    opts
    |> Keyword.get(:max_iterations, 10)
    |> normalize_max_iterations()
  end

  defp max_iterations(:continuous, _opts), do: nil

  defp normalize_max_iterations(nil), do: 10
  defp normalize_max_iterations(value), do: value

  defp finish_on_demand(state, result) do
    if state.caller do
      GenServer.reply(state.caller, result)
    end

    {:stop, :normal, state}
  end
end
