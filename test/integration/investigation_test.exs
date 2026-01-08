defmodule Beamlens.Integration.InvestigationTest do
  @moduledoc """
  Integration tests for Agent.investigate/2.

  Tests the investigation flow where watcher alerts are analyzed by the agent.
  """

  use Beamlens.IntegrationCase, async: false

  alias Beamlens.{Agent, Alert}

  describe "Agent.investigate/2" do
    @describetag timeout: 120_000

    test "returns :no_alerts when given empty list", %{client_registry: client_registry} do
      assert {:ok, :no_alerts} =
               Agent.investigate([],
                 client_registry: client_registry,
                 timeout: :timer.seconds(60)
               )
    end

    test "investigates single alert and returns health analysis", %{
      client_registry: client_registry
    } do
      alert = build_alert(:warning, "Memory usage elevated at 85%")

      {:ok, analysis} =
        Agent.investigate([alert], client_registry: client_registry, timeout: :timer.seconds(60))

      assert %Beamlens.HealthAnalysis{} = analysis
      assert analysis.status in [:healthy, :warning, :critical]
      assert is_binary(analysis.summary)
      assert is_list(analysis.concerns)
      assert is_list(analysis.recommendations)
    end

    test "investigates multiple alerts and correlates findings", %{
      client_registry: client_registry
    } do
      alerts = [
        build_alert(:warning, "Memory usage elevated at 85%"),
        build_alert(:info, "Process count increased by 20%"),
        build_alert(:warning, "Scheduler run queue growing")
      ]

      {:ok, analysis} =
        Agent.investigate(alerts,
          client_registry: client_registry,
          timeout: :timer.seconds(60)
        )

      assert %Beamlens.HealthAnalysis{} = analysis
      assert analysis.status in [:healthy, :warning, :critical]
    end

    test "first event is watcher_alerts, not snapshot", %{client_registry: client_registry} do
      alert = build_alert(:warning, "Test anomaly")

      {:ok, analysis} =
        Agent.investigate([alert],
          client_registry: client_registry,
          timeout: :timer.seconds(60)
        )

      [first_event | _] = analysis.events
      assert %Beamlens.Events.ToolCall{intent: "watcher_alerts"} = first_event
      assert is_map(first_event.result)
      assert Map.has_key?(first_event.result, :alerts)
    end

    test "watcher_alerts event contains alert data", %{client_registry: client_registry} do
      alert = build_alert(:critical, "Critical memory exhaustion")

      {:ok, analysis} =
        Agent.investigate([alert],
          client_registry: client_registry,
          timeout: :timer.seconds(60)
        )

      [first_event | _] = analysis.events
      [alert_data | _] = first_event.result.alerts

      assert alert_data.watcher == :beam
      assert alert_data.severity == :critical
      assert is_binary(alert_data.summary)
    end

    test "includes LLMCall events showing agent reasoning", %{client_registry: client_registry} do
      alert = build_alert(:warning, "Elevated memory usage")

      {:ok, analysis} =
        Agent.investigate([alert],
          client_registry: client_registry,
          timeout: :timer.seconds(60)
        )

      llm_calls =
        Enum.filter(analysis.events, &match?(%Beamlens.Events.LLMCall{}, &1))

      assert llm_calls != [], "Expected at least one LLMCall event"

      [first_llm_call | _] = llm_calls
      assert is_binary(first_llm_call.tool_selected)
      assert %DateTime{} = first_llm_call.occurred_at
    end

    test "includes JudgeCall event when judge is enabled (default)", %{
      client_registry: client_registry
    } do
      alert = build_alert(:warning, "Test anomaly")

      {:ok, analysis} =
        Agent.investigate([alert],
          client_registry: client_registry,
          timeout: :timer.seconds(60)
        )

      judge_calls =
        Enum.filter(analysis.events, &match?(%Beamlens.Events.JudgeCall{}, &1))

      assert judge_calls != [], "Expected at least one JudgeCall event"

      [judge_call | _] = judge_calls
      assert judge_call.verdict in [:accept, :retry]
      assert judge_call.confidence in [:high, :medium, :low]
    end

    test "excludes JudgeCall events when judge is disabled", %{client_registry: client_registry} do
      alert = build_alert(:warning, "Test anomaly")

      {:ok, analysis} =
        Agent.investigate([alert],
          judge: false,
          client_registry: client_registry,
          timeout: :timer.seconds(60)
        )

      judge_calls =
        Enum.filter(analysis.events, &match?(%Beamlens.Events.JudgeCall{}, &1))

      assert judge_calls == [], "Expected no JudgeCall events when judge: false"
    end
  end

  defp build_alert(severity, summary) do
    Alert.new(%{
      watcher: :beam,
      anomaly_type: :memory_elevated,
      severity: severity,
      summary: summary,
      snapshot: %{
        memory_utilization_pct: 85.0,
        process_count: 150,
        scheduler_run_queue: 5
      }
    })
  end
end
