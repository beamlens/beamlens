defmodule Beamlens.Skill.Base do
  @moduledoc """
  Base callbacks available to all skills.

  These callbacks provide common utilities that every operator can use,
  regardless of their specific domain. They are automatically merged
  with skill-specific callbacks when the operator executes Lua code.

  ## Available Callbacks

  - `get_current_time()` - Returns current UTC timestamp
  - `get_node_info()` - Returns node name and uptime
  """

  @doc """
  Returns the base callbacks map.

  These are merged with skill-specific callbacks in the operator.
  """
  def callbacks do
    %{
      "get_current_time" => &get_current_time/0,
      "get_node_info" => &get_node_info/0
    }
  end

  @doc """
  Returns documentation for base callbacks.

  This is appended to skill-specific callback docs.
  """
  def callback_docs do
    """
    ### get_current_time()
    Returns the current UTC timestamp as ISO 8601 string.
    Use this to determine how old notifications or snapshots are.

    Example response: `{timestamp: "2024-01-06T10:30:00Z", unix_ms: 1704537000000}`

    ### get_node_info()
    Returns basic node information including uptime and OS.

    Example response: `{node: "myapp@host", uptime_seconds: 86400, os_type: "unix", os_name: "darwin"}`
    """
  end

  defp get_current_time do
    now = DateTime.utc_now()

    %{
      timestamp: DateTime.to_iso8601(now),
      unix_ms: DateTime.to_unix(now, :millisecond)
    }
  end

  defp get_node_info do
    {wall_clock_ms, _} = :erlang.statistics(:wall_clock)
    {os_family, os_name} = :os.type()

    %{
      node: Atom.to_string(Node.self()),
      uptime_seconds: div(wall_clock_ms, 1000),
      os_type: Atom.to_string(os_family),
      os_name: Atom.to_string(os_name)
    }
  end
end
