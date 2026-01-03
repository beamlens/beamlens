// BeamLens BAML definitions
// Note: This placeholder client is overridden at runtime via client_registry

client<llm> Default {
  provider anthropic
  options {
    model "claude-haiku-4-5-20250514"
  }
}

class HealthAnalysis {
  status string @description("Overall status: healthy, warning, or critical")
  summary string @description("Brief 1-2 sentence summary")
  concerns string[] @description("List of any concerns found, empty if none")
  recommendations string[] @description("Actionable recommendations, empty if none")
}

// Tool classes with intent literals for disambiguation (per BAML docs pattern)

class GetSystemInfo {
  intent "get_system_info" @description("Get basic node context")
}

class GetMemoryStats {
  intent "get_memory_stats" @description("Get detailed memory statistics for leak detection")
}

class GetProcessStats {
  intent "get_process_stats" @description("Get process/port counts and limits for capacity check")
}

class GetSchedulerStats {
  intent "get_scheduler_stats" @description("Get scheduler details and run queues for performance analysis")
}

class GetAtomStats {
  intent "get_atom_stats" @description("Get atom table metrics when suspecting atom leaks")
}

class GetPersistentTerms {
  intent "get_persistent_terms" @description("Get persistent term usage statistics")
}

class Done {
  intent "done"
  analysis HealthAnalysis @description("Final health analysis")
}

class Message {
  role string @description("assistant or tool")
  content string @description("JSON content")
}

// Union type - LLM picks exactly one tool
function SelectTool(messages: Message[]) -> GetSystemInfo | GetMemoryStats | GetProcessStats | GetSchedulerStats | GetAtomStats | GetPersistentTerms | Done {
  client Default
  prompt #"
    You are a BEAM VM health analyst. Analyze the BEAM VM and produce a health analysis.

    Conversation so far:
    {% for msg in messages %}
    [{{ msg.role }}]: {{ msg.content }}
    {% endfor %}

    Select your next action:
    {{ ctx.output_format }}
  "#
}
