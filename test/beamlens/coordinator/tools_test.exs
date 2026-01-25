defmodule Beamlens.Coordinator.ToolsTest do
  use ExUnit.Case, async: true

  alias Beamlens.Coordinator.Tools

  alias Beamlens.Coordinator.Tools.{
    Done,
    GetNotifications,
    GetOperatorStatuses,
    InvokeOperators,
    MessageOperator,
    ProduceInsight,
    Think,
    UpdateNotificationStatuses,
    Wait
  }

  describe "schema/0 - GetNotifications" do
    test "parses get_notifications without status" do
      schema = Tools.schema()
      input = %{intent: "get_notifications"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %GetNotifications{} = result
      assert result.status == nil
    end

    test "parses get_notifications with unread status" do
      schema = Tools.schema()
      input = %{intent: "get_notifications", status: "unread"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %GetNotifications{} = result
      assert result.status == :unread
    end

    test "parses get_notifications with acknowledged status" do
      schema = Tools.schema()
      input = %{intent: "get_notifications", status: "acknowledged"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %GetNotifications{} = result
      assert result.status == :acknowledged
    end

    test "parses get_notifications with resolved status" do
      schema = Tools.schema()
      input = %{intent: "get_notifications", status: "resolved"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %GetNotifications{} = result
      assert result.status == :resolved
    end

    test "parses get_notifications with all status (becomes nil)" do
      schema = Tools.schema()
      input = %{intent: "get_notifications", status: "all"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %GetNotifications{} = result
      assert result.status == nil
    end
  end

  describe "schema/0 - UpdateNotificationStatuses" do
    test "parses update_notification_statuses with all fields" do
      schema = Tools.schema()

      input = %{
        intent: "update_notification_statuses",
        notification_ids: ["notification1", "notification2"],
        status: "acknowledged",
        reason: "Processing these notifications"
      }

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %UpdateNotificationStatuses{} = result
      assert result.notification_ids == ["notification1", "notification2"]
      assert result.status == :acknowledged
      assert result.reason == "Processing these notifications"
    end

    test "parses update_notification_statuses without optional reason" do
      schema = Tools.schema()

      input = %{
        intent: "update_notification_statuses",
        notification_ids: ["notification1"],
        status: "resolved"
      }

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %UpdateNotificationStatuses{} = result
      assert result.notification_ids == ["notification1"]
      assert result.status == :resolved
      assert result.reason == nil
    end

    test "transforms status to atoms" do
      schema = Tools.schema()

      for status <- ["acknowledged", "resolved"] do
        input = %{
          intent: "update_notification_statuses",
          notification_ids: ["n1"],
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
        notification_ids: ["notification1", "notification2"],
        correlation_type: "causal",
        summary: "Memory spike caused scheduler contention",
        matched_observations: ["Memory at 85%", "Run queue at 50"],
        hypothesis_grounded: true,
        root_cause_hypothesis: "Unbounded ETS table growth",
        confidence: "high"
      }

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %ProduceInsight{} = result
      assert result.notification_ids == ["notification1", "notification2"]
      assert result.correlation_type == :causal
      assert result.summary == "Memory spike caused scheduler contention"
      assert result.matched_observations == ["Memory at 85%", "Run queue at 50"]
      assert result.hypothesis_grounded == true
      assert result.root_cause_hypothesis == "Unbounded ETS table growth"
      assert result.confidence == :high
    end

    test "parses produce_insight without optional root_cause_hypothesis" do
      schema = Tools.schema()

      input = %{
        intent: "produce_insight",
        notification_ids: ["notification1"],
        correlation_type: "temporal",
        summary: "Notifications close in time",
        matched_observations: ["observation1"],
        hypothesis_grounded: false,
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
          notification_ids: ["n1"],
          correlation_type: correlation_type,
          summary: "test",
          matched_observations: ["observation1"],
          hypothesis_grounded: false,
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
          notification_ids: ["n1"],
          correlation_type: "temporal",
          summary: "test",
          matched_observations: ["observation1"],
          hypothesis_grounded: false,
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

  describe "schema/0 - Think" do
    test "parses think" do
      schema = Tools.schema()
      input = %{intent: "think", thought: "These notifications seem related..."}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %Think{} = result
      assert result.thought == "These notifications seem related..."
    end
  end

  describe "schema/0 - InvokeOperators" do
    test "parses invoke_operators with skills" do
      schema = Tools.schema()
      input = %{intent: "invoke_operators", skills: ["beam", "ets"]}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %InvokeOperators{} = result
      assert result.skills == ["beam", "ets"]
      assert result.context == nil
    end

    test "parses invoke_operators with optional context" do
      schema = Tools.schema()

      input = %{
        intent: "invoke_operators",
        skills: ["beam"],
        context: "High memory usage detected"
      }

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %InvokeOperators{} = result
      assert result.skills == ["beam"]
      assert result.context == "High memory usage detected"
    end
  end

  describe "schema/0 - MessageOperator" do
    test "parses message_operator" do
      schema = Tools.schema()

      input = %{
        intent: "message_operator",
        skill: "beam",
        message: "What is the current memory usage?"
      }

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %MessageOperator{} = result
      assert result.skill == "beam"
      assert result.message == "What is the current memory usage?"
    end
  end

  describe "schema/0 - GetOperatorStatuses" do
    test "parses get_operator_statuses" do
      schema = Tools.schema()
      input = %{intent: "get_operator_statuses"}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %GetOperatorStatuses{} = result
    end
  end

  describe "schema/0 - Wait" do
    test "parses wait with milliseconds" do
      schema = Tools.schema()
      input = %{intent: "wait", ms: 5000}

      assert {:ok, result} = Zoi.parse(schema, input)
      assert %Wait{} = result
      assert result.ms == 5000
    end
  end

  describe "schema/0 - invalid inputs" do
    test "rejects invalid intent" do
      schema = Tools.schema()
      input = %{intent: "invalid_tool"}

      assert {:error, _} = Zoi.parse(schema, input)
    end

    test "rejects update_notification_statuses with missing notification_ids" do
      schema = Tools.schema()

      input = %{
        intent: "update_notification_statuses",
        status: "acknowledged"
      }

      assert {:error, _} = Zoi.parse(schema, input)
    end

    test "rejects produce_insight with missing required fields" do
      schema = Tools.schema()

      input = %{
        intent: "produce_insight",
        notification_ids: ["n1"]
      }

      assert {:error, _} = Zoi.parse(schema, input)
    end
  end
end
