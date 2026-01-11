defmodule Beamlens.Skill.Ecto.Adapters.Generic do
  @moduledoc """
  Fallback adapter for non-PostgreSQL databases.

  Provides telemetry-based metrics only. Database-specific queries
  return an error indicating the feature is not available.
  """

  @not_available %{error: "not_available_for_this_database"}

  def available?, do: true

  def index_usage(_repo), do: @not_available
  def unused_indexes(_repo), do: @not_available
  def table_sizes(_repo, _limit \\ 20), do: @not_available
  def cache_hit(_repo), do: @not_available
  def locks(_repo), do: @not_available
  def long_running_queries(_repo), do: @not_available
  def bloat(_repo, _limit \\ 20), do: @not_available
  def slow_queries(_repo, _limit \\ 10), do: @not_available
  def connections(_repo), do: @not_available
end
