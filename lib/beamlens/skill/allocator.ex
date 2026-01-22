defmodule Beamlens.Skill.Allocator do
  @moduledoc """
  Memory allocator metrics skill.

  Provides callback functions for monitoring VM memory allocator fragmentation
  and carrier utilization. Detects memory fragmentation issues in long-running
  nodes where allocated memory exceeds actual usage.

  ## Memory Fragmentation

  Long-running BEAM nodes can experience allocator fragmentation where:
  - Memory allocated during peak load is never fully returned to the OS
  - OS reports much higher memory usage than erlang:memory() shows
  - VM allocators (binary_alloc, eheap_alloc, ets_alloc, etc.) fragment carriers

  This skill detects such issues by monitoring allocator block and carrier metrics.

  All functions are read-only with zero side effects.
  """

  @behaviour Beamlens.Skill

  @allocators [
    :binary_alloc,
    :eheap_alloc,
    :ets_alloc,
    :fix_alloc,
    :literal_alloc,
    :temp_alloc,
    :sl_alloc,
    :std_alloc,
    :ll_alloc,
    :driver_alloc
  ]

  @impl true
  def title, do: "Memory Allocators"

  @impl true
  def description,
    do: "VM allocator fragmentation: carrier utilization, block efficiency"

  @impl true
  def system_prompt do
    """
    You are a memory allocator monitor. You track VM-level allocator metrics
    to detect memory fragmentation in long-running nodes.

    ## Your Domain
    - Allocator carriers and blocks across all VM allocators
    - Block vs carrier size ratios (fragmentation indicators)
    - Memory usage efficiency at the allocator level

    ## What to Watch For
    - Low block/carrier ratio: High fragmentation, carriers underutilized
    - Many carriers with small blocks: Memory fragmentation
    - binary_alloc issues: Binary fragmentation after traffic spikes
    - eheap_alloc issues: Process heap fragmentation
    - ets_alloc issues: ETS table fragmentation

    ## Fragmentation Detection
    - Usage ratio < 0.5 (50%): Moderate fragmentation
    - Usage ratio < 0.3 (30%): Severe fragmentation, investigate
    - Compare block size vs carrier size to detect waste
    - Multiple allocators with low ratios: System-wide fragmentation

    ## Remediation
    - Restart node during maintenance window (returns memory to OS)
    - Trigger process hibernation to compact heaps
    - Reduce peak load to lower carrier retention
    """
  end

  @impl true
  def snapshot do
    allocators = allocator_summary()

    %{
      allocator_count: length(allocators),
      total_carriers: Enum.reduce(allocators, 0, fn a, sum -> sum + a.carriers end),
      fragmented_allocators: Enum.count(allocators, fn a -> a.usage_ratio < 0.5 end),
      worst_usage_ratio:
        Enum.min_by(allocators, fn a -> a.usage_ratio end, fn -> %{usage_ratio: 1.0} end).usage_ratio
    }
  end

  @impl true
  def callbacks do
    %{
      "allocator_summary" => &allocator_summary/0,
      "allocator_by_type" => &allocator_by_type/1,
      "allocator_fragmentation" => &allocator_fragmentation/0,
      "allocator_problematic" => &allocator_problematic/0
    }
  end

  @impl true
  def callback_docs do
    """
    ### allocator_summary()
    Summary of all allocators with name, carriers, blocks, usage_ratio

    ### allocator_by_type(allocator_name)
    Detailed metrics for specific allocator: binary_alloc, eheap_alloc, ets_alloc, etc.
    Returns carriers, blocks, block_size_mb, carrier_size_mb, usage_ratio

    ### allocator_fragmentation()
    Current vs maximum fragmentation metrics across all allocators

    ### allocator_problematic()
    Allocators with usage_ratio < 0.5 (potential fragmentation issues)
    """
  end

  @doc """
  Summary metrics for all VM allocators.

  Returns list of maps with allocator name, carriers, blocks,
  block size, carrier size, and usage ratio (blocks/carriers).
  """
  def allocator_summary do
    @allocators
    |> Enum.map(&allocator_info/1)
    |> Enum.filter(fn
      nil -> false
      _ -> true
    end)
    |> Enum.map(fn {name, instances} ->
      metrics = aggregate_instances(instances)

      %{
        name: name,
        carriers: metrics.carriers,
        blocks: metrics.blocks,
        block_size_mb: bytes_to_mb(metrics.blocks_size),
        carrier_size_mb: bytes_to_mb(metrics.carriers_size),
        usage_ratio: Float.round(metrics.usage_ratio, 3)
      }
    end)
  end

  @doc """
  Detailed metrics for a specific allocator type.

  Returns map with carriers, blocks, block_size_mb, carrier_size_mb,
  and usage_ratio. Returns nil if allocator not found or unavailable.
  """
  def allocator_by_type(allocator_name) when allocator_name in @allocators do
    case safe_allocator_info(allocator_name) do
      nil ->
        nil

      {^allocator_name, instances} when is_list(instances) ->
        metrics = aggregate_instances(instances)

        %{
          name: allocator_name,
          carriers: metrics.carriers,
          blocks: metrics.blocks,
          block_size_mb: bytes_to_mb(metrics.blocks_size),
          carrier_size_mb: bytes_to_mb(metrics.carriers_size),
          usage_ratio: Float.round(metrics.usage_ratio, 3),
          mseg_carriers: metrics.mseg_carriers,
          sys_alloc_carriers: metrics.sys_alloc_carriers
        }

      _ ->
        nil
    end
  end

  def allocator_by_type(_allocator_name), do: nil

  @doc """
  Fragmentation metrics comparing current vs worst-case usage.

  Returns map with average_usage_ratio, worst_allocator (name),
  worst_usage_ratio, and fragmentation_score.
  """
  def allocator_fragmentation do
    allocators = allocator_summary()

    if allocators == [] do
      %{
        average_usage_ratio: 1.0,
        worst_allocator: nil,
        worst_usage_ratio: 1.0,
        fragmentation_score: 0.0
      }
    else
      worst = Enum.min_by(allocators, fn a -> a.usage_ratio end)

      avg_ratio =
        Enum.reduce(allocators, 0.0, fn a, sum -> sum + a.usage_ratio end) / length(allocators)

      %{
        average_usage_ratio: Float.round(avg_ratio, 3),
        worst_allocator: worst.name,
        worst_usage_ratio: worst.usage_ratio,
        fragmentation_score: Float.round(1.0 - avg_ratio, 3)
      }
    end
  end

  @doc """
  Identifies allocators with potential fragmentation issues.

  Returns allocators with usage_ratio < 0.5 (less than 50% carrier utilization).
  These may indicate memory fragmentation where allocated carriers are
  underutilized.
  """
  def allocator_problematic do
    allocator_summary()
    |> Enum.filter(fn a -> a.usage_ratio < 0.5 end)
    |> Enum.sort_by(fn a -> a.usage_ratio end)
  end

  defp safe_allocator_info(allocator_name) do
    case :erlang.system_info({:allocator, allocator_name}) do
      {:error, _} -> nil
      instances when is_list(instances) -> {allocator_name, instances}
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp allocator_info(allocator_name) do
    safe_allocator_info(allocator_name)
  end

  defp aggregate_instances(instances) when is_list(instances) do
    Enum.reduce(
      instances,
      %{
        carriers: 0,
        blocks: 0,
        blocks_size: 0,
        carriers_size: 0,
        mseg_carriers: 0,
        sys_alloc_carriers: 0
      },
      fn {:instance, _instance_num, instance_data}, acc ->
        mbcs = Keyword.get(instance_data, :mbcs, [])
        sbcs = Keyword.get(instance_data, :sbcs, [])

        acc
        |> Map.update!(:carriers, &(&1 + aggregate_carriers(mbcs, sbcs)))
        |> Map.update!(:blocks, &(&1 + aggregate_blocks(mbcs, sbcs)))
        |> Map.update!(:blocks_size, &(&1 + aggregate_blocks_size(mbcs, sbcs)))
        |> Map.update!(:carriers_size, &(&1 + aggregate_carriers_size(mbcs, sbcs)))
        |> Map.update!(:mseg_carriers, &(&1 + Keyword.get(mbcs, :mseg_alloc_carriers, 0)))
        |> Map.update!(:mseg_carriers, &(&1 + Keyword.get(sbcs, :mseg_alloc_carriers, 0)))
        |> Map.update!(:sys_alloc_carriers, &(&1 + Keyword.get(mbcs, :sys_alloc_carriers, 0)))
        |> Map.update!(:sys_alloc_carriers, &(&1 + Keyword.get(sbcs, :sys_alloc_carriers, 0)))
      end
    )
    |> calculate_usage_ratio()
  end

  defp aggregate_carriers(mbcs, sbcs) do
    mbcs_carriers = extract_carriers_count(mbcs)
    sbcs_carriers = extract_carriers_count(sbcs)
    mbcs_carriers + sbcs_carriers
  end

  defp extract_carriers_count(list) do
    case List.keyfind(list, :carriers, 0) do
      {:carriers, count, _, _} when is_integer(count) -> count
      {:carriers, _current, _max, _selected} -> 1
      _ -> 0
    end
  end

  defp aggregate_blocks(mbcs, sbcs) do
    mbcs_blocks = extract_blocks_count(mbcs)
    sbcs_blocks = extract_blocks_count(sbcs)
    mbcs_blocks + sbcs_blocks
  end

  defp extract_blocks_count(list) do
    blocks_list = List.keyfind(list, :blocks, 0)
    sum_blocks_from_list(blocks_list)
  end

  defp sum_blocks_from_list({:blocks, blocks_list}) when is_list(blocks_list) do
    Enum.reduce(blocks_list, 0, fn {_alloc_type, counts}, acc ->
      acc + extract_count_from_tuple(counts)
    end)
  end

  defp sum_blocks_from_list(_), do: 0

  defp extract_count_from_tuple({count, _, _, _}) when is_integer(count), do: count
  defp extract_count_from_tuple({count, _, _}) when is_integer(count), do: count
  defp extract_count_from_tuple(_), do: 0

  defp aggregate_blocks_size(mbcs, sbcs) do
    mbcs_size = extract_blocks_size(mbcs)
    sbcs_size = extract_blocks_size(sbcs)
    mbcs_size + sbcs_size
  end

  defp extract_blocks_size(list) do
    case List.keyfind(list, :blocks_size, 0) do
      {:blocks_size, size} when is_integer(size) -> size
      _ -> 0
    end
  end

  defp aggregate_carriers_size(mbcs, sbcs) do
    mbcs_size = extract_carriers_size(mbcs)
    sbcs_size = extract_carriers_size(sbcs)
    mbcs_size + sbcs_size
  end

  defp extract_carriers_size(list) do
    case List.keyfind(list, :carriers_size, 0) do
      {:carriers_size, size} when is_integer(size) -> size
      _ -> 0
    end
  end

  defp calculate_usage_ratio(metrics) do
    usage_ratio =
      if metrics.carriers_size > 0 do
        metrics.blocks_size / metrics.carriers_size
      else
        1.0
      end

    Map.put(metrics, :usage_ratio, usage_ratio)
  end

  defp bytes_to_mb(bytes), do: Float.round(bytes / 1_048_576, 2)
end
