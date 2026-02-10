defmodule Beamlens.Integration.PipelineTest do
  @moduledoc false

  use Beamlens.IntegrationCase, async: false

  alias Beamlens.Coordinator
  alias Beamlens.Coordinator.Strategy.Pipeline

  defp start_pipeline_coordinator(context, opts \\ []) do
    name = :"pipeline_#{:erlang.unique_integer([:positive])}"

    opts =
      opts
      |> Keyword.put(:name, name)
      |> Keyword.put(:client_registry, context.client_registry)
      |> Keyword.put(:strategy, Pipeline)

    start_supervised({Coordinator, opts})
  end

  describe "pipeline classify → gather → synthesize" do
    @tag timeout: 120_000
    test "pipeline processes a simple question end-to-end", context do
      ref = make_ref()
      parent = self()

      events = [
        [:beamlens, :coordinator, :pipeline_classify_start],
        [:beamlens, :coordinator, :pipeline_classify_complete],
        [:beamlens, :coordinator, :pipeline_synthesize_start],
        [:beamlens, :coordinator, :pipeline_synthesize_complete]
      ]

      for event <- events do
        :telemetry.attach(
          {ref, event},
          event,
          fn event_name, _measurements, metadata, _ ->
            send(parent, {:telemetry, event_name, metadata})
          end,
          nil
        )
      end

      on_exit(fn ->
        for event <- events do
          :telemetry.detach({ref, event})
        end
      end)

      {:ok, pid} = start_pipeline_coordinator(context)

      start_operator(context, skill: Beamlens.Skill.Beam)

      result =
        Coordinator.run(pid, %{reason: "What BEAM VM info can you see?"},
          strategy: Pipeline,
          timeout: 90_000,
          deadline: 90_000,
          skills: [Beamlens.Skill.Beam]
        )

      assert_receive {:telemetry, [:beamlens, :coordinator, :pipeline_classify_start], _}, 0
      assert_receive {:telemetry, [:beamlens, :coordinator, :pipeline_classify_complete], _}, 0

      assert {:ok, %{insights: _insights, operator_results: _results}} = result
    end
  end
end
