defmodule Beamlens.Skill.Ecto.Global do
  @moduledoc """
  Database-wide Ecto monitoring skill.

  Monitors database-level metrics that are the same regardless of which node
  queries them: indexes, locks, bloat, slow queries from pg_stat_statements.
  Run as a cluster singleton to avoid duplicate monitoring.

  ## Usage

  Define a skill module for your Repo:

      defmodule MyApp.EctoGlobalSkill do
        use Beamlens.Skill.Ecto.Global, repo: MyApp.Repo
      end

  ## Clustered Deployment (Recommended)

  Wrap in Highlander to run as a singleton across the cluster:

      children = [
        {Highlander,
          {Beamlens.Operator, skill: MyApp.EctoGlobalSkill, client_registry: client_registry()}}
      ]

  Or use with Oban for scheduled monitoring:

      defmodule MyApp.EctoGlobalWorker do
        use Oban.Worker, queue: :monitoring, unique: [period: 300]

        def perform(_job) do
          Beamlens.Operator.run_once(MyApp.EctoGlobalSkill, client_registry())
        end
      end

  ## PostgreSQL Features

  With `{:ecto_psql_extras, "~> 0.8\"}` installed, additional callbacks
  are available for index analysis, cache hit ratios, locks, and bloat.

  ## PII Safety

  Query text from pg_stat_statements uses parameterized SQL ($1, $2 placeholders).
  Functions querying pg_stat_activity (locks, long_running) exclude query text entirely.
  """

  alias Beamlens.Skill.Ecto.Adapters.{Generic, Postgres}

  defmacro __using__(opts) do
    ecto_global_module = __MODULE__

    quote bind_quoted: [opts: opts, ecto_global_module: ecto_global_module] do
      @behaviour Beamlens.Skill

      @repo Keyword.fetch!(opts, :repo)
      @ecto_global_module ecto_global_module

      @impl true
      def id, do: :ecto_global

      @impl true
      def description do
        @ecto_global_module.description()
      end

      @impl true
      def system_prompt do
        @ecto_global_module.system_prompt()
      end

      @impl true
      def snapshot do
        @ecto_global_module.snapshot(@repo)
      end

      @impl true
      def callbacks do
        @ecto_global_module.callbacks(@repo)
      end

      @impl true
      def callback_docs do
        @ecto_global_module.callback_docs()
      end
    end
  end

  def description, do: "Database (global): indexes, locks, bloat, slow queries"

  def system_prompt do
    """
    You are monitoring database-wide metrics that are consistent across all nodes.
    Your queries go directly to the database for system-level insights.

    ## Your Domain
    - Index usage and unused indexes
    - Table and index bloat
    - Database locks and long-running queries
    - Cache hit ratios
    - Slow queries from pg_stat_statements

    ## What to Watch For
    - Unused indexes wasting space and slowing writes
    - High bloat ratios indicating need for VACUUM
    - Blocking locks causing contention
    - Low cache hit ratios indicating memory pressure
    - Slow query patterns from pg_stat_statements

    ## Important Context
    - You run as a singleton - only one instance cluster-wide
    - Your metrics are database-wide, not node-specific
    - For per-node connection pool metrics, use the local Ecto skill
    """
  end

  def snapshot(repo) do
    adapter = detect_adapter(repo)

    %{
      cache_hit: adapter.cache_hit(repo),
      connections: adapter.connections(repo)
    }
  end

  def callbacks(repo) do
    adapter = detect_adapter(repo)

    %{
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
    ### ecto_db_slow_queries(limit)
    Slow queries from pg_stat_statements with parameterized SQL (no PII): query, avg_time_ms, call_count, total_time_ms

    ### ecto_index_usage()
    Index scan statistics (PostgreSQL): table, index, index_scans, size

    ### ecto_unused_indexes()
    Indexes with zero scans (PostgreSQL): table, index, size

    ### ecto_table_sizes(limit)
    Table sizes (PostgreSQL): table, row_count, size, index_size, total_size

    ### ecto_cache_hit()
    Buffer cache hit ratios (PostgreSQL): table_hit_ratio, index_hit_ratio

    ### ecto_locks()
    Active database locks (PostgreSQL): relation, mode, granted, pid

    ### ecto_long_running()
    Long-running queries (PostgreSQL): pid, duration, state (query text excluded for PII safety)

    ### ecto_bloat(limit)
    Table/index bloat (PostgreSQL): table, bloat_ratio, waste, dead_tuples

    ### ecto_connections()
    Database connections (PostgreSQL): active, idle, waiting, total
    """
  end

  @doc false
  def detect_adapter(repo) do
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
