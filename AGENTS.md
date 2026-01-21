A runtime AI agent that monitors BEAM application health and generates actionable analyses.

## Copywriting

Always refer to this for guidance on copywriting: https://gist.githubusercontent.com/bradleygolden/3426fe9db8cce5652dbda749eafc57b1/raw/2346ff8da345cf5ae6e9401f63edc534f89189be/elixir-library-documentation-manifesto

## Rules

- Zero production impact: all calls must be read-only with no side effects
- No sensitive data: never analyze or expose PII/PHI
- No backwards compatibility: write clean, current code
- Never use @spec
- Never use Process.sleep in tests. Instead rely on deterministic logic
- Never use non-critical comments
- Avoid tautological or disjunctive assertions. Each test should assert exactly one expected outcome. If you're uncertain which outcome to expect, that indicates the test setup needs to be more specific, not that the assertion should be looser.
- NEVER use case statements or any kind of conditional logic in test assertions where the conditional logic is meant to handle different outcomes.
- **Avoid overly prescriptive documentation** - LLMs can infer from guidance and put together insights. Don't hard-code deterministic steps or enumerate every field. Document intent and patterns, not implementation details.
- **Code smell: Hard-coded deterministic steps** - Only use determinism where inference is 100% not needed. Let LLMs synthesize information rather than following step-by-step recipes.

## Conventions

This project uses the puck dependency for its AI agent interface. Please refer to the deps documentation for more information as needed.

- AI agents are just loops that pattern match on structured output in the form of structs. This is capable via Puck

## Elixir/OTP Principles

Write idiomatic Elixir. Trust the BEAM.

- **Let it crash** - Don't over-defend with try/rescue. Let supervisors handle failures. Rescue only at boundaries where you must translate errors.
- **Supervisors for fault tolerance** - Processes should be supervised. Design supervisor trees that isolate failure domains.
- **Processes for isolation** - Use processes to isolate state and failure, not just for concurrency.
- **Pattern matching over conditionals** - Prefer function clause matching over if/cond/case when dispatching on shape.
- **Pipelines over nesting** - Use |> for data transformations. Avoid deeply nested function calls.
- **GenServer for state** - When you need state, reach for GenServer. Keep state minimal and focused.
- **Task for fire-and-forget** - Use Task.Supervisor for work that doesn't need a reply.
- **Immutability is the default** - Don't fight it. Transform data, don't mutate it.
- **Fail fast, fail loud** - Raise on invalid inputs at boundaries. Don't silently return nil or defaults.

# BAML Language Reference

BAML is a domain-specific language for building type-safe LLM prompts as functions. This project uses `baml_elixir` to call BAML functions from Elixir.

## Testing

Run tests defined in `.baml` files:

```bash
baml-cli test                          # Run all tests
baml-cli test -i "MyFunction:TestName" # Run specific test
```

## Types

### Primitive Types
```baml
bool      // true/false
int       // integers
float     // decimal numbers
string    // text
null      // null value
```

### Composite Types
```baml
string[]           // array of strings
int?               // optional int
string | int       // union type
map<string, int>   // key-value map
"a" | "b" | "c"    // literal union
```

### Multimodal Types
```baml
image    // for vision models
audio    // for audio models
video    // for video models
pdf      // for document models
```

### Type Aliases
```baml
type Primitive = int | string | bool | float
type Graph = map<string, string[]>

// Recursive types are supported through containers
type JsonValue = int | string | bool | float | JsonObject | JsonArray
type JsonObject = map<string, JsonValue>
type JsonArray = JsonValue[]
```

## Classes

Classes define structured data. Properties have NO colon.

```baml
class MyObject {
  // Required string
  name string

  // Optional field (use ?)
  nickname string?

  // Field with description (goes AFTER the type)
  age int @description("Age in years")

  // Field with alias (renames for LLM, keeps original in code)
  email string @alias("email_address")

  // Arrays (cannot be optional)
  tags string[]

  // Nested objects
  address Address

  // Enum field
  status Status

  // Union type
  result "success" | "error"

  // Literal types
  version 1 | 2 | 3

  // Map type
  metadata map<string, string>

  // Multimodal
  photo image
}

// Recursive classes are supported
class Node {
  value int
  children Node[]
}
```

### Field Attributes
- `@alias("name")` - Rename field for LLM (keeps original name in code)
- `@description("...")` - Add context for the LLM

### Class Attributes
- `@@dynamic` - Allow adding fields at runtime

## Enums

Enums are for classification tasks with a fixed set of values.

```baml
enum Category {
  PENDING
  ACTIVE @description("Currently being processed")
  COMPLETE
  CANCELLED @alias("CANCELED") @description("Was stopped before completion")
  INTERNAL @skip  // Exclude from prompt
}

// Dynamic enum (can modify at runtime)
enum DynamicCategory {
  Value1
  Value2
  @@dynamic
}
```

### Value Attributes
- `@alias("name")` - Rename value for LLM
- `@description("...")` - Add context
- `@skip` - Exclude from prompt

## Functions

Functions define LLM calls with typed inputs/outputs.

```baml
function FunctionName(param1: Type1, param2: Type2) -> ReturnType {
  client "provider/model"
  prompt #"
    Your prompt here with {{ param1 }} and {{ param2 }}

    {{ ctx.output_format }}
  "#
}
```

### LLM Clients (Shorthand Syntax)
```baml
client "openai/gpt-4o"
client "openai/gpt-4o-mini"
client "anthropic/claude-sonnet-4-20250514"
client "anthropic/claude-3-5-haiku-latest"
client "google-ai/gemini-2.0-flash"
```

### Prompt Syntax Rules

1. **Always include inputs** - Reference all input parameters in the prompt
2. **Always include output format** - Use `{{ ctx.output_format }}`
3. **Use roles for chat models** - `{{ _.role("system") }}`, `{{ _.role("user") }}`
4. **DO NOT repeat output schema fields** - `{{ ctx.output_format }}` handles this automatically

### Complete Function Example

```baml
class TweetAnalysis {
  mainTopic string @description("The primary topic of the tweet")
  sentiment "positive" | "negative" | "neutral"
  isSpam bool
}

function ClassifyTweets(tweets: string[]) -> TweetAnalysis[] {
  client "openai/gpt-4o-mini"
  prompt #"
    Analyze each tweet and classify it.

    {{ _.role("user") }}
    {{ tweets }}

    {{ ctx.output_format }}
  "#
}
```

## Prompt Syntax (Jinja)

### Variables
```jinja
{{ variable }}
{{ object.field }}
{{ array[0] }}
```

### Conditionals
```jinja
{% if condition %}
  content
{% elif other_condition %}
  other content
{% else %}
  fallback
{% endif %}
```

### Loops
```jinja
{% for item in items %}
  {{ item }}
{% endfor %}

{% for item in items %}
  {{ _.role("user") if loop.index % 2 == 1 else _.role("assistant") }}
  {{ item }}
{% endfor %}
```

### Roles
```jinja
{{ _.role("system") }}   // System message
{{ _.role("user") }}     // User message
{{ _.role("assistant") }} // Assistant message
```

### Context Variables
```jinja
{{ ctx.output_format }}      // Output schema instructions (REQUIRED)
{{ ctx.client.provider }}    // Current provider name
{{ ctx.client.name }}        // Client name
```

## Template Strings

Reusable prompt snippets:

```baml
template_string FormatMessages(messages: Message[]) #"
  {% for m in messages %}
    {{ _.role(m.role) }}
    {{ m.content }}
  {% endfor %}
"#

function Chat(messages: Message[]) -> string {
  client "openai/gpt-4o"
  prompt #"
    {{ FormatMessages(messages) }}
    {{ ctx.output_format }}
  "#
}
```

## Checks and Assertions

### @assert - Strict validation (raises exception on failure)
```baml
class Person {
  age int @assert(valid_age, {{ this >= 0 and this <= 150 }})
  email string @assert(valid_email, {{ this|regex_match("@") }})
}

// On return type
function GetScore(input: string) -> int @assert(valid_score, {{ this >= 0 and this <= 100 }}) {
  client "openai/gpt-4o"
  prompt #"..."#
}
```

### @check - Non-exception validation (can inspect results)
```baml
class Citation {
  quote string @check(has_content, {{ this|length > 0 }})
}
```

### Block-level assertions (cross-field validation)
```baml
class DateRange {
  start_date string
  end_date string
  @@assert(valid_range, {{ this.start_date < this.end_date }})
}
```

## Multimodal Inputs

```baml
function DescribeImage(img: image) -> string {
  client "openai/gpt-4o"
  prompt #"
    {{ _.role("user") }}
    Describe this image:
    {{ img }}
  "#
}

function TranscribeAudio(audio: audio) -> string {
  client "openai/gpt-4o"
  prompt #"
    {{ _.role("user") }}
    Transcribe: {{ audio }}
  "#
}
```

## Union Return Types (Tool Selection)

```baml
class SearchQuery {
  query string
}

class WeatherRequest {
  city string
}

class CalendarEvent {
  title string
  date string
}

function RouteRequest(input: string) -> SearchQuery | WeatherRequest | CalendarEvent {
  client "openai/gpt-4o"
  prompt #"
    Determine what the user wants and extract the appropriate data.

    {{ _.role("user") }}
    {{ input }}

    {{ ctx.output_format }}
  "#
}
```

## Chat History Pattern

```baml
class Message {
  role "user" | "assistant"
  content string
}

function Chat(messages: Message[]) -> string {
  client "openai/gpt-4o"
  prompt #"
    {{ _.role("system") }}
    You are a helpful assistant.

    {% for message in messages %}
      {{ _.role(message.role) }}
      {{ message.content }}
    {% endfor %}
  "#
}
```

## Tests

```baml
test TestClassify {
  functions [ClassifyTweets]
  args {
    tweets ["Hello world!", "Buy now! Limited offer!"]
  }
}

test TestImage {
  functions [DescribeImage]
  args {
    img { url "https://example.com/image.png" }
  }
}

test TestLocalImage {
  functions [DescribeImage]
  args {
    img { file "test_image.png" }
  }
}
```

## Providers and Clients

### Supported Providers

| Provider | Shorthand Example | Default API Key Env Var |
|----------|-------------------|------------------------|
| **openai** | `"openai/gpt-4o"` | `OPENAI_API_KEY` |
| **anthropic** | `"anthropic/claude-sonnet-4-20250514"` | `ANTHROPIC_API_KEY` |
| **google-ai** | `"google-ai/gemini-2.0-flash"` | `GOOGLE_API_KEY` |
| **vertex** | `"vertex/gemini-2.0-flash"` | Google Cloud credentials |
| **azure-openai** | (requires full config) | `AZURE_OPENAI_API_KEY` |
| **aws-bedrock** | (requires full config) | AWS credentials |

### Named Client (full control)

```baml
client<llm> MyClient {
  provider openai
  options {
    model "gpt-4o"
    api_key env.MY_OPENAI_KEY
    temperature 0.7
    max_tokens 1000
  }
}

function MyFunc(input: string) -> string {
  client MyClient
  prompt #"..."#
}
```

### Retry Policies

```baml
retry_policy MyRetryPolicy {
  max_retries 3
  strategy {
    type exponential_backoff
    delay_ms 200
    multiplier 1.5
    max_delay_ms 10000
  }
}

client<llm> ReliableClient {
  provider openai
  retry_policy MyRetryPolicy
  options {
    model "gpt-4o"
  }
}
```

### Fallback Clients

```baml
client<llm> PrimaryClient {
  provider openai
  options { model "gpt-4o" }
}

client<llm> BackupClient {
  provider anthropic
  options { model "claude-sonnet-4-20250514" }
}

client<llm> ResilientClient {
  provider fallback
  options {
    strategy [
      PrimaryClient
      BackupClient
    ]
  }
}
```

### Environment Variables

Reference environment variables with `env.VAR_NAME`:
```baml
client<llm> MyClient {
  provider openai
  options {
    api_key env.MY_CUSTOM_KEY
    base_url env.CUSTOM_BASE_URL
  }
}
```

## Best Practices

1. **Always use `{{ ctx.output_format }}`** - Never write output schema manually
2. **Use `{{ _.role("user") }}`** - Mark where user inputs begin
3. **Use enums for classification** - Not confidence scores or numbers
4. **Use literal unions for small fixed sets** - `"high" | "medium" | "low"` instead of enums
5. **Use @description on fields** - Guides the LLM without repeating in prompt
6. **Keep prompts concise** - Let the type system do the work
7. **Avoid confidence levels** - Don't add confidence scores to extraction schemas
8. **Use composition over inheritance** - Nest classes instead of inheriting

## Documentation

For detailed documentation: **https://docs.boundaryml.com**
