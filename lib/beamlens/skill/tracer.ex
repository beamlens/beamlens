defmodule Beamlens.Skill.Tracer do
  @moduledoc """
  Production-safe function call tracing powered by Recon.

  Provides heavily rate-limited tracing of function calls for debugging
  without risk of overwhelming the node. Uses the battle-tested
  Recon library with additional safety layers.

  ## Safety Guarantees

  - **Rate limiting**: 5 traces per second max (configurable)
  - **Message limit**: 50 traces before auto-stop (configurable)
  - **Time limit**: 60 seconds max before auto-stop
  - **Blocked hot paths**: High-frequency stdlib functions rejected
  - **Arity required**: Must specify function arity (no wildcards)
  - **Process isolation**: Tracer runs in separate process

  ## Blocked Functions

  The following high-frequency functions are blocked to prevent
  accidental node overload:

  - `:erlang.send/2`, `Kernel.send/2`
  - `GenServer.call/2,3`, `GenServer.cast/2`
  - `:ets.lookup/2`, `:ets.insert/2`
  - `Process.send/2,3`

  ## Requirements

  Requires the `recon` package:

      {:recon, "~> 2.3"}
  """

  use GenServer
  @behaviour Beamlens.Skill

  @default_max_traces 50
  @default_rate_limit {5, 1000}
  @default_max_duration_ms 60_000

  @blocked_functions [
    {:erlang, :send, 2},
    {:erlang, :send, 3},
    {:erlang, :!, 2},
    {:ets, :lookup, 2},
    {:ets, :insert, 2},
    {:ets, :delete, 2},
    {GenServer, :call, 2},
    {GenServer, :call, 3},
    {GenServer, :cast, 2},
    {Process, :send, 2},
    {Process, :send, 3},
    {:gen_server, :call, 2},
    {:gen_server, :call, 3},
    {:gen_server, :cast, 2}
  ]

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
    - Heavily rate-limited trace sessions (5 traces per second)
    - Message-limited sessions (50 traces max)
    - Time-limited sessions (60 seconds max)

    ## Safety Restrictions
    - You MUST specify a concrete arity (no wildcards)
    - High-frequency stdlib functions are blocked (send, ets, GenServer internals)
    - Traces auto-stop after limits are reached

    ## When to Use Tracing
    - Investigating specific function behavior in YOUR application code
    - Debugging production issues without redeployment
    - Understanding call patterns and sequences
    - Finding root cause of errors

    ## What Gets Captured
    Each trace event contains: timestamp, pid, module, function, and arity.

    ## Blocked Functions
    These cannot be traced: :erlang.send, Kernel.send, :ets.lookup, :ets.insert,
    GenServer.call, GenServer.cast, Process.send
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
      "trace_get" => &get_traces/0
    }
  end

  @impl true
  def callback_docs do
    """
    ### trace_start(module, function, arity)
    Start a new trace session for matching functions.

    Arguments:
    - module: Module to trace (e.g., MyApp.Worker) - no wildcards
    - function: Function name atom (e.g., :handle_call) - no wildcards
    - arity: Function arity (0-255) - REQUIRED, no wildcards

    Returns: {:ok, %{status: :started, matches: count}} or {:error, reason}

    Note: High-frequency stdlib functions are blocked for safety.

    ### trace_stop()
    Stop the active trace session.

    Returns: {:ok, %{status: :stopped}}

    ### trace_get()
    Get collected trace events from the current or last session.

    Returns: list of trace event strings
    """
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       active: false,
       traces: [],
       collector_pid: nil,
       trace_spec: nil,
       timer_ref: nil,
       started_at: nil
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      active: state.active,
      trace_count: length(state.traces),
      trace_spec: state.trace_spec,
      elapsed_ms: elapsed_ms(state)
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_call({:start_trace, module, function, arity}, _from, state) do
    with :ok <- check_not_active(state),
         :ok <- validate_no_wildcards(module, function, arity),
         :ok <- validate_not_blocked(module, function, arity) do
      collector_pid = spawn_collector(self())

      opts = [
        {:io_server, collector_pid},
        {:args, :arity}
      ]

      try do
        matches = :recon_trace.calls({module, function, arity}, @default_rate_limit, opts)

        timer_ref = Process.send_after(self(), :timeout, @default_max_duration_ms)

        new_state = %{
          active: true,
          traces: [],
          collector_pid: collector_pid,
          trace_spec: {module, function, arity},
          timer_ref: timer_ref,
          started_at: System.monotonic_time(:millisecond)
        }

        {:reply, {:ok, %{status: :started, matches: matches}}, new_state}
      rescue
        e ->
          Process.exit(collector_pid, :shutdown)
          {:reply, {:error, Exception.message(e)}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:stop_trace, _from, state) do
    {:reply, {:ok, %{status: :stopped, trace_count: length(state.traces)}}, do_stop(state)}
  end

  @impl true
  def handle_call(:get_traces, _from, state) do
    {:reply, Enum.reverse(state.traces), state}
  end

  @impl true
  def handle_info({:trace_line, line}, state) do
    new_traces = [line | state.traces]

    if length(new_traces) >= @default_max_traces do
      {:noreply, do_stop(%{state | traces: new_traces})}
    else
      {:noreply, %{state | traces: new_traces}}
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    {:noreply, do_stop(state)}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, %{collector_pid: pid} = state) do
    {:noreply, %{state | collector_pid: nil}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.active, do: :recon_trace.clear()
    :ok
  end

  @doc """
  Starts a trace session for the given module, function, and arity.

  Returns `{:ok, %{status: :started, matches: count}}` on success,
  or `{:error, reason}` if validation fails or a trace is already active.
  """
  def start_trace({module, function, arity}) do
    GenServer.call(__MODULE__, {:start_trace, module, function, arity})
  end

  @doc """
  Stops the active trace session.

  Returns `{:ok, %{status: :stopped, trace_count: count}}`.
  """
  def stop_trace do
    GenServer.call(__MODULE__, :stop_trace)
  end

  @doc """
  Returns collected trace events from the current or last session.
  """
  def get_traces do
    GenServer.call(__MODULE__, :get_traces)
  end

  defp check_not_active(%{active: true}), do: {:error, :trace_already_active}
  defp check_not_active(_), do: :ok

  defp validate_no_wildcards(module, function, arity) do
    wildcards = [:_, :*, :"$1", :"$2", :"$3"]

    cond do
      module in wildcards ->
        {:error, :wildcard_module_not_allowed}

      function in wildcards ->
        {:error, :wildcard_function_not_allowed}

      arity in wildcards ->
        {:error, :arity_required}

      not is_integer(arity) or arity < 0 or arity > 255 ->
        {:error, :invalid_arity}

      true ->
        :ok
    end
  end

  defp validate_not_blocked(module, function, arity) do
    if {module, function, arity} in @blocked_functions do
      {:error, {:blocked_function, {module, function, arity}}}
    else
      :ok
    end
  end

  defp do_stop(state) do
    if state.active do
      :recon_trace.clear()

      if state.collector_pid && Process.alive?(state.collector_pid) do
        Process.exit(state.collector_pid, :shutdown)
      end

      if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    end

    %{state | active: false, collector_pid: nil, timer_ref: nil}
  end

  defp elapsed_ms(%{started_at: nil}), do: nil

  defp elapsed_ms(%{started_at: started_at}) do
    System.monotonic_time(:millisecond) - started_at
  end

  defp spawn_collector(parent) do
    spawn_link(fn -> collector_loop(parent) end)
  end

  defp collector_loop(parent) do
    receive do
      {:io_request, from, reply_as, {:put_chars, _encoding, chars}} ->
        line = IO.chardata_to_string(chars)
        send(parent, {:trace_line, String.trim(line)})
        send(from, {:io_reply, reply_as, :ok})
        collector_loop(parent)

      {:io_request, from, reply_as, {:put_chars, chars}} ->
        line = IO.chardata_to_string(chars)
        send(parent, {:trace_line, String.trim(line)})
        send(from, {:io_reply, reply_as, :ok})
        collector_loop(parent)

      {:io_request, from, reply_as, _request} ->
        send(from, {:io_reply, reply_as, :ok})
        collector_loop(parent)

      _ ->
        collector_loop(parent)
    end
  end
end
