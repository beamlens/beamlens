defmodule Beamlens.Operator.ToolsTest do
  use ExUnit.Case, async: true

  alias Beamlens.Operator.Tools

  alias Beamlens.Operator.Tools.{
    Execute,
    GetNotifications,
    GetSnapshot,
    GetSnapshots,
    SendNotification,
    SetState,
    TakeSnapshot,
    Think,
    Wait
  }

  describe "schema/0" do
    test "parses set_state" do
      schema = Tools.schema()
      input = %{intent: "set_state", state: "healthy", reason: "All good"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %SetState{} = result
      assert result.state == :healthy
      assert result.reason == "All good"
    end

    test "parses send_notification" do
      schema = Tools.schema()

      input = %{
        intent: "send_notification",
        type: "memory_elevated",
        summary: "High memory",
        severity: "warning",
        snapshot_ids: ["abc123"]
      }

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %SendNotification{} = result
      assert result.type == "memory_elevated"
      assert result.severity == :warning
      assert result.snapshot_ids == ["abc123"]
    end

    test "rejects send_notification with missing snapshot_ids" do
      schema = Tools.schema()

      input = %{
        intent: "send_notification",
        type: "memory_elevated",
        summary: "High memory",
        severity: "warning"
      }

      assert {:error, _} = Zoi.parse(schema, input)
    end

    test "parses get_notifications" do
      schema = Tools.schema()
      input = %{intent: "get_notifications"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %GetNotifications{} = result
    end

    test "parses take_snapshot" do
      schema = Tools.schema()
      input = %{intent: "take_snapshot"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %TakeSnapshot{} = result
    end

    test "parses get_snapshot" do
      schema = Tools.schema()
      input = %{intent: "get_snapshot", id: "snap123"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %GetSnapshot{} = result
      assert result.id == "snap123"
    end

    test "parses get_snapshots with optional fields" do
      schema = Tools.schema()
      input = %{intent: "get_snapshots", limit: 10, offset: 5}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %GetSnapshots{} = result
      assert result.limit == 10
      assert result.offset == 5
    end

    test "parses get_snapshots without optional fields" do
      schema = Tools.schema()
      input = %{intent: "get_snapshots"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %GetSnapshots{} = result
      assert result.limit == nil
      assert result.offset == nil
    end

    test "parses execute" do
      schema = Tools.schema()
      input = %{intent: "execute", code: "return get_memory()"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %Execute{} = result
      assert result.code == "return get_memory()"
    end

    test "parses wait" do
      schema = Tools.schema()
      input = %{intent: "wait", ms: 5000}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %Wait{} = result
      assert result.ms == 5000
    end

    test "parses think" do
      schema = Tools.schema()
      input = %{intent: "think", thought: "Analyzing high memory usage pattern..."}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %Think{} = result
      assert result.thought == "Analyzing high memory usage pattern..."
    end

    test "transforms all valid states" do
      schema = Tools.schema()

      for state <- ["healthy", "observing", "warning", "critical"] do
        input = %{intent: "set_state", state: state, reason: "test"}
        {:ok, result} = Zoi.parse(schema, input)
        assert result.state == String.to_atom(state)
      end
    end

    test "transforms all valid severities" do
      schema = Tools.schema()

      for severity <- ["info", "warning", "critical"] do
        input = %{
          intent: "send_notification",
          type: "test",
          summary: "test",
          severity: severity,
          snapshot_ids: ["id1"]
        }

        {:ok, result} = Zoi.parse(schema, input)
        assert result.severity == String.to_atom(severity)
      end
    end

    test "rejects invalid intent" do
      schema = Tools.schema()
      input = %{intent: "invalid_tool"}

      assert {:error, _} = Zoi.parse(schema, input)
    end

    test "parses done tool" do
      schema = Tools.schema()
      input = %{intent: "done"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %Tools.Done{} = result
    end
  end
end
