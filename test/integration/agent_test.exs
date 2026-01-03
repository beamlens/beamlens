defmodule Beamlens.Integration.AgentTest do
  @moduledoc false

  use Beamlens.IntegrationCase, async: false

  describe "Agent.run/1 with Ollama" do
    @tag timeout: 120_000
    test "runs agent loop and returns health analysis", %{client_registry: client_registry} do
      {:ok, analysis} = Beamlens.Agent.run(client_registry: client_registry, max_iterations: 10)

      assert %Beamlens.HealthAnalysis{} = analysis
      assert analysis.status in [:healthy, :warning, :critical]
      assert is_binary(analysis.summary)
      assert is_list(analysis.concerns)
      assert is_list(analysis.recommendations)
    end
  end
end
