// BeamLens BAML definitions
// Note: This placeholder client is overridden at runtime via client_registry

client<llm> Default {
  provider anthropic
  options {
    model "claude-haiku-4-5-20251001"
  }
}

class HealthAnalysis {
  status "healthy" | "warning" | "critical" @description(#"Overall health status"#)
  summary string @description(#"Brief 1-2 sentence summary. Include key percentage values calculated from metrics."#)
    @check(has_summary, {{ this|length > 10 }})
    @check(not_too_long, {{ this|length < 500 }})
  concerns string[] @description(#"List of concerns found. MUST be empty for healthy status."#)
  recommendations string[] @description(#"Actionable recommendations. Keep minimal or empty for healthy status."#)
  reasoning string @description(#"Brief explanation of how you arrived at this assessment"#)
  @@assert(concerns_match_status, {{
    (this.status == "healthy" and this.concerns|length == 0) or
    this.status != "healthy"
  }})
  @@assert(healthy_minimal_recommendations, {{
    this.status != "healthy" or this.recommendations|length <= 1
  }})
}

// Tool classes with intent literals for disambiguation (per BAML docs pattern)

class GetOverview {
  intent "get_overview" @description(#"Get high-level utilization percentages across all categories"#)
}

class GetSystemInfo {
  intent "get_system_info" @description(#"Get node identity and context (OTP version, uptime, schedulers)"#)
}

class GetMemoryStats {
  intent "get_memory_stats" @description(#"Get detailed memory statistics for leak detection"#)
}

class GetProcessStats {
  intent "get_process_stats" @description(#"Get process/port counts and limits for capacity check"#)
}

class GetSchedulerStats {
  intent "get_scheduler_stats" @description(#"Get scheduler details and run queues for performance analysis"#)
}

class GetAtomStats {
  intent "get_atom_stats" @description(#"Get atom table metrics when suspecting atom leaks"#)
}

class GetPersistentTerms {
  intent "get_persistent_terms" @description(#"Get persistent term usage statistics"#)
}

class GetTopProcesses {
  intent "get_top_processes" @description(#"Drill into top processes by resource usage"#)
  limit int? @description(#"Max processes to return (1-50, default 10)"#)
  offset int? @description(#"Skip first N processes (default 0)"#)
  sort_by "memory" | "message_queue" | "reductions" @description(#"Sort by memory, message_queue, or reductions"#)
}

class Done {
  intent "done"
  analysis HealthAnalysis @description(#"Final health analysis"#)
}

class Message {
  role string @description(#"assistant or tool"#)
  content string @description(#"JSON content"#)
}

// Union type - LLM picks exactly one tool
function SelectTool(messages: Message[]) -> GetOverview | GetSystemInfo | GetMemoryStats | GetProcessStats | GetSchedulerStats | GetAtomStats | GetPersistentTerms | GetTopProcesses | Done {
  client Default
  prompt #"
You are a BEAM VM health analyst. The first message contains a complete snapshot of all VM metrics.

## SNAPSHOT-FIRST ANALYSIS
The snapshot includes:
- system_info: Node identity, OTP version, uptime, schedulers
- memory_stats: Detailed memory breakdown (total_mb, processes_mb, system_mb, binary_mb, ets_mb, code_mb)
- process_stats: Process/port counts and limits
- scheduler_stats: Scheduler details and run_queue
- atom_stats: Atom table metrics
- persistent_terms: Persistent term usage
- overview: Pre-calculated utilization percentages
- top_processes: Top 10 processes by memory

## ANALYSIS APPROACH
Use your judgment to assess VM health based on the metrics. Consider:
- Resource utilization levels and how they relate to limits
- Run queue depth relative to available schedulers
- Memory distribution across categories (processes, binary, ETS)
- Any unusual patterns or concerning trends

## WHEN TO RETURN DONE (PREFERRED)
Return Done immediately if:
- The snapshot provides all information needed for assessment
- No anomalies require deeper investigation
- You can determine health status from the data provided

## WHEN TO CALL ADDITIONAL TOOLS (RARE)
Only call tools if you need:
- get_top_processes with different sorting (message_queue, reductions)
- Pagination to see more than the initial 10 processes

## OUTPUT GUIDELINES
- healthy: Concerns = [], Recommendations = [] or at most one minor suggestion
- warning: List specific concerns with percentages
- critical: State urgent issues with exact numbers

Include your reasoning in the analysis.reasoning field.

## Conversation
{% for msg in messages %}
[{{ msg.role }}]: {{ msg.content }}
{% endfor %}

Select your next action:
{{ ctx.output_format }}
"#
}

// ============================================================================
// JUDGE AGENT
// ============================================================================

class AnalysisInput {
  status "healthy" | "warning" | "critical" @description(#"Health status determined by the analysis"#)
  summary string @description(#"Summary of the analysis findings"#)
  concerns string[] @description(#"List of concerns identified"#)
  recommendations string[] @description(#"List of recommendations"#)
}

class JudgeFeedback {
  @@description(#"The analysis being evaluated"#)

  verdict "accept" | "retry" @description(#""accept" if analysis status and concerns correctly match calculated memory thresholds. "retry" ONLY if: (1) memory >= 60% but status is "healthy" with no memory concerns, OR (2) memory < 60% but status is "warning"/"critical", OR (3) data sufficiency not met. Do NOT retry for summary wording issues."#)
  confidence "high" | "medium" | "low" @description(#"Confidence level in the verdict"#)
  issues string[] @description(#"List of specific issues found. MUST be empty array [] if verdict is accept. Only include issues when verdict is retry."#)
  feedback string @description(#"Detailed guidance for retry. MUST be empty string if verdict is accept."#)
  @@assert(issues_match_verdict, {{
    (this.verdict == "accept" and this.issues|length == 0) or
    this.verdict == "retry"
  }})
  @@assert(feedback_when_retry, {{
    (this.verdict == "retry" and this.feedback|length > 10) or
    this.verdict == "accept"
  }})
}

function JudgeAnalysis(
  analysis: AnalysisInput,
  event_trail: string,
  attempt: int
) -> JudgeFeedback {
  client Default
  prompt #"
{{ _.role("system") }}
You are a quality reviewer for BEAM VM health analyses. Your job is to verify that
the analysis conclusions are supported by the collected data.

## Evaluation Criteria

### 1. Data Sufficiency
- The analysis should be based on sufficient metrics
- At minimum: system_info + 2 other metric categories
- If NOT met → verdict: "retry"

### 2. Status-Data Consistency
- The status should reflect the collected metrics
- "healthy" status should have no significant resource concerns
- "warning" or "critical" should identify the specific concerns with data backing

### 3. Status-Concern Consistency
- "healthy" status MUST have empty concerns list
- "warning" or "critical" MUST have at least one concern

### 4. Accept Valid Analyses (Be Lenient)
- Focus on whether conclusions are supported by data
- Do NOT require perfect wording - focus on STATUS and CONCERNS correctness
- Minor imprecision in summaries is acceptable if the overall assessment is correct

{{ _.role("user") }}
## Analysis Under Review
Status: {{ analysis.status }}
Summary: {{ analysis.summary }}
Concerns: {{ analysis.concerns }}
Recommendations: {{ analysis.recommendations }}

## Data Collection Trail (Events)
{{ event_trail }}

## Your Evaluation Process

1. Review the collected metrics in the event trail
2. Assess whether the status reflects the actual resource utilization levels
3. Verify that concerns (if any) are supported by the data
4. Check that the status and concerns are internally consistent

Verdict:
- "accept" if the analysis conclusions are reasonably supported by the data
- "retry" if there are significant mismatches between data and conclusions

## Attempt {{ attempt }} of 3

{% if attempt > 1 %}
This is a retry. Focus on whether prior feedback was addressed.
{% endif %}

{{ ctx.output_format }}
"#
}

// ============================================================================
// TESTS
// ============================================================================

// Phase 1: Minimum Viable Tests

test SelectTool_WithSnapshot_Healthy {
  functions [SelectTool]
  args {
    messages [
      { role "tool", content #"{"system_info":{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":3600,"schedulers_online":8},"memory_stats":{"total_mb":512,"processes_mb":100,"processes_used_mb":90,"system_mb":200,"binary_mb":50,"ets_mb":20,"code_mb":40},"process_stats":{"process_count":500,"process_limit":262144,"port_count":50,"port_limit":65536},"scheduler_stats":{"schedulers":8,"schedulers_online":8,"dirty_cpu_schedulers_online":8,"dirty_io_schedulers":10,"run_queue":0},"atom_stats":{"atom_count":25000,"atom_limit":2097152,"atom_mb":2.5,"atom_used_mb":2.3},"persistent_terms":{"count":10,"memory_mb":0.5},"overview":{"memory_utilization_pct":58.6,"process_utilization_pct":0.19,"port_utilization_pct":0.08,"atom_utilization_pct":1.2,"scheduler_run_queue":0,"schedulers_online":8},"top_processes":{"total_processes":500,"showing":10,"offset":0,"limit":10,"sort_by":"memory_kb","processes":[]}}"# }
    ]
  }
  @@assert(returns_done_healthy, {{ this.intent == "done" and this.analysis.status == "healthy" }})
}

test SelectTool_AfterSystemInfo {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"nonode@nohost","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":3600,"schedulers_online":8}"# }
    ]
  }
  @@assert(continues_analysis, {{ this.intent != "done" }})
}

// Phase 4: Extended Tests

test SelectTool_HighMemoryScenario {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":86400,"schedulers_online":16}"# },
      { role "assistant", content #"{"intent":"get_memory_stats"}"# },
      { role "tool", content #"{"total_mb":15000.0,"processes_mb":8000.0,"processes_used_mb":7500.0,"system_mb":5000.0,"binary_mb":4500.0,"ets_mb":1200.0,"code_mb":500.0}"# }
    ]
  }
  @@assert(warning_if_done, {{
    this.intent != "done" or this.analysis.status == "warning"
  }})
}

test SelectTool_ProcessLimitWarning {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":86400,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_process_stats"}"# },
      { role "tool", content #"{"process_count":200000,"process_limit":262144,"port_count":25,"port_limit":65536}"# }
    ]
  }
  @@assert(warning_if_done, {{
    this.intent != "done" or this.analysis.status == "warning"
  }})
}

test SelectTool_Boundary_Process70Percent {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":86400,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_process_stats"}"# },
      { role "tool", content #"{"process_count":183500,"process_limit":262144,"port_count":25,"port_limit":65536}"# }
    ]
  }
  @@assert(warning_if_done, {{
    this.intent != "done" or this.analysis.status == "warning"
  }})
}

test SelectTool_Boundary_Process90Percent {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":86400,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_process_stats"}"# },
      { role "tool", content #"{"process_count":235500,"process_limit":262144,"port_count":25,"port_limit":65536}"# }
    ]
  }
  @@assert(critical_if_done, {{
    this.intent != "done" or this.analysis.status == "critical"
  }})
}

test SelectTool_Boundary_Memory70Percent {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":86400,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_memory_stats"}"# },
      { role "tool", content #"{"total_mb":10000.0,"processes_mb":6000.0,"processes_used_mb":5800.0,"system_mb":2000.0,"binary_mb":700.0,"ets_mb":300.0,"code_mb":200.0}"# }
    ]
  }
  @@assert(warning_if_done, {{
    this.intent != "done" or this.analysis.status == "warning"
  }})
}

test SelectTool_Boundary_RunQueueHigh {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":3600,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_scheduler_stats"}"# },
      { role "tool", content #"{"schedulers":8,"schedulers_online":8,"dirty_cpu_schedulers_online":8,"dirty_io_schedulers":10,"run_queue":160}"# }
    ]
  }
  @@assert(critical_if_done, {{
    this.intent != "done" or this.analysis.status == "critical"
  }})
}

test SelectTool_NotDoneWithSingleMetric {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"nonode@nohost","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":3600,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_memory_stats"}"# },
      { role "tool", content #"{"total_mb":256.5,"processes_mb":45.2,"processes_used_mb":40.0,"system_mb":100.0,"binary_mb":12.3,"ets_mb":8.1,"code_mb":32.0}"# }
    ]
  }
  @@assert(continues_analysis, {{ this.intent != "done" }})
}

test SelectTool_HealthySystemDone {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_overview"}"# },
      { role "tool", content #"{"memory_utilization_pct":58.6,"process_utilization_pct":0.19,"port_utilization_pct":0.08,"atom_utilization_pct":2.5,"scheduler_run_queue":0,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_memory_stats"}"# },
      { role "tool", content #"{"total_mb":512.0,"processes_mb":100.0,"processes_used_mb":90.0,"system_mb":200.0,"binary_mb":50.0,"ets_mb":20.0,"code_mb":40.0}"# },
      { role "assistant", content #"{"intent":"get_process_stats"}"# },
      { role "tool", content #"{"process_count":500,"process_limit":262144,"port_count":50,"port_limit":65536}"# },
      { role "assistant", content #"{"intent":"get_scheduler_stats"}"# },
      { role "tool", content #"{"schedulers":8,"schedulers_online":8,"dirty_cpu_schedulers_online":8,"dirty_io_schedulers":10,"run_queue":0}"# }
    ]
  }
  @@assert(is_done, {{ this.intent == "done" }})
}

// ============================================================================
// EDGE CASE TESTS
// ============================================================================

// Process count at 95% of limit - should detect as critical if it concludes
test SelectTool_EdgeCase_ProcessExhaustion {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":604800,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_process_stats"}"# },
      { role "tool", content #"{"process_count":250000,"process_limit":262144,"port_count":25,"port_limit":65536}"# }
    ]
  }
  @@assert(critical_if_done, {{
    this.intent != "done" or this.analysis.status == "critical"
  }})
}

// Atom table near exhaustion - dangerous condition
test SelectTool_EdgeCase_AtomExhaustion {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":2592000,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_atom_stats"}"# },
      { role "tool", content #"{"atom_count":1800000,"atom_limit":2097152,"atom_mb":95.5,"atom_used_mb":92.3}"# }
    ]
  }
  @@assert(warning_if_done, {{
    this.intent != "done" or this.analysis.status == "warning"
  }})
}

// High run queue indicates scheduler contention
test SelectTool_EdgeCase_SchedulerContention {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":3600,"schedulers_online":4}"# },
      { role "assistant", content #"{"intent":"get_scheduler_stats"}"# },
      { role "tool", content #"{"schedulers":4,"schedulers_online":4,"dirty_cpu_schedulers_online":4,"dirty_io_schedulers":10,"run_queue":150}"# }
    ]
  }
  @@assert(critical_if_done, {{
    this.intent != "done" or this.analysis.status == "critical"
  }})
}

// Binary memory leak pattern - binary_mb much higher than expected
test SelectTool_EdgeCase_BinaryMemoryLeak {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":259200,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_memory_stats"}"# },
      { role "tool", content #"{"total_mb":8000.0,"processes_mb":500.0,"processes_used_mb":450.0,"system_mb":2000.0,"binary_mb":5200.0,"ets_mb":100.0,"code_mb":200.0}"# }
    ]
  }
  @@assert(warning_if_done, {{
    this.intent != "done" or this.analysis.status == "warning"
  }})
}

// Conflicting signals - some metrics good, some concerning
test SelectTool_EdgeCase_MixedSignals {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":86400,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_memory_stats"}"# },
      { role "tool", content #"{"total_mb":512.0,"processes_mb":100.0,"processes_used_mb":90.0,"system_mb":200.0,"binary_mb":50.0,"ets_mb":20.0,"code_mb":40.0}"# },
      { role "assistant", content #"{"intent":"get_process_stats"}"# },
      { role "tool", content #"{"process_count":240000,"process_limit":262144,"port_count":50,"port_limit":65536}"# }
    ]
  }
  @@assert(warning_if_done, {{
    this.intent != "done" or this.analysis.status == "warning"
  }})
}

// Port/file descriptor exhaustion - can't accept new connections
test SelectTool_EdgeCase_PortExhaustion {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":172800,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_process_stats"}"# },
      { role "tool", content #"{"process_count":5000,"process_limit":262144,"port_count":62000,"port_limit":65536}"# }
    ]
  }
  @@assert(critical_if_done, {{
    this.intent != "done" or this.analysis.status == "critical"
  }})
}

// ETS table explosion - unbounded cache or state accumulation
test SelectTool_EdgeCase_ETSExplosion {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":604800,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_memory_stats"}"# },
      { role "tool", content #"{"total_mb":12000.0,"processes_mb":800.0,"processes_used_mb":750.0,"system_mb":4000.0,"binary_mb":200.0,"ets_mb":6500.0,"code_mb":300.0}"# }
    ]
  }
  @@assert(warning_if_done, {{
    this.intent != "done" or this.analysis.status == "warning"
  }})
}

// Persistent term abuse - too many terms causing GC pressure on spawns
test SelectTool_EdgeCase_PersistentTermAbuse {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":86400,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_persistent_terms"}"# },
      { role "tool", content #"{"count":50000,"memory_mb":2048.0}"# }
    ]
  }
  @@assert(warning_if_done, {{
    this.intent != "done" or this.analysis.status == "warning"
  }})
}

// Schedulers offline - config issue or unexpected state
test SelectTool_EdgeCase_SchedulersOffline {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":3600,"schedulers_online":2}"# },
      { role "assistant", content #"{"intent":"get_scheduler_stats"}"# },
      { role "tool", content #"{"schedulers":8,"schedulers_online":2,"dirty_cpu_schedulers_online":2,"dirty_io_schedulers":10,"run_queue":45}"# }
    ]
  }
  @@assert(warning_if_done, {{
    this.intent != "done" or this.analysis.status == "warning"
  }})
}

// Memory pressure but metrics don't add up - fragmentation or hidden allocator
test SelectTool_EdgeCase_UnexplainedMemory {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":1209600,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_memory_stats"}"# },
      { role "tool", content #"{"total_mb":16000.0,"processes_mb":1000.0,"processes_used_mb":900.0,"system_mb":8000.0,"binary_mb":500.0,"ets_mb":200.0,"code_mb":300.0}"# }
    ]
  }
  @@assert(warning_if_done, {{
    this.intent != "done" or this.analysis.status == "warning"
  }})
}

// Fresh start baseline - just booted, minimal load
test SelectTool_EdgeCase_FreshStart {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":60,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_memory_stats"}"# },
      { role "tool", content #"{"total_mb":256.0,"processes_mb":45.0,"processes_used_mb":40.0,"system_mb":120.0,"binary_mb":10.0,"ets_mb":5.0,"code_mb":70.0}"# },
      { role "assistant", content #"{"intent":"get_process_stats"}"# },
      { role "tool", content #"{"process_count":85,"process_limit":262144,"port_count":12,"port_limit":65536}"# }
    ]
  }
  @@assert(healthy_if_done, {{
    this.intent != "done" or this.analysis.status == "healthy"
  }})
}

// Very long uptime with subtle leak signs
test SelectTool_EdgeCase_LongUptimeSlowLeak {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":7776000,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_memory_stats"}"# },
      { role "tool", content #"{"total_mb":4000.0,"processes_mb":2200.0,"processes_used_mb":2100.0,"system_mb":1200.0,"binary_mb":300.0,"ets_mb":150.0,"code_mb":150.0}"# },
      { role "assistant", content #"{"intent":"get_atom_stats"}"# },
      { role "tool", content #"{"atom_count":950000,"atom_limit":2097152,"atom_mb":52.0,"atom_used_mb":50.0}"# }
    ]
  }
  @@assert(warning_if_done, {{
    this.intent != "done" or this.analysis.status == "warning"
  }})
}

// ============================================================================
// ANOMALY DETECTION TESTS (from eval harness learnings)
// ============================================================================

// Binary memory > 25% of total indicates potential binary leak
test SelectTool_Anomaly_BinaryMemoryLeak {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":604800,"schedulers_online":16}"# },
      { role "assistant", content #"{"intent":"get_memory_stats"}"# },
      { role "tool", content #"{"total_mb":15000.0,"processes_mb":8000.0,"processes_used_mb":7500.0,"system_mb":5000.0,"binary_mb":4500.0,"ets_mb":1200.0,"code_mb":500.0}"# },
      { role "assistant", content #"{"intent":"get_process_stats"}"# },
      { role "tool", content #"{"process_count":75000,"process_limit":262144,"port_count":1000,"port_limit":65536}"# }
    ]
  }
  // binary_mb 4500/15000 = 30% > 25% threshold
  @@assert(warning_if_done, {{
    this.intent != "done" or this.analysis.status == "warning"
  }})
}

// Run queue > schedulers * 10 indicates scheduler contention
test SelectTool_Anomaly_SchedulerContention {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":3600,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_scheduler_stats"}"# },
      { role "tool", content #"{"schedulers":8,"schedulers_online":8,"dirty_cpu_schedulers_online":8,"dirty_io_schedulers":10,"run_queue":120}"# },
      { role "assistant", content #"{"intent":"get_memory_stats"}"# },
      { role "tool", content #"{"total_mb":2048.0,"processes_mb":800.0,"processes_used_mb":750.0,"system_mb":600.0,"binary_mb":200.0,"ets_mb":100.0,"code_mb":150.0}"# }
    ]
  }
  // run_queue 120 > schedulers_online 8 * 10 = 80
  @@assert(warning_if_done, {{
    this.intent != "done" or this.analysis.status == "warning"
  }})
}

// Memory usage at ~80% should be warning (processes + system / total)
test SelectTool_Anomaly_Memory80Percent {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":86400,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_memory_stats"}"# },
      { role "tool", content #"{"total_mb":10000.0,"processes_mb":6000.0,"processes_used_mb":5800.0,"system_mb":2000.0,"binary_mb":700.0,"ets_mb":300.0,"code_mb":200.0}"# },
      { role "assistant", content #"{"intent":"get_process_stats"}"# },
      { role "tool", content #"{"process_count":50000,"process_limit":262144,"port_count":500,"port_limit":65536}"# }
    ]
  }
  // processes_mb + system_mb = 8000/10000 = 80% > 60% threshold
  @@assert(warning_if_done, {{
    this.intent != "done" or this.analysis.status == "warning"
  }})
}

// Verify get_top_processes is parsed correctly with parameters
test SelectTool_GetTopProcesses_WithParams {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_overview"}"# },
      { role "tool", content #"{"memory_utilization_pct":67.1,"process_utilization_pct":64.9,"port_utilization_pct":0.3,"atom_utilization_pct":5.0,"scheduler_run_queue":2,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_process_stats"}"# },
      { role "tool", content #"{"process_count":170000,"process_limit":262144,"port_count":200,"port_limit":65536}"# },
      { role "assistant", content #"{"intent":"get_memory_stats"}"# },
      { role "tool", content #"{"total_mb":8192.0,"processes_mb":4000.0,"processes_used_mb":3800.0,"system_mb":1500.0,"binary_mb":300.0,"ets_mb":200.0,"code_mb":200.0}"# }
    ]
  }
  // Process count at 65% and memory at 67% triggers warning - agent should investigate or complete with warning
  @@assert(continues_or_warns, {{
    this.intent == "get_scheduler_stats" or
    this.intent == "get_top_processes" or
    (this.intent == "done" and this.analysis.status == "warning")
  }})
}

// Truly healthy system with low metrics and no anomalies
test SelectTool_Anomaly_TrulyHealthy {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"prod@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":3600,"schedulers_online":8}"# },
      { role "assistant", content #"{"intent":"get_memory_stats"}"# },
      { role "tool", content #"{"total_mb":512.0,"processes_mb":100.0,"processes_used_mb":90.0,"system_mb":200.0,"binary_mb":50.0,"ets_mb":20.0,"code_mb":40.0}"# },
      { role "assistant", content #"{"intent":"get_process_stats"}"# },
      { role "tool", content #"{"process_count":1000,"process_limit":262144,"port_count":100,"port_limit":65536}"# },
      { role "assistant", content #"{"intent":"get_scheduler_stats"}"# },
      { role "tool", content #"{"schedulers":8,"schedulers_online":8,"dirty_cpu_schedulers_online":8,"dirty_io_schedulers":10,"run_queue":0}"# }
    ]
  }
  // All metrics low: process 0.4%, binary 9.7%, run_queue 0
  @@assert(healthy_if_done, {{
    this.intent != "done" or this.analysis.status == "healthy"
  }})
}

// ============================================================================
// JUDGE AGENT TESTS
// ============================================================================

test JudgeAnalysis_AcceptHealthy {
  functions [JudgeAnalysis]
  args {
    analysis {
      status "healthy"
      summary "All metrics nominal. Process count at 0.4% of limit, memory at 58%, run queue at 0."
      concerns []
      recommendations []
    }
    event_trail #"[LLM] iteration=0 selected=get_system_info
[TOOL] get_system_info: {"node":"prod@host","schedulers_online":8}
[LLM] iteration=1 selected=get_memory_stats
[TOOL] get_memory_stats: {"total_mb":512,"processes_mb":100,"system_mb":200}
[LLM] iteration=2 selected=get_process_stats
[TOOL] get_process_stats: {"process_count":1000,"process_limit":262144}"#
    attempt 1
  }
  @@assert(accepts, {{ this.verdict == "accept" }})
  @@assert(no_issues, {{ this.issues|length == 0 }})
}

test JudgeAnalysis_AcceptWarning {
  functions [JudgeAnalysis]
  args {
    analysis {
      status "warning"
      summary "Memory utilization elevated at 80%. Process and scheduler metrics normal."
      concerns ["Memory utilization at 80% of capacity"]
      recommendations ["Monitor memory usage", "Consider increasing memory allocation"]
    }
    event_trail #"[LLM] iteration=0 selected=get_system_info
[TOOL] get_system_info: {"node":"prod@host","schedulers_online":8}
[LLM] iteration=1 selected=get_memory_stats
[TOOL] get_memory_stats: {"total_mb":10000,"processes_mb":6000,"system_mb":2000}
[LLM] iteration=2 selected=get_process_stats
[TOOL] get_process_stats: {"process_count":5000,"process_limit":262144}"#
    attempt 1
  }
  @@assert(accepts, {{ this.verdict == "accept" }})
}

test JudgeAnalysis_RejectInsufficientData {
  functions [JudgeAnalysis]
  args {
    analysis {
      status "healthy"
      summary "System appears healthy based on initial metrics."
      concerns []
      recommendations []
    }
    event_trail #"[LLM] iteration=0 selected=get_system_info
[TOOL] get_system_info: {"node":"prod@host","schedulers_online":8}"#
    attempt 1
  }
  @@assert(retries, {{ this.verdict == "retry" }})
  @@assert(has_issues, {{ this.issues|length > 0 }})
}

test JudgeAnalysis_RejectPhantomConcern {
  functions [JudgeAnalysis]
  args {
    analysis {
      status "warning"
      summary "Memory leak detected in binary heap."
      concerns ["Binary memory leak causing memory pressure"]
      recommendations ["Investigate binary memory usage"]
    }
    event_trail #"[LLM] iteration=0 selected=get_system_info
[TOOL] get_system_info: {"node":"prod@host","schedulers_online":8}
[LLM] iteration=1 selected=get_memory_stats
[TOOL] get_memory_stats: {"total_mb":512,"processes_mb":100,"system_mb":200,"binary_mb":10}
[LLM] iteration=2 selected=get_process_stats
[TOOL] get_process_stats: {"process_count":1000,"process_limit":262144}"#
    attempt 1
  }
  @@assert(retries, {{ this.verdict == "retry" }})
}

test JudgeAnalysis_RejectMissedConcern {
  functions [JudgeAnalysis]
  args {
    analysis {
      status "healthy"
      summary "All systems operating normally."
      concerns []
      recommendations []
    }
    event_trail #"[LLM] iteration=0 selected=get_system_info
[TOOL] get_system_info: {"node":"prod@host","schedulers_online":8}
[LLM] iteration=1 selected=get_memory_stats
[TOOL] get_memory_stats: {"total_mb":10000,"processes_mb":6000,"system_mb":2500}
[LLM] iteration=2 selected=get_process_stats
[TOOL] get_process_stats: {"process_count":5000,"process_limit":262144}"#
    attempt 1
  }
  @@assert(retries, {{ this.verdict == "retry" }})
}

// ============================================================================
// OVERVIEW TOOL TESTS
// ============================================================================

test SelectTool_AfterOverviewHighAtom {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_overview"}"# },
      { role "tool", content #"{"memory_utilization_pct":45.2,"process_utilization_pct":1.9,"port_utilization_pct":0.04,"atom_utilization_pct":90.0,"scheduler_run_queue":2,"schedulers_online":8}"# }
    ]
  }
  @@assert(investigates_atoms, {{ this.intent == "get_atom_stats" }})
}

test SelectTool_AfterOverviewHighMemory {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_overview"}"# },
      { role "tool", content #"{"memory_utilization_pct":75.0,"process_utilization_pct":2.5,"port_utilization_pct":0.1,"atom_utilization_pct":12.0,"scheduler_run_queue":1,"schedulers_online":8}"# }
    ]
  }
  @@assert(investigates_memory, {{ this.intent == "get_memory_stats" }})
}

test SelectTool_AfterOverviewHealthy {
  functions [SelectTool]
  args {
    messages [
      { role "assistant", content #"{"intent":"get_overview"}"# },
      { role "tool", content #"{"memory_utilization_pct":35.0,"process_utilization_pct":1.5,"port_utilization_pct":0.1,"atom_utilization_pct":15.0,"scheduler_run_queue":0,"schedulers_online":8}"# }
    ]
  }
  @@assert(valid_next_action, {{
    this.intent == "get_system_info" or
    this.intent == "get_memory_stats" or
    this.intent == "get_process_stats" or
    this.intent == "get_scheduler_stats" or
    (this.intent == "done" and this.analysis.status == "healthy")
  }})
}
