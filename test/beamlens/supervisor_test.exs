defmodule Beamlens.SupervisorTest do
  use ExUnit.Case, async: false

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
             [skill: Beamlens.Skill.Beam],
             [skill: Beamlens.Skill.Ets],
             [skill: Beamlens.Skill.System]
           ]}
        )

      # Verify operators are listed correctly
      operators = Beamlens.list_operators()

      assert length(operators) == 3
      # Static operators are always running (in idle status)
      assert Enum.all?(operators, &(&1.running == false))

      names = Enum.map(operators, & &1.name)
      assert Beamlens.Skill.Beam in names
      assert Beamlens.Skill.Ets in names
      assert Beamlens.Skill.System in names

      # Verify each operator has expected structure (idle until invoked)
      beam_op = Enum.find(operators, &(&1.name == Beamlens.Skill.Beam))
      assert beam_op.state == :healthy
      assert beam_op.title == "BEAM VM"
    end
  end

  describe "static coordinator" do
    test "starts coordinator as static child" do
      {:ok, _supervisor} = start_supervised({Beamlens.Supervisor, []})

      # Coordinator should be registered with its module name
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
      assert length(operators) == 7
    end
  end
end
