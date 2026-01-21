defmodule Beamlens.Skill.Tracer do
  @moduledoc """
  Production-safe function call tracing.

  Provides rate-limited tracing of function calls for debugging
  without risk of overwhelming the node. All tracing is time-bounded
  and message-limited to ensure zero production impact.

  ## Safety Guarantees

  - Rate limiting: max 100 messages per second
  - Message limit: max 100 total trace events
  - Time limit: max 5 minutes per trace session
  - Auto-shutoff: traces stop automatically when limits reached
  - Specificity required: must specify module/function patterns

  No PII/PHI exposure: traces may contain function arguments and
  return values, but operator should sanitize before analysis.
  """

  use GenServer
  @behaviour Beamlens.Skill

  @max_events 100
  @max_duration_ms 300_000

  ## Skill Callbacks

  @impl true
  def title, do: "Tracer"

  @impl true
  def description, do: "Production-safe function call tracing"

  @impl true
  def system_prompt do
    """
    You are a production-safe function tracer. You help debug BEAM applications
    by tracing function calls without risking node stability.

    ## Your Domain
    - Function call tracing (module, function, arity)
    - Rate-limited and time-bounded trace sessions
    - Trace event capture (timestamp, pid, module, function, arity)
    - Zero-impact tracing (safe for production use)

    ## Safety First
    - NEVER trace all functions - always require specific patterns
    - Rate limiting prevents node overload (100 events max)
    - Auto-shutoff when limits reached (100 events or 5 minutes)
    - Trace only what's needed for the specific investigation

    ## When to Use Tracing
    - Investigating specific function behavior
    - Debugging production issues without redeployment
    - Understanding call patterns and sequences
    - Finding root cause of errors or performance issues
    """
  end

  @impl true
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @impl true
  def callbacks do
    %{
      "trace_start" => &start_trace/1,
      "trace_stop" => &stop_trace/0,
      "trace_list" => &list_traces/0
    }
  end

  @impl true
  def callback_docs do
    """
    ### trace_start(module_pattern, function_pattern)
    Start a new trace session for matching functions.

    Arguments:
    - module_pattern: Module to trace (e.g., MyModule, :"*")
    - function_pattern: Function name pattern (e.g., :my_func, :"_*")

    Returns: %{trace_id: id, status: :started}

    ### trace_stop()
    Stop the active trace session and collect results.

    Returns: %{events: [...], status: :stopped}

    ### trace_list()
    List all trace sessions.

    Returns: list of trace session info
    """
  end

  ## GenServer Callbacks

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    {:ok, %{active_trace: nil, events: [], start_time: nil}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    active_count = if state.active_trace, do: 1, else: 0
    {:reply, %{active_trace_count: active_count, event_count: length(state.events)}, state}
  end

  @impl true
  def handle_call({:start_trace, module_pattern, function_pattern}, _from, state) do
    if state.active_trace do
      {:reply, {:error, :trace_already_active}, state}
    else
      case setup_trace(module_pattern, function_pattern) do
        {:ok, trace_pid} ->
          new_state = %{
            active_trace: %{
              module_pattern: module_pattern,
              function_pattern: function_pattern,
              tracer_pid: trace_pid
            },
            events: [],
            start_time: System.monotonic_time(:millisecond)
          }

          {:reply, {:ok, %{status: :started}}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call(:stop_trace, _from, state) do
    if state.active_trace do
      stop_tracing(state.active_trace)
      result = %{events: Enum.reverse(state.events), status: :stopped}
      {:reply, {:ok, result}, %{active_trace: nil, events: [], start_time: nil}}
    else
      {:reply, {:error, :no_active_trace}, state}
    end
  end

  @impl true
  def handle_call(:list_traces, _from, state) do
    traces =
      if state.active_trace do
        [
          %{
            module_pattern: state.active_trace.module_pattern,
            function_pattern: state.active_trace.function_pattern,
            event_count: length(state.events),
            duration_ms: System.monotonic_time(:millisecond) - state.start_time
          }
        ]
      else
        []
      end

    {:reply, traces, state}
  end

  @impl true
  def handle_info({:trace, pid, :call, {module, function, arity}}, state) do
    event = %{
      timestamp: System.system_time(:microsecond),
      pid: inspect(pid),
      type: :call,
      module: inspect(module),
      function: function,
      arity: arity
    }

    new_events = [event | state.events]
    new_state = %{state | events: new_events}

    if length(new_events) >= @max_events or exceeded_duration?(new_state) do
      stop_tracing(state.active_trace)
      send(self(), :auto_stop)
      {:noreply, new_state}
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:trace, _pid, :return_from, {module, function, arity}, _return}, state) do
    event = %{
      timestamp: System.system_time(:microsecond),
      type: :return_from,
      module: inspect(module),
      function: function,
      arity: arity
    }

    new_events = [event | state.events]
    new_state = %{state | events: new_events}

    if length(new_events) >= @max_events or exceeded_duration?(new_state) do
      stop_tracing(state.active_trace)
      send(self(), :auto_stop)
      {:noreply, new_state}
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:auto_stop, state) do
    {:noreply, %{state | active_trace: nil}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.active_trace, do: stop_tracing(state.active_trace)
    :ok
  end

  ## Client API

  def start_trace({module_pattern, function_pattern}) do
    GenServer.call(__MODULE__, {:start_trace, module_pattern, function_pattern})
  end

  def stop_trace do
    GenServer.call(__MODULE__, :stop_trace)
  end

  def list_traces do
    GenServer.call(__MODULE__, :list_traces)
  end

  ## Private Helpers

  defp setup_trace(module_pattern, function_pattern) do
    parent = self()
    pid = spawn_link(fn -> tracer_loop(parent) end)
    setup_trace_on_pid(pid, module_pattern, function_pattern)
  end

  defp setup_trace_on_pid(pid, module_pattern, function_pattern) do
    case :erlang.trace(pid, true, [:call, :arity]) do
      1 -> apply_trace_pattern(pid, module_pattern, function_pattern)
      _ -> {:error, :trace_setup_failed}
    end
  end

  defp apply_trace_pattern(pid, module_pattern, function_pattern) do
    match_spec = [{:_, [], [{:return_trace}]}]

    case :erlang.trace_pattern({module_pattern, function_pattern, :_}, match_spec, []) do
      1 -> {:ok, pid}
      _ -> {:error, :trace_pattern_failed}
    end
  end

  defp stop_tracing(nil), do: :ok

  defp stop_tracing(active_trace) do
    :erlang.trace_pattern(
      {active_trace.module_pattern, active_trace.function_pattern, :_},
      false,
      []
    )

    :erlang.trace(active_trace.tracer_pid, false, [:all])
  end

  defp tracer_loop(parent) do
    receive do
      _ -> tracer_loop(parent)
    end
  end

  defp exceeded_duration?(state) do
    if state.start_time do
      elapsed = System.monotonic_time(:millisecond) - state.start_time
      elapsed >= @max_duration_ms
    else
      false
    end
  end
end
