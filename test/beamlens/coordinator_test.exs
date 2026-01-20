defmodule Beamlens.CoordinatorTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Beamlens.Coordinator
  alias Beamlens.Coordinator.Insight
  alias Beamlens.Operator.Notification

  defp mock_client do
    Puck.Client.new({Puck.Backends.Mock, error: :test_stop})
  end

  defp blocking_client do
    Puck.Client.new({__MODULE__.BlockingBackend, %{}})
  end

  defmodule BlockingBackend do
    @behaviour Puck.Backend

    def call(_config, _messages, _opts) do
      receive do
        :unblock -> {:error, :blocked}
      end
    end

    def stream(_config, _messages, _opts) do
      receive do
        :unblock -> {:error, :blocked}
      end
    end

    def introspect(_config) do
      %{
        provider: "mock",
        model: "blocking",
        operation: :chat,
        capabilities: []
      }
    end
  end

  defp start_coordinator(opts \\ []) do
    Process.flag(:trap_exit, true)
    name = Keyword.get(opts, :name, :"coordinator_#{:erlang.unique_integer([:positive])}")

    opts = Keyword.put(opts, :name, name)

    {:ok, pid} = Coordinator.start_link(opts)

    :sys.replace_state(pid, fn state ->
      %{state | client: mock_client()}
    end)

    {:ok, pid}
  end

  defp stop_coordinator(pid) do
    if Process.alive?(pid), do: do_stop_coordinator(pid)
  end

  defp do_stop_coordinator(pid) do
    :sys.replace_state(pid, fn state ->
      %{state | pending_task: nil}
    end)

    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  defp build_test_notification(overrides \\ %{}) do
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

  defp simulate_notification(coordinator_pid, notification) do
    # Simulate an operator sending a notification by:
    # 1. Adding a fake operator entry to running_operators
    # 2. Sending the notification as if from that operator
    fake_operator_pid = self()

    :sys.replace_state(coordinator_pid, fn state ->
      %{
        state
        | running_operators:
            Map.put(state.running_operators, fake_operator_pid, %{
              skill: :test,
              ref: make_ref(),
              started_at: DateTime.utc_now()
            })
      }
    end)

    send(coordinator_pid, {:operator_notification, fake_operator_pid, notification})
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

  describe "run/2 without started coordinator" do
    test "raises ArgumentError when coordinator not started" do
      assert_raise ArgumentError, ~r/Coordinator not started/, fn ->
        Coordinator.run(%{reason: "test"}, [])
      end
    end
  end

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
      assert status.notification_count == 0
      assert status.unread_count == 0
      assert status.iteration == 0

      stop_coordinator(pid)
    end

    test "reflects notification counts accurately" do
      {:ok, pid} = start_coordinator()

      notification1 = build_test_notification(%{anomaly_type: "type1"})
      notification2 = build_test_notification(%{anomaly_type: "type2"})

      :sys.replace_state(pid, fn state ->
        notifications = %{
          notification1.id => %{notification: notification1, status: :unread},
          notification2.id => %{notification: notification2, status: :acknowledged}
        }

        %{state | notifications: notifications}
      end)

      status = Coordinator.status(pid)

      assert status.notification_count == 2
      assert status.unread_count == 1

      stop_coordinator(pid)
    end
  end

  describe "initial state" do
    test "starts with empty notifications" do
      {:ok, pid} = start_coordinator()

      state = :sys.get_state(pid)
      assert state.notifications == %{}

      stop_coordinator(pid)
    end

    test "starts with running false" do
      {:ok, pid} = start_coordinator()

      state = :sys.get_state(pid)
      assert state.status == :idle

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

  describe "notification ingestion" do
    test "notification received creates entry with unread status" do
      {:ok, pid} = start_coordinator()

      notification = build_test_notification()

      :sys.replace_state(pid, fn state ->
        %{state | status: :running}
      end)

      simulate_notification(pid, notification)

      state = :sys.get_state(pid)

      assert Map.has_key?(state.notifications, notification.id)
      assert state.notifications[notification.id].status == :unread
      assert state.notifications[notification.id].notification == notification

      stop_coordinator(pid)
    end

    test "multiple notifications can coexist" do
      {:ok, pid} = start_coordinator()

      :sys.replace_state(pid, fn state ->
        %{state | status: :running}
      end)

      notification1 = build_test_notification(%{anomaly_type: "type1"})
      notification2 = build_test_notification(%{anomaly_type: "type2"})

      simulate_notification(pid, notification1)
      simulate_notification(pid, notification2)

      state = :sys.get_state(pid)

      assert map_size(state.notifications) == 2
      assert Map.has_key?(state.notifications, notification1.id)
      assert Map.has_key?(state.notifications, notification2.id)

      stop_coordinator(pid)
    end

    test "first notification triggers loop start" do
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

      notification = build_test_notification()
      simulate_notification(pid, notification)

      assert_receive {:telemetry, :iteration_start, %{iteration: 0}}, 1000

      stop_coordinator(pid)
      :telemetry.detach({ref, :iteration_start})
    end
  end

  describe "handle_action - GetNotifications" do
    test "increments iteration after processing" do
      {:ok, pid} = start_coordinator()

      notification1 = build_test_notification(%{anomaly_type: "type1"})
      notification2 = build_test_notification(%{anomaly_type: "type2"})

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        notifications = %{
          notification1.id => %{notification: notification1, status: :unread},
          notification2.id => %{notification: notification2, status: :acknowledged}
        }

        %{state | notifications: notifications, status: :running, pending_task: task}
      end)

      action_map = %{intent: "get_notifications"}
      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      state = :sys.get_state(pid)

      assert state.iteration == 1

      stop_coordinator(pid)
    end

    test "filters by unread status and adds result to context" do
      {:ok, pid} = start_coordinator()

      notification1 = build_test_notification(%{anomaly_type: "type1"})
      notification2 = build_test_notification(%{anomaly_type: "type2"})

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        notifications = %{
          notification1.id => %{notification: notification1, status: :unread},
          notification2.id => %{notification: notification2, status: :acknowledged}
        }

        %{state | notifications: notifications, status: :running, pending_task: task}
      end)

      action_map = %{intent: "get_notifications", status: "unread"}
      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      state = :sys.get_state(pid)

      last_message = List.last(state.context.messages)
      content_text = extract_content_text(last_message.content)
      assert content_text =~ notification1.id
      refute content_text =~ notification2.id

      stop_coordinator(pid)
    end
  end

  describe "handle_action - UpdateNotificationStatuses" do
    test "updates single notification status" do
      {:ok, pid} = start_coordinator()

      notification = build_test_notification()
      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        notifications = %{notification.id => %{notification: notification, status: :unread}}
        %{state | notifications: notifications, status: :running, pending_task: task}
      end)

      action_map = %{
        intent: "update_notification_statuses",
        notification_ids: [notification.id],
        status: "acknowledged"
      }

      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      state = :sys.get_state(pid)

      assert state.notifications[notification.id].status == :acknowledged

      stop_coordinator(pid)
    end

    test "updates multiple notifications" do
      {:ok, pid} = start_coordinator()

      notification1 = build_test_notification(%{anomaly_type: "type1"})
      notification2 = build_test_notification(%{anomaly_type: "type2"})
      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        notifications = %{
          notification1.id => %{notification: notification1, status: :unread},
          notification2.id => %{notification: notification2, status: :unread}
        }

        %{state | notifications: notifications, status: :running, pending_task: task}
      end)

      action_map = %{
        intent: "update_notification_statuses",
        notification_ids: [notification1.id, notification2.id],
        status: "resolved",
        reason: "Test reason"
      }

      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      state = :sys.get_state(pid)

      assert state.notifications[notification1.id].status == :resolved
      assert state.notifications[notification2.id].status == :resolved

      stop_coordinator(pid)
    end

    test "ignores non-existent notification IDs" do
      {:ok, pid} = start_coordinator()

      notification = build_test_notification()
      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        notifications = %{notification.id => %{notification: notification, status: :unread}}
        %{state | notifications: notifications, status: :running, pending_task: task}
      end)

      action_map = %{
        intent: "update_notification_statuses",
        notification_ids: [notification.id, "nonexistent_id"],
        status: "acknowledged"
      }

      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      state = :sys.get_state(pid)

      assert state.notifications[notification.id].status == :acknowledged
      refute Map.has_key?(state.notifications, "nonexistent_id")

      stop_coordinator(pid)
    end
  end

  describe "handle_action - ProduceInsight" do
    test "auto-resolves referenced notifications" do
      {:ok, pid} = start_coordinator()

      notification1 = build_test_notification(%{anomaly_type: "type1"})
      notification2 = build_test_notification(%{anomaly_type: "type2"})
      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        notifications = %{
          notification1.id => %{notification: notification1, status: :acknowledged},
          notification2.id => %{notification: notification2, status: :acknowledged}
        }

        %{state | notifications: notifications, status: :running, pending_task: task}
      end)

      action_map = %{
        intent: "produce_insight",
        notification_ids: [notification1.id, notification2.id],
        correlation_type: "causal",
        summary: "Test correlation",
        confidence: "high"
      }

      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      state = :sys.get_state(pid)

      assert state.notifications[notification1.id].status == :resolved
      assert state.notifications[notification2.id].status == :resolved

      stop_coordinator(pid)
    end

    test "adds insight_produced to context" do
      {:ok, pid} = start_coordinator()

      notification = build_test_notification()
      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        notifications = %{notification.id => %{notification: notification, status: :acknowledged}}
        %{state | notifications: notifications, status: :running, pending_task: task}
      end)

      action_map = %{
        intent: "produce_insight",
        notification_ids: [notification.id],
        correlation_type: "temporal",
        summary: "Test insight",
        root_cause_hypothesis: "Test hypothesis",
        confidence: "medium"
      }

      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      state = :sys.get_state(pid)

      last_message = List.last(state.context.messages)
      content_text = extract_content_text(last_message.content)
      assert content_text =~ "insight_produced"

      stop_coordinator(pid)
    end
  end

  describe "handle_action - Done" do
    test "stops loop when no unread notifications" do
      {:ok, pid} = start_coordinator()

      notification = build_test_notification()
      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        notifications = %{notification.id => %{notification: notification, status: :resolved}}
        %{state | notifications: notifications, status: :running, pending_task: task}
      end)

      action_map = %{intent: "done"}
      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      state = :sys.get_state(pid)

      assert state.status == :idle

      stop_coordinator(pid)
    end

    test "rejects done when unread notifications exist" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :done_rejected},
        [:beamlens, :coordinator, :done_rejected],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :done_rejected, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      notification = build_test_notification()
      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        notifications = %{notification.id => %{notification: notification, status: :unread}}

        %{
          state
          | notifications: notifications,
            status: :running,
            pending_task: task,
            iteration: 5,
            client: blocking_client()
        }
      end)

      action_map = %{intent: "done"}
      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      assert_receive {:telemetry, :done_rejected, %{unread_count: 1}}, 1000

      state = :sys.get_state(pid)
      assert state.status == :running
      assert state.iteration == 6

      stop_coordinator(pid)
      :telemetry.detach({ref, :done_rejected})
    end

    test "rejects done when operators are still running" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :done_rejected},
        [:beamlens, :coordinator, :done_rejected],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :done_rejected, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      task = Task.async(fn -> :ok end)
      Task.await(task)

      fake_operator_pid = spawn(fn -> :timer.sleep(:infinity) end)
      fake_ref = make_ref()

      :sys.replace_state(pid, fn state ->
        running_operators = %{
          fake_operator_pid => %{
            skill: Beamlens.Skill.Beam,
            ref: fake_ref,
            started_at: DateTime.utc_now()
          }
        }

        %{
          state
          | running_operators: running_operators,
            status: :running,
            pending_task: task,
            iteration: 5,
            client: blocking_client()
        }
      end)

      action_map = %{intent: "done"}
      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      assert_receive {:telemetry, :done_rejected, %{running_operator_count: 1}}, 1000

      state = :sys.get_state(pid)
      assert state.status == :running
      assert state.iteration == 6

      Process.exit(fake_operator_pid, :kill)
      stop_coordinator(pid)
      :telemetry.detach({ref, :done_rejected})
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
        %{state | status: :running, pending_task: task, pending_trace_id: "test-trace"}
      end)

      send(pid, {task.ref, {:error, :test_error}})

      assert_receive {:telemetry, :llm_error, %{reason: :test_error}}, 1000

      state = :sys.get_state(pid)
      assert state.status == :idle

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
        %{state | status: :running, pending_task: task, pending_trace_id: "test-trace"}
      end)

      send(pid, {:DOWN, task.ref, :process, task.pid, :killed})

      assert_receive {:telemetry, :llm_error, %{reason: {:task_crashed, :killed}}}, 1000

      state = :sys.get_state(pid)
      assert state.status == :idle

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

      assert_receive {:telemetry, :started, %{running: false, notification_count: 0}}, 1000

      stop_coordinator(pid)
      :telemetry.detach({ref, :started})
    end

    test "emits operator_notification_received event" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :operator_notification_received},
        [:beamlens, :coordinator, :operator_notification_received],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :operator_notification_received, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      :sys.replace_state(pid, fn state ->
        %{state | status: :running}
      end)

      notification = build_test_notification()
      simulate_notification(pid, notification)

      assert_receive {:telemetry, :operator_notification_received,
                      %{notification_id: _, operator_pid: _}},
                     1000

      stop_coordinator(pid)
      :telemetry.detach({ref, :operator_notification_received})
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

      notification = build_test_notification()
      simulate_notification(pid, notification)

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

      notification = build_test_notification()
      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        notifications = %{notification.id => %{notification: notification, status: :acknowledged}}

        %{
          state
          | notifications: notifications,
            status: :running,
            pending_task: task,
            pending_trace_id: "test-trace"
        }
      end)

      action_map = %{
        intent: "produce_insight",
        notification_ids: [notification.id],
        correlation_type: "temporal",
        summary: "Test insight",
        confidence: "low"
      }

      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

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
        %{state | status: :running, pending_task: task, pending_trace_id: "test-trace"}
      end)

      action_map = %{intent: "done"}
      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      assert_receive {:telemetry, :done, %{has_unread: false}}, 1000

      stop_coordinator(pid)
      :telemetry.detach({ref, :done})
    end
  end

  describe "compaction configuration" do
    defp start_coordinator_for_compaction_test(opts \\ []) do
      name =
        Keyword.get(opts, :name, :"coordinator_compaction_#{:erlang.unique_integer([:positive])}")

      opts = Keyword.put(opts, :name, name)
      Coordinator.start_link(opts)
    end

    test "uses default compaction settings when not specified" do
      {:ok, pid} = start_coordinator_for_compaction_test()

      state = :sys.get_state(pid)
      client = state.client

      assert client.auto_compaction != nil
      {:summarize, config} = client.auto_compaction
      assert Keyword.get(config, :max_tokens) == 50_000
      assert Keyword.get(config, :keep_last) == 5
      assert is_binary(Keyword.get(config, :prompt))

      stop_coordinator(pid)
    end

    test "uses custom compaction_max_tokens when provided" do
      {:ok, pid} = start_coordinator_for_compaction_test(compaction_max_tokens: 100_000)

      state = :sys.get_state(pid)
      {:summarize, config} = state.client.auto_compaction
      assert Keyword.get(config, :max_tokens) == 100_000

      stop_coordinator(pid)
    end

    test "uses custom compaction_keep_last when provided" do
      {:ok, pid} = start_coordinator_for_compaction_test(compaction_keep_last: 10)

      state = :sys.get_state(pid)
      {:summarize, config} = state.client.auto_compaction
      assert Keyword.get(config, :keep_last) == 10

      stop_coordinator(pid)
    end

    test "uses both custom compaction settings when provided" do
      {:ok, pid} =
        start_coordinator_for_compaction_test(
          compaction_max_tokens: 75_000,
          compaction_keep_last: 8
        )

      state = :sys.get_state(pid)
      {:summarize, config} = state.client.auto_compaction

      assert Keyword.get(config, :max_tokens) == 75_000
      assert Keyword.get(config, :keep_last) == 8

      stop_coordinator(pid)
    end

    test "compaction prompt mentions notification analysis context" do
      {:ok, pid} = start_coordinator_for_compaction_test()

      state = :sys.get_state(pid)
      {:summarize, config} = state.client.auto_compaction
      prompt = Keyword.get(config, :prompt)

      assert prompt =~ "Notification IDs"
      assert prompt =~ "correlation"
      assert prompt =~ "Insights"

      stop_coordinator(pid)
    end
  end

  describe "handle_action - InvokeOperators" do
    setup do
      start_supervised!({Registry, keys: :unique, name: Beamlens.OperatorRegistry})

      :persistent_term.put(
        {Beamlens.Supervisor, :skills},
        [Beamlens.Skill.Beam, Beamlens.Skill.Ets, Beamlens.Skill.Gc]
      )

      on_exit(fn ->
        :persistent_term.erase({Beamlens.Supervisor, :skills})
      end)
    end

    test "emits invoke_operators telemetry event" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :invoke_operators},
        [:beamlens, :coordinator, :invoke_operators],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :invoke_operators, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        %{state | status: :running, pending_task: task, pending_trace_id: "test-trace"}
      end)

      action_map = %{
        intent: "invoke_operators",
        skills: ["Beamlens.Skill.Beam"],
        context: "test analysis"
      }

      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      assert_receive {:telemetry, :invoke_operators, %{skills: ["Beamlens.Skill.Beam"]}}, 1000

      stop_coordinator(pid)
      :telemetry.detach({ref, :invoke_operators})
    end

    test "adds result to context with started skills count" do
      {:ok, pid} = start_coordinator()

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        %{state | status: :running, pending_task: task, pending_trace_id: "test-trace"}
      end)

      action_map = %{intent: "invoke_operators", skills: ["Beamlens.Skill.Beam"]}
      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      state = :sys.get_state(pid)
      last_message = List.last(state.context.messages)
      content_text = extract_content_text(last_message.content)

      assert content_text =~ "started"
      assert content_text =~ "count"

      stop_coordinator(pid)
    end

    test "increments iteration after processing" do
      {:ok, pid} = start_coordinator()

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :running,
            pending_task: task,
            pending_trace_id: "test-trace",
            iteration: 0
        }
      end)

      action_map = %{intent: "invoke_operators", skills: ["Beamlens.Skill.Beam"]}
      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      state = :sys.get_state(pid)
      assert state.iteration == 1

      stop_coordinator(pid)
    end

    test "handles unknown skill gracefully" do
      skill_atom =
        try do
          String.to_existing_atom("nonexistent_skill_xyz123")
        rescue
          ArgumentError -> nil
        end

      assert skill_atom == nil
    end
  end

  describe "handle_action - MessageOperator" do
    test "returns error when operator not running" do
      {:ok, pid} = start_coordinator()

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        %{state | status: :running, pending_task: task, pending_trace_id: "test-trace"}
      end)

      action_map = %{
        intent: "message_operator",
        skill: "Beamlens.Skill.Beam",
        message: "test message"
      }

      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      state = :sys.get_state(pid)
      last_message = List.last(state.context.messages)
      content_text = extract_content_text(last_message.content)

      assert content_text =~ "error"
      assert content_text =~ "not running"

      stop_coordinator(pid)
    end

    test "emits message_operator telemetry event" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :message_operator},
        [:beamlens, :coordinator, :message_operator],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :message_operator, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        %{state | status: :running, pending_task: task, pending_trace_id: "test-trace"}
      end)

      action_map = %{
        intent: "message_operator",
        skill: "Beamlens.Skill.Beam",
        message: "test message"
      }

      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      assert_receive {:telemetry, :message_operator, %{skill: "Beamlens.Skill.Beam"}}, 1000

      stop_coordinator(pid)
      :telemetry.detach({ref, :message_operator})
    end

    test "increments iteration after processing" do
      {:ok, pid} = start_coordinator()

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :running,
            pending_task: task,
            pending_trace_id: "test-trace",
            iteration: 0
        }
      end)

      action_map = %{
        intent: "message_operator",
        skill: "Beamlens.Skill.Beam",
        message: "test message"
      }

      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      state = :sys.get_state(pid)
      assert state.iteration == 1

      stop_coordinator(pid)
    end

    test "handles invalid skill name without crashing" do
      {:ok, pid} = start_coordinator()

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        %{state | status: :running, pending_task: task, pending_trace_id: "test-trace"}
      end)

      action_map = %{
        intent: "message_operator",
        skill: "nonexistent_skill_12345",
        message: "test"
      }

      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      state = :sys.get_state(pid)
      last_message = List.last(state.context.messages)
      content_text = extract_content_text(last_message.content)

      assert content_text =~ "error"
      assert content_text =~ "not running"
      assert Process.alive?(pid)

      stop_coordinator(pid)
    end

    test "resolves valid skill module string" do
      {:ok, pid} = start_coordinator()

      task = Task.async(fn -> :ok end)
      Task.await(task)

      test_pid = self()

      fake_operator_pid =
        spawn(fn ->
          receive do
            {:"$gen_call", from, {:message, _msg}} ->
              GenServer.reply(from, {:ok, %{response: "fake response"}})
              send(test_pid, :operator_received_message)
          end
        end)

      :sys.replace_state(pid, fn state ->
        running_operators =
          Map.put(state.running_operators, fake_operator_pid, %{
            skill: Beamlens.Skill.Beam,
            ref: make_ref(),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | status: :running,
            pending_task: task,
            pending_trace_id: "test-trace",
            running_operators: running_operators
        }
      end)

      action_map = %{
        intent: "message_operator",
        skill: "Beamlens.Skill.Beam",
        message: "status check"
      }

      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      assert_receive :operator_received_message, 1000

      state = :sys.get_state(pid)
      last_message = List.last(state.context.messages)
      content_text = extract_content_text(last_message.content)

      refute content_text =~ "not running"
      assert Process.alive?(pid)

      stop_coordinator(pid)
    end
  end

  describe "handle_action - GetOperatorStatuses" do
    test "returns empty list when no operators running" do
      {:ok, pid} = start_coordinator()

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        %{state | status: :running, pending_task: task, pending_trace_id: "test-trace"}
      end)

      action_map = %{intent: "get_operator_statuses"}
      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      state = :sys.get_state(pid)
      last_message = List.last(state.context.messages)
      content_text = extract_content_text(last_message.content)

      assert content_text =~ "[]"

      stop_coordinator(pid)
    end

    test "handles dead operator PIDs gracefully" do
      {:ok, pid} = start_coordinator()

      dead_pid = spawn(fn -> :ok end)

      :sys.replace_state(pid, fn state ->
        running_operators =
          Map.put(state.running_operators, dead_pid, %{
            skill: Beamlens.Skill.Beam,
            ref: make_ref(),
            started_at: DateTime.utc_now()
          })

        %{state | running_operators: running_operators}
      end)

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        %{state | status: :running, pending_task: task, pending_trace_id: "test-trace"}
      end)

      action_map = %{intent: "get_operator_statuses"}
      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      state = :sys.get_state(pid)
      last_message = List.last(state.context.messages)
      content_text = extract_content_text(last_message.content)

      assert content_text =~ "alive"
      assert content_text =~ "false"

      stop_coordinator(pid)
    end

    test "emits get_operator_statuses telemetry event" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :get_operator_statuses},
        [:beamlens, :coordinator, :get_operator_statuses],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :get_operator_statuses, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        %{state | status: :running, pending_task: task, pending_trace_id: "test-trace"}
      end)

      action_map = %{intent: "get_operator_statuses"}
      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      assert_receive {:telemetry, :get_operator_statuses, %{trace_id: "test-trace"}}, 1000

      stop_coordinator(pid)
      :telemetry.detach({ref, :get_operator_statuses})
    end

    test "increments iteration after processing" do
      {:ok, pid} = start_coordinator()

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :running,
            pending_task: task,
            pending_trace_id: "test-trace",
            iteration: 0
        }
      end)

      action_map = %{intent: "get_operator_statuses"}
      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      state = :sys.get_state(pid)
      assert state.iteration == 1

      stop_coordinator(pid)
    end
  end

  describe "handle_action - Wait" do
    test "schedules continue_after_wait message" do
      {:ok, pid} = start_coordinator()

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        %{state | status: :running, pending_task: task, pending_trace_id: "test-trace"}
      end)

      action_map = %{intent: "wait", ms: 50}
      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      state = :sys.get_state(pid)
      last_message = List.last(state.context.messages)
      content_text = extract_content_text(last_message.content)

      assert content_text =~ "waited"
      assert content_text =~ "50"

      stop_coordinator(pid)
    end

    test "emits wait telemetry event" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :wait},
        [:beamlens, :coordinator, :wait],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :wait, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        %{state | status: :running, pending_task: task, pending_trace_id: "test-trace"}
      end)

      action_map = %{intent: "wait", ms: 100}
      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      assert_receive {:telemetry, :wait, %{ms: 100}}, 1000

      stop_coordinator(pid)
      :telemetry.detach({ref, :wait})
    end

    test "increments iteration after processing" do
      {:ok, pid} = start_coordinator()

      task = Task.async(fn -> :ok end)
      Task.await(task)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :running,
            pending_task: task,
            pending_trace_id: "test-trace",
            iteration: 0
        }
      end)

      action_map = %{intent: "wait", ms: 10}
      send(pid, {task.ref, {:ok, %{content: action_map}, Puck.Context.new()}})

      state = :sys.get_state(pid)
      assert state.iteration == 1

      stop_coordinator(pid)
    end
  end

  describe "operator crash handling" do
    test "coordinator handles DOWN and removes operator from running_operators" do
      {:ok, pid} = start_coordinator()

      operator_pid = spawn(fn -> :ok end)
      operator_ref = make_ref()

      :sys.replace_state(pid, fn state ->
        running_operators =
          Map.put(state.running_operators, operator_pid, %{
            skill: Beamlens.Skill.Beam,
            ref: operator_ref,
            started_at: DateTime.utc_now()
          })

        %{state | running_operators: running_operators}
      end)

      send(pid, {:DOWN, operator_ref, :process, operator_pid, :killed})

      state = :sys.get_state(pid)
      assert map_size(state.running_operators) == 0

      stop_coordinator(pid)
    end

    test "coordinator handles EXIT and removes operator from running_operators" do
      {:ok, pid} = start_coordinator()

      operator_pid = spawn(fn -> :ok end)
      operator_ref = make_ref()

      :sys.replace_state(pid, fn state ->
        running_operators =
          Map.put(state.running_operators, operator_pid, %{
            skill: Beamlens.Skill.Beam,
            ref: operator_ref,
            started_at: DateTime.utc_now()
          })

        %{state | running_operators: running_operators}
      end)

      send(pid, {:EXIT, operator_pid, :killed})

      state = :sys.get_state(pid)
      assert map_size(state.running_operators) == 0

      stop_coordinator(pid)
    end

    test "coordinator emits operator_crashed telemetry on DOWN" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :operator_crashed},
        [:beamlens, :coordinator, :operator_crashed],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :operator_crashed, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      operator_pid = spawn(fn -> :ok end)
      operator_ref = make_ref()

      :sys.replace_state(pid, fn state ->
        running_operators =
          Map.put(state.running_operators, operator_pid, %{
            skill: Beamlens.Skill.Beam,
            ref: operator_ref,
            started_at: DateTime.utc_now()
          })

        %{state | running_operators: running_operators}
      end)

      send(pid, {:DOWN, operator_ref, :process, operator_pid, :killed})

      assert_receive {:telemetry, :operator_crashed,
                      %{skill: Beamlens.Skill.Beam, reason: :killed}},
                     1000

      stop_coordinator(pid)
      :telemetry.detach({ref, :operator_crashed})
    end

    test "coordinator emits operator_crashed telemetry on EXIT" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :operator_crashed},
        [:beamlens, :coordinator, :operator_crashed],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :operator_crashed, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      operator_pid = spawn(fn -> :ok end)
      operator_ref = make_ref()

      :sys.replace_state(pid, fn state ->
        running_operators =
          Map.put(state.running_operators, operator_pid, %{
            skill: Beamlens.Skill.Beam,
            ref: operator_ref,
            started_at: DateTime.utc_now()
          })

        %{state | running_operators: running_operators}
      end)

      send(pid, {:EXIT, operator_pid, :boom})

      assert_receive {:telemetry, :operator_crashed,
                      %{skill: Beamlens.Skill.Beam, reason: :boom}},
                     1000

      stop_coordinator(pid)
      :telemetry.detach({ref, :operator_crashed})
    end

    test "coordinator continues running after operator crash" do
      {:ok, pid} = start_coordinator()

      operator_pid = spawn(fn -> :ok end)
      operator_ref = make_ref()

      :sys.replace_state(pid, fn state ->
        running_operators =
          Map.put(state.running_operators, operator_pid, %{
            skill: Beamlens.Skill.Beam,
            ref: operator_ref,
            started_at: DateTime.utc_now()
          })

        %{state | running_operators: running_operators, status: :running}
      end)

      send(pid, {:DOWN, operator_ref, :process, operator_pid, :killed})

      assert Process.alive?(pid)

      state = :sys.get_state(pid)
      assert state.status == :running

      stop_coordinator(pid)
    end

    test "multiple operator crashes handled independently" do
      {:ok, pid} = start_coordinator()

      operator_pid1 = spawn(fn -> :ok end)
      operator_ref1 = make_ref()
      operator_pid2 = spawn(fn -> :ok end)
      operator_ref2 = make_ref()

      :sys.replace_state(pid, fn state ->
        running_operators =
          state.running_operators
          |> Map.put(operator_pid1, %{
            skill: Beamlens.Skill.Beam,
            ref: operator_ref1,
            started_at: DateTime.utc_now()
          })
          |> Map.put(operator_pid2, %{
            skill: Beamlens.Skill.Ets,
            ref: operator_ref2,
            started_at: DateTime.utc_now()
          })

        %{state | running_operators: running_operators}
      end)

      send(pid, {:DOWN, operator_ref1, :process, operator_pid1, :killed})

      state = :sys.get_state(pid)
      assert map_size(state.running_operators) == 1
      assert Map.has_key?(state.running_operators, operator_pid2)

      send(pid, {:EXIT, operator_pid2, :boom})

      state = :sys.get_state(pid)
      assert map_size(state.running_operators) == 0

      stop_coordinator(pid)
    end

    test "ignores DOWN from unknown refs" do
      {:ok, pid} = start_coordinator()

      unknown_pid = spawn(fn -> :ok end)
      unknown_ref = make_ref()

      state_before = :sys.get_state(pid)

      send(pid, {:DOWN, unknown_ref, :process, unknown_pid, :killed})

      state_after = :sys.get_state(pid)
      assert state_before.running_operators == state_after.running_operators

      stop_coordinator(pid)
    end

    test "ignores EXIT from unknown pids" do
      {:ok, pid} = start_coordinator()

      unknown_pid = spawn(fn -> :ok end)

      state_before = :sys.get_state(pid)

      send(pid, {:EXIT, unknown_pid, :killed})

      state_after = :sys.get_state(pid)
      assert state_before.running_operators == state_after.running_operators

      stop_coordinator(pid)
    end
  end

  describe "coordinator crash cascades to operators" do
    test "linked operators die when coordinator dies" do
      Process.flag(:trap_exit, true)

      {:ok, coordinator_pid} = start_coordinator()

      operator_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :sys.replace_state(coordinator_pid, fn state ->
        Process.link(operator_pid)

        running_operators =
          Map.put(state.running_operators, operator_pid, %{
            skill: Beamlens.Skill.Beam,
            ref: Process.monitor(operator_pid),
            started_at: DateTime.utc_now()
          })

        %{state | running_operators: running_operators}
      end)

      ref = Process.monitor(operator_pid)

      Process.unlink(coordinator_pid)
      Process.exit(coordinator_pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^operator_pid, :killed}, 1000
    end
  end

  describe "operator notification flow" do
    test "ignores notifications from unknown operator PIDs" do
      {:ok, pid} = start_coordinator()

      unknown_pid = spawn(fn -> :ok end)
      notification = build_test_notification()

      state_before = :sys.get_state(pid)

      send(pid, {:operator_notification, unknown_pid, notification})

      state_after = :sys.get_state(pid)
      assert map_size(state_after.notifications) == map_size(state_before.notifications)

      stop_coordinator(pid)
    end
  end

  describe "run/1 and run/2 API variations" do
    test "run/1 with keyword list delegates to run/2" do
      opts = [context: %{reason: "test"}, timeout: 100]
      {context, remaining} = Keyword.pop(opts, :context, %{})

      assert context == %{reason: "test"}
      assert remaining == [timeout: 100]
    end

    test "run/1 with map context delegates to run/2 with empty opts" do
      context = %{reason: "test"}
      assert is_map(context)
    end

    test "run/2 extracts notifications from opts" do
      notification = build_test_notification()
      opts = [notifications: [notification], timeout: 100]
      {notifications, remaining} = Keyword.pop(opts, :notifications, [])

      assert notifications == [notification]
      assert remaining == [timeout: 100]
    end

    test "run/2 extracts skills from opts" do
      opts = [skills: [Beamlens.Skill.Beam, Beamlens.Skill.Ets], timeout: 100]
      {skills, remaining} = Keyword.pop(opts, :skills, nil)

      assert skills == [Beamlens.Skill.Beam, Beamlens.Skill.Ets]
      assert remaining == [timeout: 100]
    end

    test "run/2 extracts client_registry from opts" do
      client_registry = %{primary: "Test", clients: []}
      opts = [client_registry: client_registry, timeout: 100]
      {extracted, remaining} = Keyword.pop(opts, :client_registry, %{})

      assert extracted == client_registry
      assert remaining == [timeout: 100]
    end

    test "start_link accepts skills option" do
      {:ok, pid} = start_coordinator(skills: [Beamlens.Skill.Beam, Beamlens.Skill.Ets])

      assert Process.alive?(pid)

      stop_coordinator(pid)
    end

    test "start_link works without skills option" do
      {:ok, pid} = start_coordinator()

      assert Process.alive?(pid)

      stop_coordinator(pid)
    end
  end

  describe "puck_client override" do
    test "runs with provided client" do
      client =
        Puck.Test.mock_client(
          [%Beamlens.Coordinator.Tools.Done{intent: "done"}],
          default: %Beamlens.Coordinator.Tools.Done{intent: "done"}
        )

      {:ok, pid} =
        Coordinator.start_link(
          name: Beamlens.Coordinator,
          puck_client: client
        )

      assert {:ok, %{insights: [], operator_results: []}} =
               Coordinator.run(%{}, skills: [], timeout: 1_000)

      stop_coordinator(pid)
    end
  end

  describe "operator completion flow" do
    test "operator_complete message merges notifications" do
      {:ok, pid} = start_coordinator()

      operator_pid = spawn(fn -> :ok end)
      operator_ref = make_ref()

      :sys.replace_state(pid, fn state ->
        running_operators =
          Map.put(state.running_operators, operator_pid, %{
            skill: Beamlens.Skill.Beam,
            ref: operator_ref,
            started_at: DateTime.utc_now()
          })

        %{state | running_operators: running_operators}
      end)

      notification = build_test_notification()

      result = %{
        summary: "Test result",
        notifications: [notification]
      }

      send(pid, {:operator_complete, operator_pid, Beamlens.Skill.Beam, result})

      state = :sys.get_state(pid)
      assert Map.has_key?(state.notifications, notification.id)
      assert state.notifications[notification.id].status == :unread

      stop_coordinator(pid)
    end

    test "operator_complete adds result to operator_results" do
      {:ok, pid} = start_coordinator()

      operator_pid = spawn(fn -> :ok end)
      operator_ref = make_ref()

      :sys.replace_state(pid, fn state ->
        running_operators =
          Map.put(state.running_operators, operator_pid, %{
            skill: Beamlens.Skill.Beam,
            ref: operator_ref,
            started_at: DateTime.utc_now()
          })

        %{state | running_operators: running_operators}
      end)

      result = %{summary: "Test result", notifications: []}

      send(pid, {:operator_complete, operator_pid, Beamlens.Skill.Beam, result})

      state = :sys.get_state(pid)
      assert length(state.operator_results) == 1

      [operator_result] = state.operator_results
      assert operator_result.skill == Beamlens.Skill.Beam
      assert operator_result.summary == "Test result"

      stop_coordinator(pid)
    end

    test "operator removed from running_operators on completion" do
      {:ok, pid} = start_coordinator()

      operator_pid = spawn(fn -> :ok end)
      operator_ref = make_ref()

      :sys.replace_state(pid, fn state ->
        running_operators =
          Map.put(state.running_operators, operator_pid, %{
            skill: Beamlens.Skill.Beam,
            ref: operator_ref,
            started_at: DateTime.utc_now()
          })

        %{state | running_operators: running_operators}
      end)

      result = %{summary: "Test result", notifications: []}

      send(pid, {:operator_complete, operator_pid, Beamlens.Skill.Beam, result})

      state = :sys.get_state(pid)
      assert map_size(state.running_operators) == 0

      stop_coordinator(pid)
    end

    test "emits operator_complete telemetry" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :operator_complete},
        [:beamlens, :coordinator, :operator_complete],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :operator_complete, metadata})
        end,
        nil
      )

      {:ok, pid} = start_coordinator()

      operator_pid = spawn(fn -> :ok end)
      operator_ref = make_ref()

      :sys.replace_state(pid, fn state ->
        running_operators =
          Map.put(state.running_operators, operator_pid, %{
            skill: Beamlens.Skill.Beam,
            ref: operator_ref,
            started_at: DateTime.utc_now()
          })

        %{state | running_operators: running_operators}
      end)

      result = %{summary: "Test result", notifications: []}

      send(pid, {:operator_complete, operator_pid, Beamlens.Skill.Beam, result})

      assert_receive {:telemetry, :operator_complete,
                      %{skill: Beamlens.Skill.Beam, result: ^result}},
                     1000

      stop_coordinator(pid)
      :telemetry.detach({ref, :operator_complete})
    end

    test "ignores completion from unknown operator PIDs" do
      {:ok, pid} = start_coordinator()

      unknown_pid = spawn(fn -> :ok end)
      result = %{summary: "Test result", notifications: []}

      state_before = :sys.get_state(pid)

      send(pid, {:operator_complete, unknown_pid, Beamlens.Skill.Beam, result})

      state_after = :sys.get_state(pid)
      assert state_before.operator_results == state_after.operator_results

      stop_coordinator(pid)
    end
  end

  describe "invocation queue" do
    test "queues concurrent requests and processes them in order" do
      client =
        Puck.Test.mock_client(
          [%Beamlens.Coordinator.Tools.Done{intent: "done"}],
          default: %Beamlens.Coordinator.Tools.Done{intent: "done"}
        )

      {:ok, pid} =
        Coordinator.start_link(
          name: :"test_coord_queue_#{:erlang.unique_integer([:positive])}",
          puck_client: client
        )

      caller = self()

      spawn(fn ->
        result = Coordinator.run(pid, %{reason: "first"}, [])
        send(caller, {:result1, result})
      end)

      spawn(fn ->
        result = Coordinator.run(pid, %{reason: "second"}, [])
        send(caller, {:result2, result})
      end)

      assert_receive {:result1, {:ok, _}}, 2_000
      assert_receive {:result2, {:ok, _}}, 2_000

      stop_coordinator(pid)
    end

    test "queued invocation resets state for fresh analysis" do
      client =
        Puck.Test.mock_client(
          [%Beamlens.Coordinator.Tools.Done{intent: "done"}],
          default: %Beamlens.Coordinator.Tools.Done{intent: "done"}
        )

      {:ok, pid} =
        Coordinator.start_link(
          name: :"test_coord_reset_#{:erlang.unique_integer([:positive])}",
          puck_client: client
        )

      {:ok, result1} = Coordinator.run(pid, %{reason: "first"}, [])
      {:ok, result2} = Coordinator.run(pid, %{reason: "second"}, [])

      assert result1.insights == []
      assert result2.insights == []

      stop_coordinator(pid)
    end
  end

  describe "build_initial_context/1" do
    test "formats map with reason key" do
      context = %{reason: "memory alert triggered"}

      result = Coordinator.build_initial_context(context)

      assert %Puck.Context{} = result
      assert length(result.messages) == 1
      [message] = result.messages
      assert message.role == :user
      [part] = message.content
      assert part.text =~ "memory alert"
    end

    test "handles empty map" do
      context = %{}

      result = Coordinator.build_initial_context(context)

      assert %Puck.Context{} = result
      assert result.messages == []
    end

    test "handles nil" do
      result = Coordinator.build_initial_context(nil)

      assert %Puck.Context{} = result
      assert result.messages == []
    end

    test "formats map with multiple keys" do
      context = %{
        reason: "high latency",
        threshold: "500ms",
        service: "api"
      }

      result = Coordinator.build_initial_context(context)

      assert %Puck.Context{} = result
      assert length(result.messages) == 1
      [message] = result.messages
      [part] = message.content
      assert part.text =~ "high latency"
      assert part.text =~ "500ms"
      assert part.text =~ "api"
    end

    test "handles non-string values" do
      context = %{
        count: 42,
        enabled: true,
        threshold: 99.9
      }

      result = Coordinator.build_initial_context(context)

      assert %Puck.Context{} = result
      assert length(result.messages) == 1
      [message] = result.messages
      [part] = message.content
      assert part.text =~ "42"
      assert part.text =~ "true"
      assert part.text =~ "99.9"
    end

    test "handles special characters safely" do
      context = %{reason: "Error: <process crashed> & restarted"}

      result = Coordinator.build_initial_context(context)

      assert %Puck.Context{} = result
      assert length(result.messages) == 1
      [message] = result.messages
      [part] = message.content
      assert is_binary(part.text)
      assert part.text =~ "<process crashed>"
    end
  end
end
