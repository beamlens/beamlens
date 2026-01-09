defmodule Beamlens.Watchers.ServerTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Beamlens.AlertQueue
  alias Beamlens.Watchers.Server

  defmodule TestObservation do
    defstruct [:observed_at, :value]
  end

  defmodule TestWatcher do
    @behaviour Beamlens.Watchers.Watcher

    def domain, do: :test

    def tools, do: []

    def init(_config), do: {:ok, %{}}

    def collect_snapshot(_state) do
      %{collected_at: System.system_time(), value: 42}
    end

    def baseline_config do
      %{window_size: 10, min_observations: 100}
    end

    def snapshot_to_observation(snapshot) do
      %TestObservation{
        observed_at: DateTime.utc_now(),
        value: snapshot.value
      }
    end

    def format_observations_for_prompt(observations) do
      Enum.map_join(observations, "\n", fn obs ->
        "#{DateTime.to_iso8601(obs.observed_at)}: value=#{obs.value}"
      end)
    end
  end

  setup do
    {:ok, queue} = AlertQueue.start_link(name: nil)
    {:ok, queue: queue}
  end

  describe "start_link/1" do
    test "starts with valid options", %{queue: queue} do
      {:ok, pid} =
        Server.start_link(
          watcher_module: TestWatcher,
          cron: "*/1 * * * *",
          config: [],
          alert_handler: &AlertQueue.push(&1, queue)
        )

      assert Process.alive?(pid)
    end

    test "fails with invalid cron expression" do
      Process.flag(:trap_exit, true)

      result =
        Server.start_link(
          watcher_module: TestWatcher,
          cron: "invalid",
          config: []
        )

      assert {:error, _} = result
    end

    test "stores client_registry in state", %{queue: queue} do
      client_registry = %{primary: "Test", clients: []}

      {:ok, pid} =
        Server.start_link(
          watcher_module: TestWatcher,
          cron: "0 0 1 1 *",
          config: [],
          alert_handler: &AlertQueue.push(&1, queue),
          client_registry: client_registry
        )

      state = :sys.get_state(pid)
      assert state.client_registry == client_registry
    end
  end

  describe "status/1" do
    test "returns current status", %{queue: queue} do
      {:ok, pid} =
        Server.start_link(
          watcher_module: TestWatcher,
          cron: "*/1 * * * *",
          config: [],
          alert_handler: &AlertQueue.push(&1, queue)
        )

      status = Server.status(pid)

      assert status.watcher == :test
      assert status.cron == "*/1 * * * *"
      assert status.run_count == 0
      assert status.running == false
      assert status.next_run_at != nil
    end
  end

  describe "trigger/1" do
    test "runs check and increments run_count", %{queue: queue} do
      parent = self()
      ref = make_ref()

      :telemetry.attach(
        ref,
        [:beamlens, :watcher, :check_stop],
        fn _event, _measurements, _metadata, _ -> send(parent, :check_done) end,
        nil
      )

      {:ok, pid} =
        Server.start_link(
          watcher_module: TestWatcher,
          cron: "0 0 1 1 *",
          config: [],
          alert_handler: &AlertQueue.push(&1, queue)
        )

      Server.trigger(pid)
      assert_receive :check_done

      status = Server.status(pid)
      assert status.run_count == 1

      :telemetry.detach(ref)
    end

    test "increments run count on each trigger", %{queue: queue} do
      parent = self()
      ref = make_ref()

      :telemetry.attach(
        ref,
        [:beamlens, :watcher, :check_stop],
        fn _event, _measurements, _metadata, _ -> send(parent, :check_done) end,
        nil
      )

      {:ok, pid} =
        Server.start_link(
          watcher_module: TestWatcher,
          cron: "0 0 1 1 *",
          config: [],
          alert_handler: &AlertQueue.push(&1, queue)
        )

      Server.trigger(pid)
      assert_receive :check_done
      Server.trigger(pid)
      assert_receive :check_done
      Server.trigger(pid)
      assert_receive :check_done

      status = Server.status(pid)
      assert status.run_count == 3

      :telemetry.detach(ref)
    end
  end

  describe "telemetry events" do
    test "emits started event on init", %{queue: queue} do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        ref,
        [:beamlens, :watcher, :started],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :started, metadata})
        end,
        nil
      )

      {:ok, _pid} =
        Server.start_link(
          watcher_module: TestWatcher,
          cron: "*/1 * * * *",
          config: [],
          alert_handler: &AlertQueue.push(&1, queue)
        )

      assert_receive {:telemetry, :started, %{watcher: :test}}

      :telemetry.detach(ref)
    end

    test "emits check_start and check_stop on trigger", %{queue: queue} do
      ref = make_ref()
      parent = self()

      handler = fn event, _measurements, metadata, _ ->
        send(parent, {:telemetry, event, metadata})
      end

      :telemetry.attach_many(
        ref,
        [
          [:beamlens, :watcher, :check_start],
          [:beamlens, :watcher, :check_stop]
        ],
        handler,
        nil
      )

      {:ok, pid} =
        Server.start_link(
          watcher_module: TestWatcher,
          cron: "0 0 1 1 *",
          config: [],
          alert_handler: &AlertQueue.push(&1, queue)
        )

      Server.trigger(pid)

      assert_receive {:telemetry, [:beamlens, :watcher, :check_start], %{watcher: :test}}
      assert_receive {:telemetry, [:beamlens, :watcher, :check_stop], %{watcher: :test}}

      :telemetry.detach(ref)
    end

    test "emits baseline_collecting when gathering observations", %{queue: queue} do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        ref,
        [:beamlens, :watcher, :baseline_collecting],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :baseline_collecting, metadata})
        end,
        nil
      )

      {:ok, pid} =
        Server.start_link(
          watcher_module: TestWatcher,
          cron: "0 0 1 1 *",
          config: [],
          alert_handler: &AlertQueue.push(&1, queue)
        )

      Server.trigger(pid)

      assert_receive {:telemetry, :baseline_collecting,
                      %{watcher: :test, observation_count: 1, min_required: 100}}

      :telemetry.detach(ref)
    end
  end

  describe "alert cooldown" do
    test "initializes with empty alert_cooldowns", %{queue: queue} do
      {:ok, pid} =
        Server.start_link(
          watcher_module: TestWatcher,
          cron: "0 0 1 1 *",
          config: [],
          alert_handler: &AlertQueue.push(&1, queue)
        )

      state = :sys.get_state(pid)
      assert state.alert_cooldowns == %{}
    end

    test "baseline_anomaly_suppressed telemetry event is registered" do
      event_names = Beamlens.Telemetry.event_names()
      assert [:beamlens, :watcher, :baseline_anomaly_suppressed] in event_names
    end

    test "baseline_anomaly_detected telemetry event is registered" do
      event_names = Beamlens.Telemetry.event_names()
      assert [:beamlens, :watcher, :baseline_anomaly_detected] in event_names
    end

    test "cooldown is active within cooldown_seconds", %{queue: queue} do
      {:ok, pid} =
        Server.start_link(
          watcher_module: TestWatcher,
          cron: "0 0 1 1 *",
          config: [],
          alert_handler: &AlertQueue.push(&1, queue)
        )

      cooldown_data = %{
        reported_at: DateTime.utc_now(),
        cooldown_seconds: 600
      }

      :sys.replace_state(pid, fn state ->
        %{state | alert_cooldowns: %{"memory" => cooldown_data}}
      end)

      state = :sys.get_state(pid)
      assert state.alert_cooldowns["memory"].cooldown_seconds == 600
      assert state.alert_cooldowns["memory"].reported_at != nil
    end

    test "cooldown expires after cooldown_seconds", %{queue: queue} do
      {:ok, pid} =
        Server.start_link(
          watcher_module: TestWatcher,
          cron: "0 0 1 1 *",
          config: [],
          alert_handler: &AlertQueue.push(&1, queue)
        )

      past_time = DateTime.add(DateTime.utc_now(), -700, :second)

      cooldown_data = %{
        reported_at: past_time,
        cooldown_seconds: 600
      }

      :sys.replace_state(pid, fn state ->
        %{state | alert_cooldowns: %{"memory" => cooldown_data}}
      end)

      state = :sys.get_state(pid)

      diff =
        DateTime.diff(DateTime.utc_now(), state.alert_cooldowns["memory"].reported_at, :second)

      assert diff > state.alert_cooldowns["memory"].cooldown_seconds
    end

    test "cooldown stores LLM-provided duration in seconds", %{queue: queue} do
      {:ok, pid} =
        Server.start_link(
          watcher_module: TestWatcher,
          cron: "0 0 1 1 *",
          config: [],
          alert_handler: &AlertQueue.push(&1, queue)
        )

      cooldown_15_min = %{
        reported_at: DateTime.utc_now(),
        cooldown_seconds: 15 * 60
      }

      :sys.replace_state(pid, fn state ->
        %{state | alert_cooldowns: %{"scheduler" => cooldown_15_min}}
      end)

      state = :sys.get_state(pid)
      assert state.alert_cooldowns["scheduler"].cooldown_seconds == 900
    end
  end
end
