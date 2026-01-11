defmodule Beamlens.Operator.AlertTest do
  use ExUnit.Case, async: true

  alias Beamlens.Operator.Alert

  describe "new/1" do
    test "creates alert with required fields" do
      attrs = %{
        operator: :beam,
        anomaly_type: "memory_elevated",
        severity: :warning,
        summary: "Memory at 85%",
        snapshots: [%{id: "snap1", data: %{}}]
      }

      alert = Alert.new(attrs)

      assert alert.operator == :beam
      assert alert.anomaly_type == "memory_elevated"
      assert alert.severity == :warning
      assert alert.summary == "Memory at 85%"
      assert alert.snapshots == [%{id: "snap1", data: %{}}]
    end

    test "generates unique id if not provided" do
      attrs = %{
        operator: :beam,
        anomaly_type: "test",
        severity: :info,
        summary: "test",
        snapshots: []
      }

      alert = Alert.new(attrs)

      assert is_binary(alert.id)
      assert String.length(alert.id) == 16
    end

    test "uses provided id if given" do
      attrs = %{
        id: "custom-id",
        operator: :beam,
        anomaly_type: "test",
        severity: :info,
        summary: "test",
        snapshots: []
      }

      alert = Alert.new(attrs)

      assert alert.id == "custom-id"
    end

    test "sets detected_at to current time if not provided" do
      attrs = %{
        operator: :beam,
        anomaly_type: "test",
        severity: :info,
        summary: "test",
        snapshots: []
      }

      before = DateTime.utc_now()
      alert = Alert.new(attrs)
      after_time = DateTime.utc_now()

      assert DateTime.compare(alert.detected_at, before) in [:gt, :eq]
      assert DateTime.compare(alert.detected_at, after_time) in [:lt, :eq]
    end

    test "sets node to current node if not provided" do
      attrs = %{
        operator: :beam,
        anomaly_type: "test",
        severity: :info,
        summary: "test",
        snapshots: []
      }

      alert = Alert.new(attrs)

      assert alert.node == Node.self()
    end

    test "generates trace_id if not provided" do
      attrs = %{
        operator: :beam,
        anomaly_type: "test",
        severity: :info,
        summary: "test",
        snapshots: []
      }

      alert = Alert.new(attrs)

      assert is_binary(alert.trace_id)
      assert String.length(alert.trace_id) == 32
    end

    test "raises on missing required field" do
      assert_raise KeyError, fn ->
        Alert.new(%{operator: :beam})
      end
    end
  end

  describe "generate_id/0" do
    test "returns 16-character lowercase hex string" do
      id = Alert.generate_id()

      assert is_binary(id)
      assert String.length(id) == 16
      assert id =~ ~r/^[a-f0-9]+$/
    end

    test "returns unique values on each call" do
      ids = for _ <- 1..100, do: Alert.generate_id()
      unique_ids = Enum.uniq(ids)

      assert length(unique_ids) == 100
    end
  end

  describe "Jason.Encoder" do
    test "encodes alert to JSON" do
      alert =
        Alert.new(%{
          operator: :beam,
          anomaly_type: "test",
          severity: :info,
          summary: "test",
          snapshots: []
        })

      assert {:ok, json} = Jason.encode(alert)
      assert is_binary(json)
    end
  end
end
