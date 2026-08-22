defmodule Gitility.MixProject do
  use Mix.Project

  # Do not hand-edit. The release script (scripts/release.exs, via `just release`)
  # bumps this line and the CHANGELOG together when cutting a release.
  @version "0.5.0"
  @source_url "https://github.com/jtippett/gitility"

  def project do
    [
      app: :gitility,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      docs: docs(),
      name: "Gitility",
      description:
        "Snapshot-first Git object queries for Elixir — bounded, cancellable, " <>
          "structured reads (tree, file, search, log, diff, blame) over pluggable " <>
          "object databases, no worktree or checkout required",
      source_url: @source_url,
      test_pattern: "*_test.exs"
    ]
  end

  def application do
    [
      mod: {Gitility.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.38", optional: true},
      {:rustler_precompiled, "~> 0.9"},
      {:jason, "~> 1.4"},
      {:postgrex, "~> 0.22.4", optional: true},
      {:req, "~> 0.5.8", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      },
      files: ~w(lib Cargo.toml Cargo.lock native/gitility/Cargo.toml native/gitility/src
           crates/gitility-core/Cargo.toml crates/gitility-core/src crates/gitility-core/vendor
           crates/gitility-core/benches/verify_tax.rs
           checksum-Elixir.Gitility.Native.exs .formatter.exs mix.exs
           README.md CHANGELOG.md LICENSE docs/format/bundle-v1.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "docs/format/bundle-v1.md": [title: "Bundle format v1 (frozen)"],
        "CHANGELOG.md": []
      ],
      source_url: @source_url,
      source_ref: "v#{@version}",
      groups_for_modules: [
        "Mirror replication": [
          Gitility.Mirror,
          Gitility.Mirror.Receipt,
          Gitility.Mirror.Restore,
          Gitility.ObjectStore,
          Gitility.ObjectStore.Conformance,
          Gitility.ObjectStore.Local,
          Gitility.ObjectStore.S3
        ]
      ]
    ]
  end
end
