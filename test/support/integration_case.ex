defmodule Beamlens.IntegrationCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
    end
  end

  setup do
    case check_ollama_available() do
      :ok ->
        {:ok, client_registry: ollama_client_registry()}

      {:error, reason} ->
        flunk("Ollama is not available: #{reason}. Start Ollama with: ollama serve")
    end
  end

  defp ollama_client_registry do
    %{
      primary: "Ollama",
      clients: [
        %{
          name: "Ollama",
          provider: "openai-generic",
          options: %{base_url: "http://localhost:11434/v1", model: "qwen3:4b"}
        }
      ]
    }
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
