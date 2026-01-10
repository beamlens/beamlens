defmodule Beamlens.Integration.CoordinatorTest do
  @moduledoc false

  use Beamlens.IntegrationCase, async: false

  alias Beamlens.Coordinator
  alias Beamlens.Watcher.Alert

  defp start_coordinator(context, opts \\ []) do
    name = :"coordinator_#{:erlang.unique_integer([:positive])}"

    opts =
      opts
      |> Keyword.put(:name, name)
      |> Keyword.put(:client_registry, context.client_registry)

    start_supervised({Coordinator, opts})
  end

  defp build_test_alert(overrides \\ %{}) do
    Alert.new(
      Map.merge(
        %{
          watcher: :integration_test,
          anomaly_type: "test_anomaly",
          severity: :warning,
          summary: "Test alert for integration testing",
          snapshots: []
        },
        overrides
      )
    )
  end

  defp inject_alert(pid, alert) do
    GenServer.cast(pid, {:alert_received, alert})
    alert
  end

  describe "coordinator lifecycle" do
    @tag timeout: 30_000
    test "starts and processes an injected alert", context do
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

      alert = build_test_alert()
      inject_alert(pid, alert)

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

      alert = build_test_alert()
      inject_alert(pid, alert)

      assert_receive {:telemetry, :llm_start, %{trace_id: trace_id}}, 15_000
      assert is_binary(trace_id)
    end

    @tag timeout: 60_000
    test "processes tool response and continues or stops", context do
      ref = make_ref()
      parent = self()

      events = [
        [:beamlens, :coordinator, :get_alerts],
        [:beamlens, :coordinator, :update_alert_statuses],
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

      alert = build_test_alert(%{summary: "Memory at 85% - elevated but not critical"})
      inject_alert(pid, alert)

      received_event =
        receive do
          {:telemetry, [:beamlens, :coordinator, :get_alerts], _} -> :get_alerts
          {:telemetry, [:beamlens, :coordinator, :update_alert_statuses], _} -> :update_statuses
          {:telemetry, [:beamlens, :coordinator, :insight_produced], _} -> :insight_produced
          {:telemetry, [:beamlens, :coordinator, :done], _} -> :done
          {:telemetry, [:beamlens, :coordinator, :llm_error], metadata} -> {:llm_error, metadata}
        after
          30_000 -> :timeout
        end

      case received_event do
        {:llm_error, metadata} ->
          flunk("LLM error occurred: #{inspect(metadata)}")

        :timeout ->
          flunk("Timeout waiting for tool action - no telemetry received")

        event when event in [:get_alerts, :update_statuses, :insight_produced, :done] ->
          assert true
      end
    end
  end

  describe "multi-alert processing" do
    @tag timeout: 90_000
    test "handles multiple related alerts", context do
      ref = make_ref()
      parent = self()

      events = [
        [:beamlens, :coordinator, :alert_received],
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

      alert1 =
        build_test_alert(%{
          watcher: :beam,
          anomaly_type: "memory_elevated",
          severity: :warning,
          summary: "Memory at 78% - elevated usage detected"
        })

      alert2 =
        build_test_alert(%{
          watcher: :beam,
          anomaly_type: "scheduler_contention",
          severity: :warning,
          summary: "Run queue at 45 - scheduler pressure detected"
        })

      inject_alert(pid, alert1)

      assert_receive {:telemetry, [:beamlens, :coordinator, :alert_received], %{alert_id: _}},
                     5_000

      inject_alert(pid, alert2)

      assert_receive {:telemetry, [:beamlens, :coordinator, :alert_received], %{alert_id: _}},
                     5_000

      assert_receive {:telemetry, [:beamlens, :coordinator, :iteration_start], %{iteration: _}},
                     10_000

      status = Coordinator.status(pid)
      assert status.alert_count == 2
    end
  end
end
