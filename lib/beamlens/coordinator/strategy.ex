defmodule Beamlens.Coordinator.Strategy do
  @moduledoc """
  Behaviour for coordinator execution strategies.

  A strategy owns the loop logic and tool dispatch — it decides what to do
  with each tool the LLM selects. The coordinator retains GenServer
  infrastructure (queueing, operator lifecycle, deadlines, caller monitoring).

  ## Return Values

  Strategies return GenServer-compatible tuples from `handle_action/3`:

    * `{:noreply, state, {:continue, :loop}}` — continue iterating
    * `{:noreply, state}` — pause (e.g., Wait tool)
    * `{:finish, state}` — signal completion (coordinator calls `finish/1`)

  ## Implementing a Strategy

      defmodule MyStrategy do
        @behaviour Beamlens.Coordinator.Strategy

        @impl true
        def handle_action(%MyTool{} = action, state, trace_id) do
          {:noreply, state, {:continue, :loop}}
        end
      end

  """

  @callback handle_action(action :: struct(), state :: struct(), trace_id :: String.t()) ::
              {:noreply, struct()}
              | {:noreply, struct(), {:continue, :loop}}
              | {:finish, struct()}
end
