defmodule Beamlens.Integration.CoordinatorOperatorTest do
  @moduledoc """
  Integration tests for coordinator-operator communication.

  Tests the on-demand mode where the coordinator can:
  - Invoke operators via InvokeOperators tool
  - Receive real-time notifications from operators
  - Query operator status via GetOperatorStatuses
  - Message operators (LLM-to-LLM) via MessageOperator
  """

  use Beamlens.IntegrationCase, async: false

  alias Beamlens.Coordinator
  alias Beamlens.Operator.Notification

  setup context do
    start_supervised!({Coordinator, name: Coordinator, client_registry: context.client_registry})

    :ok
  end

  describe "coordinator on-demand mode" do
    @tag timeout: 120_000
    test "completes analysis and returns result", context do
      ref = make_ref()
      parent = self()

      events = [
        [:beamlens, :coordinator, :iteration_start],
        [:beamlens, :coordinator, :get_notifications],
        [:beamlens, :coordinator, :done]
      ]

      for event <- events do
        :telemetry.attach(
          {ref, event},
          event,
          fn event_name, _measurements, metadata, _ ->
            send(parent, {:telemetry, event_name, metadata})
          end,
          nil
        )
      end

      on_exit(fn ->
        for event <- events do
          :telemetry.detach({ref, event})
        end
      end)

      {:ok, result} =
        Coordinator.run(%{},
          client_registry: context.client_registry,
          max_iterations: 15,
          timeout: 120_000
        )

      assert is_map(result)
      assert Map.has_key?(result, :insights)
      assert Map.has_key?(result, :operator_results)
      assert is_list(result.insights)
      assert is_list(result.operator_results)

      assert_receive {:telemetry, [:beamlens, :coordinator, :iteration_start], _}, 0
      assert_receive {:telemetry, [:beamlens, :coordinator, :done], _}, 0
    end

    @tag timeout: 180_000
    test "processes pre-seeded notifications", context do
      ref = make_ref()
      parent = self()

      events = [
        [:beamlens, :coordinator, :get_notifications],
        [:beamlens, :coordinator, :update_notification_statuses],
        [:beamlens, :coordinator, :done]
      ]

      for event <- events do
        :telemetry.attach(
          {ref, event},
          event,
          fn event_name, _measurements, metadata, _ ->
            send(parent, {:telemetry, event_name, metadata})
          end,
          nil
        )
      end

      on_exit(fn ->
        for event <- events do
          :telemetry.detach({ref, event})
        end
      end)

      notifications = [
        build_notification(%{
          operator: Beamlens.Skill.Beam,
          anomaly_type: "memory_elevated",
          severity: :warning,
          summary: "Memory at 78% - elevated usage"
        }),
        build_notification(%{
          operator: Beamlens.Skill.Beam,
          anomaly_type: "scheduler_contention",
          severity: :warning,
          summary: "Run queue at 45 - scheduler pressure"
        })
      ]

      {:ok, result} =
        Coordinator.run(%{},
          notifications: notifications,
          client_registry: context.client_registry,
          max_iterations: 20,
          timeout: 180_000
        )

      assert is_map(result)
      assert is_list(result.insights)

      assert_receive {:telemetry, [:beamlens, :coordinator, :get_notifications],
                      %{count: count, status: status}},
                     0

      assert count >= 0
      assert status in [:unread, :acknowledged, :resolved, :all, nil]
      assert_receive {:telemetry, [:beamlens, :coordinator, :done], _}, 0
    end
  end

  describe "coordinator with correlated notifications" do
    @tag timeout: 180_000
    test "completes with correlated notifications", context do
      notifications = [
        build_notification(%{
          operator: Beamlens.Skill.Beam,
          anomaly_type: "memory_elevated",
          severity: :warning,
          summary: "Memory at 85%"
        }),
        build_notification(%{
          operator: Beamlens.Skill.Beam,
          anomaly_type: "gc_pressure",
          severity: :warning,
          summary: "High GC frequency"
        })
      ]

      {:ok, result} =
        Coordinator.run(%{},
          notifications: notifications,
          client_registry: context.client_registry,
          max_iterations: 25,
          timeout: 180_000
        )

      assert is_map(result)
      assert is_list(result.insights)
    end
  end

  defp build_notification(overrides) do
    Notification.new(
      Map.merge(
        %{
          operator: :test,
          anomaly_type: "test_anomaly",
          severity: :info,
          summary: "Test notification",
          snapshots: []
        },
        overrides
      )
    )
  end
end
