// ============================================================================
// BASELINE LEARNING
// ============================================================================

// Decision: Continue observing to build baseline
class ContinueObserving {
  intent "continue_observing"
  notes string @description(#"Notes to remember for next analysis (patterns noticed, ranges observed, etc.)"#)
  confidence "low" | "medium" @description(#"Confidence in having established a baseline"#)
}

// Decision: Alert - detected anomaly deviation from baseline
class Alert {
  intent "report_anomaly"
  anomaly_type string @description(#"Type of anomaly (e.g., memory_elevated, process_spike, scheduler_contention)"#)
  severity "info" | "warning" | "critical" @description(#"Severity based on deviation from baseline"#)
  summary string @description(#"Brief description of the anomaly"#)
  evidence string[] @description(#"Specific data points supporting the anomaly detection"#)
  confidence "medium" | "high" @description(#"Confidence in anomaly detection"#)
  cooldown_minutes int @description(#"Minutes to suppress re-alerts for this category. Choose based on context."#)
}

// Decision: Healthy - baseline established, all normal
class Healthy {
  intent "report_healthy"
  summary string @description(#"Brief summary of healthy state"#)
  confidence "medium" | "high" @description(#"Confidence that system is operating normally"#)
}

// Main baseline analysis function
function AnalyzeBaseline(messages: Message[]) -> ContinueObserving | Alert | Healthy {
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
Observations (50 total, 2.5 hours):

2024-01-06T12:30:00Z: mem=45.5%, proc=12.3%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T12:25:00Z: mem=44.8%, proc=12.1%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T12:20:00Z: mem=45.2%, proc=12.2%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T12:15:00Z: mem=45.1%, proc=12.0%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T12:10:00Z: mem=44.9%, proc=12.1%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T12:05:00Z: mem=45.3%, proc=12.2%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T12:00:00Z: mem=45.0%, proc=12.1%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T11:55:00Z: mem=44.7%, proc=12.0%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T11:50:00Z: mem=45.4%, proc=12.3%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T11:45:00Z: mem=45.1%, proc=12.2%, port=0.5%, atom=1.2%, rq=0, sched=8
2024-01-06T11:40:00Z: mem=44.6%, proc=11.9%, port=0.5%, atom=1.2%, rq=1, sched=8
2024-01-06T11:35:00Z: mem=45.2%, proc=12.1%, port=0.5%, atom=1.2%, rq=0, sched=8

Previous notes: Baseline established. Memory consistently 44.5-45.5% for 2+ hours. Process usage stable at 12%. Run queue typically 0, rare spike to 1 is normal. All metrics within tight variance - this system is healthy and stable."#}
    ]
  }
  @@assert(reports_healthy, {{ this.intent == "report_healthy" }})
  @@assert(high_confidence, {{ this.confidence == "high" }})
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

// ============================================================================
// WATCHER INVESTIGATION
// ============================================================================

// Findings produced by watcher investigation
class WatcherFindings {
  anomaly_type string @description(#"Type of anomaly investigated (e.g., memory_elevated, scheduler_contention)"#)
  severity "info" | "warning" | "critical" @description(#"Final assessed severity"#)
  root_cause string @description(#"Identified or suspected root cause"#)
  evidence string[] @description(#"Data points supporting the findings"#)
  recommendations string[] @description(#"Actionable recommendations"#)
  confidence "low" | "medium" | "high" @description(#"Confidence in findings"#)
}

// Decision: Investigation complete with findings
class InvestigationComplete {
  intent "investigation_complete"
  findings WatcherFindings @description(#"Detailed investigation findings"#)
}

// Tool selection for watcher investigation loop
// First message contains alert context, subsequent messages are tool results
function SelectInvestigationTool(messages: Message[]) -> GetOverview | GetSystemInfo | GetMemoryStats | GetProcessStats | GetSchedulerStats | GetAtomStats | GetPersistentTerms | GetTopProcesses | InvestigationComplete {
  client Default
  prompt #"
{{ _.role("system") }}
You are a specialized BEAM VM watcher that just detected an anomaly.
Your job is to investigate deeper and produce detailed findings.

The first message contains the alert context. Subsequent messages show tool calls and results.

## Investigation Goals
1. Gather additional data relevant to the anomaly type
2. Identify the root cause or likely causes
3. Assess the true severity based on evidence
4. Provide actionable recommendations

## Tool Selection Guide
- get_overview: Start here for quick health check
- get_memory_stats: For memory-related anomalies
- get_process_stats: For process count or limit concerns
- get_scheduler_stats: For run queue or scheduler issues
- get_atom_stats: For atom table concerns
- get_top_processes: To identify resource-hungry processes

## When to Complete Investigation
Return InvestigationComplete when:
- You have enough evidence to explain the anomaly
- You can identify a root cause (or likely cause)
- You have actionable recommendations
- Further tool calls won't provide new insights

Do NOT rush to conclusions. Gather 2-3 relevant data points before completing.

{% for msg in messages %}
{{ _.role(msg.role) }}
{{ msg.content }}
{% endfor %}

{{ ctx.output_format }}
"#
}

// ============================================================================
// INVESTIGATION TESTS
// ============================================================================

test SelectInvestigationTool_MemoryAlert_GathersData {
  functions [SelectInvestigationTool]
  args {
    messages [
      { role "user", content #"[ALERT CONTEXT]
Anomaly detected: memory_elevated
Severity: warning
Summary: Memory usage at 72% exceeds baseline of 45%"# }
    ]
  }
  @@assert(starts_investigation, {{
    this.intent == "get_overview" or
    this.intent == "get_memory_stats" or
    this.intent == "get_top_processes"
  }})
}

test SelectInvestigationTool_SchedulerAlert_GathersData {
  functions [SelectInvestigationTool]
  args {
    messages [
      { role "user", content #"[ALERT CONTEXT]
Anomaly detected: scheduler_contention
Severity: warning
Summary: Run queue at 85, significantly above baseline of 0-2"# }
    ]
  }
  @@assert(investigates_schedulers, {{
    this.intent == "get_overview" or
    this.intent == "get_scheduler_stats" or
    this.intent == "get_process_stats"
  }})
}

test SelectInvestigationTool_CompletesWithFindings {
  functions [SelectInvestigationTool]
  args {
    messages [
      { role "user", content #"[ALERT CONTEXT]
Anomaly detected: memory_elevated
Severity: warning
Summary: Memory usage trending upward"# },
      { role "assistant", content #"{"intent":"get_memory_stats"}"# },
      { role "user", content #"{"total_mb":10000.0,"processes_mb":6500.0,"processes_used_mb":6200.0,"system_mb":2000.0,"binary_mb":800.0,"ets_mb":400.0,"code_mb":300.0}"# },
      { role "assistant", content #"{"intent":"get_top_processes"}"# },
      { role "user", content #"{"total_processes":50000,"showing":10,"offset":0,"limit":10,"sort_by":"memory_kb","processes":[{"pid":"<0.500.0>","memory_kb":512000,"message_queue_len":0,"reductions":1000000,"current_function":"gen_server:loop/7","registered_name":"cache_server"}]}"# }
    ]
  }
  @@assert(completes_or_continues, {{
    this.intent == "investigation_complete" or
    this.intent == "get_process_stats" or
    this.intent == "get_scheduler_stats"
  }})
}
