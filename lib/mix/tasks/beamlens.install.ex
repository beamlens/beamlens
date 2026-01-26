defmodule Mix.Tasks.Beamlens.Install.ProviderConfig do
  @moduledoc false
  @enforce_keys [:name, :provider, :default_model]
  defstruct [:name, :provider, :default_model, :env_var, :base_url, :notice]
end

defmodule Mix.Tasks.Beamlens.Install do
  @shortdoc "Sets up Beamlens in your project."
  @moduledoc """
  #{@shortdoc}

  Running this command will add Beamlens to your supervision tree.

  ## Example

      $ mix igniter.install beamlens
      $ mix igniter.install beamlens --provider openai --model gpt-5-mini
      $ mix igniter.install beamlens --provider ollama --model qwen3

  ## Options

  * `--provider` - LLM provider to use. If not specified, uses the built-in default (Anthropic).
    One of: anthropic, openai, ollama, google-ai, vertex-ai, aws-bedrock, azure-openai, openrouter, openai-generic.
  * `--model` - Model name to use. Only applies when --provider is specified. Defaults vary by provider.

  ## Default Models by Provider

  | Provider | Default Model |
  |----------|---------------|
  | anthropic | claude-haiku-4-5-20251001 |
  | openai | gpt-5-mini |
  | ollama | qwen3 |
  | google-ai | gemini-3-flash-preview |
  | vertex-ai | gemini-3-flash-preview |
  | aws-bedrock | anthropic.claude-haiku-4-5-20251001-v1:0 |
  | azure-openai | gpt-5-mini |
  | openrouter | openai/gpt-5-mini |
  | openai-generic | your-model |

  This will:
  - Add beamlens to mix.exs dependencies
  - Add Beamlens to your Application's supervision tree
  - Configure the LLM provider if specified

  When using default Anthropic provider, set the ANTHROPIC_API_KEY environment variable.
  """

  use Igniter.Mix.Task

  alias Mix.Tasks.Beamlens.Install.ProviderConfig

  @providers %{
    "anthropic" => %ProviderConfig{
      name: "Anthropic",
      provider: "anthropic",
      default_model: "claude-haiku-4-5-20251001",
      env_var: "ANTHROPIC_API_KEY"
    },
    "openai" => %ProviderConfig{
      name: "OpenAI",
      provider: "openai",
      default_model: "gpt-5-mini",
      env_var: "OPENAI_API_KEY"
    },
    "ollama" => %ProviderConfig{
      name: "Ollama",
      provider: "openai-generic",
      default_model: "qwen3",
      base_url: "http://localhost:11434/v1"
    },
    "google-ai" => %ProviderConfig{
      name: "GoogleAI",
      provider: "google-ai",
      default_model: "gemini-3-flash-preview",
      env_var: "GOOGLE_API_KEY"
    },
    "vertex-ai" => %ProviderConfig{
      name: "VertexAI",
      provider: "vertex-ai",
      default_model: "gemini-3-flash-preview",
      notice: "Configure project_id and location in your Application module after installation."
    },
    "aws-bedrock" => %ProviderConfig{
      name: "Bedrock",
      provider: "aws-bedrock",
      default_model: "anthropic.claude-haiku-4-5-20251001-v1:0",
      notice:
        "Configure region in your Application module after installation. Uses AWS credentials."
    },
    "azure-openai" => %ProviderConfig{
      name: "AzureOpenAI",
      provider: "azure-openai",
      default_model: "gpt-5-mini",
      env_var: "AZURE_OPENAI_API_KEY",
      notice:
        "Configure resource_name, deployment_id, and api_version in your Application module."
    },
    "openrouter" => %ProviderConfig{
      name: "OpenRouter",
      provider: "openrouter",
      default_model: "openai/gpt-5-mini",
      env_var: "OPENROUTER_API_KEY"
    },
    "openai-generic" => %ProviderConfig{
      name: "OpenAIGeneric",
      provider: "openai-generic",
      default_model: "your-model",
      base_url: "https://your-api-endpoint/v1",
      notice:
        "Configure base_url and model in your Application module for your OpenAI-compatible API."
    }
  }

  @doc false
  def providers, do: @providers

  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      adds_deps: [{:beamlens, []}],
      installs: [],
      composes: [],
      positional: [],
      schema: [
        provider: :string,
        model: :string
      ],
      defaults: [],
      aliases: [
        p: :provider,
        m: :model
      ],
      example: """
      mix igniter.install beamlens
      mix igniter.install beamlens --provider openai --model gpt-5-mini
      """
    }
  end

  @doc false
  @impl true
  def igniter(igniter) do
    options = igniter.args.options
    provider_key = options[:provider]

    if provider_key do
      child_spec = build_child_spec(provider_key, options[:model])

      igniter
      |> Igniter.Project.Application.add_new_child(child_spec, after: fn _module -> true end)
      |> maybe_add_notice(provider_key)
    else
      Igniter.Project.Application.add_new_child(igniter, Beamlens, after: fn _module -> true end)
    end
  end

  defp build_child_spec(provider_key, model) do
    provider_config = Map.fetch!(@providers, provider_key)
    model = model || provider_config.default_model

    client_options = build_client_options(provider_config, model)

    client_registry = %{
      primary: provider_config.name,
      clients: [
        %{
          name: provider_config.name,
          provider: provider_config.provider,
          options: client_options
        }
      ]
    }

    {Beamlens, [client_registry: client_registry]}
  end

  defp build_client_options(%ProviderConfig{base_url: base_url}, model)
       when not is_nil(base_url) do
    %{model: model, base_url: base_url}
  end

  defp build_client_options(%ProviderConfig{}, model) do
    %{model: model}
  end

  defp maybe_add_notice(igniter, provider_key) do
    provider_config = Map.get(@providers, provider_key)

    igniter
    |> maybe_add_env_var_notice(provider_config)
    |> maybe_add_base_url_notice(provider_config)
    |> maybe_add_custom_notice(provider_config)
  end

  defp maybe_add_env_var_notice(igniter, %ProviderConfig{env_var: env_var, name: name})
       when not is_nil(env_var) do
    Igniter.add_notice(igniter, """
    Set the #{env_var} environment variable to authenticate with #{name}.
    """)
  end

  defp maybe_add_env_var_notice(igniter, %ProviderConfig{}), do: igniter

  defp maybe_add_base_url_notice(igniter, %ProviderConfig{base_url: base_url, name: name})
       when not is_nil(base_url) do
    Igniter.add_notice(igniter, """
    Ensure #{name} is running at #{base_url}.
    """)
  end

  defp maybe_add_base_url_notice(igniter, %ProviderConfig{}), do: igniter

  defp maybe_add_custom_notice(igniter, %ProviderConfig{notice: notice})
       when not is_nil(notice) do
    Igniter.add_notice(igniter, notice)
  end

  defp maybe_add_custom_notice(igniter, %ProviderConfig{}), do: igniter
end
