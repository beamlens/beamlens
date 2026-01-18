defmodule Beamlens.Integration.CoordinatorTest do
  @moduledoc false

  use Beamlens.IntegrationCase, async: false

  alias Beamlens.Coordinator
  alias Beamlens.Operator.Notification

  defp start_coordinator(context, opts \\ [])

  defp start_coordinator(%{puck_client: %Puck.Client{}} = context, opts) do
    name = :"coordinator_#{:erlang.unique_integer([:positive])}"

    puck_client =
      Beamlens.Testing.mock_client(
        [
          %Beamlens.Coordinator.Tools.GetNotifications{intent: "get_notifications", status: nil},
          %Beamlens.Coordinator.Tools.Done{intent: "done"}
        ],
        default: %Beamlens.Coordinator.Tools.Done{intent: "done"}
      )

    opts =
      opts
      |> Keyword.put(:name, name)
      |> Keyword.put(:client_registry, context.client_registry)
      |> Keyword.put(:puck_client, puck_client)

    start_supervised({Coordinator, opts})
  end

  defp start_coordinator(context, opts) do
    name = :"coordinator_#{:erlang.unique_integer([:positive])}"

    opts =
      opts
      |> Keyword.put(:name, name)
      |> Keyword.put(:client_registry, context.client_registry)

    start_supervised({Coordinator, opts})
  end

  defp build_test_notification(overrides \\ %{}) do
    Notification.new(
      Map.merge(
        %{
          operator: :integration_test,
          anomaly_type: "test_anomaly",
          severity: :warning,
          summary: "Test notification for integration testing",
          snapshots: []
        },
        overrides
      )
    )
  end

  defp inject_notification(pid, notification) do
    # Simulate an operator sending a notification
    fake_operator_pid = self()

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running_operators:
            Map.put(state.running_operators, fake_operator_pid, %{
              skill: notification.operator,
              ref: make_ref(),
              started_at: DateTime.utc_now()
            })
      }
    end)

    send(pid, {:operator_notification, fake_operator_pid, notification})
    notification
  end

  describe "coordinator lifecycle" do
    @tag timeout: 30_000
    test "starts and processes an injected notification", context do
      ref = make_ref()
      parent = self()
      on_exit(fn -> :telemetry.detach(ref) end)

      :telemetry.attach(
        ref,
        [:beamlens, :coordinator, :iteration_start],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :iteration_start, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator(context)

      notification = build_test_notification()
      inject_notification(pid, notification)

      assert_receive {:telemetry, :iteration_start, %{iteration: 0}}, 10_000
    end

    @tag timeout: 60_000
    test "emits llm events during loop", context do
      ref = make_ref()
      parent = self()
      on_exit(fn -> :telemetry.detach(ref) end)

      :telemetry.attach(
        ref,
        [:beamlens, :llm, :start],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :llm_start, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator(context)

      notification = build_test_notification()
      inject_notification(pid, notification)

      assert_receive {:telemetry, :llm_start, %{trace_id: trace_id}}, 15_000
      assert is_binary(trace_id)
    end

    @tag timeout: 60_000
    test "processes tool response and continues or stops", context do
      ref = make_ref()
      parent = self()

      events = [
        [:beamlens, :coordinator, :get_notifications],
        [:beamlens, :coordinator, :update_notification_statuses],
        [:beamlens, :coordinator, :insight_produced],
        [:beamlens, :coordinator, :done],
        [:beamlens, :coordinator, :llm_error]
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

      {:ok, pid} = start_coordinator(context)

      notification =
        build_test_notification(%{summary: "Memory at 85% - elevated but not critical"})

      inject_notification(pid, notification)

      received_event =
        receive do
          {:telemetry, [:beamlens, :coordinator, :get_notifications], _} ->
            :get_notifications

          {:telemetry, [:beamlens, :coordinator, :update_notification_statuses], _} ->
            :update_statuses

          {:telemetry, [:beamlens, :coordinator, :insight_produced], _} ->
            :insight_produced

          {:telemetry, [:beamlens, :coordinator, :done], _} ->
            :done

          {:telemetry, [:beamlens, :coordinator, :llm_error], metadata} ->
            {:llm_error, metadata}
        after
          30_000 -> :timeout
        end

      case received_event do
        {:llm_error, metadata} ->
          flunk("LLM error occurred: #{inspect(metadata)}")

        :timeout ->
          flunk("Timeout waiting for tool action - no telemetry received")

        _event ->
          :ok
      end
    end
  end

  describe "multi-notification processing" do
    @tag timeout: 90_000
    test "handles multiple related notifications", context do
      ref = make_ref()
      parent = self()

      events = [
        [:beamlens, :coordinator, :operator_notification_received],
        [:beamlens, :coordinator, :iteration_start]
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

      {:ok, pid} = start_coordinator(context)

      notification1 =
        build_test_notification(%{
          operator: :beam,
          anomaly_type: "memory_elevated",
          severity: :warning,
          summary: "Memory at 78% - elevated usage detected"
        })

      notification2 =
        build_test_notification(%{
          operator: :beam,
          anomaly_type: "scheduler_contention",
          severity: :warning,
          summary: "Run queue at 45 - scheduler pressure detected"
        })

      inject_notification(pid, notification1)

      assert_receive {:telemetry, [:beamlens, :coordinator, :operator_notification_received],
                      %{notification_id: _}},
                     5_000

      inject_notification(pid, notification2)

      assert_receive {:telemetry, [:beamlens, :coordinator, :operator_notification_received],
                      %{notification_id: _}},
                     5_000

      assert_receive {:telemetry, [:beamlens, :coordinator, :iteration_start], %{iteration: _}},
                     10_000

      status = Coordinator.status(pid)
      assert status.notification_count == 2
    end
  end
end
