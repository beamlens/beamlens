defmodule Beamlens.Operator.NotificationTest do
  use ExUnit.Case, async: true

  alias Beamlens.Operator.Notification

  describe "new/1" do
    test "creates notification with required fields" do
      attrs = %{
        operator: :beam,
        anomaly_type: "memory_elevated",
        severity: :warning,
        context: "Node running for 3 days, 500 processes active",
        observation: "Memory at 85%, exceeding 60% threshold",
        snapshots: [%{id: "snap1", data: %{}}]
      }

      notification = Notification.new(attrs)

      assert notification.operator == :beam
      assert notification.anomaly_type == "memory_elevated"
      assert notification.severity == :warning
      assert notification.context == "Node running for 3 days, 500 processes active"
      assert notification.observation == "Memory at 85%, exceeding 60% threshold"
      assert notification.snapshots == [%{id: "snap1", data: %{}}]
    end

    test "generates unique id if not provided" do
      attrs = %{
        operator: :beam,
        anomaly_type: "test",
        severity: :info,
        context: "test context",
        observation: "test observation",
        snapshots: []
      }

      notification = Notification.new(attrs)

      assert is_binary(notification.id)
      assert String.length(notification.id) == 16
    end

    test "uses provided id if given" do
      attrs = %{
        id: "custom-id",
        operator: :beam,
        anomaly_type: "test",
        severity: :info,
        context: "test context",
        observation: "test observation",
        snapshots: []
      }

      notification = Notification.new(attrs)

      assert notification.id == "custom-id"
    end

    test "sets detected_at to current time if not provided" do
      attrs = %{
        operator: :beam,
        anomaly_type: "test",
        severity: :info,
        context: "test context",
        observation: "test observation",
        snapshots: []
      }

      before = DateTime.utc_now()
      notification = Notification.new(attrs)
      after_time = DateTime.utc_now()

      assert DateTime.compare(notification.detected_at, before) in [:gt, :eq]
      assert DateTime.compare(notification.detected_at, after_time) in [:lt, :eq]
    end

    test "sets node to current node if not provided" do
      attrs = %{
        operator: :beam,
        anomaly_type: "test",
        severity: :info,
        context: "test context",
        observation: "test observation",
        snapshots: []
      }

      notification = Notification.new(attrs)

      assert notification.node == Node.self()
    end

    test "generates trace_id if not provided" do
      attrs = %{
        operator: :beam,
        anomaly_type: "test",
        severity: :info,
        context: "test context",
        observation: "test observation",
        snapshots: []
      }

      notification = Notification.new(attrs)

      assert is_binary(notification.trace_id)
      assert String.length(notification.trace_id) == 32
    end

    test "stores optional hypothesis" do
      attrs = %{
        operator: :beam,
        anomaly_type: "memory_elevated",
        severity: :warning,
        context: "Node running for 3 days",
        observation: "Memory at 85%",
        hypothesis: "Likely due to ETS table growth",
        snapshots: []
      }

      notification = Notification.new(attrs)

      assert notification.hypothesis == "Likely due to ETS table growth"
    end

    test "hypothesis defaults to nil" do
      attrs = %{
        operator: :beam,
        anomaly_type: "test",
        severity: :info,
        context: "test context",
        observation: "test observation",
        snapshots: []
      }

      notification = Notification.new(attrs)

      assert notification.hypothesis == nil
    end

    test "raises on missing required field" do
      assert_raise KeyError, fn ->
        Notification.new(%{operator: :beam})
      end
    end

    test "raises on missing context" do
      assert_raise KeyError, fn ->
        Notification.new(%{
          operator: :beam,
          anomaly_type: "test",
          severity: :info,
          observation: "test observation",
          snapshots: []
        })
      end
    end

    test "raises on missing observation" do
      assert_raise KeyError, fn ->
        Notification.new(%{
          operator: :beam,
          anomaly_type: "test",
          severity: :info,
          context: "test context",
          snapshots: []
        })
      end
    end
  end

  describe "generate_id/0" do
    test "returns 16-character lowercase hex string" do
      id = Notification.generate_id()

      assert is_binary(id)
      assert String.length(id) == 16
      assert id =~ ~r/^[a-f0-9]+$/
    end

    test "returns unique values on each call" do
      ids = for _ <- 1..100, do: Notification.generate_id()
      unique_ids = Enum.uniq(ids)

      assert length(unique_ids) == 100
    end
  end

  describe "Jason.Encoder" do
    test "encodes notification to JSON" do
      notification =
        Notification.new(%{
          operator: :beam,
          anomaly_type: "test",
          severity: :info,
          context: "test context",
          observation: "test observation",
          snapshots: []
        })

      assert {:ok, json} = Jason.encode(notification)
      assert is_binary(json)
    end

    test "encoded JSON contains decomposed fields" do
      notification =
        Notification.new(%{
          operator: :beam,
          anomaly_type: "memory_elevated",
          severity: :warning,
          context: "Node running for 3 days",
          observation: "Memory at 85%",
          hypothesis: "ETS table growth",
          snapshots: []
        })

      {:ok, json} = Jason.encode(notification)
      decoded = Jason.decode!(json)

      assert decoded["context"] == "Node running for 3 days"
      assert decoded["observation"] == "Memory at 85%"
      assert decoded["hypothesis"] == "ETS table growth"
    end
  end
end
