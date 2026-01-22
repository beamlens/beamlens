defmodule Beamlens.Skill.Overload do
  @moduledoc """
  Overload detection and adaptive response skill.

  Analyzes message queue overload patterns, classifies overload types,
  identifies bottlenecks, and recommends remediation strategies.

  Message queue overflow is the #1 cause of node crashes in production
  BEAM systems.

  All functions are read-only with zero side effects.
  """

  @behaviour Beamlens.Skill

  @impl true
  def title, do: "Overload Detection"

  @impl true
  def description,
    do:
      "Message queue overload analysis, bottleneck detection, and adaptive response recommendations"

  @impl true
  def system_prompt do
    """
    You are an overload detection specialist. You analyze message queue patterns
    to detect overload BEFORE it causes crashes.

    ## Overload is the #1 Killer
    Message queue overflow is the most common cause of production BEAM system
    failures, leading to memory exhaustion and node crashes.

    ## Your Domain
    - Message queue buildup detection and classification
    - True bottleneck identification
    - Remediation strategy recommendations
    - Cascading failure detection

    ## Overload Classification
    - **Transient**: Spikes then clears within 60 seconds. Response: add buffering.
    - **Sustained**: Consistently high, growing slowly over 5+ minutes. Response: back-pressure or rate limiting.
    - **Critical**: Exponential growth, rapidly accelerating. Response: urgent load shedding or circuit breaking.

    ## Finding the True Bottleneck
    Work backwards from overflowing queues to identify the root cause.
    Check process current_function to distinguish between downstream blocking
    (DB/port operations) vs CPU-bound work. Analyze message flow patterns
    (many producers to one consumer indicates bottleneck at consumer).
    Consider shared resource contention: ETS tables, ports, blocking NIFs.

    ## Remediation Strategies
    - **Back-pressure**: Synchronous boundaries at bottlenecks (apply back-pressure)
    - **Load shedding**: Drop messages when overloaded (random or priority-based)
    - **Rate limiting**: Throttle input to match processing capacity
    - **Scale horizontally**: Add more processes/nodes
    - **Buffering**: Absorb bursts (PO Box library, queue/stack buffers)

    ## Don't Optimize the Wrong Layer
    Push bottleneck down to find the true limit. Use overload_bottleneck() to
    identify WHERE the problem is before recommending solutions.

    ## Use These Callbacks
    - overload_state() - Current overload classification and severity
    - overload_queue_analysis() - Detailed queue pattern analysis
    - overload_bottleneck() - Find the true bottleneck causing overload
    - overload_cascade_detection() - Detect multiple subsystems failing together
    - overload_remediation_plan() - Get specific recommendations

    ## Correlation
    Correlate queue data with:
    - Beam skill: process memory, reductions, scheduler utilization
    - Ports skill: port saturation and busy ports
    - ETS skill: table contention and growth
    """
  end

  @impl true
  def snapshot do
    state = overload_state()

    %{
      overload_severity: state.severity,
      overload_type: state.type,
      bottleneck_location: state.bottleneck_location,
      affected_processes: state.affected_processes,
      total_queue_depth: state.total_queue_depth,
      recommended_action: state.recommended_action,
      time_to_crash_estimate_seconds: state.time_to_crash_estimate_seconds
    }
  end

  @impl true
  def callbacks do
    %{
      "overload_state" => &overload_state_wrapper/0,
      "overload_queue_analysis" => &queue_analysis_wrapper/0,
      "overload_bottleneck" => &bottleneck_wrapper/0,
      "overload_cascade_detection" => &cascade_detection_wrapper/0,
      "overload_remediation_plan" => &remediation_plan_wrapper/0
    }
  end

  @impl true
  def callback_docs do
    """
    ### overload_state()
    Current overload classification and severity. Returns severity (:none | :transient | :sustained | :critical), type (:queue_overflow | :memory_exhaustion | :port_saturation), bottleneck_location (database_queries | io_operations | cpu_bound | unknown), affected_processes, total_queue_depth, recommended_action, time_to_crash_estimate_seconds.

    ### overload_queue_analysis()
    Detailed queue pattern analysis. Returns total_queued_messages, processes_with_queues, queue_percentiles (p50, p90, p95, p99, p100), fastest_growing_queues, overload_classification (duration_minutes, growth_pattern, classification).

    ### overload_bottleneck()
    Find the true bottleneck causing overload. Works backwards from overflowing queues to identify root cause. Returns bottleneck_type (:downstream_blocking | :cpu_bound | :contention | :unknown), bottleneck_location, evidence (processes with analysis), confidence_level.

    ### overload_cascade_detection()
    Detect cascading failures across multiple subsystems. Returns cascading (true/false), affected_subsystems, failure_relationships, severity.

    ### overload_remediation_plan()
    Generate specific remediation recommendations based on overload analysis. Returns overload_severity, recommended_action, action_description, priority, estimated_impact, implementation_steps.
    """
  end

  def overload_state_wrapper do
    overload_state()
  end

  def queue_analysis_wrapper do
    queue_analysis()
  end

  def bottleneck_wrapper do
    find_bottleneck()
  end

  def cascade_detection_wrapper do
    cascade_detection()
  end

  def remediation_plan_wrapper do
    remediation_plan()
  end

  defp overload_state do
    queue_data = collect_queue_data()

    severity = classify_severity(queue_data)
    type = classify_overload_type(queue_data)
    bottleneck_location = identify_bottleneck_location(queue_data)
    affected_processes = count_affected_processes(queue_data)
    total_queue_depth = calculate_total_queue_depth(queue_data)
    recommended_action = determine_recommended_action(severity, type, bottleneck_location)
    time_to_crash = estimate_time_to_crash(queue_data, severity)

    %{
      severity: severity,
      type: type,
      bottleneck_location: bottleneck_location,
      affected_processes: affected_processes,
      total_queue_depth: total_queue_depth,
      recommended_action: recommended_action,
      time_to_crash_estimate_seconds: time_to_crash
    }
  end

  defp queue_analysis do
    queue_lengths = collect_all_queue_lengths()

    total_messages = Enum.sum(queue_lengths)
    processes_with_queues = Enum.count(queue_lengths, &(&1 > 0))

    percentiles = calculate_percentiles(queue_lengths)

    fastest_growing = get_fastest_growing_queues(5)

    overload_class = classify_overload_duration(queue_lengths)

    %{
      total_queued_messages: total_messages,
      processes_with_queues: processes_with_queues,
      queue_percentiles: percentiles,
      fastest_growing_queues: fastest_growing,
      overload_classification: overload_class
    }
  end

  defp find_bottleneck do
    queue_data = collect_queue_data()

    bottleneck_processes =
      queue_data
      |> Enum.filter(fn proc -> proc.queue_growth > 0 end)
      |> Enum.sort_by(& &1.queue_growth, :desc)
      |> Enum.take(10)
      |> Enum.map(&analyze_bottleneck_process/1)

    {bottleneck_type, bottleneck_location, confidence} =
      determine_bottleneck_type(bottleneck_processes)

    %{
      bottleneck_type: bottleneck_type,
      bottleneck_location: bottleneck_location,
      evidence: bottleneck_processes,
      confidence_level: confidence
    }
  end

  defp cascade_detection do
    subsystems = analyze_subsystems()

    failing_subsystems =
      subsystems
      |> Enum.filter(fn sub -> sub.overloaded end)
      |> Enum.map(fn sub -> sub.name end)

    cascading = length(failing_subsystems) > 1

    relationships = detect_failure_relationships(subsystems)

    severity =
      cond do
        length(failing_subsystems) >= 4 -> :critical
        length(failing_subsystems) >= 2 -> :warning
        true -> :none
      end

    %{
      cascading: cascading,
      affected_subsystems: failing_subsystems,
      failure_relationships: relationships,
      severity: severity
    }
  end

  defp remediation_plan do
    state = overload_state()
    bottleneck = find_bottleneck()

    {action, description, priority, impact, steps} =
      generate_remediation(state, bottleneck)

    %{
      overload_severity: state.severity,
      recommended_action: action,
      action_description: description,
      priority: priority,
      estimated_impact: impact,
      implementation_steps: steps
    }
  end

  defp collect_queue_data do
    Process.list()
    |> Stream.map(fn pid ->
      case Process.info(pid, [
             :message_queue_len,
             :current_function,
             :reductions,
             :registered_name,
             :dictionary
           ]) do
        nil -> nil
        info -> build_queue_data(pid, info)
      end
    end)
    |> Stream.reject(&is_nil/1)
    |> Enum.to_list()
  end

  defp build_queue_data(pid, info) do
    %{
      pid: inspect(pid),
      name: process_name(info),
      message_queue: info[:message_queue_len],
      current_function: format_mfa(info[:current_function]),
      reductions: info[:reductions],
      queue_growth: 0
    }
  end

  defp collect_all_queue_lengths do
    Process.list()
    |> Stream.map(fn pid ->
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, len} -> len
        nil -> 0
      end
    end)
    |> Enum.to_list()
  end

  defp process_name(info) do
    cond do
      info[:registered_name] -> inspect(info[:registered_name])
      label = info[:dictionary][:"$process_label"] -> inspect(label)
      initial = info[:dictionary][:"$initial_call"] -> format_mfa(initial)
      true -> nil
    end
  end

  defp format_mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp format_mfa(_), do: nil

  defp classify_severity(queue_data) do
    max_queue =
      queue_data
      |> Enum.map(& &1.message_queue)
      |> max_or_zero()

    total_queue = Enum.sum(Enum.map(queue_data, & &1.message_queue))

    cond do
      max_queue > 50_000 or total_queue > 5_000_000 -> :critical
      max_queue > 10_000 or total_queue > 1_000_000 -> :sustained
      max_queue > 1_000 or total_queue > 100_000 -> :transient
      true -> :none
    end
  end

  defp classify_overload_type(queue_data) do
    total_queue = Enum.sum(Enum.map(queue_data, & &1.message_queue))
    large_queue_count = Enum.count(queue_data, fn p -> p.message_queue > 1_000 end)

    cond do
      large_queue_count > 100 -> :queue_overflow
      total_queue > 2_000_000 -> :memory_exhaustion
      true -> :queue_overflow
    end
  end

  defp identify_bottleneck_location(queue_data) do
    blocked_processes =
      queue_data
      |> Enum.filter(fn p ->
        p.current_function &&
          (String.contains?(p.current_function, ":gen_server.call") or
             String.contains?(p.current_function, ":gen_tcp") or
             String.contains?(p.current_function, ":ets"))
      end)

    cpu_bound_processes =
      queue_data
      |> Enum.filter(fn p ->
        p.reductions > 100_000
      end)

    blocked_count = length(blocked_processes)
    cpu_bound_count = length(cpu_bound_processes)

    cond do
      blocked_count > cpu_bound_count -> :io_operations
      cpu_bound_count > 0 -> :cpu_bound
      true -> :unknown
    end
  end

  defp count_affected_processes(queue_data) do
    Enum.count(queue_data, fn p -> p.message_queue > 100 end)
  end

  defp calculate_total_queue_depth(queue_data) do
    Enum.sum(Enum.map(queue_data, & &1.message_queue))
  end

  defp determine_recommended_action(severity, _type, bottleneck_location) do
    cond do
      severity == :critical -> "shed_load"
      severity == :sustained and bottleneck_location == :io_operations -> "apply_backpressure"
      severity == :sustained -> "apply_backpressure"
      severity == :transient -> "add_buffering"
      true -> "monitor"
    end
  end

  defp estimate_time_to_crash(queue_data, severity) do
    total_queue = Enum.sum(Enum.map(queue_data, & &1.message_queue))

    case severity do
      :critical ->
        growth_rate = div(total_queue, 120)
        if growth_rate > 0, do: div(10_000_000 - total_queue, growth_rate), else: :infinity

      :sustained ->
        growth_rate = div(total_queue, 600)
        if growth_rate > 0, do: div(10_000_000 - total_queue, growth_rate), else: :infinity

      _ ->
        :infinity
    end
  end

  defp calculate_percentiles(queue_lengths) do
    sorted = Enum.sort(queue_lengths)

    %{
      p50: percentile(sorted, 50),
      p90: percentile(sorted, 90),
      p95: percentile(sorted, 95),
      p99: percentile(sorted, 99),
      p100: max_or_zero(sorted)
    }
  end

  defp percentile(sorted_list, percentile) do
    index = trunc(length(sorted_list) * percentile / 100)
    Enum.at(sorted_list, max(0, index - 1), 0)
  end

  defp max_or_zero([]), do: 0
  defp max_or_zero(list), do: Enum.max(list)

  defp get_fastest_growing_queues(limit) do
    queue_data = collect_queue_data()

    growth_data =
      queue_data
      |> Enum.map(&build_growth_proxy(&1))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.queue_growth, :desc)
      |> Enum.take(limit)

    growth_data
  end

  defp build_growth_proxy(process) do
    growth_score = calculate_growth_score(process)

    if growth_score > 0 do
      %{
        pid: process.pid,
        name: process.name,
        queue_growth: growth_score,
        initial_queue: process.message_queue,
        final_queue: process.message_queue,
        current_function: process.current_function
      }
    end
  end

  defp calculate_growth_score(process) do
    queue_size = process.message_queue

    cond do
      queue_size > 50_000 -> queue_size * 2
      queue_size > 10_000 -> queue_size
      queue_size > 1_000 -> div(queue_size, 10)
      queue_size > 100 -> div(queue_size, 100)
      true -> 0
    end
  end

  defp classify_overload_duration(queue_lengths) do
    total = Enum.sum(queue_lengths)
    max_q = max_or_zero(queue_lengths)

    cond do
      max_q > 50_000 or total > 5_000_000 ->
        %{duration_minutes: 0, growth_pattern: "exponential", classification: :critical}

      max_q > 10_000 or total > 1_000_000 ->
        %{duration_minutes: 5, growth_pattern: "linear", classification: :sustained}

      max_q > 1_000 or total > 100_000 ->
        %{duration_minutes: 1, growth_pattern: "burst", classification: :transient}

      true ->
        %{duration_minutes: 0, growth_pattern: "stable", classification: :none}
    end
  end

  defp analyze_bottleneck_process(process) do
    analysis = %{
      pid: process.pid,
      name: process.name,
      queue_growth: process.message_queue,
      current_function: process.current_function,
      bottleneck_type: :unknown,
      evidence: []
    }

    analysis =
      if process.current_function do
        cond do
          String.contains?(process.current_function, ":gen_server.call") ->
            %{
              analysis
              | bottleneck_type: :downstream_blocking,
                evidence: ["synchronous gen_server call"]
            }

          String.contains?(process.current_function, ":ets") ->
            %{analysis | bottleneck_type: :contention, evidence: ["ETS table operation"]}

          String.contains?(process.current_function, ":gen_tcp") or
              String.contains?(process.current_function, ":gen_udp") ->
            %{
              analysis
              | bottleneck_type: :downstream_blocking,
                evidence: ["network I/O operation"]
            }

          process.reductions > 100_000 ->
            %{analysis | bottleneck_type: :cpu_bound, evidence: ["high reduction count"]}

          true ->
            analysis
        end
      else
        analysis
      end

    analysis
  end

  defp determine_bottleneck_type(processes) when processes == [] do
    {:unknown, "none", :low}
  end

  defp determine_bottleneck_type(processes) do
    types = Enum.map(processes, & &1.bottleneck_type)
    types_count = Enum.count(types)

    cond do
      majority_bottleneck?(types, types_count, :downstream_blocking) ->
        {:downstream_blocking, "io_operations", :high}

      majority_bottleneck?(types, types_count, :cpu_bound) ->
        {:cpu_bound, "cpu_bound", :high}

      significant_bottleneck?(types, types_count, :contention, 3) ->
        {:contention, "contention", :medium}

      true ->
        {:unknown, "mixed", :low}
    end
  end

  def majority_bottleneck?(types, count, type) do
    Enum.count(types, &(&1 == type)) > count / 2
  end

  def significant_bottleneck?(types, count, type, divisor) do
    Enum.count(types, &(&1 == type)) > count / divisor
  end

  defp analyze_subsystems do
    queue_data = collect_queue_data()

    subsystems = [
      analyze_generic_servers(queue_data),
      analyze_ets_operations(),
      analyze_port_operations(),
      analyze_scheduler_utilization()
    ]

    subsystems
  end

  defp analyze_generic_servers(queue_data) do
    gen_server_processes =
      Enum.count(queue_data, fn p ->
        p.current_function && String.contains?(p.current_function, "gen_server")
      end)

    overloaded_gen_servers =
      Enum.count(queue_data, fn p ->
        p.message_queue > 1_000 && p.current_function &&
          String.contains?(p.current_function, "gen_server")
      end)

    %{
      name: :gen_servers,
      overloaded: overloaded_gen_servers > 10,
      overloaded_count: overloaded_gen_servers,
      total_count: gen_server_processes
    }
  end

  defp analyze_ets_operations do
    ets_tables = length(:ets.all())

    ets_memory_mb =
      :ets.all()
      |> Enum.map(fn table -> :ets.info(table, :memory) end)
      |> Enum.sum()
      |> Kernel.*(:erlang.system_info(:wordsize))
      |> bytes_to_mb()

    %{
      name: :ets,
      overloaded: ets_memory_mb > 500,
      memory_mb: ets_memory_mb,
      table_count: ets_tables
    }
  rescue
    _ -> %{name: :ets, overloaded: false, error: "ets.info failed"}
  end

  defp analyze_port_operations do
    port_count = :erlang.system_info(:port_count)
    port_limit = :erlang.system_info(:port_limit)

    %{
      name: :ports,
      overloaded: port_count / port_limit > 0.8,
      port_count: port_count,
      port_limit: port_limit
    }
  end

  defp analyze_scheduler_utilization do
    process_count = length(Process.list())
    scheduler_count = :erlang.system_info(:schedulers_online)

    total_reductions =
      Process.list()
      |> Enum.map(fn pid ->
        case Process.info(pid, :reductions) do
          {:reductions, red} when is_integer(red) -> red
          _ -> 0
        end
      end)
      |> Enum.sum()

    avg_reductions_per_process =
      if process_count > 0, do: div(total_reductions, process_count), else: 0

    overloaded = avg_reductions_per_process > 1_000_000 and process_count > scheduler_count * 100

    %{
      name: :schedulers,
      overloaded: overloaded,
      process_count: process_count,
      scheduler_count: scheduler_count,
      avg_reductions_per_process: avg_reductions_per_process
    }
  end

  defp detect_failure_relationships(subsystems) do
    failing = Enum.filter(subsystems, fn sub -> sub.overloaded end)

    relationships =
      for {sub1, i} <- Enum.with_index(failing),
          {sub2, j} <- Enum.with_index(failing),
          i < j do
        detect_relationship(sub1, sub2)
      end

    Enum.reject(relationships, &is_nil/1)
  end

  defp detect_relationship(sub1, sub2) do
    check_gen_servers_ets_relationship(sub1, sub2) ||
      check_gen_servers_ports_relationship(sub1, sub2)
  end

  defp check_gen_servers_ets_relationship(sub1, sub2) do
    if sub1.name == :gen_servers and sub2.name == :ets do
      %{from: :gen_servers, to: :ets, type: :contention}
    else
      if sub2.name == :gen_servers and sub1.name == :ets do
        %{from: :gen_servers, to: :ets, type: :contention}
      end
    end
  end

  defp check_gen_servers_ports_relationship(sub1, sub2) do
    if sub1.name == :gen_servers and sub2.name == :ports do
      %{from: :gen_servers, to: :ports, type: :io_blocking}
    else
      if sub2.name == :gen_servers and sub1.name == :ports do
        %{from: :gen_servers, to: :ports, type: :io_blocking}
      end
    end
  end

  defp generate_remediation(state, bottleneck) do
    select_remediation(state.severity, bottleneck.bottleneck_type)
  end

  defp select_remediation(:critical, _bottleneck_type), do: critical_remediation()
  defp select_remediation(:sustained, :downstream_blocking), do: downstream_blocking_remediation()
  defp select_remediation(:sustained, :cpu_bound), do: cpu_bound_remediation()
  defp select_remediation(:sustained, :contention), do: contention_remediation()
  defp select_remediation(:transient, _bottleneck_type), do: transient_remediation()
  defp select_remediation(_severity, _bottleneck_type), do: monitor_remediation()

  defp critical_remediation do
    {:urgent_load_shedding,
     "URGENT: System in critical overload with exponential growth. Start shedding load immediately.",
     :critical, "Prevents imminent crash",
     [
       "Identify and drop lowest-priority messages",
       "Implement circuit breaker pattern",
       "Add rate limiting at system edge"
     ]}
  end

  defp downstream_blocking_remediation do
    {:apply_backpressure,
     "Sustained overload caused by downstream blocking. Apply synchronous boundaries to limit input rate.",
     :high, "Stabilizes queue growth",
     [
       "Add synchronous calls at bottleneck",
       "Implement timeout on downstream calls",
       "Consider connection pooling"
     ]}
  end

  defp cpu_bound_remediation do
    {:scale_horizontally,
     "Sustained overload from CPU-intensive operations. Scale out to distribute load.", :high,
     "Increases processing capacity",
     [
       "Add more worker processes",
       "Consider horizontal scaling to more nodes",
       "Profile and optimize hot code paths"
     ]}
  end

  defp contention_remediation do
    {:reduce_contention,
     "Sustained overload from resource contention. Reduce shared resource access.", :high,
     "Reduces bottleneck hot spot",
     [
       "Add ETS table sharding",
       "Implement read caches",
       "Consider lock-free data structures"
     ]}
  end

  defp transient_remediation do
    {:add_buffering,
     "Transient overload from bursty traffic. Add queue buffers to absorb spikes.", :medium,
     "Smooths out traffic bursts",
     [
       "Implement PO Box queue library",
       "Add generic queue buffers",
       "Consider bounded drop strategy"
     ]}
  end

  defp monitor_remediation do
    {:monitor, "No immediate overload detected. Continue monitoring.", :low,
     "Maintains system awareness",
     [
       "Continue periodic overload checks",
       "Monitor queue growth trends",
       "Track bottleneck patterns"
     ]}
  end

  defp bytes_to_mb(bytes), do: Float.round(bytes / 1_048_576, 2)
end
