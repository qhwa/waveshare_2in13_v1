defmodule Waveshare2in13V1.MixProject do
  use Mix.Project

  def project do
    [
      app: :waveshare_2in13_v1,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      {:inky, "~> 1.0"},
      {:circuits_gpio, "~> 2.1", override: true},
      {:circuits_spi, "~> 2.0", override: true}
    ]
  end
end
