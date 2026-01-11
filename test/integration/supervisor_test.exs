defmodule Beamlens.Integration.SupervisorTest do
  @moduledoc false

  use Beamlens.IntegrationCase, async: false

  alias Beamlens.Operator.Supervisor, as: OperatorSupervisor

  setup do
    start_supervised!({Registry, keys: :unique, name: Beamlens.OperatorRegistry})
    {:ok, supervisor} = OperatorSupervisor.start_link(name: nil)
    {:ok, supervisor: supervisor}
  end

  describe "start_operator/2 with atom spec" do
    @tag timeout: 30_000
    test "starts builtin beam operator", %{supervisor: supervisor} do
      result = OperatorSupervisor.start_operator(supervisor, :beam)

      assert {:ok, pid} = result
      assert Process.alive?(pid)
    end
  end
end
