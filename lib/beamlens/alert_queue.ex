defmodule Beamlens.AlertQueue do
  @moduledoc """
  In-memory queue for alerts from watchers to the orchestrator.

  Provides the unidirectional communication channel in the **Orchestrator-Workers**
  pattern. Watchers push alerts when they detect anomalies, and the orchestrator
  takes alerts for investigation.

  ## Features

    * FIFO queue ordering
    * Subscriber notifications when alerts arrive
    * Atomic take-all operation for batch processing

  ## Example

      # Watcher pushes an alert
      Beamlens.AlertQueue.push(alert)

      # Orchestrator takes all pending alerts
      alerts = Beamlens.AlertQueue.take_all()

      # Subscribe to alert notifications
      Beamlens.AlertQueue.subscribe()
      receive do
        {:alert_available, alert} -> handle_alert(alert)
      end
  """

  use GenServer

  alias Beamlens.Alert

  defstruct alerts: :queue.new(), subscribers: MapSet.new()

  @doc """
  Starts the AlertQueue GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Pushes an alert onto the queue.

  Notifies all subscribers that an alert is available.
  """
  def push(%Alert{} = alert, server \\ __MODULE__) do
    GenServer.cast(server, {:push, alert})
  end

  @doc """
  Takes all pending alerts from the queue.

  Returns a list of alerts in FIFO order and clears the queue.
  Returns an empty list if no alerts are pending.
  """
  def take_all(server \\ __MODULE__) do
    GenServer.call(server, :take_all)
  end

  @doc """
  Checks if there are pending alerts in the queue.
  """
  def pending?(server \\ __MODULE__) do
    GenServer.call(server, :pending?)
  end

  @doc """
  Returns the number of pending alerts.
  """
  def count(server \\ __MODULE__) do
    GenServer.call(server, :count)
  end

  @doc """
  Subscribes the calling process to alert notifications.

  When an alert is pushed, subscribers receive `{:alert_available, alert}`.
  Subscription is automatically removed when the subscriber process terminates.
  """
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc """
  Unsubscribes the calling process from alert notifications.
  """
  def unsubscribe(server \\ __MODULE__) do
    GenServer.call(server, {:unsubscribe, self()})
  end

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:push, %Alert{} = alert}, state) do
    new_queue = :queue.in(alert, state.alerts)
    notify_subscribers(state.subscribers, alert)
    {:noreply, %{state | alerts: new_queue}}
  end

  @impl true
  def handle_call(:take_all, _from, state) do
    alerts = :queue.to_list(state.alerts)
    {:reply, alerts, %{state | alerts: :queue.new()}}
  end

  def handle_call(:pending?, _from, state) do
    {:reply, not :queue.is_empty(state.alerts), state}
  end

  def handle_call(:count, _from, state) do
    {:reply, :queue.len(state.alerts), state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  defp notify_subscribers(subscribers, alert) do
    Enum.each(subscribers, fn pid ->
      send(pid, {:alert_available, alert})
    end)
  end
end
