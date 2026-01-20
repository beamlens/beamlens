defmodule Beamlens.OperatorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Beamlens.Operator
  alias Beamlens.Operator.Snapshot

  defmodule TestSkill do
    @behaviour Beamlens.Skill

    def title, do: "Test Skill"

    def description, do: "Test skill for unit tests"

    def system_prompt, do: "You are a test skill for unit tests."

    def snapshot do
      %{
        memory_utilization_pct: 45.0,
        process_utilization_pct: 10.0,
        port_utilization_pct: 5.0,
        atom_utilization_pct: 2.0,
        scheduler_run_queue: 0,
        schedulers_online: 8
      }
    end

    def callbacks do
      %{
        "get_test_value" => fn -> 42 end
      }
    end

    def callback_docs do
      "### get_test_value()\nReturns 42"
    end
  end

  defp start_operator_without_loop(opts \\ []) do
    opts = Keyword.merge([skill: TestSkill, start_loop: false], opts)
    Operator.start_link(opts)
  end

  defp mock_client do
    # Return an error to gracefully stop the loop after iteration_start telemetry
    Puck.Client.new({Puck.Backends.Mock, error: :test_stop})
  end

  describe "start_link/1" do
    test "starts with valid options" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        ref,
        [:beamlens, :operator, :started],
        fn _event, _measurements, _metadata, _ -> send(parent, :started) end,
        nil
      )

      {:ok, pid} = start_operator_without_loop()

      assert Process.alive?(pid)
      assert_receive :started

      Operator.stop(pid)
      :telemetry.detach(ref)
    end

    test "stores client_registry in state" do
      client_registry = %{primary: "Test", clients: []}

      {:ok, pid} =
        start_operator_without_loop(client_registry: client_registry)

      state = :sys.get_state(pid)
      assert state.client_registry == client_registry

      Operator.stop(pid)
    end
  end

  describe "status/1" do
    test "returns current status" do
      {:ok, pid} = start_operator_without_loop()

      status = Operator.status(pid)

      assert status.operator == TestSkill
      assert status.state == :healthy
      assert status.running == false

      Operator.stop(pid)
    end
  end

  describe "initial state" do
    test "starts in healthy state" do
      {:ok, pid} = start_operator_without_loop()

      state = :sys.get_state(pid)
      assert state.state == :healthy

      Operator.stop(pid)
    end

    test "starts with status reflecting start_loop option" do
      {:ok, pid} = start_operator_without_loop()

      state = :sys.get_state(pid)
      assert state.status == :idle

      Operator.stop(pid)
    end

    test "initializes with empty notifications list" do
      {:ok, pid} = start_operator_without_loop()

      state = :sys.get_state(pid)
      assert state.notifications == []

      Operator.stop(pid)
    end

    test "snapshots list starts empty" do
      {:ok, pid} = start_operator_without_loop()

      state = :sys.get_state(pid)
      assert state.snapshots == []

      Operator.stop(pid)
    end

    test "iteration counter starts at zero" do
      {:ok, pid} = start_operator_without_loop()

      state = :sys.get_state(pid)
      assert state.iteration == 0

      Operator.stop(pid)
    end

    test "stores skill in state" do
      {:ok, pid} = start_operator_without_loop()

      state = :sys.get_state(pid)
      assert state.skill == TestSkill

      Operator.stop(pid)
    end
  end

  describe "snapshot management" do
    test "snapshots are stored with unique IDs" do
      snapshot1 = Snapshot.new(%{test: 1})
      snapshot2 = Snapshot.new(%{test: 2})

      assert snapshot1.id != snapshot2.id
      assert String.length(snapshot1.id) == 16
      assert String.length(snapshot2.id) == 16
    end

    test "snapshot IDs are lowercase hex" do
      snapshot = Snapshot.new(%{test: "data"})

      assert snapshot.id =~ ~r/^[a-f0-9]+$/
    end
  end

  describe "state transitions" do
    test "valid states are healthy, observing, warning, critical" do
      {:ok, pid} = start_operator_without_loop()

      for expected_state <- [:healthy, :observing, :warning, :critical] do
        :sys.replace_state(pid, fn state ->
          %{state | state: expected_state}
        end)

        status = Operator.status(pid)
        assert status.state == expected_state
      end

      Operator.stop(pid)
    end
  end

  describe "telemetry events" do
    test "emits started event on init" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        ref,
        [:beamlens, :operator, :started],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :started, metadata})
        end,
        nil
      )

      {:ok, pid} = start_operator_without_loop()

      assert_receive {:telemetry, :started, %{operator: TestSkill}}

      Operator.stop(pid)
      :telemetry.detach(ref)
    end

    test "emits iteration_start event when loop triggered with mock client" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        ref,
        [:beamlens, :operator, :iteration_start],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :iteration_start, metadata})
        end,
        nil
      )

      {:ok, pid} = start_operator_without_loop()

      :sys.replace_state(pid, fn state ->
        %{state | client: mock_client(), status: :running}
      end)

      send(pid, :continue_loop)

      assert_receive {:telemetry, :iteration_start,
                      %{operator: TestSkill, iteration: 0, trace_id: _}},
                     1000

      Operator.stop(pid)
      :telemetry.detach(ref)
    end

    test "iteration_start includes trace_id" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        ref,
        [:beamlens, :operator, :iteration_start],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :iteration_start, metadata})
        end,
        nil
      )

      {:ok, pid} = start_operator_without_loop()

      :sys.replace_state(pid, fn state ->
        %{state | client: mock_client(), status: :running}
      end)

      send(pid, :continue_loop)

      assert_receive {:telemetry, :iteration_start, %{trace_id: trace_id}}, 1000
      assert is_binary(trace_id)
      assert String.length(trace_id) == 32

      Operator.stop(pid)
      :telemetry.detach(ref)
    end
  end

  describe "context management" do
    test "context tracks iteration in metadata" do
      {:ok, pid} = start_operator_without_loop()

      state = :sys.get_state(pid)
      assert is_map(state.context.metadata)
      assert Map.has_key?(state.context.metadata, :iteration)
      assert state.context.metadata.iteration == 0

      Operator.stop(pid)
    end
  end

  describe "handle_info :continue_loop" do
    test "triggers loop continuation with mock client" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        ref,
        [:beamlens, :operator, :iteration_start],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :iteration_start, metadata})
        end,
        nil
      )

      {:ok, pid} = start_operator_without_loop()

      :sys.replace_state(pid, fn state ->
        %{state | client: mock_client(), status: :running, iteration: 5}
      end)

      send(pid, :continue_loop)

      assert_receive {:telemetry, :iteration_start, %{iteration: 5}}, 1000

      Operator.stop(pid)
      :telemetry.detach(ref)
    end
  end

  describe "client configuration" do
    test "builds client with default configuration when no registry provided" do
      {:ok, pid} = start_operator_without_loop()

      state = :sys.get_state(pid)
      assert state.client != nil
      assert state.client_registry == nil

      Operator.stop(pid)
    end
  end

  describe "notification structure" do
    test "notifications include required fields when created" do
      alias Beamlens.Operator.Notification

      notification =
        Notification.new(%{
          operator: :test,
          anomaly_type: "test_anomaly",
          severity: :warning,
          summary: "Test summary",
          snapshots: []
        })

      assert notification.operator == :test
      assert notification.anomaly_type == "test_anomaly"
      assert notification.severity == :warning
      assert notification.summary == "Test summary"
      assert is_binary(notification.id)
      assert %DateTime{} = notification.detected_at
      assert is_binary(notification.trace_id)
    end
  end

  describe "compaction configuration" do
    test "uses default compaction settings when not specified" do
      {:ok, pid} = start_operator_without_loop()

      state = :sys.get_state(pid)
      client = state.client

      assert client.auto_compaction != nil
      {:summarize, config} = client.auto_compaction
      assert Keyword.get(config, :max_tokens) == 50_000
      assert Keyword.get(config, :keep_last) == 5
      assert is_binary(Keyword.get(config, :prompt))

      Operator.stop(pid)
    end

    test "uses custom compaction_max_tokens when provided" do
      {:ok, pid} = start_operator_without_loop(compaction_max_tokens: 100_000)

      state = :sys.get_state(pid)
      {:summarize, config} = state.client.auto_compaction
      assert Keyword.get(config, :max_tokens) == 100_000

      Operator.stop(pid)
    end

    test "uses custom compaction_keep_last when provided" do
      {:ok, pid} = start_operator_without_loop(compaction_keep_last: 10)

      state = :sys.get_state(pid)
      {:summarize, config} = state.client.auto_compaction
      assert Keyword.get(config, :keep_last) == 10

      Operator.stop(pid)
    end

    test "uses both custom compaction settings when provided" do
      {:ok, pid} =
        start_operator_without_loop(
          compaction_max_tokens: 75_000,
          compaction_keep_last: 8
        )

      state = :sys.get_state(pid)
      {:summarize, config} = state.client.auto_compaction

      assert Keyword.get(config, :max_tokens) == 75_000
      assert Keyword.get(config, :keep_last) == 8

      Operator.stop(pid)
    end

    test "compaction prompt mentions monitoring context" do
      {:ok, pid} = start_operator_without_loop()

      state = :sys.get_state(pid)
      {:summarize, config} = state.client.auto_compaction
      prompt = Keyword.get(config, :prompt)

      assert prompt =~ "monitoring"
      assert prompt =~ "Snapshot IDs"
      assert prompt =~ "anomalies"

      Operator.stop(pid)
    end
  end

  describe "tool schemas" do
    alias Beamlens.Operator.Tools

    test "schema includes Done tool" do
      schema = Tools.schema()
      assert schema != nil

      {:ok, result} = Zoi.parse(schema, %{intent: "done"})
      assert %Tools.Done{intent: "done"} = result
    end
  end

  describe "notify_pid option" do
    test "stores notify_pid in state when provided" do
      {:ok, pid} = start_operator_without_loop(notify_pid: self())

      state = :sys.get_state(pid)
      assert state.notify_pid == self()

      Operator.stop(pid)
    end

    test "notify_pid defaults to nil when not provided" do
      {:ok, pid} = start_operator_without_loop()

      state = :sys.get_state(pid)
      assert state.notify_pid == nil

      Operator.stop(pid)
    end
  end

  describe "run/2 skill resolution" do
    test "returns error for invalid skill module" do
      assert {:error, {:invalid_skill_module, :nonexistent}} =
               Operator.run(:nonexistent, %{})
    end
  end

  describe "run/3 without started operator" do
    test "raises ArgumentError when operator not in registry" do
      start_supervised!({Registry, keys: :unique, name: Beamlens.OperatorRegistry})

      assert_raise ArgumentError, ~r/Operator for .* not started/, fn ->
        Operator.run(TestSkill, %{reason: "test"}, [])
      end
    end
  end

  describe "puck_client override" do
    test "uses provided puck_client for loop responses" do
      responses = [
        %Beamlens.Operator.Tools.TakeSnapshot{intent: "take_snapshot"},
        %Beamlens.Operator.Tools.SetState{intent: "set_state", state: :healthy, reason: "ok"},
        %Beamlens.Operator.Tools.Done{intent: "done"}
      ]

      client = Puck.Test.mock_client(responses)

      {:ok, pid} =
        Operator.start_link(
          skill: TestSkill,
          start_loop: true,
          notify_pid: self(),
          puck_client: client
        )

      Operator.await(pid, 1_000)

      assert_receive {:operator_complete, _, _,
                      %Beamlens.Operator.CompletionResult{state: :healthy}},
                     1_000
    end
  end

  describe "snapshot_id resolution" do
    alias Beamlens.Operator.Tools.{Done, SendNotification, TakeSnapshot}

    test "send_notification references snapshot via function response" do
      responses = [
        %TakeSnapshot{intent: "take_snapshot"},
        fn messages ->
          snapshot_id =
            messages
            |> Enum.reverse()
            |> Enum.find_value(fn
              %{metadata: %{tool_result: true}, content: [%{text: json} | _]} ->
                case Jason.decode(json) do
                  {:ok, %{"id" => id, "data" => _, "captured_at" => _}} -> id
                  _ -> nil
                end

              _ ->
                nil
            end)

          %SendNotification{
            intent: "send_notification",
            type: "process_spike",
            summary: "process count elevated",
            severity: :warning,
            snapshot_ids: [snapshot_id]
          }
        end,
        %Done{intent: "done"}
      ]

      client = Puck.Test.mock_client(responses)

      {:ok, pid} =
        Operator.start_link(
          skill: TestSkill,
          start_loop: true,
          notify_pid: self(),
          puck_client: client
        )

      Operator.await(pid, 1_000)

      assert_receive {:operator_complete, _, _,
                      %Beamlens.Operator.CompletionResult{
                        notifications: [notification],
                        snapshots: [snapshot]
                      }},
                     1_000

      assert Enum.any?(notification.snapshots, &(&1.id == snapshot.id))
    end
  end

  describe "message/3" do
    test "exits when operator not found" do
      assert_raise ArgumentError, fn ->
        Operator.message(:nonexistent, "test")
      end
    catch
      :exit, _ -> :ok
    end
  end

  describe "run_async/3" do
    alias Beamlens.Operator.Tools.Done

    test "sends operator_complete message to notify_pid" do
      client = Puck.Test.mock_client([%Done{intent: "done"}])

      {:ok, pid} =
        Operator.start_link(
          skill: TestSkill,
          name: :"test_async_#{:erlang.unique_integer([:positive])}",
          start_loop: false,
          puck_client: client
        )

      Operator.run_async(pid, %{reason: "test"}, notify_pid: self())

      assert_receive {:operator_complete, ^pid, TestSkill,
                      %Beamlens.Operator.CompletionResult{state: :healthy}},
                     1_000

      Operator.stop(pid)
    end

    test "sends operator_notification messages for each notification" do
      alias Beamlens.Operator.Tools.{SendNotification, TakeSnapshot}

      responses = [
        %TakeSnapshot{intent: "take_snapshot"},
        fn messages ->
          snapshot_id =
            messages
            |> Enum.reverse()
            |> Enum.find_value(fn
              %{metadata: %{tool_result: true}, content: [%{text: json} | _]} ->
                case Jason.decode(json) do
                  {:ok, %{"id" => id}} -> id
                  _ -> nil
                end

              _ ->
                nil
            end)

          %SendNotification{
            intent: "send_notification",
            type: "test_alert",
            summary: "Test notification",
            severity: :info,
            snapshot_ids: [snapshot_id]
          }
        end,
        %Done{intent: "done"}
      ]

      client = Puck.Test.mock_client(responses)

      {:ok, pid} =
        Operator.start_link(
          skill: TestSkill,
          name: :"test_async_notif_#{:erlang.unique_integer([:positive])}",
          start_loop: false,
          puck_client: client
        )

      Operator.run_async(pid, %{reason: "test"}, notify_pid: self())

      assert_receive {:operator_notification, ^pid, %Beamlens.Operator.Notification{}}, 1_000
      assert_receive {:operator_complete, ^pid, TestSkill, _result}, 1_000

      Operator.stop(pid)
    end
  end

  describe "invocation queue" do
    alias Beamlens.Operator.Tools.Done

    test "queues concurrent requests and processes them in order" do
      client = Puck.Test.mock_client([%Done{intent: "done"}], default: %Done{intent: "done"})

      {:ok, pid} =
        Operator.start_link(
          skill: TestSkill,
          name: :"test_operator_#{:erlang.unique_integer([:positive])}",
          start_loop: false,
          puck_client: client
        )

      caller1 = self()

      spawn(fn ->
        result = Operator.run(pid, %{reason: "first"}, [])
        send(caller1, {:result1, result})
      end)

      spawn(fn ->
        result = Operator.run(pid, %{reason: "second"}, [])
        send(caller1, {:result2, result})
      end)

      assert_receive {:result1, {:ok, _}}, 2_000
      assert_receive {:result2, {:ok, _}}, 2_000

      Operator.stop(pid)
    end

    test "processes queued async invocations after current completes" do
      client = Puck.Test.mock_client([%Done{intent: "done"}], default: %Done{intent: "done"})

      {:ok, pid} =
        Operator.start_link(
          skill: TestSkill,
          name: :"test_operator_queue_#{:erlang.unique_integer([:positive])}",
          start_loop: false,
          puck_client: client
        )

      Operator.run_async(pid, %{reason: "first"}, notify_pid: self())
      Operator.run_async(pid, %{reason: "second"}, notify_pid: self())

      assert_receive {:operator_complete, ^pid, TestSkill, _}, 2_000
      assert_receive {:operator_complete, ^pid, TestSkill, _}, 2_000

      Operator.stop(pid)
    end
  end
end
