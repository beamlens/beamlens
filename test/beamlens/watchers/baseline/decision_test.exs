defmodule Beamlens.Watchers.Baseline.DecisionTest do
  use ExUnit.Case, async: true

  alias Beamlens.Watchers.Baseline.Decision
  alias Beamlens.Watchers.Baseline.Decision.{ContinueObserving, ReportAnomaly, ReportHealthy}

  describe "schema/0 parsing ContinueObserving" do
    test "parses valid continue_observing with low confidence" do
      input = %{
        intent: "continue_observing",
        notes: "Need more observations to establish baseline",
        confidence: "low"
      }

      assert {:ok, %ContinueObserving{} = decision} = Zoi.parse(Decision.schema(), input)
      assert decision.intent == "continue_observing"
      assert decision.notes == "Need more observations to establish baseline"
      assert decision.confidence == :low
    end

    test "parses valid continue_observing with medium confidence" do
      input = %{
        intent: "continue_observing",
        notes: "Patterns emerging but not stable yet",
        confidence: "medium"
      }

      assert {:ok, %ContinueObserving{} = decision} = Zoi.parse(Decision.schema(), input)
      assert decision.confidence == :medium
    end

    test "rejects continue_observing with high confidence" do
      input = %{
        intent: "continue_observing",
        notes: "Some notes",
        confidence: "high"
      }

      assert {:error, _} = Zoi.parse(Decision.schema(), input)
    end
  end

  describe "schema/0 parsing ReportAnomaly" do
    test "parses valid report_anomaly with all fields" do
      input = %{
        intent: "report_anomaly",
        anomaly_type: "memory_spike",
        severity: "warning",
        summary: "Memory usage increased 50% in last hour",
        evidence: ["Memory at 85%", "Trend shows consistent increase"],
        confidence: "high"
      }

      assert {:ok, %ReportAnomaly{} = decision} = Zoi.parse(Decision.schema(), input)
      assert decision.intent == "report_anomaly"
      assert decision.anomaly_type == "memory_spike"
      assert decision.severity == :warning
      assert decision.summary == "Memory usage increased 50% in last hour"
      assert decision.evidence == ["Memory at 85%", "Trend shows consistent increase"]
      assert decision.confidence == :high
    end

    test "parses report_anomaly with info severity" do
      input = %{
        intent: "report_anomaly",
        anomaly_type: "process_count_change",
        severity: "info",
        summary: "Process count changed",
        evidence: ["Count went from 100 to 150"],
        confidence: "medium"
      }

      assert {:ok, %ReportAnomaly{} = decision} = Zoi.parse(Decision.schema(), input)
      assert decision.severity == :info
    end

    test "parses report_anomaly with critical severity" do
      input = %{
        intent: "report_anomaly",
        anomaly_type: "scheduler_saturation",
        severity: "critical",
        summary: "Schedulers at 100% utilization",
        evidence: ["All schedulers maxed"],
        confidence: "high"
      }

      assert {:ok, %ReportAnomaly{} = decision} = Zoi.parse(Decision.schema(), input)
      assert decision.severity == :critical
    end

    test "rejects report_anomaly with low confidence" do
      input = %{
        intent: "report_anomaly",
        anomaly_type: "test",
        severity: "warning",
        summary: "Test",
        evidence: [],
        confidence: "low"
      }

      assert {:error, _} = Zoi.parse(Decision.schema(), input)
    end

    test "rejects report_anomaly with invalid severity" do
      input = %{
        intent: "report_anomaly",
        anomaly_type: "test",
        severity: "urgent",
        summary: "Test",
        evidence: [],
        confidence: "high"
      }

      assert {:error, _} = Zoi.parse(Decision.schema(), input)
    end

    test "parses report_anomaly with explicit cooldown_minutes" do
      input = %{
        intent: "report_anomaly",
        anomaly_type: "memory_spike",
        severity: "warning",
        summary: "Memory elevated",
        evidence: ["Memory at 85%"],
        confidence: "high",
        cooldown_minutes: 15
      }

      assert {:ok, %ReportAnomaly{} = decision} = Zoi.parse(Decision.schema(), input)
      assert decision.cooldown_minutes == 15
    end

    test "defaults cooldown_minutes to 5 when omitted" do
      input = %{
        intent: "report_anomaly",
        anomaly_type: "memory_spike",
        severity: "warning",
        summary: "Memory elevated",
        evidence: ["Memory at 85%"],
        confidence: "high"
      }

      assert {:ok, %ReportAnomaly{} = decision} = Zoi.parse(Decision.schema(), input)
      assert decision.cooldown_minutes == 5
    end
  end

  describe "schema/0 parsing ReportHealthy" do
    test "parses valid report_healthy with medium confidence" do
      input = %{
        intent: "report_healthy",
        summary: "System operating within normal parameters",
        confidence: "medium"
      }

      assert {:ok, %ReportHealthy{} = decision} = Zoi.parse(Decision.schema(), input)
      assert decision.intent == "report_healthy"
      assert decision.summary == "System operating within normal parameters"
      assert decision.confidence == :medium
    end

    test "parses valid report_healthy with high confidence" do
      input = %{
        intent: "report_healthy",
        summary: "All metrics stable over observation window",
        confidence: "high"
      }

      assert {:ok, %ReportHealthy{} = decision} = Zoi.parse(Decision.schema(), input)
      assert decision.confidence == :high
    end

    test "rejects report_healthy with low confidence" do
      input = %{
        intent: "report_healthy",
        summary: "Test",
        confidence: "low"
      }

      assert {:error, _} = Zoi.parse(Decision.schema(), input)
    end
  end

  describe "schema/0 union discriminator" do
    test "rejects unknown intent value" do
      input = %{
        intent: "unknown_intent",
        summary: "Test"
      }

      assert {:error, _} = Zoi.parse(Decision.schema(), input)
    end

    test "rejects missing intent field" do
      input = %{
        summary: "Test",
        confidence: "high"
      }

      assert {:error, _} = Zoi.parse(Decision.schema(), input)
    end

    test "rejects missing required fields for continue_observing" do
      input = %{
        intent: "continue_observing",
        confidence: "low"
      }

      assert {:error, _} = Zoi.parse(Decision.schema(), input)
    end

    test "rejects missing required fields for report_anomaly" do
      input = %{
        intent: "report_anomaly",
        severity: "warning",
        confidence: "high"
      }

      assert {:error, _} = Zoi.parse(Decision.schema(), input)
    end
  end
end
