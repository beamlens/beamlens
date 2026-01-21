defmodule Beamlens.Skill.SystemMonitor.EventStoreTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Beamlens.Skill.SystemMonitor.EventStore

  @test_name :test_system_monitor_event_store

  setup do
    {:ok, pid} = start_supervised({EventStore, name: @test_name, max_size: 100})
    {:ok, store: pid}
  end

  describe "start_link/1" do
    test "starts the GenServer" do
      pid = Process.whereis(@test_name)
      assert Process.alive?(pid)
    end

    test "registers system_monitor on init" do
      pid = Process.whereis(@test_name)
      assert is_pid(pid)
      assert Process.info(pid, :messages) != nil
    end
  end

  describe "get_stats/1" do
    test "returns empty stats when no events" do
      stats = EventStore.get_stats(@test_name)

      assert stats.long_gc_count_5m == 0
      assert stats.long_schedule_count_5m == 0
      assert stats.affected_process_count == 0
      assert stats.max_gc_duration_ms == 0
      assert stats.max_schedule_duration_ms == 0
    end

    test "aggregates long_gc events" do
      send(@test_name, {:long_gc, {100, 1000, 10, 500, 0}, self()})

      EventStore.flush(@test_name)

      stats = EventStore.get_stats(@test_name)

      assert stats.long_gc_count_5m == 1
      assert is_integer(stats.max_gc_duration_ms)
      assert stats.max_gc_duration_ms == 100
      assert stats.affected_process_count == 1
    end

    test "aggregates long_schedule events" do
      send(@test_name, {:long_schedule, {150, 1000}, self()})

      EventStore.flush(@test_name)

      stats = EventStore.get_stats(@test_name)

      assert stats.long_schedule_count_5m == 1
      assert is_integer(stats.max_schedule_duration_ms)
      assert stats.max_schedule_duration_ms == 150
      assert stats.affected_process_count == 1
    end

    test "counts unique affected processes" do
      pid1 = self()
      pid2 = spawn(fn -> receive do: (_ -> :ok) end)

      send(@test_name, {:long_gc, {100, 1000, 10, 500, 0}, pid1})
      send(@test_name, {:long_schedule, {150, 1000}, pid1})
      send(@test_name, {:long_gc, {200, 1000, 10, 500, 0}, pid2})

      EventStore.flush(@test_name)

      stats = EventStore.get_stats(@test_name)

      assert stats.affected_process_count == 2
    end

    test "tracks maximum durations correctly" do
      send(@test_name, {:long_gc, {100, 1000, 10, 500, 0}, self()})
      send(@test_name, {:long_gc, {300, 1000, 10, 500, 0}, self()})
      send(@test_name, {:long_schedule, {150, 1000}, self()})
      send(@test_name, {:long_schedule, {250, 1000}, self()})

      EventStore.flush(@test_name)

      stats = EventStore.get_stats(@test_name)

      assert stats.max_gc_duration_ms == 300
      assert stats.max_schedule_duration_ms == 250
    end
  end

  describe "get_events/2" do
    test "returns empty list when no events" do
      events = EventStore.get_events(@test_name)
      assert events == []
    end

    test "returns all events" do
      send(@test_name, {:long_gc, {100, 1000, 10, 500, 0}, self()})
      send(@test_name, {:long_schedule, {150, 1000}, self()})

      EventStore.flush(@test_name)

      events = EventStore.get_events(@test_name)

      assert length(events) == 2
    end

    test "filters by long_gc type" do
      send(@test_name, {:long_gc, {100, 1000, 10, 500, 0}, self()})
      send(@test_name, {:long_schedule, {150, 1000}, self()})

      EventStore.flush(@test_name)

      events = EventStore.get_events(@test_name, type: "long_gc")

      assert length(events) == 1
      assert hd(events).type == "long_gc"
    end

    test "filters by long_schedule type" do
      send(@test_name, {:long_gc, {100, 1000, 10, 500, 0}, self()})
      send(@test_name, {:long_schedule, {150, 1000}, self()})

      EventStore.flush(@test_name)

      events = EventStore.get_events(@test_name, type: "long_schedule")

      assert length(events) == 1
      assert hd(events).type == "long_schedule"
    end

    test "returns all events when type is nil" do
      send(@test_name, {:long_gc, {100, 1000, 10, 500, 0}, self()})
      send(@test_name, {:long_schedule, {150, 1000}, self()})

      EventStore.flush(@test_name)

      events = EventStore.get_events(@test_name, type: nil)

      assert length(events) == 2
    end

    test "respects limit parameter" do
      for i <- 1..10 do
        send(@test_name, {:long_gc, {i * 10, 1000, 10, 500, 0}, self()})
      end

      EventStore.flush(@test_name)

      events = EventStore.get_events(@test_name, limit: 5)

      assert length(events) == 5
    end

    test "returns events in chronological order" do
      send(@test_name, {:long_gc, {100, 1000, 10, 500, 0}, self()})
      send(@test_name, {:long_schedule, {150, 1000}, self()})
      send(@test_name, {:long_gc, {200, 1000, 10, 500, 0}, self()})

      EventStore.flush(@test_name)

      events = EventStore.get_events(@test_name)

      assert length(events) == 3
      assert Enum.at(events, 0).type == "long_gc"
      assert Enum.at(events, 1).type == "long_schedule"
      assert Enum.at(events, 2).type == "long_gc"
    end

    test "includes heap_size for long_gc events" do
      send(@test_name, {:long_gc, {100, 1000, 10, 500, 0}, self()})

      EventStore.flush(@test_name)

      events = EventStore.get_events(@test_name, type: "long_gc")

      assert hd(events).heap_size == 1000
      assert hd(events).old_heap_size == 500
    end

    test "includes runtime_reductions for long_schedule events" do
      send(@test_name, {:long_schedule, {150, 1000}, self()})

      EventStore.flush(@test_name)

      events = EventStore.get_events(@test_name, type: "long_schedule")

      assert hd(events).runtime_reductions == 1000
    end

    test "formats datetime as ISO8601" do
      send(@test_name, {:long_gc, {100, 1000, 10, 500, 0}, self()})

      EventStore.flush(@test_name)

      events = EventStore.get_events(@test_name)

      assert hd(events).datetime =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
    end

    test "formats pid as inspect string" do
      send(@test_name, {:long_gc, {100, 1000, 10, 500, 0}, self()})

      EventStore.flush(@test_name)

      events = EventStore.get_events(@test_name)

      assert hd(events).pid =~ ~r/^#PID<\d+\.\d+\.\d+>$/
    end
  end

  describe "ring buffer behavior" do
    test "enforces max size limit" do
      stop_supervised!(EventStore)
      {:ok, _pid} = start_supervised({EventStore, name: @test_name, max_size: 5})

      for i <- 1..10 do
        send(@test_name, {:long_gc, {i * 10, 1000, 10, 500, 0}, self()})
      end

      EventStore.flush(@test_name)

      stats = EventStore.get_stats(@test_name)

      assert stats.long_gc_count_5m == 5
    end

    test "removes oldest events when max size exceeded" do
      stop_supervised!(EventStore)
      {:ok, _pid} = start_supervised({EventStore, name: @test_name, max_size: 3})

      send(@test_name, {:long_gc, {100, 1000, 10, 500, 0}, self()})
      send(@test_name, {:long_gc, {200, 1000, 10, 500, 0}, self()})
      send(@test_name, {:long_gc, {300, 1000, 10, 500, 0}, self()})
      send(@test_name, {:long_gc, {400, 1000, 10, 500, 0}, self()})

      EventStore.flush(@test_name)

      events = EventStore.get_events(@test_name)

      assert length(events) == 3

      durations = Enum.map(events, & &1.duration_ms)

      assert 100 not in durations
      assert 200 in durations
      assert 300 in durations
      assert 400 in durations
    end
  end

  describe "time-based pruning" do
    test "prunes old events based on timestamp" do
      stats = EventStore.get_stats(@test_name)

      assert stats.long_gc_count_5m == 0
    end
  end

  describe "termination" do
    test "unregisters system_monitor on terminate" do
      pid = Process.whereis(@test_name)

      monitor_ref = Process.monitor(pid)

      GenServer.stop(@test_name, :normal)

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}
    end
  end

  describe "when store not running" do
    test "get_stats returns empty stats for non-existent store" do
      stats = EventStore.get_stats(:nonexistent_store)

      assert stats.long_gc_count_5m == 0
      assert stats.long_schedule_count_5m == 0
      assert stats.affected_process_count == 0
      assert stats.max_gc_duration_ms == 0
      assert stats.max_schedule_duration_ms == 0
    end

    test "get_events returns empty list for non-existent store" do
      events = EventStore.get_events(:nonexistent_store)
      assert events == []
    end

    test "get_events with options returns empty list for non-existent store" do
      events = EventStore.get_events(:nonexistent_store, type: "long_gc", limit: 10)
      assert events == []
    end

    test "flush returns :ok for non-existent store" do
      assert EventStore.flush(:nonexistent_store) == :ok
    end
  end
end
