defmodule Letflow.Engine.Wasm.ResourceLimits do
  @moduledoc """
  This module configures WASM-09's fuel-based execution limit and WASM-10's
  linear-memory cap, both per
  `docs/migration/decisions/0014-scripting-plugin-runtime-strategy.md`'s
  direct `wasmex` analogues (`Wasmex.EngineConfig.consume_fuel`,
  `Wasmex.StoreLimits.memory_size`). Both mechanisms were live-verified
  against the real installed dependency, not assumed from documentation
  (`lib/letflow/design/req169-wasm-fuel-and-memory-cap.md` §1).

  **Fuel metering behaves as decision 0014 and WASM-09 describe:** an
  infinite guest loop genuinely terminates within its configured budget,
  surfacing as a clean `{:error, "...all fuel consumed by WebAssembly..."}`
  return -- never a crash, never a hang (§1.1). The budget is NOT reset
  automatically between invocations -- omitting a fresh `arm_fuel/2` call
  before a call genuinely starves it on whatever fuel the previous call left
  behind, live-reproduced (§1.2) -- so this module's contract requires
  `arm_fuel/2` immediately before every single invocation, not once at
  `Store`-creation time.

  **DIVERGENCE FROM WASM-10's LITERAL WORDING, LIVE-VERIFIED, NOT WORKED
  AROUND SILENTLY.** WASM-10 reads "Attempt to grow beyond cap MUST TRAP."
  The real, live-verified behavior is that `memory.grow` beyond
  `StoreLimits.memory_size` does **NOT** trap: it returns WebAssembly's own
  standard `-1` growth-failure sentinel, an ordinary successful call return,
  and the guest's own execution continues completely normally (§1.6). The
  SECURITY property WASM-10 cares about -- a guest's real linear memory
  cannot be made to exceed the configured cap -- IS live-verified true
  (§1.5): `StoreLimits.memory_size` physically, unconditionally bounds real
  memory growth regardless of what the guest requests or its own
  module-declared maximum allows. Decision 0014's own quoted evidence
  ("Growing a linear memory beyond this limit will fail") was itself
  accurate; it is WASM-10's own restatement of that as "MUST TRAP" that this
  live verification found does not hold. This module does not fabricate a
  trap that does not occur; `classify_call_result/1` correctly reports a
  capped-growth attempt as an ordinary success, and
  `memory_grew_within_cap?/3` is the mechanism this module provides
  instead, to let a caller confirm the cap held by comparing real memory
  size directly. Any host function that later dereferences an offset a
  guest computed under a false assumption that its `memory.grow` succeeded
  is still protected -- independently -- by
  `Letflow.Engine.Wasm.MemoryGuard`'s own fresh-every-call bounds check
  (REQ-168), which never trusts a guest's own bookkeeping.

  See `lib/letflow/design/req169-wasm-fuel-and-memory-cap.md` (gate-approved)
  for the full design this module implements, including §1's live
  verification findings this moduledoc summarizes.

  ## Scope boundary

  This module owns constructing a correctly configured `Wasmex.Engine`/
  `Wasmex.StoreOrCaller` pair and arming a per-invocation fuel budget. It
  does not dispatch a guest call (`PluginHandler`'s job), does not build the
  import table (`CapabilityGate`'s job), and does not validate pointer/
  length pairs against guest memory (`MemoryGuard`'s job) -- see design §3.
  Wiring this module's output into `PluginHandler`'s/`CapabilityGate`'s
  actual `Wasmex.start_link/1` call is a future dispatch-integration
  requirement's job.
  """

  alias Wasmex.Engine
  alias Wasmex.EngineConfig
  alias Wasmex.Store
  alias Wasmex.StoreLimits
  alias Wasmex.StoreOrCaller

  @typedoc "Caller-supplied, per-guest-invocation resource configuration --
  AC4's required configurability. `fuel_budget` and `memory_cap_bytes` are
  the two configurable knobs this requirement names; `table_elements_cap`
  is included to keep this config's shape complete alongside StoreLimits'
  own field set (decision 0014's own evidence names it alongside
  memory_size) but is untested by this requirement's own
  acceptance criteria."
  @type config :: %{
          required(:fuel_budget) => pos_integer(),
          required(:memory_cap_bytes) => pos_integer(),
          optional(:table_elements_cap) => pos_integer()
        }

  @typedoc "Why building the Engine/Store pair itself failed -- distinct
  from any later per-invocation outcome (arm_fuel/2, classify_call_result/1
  below). :store_limits_rejected covers a StoreLimits value Wasmtime itself
  refuses (e.g. an initial declared memory already exceeding
  memory_cap_bytes at instantiation time, §1.5's live-verified crash shape)
  -- that crash shape belongs to whatever later calls Wasmex.start_link/1
  with the store this module builds (a future wiring requirement's
  concern), not to build_store/1 itself, which per §1's probes only ever
  fails with a clean {:error, binary()}; the variant is named here so this
  module's own documentation stays consistent with that future caller's
  responsibility."
  @type build_defect ::
          {:engine_build_failed, raw_reason :: term()}
          | {:store_build_failed, raw_reason :: term()}
          | {:store_limits_rejected, {:crashed, raw_reason :: term()}}

  @doc """
  Builds a fresh `Wasmex.Engine` configured with `consume_fuel: true` (§1.1
  -- never left at its documented `false` default) plus a fresh
  `Wasmex.Store` built against that engine and a `Wasmex.StoreLimits`
  (`memory_size` from `config.memory_cap_bytes`, `table_elements` from
  `config.table_elements_cap` when present). Returns the pair together
  because a Store's fuel/limit behavior is bound to the Engine it was built
  from (§1's probes always build both together, never reused across
  configs) -- callers must not build a Store against an unrelated Engine
  and expect this module's other functions' guarantees to hold.

  Per §1.5's crash-shape finding: a StoreLimits value Wasmtime itself
  rejects at instantiation time (e.g. a guest whose declared initial memory
  already exceeds memory_cap_bytes) surfaces as a linked `:exit` from
  whatever process calls the eventual `Wasmex.start_link/1` -- exactly like
  REQ-166/167's already-documented `Wasmex.start_link/1` failure shape.
  This function itself only builds the Engine/Store pair
  (`Wasmex.Engine.new/1`, `Wasmex.Store.new/2`), which §1's probes show
  fail with a clean `{:error, binary()}` on a malformed EngineConfig/
  StoreLimits, not a crash -- the instantiation-time crash risk belongs to
  whatever later calls `Wasmex.start_link/1` with the returned store
  (`PluginHandler`/`CapabilityGate`, a future wiring requirement's concern,
  not this function's).
  """
  @spec build_store(config()) ::
          {:ok, {Engine.t(), StoreOrCaller.t()}} | {:error, build_defect()}
  def build_store(%{fuel_budget: fuel_budget, memory_cap_bytes: memory_cap_bytes} = config)
      when is_integer(fuel_budget) and fuel_budget > 0 and
             is_integer(memory_cap_bytes) and memory_cap_bytes > 0 do
    with {:ok, engine} <- new_engine(),
         {:ok, store} <- new_store(store_limits(config), engine) do
      {:ok, {engine, store}}
    end
  end

  @spec store_limits(config()) :: StoreLimits.t()
  defp store_limits(config) do
    %StoreLimits{
      memory_size: config.memory_cap_bytes,
      table_elements: Map.get(config, :table_elements_cap)
    }
  end

  @spec new_engine() :: {:ok, Engine.t()} | {:error, build_defect()}
  defp new_engine do
    case Engine.new(%EngineConfig{consume_fuel: true}) do
      {:ok, engine} -> {:ok, engine}
      {:error, reason} -> {:error, {:engine_build_failed, reason}}
    end
  end

  @spec new_store(StoreLimits.t(), Engine.t()) ::
          {:ok, StoreOrCaller.t()} | {:error, build_defect()}
  defp new_store(store_limits, engine) do
    case Store.new(store_limits, engine) do
      {:ok, store} -> {:ok, store}
      {:error, reason} -> {:error, {:store_build_failed, reason}}
    end
  end

  @typedoc "Why arming fuel before an invocation failed -- AC5's own
  mechanism. :fuel_not_configured is §1.3's live-verified finding:
  set_fuel/2 itself fails cleanly, with this distinguishable reason, when
  the Engine the Store was built from did not have consume_fuel: true --
  this is what makes a config that silently leaves fuel metering disabled
  fail loudly here, before any guest code runs, rather than allowing an
  unbounded guest through silently."
  @type arm_fuel_defect :: {:fuel_not_configured, raw_reason :: binary()}

  @doc """
  MUST be called with a fresh `fuel_budget` immediately before every single
  guest invocation against `store` -- never once at Store-creation time
  only (§1.2's live-reproduced starvation finding: omitting this call
  before invocation N+1 genuinely starves it on whatever fuel invocation N
  left behind, down to and including 0). Thin wrapper over
  `Wasmex.StoreOrCaller.set_fuel/2`, translating its own `{:error,
  binary()}` return into the structured `arm_fuel_defect()` shape (§1.3)
  rather than passing the raw wasmex string through -- this project's
  structured-error convention (`module_registry.ex`, `capability_gate.ex`,
  `memory_guard.ex`) never surfaces a bare wasmex string as a
  caller-facing reason.
  """
  @spec arm_fuel(StoreOrCaller.t(), fuel_budget :: pos_integer()) ::
          :ok | {:error, arm_fuel_defect()}
  def arm_fuel(store, fuel_budget) when is_integer(fuel_budget) and fuel_budget > 0 do
    case StoreOrCaller.set_fuel(store, fuel_budget) do
      :ok -> :ok
      {:error, reason} -> {:error, {:fuel_not_configured, reason}}
    end
  end

  @fuel_exhausted_substring "all fuel consumed by WebAssembly"

  @typedoc "The structured, caller-facing classification of a completed
  Wasmex.call_function/4 outcome, distinguishing three shapes this design's
  own live verification confirmed are textually distinct and always will
  be, by construction, since they come from three different wasmex/
  Wasmtime code paths (§1.1's fuel-trap wrapper string; an ordinary Wasm
  runtime trap unrelated to fuel/memory such as `unreachable` or an
  out-of-bounds load/store; and this module's own memory-cap observation,
  §1.6, which is NOT a wasmex-reported error shape at all -- see
  classify_call_result/1's own doc note). Deliberately does NOT include a
  timeout/interruption variant: a wasmex-level or outer-task-level timeout
  is a distinct code path this module never touches (REQ-165's
  `handle_yield_result/4` `nil` clause produces its own `{:error,
  \"...did not respond within Nms\"}` shape, textually distinguishable from
  both classifications below by construction), and REQ-170's future
  wall-clock mechanism is explicitly out of this module's classification
  scope (AC6)."
  @type call_classification ::
          :fuel_exhausted
          | {:trap, raw_message :: binary()}
          | :ok

  @doc """
  Classifies an already-completed `Wasmex.call_function/4` return value
  (never calls it itself -- this module does not dispatch guest calls,
  `PluginHandler`/`CapabilityGate`'s job) into one of `call_classification()`'s
  three shapes, by substring-matching the raw wasmex string per this
  project's already-established classify_crash/1-style convention
  (`module_registry.ex`, `capability_gate.ex`): `{:error, reason}` where
  `reason` contains `"all fuel consumed by WebAssembly"` classifies as
  `:fuel_exhausted` (§1.1's exact string); any other `{:error, reason}`
  classifies as `{:trap, reason}` (a real Wasm trap unrelated to fuel --
  e.g. an unreachable instruction, an out-of-bounds memory access
  `MemoryGuard` did not itself intercept because it came from
  guest-internal code rather than a host function's pointer/length pair);
  any other return (including `wasmex`'s own success shape, `{:ok,
  results}`) classifies as `:ok`.

  Does NOT classify a memory-cap breach as a distinct case, because §1.6
  live-verified there is nothing in a `Wasmex.call_function/4` return to
  classify: `memory.grow` beyond `StoreLimits.memory_size` returns a plain
  Wasm-spec-standard `-1` success value, indistinguishable at this
  function's level from any other successful i32 return. A caller needing
  to know whether a memory-cap bound was hit during a call must use
  `memory_grew_within_cap?/3` (below) instead, comparing real memory size
  before/after -- this is the honest consequence of §1.6's finding, not an
  omission.
  """
  @spec classify_call_result(term()) :: call_classification()
  def classify_call_result({:error, reason}) when is_binary(reason) do
    if String.contains?(reason, @fuel_exhausted_substring) do
      :fuel_exhausted
    else
      {:trap, reason}
    end
  end

  def classify_call_result({:error, reason}), do: {:trap, reason}
  def classify_call_result(_other), do: :ok

  @doc """
  The memory-cap observation this design's own honesty commits to
  providing in place of a trap that does not exist: compares the real,
  live-fetched `Wasmex.Memory.size/2` value captured by the caller BEFORE
  an invocation against the value captured AFTER, and reports whether the
  growth (if any) stayed within `memory_cap_bytes`. This is a pure
  arithmetic comparison over two already-known integers -- it does not
  itself call `Wasmex.Memory.size/2` (the caller must fetch both, exactly
  the same "caller supplies the live value, this module never caches or
  re-fetches" discipline `MemoryGuard.check_bounds/3` already established,
  `req168-wasm-memory-isolation.md` §4). Returns `:within_cap` whenever
  `size_after <= memory_cap_bytes` (covers both "did not attempt to grow"
  and "grew, but stayed within the cap"); `:capped` when `size_after`
  exceeds `memory_cap_bytes` -- callers that cannot independently confirm
  an attempt was made should treat `:within_cap` as the only fact this
  function actually proves (memory did not exceed the cap), not as proof
  no attempt occurred.
  """
  @spec memory_grew_within_cap?(
          size_before :: non_neg_integer(),
          size_after :: non_neg_integer(),
          memory_cap_bytes :: pos_integer()
        ) :: :within_cap | :capped
  def memory_grew_within_cap?(size_before, size_after, memory_cap_bytes)
      when is_integer(size_before) and size_before >= 0 and
             is_integer(size_after) and size_after >= 0 and
             is_integer(memory_cap_bytes) and memory_cap_bytes > 0 do
    if size_after <= memory_cap_bytes do
      :within_cap
    else
      :capped
    end
  end
end
