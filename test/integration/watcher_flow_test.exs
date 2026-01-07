defmodule Beamlens.Integration.WatcherFlowTest do
  @moduledoc """
  Integration tests for the watcher → alert → investigation flow.

  Tests the full orchestrator-workers pattern where:
  1. Alerts are pushed to AlertQueue
  2. AlertHandler receives notification
  3. Agent.investigate/2 is called
  4. HealthAnalysis is produced
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Beamlens.{Alert, AlertHandler, AlertQueue}

  describe "AlertHandler.investigate/1 with real LLM" do
    @describetag timeout: 120_000

    setup do
      {:ok, queue} = start_supervised(AlertQueue)
      {:ok, handler} = start_supervised({AlertHandler, trigger: :manual})
      {:ok, queue: queue, handler: handler}
    end

    test "investigates pending alerts and returns analysis", %{handler: handler} do
      alert = build_alert(:warning, "Memory elevated to 80%")
      AlertQueue.push(alert)

      assert AlertHandler.pending?(handler)

      {:ok, analysis} = AlertHandler.investigate(handler)

      assert %Beamlens.HealthAnalysis{} = analysis
      assert analysis.status in [:healthy, :warning, :critical]
      refute AlertHandler.pending?(handler)
    end

    test "returns :no_alerts when queue is empty", %{handler: handler} do
      refute AlertHandler.pending?(handler)

      {:ok, :no_alerts} = AlertHandler.investigate(handler)
    end

    test "processes multiple alerts in single investigation", %{handler: handler} do
      alerts = [
        build_alert(:warning, "Memory elevated"),
        build_alert(:info, "Process count spike"),
        build_alert(:warning, "Run queue growing")
      ]

      Enum.each(alerts, &AlertQueue.push/1)
      assert AlertQueue.count() == 3

      {:ok, analysis} = AlertHandler.investigate(handler)

      assert %Beamlens.HealthAnalysis{} = analysis
      assert AlertQueue.count() == 0
    end

    test "analysis includes watcher_alerts as first event", %{handler: handler} do
      alert = build_alert(:critical, "Critical memory exhaustion")
      AlertQueue.push(alert)

      {:ok, analysis} = AlertHandler.investigate(handler)

      [first_event | _] = analysis.events
      assert %Beamlens.Events.ToolCall{intent: "watcher_alerts"} = first_event
    end
  end

  describe "Full supervision tree flow" do
    @describetag timeout: 120_000

    test "Beamlens.investigate/0 processes pending alerts" do
      {:ok, _supervisor} =
        start_supervised(
          {Beamlens,
           watchers: [], alert_handler: [trigger: :manual], circuit_breaker: [enabled: false]}
        )

      alert = build_alert(:warning, "Test anomaly from watcher")
      AlertQueue.push(alert)

      {:ok, analysis} = Beamlens.investigate()

      assert %Beamlens.HealthAnalysis{} = analysis
      assert analysis.status in [:healthy, :warning, :critical]
    end

    test "Beamlens.pending_alerts?/0 reflects queue state" do
      {:ok, _supervisor} =
        start_supervised(
          {Beamlens,
           watchers: [], alert_handler: [trigger: :manual], circuit_breaker: [enabled: false]}
        )

      refute Beamlens.pending_alerts?()

      alert = build_alert(:info, "Test alert")
      AlertQueue.push(alert)

      assert Beamlens.pending_alerts?()
    end
  end

  defp build_alert(severity, summary) do
    Alert.new(%{
      watcher: :beam,
      anomaly_type: :memory_elevated,
      severity: severity,
      summary: summary,
      snapshot: %{
        memory_utilization_pct: 80.0,
        process_count: 120,
        scheduler_run_queue: 3
      }
    })
  end
end
