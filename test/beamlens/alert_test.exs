defmodule Beamlens.AlertTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Beamlens.Alert

  describe "new/1" do
    test "creates alert with required attributes" do
      attrs = %{
        watcher: :beam,
        anomaly_type: :memory_elevated,
        severity: :warning,
        summary: "Memory at 72%",
        snapshot: %{memory_utilization_pct: 72.0}
      }

      alert = Alert.new(attrs)

      assert alert.watcher == :beam
      assert alert.anomaly_type == :memory_elevated
      assert alert.severity == :warning
      assert alert.summary == "Memory at 72%"
      assert alert.snapshot == %{memory_utilization_pct: 72.0}
    end

    test "auto-generates id when not provided" do
      alert = Alert.new(valid_attrs())

      assert is_binary(alert.id)
      assert byte_size(alert.id) == 16
    end

    test "uses provided id when given" do
      alert = Alert.new(Map.put(valid_attrs(), :id, "custom-id"))

      assert alert.id == "custom-id"
    end

    test "auto-generates trace_id when not provided" do
      alert = Alert.new(valid_attrs())

      assert is_binary(alert.trace_id)
      assert byte_size(alert.trace_id) == 32
    end

    test "uses provided trace_id when given" do
      alert = Alert.new(Map.put(valid_attrs(), :trace_id, "custom-trace"))

      assert alert.trace_id == "custom-trace"
    end

    test "sets detected_at to current time when not provided" do
      before = DateTime.utc_now()
      alert = Alert.new(valid_attrs())
      after_time = DateTime.utc_now()

      assert DateTime.compare(alert.detected_at, before) in [:gt, :eq]
      assert DateTime.compare(alert.detected_at, after_time) in [:lt, :eq]
    end

    test "uses provided detected_at when given" do
      timestamp = ~U[2024-01-06 10:30:00Z]
      alert = Alert.new(Map.put(valid_attrs(), :detected_at, timestamp))

      assert alert.detected_at == timestamp
    end

    test "sets node to current node when not provided" do
      alert = Alert.new(valid_attrs())

      assert alert.node == Node.self()
    end

    test "uses provided node when given" do
      alert = Alert.new(Map.put(valid_attrs(), :node, :other@host))

      assert alert.node == :other@host
    end

    test "raises when required attribute is missing" do
      assert_raise KeyError, fn ->
        Alert.new(%{watcher: :beam})
      end
    end

    test "supports all severity levels" do
      for severity <- [:info, :warning, :critical] do
        alert = Alert.new(Map.put(valid_attrs(), :severity, severity))
        assert alert.severity == severity
      end
    end
  end

  describe "generate_id/0" do
    test "returns 16-character hex string" do
      id = Alert.generate_id()

      assert is_binary(id)
      assert byte_size(id) == 16
      assert Regex.match?(~r/^[0-9a-f]{16}$/, id)
    end

    test "generates unique ids" do
      ids = for _ <- 1..100, do: Alert.generate_id()
      unique_ids = Enum.uniq(ids)

      assert length(unique_ids) == 100
    end
  end

  describe "JSON encoding" do
    test "encodes alert to JSON" do
      alert = Alert.new(valid_attrs())

      assert {:ok, json} = Jason.encode(alert)
      assert is_binary(json)
    end

    test "JSON contains all fields" do
      alert = Alert.new(valid_attrs())
      {:ok, json} = Jason.encode(alert)
      decoded = Jason.decode!(json)

      assert decoded["watcher"] == "beam"
      assert decoded["anomaly_type"] == "memory_elevated"
      assert decoded["severity"] == "warning"
      assert decoded["summary"] == "Memory at 72%"
      assert decoded["snapshot"] == %{"memory_utilization_pct" => 72.0}
    end
  end

  defp valid_attrs do
    %{
      watcher: :beam,
      anomaly_type: :memory_elevated,
      severity: :warning,
      summary: "Memory at 72%",
      snapshot: %{memory_utilization_pct: 72.0}
    }
  end
end
