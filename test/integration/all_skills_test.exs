defmodule Beamlens.Integration.AllSkillsTest do
  @moduledoc """
  Tests that all built-in skills work correctly in integration.

  Verifies each skill can start an operator and take a snapshot.
  """

  use Beamlens.IntegrationCase, async: false

  @skills [
    {:beam, Beamlens.Skill.Beam},
    {:ets, Beamlens.Skill.Ets},
    {:gc, Beamlens.Skill.Gc},
    {:ports, Beamlens.Skill.Ports},
    {:sup, Beamlens.Skill.Sup},
    {:exception, Beamlens.Skill.Exception}
  ]

  setup do
    start_supervised!(Beamlens.Skill.Exception.ExceptionStore)
    :ok
  end

  describe "built-in skills" do
    for {skill_name, skill_module} <- @skills do
      @tag timeout: 30_000
      test "#{skill_name} skill starts and takes snapshot", context do
        skill_module = unquote(skill_module)
        skill_name = unquote(skill_name)
        parent = self()
        handler_id = "#{skill_name}-snapshot-#{System.unique_integer()}"
        on_exit(fn -> :telemetry.detach(handler_id) end)

        :telemetry.attach(
          handler_id,
          [:beamlens, :operator, :take_snapshot],
          fn _event, _measurements, %{operator: o, snapshot_id: id}, _ ->
            if o == skill_name, do: send(parent, {:snapshot, id})
          end,
          nil
        )

        {:ok, _pid} = start_operator(context, skill_module: skill_module)

        assert_receive {:snapshot, snapshot_id}, 25_000
        assert is_binary(snapshot_id)
        assert String.length(snapshot_id) == 16
      end
    end
  end

  describe "skill contracts" do
    for {skill_name, skill_module} <- @skills do
      test "#{skill_name} implements behaviour correctly" do
        skill_module = unquote(skill_module)
        skill_name = unquote(skill_name)

        assert skill_module.id() == skill_name

        snapshot = skill_module.snapshot()
        assert is_map(snapshot)
        assert map_size(snapshot) > 0

        callbacks = skill_module.callbacks()
        assert is_map(callbacks)

        docs = skill_module.callback_docs()
        assert is_binary(docs)
      end
    end
  end
end
