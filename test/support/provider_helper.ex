defmodule Beamlens.TestSupport.Provider do
  @moduledoc false

  def build_context(provider \\ nil) do
    provider = current_provider(provider)

    case do_build_context(provider) do
      {:ok, context} -> {:ok, Map.put(context, :provider, provider)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_provider(nil), do: System.get_env("BEAMLENS_TEST_PROVIDER", "anthropic")
  defp current_provider(provider), do: provider

  defp do_build_context("anthropic") do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil ->
        {:error, "ANTHROPIC_API_KEY not set. Set it or use BEAMLENS_TEST_PROVIDER=ollama"}

      _key ->
        model = System.get_env("BEAMLENS_TEST_MODEL", "claude-haiku-4-5")

        {:ok,
         %{
           client_registry: %{
             primary: "Anthropic",
             clients: [
               %{
                 name: "Anthropic",
                 provider: "anthropic",
                 options: %{model: model}
               }
             ]
           }
         }}
    end
  end

  defp do_build_context("openai") do
    case System.get_env("OPENAI_API_KEY") do
      nil ->
        {:error, "OPENAI_API_KEY not set"}

      _key ->
        model = System.get_env("BEAMLENS_TEST_MODEL", "gpt-4o-mini")

        {:ok,
         %{
           client_registry: %{
             primary: "OpenAI",
             clients: [
               %{
                 name: "OpenAI",
                 provider: "openai",
                 options: %{model: model}
               }
             ]
           }
         }}
    end
  end

  defp do_build_context("ollama") do
    case check_ollama_available() do
      :ok ->
        model = System.get_env("BEAMLENS_TEST_MODEL", "qwen3:4b")

        {:ok,
         %{
           client_registry: %{
             primary: "Ollama",
             clients: [
               %{
                 name: "Ollama",
                 provider: "openai-generic",
                 options: %{base_url: "http://localhost:11434/v1", model: model}
               }
             ]
           }
         }}

      {:error, reason} ->
        {:error, "Ollama not available: #{reason}. Start with: ollama serve"}
    end
  end

  defp do_build_context("google-ai") do
    case System.get_env("GOOGLE_API_KEY") do
      nil ->
        {:error, "GOOGLE_API_KEY not set. Set it or use BEAMLENS_TEST_PROVIDER=ollama"}

      _key ->
        model = System.get_env("BEAMLENS_TEST_MODEL", "gemini-flash-lite-latest")

        {:ok,
         %{
           client_registry: %{
             primary: "Gemini",
             clients: [
               %{
                 name: "Gemini",
                 provider: "google-ai",
                 options: %{model: model}
               }
             ]
           }
         }}
    end
  end

  defp do_build_context("zai") do
    case System.get_env("ZAI_API_KEY") do
      nil ->
        {:error, "ZAI_API_KEY not set. Set it or use BEAMLENS_TEST_PROVIDER=ollama"}

      _key ->
        model = System.get_env("BEAMLENS_TEST_MODEL", "glm-4.7-flash")

        {:ok,
         %{
           client_registry: %{
             primary: "Zai",
             clients: [
               %{
                 name: "Zai",
                 provider: "zai",
                 options: %{model: model}
               }
             ]
           }
         }}
    end
  end

  defp do_build_context("mock") do
    responses = [
      %Beamlens.Operator.Tools.TakeSnapshot{intent: "take_snapshot"},
      %Beamlens.Operator.Tools.Done{intent: "done"}
    ]

    puck_client =
      Puck.Test.mock_client(
        responses,
        default: %Beamlens.Operator.Tools.Done{intent: "done"}
      )

    {:ok, %{client_registry: %{}, puck_client: puck_client}}
  end

  defp do_build_context(provider) do
    {:error,
     "Unknown provider: #{provider}. Use anthropic, openai, google-ai, zai, ollama, or mock"}
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
