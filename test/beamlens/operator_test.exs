defmodule Beamlens.OperatorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Beamlens.Operator
  alias Beamlens.Operator.Snapshot

  defmodule TestSkill do
    @behaviour Beamlens.Skill

    def id, do: :test_continuous

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

      assert status.operator == :test_continuous
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

    test "starts with running reflecting start_loop option" do
      {:ok, pid} = start_operator_without_loop()

      state = :sys.get_state(pid)
      assert state.running == false

      Operator.stop(pid)
    end

    test "initializes with empty alerts list" do
      {:ok, pid} = start_operator_without_loop()

      state = :sys.get_state(pid)
      assert state.alerts == []

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

      assert_receive {:telemetry, :started, %{operator: :test_continuous}}

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
        %{state | client: mock_client(), running: true}
      end)

      send(pid, :continue_loop)

      assert_receive {:telemetry, :iteration_start,
                      %{operator: :test_continuous, iteration: 0, trace_id: _}},
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
        %{state | client: mock_client(), running: true}
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
        %{state | client: mock_client(), running: true, iteration: 5}
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

  describe "alert structure" do
    test "alerts include required fields when created" do
      alias Beamlens.Operator.Alert

      alert =
        Alert.new(%{
          operator: :test,
          anomaly_type: "test_anomaly",
          severity: :warning,
          summary: "Test summary",
          snapshots: []
        })

      assert alert.operator == :test
      assert alert.anomaly_type == "test_anomaly"
      assert alert.severity == :warning
      assert alert.summary == "Test summary"
      assert is_binary(alert.id)
      assert %DateTime{} = alert.detected_at
      assert is_binary(alert.trace_id)
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
end
