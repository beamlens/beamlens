// ============================================================================
// OPERATOR AGENT TOOLS
// ============================================================================
// Agent tools for one-shot analysis via run/2 (runs until done() is called).
//
// Message class for conversation history
class Message {
  role string @description("assistant or tool")
  content string @description("JSON content")
}

//
// - SetState: Update operator state
// - SendNotification: Create a notification with referenced snapshots
// - GetNotifications: See previous notifications
// - TakeSnapshot: Capture current metrics with unique ID
// - GetSnapshot: Retrieve a specific snapshot by ID
// - GetSnapshots: Retrieve multiple snapshots with pagination
// - Execute: Run Lua code for investigation
// - Wait: Sleep before next iteration
// - Think: Reason through complex decisions
// - Done: Signal analysis completion

class SetState {
  intent "set_state"
  state "healthy" | "observing" | "warning" | "critical" @description("New operator state")
  reason string @description("Why you're setting this state")
}

class SendNotification {
  intent "send_notification"
  type string @description("Type of notification (e.g., memory_elevated, scheduler_contention)")
  context string @description("Factual system state: What is the current context? (e.g., 'Node running for 3 days, 500 processes active')")
  observation string @description("Factual anomaly: What did you observe? (e.g., 'Memory at 85%, exceeding 60% threshold')")
  hypothesis string? @description("Speculative cause: What MIGHT be happening? (e.g., 'Likely due to ETS table growth')")
  severity "info" | "warning" | "critical" @description("Notification severity")
  snapshot_ids string[] @description("IDs of snapshots to include with notification - required")
}

class GetNotifications {
  intent "get_notifications"
}

class TakeSnapshot {
  intent "take_snapshot"
}

class GetSnapshot {
  intent "get_snapshot"
  id string @description("Snapshot ID to retrieve")
}

class GetSnapshots {
  intent "get_snapshots"
  limit int? @description("Max snapshots to return")
  offset int? @description("Number of snapshots to skip")
}

class Execute {
  intent "execute"
  code string @description("Lua code to execute. Available functions are documented in the system prompt.")
}

class Wait {
  intent "wait"
  ms int @description("Milliseconds to sleep before next iteration")
}

class Think {
  intent "think"
  thought string @description("Your reasoning about the current situation")
}

class Done {
  intent "done"
}

// ============================================================================
// SHARED PROMPT COMPONENTS
// ============================================================================

template_string OperatorToolDocs(callback_docs: string) #"
## Available Tools

### set_state(state, reason)
Update your state. Use this to reflect your current assessment.
If everything is fine, set state to healthy with a brief reason.

### send_notification(type, context, observation, hypothesis?, severity, snapshot_ids)
Create a notification when you detect an anomaly. Separate FACTS from SPECULATION.

- type: Descriptive name like "memory_elevated", "scheduler_contention"
- context: FACTUAL system state (e.g., "Node running for 3 days, 500 processes active")
- observation: FACTUAL anomaly description (e.g., "Memory at 85%, exceeding 60% threshold")
- hypothesis: SPECULATIVE cause - what MIGHT be happening (optional, use only if you have a theory)
- severity: info/warning/critical based on impact
- snapshot_ids: REQUIRED - IDs of snapshots that show the issue (from take_snapshot)

## Decomposition Rules (CRITICAL)
1. context + observation = FACTS ONLY - no speculation, no "likely", no "probably"
2. hypothesis = SPECULATION ONLY - use words like "might", "possibly", "could be"
3. If you're uncertain, put it in hypothesis, not observation
4. The coordinator correlates on facts only; hypotheses are validated across operators

IMPORTANT: You must include snapshot_ids referencing the snapshots that show
the anomaly. Notifications without snapshots will fail.

### get_notifications()
Retrieve previous notifications for correlation. Use this to avoid duplicate
notifications or to understand if an issue is recurring.

### take_snapshot()
Capture current system metrics and store with a unique ID. Returns:
- id: Unique snapshot identifier (use this in send_notification)
- captured_at: Timestamp
- data: Metrics including memory_utilization_pct, process_utilization_pct, etc.

Call this to capture metrics at specific points during your investigation.

### get_snapshot(id)
Retrieve a specific snapshot by its ID. Use this to review a previously
captured snapshot.

### get_snapshots(limit?, offset?)
Retrieve multiple snapshots with optional pagination.
- limit: Maximum number to return
- offset: Number to skip from the beginning

### execute(code)
Run Lua code to gather detailed metrics. Available functions:

{{ callback_docs }}

### think(thought)
Use this to reason through complex decisions before acting. Your thought
will be recorded but no action is taken. Good for:
- Analyzing tool results before deciding next action
- Working through ambiguous situations
- Planning multi-step investigations
"#

template_string OperatorMessages(messages: Message[]) #"
{% for message in messages %}
{{ _.role(message.role) }}
{{ message.content }}
{% endfor %}
"#

// ============================================================================
// OPERATOR FUNCTION
// ============================================================================
// Runs until LLM calls done() to signal completion

function OperatorRun(messages: Message[], system_prompt: string, callback_docs: string) -> SetState | SendNotification | GetNotifications | TakeSnapshot | GetSnapshot | GetSnapshots | Execute | Wait | Think | Done {
  client Default
  prompt #"
{{ _.role("system") }}
{{ system_prompt }}

## State Model
You have a state that reflects your current assessment:
- healthy: Everything is normal
- observing: Something looks off, you're gathering more data
- warning: Elevated concern, but not critical
- critical: Active issue requiring immediate attention

{{ OperatorToolDocs(callback_docs) }}

### wait(ms)
Sleep for the specified milliseconds, then continue investigating.
Use this when you need to wait for conditions to change or to pace your investigation.

### done()
Signal that you have completed your analysis. Use this when:
- You've finished investigating the concern
- You've sent any necessary notifications
- You're ready to return results

## Guidelines

Your workflow:
1. Start by calling take_snapshot() to capture current system metrics
2. Investigate using execute() and additional snapshots as needed
3. Send notifications for any issues found (include snapshot_ids)
4. Set appropriate state based on your findings
5. Call done() when your analysis is complete

{{ OperatorMessages(messages) }}

What action do you want to take?

{{ ctx.output_format }}
"#
}

// ============================================================================
// OPERATOR TESTS
// ============================================================================

test OperatorRun_CallsTakeSnapshot {
  functions [OperatorRun]
  args {
    messages [
      { role "user", content "Current state: healthy" }
    ]
    system_prompt "You are a BEAM VM health monitor."
    callback_docs #"
### beam_get_memory()
Memory stats in MB: total_mb, processes_mb, system_mb, binary_mb, ets_mb, code_mb

### beam_get_processes()
Process/port counts: process_count, process_limit, port_count, port_limit

### beam_get_schedulers()
Scheduler stats: schedulers, schedulers_online, run_queue

### beam_top_processes(limit, sort_by)
Top N processes by "memory", "message_queue", or "reductions"
"#
  }
  @@assert(calls_take_snapshot, {{ this.intent == "take_snapshot" }})
}

test OperatorRun_HealthySnapshot {
  functions [OperatorRun]
  args {
    messages [
      { role "user", content #"Current state: healthy"# },
      { role "user", content #"{"id":"abc123","captured_at":"2024-01-06T10:30:00Z","data":{"process_utilization_pct":12.1,"port_utilization_pct":3.4,"atom_utilization_pct":8.9,"scheduler_run_queue":0,"schedulers_online":8}}"# }
    ]
    system_prompt "You are a BEAM VM health monitor."
    callback_docs #"
### beam_get_memory()
Memory stats in MB: total_mb, processes_mb, system_mb, binary_mb, ets_mb, code_mb

### beam_top_processes(limit, sort_by)
Top N processes by "memory", "message_queue", or "reductions"
"#
  }
  @@assert(stays_healthy_or_waits, {{
    (this.intent == "set_state" and this.state == "healthy") or
    this.intent == "wait" or
    this.intent == "think"
  }})
}

test OperatorRun_HighProcessUtilization_Investigates {
  functions [OperatorRun]
  args {
    messages [
      { role "user", content #"Current state: healthy"# },
      { role "user", content #"{"id":"abc123","captured_at":"2024-01-06T10:30:00Z","data":{"process_utilization_pct":78.5,"port_utilization_pct":3.4,"atom_utilization_pct":8.9,"scheduler_run_queue":0,"schedulers_online":8}}"# }
    ]
    system_prompt "You are a BEAM VM health monitor. Process utilization > 70% warrants investigation."
    callback_docs #"
### beam_get_processes()
Process/port counts: process_count, process_limit, port_count, port_limit

### beam_top_processes(limit, sort_by)
Top N processes by "memory", "message_queue", or "reductions"
"#
  }
  @@assert(investigates_or_sends_notification, {{
    this.intent == "execute" or
    this.intent == "send_notification" or
    this.intent == "take_snapshot" or
    this.intent == "think" or
    (this.intent == "set_state" and this.state != "healthy")
  }})
}

test OperatorRun_CriticalAtomUtilization_Notifies {
  functions [OperatorRun]
  args {
    messages [
      { role "user", content #"Current state: warning"# },
      { role "user", content #"{"id":"snap1","captured_at":"2024-01-06T10:30:00Z","data":{"process_utilization_pct":12.1,"port_utilization_pct":3.4,"atom_utilization_pct":85.0,"scheduler_run_queue":0,"schedulers_online":8}}"# },
      { role "user", content #"{"id":"snap2","captured_at":"2024-01-06T10:30:30Z","data":{"process_utilization_pct":12.1,"port_utilization_pct":3.4,"atom_utilization_pct":92.5,"scheduler_run_queue":0,"schedulers_online":8}}"# }
    ]
    system_prompt "You are a BEAM VM health monitor. Atom utilization > 50% is critical - atoms are never garbage collected."
    callback_docs #"
### beam_get_atoms()
Atom table: atom_count, atom_limit, atom_mb, atom_used_mb

### beam_top_processes(limit, sort_by)
Top N processes by "memory", "message_queue", or "reductions"
"#
  }
  @@assert(notifies_or_escalates, {{
    this.intent == "send_notification" or
    (this.intent == "set_state" and this.state == "critical") or
    this.intent == "execute" or
    this.intent == "think"
  }})
}

test OperatorRun_SchedulerContention {
  functions [OperatorRun]
  args {
    messages [
      { role "user", content #"Current state: healthy"# },
      { role "user", content #"{"id":"abc123","captured_at":"2024-01-06T10:30:00Z","data":{"process_utilization_pct":12.1,"port_utilization_pct":3.4,"atom_utilization_pct":8.9,"scheduler_run_queue":85,"schedulers_online":8}}"# }
    ]
    system_prompt "You are a BEAM VM health monitor. Run queue > 2x schedulers indicates contention."
    callback_docs #"
### beam_get_schedulers()
Scheduler stats: schedulers, schedulers_online, run_queue

### beam_top_processes(limit, sort_by)
Top N processes by "memory", "message_queue", or "reductions"
"#
  }
  @@assert(responds_to_contention, {{
    this.intent == "execute" or
    this.intent == "send_notification" or
    this.intent == "take_snapshot" or
    this.intent == "think" or
    (this.intent == "set_state" and this.state != "healthy")
  }})
}

test OperatorRun_CallsDoneAfterAnalysis {
  functions [OperatorRun]
  args {
    messages [
      { role "user", content #"Analyze: routine check"# },
      { role "assistant", content #"{"intent":"take_snapshot"}"# },
      { role "tool", content #"{"id":"abc123","captured_at":"2024-01-06T10:30:00Z","data":{"process_utilization_pct":12.1,"port_utilization_pct":3.4,"atom_utilization_pct":8.9,"scheduler_run_queue":0,"schedulers_online":8}}"# },
      { role "assistant", content #"{"intent":"set_state","state":"healthy","reason":"All metrics within normal ranges"}"# },
      { role "tool", content #"{"ok":true}"# }
    ]
    system_prompt "You are a BEAM VM health monitor. After confirming healthy state, call done() to complete your analysis."
    callback_docs #"
### beam_get_memory()
Memory stats in MB: total_mb, processes_mb, system_mb, binary_mb, ets_mb, code_mb
"#
  }
  @@assert(calls_done, {{ this.intent == "done" }})
}

// ============================================================================
// INTENT DECOMPOSITION TESTS (Fact vs Speculation)
// ============================================================================

test OperatorRun_DecomposedNotification_SeparatesFactFromSpeculation {
  functions [OperatorRun]
  args {
    messages [
      { role "user", content #"Current state: observing"# },
      { role "assistant", content #"{"intent":"take_snapshot"}"# },
      { role "tool", content #"{"id":"snap1","captured_at":"2024-01-06T10:30:00Z","data":{"memory_utilization_pct":85.0,"process_count":500}}"# }
    ]
    system_prompt "You are a BEAM VM health monitor. Memory > 80% requires sending a notification. You must send a notification now."
    callback_docs #"
### beam_get_memory()
Returns memory stats in MB: total_mb, processes_mb, system_mb, binary_mb, ets_mb, code_mb
"#
  }
  @@assert(has_context_and_observation, {{
    this.intent == "send_notification" and
    this.context is not none and
    this.observation is not none
  }})
}

test OperatorRun_DecomposedNotification_HypothesisIsOptional {
  functions [OperatorRun]
  args {
    messages [
      { role "user", content #"Current state: warning"# },
      { role "assistant", content #"{"intent":"take_snapshot"}"# },
      { role "tool", content #"{"id":"snap1","captured_at":"2024-01-06T10:30:00Z","data":{"memory_utilization_pct":90.0,"process_count":400}}"# }
    ]
    system_prompt "You are a BEAM VM health monitor. Memory > 80% requires sending a notification. You must send a notification now."
    callback_docs #"
### beam_get_memory()
Returns memory stats in MB
"#
  }
  @@assert(sends_notification, {{ this.intent == "send_notification" }})
}

test OperatorRun_DecomposedNotification_ContextIsFactual {
  functions [OperatorRun]
  args {
    messages [
      { role "user", content #"Current state: observing"# },
      { role "assistant", content #"{"intent":"take_snapshot"}"# },
      { role "tool", content #"{"id":"snap1","captured_at":"2024-01-06T10:30:00Z","data":{"memory_utilization_pct":85.0,"uptime_seconds":259200}}"# }
    ]
    system_prompt "You are a BEAM VM health monitor. Memory > 80% requires a notification. Context field must be factual only - no speculation words like 'likely' or 'probably'. Send a notification now."
    callback_docs #"
### beam_get_memory()
Returns memory stats in MB
"#
  }
  @@assert(notification_with_factual_context, {{
    this.intent == "send_notification" and
    "likely" not in this.context and
    "probably" not in this.context and
    "might" not in this.context
  }})
}
