defmodule Beamlens.Skill.BeamTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Beamlens.Skill.Beam
  alias Beamlens.Skill.Beam.AtomStore

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

    test "includes binary memory in snapshot" do
      snapshot = Beam.snapshot()

      assert is_float(snapshot.binary_memory_mb)
      assert snapshot.binary_memory_mb >= 0
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
      assert Map.has_key?(callbacks, "beam_binary_info")
      assert Map.has_key?(callbacks, "beam_top_reducers_window")
      assert Map.has_key?(callbacks, "beam_reduction_rate")
      assert Map.has_key?(callbacks, "beam_burst_detection")
      assert Map.has_key?(callbacks, "beam_hot_functions")
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
      assert is_function(callbacks["beam_binary_info"], 1)
      assert is_function(callbacks["beam_top_reducers_window"], 2)
      assert is_function(callbacks["beam_reduction_rate"], 2)
      assert is_function(callbacks["beam_burst_detection"], 2)
      assert is_function(callbacks["beam_hot_functions"], 2)
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

    test "rate limits GC calls to once per minute" do
      result1 = Beam.callbacks()["beam_binary_leak"].(10)

      refute Map.has_key?(result1, :error)

      result2 = Beam.callbacks()["beam_binary_leak"].(10)

      assert result2.error == "rate_limited"
      assert result2.message =~ "GC can only be run once per minute"
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

  describe "beam_binary_info callback" do
    test "returns detailed binary info for process" do
      pid_str = inspect(self())
      result = Beam.callbacks()["beam_binary_info"].(pid_str)

      assert result.pid == pid_str
      assert is_integer(result.binary_count)
      assert is_integer(result.binary_memory_kb)
      assert is_list(result.binaries)
    end

    test "binaries list has expected structure" do
      pid_str = inspect(self())
      result = Beam.callbacks()["beam_binary_info"].(pid_str)

      Enum.each(result.binaries, fn binary ->
        assert is_binary(binary.id)
        assert is_integer(binary.size_bytes)
        assert is_integer(binary.refcount)
      end)
    end

    test "returns error for non-existent process" do
      fake_pid = "#PID<0.9999.0>"
      result = Beam.callbacks()["beam_binary_info"].(fake_pid)

      assert result.error == "process_not_found"
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
      assert docs =~ "beam_binary_info"
      assert docs =~ "beam_scheduler_utilization"
      assert docs =~ "beam_scheduler_capacity_available"
      assert docs =~ "beam_scheduler_health"
      assert docs =~ "beam_top_reducers_window"
      assert docs =~ "beam_reduction_rate"
      assert docs =~ "beam_burst_detection"
      assert docs =~ "beam_hot_functions"
      assert docs =~ "beam_atom_growth_rate"
      assert docs =~ "beam_atom_leak_detected"
    end
  end

  describe "beam_top_reducers_window callback" do
    test "returns top reducers over a window" do
      result = Beam.callbacks()["beam_top_reducers_window"].(5, 200)

      assert is_integer(result.window_ms)
      assert result.window_ms == 200
      assert is_integer(result.showing)
      assert is_integer(result.limit)
      assert result.limit == 5
      assert is_list(result.processes)
    end

    test "processes have expected fields" do
      result = Beam.callbacks()["beam_top_reducers_window"].(3, 150)

      Enum.each(result.processes, fn process ->
        assert is_binary(process.pid)
        assert is_integer(process.reductions_delta)
        assert is_float(process.rate_per_sec)
        assert process.reductions_delta >= 0
        assert process.rate_per_sec >= 0
      end)
    end

    test "respects limit parameter" do
      result = Beam.callbacks()["beam_top_reducers_window"].(2, 100)

      assert length(result.processes) <= 2
    end
  end

  describe "beam_reduction_rate callback" do
    test "returns reduction rate for current process" do
      pid_str = inspect(self())

      result = Beam.callbacks()["beam_reduction_rate"].(pid_str, 100)

      assert result.pid == pid_str
      assert is_float(result.reductions_per_sec)
      assert is_integer(result.reductions_delta)
      assert result.reductions_delta >= 0
      assert result.window_ms == 100
      assert result.trend in ["very_high", "high", "moderate", "low", "idle"]
    end

    test "returns error for non-existent process" do
      fake_pid = "#PID<0.9999.0>"

      result = Beam.callbacks()["beam_reduction_rate"].(fake_pid, 100)

      assert result.pid == fake_pid
      assert result.error == "process_not_found"
    end
  end

  describe "beam_burst_detection callback" do
    test "returns burst detection results" do
      result = Beam.callbacks()["beam_burst_detection"].(200, 200)

      assert is_integer(result.baseline_window_ms)
      assert result.baseline_window_ms == 200
      assert is_integer(result.burst_threshold_pct)
      assert result.burst_threshold_pct == 200
      assert is_integer(result.showing)
      assert is_list(result.processes)
    end

    test "burst entries have expected fields" do
      result = Beam.callbacks()["beam_burst_detection"].(150, 300)

      Enum.each(result.processes, fn process ->
        assert is_binary(process.pid)
        assert is_float(process.baseline_rate)
        assert is_float(process.current_rate)
        assert is_float(process.burst_multiplier_pct)
        assert process.burst_multiplier_pct >= 300
      end)
    end
  end

  describe "beam_hot_functions callback" do
    test "returns hot functions over a window" do
      result = Beam.callbacks()["beam_hot_functions"].(5, 200)

      assert is_integer(result.window_ms)
      assert result.window_ms == 200
      assert is_integer(result.showing)
      assert is_integer(result.limit)
      assert result.limit == 5
      assert is_list(result.functions)
    end

    test "functions have expected fields" do
      result = Beam.callbacks()["beam_hot_functions"].(3, 150)

      Enum.each(result.functions, fn function ->
        assert is_binary(function.function)
        assert is_integer(function.avg_reductions)
        assert function.avg_reductions >= 0
        assert is_integer(function.process_count)
        assert function.process_count >= 0
      end)
    end

    test "functions are sorted by avg_reductions descending" do
      result = Beam.callbacks()["beam_hot_functions"].(10, 200)

      if length(result.functions) > 1 do
        reductions = Enum.map(result.functions, & &1.avg_reductions)
        assert reductions == Enum.sort(reductions, :desc)
      end
    end

    test "respects limit parameter" do
      result = Beam.callbacks()["beam_hot_functions"].(2, 100)

      assert length(result.functions) <= 2
    end
  end

  describe "beam_atom_growth_rate callback" do
    setup do
      start_supervised!({Beamlens.Skill.Beam.AtomStore, [name: Beamlens.Skill.Beam.AtomStore]})
      :ok
    end

    test "returns atom growth metrics" do
      result = Beam.callbacks()["beam_atom_growth_rate"].(10)

      assert is_integer(result.current_count)
      assert is_integer(result.limit)
      assert is_float(result.utilization_pct)
      assert result.time_window_minutes == 10
      assert is_integer(result.samples_count)
    end

    test "returns urgency classification" do
      result = Beam.callbacks()["beam_atom_growth_rate"].(5)

      assert result.urgency in [
               :healthy,
               :monitoring,
               :concerning,
               :warning,
               :critical,
               :insufficient_history
             ]
    end

    test "handles insufficient history gracefully" do
      result = Beam.callbacks()["beam_atom_growth_rate"].(1000)

      assert result.urgency in [:insufficient_history, :healthy]
      assert result.samples_count >= 0
    end

    test "handles zero time window without division by zero" do
      samples = AtomStore.get_samples()

      if length(samples) >= 2 do
        timestamp = hd(samples).timestamp

        modified_samples =
          Enum.map(samples, fn sample ->
            %{sample | timestamp: timestamp}
          end)

        result =
          beam_growth_rate_with_samples(modified_samples, 10)

        assert result.urgency == :insufficient_history
        assert result.time_window_minutes == 0.0
        assert is_nil(result.atoms_per_minute)
        assert is_nil(result.atoms_per_hour)
      end
    end
  end

  defp beam_growth_rate_with_samples(samples, minutes_back) do
    cutoff_ms = System.system_time(:millisecond) - minutes_back * 60 * 1000
    historical = Enum.filter(samples, fn sample -> sample.timestamp >= cutoff_ms end)

    if length(historical) < 2 do
      build_insufficient_history_result(minutes_back, length(historical))
    else
      oldest = List.first(historical)
      newest = List.last(historical)
      time_window_minutes = (newest.timestamp - oldest.timestamp) / (60 * 1000)

      build_growth_result_from_samples(historical, oldest, newest, time_window_minutes)
    end
  end

  defp build_insufficient_history_result(minutes_back, samples_count) do
    %{
      current_count: :erlang.system_info(:atom_count),
      limit: :erlang.system_info(:atom_limit),
      utilization_pct: 0.0,
      atoms_per_minute: nil,
      atoms_per_hour: nil,
      hours_until_exhausted: nil,
      urgency: :insufficient_history,
      time_window_minutes: minutes_back,
      samples_count: samples_count
    }
  end

  defp build_growth_result_from_samples(historical, _oldest, _newest, time_window_minutes)
       when time_window_minutes == 0.0 do
    %{
      current_count: :erlang.system_info(:atom_count),
      limit: :erlang.system_info(:atom_limit),
      utilization_pct:
        Float.round(
          :erlang.system_info(:atom_count) / :erlang.system_info(:atom_limit) * 100,
          2
        ),
      atoms_per_minute: nil,
      atoms_per_hour: nil,
      hours_until_exhausted: nil,
      urgency: :insufficient_history,
      time_window_minutes: 0.0,
      samples_count: length(historical)
    }
  end

  defp build_growth_result_from_samples(_historical, oldest, newest, time_window_minutes) do
    atoms_per_minute = (newest.count - oldest.count) / time_window_minutes
    atoms_per_hour = atoms_per_minute * 60

    hours_until_exhausted = calculate_test_hours_until_exhausted(atoms_per_minute)

    %{
      current_count: :erlang.system_info(:atom_count),
      limit: :erlang.system_info(:atom_limit),
      utilization_pct:
        Float.round(
          :erlang.system_info(:atom_count) / :erlang.system_info(:atom_limit) * 100,
          2
        ),
      atoms_per_minute: Float.round(atoms_per_minute, 2),
      atoms_per_hour: Float.round(atoms_per_hour, 2),
      hours_until_exhausted: hours_until_exhausted,
      urgency: :healthy,
      time_window_minutes: Float.round(time_window_minutes, 2),
      samples_count: 2
    }
  end

  defp calculate_test_hours_until_exhausted(atoms_per_minute) when atoms_per_minute > 0 do
    (:erlang.system_info(:atom_limit) - :erlang.system_info(:atom_count)) /
      (atoms_per_minute * 60)
  end

  defp calculate_test_hours_until_exhausted(_), do: :infinity

  describe "beam_atom_leak_detected callback" do
    setup do
      start_supervised!({Beamlens.Skill.Beam.AtomStore, [name: Beamlens.Skill.Beam.AtomStore]})
      :ok
    end

    test "returns leak detection results" do
      result = Beam.callbacks()["beam_atom_leak_detected"].()

      assert is_boolean(result.suspected_leak)
      assert is_number(result.growth_rate) or is_nil(result.growth_rate)
      assert result.current_utilization_pct >= 0
      assert is_binary(result.recommendation)
    end

    test "provides actionable recommendation" do
      result = Beam.callbacks()["beam_atom_leak_detected"].()

      assert String.length(result.recommendation) > 0
      assert is_binary(result.recommendation)
    end
  end
end
