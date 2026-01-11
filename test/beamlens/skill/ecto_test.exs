defmodule Beamlens.Skill.EctoTest do
  @moduledoc false

  use ExUnit.Case, async: false

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
    start_supervised!({TelemetryStore, repo: FakeRepo})
    :ok
  end

  describe "id/0" do
    test "returns :ecto" do
      assert TestEctoDomain.id() == :ecto
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
end
