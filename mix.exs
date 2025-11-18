defmodule OpEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :opex,
      version: "0.2.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),

      # Hex.pm metadata
      source_url: "https://github.com/kenforthewin/opex",
      homepage_url: "https://github.com/kenforthewin/opex",

      # Documentation
      docs: [
        main: "OpEx",
        extras: ["README.md", "CHANGELOG.md"]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5.0"},
      {:jason, "~> 1.4"},

      # Dev dependencies
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    OpEx - OpenRouter and Model Context Protocol (MCP) client library for Elixir.
    Provides a flexible chat interface with tool calling and MCP server support.
    """
  end

  defp package do
    [
      name: "opex",
      licenses: ["MIT"],
      maintainers: ["Kenneth Bergquist"],
      links: %{
        "GitHub" => "https://github.com/kenforthewin/opex",
        "Changelog" => "https://github.com/kenforthewin/opex/blob/main/CHANGELOG.md"
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end
end
