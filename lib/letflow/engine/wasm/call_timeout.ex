defmodule Letflow.Engine.Wasm.CallTimeout do
  @moduledoc """
  This module configures WASM-11's per-invocation wall-clock timeout and
  classifies `Letflow.Engine.PluginInterface.invoke/2,3` outcomes that
  resulted from one. See
  `lib/letflow/design/req170-wasm-wallclock-timeout.md` (gate-approved) for
  the full design, including §1's live verification findings this moduledoc
  summarizes.

  **DIVERGENCE FROM DECISION 0014's CONTAINMENT ARGUMENT AND WASM-11's
  LITERAL WORDING, LIVE-VERIFIED, NOT WORKED AROUND SILENTLY.** Decision
  0014 cited `wasmex`'s documentation that "a timed-out call is interrupted
  and its Store stays usable" as "the interruption primitive WASM-11
  needs." Live verification against the real installed `wasmex` v0.15.1
  dependency (§1.1-§1.4 of the design doc) found this does **not** hold: a
  genuinely hanging guest is never interrupted by `wasmex`'s own timeout
  mechanism at any bound tested up to 30 seconds; the calling process
  instead crashes with an ordinary `GenServer.call` timeout `exit`; the
  `Store` never becomes usable again for subsequent calls; and no BEAM-side
  mechanism (link death, `Process.exit/2`, `Task.shutdown/2`,
  `GenServer.stop/1`) can reach or terminate the already-dispatched native
  execution once it has started, because `wasmex`'s per-`Store` executor
  task discards its own `JoinHandle` and offers no cancellation point. At
  scale, this leaks `wasmex`'s node-global, CPU-count-sized native
  worker-thread pool one hung invocation at a time, and a saturated pool
  was live-observed to stall an entirely unrelated, non-hanging guest call
  (§1.5) -- filed as OQ-5-adjacent evidence, not silently absorbed (see
  decision 0014's Open Questions, OQ-5). **This scheduler-safety question
  (OQ-5) is NOT settled by this requirement** -- settling it needs a real
  load spike plus S6's own operational thresholds, per decision 0014's own
  framing; this module's live probes only observed near-zero BEAM
  scheduler utilization during a hang (`:erlang.statistics(:scheduler_wall_time)`
  values of `0.0` to `0.0007`), which rules out the specific mechanism OQ-5
  named without settling OQ-5's broader concern.

  **What DOES hold, live-verified (§1.6):**
  `Letflow.Engine.PluginInterface.invoke/2,3`'s existing, unmodified
  supervised-task boundary (REQ-057/165) reliably bounds how long the
  *caller* waits, independent of `wasmex`'s own timeout configuration --
  including when that inner value is `:infinity`. This module's
  `config().timeout_ms` sets the inner, `wasmex`-level bound that (per
  §1.1's finding) is what actually, deterministically governs elapsed wait
  time in practice, since `wasmex`'s own client-side `GenServer.call`
  timeout mechanism -- not its documented interrupt -- is what fires.
  `classify/1` distinguishes the resulting caller-facing error from
  `Letflow.Engine.Wasm.ResourceLimits`'s fuel-exhaustion/memory-cap shapes
  (REQ-169).

  **What this module does NOT claim or provide:** termination of the
  underlying guest execution itself. "Exceeding the timeout MUST INTERRUPT
  EXECUTION" (WASM-11's literal body text) is not satisfied by the
  mechanism available in this dependency version, for a guest that does
  not cooperate at a Wasmtime yield point. What is satisfied, live-verified,
  is WASM-11's own acceptance criterion text: "Host-blocking call respects
  timeout" -- the host (caller) does.

  ## Node-wide worker-pool-exhaustion finding (OQ-5-adjacent, filed not absorbed)

  A hung guest permanently consumes one thread of `wasmex`'s own
  node-global, CPU-count-sized native worker-thread pool
  (`TOKIO_RUNTIME`), with no BEAM-side mechanism able to reclaim it.
  Live-reproduced at scale (design §1.5): 32 concurrent hangs (2x this
  session's `System.schedulers_online()`) exhausted that pool, and a
  subsequently dispatched, completely unrelated, non-hanging guest call
  then stalled indefinitely -- a shared-resource exhaustion attack surface
  reachable by nothing more exotic than an ordinary tight loop, exactly
  WASM-11's own named adversarial-by-default threat model. This is filed
  as candidate scope for whoever next picks up OQ-5 or S6's operational
  thresholds (design §8): an operator-configurable cap on concurrently
  in-flight WASM invocations, independent of this requirement's
  per-invocation wall-clock bound. This module does not implement any such
  cap -- that is explicitly out of this requirement's own scope.

  ## Scope boundary

  This module owns (a) the `config()` shape a caller uses to specify the
  wasmex-level per-invocation timeout, and (b) a pure classifier over an
  already-completed `Letflow.Engine.PluginInterface.invoke/2,3` outcome,
  telling a caller whether a given `{:error, reason}` is specifically this
  requirement's wall-clock-timeout shape. It does **not** dispatch a guest
  call itself (`Letflow.Engine.Wasm.PluginHandler`'s job) and does **not**
  touch `Letflow.Engine.PluginInterface`'s crash-safety algorithm at all --
  that algorithm is reused exactly as REQ-165/057 shipped it.
  """

  @typedoc "Caller-supplied, per-guest-invocation wall-clock configuration --
  AC4's required configurability. `timeout_ms` is the value threaded into
  Wasmex.call_function/4's own 4th argument
  (`Letflow.Engine.Wasm.PluginHandler.call_export/3`) -- per the design
  doc's §1.1 live finding, THIS is the value that actually,
  deterministically bounds how long a caller waits (via the ordinary
  GenServer.call client-side timeout mechanism), independent of whether
  wasmex's own internal interrupt ever fires. Never `:infinity` in
  production use -- a caller wanting no wasmex-level bound at all must
  still rely on `Letflow.Engine.PluginInterface`'s own separate,
  already-existing outer `invoke_opts()` `timeout_ms` (REQ-057) as the
  sole backstop in that case (§1.6's live-verified guarantee), which this
  module does not configure or duplicate."
  @type config :: %{required(:timeout_ms) => pos_integer()}

  @typedoc "AC5's own distinguishing contract: what this module's
  classify/1 reports about a completed
  `Letflow.Engine.PluginInterface.invoke/2,3` outcome (NOT a raw
  `Wasmex.call_function/4` return -- that is
  `Letflow.Engine.Wasm.ResourceLimits.classify_call_result/1`'s own,
  separate input shape).

  `:wall_clock_timeout` covers BOTH live-verified timeout shapes
  `Letflow.Engine.PluginInterface`'s own, UNMODIFIED
  `handle_yield_result/4` already produces (the design doc's §1.1/§1.6,
  quoted verbatim in `classify/1`'s own `@doc`): the wasmex-level
  `GenServer.call` timeout crashing the task (observed via the existing
  `{:exit, reason}` clause) and the outer `Task.yield/2` bound firing
  first (observed via the existing `nil` clause). Both are the SAME
  caller-facing guarantee from AC1/AC3's point of view -- the caller's
  wait was bounded and it received a structured error -- so this module
  does not force a caller to distinguish which internal layer actually
  fired; a future caller needing that distinction can pattern-match the
  underlying reason string further, but no acceptance criterion here asks
  for it.

  `:not_timeout` covers every other `outcome()` shape (`:complete`, or an
  `{:error, reason}` that does not match either known timeout signature --
  e.g. a handler's own deliberate `{:error, reason}`, or a genuine crash
  unrelated to a timeout)."
  @type classification :: :wall_clock_timeout | :not_timeout

  @genserver_call_timeout_substring "{:timeout, {GenServer, :call,"
  @outer_task_timeout_substring "did not respond within"

  @doc """
  Classifies an already-completed `Letflow.Engine.PluginInterface.outcome()`
  -- never calls `invoke/2,3` itself, this module does not dispatch guest
  calls.

  Matches by substring against the two literal shapes
  `Letflow.Engine.PluginInterface.handle_yield_result/4` already,
  unmodified, produces (`lib/letflow/engine/plugin_interface.ex`, quoted
  here verbatim since this module's correctness depends on that exact text
  not silently drifting):

    - the `{:exit, reason}` clause: `"plugin handler " <> inspect(handler) <> " crashed: " <> format_exit_reason(reason)`
      -- for the design's §1.1 specific timeout shape, `format_exit_reason(reason)` on
      `{:timeout, {GenServer, :call, [pid, {:call_function, name, params, timeout}, timeout]}}`
      falls to `format_exit_reason/1`'s final `inspect(reason)` clause (the
      2-tuple's second element is itself a 3-tuple, not a list, so the
      `{exception, stacktrace} when is_list(stacktrace)` clause does not
      match), producing a string containing the literal substring
      `"{:timeout, {GenServer, :call,"` -- live-confirmed exact text, §1.1.
    - the `nil` clause: `"plugin handler " <> inspect(handler) <> " did not respond within " <> to_string(timeout_ms) <> "ms"`
      -- literal substring `"did not respond within"`.

  A reason string matching EITHER substring classifies as
  `:wall_clock_timeout`; every other `outcome()` shape (`:complete`, or any
  `{:error, reason}` not matching either substring) classifies as
  `:not_timeout`.

  Distinguishability from
  `Letflow.Engine.Wasm.ResourceLimits.classify_call_result/1`'s own
  `:fuel_exhausted` / `{:trap, raw_message}` shapes (REQ-169) holds by TWO
  independent properties, not merely by accident of current string content
  (design §4.4 details the layering): (1) type shape -- `ResourceLimits`'
  classifier returns an atom or a `{:trap, binary()}` tuple from a RAW
  `Wasmex.call_function/4` return; this classifier returns
  `:wall_clock_timeout | :not_timeout` from a `PluginInterface` OUTCOME (a
  value one call-layer higher, produced only after a full `invoke/2,3`
  round-trip, never a bare wasmex return); (2) even compared textually,
  neither of REQ-169's own live-verified strings ("all fuel consumed by
  WebAssembly", any raw Wasmtime trap message) contains "did not respond
  within" or "{:timeout, {GenServer, :call," and neither of this module's
  two substrings appears in a fuel/trap message, confirmed by direct
  inspection of both live-captured string sets.
  """
  @spec classify(Letflow.Engine.PluginInterface.outcome()) :: classification()
  def classify({:error, reason}) when is_binary(reason) do
    if String.contains?(reason, @genserver_call_timeout_substring) or
         String.contains?(reason, @outer_task_timeout_substring) do
      :wall_clock_timeout
    else
      :not_timeout
    end
  end

  def classify(_outcome), do: :not_timeout
end
