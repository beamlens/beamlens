// ============================================================================
// BASELINE LEARNING
// ============================================================================

// Decision: Continue observing to build baseline
class ContinueObserving {
  intent "continue_observing"
  notes string @description(#"Notes to remember for next analysis (patterns noticed, ranges observed, etc.)"#)
  confidence "low" | "medium" @description(#"Confidence in having established a baseline"#)
}

// Decision: Report an anomaly to the orchestrator
class ReportAnomaly {
  intent "report_anomaly"
  anomaly_type string @description(#"Type of anomaly (e.g., memory_elevated, process_spike, scheduler_contention)"#)
  severity "info" | "warning" | "critical" @description(#"Severity based on deviation from baseline"#)
  summary string @description(#"Brief description of the anomaly"#)
  evidence string[] @description(#"Specific data points supporting the anomaly detection"#)
  confidence "medium" | "high" @description(#"Confidence in anomaly detection"#)
  cooldown_minutes int @description(#"Minutes to suppress re-alerts for this category. Choose based on context."#)
}

// Decision: Report healthy status (baseline established, all normal)
class ReportHealthy {
  intent "report_healthy"
  summary string @description(#"Brief summary of healthy state"#)
  confidence "medium" | "high" @description(#"Confidence that system is operating normally"#)
}

// Main baseline analysis function
function AnalyzeBaseline(messages: Message[]) -> ContinueObserving | ReportAnomaly | ReportHealthy {
  client Default
  prompt #"
{{ _.role("system") }}
You are a baseline analyzer. Your job is to observe metrics over time,
learn what "normal" looks like for THIS specific application, and report anomalies
only when you have confidence they deviate from the established baseline.

Analyze the raw observations directly to establish patterns and detect deviations.
Use your notes to track what you've learned about this system's normal behavior.

## Decision Guidelines

### ContinueObserving
Return this when:
- You need more data points to establish a baseline (typically < 10 observations)
- Patterns are still emerging and you're not confident in what's "normal"
- Metrics are varying but within reasonable ranges for baseline establishment
- You noticed something worth watching but it's not yet anomalous

Store useful notes like:
- Observed ranges (e.g., "memory typically 40-50%")
- Patterns (e.g., "run_queue spikes briefly then settles")
- Suspicious trends (e.g., "memory has increased 3 observations in a row")

### ReportAnomaly
Return this when:
- A metric has sustained deviation (3+ consecutive readings) from established baseline
- A sudden spike exceeds 2x the typical variance you've observed
- Critical thresholds are approached regardless of baseline (>90% utilization)
- A clear trend toward resource exhaustion is detected

Severity guidelines:
- info: Unusual but not concerning, worth noting
- warning: Sustained deviation requiring attention
- critical: Immediate risk of resource exhaustion or system impact

### ReportHealthy
Return this when:
- You have enough observations to be confident in the baseline (typically 10+)
- Current metrics are within the established normal range
- No concerning trends are present
- You want to signal that monitoring is working and all is well

{% for message in messages %}
{{ _.role(message.role) }}
{{ message.content }}
{% endfor %}

Based on the observations and your accumulated knowledge, what is your decision?

{{ ctx.output_format }}
"#
}

// ============================================================================
// BASELINE TESTS
// ============================================================================

test AnalyzeBaseline_ColdStart {
  functions [AnalyzeBaseline]
  args {
    messages [
      {role "user", content #"Domain: beam
Observations (3 total, 0.05 hours):

2024-01-06T10:05:00Z: mem=45.5%, proc=12.3%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T10:04:00Z: mem=44.8%, proc=12.1%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T10:03:00Z: mem=45.2%, proc=12.2%, port=0.5%, atom=1.2%, rq=0, sched=8"#}
    ]
  }
  @@assert(continues_observing, {{ this.intent == "continue_observing" }})
  @@assert(low_confidence, {{ this.confidence == "low" }})
}

test AnalyzeBaseline_EstablishedBaseline_Healthy {
  functions [AnalyzeBaseline]
  args {
    messages [
      {role "user", content #"Domain: beam
Observations (15 total, 0.25 hours):

2024-01-06T10:15:00Z: mem=45.5%, proc=12.3%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T10:14:00Z: mem=44.8%, proc=12.1%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T10:13:00Z: mem=45.2%, proc=12.2%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T10:12:00Z: mem=46.1%, proc=12.5%, port=0.5%, atom=1.2%, rq=1, sched=8
2024-01-06T10:11:00Z: mem=44.5%, proc=11.9%, port=0.5%, atom=1.2%, rq=0, sched=8

Previous notes: Memory stable around 45%, occasional run queue of 1"#}
    ]
  }
  @@assert(reports_healthy, {{ this.intent == "report_healthy" }})
  @@assert(confident, {{ this.confidence == "medium" or this.confidence == "high" }})
}

test AnalyzeBaseline_SustainedDeviation {
  functions [AnalyzeBaseline]
  args {
    messages [
      {role "user", content #"Domain: beam
Observations (20 total, 0.33 hours):

2024-01-06T10:15:00Z: mem=72.5%, proc=12.3%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T10:14:00Z: mem=70.8%, proc=12.1%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T10:13:00Z: mem=68.2%, proc=12.2%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T10:12:00Z: mem=65.1%, proc=12.5%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T10:11:00Z: mem=45.5%, proc=11.9%, port=0.5%, atom=1.2%, rq=0, sched=8

Previous notes: Memory stable around 45%, occasional run queue of 1"#}
    ]
  }
  @@assert(reports_anomaly, {{ this.intent == "report_anomaly" }})
  @@assert(memory_related, {{ this.anomaly_type|lower|regex_match("memory") }})
}

test AnalyzeBaseline_CriticalThreshold {
  functions [AnalyzeBaseline]
  args {
    messages [
      {role "user", content #"Domain: beam
Observations (12 total, 0.2 hours):

2024-01-06T10:15:00Z: mem=92.5%, proc=12.3%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T10:14:00Z: mem=91.8%, proc=12.1%, port=0.5%, atom=1.2%, rq=0, sched=8

Previous notes: Memory stable around 45%"#}
    ]
  }
  @@assert(reports_anomaly, {{ this.intent == "report_anomaly" }})
  @@assert(critical_severity, {{ this.severity == "critical" }})
}

test AnalyzeBaseline_SchedulerContention {
  functions [AnalyzeBaseline]
  args {
    messages [
      {role "user", content #"Domain: beam
Observations (15 total, 0.25 hours):

2024-01-06T10:15:00Z: mem=45.5%, proc=12.3%, port=0.5%, atom=1.2%, rq=85, sched=8
2024-01-06T10:14:00Z: mem=45.8%, proc=12.1%, port=0.5%, atom=1.2%, rq=78, sched=8
2024-01-06T10:13:00Z: mem=45.2%, proc=12.2%, port=0.5%, atom=1.2%, rq=92, sched=8
2024-01-06T10:12:00Z: mem=45.1%, proc=12.5%, port=0.5%, atom=1.2%, rq=45, sched=8
2024-01-06T10:11:00Z: mem=45.5%, proc=11.9%, port=0.5%, atom=1.2%, rq=2, sched=8

Previous notes: Run queue typically 0-2"#}
    ]
  }
  @@assert(reports_anomaly, {{ this.intent == "report_anomaly" }})
  @@assert(scheduler_related, {{
    this.anomaly_type|lower|regex_match("scheduler|run_queue|contention|queue|spike")
  }})
}

test AnalyzeBaseline_GradualTrend {
  functions [AnalyzeBaseline]
  args {
    messages [
      {role "user", content #"Domain: beam
Observations (12 total, 0.2 hours):

2024-01-06T10:15:00Z: mem=78.5%, proc=12.3%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T10:14:00Z: mem=72.8%, proc=12.1%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T10:13:00Z: mem=66.2%, proc=12.2%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T10:12:00Z: mem=59.1%, proc=12.5%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T10:11:00Z: mem=52.5%, proc=11.9%, port=0.5%, atom=1.2%, rq=0, sched=8

Previous notes: Memory stable around 45%"#}
    ]
  }
  @@assert(reports_anomaly, {{ this.intent == "report_anomaly" }})
  @@assert(memory_related, {{ this.anomaly_type|lower|regex_match("memory|trend|leak") }})
}
