// BeamLens BAML definitions

client<llm> Haiku {
  provider anthropic
  options {
    model "claude-haiku-4-5-20250514"
    api_key env.ANTHROPIC_API_KEY
  }
}

class BeamMetrics {
  otp_release string
  schedulers_online int
  memory MemoryStats
  process_count int
  port_count int
  uptime_seconds int
  run_queue int
}

class MemoryStats {
  total_mb float
  processes_mb float
  atom_mb float
  binary_mb float
  ets_mb float
}

class HealthReport {
  status string @description("Overall status: healthy, warning, or critical")
  summary string @description("Brief 1-2 sentence summary")
  concerns string[] @description("List of any concerns found, empty if none")
  metrics_snapshot BeamMetrics @description("The metrics that were analyzed")
}

function AnalyzeBeamHealth(metrics: BeamMetrics) -> HealthReport {
  client Haiku
  prompt #"
    You are a BEAM VM health analyst. Analyze these metrics and provide a health report.

    Current BEAM VM Metrics:
    - OTP Release: {{ metrics.otp_release }}
    - Schedulers Online: {{ metrics.schedulers_online }}
    - Memory:
      - Total: {{ metrics.memory.total_mb }} MB
      - Processes: {{ metrics.memory.processes_mb }} MB
      - Atoms: {{ metrics.memory.atom_mb }} MB
      - Binaries: {{ metrics.memory.binary_mb }} MB
      - ETS: {{ metrics.memory.ets_mb }} MB
    - Process Count: {{ metrics.process_count }}
    - Port Count: {{ metrics.port_count }}
    - Uptime: {{ metrics.uptime_seconds }} seconds
    - Run Queue: {{ metrics.run_queue }}

    Evaluation criteria:
    - run_queue > 0 indicates scheduler backpressure (warning if > 1, critical if > schedulers)
    - Process count should typically be < 100,000 for most apps
    - Memory growth patterns (if available from context)

    {{ ctx.output_format }}
  "#
}
