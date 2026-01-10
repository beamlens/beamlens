defmodule Beamlens.Domain.LoggerTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Beamlens.Domain.Logger, as: LoggerDomain
  alias Beamlens.Domain.Logger.LogStore

  setup do
    start_supervised!({LogStore, name: LogStore})
    :ok
  end

  describe "domain/0" do
    test "returns :logger" do
      assert LoggerDomain.domain() == :logger
    end
  end

  describe "snapshot/0" do
    test "returns expected keys" do
      snapshot = LoggerDomain.snapshot()

      assert Map.has_key?(snapshot, :total_logs_1m)
      assert Map.has_key?(snapshot, :error_count_1m)
      assert Map.has_key?(snapshot, :warning_count_1m)
      assert Map.has_key?(snapshot, :error_rate_pct)
      assert Map.has_key?(snapshot, :unique_error_modules)
    end

    test "returns numeric values" do
      snapshot = LoggerDomain.snapshot()

      assert is_integer(snapshot.total_logs_1m)
      assert is_integer(snapshot.error_count_1m)
      assert is_integer(snapshot.warning_count_1m)
      assert is_float(snapshot.error_rate_pct) or is_integer(snapshot.error_rate_pct)
      assert is_integer(snapshot.unique_error_modules)
    end
  end

  describe "callbacks/0" do
    test "returns all expected callback keys" do
      callbacks = LoggerDomain.callbacks()

      assert Map.has_key?(callbacks, "logger_stats")
      assert Map.has_key?(callbacks, "logger_recent")
      assert Map.has_key?(callbacks, "logger_errors")
      assert Map.has_key?(callbacks, "logger_search")
      assert Map.has_key?(callbacks, "logger_by_module")
    end

    test "all callbacks are functions" do
      callbacks = LoggerDomain.callbacks()

      Enum.each(callbacks, fn {name, callback} ->
        assert is_function(callback), "#{name} should be a function"
      end)
    end

    test "logger_stats callback returns stats" do
      callbacks = LoggerDomain.callbacks()
      stats = callbacks["logger_stats"].()

      assert is_map(stats)
      assert Map.has_key?(stats, :total_count)
      assert Map.has_key?(stats, :error_count)
    end

    test "logger_recent callback returns logs" do
      callbacks = LoggerDomain.callbacks()
      logs = callbacks["logger_recent"].(10, nil)

      assert is_list(logs)
    end

    test "logger_errors callback returns errors" do
      callbacks = LoggerDomain.callbacks()
      errors = callbacks["logger_errors"].(10)

      assert is_list(errors)
    end

    test "logger_search callback returns results" do
      callbacks = LoggerDomain.callbacks()
      results = callbacks["logger_search"].("test", 10)

      assert is_list(results)
    end

    test "logger_by_module callback returns logs" do
      callbacks = LoggerDomain.callbacks()
      logs = callbacks["logger_by_module"].("TestModule", 10)

      assert is_list(logs)
    end
  end

  describe "callback_docs/0" do
    test "returns documentation string" do
      docs = LoggerDomain.callback_docs()

      assert is_binary(docs)
      assert String.contains?(docs, "logger_stats")
      assert String.contains?(docs, "logger_recent")
      assert String.contains?(docs, "logger_errors")
      assert String.contains?(docs, "logger_search")
      assert String.contains?(docs, "logger_by_module")
    end
  end
end
