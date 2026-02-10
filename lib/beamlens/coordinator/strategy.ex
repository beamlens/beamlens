defmodule Beamlens.Coordinator.Strategy do
  @moduledoc """
  Behaviour for coordinator execution strategies.

  A strategy owns the loop logic and tool dispatch — it decides what to do
  with each tool the LLM selects. The coordinator retains GenServer
  infrastructure (queueing, operator lifecycle, deadlines, caller monitoring).

  ## Return Values

  Strategies return GenServer-compatible tuples:

    * `{:noreply, state, {:continue, :loop}}` — continue iterating
    * `{:noreply, state}` — pause (e.g., Wait tool)
    * `{:finish, state}` — signal completion (coordinator calls `finish/1`)

  ## Callbacks

  ### `handle_action/3` (required)

  Dispatches a single tool action selected by the LLM. Used by strategies
  that follow the iterative loop pattern (e.g., `AgentLoop`).

  ### `continue_loop/2` (optional)

  Controls what happens each time the coordinator loop fires. When defined,
  replaces the default LLM call with strategy-specific logic. Used by
  strategies that own the full execution flow (e.g., `Pipeline`).

  ## Implementing a Strategy

      defmodule MyStrategy do
        @behaviour Beamlens.Coordinator.Strategy

        @impl true
        def handle_action(%MyTool{} = action, state, trace_id) do
          {:noreply, state, {:continue, :loop}}
        end
      end

  """

  @type loop_result ::
          {:noreply, struct()}
          | {:noreply, struct(), {:continue, :loop}}
          | {:finish, struct()}

  @callback handle_action(action :: struct(), state :: struct(), trace_id :: String.t()) ::
              loop_result()

  @callback continue_loop(state :: struct(), trace_id :: String.t()) :: loop_result()

  @optional_callbacks [continue_loop: 2]
end
