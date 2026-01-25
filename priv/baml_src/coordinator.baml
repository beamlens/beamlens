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
  summary string @description("Brief explanation based on OBSERVATIONS ONLY - no speculation")
  matched_observations string[] @description("Specific observations from notifications that correlated (copy exact text)")
  hypothesis_grounded bool @description("True ONLY if hypotheses were corroborated by multiple independent operators")
  root_cause_hypothesis string? @description("Only provide if grounded=true OR derived purely from observations")
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
  skills string[] @description("List of skill modules to invoke in parallel (e.g., [\"Beamlens.Skill.Beam\", \"Beamlens.Skill.Ets\"])")
  context string? @description("Shared context for all operators")
}

class CoordinatorMessageOperator {
  intent "message_operator"
  skill string @description("Full module name of the running operator to message (e.g., \"Beamlens.Skill.Beam\")")
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

### produce_insight(notification_ids, correlation_type, summary, matched_observations, hypothesis_grounded, root_cause_hypothesis?, confidence)
Create insight correlating notifications. Auto-resolves the referenced notifications.
- temporal: Notifications occurred close in time, possibly related
- causal: One notification directly caused another (A -> B)
- symptomatic: Notifications share a common hidden cause (A <- X -> B)

## Correlation Rules (CRITICAL - Fact vs Speculation)

Notifications have decomposed fields: context (facts), observation (facts), hypothesis (speculation).

1. **Correlate on FACTS ONLY** - Match on context + observation fields, NEVER on hypothesis
2. **Evaluate hypotheses AFTER** finding observation correlations
3. **A hypothesis is GROUNDED only when:**
   - Same hypothesis appears from multiple INDEPENDENT operators, OR
   - Factual observations from other operators directly support it
4. **Set hypothesis_grounded: false** if speculation is not corroborated
5. **matched_observations** must contain exact observation text that correlated
6. **summary** must describe correlation based on observations only - no speculation
7. **root_cause_hypothesis** should only be provided if grounded=true OR derived from observations

### invoke_operators(skills, context?)
Start multiple operators in parallel. They run independently and send notifications
in real-time as they find issues. Use when you need fresh data from one or more domains.
Example: invoke_operators(["Beamlens.Skill.Beam", "Beamlens.Skill.Ets"]) to check both BEAM VM and ETS tables.

### message_operator(skill, message)
Send a custom prompt to a running operator. The operator's LLM will respond using its
full conversation context. Use to ask specific questions about what an operator is seeing.
Example: message_operator("Beamlens.Skill.Beam", "What's causing the elevated memory?")

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
2. **IMPORTANT**: When given an investigation reason/context but no notifications exist,
   ALWAYS invoke the relevant operators first to gather fresh data before concluding.
   Match the context to available skills (e.g., "logging issues" → Logger, "memory" → Beam/Gc)
3. If you need fresh data, invoke relevant operators (they run in parallel)
4. Use get_operator_statuses() to check which operators are running
5. Notifications arrive in real-time - check get_notifications() periodically
6. Use message_operator() to ask running operators about their findings
7. Wait if operators need more time to gather data
8. Produce insights for correlated notifications
9. Call done when finished with all analysis - but NEVER call done without first
   invoking operators when an investigation context was provided

**CRITICAL**: You MUST use ONLY the exact tool names listed above. The available intents are:
- get_notifications
- update_notification_statuses (use this to acknowledge OR resolve notifications)
- produce_insight
- invoke_operators
- message_operator
- get_operator_statuses
- wait
- think
- done

Do NOT invent tool names like "acknowledge_notification" - use "update_notification_statuses" instead.

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
    operator_descriptions "- Beamlens.Skill.Beam: BEAM VM health: memory, processes, schedulers, atoms"
    available_skills "Beamlens.Skill.Beam"
  }
  @@assert(gets_notifications, {{ this.intent == "get_notifications" }})
}

test CoordinatorRun_AcknowledgesUnreadNotifications {
  functions [CoordinatorRun]
  args {
    messages [
      { role "user", content "Process notifications" },
      { role "user", content #"[{"id":"a1","status":"unread","operator":"Beamlens.Skill.Beam","anomaly_type":"memory_elevated","severity":"warning","summary":"Memory at 78%","detected_at":"2024-01-06T10:30:00Z"},{"id":"a2","status":"unread","operator":"Beamlens.Skill.Beam","anomaly_type":"scheduler_contention","severity":"warning","summary":"Run queue at 45","detected_at":"2024-01-06T10:30:30Z"}]"# },
      { role "user", content "You should acknowledge these unread notifications to start analyzing them." }
    ]
    operator_descriptions "- Beamlens.Skill.Beam: BEAM VM health: memory, processes, schedulers, atoms"
    available_skills "Beamlens.Skill.Beam"
  }
  @@assert(acknowledges_first, {{ this.intent == "update_notification_statuses" and this.status == "acknowledged" }})
}

test CoordinatorRun_ResolvesFalsePositive {
  functions [CoordinatorRun]
  args {
    messages [
      { role "user", content "Process notifications" },
      { role "user", content #"[{"id":"a1","status":"acknowledged","operator":"Beamlens.Skill.Beam","anomaly_type":"memory_elevated","severity":"info","summary":"Brief memory spike, returned to normal - no action needed","detected_at":"2024-01-06T10:30:00Z"}]"# },
      { role "user", content "This notification indicates a false alarm that returned to normal. Resolve it as it requires no further action." }
    ]
    operator_descriptions "- Beamlens.Skill.Beam: BEAM VM health: memory, processes, schedulers, atoms"
    available_skills "Beamlens.Skill.Beam"
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
    operator_descriptions "- Beamlens.Skill.Beam: BEAM VM health: memory, processes, schedulers, atoms"
    available_skills "Beamlens.Skill.Beam"
  }
  @@assert(calls_done, {{ this.intent == "done" }})
}

test CoordinatorRun_InvokesOperatorsForFreshData {
  functions [CoordinatorRun]
  args {
    messages [
      { role "user", content "Reason: Check BEAM VM health" },
      { role "assistant", content #"{"intent":"get_notifications","status":"unread"}"# },
      { role "user", content "[]" }
    ]
    operator_descriptions "- Beamlens.Skill.Beam: BEAM VM health: memory, processes, schedulers, atoms"
    available_skills "Beamlens.Skill.Beam, Beamlens.Skill.Ets, Beamlens.Skill.Gc"
  }
  @@assert(invokes_beam, {{ this.intent == "invoke_operators" and this.skills[0] == "Beamlens.Skill.Beam" }})
}

test CoordinatorRun_InvokesLoggerForLoggingIssues {
  functions [CoordinatorRun]
  args {
    messages [
      { role "user", content "Reason: Investigate logging issues" },
      { role "assistant", content #"{"intent":"get_notifications","status":"unread"}"# },
      { role "user", content "[]" }
    ]
    operator_descriptions "- Beamlens.Skill.Logger: Application logs: error rates, patterns, module-specific issues"
    available_skills "Beamlens.Skill.Logger"
  }
  @@assert(invokes_logger, {{ this.intent == "invoke_operators" and this.skills[0] == "Beamlens.Skill.Logger" }})
}

test CoordinatorRun_CallsDoneAfterAnalysis {
  functions [CoordinatorRun]
  args {
    messages [
      { role "user", content "Analyze notifications" },
      { role "assistant", content #"{"intent":"get_notifications","status":"unread"}"# },
      { role "user", content "[]" },
      { role "assistant", content #"{"intent":"invoke_operators","skills":["Beamlens.Skill.Beam"],"context":"gather current metrics"}"# },
      { role "user", content #"{"started":["Beamlens.Skill.Beam"],"count":1}"# },
      { role "assistant", content #"{"intent":"wait","ms":5000}"# },
      { role "user", content #"{"waited":5000}"# },
      { role "assistant", content #"{"intent":"get_operator_statuses"}"# },
      { role "user", content #"[]"# },
      { role "user", content "All operators have completed. No pending work remains. You should finish the analysis now." }
    ]
    operator_descriptions "- Beamlens.Skill.Beam: BEAM VM health: memory, processes, schedulers, atoms"
    available_skills "Beamlens.Skill.Beam"
  }
  @@assert(calls_done, {{ this.intent == "done" }})
}

// ============================================================================
// INTENT DECOMPOSITION TESTS (Grounded Insights)
// ============================================================================

test CoordinatorRun_ProducesInsightWithMatchedObservations {
  functions [CoordinatorRun]
  args {
    messages [
      { role "user", content "Process notifications" },
      { role "assistant", content #"{"intent":"get_notifications","status":"unread"}"# },
      { role "user", content #"[{"id":"n1","status":"unread","operator":"Beamlens.Skill.Beam","context":"Node running for 3 days","observation":"Memory at 85%","hypothesis":"ETS table growth","severity":"warning"}]"# },
      { role "assistant", content #"{"intent":"update_notification_statuses","notification_ids":["n1"],"status":"acknowledged"}"# },
      { role "user", content #"{"updated":["n1"]}"# },
      { role "user", content "Produce an insight for this acknowledged notification. Use produce_insight with matched_observations containing the observation text." }
    ]
    operator_descriptions "- Beamlens.Skill.Beam: BEAM VM health"
    available_skills "Beamlens.Skill.Beam"
  }
  @@assert(produces_insight_or_acknowledges, {{
    this.intent == "produce_insight" or
    this.intent == "update_notification_statuses"
  }})
}

test CoordinatorRun_InsightHypothesisGroundedFalseForSingleSource {
  functions [CoordinatorRun]
  args {
    messages [
      { role "user", content "Process notifications" },
      { role "assistant", content #"{"intent":"get_notifications"}"# },
      { role "user", content #"[{"id":"n1","status":"acknowledged","operator":"Beamlens.Skill.Beam","context":"Node active","observation":"Memory at 85%","hypothesis":"ETS growth","severity":"warning"}]"# },
      { role "user", content "Produce an insight for this single notification. Since there is only ONE operator source, hypothesis_grounded MUST be false." }
    ]
    operator_descriptions "- Beamlens.Skill.Beam: BEAM VM health"
    available_skills "Beamlens.Skill.Beam"
  }
  @@assert(hypothesis_not_grounded, {{
    this.intent == "produce_insight" and
    this.hypothesis_grounded == false
  }})
}

test CoordinatorRun_InsightHypothesisGroundedTrueForCorroboratedHypotheses {
  functions [CoordinatorRun]
  args {
    messages [
      { role "user", content "Process notifications" },
      { role "assistant", content #"{"intent":"get_notifications"}"# },
      { role "user", content #"[{"id":"n1","status":"acknowledged","operator":"Beamlens.Skill.Beam","context":"Node active","observation":"Memory at 85%","hypothesis":"ETS table growth","severity":"warning"},{"id":"n2","status":"acknowledged","operator":"Beamlens.Skill.Ets","context":"Node active","observation":"ETS tables using 500MB","hypothesis":"Unbounded table growth","severity":"warning"}]"# },
      { role "user", content "These notifications from TWO INDEPENDENT operators (Beam and Ets) share a corroborated hypothesis about ETS growth. Produce an insight with hypothesis_grounded=true." }
    ]
    operator_descriptions "- Beamlens.Skill.Beam: BEAM VM health\n- Beamlens.Skill.Ets: ETS table monitoring"
    available_skills "Beamlens.Skill.Beam, Beamlens.Skill.Ets"
  }
  @@assert(hypothesis_grounded, {{
    this.intent == "produce_insight" and
    this.hypothesis_grounded == true
  }})
}
