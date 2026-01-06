defmodule Beamlens.Watchers.Server do
  @moduledoc """
  GenServer that runs a watcher on a cron schedule.

  Each watcher server:
  1. Starts with a cron schedule
  2. On each tick: collects snapshot, detects anomaly
  3. If anomaly: creates Report, sends to ReportQueue (unless in cooldown)
  4. Emits telemetry events for lifecycle

  This is the runtime component of the **Orchestrator-Workers** pattern.
  Each Server runs a single watcher module continuously.

  ## Alert Cooldown

  To prevent alert fatigue, detected anomalies are subject to a 5-minute cooldown
  per metric category. After reporting a "memory_high" anomaly, subsequent memory
  anomalies within 5 minutes are suppressed (emitting telemetry event
  `[:beamlens, :watcher, :baseline_anomaly_suppressed]`).

  Categories are derived from the anomaly type prefix (e.g., "memory_high" → :memory).

  ## Example

      {:ok, pid} = Server.start_link(
        name: {:via, Registry, {MyRegistry, :beam}},
        watcher_module: Beamlens.Watchers.BeamWatcher,
        cron: "*/1 * * * *",
        config: []
      )
  """

  use GenServer

  alias Beamlens.{Report, ReportQueue, Telemetry}
  alias Beamlens.Scheduler.Schedule

  alias Beamlens.Watchers.{ObservationHistory, Status}

  alias Beamlens.Watchers.Baseline.{
    Analyzer,
    Context,
    Decision
  }

  alias Crontab.CronExpression.Parser

  @default_window_size 60
  @default_min_observations 3
  @default_cooldown_seconds 300

  defstruct [
    :name,
    :watcher_module,
    :watcher_state,
    :cron,
    :cron_string,
    :timer_ref,
    :next_run_at,
    :last_run_at,
    :report_handler,
    :baseline_config,
    :observation_history,
    :baseline_context,
    :llm_client,
    :client_registry,
    run_count: 0,
    running: false,
    alert_cooldowns: %{}
  ]

  @doc """
  Starts a Server.

  ## Options

    * `:name` - (optional) GenServer name
    * `:watcher_module` - (required) module implementing Watcher behaviour
    * `:cron` - (required) cron expression string
    * `:config` - (optional) config passed to watcher's init/1
    * `:report_handler` - (optional) function to handle reports, defaults to ReportQueue.push/1
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Triggers an immediate check, bypassing the cron schedule.

  Useful for testing or manual intervention.
  """
  def trigger(server) do
    GenServer.cast(server, :trigger)
  end

  @doc """
  Returns the current status of the watcher.
  """
  def status(server) do
    GenServer.call(server, :status)
  end

  @impl true
  def init(opts) do
    watcher_module = Keyword.fetch!(opts, :watcher_module)
    cron_string = Keyword.fetch!(opts, :cron)
    watcher_config = Keyword.get(opts, :config, [])
    report_handler = Keyword.get(opts, :report_handler, &default_report_handler/1)
    name = Keyword.get(opts, :name)
    llm_client = Keyword.get(opts, :llm_client)
    client_registry = Keyword.get(opts, :client_registry)

    with {:ok, cron} <- Parser.parse(cron_string),
         {:ok, watcher_state} <- watcher_module.init(watcher_config) do
      baseline_config = watcher_module.baseline_config()

      state = %__MODULE__{
        name: name,
        watcher_module: watcher_module,
        watcher_state: watcher_state,
        cron: cron,
        cron_string: cron_string,
        report_handler: report_handler,
        next_run_at: Schedule.compute_next_run(cron),
        baseline_config: baseline_config,
        observation_history: init_observation_history(baseline_config),
        baseline_context: Context.new(),
        llm_client: llm_client,
        client_registry: client_registry
      }

      emit_telemetry(:started, state)
      {:ok, start_timer(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp init_observation_history(config) do
    window_size = Map.get(config, :window_size, @default_window_size)
    ObservationHistory.new(window_size: window_size)
  end

  @impl true
  def handle_cast(:trigger, state) do
    if state.running do
      emit_telemetry(:skipped, state, %{reason: :already_running, source: :manual})
      {:noreply, state}
    else
      emit_telemetry(:triggered, state, %{source: :manual})
      {:noreply, run_check(state)}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %Status{
      watcher: state.watcher_module.domain(),
      cron: state.cron_string,
      next_run_at: state.next_run_at,
      last_run_at: state.last_run_at,
      run_count: state.run_count,
      running: state.running
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:tick, %{running: true} = state) do
    emit_telemetry(:skipped, state, %{reason: :already_running, source: :scheduled})
    {:noreply, reschedule(state)}
  end

  def handle_info(:tick, state) do
    {ms, status} = Schedule.ms_until_next_run(%Schedule{next_run_at: state.next_run_at})

    if status == :clamped or ms > 0 do
      {:noreply, reschedule(state)}
    else
      emit_telemetry(:triggered, state, %{source: :scheduled})
      {:noreply, run_check(state) |> reschedule()}
    end
  end

  defp run_check(state) do
    state = %{state | running: true}
    emit_telemetry(:check_start, state)

    module = state.watcher_module
    snapshot = module.collect_snapshot(state.watcher_state)
    state = run_baseline_check(state, snapshot)

    emit_telemetry(:check_stop, state)

    %{
      state
      | running: false,
        run_count: state.run_count + 1,
        last_run_at: NaiveDateTime.utc_now()
    }
  end

  defp run_baseline_check(state, snapshot) do
    module = state.watcher_module
    trace_id = Telemetry.generate_trace_id()

    observation = module.snapshot_to_observation(snapshot)
    history = ObservationHistory.add(state.observation_history, observation)
    context = Context.record_observation(state.baseline_context)

    min_observations =
      Map.get(state.baseline_config, :min_observations, @default_min_observations)

    if ObservationHistory.count(history) < min_observations do
      emit_telemetry(:baseline_collecting, state, %{
        observation_count: ObservationHistory.count(history),
        min_required: min_observations
      })

      %{state | observation_history: history, baseline_context: context}
    else
      emit_telemetry(:baseline_analysis_start, state, %{trace_id: trace_id})

      opts = [
        llm_client: state.llm_client,
        client_registry: state.client_registry,
        trace_id: trace_id
      ]

      case Analyzer.analyze(module.domain(), history, context, module, opts) do
        {:ok, decision} ->
          handle_baseline_decision(state, decision, snapshot, history, context, trace_id)

        {:error, reason} ->
          emit_telemetry(:baseline_analysis_stop, state, %{
            trace_id: trace_id,
            success: false,
            error: reason
          })

          %{state | observation_history: history, baseline_context: context}
      end
    end
  end

  defp handle_baseline_decision(
         state,
         %Decision.ContinueObserving{} = decision,
         _snapshot,
         history,
         context,
         trace_id
       ) do
    emit_telemetry(:baseline_analysis_stop, state, %{trace_id: trace_id, success: true})

    emit_telemetry(:baseline_continue_observing, state, %{
      trace_id: trace_id,
      confidence: decision.confidence
    })

    context = Context.update_notes(context, decision.notes)
    %{state | observation_history: history, baseline_context: context}
  end

  defp handle_baseline_decision(
         state,
         %Decision.ReportAnomaly{} = decision,
         snapshot,
         _history,
         _context,
         trace_id
       ) do
    emit_telemetry(:baseline_analysis_stop, state, %{trace_id: trace_id, success: true})

    category = metric_category(decision.anomaly_type)
    window_size = Map.get(state.baseline_config, :window_size, @default_window_size)

    if in_cooldown?(state.alert_cooldowns, category) do
      emit_telemetry(:baseline_anomaly_suppressed, state, %{
        trace_id: trace_id,
        anomaly_type: decision.anomaly_type,
        category: category,
        reason: :cooldown
      })

      %{
        state
        | observation_history: ObservationHistory.new(window_size: window_size),
          baseline_context: Context.new()
      }
    else
      report =
        build_report(
          state,
          String.to_atom(decision.anomaly_type),
          decision.severity,
          decision.summary,
          snapshot
        )

      emit_telemetry(:baseline_anomaly_detected, state, %{
        trace_id: trace_id,
        report_id: report.id,
        severity: decision.severity,
        anomaly_type: decision.anomaly_type,
        confidence: decision.confidence
      })

      state.report_handler.(report)

      %{
        state
        | observation_history: ObservationHistory.new(window_size: window_size),
          baseline_context: Context.new(),
          alert_cooldowns: Map.put(state.alert_cooldowns, category, DateTime.utc_now())
      }
    end
  end

  defp handle_baseline_decision(
         state,
         %Decision.ReportHealthy{} = decision,
         _snapshot,
         history,
         context,
         trace_id
       ) do
    emit_telemetry(:baseline_analysis_stop, state, %{trace_id: trace_id, success: true})

    emit_telemetry(:baseline_healthy, state, %{
      trace_id: trace_id,
      confidence: decision.confidence,
      summary: decision.summary
    })

    %{state | observation_history: history, baseline_context: context}
  end

  defp build_report(state, anomaly_type, severity, summary, snapshot) do
    Report.new(%{
      watcher: state.watcher_module.domain(),
      anomaly_type: anomaly_type,
      severity: severity,
      summary: summary,
      snapshot: snapshot
    })
  end

  defp start_timer(state) do
    {ms, _status} = Schedule.ms_until_next_run(%Schedule{next_run_at: state.next_run_at})
    ms = max(ms, 100)
    timer_ref = Process.send_after(self(), :tick, ms)
    %{state | timer_ref: timer_ref}
  end

  defp reschedule(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    next = Schedule.compute_next_run(state.cron)
    start_timer(%{state | next_run_at: next})
  end

  defp default_report_handler(report) do
    ReportQueue.push(report)
  end

  defp emit_telemetry(event, state, extra \\ %{}) do
    :telemetry.execute(
      [:beamlens, :watcher, event],
      %{system_time: System.system_time()},
      Map.merge(
        %{
          watcher: state.watcher_module.domain(),
          cron: state.cron_string
        },
        extra
      )
    )
  end

  defp metric_category(anomaly_type) when is_binary(anomaly_type) do
    [prefix | _] = String.split(anomaly_type, "_")
    String.to_atom(prefix)
  end

  defp in_cooldown?(cooldowns, category) do
    cooldowns |> Map.get(category) |> cooldown_active?()
  end

  defp cooldown_active?(nil), do: false

  defp cooldown_active?(reported_at) do
    DateTime.diff(DateTime.utc_now(), reported_at, :second) < @default_cooldown_seconds
  end
end
