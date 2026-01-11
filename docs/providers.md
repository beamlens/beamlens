# LLM Provider Configuration

BeamLens supports the vast majority of LLM providers. You can configure them in the `client_registry` section of your configuration.

```elixir
{Beamlens,
  operators: [:beam],
  client_registry: %{
    primary: "Ollama",
    clients: [
      %{
        name: "Ollama",
        provider: "openai-generic",
        options: %{base_url: "http://localhost:11434/v1", model: "llama3.2"}
      }
    ]
  }}
```

BeamLens utilizes BAML to provide LLM Client support. See the [ClientRegistry](https://docs.boundaryml.com/ref/baml_client/client-registry) documentation if you have questions beyond what this documentation provides.

## Default: Anthropic

By default Anthropic is configured with the `claude-haiku-4-5` model. No configuration needed. Set your API key and you're ready:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

## Anthropic

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

```elixir
client_registry: %{
  primary: "Anthropic",
  clients: [
    %{
      name: "Anthropic",
      provider: "anthropic",
      options: %{model: "claude-haiku-4-5-20251001"}
    }
  ]
}
```

Refer to the [BAML Anthropic documentation](https://docs.boundaryml.com/ref/llm-client-providers/anthropic) for more details.


## AWS Bedrock

AWS Bedrock uses standard AWS authentication methods.


```elixir
client_registry: %{
  primary: "Bedrock",
  clients: [
    %{
      name: "Bedrock",
      provider: "aws-bedrock",
      options: %{
        model: "anthropic.claude-3-5-haiku-20241022-v1:0",
        region: "us-east-1"
      }
    }
  ]
}
```

Refer to the [BAML AWS Bedrock documentation](https://docs.boundaryml.com/ref/llm-client-providers/aws-bedrock) for more details.

## Google AI Gemini

```bash
export GOOGLE_API_KEY="..."
```

```elixir
client_registry: %{
  primary: "GoogleAI",
  clients: [
    %{
      name: "GoogleAI",
      provider: "google-ai",
      options: %{model: "gemini-2.0-flash"}
    }
  ]
}
```

Refer to the [BAML Google AI Gemini documentation](https://docs.boundaryml.com/ref/llm-client-providers/google-ai-gemini) for more details.

## Google Vertex AI

Uses Google Cloud Application Default Credentials.

```elixir
client_registry: %{
  primary: "GoogleVertexAI",
  clients: [
    %{
      name: "GoogleVertexAI",
      provider: "vertex-ai",
      options: %{
        model: "gemini-2.5-pro",
        location: "us-central1",
        project_id: "my-project-id",
        query_params: %{
          key: "Your VERTEX_API_KEY" # Or set the API KEY
        }
      }
    }
  ]
}
```

Refer to the [BAML Vertex AI documentation](https://docs.boundaryml.com/ref/llm-client-providers/google-vertex) for more details.

## Ollama (Local)

No API key. Your data stays on your machine.

```bash
# Install and run Ollama
ollama serve
ollama pull llama3.2
```

```elixir
client_registry: %{
  primary: "Ollama",
  clients: [
    %{
      name: "Ollama",
      provider: "openai-generic",
      options: %{
        base_url: "http://localhost:11434/v1",
        model: "llama3.2"
      }
    }
  ]
}
```

Refer to the [BAML Ollama documentation](https://docs.boundaryml.com/ref/llm-client-providers/ollama) for more details.

## OpenAI

```bash
export OPENAI_API_KEY="sk-..."
```

```elixir
client_registry: %{
  primary: "OpenAI",
  clients: [
    %{
      name: "OpenAI",
      provider: "openai",
      options: %{model: "gpt-4o-mini"}
    }
  ]
}
```

Refer to the [BAML OpenAI documentation](https://docs.boundaryml.com/ref/llm-client-providers/open-ai) for more details.

## OpenAI Azure

```bash
export AZURE_OPENAI_API_KEY="..."
```

```elixir
client_registry: %{
  primary: "AzureOpenAI",
  clients: [
    %{
      name: "AzureOpenAI",
      provider: "azure-openai",
      options: %{
        resource_name: "your-resource-name",
        deployment_id: "your-deployment-id",
        api_version: "2024-02-15-preview"
      }
    }
  ]
}
```

Refer to the [BAML OpenAI Azure documentation](https://docs.boundaryml.com/ref/llm-client-providers/open-ai-from-azure) for more details.

## OpenAI Generic

```elixir
client_registry: %{
  primary: "OpenAIGeneric",
  clients: [
    %{
      name: "OpenAIGeneric",
      provider: "openai-generic",
      options: %{
        base_url: "https://api.provider.com",
        model: "o<provider-specified-format>"
      }
    }
  ]
}
```

Refer to the [BAML OpenAI Generic documentation](https://docs.boundaryml.com/ref/llm-client-providers/openai-generic) for more details.

## OpenRouter

```bash
export OPENROUTER_API_KEY="..."
```

```elixir
client_registry: %{
  primary: "OpenRouter",
  clients: [
    %{
      name: "OpenRouter",
      provider: "openrouter",
      options: %{
        model: "openai/gpt-4o-mini"
      }
    }
  ]
}
```

Refer to the [BAML OpenRouter documentation](https://docs.boundaryml.com/ref/llm-client-providers/openrouter) for more details.

## Advanced Patterns

### Retry Policy

Handle transient failures with exponential backoff. BeamLens includes a `DefaultRetry` policy (3 retries, exponential backoff starting at 200ms):

```elixir
client_registry: %{
  primary: "Anthropic",
  clients: [
    %{
      name: "Anthropic",
      provider: "anthropic",
      options: %{model: "claude-haiku-4-5-20251001"},
      retry_policy: "DefaultRetry"
    }
  ]
}
```

The `DefaultRetry` policy uses:
- 3 retries after initial failure
- Exponential backoff starting at 200ms
- 1.5x multiplier per retry
- Maximum delay of 10 seconds

### Fallback Chains

Switch providers when your primary fails:

```elixir
client_registry: %{
  primary: "PrimaryWithFallback",
  clients: [
    %{
      name: "Primary",
      provider: "anthropic",
      options: %{model: "claude-haiku-4-5-20251001"}
    },
    %{
      name: "Backup",
      provider: "openai",
      options: %{model: "gpt-4o-mini"}
    },
    %{
      name: "PrimaryWithFallback",
      provider: "fallback",
      options: %{strategy: ["Primary", "Backup"]}
    }
  ]
}
```

### Round-Robin

Distribute load across multiple providers or API keys:

```elixir
client_registry: %{
  primary: "RoundRobinClient",
  clients: [
    %{
      name: "Client1",
      provider: "anthropic",
      options: %{model: "claude-haiku-4-5-20251001"}
    },
    %{
      name: "Client2",
      provider: "anthropic",
      options: %{model: "claude-haiku-4-5-20251001"}
    },
    %{
      name: "RoundRobinClient",
      provider: "round-robin",
      options: %{strategy: ["Client1", "Client2"]}
    }
  ]
}
```

Each request cycles through the clients in order. Useful for spreading rate limits across multiple API keys.

## More Providers

BeamLens uses [BAML](https://docs.boundaryml.com/docs/snippets/clients/overview) for LLM integration. Any provider BAML supports works with BeamLens:

- Together AI
- Groq
- Vercel AI Gateway
- And more

See the [BAML provider documentation](https://docs.boundaryml.com/docs/snippets/clients/overview) for the full list and configuration options.
