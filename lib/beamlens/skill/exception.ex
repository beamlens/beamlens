if Code.ensure_loaded?(Tower) do
  defmodule Beamlens.Skill.Exception do
    @moduledoc """
    Application exception monitoring skill.

    > #### Experimental {: .warning}
    >
    > This skill is experimental. The API may change in future releases.

    Captures and analyzes exceptions via Tower's reporter system
    to help identify error patterns, exception types, and crash investigations.

    Requires Tower to be installed and configured:

        # In mix.exs deps
        {:tower, "~> 0.8.6"}

        # In config/config.exs
        config :tower,
          reporters: [Beamlens.Skill.Exception.ExceptionStore]

    ## Usage

        {Beamlens, skills: [:beam, :exception]}

    ## Sensitive Data

    This skill captures exception messages and stacktraces which may contain
    sensitive data (file paths, variable values, etc.). Ensure your exception
    handling does not expose PII before enabling this operator.

    All functions are read-only with zero side effects.
    """

    @behaviour Beamlens.Skill

    alias Beamlens.Skill.Exception.ExceptionStore

    @impl true
    def title, do: "Exceptions"

    @impl true
    def description, do: "Exceptions: error types, crash patterns, stacktraces"

    @impl true
    def system_prompt do
      """
      You are an exception analyst. You monitor application exceptions and crashes
      to detect error patterns, recurring issues, and system instability.

      ## Your Domain
      - Exception types and frequencies
      - Error vs exit vs throw distribution
      - Stacktrace analysis
      - Exception message patterns

      ## What to Watch For
      - Sudden spike in exception rate
      - New exception types appearing
      - Repeated exceptions from same location
      - Exit signals indicating process crashes
      - Exceptions correlating with specific operations
      """
    end

    @doc """
    High-level exception statistics for quick health assessment.

    Returns a map with:
    - `:total_exceptions_5m` - Total exceptions in the 5-minute window
    - `:by_kind` - Map of counts by exception kind (`:error`, `:exit`, `:throw`, `:message`)
    - `:by_level` - Map of counts by log level
    - `:top_exception_types` - List of maps, each with `:type` (string) and `:count` (integer)
    - `:unique_exception_types` - Count of distinct exception types
    """
    @impl true
    def snapshot do
      stats = ExceptionStore.get_stats()

      top_types =
        Enum.map(stats.top_types, fn {type, count} ->
          %{type: type, count: count}
        end)

      %{
        total_exceptions_5m: stats.total_count,
        by_kind: stats.by_kind,
        by_level: stats.by_level,
        top_exception_types: top_types,
        unique_exception_types: stats.type_count
      }
    end

    @doc """
    Returns the Lua sandbox callback map for exception analysis.

    These functions are registered with Puck.Sandbox.Eval and can be
    called from LLM-generated Lua code.
    """
    @impl true
    def callbacks do
      %{
        "exception_stats" => fn -> ExceptionStore.get_stats() end,
        "exception_recent" => &recent_exceptions/2,
        "exception_by_type" => &exceptions_by_type/2,
        "exception_search" => &search_exceptions/2,
        "exception_stacktrace" => &get_stacktrace/1
      }
    end

    @impl true
    def callback_docs do
      """
      ### exception_stats()
      Exception statistics: total_count, by_kind, by_level, top_types, type_count

      ### exception_recent(limit, kind)
      Recent exceptions. Kind: "error", "exit", "throw", or nil for all.
      Returns: id, datetime, kind, level, type, message (truncated)

      ### exception_by_type(exception_type, limit)
      Exceptions matching the given type name (e.g., "ArgumentError")

      ### exception_search(pattern, limit)
      Search exception messages by regex pattern

      ### exception_stacktrace(exception_id)
      Get full stacktrace for a specific exception by ID
      """
    end

    defp recent_exceptions(limit, kind) when is_number(limit) do
      kind_opt = if is_binary(kind) and kind != "", do: kind, else: nil
      ExceptionStore.get_exceptions(ExceptionStore, kind: kind_opt, limit: limit)
    end

    defp exceptions_by_type(exception_type, limit)
         when is_binary(exception_type) and is_number(limit) do
      ExceptionStore.get_by_type(ExceptionStore, exception_type, limit)
    end

    defp search_exceptions(pattern, limit) when is_binary(pattern) and is_number(limit) do
      ExceptionStore.search(ExceptionStore, pattern, limit: limit)
    end

    defp get_stacktrace(exception_id) when is_binary(exception_id) do
      ExceptionStore.get_stacktrace(ExceptionStore, exception_id)
    end
  end
end
