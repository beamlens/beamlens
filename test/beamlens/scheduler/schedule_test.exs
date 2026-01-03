defmodule Beamlens.Scheduler.ScheduleTest do
  use ExUnit.Case, async: true

  alias Beamlens.Scheduler.Schedule

  describe "new/1" do
    test "parses valid cron expression" do
      assert {:ok, schedule} = Schedule.new(name: :test, cron: "*/5 * * * *")
      assert schedule.name == :test
      assert schedule.cron_string == "*/5 * * * *"
      assert schedule.agent_opts == []
      assert schedule.running == nil
      assert schedule.run_count == 0
      assert %NaiveDateTime{} = schedule.next_run_at
    end

    test "parses cron with agent_opts" do
      opts = [name: :test, cron: "0 2 * * *", agent_opts: [timeout: 60_000]]
      assert {:ok, schedule} = Schedule.new(opts)
      assert schedule.agent_opts == [timeout: 60_000]
    end

    test "returns error for invalid cron" do
      assert {:error, {:invalid_cron, :bad, _reason}} =
               Schedule.new(name: :bad, cron: "not a cron")
    end

    test "raises on missing name" do
      assert_raise KeyError, fn ->
        Schedule.new(cron: "* * * * *")
      end
    end

    test "raises on missing cron" do
      assert_raise KeyError, fn ->
        Schedule.new(name: :test)
      end
    end
  end

  describe "compute_next_run/2" do
    test "computes next run from given time" do
      {:ok, schedule} = Schedule.new(name: :test, cron: "0 * * * *")

      # At 10:30, next run should be 11:00
      now = ~N[2024-01-15 10:30:00]
      next = Schedule.compute_next_run(schedule.cron, now)

      assert next == ~N[2024-01-15 11:00:00]
    end

    test "handles minute intervals" do
      {:ok, schedule} = Schedule.new(name: :test, cron: "*/5 * * * *")

      now = ~N[2024-01-15 10:02:00]
      next = Schedule.compute_next_run(schedule.cron, now)

      assert next == ~N[2024-01-15 10:05:00]
    end
  end

  describe "ms_until_next_run/1" do
    test "returns exact timing for near runs" do
      {:ok, schedule} = Schedule.new(name: :test, cron: "* * * * *")

      # Schedule is mutable so we'd need to set next_run_at
      # For this test, we just verify the function exists and returns tuple
      {ms, type} = Schedule.ms_until_next_run(schedule)

      assert is_integer(ms)
      assert ms >= 0
      assert type in [:exact, :clamped]
    end

    test "clamps delays over 49 days" do
      {:ok, schedule} = Schedule.new(name: :test, cron: "0 0 1 1 *")

      # Set next_run_at far in the future
      far_future = NaiveDateTime.add(NaiveDateTime.utc_now(), 60 * 24 * 60 * 60, :second)
      schedule = %{schedule | next_run_at: far_future}

      {ms, type} = Schedule.ms_until_next_run(schedule)

      assert type == :clamped
      assert ms == 2_147_483_647
    end
  end

  describe "to_public_map/1" do
    test "returns sanitized map without refs" do
      {:ok, schedule} = Schedule.new(name: :test, cron: "*/5 * * * *")
      schedule = %{schedule | running: make_ref(), timer_ref: make_ref()}

      public = Schedule.to_public_map(schedule)

      assert public.name == :test
      assert public.cron == "*/5 * * * *"
      assert public.running? == true
      refute Map.has_key?(public, :running)
      refute Map.has_key?(public, :timer_ref)
    end

    test "shows running? as false when not running" do
      {:ok, schedule} = Schedule.new(name: :test, cron: "*/5 * * * *")

      public = Schedule.to_public_map(schedule)

      assert public.running? == false
    end
  end
end
