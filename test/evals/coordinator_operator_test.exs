defmodule Beamlens.Evals.CoordinatorOperatorTest do
  @moduledoc """
  Eval tests for coordinator-operator tool selection patterns.

  Uses Puck.Eval to capture tool trajectories and grade that the coordinator
  makes appropriate tool selections when interacting with operators.
  """

  use ExUnit.Case, async: false

  alias Beamlens.Coordinator
  alias Beamlens.Coordinator.Tools.{Done, GetNotifications}
  alias Beamlens.IntegrationCase
  alias Beamlens.Operator.Notification
  alias Puck.Eval.Graders

  @moduletag :eval

  setup do
    # Configure operators for coordinator tests
    :persistent_term.put(
      {Beamlens.Supervisor, :skills},
      [Beamlens.Skill.Beam, Beamlens.Skill.Ets, Beamlens.Skill.Gc]
    )

    on_exit(fn ->
      :persistent_term.erase({Beamlens.Supervisor, :skills})
    end)

    case IntegrationCase.build_client_registry() do
      {:ok, registry} ->
        {:ok, client_registry: registry}

      {:error, reason} ->
        flunk(reason)
    end
  end

  describe "coordinator tool selection eval" do
    @tag timeout: 120_000
    test "gets notifications and calls done", context do
      {_output, trajectory} =
        Puck.Eval.collect(
          fn ->
            {:ok, _result} =
              Coordinator.run(%{},
                client_registry: context.client_registry,
                max_iterations: 15,
                timeout: 120_000
              )

            :ok
          end,
          timeout: 200
        )

      result =
        Puck.Eval.grade(nil, trajectory, [
          Graders.output_produced(GetNotifications),
          Graders.output_produced(Done)
        ])

      assert result.passed?,
             "Eval failed.\nSteps: #{trajectory.total_steps}\nResults: #{inspect(result.grader_results, pretty: true)}"
    end

    @tag timeout: 180_000
    test "processes pre-seeded notifications", context do
      notifications = [
        build_notification(%{
          operator: Beamlens.Skill.Beam,
          anomaly_type: "memory_elevated",
          severity: :warning,
          summary: "Memory at 85% - elevated usage"
        })
      ]

      {_output, trajectory} =
        Puck.Eval.collect(
          fn ->
            {:ok, _result} =
              Coordinator.run(%{},
                notifications: notifications,
                client_registry: context.client_registry,
                max_iterations: 15,
                timeout: 180_000
              )

            :ok
          end,
          timeout: 200
        )

      result =
        Puck.Eval.grade(nil, trajectory, [
          Graders.output_produced(GetNotifications),
          Graders.output_produced(Done)
        ])

      assert result.passed?,
             "Eval failed.\nSteps: #{trajectory.total_steps}\nResults: #{inspect(result.grader_results, pretty: true)}"
    end
  end

  describe "coordinator tool selection - complex scenarios" do
    @tag timeout: 180_000
    test "handles correlated notifications", context do
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

      {_output, trajectory} =
        Puck.Eval.collect(
          fn ->
            {:ok, _result} =
              Coordinator.run(%{},
                notifications: notifications,
                client_registry: context.client_registry,
                max_iterations: 25,
                timeout: 180_000
              )

            :ok
          end,
          timeout: 200
        )

      result =
        Puck.Eval.grade(nil, trajectory, [
          Graders.output_produced(GetNotifications),
          Graders.output_produced(Done)
        ])

      assert result.passed?,
             "Basic flow failed.\nSteps: #{trajectory.total_steps}\nResults: #{inspect(result.grader_results, pretty: true)}"
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
