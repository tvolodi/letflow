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
- **DOES fix the isolated `mix test --only wasm_hang` CI flake's own documented
  CONCURRENT-contention failure mode — REWORK 2, ORCH's own "option three" decision
  (§6).** All eight hang dispatches across the seven `:wasm_hang`-tagged tests are, in
  this rework, wired to acquire/release a lease around their own EXISTING direct calls
  (`PluginInterface.invoke/2,3`, `PluginHandler.handle_node/1`, or raw
  `Wasmex.call_function/4`), using exactly the crash-safety placement §2 already worked
  out for a real caller. §6.3 works through the claim precisely rather than asserting
  it: concurrent admission is genuinely serialized by construction (no two hangs are
  ever admitted at once, closing the exact race ISS-0418's own recurrence log
  documents); a wedged native slot is never reclaimed regardless (§0's own core
  finding, unchanged), and §6.3.1 names the one residual arithmetic risk (cumulative
  sequential leaks exceeding a small runner's total pool size) this wiring does not and
  cannot close.
- **DOES NOT cap production WASM dispatch. This is the limitation that must not
  erode, stated here with the same prominence as the CI-flake fix above, per this
  rework's own explicit instruction not to let it go quiet:** the wiring in §6 is
  TEST-SIDE ONLY, added directly to `test/letflow/engine/wasm/*.exs`. §1/§8.1's scope
  boundary is otherwise unchanged — `PluginInterface.invoke/2,3` and
  `PluginHandler`/`handle_node/1` themselves are still NOT modified, and no production
  call site acquires a lease, because none exists yet (OQ-C — most plausibly REQ-056,
  still `pending`). **A real, adversarial WASM guest running in production today, or
  after this design ships, is dispatched with NO admission cap of any kind** — this
  design's only production-facing artifact is the primitive itself (§5) and the
  contract (§8.1) a future dispatch-integration requirement must follow to actually
  gate live traffic. A future reader must not come away believing production is
  protected by this run; it is not, and §6/§8.1/§9 OQ-C all restate this.
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
  `owner_ref = Process.monitor(owner_pid)`, `sandbox_pool.ex:566`) and releases the
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
`sandbox_pool.ex:407`).

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

**Default:** `max(div(System.schedulers_online(), 2), 1)`.

**REWORK NOTE (CODE-DESIGN-VALIDATOR step-02b, MAJOR finding), read before the
justification below.** The prior revision of this section recommended
`max(System.schedulers_online() - 2, 1)` and, in the same paragraph, quoted this exact
host's own numbers (`available_parallelism()` = 8 per REQ-170 §1.5, `schedulers_online()`
= 16) as illustration — without checking its own formula against those numbers. Checked
now: `max(16 - 2, 1) = 14`, which is **greater than** the cited pool size of 8. That is a
non-protective default on the design's own worked example, exactly the "a cap at or
above the actual native pool size bounds nothing" failure this same section warns
against one paragraph earlier. This was a real design defect, not a wording slip, and is
fixed by replacing the fixed-subtraction formula with a fixed-fraction one (below), which
degrades far more gracefully when the two counts diverge, plus an explicit
operator-facing warning (last bullet) rather than a buried caveat.

**Justification, stated explicitly per OQ-5's own "operator-configurable" wording
(the number must be justified, not merely picked):**

- **The core problem, stated first because it drives every choice below: there is no
  BEAM-side API that reads `wasmex`'s own native `TOKIO_RUNTIME` pool size directly**
  (confirmed absent by ISSUE-FIXER's grep of the full native/lib source trees, per its
  diagnosis §1 — no NIF parameter, env var, or `Wasmex.EngineConfig` field exposes it;
  this design's own review of the codebase found no existing `:erlang.system_info/1`-
  based proxy for it either, so nothing already in this codebase can be reused here).
  `wasmex`'s pool is sized to `std::thread::available_parallelism()`, a Rust-side OS
  query with **no Elixir/BEAM equivalent surfaced anywhere in this dependency or the
  standard library** — `System.schedulers_online()` is the nearest BEAM-side number,
  but it counts BEAM schedulers, not OS logical cores, and the two are configured
  independently (`+S`/`+SDcpu` VM flags can set BEAM's scheduler count to anything,
  unrelated to what `available_parallelism()` reports). **This design cannot compute an
  exact answer and does not claim to; it computes a deliberately conservative one.**
- **Corrected figures for this host, re-measured directly this session (not assumed
  from a different host's numbers, which was the prior revision's own error):
  `nproc` = 16 and `System.schedulers_online()` = 16 on the CODE-DESIGN-VALIDATOR's
  and this rework's own host** — i.e. on THIS host the two counts agree, unlike
  REQ-170's original design-session host (`available_parallelism()` = 8 against
  `schedulers_online()` = 16, a 2x divergence). Both real, both cited accurately now:
  REQ-170 §1.5's host is a genuine, documented case where the two diverge sharply, and
  this rework's own host is a case where they do not — the formula below is chosen to
  survive the divergent case, since that is the one that can silently fail to protect.
- **Why a fixed FRACTION, not a fixed SUBTRACTION, of `schedulers_online()`:** a fixed
  subtraction (the prior `- 2`) shrinks the cap by a constant amount regardless of how
  large `schedulers_online()` gets relative to the real pool size — exactly why it
  failed on the 16-vs-8 case (16 - 2 = 14, still far above 8). A fixed **fraction**
  shrinks proportionally, so it degrades gracefully as the divergence widens instead of
  becoming a no-op past some threshold. `div(schedulers_online(), 2)` on the two
  concretely known cases: REQ-170's divergent host, `div(16, 2) = 8`, exactly equal to
  the cited real pool size of 8 (not strictly below it — see the explicit caveat below,
  this is not claimed as a proof of protection, only as no longer a proven no-op); this
  rework's own convergent host, `div(16, 2) = 8`, comfortably below the real pool size
  of 16. A small CI runner (~4 vCPU, ISS-0418's own recurrence evidence, where the two
  counts typically track 1:1 on a dedicated runner): `div(4, 2) = 2`, below a pool of
  ~4. `max(_, 1)` floors at 1 rather than 0 or a negative number on a 1-2 core host,
  mirroring `Letflow.Admission.init/1`'s own identical `max(pool_size - reserved_headroom, 1)`
  floor shape (though the operation before the floor now differs, per above).
- **Explicit caveat, stated plainly rather than buried, per the validator's own
  required fix:** this formula is a **heuristic over an unmeasurable quantity, not a
  guarantee.** On REQ-170's own cited host it lands exactly AT the real pool size
  (`div(16,2)=8` vs. an actual 8) — the boundary case, not strictly below it — so it is
  not proven protective there either, only no longer proven non-protective as the prior
  `-2` formula was. **An operator whose BEAM scheduler count is set (via `+S`/`+SDcpu`)
  to significantly exceed the host's actual logical core count — the specific
  divergence this default cannot detect or correct for — must override `cap` manually
  to a value measured against that host's real `available_parallelism()`** (obtainable
  operationally outside the BEAM, e.g. `nproc` on Linux, since no in-BEAM read exists).
  This is not a hypothetical: REQ-170's own design-session host is a real, already-
  measured instance of exactly this divergence.
- **This default is deliberately NOT tight enough to fully prevent exhaustion under a
  sufficiently large burst** — per §0/§4, no default can, since the cap bounds
  concurrent callers, not leaked threads, and this default is sized for ordinary
  production headroom, not adversarial-burst safety. An operator running WASM plugins
  under a threat model where many simultaneous tenant-supplied hangs are expected
  should configure a tighter value explicitly; this default optimizes for "do not
  throttle ordinary traffic too aggressively" over "survive a deliberate burst,"
  consistent with this being a harm-reduction mechanism (§0), not a hard security
  boundary.
- **This is explicitly separate from and smaller in scope than the `:test`-environment
  override (§6.1, now superseded by §6's rework below — see that section)** — a test
  or CI-specific override is not this production default, and must not replace it in
  non-test environments.

---

## 6 — Test strategy: ORCH's option three — wire the lease into the eight `:wasm_hang` hang dispatches directly, in this same run

**REWORK 2 NOTE (ORCH decision, following CODE-DESIGN-VALIDATOR's step-02b BLOCKER and
this design's own rework-1 §6.4 finding).** Rework 1 retracted the false determinism
claim (route (b): keep §1/§8.1's boundary, state the limitation) and separately
surfaced, unprompted, a third option the gate had not offered: wire the lease directly
into the `wasm_hang` tests' own existing call sites, closing the CI flake in this same
run without waiting for OQ-C's unbuilt production dispatch integration. **ORCH has
now chosen that option explicitly** (its own message to this rework, reasoning
recapped in §6.0 below) — this section replaces rework 1's §6 entirely with that
design.

### 6.0 ORCH's reasoning, recapped for the implementer's context (not re-litigated — accepted)

ISS-0418 was selected specifically because the CI gate measures 44% (14/25 runs) with
every classifiable failure being this one flake; a primitive proven not to touch that
call graph would leave the run's stated justification unmet while the record showed the
issue addressed — exactly the "looks fixed, isn't" outcome already caught twice
elsewhere in this pipeline (ISS-0427, the ISS-0069 gate). The cost is bounded and
already measured: the tests in question already call `invoke/2,3`/`handle_node/1`/raw
`Wasmex.call_function/4` directly, so wiring a lease around calls that already exist
is additive test-code, not a change to REQ-057/165/170's shipped algorithm — the actual
objection route (a) raised in rework 1 (modifying `invoke/2,3` itself, or forcing every
caller through a new required wrapper) does not apply to wiring a lease **around**
existing calls from the test's own process. This design accepts that reasoning; §6.4
records why it holds up against a second, independent check (the exact case-by-case
mechanics below) rather than merely on ORCH's say-so.

### 6.1 The exact tests, and why the count is eight, not seven

**Seven `@tag :wasm_hang` tests exist across three files, but one dispatches two
sequential live hangs, so this section wires eight hang-dispatch sites across seven
test bodies.** Confirmed by direct re-read of all three files this rework:

| # | File:line | Call shape | Hang dispatches in this test body |
|---|---|---|---|
| 1 | `call_timeout_test.exs:76` (AC2) | Raw `Wasmex.call_function/4`, no `PluginInterface`/`PluginHandler` at all — `Wasmex.start_link/1` then two sequential `Wasmex.call_function/4` calls on the SAME pid, both wrapped in `try/catch :exit` | 2 (the test's own second call on the now-wedged `pid` is itself a second live hang, per §1.2's "Store stays wedged" finding — see §6.2's note on this specific test) |
| 2 | `call_timeout_test.exs:155` (AC5) | `PluginInterface.invoke/2` directly | 1 |
| 3 | `host_api_write_test.exs:458` | Raw `Wasmex.call_function/4` via `start_instance/2`'s own helper, wrapped in `try/catch :exit` | 1 |
| 4 | `plugin_handler_test.exs:152` (AC5) | `PluginInterface.invoke/3` directly | 1 |
| 5 | `plugin_handler_test.exs:353` (REQ-170 AC1) | `PluginInterface.invoke/2` directly | 1 |
| 6 | `plugin_handler_test.exs:393` (REQ-170 AC3) | `Task.Supervisor.async_nolink/2` + `PluginHandler.handle_node/1` directly, MIRRORING `invoke/2,3`'s own internal algorithm (the test itself plays the role `invoke/2,3` plays in production) | 1 |
| 7 | `plugin_handler_test.exs:472` (REQ-170 AC4) | `PluginInterface.invoke/2` directly, called TWICE sequentially (`timeout_ms` 300 then 7,000) in one test body | 2 |

Total: 7 tagged tests, 8 hang dispatches (`call_timeout_test.exs:76`'s test body
contains 2, `plugin_handler_test.exs:472`'s test body contains 2, the remaining five
contain 1 each) — this reconciles ORCH's "eight" against the validator's own "seven"
citation, which counted tagged tests, not hang dispatches; both counts are correct for
what they count, stated here so neither is mistaken for an error in the other.

### 6.2 Three distinct wiring shapes, one principle applied three times

**The governing principle is §2's, restated for a test process instead of a future
production caller: acquire the lease in the process that is never the one
`Task.shutdown(:brutal_kill)` (or, for the raw-`wasmex` tests, nothing at all) targets,
and release it on every return path, including the hang path, via a guaranteed-cleanup
construct.** Concretely, per call shape:

**Shape A — tests calling `PluginInterface.invoke/2,3` directly** (rows 2, 4, 5, 7):
the test process itself IS `invoke/2,3`'s caller, exactly the position §2/§8.1 already
specify for a production caller. Each such test wraps its existing
`PluginInterface.invoke(...)` call as:

```
{:ok, lease} = InvocationLease.try_acquire()
result = PluginInterface.invoke(PluginHandler, hang_context, opts)
:ok = InvocationLease.release(lease)
# existing assertions against `result`, unchanged
```

using a `try/after`-equivalent (an ExUnit `on_exit/1` callback registered immediately
after `try_acquire/0` succeeds is the idiomatic guaranteed-cleanup construct for a test
body, since it runs even if a later `assert` in the same test raises) rather than a bare
sequential `release/1` call, so a later assertion failure in the same test does not skip
the release and leak a lease slot into the NEXT test in the same file (this is exactly
the same "guaranteed regardless of outcome" property §2 already established for
`invoke/2,3`'s own future caller, applied here to ExUnit's own failure-can-happen-anywhere
shape instead of a brutal-kill). Row 7's test acquires and releases the lease **twice**,
once around each of its two sequential `invoke/2` calls — not once around both, since
each call is an independent admission event and the second call must not be admitted
until the first's lease (and, more importantly per §6.3, the first's OWN outer bound)
has actually returned.

**Shape B — the test mirroring `invoke/2,3`'s own internal algorithm** (row 6,
`plugin_handler_test.exs:393`): this test does not call `invoke/2,3` at all — it
reimplements its `Task.Supervisor.async_nolink/2` + `Task.yield/2` +
`Task.shutdown(:brutal_kill)` shape directly, specifically so the dispatched task's pid
is observable to the test (per that test's own existing comment, `invoke/3`'s wrapper
does not expose it). **The test process here plays exactly the role `invoke/2,3` plays
in production** — it is the process that calls `Task.shutdown(:brutal_kill)`, never the
process targeted by it (the target is the `async_nolink`'d task running
`PluginHandler.handle_node/1`). The lease is acquired by the test process before
`Task.Supervisor.async_nolink/2` is called and released via the same `on_exit/1`
guaranteed-cleanup construct as Shape A, immediately after the existing
`Task.shutdown(task, :brutal_kill)` call (which this test already performs) — §2's
crash-safety reasoning transfers verbatim, since this test's own process is
structurally identical to `invoke/2,3`'s own caller-side code, just written out longhand
instead of calling the wrapper.

**Shape C — tests bypassing `PluginInterface`/`PluginHandler` entirely, calling raw
`Wasmex.call_function/4`** (rows 1, 3): there is no `invoke/2,3` and no
`Task.shutdown(:brutal_kill)` anywhere in these tests' own call graph at all — the test
process calls `Wasmex.start_link/1` and `Wasmex.call_function/4` directly, and the
existing `try/catch :exit` block is what observes the crash (per §1.1's live finding,
`wasmex`'s own client-side `GenServer.call` timeout crashes the CALLING process with an
ordinary `exit`, which here is the test process itself — no separate task is spawned at
all in this shape). Since the test process is never killed by anything (there is no
brutal-kill in this shape — the test process's own `try/catch` observes its own `exit`,
survives it via the `catch`, and continues running), the lease can be acquired
immediately before `Wasmex.start_link/1` and released via the SAME `on_exit/1`
guaranteed-cleanup construct as Shapes A/B, registered before the `try/catch` block:

```
{:ok, lease} = InvocationLease.try_acquire()
# existing Wasmex.start_link/1 + try/catch :exit Wasmex.call_function/4 block, unchanged
:ok = InvocationLease.release(lease)
```

Row 1's SECOND call (on the now-wedged `pid`, proving §1.2's "Store stays wedged" claim)
does **not** acquire a second lease — it is testing what happens to the SAME already-
leaked native thread from a second call on the same `Store`, not a second, independent
invocation of a fresh guest; wrapping it in its own `try_acquire/0` would misrepresent
what that specific assertion is about (a single already-wedged native resource, not two
concurrent admissions) and is not done here.

### 6.3 The honest determinism question, worked through precisely (per ORCH's own instruction (b))

**Does the wiring in §6.2 make the isolated subprocess deterministic? Worked through
directly, not asserted.** (Note: no special `cap: 1` value is required for this —
§11's closing note explains why the wiring itself, not a particular numeric cap,
is what does the serializing work; the question is stated in terms of the wiring, not
a specific configured value.)

- **For concurrent admission: yes, genuinely, by construction.** All seven test
  bodies' `describe` blocks run under `async: false` (confirmed, all three files) — so
  ExUnit itself already serializes them within one file, and ISS-0428's own note
  (quoted in ISS-0418's recurrence log) states the `wasm_hang` subprocess run as a
  whole is deliberately kept serial across files too. **What ExUnit's own serial
  execution does NOT already guarantee, and what the cap adds:** ExUnit moving on to
  test N+1 only means test N's *assertions* completed — it says nothing about whether
  test N's own dispatched native call has actually returned control to the point where
  a NEW invocation would be safe to admit without contending for a pool slot test N's
  own call might still be occupying (e.g. Shape B's test returns from its assertions
  immediately after `Task.shutdown(:brutal_kill)`, which is confirmed-fast per §1.4,
  but the underlying native `Store` execution is NOT killed by that call — only the
  BEAM task is). With the wiring in §6.2 (which holds at most one lease at a time,
  regardless of the configured `cap` value, since no two tests ever dispatch
  concurrently under `async: false`), test N+1's `try_acquire/0` call
  cannot succeed until test N has actually called `release/1` — which, per §6.2's
  `on_exit/1` placement, only fires after test N's own `invoke/2,3` (or its raw-`wasmex`
  equivalent) has ALREADY RETURNED. So admission is not merely serialized by ExUnit's
  own test ordering (which was already true) — it is serialized on the actual
  RETURN of the previous dispatch, closing the real gap the recurrence evidence
  points at: ISS-0418's own recurrence log shows failures where a NEIGHBORING test's
  not-yet-cleaned-up leak was still occupying a pool slot when the next test dispatched
  its own hang, contending for pool slots even though ExUnit had already "moved on."
  With the wiring in place, that specific race cannot occur: `try_acquire/0` blocks
  admission of the NEXT hang until the current one's own outer bound has actually fired
  and `invoke/2,3` (or its equivalent) has returned.
- **For a wedged native slot's effect on LATER tests: no — the cap does not, and cannot,
  fix this, and this must be stated as plainly as the concurrent-admission guarantee
  above, per ORCH's own instruction (b).** Every one of the eight dispatches
  permanently wedges one native `TOKIO_RUNTIME` slot FOREVER (§0 — this is the leak
  ISSUE-FIXER's diagnosis confirms has no BEAM-side reclamation). The LEASE releases
  when `invoke/2,3` (or its equivalent) returns — because the outer boundary always
  returns, per its own already-shipped AC3 guarantee, even though the underlying native
  thread does not — so the BEAM-side admission count correctly returns to `in_use: 0`
  after each test. **But the native pool itself has lost one real slot, permanently,
  every single time.** If the isolated subprocess's own native pool size is smaller
  than 8 (the number of hang dispatches in one full `mix test --only wasm_hang` run),
  the LAST one or more dispatches will be attempting to run inside an already-shrunk
  pool, regardless of how perfectly admission is serialized — the wiring in §6.2
  guarantees only one invocation is ever ADMITTED at a time (any configured `cap` value
  gives this property here, since the wiring itself never holds two leases at once),
  not that the pool still has 8 free slots by the time the 8th dispatch is admitted. **Stated precisely, per ORCH's own
  framing: the cap does not "relocate the failure" in the sense of moving WHERE a
  concurrency-caused failure happens — it genuinely eliminates the concurrency-caused
  failure mode ISS-0418's recurrence log documents (two tests racing for the same pool
  slots at the same moment). What it cannot do is grow the pool back between
  dispatches, so if 8 sequential, individually-non-concurrent dispatches exceed the
  pool's own total size, the LAST dispatch(es) still risk running against a pool with
  fewer free slots than it started with — but this is now a DIFFERENT, narrower risk
  than the one ISS-0418 documents:** ISS-0418's own recurrence evidence is entirely
  about CONCURRENT contention (multiple simultaneous dispatches racing for the same
  slots on a small/contended runner), not about strictly-sequential, one-at-a-time
  dispatches exceeding a fixed pool size — no recurrence note in ISS-0418's own record
  describes a failure shape consistent with "ran out of pool slots despite perfectly
  serial admission." This is the honest boundary of what serialization buys: it removes
  the race, not the arithmetic. §6.3.1 below states what closes that residual
  arithmetic risk, since 8 dispatches against a small CI runner's pool is a real,
  checkable number, not a hypothetical.

#### 6.3.1 Closing the residual arithmetic risk: the pool must have at least 8 free slots at the START of the isolated subprocess

Since the isolated `mix test --only wasm_hang` subprocess is short-lived and freshly
started (per ISS-0352's own architecture — a brand-new BEAM node, hence a brand-new,
completely unused `TOKIO_RUNTIME`), its native pool starts this run with its FULL
`available_parallelism()`-sized capacity, zero slots already consumed by anything else.
**The residual risk in §6.3 above is therefore only live if `available_parallelism()`
in that fresh subprocess is smaller than 8** (the total, strictly-sequential dispatch
count this section wires). ISS-0418's own recurrence evidence cites CI runners as small
as ~4 vCPU. **This is a real, named constraint this design surfaces rather than
silently assumes away: on a CI runner where `available_parallelism()` < 8, this
design's serialization removes the CONCURRENCY failure mode but the sequential dispatch
count (8) can still exceed a small runner's total pool size, and the cap's own
mechanism (bounding how many are admitted AT ONCE) does not, and cannot, address a
pool that is simply too small for 8 sequential, non-recoverable leaks in one process
lifetime.** This is not a defect this rework can fix by tuning `cap` (a smaller cap
does not change the total number of dispatches, only how many run concurrently, and
these dispatches are already forced fully sequential by the wiring above regardless of
`cap`'s value — no `:test`-environment override of `cap` is used at all, per §11's own
note that the wiring, not a specific numeric cap, is what serializes here). It is a
fact about this test suite's own
total hang footprint versus a given runner's pool size, independent of this design.
**Named as residual scope, not silently absorbed:** if this specific failure mode
(exhaustion from cumulative sequential leaks within one `wasm_hang` run, distinct from
ISS-0418's own documented concurrent-contention shape) is ever observed after this
design ships, it is evidence the suite's OWN total hang footprint (8 dispatches) needs
further reduction — the same "reduce genuine-hang footprint" lever ISS-0352's original
resolution already used once (from ~9 to ~7) — not evidence this design's serialization
failed at what it actually claims to do.

### 6.4 What this test wiring proves about the primitive that `invocation_lease_test.exs`'s unit tests alone would not

`invocation_lease_test.exs` (§6.5 below) proves `InvocationLease`'s own mechanics
correct against a synthetic `Process.exit(pid, :kill)` stand-in for a brutal-kill — fast,
deterministic, zero dependency on `wasmex`. **What it cannot prove, and what wiring the
lease into the real `wasm_hang` tests does prove:** that the lease's placement (§2/§8.1's
"acquire outside the process `Task.shutdown(:brutal_kill)` targets") is correct against
`PluginInterface.invoke/2,3`'s REAL algorithm and a REAL `wasmex` hang, not a stand-in —
i.e. that `try_acquire/0` called from a real `invoke/2,3` caller (or its Shape B/C
equivalents) genuinely survives the real brutal-kill/exit path and its `release/1`
genuinely fires every time, under the exact mechanism ISSUE-FIXER's diagnosis live-
reproduced. A synthetic `Process.exit(pid, :kill)` proves the MONITOR mechanism works;
only a real `wasm_hang` test run proves the PLACEMENT (which process acquires, which
process is killed) is correct against the real call graph, not just against this
design's own description of it. This is the same category of "verify against the real
source, don't assume" discipline REQ-170's own design doc applied to `wasmex`'s
documented claims (§1 there) — here applied to this design's own claim about where the
kill boundary is, checked against a real hang rather than only against a description of
one.

### 6.5 Unit coverage of the primitive itself (unchanged in substance from rework 1)

- **New test, `test/letflow/engine/wasm/invocation_lease_test.exs`** (ELIXIR-DEV/
  TEST-DESIGNER scope): starts an isolated `InvocationLease` instance (mirrors
  `Letflow.Admission`'s own `start_link/1` test-isolation `opts` override convention,
  §5.1/`admission.ex`'s own `:name`/`:pool_size` overrides). Asserts:
  (a) a first `try_acquire/0` succeeds; (b) a second, concurrent `try_acquire/0` (from a
  second process) against a `cap: 1` instance returns `{:error, :capacity}` while the
  first lease is held; (c) after the first lease's holder process is killed
  (`Process.exit(pid, :kill)`) WITHOUT calling `release/1`, a subsequent `try_acquire/0`
  succeeds within a bounded wait — the direct proof of §2's monitor-based auto-release,
  using an ordinary process kill as the cheap, non-WASM-dependent stand-in for
  `PluginInterface.invoke/2,3`'s own brutal-kill; (d) an explicit `release/1` followed
  immediately by that same process exiting does not double-decrement `in_use` (proves
  the demonitor+flush race is closed, §5.3).
- This suite proves the primitive's mechanics in isolation (§6.4 states precisely what
  it does and does not prove beyond that).

### 6.6 Honesty clause, mirroring REQ-170 §5.2 item 3's precedent

Any new test or moduledoc content this design's implementation produces must state
precisely what §6.3 states — concurrent admission is genuinely serialized by
construction; a wedged native slot is never reclaimed regardless; the residual
sequential-exhaustion risk of §6.3.1 is named, not hidden. It must ALSO state, with
equal prominence, what §7's own moduledoc mandate now requires: this wiring covers only
the `:wasm_hang` test suite, and production WASM dispatch remains admitted with no cap
of any kind until a future dispatch-integration requirement (OQ-C) wires a real caller
against §8.1's contract. A comment on the new `try_acquire/0`/`on_exit` wiring inside
each test file must say so explicitly (e.g. "this lease is test-side only; production
dispatch does not acquire one yet — see design doc §0/§7"), not merely rely on the
moduledoc living in a different file. Per §0/§7, this is a comment/documentation
obligation carried into implementation, not a design element with its own separate
artifact.

---

## 7 — Required moduledoc content for `Letflow.Engine.Wasm.InvocationLease` (mirrors `CallTimeout`'s own precedent, §6 of req170's design)

Required moduledoc content, verbatim in substance (ELIXIR-DEV may adjust prose flow but
must preserve every factual clause):

> Bounds how many WASM guest invocations MAY be simultaneously dispatched through
> `Letflow.Engine.Wasm.PluginHandler.run_guest/3`, admitted via a global counting
> semaphore (`try_acquire/0`/`release/1`) — **for whichever caller actually acquires a
> lease before dispatching.** Filed against decision 0014's OQ-5 and
> `docs/issues/ISS-0418.yaml` (eleven-plus recurrences of a CI flake caused by the
> mechanism this module bounds). See
> `lib/letflow/design/iss0418-wasm-concurrency-cap.md` for the full design and its live
> diagnosis (`handoffs/WF03-ISS0418-20260905/step-01-issue-fixer-diagnosis.json`).
>
> **PRODUCTION WASM DISPATCH DOES NOT CALL THIS MODULE YET, STATED AS PLAINLY AS THE
> NATIVE-LEAK LIMITATION BELOW.** As of this module's introduction, the only callers
> wired to `try_acquire/0`/`release/1` are the `:wasm_hang`-tagged tests in
> `test/letflow/engine/wasm/` (design doc §6) — added specifically to make those tests'
> own admission deterministic and close a documented CI flake. `PluginInterface.invoke/2,3`
> and `Letflow.Engine.Wasm.PluginHandler` are NOT modified by this module's introduction
> and do not call `try_acquire/0` anywhere in their own bodies. **A real WASM guest
> invocation reached by production dispatch is therefore admitted with NO cap of any
> kind today** — this module exists as a primitive and a contract (design doc §8.1) for
> a future dispatch-integration requirement to wire into the real call path; until that
> requirement ships, this module protects only the test suite that explicitly calls it,
> never live traffic.
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
- **OQ-D (REWORK 2: RESOLVED by ORCH's own decision — kept here for the historical
  record of how this design arrived at its current scope).** Rework 1 named this as an
  undecided prioritization question for ORCH: wait for OQ-C's production caller, or
  wire the `wasm_hang` tests onto the lease now as an interim measure. **ORCH chose the
  interim wiring explicitly** (recapped §6.0) — the eight hang dispatches across seven
  tests are wired in this same run (§6.1/§6.2), while OQ-C's production call site
  remains unbuilt and out of scope here. This is no longer an open question for a
  future reader; it is recorded as settled, with the reasoning kept so a future reader
  understands why production remains uncapped despite the CI flake being addressed.

None of these open questions block implementation of §5/§8's actual contract. Whoever
builds OQ-C's production dispatch integration must still read §8.1 in full before
wiring a real production call site — the test wiring in §6 does not substitute for it,
and does not, by construction, make production dispatch safe (§0's own restated
limitation).

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
| — | Test strategy: deterministic vs. probabilistic fix for `wasm_hang` | §6 (REWORK 2, ORCH's option three: the eight hang dispatches across seven tests are wired to the lease in this run, closing the CONCURRENT-contention failure mode deterministically by construction, §6.3; a residual sequential-exhaustion risk is named, not hidden, §6.3.1; production dispatch stays uncapped, §0/§8.1) |

---

## 11 — Confirmation: exactly which existing files this design touches, and which it does not

**REWORK 2: this section's shape changed from rework 1** — ORCH's option-three
decision (§6) means the three `wasm_hang` test files ARE modified in this run, unlike
rework 1's scope. Restated in full below rather than diffed, so this section stays a
single, unambiguous source of truth.

**New files:** `lib/letflow/engine/wasm/invocation_lease.ex` (§5/§7); one new test file,
`test/letflow/engine/wasm/invocation_lease_test.exs` (§6.5) — TEST-DESIGNER's scope, not
built here.

**Modified:** `lib/letflow/application.ex` (add `InvocationLease` as a new supervised
child, §5.1 — no ordering dependency on any existing child);
`test/letflow/engine/wasm/call_timeout_test.exs` (2 hang dispatches wired, §6.2 Shapes A/C,
rows 1-2 of §6.1's table); `test/letflow/engine/wasm/host_api_write_test.exs` (1 hang
dispatch wired, §6.2 Shape C, row 3); `test/letflow/engine/wasm/plugin_handler_test.exs`
(4 hang dispatches across 4 tests wired, §6.2 Shapes A/B, rows 4-7) — in every case the
change is additive `try_acquire/0`/`on_exit(release/1)` wrapping around each test's
EXISTING call, per §6.2's three shapes; no test's own existing assertions, fixtures, or
`@tag` values change.

**NOT modified by this design:** `lib/letflow/admission.ex` (§3 — a new module is used
instead, Admission stays exactly as REQ-216/REQ-217/REQ-218 shipped it);
`lib/letflow/engine/plugin_interface.ex` (§8.1 — the lease is acquired/released by
`invoke/2,3`'s CALLER, which for the test-wiring in §6 is the test process itself,
exactly as it will be for a real future caller; `invoke/2,3`'s own body is never
touched); `lib/letflow/engine/wasm/plugin_handler.ex` (§8.1's correction — this design's
first draft proposed a `handle_node/1` change and struck it in the same pass once the
actual brutal-kill boundary was traced precisely; `PluginHandler` needs no change at
all, in production OR in the test wiring, which wraps calls to it, not its own body);
`test/test_helper.exs`, `lib/mix/tasks/letflow.check.test.ex`, `config/test.exs` (§6 —
no `:test`-environment `cap` override is used; the wiring in §6.2 calls
`InvocationLease.try_acquire()`/`release/1` against the SAME globally-supervised
instance §5.1 adds to `Letflow.Application`, using its ordinary production default
(§5.5) — not a special test-only cap value, since §6.3's serialization property holds
for ANY cap, not specifically `cap: 1`, as long as it is below the number of
simultaneously-in-flight dispatches, which the wiring itself already guarantees is
never more than one regardless of the configured cap);
`lib/letflow/engine/wasm/call_timeout.ex`, `resource_limits.ex`, `capability_gate.ex`,
`module_registry.ex`, `memory_guard.ex` (untouched, no interaction with this design's
scope).

**A note on why no special test-`cap` override is needed in this rework, correcting
rework 1's own §6.1/OQ-D framing:** rework 1 assumed a `cap: 1` override was necessary
to force serialization. Rework 2's actual wiring (§6.2) makes this unnecessary — since
every hang dispatch in the suite is now individually wrapped in its own
`try_acquire/0`/`release/1` pair, and `async: false` already ensures only one test
body executes at a time, at most one lease is ever held at once regardless of what
`cap` is configured to. A `cap: 1` override would have been redundant, not incorrect —
this design does not add one, to avoid implying the numeric value of `cap` is what does
the serializing work here (it is the WIRING — one acquire/release pair per dispatch,
never overlapped — that does it, per §6.3's own precise statement).
