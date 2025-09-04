defmodule LetItCrash.MixProject do
  use Mix.Project

  @version "0.1.0"
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
      description: description()
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
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
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
end
