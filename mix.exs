defmodule Beamlens.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/beamlens/beamlens"

  def project do
    [
      app: :beamlens,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      description: "Adaptive runtime intelligence for the BEAM.",
      package: package(),
      docs: docs(),
      name: "beamlens",
      source_url: @source_url
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    extra_apps =
      if Mix.env() in [:dev, :test] do
        [:logger, :os_mon]
      else
        [:logger]
      end

    [extra_applications: extra_apps]
  end

  defp dialyzer do
    [
      plt_add_apps: [:ex_unit]
    ]
  end

  defp deps do
    [
      {:puck, "~> 0.2.8"},
      {:jason, "~> 1.4"},
      {:zoi, "~> 0.12"},
      {:baml_elixir, "~> 1.0.0-pre"},
      {:rustler, "~> 0.36", optional: true},
      {:lua, "~> 0.4"},
      {:telemetry, "~> 1.2"},
      {:ecto_psql_extras, "~> 0.8", optional: true},
      {:tower, "~> 0.8.6", optional: true},
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
      files: ~w(lib priv/baml_src .formatter.exs mix.exs README* LICENSE* CHANGELOG* docs),
      exclude_patterns: [~r/\.baml_optimize/, ~r/\.gitignore$/]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "docs/architecture.md",
        "docs/providers.md",
        "docs/deployment.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
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
          Beamlens.Supervisor
        ],
        Operator: [
          Beamlens.Operator,
          Beamlens.Operator.Supervisor,
          Beamlens.Operator.Notification,
          Beamlens.Operator.Snapshot,
          Beamlens.Operator.Tools,
          Beamlens.Operator.Status,
          Beamlens.Operator.CompletionResult
        ],
        Coordinator: [
          Beamlens.Coordinator,
          Beamlens.Coordinator.Insight,
          Beamlens.Coordinator.Tools,
          Beamlens.Coordinator.Status
        ],
        Skill: [
          Beamlens.Skill,
          Beamlens.Skill.Allocator,
          Beamlens.Skill.Base,
          Beamlens.Skill.Beam,
          Beamlens.Skill.Beam.AtomStore,
          Beamlens.Skill.Ecto,
          Beamlens.Skill.Ecto.Local,
          Beamlens.Skill.Ecto.Global,
          Beamlens.Skill.Ecto.TelemetryStore,
          Beamlens.Skill.Ecto.Adapters.Postgres,
          Beamlens.Skill.Ecto.Adapters.Generic,
          Beamlens.Skill.Ets,
          Beamlens.Skill.Ets.GrowthStore,
          Beamlens.Skill.Exception,
          Beamlens.Skill.Exception.ExceptionStore,
          Beamlens.Skill.Gc,
          Beamlens.Skill.Logger,
          Beamlens.Skill.Logger.LogStore,
          Beamlens.Skill.Monitor,
          Beamlens.Skill.Monitor.Supervisor,
          Beamlens.Skill.Monitor.Detector,
          Beamlens.Skill.Monitor.MetricStore,
          Beamlens.Skill.Monitor.BaselineStore,
          Beamlens.Skill.Monitor.Statistics,
          Beamlens.Skill.Overload,
          Beamlens.Skill.Ports,
          Beamlens.Skill.Sup,
          Beamlens.Skill.System,
          Beamlens.Skill.SystemMonitor,
          Beamlens.Skill.SystemMonitor.EventStore,
          Beamlens.Skill.Tracer
        ],
        Telemetry: [
          Beamlens.Telemetry,
          Beamlens.Telemetry.Hooks
        ],
        LLM: [
          Beamlens.LLM.Utils
        ]
      ]
    ]
  end
end
