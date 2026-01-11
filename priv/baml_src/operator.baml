// ============================================================================
// OPERATOR AGENT TOOLS
// ============================================================================
// Continuous agent loop with 9 tools:
//
// Message class for conversation history
class Message {
  role string @description("assistant or tool")
  content string @description("JSON content")
}

//
// - SetState: Update operator state
// - FireAlert: Create an alert with referenced snapshots
// - GetAlerts: See previous alerts
// - TakeSnapshot: Capture current metrics with unique ID
// - GetSnapshot: Retrieve a specific snapshot by ID
// - GetSnapshots: Retrieve multiple snapshots with pagination
// - Execute: Run Lua code for investigation
// - Wait: Sleep before next iteration

class SetState {
  intent "set_state"
  state "healthy" | "observing" | "warning" | "critical" @description("New operator state")
  reason string @description("Why you're setting this state")
}

class FireAlert {
  intent "fire_alert"
  type string @description("Type of alert (e.g., memory_elevated, scheduler_contention)")
  summary string @description("Brief description of the issue")
  severity "info" | "warning" | "critical" @description("Alert severity")
  snapshot_ids string[] @description("IDs of snapshots to include with alert - required")
}

class GetAlerts {
  intent "get_alerts"
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

// Main operator loop function
function OperatorLoop(messages: Message[], callback_docs: string) -> SetState | FireAlert | GetAlerts | TakeSnapshot | GetSnapshot | GetSnapshots | Execute | Wait | Think {
  client Default
  prompt #"
{{ _.role("system") }}
You are a system operator agent running continuously. Your job is to monitor
your assigned domain, detect anomalies, and alert when necessary.

## State Model
You have a state that reflects your current assessment:
- healthy: Everything is normal
- observing: Something looks off, you're gathering more data
- warning: Elevated concern, but not critical
- critical: Active issue requiring immediate attention

## Available Tools

### set_state(state, reason)
Update your state. Use this to reflect your current assessment.
If everything is fine, set state to healthy with a brief reason.

### fire_alert(type, summary, severity, snapshot_ids)
Create an alert when you detect an anomaly.
- type: Descriptive name like "memory_elevated", "scheduler_contention"
- summary: Brief human-readable description
- severity: info/warning/critical based on impact
- snapshot_ids: REQUIRED - IDs of snapshots that show the issue (from take_snapshot)

IMPORTANT: You must include snapshot_ids referencing the snapshots that show
the anomaly. Alerts without snapshots will fail.

### get_alerts()
Retrieve previous alerts for correlation. Use this to avoid duplicate
alerts or to understand if an issue is recurring.

### take_snapshot()
Capture current system metrics and store with a unique ID. Returns:
- id: Unique snapshot identifier (use this in fire_alert)
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

### wait(ms)
Sleep for the specified milliseconds, then continue.
- Normal operation: wait(30000) -- 30 seconds
- Elevated concern: wait(5000) -- 5 seconds
- Critical monitoring: wait(1000) -- 1 second

### think(thought)
Use this to reason through complex decisions before acting. Your thought
will be recorded but no action is taken. Good for:
- Analyzing tool results before deciding next action
- Working through ambiguous situations
- Planning multi-step investigations

## Guidelines

1. Start by calling take_snapshot() to capture current system metrics
2. If metrics look normal, confirm with set_state(healthy, "reason") then wait
3. If something looks off, take more snapshots and use execute() to investigate
4. When firing alerts, include the snapshot IDs that show the problem
5. Set appropriate wait times based on urgency

{% for message in messages %}
{{ _.role(message.role) }}
{{ message.content }}
{% endfor %}

What action do you want to take?

{{ ctx.output_format }}
"#
}

// ============================================================================
// OPERATOR TESTS
// ============================================================================

test OperatorLoop_CallsTakeSnapshot {
  functions [OperatorLoop]
  args {
    messages [
      { role "user", content "Current state: healthy" }
    ]
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

test OperatorLoop_HealthySnapshot {
  functions [OperatorLoop]
  args {
    messages [
      { role "user", content #"Current state: healthy"# },
      { role "user", content #"{"id":"abc123","captured_at":"2024-01-06T10:30:00Z","data":{"process_utilization_pct":12.1,"port_utilization_pct":3.4,"atom_utilization_pct":8.9,"scheduler_run_queue":0,"schedulers_online":8}}"# }
    ]
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

test OperatorLoop_HighProcessUtilization_Investigates {
  functions [OperatorLoop]
  args {
    messages [
      { role "user", content #"Current state: healthy"# },
      { role "user", content #"{"id":"abc123","captured_at":"2024-01-06T10:30:00Z","data":{"process_utilization_pct":78.5,"port_utilization_pct":3.4,"atom_utilization_pct":8.9,"scheduler_run_queue":0,"schedulers_online":8}}"# }
    ]
    callback_docs #"
### beam_get_processes()
Process/port counts: process_count, process_limit, port_count, port_limit

### beam_top_processes(limit, sort_by)
Top N processes by "memory", "message_queue", or "reductions"
"#
  }
  @@assert(investigates_or_alerts, {{
    this.intent == "execute" or
    this.intent == "fire_alert" or
    this.intent == "take_snapshot" or
    this.intent == "think" or
    (this.intent == "set_state" and this.state != "healthy")
  }})
}

test OperatorLoop_CriticalAtomUtilization_Alerts {
  functions [OperatorLoop]
  args {
    messages [
      { role "user", content #"Current state: warning"# },
      { role "user", content #"{"id":"snap1","captured_at":"2024-01-06T10:30:00Z","data":{"process_utilization_pct":12.1,"port_utilization_pct":3.4,"atom_utilization_pct":85.0,"scheduler_run_queue":0,"schedulers_online":8}}"# },
      { role "user", content #"{"id":"snap2","captured_at":"2024-01-06T10:30:30Z","data":{"process_utilization_pct":12.1,"port_utilization_pct":3.4,"atom_utilization_pct":92.5,"scheduler_run_queue":0,"schedulers_online":8}}"# }
    ]
    callback_docs #"
### beam_get_atoms()
Atom table: atom_count, atom_limit, atom_mb, atom_used_mb

### beam_top_processes(limit, sort_by)
Top N processes by "memory", "message_queue", or "reductions"
"#
  }
  @@assert(alerts_or_escalates, {{
    this.intent == "fire_alert" or
    (this.intent == "set_state" and this.state == "critical") or
    this.intent == "execute" or
    this.intent == "think"
  }})
}

test OperatorLoop_SchedulerContention {
  functions [OperatorLoop]
  args {
    messages [
      { role "user", content #"Current state: healthy"# },
      { role "user", content #"{"id":"abc123","captured_at":"2024-01-06T10:30:00Z","data":{"process_utilization_pct":12.1,"port_utilization_pct":3.4,"atom_utilization_pct":8.9,"scheduler_run_queue":85,"schedulers_online":8}}"# }
    ]
    callback_docs #"
### beam_get_schedulers()
Scheduler stats: schedulers, schedulers_online, run_queue

### beam_top_processes(limit, sort_by)
Top N processes by "memory", "message_queue", or "reductions"
"#
  }
  @@assert(responds_to_contention, {{
    this.intent == "execute" or
    this.intent == "fire_alert" or
    this.intent == "take_snapshot" or
    this.intent == "think" or
    (this.intent == "set_state" and this.state != "healthy")
  }})
}
