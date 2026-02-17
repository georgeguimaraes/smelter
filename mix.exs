defmodule Smelter.MixProject do
  use Mix.Project

  @version "0.1.2"
  @source_url "https://github.com/georgeguimaraes/smelter"

  def project do
    [
      app: :smelter,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Hex
      name: "Smelter",
      description: "JSON Schema to Elixir code generator",
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ecto, "~> 3.12"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
