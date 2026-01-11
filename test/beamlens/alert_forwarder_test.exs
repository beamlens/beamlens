defmodule Beamlens.AlertForwarderTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Beamlens.AlertForwarder
  alias Beamlens.Operator.Alert

  defp build_test_alert(overrides \\ %{}) do
    Alert.new(
      Map.merge(
        %{
          operator: :test,
          anomaly_type: "test_anomaly",
          severity: :info,
          summary: "Test alert",
          snapshots: []
        },
        overrides
      )
    )
  end

  describe "pubsub_topic/0" do
    test "returns the expected topic" do
      assert AlertForwarder.pubsub_topic() == "beamlens:alerts"
    end
  end

  describe "start_link/1" do
    test "starts with pubsub option" do
      pubsub_name = :"TestPubSub_start_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = start_supervised({Phoenix.PubSub, name: pubsub_name})

      {:ok, pid} = AlertForwarder.start_link(pubsub: pubsub_name)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "fails to start when pubsub option missing" do
      Process.flag(:trap_exit, true)

      assert {:error, _} = AlertForwarder.start_link([])
    end
  end

  describe "alert forwarding" do
    test "broadcasts alerts to pubsub when telemetry event fires" do
      pubsub_name = :"TestPubSub_broadcast_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: pubsub_name)

      {:ok, forwarder} = AlertForwarder.start_link(pubsub: pubsub_name)
      Phoenix.PubSub.subscribe(pubsub_name, AlertForwarder.pubsub_topic())

      alert = build_test_alert()

      :telemetry.execute(
        [:beamlens, :operator, :alert_fired],
        %{system_time: System.system_time()},
        %{alert: alert, operator: :test, trace_id: "test-trace"}
      )

      assert_receive {:beamlens_alert, received_alert, source_node}, 1000
      assert received_alert.id == alert.id
      assert source_node == node()

      GenServer.stop(forwarder)
    end
  end

  describe "terminate/2" do
    test "detaches telemetry handler on stop" do
      pubsub_name = :"TestPubSub_term_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = start_supervised({Phoenix.PubSub, name: pubsub_name})

      {:ok, pid} = AlertForwarder.start_link(pubsub: pubsub_name)

      handlers_before = :telemetry.list_handlers([:beamlens, :operator, :alert_fired])
      assert Enum.any?(handlers_before, &(&1.id == "beamlens-alert-forwarder"))

      GenServer.stop(pid)

      handlers_after = :telemetry.list_handlers([:beamlens, :operator, :alert_fired])
      refute Enum.any?(handlers_after, &(&1.id == "beamlens-alert-forwarder"))
    end
  end
end
