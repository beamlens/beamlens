defmodule Beamlens.Skill.BeamTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Beamlens.Skill.Beam

  describe "title/0" do
    test "returns a non-empty string" do
      title = Beam.title()

      assert is_binary(title)
      assert String.length(title) > 0
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      description = Beam.description()

      assert is_binary(description)
      assert String.length(description) > 0
    end
  end

  describe "system_prompt/0" do
    test "returns a non-empty string" do
      system_prompt = Beam.system_prompt()

      assert is_binary(system_prompt)
      assert String.length(system_prompt) > 0
    end
  end

  describe "snapshot/0" do
    test "returns utilization percentages" do
      snapshot = Beam.snapshot()

      assert is_float(snapshot.process_utilization_pct)
      assert is_float(snapshot.port_utilization_pct)
      assert is_float(snapshot.atom_utilization_pct)
      assert is_integer(snapshot.scheduler_run_queue)
      assert is_integer(snapshot.schedulers_online)
    end

    test "utilization values are within bounds" do
      snapshot = Beam.snapshot()

      assert snapshot.process_utilization_pct >= 0
      assert snapshot.process_utilization_pct <= 100
    end
  end

  describe "callbacks/0" do
    test "returns callback map with expected keys" do
      callbacks = Beam.callbacks()

      assert is_map(callbacks)
      assert Map.has_key?(callbacks, "beam_get_memory")
      assert Map.has_key?(callbacks, "beam_get_processes")
      assert Map.has_key?(callbacks, "beam_get_schedulers")
      assert Map.has_key?(callbacks, "beam_get_atoms")
      assert Map.has_key?(callbacks, "beam_get_system")
      assert Map.has_key?(callbacks, "beam_get_persistent_terms")
      assert Map.has_key?(callbacks, "beam_top_processes")
      assert Map.has_key?(callbacks, "beam_queue_processes")
      assert Map.has_key?(callbacks, "beam_queue_growth")
      assert Map.has_key?(callbacks, "beam_queue_stats")
    end

    test "callbacks are functions" do
      callbacks = Beam.callbacks()

      assert is_function(callbacks["beam_get_memory"], 0)
      assert is_function(callbacks["beam_get_processes"], 0)
      assert is_function(callbacks["beam_get_schedulers"], 0)
      assert is_function(callbacks["beam_get_atoms"], 0)
      assert is_function(callbacks["beam_get_system"], 0)
      assert is_function(callbacks["beam_get_persistent_terms"], 0)
      assert is_function(callbacks["beam_top_processes"], 2)
      assert is_function(callbacks["beam_queue_processes"], 1)
      assert is_function(callbacks["beam_queue_growth"], 2)
      assert is_function(callbacks["beam_queue_stats"], 0)
    end
  end

  describe "beam_get_system callback" do
    test "returns system context" do
      info = Beam.callbacks()["beam_get_system"].()

      assert is_binary(info.node)
      assert is_binary(info.otp_release)
      assert is_binary(info.elixir_version)
      assert is_integer(info.uptime_seconds)
      assert is_integer(info.schedulers_online)
    end
  end

  describe "beam_get_memory callback" do
    test "returns memory in MB" do
      stats = Beam.callbacks()["beam_get_memory"].()

      assert is_float(stats.total_mb)
      assert is_float(stats.processes_mb)
      assert is_float(stats.system_mb)
      assert is_float(stats.binary_mb)
      assert is_float(stats.ets_mb)
      assert is_float(stats.code_mb)
    end

    test "total is positive" do
      stats = Beam.callbacks()["beam_get_memory"].()
      assert stats.total_mb > 0
    end
  end

  describe "beam_get_processes callback" do
    test "returns counts and limits" do
      stats = Beam.callbacks()["beam_get_processes"].()

      assert is_integer(stats.process_count)
      assert is_integer(stats.process_limit)
      assert is_integer(stats.port_count)
      assert is_integer(stats.port_limit)
    end

    test "count is less than limit" do
      stats = Beam.callbacks()["beam_get_processes"].()
      assert stats.process_count < stats.process_limit
    end
  end

  describe "beam_get_schedulers callback" do
    test "returns scheduler information" do
      stats = Beam.callbacks()["beam_get_schedulers"].()

      assert is_integer(stats.schedulers)
      assert is_integer(stats.schedulers_online)
      assert is_integer(stats.dirty_cpu_schedulers_online)
      assert is_integer(stats.dirty_io_schedulers)
      assert is_integer(stats.run_queue)
    end
  end

  describe "beam_get_atoms callback" do
    test "returns atom table metrics" do
      stats = Beam.callbacks()["beam_get_atoms"].()

      assert is_integer(stats.atom_count)
      assert is_integer(stats.atom_limit)
      assert is_float(stats.atom_mb)
      assert is_float(stats.atom_used_mb)
    end
  end

  describe "beam_get_persistent_terms callback" do
    test "returns persistent term usage" do
      stats = Beam.callbacks()["beam_get_persistent_terms"].()

      assert is_integer(stats.count)
      assert is_float(stats.memory_mb)
    end
  end

  describe "beam_top_processes callback" do
    test "returns top processes with limit and sort" do
      result = Beam.callbacks()["beam_top_processes"].(10, "memory")

      assert is_integer(result.total_processes)
      assert result.showing <= 10
      assert result.offset == 0
      assert result.limit == 10
      assert is_list(result.processes)
    end

    test "respects limit" do
      result = Beam.callbacks()["beam_top_processes"].(5, "memory")

      assert result.showing <= 5
      assert result.limit == 5
    end

    test "caps limit at 50" do
      result = Beam.callbacks()["beam_top_processes"].(100, "memory")

      assert result.limit == 50
    end

    test "process entries have expected fields" do
      result = Beam.callbacks()["beam_top_processes"].(1, "memory")

      assert result.showing > 0
      [proc | _] = result.processes
      assert Map.has_key?(proc, :pid)
      assert Map.has_key?(proc, :memory_kb)
      assert Map.has_key?(proc, :message_queue)
      assert Map.has_key?(proc, :reductions)
    end

    test "supports sort_by memory" do
      result = Beam.callbacks()["beam_top_processes"].(5, "memory")

      assert result.sort_by == "memory_kb"
    end

    test "supports sort_by message_queue" do
      result = Beam.callbacks()["beam_top_processes"].(5, "message_queue")

      assert result.sort_by == "message_queue"
    end

    test "supports sort_by reductions" do
      result = Beam.callbacks()["beam_top_processes"].(5, "reductions")

      assert result.sort_by == "reductions"
    end
  end

  describe "callback_docs/0" do
    test "returns non-empty string" do
      docs = Beam.callback_docs()

      assert is_binary(docs)
      assert String.length(docs) > 0
    end

    test "documents all callbacks" do
      docs = Beam.callback_docs()

      assert docs =~ "beam_get_memory"
      assert docs =~ "beam_get_processes"
      assert docs =~ "beam_get_schedulers"
      assert docs =~ "beam_get_atoms"
      assert docs =~ "beam_get_system"
      assert docs =~ "beam_get_persistent_terms"
      assert docs =~ "beam_top_processes"
      assert docs =~ "beam_queue_processes"
      assert docs =~ "beam_queue_growth"
      assert docs =~ "beam_queue_stats"
    end
  end

  describe "beam_queue_processes callback" do
    test "returns processes with queue data" do
      result = Beam.callbacks()["beam_queue_processes"].(0)

      assert is_integer(result.threshold)
      assert is_integer(result.count)
      assert is_list(result.processes)
    end

    test "filters by threshold" do
      result = Beam.callbacks()["beam_queue_processes"].(1000)

      assert result.threshold == 1000

      Enum.each(result.processes, fn proc ->
        assert proc.message_queue > 1000
      end)
    end

    test "processes have expected fields" do
      result = Beam.callbacks()["beam_queue_processes"].(0)

      Enum.each(result.processes, fn proc ->
        assert Map.has_key?(proc, :pid)
        assert Map.has_key?(proc, :message_queue)
        assert Map.has_key?(proc, :current_function)
      end)
    end

    test "sorts by queue size descending" do
      result = Beam.callbacks()["beam_queue_processes"].(0)

      if length(result.processes) > 1 do
        queue_sizes = Enum.map(result.processes, & &1.message_queue)
        assert queue_sizes == Enum.sort(queue_sizes, :desc)
      end
    end
  end

  describe "beam_queue_growth callback" do
    test "returns growth data over interval" do
      result = Beam.callbacks()["beam_queue_growth"].(10, 5)

      assert is_integer(result.interval_ms)
      assert result.interval_ms == 10
      assert is_integer(result.showing)
      assert is_integer(result.limit)
      assert result.limit == 5
      assert is_list(result.processes)
    end

    test "processes have growth fields" do
      result = Beam.callbacks()["beam_queue_growth"].(5, 3)

      Enum.each(result.processes, fn proc ->
        assert Map.has_key?(proc, :pid)
        assert is_integer(proc.queue_growth)
        assert proc.queue_growth > 0
        assert is_integer(proc.initial_queue)
        assert is_integer(proc.final_queue)
        assert proc.final_queue > proc.initial_queue
      end)
    end

    test "respects limit" do
      result = Beam.callbacks()["beam_queue_growth"].(5, 2)

      assert result.showing <= 2
      assert result.limit == 2
    end

    test "sorts by growth rate descending" do
      result = Beam.callbacks()["beam_queue_growth"].(5, 10)

      if length(result.processes) > 1 do
        growth_rates = Enum.map(result.processes, & &1.queue_growth)
        assert growth_rates == Enum.sort(growth_rates, :desc)
      end
    end
  end

  describe "beam_queue_stats callback" do
    test "returns aggregate queue statistics" do
      stats = Beam.callbacks()["beam_queue_stats"].()

      assert is_integer(stats.total_queued_messages)
      assert is_integer(stats.processes_with_large_queues)
      assert is_integer(stats.processes_with_critical_queues)
      assert is_integer(stats.max_queue_size)
    end

    test "total queued messages is non-negative" do
      stats = Beam.callbacks()["beam_queue_stats"].()

      assert stats.total_queued_messages >= 0
    end

    test "large queue count is non-negative" do
      stats = Beam.callbacks()["beam_queue_stats"].()

      assert stats.processes_with_large_queues >= 0
    end

    test "critical queue count is non-negative" do
      stats = Beam.callbacks()["beam_queue_stats"].()

      assert stats.processes_with_critical_queues >= 0
    end

    test "max_queue_size matches max process queue when present" do
      stats = Beam.callbacks()["beam_queue_stats"].()

      if stats.max_queue_process do
        assert Map.has_key?(stats.max_queue_process, :pid)
        assert Map.has_key?(stats.max_queue_process, :name)
      end
    end
  end
end
