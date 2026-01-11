defmodule Beamlens.Skill.Ets do
  @moduledoc """
  ETS table monitoring skill.

  Provides callback functions for monitoring ETS table health.
  All functions are read-only with zero side effects.
  No PII/PHI exposure - only aggregate table statistics.
  """

  @behaviour Beamlens.Skill

  @impl true
  def id, do: :ets

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

    ## What to Watch For
    - Tables with unbounded growth: missing cleanup logic
    - Large tables with no read/write concurrency: potential bottleneck
    - Public tables: potential for uncontrolled access
    - Single large table dominating memory: review data structure
    - Growing table count: potential table leaks
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
      "ets_top_tables" => &top_tables/2
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
  rescue
    ArgumentError -> nil
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
  rescue
    ArgumentError -> false
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
end
