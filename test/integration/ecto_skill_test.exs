defmodule Beamlens.Integration.EctoSkillTest do
  @moduledoc false

  use Beamlens.IntegrationCase, async: false

  import Beamlens.EctoTestHelper

  alias Beamlens.Operator
  alias Beamlens.Skill.Ecto.TelemetryStore

  defmodule FakeRepo do
    def config, do: [telemetry_prefix: [:test, :ecto_integration]]
    def __adapter__, do: Ecto.Adapters.Postgres
  end

  defmodule TestEctoSkill do
    use Beamlens.Skill.Ecto, repo: FakeRepo
  end

  setup do
    start_supervised!({Registry, keys: :unique, name: Beamlens.Skill.Ecto.Registry})
    start_supervised!({TelemetryStore, repo: FakeRepo, slow_threshold_ms: 100})
    :ok
  end

  describe "Ecto skill operator" do
    @tag timeout: 60_000
    test "runs and completes with empty telemetry store", context do
      {:ok, pid} = start_operator(context, skill: TestEctoSkill)
      {:ok, notifications} = Operator.run(pid, %{}, [])

      assert is_list(notifications)
    end

    @tag timeout: 60_000
    test "runs and completes with queries present", context do
      inject_query(FakeRepo, total_time_ms: 50)
      inject_query(FakeRepo, total_time_ms: 75)

      {:ok, pid} = start_operator(context, skill: TestEctoSkill)
      {:ok, notifications} = Operator.run(pid, %{}, [])

      assert is_list(notifications)
    end

    @tag timeout: 60_000
    test "runs with context reason", context do
      inject_slow_query(FakeRepo, total_time_ms: 200)

      {:ok, pid} = start_operator(context, skill: TestEctoSkill)
      {:ok, notifications} = Operator.run(pid, %{reason: "slow query spike detected"}, [])

      assert is_list(notifications)
    end

    @tag timeout: 60_000
    test "runs with mixed query types", context do
      inject_query(FakeRepo, total_time_ms: 10)
      inject_slow_query(FakeRepo, total_time_ms: 150)
      inject_error_query(FakeRepo, total_time_ms: 20)

      {:ok, pid} = start_operator(context, skill: TestEctoSkill)
      {:ok, notifications} = Operator.run(pid, %{}, [])

      assert is_list(notifications)
    end
  end
end
