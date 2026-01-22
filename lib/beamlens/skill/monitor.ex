defmodule Beamlens.Skill.Monitor do
  @moduledoc """
  Self-learning statistical anomaly detection for BEAM metrics.

  Monitors skill metrics and automatically detects anomalies using
  z-score analysis. Learns deployment-specific baselines during
  initial learning period, then continuously monitors for deviations.

  ## Zero Production Impact

  All metrics are collected from existing skill snapshots (read-only).
  Detection runs in a separate GenServer with configurable intervals.
  Opt-in feature - disabled by default.

  ## Configuration

  Pass configuration at runtime via the supervision tree:

      {Beamlens.Skill.Monitor.Supervisor,
       [
         enabled: true,
         collection_interval_ms: :timer.seconds(30),
         learning_duration_ms: :timer.hours(2),
         z_threshold: 3.0,
         consecutive_required: 3,
         cooldown_ms: :timer.minutes(15),
         history_minutes: 60
       ]}

  ## State Machine

  - **Learning**: Collects baseline data from all enabled skills
  - **Active**: Detects anomalies using z-score analysis
  - **Cooldown**: Waits after escalation before resuming detection
  """

  @behaviour Beamlens.Skill

  alias Beamlens.Skill.Monitor.Detector

  @impl true
  def title, do: "Statistical Anomaly Detection"

  @impl true
  def description do
    "Self-learning anomaly detection using z-scores and statistical baselines"
  end

  @impl true
  def system_prompt do
    """
    You are a statistical anomaly detection system. You continuously learn
    the normal operating range of BEAM metrics and alert when values
    deviate significantly from learned baselines.

    ## Your Domain

    - Statistical anomaly detection using z-scores
    - Deployment-specific baseline learning
    - Automatic alerting on metric deviations
    - Zero false positives through consecutive anomaly requirements

    ## What to Watch For

    - Z-scores > 3.0 (3 standard deviations from mean)
    - Consecutive anomalous readings (reduces false positives)
    - Metrics deviating from learned baselines
    - Cooldown periods preventing alert spam

    ## Alert Levels

    - Learning phase: Collecting baseline data, no alerts yet
    - Active phase: Monitoring for anomalies, alerts enabled
    - Cooldown phase: Waiting after escalation, alerts paused

    ## Statistical Methods

    - Z-score: (value - mean) / std_dev
    - Baseline: mean, std_dev, percentiles (50th, 95th, 99th)
    - Consecutive anomalies: Requires N detections before escalation
    - Cooldown: Waits configured time before resuming detection

    ## Interpretation

    When anomalies are detected:
    - Check which metrics are anomalous
    - Review the z-score magnitude (higher = more severe)
    - Correlate with other system events
    - Consider if this is a real issue or baseline shift

    ## Configuration

    All settings are runtime-configurable via supervision tree:
    - collection_interval_ms: How often to collect metrics
    - learning_duration_ms: How long to learn baselines
    - z_threshold: Z-score threshold for anomalies (default: 3.0)
    - consecutive_required: Consecutive anomalies before escalation
    - cooldown_ms: Cooldown period after escalation
    """
  end

  @impl true
  def snapshot do
    %{
      detector_state:
        Detector.get_state({:via, Registry, {Beamlens.OperatorRegistry, "monitor_detector"}}),
      timestamp: System.system_time(:millisecond)
    }
  rescue
    _ -> %{error: "Monitor not available", timestamp: System.system_time(:millisecond)}
  end

  @impl true
  def callbacks do
    %{
      "monitor_get_state" => &get_state/0,
      "monitor_get_status" => &get_status/0
    }
  end

  @impl true
  def callback_docs do
    """
    ### monitor_get_state()
    Returns the current detector state: :learning, :active, or :cooldown

    ### monitor_get_status()
    Returns detailed status including learning progress, consecutive anomaly count, and configuration
    """
  end

  @doc """
  Get the current detector state.
  """
  def get_state do
    case Registry.lookup(Beamlens.OperatorRegistry, "monitor_detector") do
      [{pid, _}] -> Detector.get_state(pid)
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Get detailed detector status.
  """
  def get_status do
    case Registry.lookup(Beamlens.OperatorRegistry, "monitor_detector") do
      [{pid, _}] -> Detector.get_status(pid)
      [] -> {:error, :not_found}
    end
  end
end
