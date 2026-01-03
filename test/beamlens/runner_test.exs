defmodule Beamlens.RunnerTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  describe "run-in-progress guard" do
    test "skips overlapping runs" do
      # Start runner in manual mode so we can control when runs happen
      {:ok, pid} = GenServer.start_link(Beamlens.Runner, mode: :manual)

      # Manually set state to running: true to simulate an in-progress run
      :sys.replace_state(pid, fn state -> %{state | running: true, interval: 1000} end)

      # Send a :run message while "running"
      log =
        capture_log(fn ->
          send(pid, :run)
          # Give it time to process
          Process.sleep(50)
        end)

      assert log =~ "Skipping run - previous run still in progress"

      # Clean up
      GenServer.stop(pid)
    end

    test "includes running: false in initial state" do
      {:ok, pid} = GenServer.start_link(Beamlens.Runner, mode: :manual)

      state = :sys.get_state(pid)
      assert state.running == false

      GenServer.stop(pid)
    end
  end
end
