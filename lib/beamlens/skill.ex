defmodule Beamlens.Skill do
  @moduledoc """
  Behavior for defining monitoring skills.

  Each skill provides metrics for a specific area (BEAM VM, database, etc.)
  and sandbox callbacks for LLM-driven investigation.

  ## Required Callbacks

  - `id/0` - Returns the skill identifier atom (e.g., `:beam`)
  - `snapshot/0` - Returns high-level metrics for quick health assessment
  - `callbacks/0` - Returns the Lua sandbox callback map for investigation
  - `callback_docs/0` - Returns markdown documentation for callbacks

  ## Example

      defmodule MyApp.Skills.Database do
        @behaviour Beamlens.Skill

        @impl true
        def id, do: :database

        @impl true
        def snapshot do
          %{
            connection_pool_utilization_pct: 45.2,
            query_queue_length: 0,
            active_connections: 5
          }
        end

        @impl true
        def callbacks do
          %{
            "get_pool_stats" => &pool_stats/0,
            "get_slow_queries" => &slow_queries/0
          }
        end

        @impl true
        def callback_docs do
          \"\"\"
          ### get_pool_stats()
          Connection pool statistics: size, available, in_use

          ### get_slow_queries()
          Queries exceeding 100ms threshold
          \"\"\"
        end
      end
  """

  @callback id() :: atom()
  @callback snapshot() :: map()
  @callback callbacks() :: map()
  @callback callback_docs() :: String.t()
end
