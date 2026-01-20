defmodule Beamlens.Skill do
  @moduledoc """
  Behavior for defining monitoring skills.

  Each skill provides metrics for a specific area (BEAM VM, database, etc.)
  and sandbox callbacks for LLM-driven investigation.

  ## Required Callbacks

  - `title/0` - Returns a human-readable title for UI display (e.g., "BEAM VM")
  - `description/0` - Returns a brief (1-line) summary for the Coordinator
  - `system_prompt/0` - Returns the operator's identity and monitoring focus
  - `snapshot/0` - Returns high-level metrics for quick health assessment
  - `callbacks/0` - Returns the Lua sandbox callback map for investigation
  - `callback_docs/0` - Returns markdown documentation for callbacks

  The module itself is the skill identifier - no separate `id/0` callback needed.

  ## Configuration

  Register your custom skill in your application's supervision tree:

      children = [
        {Beamlens, skills: [
          Beamlens.Skill.Beam,  # built-in skill
          MyApp.Skills.Redis    # custom skill
        ]}
      ]

  If no skills are specified, all built-in skills are started by default.

  ## Callback Naming Conventions

  Prefix callback names with your skill identifier to avoid collisions:

      # Good - prefixed with skill name
      %{
        "redis_get_info" => &get_info/0,
        "redis_top_keys" => &top_keys/1
      }

      # Avoid - generic names may collide
      %{
        "get_info" => &get_info/0,
        "top_keys" => &top_keys/1
      }

  ## Return Type Requirements

  All callback return values and snapshot data must be JSON-serializable.

  **Supported types:**
  - Strings, integers, floats, booleans
  - Lists (arrays)
  - Maps with string or atom keys
  - `nil`

  **Not supported:**
  - Tuples (use lists instead)
  - PIDs, references, ports
  - Structs (convert to maps)
  - Functions

  ## Callback Arity Patterns

  Callbacks can accept 0, 1, or 2 arguments from Lua:

      %{
        # No arguments
        "redis_get_info" => fn -> get_info() end,

        # Single argument
        "redis_get_key" => fn key -> get_key(key) end,

        # Two arguments (limit, pattern)
        "redis_top_keys" => fn limit, pattern -> top_keys(limit, pattern) end
      }

  The LLM calls these via Lua code: `redis_top_keys(10, "user:*")`

  ## Writing Effective system_prompt

  The `system_prompt/0` defines the operator's identity and focus. It tells the
  LLM what domain it monitors and what anomalies to watch for:

      def system_prompt do
        \"\"\"
        You are a Redis cache monitor. You track cache health, memory usage,
        and key distribution patterns.

        ## Your Domain
        - Cache hit rates and efficiency
        - Memory usage and eviction pressure
        - Key distribution and hot spots
        - Connection pool health

        ## What to Watch For
        - Hit rate < 90%: cache may be ineffective
        - Memory usage > 80%: eviction pressure increasing
        - Hot keys with excessive access patterns
        - Connection count approaching limit
        \"\"\"
      end

  ## Writing Effective callback_docs

  The `callback_docs/0` string is passed directly to the LLM. Clear, example-rich
  documentation helps the LLM use your callbacks effectively:

      def callback_docs do
        \"\"\"
        ### redis_get_info()
        Returns Redis server information including memory usage, connected clients,
        and uptime.

        Example response:
        ```
        {memory_used_mb: 125.5, connected_clients: 42, uptime_seconds: 86400}
        ```

        ### redis_top_keys(limit, pattern)
        Returns the top N keys by memory usage matching the given pattern.

        Parameters:
        - limit: Number of keys to return (default: 10)
        - pattern: Glob pattern to filter keys (default: "*")

        Example: `redis_top_keys(5, "session:*")` returns top 5 session keys
        \"\"\"
      end

  ## Skills with Background Data Collection

  If your skill needs to collect data over time (like log aggregation), you'll
  need a background process. See `Beamlens.Skill.Logger` for an example pattern
  using a GenServer store.

  Key pattern:
  1. Create a GenServer to collect/store data (e.g., `MyApp.Skills.Redis.Store`)
  2. Start it in your application's supervision tree
  3. Have callbacks query the store

  ## Complete Example

      defmodule MyApp.Skills.Redis do
        @behaviour Beamlens.Skill

        @impl true
        def title, do: "Redis Cache"

        @impl true
        def description, do: "Redis cache: hit rates, memory, key distribution"

        @impl true
        def system_prompt do
          \"\"\"
          You are a Redis cache monitor. You track cache health, memory usage,
          and key distribution patterns.

          ## Your Domain
          - Cache hit rates and efficiency
          - Memory usage and eviction pressure
          - Key distribution and hot spots

          ## What to Watch For
          - Hit rate < 90%: cache may be ineffective
          - Memory usage > 80%: eviction pressure increasing
          - Hot keys with excessive access patterns
          \"\"\"
        end

        @impl true
        def snapshot do
          case Redix.command(:redix, ["INFO"]) do
            {:ok, info} ->
              parsed = parse_redis_info(info)
              %{
                memory_used_mb: parsed.used_memory / 1_000_000,
                connected_clients: parsed.connected_clients,
                ops_per_sec: parsed.instantaneous_ops_per_sec,
                hit_rate_pct: calculate_hit_rate(parsed)
              }

            {:error, _} ->
              %{error: "Redis connection failed"}
          end
        end

        @impl true
        def callbacks do
          %{
            "redis_get_info" => fn -> get_info() end,
            "redis_slow_log" => fn count -> slow_log(count) end,
            "redis_top_keys" => fn limit, pattern -> top_keys(limit, pattern) end
          }
        end

        @impl true
        def callback_docs do
          \"\"\"
          ### redis_get_info()
          Full Redis INFO output as a map.

          ### redis_slow_log(count)
          Returns the N most recent slow queries from Redis SLOWLOG.
          - count: Number of entries (default: 10)

          ### redis_top_keys(limit, pattern)
          Scans for keys matching pattern and returns top N by memory.
          - limit: Max keys to return
          - pattern: Glob pattern (e.g., "user:*", "cache:*")

          Note: Uses SCAN, safe for production but may be slow on large datasets.
          \"\"\"
        end

        defp get_info do
          # Implementation
        end

        defp slow_log(count) do
          # Implementation
        end

        defp top_keys(limit, pattern) do
          # Implementation
        end
      end
  """

  @callback title() :: String.t()
  @callback description() :: String.t()
  @callback system_prompt() :: String.t()
  @callback snapshot() :: map()
  @callback callbacks() :: map()
  @callback callback_docs() :: String.t()
end
