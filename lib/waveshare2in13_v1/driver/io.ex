defmodule Waveshare2in13V1.Driver.IO do
  @moduledoc """
  IO layer for the plain Waveshare 2.13inch e-Paper HAT.

  BCM pin mapping:
    * busy_pin  -> 24
    * cs0_pin   -> 0   (spidev0.0 / CE0)
    * dc_pin    -> 25
    * reset_pin -> 17
  """

  @behaviour Inky.InkyIO

  defmodule State do
    @enforce_keys [:gpio_mod, :spi_mod, :busy_pid, :dc_pid, :reset_pid, :spi_pid]
    defstruct [:gpio_mod, :spi_mod, :busy_pid, :dc_pid, :reset_pid, :spi_pid]
  end

  @pin_mappings %{
    busy_pin: 24,
    cs0_pin: 0,
    dc_pin: 25,
    reset_pin: 17
  }

  @default_spi_speed_hz 2_000_000
  @spi_command 0
  @spi_data 1
  @spi_chunk_bytes 4096

  @impl Inky.InkyIO
  def init(opts \\ []) do
    gpio = Keyword.get(opts, :gpio_mod, Circuits.GPIO)
    spi = Keyword.get(opts, :spi_mod, Circuits.SPI)
    speed_hz = Keyword.get(opts, :speed_hz, @default_spi_speed_hz)

    spi_address = "spidev0." <> to_string(@pin_mappings.cs0_pin)

    {:ok, dc_pid} = gpio.open(@pin_mappings.dc_pin, :output)
    {:ok, reset_pid} = gpio.open(@pin_mappings.reset_pin, :output)
    {:ok, busy_pid} = gpio.open(@pin_mappings.busy_pin, :input)
    {:ok, spi_pid} = spi.open(spi_address, speed_hz: speed_hz)

    %State{
      gpio_mod: gpio,
      spi_mod: spi,
      busy_pid: busy_pid,
      dc_pid: dc_pid,
      reset_pid: reset_pid,
      spi_pid: spi_pid
    }
  end

  @impl Inky.InkyIO
  def handle_sleep(_state, duration_ms) do
    :timer.sleep(duration_ms)
  end

  @impl Inky.InkyIO
  def handle_read_busy(state) do
    gpio_call(state, :read, [state.busy_pid])
  end

  @impl Inky.InkyIO
  def handle_reset(state, value) do
    :ok = gpio_call(state, :write, [state.reset_pid, value])
  end

  @impl Inky.InkyIO
  def handle_command(state, command, data) do
    write_command(state, command)
    write_data(state, data)
  end

  @impl Inky.InkyIO
  def handle_command(state, command) do
    write_command(state, command)
  end

  defp write_command(state, command) do
    spi_write(state, @spi_command, maybe_wrap_integer(command))
  end

  defp write_data(state, data) do
    spi_write(state, @spi_data, maybe_wrap_integer(data))
  end

  defp spi_write(state, data_or_command, values) when is_list(values) do
    spi_write(state, data_or_command, :erlang.list_to_binary(values))
  end

  defp spi_write(state, data_or_command, value) when is_binary(value) do
    :ok = gpio_call(state, :write, [state.dc_pid, data_or_command])

    case spi_call(state, :transfer, [state.spi_pid, value]) do
      {:ok, response} ->
        {:ok, response}

      {:error, :transfer_failed} ->
        spi_call_chunked(state, value)
    end
  end

  defp spi_call_chunked(state, value) do
    size = byte_size(value)
    parts = div(size - 1, @spi_chunk_bytes)

    for x <- 0..parts do
      offset = x * @spi_chunk_bytes
      length = min(@spi_chunk_bytes, size - offset)

      {:ok, <<_::binary>>} =
        spi_call(state, :transfer, [state.spi_pid, :binary.part(value, offset, length)])
    end

    :ok
  end

  defp maybe_wrap_integer(value) when is_integer(value), do: <<value>>
  defp maybe_wrap_integer(value), do: value

  defp gpio_call(state, op, args), do: apply(state.gpio_mod, op, args)
  defp spi_call(state, op, args), do: apply(state.spi_mod, op, args)
end
