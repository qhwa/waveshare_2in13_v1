This project provides a driver for the Waveshare 2.13 inch e-paper display (V1) for Elixir projects.

## Installation

The package can be installed by adding `waveshare_2in13_v1` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:inky, "~> 1.0"},
    {:waveshare_2in13_v1, github: "qhwa/waveshare_2in13_v1"}
  ]
end
```

## Usage

```elixir
display = %Inky.Display{
  type: :waveshare_2in13,
  width: 122,
  height: 250,
  rotation: 0,
  accent: :black,
  packed_dimensions: %{
    width: <<16>>,
    height: <<250, 0>>
  },
  luts: nil
}

{:ok, pid} =
  Inky.start_link(:phat, :black, hal_mod: Waveshare2in13V1.Driver.HAL, display: display)


Inky.set_pixels(pid, fn x, y, w, h, _acc ->
  case {div(x * 2, w), div(y * 2, h)} do
    {0, 0} -> :black
    {1, 0} -> :white
    {0, 1} -> :white
    {1, 1} -> :black
  end
end, push: :await)
```
