defmodule Waveshare2in13V1.Driver.HAL do
  @moduledoc """
  HAL for the plain Waveshare 2.13inch e-Paper HAT (250x122, black/white).

  This follows the older/plain `epd2in13.py` init/update flow, not the V4/(D) path.
  Expected Raspberry Pi wiring:
    * DC   -> GPIO25
    * RST  -> GPIO17
    * BUSY -> GPIO24
    * CS   -> CE0 / spidev0.0
  """

  import Bitwise

  @behaviour Inky.HAL

  alias Inky.PixelUtil
  require Logger

  @io_mod Waveshare2in13V1.Driver.IO

  @width 122
  @height 250
  @rotation 0
  @busy_timeout_ms 10_000

  # Plain epd2in13.py LUTs
  @lut_full_update [
    0x22,
    0x55,
    0xAA,
    0x55,
    0xAA,
    0x55,
    0xAA,
    0x11,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x1E,
    0x1E,
    0x1E,
    0x1E,
    0x1E,
    0x1E,
    0x1E,
    0x1E,
    0x01,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00
  ]

  @lut_partial_update [
    0x18,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x0F,
    0x01,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00
  ]

  # 1 = white, 0 = black
  @bw_color_map %{
    white: 1,
    black: 0,
    accent: 0,
    red: 0,
    yellow: 0,
    miss: 1
  }

  defmodule State do
    @enforce_keys [:io_mod, :io_state, :width, :height, :rotation]
    defstruct [:io_mod, :io_state, :width, :height, :rotation]
  end

  @impl Inky.HAL
  def init(_args) do
    io_args = [
      gpio_mod: Circuits.GPIO,
      spi_mod: Circuits.SPI,
      speed_hz: 2_000_000
    ]

    Logger.info("Waveshare2in13HAL init (plain epd2in13 path)")

    %State{
      io_mod: @io_mod,
      io_state: @io_mod.init(io_args),
      width: @width,
      height: @height,
      rotation: @rotation
    }
  end

  @impl Inky.HAL
  def handle_update(pixels, _border, push_policy, state = %State{}) do
    lut =
      case push_policy do
        :once -> @lut_partial_update
        _ -> @lut_full_update
      end

    with :ok <- pre_update(state, push_policy),
         {:ok, buffer} <- pixels_to_buffer(pixels, state),
         :ok <- init_panel(state, lut),
         :ok <- set_window(state, 0, 0, state.width - 1, state.height - 1),
         :ok <- write_image(state, buffer),
         :ok <- turn_on_display(state) do
      :ok
    end
  end

  defp pixels_to_buffer(pixels, state) do
    {:ok,
     PixelUtil.pixels_to_bits(
       pixels,
       state.width,
       state.height,
       state.rotation,
       @bw_color_map
     )}
  end

  defp pre_update(state, :once) do
    case read_busy(state) do
      0 -> :ok
      1 -> {:error, :device_busy}
      other -> {:error, {:unexpected_busy_value, other}}
    end
  end

  defp pre_update(_state, _policy), do: :ok

  # Older plain epd2in13 init flow:
  # reset
  # 0x01, 0x0C, 0x2C, 0x3A, 0x3B, 0x3C, 0x11, 0x32(lut)
  defp init_panel(state, lut) do
    with :ok <- hardware_reset(state),
         :ok <-
           write_command(
             state,
             0x01,
             <<@height - 1 &&& 0xFF, (@height - 1) >>> 8 &&& 0xFF, 0x00>>
           ),
         :ok <- write_command(state, 0x0C, <<0xD7, 0xD6, 0x9D>>),
         :ok <- write_command(state, 0x2C, 0xA8),
         :ok <- write_command(state, 0x3A, 0x1A),
         :ok <- write_command(state, 0x3B, 0x08),
         :ok <- write_command(state, 0x3C, 0x03),
         :ok <- write_command(state, 0x11, 0x03),
         :ok <- write_command(state, 0x32, :erlang.list_to_binary(lut)) do
      :ok
    end
  end

  # Plain epd2in13.py reset timing: high 200ms -> low 5ms -> high 200ms
  defp hardware_reset(state) do
    with :ok <- set_reset(state, 1),
         :ok <- sleep(state, 200),
         :ok <- set_reset(state, 0),
         :ok <- sleep(state, 5),
         :ok <- set_reset(state, 1),
         :ok <- sleep(state, 200) do
      :ok
    end
  end

  defp set_window(state, x_start, y_start, x_end, y_end) do
    with :ok <-
           write_command(
             state,
             0x44,
             <<x_start >>> 3 &&& 0xFF, x_end >>> 3 &&& 0xFF>>
           ),
         :ok <-
           write_command(
             state,
             0x45,
             <<
               y_start &&& 0xFF,
               y_start >>> 8 &&& 0xFF,
               y_end &&& 0xFF,
               y_end >>> 8 &&& 0xFF
             >>
           ) do
      :ok
    end
  end

  # Plain epd2in13.py sets cursor per row and waits busy after 0x4F.
  defp set_cursor(state, x, y) do
    with :ok <- write_command(state, 0x4E, x >>> 3 &&& 0xFF),
         :ok <- write_command(state, 0x4F, <<y &&& 0xFF, y >>> 8 &&& 0xFF>>),
         :ok <- await_idle(state, @busy_timeout_ms) do
      :ok
    end
  end

  # Mirror plain driver: for each row, set cursor, issue 0x24, write row bytes.
  defp write_image(state, buffer) do
    do_write_image(state, buffer, 0)
  end

  defp do_write_image(_state, _buffer, y) when y >= @height, do: :ok

  defp do_write_image(state, buffer, y) do
    line_bits = state.width
    padded_line_bits = div(line_bits + 7, 8) * 8
    bit_offset = y * line_bits

    row_bits = slice_bits(buffer, bit_offset, line_bits)
    padding = padded_line_bits - line_bits
    row = <<row_bits::bitstring, 0::size(padding)>>

    with :ok <- set_cursor(state, 0, y),
         :ok <- write_command(state, 0x24, row) do
      do_write_image(state, buffer, y + 1)
    end
  end

  defp slice_bits(bits, offset, size) do
    total = bit_size(bits)
    trailing = total - offset - size

    <<_::size(offset), part::bitstring-size(size), _::size(trailing)>> = bits
    part
  end

  # Plain epd2in13.py:
  # 0x22 -> 0xC4, 0x20, 0xFF, then wait busy
  defp turn_on_display(state) do
    with :ok <- write_command(state, 0x22, 0xC4),
         :ok <- write_command(state, 0x20),
         :ok <- write_command(state, 0xFF),
         :ok <- await_idle(state, @busy_timeout_ms) do
      :ok
    end
  end

  defp await_idle(state, timeout_ms) do
    started = System.monotonic_time(:millisecond)
    do_await_idle(state, started, timeout_ms)
  end

  defp do_await_idle(state, started, timeout_ms) do
    case read_busy(state) do
      0 ->
        :ok

      1 ->
        now = System.monotonic_time(:millisecond)

        if now - started > timeout_ms do
          Logger.warning("Waveshare2in13HAL busy timeout")
          {:error, :busy_timeout}
        else
          :ok = sleep(state, 100)
          do_await_idle(state, started, timeout_ms)
        end

      other ->
        {:error, {:unexpected_busy_value, other}}
    end
  end

  defp sleep(state, ms) do
    io_call(state, :handle_sleep, [ms])
  end

  defp set_reset(state, value) do
    io_call(state, :handle_reset, [value])
  end

  defp read_busy(state) do
    io_call(state, :handle_read_busy, [])
  end

  defp write_command(state, command) do
    case io_call(state, :handle_command, [command]) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_command(state, command, data) do
    case io_call(state, :handle_command, [command, data]) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp io_call(state, op, args) do
    apply(state.io_mod, op, [state.io_state | args])
  end
end
