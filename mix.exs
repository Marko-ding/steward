# SPDX-License-Identifier: Apache-2.0

defmodule Steward.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/marko-ding/steward"

  def project do
    [
      app: :steward,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,

      # Docs
      name: "Steward",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),

      # hex.pm
      package: package(),
      description: "Self-reconciling scheduled jobs for Oban",

      # Deps, aliases
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps()
    ]
  end

  defp docs do
    [
      main: "Steward",
      source_ref: "v#{@version}",
      logo: "assets/logo.svg",
      extras: [
        {"CHANGELOG.md", title: "Changelog"},
        {"LICENSE", title: "License"}
      ],
      groups_for_modules: [
        Core: [
          Steward,
          Steward.Controller,
          Steward.Worker,
          Steward.Spec,
          Steward.Resource,
          Steward.Oban
        ],
        Setup: [Steward.Config, Steward.Plugin, Steward.Migrations, Steward.Telemetry],
        Testing: [Steward.Testing],
        Errors: [Steward.ResourceNotFoundError, Steward.ResourceAlreadyPrunedError]
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        GitHub: @source_url,
        Changelog: "#{@source_url}/blob/v#{@version}/CHANGELOG.md"
      }
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp aliases do
    [
      "ecto.reset": [
        "ecto.drop",
        "ecto.create",
        "ecto.migrate"
      ]
    ]
  end

  defp deps do
    [
      {:oban, "~> 2.20"},
      {:ecto_sql, "~> 3.14"},
      {:telemetry, "~> 1.3"},
      {:jason, "~> 1.4", optional: true},
      {:postgrex, ">= 0.0.0", only: :test},
      {:mox, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
