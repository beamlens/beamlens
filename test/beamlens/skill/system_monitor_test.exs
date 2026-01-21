defmodule Beamlens.Skill.SystemMonitorTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Beamlens.Skill.SystemMonitor

  describe "title/0" do
    test "returns a non-empty string" do
      title = SystemMonitor.title()

      assert is_binary(title)
      assert String.length(title) > 0
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      description = SystemMonitor.description()

      assert is_binary(description)
      assert String.length(description) > 0
    end
  end

  describe "system_prompt/0" do
    test "returns a non-empty string" do
      system_prompt = SystemMonitor.system_prompt()

      assert is_binary(system_prompt)
      assert String.length(system_prompt) > 0
    end
  end

  describe "snapshot/0" do
    test "returns expected keys" do
      snapshot = SystemMonitor.snapshot()

      assert Map.has_key?(snapshot, :long_gc_events_5m)
      assert Map.has_key?(snapshot, :long_schedule_events_5m)
      assert Map.has_key?(snapshot, :max_gc_duration_ms)
      assert Map.has_key?(snapshot, :max_schedule_duration_ms)
      assert Map.has_key?(snapshot, :affected_process_count)
    end

    test "event counts are non-negative integers" do
      snapshot = SystemMonitor.snapshot()

      assert is_integer(snapshot.long_gc_events_5m)
      assert snapshot.long_gc_events_5m >= 0

      assert is_integer(snapshot.long_schedule_events_5m)
      assert snapshot.long_schedule_events_5m >= 0
    end

    test "max durations are non-negative integers" do
      snapshot = SystemMonitor.snapshot()

      assert is_integer(snapshot.max_gc_duration_ms)
      assert snapshot.max_gc_duration_ms >= 0

      assert is_integer(snapshot.max_schedule_duration_ms)
      assert snapshot.max_schedule_duration_ms >= 0
    end

    test "affected_process_count is non-negative integer" do
      snapshot = SystemMonitor.snapshot()

      assert is_integer(snapshot.affected_process_count)
      assert snapshot.affected_process_count >= 0
    end
  end

  describe "callbacks/0" do
    test "returns callback map with expected keys" do
      callbacks = SystemMonitor.callbacks()

      assert is_map(callbacks)
      assert Map.has_key?(callbacks, "sysmon_stats")
      assert Map.has_key?(callbacks, "sysmon_events")
    end

    test "callbacks are functions with correct arity" do
      callbacks = SystemMonitor.callbacks()

      assert is_function(callbacks["sysmon_stats"], 0)
      assert is_function(callbacks["sysmon_events"], 2)
    end
  end

  describe "sysmon_stats callback" do
    test "returns stats map with expected keys" do
      stats = SystemMonitor.callbacks()["sysmon_stats"].()

      assert Map.has_key?(stats, :long_gc_count_5m)
      assert Map.has_key?(stats, :long_schedule_count_5m)
      assert Map.has_key?(stats, :affected_process_count)
      assert Map.has_key?(stats, :max_gc_duration_ms)
      assert Map.has_key?(stats, :max_schedule_duration_ms)
    end

    test "counts are non-negative" do
      stats = SystemMonitor.callbacks()["sysmon_stats"].()

      assert stats.long_gc_count_5m >= 0
      assert stats.long_schedule_count_5m >= 0
      assert stats.affected_process_count >= 0
    end

    test "max durations are non-negative" do
      stats = SystemMonitor.callbacks()["sysmon_stats"].()

      assert stats.max_gc_duration_ms >= 0
      assert stats.max_schedule_duration_ms >= 0
    end
  end

  describe "sysmon_events callback" do
    test "returns list of events" do
      events = SystemMonitor.callbacks()["sysmon_events"].(nil, 10)

      assert is_list(events)
    end

    test "accepts type filter" do
      events = SystemMonitor.callbacks()["sysmon_events"].("long_gc", 10)

      assert is_list(events)
    end

    test "accepts limit parameter" do
      events_limited = SystemMonitor.callbacks()["sysmon_events"].(nil, 5)
      events_unlimited = SystemMonitor.callbacks()["sysmon_events"].(nil, 100)

      assert is_list(events_limited)
      assert is_list(events_unlimited)
    end

    test "when events exist, each event has expected fields" do
      events = SystemMonitor.callbacks()["sysmon_events"].(nil, 10)

      Enum.each(events, fn event ->
        assert Map.has_key?(event, :datetime)
        assert Map.has_key?(event, :type)
        assert Map.has_key?(event, :duration_ms)
        assert Map.has_key?(event, :pid)
      end)
    end
  end

  describe "callback_docs/0" do
    test "returns non-empty string" do
      docs = SystemMonitor.callback_docs()

      assert is_binary(docs)
      assert String.length(docs) > 0
    end

    test "documents all callbacks" do
      docs = SystemMonitor.callback_docs()

      assert docs =~ "sysmon_stats"
      assert docs =~ "sysmon_events"
    end
  end
end
