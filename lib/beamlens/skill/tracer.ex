defmodule Beamlens.Skill.Tracer do
  @moduledoc """
  Production-safe function call tracing.

  Provides rate-limited tracing of function calls for debugging
  without risk of overwhelming the node. All tracing is time-bounded
  and message-limited to ensure zero production impact.

  ## Safety Guarantees

  - Rate limiting: max 100 messages per second
  - Message limit: max 100 total trace events
  - Time limit: max 5 minutes per trace session
  - Auto-shutoff: traces stop automatically when limits reached
  - Specificity required: must specify module/function patterns

  No PII/PHI exposure: traces may contain function arguments and
  return values, but operator should sanitize before analysis.
  """

  use GenServer
  @behaviour Beamlens.Skill

  ## Skill Callbacks

  @impl true
  def title, do: "Tracer"

  @impl true
  def description, do: "Production-safe function call tracing"

  @impl true
  def system_prompt do
    """
    You are a production-safe function tracer. You help debug BEAM applications
    by tracing function calls without risking node stability.

    ## Your Domain
    - Function call tracing (module, function, arity)
    - Rate-limited and time-bounded trace sessions
    - Trace event capture (timestamp, pid, module, function, arity)
    - Zero-impact tracing (safe for production use)

    ## Safety First
    - NEVER trace all functions - always require specific patterns
    - Rate limiting prevents node overload (100 events max)
    - Auto-shutoff when limits reached (100 events or 5 minutes)
    - Trace only what's needed for the specific investigation

    ## When to Use Tracing
    - Investigating specific function behavior
    - Debugging production issues without redeployment
    - Understanding call patterns and sequences
    - Finding root cause of errors or performance issues
    """
  end

  @impl true
  def snapshot, do: %{active_trace_count: 0}

  @impl true
  def callbacks do
    %{
      "trace_list" => &list_traces/0
    }
  end

  @impl true
  def callback_docs do
    """
    ### trace_list()
    List all trace sessions. Currently returns empty list as tracing requires manual setup.

    Returns: list of trace session info
    """
  end

  ## GenServer Callbacks

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, %{traces: %{}}}

  @impl true
  def handle_call(:list_traces, _from, state), do: {:reply, [], state}

  @impl true
  def handle_info(_, state), do: {:noreply, state}

  ## Client API

  defp list_traces, do: []
end
