defmodule GeoGenius.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/agoodway/geo_genius"

  def project do
    [
      app: :geo_genius,
      version: @version,
      description:
        "A versioned catalog of named geographic areas for Elixir and PostgreSQL/PostGIS applications",
      elixir: "~> 1.17",
      source_url: @source_url,
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      dialyzer: dialyzer(),
      docs: docs(),
      package: package(),
      deps: deps()
    ]
  end

  def cli, do: [preferred_envs: [check: :test, quality: :test]]

  def application do
    [
      extra_applications: [:logger],
      mod: {GeoGenius.Application, []}
    ]
  end

  defp deps do
    [
      {:ecto, "~> 3.13"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.20.0 and < 0.23.0"},
      {:geo_postgis, "~> 3.7"},
      {:ecto_evolver, "~> 0.1.0"},
      {:telemetry, "~> 1.3"},
      {:jason, "~> 1.4"},
      {:nimble_csv, "~> 1.2"},
      {:req, "~> 0.7", optional: true},
      {:pgflow, ">= 0.3.4 and < 0.4.0", optional: true},
      {:phoenix, "~> 1.7", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:livefilter, "~> 0.2.0", optional: true},
      {:plug, "~> 1.0", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22 or ~> 0.23", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.2", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.3", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38 or ~> 0.39 or ~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      test: ["ecto.create --quiet", "test"],
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "doctor",
        "test"
      ],
      quality: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "sobelow --config",
        "ex_dna",
        "doctor",
        "credo --strict"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      ignore_warnings: ".dialyzer_ignore.exs",
      flags: [:error_handling, :unknown]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "main",
      extras: [
        "README.md",
        "guides/installation.md",
        "guides/reading.md",
        "guides/ingestion.md",
        "guides/projections.md",
        "guides/sql_api.md",
        "docs/design/geo-genius-design.md",
        "CHANGELOG.md"
      ],
      groups_for_modules: groups_for_modules()
    ]
  end

  # Without these every module renders in one flat sidebar, which buries the
  # handful a host actually calls under the adapters, providers, and internals
  # behind them. `GeoGenius` itself stays ungrouped, at the top.
  defp groups_for_modules do
    [
      Reading: [
        GeoGenius.AreaMatch,
        GeoGenius.SeededMatch,
        GeoGenius.Published,
        GeoGenius.Published.Area,
        GeoGenius.Published.AreaCode,
        GeoGenius.Published.AreaName,
        GeoGenius.Published.AreaRelation,
        GeoGenius.Query,
        GeoGenius.Preflight,
        GeoGenius.ReleaseArtifacts,
        GeoGenius.ReleaseArtifacts.Artifact
      ],
      Ingestion: [
        GeoGenius.ImportRun,
        GeoGenius.Manifest,
        GeoGenius.Manifest.Artifact,
        GeoGenius.Manifest.Source,
        GeoGenius.Pipeline,
        GeoGenius.Registration
      ],
      Catalog: [
        GeoGenius.Catalog,
        GeoGenius.Context,
        GeoGenius.Staging
      ],
      "Extension points": [
        GeoGenius.Cache,
        GeoGenius.Command,
        GeoGenius.Downloader,
        GeoGenius.Notifier,
        GeoGenius.Provider,
        GeoGenius.Provider.Area,
        GeoGenius.Provider.Area.Code,
        GeoGenius.Provider.Area.Name,
        GeoGenius.Runner,
        GeoGenius.Store
      ],
      "Shipped adapters": [
        GeoGenius.Caches.FileSystem,
        GeoGenius.Commands.System,
        GeoGenius.Downloaders.Req,
        GeoGenius.Notifiers.Noop,
        GeoGenius.Providers.CSV,
        GeoGenius.Providers.GeoJSON,
        GeoGenius.Providers.GeoJSONSequence,
        GeoGenius.Providers.Shapefile,
        GeoGenius.Runners.Inline,
        GeoGenius.Runners.PgFlow,
        GeoGenius.Runners.Task,
        GeoGenius.Stores.Postgres
      ],
      Installation: [
        GeoGenius.Migration,
        GeoGenius.Migrations.V01
      ],
      Exceptions: [
        GeoGenius.ArtifactError,
        GeoGenius.CatalogError,
        GeoGenius.CandidateError,
        GeoGenius.EnqueueError,
        GeoGenius.ImportError,
        GeoGenius.ManifestError,
        GeoGenius.PreflightError,
        GeoGenius.QueryError,
        GeoGenius.StagingError
      ],
      "Mix tasks": [~r/^Mix\.Tasks\.GeoGenius\./],
      Internal: [
        GeoGenius.Application,
        GeoGenius.Bootstrap,
        GeoGenius.Config,
        GeoGenius.ExecutionGuardian,
        GeoGenius.Files,
        GeoGenius.MixHelpers,
        GeoGenius.Pipeline.Artifacts,
        GeoGenius.Pipeline.CommandAllowlist,
        GeoGenius.Pipeline.Normalize,
        GeoGenius.Pipeline.State,
        GeoGenius.Published.Prefix,
        GeoGenius.Providers.Batch,
        GeoGenius.Providers.Fields,
        GeoGenius.Providers.ManifestOptions,
        GeoGenius.ResultMapper,
        GeoGenius.Telemetry
      ]
    ]
  end

  defp package do
    [
      files:
        ~w(lib priv/geo_genius guides docs/design test/pgtap test/pgtap_support docker-compose.yml database
           .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
