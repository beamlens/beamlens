class PipelineClassifyResult {
  intent "question" | "investigation" @description("question = direct answer needed, investigation = deeper analysis")
  skills string[] @description("Skill modules to invoke (e.g., [\"Beamlens.Skill.Beam\"])")
  operator_context string @description("Focused context to pass to operators instead of raw query")
}

function PipelineClassify(query: string, available_skills: string) -> PipelineClassifyResult {
  client Default
  prompt #"
{{ _.role("system") }}
You are a query classifier for a BEAM application monitoring system.

Given a user query and available skills, determine:
1. The intent: "question" for direct questions, "investigation" for deeper analysis
2. Which skills to invoke to gather the needed data
3. A focused context string for the operators (more specific than the raw query)

## Available Skills

{{ available_skills }}

## Rules
- Select only skills relevant to the query
- The operator_context should be actionable and specific
- For simple questions, select the minimum skills needed

{{ _.role("user") }}
{{ query }}

{{ ctx.output_format }}
"#
}

class PipelineSynthesizeResult {
  answer string @description("Human-readable answer to the original question")
}

function PipelineSynthesize(query: string, operator_data: string) -> PipelineSynthesizeResult {
  client Default
  prompt #"
{{ _.role("system") }}
You are a response synthesizer for a BEAM application monitoring system.

Given the original user query and data gathered by operators, produce a clear,
concise answer. Base your answer strictly on the factual data provided.
Do not speculate beyond what the data shows.

{{ _.role("user") }}
## Original Question
{{ query }}

## Operator Data
{{ operator_data }}

Synthesize a clear answer based on the operator data above.

{{ ctx.output_format }}
"#
}

test PipelineClassify_SimpleQuestion {
  functions [PipelineClassify]
  args {
    query "What OS is running?"
    available_skills "- Beamlens.Skill.Os: Operating system monitoring\n- Beamlens.Skill.Beam: BEAM VM health"
  }
  @@assert(selects_os_skill, {{ "Beamlens.Skill.Os" in this.skills }})
}

test PipelineClassify_BeamQuestion {
  functions [PipelineClassify]
  args {
    query "How much memory is the BEAM using?"
    available_skills "- Beamlens.Skill.Beam: BEAM VM health: memory, processes, schedulers, atoms\n- Beamlens.Skill.Ets: ETS table monitoring"
  }
  @@assert(selects_beam_skill, {{ "Beamlens.Skill.Beam" in this.skills }})
}

test PipelineSynthesize_SimpleAnswer {
  functions [PipelineSynthesize]
  args {
    query "What OS is running?"
    operator_data #"[{"operator":"Beamlens.Skill.Os","context":"System running normally","observation":"Operating system is macOS (darwin) on arm64 architecture"}]"#
  }
  @@assert(mentions_macos, {{ "macOS" in this.answer or "darwin" in this.answer }})
}
