defmodule Beamlens.Skill.Ecto do
  @moduledoc """
  Ecto database monitoring skill.

  > #### Experimental {: .warning}
  >
  > This skill is experimental. The API may change in future releases.

  Monitors query performance, connection pool health, and database-specific
  insights. Requires configuration with a Repo module.

  ## Usage

  Define a skill module for your Repo:

      defmodule MyApp.EctoSkill do
        use Beamlens.Skill.Ecto, repo: MyApp.Repo
      end

  Then configure in your supervision tree:

      children = [
        {Beamlens, skills: [:beam, MyApp.EctoSkill]}
      ]

  ## PII Safety

  Query text from pg_stat_statements uses parameterized SQL ($1, $2 placeholders).
  Functions querying pg_stat_activity (locks, long_running) exclude query text entirely.

  ## PostgreSQL Features

  With `{:ecto_psql_extras, "~> 0.8"}` installed, additional callbacks
  are available for index analysis, cache hit ratios, locks, and bloat.
  """

  alias Beamlens.Skill.Ecto.Adapters.{Generic, Postgres}
  alias Beamlens.Skill.Ecto.TelemetryStore

  defmacro __using__(opts) do
    ecto_module = __MODULE__

    quote bind_quoted: [opts: opts, ecto_module: ecto_module] do
      @behaviour Beamlens.Skill

      @repo Keyword.fetch!(opts, :repo)
      @ecto_module ecto_module

      @impl true
      def title do
        @ecto_module.title()
      end

      @impl true
      def description do
        @ecto_module.description()
      end

      @impl true
      def system_prompt do
        @ecto_module.system_prompt()
      end

      @impl true
      def snapshot do
        @ecto_module.snapshot(@repo)
      end

      @impl true
      def callbacks do
        @ecto_module.callbacks(@repo)
      end

      @impl true
      def callback_docs do
        @ecto_module.callback_docs()
      end
    end
  end

  def title, do: "Database"

  def description, do: "Database: query performance, connection pool, slow queries"

  def system_prompt do
    """
    You are a database performance analyst. You monitor Ecto query performance,
    connection pool health, and database-specific metrics.

    ## Your Domain
    - Query performance (execution time, slow queries)
    - Connection pool utilization and contention
    - Index usage and efficiency
    - Cache hit ratios
    - Database locks and long-running queries

    ## What to Watch For
    - Average query time spikes
    - High p95 query times indicating outliers
    - Pool contention (queue times increasing)
    - Unused indexes wasting space
    - Low cache hit ratios
    - Blocking locks or long-running transactions
    """
  end

  def snapshot(repo) do
    stats = TelemetryStore.query_stats(repo)

    %{
      query_count_1m: stats.query_count,
      avg_query_time_ms: stats.avg_time_ms,
      max_query_time_ms: stats.max_time_ms,
      p95_query_time_ms: stats.p95_time_ms,
      slow_query_count: stats.slow_count,
      error_count: stats.error_count
    }
  end

  def callbacks(repo) do
    adapter = detect_adapter(repo)

    %{
      "ecto_query_stats" => fn -> TelemetryStore.query_stats(repo) end,
      "ecto_slow_queries" => fn limit -> TelemetryStore.slow_queries(repo, limit) end,
      "ecto_pool_stats" => fn -> TelemetryStore.pool_stats(repo) end,
      "ecto_db_slow_queries" => fn limit -> adapter.slow_queries(repo, limit) end,
      "ecto_index_usage" => fn -> adapter.index_usage(repo) end,
      "ecto_unused_indexes" => fn -> adapter.unused_indexes(repo) end,
      "ecto_table_sizes" => fn limit -> adapter.table_sizes(repo, limit) end,
      "ecto_cache_hit" => fn -> adapter.cache_hit(repo) end,
      "ecto_locks" => fn -> adapter.locks(repo) end,
      "ecto_long_running" => fn -> adapter.long_running_queries(repo) end,
      "ecto_bloat" => fn limit -> adapter.bloat(repo, limit) end,
      "ecto_connections" => fn -> adapter.connections(repo) end
    }
  end

  def callback_docs do
    """
    ### ecto_query_stats()
    Query statistics from telemetry: query_count, avg_time_ms, max_time_ms, p95_time_ms, slow_count, error_count

    ### ecto_slow_queries(limit)
    Recent slow queries from telemetry: source, total_time_ms, query_time_ms, queue_time_ms, result

    ### ecto_pool_stats()
    Connection pool health: avg_queue_time_ms, max_queue_time_ms, p95_queue_time_ms, high_contention_count

    ### ecto_db_slow_queries(limit)
    Slow queries from pg_stat_statements with parameterized SQL (no PII). Returns raw columns from ecto_psql_extras (no renaming).

    ### ecto_index_usage()
    Index scan statistics (PostgreSQL). Returns raw columns from ecto_psql_extras (no renaming).

    ### ecto_unused_indexes()
    Indexes with zero scans (PostgreSQL). Returns raw columns from ecto_psql_extras (no renaming).

    ### ecto_table_sizes(limit)
    Table sizes (PostgreSQL). Returns raw columns from ecto_psql_extras (no renaming).

    ### ecto_cache_hit()
    Buffer cache hit ratios (PostgreSQL). Returns raw columns from ecto_psql_extras (no renaming).

    ### ecto_locks()
    Active database locks (PostgreSQL). Returns raw columns from ecto_psql_extras (no renaming), query text excluded for PII safety.

    ### ecto_long_running()
    Long-running queries (PostgreSQL). Returns raw columns from ecto_psql_extras (no renaming), query text excluded for PII safety.

    ### ecto_bloat(limit)
    Table/index bloat (PostgreSQL). Returns raw columns from ecto_psql_extras (no renaming).

    ### ecto_connections()
    Database connections (PostgreSQL). Returns raw columns from ecto_psql_extras (no renaming).
    """
  end

  defp detect_adapter(repo) do
    if postgres_repo?(repo) and Postgres.available?() do
      Postgres
    else
      Generic
    end
  end

  defp postgres_repo?(repo) do
    case repo.__adapter__() do
      Ecto.Adapters.Postgres -> true
      _ -> false
    end
  end
end
