defmodule Beamlens.Skill.Ecto.Local do
  @moduledoc """
  Node-local Ecto monitoring skill.

  > #### Experimental {: .warning}
  >
  > This skill is experimental. The API may change in future releases.

  Monitors connection pool health and query performance using telemetry data
  collected on this node. Each node in a cluster should run its own instance
  of this skill.

  ## Usage

  Define a skill module for your Repo:

      defmodule MyApp.EctoLocalSkill do
        use Beamlens.Skill.Ecto.Local, repo: MyApp.Repo
      end

  Then configure in your supervision tree:

      children = [
        {Beamlens, skills: [:beam, MyApp.EctoLocalSkill]}
      ]

  ## Clustered Deployment

  In a cluster, run this skill on every node alongside the BEAM and other
  per-node skills:

      children = [
        {Beamlens.Operator, skill: MyApp.EctoLocalSkill, client_registry: client_registry()}
      ]

  For database-wide metrics (indexes, locks, bloat), use `Beamlens.Skill.Ecto.Global`
  as a cluster singleton instead.

  ## Metrics Monitored

  - Query count and timing (avg, max, p95)
  - Slow query detection
  - Connection pool queue times
  - Pool contention indicators
  """

  alias Beamlens.Skill.Ecto.TelemetryStore

  defmacro __using__(opts) do
    ecto_local_module = __MODULE__

    quote bind_quoted: [opts: opts, ecto_local_module: ecto_local_module] do
      @behaviour Beamlens.Skill

      @repo Keyword.fetch!(opts, :repo)
      @ecto_local_module ecto_local_module

      @impl true
      def id, do: :ecto_local

      @impl true
      def description do
        @ecto_local_module.description()
      end

      @impl true
      def system_prompt do
        @ecto_local_module.system_prompt()
      end

      @impl true
      def snapshot do
        @ecto_local_module.snapshot(@repo)
      end

      @impl true
      def callbacks do
        @ecto_local_module.callbacks(@repo)
      end

      @impl true
      def callback_docs do
        @ecto_local_module.callback_docs()
      end
    end
  end

  def description, do: "Database (local): connection pool, query performance"

  def system_prompt do
    """
    You are monitoring the local database connection pool and query performance
    for this node. Your metrics come from telemetry events on this specific node.

    ## Your Domain
    - Query performance from this node's perspective
    - Connection pool utilization and contention
    - Queue times indicating pool pressure

    ## What to Watch For
    - Rising average query times
    - High p95 times indicating outlier slow queries
    - Pool queue time spikes (connection contention)
    - Error rate increases

    ## Important Context
    - Your metrics are node-local, not cluster-wide
    - Pool stats reflect this node's connections only
    - Query stats reflect queries executed from this node
    - For database-wide metrics (indexes, locks), use the global Ecto skill
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
    %{
      "ecto_query_stats" => fn -> TelemetryStore.query_stats(repo) end,
      "ecto_slow_queries" => fn limit -> TelemetryStore.slow_queries(repo, limit) end,
      "ecto_pool_stats" => fn -> TelemetryStore.pool_stats(repo) end
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
    """
  end
end
