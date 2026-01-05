defmodule Beamlens.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias Beamlens.CircuitBreaker

  setup do
    case Process.whereis(CircuitBreaker) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    :ok
  end

  describe "init/1" do
    test "starts with closed state and default options" do
      {:ok, pid} = CircuitBreaker.start_link()

      try do
        state = CircuitBreaker.get_state()

        assert state.state == :closed
        assert state.failure_count == 0
        assert state.success_count == 0
        assert state.failure_threshold == 5
        assert state.reset_timeout == 30_000
        assert state.success_threshold == 2
      after
        GenServer.stop(pid)
      end
    end

    test "accepts custom configuration" do
      opts = [
        failure_threshold: 3,
        reset_timeout: 10_000,
        success_threshold: 1
      ]

      {:ok, pid} = CircuitBreaker.start_link(opts)

      try do
        state = CircuitBreaker.get_state()

        assert state.failure_threshold == 3
        assert state.reset_timeout == 10_000
        assert state.success_threshold == 1
      after
        GenServer.stop(pid)
      end
    end
  end

  describe "allow?/0" do
    test "returns true when circuit is closed" do
      {:ok, pid} = CircuitBreaker.start_link()

      try do
        assert CircuitBreaker.allow?() == true
      after
        GenServer.stop(pid)
      end
    end

    test "returns true when circuit is half_open" do
      opts = [failure_threshold: 1, reset_timeout: 60_000]
      {:ok, pid} = CircuitBreaker.start_link(opts)

      try do
        CircuitBreaker.record_failure(:test_error)
        assert CircuitBreaker.get_state().state == :open

        send(pid, :reset_timeout)
        _ = CircuitBreaker.get_state()

        assert CircuitBreaker.get_state().state == :half_open
        assert CircuitBreaker.allow?() == true
      after
        GenServer.stop(pid)
      end
    end

    test "returns false when circuit is open" do
      opts = [failure_threshold: 1, reset_timeout: 60_000]
      {:ok, pid} = CircuitBreaker.start_link(opts)

      try do
        CircuitBreaker.record_failure(:test_error)
        assert CircuitBreaker.get_state().state == :open
        assert CircuitBreaker.allow?() == false
      after
        GenServer.stop(pid)
      end
    end
  end

  describe "record_failure/1" do
    test "increments failure count" do
      {:ok, pid} = CircuitBreaker.start_link()

      try do
        CircuitBreaker.record_failure(:error_1)

        state = CircuitBreaker.get_state()
        assert state.failure_count == 1
        assert state.last_failure_reason == :error_1
      after
        GenServer.stop(pid)
      end
    end

    test "opens circuit after threshold reached" do
      opts = [failure_threshold: 3, reset_timeout: 60_000]
      {:ok, pid} = CircuitBreaker.start_link(opts)

      try do
        CircuitBreaker.record_failure(:error_1)
        CircuitBreaker.record_failure(:error_2)
        CircuitBreaker.record_failure(:error_3)

        state = CircuitBreaker.get_state()
        assert state.state == :open
        assert state.failure_count == 3
      after
        GenServer.stop(pid)
      end
    end

    test "transitions from half_open back to open on failure" do
      opts = [failure_threshold: 1, reset_timeout: 60_000]
      {:ok, pid} = CircuitBreaker.start_link(opts)

      try do
        CircuitBreaker.record_failure(:first_error)
        assert CircuitBreaker.get_state().state == :open

        send(pid, :reset_timeout)
        _ = CircuitBreaker.get_state()
        assert CircuitBreaker.get_state().state == :half_open

        CircuitBreaker.record_failure(:second_error)

        state = CircuitBreaker.get_state()
        assert state.state == :open
        assert state.last_failure_reason == :second_error
      after
        GenServer.stop(pid)
      end
    end
  end

  describe "record_success/0" do
    test "resets failure count when closed" do
      opts = [failure_threshold: 5]
      {:ok, pid} = CircuitBreaker.start_link(opts)

      try do
        CircuitBreaker.record_failure(:error_1)
        CircuitBreaker.record_failure(:error_2)
        assert CircuitBreaker.get_state().failure_count == 2

        CircuitBreaker.record_success()

        assert CircuitBreaker.get_state().failure_count == 0
      after
        GenServer.stop(pid)
      end
    end

    test "closes circuit after success threshold in half_open" do
      opts = [failure_threshold: 1, reset_timeout: 60_000, success_threshold: 2]
      {:ok, pid} = CircuitBreaker.start_link(opts)

      try do
        CircuitBreaker.record_failure(:error)
        assert CircuitBreaker.get_state().state == :open

        send(pid, :reset_timeout)
        _ = CircuitBreaker.get_state()
        assert CircuitBreaker.get_state().state == :half_open

        CircuitBreaker.record_success()
        assert CircuitBreaker.get_state().state == :half_open
        assert CircuitBreaker.get_state().success_count == 1

        CircuitBreaker.record_success()

        state = CircuitBreaker.get_state()
        assert state.state == :closed
        assert state.failure_count == 0
        assert state.success_count == 0
      after
        GenServer.stop(pid)
      end
    end
  end

  describe "reset/0" do
    test "resets circuit to closed state" do
      opts = [failure_threshold: 1, reset_timeout: 60_000]
      {:ok, pid} = CircuitBreaker.start_link(opts)

      try do
        CircuitBreaker.record_failure(:error)
        assert CircuitBreaker.get_state().state == :open

        assert :ok = CircuitBreaker.reset()

        state = CircuitBreaker.get_state()
        assert state.state == :closed
        assert state.failure_count == 0
        assert state.success_count == 0
        assert state.last_failure_at == nil
        assert state.last_failure_reason == nil
      after
        GenServer.stop(pid)
      end
    end
  end

  describe "state transitions" do
    test "full cycle: closed -> open -> half_open -> closed" do
      opts = [failure_threshold: 2, reset_timeout: 60_000, success_threshold: 1]
      {:ok, pid} = CircuitBreaker.start_link(opts)

      try do
        assert CircuitBreaker.get_state().state == :closed

        CircuitBreaker.record_failure(:error_1)
        CircuitBreaker.record_failure(:error_2)
        assert CircuitBreaker.get_state().state == :open

        send(pid, :reset_timeout)
        _ = CircuitBreaker.get_state()
        assert CircuitBreaker.get_state().state == :half_open

        CircuitBreaker.record_success()
        assert CircuitBreaker.get_state().state == :closed
      after
        GenServer.stop(pid)
      end
    end

    test "half_open -> open on single failure" do
      opts = [failure_threshold: 1, reset_timeout: 60_000, success_threshold: 3]
      {:ok, pid} = CircuitBreaker.start_link(opts)

      try do
        CircuitBreaker.record_failure(:first)
        assert CircuitBreaker.get_state().state == :open

        send(pid, :reset_timeout)
        _ = CircuitBreaker.get_state()
        assert CircuitBreaker.get_state().state == :half_open

        CircuitBreaker.record_success()
        assert CircuitBreaker.get_state().state == :half_open
        assert CircuitBreaker.get_state().success_count == 1

        CircuitBreaker.record_failure(:second)

        state = CircuitBreaker.get_state()
        assert state.state == :open
        assert state.success_count == 0
      after
        GenServer.stop(pid)
      end
    end
  end

  describe "telemetry events" do
    test "emits state_change event on transition" do
      opts = [failure_threshold: 1, reset_timeout: 60_000]
      {:ok, pid} = CircuitBreaker.start_link(opts)

      test_pid = self()

      :telemetry.attach(
        "test-state-change",
        [:beamlens, :circuit_breaker, :state_change],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      try do
        CircuitBreaker.record_failure(:error)

        assert_receive {:telemetry, [:beamlens, :circuit_breaker, :state_change], measurements,
                        metadata},
                       1000

        assert is_integer(measurements.system_time)
        assert metadata.from == :closed
        assert metadata.to == :open
        assert metadata.failure_count == 1
        assert metadata.reason == :error
      after
        :telemetry.detach("test-state-change")
        GenServer.stop(pid)
      end
    end

    test "emits rejected event when circuit is open" do
      opts = [failure_threshold: 1, reset_timeout: 60_000]
      {:ok, pid} = CircuitBreaker.start_link(opts)

      test_pid = self()

      :telemetry.attach(
        "test-rejected",
        [:beamlens, :circuit_breaker, :rejected],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      try do
        CircuitBreaker.record_failure(:error)
        assert CircuitBreaker.get_state().state == :open

        CircuitBreaker.allow?()

        assert_receive {:telemetry, [:beamlens, :circuit_breaker, :rejected], measurements,
                        metadata},
                       1000

        assert is_integer(measurements.system_time)
        assert metadata.state == :open
        assert metadata.failure_count == 1
      after
        :telemetry.detach("test-rejected")
        GenServer.stop(pid)
      end
    end
  end
end
