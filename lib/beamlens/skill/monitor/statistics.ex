defmodule Beamlens.Skill.Monitor.Statistics do
  @moduledoc """
  Pure statistical functions for anomaly detection.

  All functions are pure and side-effect free.
  No PII/PHI exposure - only numerical metric analysis.
  """

  @doc """
  Calculates the arithmetic mean of a list of numbers.

  Returns 0.0 for empty lists.
  """
  def mean([]), do: 0.0

  def mean(numbers) when is_list(numbers) do
    Enum.sum(numbers) / length(numbers)
  end

  @doc """
  Calculates population standard deviation given the mean.

  Uses the population formula (divides by n, not n-1).
  Returns 0.0 for empty lists or single-element lists.
  """
  def std_dev([], _mean), do: 0.0
  def std_dev([_], _mean), do: 0.0

  def std_dev(numbers, mean) when is_list(numbers) do
    variance =
      numbers
      |> Enum.map(fn x -> :math.pow(x - mean, 2) end)
      |> Enum.sum()
      |> Kernel./(length(numbers))

    :math.sqrt(variance)
  end

  @doc """
  Calculates the z-score for a value given mean and standard deviation.

  Z-score measures how many standard deviations a value is from the mean.
  Returns 0.0 when std_dev is 0 (no variance).
  """
  def z_score(_value, _mean, std_dev) when std_dev == 0.0 do
    0.0
  end

  def z_score(value, mean, std_dev) when std_dev > 0 do
    (value - mean) / std_dev
  end

  @doc """
  Calculates the Nth percentile (0-100) of a sorted list.

  Uses linear interpolation between closest ranks.
  Returns 0.0 for empty lists.
  """
  def percentile([], _p), do: 0.0

  def percentile(numbers, p) when is_list(numbers) and p >= 0 and p <= 100 do
    sorted = Enum.sort(numbers)
    count = length(sorted)

    if count == 1 do
      hd(sorted)
    else
      # Linear interpolation method
      rank = p / 100 * (count - 1)
      lower = floor(rank)
      upper = ceil(rank)

      if lower == upper do
        Enum.at(sorted, trunc(rank))
      else
        lower_val = Enum.at(sorted, lower)
        upper_val = Enum.at(sorted, upper)
        fraction = rank - lower
        lower_val + fraction * (upper_val - lower_val)
      end
    end
  end

  @doc """
  Calculates exponential moving average over a list.

  Alpha determines the weighting of recent observations:
  - Higher alpha (closer to 1.0) = more weight on recent data
  - Lower alpha (closer to 0.0) = smoother, slower to react

  Returns the first value for single-element lists.
  Returns 0.0 for empty lists.
  """
  def ema([], _alpha), do: 0.0
  def ema([first], _alpha), do: first

  def ema([first | rest], alpha) when alpha > 0 and alpha <= 1 do
    Enum.reduce(rest, first, fn value, acc ->
      alpha * value + (1 - alpha) * acc
    end)
  end

  @doc """
  Detects if a value is anomalous based on z-score threshold.

  Returns true if the absolute z-score exceeds the threshold.
  """
  def detect_anomaly?(value, baseline, z_threshold) do
    z = z_score(value, baseline.mean, baseline.std_dev)
    abs(z) > z_threshold
  end

  @doc """
  Calculates a full baseline from a list of samples.

  Returns a map with mean, std_dev, and key percentiles.
  """
  def calculate_baseline([]) do
    %{
      mean: 0.0,
      std_dev: 0.0,
      percentile_50: 0.0,
      percentile_95: 0.0,
      percentile_99: 0.0,
      sample_count: 0
    }
  end

  def calculate_baseline(samples) when is_list(samples) do
    mean_val = mean(samples)
    std_dev_val = std_dev(samples, mean_val)

    %{
      mean: mean_val,
      std_dev: std_dev_val,
      percentile_50: percentile(samples, 50),
      percentile_95: percentile(samples, 95),
      percentile_99: percentile(samples, 99),
      sample_count: length(samples)
    }
  end
end
