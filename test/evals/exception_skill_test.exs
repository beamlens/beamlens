defmodule Beamlens.Evals.ExceptionSkillTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Beamlens.ExceptionTestHelper

  alias Beamlens.IntegrationCase
  alias Beamlens.Operator
  alias Beamlens.Operator.Tools.{Done, SendNotification, TakeSnapshot}
  alias Beamlens.Skill.Exception, as: ExceptionSkill
  alias Beamlens.Skill.Exception.ExceptionStore
  alias Puck.Eval.Graders

  @moduletag :eval

  setup do
    start_supervised!({ExceptionStore, name: ExceptionStore})

    case IntegrationCase.build_client_registry() do
      {:ok, registry} ->
        {:ok, client_registry: registry}

      {:error, reason} ->
        flunk(reason)
    end
  end

  describe "exception skill eval" do
    test "no exceptions leads to Done without notification", context do
      {_output, trajectory} =
        Puck.Eval.collect(
          fn ->
            {:ok, pid} =
              Operator.start_link(
                skill: ExceptionSkill,
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

    test "exception spike leads to notification", context do
      for _ <- 1..10 do
        inject_exception(
          %RuntimeError{message: "database connection failed: timeout after 5000ms"},
          stacktrace: [
            {MyApp.Database, :query, 2, [file: ~c"lib/my_app/database.ex", line: 42]},
            {MyApp.UserService, :get_user, 1, [file: ~c"lib/my_app/user_service.ex", line: 15]}
          ]
        )
      end

      {_output, trajectory} =
        Puck.Eval.collect(
          fn ->
            {:ok, pid} =
              Operator.start_link(
                skill: ExceptionSkill,
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
