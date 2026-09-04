# ISS-0418 — Operator-configurable cap on concurrently in-flight WASM invocations (OQ-5 candidate (a))

**Issue:** ISS-0418 (MAJOR, eleven-plus recurrences of the `wasm_hang` CI flake, root
cause diagnosed live by ISSUE-FIXER in `handoffs/WF03-ISS0418-20260905/step-01-issue-fixer-diagnosis.json`)
**Related:** ISS-0352 (original CI reproduction, six recurrences absorbed into the
current isolation architecture), REQ-170 (`lib/letflow/design/req170-wasm-wallclock-timeout.md`,
the wall-clock caller bound this design does not duplicate), decision 0014 OQ-5,
REQ-216 (`Letflow.Admission`, reused here — see §3 for why and how), ISS-0437 (per-tenant
retention gap — see §3.4 for why this design does not trigger it)
**Owner (design):** CODE-DESIGNER — **Owner (implementation):** ELIXIR-DEV
**Date:** 2026-09-05

This is a design artefact — `@spec`/`@type` signatures, `@moduledoc`/`@doc` prose, and
supervision-tree wiring only. No function bodies, no `.ex` code blocks with real
implementation logic. See `docs/agents/workflows/WF-02_requirement_implementation.md`
Step 1 / `.claude/agents/code-designer.md`.

---

## 0 — Read this first: what this design does and does not guarantee

**ISSUE-FIXER's diagnosis (step-01 handoff) is treated as verified fact, not
re-derived here** — it read wasmex 0.15.1's real Rust source directly and live-reproduced
pool exhaustion on this host (16 concurrent hangs exhaust `TOKIO_RUNTIME`; a subsequent
trivial call did not return at 20s or 90s; no recovery observed). Three corrections/
findings from that diagnosis are load-bearing for every decision below and are not
re-argued:

1. The leak is **one permanently-blocked Tokio task per `Store`** (not per raw
   invocation as a NIF primitive) — but because `PluginHandler.start_instance/1` creates
   a fresh `Store` per call with no pooling (REQ-174 declined), in this codebase's actual
   call pattern this distinction is moot: **every hung `PluginInterface.invoke/2,3` call
   still leaks exactly one thread-equivalent, unbounded by call count.**
2. **Store pooling is mechanistically ruled out** (§2 of the diagnosis) — a pooled
   Store that ever receives one hang is permanently wedged forever, so pooling would not
   bound the leak, only add false confidence. This design does not propose it.
3. **The leak is confirmed unbounded and unrecoverable within the BEAM** over at least a
   90-second observation window. Nothing this design builds changes that fact.

**Given (3), stated as plainly as ISSUE-FIXER's own diagnosis states it:**

> **A semaphore admitting callers into `PluginHandler.run_guest/3` bounds the number of
> WASM invocations that may be simultaneously IN FLIGHT. It does NOT bound, reclaim, or
> even observe the number of PERMANENTLY LEAKED executor tasks already stuck in
> wasmex's shared `TOKIO_RUNTIME`. Every hang that occurs, whether one at a time under a
> cap of one or many at once under no cap at all, consumes one pool slot forever. The cap
> changes the RATE and the WORST-CASE INSTANTANEOUS BLAST RADIUS of exhaustion — it slows
> time-to-exhaustion and bounds how many hangs can pile up in one moment — but it cannot
> prevent eventual exhaustion if hangs keep occurring over a long enough time window,
> because the pool never grows back. The only two things that ever reclaim a leaked
> thread are killing the OS process it lives in, or restarting the BEAM node — both
> outside this design's scope (§4).**

This is an honestly-scoped **harm-reduction** mechanism, not harm-elimination, and
this document's own `@moduledoc` requirement (§7) mandates that this exact paragraph's
substance ship in the production module's documentation, not just here.

**What the cap DOES concretely guarantee, and why that is still worth building:**

- **Bounds simultaneous blast radius.** Without a cap, N concurrent hung invocations
  (e.g. a burst of adversarial or merely slow guests across several tenants) can consume
  up to N pool slots in one moment, exhausting an `available_parallelism()`-sized pool
  (as few as 4 slots on a small CI runner, per ISS-0418's own recurrence evidence)
  almost immediately. With a cap of `C`, no more than `C` invocations can be
  simultaneously dispatched at all, so no single burst can consume more than `C` slots
  before the admission gate itself starts rejecting/queuing new attempts.
- **Gives an operator a real dial.** Per OQ-5's own wording ("operator-configurable"),
  §5 below names the config key, default, and justification.
- **Directly fixes the isolated `mix test --only wasm_hang` CI flake's proximate
  trigger**, which is exactly this shape: several `:wasm_hang`-tagged tests dispatching
  hangs in overlapping windows under CI runner contention, racing to exhaust a
  4-16-slot pool before the short-lived test subprocess exits. §6 shows this
  deterministically, not probabilistically.
- **Does not require solving reclamation to ship.** §4 states plainly that reclamation
  (subprocess isolation, periodic node-health-triggered restart) is out of scope here,
  named as follow-up, and that without it the cap's guarantee is bounded-rate, not
  bounded-total, over the lifetime of a long-running node.

---

## 1 — Scope boundary: what this module is, and what it explicitly is not

**New module: `Letflow.Engine.Wasm.InvocationLease`**, `lib/letflow/engine/wasm/invocation_lease.ex`.

This is **not** an extension of `Letflow.Admission` (REQ-216) — §3 argues this choice
explicitly, since ISSUE-FIXER's diagnosis left it as an open decision point (item 5 of
its "what the design must decide" list). `Letflow.Admission` remains completely
unmodified by this design.

**This module owns exactly two things:**

1. A single global counting semaphore, sized by an operator-configurable cap, gating
   entry to a WASM guest dispatch.
2. A **lease** primitive whose release does not depend on cooperation from the process
   that acquired it — because that process is exactly the one the existing
   `PluginInterface.invoke/2,3` brutal-kills on timeout (§2 states why this is
   necessary, not optional).

**This module does NOT:**

- Dispatch a guest call itself (`PluginHandler`'s job, §5 states the one call site it
  gains).
- Touch `PluginInterface.invoke/2,3`'s crash-safety algorithm (unmodified, per REQ-170's
  own precedent of reusing it as-is).
- Attempt to reclaim, count, or observe already-leaked native `Tokio` tasks in any way
  (§0/§4 — not possible from the BEAM side, per ISSUE-FIXER's live-reproduced finding).
- Provide per-tenant fair-share tracking. §3.4 states why a single global budget is the
  right shape here, unlike `Letflow.Admission`'s HTTP/poller use case.

---

## 2 — The admission-ref leak problem, and why a plain semaphore is self-defeating

**Restating ISSUE-FIXER's finding precisely, since the fix must close exactly this
gap.** `PluginInterface.invoke/2,3`'s existing algorithm:

```
task = Task.Supervisor.async_nolink(PluginTaskSupervisor, fn -> handler.handle_node(context) end)
task |> Task.yield(timeout_ms) |> handle_yield_result(task, handler, timeout_ms)
```

On the `nil` branch (outer timeout), `handle_yield_result/4` calls
`Task.shutdown(task, :brutal_kill)` — the task process that ran `handle_node/1` (and
therefore, transitively, `PluginHandler.run_guest/3`, `Wasmex.start_link/1`, and
`Wasmex.call_function/4`) is **killed**, not given a chance to run any further code
inside itself. If that same task process were the one that had called
`try_acquire/2` on entry and were relying on itself calling `release/2` on exit, the
brutal-kill path skips `release/2` entirely — for exactly the hangs this cap exists to
bound. **A cap wired this way would leak one admission unit per hang, at exactly the
rate the underlying native leak occurs, degrading the cap itself to zero available
slots after enough hangs — the identical failure shape one layer up**, which
ISSUE-FIXER's diagnosis calls out explicitly as the reason this is a real design
decision, not mechanical wiring.

**This design's answer: the lease is acquired and released from a process that is
never the one killed.**

- The **acquiring process is the caller of `PluginInterface.invoke/2,3`** (i.e.
  whatever engine code calls `invoke/2,3` to dispatch to `PluginHandler`) — not the
  inner `Task.Supervisor.async_nolink/2`-spawned task. This caller process is never
  brutal-killed by `invoke/2,3`'s own algorithm; it is the process that *calls*
  `Task.shutdown/2`, never the process shut down.
- Release is **monitor-driven**, not cooperation-driven, mirroring
  `Letflow.SandboxPool`'s own established `Process.monitor/1` +
  `handle_info({:DOWN, ...})` idiom (`plugin_interface.ex`'s own moduledoc names this
  exact precedent for "observe termination via a monitor, not by trusting the
  terminated process to clean up after itself"). Concretely: the lease-holding process
  (the `invoke/2,3` caller) monitors nothing extra — it does not need to, because it is
  never killed. The lease itself is released **synchronously by that same caller once
  `invoke/2,3` returns**, on every possible return path (`{:complete, _}`, `{:error,
  _}` for a deliberate handler error, `{:error, _}` for a crash, and `{:error, _}` for
  an outer timeout) — `invoke/2,3` always returns one of these `outcome()` values,
  never leaves its caller hanging (per its own AC3 guarantee, already live-verified by
  REQ-170 §1.6), so "release once `invoke/2,3` returns" is unconditionally reachable
  from the lease-holder's own code with a bare `try/after` or an equivalent
  guaranteed-cleanup construct — no monitor needed for THIS half, because the acquiring
  process's own liveness is never at risk from the hang.
- **The one remaining risk this must still cover:** what if the CALLER of
  `invoke/2,3` itself crashes or is killed after acquiring the lease but before
  `invoke/2,3` returns (e.g. its own supervisor restarts it, an unrelated crash in
  sibling code inside the same process)? This is where a monitor genuinely is needed —
  not on the killed inner task (irrelevant, per above), but as a backstop against the
  **lease-holder** itself dying uncleanly. `InvocationLease` therefore monitors the
  acquiring process's pid at acquire time (mirroring `SandboxPool`'s
  `owner_ref = Process.monitor(owner_pid)`, `sandbox_pool.ex:567`) and releases the
  lease automatically on that pid's own `:DOWN`, exactly once, idempotently with an
  explicit `release/1` call (matching `Letflow.Admission.release/2`'s own idempotent-
  no-op-on-unknown-ref contract, so a `:DOWN`-triggered auto-release racing an explicit
  `release/1` call from the same process's own `after` block can never double-release
  or crash).

**Net effect:** a lease is released either (a) explicitly, by the acquiring process,
once `invoke/2,3` returns by any path, or (b) automatically, by `InvocationLease`
itself, if the acquiring process dies before doing (a). There is no path by which a
lease outlives both its holder and its own `invoke/2,3` call — including the exact
brutal-kill scenario ISSUE-FIXER's diagnosis identified, because that kill lands on the
*inner* task, never the lease-holding *caller*.

---

## 3 — Why a new module, not an extension of `Letflow.Admission`

ISSUE-FIXER's diagnosis leaves this as an explicit, un-defaulted decision (item 5).
This design chooses **new, purpose-built module**, for four independent reasons, each
sufficient on its own:

### 3.1 — Admission's core assumption is caller cooperation; this caller cannot cooperate

`Letflow.Admission`'s own moduledoc states its crash semantics plainly: "this module
does not monitor callers... a leaked ref stays counted against its budget until this
process itself restarts or the ref is explicitly released." That is not a bug in
Admission — it is a correct design for REQ-216's actual callers (HTTP request-handling
processes and `Letflow.Scheduler.Poller` sweeps), which always run to completion or
crash in the ordinary BEAM sense (an exit that terminates the *whole* calling process,
not a targeted `Task.shutdown(:brutal_kill)` of an *inner* task while the outer,
ref-holding process survives and keeps running). **Retrofitting monitor-based release
onto `Letflow.Admission` to serve this one new caller shape would change a documented
invariant of a shipped, gate-approved module for every existing and future caller of
it** — REQ-217's HTTP wiring and REQ-218's poller wiring both currently rely on
Admission's simple, non-monitoring semantics; adding monitoring changes crash-recovery
behavior for those call sites too, and REVIEWER would need to re-examine both against a
changed invariant. A new, smaller module with the monitor built in from the start avoids
retroactively complicating an already-shipped design for a use case it was never built
for.

### 3.2 — Different exhaustion semantics: capacity vs. blast-radius

`Letflow.Admission` returns `{:error, :capacity}` synchronously, with no queue — correct
for an HTTP request (fail fast, let the client retry) and a poller sweep (skip this
tick, try next tick). A WASM invocation inside engine dispatch has a different natural
shape: **the caller already has `PluginInterface.invoke/2,3`'s own outer
`timeout_ms`-bounded wait as its existing "don't wait forever" mechanism** (REQ-170,
unmodified). §5.2 below discusses whether admission at cap should fail fast
(`{:error, :capacity}`, mirroring Admission) or block briefly — this design recommends
fail-fast, for consistency with Admission's own precedent and because blocking here
would just relocate the "how long do we wait" question without adding value, given
`invoke/2,3`'s own bound already exists one layer up.

### 3.3 — Global-only, not per-tenant fair-share

`Letflow.Admission`'s defining feature is composing a global budget with **per-tenant**
fair-share budgets (`{:tenant, schema}`), because REQ-216's own text is about HTTP/poller
admission fairness *across tenants competing for the same node*. This cap's actual
threat model, per ISSUE-FIXER's diagnosis and REQ-170 §1.5/§8, is a **single, node-global,
cross-tenant native resource** (`wasmex`'s `TOKIO_RUNTIME`) that has no per-tenant
partition at all — one tenant's hang consumes a slot indistinguishable from any other
tenant's hang, at the native layer. A per-tenant fair-share division here would be
**actively misleading**: it would suggest tenant isolation that the underlying resource
does not have. This design uses only a single **global** counter — no `{:tenant, _}`
variant — stated explicitly so a future reader does not expect per-tenant WASM fairness
from this mechanism.

### 3.4 — Sidesteps ISS-0437 entirely, by construction

ISS-0437 tracks `Letflow.Admission`'s per-tenant-entry unbounded-retention gap
(`state.tenants` never evicts). Because this design has no per-tenant tracking at all
(§3.3), it has no tenant-keyed map, and therefore no analogous retention concern —
confirmed here explicitly per ISSUE-FIXER's request to check the interaction, not left
implicit. State size for `InvocationLease` is bounded by `cap` (the number of
concurrently-outstanding leases, which by construction never exceeds the configured
cap) — not by tenant cardinality.

### 3.5 — What IS reused, deliberately, rather than re-invented

The **shape** of `Letflow.Admission`'s design is reused as precedent, not its code: a
single supervised `GenServer` holding counter + `refs` map in one state term (so
acquire/release stay atomic for free via mailbox serialization); an opaque
`Ref`-style struct callers must not construct or pattern-match into; idempotent
`release/2` on an unknown/already-released ref (`:ok`, never a raise); `try_acquire`-style
naming. This design deliberately keeps naming/shape parallel to `Letflow.Admission` so
a future reader recognizes the pattern immediately, while keeping the module boundary
separate for the reasons above.

---

## 4 — Reclamation: not possible from inside the BEAM; stated plainly, scoped out

Direct answer to ISSUE-FIXER's diagnosis item 4/Option D: **no mechanism inside this
design, or reachable from the BEAM at all today, reclaims an already-leaked
`TOKIO_RUNTIME` executor task.** This is not a limitation of this design specifically —
per ISSUE-FIXER's own live reproduction (90-second no-recovery window) and REQ-170
§1.4's source-level explanation (the per-`Store` executor task's `JoinHandle` is
discarded by `wasmex` itself; nothing in the dependency retains a handle capable of
cancelling it), **no BEAM-reachable API exists to reclaim it, full stop** — this is not
a gap this design chooses to leave for later engineering convenience; it is a closed
question given the dependency's current internals, short of patching or forking
`wasmex`.

**What that implies, stated rather than left implicit (per ISSUE-FIXER's item 4
instruction):**

- **The cap is sufficient to fix the immediate CI flake** (§6) because the CI subprocess
  is short-lived and exits shortly after its own test file's hangs run — the leaked
  threads die with that process, which is ISS-0352's own already-shipped isolation
  architecture (isolating the flake to a fresh, short-lived `mix test --only wasm_hang`
  BEAM node), unaffected and unduplicated by this design.
- **The cap is NOT sufficient, alone, to make a long-running production node immune to
  eventual exhaustion** if genuinely adversarial or merely slow guests keep occurring
  over the node's full uptime — every hang under the cap still permanently consumes one
  pool slot, and nothing ever gives one back. Two options exist to close that residual
  gap, named as **out-of-scope follow-up, not designed here**, matching ISSUE-FIXER's
  own recommendation:
  1. **Subprocess-per-invocation isolation**, generalizing ISS-0352's own CI-isolation
     trick to production traffic — a leaked thread dies when its OS process is killed.
     This is a materially larger architectural change (an IPC boundary on every guest
     call) than "a cap," and is not designed here.
  2. **A periodic health-probe-triggered node restart** — dispatch a cheap, known-
     non-hanging synthetic guest call on an interval; if it fails to return within a
     generous bound, infer pool exhaustion and restart the node under supervision. This
     is the only mechanism ISSUE-FIXER's diagnosis found that actually reclaims already-
     leaked capacity (by paying for a full node restart), and it composes with this
     cap rather than replacing it. Not designed here — named for whoever picks up OQ-5's
     wider scope, per the same "file it, don't build it" discipline REQ-170 §8 already
     used for this very cap.
- **This design's own moduledoc (§7) must state this limitation permanently**, mirroring
  `CallTimeout`'s own precedent of shipping an honest "what this does NOT provide"
  section rather than letting the limitation live only in a design doc nobody re-reads.

---

## 5 — Public contract: `Letflow.Engine.Wasm.InvocationLease`

### 5.1 Process shape and supervision

A single supervised `GenServer`, added as a child of `Letflow.Application`'s
supervision tree, alongside `Letflow.Engine.PluginTaskSupervisor` (both are WASM/plugin-
dispatch infrastructure with no start-order dependency on each other or on `Repo` —
mirrors `Letflow.Admission`'s own "no ordering dependency" precedent: `init/1` reads
only static application config, makes no `Repo` call, no `Registry` lookup, and no call
to any other supervised process).

```
@typedoc "An opaque lease handle returned by try_acquire/0. Callers must not
pattern-match on or construct this struct directly -- only release/1 (or the
automatic monitor-triggered release, S2) consumes it."
@type lease :: %Letflow.Engine.Wasm.InvocationLease.Lease{id: reference()}
```

### 5.2 Client API

```
@doc """
Attempts to acquire one lease against the global WASM-invocation cap
(S5.3's config key). Monitors `self()` at acquire time (S2) so the lease
is automatically released if the calling process dies before an explicit
release/1 call. Never parks the caller -- returns {:error, :capacity}
immediately if the cap is already fully leased, mirroring
Letflow.Admission.try_acquire/2's own non-queuing precedent (S3.2's
rationale: the caller already has PluginInterface.invoke/2,3's own
outer timeout as its "how long to wait" mechanism one layer up; this
gate does not duplicate that decision).
"""
@spec try_acquire() :: {:ok, lease()} | {:error, :capacity}

@doc """
Releases a previously-acquired lease. Idempotent: releasing an unknown,
already-released, or hand-constructed lease is a documented no-op --
always :ok, never a raise (mirrors Letflow.Admission.release/2's own
idempotency contract, S3.5). Safe to call from the same process that
acquired the lease (the expected, primary path, S2) -- calling it from
a different process is not a supported usage and is not guaranteed to
behave sensibly, since the automatic monitor-based release (S2) is keyed
to the ACQUIRING process's pid, not the caller of release/1.
"""
@spec release(lease()) :: :ok

@doc """
Returns the currently configured global cap, live from GenServer state
-- for observability/tests, mirroring Letflow.Admission.global_cap/1's
own precedent.
"""
@spec cap() :: pos_integer()
```

### 5.3 State shape

```
# %{
#   cap:     pos_integer(),                          # fixed at init/1, from config (S5's key)
#   in_use:  non_neg_integer(),
#   leases:  %{optional(reference()) => %{monitor_ref: reference(), pid: pid()}}
# }
```

`leases` is keyed by the same opaque `id` the `Lease` struct carries (mirrors
`Letflow.Admission`'s `refs` map keyed by `Ref.id`) and additionally stores the
`Process.monitor/1` reference and the acquiring pid, so a `:DOWN` for that monitor ref
can look up and release exactly the right lease entry, and so an explicit `release/1`
call can `Process.demonitor(monitor_ref, [:flush])` to avoid a stale `:DOWN` arriving
after an already-completed explicit release (mirrors `SandboxPool`'s own documented
"flush so a normally-returning worker never ALSO delivers a `:DOWN`" precedent,
`sandbox_pool.ex:406`).

### 5.4 GenServer-internal behavior (prose, not code)

- `init/1` reads `cap` from config (§5.5) and starts with `in_use: 0`, `leases: %{}`.
- `try_acquire` (`handle_call`): if `in_use < cap`, monitor the calling pid
  (`elem(_from, 0)`, the standard `GenServer.call/2` caller-pid extraction — the same
  pattern used wherever a `GenServer` needs the caller's pid rather than the process
  it happens to run in, since `self()` inside `handle_call/3` is the server itself, not
  the caller), mint a new `id = make_ref()`, insert into `leases`, increment `in_use`,
  reply `{:ok, %Lease{id: id}}`. If `in_use >= cap`, reply `{:error, :capacity}` with
  zero mutation — same "evaluate before mutating, no rollback" discipline
  `Letflow.Admission`'s own moduledoc documents.
- `release` (`handle_call`): look up `id` in `leases`. Present — demonitor+flush,
  remove the entry, decrement `in_use`, reply `:ok`. Absent — reply `:ok`, no mutation
  (idempotent no-op, §5.2).
- `handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state)`: find the lease
  entry whose `monitor_ref` matches (an O(map-size) scan over `leases`, which is bounded
  by `cap` and therefore small — a linear scan here is the same tradeoff
  `Letflow.SandboxPool`/`Letflow.Supervisor.PollersBreaker` already accept for their own
  bounded-size `:DOWN`-keyed lookups), remove it, decrement `in_use`. A `:DOWN` for a
  monitor ref no longer present (already explicitly released and demonitored) is a
  documented no-op, matching the "stale ref" precedent
  `pollers_breaker.ex:167` already establishes in this codebase for the identical
  race shape.
- On this `GenServer`'s own crash/restart, `init/1` starts fresh
  (`in_use: 0`, `leases: %{}`) — same safe-failure direction as `Letflow.Admission`'s
  own documented crash semantics: can only under-count (transiently widen admission
  after a restart), never over-count (permanently wedge admission shut). Stated
  explicitly as an accepted tradeoff, not a gap: a restart of this GenServer does not,
  and cannot, affect any already-leaked `wasmex` native thread either way (§4) — this
  GenServer's own state has never had any relationship to native pool occupancy beyond
  bounding how many NEW invocations may be dispatched at once.

### 5.5 Configuration surface: key, default, and justification (OQ-5's own "operator-configurable" wording)

**Config key:** `Application.get_env(:letflow, :invocation_lease, [])[:cap]`, read once
at `init/1` — mirrors `Letflow.Admission.start_link/1`'s own
`Application.get_env(:letflow, :admission, [])` / `Keyword.get_lazy/3` idiom exactly
(§3.5), including the same `opts`-override-for-test-isolation convention
(`start_link(opts \\ [])` accepts a `:cap` override, taking precedence over the
application-env value, matching `Letflow.Admission.start_link/1`'s own `:pool_size`/
`:reserved_headroom` overrides).

**Default:** `max(System.schedulers_online() - 2, 1)`.

**Justification, stated explicitly per OQ-5's own "operator-configurable" wording
(the number must be justified, not merely picked):**

- The underlying native resource this cap protects (`wasmex`'s `TOKIO_RUNTIME`) is
  sized to `std::thread::available_parallelism()` — which ISSUE-FIXER's diagnosis
  confirms is a **different, typically smaller** count than
  `System.schedulers_online()` on the same host (REQ-170 §1.5 measured
  `available_parallelism()` = 8 against `System.schedulers_online()` = 16 on one host;
  ISSUE-FIXER's own reproduction host measured both at 16, i.e. the two counts are not
  reliably related in either direction across environments). **This is a real gap this
  design cannot close by formula alone: there is no BEAM-side API that reads
  `wasmex`'s own native pool size directly** (confirmed absent by ISSUE-FIXER's grep of
  the full native/lib source trees, per its diagnosis §1). `System.schedulers_online()`
  is used as the best available BEAM-side proxy for host core count, which is what
  `available_parallelism()` itself derives from — not because the two are guaranteed
  equal, but because it is the closest available signal without adding a new
  dependency or native call solely to read a thread-pool size.
- **The `- 2` headroom, and why a cap must stay strictly BELOW the pool size to bound
  anything at all:** per ISSUE-FIXER's diagnosis and OQ-5's own wording ("a cap at or
  above that number bounds nothing"), a cap set at or above the actual native pool size
  permits exactly the same worst case as no cap — every concurrent slot could still be
  consumed by hangs simultaneously. Subtracting a fixed headroom (2, mirroring
  `Letflow.Admission`'s own `@default_reserved_headroom 2` naming and magnitude, §3.5's
  "reuse the shape, not the code" precedent) guarantees the cap is strictly below the
  proxy count on every host this formula runs on, including small hosts (`max(_, 1)`
  floors at 1 rather than 0 or a negative number on a 1-2 core host, mirroring
  `Letflow.Admission.init/1`'s own identical `max(pool_size - reserved_headroom, 1)`
  floor).
- **This default is deliberately NOT tight enough to fully prevent exhaustion under a
  sufficiently large burst** — per §0/§4, no default can, since the cap bounds
  concurrent callers, not leaked threads, and this default is sized for ordinary
  production headroom, not adversarial-burst safety. An operator running WASM plugins
  under a threat model where many simultaneous tenant-supplied hangs are expected
  should configure a tighter value explicitly; this default optimizes for "do not
  throttle ordinary traffic" over "survive a deliberate burst," consistent with this
  being a harm-reduction mechanism (§0), not a hard security boundary.
- **This is explicitly separate from and smaller in scope than the `:test`-environment
  override (§6.1)**, which deliberately sets `cap: 1` for the isolated `wasm_hang`
  subprocess specifically — that override is not this default, and must not replace it
  in non-test environments.

---

## 6 — Test strategy: making `wasm_hang` deterministic, not merely less likely to flake

**The core question, stated per the handoff's own framing:** does this design make the
`wasm_hang` tests deterministic, or merely reduce flake probability? **Answer: it makes
the CI failure mode structurally impossible to reproduce via pool exhaustion, by
construction, PROVIDED the cap is configured at or below the pool size in the isolated
`mix test --only wasm_hang` subprocess — §6.1 states exactly how that is arranged and
verified, not left to chance.**

### 6.1 Why "operator-configurable, default X" alone does not fix the CI flake, and what closes the gap

Per ISS-0418's own OQ-5 wording and §5's cap default (§5.5 below recommends a default
derived from `System.schedulers_online()`), the DEFAULT cap in a production or
ordinary-dev deployment is deliberately generous (close to the actual pool size) so
normal WASM traffic is not artificially throttled. **A generous default alone does NOT
fix the CI flake**, because the flake's own precondition (ISS-0418's own recurrence
data: 4-16 concurrent `:wasm_hang`-tagged tests contending on a 4-16-slot pool) is
exactly sized to a generous cap — it would still allow all of them to dispatch at once.

**What actually closes the gap: `test/test_helper.exs`'s existing `:wasm_hang`
isolation architecture (ISS-0352) already runs those tests in their OWN short-lived,
serial (per ISS-0428's explicit "deliberately left serial" note quoted in ISS-0418's
own recurrence log) subprocess.** This design's cap composes with that existing
architecture by configuring a **test-specific override** — `config :letflow,
:invocation_lease, cap: 1` (or a small number strictly less than the number of
`:wasm_hang`-tagged tests that could otherwise overlap) for the `:test` environment's
`mix test --only wasm_hang` invocation specifically (via `config/test.exs` or an
env-var override read at `init/1`, per §5.5's mechanism) — **so within that isolated
subprocess, hangs are admitted ONE AT A TIME by construction, never
concurrently, regardless of runner size or contention.** Since `wasm_hang` tests already
run serially within their own ExUnit run (ISS-0428's note), a cap of 1 does not slow
that suite further than it already runs — it converts "serial in ExUnit's own test
ordering, but each test's OWN internal concurrent-dispatch fixtures could still overlap
with a NEIGHBORING test's not-yet-cleaned-up leak" into "structurally serialized at the
admission layer, independent of ExUnit's own scheduling," which is the actual gap the
recurrence evidence (§6.2) shows matters.

This is the deterministic fix: **a test that cannot begin dispatching until the
previous invocation's lease is held cannot race that previous invocation for pool
slots**, full stop, by construction of the semaphore — not "less likely," genuinely
`cap`-many-at-once, structurally.

### 6.2 What test asserts this, concretely (design-level test plan, not test code)

- **New test, `test/letflow/engine/wasm/invocation_lease_test.exs`** (ELIXIR-DEV/
  TEST-DESIGNER scope): starts an isolated `InvocationLease` instance (mirrors
  `Letflow.Admission`'s own `start_link/1` test-isolation `opts` override convention,
  §5.1/`admission.ex`'s own `:name`/`:pool_size` overrides) with `cap: 1`. Asserts:
  (a) a first `try_acquire/0` succeeds; (b) a second, concurrent `try_acquire/0` (from a
  second process) returns `{:error, :capacity}` while the first lease is held; (c) after
  the first lease's holder process is killed (`Process.exit(pid, :kill)`) WITHOUT
  calling `release/1`, a subsequent `try_acquire/0` succeeds within a bounded wait —
  this is the direct proof of §2's monitor-based auto-release, using an ordinary process
  kill as the cheap, non-WASM-dependent stand-in for `PluginInterface.invoke/2,3`'s own
  brutal-kill; (d) an explicit `release/1` followed immediately by that same process
  exiting does not double-decrement `in_use` (proves the demonitor+flush race is closed,
  §5.3).
- **Existing `:wasm_hang`-tagged tests are NOT rewritten to assert on `InvocationLease`
  directly** — they continue asserting their own REQ-170/`CallTimeout` acceptance
  criteria unchanged. This design's own regression coverage for "does the cap actually
  prevent CI exhaustion" is the `invocation_lease_test.exs` unit-level proof above
  (deterministic, fast, no real `wasmex` dependency) PLUS a live end-to-end
  confirmation that `mix test --only wasm_hang` itself completes and passes cleanly
  after this design ships, run by TEST-RUNNER per the normal WF-03 Step 4/5 gate,
  quoting real output — not a new automated test that re-runs ISS-0418's own
  32-concurrent-hang saturation scenario inside `mix test` (REQ-170 §5.7 already
  established why that specific scenario does not belong inside the normal suite: it
  durably occupies the shared native pool for over a minute, corrupting every other
  WASM test's timing assumptions).
- **This is not "hope it stops flaking."** The `cap: 1` test-environment override
  (§6.1) is a structural guarantee, verifiable by the unit test above without touching
  `wasmex` at all, and CI's own subsequent real runs of `mix test --only wasm_hang`
  (which TEST-RUNNER/RELEASE-VALIDATOR already runs on every PR per the existing
  `lib/mix/tasks/letflow.check.test.ex` two-subprocess gate) serve as the ongoing,
  repeated confirmation in the exact environment the flake was originally observed in.

### 6.3 Honesty clause, mirroring REQ-170 §5.2 item 3's precedent

Any new test or moduledoc content this design's implementation produces must not claim
the underlying native leak is prevented or reclaimed — only that concurrent admission
is bounded. Per §0, this is a comment/documentation obligation carried into
implementation, not a design element with its own separate artifact.

---

## 7 — Required moduledoc content for `Letflow.Engine.Wasm.InvocationLease` (mirrors `CallTimeout`'s own precedent, §6 of req170's design)

Required moduledoc content, verbatim in substance (ELIXIR-DEV may adjust prose flow but
must preserve every factual clause):

> Bounds how many WASM guest invocations (`Letflow.Engine.Wasm.PluginHandler.run_guest/3`)
> may be simultaneously dispatched, admitted via a global counting semaphore
> (`try_acquire/0`/`release/1`). Filed against decision 0014's OQ-5 and
> `docs/issues/ISS-0418.yaml` (eleven-plus recurrences of a CI flake caused by the
> mechanism this module bounds). See
> `lib/letflow/design/iss0418-wasm-concurrency-cap.md` for the full design and its live
> diagnosis (`handoffs/WF03-ISS0418-20260905/step-01-issue-fixer-diagnosis.json`).
>
> **WHAT THIS MODULE DOES NOT GUARANTEE, STATED PLAINLY.** `wasmex` (Wasmtime via a Rust
> NIF) permanently leaks one native worker-thread-pool slot (`TOKIO_RUNTIME`, node-global,
> sized to `available_parallelism()`) per genuinely-hanging guest invocation, with no
> BEAM-side mechanism able to reclaim it, live-verified up to a 90-second observation
> window with zero recovery. This module bounds how many invocations may be
> **simultaneously in flight** — it does **not**, and cannot, reclaim an already-leaked
> thread, observe how many threads are currently leaked, or prevent eventual pool
> exhaustion if hangs keep occurring over a long enough time window at any nonzero rate.
> Every hang, admitted one at a time or many at once, permanently consumes one pool slot
> forever; this module changes the RATE and worst-case INSTANTANEOUS blast radius of
> exhaustion, not whether exhaustion can ultimately occur on a sufficiently
> long-lived, sufficiently abused node. The only mechanisms that reclaim a leaked
> thread are killing the OS process it lives in or restarting the BEAM node — both
> outside this module's scope; see the design doc §4 for named, unbuilt follow-up
> options (subprocess-per-invocation isolation; a periodic health-probe-triggered
> restart).
>
> **What this module DOES guarantee:** no more than the configured cap
> (`try_acquire/0`) of WASM invocations are ever simultaneously dispatched through
> `PluginHandler.run_guest/3`, admitted synchronously with no queue
> (`{:error, :capacity}` immediately on exhaustion, mirroring `Letflow.Admission`'s own
> non-queuing precedent) — bounding simultaneous worst-case damage from a burst of
> concurrent hangs to at most `cap` leaked slots at a time, rather than unboundedly many.
>
> **Why this is a new module, not an extension of `Letflow.Admission` (REQ-216):** see
> design doc §3. In short — `Letflow.Admission`'s documented crash semantics assume a
> caller that either cooperates (calls `release/2` itself) or crashes as a whole
> process; `PluginInterface.invoke/2,3`'s own brutal-kill-on-timeout mechanism kills
> only an INNER task while the outer caller survives, so this module acquires/releases
> its lease from that surviving outer caller and additionally monitors it, automatically
> releasing on that caller's own death — a shape `Letflow.Admission` does not have and
> was not built for. This module also has no per-tenant fair-share dimension, since the
> underlying leaked resource (`TOKIO_RUNTIME`) has no per-tenant partition at all.

---

## 8 — Call-site wiring: the one change to `PluginHandler`

**`PluginHandler.handle_node/1` gains a `try_acquire/0` at its very start and a
`release/1` guaranteeing cleanup on every return path** — this is the ONE integration
point this design specifies; no other module changes.

```
@spec handle_node(ExecutionContext.t()) :: Letflow.Engine.PluginInterface.outcome()
# Same signature/contract as today (REQ-165/170, unchanged). New behavior, stated
# in prose since this is a design doc: on entry, calls
# Letflow.Engine.Wasm.InvocationLease.try_acquire/0. {:error, :capacity} maps to
# this callback's own {:error, reason} outcome shape (a new, distinctly-worded
# reason string -- e.g. containing a stable substring such as
# "wasm invocation cap reached" -- so a future caller can distinguish this
# admission-rejection shape from CallTimeout's :wall_clock_timeout shape and from
# ResourceLimits'/HostApi's own shapes, by the same substring-matching convention
# CallTimeout.classify/1 already established; this design does not build that
# classifier itself, since no acceptance criterion here asks for one -- named as
# an open question, S9 OQ-A). {:ok, lease} proceeds to today's existing
# run_guest/3 call exactly as before, and releases the lease via the guaranteed-
# cleanup path described in S2/S8's own text below, regardless of which of
# run_guest/3's outcomes results -- {:ok, _}, {:error, _}, or an uncaught
# raise/exit inside this SAME process (handle_node/1's own process, which is the
# lease-acquiring process per S2 -- note this is DIFFERENT from S2's framing of
# "the invoke/2,3 CALLER" in the abstract; S8.1 below reconciles this precisely,
# since it changes which process actually holds the monitor).
```

### 8.1 — Precisely which process holds the lease: reconciling §2's framing with the real call graph

**§2 spoke of "the caller of `PluginInterface.invoke/2,3`" in the abstract to state the
general principle (acquire outside the process that can be brutal-killed). This
section pins down the concrete call graph, since `PluginHandler.handle_node/1` itself
runs INSIDE the very task `Task.Supervisor.async_nolink/2` spawns and
`Task.shutdown(:brutal_kill)` can kill** — i.e. `handle_node/1`'s own process is
**not** safe from the kill, contradicting a naive reading of §2.

**Resolution: the lease is acquired one level further out — by `invoke/2,3`'s own
caller, before `invoke/2,3` is even called, not inside `handle_node/1`.** This changes
§8's call-site wiring from what a first reading might suggest:

- **`PluginInterface.invoke/2,3` is NOT modified** (§1's own stated scope boundary,
  preserved) — it does not know about leases at all.
- **The actual new call site is one level up: wherever engine/dispatch code calls
  `PluginInterface.invoke(Letflow.Engine.Wasm.PluginHandler, context, opts)`** (per
  decision 0014/`plugin_interface.ex`'s own moduledoc, this call site does not exist
  yet in the shipped codebase today — REQ-057's own moduledoc states runtime dispatch
  wiring is future work, "most plausibly REQ-056, pending"). **This design therefore
  states the contract that future dispatch-integration call site must follow, rather
  than building a call site that does not exist yet** — mirroring REQ-170 §4.4's own
  precedent of stating a future composition point without building it prematurely:
  that caller must (a) call `InvocationLease.try_acquire/0` before calling
  `PluginInterface.invoke/2,3` **at all**, (b) map `{:error, :capacity}` to its own
  appropriate outcome without ever calling `invoke/2,3` in that case (so a
  capacity-rejected invocation never reaches `PluginHandler`, never starts a `Wasmex`
  instance, and therefore adds zero native-pool pressure), and (c) release the lease
  in a `try/after`-equivalent wrapped around the `invoke/2,3` call, guaranteeing
  release regardless of `invoke/2,3`'s returned `outcome()` shape.
- **§8's `handle_node/1` code-shape sketch above is corrected by this section: strike
  it.** `PluginHandler.handle_node/1` itself is NOT where `try_acquire/0`/`release/1`
  are called — that was this design's own first-draft error, caught and corrected in
  this same authoring pass rather than shipped, per this project's own
  "verify against the real source, don't assume" discipline. The correct, single
  integration point is the **future dispatch-integration call site** named above.
- **Why this is still safe against the exact brutal-kill scenario §2 exists for:**
  the process that calls `PluginInterface.invoke/2,3` (and therefore holds the lease)
  is, by construction of `invoke/2,3`'s own algorithm, never the process
  `Task.shutdown(:brutal_kill)` targets — that call always targets the INNER task
  `invoke/2,3` itself spawns via `Task.Supervisor.async_nolink/2`, one level below
  `invoke/2,3`'s own caller. The lease-holder is therefore always exactly one level
  outside the kill radius, regardless of how many internal layers `handle_node/1`'s own
  call graph has. `invoke/2,3`'s own AC3 guarantee (already live-verified, REQ-170
  §1.6) — the caller is reliably unblocked within a bound, by a mechanism outside the
  killed task — is exactly what makes the lease-holder's own `try/after`-equivalent
  release reachable no matter what the guest does.

**This correction is recorded here, in the design itself, rather than silently fixed
without comment** — CODE-DESIGN-VALIDATOR should treat §8's original code-shape
sketch as superseded by this section, not as two conflicting instructions to choose
between.

---

## 9 — Open questions this design leaves for ELIXIR-DEV, stated rather than guessed

- **OQ-A — should `{:error, :capacity}` at this cap be distinguishable, by pattern
  match, from `CallTimeout`'s `:wall_clock_timeout` and `ResourceLimits`'
  fuel/memory-cap shapes?** No acceptance criterion in this issue asks for it. This
  design recommends a distinctly-worded, stable substring (e.g. `"wasm invocation cap
  reached"`) purely so a future classifier COULD be added without re-deriving the
  string, but does not build the classifier itself — genuinely new scope if wanted,
  not blocking.
- **OQ-B — the exact numeric default (§5.5) and its config key's final name.** §5.5
  recommends `System.schedulers_online()`-derived headroom below the actual native pool
  size, but the precise formula/value is ELIXIR-DEV's to finalize with a one-line
  justification, mirroring REQ-170 §9 OQ-1's identical precedent for
  `@default_wasmex_timeout_ms`.
- **OQ-C — where the future dispatch-integration call site (§8.1) actually lives.**
  This design states the CONTRACT that call site must follow; it does not know which
  future requirement builds it (REQ-057's own moduledoc names REQ-056 as the most
  plausible owner, still `pending` as of this writing). Whoever builds that requirement
  must read this design's §8.1 before wiring `PluginInterface.invoke/2,3` into a real
  dispatch path, so the lease is not silently omitted from the first real caller.
- **OQ-D — should the `:test`-environment `cap: 1` override (§6.1) be wired via
  `config/test.exs` (applies to the WHOLE `:test` env, including the main suite) or an
  env-var read only by the `mix test --only wasm_hang` subprocess invocation inside
  `lib/mix/tasks/letflow.check.test.ex`?** This design recommends the latter — scoping
  the tight cap to exactly the subprocess it is meant to protect, so the main suite's
  own (currently zero, per ISS-0352's resolution) WASM-hang-adjacent tests are never
  affected by a cap of 1 they don't need — but the exact mechanism (an application-env
  override passed via `MIX_ENV`-scoped config, vs. a literal `Application.put_env/3`
  call inside the mix task before shelling out) is ELIXIR-DEV's to finalize against
  `letflow.check.test.ex`'s existing subprocess-invocation shape, which this design did
  not modify or fully re-derive here.

None of these open questions block implementation of §5/§8's actual contract.

---

## 10 — Traceability: ISS-0418's own decision points → design elements

| # | Decision point (from ISSUE-FIXER's step-01 handoff, §5) | Design element |
|---|---|---|
| 1 | Adopt Option A (admission gating) as primary mechanism; solve never-released-ref-on-brutal-kill | §2 (lease acquired/released one level outside the kill radius, monitor-backed); §8.1 (exact call-site correction) |
| 2 | Document plainly that the cap bounds concurrent invocations, not leaked threads, and the leak is confirmed unbounded | §0 (headline statement); §7 (required moduledoc content) |
| 3 | Name Option D (subprocess isolation / health-probe restart) as follow-up scope, not built here | §4 |
| 4 | The cap's numeric default and config surface | §5.5; OQ-B |
| 5 | Extend `Letflow.Admission` or build new — justified explicitly | §3 (four independent reasons) |
| — | Is reclamation possible at all (ISS-0418's own item 4 in the task description) | §4 (no — stated plainly, with the two named non-cap follow-ups) |
| — | Test strategy: deterministic vs. probabilistic fix for `wasm_hang` | §6 (deterministic within the isolated subprocess, via a `cap: 1` test-environment override composing with ISS-0352's existing serial isolation) |

---

## 11 — Confirmation: exactly which existing files this design touches, and which it does not

**New files:** `lib/letflow/engine/wasm/invocation_lease.ex` (§5/§7); one new test file,
`test/letflow/engine/wasm/invocation_lease_test.exs` (§6.2) — TEST-DESIGNER's scope, not
built here.

**Modified:** `lib/letflow/application.ex` (add `InvocationLease` as a new supervised
child, §5.1 — no ordering dependency on any existing child); `config/test.exs` or
`lib/mix/tasks/letflow.check.test.ex` (§6.1/OQ-D — the test-environment cap override for
the isolated `:wasm_hang` subprocess specifically).

**NOT modified by this design:** `lib/letflow/admission.ex` (§3 — a new module is used
instead, Admission stays exactly as REQ-216/REQ-217/REQ-218 shipped it);
`lib/letflow/engine/plugin_interface.ex` (§8.1 — the lease is acquired/released by
`invoke/2,3`'s future caller, never inside `invoke/2,3` itself);
`lib/letflow/engine/wasm/plugin_handler.ex` (§8.1's correction — this design's first
draft proposed a `handle_node/1` change and struck it in the same pass once the actual
brutal-kill boundary was traced precisely; `PluginHandler` needs no change at all);
`lib/letflow/engine/wasm/call_timeout.ex`, `resource_limits.ex`, `capability_gate.ex`,
`module_registry.ex`, `memory_guard.ex` (untouched, no interaction with this design's
scope).
