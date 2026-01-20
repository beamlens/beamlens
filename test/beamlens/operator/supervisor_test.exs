defmodule Beamlens.Operator.SupervisorTest do
  @moduledoc false

  use ExUnit.Case

  alias Beamlens.Operator
  alias Beamlens.Operator.Supervisor, as: OperatorSupervisor

  defmodule TestSkill do
    @behaviour Beamlens.Skill

    def title, do: "Test Skill"

    def description, do: "Test skill for supervisor tests"

    def system_prompt, do: "You are a test skill for supervisor tests."

    def snapshot do
      %{
        memory_utilization_pct: 45.0,
        process_utilization_pct: 10.0,
        port_utilization_pct: 5.0,
        atom_utilization_pct: 2.0,
        scheduler_run_queue: 0,
        schedulers_online: 8
      }
    end

    def callbacks, do: %{}

    def callback_docs, do: "Test skill callbacks"
  end

  defmodule TestSkill2 do
    @behaviour Beamlens.Skill

    def title, do: "Test Skill 2"

    def description, do: "Second test skill for supervisor tests"

    def system_prompt, do: "You are a second test skill for supervisor tests."

    def snapshot do
      %{
        memory_utilization_pct: 50.0,
        process_utilization_pct: 15.0,
        port_utilization_pct: 6.0,
        atom_utilization_pct: 3.0,
        scheduler_run_queue: 1,
        schedulers_online: 8
      }
    end

    def callbacks, do: %{}

    def callback_docs, do: "Test skill 2 callbacks"
  end

  describe "init/1 with configured operators" do
    setup do
      :persistent_term.erase({Beamlens.Supervisor, :skills})
      start_supervised!({Registry, keys: :unique, name: Beamlens.OperatorRegistry})

      on_exit(fn ->
        :persistent_term.erase({Beamlens.Supervisor, :skills})
      end)

      :ok
    end

    test "starts operators as static children" do
      {:ok, supervisor} =
        OperatorSupervisor.start_link(
          name: nil,
          skills: [TestSkill, TestSkill2]
        )

      children = Supervisor.which_children(supervisor)
      assert length(children) == 2

      skill_ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)
      assert TestSkill in skill_ids
      assert TestSkill2 in skill_ids

      Supervisor.stop(supervisor)
    end

    test "operators start in idle status" do
      {:ok, supervisor} =
        OperatorSupervisor.start_link(
          name: nil,
          skills: [TestSkill]
        )

      [{TestSkill, pid, :worker, _}] = Supervisor.which_children(supervisor)

      status = Operator.status(pid)
      assert status.running == false
      assert status.state == :healthy

      Supervisor.stop(supervisor)
    end

    test "operators are registered in OperatorRegistry" do
      {:ok, supervisor} =
        OperatorSupervisor.start_link(
          name: nil,
          skills: [TestSkill]
        )

      [{pid, _}] = Registry.lookup(Beamlens.OperatorRegistry, TestSkill)
      assert Process.alive?(pid)

      Supervisor.stop(supervisor)
    end

    test "passes client_registry to operators" do
      client_registry = %{primary: "Test", clients: []}

      {:ok, supervisor} =
        OperatorSupervisor.start_link(
          name: nil,
          skills: [TestSkill],
          client_registry: client_registry
        )

      [{TestSkill, pid, :worker, _}] = Supervisor.which_children(supervisor)

      state = :sys.get_state(pid)
      assert state.client_registry == client_registry

      Supervisor.stop(supervisor)
    end

    test "handles keyword spec for operators" do
      {:ok, supervisor} =
        OperatorSupervisor.start_link(
          name: nil,
          skills: [[skill: TestSkill]]
        )

      children = Supervisor.which_children(supervisor)
      assert length(children) == 1

      Supervisor.stop(supervisor)
    end

    test "skips invalid skill modules" do
      {:ok, supervisor} =
        OperatorSupervisor.start_link(
          name: nil,
          skills: [TestSkill, :invalid_skill]
        )

      children = Supervisor.which_children(supervisor)
      assert length(children) == 1

      Supervisor.stop(supervisor)
    end
  end

  describe "list_operators/0" do
    setup do
      :persistent_term.erase({Beamlens.Supervisor, :skills})
      start_supervised!({Registry, keys: :unique, name: Beamlens.OperatorRegistry})

      on_exit(fn ->
        :persistent_term.erase({Beamlens.Supervisor, :skills})
      end)

      :ok
    end

    test "returns empty list when no skills configured" do
      :persistent_term.put({Beamlens.Supervisor, :skills}, [])

      {:ok, supervisor} = OperatorSupervisor.start_link(name: nil, skills: [])
      assert OperatorSupervisor.list_operators() == []
      Supervisor.stop(supervisor)
    end

    test "returns list of operator statuses" do
      :persistent_term.put({Beamlens.Supervisor, :skills}, [TestSkill, TestSkill2])

      {:ok, supervisor} =
        OperatorSupervisor.start_link(
          name: nil,
          skills: [TestSkill, TestSkill2]
        )

      operators = OperatorSupervisor.list_operators()

      assert length(operators) == 2
      names = Enum.map(operators, & &1.name)
      assert TestSkill in names
      assert TestSkill2 in names

      Supervisor.stop(supervisor)
    end

    test "includes title and description from skill module" do
      :persistent_term.put({Beamlens.Supervisor, :skills}, [TestSkill])

      {:ok, supervisor} =
        OperatorSupervisor.start_link(
          name: nil,
          skills: [TestSkill]
        )

      [operator] = OperatorSupervisor.list_operators()

      assert operator.title == "Test Skill"
      assert operator.description == "Test skill for supervisor tests"

      Supervisor.stop(supervisor)
    end
  end

  describe "operator_status/1" do
    setup do
      :persistent_term.erase({Beamlens.Supervisor, :skills})
      start_supervised!({Registry, keys: :unique, name: Beamlens.OperatorRegistry})

      on_exit(fn ->
        :persistent_term.erase({Beamlens.Supervisor, :skills})
      end)

      :ok
    end

    test "returns operator status" do
      {:ok, supervisor} =
        OperatorSupervisor.start_link(
          name: nil,
          skills: [TestSkill]
        )

      {:ok, status} = OperatorSupervisor.operator_status(TestSkill)

      assert status.operator == TestSkill
      assert status.state == :healthy

      Supervisor.stop(supervisor)
    end

    test "returns error for non-existent operator" do
      {:ok, supervisor} = OperatorSupervisor.start_link(name: nil, skills: [])
      assert {:error, :not_found} = OperatorSupervisor.operator_status(:nonexistent)
      Supervisor.stop(supervisor)
    end
  end

  describe "resolve_skill/1" do
    test "resolves valid skill module" do
      assert {:ok, TestSkill} = OperatorSupervisor.resolve_skill(TestSkill)
    end

    test "returns error for invalid skill module" do
      assert {:error, {:invalid_skill_module, :unknown}} =
               OperatorSupervisor.resolve_skill(:unknown)
    end

    test "resolves builtin skill atoms" do
      assert {:ok, Beamlens.Skill.Beam} = OperatorSupervisor.resolve_skill(:beam)
      assert {:ok, Beamlens.Skill.Ets} = OperatorSupervisor.resolve_skill(:ets)
    end
  end
end
