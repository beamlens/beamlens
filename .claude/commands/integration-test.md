---
description: Run integration tests
allowed-tools: Bash(mix test:*), Read, Grep
---

Run integration tests and analyze the results comprehensively.

## Execution

Stream output to a file for analysis:
```bash
mix test --only integration 2>&1 > /tmp/integration_test_output.txt; echo "Exit code: $?"
```

## Analysis

Read `/tmp/integration_test_output.txt` and analyze:

1. **Test Results**: Check for failures, identify root causes from stack traces
2. **BAML/LLM Responses**: Review the `[BAML INFO]` blocks for:
   - Parsing errors (missing fields, coercion failures)
   - Quality of LLM reasoning and intent selection
   - Appropriateness of severity levels and conclusions
3. **Behavioral Patterns**: Look for problematic flows like excessive tool calls, missed anomalies, or incorrect judge verdicts

Report findings with specific fixes for any issues discovered.
