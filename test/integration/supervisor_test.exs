defmodule Beamlens.Integration.SupervisorTest do
  @moduledoc false

  use Beamlens.IntegrationCase, async: false

  alias Beamlens.Operator
  alias Beamlens.Operator.Supervisor, as: OperatorSupervisor

  setup do
    start_supervised!({Registry, keys: :unique, name: Beamlens.OperatorRegistry})
    :ok
  end

  describe "static operator supervision" do
    @tag timeout: 30_000
    test "starts configured operators as static children" do
      {:ok, supervisor} =
        OperatorSupervisor.start_link(
          name: nil,
          skills: [Beamlens.Skill.Beam]
        )

      children = Supervisor.which_children(supervisor)
      assert length(children) == 1

      [{Beamlens.Skill.Beam, pid, :worker, _}] = children
      assert Process.alive?(pid)

      Supervisor.stop(supervisor)
    end

    @tag timeout: 30_000
    test "operators are accessible via Registry" do
      {:ok, supervisor} =
        OperatorSupervisor.start_link(
          name: nil,
          skills: [Beamlens.Skill.Beam]
        )

      [{pid, _}] = Registry.lookup(Beamlens.OperatorRegistry, Beamlens.Skill.Beam)
      assert Process.alive?(pid)

      status = Operator.status(pid)
      assert status.state == :healthy
      assert status.running == false

      Supervisor.stop(supervisor)
    end
  end
end
