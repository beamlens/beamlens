defmodule Beamlens.IntegrationCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      import Beamlens.IntegrationCase, only: [start_operator: 2]
    end
  end

  @doc """
  Starts an operator under the test supervisor.

  Uses `start_supervised/2` so the operator is automatically cleaned up
  when the test ends. The GenServer is now responsive during LLM calls
  (via Task.async), so normal shutdown works.

  ## Example

      {:ok, pid} = start_operator(context, skill_module: MySkill)

  """
  def start_operator(context, opts) do
    opts = Keyword.put(opts, :client_registry, context.client_registry)
    start_supervised({Beamlens.Operator, opts})
  end

  setup do
    provider = System.get_env("BEAMLENS_TEST_PROVIDER", "anthropic")

    case build_client_registry(provider) do
      {:ok, registry} ->
        {:ok, client_registry: registry}

      {:error, reason} ->
        flunk(reason)
    end
  end

  defp build_client_registry("anthropic") do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil ->
        {:error, "ANTHROPIC_API_KEY not set. Set it or use BEAMLENS_TEST_PROVIDER=ollama"}

      _key ->
        model = System.get_env("BEAMLENS_TEST_MODEL", "claude-haiku-4-5")

        {:ok,
         %{
           primary: "Anthropic",
           clients: [
             %{
               name: "Anthropic",
               provider: "anthropic",
               options: %{model: model}
             }
           ]
         }}
    end
  end

  defp build_client_registry("openai") do
    case System.get_env("OPENAI_API_KEY") do
      nil ->
        {:error, "OPENAI_API_KEY not set"}

      _key ->
        model = System.get_env("BEAMLENS_TEST_MODEL", "gpt-4o-mini")

        {:ok,
         %{
           primary: "OpenAI",
           clients: [
             %{
               name: "OpenAI",
               provider: "openai",
               options: %{model: model}
             }
           ]
         }}
    end
  end

  defp build_client_registry("ollama") do
    case check_ollama_available() do
      :ok ->
        model = System.get_env("BEAMLENS_TEST_MODEL", "qwen3:4b")

        {:ok,
         %{
           primary: "Ollama",
           clients: [
             %{
               name: "Ollama",
               provider: "openai-generic",
               options: %{base_url: "http://localhost:11434/v1", model: model}
             }
           ]
         }}

      {:error, reason} ->
        {:error, "Ollama not available: #{reason}. Start with: ollama serve"}
    end
  end

  defp build_client_registry(provider) do
    {:error, "Unknown provider: #{provider}. Use anthropic, openai, or ollama"}
  end

  defp check_ollama_available do
    Application.ensure_all_started(:inets)
    url = ~c"http://localhost:11434/api/tags"

    case :httpc.request(:get, {url, []}, [timeout: 5000], []) do
      {:ok, {{_, 200, _}, _, _}} ->
        :ok

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "Ollama returned status #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
