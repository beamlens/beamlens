defmodule Beamlens.SupervisorTest do
  use ExUnit.Case, async: false

  alias Beamlens.Skill.Anomaly.Detector

  describe "start_link/1" do
    test "starts supervisor" do
      {:ok, supervisor} = start_supervised({Beamlens.Supervisor, []})

      assert Process.alive?(supervisor)
    end
  end

  describe "quick start pattern" do
    test "lists configured operators" do
      {:ok, _supervisor} =
        start_supervised(
          {Beamlens,
           skills: [
             Beamlens.Skill.Beam,
             Beamlens.Skill.Ets,
             Beamlens.Skill.Os
           ]}
        )

      operators = Beamlens.list_operators()

      assert length(operators) == 3
      assert Enum.all?(operators, &(&1.running == false))

      names = Enum.map(operators, & &1.name)
      assert Beamlens.Skill.Beam in names
      assert Beamlens.Skill.Ets in names
      assert Beamlens.Skill.Os in names

      beam_op = Enum.find(operators, &(&1.name == Beamlens.Skill.Beam))
      assert beam_op.state == :healthy
      assert beam_op.title == "BEAM VM"
    end
  end

  describe "static coordinator" do
    test "starts coordinator as static child" do
      {:ok, _supervisor} = start_supervised({Beamlens.Supervisor, []})

      assert Process.whereis(Beamlens.Coordinator) != nil
    end
  end

  describe "coordinator configuration" do
    test "coordinator receives client_registry from supervisor" do
      client_registry = %{primary: "Test", clients: []}
      {:ok, _} = start_supervised({Beamlens.Supervisor, client_registry: client_registry})

      pid = Process.whereis(Beamlens.Coordinator)
      state = :sys.get_state(pid)
      assert state.client_registry == client_registry
    end
  end

  describe "default skills" do
    test "uses builtin skills when not specified" do
      {:ok, _} = start_supervised({Beamlens.Supervisor, []})

      operators = Beamlens.list_operators()
      assert length(operators) == 12
    end

    test "treats explicit empty skills list as default skills" do
      {:ok, _} = start_supervised({Beamlens.Supervisor, skills: []})

      operators = Beamlens.list_operators()
      assert length(operators) == 12
    end
  end

  describe "collocated skill configuration" do
    test "accepts {skill, opts} tuple format" do
      {:ok, _} =
        start_supervised(
          {Beamlens,
           skills: [
             Beamlens.Skill.Beam,
             {Beamlens.Skill.Anomaly,
              [
                enabled: true,
                collection_interval_ms: :timer.seconds(30),
                learning_duration_ms: :timer.minutes(10),
                z_threshold: 2.5
              ]}
           ]}
        )

      operators = Beamlens.list_operators()

      assert Enum.find(operators, &(&1.name == Beamlens.Skill.Beam))
      assert Enum.find(operators, &(&1.name == Beamlens.Skill.Anomaly))
    end

    test "mixes module and tuple formats" do
      {:ok, _} =
        start_supervised(
          {Beamlens,
           skills: [
             Beamlens.Skill.Beam,
             Beamlens.Skill.Ets,
             {Beamlens.Skill.Anomaly, enabled: true}
           ]}
        )

      operators = Beamlens.list_operators()

      assert length(operators) == 3
      assert Enum.find(operators, &(&1.name == Beamlens.Skill.Beam))
      assert Enum.find(operators, &(&1.name == Beamlens.Skill.Ets))
      assert Enum.find(operators, &(&1.name == Beamlens.Skill.Anomaly))
    end

    test "collocated config applies to Monitor supervisor" do
      {:ok, _} =
        start_supervised(
          {Beamlens,
           skills: [
             Beamlens.Skill.Beam,
             {Beamlens.Skill.Anomaly,
              [
                enabled: true,
                collection_interval_ms: :timer.seconds(15),
                learning_duration_ms: :timer.minutes(30)
              ]}
           ]}
        )

      detector_pid =
        case Registry.lookup(Beamlens.OperatorRegistry, "monitor_detector") do
          [{pid, _}] -> pid
          [] -> flunk("Monitor detector not found")
        end

      status = Detector.get_status(detector_pid)

      assert status.collection_interval_ms == :timer.seconds(15)
      assert status.state == :learning
    end
  end

  describe "tracer_child/1" do
    test "starts Tracer GenServer when Tracer skill is included" do
      {:ok, _} =
        start_supervised(
          {Beamlens.Supervisor,
           skills: [
             Beamlens.Skill.Beam,
             Beamlens.Skill.Tracer
           ]}
        )

      tracer_pid = Process.whereis(Beamlens.Skill.Tracer)
      assert tracer_pid != nil
      assert Process.alive?(tracer_pid)
    end

    test "does not start Tracer GenServer when Tracer skill is excluded" do
      {:ok, _} =
        start_supervised(
          {Beamlens.Supervisor,
           skills: [
             Beamlens.Skill.Beam
           ]}
        )

      tracer_pid = Process.whereis(Beamlens.Skill.Tracer)
      assert tracer_pid == nil
    end
  end

  describe "anomaly skill defaults" do
    test "anomaly infrastructure starts by default with builtin skills" do
      {:ok, _} = start_supervised({Beamlens.Supervisor, []})

      detector_result = Registry.lookup(Beamlens.OperatorRegistry, "monitor_detector")

      assert [{detector_pid, _}] = detector_result
      assert Process.alive?(detector_pid)

      status = Detector.get_status(detector_pid)
      assert status.state == :learning
    end

    test "detector excludes itself from monitored skills" do
      {:ok, _} = start_supervised({Beamlens.Supervisor, []})

      [{detector_pid, _}] = Registry.lookup(Beamlens.OperatorRegistry, "monitor_detector")
      state = :sys.get_state(detector_pid)

      refute Beamlens.Skill.Anomaly in state.skills
    end

    test "detector can be disabled explicitly" do
      {:ok, _} =
        start_supervised(
          {Beamlens,
           skills: [
             Beamlens.Skill.Beam,
             {Beamlens.Skill.Anomaly, enabled: false}
           ]}
        )

      detector_result = Registry.lookup(Beamlens.OperatorRegistry, "monitor_detector")

      assert detector_result == []
    end
  end
end
