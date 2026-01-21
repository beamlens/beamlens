defmodule Beamlens.Skill.Ets do
  @moduledoc """
  ETS table monitoring skill.

  Provides callback functions for monitoring ETS table health.
  All functions are read-only with zero side effects.
  No PII/PHI exposure - only aggregate table statistics.
  """

  @behaviour Beamlens.Skill

  alias Beamlens.Skill.Ets.GrowthStore

  @impl true
  def title, do: "ETS Tables"

  @impl true
  def description, do: "ETS tables: memory usage, table sizes, growth patterns"

  @impl true
  def system_prompt do
    """
    You are an ETS table analyst. You monitor ETS tables for memory usage,
    growth patterns, and potential leaks.

    ## Your Domain
    - Table count and total memory usage
    - Individual table sizes and memory
    - Table configuration (type, protection, concurrency settings)
    - Growth rates over time windows
    - Tables that only grow without bound

    ## What to Watch For
    - Tables with unbounded growth: missing cleanup logic
    - Large tables with no read/write concurrency: potential bottleneck
    - Public tables: potential for uncontrolled access
    - Single large table dominating memory: review data structure
    - Growing table count: potential table leaks
    - Continuous growth: records added faster than removed

    ## ETS Growth Leaks
    ETS tables are never GC'd - records persist until deleted.

    Remediation:
    - Add TTL logic to periodically delete old records
    - Shard large tables across multiple nodes
    - Set max size limits and drop old records when exceeded
    - Review tables with high memory for cleanup logic
    """
  end

  @impl true
  def snapshot do
    tables = :ets.all()
    word_size = :erlang.system_info(:wordsize)

    total_memory =
      Enum.reduce(tables, 0, fn table, acc ->
        case :ets.info(table, :memory) do
          :undefined -> acc
          mem -> acc + mem * word_size
        end
      end)

    %{
      table_count: length(tables),
      total_memory_mb: bytes_to_mb(total_memory),
      largest_table_mb: largest_table_memory(tables, word_size)
    }
  end

  @impl true
  def callbacks do
    %{
      "ets_list_tables" => &list_tables/0,
      "ets_table_info" => &table_info/1,
      "ets_top_tables" => &top_tables/2,
      "ets_growth_stats" => &growth_stats/1,
      "ets_leak_candidates" => &leak_candidates/1
    }
  end

  @impl true
  def callback_docs do
    """
    ### ets_list_tables()
    All ETS tables with: name, type, protection, size, memory_kb

    ### ets_table_info(table_name)
    Single table details: name, id, owner_pid, type, protection, size, memory_kb, compressed, read_concurrency, write_concurrency

    ### ets_top_tables(limit, sort_by)
    Top N tables by "memory" or "size". Returns list with name, type, protection, size, memory_kb

    ### ets_growth_stats(interval_minutes)
    Table growth over time window. Takes two samples interval_minutes apart. Returns tables with highest growth rates including size_delta, growth_pct, current_size, memory_mb

    ### ets_leak_candidates(threshold_pct)
    Potential leaking tables that grew by more than threshold_pct over last hour. Returns tables that only grow (never shrink) with high memory but no configured limits
    """
  end

  defp list_tables do
    word_size = :erlang.system_info(:wordsize)

    :ets.all()
    |> Enum.map(fn table -> table_summary(table, word_size) end)
    |> Enum.reject(&is_nil/1)
  end

  defp table_info(table_name) when is_binary(table_name) do
    table_ref = resolve_table_ref(table_name)

    if table_ref do
      word_size = :erlang.system_info(:wordsize)
      table_details(table_ref, word_size)
    else
      %{error: "table_not_found", name: table_name}
    end
  end

  defp top_tables(limit, sort_by) when is_number(limit) and is_binary(sort_by) do
    limit = min(limit, 50)
    word_size = :erlang.system_info(:wordsize)
    sort_key = normalize_sort_key(sort_by)

    :ets.all()
    |> Enum.map(fn table -> table_summary(table, word_size) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&Map.get(&1, sort_key), :desc)
    |> Enum.take(limit)
  end

  defp growth_stats(interval_minutes) when is_number(interval_minutes) do
    samples = GrowthStore.get_samples()
    cutoff_ms = System.system_time(:millisecond) - trunc(interval_minutes * 60 * 1000)

    {oldest, newest} = find_boundary_samples(samples, cutoff_ms)

    calculate_growth_stats(oldest, newest)
  end

  defp leak_candidates(threshold_pct) when is_number(threshold_pct) do
    samples = GrowthStore.get_samples()
    cutoff_ms = System.system_time(:millisecond) - trunc(60 * 60 * 1000)

    {oldest, newest} = find_boundary_samples(samples, cutoff_ms)

    identify_leak_candidates(oldest, newest, threshold_pct)
  end

  defp find_boundary_samples(samples, cutoff_ms) do
    filtered = Enum.filter(samples, fn s -> s.timestamp >= cutoff_ms end)

    oldest = List.last(filtered)
    newest = List.first(filtered)

    {oldest, newest}
  end

  defp table_summary(table, word_size) do
    case safe_table_info(table) do
      nil ->
        nil

      info ->
        %{
          name: format_table_name(info[:name] || info[:id]),
          type: info[:type],
          protection: info[:protection],
          size: info[:size],
          memory_kb: div(info[:memory] * word_size, 1024)
        }
    end
  end

  defp table_details(table, word_size) do
    case safe_table_info(table) do
      nil ->
        %{error: "table_info_unavailable"}

      info ->
        %{
          name: format_table_name(info[:name] || info[:id]),
          id: format_table_name(info[:id]),
          owner_pid: inspect(info[:owner]),
          type: info[:type],
          protection: info[:protection],
          size: info[:size],
          memory_kb: div(info[:memory] * word_size, 1024),
          compressed: info[:compressed],
          read_concurrency: info[:read_concurrency],
          write_concurrency: info[:write_concurrency]
        }
    end
  end

  defp safe_table_info(table) do
    case :ets.info(table) do
      :undefined -> nil
      info -> info
    end
  end

  defp resolve_table_ref(name_string) do
    atom_name = string_to_existing_atom(name_string)

    if atom_name && table_exists?(atom_name) do
      atom_name
    else
      find_table_by_name(name_string, atom_name)
    end
  end

  defp string_to_existing_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end

  defp find_table_by_name(name_string, atom_name) do
    Enum.find(:ets.all(), &table_matches_name?(&1, name_string, atom_name))
  end

  defp table_matches_name?(table, name_string, atom_name) do
    case :ets.info(table, :name) do
      ^atom_name -> true
      _ -> format_table_name(table) == name_string
    end
  end

  defp table_exists?(name) do
    :ets.info(name) != :undefined
  end

  defp format_table_name(name) when is_atom(name), do: Atom.to_string(name)
  defp format_table_name(ref) when is_reference(ref), do: inspect(ref)
  defp format_table_name(other), do: inspect(other)

  defp normalize_sort_key("memory"), do: :memory_kb
  defp normalize_sort_key("size"), do: :size
  defp normalize_sort_key(_), do: :memory_kb

  defp largest_table_memory(tables, word_size) do
    tables
    |> Enum.map(&table_memory_bytes(&1, word_size))
    |> Enum.max(fn -> 0 end)
    |> bytes_to_mb()
  end

  defp table_memory_bytes(table, word_size) do
    case :ets.info(table, :memory) do
      :undefined -> 0
      mem -> mem * word_size
    end
  end

  defp bytes_to_mb(bytes), do: Float.round(bytes / 1_048_576, 2)

  defp calculate_growth_stats(nil, _newest), do: %{fastest_growing_tables: []}
  defp calculate_growth_stats(_oldest, nil), do: %{fastest_growing_tables: []}

  defp calculate_growth_stats(oldest, newest) do
    initial_tables = Map.new(oldest.tables, fn t -> {t.name, t} end)

    growth_stats =
      Enum.map(newest.tables, fn final_data ->
        case Map.get(initial_tables, final_data.name) do
          nil ->
            %{
              name: final_data.name,
              size_delta: final_data.size,
              growth_pct: 100.0,
              current_size: final_data.size,
              memory_mb: bytes_to_mb(final_data.memory)
            }

          initial_data ->
            size_delta = final_data.size - initial_data.size
            growth_pct = calculate_growth_percentage(initial_data.size, final_data.size)

            %{
              name: final_data.name,
              size_delta: size_delta,
              growth_pct: growth_pct,
              current_size: final_data.size,
              memory_mb: bytes_to_mb(final_data.memory)
            }
        end
      end)

    fastest_growing =
      growth_stats
      |> Enum.filter(fn stat -> stat.size_delta > 0 end)
      |> Enum.sort_by(& &1.size_delta, :desc)
      |> Enum.take(10)

    %{fastest_growing_tables: fastest_growing}
  end

  defp identify_leak_candidates(nil, _newest, _threshold_pct), do: %{suspected_leaks: []}
  defp identify_leak_candidates(_oldest, nil, _threshold_pct), do: %{suspected_leaks: []}

  defp identify_leak_candidates(oldest, newest, threshold_pct) do
    initial_tables = Map.new(oldest.tables, fn t -> {t.name, t} end)

    candidates =
      Enum.map(newest.tables, fn final_data ->
        initial_size = Map.get(initial_tables, final_data.name)[:size]

        growth_pct =
          if initial_size == nil do
            100.0
          else
            calculate_growth_percentage(initial_size, final_data.size)
          end

        size_delta =
          if initial_size == nil do
            final_data.size
          else
            final_data.size - initial_size
          end

        if growth_pct > threshold_pct and size_delta > 0 do
          %{
            name: final_data.name,
            growth_pct: growth_pct,
            size_delta: size_delta,
            current_size: final_data.size,
            memory_mb: bytes_to_mb(final_data.memory),
            only_grows: true
          }
        end
      end)
      |> Enum.reject(&is_nil/1)

    %{suspected_leaks: candidates}
  end

  defp calculate_growth_percentage(initial_size, final_size) do
    if initial_size == 0 do
      if final_size > 0, do: 100.0, else: 0.0
    else
      Float.round((final_size - initial_size) / initial_size * 100, 2)
    end
  end
end
