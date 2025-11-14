defmodule OpEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :opex,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package()
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
      {:jason, "~> 1.4"}
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
      links: %{}
    ]
  end
end
