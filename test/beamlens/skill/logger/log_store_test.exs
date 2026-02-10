defmodule Beamlens.Skill.Logger.LogStoreTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Beamlens.Skill.Logger.LogStore

  @test_name :test_log_store

  setup do
    {:ok, pid} = start_supervised({LogStore, name: @test_name, max_size: 100})
    {:ok, store: pid}
  end

  describe "get_stats/1" do
    test "returns empty stats when no logs" do
      stats = LogStore.get_stats(@test_name)

      assert stats.total_count == 0
      assert stats.error_count == 0
      assert stats.warning_count == 0
      assert stats.info_count == 0
      assert stats.debug_count == 0
      assert stats.error_rate == 0.0
      assert stats.error_module_count == 0
    end

    test "aggregates log events by level", %{store: _store} do
      capture_log(fn ->
        Logger.error("error message")
        Logger.warning("warning message")
        Logger.warning("another warning")
      end)

      LogStore.flush(@test_name)

      stats = LogStore.get_stats(@test_name)

      assert stats.total_count >= 3
      assert stats.error_count >= 1
      assert stats.warning_count >= 2
    end

    test "calculates error rate", %{store: _store} do
      capture_log(fn ->
        Logger.error("error 1")
        Logger.error("error 2")
        Logger.warning("warning 1")
        Logger.warning("warning 2")
      end)

      LogStore.flush(@test_name)

      stats = LogStore.get_stats(@test_name)

      assert stats.error_count >= 2
      assert stats.warning_count >= 2
      assert stats.error_rate > 0.0
    end
  end

  describe "get_logs/2" do
    test "returns empty list when no logs" do
      logs = LogStore.get_logs(@test_name)
      assert logs == []
    end

    test "log entries use :func key instead of :function", %{store: _store} do
      capture_log(fn ->
        Logger.warning("shape test")
      end)

      LogStore.flush(@test_name)

      [entry | _] =
        @test_name
        |> LogStore.get_logs(limit: 10)
        |> Enum.filter(&String.contains?(&1.message, "shape test"))

      assert %{timestamp: _, level: _, message: _, module: _, func: _, line: _, domain: _} = entry
      refute Map.has_key?(entry, :function)
    end

    test "returns logs", %{store: _store} do
      capture_log(fn ->
        Logger.warning("first")
        Logger.warning("second")
        Logger.warning("third")
      end)

      LogStore.flush(@test_name)

      logs = LogStore.get_logs(@test_name)

      assert length(logs) >= 3
      messages = Enum.map(logs, & &1.message)
      assert Enum.any?(messages, &String.contains?(&1, "first"))
      assert Enum.any?(messages, &String.contains?(&1, "second"))
      assert Enum.any?(messages, &String.contains?(&1, "third"))
    end

    test "filters by level", %{store: _store} do
      capture_log(fn ->
        Logger.error("error")
        Logger.warning("warning")
      end)

      LogStore.flush(@test_name)

      logs = LogStore.get_logs(@test_name, level: "error")

      assert logs != []
      assert Enum.all?(logs, &(&1.level == :error))
    end

    test "respects limit", %{store: _store} do
      capture_log(fn ->
        for i <- 1..10 do
          Logger.warning("message #{i}")
        end
      end)

      LogStore.flush(@test_name)

      logs = LogStore.get_logs(@test_name, limit: 5)

      assert length(logs) == 5
    end
  end

  describe "recent_errors/2" do
    test "returns only error-level logs", %{store: _store} do
      capture_log(fn ->
        Logger.warning("warning")
        Logger.error("error 1")
        Logger.warning("another warning")
        Logger.error("error 2")
      end)

      LogStore.flush(@test_name)

      errors = LogStore.recent_errors(@test_name, 10)

      assert length(errors) >= 2
      assert Enum.all?(errors, &(&1.level == :error))
    end

    test "respects limit", %{store: _store} do
      capture_log(fn ->
        for i <- 1..10 do
          Logger.error("error #{i}")
        end
      end)

      LogStore.flush(@test_name)

      errors = LogStore.recent_errors(@test_name, 3)

      assert length(errors) == 3
    end
  end

  describe "search/3" do
    test "returns matching logs", %{store: _store} do
      capture_log(fn ->
        Logger.warning("user logged in")
        Logger.warning("user logged out")
        Logger.warning("system started")
      end)

      LogStore.flush(@test_name)

      results = LogStore.search(@test_name, "user", limit: 10)

      assert length(results) >= 2
    end

    test "returns empty list for no matches", %{store: _store} do
      capture_log(fn ->
        Logger.warning("hello world")
      end)

      LogStore.flush(@test_name)

      results = LogStore.search(@test_name, "xyznotfound123", limit: 10)

      assert results == []
    end

    test "handles invalid regex gracefully", %{store: _store} do
      capture_log(fn ->
        Logger.warning("test message")
      end)

      LogStore.flush(@test_name)

      results = LogStore.search(@test_name, "[invalid", limit: 10)

      assert results == []
    end
  end

  describe "message truncation" do
    test "truncates messages exceeding 2048 bytes", %{store: _store} do
      long_message = String.duplicate("x", 3000)

      capture_log(fn ->
        Logger.warning(long_message)
      end)

      LogStore.flush(@test_name)

      logs = LogStore.get_logs(@test_name, limit: 1)
      [log] = Enum.filter(logs, &String.contains?(&1.message, "xxx"))

      assert String.length(log.message) < 3000
      assert String.ends_with?(log.message, "... (truncated)")
    end
  end

  describe "ring buffer behavior" do
    test "enforces max size", %{} do
      stop_supervised!(LogStore)
      {:ok, _pid} = start_supervised({LogStore, name: @test_name, max_size: 5})

      capture_log(fn ->
        for i <- 1..10 do
          Logger.warning("message #{i}")
        end
      end)

      LogStore.flush(@test_name)

      stats = LogStore.get_stats(@test_name)

      assert stats.total_count == 5
    end
  end

  describe "logger handler" do
    test "handlers are registered" do
      handlers = :logger.get_handler_ids()

      matching =
        Enum.filter(handlers, fn id ->
          id |> Atom.to_string() |> String.starts_with?("beamlens_logger_")
        end)

      assert matching != []
    end
  end

  describe "when store not running" do
    test "get_stats returns empty stats for non-existent store" do
      stats = LogStore.get_stats(:nonexistent_store)

      assert stats.total_count == 0
      assert stats.error_count == 0
    end

    test "get_logs returns empty list for non-existent store" do
      logs = LogStore.get_logs(:nonexistent_store)
      assert logs == []
    end

    test "recent_errors returns empty list for non-existent store" do
      errors = LogStore.recent_errors(:nonexistent_store, 10)
      assert errors == []
    end

    test "search returns empty list for non-existent store" do
      results = LogStore.search(:nonexistent_store, "test", limit: 10)
      assert results == []
    end
  end
end
