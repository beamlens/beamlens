defmodule Beamlens.Skill.EctoTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Beamlens.EctoTestHelper

  alias Beamlens.Skill.Ecto.TelemetryStore

  defmodule FakeRepo do
    def config, do: [telemetry_prefix: [:test, :ecto_domain]]
    def __adapter__, do: Ecto.Adapters.Postgres
  end

  defmodule TestEctoDomain do
    use Beamlens.Skill.Ecto, repo: FakeRepo
  end

  setup do
    start_supervised!({Registry, keys: :unique, name: Beamlens.Skill.Ecto.Registry})
    start_supervised!({TelemetryStore, repo: FakeRepo, slow_threshold_ms: 100})
    :ok
  end

  describe "title/0" do
    test "returns a non-empty string" do
      title = TestEctoDomain.title()

      assert is_binary(title)
      assert String.length(title) > 0
    end
  end

  describe "snapshot/0" do
    test "returns snapshot with expected keys" do
      snapshot = TestEctoDomain.snapshot()

      assert Map.has_key?(snapshot, :query_count_1m)
      assert Map.has_key?(snapshot, :avg_query_time_ms)
      assert Map.has_key?(snapshot, :max_query_time_ms)
      assert Map.has_key?(snapshot, :p95_query_time_ms)
      assert Map.has_key?(snapshot, :slow_query_count)
      assert Map.has_key?(snapshot, :error_count)
    end

    test "returns zero values when no events" do
      snapshot = TestEctoDomain.snapshot()

      assert snapshot.query_count_1m == 0
      assert snapshot.avg_query_time_ms == 0.0
      assert snapshot.max_query_time_ms == 0.0
    end

    test "query_count_1m reflects injected count" do
      inject_query(FakeRepo, total_time_ms: 10)
      inject_query(FakeRepo, total_time_ms: 20)
      inject_query(FakeRepo, total_time_ms: 30)

      snapshot = TestEctoDomain.snapshot()

      assert snapshot.query_count_1m == 3
    end

    test "avg_query_time_ms reflects injected times" do
      inject_query(FakeRepo, total_time_ms: 10)
      inject_query(FakeRepo, total_time_ms: 20)
      inject_query(FakeRepo, total_time_ms: 30)

      snapshot = TestEctoDomain.snapshot()

      assert snapshot.avg_query_time_ms == 20.0
    end

    test "max_query_time_ms reflects slowest query" do
      inject_query(FakeRepo, total_time_ms: 10)
      inject_query(FakeRepo, total_time_ms: 50)
      inject_query(FakeRepo, total_time_ms: 30)

      snapshot = TestEctoDomain.snapshot()

      assert snapshot.max_query_time_ms == 50.0
    end

    test "slow_query_count reflects queries above threshold" do
      inject_query(FakeRepo, total_time_ms: 50)
      inject_query(FakeRepo, total_time_ms: 150)
      inject_query(FakeRepo, total_time_ms: 200)

      snapshot = TestEctoDomain.snapshot()

      assert snapshot.slow_query_count == 2
    end

    test "error_count reflects failed queries" do
      inject_query(FakeRepo, total_time_ms: 10)
      inject_error_query(FakeRepo, total_time_ms: 20)
      inject_error_query(FakeRepo, total_time_ms: 30)

      snapshot = TestEctoDomain.snapshot()

      assert snapshot.error_count == 2
    end
  end

  describe "callbacks/0" do
    test "returns callback map with all 12 expected keys" do
      callbacks = TestEctoDomain.callbacks()

      assert is_map(callbacks)
      assert Map.has_key?(callbacks, "ecto_query_stats")
      assert Map.has_key?(callbacks, "ecto_slow_queries")
      assert Map.has_key?(callbacks, "ecto_pool_stats")
      assert Map.has_key?(callbacks, "ecto_db_slow_queries")
      assert Map.has_key?(callbacks, "ecto_index_usage")
      assert Map.has_key?(callbacks, "ecto_unused_indexes")
      assert Map.has_key?(callbacks, "ecto_table_sizes")
      assert Map.has_key?(callbacks, "ecto_cache_hit")
      assert Map.has_key?(callbacks, "ecto_locks")
      assert Map.has_key?(callbacks, "ecto_long_running")
      assert Map.has_key?(callbacks, "ecto_bloat")
      assert Map.has_key?(callbacks, "ecto_connections")
    end

    test "callbacks are functions with correct arity" do
      callbacks = TestEctoDomain.callbacks()

      assert is_function(callbacks["ecto_query_stats"], 0)
      assert is_function(callbacks["ecto_slow_queries"], 1)
      assert is_function(callbacks["ecto_pool_stats"], 0)
      assert is_function(callbacks["ecto_db_slow_queries"], 1)
      assert is_function(callbacks["ecto_index_usage"], 0)
      assert is_function(callbacks["ecto_unused_indexes"], 0)
      assert is_function(callbacks["ecto_table_sizes"], 1)
      assert is_function(callbacks["ecto_cache_hit"], 0)
      assert is_function(callbacks["ecto_locks"], 0)
      assert is_function(callbacks["ecto_long_running"], 0)
      assert is_function(callbacks["ecto_bloat"], 1)
      assert is_function(callbacks["ecto_connections"], 0)
    end
  end

  describe "callback_docs/0" do
    test "returns non-empty string" do
      docs = TestEctoDomain.callback_docs()

      assert is_binary(docs)
      assert String.length(docs) > 0
    end

    test "documents all callbacks" do
      docs = TestEctoDomain.callback_docs()

      assert docs =~ "ecto_query_stats"
      assert docs =~ "ecto_slow_queries"
      assert docs =~ "ecto_pool_stats"
      assert docs =~ "ecto_db_slow_queries"
      assert docs =~ "ecto_index_usage"
      assert docs =~ "ecto_unused_indexes"
      assert docs =~ "ecto_table_sizes"
      assert docs =~ "ecto_cache_hit"
      assert docs =~ "ecto_locks"
      assert docs =~ "ecto_long_running"
      assert docs =~ "ecto_bloat"
      assert docs =~ "ecto_connections"
    end

    test "mentions PII safety for long_running" do
      docs = TestEctoDomain.callback_docs()

      assert docs =~ "query text excluded"
    end
  end

  describe "ecto_query_stats callback" do
    test "returns query statistics" do
      stats = TestEctoDomain.callbacks()["ecto_query_stats"].()

      assert Map.has_key?(stats, :query_count)
      assert Map.has_key?(stats, :avg_time_ms)
      assert Map.has_key?(stats, :max_time_ms)
      assert Map.has_key?(stats, :p95_time_ms)
      assert Map.has_key?(stats, :slow_count)
      assert Map.has_key?(stats, :error_count)
    end
  end

  describe "ecto_pool_stats callback" do
    test "returns pool statistics" do
      stats = TestEctoDomain.callbacks()["ecto_pool_stats"].()

      assert Map.has_key?(stats, :avg_queue_time_ms)
      assert Map.has_key?(stats, :max_queue_time_ms)
      assert Map.has_key?(stats, :p95_queue_time_ms)
      assert Map.has_key?(stats, :high_contention_count)
    end
  end

  describe "ecto_slow_queries callback" do
    test "returns slow queries result" do
      result = TestEctoDomain.callbacks()["ecto_slow_queries"].(10)

      assert Map.has_key?(result, :queries)
      assert Map.has_key?(result, :threshold_ms)
      assert is_list(result.queries)
    end
  end

  describe "callbacks with injected data" do
    test "ecto_query_stats returns counts matching injected queries" do
      inject_query(FakeRepo, total_time_ms: 10)
      inject_query(FakeRepo, total_time_ms: 20)
      inject_error_query(FakeRepo, total_time_ms: 30)

      stats = TestEctoDomain.callbacks()["ecto_query_stats"].()

      assert stats.query_count == 3
      assert stats.error_count == 1
      assert stats.avg_time_ms == 20.0
    end

    test "ecto_slow_queries returns queries sorted by time" do
      inject_slow_query(FakeRepo, total_time_ms: 150, source: "lib/app.ex:10")
      inject_slow_query(FakeRepo, total_time_ms: 300, source: "lib/app.ex:20")
      inject_slow_query(FakeRepo, total_time_ms: 200, source: "lib/app.ex:15")

      result = TestEctoDomain.callbacks()["ecto_slow_queries"].(10)

      assert length(result.queries) == 3
      [first, second, third] = result.queries
      assert first.total_time_ms == 300.0
      assert second.total_time_ms == 200.0
      assert third.total_time_ms == 150.0
    end

    test "ecto_slow_queries respects limit" do
      inject_slow_query(FakeRepo, total_time_ms: 150)
      inject_slow_query(FakeRepo, total_time_ms: 200)
      inject_slow_query(FakeRepo, total_time_ms: 250)

      result = TestEctoDomain.callbacks()["ecto_slow_queries"].(2)

      assert length(result.queries) == 2
    end

    test "ecto_pool_stats returns queue time stats" do
      inject_query(FakeRepo, total_time_ms: 10, queue_time_ms: 5)
      inject_query(FakeRepo, total_time_ms: 20, queue_time_ms: 10)
      inject_query(FakeRepo, total_time_ms: 30, queue_time_ms: 15)

      stats = TestEctoDomain.callbacks()["ecto_pool_stats"].()

      assert stats.avg_queue_time_ms == 10.0
      assert stats.max_queue_time_ms == 15.0
    end

    test "ecto_pool_stats returns high contention count" do
      inject_query(FakeRepo, total_time_ms: 10, queue_time_ms: 10)
      inject_query(FakeRepo, total_time_ms: 20, queue_time_ms: 60)
      inject_query(FakeRepo, total_time_ms: 30, queue_time_ms: 100)

      stats = TestEctoDomain.callbacks()["ecto_pool_stats"].()

      assert stats.high_contention_count == 2
    end
  end
end
