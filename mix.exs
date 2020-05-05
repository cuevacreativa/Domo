defmodule Domo.MixProject do
  use Mix.Project

  @version "0.0.7"
  @repo_url "https://github.com/IvanRublev/Domo"

  def project do
    [
      app: :domo,
      version: @version,
      elixir: ">= 1.11.0-dev",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Tools
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: cli_env(),

      # Docs
      name: "Domo",
      docs: [
        main: "Domo",
        source_url: @repo_url,
        source_ref: "v#{@version}"
      ],

      # Package
      package: package(),
      description:
        "A library for defining custom composable types " <>
          "for fields of a struct to make these pieces of data " <>
          "to flow through the app consistently. " <>
          "**⚠️ Preview, requires Elixir 1.11.0-dev to run**"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # Development and test dependencies
      {:dialyxir, "~> 1.0", only: :dev, runtime: false},
      {:excoveralls, "~> 0.13.0", only: :test, runtime: false},
      {:mix_test_watch, "~> 1.0", only: :test, runtime: false},

      # Project dependencies
      {:typed_struct, "~> 0.1.4"},

      # Documentation dependencies
      {:ex_doc, "~> 0.19", only: :docs, runtime: false}
    ]
  end

  defp cli_env do
    [
      # Run mix test.watch in `:test` env.
      "test.watch": :test,

      # Always run Coveralls Mix tasks in `:test` env.
      coveralls: :test,
      "coveralls.detail": :test,
      "coveralls.html": :test,

      # Use a custom env for docs.
      docs: :docs
    ]
  end

  defp package do
    [
      files: [".formatter.exs", "lib", "mix.exs", "README.md", "LICENSE"],
      licenses: ["MIT"],
      links: %{"GitHub" => @repo_url}
    ]
  end
end
