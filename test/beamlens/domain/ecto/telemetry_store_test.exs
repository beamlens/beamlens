defmodule Beamlens.Domain.Ecto.TelemetryStoreTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Beamlens.Domain.Ecto.TelemetryStore

  defmodule FakeRepo do
    def config, do: [telemetry_prefix: [:test, :repo]]
  end

  setup do
    start_supervised!({Registry, keys: :unique, name: Beamlens.Domain.Ecto.Registry})

    {:ok, pid} =
      start_supervised(
        {TelemetryStore, repo: FakeRepo, slow_threshold_ms: 50, window_ms: :timer.minutes(5)}
      )

    {:ok, store: pid, repo: FakeRepo}
  end

  describe "query_stats/1" do
    test "returns empty stats when no events", %{repo: repo} do
      stats = TelemetryStore.query_stats(repo)

      assert stats.query_count == 0
      assert stats.avg_time_ms == 0.0
      assert stats.max_time_ms == 0.0
      assert stats.p95_time_ms == 0.0
      assert stats.slow_count == 0
      assert stats.error_count == 0
    end

    test "receives events when handler called directly", %{store: store} do
      measurements = %{
        total_time: System.convert_time_unit(10_000, :microsecond, :native),
        query_time: System.convert_time_unit(8_000, :microsecond, :native),
        decode_time: System.convert_time_unit(1_000, :microsecond, :native),
        queue_time: System.convert_time_unit(0, :microsecond, :native),
        idle_time: System.convert_time_unit(0, :microsecond, :native)
      }

      metadata = %{source: nil, result: {:ok, []}}

      TelemetryStore.handle_telemetry_event(
        [:test, :repo, :query],
        measurements,
        metadata,
        %{pid: store}
      )

      TelemetryStore.flush(FakeRepo)
      stats = TelemetryStore.query_stats(FakeRepo)

      assert stats.query_count == 1
    end

    test "telemetry handlers are attached", %{} do
      handlers = :telemetry.list_handlers([:test, :repo, :query])
      handler_ids = Enum.map(handlers, & &1.id)

      assert "beamlens-ecto-#{inspect(FakeRepo)}" in handler_ids
    end

    test "aggregates telemetry events", %{repo: repo} do
      emit_query_event(10)
      emit_query_event(20)
      emit_query_event(30)
      TelemetryStore.flush(repo)

      stats = TelemetryStore.query_stats(repo)

      assert stats.query_count == 3
      assert stats.avg_time_ms == 20.0
      assert stats.max_time_ms == 30.0
    end

    test "counts slow queries", %{repo: repo} do
      emit_query_event(10)
      emit_query_event(100)
      emit_query_event(200)
      TelemetryStore.flush(repo)

      stats = TelemetryStore.query_stats(repo)

      assert stats.slow_count == 2
    end

    test "counts error queries", %{repo: repo} do
      emit_query_event(10, :ok)
      emit_query_event(20, :error)
      emit_query_event(30, :error)
      TelemetryStore.flush(repo)

      stats = TelemetryStore.query_stats(repo)

      assert stats.error_count == 2
    end
  end

  describe "slow_queries/2" do
    test "returns empty list when no slow queries", %{repo: repo} do
      emit_query_event(10)
      emit_query_event(20)
      TelemetryStore.flush(repo)

      result = TelemetryStore.slow_queries(repo, 10)

      assert result.queries == []
      assert result.threshold_ms == 50
    end

    test "returns slow queries sorted by time", %{repo: repo} do
      emit_query_event(100, :ok, "lib/app.ex:10")
      emit_query_event(200, :ok, "lib/app.ex:20")
      emit_query_event(150, :ok, "lib/app.ex:15")
      TelemetryStore.flush(repo)

      result = TelemetryStore.slow_queries(repo, 10)

      assert length(result.queries) == 3
      [first, second, third] = result.queries
      assert first.total_time_ms == 200.0
      assert second.total_time_ms == 150.0
      assert third.total_time_ms == 100.0
    end

    test "respects limit", %{repo: repo} do
      emit_query_event(100)
      emit_query_event(200)
      emit_query_event(150)
      TelemetryStore.flush(repo)

      result = TelemetryStore.slow_queries(repo, 2)

      assert length(result.queries) == 2
    end

    test "includes source in slow query results", %{repo: repo} do
      emit_query_event(100, :ok, "lib/my_app/users.ex:42")
      TelemetryStore.flush(repo)

      result = TelemetryStore.slow_queries(repo, 10)

      [query] = result.queries
      assert query.source == "lib/my_app/users.ex:42"
    end
  end

  describe "max_events" do
    test "caps events at max_events limit", %{} do
      # Send more events than max_events directly to the existing store
      # The store has default 50k max, but we can test the behavior
      # by calling handle_telemetry_event directly and checking the cap

      # Restart with low max_events
      stop_supervised!({TelemetryStore, FakeRepo})

      {:ok, capped_store} =
        start_supervised({TelemetryStore, repo: FakeRepo, max_events: 5})

      for _ <- 1..10 do
        TelemetryStore.handle_telemetry_event(
          [:test, :repo, :query],
          %{
            total_time: 1000,
            query_time: 800,
            decode_time: 100,
            queue_time: 0,
            idle_time: 0
          },
          %{source: nil, result: {:ok, []}},
          %{pid: capped_store}
        )
      end

      TelemetryStore.flush(FakeRepo)
      stats = TelemetryStore.query_stats(FakeRepo)

      assert stats.query_count == 5
    end
  end

  describe "pool_stats/1" do
    test "returns empty stats when no events", %{repo: repo} do
      stats = TelemetryStore.pool_stats(repo)

      assert stats.avg_queue_time_ms == 0.0
      assert stats.max_queue_time_ms == 0.0
      assert stats.p95_queue_time_ms == 0.0
      assert stats.high_contention_count == 0
    end

    test "aggregates queue times", %{repo: repo} do
      emit_query_event_with_queue(10, 5)
      emit_query_event_with_queue(20, 10)
      emit_query_event_with_queue(30, 15)
      TelemetryStore.flush(repo)

      stats = TelemetryStore.pool_stats(repo)

      assert stats.avg_queue_time_ms == 10.0
      assert stats.max_queue_time_ms == 15.0
    end

    test "counts high contention events", %{repo: repo} do
      emit_query_event_with_queue(10, 10)
      emit_query_event_with_queue(20, 60)
      emit_query_event_with_queue(30, 100)
      TelemetryStore.flush(repo)

      stats = TelemetryStore.pool_stats(repo)

      assert stats.high_contention_count == 2
    end
  end

  defp emit_query_event(total_time_ms, result \\ :ok, source \\ nil) do
    emit_query_event_with_queue(total_time_ms, 0, result, source)
  end

  defp emit_query_event_with_queue(total_time_ms, queue_time_ms, result \\ :ok, source \\ nil) do
    measurements = %{
      total_time: ms_to_native(total_time_ms),
      query_time: ms_to_native(total_time_ms * 0.8),
      decode_time: ms_to_native(total_time_ms * 0.1),
      queue_time: ms_to_native(queue_time_ms),
      idle_time: ms_to_native(0)
    }

    metadata = %{
      source: source,
      result: if(result == :ok, do: {:ok, []}, else: {:error, :fake_error})
    }

    :telemetry.execute([:test, :repo, :query], measurements, metadata)
  end

  defp ms_to_native(ms) do
    System.convert_time_unit(trunc(ms * 1000), :microsecond, :native)
  end
end
