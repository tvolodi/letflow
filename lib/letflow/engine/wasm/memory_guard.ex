defmodule Letflow.Engine.Wasm.MemoryGuard do
  @moduledoc """
  This module bounds-checks every `(offset, length)` pair a host function
  resolves against a guest module's linear memory before any dereference,
  per WASM-08. It prevents the **host** from dereferencing a pointer/length
  pair a guest supplied that does not fit within that instance's real,
  current memory -- including a pair whose magnitude is far beyond anything
  the WASM32 address space or this platform's own `StoreLimits.memory_size`
  cap (REQ-169) could ever make legitimate (live-verified,
  `lib/letflow/design/req168-wasm-memory-isolation.md` §1.4: at such a
  magnitude, `wasmex`'s own internal Rust-side buffer allocation fails
  before its own bounds check would run, either hanging the calling process
  indefinitely or aborting the entire BEAM node with `SIGABRT` -- this
  module's arithmetic check, performed in Elixir's arbitrary-precision
  integers before any value reaches `wasmex`, is what prevents that class
  of input from ever being presented to `wasmex` at all).

  **This validation does NOT bound a fault occurring inside Wasmtime's own
  native code/runtime itself** -- a Wasmtime engine bug, JIT-compiler
  defect, or hardware fault unrelated to pointer/length magnitude remains
  the disclosed, uncovered class `Letflow.Engine.Wasm.PluginHandler`'s own
  moduledoc already states (per
  `lib/letflow/design/req165-wasmex-process-boundary.md` §7.2, "Residual
  risk -- NOT covered by the process boundary": "a Wasmtime- or NIF-layer
  crash inside a call this module makes does not raise, exit, or trap in
  the ordinary BEAM sense... it can crash the entire BEAM node... This is
  an accepted, stated limitation, not a gap this module papers over.").
  This module closes the specific allocation-abort hazard named above,
  which is a distinct, narrower, and now-understood mechanism; it does not
  and cannot close that broader, already-disclosed class.

  ## Every future host function MUST go through this module

  Per `lib/letflow/design/req168-wasm-memory-isolation.md` §4: every
  host-side read or write of guest linear memory (REQ-171/172's future host
  functions included) must call `read/4` or `write/4` below -- never
  `Wasmex.Memory.read_binary/write_binary/get_byte/set_byte` directly. AC1's
  repo-search check (`grep -rn 'Wasmex.Memory\\.' lib/ --include='*.ex'`)
  must show hits only inside this module (plus `Wasmex.Memory.size/2`/
  `grow/2` calls unrelated to pointer/length dereferencing, out of this
  design's scope).

  See `lib/letflow/design/req168-wasm-memory-isolation.md` (gate-approved)
  for the full design this module implements, including §1's live
  verification findings this moduledoc summarizes.
  """

  @typedoc "One concrete way a pointer/length pair failed validation, or a
  raw Wasmex.Memory call itself reported a clean failure (§1.6 -- never
  assumed absent just because a Wasmex.Memory function's own @spec omits
  it)."
  @type bounds_defect ::
          {:invalid_argument, field :: :offset | :length, value :: term()}
          | {:offset_out_of_range, offset :: integer(), memory_size :: non_neg_integer()}
          | {:length_exceeds_memory, offset :: integer(), length :: integer(),
             memory_size :: non_neg_integer()}
          | {:memory_access_failed, raw_reason :: term()}

  @typedoc "The structured rejection reason surfaced to every caller -- AC2's
  'structured error outcome', never an exception/exit."
  @type guard_error :: {:invalid_pointer, bounds_defect()}

  @doc """
  The pure arithmetic core (design §2's five steps, minus the live
  `Wasmex.Memory.size/2` fetch) -- takes the real current memory size as an
  already-known integer rather than fetching it, so this function has no
  Wasmex/NIF dependency at all and is callable with fabricated integers
  alone, at any magnitude, including magnitudes that would be dangerous to
  hand to a live `Wasmex.Memory` call (see moduledoc and
  `lib/letflow/design/req168-wasm-memory-isolation.md` §5.4 -- this function
  is always safe to call directly; `read/4`/`write/4` below are the only
  functions in this module that ever touch a live `wasmex` handle).

  Steps, in order, all using Elixir's exact, non-wrapping integer
  arithmetic:

    1. Type/sign guard -- `offset` and `length` must both be integers and
       both non-negative.
    2. (Caller already fetched `memory_size` -- this function does not
       fetch it itself.)
    3. Offset-range check -- reject if `offset > memory_size`.
    4. End-of-range check -- compute `range_end = offset + length` exactly
       (bignum arithmetic, cannot wrap at any magnitude) and reject if
       `range_end > memory_size`.
    5. Otherwise `:ok`.
  """
  @spec check_bounds(offset :: integer(), length :: integer(), memory_size :: non_neg_integer()) ::
          :ok | {:error, bounds_defect()}
  def check_bounds(offset, length, memory_size)
      when is_integer(memory_size) and memory_size >= 0 do
    with :ok <- check_type_and_sign(:offset, offset),
         :ok <- check_type_and_sign(:length, length),
         :ok <- check_offset_range(offset, memory_size) do
      check_end_of_range(offset, length, memory_size)
    end
  end

  defp check_type_and_sign(_field, value) when is_integer(value) and value >= 0, do: :ok
  defp check_type_and_sign(field, value), do: {:error, {:invalid_argument, field, value}}

  defp check_offset_range(offset, memory_size) when offset > memory_size,
    do: {:error, {:offset_out_of_range, offset, memory_size}}

  defp check_offset_range(_offset, _memory_size), do: :ok

  defp check_end_of_range(offset, length, memory_size) do
    range_end = offset + length

    if range_end > memory_size do
      {:error, {:length_exceeds_memory, offset, length, memory_size}}
    else
      :ok
    end
  end

  @doc """
  THE single validation function every host-side READ of guest memory goes
  through (AC1). Fetches the instance's real, current memory size fresh via
  `Wasmex.Memory.size/2` (never cached -- design §2 step 2 -- `size/2`
  returns a bare integer, not a tagged tuple, per design §1.1), runs it and
  the given `offset`/`length` through `check_bounds/3`, and only if that
  returns `:ok` calls `Wasmex.Memory.read_binary/4`. Pattern-matches BOTH
  the documented success shape (`binary()`) and an `{:error, _}` tuple on
  that call's return (§1.6 -- never assumes the declared `@spec` is
  exhaustive). No exception, `exit`, or native fault can propagate out of
  this function on a malformed input: every path returns an ordinary tagged
  tuple.
  """
  @spec read(Wasmex.StoreOrCaller.t(), Wasmex.Memory.t(), offset :: integer(), length :: integer()) ::
          {:ok, binary()} | {:error, guard_error()}
  def read(store, memory, offset, length) do
    memory_size = Wasmex.Memory.size(store, memory)

    case check_bounds(offset, length, memory_size) do
      :ok ->
        case Wasmex.Memory.read_binary(store, memory, offset, length) do
          {:error, reason} -> {:error, {:invalid_pointer, {:memory_access_failed, reason}}}
          binary when is_binary(binary) -> {:ok, binary}
        end

      {:error, defect} ->
        {:error, {:invalid_pointer, defect}}
    end
  end

  @doc """
  THE single validation function every host-side WRITE into guest memory
  goes through -- the write-side counterpart to `read/4`. `length` is
  implicitly `byte_size(data)` for the bounds check (design §2's algorithm
  applied with that substitution). Mirrors `read/4`'s defect handling and
  defensive `{:error, _}` pattern-match exactly (§1.6).
  """
  @spec write(Wasmex.StoreOrCaller.t(), Wasmex.Memory.t(), offset :: integer(), data :: binary()) ::
          :ok | {:error, guard_error()}
  def write(store, memory, offset, data) when is_binary(data) do
    memory_size = Wasmex.Memory.size(store, memory)
    length = byte_size(data)

    case check_bounds(offset, length, memory_size) do
      :ok ->
        case Wasmex.Memory.write_binary(store, memory, offset, data) do
          {:error, reason} -> {:error, {:invalid_pointer, {:memory_access_failed, reason}}}
          :ok -> :ok
        end

      {:error, defect} ->
        {:error, {:invalid_pointer, defect}}
    end
  end
end
