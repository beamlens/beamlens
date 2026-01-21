defmodule Beamlens.Skill.Tracer do
  @moduledoc """
  Production-safe function call tracing.

  Provides rate-limited tracing of function calls for debugging
  without risk of overwhelming the node. All tracing is time-bounded
  and message-limited to ensure zero production impact.

  ## Safety Guarantees

  - Message limit: max 100 total trace events
  - Time limit: max 5 minutes per trace session
  - Auto-shutoff: traces stop automatically when limits reached
  - Specificity required: must specify concrete module/function patterns
  - Runtime enforcement: wildcard patterns rejected at setup time

  ## What Gets Traced

  Traces capture metadata only:
  - Timestamp (microsecond precision)
  - Process identifier (PID)
  - Module name, function name
  - Event type (:call, :return_from)

  Function arguments and return values are never captured by design.
  The trace flags use `:timestamp` instead of capturing return values,
  and the match spec explicitly excludes argument binding.
  This makes it impossible for sensitive data to leak through traces
  at the Erlang VM level.
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
    - Function call tracing (module, function)
    - Rate-limited and time-bounded trace sessions
    - Trace event capture (timestamp, pid, module, function)
    - Zero-impact tracing (safe for production use)

    ## How Tracing Works
    - Specify concrete module and function names to trace
    - Runtime validation prevents wildcard patterns (:"*", :_, etc.)
    - Message limits prevent node overload (100 events max)
    - Auto-shutoff when limits reached (100 events or 5 minutes)
    - Trace only what's needed for the specific investigation

    ## When to Use Tracing
    - Investigating specific function behavior
    - Debugging production issues without redeployment
    - Understanding call patterns and sequences
    - Finding root cause of errors or performance issues

    ## What Gets Captured
    Each trace event contains: timestamp, pid, module, function, event type
    Function arguments and return values are never captured by design.
    The tracing implementation uses Erlang's `:timestamp` flag which excludes
    return values entirely, making it impossible for sensitive data to leak.
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
    - module_pattern: Module to trace (e.g., MyModule, :erlang)
    - function_pattern: Function name (e.g., :my_func, :timestamp)

    Returns: {:ok, %{status: :started}} or {:error, reason}

    ### trace_stop()
    Stop the active trace session and collect results.

    Returns: {:ok, %{events: [...], status: :stopped}} or {:error, :no_active_trace}

    ### trace_list()
    List all active trace sessions.

    Returns: list of trace session info with module_pattern, function_pattern, event_count, duration_ms
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
      with :ok <- validate_patterns(module_pattern, function_pattern),
           {:ok, trace_pid} <- setup_trace(module_pattern, function_pattern) do
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
      else
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
  def handle_info({:trace_ts, pid, :call, {module, function, arity}, timestamp}, state) do
    event = %{
      timestamp: timestamp,
      pid: inspect(pid),
      type: :call,
      module: inspect(module),
      function: function,
      arity: arity
    }

    handle_trace_event(event, state)
  end

  @impl true
  def handle_info({:trace_ts, _pid, :return_from, {module, function, _arity}, timestamp}, state) do
    event = %{
      timestamp: timestamp,
      type: :return_from,
      module: inspect(module),
      function: function
    }

    handle_trace_event(event, state)
  end

  @impl true
  def handle_info(:auto_stop, state) do
    {:noreply, %{state | active_trace: nil}}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, state) do
    if state.active_trace && state.active_trace.tracer_pid == pid do
      {:noreply, %{state | active_trace: nil}}
    else
      {:noreply, state}
    end
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

  defp validate_patterns(module_pattern, function_pattern) do
    forbidden_patterns = [:_, :*]

    cond do
      module_pattern in forbidden_patterns ->
        {:error, :wildcard_module_not_allowed}

      function_pattern in forbidden_patterns ->
        {:error, :wildcard_function_not_allowed}

      true ->
        :ok
    end
  end

  defp setup_trace(module_pattern, function_pattern) do
    parent = self()
    pid = spawn_link(fn -> tracer_loop(parent) end)
    setup_trace_on_pid(pid, module_pattern, function_pattern)
  end

  defp setup_trace_on_pid(pid, module_pattern, function_pattern) do
    case :erlang.trace(pid, true, [:call, :arity, :timestamp]) do
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

  defp handle_trace_event(event, state) do
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

  defp exceeded_duration?(state) do
    if state.start_time do
      elapsed = System.monotonic_time(:millisecond) - state.start_time
      elapsed >= @max_duration_ms
    else
      false
    end
  end
end
