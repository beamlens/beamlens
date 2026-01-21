defmodule Beamlens.Skill.Ets.GrowthStore do
  @moduledoc """
  Stores ETS table size history for growth tracking.

  Periodically samples ETS table sizes and maintains a configurable
  history window. All operations are read-only with minimal overhead.
  """

  use GenServer

  @default_sample_interval_ms 60_000
  @default_history_minutes 60

  defstruct [:samples, :max_samples, :timer_ref]

  @doc """
  Start the growth store with options.
  """
  def start_link(opts \\ []) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])

    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @impl true
  def init(opts) do
    sample_interval_ms = Keyword.get(opts, :sample_interval_ms, @default_sample_interval_ms)
    history_minutes = Keyword.get(opts, :history_minutes, @default_history_minutes)
    max_samples = div(history_minutes * 60_000, sample_interval_ms)

    initial_sample = capture_sample()

    timer_ref = Process.send_after(self(), :sample, sample_interval_ms)

    state = %__MODULE__{
      samples: :queue.in(initial_sample, :queue.new()),
      max_samples: max_samples,
      timer_ref: timer_ref
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:sample, state) do
    sample = capture_sample()
    new_samples = add_sample(state.samples, sample, state.max_samples)
    timer_ref = Process.send_after(self(), :sample, @default_sample_interval_ms)

    {:noreply, %{state | samples: new_samples, timer_ref: timer_ref}}
  end

  @impl true
  def handle_call(:get_samples, _from, state) do
    samples = :queue.to_list(state.samples)
    {:reply, samples, state}
  end

  @impl true
  def handle_call(:get_latest, _from, state) do
    latest = get_latest_sample(state.samples)
    {:reply, latest, state}
  end

  defp add_sample(samples, sample, max_samples) do
    samples = :queue.in(sample, samples)

    if :queue.len(samples) > max_samples do
      {_, dropped_samples} = :queue.out(samples)
      dropped_samples
    else
      samples
    end
  end

  defp get_latest_sample(samples) do
    case :queue.out(samples) do
      {{:value, latest}, _} -> latest
      {:empty, _} -> nil
    end
  end

  defp capture_sample do
    word_size = :erlang.system_info(:wordsize)

    table_data =
      :ets.all()
      |> Enum.map(fn table ->
        case :ets.info(table) do
          :undefined ->
            nil

          info ->
            %{
              name: format_table_name(info[:name] || info[:id]),
              size: info[:size],
              memory: info[:memory] * word_size
            }
        end
      end)
      |> Enum.reject(&is_nil/1)

    %{
      timestamp: System.system_time(:millisecond),
      tables: table_data
    }
  end

  defp format_table_name(name) when is_atom(name), do: Atom.to_string(name)
  defp format_table_name(ref) when is_reference(ref), do: inspect(ref)
  defp format_table_name(other), do: inspect(other)

  @doc """
  Get all historical samples.
  """
  def get_samples(store \\ __MODULE__) do
    GenServer.call(store, :get_samples)
  end

  @doc """
  Get the most recent sample.
  """
  def get_latest(store \\ __MODULE__) do
    GenServer.call(store, :get_latest)
  end
end
