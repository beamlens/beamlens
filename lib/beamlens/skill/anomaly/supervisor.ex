defmodule Beamlens.Skill.Anomaly.Supervisor do
  @moduledoc """
  Supervisor for Anomaly skill components.

  Manages the child processes for the statistical anomaly detection system:

    * `MetricStore` - ETS ring buffer for time-series metric data
    * `BaselineStore` - ETS cache with optional DETS persistence
    * `Detector` - State machine for learning, detection, and cooldown

  The Detector automatically excludes `Beamlens.Skill.Anomaly` from its monitored
  skills to prevent self-referential calls that would cause deadlocks.

  All configuration is passed at runtime via the supervision tree.
  """

  use Supervisor

  alias Beamlens.Skill.Anomaly.BaselineStore
  alias Beamlens.Skill.Anomaly.Detector
  alias Beamlens.Skill.Anomaly.MetricStore

  @default_collection_interval_ms 30_000
  @default_learning_duration_ms :timer.hours(2)
  @default_z_threshold 3.0
  @default_consecutive_required 3
  @default_cooldown_ms :timer.minutes(15)
  @default_history_minutes 60
  @default_auto_trigger true
  @default_max_triggers_per_hour 3

  def start_link(opts) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])

    Supervisor.start_link(__MODULE__, init_opts, gen_opts)
  end

  @impl true
  def init(opts) do
    collection_interval_ms =
      Keyword.get(opts, :collection_interval_ms, @default_collection_interval_ms)

    learning_duration_ms = Keyword.get(opts, :learning_duration_ms, @default_learning_duration_ms)
    z_threshold = Keyword.get(opts, :z_threshold, @default_z_threshold)
    consecutive_required = Keyword.get(opts, :consecutive_required, @default_consecutive_required)
    cooldown_ms = Keyword.get(opts, :cooldown_ms, @default_cooldown_ms)
    history_minutes = Keyword.get(opts, :history_minutes, @default_history_minutes)
    auto_trigger = Keyword.get(opts, :auto_trigger, @default_auto_trigger)

    max_triggers_per_hour =
      Keyword.get(opts, :max_triggers_per_hour, @default_max_triggers_per_hour)

    dets_file = Keyword.get(opts, :dets_file)
    auto_save_interval_ms = Keyword.get(opts, :auto_save_interval_ms, :timer.minutes(5))

    all_skills = Keyword.get(opts, :skills, Beamlens.Supervisor.registered_skills())
    skills = Enum.reject(all_skills, &(&1 == Beamlens.Skill.Anomaly))

    children = [
      {MetricStore,
       [
         name: {:via, Registry, {Beamlens.OperatorRegistry, "monitor_metric_store"}},
         sample_interval_ms: collection_interval_ms,
         history_minutes: history_minutes
       ]},
      {BaselineStore,
       [
         name: {:via, Registry, {Beamlens.OperatorRegistry, "monitor_baseline_store"}},
         ets_table: :beamlens_monitor_baselines,
         dets_file: dets_file,
         auto_save_interval_ms: auto_save_interval_ms
       ]},
      {Detector,
       [
         name: {:via, Registry, {Beamlens.OperatorRegistry, "monitor_detector"}},
         metric_store: {:via, Registry, {Beamlens.OperatorRegistry, "monitor_metric_store"}},
         baseline_store: {:via, Registry, {Beamlens.OperatorRegistry, "monitor_baseline_store"}},
         collection_interval_ms: collection_interval_ms,
         learning_duration_ms: learning_duration_ms,
         z_threshold: z_threshold,
         consecutive_required: consecutive_required,
         cooldown_ms: cooldown_ms,
         skills: skills,
         auto_trigger: auto_trigger,
         max_triggers_per_hour: max_triggers_per_hour
       ]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
