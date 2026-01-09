defmodule Beamlens.SupervisorTest do
  use ExUnit.Case, async: false

  describe "start_link/1 with client_registry" do
    test "starts supervisor with client_registry" do
      client_registry = %{primary: "Test", clients: []}

      {:ok, supervisor} =
        start_supervised({Beamlens.Supervisor, client_registry: client_registry, watchers: []})

      assert Process.alive?(supervisor)
    end
  end
end
