defmodule Beamlens.Coordinator.Strategy.PipelineTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Beamlens.Coordinator
  alias Beamlens.Coordinator.Strategy.Pipeline
  alias Beamlens.Coordinator.Strategy.Pipeline.Tools.{ClassifyResult, SynthesizeResult}
  alias Beamlens.Operator.Notification

  setup do
    start_supervised!({Registry, keys: :unique, name: Beamlens.OperatorRegistry})
    :ok
  end

  defp mock_client do
    Puck.Client.new({Puck.Backends.Mock, error: :test_stop})
  end

  defp start_pipeline_coordinator(opts \\ []) do
    Process.flag(:trap_exit, true)
    name = :"pipeline_#{:erlang.unique_integer([:positive])}"

    opts =
      opts
      |> Keyword.put(:name, name)
      |> Keyword.put_new(:strategy, Pipeline)

    {:ok, pid} = Coordinator.start_link(opts)

    :sys.replace_state(pid, fn state ->
      %{state | client: mock_client()}
    end)

    {:ok, pid}
  end

  defp stop_coordinator(pid) do
    if Process.alive?(pid) do
      :sys.replace_state(pid, fn state ->
        %{state | pending_task: nil}
      end)

      GenServer.stop(pid, :normal)
    end
  catch
    :exit, _ -> :ok
  end

  defp build_test_notification(overrides \\ %{}) do
    Notification.new(
      Map.merge(
        %{
          operator: :test,
          anomaly_type: "test_anomaly",
          severity: :info,
          context: "Test context",
          observation: "Test observation",
          snapshots: []
        },
        overrides
      )
    )
  end

  defp completed_task do
    task = Task.async(fn -> :ok end)
    Task.await(task)
    task
  end

  defp send_action(pid, task, content) do
    send(pid, {task.ref, {:ok, %{content: content}, Puck.Context.new()}})
  end

  describe "strategy_state initialization" do
    test "starts with nil strategy_state" do
      {:ok, pid} = start_pipeline_coordinator()

      state = :sys.get_state(pid)
      assert state.strategy == Pipeline
      assert state.strategy_state == nil

      stop_coordinator(pid)
    end
  end

  describe "continue_loop/2 — classify stage" do
    test "sets strategy_state to :classifying and starts a task" do
      {:ok, pid} = start_pipeline_coordinator()

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :classify_start},
        [:beamlens, :coordinator, :pipeline_classify_start],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :classify_start, metadata})
        end,
        nil
      )

      :sys.replace_state(pid, fn state ->
        context = Coordinator.build_initial_context(%{reason: "what OS is running?"})
        %{state | status: :running, context: context}
      end)

      send(pid, :continue_after_wait)

      assert_receive {:telemetry, :classify_start, _}, 2_000

      state = :sys.get_state(pid)
      assert state.strategy_state == :classifying

      stop_coordinator(pid)
      :telemetry.detach({ref, :classify_start})
    end
  end

  describe "handle_action — ClassifyResult" do
    test "transitions to :gathering and increments iteration" do
      {:ok, pid} = start_pipeline_coordinator()

      task = completed_task()

      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :running,
            strategy_state: :classifying,
            pending_task: task,
            pending_trace_id: "test-trace"
        }
      end)

      classify_result = %ClassifyResult{
        intent: :question,
        skills: ["Nonexistent.Skill.Here"],
        operator_context: "Report the OS"
      }

      send_action(pid, task, classify_result)

      state = :sys.get_state(pid)
      assert state.iteration == 1

      stop_coordinator(pid)
    end

    test "no operators found continues to synthesize stage" do
      {:ok, pid} = start_pipeline_coordinator()

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :classify_complete},
        [:beamlens, :coordinator, :pipeline_classify_complete],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :classify_complete, metadata})
        end,
        nil
      )

      task = completed_task()

      :sys.replace_state(pid, fn state ->
        context = Coordinator.build_initial_context(%{reason: "test"})

        %{
          state
          | status: :running,
            strategy_state: :classifying,
            pending_task: task,
            pending_trace_id: "test-trace",
            context: context
        }
      end)

      classify_result = %ClassifyResult{
        intent: :question,
        skills: ["Nonexistent.Skill"],
        operator_context: "test"
      }

      send_action(pid, task, classify_result)

      assert_receive {:telemetry, :classify_complete, _}, 1_000

      state = :sys.get_state(pid)
      assert map_size(state.running_operators) == 0

      stop_coordinator(pid)
      :telemetry.detach({ref, :classify_complete})
    end

    test "emits pipeline_classify_complete telemetry" do
      {:ok, pid} = start_pipeline_coordinator()

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :classify_complete},
        [:beamlens, :coordinator, :pipeline_classify_complete],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :classify_complete, metadata})
        end,
        nil
      )

      task = completed_task()

      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :running,
            strategy_state: :classifying,
            pending_task: task,
            pending_trace_id: "test-trace"
        }
      end)

      classify_result = %ClassifyResult{
        intent: :question,
        skills: ["Beamlens.Skill.Beam"],
        operator_context: "Report the OS"
      }

      send_action(pid, task, classify_result)

      assert_receive {:telemetry, :classify_complete,
                      %{intent: :question, skills: ["Beamlens.Skill.Beam"]}},
                     1_000

      stop_coordinator(pid)
      :telemetry.detach({ref, :classify_complete})
    end
  end

  describe "continue_loop/2 — gathering stage" do
    test "polls when operators still running" do
      {:ok, pid} = start_pipeline_coordinator()

      fake_operator_pid = spawn(fn -> :timer.sleep(:infinity) end)
      fake_ref = make_ref()

      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :running,
            strategy_state: :gathering,
            running_operators: %{
              fake_operator_pid => %{
                skill: Beamlens.Skill.Beam,
                ref: fake_ref,
                started_at: DateTime.utc_now()
              }
            }
        }
      end)

      send(pid, :continue_after_wait)

      state = :sys.get_state(pid)
      assert state.strategy_state == :gathering

      Process.exit(fake_operator_pid, :kill)
      stop_coordinator(pid)
    end

    test "transitions to :synthesizing when operators complete" do
      {:ok, pid} = start_pipeline_coordinator()

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :synthesize_start},
        [:beamlens, :coordinator, :pipeline_synthesize_start],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :synthesize_start, metadata})
        end,
        nil
      )

      notification = build_test_notification()

      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :running,
            strategy_state: :gathering,
            running_operators: %{},
            notifications: %{
              notification.id => %{notification: notification, status: :unread}
            },
            context: Coordinator.build_initial_context(%{reason: "test query"})
        }
      end)

      send(pid, :continue_after_wait)

      assert_receive {:telemetry, :synthesize_start, _}, 2_000

      state = :sys.get_state(pid)
      assert state.strategy_state == :synthesizing

      stop_coordinator(pid)
      :telemetry.detach({ref, :synthesize_start})
    end
  end

  describe "handle_action — SynthesizeResult" do
    test "creates insight from notifications and finishes" do
      {:ok, pid} = start_pipeline_coordinator()

      task = completed_task()
      notification = build_test_notification()

      caller_ref = make_ref()
      caller = {self(), caller_ref}

      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :running,
            strategy_state: :synthesizing,
            pending_task: task,
            pending_trace_id: "test-trace",
            caller: caller,
            notifications: %{
              notification.id => %{notification: notification, status: :unread}
            }
        }
      end)

      synthesize_result = %SynthesizeResult{answer: "The system is running macOS."}
      send_action(pid, task, synthesize_result)

      assert_receive {^caller_ref, {:ok, result}}, 1_000

      assert length(result.insights) == 1
      [insight] = result.insights
      assert insight.summary == "The system is running macOS."
      assert notification.id in insight.notification_ids

      stop_coordinator(pid)
    end

    test "resolves all notifications" do
      {:ok, pid} = start_pipeline_coordinator()

      task = completed_task()
      n1 = build_test_notification(%{anomaly_type: "type1"})
      n2 = build_test_notification(%{anomaly_type: "type2"})

      caller_ref = make_ref()
      caller = {self(), caller_ref}

      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :running,
            strategy_state: :synthesizing,
            pending_task: task,
            pending_trace_id: "test-trace",
            caller: caller,
            notifications: %{
              n1.id => %{notification: n1, status: :unread},
              n2.id => %{notification: n2, status: :unread}
            }
        }
      end)

      synthesize_result = %SynthesizeResult{answer: "Both issues are related."}
      send_action(pid, task, synthesize_result)

      assert_receive {^caller_ref, {:ok, _result}}, 1_000

      stop_coordinator(pid)
    end

    test "handles no notifications gracefully" do
      {:ok, pid} = start_pipeline_coordinator()

      task = completed_task()

      caller_ref = make_ref()
      caller = {self(), caller_ref}

      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :running,
            strategy_state: :synthesizing,
            pending_task: task,
            pending_trace_id: "test-trace",
            caller: caller,
            notifications: %{}
        }
      end)

      synthesize_result = %SynthesizeResult{answer: "No issues found."}
      send_action(pid, task, synthesize_result)

      assert_receive {^caller_ref, {:ok, result}}, 1_000
      assert result.insights == []

      stop_coordinator(pid)
    end

    test "emits pipeline_synthesize_complete telemetry" do
      {:ok, pid} = start_pipeline_coordinator()

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {ref, :synthesize_complete},
        [:beamlens, :coordinator, :pipeline_synthesize_complete],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry, :synthesize_complete, metadata})
        end,
        nil
      )

      task = completed_task()
      caller_ref = make_ref()
      caller = {self(), caller_ref}

      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :running,
            strategy_state: :synthesizing,
            pending_task: task,
            pending_trace_id: "test-trace",
            caller: caller,
            notifications: %{}
        }
      end)

      synthesize_result = %SynthesizeResult{answer: "All good."}
      send_action(pid, task, synthesize_result)

      assert_receive {:telemetry, :synthesize_complete, %{trace_id: "test-trace"}}, 1_000

      stop_coordinator(pid)
      :telemetry.detach({ref, :synthesize_complete})
    end
  end

  describe "Pipeline tools schemas" do
    alias Beamlens.Coordinator.Strategy.Pipeline.Tools, as: PipelineTools

    test "classify_schema parses valid classify result" do
      input = %{
        intent: "question",
        skills: ["Beamlens.Skill.Beam"],
        operator_context: "Check memory"
      }

      assert {:ok, %ClassifyResult{intent: :question, skills: ["Beamlens.Skill.Beam"]}} =
               Zoi.parse(PipelineTools.classify_schema(), input)
    end

    test "classify_schema parses investigation intent" do
      input = %{
        intent: "investigation",
        skills: ["Beamlens.Skill.Beam", "Beamlens.Skill.Ets"],
        operator_context: "Investigate memory leak"
      }

      assert {:ok, %ClassifyResult{intent: :investigation}} =
               Zoi.parse(PipelineTools.classify_schema(), input)
    end

    test "synthesize_schema parses valid result" do
      input = %{answer: "The system is healthy."}

      assert {:ok, %SynthesizeResult{answer: "The system is healthy."}} =
               Zoi.parse(PipelineTools.synthesize_schema(), input)
    end
  end
end
