defmodule Beamlens.Skill.Logger do
  @moduledoc """
  Application log monitoring skill.

  Captures and analyzes application logs via an Erlang `:logger` handler
  to help identify error patterns, log anomalies, and module-specific issues.

  Requires `Beamlens.Skill.Logger.LogStore` to be running. The LogStore
  is automatically started when configuring the `:logger` watcher.

  ## Usage

      {Beamlens, skills: [:beam, :logger]}

  ## Sensitive Data

  This skill captures application log messages and makes them available
  for LLM analysis. Ensure your application logs do not contain sensitive
  data (PII, secrets, tokens) before enabling this watcher.

  All functions are read-only with zero side effects.
  """

  @behaviour Beamlens.Skill

  alias Beamlens.Skill.Logger.LogStore

  @impl true
  def title, do: "Application Logs"

  @impl true
  def description, do: "Application logs: error rates, patterns, module-specific issues"

  @impl true
  def system_prompt do
    """
    You are an application log analyst. You monitor log streams for error patterns,
    anomalies, and early warning signs of problems.

    ## Your Domain
    - Error rates and patterns
    - Warning accumulation
    - Module-specific issues
    - Log volume anomalies

    ## What to Watch For
    - Sudden spike in error rate
    - Repeated errors from same module
    - New error types appearing
    - Error patterns correlating with time or load
    - Cascading failures across modules
    """
  end

  @doc """
  High-level log statistics for quick health assessment.

  Returns counts by log level and error rate over a 1-minute rolling window.
  """
  @impl true
  def snapshot do
    stats = LogStore.get_stats()

    %{
      total_logs_1m: stats.total_count,
      error_count_1m: stats.error_count,
      warning_count_1m: stats.warning_count,
      error_rate_pct: stats.error_rate,
      unique_error_modules: stats.error_module_count
    }
  end

  @doc """
  Returns the Lua sandbox callback map for log analysis.

  These functions are registered with Puck.Sandbox.Eval and can be
  called from LLM-generated Lua code.
  """
  @impl true
  def callbacks do
    %{
      "logger_stats" => fn -> LogStore.get_stats() end,
      "logger_recent" => &recent_logs/2,
      "logger_errors" => fn limit -> LogStore.recent_errors(LogStore, limit) end,
      "logger_search" => &search_logs/2,
      "logger_by_module" => &logs_by_module/2
    }
  end

  @impl true
  def callback_docs do
    """
    ### logger_stats()
    Log statistics: total_count, error_count, warning_count, info_count, debug_count, error_rate, error_module_count

    ### logger_recent(limit, level)
    Recent log entries. Level: "error", "warning", "info", "debug", or nil for all.
    Returns: timestamp, level, message, module, function, line, domain

    ### logger_errors(limit)
    Recent error-level logs with full message content

    ### logger_search(pattern, limit)
    Search logs by regex pattern. Returns matching entries.

    ### logger_by_module(module_name, limit)
    Logs from modules matching the given name. Useful for investigating specific components.
    """
  end

  defp recent_logs(limit, level) when is_number(limit) do
    level_opt = if is_binary(level) and level != "", do: level, else: nil
    LogStore.get_logs(LogStore, level: level_opt, limit: limit)
  end

  defp search_logs(pattern, limit) when is_binary(pattern) and is_number(limit) do
    LogStore.search(LogStore, pattern, limit: limit)
  end

  defp logs_by_module(module_name, limit) when is_binary(module_name) and is_number(limit) do
    LogStore.get_logs_by_module(LogStore, module_name, limit)
  end
end
