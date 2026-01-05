defmodule Beamlens.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamlens,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      description: "A minimal AI agent that monitors BEAM VM health",
      package: package()
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger]]
  end

  defp dialyzer do
    [
      plt_add_apps: [:ex_unit]
    ]
  end

  defp deps do
    [
      {:puck, "~> 0.1.0"},
      {:jason, "~> 1.4"},
      {:zoi, "~> 0.12"},
      # TODO: Switch back to hex.pm once ClientRegistry is released
      # {:baml_elixir, "~> 1.0.0-pre.24"},
      {:baml_elixir,
       github: "emilsoman/baml_elixir",
       ref: "51fdb81640230dd14b4556c1d078bce8d8218368",
       override: true},
      {:rustler, "~> 0.36", optional: true},
      {:telemetry, "~> 1.2"},
      {:crontab, "~> 1.1"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "test --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "dialyzer"
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{}
    ]
  end
end
