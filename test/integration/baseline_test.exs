defmodule Beamlens.Integration.BaselineTest do
  @moduledoc """
  Integration tests for the baseline learning system.

  Tests that watchers can:
  1. Collect observations over time
  2. Call the LLM for baseline analysis after min_observations
  3. Receive decisions: continue_observing, report_anomaly, or report_healthy
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Beamlens.AlertQueue
  alias Beamlens.Watchers.Server

  defmodule TestObservation do
    @moduledoc false
    defstruct [:observed_at, :memory_pct, :process_count]
  end

  defmodule TestWatcher do
    @moduledoc false
    @behaviour Beamlens.Watchers.Watcher

    def domain, do: :test_baseline

    def tools, do: []

    def init(_config), do: {:ok, %{call_count: 0}}

    def collect_snapshot(_state) do
      %{
        memory_pct: 45.0 + :rand.uniform(10),
        process_count: 100 + :rand.uniform(20),
        collected_at: System.system_time(:millisecond)
      }
    end

    def baseline_config do
      %{
        window_size: 10,
        min_observations: 3
      }
    end

    def snapshot_to_observation(snapshot) do
      %TestObservation{
        observed_at: DateTime.utc_now(),
        memory_pct: snapshot.memory_pct,
        process_count: snapshot.process_count
      }
    end

    def format_observations_for_prompt(observations) do
      Enum.map_join(observations, "\n", fn obs ->
        "#{DateTime.to_iso8601(obs.observed_at)}: memory=#{obs.memory_pct}%, processes=#{obs.process_count}"
      end)
    end
  end

  describe "Baseline.Analyzer with real LLM" do
    @describetag timeout: 120_000

    alias Beamlens.Watchers.Baseline.{Analyzer, Context}
    alias Beamlens.Watchers.ObservationHistory

    test "returns a valid decision with required fields" do
      history = build_observation_history(5)
      context = build_context(5)

      {:ok, decision} = Analyzer.analyze(:test, history, context, TestWatcher)

      assert decision.intent != nil
      assert decision.confidence != nil
    end

    test "does not report anomaly for stable metrics" do
      history = build_stable_history(5)
      context = build_context(5)

      {:ok, decision} = Analyzer.analyze(:test, history, context, TestWatcher)

      refute decision.intent == "report_anomaly"
    end

    defp build_observation_history(count) do
      history = ObservationHistory.new(window_size: 10)

      Enum.reduce(1..count, history, fn i, acc ->
        obs = %TestObservation{
          observed_at: DateTime.add(DateTime.utc_now(), -i * 60, :second),
          memory_pct: 45.0 + :rand.uniform(10),
          process_count: 100 + :rand.uniform(20)
        }

        ObservationHistory.add(acc, obs)
      end)
    end

    defp build_stable_history(count) do
      history = ObservationHistory.new(window_size: 10)

      Enum.reduce(1..count, history, fn i, acc ->
        obs = %TestObservation{
          observed_at: DateTime.add(DateTime.utc_now(), -i * 60, :second),
          memory_pct: 45.0,
          process_count: 100
        }

        ObservationHistory.add(acc, obs)
      end)
    end

    defp build_context(observation_count) do
      ctx = Context.new()

      Enum.reduce(1..observation_count, ctx, fn _, acc ->
        Context.record_observation(acc)
      end)
    end
  end

  describe "Watcher Server baseline flow with real LLM" do
    @describetag timeout: 180_000

    setup do
      {:ok, queue} = start_supervised(AlertQueue)
      {:ok, queue: queue}
    end

    test "triggers baseline analysis after min_observations", %{queue: queue} do
      ref = make_ref()
      parent = self()

      handler = fn event, _measurements, metadata, _ ->
        send(parent, {:telemetry, event, metadata})
      end

      :telemetry.attach_many(
        ref,
        [
          [:beamlens, :watcher, :check_stop],
          [:beamlens, :watcher, :baseline_analysis_start]
        ],
        handler,
        nil
      )

      {:ok, server} =
        Server.start_link(
          watcher_module: TestWatcher,
          cron: "0 0 1 1 *",
          config: [],
          alert_handler: &AlertQueue.push(&1, queue)
        )

      Server.trigger(server)
      assert_receive {:telemetry, [:beamlens, :watcher, :check_stop], _}, 60_000
      Server.trigger(server)
      assert_receive {:telemetry, [:beamlens, :watcher, :check_stop], _}, 60_000
      Server.trigger(server)

      assert_receive {:telemetry, [:beamlens, :watcher, :baseline_analysis_start],
                      %{trace_id: _}},
                     60_000

      :telemetry.detach(ref)
    end

    test "completes baseline analysis after min_observations", %{queue: queue} do
      ref = make_ref()
      parent = self()

      handler = fn event, _measurements, metadata, _ ->
        send(parent, {:telemetry, event, metadata})
      end

      :telemetry.attach_many(
        ref,
        [
          [:beamlens, :watcher, :check_stop],
          [:beamlens, :watcher, :baseline_analysis_stop]
        ],
        handler,
        nil
      )

      {:ok, server} =
        Server.start_link(
          watcher_module: TestWatcher,
          cron: "0 0 1 1 *",
          config: [],
          alert_handler: &AlertQueue.push(&1, queue)
        )

      for _ <- 1..3 do
        Server.trigger(server)
        assert_receive {:telemetry, [:beamlens, :watcher, :check_stop], _}, 60_000
      end

      assert_receive {:telemetry, [:beamlens, :watcher, :baseline_analysis_stop], metadata},
                     60_000

      assert metadata.success == true

      :telemetry.detach(ref)
    end
  end
end
