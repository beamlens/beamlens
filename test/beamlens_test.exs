defmodule BeamlensTest do
  use ExUnit.Case

  describe "Beamlens.Collector.system_info/0" do
    test "returns expected structure" do
      info = Beamlens.Collector.system_info()

      assert is_binary(info.node)
      assert is_binary(info.otp_release)
      assert is_binary(info.elixir_version)
      assert is_integer(info.uptime_seconds)
      assert is_integer(info.schedulers_online)
      assert info.schedulers_online > 0
    end

    test "is read-only (no side effects)" do
      i1 = Beamlens.Collector.system_info()
      i2 = Beamlens.Collector.system_info()

      assert Map.keys(i1) == Map.keys(i2)
      assert i1.node == i2.node
      assert i1.otp_release == i2.otp_release
      assert i1.elixir_version == i2.elixir_version
      assert i1.schedulers_online == i2.schedulers_online
    end
  end

  describe "Beamlens.Collector.memory_stats/0" do
    test "returns expected structure" do
      stats = Beamlens.Collector.memory_stats()

      assert is_float(stats.total_mb)
      assert is_float(stats.processes_mb)
      assert is_float(stats.processes_used_mb)
      assert is_float(stats.system_mb)
      assert is_float(stats.binary_mb)
      assert is_float(stats.ets_mb)
      assert is_float(stats.code_mb)
    end
  end

  describe "Beamlens.Collector.process_stats/0" do
    test "returns expected structure" do
      stats = Beamlens.Collector.process_stats()

      assert is_integer(stats.process_count)
      assert is_integer(stats.process_limit)
      assert is_integer(stats.port_count)
      assert is_integer(stats.port_limit)
      assert stats.process_count > 0
      assert stats.process_limit > stats.process_count
    end
  end

  describe "Beamlens.Collector.scheduler_stats/0" do
    test "returns expected structure" do
      stats = Beamlens.Collector.scheduler_stats()

      assert is_integer(stats.schedulers)
      assert is_integer(stats.schedulers_online)
      assert is_integer(stats.dirty_cpu_schedulers_online)
      assert is_integer(stats.dirty_io_schedulers)
      assert is_integer(stats.run_queue)
      assert stats.schedulers >= stats.schedulers_online
    end
  end

  describe "Beamlens.Collector.atom_stats/0" do
    test "returns expected structure" do
      stats = Beamlens.Collector.atom_stats()

      assert is_integer(stats.atom_count)
      assert is_integer(stats.atom_limit)
      assert is_float(stats.atom_mb)
      assert is_float(stats.atom_used_mb)
      assert stats.atom_count > 0
      assert stats.atom_limit > stats.atom_count
    end
  end

  describe "Beamlens.Collector.persistent_terms/0" do
    test "returns expected structure" do
      stats = Beamlens.Collector.persistent_terms()

      assert is_integer(stats.count)
      assert is_float(stats.memory_mb)
      assert stats.count >= 0
    end
  end
end
