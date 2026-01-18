defmodule Beamlens.Evals.OperatorTest do
  use ExUnit.Case, async: false

  alias Beamlens.Operator
  alias Beamlens.Operator.Tools.{SendNotification, TakeSnapshot, Wait}
  alias Beamlens.TestSupport.Provider
  alias Puck.Eval.Graders

  @moduletag :eval

  setup do
    case Provider.build_context() do
      {:ok, context} -> {:ok, context}
      {:error, reason} -> flunk(reason)
    end
  end

  defp with_client(
         %{provider: "mock", client_registry: client_registry},
         %Puck.Client{} = client,
         opts
       ) do
    opts
    |> Keyword.put(:client_registry, client_registry)
    |> Keyword.put(:puck_client, client)
  end

  defp with_client(%{client_registry: client_registry}, _client, opts) do
    Keyword.put(opts, :client_registry, client_registry)
  end

  defp provider_puck_client(%{provider: "mock"}) do
    Beamlens.Testing.mock_client([
      %Beamlens.Operator.Tools.TakeSnapshot{intent: "take_snapshot"},
      %Beamlens.Operator.Tools.Wait{intent: "wait", ms: 1}
    ])
  end

  defp provider_puck_client(_context), do: nil

  defmodule HealthySkill do
    @behaviour Beamlens.Skill

    def title, do: "Healthy Skill"

    def description, do: "Test skill for operator evals"

    def system_prompt, do: "You are a test skill for operator evals."

    def snapshot do
      %{
        memory_utilization_pct: 45.0,
        process_utilization_pct: 10.0,
        port_utilization_pct: 5.0,
        atom_utilization_pct: 2.0,
        scheduler_run_queue: 0,
        schedulers_online: 8
      }
    end

    def callbacks do
      %{
        "get_test_value" => fn -> 42 end
      }
    end

    def callback_docs do
      "### get_test_value()\nReturns 42 for testing"
    end
  end

  describe "operator happy path eval" do
    test "healthy metrics lead to TakeSnapshot and eventually Wait (no notifications)", context do
      puck_client = provider_puck_client(context)

      {_output, trajectory} =
        Puck.Eval.collect(
          fn ->
            {:ok, pid} =
              Operator.start_link(
                with_client(context, puck_client, skill: HealthySkill, start_loop: true)
              )

            wait_for_wait_and_stop(pid)
            :ok
          end,
          timeout: 100
        )

      result =
        Puck.Eval.grade(nil, trajectory, [
          Graders.output_produced(TakeSnapshot),
          Graders.output_not_produced(SendNotification),
          Graders.output_produced(Wait)
        ])

      assert result.passed?,
             "Eval failed.\nSteps: #{trajectory.total_steps}\nResults: #{inspect(result.grader_results, pretty: true)}"
    end
  end

  defp wait_for_wait_and_stop(pid) do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      ref,
      [:beamlens, :operator, :wait],
      fn _event, _measurements, _metadata, _ ->
        send(parent, {:wait_fired, ref})
      end,
      nil
    )

    receive do
      {:wait_fired, ^ref} ->
        Operator.stop(pid)
    after
      60_000 -> raise "Operator did not reach Wait action within timeout"
    end

    :telemetry.detach(ref)
  end
end
