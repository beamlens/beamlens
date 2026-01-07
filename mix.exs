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
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.35", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "test --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "sobelow --config",
        "dialyzer",
        "docs --warnings-as-errors"
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
      exclude_patterns: [~r/\.baml_optimize/, ~r/\.gitignore$/]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "docs/architecture.md", "CHANGELOG.md", "LICENSE"],
      source_ref: "v#{@version}",
      formatters: ["html"],
      authors: ["Bradley Golden"],
      before_closing_body_tag: fn
        :html ->
          """
          <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
          <script>
            document.addEventListener("DOMContentLoaded", function () {
              mermaid.initialize({ startOnLoad: false, theme: "default" });
              let id = 0;
              for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
                const preEl = codeEl.parentElement;
                const graphDefinition = codeEl.textContent;
                const graphEl = document.createElement("div");
                graphEl.classList.add("mermaid-graph");
                const graphId = "mermaid-graph-" + id++;
                mermaid.render(graphId, graphDefinition).then(({svg}) => {
                  graphEl.innerHTML = svg;
                  preEl.replaceWith(graphEl);
                });
              }
            });
          </script>
          """

        _ ->
          ""
      end,
      groups_for_modules: [
        Core: [
          Beamlens,
          Beamlens.Agent,
          Beamlens.Judge,
          Beamlens.HealthAnalysis
        ],
        Watchers: [
          Beamlens.Watchers.Watcher,
          Beamlens.Watchers.Server,
          Beamlens.Watchers.Status,
          Beamlens.Watchers.Supervisor,
          Beamlens.Watchers.BeamWatcher,
          Beamlens.Watchers.Beam.BeamObservation,
          Beamlens.Watchers.ObservationHistory
        ],
        Baseline: [
          Beamlens.Watchers.Baseline,
          Beamlens.Watchers.Baseline.Analyzer,
          Beamlens.Watchers.Baseline.Context,
          Beamlens.Watchers.Baseline.Decision,
          Beamlens.Watchers.Baseline.Investigator
        ],
        Alerts: [
          Beamlens.Alert,
          Beamlens.AlertQueue,
          Beamlens.AlertHandler
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
