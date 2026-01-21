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
      assert Map.has_key?(callbacks, "beam_binary_leak")
      assert Map.has_key?(callbacks, "beam_binary_top_memory")
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
      assert is_function(callbacks["beam_binary_leak"], 1)
      assert is_function(callbacks["beam_binary_top_memory"], 1)
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

  describe "beam_binary_leak callback" do
    test "returns leak detection results" do
      result = Beam.callbacks()["beam_binary_leak"].(10)

      assert is_integer(result.total_processes)
      assert is_integer(result.limit)
      assert is_list(result.processes)
    end

    test "respects limit parameter" do
      result = Beam.callbacks()["beam_binary_leak"].(5)

      assert result.limit == 5
    end

    test "caps limit at 50" do
      result = Beam.callbacks()["beam_binary_leak"].(100)

      assert result.limit == 50
    end
  end

  describe "beam_binary_top_memory callback" do
    test "returns top binary memory consumers" do
      result = Beam.callbacks()["beam_binary_top_memory"].(10)

      assert is_integer(result.total_processes)
      assert is_integer(result.limit)
      assert is_list(result.processes)
    end

    test "respects limit parameter" do
      result = Beam.callbacks()["beam_binary_top_memory"].(5)

      assert result.limit == 5
    end

    test "caps limit at 50" do
      result = Beam.callbacks()["beam_binary_top_memory"].(100)

      assert result.limit == 50
    end
  end

  describe "beam_scheduler_utilization/1 callback" do
    test "returns scheduler utilization metrics" do
      result = Beam.callbacks()["beam_scheduler_utilization"].(100)

      assert is_list(result.schedulers)
      assert is_float(result.avg_utilization_pct)
      assert is_float(result.max_utilization_pct)
      assert is_float(result.min_utilization_pct)
      assert is_boolean(result.imbalanced)
    end

    test "returns per-scheduler data with ids" do
      result = Beam.callbacks()["beam_scheduler_utilization"].(100)

      Enum.each(result.schedulers, fn scheduler ->
        assert is_integer(scheduler.id)
        assert is_float(scheduler.utilization_pct)
        assert scheduler.utilization_pct >= 0.0
      end)
    end

    test "enforces minimum sample time" do
      result = Beam.callbacks()["beam_scheduler_utilization"].(10)

      assert is_list(result.schedulers)
    end
  end

  describe "beam_scheduler_capacity_available/0 callback" do
    test "returns boolean indicating capacity" do
      result = Beam.callbacks()["beam_scheduler_capacity_available"].()

      assert is_boolean(result)
    end
  end

  describe "beam_scheduler_health/0 callback" do
    test "returns health assessment" do
      result = Beam.callbacks()["beam_scheduler_health"].()

      assert result.status in [:healthy, :warning, :critical]
      assert is_float(result.avg_utilization_pct)
      assert is_float(result.max_utilization_pct)
      assert is_float(result.min_utilization_pct)
      assert is_float(result.imbalance_factor)
      assert is_boolean(result.imbalanced)
      assert is_list(result.recommendations)
    end

    test "recommendations are non-empty strings" do
      result = Beam.callbacks()["beam_scheduler_health"].()

      Enum.each(result.recommendations, fn recommendation ->
        assert is_binary(recommendation)
        assert String.length(recommendation) > 0
      end)
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
      assert docs =~ "beam_binary_leak"
      assert docs =~ "beam_binary_top_memory"
      assert docs =~ "beam_scheduler_utilization"
      assert docs =~ "beam_scheduler_capacity_available"
      assert docs =~ "beam_scheduler_health"
    end
  end
end
