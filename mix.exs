defmodule Beamlens.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/bradleygolden/beamlens"

  def project do
    [
      app: :beamlens,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      description: "Your BEAM Expert, Always On — an AI agent for runtime analysis",
      package: package(),
      docs: docs(),
      name: "BeamLens",
      source_url: @source_url,
      homepage_url: "https://beamlens.dev"
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
      {:baml_elixir, "~> 1.0.0-pre.23"},
      {:rustler, "~> 0.36", optional: true},
      {:telemetry, "~> 1.2"},
      {:crontab, "~> 1.1"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false}
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
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Website" => "https://beamlens.dev"
      },
      exclude_patterns: [~r/\.baml_optimize/]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_ref: "v#{@version}",
      formatters: ["html"],
      authors: ["Bradley Golden"],
      groups_for_modules: [
        Core: [
          Beamlens,
          Beamlens.Agent,
          Beamlens.Judge,
          Beamlens.HealthAnalysis
        ],
        Events: [
          Beamlens.Events,
          Beamlens.Events.JudgeCall,
          Beamlens.Events.LLMCall,
          Beamlens.Events.ToolCall
        ],
        Scheduling: [
          Beamlens.Scheduler,
          Beamlens.Scheduler.Schedule
        ],
        Collectors: [
          Beamlens.Collector,
          Beamlens.Collectors.Beam,
          Beamlens.Tool,
          Beamlens.Tools
        ],
        Observability: [
          Beamlens.Telemetry,
          Beamlens.Telemetry.Hooks
        ],
        Infrastructure: [
          Beamlens.CircuitBreaker,
          Beamlens.BAML
        ]
      ]
    ]
  end
end
