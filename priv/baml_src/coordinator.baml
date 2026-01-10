// ============================================================================
// COORDINATOR AGENT TOOLS
// ============================================================================
// Alert correlation agent with 4 tools:
//
// - CoordinatorGetAlerts: Query alerts, optionally filtered by status
// - CoordinatorUpdateAlertStatuses: Set status on multiple alerts
// - CoordinatorProduceInsight: Emit insight + auto-resolve referenced alerts
// - CoordinatorDone: End loop, wait for next alert
//
// Note: Message class is shared from watcher.baml

class CoordinatorGetAlerts {
  intent "get_alerts"
  status "unread" | "acknowledged" | "resolved" | "all"? @description("Filter by status, default all")
}

class CoordinatorUpdateAlertStatuses {
  intent "update_alert_statuses"
  alert_ids string[] @description("IDs of alerts to update")
  status "acknowledged" | "resolved" @description("New status for these alerts")
  reason string? @description("Optional reason for the status change")
}

class CoordinatorProduceInsight {
  intent "produce_insight"
  alert_ids string[] @description("IDs of alerts this insight correlates")
  correlation_type "temporal" | "causal" | "symptomatic" @description("How alerts are related")
  summary string @description("Brief explanation of the correlation")
  root_cause_hypothesis string? @description("Possible root cause if identified")
  confidence "high" | "medium" | "low" @description("Confidence in this correlation")
}

class CoordinatorDone {
  intent "done"
}

function CoordinatorLoop(messages: Message[]) -> CoordinatorGetAlerts | CoordinatorUpdateAlertStatuses | CoordinatorProduceInsight | CoordinatorDone {
  client Default
  prompt #"
{{ _.role("system") }}
You are an alert correlation agent. You receive alerts from BEAM system watchers
and identify patterns across them.

## Alert States
- unread: New alerts, not yet processed
- acknowledged: You're currently analyzing these
- resolved: Processed (correlated into insight or dismissed)

## Available Tools

### get_alerts(status?)
Query alerts. Filter by status or get all.

### update_alert_statuses(alert_ids, status, reason?)
Update status on multiple alerts.
- acknowledged: You're currently analyzing these
- resolved: Done processing (use for unrelated/false positives without insight)

### produce_insight(alert_ids, correlation_type, summary, root_cause_hypothesis?, confidence)
Create insight correlating alerts. Auto-resolves the referenced alerts.
- temporal: Alerts occurred close in time, possibly related
- causal: One alert directly caused another (A -> B)
- symptomatic: Alerts share a common hidden cause (A <- X -> B)

### done()
End processing. Call when finished with current alerts.

## Guidelines
1. Start by getting unread alerts
2. Mark alerts as acknowledged before analyzing
3. Look for patterns: same watcher, timing, related domains
4. Memory issues often cascade to scheduler/process problems
5. Produce insight for correlated alerts
6. Mark unrelated alerts as resolved (no insight needed)
7. Call done when finished

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

test CoordinatorLoop_GetsAlertsFirst {
  functions [CoordinatorLoop]
  args {
    messages [
      { role "user", content "Process alerts" }
    ]
  }
  @@assert(gets_alerts, {{ this.intent == "get_alerts" }})
}

test CoordinatorLoop_AcknowledgesUnreadAlerts {
  functions [CoordinatorLoop]
  args {
    messages [
      { role "user", content "Process alerts" },
      { role "user", content #"[{"id":"a1","status":"unread","watcher":"beam","anomaly_type":"memory_elevated","severity":"warning","summary":"Memory at 78%","detected_at":"2024-01-06T10:30:00Z"},{"id":"a2","status":"unread","watcher":"beam","anomaly_type":"scheduler_contention","severity":"warning","summary":"Run queue at 45","detected_at":"2024-01-06T10:30:30Z"}]"# }
    ]
  }
  @@assert(acknowledges_first, {{ this.intent == "update_alert_statuses" and this.status == "acknowledged" }})
}

test CoordinatorLoop_ResolvesFalsePositive {
  functions [CoordinatorLoop]
  args {
    messages [
      { role "user", content "Process alerts" },
      { role "user", content #"[{"id":"a1","status":"acknowledged","watcher":"beam","anomaly_type":"memory_elevated","severity":"info","summary":"Brief memory spike, returned to normal - no action needed","detected_at":"2024-01-06T10:30:00Z"}]"# }
    ]
  }
  @@assert(resolves_false_positive, {{ this.intent == "update_alert_statuses" and this.status == "resolved" }})
}

test CoordinatorLoop_CompletesWhenDone {
  functions [CoordinatorLoop]
  args {
    messages [
      { role "user", content "Process alerts" },
      { role "assistant", content #"{"intent":"get_alerts","status":"unread"}"# },
      { role "user", content "No unread alerts found: []" }
    ]
  }
  @@assert(calls_done, {{ this.intent == "done" }})
}
