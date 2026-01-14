// ============================================================================
// COORDINATOR AGENT TOOLS
// ============================================================================
// Notification correlation agent tools.
//
// Tools:
// - CoordinatorGetNotifications: Query notifications, optionally filtered by status
// - CoordinatorUpdateNotificationStatuses: Set status on multiple notifications
// - CoordinatorProduceInsight: Emit insight + auto-resolve referenced notifications
// - CoordinatorDone: Signal analysis completion
// - CoordinatorThink: Reason through complex decisions before acting
// - CoordinatorInvokeOperators: Spawn multiple operators in parallel
// - CoordinatorMessageOperator: Send message to running operator, get LLM response
// - CoordinatorGetOperatorStatuses: Check status of running operators
// - CoordinatorWait: Pause loop for specified duration
//
// Note: Message class is shared from operator.baml

class CoordinatorGetNotifications {
  intent "get_notifications"
  status "unread" | "acknowledged" | "resolved" | "all"? @description("Filter by status, default all")
}

class CoordinatorUpdateNotificationStatuses {
  intent "update_notification_statuses"
  notification_ids string[] @description("IDs of notifications to update")
  status "acknowledged" | "resolved" @description("New status for these notifications")
  reason string? @description("Optional reason for the status change")
}

class CoordinatorProduceInsight {
  intent "produce_insight"
  notification_ids string[] @description("IDs of notifications this insight correlates")
  correlation_type "temporal" | "causal" | "symptomatic" @description("How notifications are related")
  summary string @description("Brief explanation of the correlation")
  root_cause_hypothesis string? @description("Possible root cause if identified")
  confidence "high" | "medium" | "low" @description("Confidence in this correlation")
}

class CoordinatorDone {
  intent "done"
}

class CoordinatorThink {
  intent "think"
  thought string @description("Your reasoning about the current situation")
}

class CoordinatorInvokeOperators {
  intent "invoke_operators"
  skills string[] @description("List of skills to invoke in parallel (e.g., [\"beam\", \"ets\"])")
  context string? @description("Shared context for all operators")
}

class CoordinatorMessageOperator {
  intent "message_operator"
  skill string @description("Skill name of the running operator to message")
  message string @description("Your question or prompt for the operator's LLM")
}

class CoordinatorGetOperatorStatuses {
  intent "get_operator_statuses"
}

class CoordinatorWait {
  intent "wait"
  ms int @description("Milliseconds to wait before continuing")
}

// ============================================================================
// COORDINATOR FUNCTION
// ============================================================================
// Runs until LLM calls done() to signal completion.

function CoordinatorRun(messages: Message[], operator_descriptions: string, available_skills: string) -> CoordinatorGetNotifications | CoordinatorUpdateNotificationStatuses | CoordinatorProduceInsight | CoordinatorDone | CoordinatorThink | CoordinatorInvokeOperators | CoordinatorMessageOperator | CoordinatorGetOperatorStatuses | CoordinatorWait {
  client Default
  prompt #"
{{ _.role("system") }}
You are a notification correlation agent. You analyze notifications
from system operators and can spawn operators to gather fresh data when needed.

## Active Operators

{{ operator_descriptions }}

## Available Skills for Invocation

{{ available_skills }}

## Notification States
- unread: New notifications, not yet processed
- acknowledged: You're currently analyzing these
- resolved: Processed (correlated into insight or dismissed)

## Available Tools

### get_notifications(status?)
Query notifications. Filter by status or get all.

### update_notification_statuses(notification_ids, status, reason?)
Update status on multiple notifications.
- acknowledged: You're currently analyzing these
- resolved: Done processing (use for unrelated/false positives without insight)

### produce_insight(notification_ids, correlation_type, summary, root_cause_hypothesis?, confidence)
Create insight correlating notifications. Auto-resolves the referenced notifications.
- temporal: Notifications occurred close in time, possibly related
- causal: One notification directly caused another (A -> B)
- symptomatic: Notifications share a common hidden cause (A <- X -> B)

### invoke_operators(skills, context?)
Start multiple operators in parallel. They run independently and send notifications
in real-time as they find issues. Use when you need fresh data from one or more domains.
Example: invoke_operators(["beam", "ets"]) to check both BEAM VM and ETS tables.

### message_operator(skill, message)
Send a custom prompt to a running operator. The operator's LLM will respond using its
full conversation context. Use to ask specific questions about what an operator is seeing.
Example: message_operator("beam", "What's causing the elevated memory?")

### get_operator_statuses()
Get deterministic metadata for all running operators: skill, state, iteration, alive status.
Use to check which operators are still running before messaging them.

### wait(ms)
Pause your loop for the specified milliseconds. Use to give operators time to gather data
before checking on them. The loop will automatically continue after the delay.

### done()
Signal that you have completed your analysis. Use when:
- You've finished analyzing all notifications
- You've produced all relevant insights
- You're ready to return results

### think(thought)
Use this to reason through complex decisions before acting. Your thought
will be recorded but no action is taken. Good for:
- Analyzing notification patterns before correlating
- Working through ambiguous relationships
- Planning operator invocations

## Guidelines
1. Start by getting existing notifications to understand current state
2. If you need fresh data, invoke relevant operators (they run in parallel)
3. Use get_operator_statuses() to check which operators are running
4. Notifications arrive in real-time - check get_notifications() periodically
5. Use message_operator() to ask running operators about their findings
6. Wait if operators need more time to gather data
7. Produce insights for correlated notifications
8. Call done when finished with all analysis

{% for message in messages %}
{{ _.role(message.role) }}
{{ message.content }}
{% endfor %}

What action do you want to take?

{{ ctx.output_format }}
"#
}

// ============================================================================
// COORDINATOR TESTS
// ============================================================================

test CoordinatorRun_GetsNotificationsFirst {
  functions [CoordinatorRun]
  args {
    messages [
      { role "user", content "Process notifications" }
    ]
    operator_descriptions "- beam: BEAM VM health: memory, processes, schedulers, atoms"
    available_skills "beam"
  }
  @@assert(gets_notifications, {{ this.intent == "get_notifications" }})
}

test CoordinatorRun_AcknowledgesUnreadNotifications {
  functions [CoordinatorRun]
  args {
    messages [
      { role "user", content "Process notifications" },
      { role "user", content #"[{"id":"a1","status":"unread","operator":"beam","anomaly_type":"memory_elevated","severity":"warning","summary":"Memory at 78%","detected_at":"2024-01-06T10:30:00Z"},{"id":"a2","status":"unread","operator":"beam","anomaly_type":"scheduler_contention","severity":"warning","summary":"Run queue at 45","detected_at":"2024-01-06T10:30:30Z"}]"# },
      { role "user", content "You should acknowledge these unread notifications to start analyzing them." }
    ]
    operator_descriptions "- beam: BEAM VM health: memory, processes, schedulers, atoms"
    available_skills "beam"
  }
  @@assert(acknowledges_first, {{ this.intent == "update_notification_statuses" and this.status == "acknowledged" }})
}

test CoordinatorRun_ResolvesFalsePositive {
  functions [CoordinatorRun]
  args {
    messages [
      { role "user", content "Process notifications" },
      { role "user", content #"[{"id":"a1","status":"acknowledged","operator":"beam","anomaly_type":"memory_elevated","severity":"info","summary":"Brief memory spike, returned to normal - no action needed","detected_at":"2024-01-06T10:30:00Z"}]"# },
      { role "user", content "This notification indicates a false alarm that returned to normal. Resolve it as it requires no further action." }
    ]
    operator_descriptions "- beam: BEAM VM health: memory, processes, schedulers, atoms"
    available_skills "beam"
  }
  @@assert(resolves_false_positive, {{ this.intent == "update_notification_statuses" and this.status == "resolved" }})
}

test CoordinatorRun_CompletesWhenDone {
  functions [CoordinatorRun]
  args {
    messages [
      { role "user", content "Process notifications" },
      { role "assistant", content #"{"intent":"get_notifications","status":"unread"}"# },
      { role "user", content "No unread notifications found: []" },
      { role "user", content "There are no notifications to process and no pending work. You should finish the analysis now." }
    ]
    operator_descriptions "- beam: BEAM VM health: memory, processes, schedulers, atoms"
    available_skills "beam"
  }
  @@assert(calls_done, {{ this.intent == "done" }})
}

test CoordinatorRun_InvokesOperatorsForFreshData {
  functions [CoordinatorRun]
  args {
    messages [
      { role "user", content "A BEAM VM health check was requested. No notifications are currently available. Invoke the beam operator to gather current metrics." }
    ]
    operator_descriptions "- beam: BEAM VM health: memory, processes, schedulers, atoms"
    available_skills "beam, ets, gc"
  }
  @@assert(invokes_beam, {{ this.intent == "invoke_operators" and this.skills[0] == "beam" }})
}

test CoordinatorRun_CallsDoneAfterAnalysis {
  functions [CoordinatorRun]
  args {
    messages [
      { role "user", content "Analyze notifications" },
      { role "assistant", content #"{"intent":"get_notifications","status":"unread"}"# },
      { role "user", content "[]" },
      { role "assistant", content #"{"intent":"invoke_operators","skills":["beam"],"context":"gather current metrics"}"# },
      { role "user", content #"{"started":["beam"],"count":1}"# },
      { role "assistant", content #"{"intent":"wait","ms":5000}"# },
      { role "user", content #"{"waited":5000}"# },
      { role "assistant", content #"{"intent":"get_operator_statuses"}"# },
      { role "user", content #"[]"# },
      { role "user", content "All operators have completed. No pending work remains. You should finish the analysis now." }
    ]
    operator_descriptions "- beam: BEAM VM health: memory, processes, schedulers, atoms"
    available_skills "beam"
  }
  @@assert(calls_done, {{ this.intent == "done" }})
}
