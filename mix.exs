defmodule EctoTurbopuffer.MixProject do
  use Mix.Project

  @source_url "https://github.com/commoncurriculum/ecto-turbopuffer"

  def project do
    [
      app: :ecto_turbopuffer,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Ecto adapter and types for turbopuffer",
      source_url: @source_url,
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:ecto, "~> 3.13"},
      # Our fork's `combined` branch carries the fixes proposed upstream to jallum/turbopuffer.
      {:turbopuffer, github: "commoncurriculum/turbopuffer", branch: "combined"},
      # The driver uses Jason before Elixir 1.18.
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
