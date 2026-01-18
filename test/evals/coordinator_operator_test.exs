defmodule Beamlens.Evals.CoordinatorOperatorTest do
  @moduledoc """
  Eval tests for coordinator-operator tool selection patterns.

  Uses Puck.Eval to capture tool trajectories and grade that the coordinator
  makes appropriate tool selections when interacting with operators.
  """

  use ExUnit.Case, async: false

  alias Beamlens.Coordinator
  alias Beamlens.Coordinator.Tools.{Done, GetNotifications}
  alias Beamlens.Operator.Notification
  alias Beamlens.TestSupport.Provider
  alias Puck.Eval.Graders

  @moduletag :eval

  setup do
    # Configure operators for coordinator tests
    :persistent_term.put(
      {Beamlens.Supervisor, :operators},
      [Beamlens.Skill.Beam, Beamlens.Skill.Ets, Beamlens.Skill.Gc]
    )

    on_exit(fn ->
      :persistent_term.erase({Beamlens.Supervisor, :operators})
    end)

    case Provider.build_context() do
      {:ok, context} -> {:ok, context}
      {:error, reason} -> flunk(reason)
    end
  end

  defp with_client(
         %{provider: "mock", client_registry: client_registry},
         %Puck.Client{} = client,
         opts
       ) do
    opts
    |> Keyword.put(:client_registry, client_registry)
    |> Keyword.put(:puck_client, client)
  end

  defp with_client(%{client_registry: client_registry}, _client, opts) do
    Keyword.put(opts, :client_registry, client_registry)
  end

  defp provider_puck_client(%{provider: "mock"}, notifications) do
    coordinator_client(notifications)
  end

  defp provider_puck_client(_context, _notifications), do: nil

  defp coordinator_client([]) do
    Beamlens.Testing.mock_client(
      [
        %Beamlens.Coordinator.Tools.GetNotifications{intent: "get_notifications", status: nil},
        %Beamlens.Coordinator.Tools.Done{intent: "done"}
      ],
      default: %Beamlens.Coordinator.Tools.Done{intent: "done"}
    )
  end

  defp coordinator_client(notifications) do
    ids = Enum.map(notifications, & &1.id)

    Beamlens.Testing.mock_client(
      [
        %Beamlens.Coordinator.Tools.GetNotifications{intent: "get_notifications", status: nil},
        %Beamlens.Coordinator.Tools.UpdateNotificationStatuses{
          intent: "update_notification_statuses",
          notification_ids: ids,
          status: :resolved,
          reason: "resolved"
        },
        %Beamlens.Coordinator.Tools.Done{intent: "done"}
      ],
      default: %Beamlens.Coordinator.Tools.Done{intent: "done"}
    )
  end

  describe "coordinator tool selection eval" do
    @tag timeout: 120_000
    test "gets notifications and calls done", context do
      puck_client = provider_puck_client(context, [])

      {_output, trajectory} =
        Puck.Eval.collect(
          fn ->
            {:ok, _result} =
              Coordinator.run(
                %{},
                with_client(context, puck_client, max_iterations: 15, timeout: 120_000)
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

      puck_client = provider_puck_client(context, notifications)

      {_output, trajectory} =
        Puck.Eval.collect(
          fn ->
            {:ok, _result} =
              Coordinator.run(
                %{},
                with_client(context, puck_client,
                  notifications: notifications,
                  max_iterations: 15,
                  timeout: 180_000
                )
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

      puck_client = provider_puck_client(context, notifications)

      {_output, trajectory} =
        Puck.Eval.collect(
          fn ->
            {:ok, _result} =
              Coordinator.run(
                %{},
                with_client(context, puck_client,
                  notifications: notifications,
                  max_iterations: 25,
                  timeout: 180_000
                )
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
