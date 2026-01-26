defmodule Beamlens.Skill.Anomaly.Detector do
  @moduledoc """
  Detects statistical anomalies in BEAM metrics.

  Implements a state machine with three phases:
  - Learning: Collects baseline data from skill snapshots
  - Active: Detects anomalies using z-score analysis
  - Cooldown: Waits after escalation before resuming detection

  All reads are from existing skill snapshots (zero side effects).
  """

  use GenServer
  alias Beamlens.Skill.Anomaly.BaselineStore
  alias Beamlens.Skill.Anomaly.Detector.Metric
  alias Beamlens.Skill.Anomaly.Detector.Status
  alias Beamlens.Skill.Anomaly.MetricStore
  alias Beamlens.Skill.Anomaly.Statistics

  @default_collection_interval_ms 30_000
  @default_learning_duration_ms :timer.hours(2)
  @default_z_threshold 3.0
  @default_consecutive_required 3
  @default_cooldown_ms :timer.minutes(15)
  @default_auto_trigger true
  @default_max_triggers_per_hour 3
  @one_hour_ms :timer.hours(1)

  defstruct [
    :metric_store,
    :baseline_store,
    :timer_ref,
    :collection_interval_ms,
    :learning_duration_ms,
    :learning_start_time,
    :z_threshold,
    :consecutive_required,
    :cooldown_ms,
    :cooldown_start_time,
    :consecutive_count,
    :state,
    :skills,
    :auto_trigger,
    :max_triggers_per_hour,
    :trigger_history
  ]

  @doc """
  Start the detector with options.

  ## Options

    * `:metric_store` - PID of MetricStore GenServer (required)
    * `:baseline_store` - PID of BaselineStore GenServer (required)
    * `:collection_interval_ms` - How often to collect metrics (default: 30s)
    * `:learning_duration_ms` - How long to learn baselines (default: 2 hours)
    * `:z_threshold` - Z-score threshold for anomalies (default: 3.0)
    * `:consecutive_required` - Consecutive anomalies before escalation (default: 3)
    * `:cooldown_ms` - Cooldown period after escalation (default: 15 minutes)
    * `:skills` - List of skill modules to monitor (default: all registered skills)
    * `:auto_trigger` - Enable automatic Coordinator triggering (default: true)
    * `:max_triggers_per_hour` - Rate limit for auto-triggers (default: 3)
  """
  def start_link(opts \\ []) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])

    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @impl true
  def init(opts) do
    metric_store = Keyword.fetch!(opts, :metric_store)
    baseline_store = Keyword.fetch!(opts, :baseline_store)

    collection_interval_ms =
      Keyword.get(opts, :collection_interval_ms, @default_collection_interval_ms)

    learning_duration_ms = Keyword.get(opts, :learning_duration_ms, @default_learning_duration_ms)
    z_threshold = Keyword.get(opts, :z_threshold, @default_z_threshold)
    consecutive_required = Keyword.get(opts, :consecutive_required, @default_consecutive_required)
    cooldown_ms = Keyword.get(opts, :cooldown_ms, @default_cooldown_ms)
    skills = Keyword.get(opts, :skills, Beamlens.Supervisor.registered_skills())
    auto_trigger = Keyword.get(opts, :auto_trigger, @default_auto_trigger)

    max_triggers_per_hour =
      Keyword.get(opts, :max_triggers_per_hour, @default_max_triggers_per_hour)

    timer_ref = Process.send_after(self(), :collect, collection_interval_ms)

    state = %__MODULE__{
      metric_store: metric_store,
      baseline_store: baseline_store,
      timer_ref: timer_ref,
      collection_interval_ms: collection_interval_ms,
      learning_duration_ms: learning_duration_ms,
      learning_start_time: System.system_time(:millisecond),
      z_threshold: z_threshold,
      consecutive_required: consecutive_required,
      cooldown_ms: cooldown_ms,
      consecutive_count: 0,
      state: :learning,
      skills: skills,
      auto_trigger: auto_trigger,
      max_triggers_per_hour: max_triggers_per_hour,
      trigger_history: []
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    :ok
  end

  @impl true
  def handle_info(:collect, state) do
    state = collect_and_analyze(state)

    timer_ref = Process.send_after(self(), :collect, state.collection_interval_ms)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.state, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    now = System.system_time(:millisecond)

    learning_elapsed_ms =
      if state.learning_start_time, do: now - state.learning_start_time, else: nil

    triggers_in_last_hour =
      Enum.count(state.trigger_history, &(now - &1 < @one_hour_ms))

    status = %Status{
      state: state.state,
      learning_start_time: state.learning_start_time,
      learning_elapsed_ms: learning_elapsed_ms,
      cooldown_start_time: state.cooldown_start_time,
      consecutive_count: state.consecutive_count,
      collection_interval_ms: state.collection_interval_ms,
      auto_trigger: state.auto_trigger,
      triggers_in_last_hour: triggers_in_last_hour
    }

    {:reply, status, state}
  end

  defp collect_and_analyze(state) do
    metrics = collect_metrics(state.skills)
    store_metrics(state, metrics)

    case state.state do
      :learning ->
        check_learning_complete(state, metrics)

      :active ->
        detect_anomalies(state, metrics)

      :cooldown ->
        check_cooldown_complete(state)
    end
  end

  defp collect_metrics(skills) do
    Enum.flat_map(skills, fn skill ->
      try do
        snapshot = skill.snapshot()

        Enum.map(snapshot, fn {metric_name, value} ->
          %Metric{skill: skill, metric: metric_name, value: normalize_value(value)}
        end)
      catch
        :exit, reason ->
          :telemetry.execute(
            [:beamlens, :anomaly, :detector, :metric_collection_failed],
            %{system_time: System.system_time()},
            %{skill: skill, error: {:exit, reason}}
          )

          []
      end
    end)
  end

  defp normalize_value(value) when is_number(value), do: value / 1
  defp normalize_value(_), do: 0.0

  defp store_metrics(state, metrics) do
    Enum.each(metrics, fn metric ->
      MetricStore.add_sample(state.metric_store, metric.skill, metric.metric, metric.value)
    end)
  end

  defp check_learning_complete(state, _metrics) do
    elapsed = System.system_time(:millisecond) - state.learning_start_time

    if elapsed >= state.learning_duration_ms do
      :telemetry.execute(
        [:beamlens, :anomaly, :detector, :learning_complete],
        %{system_time: System.system_time(), elapsed_ms: elapsed},
        %{}
      )

      calculate_baselines(state)

      %{state | state: :active, learning_start_time: nil}
    else
      state
    end
  end

  defp calculate_baselines(state) do
    Enum.each(state.skills, fn skill ->
      try do
        snapshot = skill.snapshot()

        Enum.each(snapshot, fn {metric_name, _value} ->
          samples =
            MetricStore.get_samples(
              state.metric_store,
              skill,
              metric_name,
              state.learning_duration_ms
            )

          if samples != [] do
            values = Enum.map(samples, fn s -> s.value end)
            BaselineStore.update_baseline(state.baseline_store, skill, metric_name, values)
          end
        end)
      catch
        :exit, reason ->
          :telemetry.execute(
            [:beamlens, :anomaly, :detector, :baseline_calculation_failed],
            %{system_time: System.system_time()},
            %{skill: skill, error: {:exit, reason}}
          )

          :ok
      end
    end)
  end

  defp detect_anomalies(state, metrics) do
    {anomalies, state} =
      Enum.reduce(metrics, {[], state}, fn metric, {anomalies, acc_state} ->
        case check_for_anomaly(acc_state, metric) do
          {:anomaly, new_state} ->
            {[metric | anomalies], new_state}

          :normal ->
            {anomalies, acc_state}
        end
      end)

    if anomalies != [] do
      log_anomalies(anomalies)

      acc_state = %{state | consecutive_count: state.consecutive_count + 1}

      if acc_state.consecutive_count >= acc_state.consecutive_required do
        acc_state
        |> escalate_anomalies(anomalies)
        |> enter_cooldown()
      else
        acc_state
      end
    else
      %{state | consecutive_count: 0}
    end
  end

  defp check_for_anomaly(state, metric) do
    baseline = BaselineStore.get_baseline(state.baseline_store, metric.skill, metric.metric)

    if baseline && baseline.sample_count > 0 do
      if Statistics.detect_anomaly?(metric.value, baseline, state.z_threshold) do
        {:anomaly, state}
      else
        :normal
      end
    else
      :normal
    end
  end

  defp log_anomalies(anomalies) do
    Enum.each(anomalies, fn anomaly ->
      :telemetry.execute(
        [:beamlens, :anomaly, :detector, :anomaly_detected],
        %{system_time: System.system_time(), value: anomaly.value},
        %{skill: anomaly.skill, metric: anomaly.metric}
      )
    end)
  end

  defp escalate_anomalies(state, anomalies) do
    :telemetry.execute(
      [:beamlens, :anomaly, :detector, :escalation],
      %{system_time: System.system_time(), anomaly_count: length(anomalies)},
      %{anomalies: Enum.map(anomalies, &Map.take(&1, [:skill, :metric, :value]))}
    )

    maybe_trigger_coordinator(state, anomalies)
  end

  defp maybe_trigger_coordinator(%{auto_trigger: false} = state, _anomalies), do: state

  defp maybe_trigger_coordinator(state, anomalies) do
    now = System.system_time(:millisecond)
    recent_triggers = Enum.filter(state.trigger_history, &(now - &1 < @one_hour_ms))

    if length(recent_triggers) >= state.max_triggers_per_hour do
      :telemetry.execute(
        [:beamlens, :anomaly, :detector, :trigger_rate_limited],
        %{system_time: System.system_time(), triggers_in_last_hour: length(recent_triggers)},
        %{max_triggers_per_hour: state.max_triggers_per_hour}
      )

      %{state | trigger_history: recent_triggers}
    else
      trigger_coordinator(anomalies)
      %{state | trigger_history: [now | recent_triggers]}
    end
  end

  defp trigger_coordinator(anomalies) do
    case Process.whereis(Beamlens.TaskSupervisor) do
      nil ->
        :telemetry.execute(
          [:beamlens, :anomaly, :detector, :auto_trigger_failed],
          %{system_time: System.system_time()},
          %{reason: :task_supervisor_not_running}
        )

      _pid ->
        anomaly_summary = format_anomaly_summary(anomalies)

        Task.Supervisor.start_child(Beamlens.TaskSupervisor, fn ->
          run_coordinator(anomaly_summary)
        end)
    end
  end

  defp format_anomaly_summary(anomalies) do
    Enum.map_join(anomalies, ", ", fn a ->
      "#{inspect(a.skill)}.#{a.metric}: #{a.value}"
    end)
  end

  defp run_coordinator(anomaly_summary) do
    case Process.whereis(Beamlens.Coordinator) do
      nil ->
        :telemetry.execute(
          [:beamlens, :anomaly, :detector, :auto_trigger_failed],
          %{system_time: System.system_time()},
          %{reason: :coordinator_not_running}
        )

      _pid ->
        :telemetry.execute(
          [:beamlens, :anomaly, :detector, :auto_trigger_started],
          %{system_time: System.system_time()},
          %{anomaly_summary: anomaly_summary}
        )

        Beamlens.Coordinator.run(%{
          reason: "Detector anomaly escalation",
          anomalies: anomaly_summary
        })
    end
  end

  defp enter_cooldown(state) do
    :telemetry.execute(
      [:beamlens, :anomaly, :detector, :cooldown_started],
      %{system_time: System.system_time(), cooldown_ms: state.cooldown_ms},
      %{}
    )

    %{
      state
      | state: :cooldown,
        cooldown_start_time: System.system_time(:millisecond),
        consecutive_count: 0
    }
  end

  defp check_cooldown_complete(state) do
    elapsed = System.system_time(:millisecond) - state.cooldown_start_time

    if elapsed >= state.cooldown_ms do
      :telemetry.execute(
        [:beamlens, :anomaly, :detector, :cooldown_complete],
        %{system_time: System.system_time(), elapsed_ms: elapsed},
        %{}
      )

      %{state | state: :active, cooldown_start_time: nil}
    else
      state
    end
  end

  @doc """
  Get the current detector state (:learning, :active, or :cooldown).
  """
  def get_state(detector \\ __MODULE__) do
    GenServer.call(detector, :get_state)
  end

  @doc """
  Get detailed status information.
  """
  def get_status(detector \\ __MODULE__) do
    GenServer.call(detector, :get_status)
  end
end
