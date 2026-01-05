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
  summary string @description(#"Brief 1-2 sentence summary"#)
    @check(has_summary, {{ this|length > 10 }})
    @check(not_too_long, {{ this|length < 500 }})
  concerns string[] @description(#"List of any concerns found, empty if none"#)
  recommendations string[] @description(#"Actionable recommendations, empty if none"#)
  @@check(concerns_match_status, {{
    (this.status == "healthy" and this.concerns|length == 0) or
    this.status != "healthy"
  }})
}

// Tool classes with intent literals for disambiguation (per BAML docs pattern)

class GetSystemInfo {
  intent "get_system_info" @description(#"Get basic node context"#)
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

class Done {
  intent "done"
  analysis HealthAnalysis @description(#"Final health analysis"#)
}

class Message {
  role string @description(#"assistant or tool"#)
  content string @description(#"JSON content"#)
}

// Union type - LLM picks exactly one tool
function SelectTool(messages: Message[]) -> GetSystemInfo | GetMemoryStats | GetProcessStats | GetSchedulerStats | GetAtomStats | GetPersistentTerms | Done {
  client Default
  prompt #"
You are a BEAM VM health analyst. Analyze VM metrics and produce a health assessment.

## Analysis Process
1. Start with get_system_info to establish context
2. Gather 2-4 additional metrics based on initial findings
3. Complete with "done" once you have sufficient data

## When to Complete
- You have system info + at least 2 other metrics
- You've identified a clear health status
- Additional tools wouldn't change your assessment

## Status Guidelines
- healthy: All metrics within normal ranges
- warning: Elevated metrics (>70% capacity) or minor anomalies
- critical: Near limits (>90% capacity) or severe issues

## Conversation
{% for msg in messages %}
[{{ msg.role }}]: {{ msg.content }}
{% endfor %}

Select your next action:
{{ ctx.output_format }}
"#
}

// ============================================================================
// TESTS
// ============================================================================

// Phase 1: Minimum Viable Tests

test SelectTool_InitialSelection {
  functions [SelectTool]
  args {
    messages []
  }
  @@assert(returns_tool, {{ this.intent != "done" }})
  @@assert(valid_intent, {{
    this.intent == "get_system_info" or
    this.intent == "get_memory_stats" or
    this.intent == "get_process_stats" or
    this.intent == "get_scheduler_stats" or
    this.intent == "get_atom_stats" or
    this.intent == "get_persistent_terms"
  }})
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
      { role "assistant", content #"{"intent":"get_system_info"}"# },
      { role "tool", content #"{"node":"healthy@host","otp_release":"28","elixir_version":"1.19.4","uptime_seconds":3600,"schedulers_online":8}"# },
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
