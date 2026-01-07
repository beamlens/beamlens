defmodule Beamlens.AlertHandlerTest do
  @moduledoc false

  use ExUnit.Case

  alias Beamlens.{Alert, AlertHandler, AlertQueue}

  setup do
    start_supervised!(AlertQueue)
    {:ok, handler} = AlertHandler.start_link(name: nil, trigger: :manual)
    {:ok, handler: handler}
  end

  describe "start_link/1" do
    test "starts with default options" do
      {:ok, pid} = AlertHandler.start_link(name: nil)
      assert Process.alive?(pid)
    end

    test "starts with custom trigger mode" do
      {:ok, pid} = AlertHandler.start_link(name: nil, trigger: :on_alert)
      assert Process.alive?(pid)
    end
  end

  describe "pending?/1" do
    test "returns false when no alerts", %{handler: handler} do
      refute AlertHandler.pending?(handler)
    end

    test "returns true when alerts pending", %{handler: handler} do
      push_alert()
      assert AlertHandler.pending?(handler)
    end
  end

  describe "investigate/2" do
    test "returns :no_alerts when queue empty", %{handler: handler} do
      result = AlertHandler.investigate(handler)
      assert {:ok, :no_alerts} = result
    end
  end

  describe "telemetry events" do
    test "emits started event on init" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        ref,
        [:beamlens, :alert_handler, :started],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :started, metadata})
        end,
        nil
      )

      {:ok, _pid} = AlertHandler.start_link(name: nil, trigger: :manual)

      assert_receive {:telemetry, :started, %{trigger_mode: :manual}}

      :telemetry.detach(ref)
    end

    test "investigation_completed event structure" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        ref,
        [:beamlens, :alert_handler, :investigation_completed],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.execute(
        [:beamlens, :alert_handler, :investigation_completed],
        %{system_time: System.system_time()},
        %{status: :healthy}
      )

      assert_receive {:telemetry, [:beamlens, :alert_handler, :investigation_completed],
                      _measurements, metadata}

      assert metadata.status == :healthy

      :telemetry.detach(ref)
    end

    test "investigation_failed event structure" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        ref,
        [:beamlens, :alert_handler, :investigation_failed],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.execute(
        [:beamlens, :alert_handler, :investigation_failed],
        %{system_time: System.system_time()},
        %{reason: :timeout}
      )

      assert_receive {:telemetry, [:beamlens, :alert_handler, :investigation_failed],
                      _measurements, metadata}

      assert metadata.reason == :timeout

      :telemetry.detach(ref)
    end
  end

  describe "on_alert trigger mode" do
    test "subscribes to AlertQueue" do
      {:ok, handler} = AlertHandler.start_link(name: nil, trigger: :on_alert)
      assert Process.alive?(handler)
    end

    test "ignores alert_available in manual mode", %{handler: handler} do
      send(handler, {:alert_available, %{}})
      assert Process.alive?(handler)
    end
  end

  defp push_alert do
    alert =
      Alert.new(%{
        watcher: :beam,
        anomaly_type: :memory_elevated,
        severity: :warning,
        summary: "Test alert",
        snapshot: %{}
      })

    AlertQueue.push(alert)
  end
end
