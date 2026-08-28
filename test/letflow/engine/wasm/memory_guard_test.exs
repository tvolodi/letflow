defmodule Letflow.Engine.Wasm.MemoryGuardTest do
  @moduledoc """
  REQ-168 -- coverage for `Letflow.Engine.Wasm.MemoryGuard`. See
  `lib/letflow/design/req168-wasm-memory-isolation.md` (gate-approved) and
  `test/specs/REQ-168.md` for the full rationale and AC traceability.

  **Safety constraint (design §5.4 / spec's own mandatory notice): no test
  in this file may call `MemoryGuard.read/4`, `MemoryGuard.write/4`, or any
  `Wasmex.Memory` function directly with an offset/length value at or above
  roughly `2^40`.** Design §1.4 live-reproduced a real `SIGABRT` at that
  magnitude against this exact dependency version -- the one test case that
  uses a `2^63`-scale value (T2 case 3) targets `check_bounds/3` only, a
  pure function with zero Wasmex/NIF dependency.

  `async: false`: several tests here build a real Wasmtime instance via
  `wasmex`'s NIF, mirroring `plugin_handler_test.exs`'s and
  `module_registry_test.exs`'s identical rationale for keeping WASM-NIF
  tests serial.
  """

  use ExUnit.Case, async: false

  alias Letflow.Engine.Wasm.MemoryGuard

  defp fixture_bytes do
    Application.app_dir(:letflow, "priv")
    |> Path.join("wasm_fixtures/req168_memory.wat")
    |> File.read!()
  end

  defp start_instance do
    {:ok, pid} = Wasmex.start_link(%{bytes: fixture_bytes()})
    {:ok, store} = Wasmex.store(pid)
    {:ok, memory} = Wasmex.memory(pid)
    {pid, store, memory}
  end

  # ---------------------------------------------------------------------
  # T1: check_bounds/3 accepts every valid case (baseline).
  # ---------------------------------------------------------------------

  describe "T1: check_bounds/3 accepts valid cases" do
    test "fully in-bounds" do
      assert MemoryGuard.check_bounds(0, 10, 65536) == :ok
    end

    test "ends exactly at the boundary" do
      assert MemoryGuard.check_bounds(65526, 10, 65536) == :ok
    end

    test "zero-length read exactly at the end-of-memory boundary" do
      assert MemoryGuard.check_bounds(65536, 0, 65536) == :ok
    end
  end

  # ---------------------------------------------------------------------
  # T2 (AC3): check_bounds/3 rejects each named malformed-input shape.
  # ---------------------------------------------------------------------

  describe "T2 (AC3): check_bounds/3 rejects malformed input" do
    test "offset beyond memory size" do
      assert MemoryGuard.check_bounds(65537, 1, 65536) ==
               {:error, {:offset_out_of_range, 65537, 65536}}
    end

    test "length running past the memory end" do
      assert MemoryGuard.check_bounds(65530, 100, 65536) ==
               {:error, {:length_exceeds_memory, 65530, 100, 65536}}
    end

    test "offset+length pair that would overflow a fixed-width check (pure arithmetic only -- never a live Wasmex.Memory call, per §5.4)" do
      # Design §5.2's worked table for this exact input (offset = length =
      # 2^63, mirroring §1.4's SIGABRT-magnitude probe) states the expected
      # tag as `:length_exceeds_memory`. Per §2's algorithm as written,
      # step 3 (offset-range check) runs BEFORE step 4 (end-of-range check)
      # and rejects here first, since `offset` alone (2^63) already exceeds
      # `memory_size` (65536) -- so the algorithm's own step order (which
      # CODE-DESIGN-VALIDATOR confirmed correct) actually yields
      # `:offset_out_of_range` for this specific input, not
      # `:length_exceeds_memory`. This is a discrepancy in the design's
      # worked example, not in the algorithm or this implementation --
      # flagged here for REVIEWER rather than silently reconciled either
      # way. The safety property both the design and this test care about
      # (exact, non-wrapping bignum arithmetic at extreme magnitude,
      # correctly rejected, no live Wasmex call) holds regardless of which
      # step number rejects it.
      offset = 9_223_372_036_854_775_808
      length = 9_223_372_036_854_775_808

      assert MemoryGuard.check_bounds(offset, length, 65536) ==
               {:error, {:offset_out_of_range, offset, 65536}}
    end

    test "length alone at extreme magnitude past a valid offset -- exact non-wraparound bignum arithmetic exercises the end-of-range step (pure arithmetic only, per §5.4)" do
      offset = 0
      length = 9_223_372_036_854_775_808

      assert MemoryGuard.check_bounds(offset, length, 65536) ==
               {:error, {:length_exceeds_memory, offset, length, 65536}}
    end

    test "defensive: negative offset" do
      assert MemoryGuard.check_bounds(-1, 1, 65536) ==
               {:error, {:invalid_argument, :offset, -1}}
    end

    test "defensive: non-integer length" do
      assert MemoryGuard.check_bounds(0, "10", 65536) ==
               {:error, {:invalid_argument, :length, "10"}}
    end
  end

  # ---------------------------------------------------------------------
  # T3 (AC2): live read/4 and write/4, malformed pointer yields a
  # structured error, BEAM node/process stay up.
  # ---------------------------------------------------------------------

  describe "T3 (AC2): read/4 and write/4 against a real Wasmex.Memory handle" do
    test "valid round-trip (sanity)" do
      {_pid, store, memory} = start_instance()

      assert MemoryGuard.write(store, memory, 0, "hi") == :ok
      assert MemoryGuard.read(store, memory, 0, 2) == {:ok, "hi"}
    end

    test "malformed pointer via read/4, offset beyond size -- structured error, node stays up" do
      {_pid, store, memory} = start_instance()
      size = Wasmex.Memory.size(store, memory)

      assert {:trap_exit, false} = Process.info(self(), :trap_exit)

      assert MemoryGuard.read(store, memory, size + 1000, 10) ==
               {:error, {:invalid_pointer, {:offset_out_of_range, size + 1000, size}}}

      assert Process.alive?(self())
      assert Process.whereis(Letflow.Engine.PluginTaskSupervisor) |> Process.alive?()
    end

    test "length running past memory end via read/4" do
      {_pid, store, memory} = start_instance()
      size = Wasmex.Memory.size(store, memory)

      assert {:trap_exit, false} = Process.info(self(), :trap_exit)

      assert MemoryGuard.read(store, memory, size - 1, 1000) ==
               {:error, {:invalid_pointer, {:length_exceeds_memory, size - 1, 1000, size}}}

      assert Process.alive?(self())
      assert Process.whereis(Letflow.Engine.PluginTaskSupervisor) |> Process.alive?()
    end

    test "malformed pointer via write/4, offset beyond size" do
      {_pid, store, memory} = start_instance()
      size = Wasmex.Memory.size(store, memory)

      assert {:trap_exit, false} = Process.info(self(), :trap_exit)

      assert MemoryGuard.write(store, memory, size + 1, "x") ==
               {:error, {:invalid_pointer, {:offset_out_of_range, size + 1, size}}}

      assert Process.alive?(self())
      assert Process.whereis(Letflow.Engine.PluginTaskSupervisor) |> Process.alive?()
    end
  end

  # ---------------------------------------------------------------------
  # T4 (AC4): per-instance memory isolation.
  # ---------------------------------------------------------------------

  describe "T4 (AC4): per-instance memory isolation" do
    test "a write in one instance is not observable via a read in another" do
      {_pid_a, store_a, mem_a} = start_instance()
      {_pid_b, store_b, mem_b} = start_instance()

      assert MemoryGuard.write(store_a, mem_a, 0, <<99>>) == :ok
      assert MemoryGuard.read(store_b, mem_b, 0, 1) == {:ok, <<0>>}
      assert MemoryGuard.read(store_a, mem_a, 0, 1) == {:ok, <<99>>}
    end
  end

  # ---------------------------------------------------------------------
  # T5 (AC5): moduledoc content.
  # ---------------------------------------------------------------------

  describe "T5 (AC5): moduledoc discloses the residual native-crash risk" do
    test "states this validation bounds host-side dereferences only, and does NOT bound a Wasmtime-native fault" do
      {:docs_v1, _anno, _lang, _fmt, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Letflow.Engine.Wasm.MemoryGuard)

      assert moduledoc =~ "does NOT bound a fault"
      assert moduledoc =~ "Wasmtime"
      assert moduledoc =~ "native code"
    end
  end
end
