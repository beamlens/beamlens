defmodule Beamlens.Watchers.SupervisorTest do
  @moduledoc false

  use ExUnit.Case

  alias Beamlens.Watchers.Supervisor, as: WatchersSupervisor

  defmodule TestObservation do
    defstruct [:observed_at, :value]
  end

  defmodule TestWatcher do
    @behaviour Beamlens.Watchers.Watcher

    def domain, do: :test_domain

    def tools, do: []

    def init(_config), do: {:ok, %{}}

    def collect_snapshot(_state), do: %{value: 42}

    def baseline_config, do: %{window_size: 10, min_observations: 3}

    def snapshot_to_observation(snapshot) do
      %Beamlens.Watchers.SupervisorTest.TestObservation{
        observed_at: DateTime.utc_now(),
        value: snapshot[:value] || 0
      }
    end

    def format_observations_for_prompt(observations) do
      Enum.map_join(observations, "\n", fn obs ->
        "#{DateTime.to_iso8601(obs.observed_at)}: value=#{obs.value}"
      end)
    end
  end

  setup do
    start_supervised!({Registry, keys: :unique, name: Beamlens.WatcherRegistry})
    {:ok, supervisor} = WatchersSupervisor.start_link(name: nil)
    {:ok, supervisor: supervisor}
  end

  describe "start_watcher/2 with tuple spec" do
    test "starts builtin beam watcher", %{supervisor: supervisor} do
      result = WatchersSupervisor.start_watcher(supervisor, {:beam, "*/5 * * * *"})

      assert {:ok, pid} = result
      assert Process.alive?(pid)
    end

    test "returns error for unknown builtin watcher", %{supervisor: supervisor} do
      result = WatchersSupervisor.start_watcher(supervisor, {:unknown, "*/1 * * * *"})

      assert {:error, {:unknown_builtin_watcher, :unknown}} = result
    end
  end

  describe "start_watcher/2 with keyword spec" do
    test "starts custom watcher", %{supervisor: supervisor} do
      result =
        WatchersSupervisor.start_watcher(supervisor,
          name: :custom,
          watcher_module: TestWatcher,
          cron: "*/1 * * * *",
          config: []
        )

      assert {:ok, pid} = result
      assert Process.alive?(pid)
    end
  end

  describe "stop_watcher/2" do
    test "stops running watcher", %{supervisor: supervisor} do
      {:ok, pid} =
        WatchersSupervisor.start_watcher(supervisor,
          name: :to_stop,
          watcher_module: TestWatcher,
          cron: "*/1 * * * *"
        )

      ref = Process.monitor(pid)
      result = WatchersSupervisor.stop_watcher(supervisor, :to_stop)

      assert :ok = result
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end

    test "returns error for non-existent watcher", %{supervisor: supervisor} do
      result = WatchersSupervisor.stop_watcher(supervisor, :nonexistent)

      assert {:error, :not_found} = result
    end
  end

  describe "list_watchers/0" do
    test "returns empty list when no watchers", %{supervisor: _supervisor} do
      assert WatchersSupervisor.list_watchers() == []
    end

    test "returns list of watcher statuses", %{supervisor: supervisor} do
      WatchersSupervisor.start_watcher(supervisor,
        name: :watcher1,
        watcher_module: TestWatcher,
        cron: "*/1 * * * *"
      )

      WatchersSupervisor.start_watcher(supervisor,
        name: :watcher2,
        watcher_module: TestWatcher,
        cron: "*/5 * * * *"
      )

      watchers = WatchersSupervisor.list_watchers()

      assert length(watchers) == 2
      names = Enum.map(watchers, & &1.name)
      assert :watcher1 in names
      assert :watcher2 in names
    end
  end

  describe "trigger_watcher/1" do
    test "triggers watcher check", %{supervisor: supervisor} do
      parent = self()
      ref = make_ref()

      :telemetry.attach(
        ref,
        [:beamlens, :watcher, :check_stop],
        fn _event, _measurements, _metadata, _ -> send(parent, :check_done) end,
        nil
      )

      WatchersSupervisor.start_watcher(supervisor,
        name: :to_trigger,
        watcher_module: TestWatcher,
        cron: "0 0 1 1 *"
      )

      assert :ok = WatchersSupervisor.trigger_watcher(:to_trigger)
      assert_receive :check_done

      {:ok, status} = WatchersSupervisor.watcher_status(:to_trigger)
      assert status.run_count == 1

      :telemetry.detach(ref)
    end

    test "returns error for non-existent watcher" do
      assert {:error, :not_found} = WatchersSupervisor.trigger_watcher(:nonexistent)
    end
  end

  describe "watcher_status/1" do
    test "returns watcher status", %{supervisor: supervisor} do
      WatchersSupervisor.start_watcher(supervisor,
        name: :status_test,
        watcher_module: TestWatcher,
        cron: "*/1 * * * *"
      )

      {:ok, status} = WatchersSupervisor.watcher_status(:status_test)

      assert status.watcher == :test_domain
      assert status.cron == "*/1 * * * *"
      assert status.run_count == 0
    end

    test "returns error for non-existent watcher" do
      assert {:error, :not_found} = WatchersSupervisor.watcher_status(:nonexistent)
    end
  end
end
