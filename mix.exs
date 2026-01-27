defmodule FlyDeploy.MixProject do
  use Mix.Project

  def project do
    [
      app: :fly_deploy,
      version: "0.2.3",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "FlyDeploy",
      package: package(),
      homepage_url: "https://github.com/chrismccord/fly_deploy",
      description: """
      Hot code upgrades for Elixir applications running on Fly.io
      """
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
      {:req, "~> 0.5"},
      {:finch, "~> 0.20"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:phoenix_live_view, "~> 1.1", optional: true}
    ]
  end

  defp package do
    [
      maintainers: ["Chris McCord"],
      licenses: ["MIT"],
      links: %{
        GitHub: "https://github.com/chrismccord/fly_deploy"
      },
      files: ~w(lib CHANGELOG.md LICENSE.md mix.exs README.md .formatter.exs)
    ]
  end
end
