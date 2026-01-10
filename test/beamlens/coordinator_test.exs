defmodule Beamlens.CoordinatorTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Beamlens.Coordinator
  alias Beamlens.Coordinator.Insight
  alias Beamlens.Coordinator.Tools.{Done, GetAlerts, ProduceInsight, UpdateAlertStatuses}
  alias Beamlens.Watcher.Alert

  defp mock_client do
    Puck.Client.new({Puck.Backends.Mock, error: :test_stop})
  end

  defp start_coordinator(opts \\ []) do
    name = Keyword.get(opts, :name, :"coordinator_#{:erlang.unique_integer([:positive])}")
    opts = Keyword.put(opts, :name, name)
    {:ok, pid} = Coordinator.start_link(opts)

    :sys.replace_state(pid, fn state ->
      %{state | client: mock_client()}
    end)

    {:ok, pid}
  end

  defp stop_coordinator(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal)
    end
  end

  defp build_test_alert(overrides \\ %{}) do
    Alert.new(
      Map.merge(
        %{
          watcher: :test,
          anomaly_type: "test_anomaly",
          severity: :info,
          summary: "Test alert",
          snapshots: []
        },
        overrides
      )
    )
  end

  defp simulate_alert(pid, alert) do
    GenServer.cast(pid, {:alert_received, alert})
  end

  defp extract_content_text(content) when is_binary(content), do: content

  defp extract_content_text(content) when is_list(content) do
    Enum.map_join(content, "", fn
      %{text: text} -> text
      part when is_struct(part) -> Map.get(part, :text, "")
      _ -> ""
    end)
  end

  defp extract_content_text(_), do: ""

  describe "start_link/1" do
    test "starts with custom name" do
      {:ok, pid} = start_coordinator(name: :test_coordinator)

      assert Process.alive?(pid)

      stop_coordinator(pid)
    end

    test "starts with generated name" do
      {:ok, pid} = start_coordinator()

      assert Process.alive?(pid)

      stop_coordinator(pid)
    end

    test "stores client_registry in state" do
      client_registry = %{primary: "Test", clients: []}

      {:ok, pid} = start_coordinator(client_registry: client_registry)

      state = :sys.get_state(pid)
      assert state.client_registry == client_registry

      stop_coordinator(pid)
    end
  end

  describe "status/1" do
    test "returns current status" do
      {:ok, pid} = start_coordinator()

      status = Coordinator.status(pid)

      assert status.running == false
      assert status.alert_count == 0
      assert status.unread_count == 0
      assert status.iteration == 0

      stop_coordinator(pid)
    end

    test "reflects alert counts accurately" do
      {:ok, pid} = start_coordinator()

      alert1 = build_test_alert(%{anomaly_type: "type1"})
      alert2 = build_test_alert(%{anomaly_type: "type2"})

      :sys.replace_state(pid, fn state ->
        alerts = %{
          alert1.id => %{alert: alert1, status: :unread},
          alert2.id => %{alert: alert2, status: :acknowledged}
        }

        %{state | alerts: alerts}
      end)

      status = Coordinator.status(pid)

      assert status.alert_count == 2
      assert status.unread_count == 1

      stop_coordinator(pid)
    end
  end

  describe "initial state" do
    test "starts with empty alerts" do
      {:ok, pid} = start_coordinator()

      state = :sys.get_state(pid)
      assert state.alerts == %{}

      stop_coordinator(pid)
    end

    test "starts with running false" do
      {:ok, pid} = start_coordinator()

      state = :sys.get_state(pid)
      assert state.running == false

      stop_coordinator(pid)
    end

    test "starts with iteration zero" do
      {:ok, pid} = start_coordinator()

      state = :sys.get_state(pid)
      assert state.iteration == 0

      stop_coordinator(pid)
    end

    test "initializes with fresh context" do
      {:ok, pid} = start_coordinator()

      state = :sys.get_state(pid)
      assert %Puck.Context{} = state.context
      assert state.context.messages == []

      stop_coordinator(pid)
    end
  end

  describe "alert ingestion" do
    test "alert received creates entry with unread status" do
      {:ok, pid} = start_coordinator()

      alert = build_test_alert()

      :sys.replace_state(pid, fn state ->
        %{state | running: true}
      end)

      simulate_alert(pid, alert)

      state = :sys.get_state(pid)

      assert Map.has_key?(state.alerts, alert.id)
      assert state.alerts[alert.id].status == :unread
      assert state.alerts[alert.id].alert == alert

      stop_coordinator(pid)
    end

    test "multiple alerts can coexist" do
      {:ok, pid} = start_coordinator()

      :sys.replace_state(pid, fn state ->
        %{state | running: true}
      end)

      alert1 = build_test_alert(%{anomaly_type: "type1"})
      alert2 = build_test_alert(%{anomaly_type: "type2"})

      simulate_alert(pid, alert1)
      simulate_alert(pid, alert2)

      state = :sys.get_state(pid)

      assert map_size(state.alerts) == 2
      assert Map.has_key?(state.alerts, alert1.id)
      assert Map.has_key?(state.alerts, alert2.id)

      stop_coordinator(pid)
    end

    test "first alert triggers loop start via telemetry" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :iteration_start},
        [:beamlens, :coordinator, :iteration_start],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :iteration_start, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      alert = build_test_alert()
      simulate_alert(pid, alert)

      assert_receive {:telemetry, :iteration_start, %{iteration: 0}}, 1000

      stop_coordinator(pid)
      :telemetry.detach({ref, :iteration_start})
    end
  end

  describe "handle_action - GetAlerts" do
    test "increments iteration after processing" do
      {:ok, pid} = start_coordinator()

      alert1 = build_test_alert(%{anomaly_type: "type1"})
      alert2 = build_test_alert(%{anomaly_type: "type2"})

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        alerts = %{
          alert1.id => %{alert: alert1, status: :unread},
          alert2.id => %{alert: alert2, status: :acknowledged}
        }

        %{state | alerts: alerts, running: true, pending_task: task}
      end)

      send(pid, {task.ref, {:ok, %{content: %GetAlerts{status: nil}}, Puck.Context.new()}})

      state = :sys.get_state(pid)

      assert state.iteration == 1

      stop_coordinator(pid)
    end

    test "filters by unread status and adds result to context" do
      {:ok, pid} = start_coordinator()

      alert1 = build_test_alert(%{anomaly_type: "type1"})
      alert2 = build_test_alert(%{anomaly_type: "type2"})

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        alerts = %{
          alert1.id => %{alert: alert1, status: :unread},
          alert2.id => %{alert: alert2, status: :acknowledged}
        }

        %{state | alerts: alerts, running: true, pending_task: task}
      end)

      send(pid, {task.ref, {:ok, %{content: %GetAlerts{status: :unread}}, Puck.Context.new()}})

      state = :sys.get_state(pid)

      last_message = List.last(state.context.messages)
      content_text = extract_content_text(last_message.content)
      assert content_text =~ alert1.id
      refute content_text =~ alert2.id

      stop_coordinator(pid)
    end
  end

  describe "handle_action - UpdateAlertStatuses" do
    test "updates single alert status" do
      {:ok, pid} = start_coordinator()

      alert = build_test_alert()
      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        alerts = %{alert.id => %{alert: alert, status: :unread}}
        %{state | alerts: alerts, running: true, pending_task: task}
      end)

      action = %UpdateAlertStatuses{alert_ids: [alert.id], status: :acknowledged, reason: nil}
      send(pid, {task.ref, {:ok, %{content: action}, Puck.Context.new()}})

      state = :sys.get_state(pid)

      assert state.alerts[alert.id].status == :acknowledged

      stop_coordinator(pid)
    end

    test "updates multiple alerts" do
      {:ok, pid} = start_coordinator()

      alert1 = build_test_alert(%{anomaly_type: "type1"})
      alert2 = build_test_alert(%{anomaly_type: "type2"})
      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        alerts = %{
          alert1.id => %{alert: alert1, status: :unread},
          alert2.id => %{alert: alert2, status: :unread}
        }

        %{state | alerts: alerts, running: true, pending_task: task}
      end)

      action = %UpdateAlertStatuses{
        alert_ids: [alert1.id, alert2.id],
        status: :resolved,
        reason: "Test reason"
      }

      send(pid, {task.ref, {:ok, %{content: action}, Puck.Context.new()}})

      state = :sys.get_state(pid)

      assert state.alerts[alert1.id].status == :resolved
      assert state.alerts[alert2.id].status == :resolved

      stop_coordinator(pid)
    end

    test "ignores non-existent alert IDs" do
      {:ok, pid} = start_coordinator()

      alert = build_test_alert()
      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        alerts = %{alert.id => %{alert: alert, status: :unread}}
        %{state | alerts: alerts, running: true, pending_task: task}
      end)

      action = %UpdateAlertStatuses{
        alert_ids: [alert.id, "nonexistent_id"],
        status: :acknowledged,
        reason: nil
      }

      send(pid, {task.ref, {:ok, %{content: action}, Puck.Context.new()}})

      state = :sys.get_state(pid)

      assert state.alerts[alert.id].status == :acknowledged
      refute Map.has_key?(state.alerts, "nonexistent_id")

      stop_coordinator(pid)
    end
  end

  describe "handle_action - ProduceInsight" do
    test "auto-resolves referenced alerts" do
      {:ok, pid} = start_coordinator()

      alert1 = build_test_alert(%{anomaly_type: "type1"})
      alert2 = build_test_alert(%{anomaly_type: "type2"})
      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        alerts = %{
          alert1.id => %{alert: alert1, status: :acknowledged},
          alert2.id => %{alert: alert2, status: :acknowledged}
        }

        %{state | alerts: alerts, running: true, pending_task: task}
      end)

      action = %ProduceInsight{
        alert_ids: [alert1.id, alert2.id],
        correlation_type: :causal,
        summary: "Test correlation",
        root_cause_hypothesis: nil,
        confidence: :high
      }

      send(pid, {task.ref, {:ok, %{content: action}, Puck.Context.new()}})

      state = :sys.get_state(pid)

      assert state.alerts[alert1.id].status == :resolved
      assert state.alerts[alert2.id].status == :resolved

      stop_coordinator(pid)
    end

    test "adds insight_produced to context" do
      {:ok, pid} = start_coordinator()

      alert = build_test_alert()
      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        alerts = %{alert.id => %{alert: alert, status: :acknowledged}}
        %{state | alerts: alerts, running: true, pending_task: task}
      end)

      action = %ProduceInsight{
        alert_ids: [alert.id],
        correlation_type: :temporal,
        summary: "Test insight",
        root_cause_hypothesis: "Test hypothesis",
        confidence: :medium
      }

      send(pid, {task.ref, {:ok, %{content: action}, Puck.Context.new()}})

      state = :sys.get_state(pid)

      last_message = List.last(state.context.messages)
      content_text = extract_content_text(last_message.content)
      assert content_text =~ "insight_produced"

      stop_coordinator(pid)
    end
  end

  describe "handle_action - Done" do
    test "stops loop when no unread alerts" do
      {:ok, pid} = start_coordinator()

      alert = build_test_alert()
      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        alerts = %{alert.id => %{alert: alert, status: :resolved}}
        %{state | alerts: alerts, running: true, pending_task: task}
      end)

      send(pid, {task.ref, {:ok, %{content: %Done{}}, Puck.Context.new()}})

      state = :sys.get_state(pid)

      assert state.running == false

      stop_coordinator(pid)
    end

    test "resets iteration when unread alerts exist" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :done},
        [:beamlens, :coordinator, :done],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :done, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      alert = build_test_alert()
      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        alerts = %{alert.id => %{alert: alert, status: :unread}}
        %{state | alerts: alerts, running: true, pending_task: task, iteration: 5}
      end)

      send(pid, {task.ref, {:ok, %{content: %Done{}}, Puck.Context.new()}})

      assert_receive {:telemetry, :done, %{has_unread: true}}, 1000

      stop_coordinator(pid)
      :telemetry.detach({ref, :done})
    end
  end

  describe "max iterations" do
    test "stops loop when max iterations reached" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :loop_stopped},
        [:beamlens, :coordinator, :loop_stopped],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :loop_stopped, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      alert = build_test_alert()
      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        alerts = %{alert.id => %{alert: alert, status: :unread}}
        %{state | alerts: alerts, iteration: 19, running: true, pending_task: task}
      end)

      action = %GetAlerts{status: nil}
      send(pid, {task.ref, {:ok, %{content: action}, Puck.Context.new()}})

      assert_receive {:telemetry, :loop_stopped, %{reason: :max_iterations}}, 1000

      state = :sys.get_state(pid)
      assert state.running == false

      stop_coordinator(pid)
      :telemetry.detach({ref, :loop_stopped})
    end
  end

  describe "error handling" do
    test "LLM error stops loop" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :llm_error},
        [:beamlens, :coordinator, :llm_error],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :llm_error, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        %{state | running: true, pending_task: task, pending_trace_id: "test-trace"}
      end)

      send(pid, {task.ref, {:error, :test_error}})

      assert_receive {:telemetry, :llm_error, %{reason: :test_error}}, 1000

      state = :sys.get_state(pid)
      assert state.running == false

      stop_coordinator(pid)
      :telemetry.detach({ref, :llm_error})
    end

    test "task crash handled gracefully" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :llm_error},
        [:beamlens, :coordinator, :llm_error],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :llm_error, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        %{state | running: true, pending_task: task, pending_trace_id: "test-trace"}
      end)

      send(pid, {:DOWN, task.ref, :process, task.pid, :killed})

      assert_receive {:telemetry, :llm_error, %{reason: {:task_crashed, :killed}}}, 1000

      state = :sys.get_state(pid)
      assert state.running == false

      stop_coordinator(pid)
      :telemetry.detach({ref, :llm_error})
    end
  end

  describe "telemetry events" do
    test "emits started event on init" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :started},
        [:beamlens, :coordinator, :started],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :started, metadata})
        end,
        nil
      )

      {:ok, pid} =
        Coordinator.start_link(name: :"test_coord_#{:erlang.unique_integer([:positive])}")

      assert_receive {:telemetry, :started, %{running: false, alert_count: 0}}, 1000

      stop_coordinator(pid)
      :telemetry.detach({ref, :started})
    end

    test "emits alert_received event" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :alert_received},
        [:beamlens, :coordinator, :alert_received],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :alert_received, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      :sys.replace_state(pid, fn state ->
        %{state | running: true}
      end)

      alert = build_test_alert()
      simulate_alert(pid, alert)

      assert_receive {:telemetry, :alert_received, %{alert_id: _, watcher: :test}}, 1000

      stop_coordinator(pid)
      :telemetry.detach({ref, :alert_received})
    end

    test "emits iteration_start event when loop runs" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :iteration_start},
        [:beamlens, :coordinator, :iteration_start],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :iteration_start, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      alert = build_test_alert()
      simulate_alert(pid, alert)

      assert_receive {:telemetry, :iteration_start, %{iteration: 0, trace_id: _}}, 1000

      stop_coordinator(pid)
      :telemetry.detach({ref, :iteration_start})
    end

    test "emits insight_produced event" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :insight_produced},
        [:beamlens, :coordinator, :insight_produced],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :insight_produced, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      alert = build_test_alert()
      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        alerts = %{alert.id => %{alert: alert, status: :acknowledged}}

        %{
          state
          | alerts: alerts,
            running: true,
            pending_task: task,
            pending_trace_id: "test-trace"
        }
      end)

      action = %ProduceInsight{
        alert_ids: [alert.id],
        correlation_type: :temporal,
        summary: "Test insight",
        root_cause_hypothesis: nil,
        confidence: :low
      }

      send(pid, {task.ref, {:ok, %{content: action}, Puck.Context.new()}})

      assert_receive {:telemetry, :insight_produced, %{insight: %Insight{}}}, 1000

      stop_coordinator(pid)
      :telemetry.detach({ref, :insight_produced})
    end

    test "emits done event" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :done},
        [:beamlens, :coordinator, :done],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :done, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        %{state | running: true, pending_task: task, pending_trace_id: "test-trace"}
      end)

      send(pid, {task.ref, {:ok, %{content: %Done{}}, Puck.Context.new()}})

      assert_receive {:telemetry, :done, %{has_unread: false}}, 1000

      stop_coordinator(pid)
      :telemetry.detach({ref, :done})
    end
  end
end
