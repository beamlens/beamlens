defmodule Beamlens.CircuitBreaker do
  @moduledoc """
  Circuit breaker for LLM calls to prevent cascading failures.

  Implements the circuit breaker pattern with three states:

  - `:closed` - Normal operation, requests flow through
  - `:open` - Circuit tripped, requests fail fast with `{:error, :circuit_open}`
  - `:half_open` - Testing recovery, limited requests allowed through

  ## State Transitions

      ┌─────────────────────────────────────────────────┐
      │                                                 │
      ▼                                                 │
   CLOSED ──(N failures)──► OPEN ──(timeout)──► HALF_OPEN
      ▲                       ▲                    │
      │                       │                    │
      └──(M successes)────────┴────(1 failure)─────┘

  ## Configuration

  The circuit breaker accepts these options:

    * `:failure_threshold` - Consecutive failures before opening (default: 5)
    * `:reset_timeout` - Milliseconds before transitioning to half_open (default: 30_000)
    * `:success_threshold` - Successes in half_open before closing (default: 2)

  ## Usage

  The circuit breaker is automatically started by `Beamlens.Supervisor`.
  Use `allow?/0` to check if requests should proceed, and `record_success/0`
  or `record_failure/1` to update the circuit state.

      if Beamlens.CircuitBreaker.allow?() do
        case make_llm_call() do
          {:ok, result} ->
            Beamlens.CircuitBreaker.record_success()
            {:ok, result}

          {:error, reason} = error ->
            Beamlens.CircuitBreaker.record_failure(reason)
            error
        end
      else
        {:error, :circuit_open}
      end

  ## Telemetry Events

    * `[:beamlens, :circuit_breaker, :state_change]`
      - Measurements: `%{system_time: integer}`
      - Metadata: `%{from: atom(), to: atom(), failure_count: integer(), reason: term()}`

    * `[:beamlens, :circuit_breaker, :rejected]`
      - Measurements: `%{system_time: integer}`
      - Metadata: `%{state: :open | :half_open, failure_count: integer()}`
  """

  use GenServer
  require Logger

  @default_failure_threshold 5
  @default_reset_timeout :timer.seconds(30)
  @default_success_threshold 2

  defstruct [
    :state,
    :failure_count,
    :success_count,
    :last_failure_at,
    :last_failure_reason,
    :failure_threshold,
    :reset_timeout,
    :success_threshold,
    :reset_timer_ref
  ]

  # --- Client API ---

  @doc """
  Starts the circuit breaker with the given options.

  ## Options

    * `:failure_threshold` - Consecutive failures before opening (default: 5)
    * `:reset_timeout` - Milliseconds before transitioning to half_open (default: 30_000)
    * `:success_threshold` - Successes in half_open before closing (default: 2)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if a request should be allowed through.

  Returns `true` if the circuit is closed or half_open (with capacity),
  `false` if the circuit is open.

  When returning `false`, emits a `[:beamlens, :circuit_breaker, :rejected]`
  telemetry event.
  """
  def allow? do
    GenServer.call(__MODULE__, :allow?)
  end

  @doc """
  Records a successful LLM call.

  In half_open state, increments success count and may close the circuit.
  In closed state, resets failure count to zero.
  """
  def record_success do
    GenServer.cast(__MODULE__, :record_success)
  end

  @doc """
  Records a failed LLM call with the failure reason.

  Increments failure count and may open the circuit if threshold is reached.
  """
  def record_failure(reason \\ :unknown) do
    GenServer.cast(__MODULE__, {:record_failure, reason})
  end

  @doc """
  Returns the current circuit breaker state as a map.

  Useful for monitoring and debugging.
  """
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc """
  Manually resets the circuit breaker to closed state.

  Use with caution - primarily intended for testing or manual recovery.
  """
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    state = %__MODULE__{
      state: :closed,
      failure_count: 0,
      success_count: 0,
      last_failure_at: nil,
      last_failure_reason: nil,
      failure_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
      reset_timeout: Keyword.get(opts, :reset_timeout, @default_reset_timeout),
      success_threshold: Keyword.get(opts, :success_threshold, @default_success_threshold),
      reset_timer_ref: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:allow?, _from, %{state: :closed} = state) do
    {:reply, true, state}
  end

  def handle_call(:allow?, _from, %{state: :half_open} = state) do
    {:reply, true, state}
  end

  def handle_call(:allow?, _from, %{state: :open} = state) do
    emit_rejected(state)
    {:reply, false, state}
  end

  def handle_call(:get_state, _from, state) do
    public_state = %{
      state: state.state,
      failure_count: state.failure_count,
      success_count: state.success_count,
      last_failure_at: state.last_failure_at,
      last_failure_reason: state.last_failure_reason,
      failure_threshold: state.failure_threshold,
      reset_timeout: state.reset_timeout,
      success_threshold: state.success_threshold
    }

    {:reply, public_state, state}
  end

  def handle_call(:reset, _from, state) do
    cancel_reset_timer(state)

    new_state = %{
      state
      | state: :closed,
        failure_count: 0,
        success_count: 0,
        last_failure_at: nil,
        last_failure_reason: nil,
        reset_timer_ref: nil
    }

    if state.state != :closed do
      emit_state_change(state.state, :closed, new_state, :manual_reset)
    end

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast(:record_success, %{state: :closed} = state) do
    {:noreply, %{state | failure_count: 0}}
  end

  def handle_cast(:record_success, %{state: :half_open} = state) do
    new_success_count = state.success_count + 1

    if new_success_count >= state.success_threshold do
      cancel_reset_timer(state)
      new_state = %{state | state: :closed, failure_count: 0, success_count: 0, reset_timer_ref: nil}
      emit_state_change(:half_open, :closed, new_state, :recovery_complete)
      Logger.info("[BeamLens] Circuit breaker closed after #{new_success_count} successful calls")
      {:noreply, new_state}
    else
      {:noreply, %{state | success_count: new_success_count}}
    end
  end

  def handle_cast(:record_success, %{state: :open} = state) do
    {:noreply, state}
  end

  def handle_cast({:record_failure, reason}, %{state: :closed} = state) do
    new_failure_count = state.failure_count + 1
    now = DateTime.utc_now()

    if new_failure_count >= state.failure_threshold do
      timer_ref = schedule_reset_timer(state.reset_timeout)

      new_state = %{
        state
        | state: :open,
          failure_count: new_failure_count,
          last_failure_at: now,
          last_failure_reason: reason,
          reset_timer_ref: timer_ref
      }

      emit_state_change(:closed, :open, new_state, reason)

      Logger.warning(
        "[BeamLens] Circuit breaker opened after #{new_failure_count} consecutive failures. " <>
          "Will retry in #{state.reset_timeout}ms. Last error: #{inspect(reason)}"
      )

      {:noreply, new_state}
    else
      {:noreply, %{state | failure_count: new_failure_count, last_failure_at: now, last_failure_reason: reason}}
    end
  end

  def handle_cast({:record_failure, reason}, %{state: :half_open} = state) do
    timer_ref = schedule_reset_timer(state.reset_timeout)

    new_state = %{
      state
      | state: :open,
        success_count: 0,
        last_failure_at: DateTime.utc_now(),
        last_failure_reason: reason,
        reset_timer_ref: timer_ref
    }

    emit_state_change(:half_open, :open, new_state, reason)
    Logger.warning("[BeamLens] Circuit breaker reopened from half_open. Error: #{inspect(reason)}")
    {:noreply, new_state}
  end

  def handle_cast({:record_failure, _reason}, %{state: :open} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:reset_timeout, %{state: :open} = state) do
    new_state = %{state | state: :half_open, success_count: 0, reset_timer_ref: nil}
    emit_state_change(:open, :half_open, new_state, :timeout)
    Logger.info("[BeamLens] Circuit breaker half_open, testing recovery")
    {:noreply, new_state}
  end

  def handle_info(:reset_timeout, state) do
    {:noreply, %{state | reset_timer_ref: nil}}
  end

  # --- Private Helpers ---

  defp schedule_reset_timer(timeout) do
    Process.send_after(self(), :reset_timeout, timeout)
  end

  defp cancel_reset_timer(%{reset_timer_ref: nil}), do: :ok
  defp cancel_reset_timer(%{reset_timer_ref: ref}), do: Process.cancel_timer(ref)

  defp emit_state_change(from, to, state, reason) do
    :telemetry.execute(
      [:beamlens, :circuit_breaker, :state_change],
      %{system_time: System.system_time()},
      %{
        from: from,
        to: to,
        failure_count: state.failure_count,
        reason: reason
      }
    )
  end

  defp emit_rejected(state) do
    :telemetry.execute(
      [:beamlens, :circuit_breaker, :rejected],
      %{system_time: System.system_time()},
      %{
        state: state.state,
        failure_count: state.failure_count
      }
    )
  end
end
