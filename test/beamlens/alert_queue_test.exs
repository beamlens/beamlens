defmodule Beamlens.AlertQueueTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Beamlens.{Alert, AlertQueue}

  setup do
    {:ok, pid} = AlertQueue.start_link(name: nil)
    {:ok, queue: pid}
  end

  describe "push/2 and take_all/1" do
    test "returns empty list when queue is empty", %{queue: queue} do
      assert AlertQueue.take_all(queue) == []
    end

    test "returns single alert after push", %{queue: queue} do
      alert = make_alert(:beam, :memory_elevated)
      AlertQueue.push(alert, queue)

      alerts = AlertQueue.take_all(queue)

      assert length(alerts) == 1
      assert hd(alerts).watcher == :beam
    end

    test "returns alerts in FIFO order", %{queue: queue} do
      alert1 = make_alert(:beam, :memory_elevated)
      alert2 = make_alert(:ecto, :pool_exhausted)
      alert3 = make_alert(:os, :disk_full)

      AlertQueue.push(alert1, queue)
      AlertQueue.push(alert2, queue)
      AlertQueue.push(alert3, queue)

      alerts = AlertQueue.take_all(queue)

      assert length(alerts) == 3
      assert Enum.map(alerts, & &1.watcher) == [:beam, :ecto, :os]
    end

    test "clears queue after take_all", %{queue: queue} do
      AlertQueue.push(make_alert(:beam, :memory_elevated), queue)

      assert length(AlertQueue.take_all(queue)) == 1
      assert AlertQueue.take_all(queue) == []
    end
  end

  describe "pending?/1" do
    test "returns false when queue is empty", %{queue: queue} do
      refute AlertQueue.pending?(queue)
    end

    test "returns true when queue has alerts", %{queue: queue} do
      AlertQueue.push(make_alert(:beam, :memory_elevated), queue)

      assert AlertQueue.pending?(queue)
    end

    test "returns false after take_all", %{queue: queue} do
      AlertQueue.push(make_alert(:beam, :memory_elevated), queue)
      AlertQueue.take_all(queue)

      refute AlertQueue.pending?(queue)
    end
  end

  describe "count/1" do
    test "returns 0 when queue is empty", %{queue: queue} do
      assert AlertQueue.count(queue) == 0
    end

    test "returns correct count after pushes", %{queue: queue} do
      AlertQueue.push(make_alert(:beam, :memory_elevated), queue)
      AlertQueue.push(make_alert(:ecto, :pool_exhausted), queue)

      assert AlertQueue.count(queue) == 2
    end

    test "returns 0 after take_all", %{queue: queue} do
      AlertQueue.push(make_alert(:beam, :memory_elevated), queue)
      AlertQueue.take_all(queue)

      assert AlertQueue.count(queue) == 0
    end
  end

  describe "subscribe/1 and notifications" do
    test "subscriber receives notification on push", %{queue: queue} do
      AlertQueue.subscribe(queue)
      alert = make_alert(:beam, :memory_elevated)

      AlertQueue.push(alert, queue)

      assert_receive {:alert_available, ^alert}
    end

    test "multiple subscribers receive notifications", %{queue: queue} do
      parent = self()

      spawn(fn ->
        AlertQueue.subscribe(queue)
        send(parent, :subscribed)

        receive do
          {:alert_available, alert} -> send(parent, {:child_received, alert})
        end
      end)

      receive do
        :subscribed -> :ok
      end

      AlertQueue.subscribe(queue)
      alert = make_alert(:beam, :memory_elevated)
      AlertQueue.push(alert, queue)

      assert_receive {:alert_available, ^alert}
      assert_receive {:child_received, ^alert}
    end

    test "unsubscribed process does not receive notifications", %{queue: queue} do
      AlertQueue.subscribe(queue)
      AlertQueue.unsubscribe(queue)

      AlertQueue.push(make_alert(:beam, :memory_elevated), queue)

      refute_receive {:alert_available, _}
    end

    test "dead subscriber is automatically removed", %{queue: queue} do
      parent = self()

      pid =
        spawn(fn ->
          AlertQueue.subscribe(queue)
          send(parent, :subscribed)

          receive do
            :exit -> :ok
          end
        end)

      receive do
        :subscribed -> :ok
      end

      send(pid, :exit)
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      end

      AlertQueue.push(make_alert(:beam, :memory_elevated), queue)

      assert AlertQueue.count(queue) == 1
    end
  end

  defp make_alert(watcher, anomaly_type) do
    Alert.new(%{
      watcher: watcher,
      anomaly_type: anomaly_type,
      severity: :warning,
      summary: "Test alert",
      snapshot: %{}
    })
  end
end
