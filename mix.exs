defmodule LetItCrash.MixProject do
  use Mix.Project

  @version "0.6.0"
  @source_url "https://github.com/volcov/let_it_crash"

  def project do
    [
      app: :let_it_crash,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      source_url: @source_url,
      description: description(),
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    A testing library for crash recovery and OTP supervision behavior.
    Embrace the "let it crash" philosophy in your tests.
    """
  end

  defp package do
    [
      name: "let_it_crash",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["volcov"]
    ]
  end

  defp docs do
    [
      main: "LetItCrash",
      name: "LetItCrash",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE"],
      groups_for_extras: [
        "Getting Started": ["README.md"],
        "Release Notes": ["CHANGELOG.md"],
        "Project Info": ["CONTRIBUTING.md", "LICENSE"]
      ]
    ]
  end
end
