defmodule Beamlens.Integration.ExceptionSkillTest do
  @moduledoc false

  use Beamlens.IntegrationCase, async: false

  import Beamlens.ExceptionTestHelper

  alias Beamlens.Operator
  alias Beamlens.Skill.Exception, as: ExceptionSkill
  alias Beamlens.Skill.Exception.ExceptionStore

  setup do
    start_supervised!({ExceptionStore, name: ExceptionStore})
    :ok
  end

  describe "Exception skill operator" do
    @tag timeout: 60_000
    test "runs and completes with empty exception store", context do
      {:ok, pid} = start_operator(context, skill: ExceptionSkill)
      {:ok, notifications} = Operator.run(pid, %{}, [])

      assert is_list(notifications)
    end

    @tag timeout: 60_000
    test "runs and completes with exceptions present", context do
      inject_exception(%RuntimeError{message: "database connection failed"})
      inject_exception(%RuntimeError{message: "database timeout"})

      {:ok, pid} = start_operator(context, skill: ExceptionSkill)
      {:ok, notifications} = Operator.run(pid, %{}, [])

      assert is_list(notifications)
    end

    @tag timeout: 60_000
    test "runs with context reason", context do
      inject_exception(%RuntimeError{message: "test error"})

      {:ok, pid} = start_operator(context, skill: ExceptionSkill)
      {:ok, notifications} = Operator.run(pid, %{reason: "exception spike detected"}, [])

      assert is_list(notifications)
    end

    @tag timeout: 60_000
    test "runs with multiple exception types", context do
      inject_exception(%RuntimeError{message: "runtime error"})
      inject_exception(%ArgumentError{message: "argument error"})
      inject_exception(%KeyError{key: :missing, term: %{}})

      {:ok, pid} = start_operator(context, skill: ExceptionSkill)
      {:ok, notifications} = Operator.run(pid, %{}, [])

      assert is_list(notifications)
    end
  end
end
