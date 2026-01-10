defmodule Beamlens.Coordinator.ToolsTest do
  use ExUnit.Case, async: true

  alias Beamlens.Coordinator.Tools

  alias Beamlens.Coordinator.Tools.{
    Done,
    GetAlerts,
    ProduceInsight,
    UpdateAlertStatuses
  }

  describe "schema/0 - GetAlerts" do
    test "parses get_alerts without status" do
      schema = Tools.schema()
      input = %{intent: "get_alerts"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %GetAlerts{} = result
      assert result.status == nil
    end

    test "parses get_alerts with unread status" do
      schema = Tools.schema()
      input = %{intent: "get_alerts", status: "unread"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %GetAlerts{} = result
      assert result.status == :unread
    end

    test "parses get_alerts with acknowledged status" do
      schema = Tools.schema()
      input = %{intent: "get_alerts", status: "acknowledged"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %GetAlerts{} = result
      assert result.status == :acknowledged
    end

    test "parses get_alerts with resolved status" do
      schema = Tools.schema()
      input = %{intent: "get_alerts", status: "resolved"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %GetAlerts{} = result
      assert result.status == :resolved
    end

    test "parses get_alerts with all status (becomes nil)" do
      schema = Tools.schema()
      input = %{intent: "get_alerts", status: "all"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %GetAlerts{} = result
      assert result.status == nil
    end
  end

  describe "schema/0 - UpdateAlertStatuses" do
    test "parses update_alert_statuses with all fields" do
      schema = Tools.schema()

      input = %{
        intent: "update_alert_statuses",
        alert_ids: ["alert1", "alert2"],
        status: "acknowledged",
        reason: "Processing these alerts"
      }

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %UpdateAlertStatuses{} = result
      assert result.alert_ids == ["alert1", "alert2"]
      assert result.status == :acknowledged
      assert result.reason == "Processing these alerts"
    end

    test "parses update_alert_statuses without optional reason" do
      schema = Tools.schema()

      input = %{
        intent: "update_alert_statuses",
        alert_ids: ["alert1"],
        status: "resolved"
      }

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %UpdateAlertStatuses{} = result
      assert result.alert_ids == ["alert1"]
      assert result.status == :resolved
      assert result.reason == nil
    end

    test "transforms status to atoms" do
      schema = Tools.schema()

      for status <- ["acknowledged", "resolved"] do
        input = %{
          intent: "update_alert_statuses",
          alert_ids: ["a1"],
          status: status
        }

        {:ok, result} = Zoi.parse(schema, input)
        assert result.status == String.to_atom(status)
      end
    end
  end

  describe "schema/0 - ProduceInsight" do
    test "parses produce_insight with all fields" do
      schema = Tools.schema()

      input = %{
        intent: "produce_insight",
        alert_ids: ["alert1", "alert2"],
        correlation_type: "causal",
        summary: "Memory spike caused scheduler contention",
        root_cause_hypothesis: "Unbounded ETS table growth",
        confidence: "high"
      }

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %ProduceInsight{} = result
      assert result.alert_ids == ["alert1", "alert2"]
      assert result.correlation_type == :causal
      assert result.summary == "Memory spike caused scheduler contention"
      assert result.root_cause_hypothesis == "Unbounded ETS table growth"
      assert result.confidence == :high
    end

    test "parses produce_insight without optional root_cause_hypothesis" do
      schema = Tools.schema()

      input = %{
        intent: "produce_insight",
        alert_ids: ["alert1"],
        correlation_type: "temporal",
        summary: "Alerts close in time",
        confidence: "low"
      }

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %ProduceInsight{} = result
      assert result.root_cause_hypothesis == nil
    end

    test "transforms all correlation types to atoms" do
      schema = Tools.schema()

      for correlation_type <- ["temporal", "causal", "symptomatic"] do
        input = %{
          intent: "produce_insight",
          alert_ids: ["a1"],
          correlation_type: correlation_type,
          summary: "test",
          confidence: "low"
        }

        {:ok, result} = Zoi.parse(schema, input)
        assert result.correlation_type == String.to_atom(correlation_type)
      end
    end

    test "transforms all confidence levels to atoms" do
      schema = Tools.schema()

      for confidence <- ["high", "medium", "low"] do
        input = %{
          intent: "produce_insight",
          alert_ids: ["a1"],
          correlation_type: "temporal",
          summary: "test",
          confidence: confidence
        }

        {:ok, result} = Zoi.parse(schema, input)
        assert result.confidence == String.to_atom(confidence)
      end
    end
  end

  describe "schema/0 - Done" do
    test "parses done" do
      schema = Tools.schema()
      input = %{intent: "done"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %Done{} = result
    end
  end

  describe "schema/0 - invalid inputs" do
    test "rejects invalid intent" do
      schema = Tools.schema()
      input = %{intent: "invalid_tool"}

      assert {:error, _} = Zoi.parse(schema, input)
    end

    test "rejects update_alert_statuses with missing alert_ids" do
      schema = Tools.schema()

      input = %{
        intent: "update_alert_statuses",
        status: "acknowledged"
      }

      assert {:error, _} = Zoi.parse(schema, input)
    end

    test "rejects produce_insight with missing required fields" do
      schema = Tools.schema()

      input = %{
        intent: "produce_insight",
        alert_ids: ["a1"]
      }

      assert {:error, _} = Zoi.parse(schema, input)
    end
  end
end
