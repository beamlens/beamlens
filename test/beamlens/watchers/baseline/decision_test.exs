defmodule Beamlens.Watchers.Baseline.DecisionTest do
  use ExUnit.Case, async: true

  alias Beamlens.Watchers.Baseline.Decision

  alias Beamlens.Watchers.Baseline.Decision.{
    Alert,
    ContinueObserving,
    Healthy,
    InvestigationComplete,
    WatcherFindings
  }

  alias Beamlens.Tools.{GetMemoryStats, GetOverview, GetProcessStats, GetSchedulerStats}

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

  describe "schema/0 parsing Alert" do
    test "parses valid report_anomaly with all fields" do
      input = %{
        intent: "report_anomaly",
        anomaly_type: "memory_spike",
        severity: "warning",
        summary: "Memory usage increased 50% in last hour",
        evidence: ["Memory at 85%", "Trend shows consistent increase"],
        confidence: "high"
      }

      assert {:ok, %Alert{} = decision} = Zoi.parse(Decision.schema(), input)
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

      assert {:ok, %Alert{} = decision} = Zoi.parse(Decision.schema(), input)
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

      assert {:ok, %Alert{} = decision} = Zoi.parse(Decision.schema(), input)
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

      assert {:ok, %Alert{} = decision} = Zoi.parse(Decision.schema(), input)
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

      assert {:ok, %Alert{} = decision} = Zoi.parse(Decision.schema(), input)
      assert decision.cooldown_minutes == 5
    end
  end

  describe "schema/0 parsing Healthy" do
    test "parses valid report_healthy with medium confidence" do
      input = %{
        intent: "report_healthy",
        summary: "System operating within normal parameters",
        confidence: "medium"
      }

      assert {:ok, %Healthy{} = decision} = Zoi.parse(Decision.schema(), input)
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

      assert {:ok, %Healthy{} = decision} = Zoi.parse(Decision.schema(), input)
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

  describe "investigation_schema/0 parsing InvestigationComplete" do
    test "parses valid investigation_complete with findings" do
      input = %{
        intent: "investigation_complete",
        findings: %{
          anomaly_type: "memory_leak",
          severity: "warning",
          root_cause: "GenServer accumulating state without cleanup",
          evidence: ["Memory grew 50% over 1 hour", "Process heap: 500MB"],
          recommendations: ["Add periodic cleanup", "Consider ETS for large data"],
          confidence: "high"
        }
      }

      assert {:ok, %InvestigationComplete{} = result} =
               Zoi.parse(Decision.investigation_schema(), input)

      assert result.intent == "investigation_complete"
      assert %WatcherFindings{} = result.findings
      assert result.findings.anomaly_type == "memory_leak"
      assert result.findings.severity == :warning
      assert result.findings.root_cause == "GenServer accumulating state without cleanup"
      assert result.findings.evidence == ["Memory grew 50% over 1 hour", "Process heap: 500MB"]

      assert result.findings.recommendations == [
               "Add periodic cleanup",
               "Consider ETS for large data"
             ]

      assert result.findings.confidence == :high
    end

    test "parses investigation_complete with critical severity" do
      input = %{
        intent: "investigation_complete",
        findings: %{
          anomaly_type: "scheduler_deadlock",
          severity: "critical",
          root_cause: "Blocking call in scheduler",
          evidence: ["Run queue: 500"],
          recommendations: ["Move blocking work to Task"],
          confidence: "medium"
        }
      }

      assert {:ok, %InvestigationComplete{findings: findings}} =
               Zoi.parse(Decision.investigation_schema(), input)

      assert findings.severity == :critical
      assert findings.confidence == :medium
    end

    test "parses investigation_complete with low confidence" do
      input = %{
        intent: "investigation_complete",
        findings: %{
          anomaly_type: "unknown_spike",
          severity: "info",
          root_cause: "Unable to determine root cause",
          evidence: ["Transient spike observed"],
          recommendations: ["Continue monitoring"],
          confidence: "low"
        }
      }

      assert {:ok, %InvestigationComplete{findings: findings}} =
               Zoi.parse(Decision.investigation_schema(), input)

      assert findings.confidence == :low
    end
  end

  describe "investigation_schema/0 parsing tool selection" do
    test "parses get_memory_stats into struct" do
      input = %{intent: "get_memory_stats"}

      assert {:ok, %GetMemoryStats{intent: "get_memory_stats"}} =
               Zoi.parse(Decision.investigation_schema(), input)
    end

    test "parses get_overview into struct" do
      input = %{intent: "get_overview"}

      assert {:ok, %GetOverview{intent: "get_overview"}} =
               Zoi.parse(Decision.investigation_schema(), input)
    end

    test "parses get_process_stats into struct" do
      input = %{intent: "get_process_stats"}

      assert {:ok, %GetProcessStats{intent: "get_process_stats"}} =
               Zoi.parse(Decision.investigation_schema(), input)
    end

    test "parses get_scheduler_stats into struct" do
      input = %{intent: "get_scheduler_stats"}

      assert {:ok, %GetSchedulerStats{intent: "get_scheduler_stats"}} =
               Zoi.parse(Decision.investigation_schema(), input)
    end
  end
end
