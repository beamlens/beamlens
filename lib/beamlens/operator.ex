defmodule Beamlens.Operator do
  @moduledoc """
  GenServer that runs an operator in a continuous LLM-driven loop.

  The LLM has full control over timing via the `wait` tool. The loop runs:

  1. Collect snapshot
  2. Send to LLM with current state
  3. LLM returns action (set_state, fire_alert, get_alerts, execute, wait, think)
  4. Execute action and loop

  The `wait` tool lets the LLM control its own cadence:
  - Normal operation: wait(30000) -- 30 seconds
  - Elevated concern: wait(5000) -- 5 seconds
  - Critical monitoring: wait(1000) -- 1 second

  ## State Model

  The operator maintains one of four states:
  - `:healthy` - Everything is normal
  - `:observing` - Something looks off, gathering more data
  - `:warning` - Elevated concern, but not critical
  - `:critical` - Active issue requiring immediate attention

  ## Example

      {:ok, pid} = Beamlens.Operator.start_link(
        name: {:via, Registry, {MyRegistry, :beam}},
        skill_module: Beamlens.Skill.Beam
      )
  """

  use GenServer

  alias Beamlens.LLM.Utils
  alias Beamlens.Operator.{Alert, Snapshot, Tools}
  alias Beamlens.Telemetry

  alias Beamlens.Operator.Tools.{
    Execute,
    FireAlert,
    GetAlerts,
    GetSnapshot,
    GetSnapshots,
    SetState,
    TakeSnapshot,
    Think,
    Wait
  }

  alias Puck.Context
  alias Puck.Sandbox.Eval

  defstruct [
    :name,
    :skill_module,
    :client,
    :client_registry,
    :context,
    :pending_task,
    :pending_trace_id,
    alerts: [],
    snapshots: [],
    iteration: 0,
    state: :healthy,
    running: false
  ]

  @doc """
  Starts an operator process.

  ## Options

    * `:name` - Optional process name for registration
    * `:skill_module` - Required module implementing `Beamlens.Skill`
    * `:client_registry` - Optional LLM provider configuration map
    * `:start_loop` - Whether to start the LLM loop on init (default: true)
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

  @impl true
  def init(opts) do
    skill_module = Keyword.fetch!(opts, :skill_module)
    name = Keyword.get(opts, :name)
    client_registry = Keyword.get(opts, :client_registry)
    start_loop = Keyword.get(opts, :start_loop, true)
    client = build_puck_client(skill_module, client_registry, opts)

    state = %__MODULE__{
      name: name,
      skill_module: skill_module,
      client: client,
      client_registry: client_registry,
      context: Context.new(metadata: %{iteration: 0}),
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
        handle_action(response.content, %{state | context: new_context}, state.pending_trace_id)

      {:error, reason} ->
        emit_telemetry(:llm_error, state, %{trace_id: state.pending_trace_id, reason: reason})
        {:noreply, %{state | running: false, pending_trace_id: nil}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{pending_task: %Task{ref: ref}} = state) do
    emit_telemetry(:llm_error, state, %{
      trace_id: state.pending_trace_id,
      reason: {:task_crashed, reason}
    })

    {:noreply, %{state | pending_task: nil, pending_trace_id: nil, running: false}}
  end

  def handle_info(:continue_loop, state) do
    {:noreply, state, {:continue, :loop}}
  end

  def handle_info(msg, state) do
    emit_telemetry(:unexpected_message, state, %{message: inspect(msg)})
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      operator: state.skill_module.id(),
      state: state.state,
      running: state.running
    }

    {:reply, status, state}
  end

  @impl true
  def terminate(_reason, %{pending_task: %Task{} = task} = _state) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

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
         %FireAlert{type: type, summary: summary, severity: severity, snapshot_ids: snapshot_ids},
         state,
         trace_id
       ) do
    case resolve_snapshots(snapshot_ids, state.snapshots) do
      {:ok, snapshots} ->
        alert = build_alert(state, type, summary, severity, snapshots)

        emit_telemetry(:alert_fired, state, %{
          trace_id: trace_id,
          alert: alert
        })

        new_state = %{
          state
          | alerts: state.alerts ++ [alert],
            iteration: state.iteration + 1,
            pending_trace_id: nil
        }

        {:noreply, new_state, {:continue, :loop}}

      {:error, reason} ->
        emit_telemetry(:alert_failed, state, %{trace_id: trace_id, reason: reason})

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

  defp handle_action(%GetAlerts{}, state, trace_id) do
    alerts = state.alerts

    emit_telemetry(:get_alerts, state, %{
      trace_id: trace_id,
      count: length(alerts)
    })

    new_context = Utils.add_result(state.context, alerts)

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
    emit_telemetry(:execute_start, state, %{trace_id: trace_id})

    result =
      case Eval.eval(:lua, lua_code, callbacks: state.skill_module.callbacks()) do
        {:ok, result} ->
          emit_telemetry(:execute_complete, state, %{trace_id: trace_id})
          result

        {:error, reason} ->
          emit_telemetry(:execute_error, state, %{trace_id: trace_id, reason: reason})
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
    state.skill_module.snapshot()
  end

  defp build_input(operator_state) do
    "Current state: #{operator_state}"
  end

  defp build_alert(state, type, summary, severity, snapshots) do
    Alert.new(%{
      operator: state.skill_module.id(),
      anomaly_type: type,
      severity: severity,
      summary: summary,
      snapshots: snapshots
    })
  end

  defp resolve_snapshots([], _stored_snapshots) do
    {:error, "snapshot_ids required: alerts must reference at least one snapshot"}
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

  defp build_puck_client(skill_module, client_registry, opts) do
    callback_docs = skill_module.callback_docs()

    backend_config =
      %{
        function: "OperatorLoop",
        args_format: :auto,
        args: fn messages ->
          %{
            messages: Utils.format_messages_for_baml(messages),
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
    - Any alerts fired and their reasons

    Be concise. This summary will be used to continue monitoring.
    """
  end

  defp emit_telemetry(event, state, extra \\ %{}) do
    :telemetry.execute(
      [:beamlens, :operator, event],
      %{system_time: System.system_time()},
      Map.merge(
        %{operator: state.skill_module.id()},
        extra
      )
    )
  end
end
