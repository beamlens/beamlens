defmodule Beamlens.Evals.EctoSkillTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Beamlens.EctoTestHelper

  alias Beamlens.IntegrationCase
  alias Beamlens.Operator
  alias Beamlens.Operator.Tools.{Done, SendNotification, TakeSnapshot}
  alias Beamlens.Skill.Ecto.TelemetryStore
  alias Puck.Eval.Graders

  @moduletag :eval

  defmodule FakeRepo do
    def config, do: [telemetry_prefix: [:test, :ecto_eval]]
    def __adapter__, do: Ecto.Adapters.Postgres
  end

  defmodule TestEctoSkill do
    use Beamlens.Skill.Ecto, repo: FakeRepo
  end

  setup do
    start_supervised!({Registry, keys: :unique, name: Beamlens.Skill.Ecto.Registry})
    start_supervised!({TelemetryStore, repo: FakeRepo, slow_threshold_ms: 100})

    case IntegrationCase.build_client_registry() do
      {:ok, registry} ->
        {:ok, client_registry: registry}

      {:error, reason} ->
        flunk(reason)
    end
  end

  describe "ecto skill eval" do
    test "no queries leads to Done without notification", context do
      {_output, trajectory} =
        Puck.Eval.collect(
          fn ->
            {:ok, pid} =
              Operator.start_link(
                skill: TestEctoSkill,
                start_loop: true,
                client_registry: context.client_registry
              )

            wait_for_done_and_stop(pid)
            :ok
          end,
          timeout: 100
        )

      result =
        Puck.Eval.grade(nil, trajectory, [
          Graders.output_produced(TakeSnapshot),
          Graders.output_not_produced(SendNotification),
          Graders.output_produced(Done)
        ])

      assert result.passed?,
             "Eval failed.\nSteps: #{trajectory.total_steps}\nResults: #{inspect(result.grader_results, pretty: true)}"
    end

    test "slow query spike leads to notification", context do
      for _ <- 1..10 do
        inject_slow_query(
          FakeRepo,
          total_time_ms: 500,
          source: "lib/my_app/database.ex:42"
        )
      end

      {_output, trajectory} =
        Puck.Eval.collect(
          fn ->
            {:ok, pid} =
              Operator.start_link(
                skill: TestEctoSkill,
                start_loop: true,
                client_registry: context.client_registry
              )

            wait_for_done_and_stop(pid)
            :ok
          end,
          timeout: 100
        )

      result =
        Puck.Eval.grade(nil, trajectory, [
          Graders.output_produced(TakeSnapshot),
          Graders.output_produced(SendNotification)
        ])

      assert result.passed?,
             "Eval failed.\nSteps: #{trajectory.total_steps}\nResults: #{inspect(result.grader_results, pretty: true)}"
    end
  end

  defp wait_for_done_and_stop(pid) do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      ref,
      [:beamlens, :operator, :done],
      fn _event, _measurements, _metadata, _ ->
        send(parent, {:done_fired, ref})
      end,
      nil
    )

    receive do
      {:done_fired, ^ref} ->
        Operator.stop(pid)
    after
      60_000 -> raise "Operator did not reach Done action within timeout"
    end

    :telemetry.detach(ref)
  end
end
