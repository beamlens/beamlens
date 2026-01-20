defmodule Beamlens.LLMTask do
  @moduledoc false

  def async(fun) do
    case Process.whereis(Beamlens.TaskSupervisor) do
      nil -> Task.async(fun)
      _pid -> Task.Supervisor.async_nolink(Beamlens.TaskSupervisor, fun)
    end
  end
end
