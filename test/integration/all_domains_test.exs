defmodule Beamlens.Integration.AllDomainsTest do
  @moduledoc """
  Tests that all built-in domains work correctly in integration.

  Verifies each domain can start an operator and take a snapshot.
  """

  use Beamlens.IntegrationCase, async: false

  @domains [
    {:beam, Beamlens.Domain.Beam},
    {:ets, Beamlens.Domain.Ets},
    {:gc, Beamlens.Domain.Gc},
    {:ports, Beamlens.Domain.Ports},
    {:sup, Beamlens.Domain.Sup},
    {:exception, Beamlens.Domain.Exception}
  ]

  setup do
    start_supervised!(Beamlens.Domain.Exception.ExceptionStore)
    :ok
  end

  describe "built-in domains" do
    for {domain_name, domain_module} <- @domains do
      @tag timeout: 30_000
      test "#{domain_name} domain starts and takes snapshot", context do
        domain_module = unquote(domain_module)
        domain_name = unquote(domain_name)
        parent = self()
        handler_id = "#{domain_name}-snapshot-#{System.unique_integer()}"
        on_exit(fn -> :telemetry.detach(handler_id) end)

        :telemetry.attach(
          handler_id,
          [:beamlens, :operator, :take_snapshot],
          fn _event, _measurements, %{operator: o, snapshot_id: id}, _ ->
            if o == domain_name, do: send(parent, {:snapshot, id})
          end,
          nil
        )

        {:ok, _pid} = start_operator(context, domain_module: domain_module)

        assert_receive {:snapshot, snapshot_id}, 25_000
        assert is_binary(snapshot_id)
        assert String.length(snapshot_id) == 16
      end
    end
  end

  describe "domain contracts" do
    for {domain_name, domain_module} <- @domains do
      test "#{domain_name} implements behaviour correctly" do
        domain_module = unquote(domain_module)
        domain_name = unquote(domain_name)

        assert domain_module.domain() == domain_name

        snapshot = domain_module.snapshot()
        assert is_map(snapshot)
        assert map_size(snapshot) > 0

        callbacks = domain_module.callbacks()
        assert is_map(callbacks)

        docs = domain_module.callback_docs()
        assert is_binary(docs)
      end
    end
  end
end
