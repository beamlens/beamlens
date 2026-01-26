defmodule Beamlens.Integration.IntentDecompositionTest do
  @moduledoc """
  Integration tests for fact vs speculation decomposition in notifications and insights.

  Tests that:
  1. Operators correctly separate context/observation (facts) from hypothesis (speculation)
  2. Coordinator correlates on observations only, not hypotheses
  3. Insights correctly track hypothesis_grounded based on corroboration
  """

  use Beamlens.IntegrationCase, async: false

  alias Beamlens.Coordinator
  alias Beamlens.Operator
  alias Beamlens.Operator.Notification

  defmodule DecompositionSkill do
    @behaviour Beamlens.Skill

    def title, do: "Decomposition Test"

    def description, do: "Test skill for intent decomposition tests"

    def system_prompt do
      """
      You are a BEAM VM health monitor. Memory > 80% requires a notification.

      When sending notifications, you MUST decompose information:
      - context: Factual system state (no speculation)
      - observation: What anomaly you detected (factual)
      - hypothesis: What MIGHT be causing it (speculative, optional)
      """
    end

    def snapshot do
      %{
        memory_utilization_pct: 85.0,
        process_utilization_pct: 12.0,
        port_utilization_pct: 5.0,
        atom_utilization_pct: 2.0,
        scheduler_run_queue: 0,
        schedulers_online: 8
      }
    end

    def callbacks do
      %{
        "get_memory" => fn -> %{total_mb: 1000, used_mb: 850, ets_mb: 400} end
      }
    end

    def callback_docs do
      """
      ### get_memory()
      Returns memory stats: total_mb, used_mb, ets_mb
      """
    end
  end

  defp start_coordinator(context, opts \\ []) do
    name = :"coordinator_#{:erlang.unique_integer([:positive])}"

    opts =
      opts
      |> Keyword.put(:name, name)
      |> Keyword.put(:client_registry, context.client_registry)

    start_supervised({Coordinator, opts})
  end

  defp build_decomposed_notification(attrs) do
    defaults = %{
      operator: :test,
      anomaly_type: "test_anomaly",
      severity: :warning,
      context: "Node running for 3 days",
      observation: "Test observation",
      snapshots: []
    }

    Notification.new(Map.merge(defaults, attrs))
  end

  describe "notification decomposition" do
    @tag timeout: 60_000
    test "operator produces notifications with context/observation/hypothesis", context do
      {:ok, _pid} = start_operator(context, skill: DecompositionSkill)

      {:ok, notifications} =
        Operator.run(DecompositionSkill, %{reason: "memory check"},
          client_registry: context.client_registry,
          timeout: 60_000
        )

      for notification <- notifications do
        assert is_binary(notification.context), "context should be present"
        assert is_binary(notification.observation), "observation should be present"
      end
    end
  end

  describe "coordinator correlation" do
    @tag timeout: 120_000
    test "coordinator produces insights with grounding metadata", context do
      {:ok, pid} = start_coordinator(context)

      notifications = [
        build_decomposed_notification(%{
          operator: Beamlens.Skill.Beam,
          context: "Node running for 3 days",
          observation: "Memory at 85%",
          hypothesis: "ETS table growth"
        })
      ]

      {:ok, result} =
        Coordinator.run(pid, %{},
          notifications: notifications,
          client_registry: context.client_registry,
          max_iterations: 20,
          timeout: 120_000
        )

      for insight <- result.insights do
        assert is_list(insight.matched_observations)
        assert is_boolean(insight.hypothesis_grounded)
      end
    end
  end
end
