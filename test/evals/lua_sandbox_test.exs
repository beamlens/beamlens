defmodule Beamlens.Evals.LuaSandboxTest do
  use ExUnit.Case, async: false

  alias Beamlens.IntegrationCase
  alias Beamlens.Operator
  alias Beamlens.Operator.Tools.{Execute, SendNotification, TakeSnapshot}
  alias Puck.Eval.Graders

  @moduletag :eval

  setup do
    case IntegrationCase.build_client_registry() do
      {:ok, registry} ->
        {:ok, client_registry: registry}

      {:error, reason} ->
        flunk(reason)
    end
  end

  defmodule InvestigationSkill do
    @behaviour Beamlens.Skill

    def id, do: :eval_investigation

    def title, do: "Investigation Skill"

    def description, do: "Investigation skill for Lua sandbox evals"

    def system_prompt, do: "You are a test skill for Lua sandbox evals."

    def snapshot do
      %{
        memory_utilization_pct: 78.5,
        process_utilization_pct: 45.0,
        port_utilization_pct: 12.0,
        atom_utilization_pct: 3.5,
        scheduler_run_queue: 15,
        schedulers_online: 8
      }
    end

    def callbacks do
      %{
        "inv_get_memory" => fn ->
          %{
            "total_mb" => 512.5,
            "processes_mb" => 245.8,
            "binary_mb" => 89.2,
            "ets_mb" => 78.4,
            "code_mb" => 45.1,
            "system_mb" => 54.0
          }
        end,
        "inv_get_top_processes" => fn limit ->
          processes =
            for i <- 1..min(limit, 5) do
              %{
                "pid" => "<0.#{100 + i}.0>",
                "name" => "worker_#{i}",
                "memory_kb" => 50_000 - i * 5000,
                "message_queue" => 100 - i * 10,
                "reductions" => 1_000_000 - i * 100_000
              }
            end

          %{"total" => 150, "showing" => length(processes), "processes" => processes}
        end,
        "inv_get_schedulers" => fn ->
          %{
            "schedulers_online" => 8,
            "run_queue" => 15,
            "run_queue_lengths" => [3, 2, 4, 1, 2, 1, 1, 1],
            "dirty_cpu_schedulers" => 8,
            "dirty_io_schedulers" => 10
          }
        end,
        "inv_get_message_queues" => fn ->
          %{
            "total_messages" => 1250,
            "max_queue_length" => 89,
            "processes_with_queues" => 23
          }
        end,
        "inv_health_score" => fn ->
          %{
            "overall_score" => 65,
            "memory_score" => 70,
            "scheduler_score" => 55,
            "process_score" => 72,
            "recommendation" => "Consider investigating scheduler contention"
          }
        end
      }
    end

    def callback_docs do
      """
      ### inv_get_memory()
      Detailed memory breakdown in MB: total_mb, processes_mb, binary_mb, ets_mb, code_mb, system_mb

      ### inv_get_top_processes(limit)
      Top N processes by memory. Returns total count and process list with pid, name, memory_kb, message_queue, reductions

      ### inv_get_schedulers()
      Scheduler statistics: schedulers_online, run_queue, run_queue_lengths (per scheduler), dirty schedulers

      ### inv_get_message_queues()
      Message queue analysis: total_messages, max_queue_length, processes_with_queues

      ### inv_health_score()
      Compute overall health score (0-100) with component scores and recommendations
      """
    end
  end

  describe "lua sandbox eval" do
    test "elevated metrics trigger investigation using execute tool", context do
      {_output, trajectory} =
        Puck.Eval.collect(
          fn ->
            {:ok, pid} =
              Operator.start_link(
                skill: InvestigationSkill,
                start_loop: true,
                client_registry: context.client_registry
              )

            wait_for_execute_and_stop(pid)
            :ok
          end,
          timeout: 100
        )

      result =
        Puck.Eval.grade(nil, trajectory, [
          Graders.output_produced(TakeSnapshot),
          Graders.output_produced(Execute),
          Graders.output_not_produced(SendNotification)
        ])

      assert result.passed?,
             "Eval failed. Expected LLM to use execute tool for investigation.\nSteps: #{trajectory.total_steps}\nResults: #{inspect(result.grader_results, pretty: true)}"
    end
  end

  defp wait_for_execute_and_stop(pid) do
    ref = make_ref()
    parent = self()

    :telemetry.attach_many(
      ref,
      [
        [:beamlens, :operator, :execute_complete],
        [:beamlens, :operator, :execute_error]
      ],
      fn _event, _measurements, _metadata, _ ->
        send(parent, {:execute_done, ref})
      end,
      nil
    )

    receive do
      {:execute_done, ^ref} ->
        Operator.stop(pid)
    after
      60_000 -> raise "Operator did not reach Execute within timeout"
    end

    :telemetry.detach(ref)
  end
end
