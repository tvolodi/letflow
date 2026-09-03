# REQ-218 — Wire admission control into Poller's per-tick tenant sweep

Design for closing ISS-0431/GH#835's SECONDARY surface, atop REQ-216's core
`Letflow.Admission` module. Ports no R-Co source (Poller's admission wiring
has no R-Co analogue). No implementation code below — signatures,
`@spec`/`@type` shapes, and prose only.

## 0. Inputs read in full before this design (confirmed, not assumed)

* `lib/letflow/admission.ex` (REQ-216, merged) — `try_acquire(pool_selector(),
  server) :: {:ok, admission_ref()} | {:error, :capacity}`, `release(
  admission_ref(), server) :: :ok`. Both default `server` to `__MODULE__`
  (the application-supervised singleton). `release/2` is documented
  idempotent — releasing a ref whose `id` is no longer in the server's
  `refs` map (already released, or the server restarted) is a no-op,
  always `:ok`, never a raise. There is no wait queue — a rejection is an
  immediate, synchronous `{:error, :capacity}`, never a park/retry inside
  `Letflow.Admission` itself.
* `lib/letflow/scheduler/poller.ex` (current state, read in full) —
  `handle_info(:tick, state)` computes `schemas` once via
  `fetch_tenant_schemas/0`, then calls, in this exact sequence, ALL against
  the same `schemas` list:
  1. `Enum.each(schemas, fn schema_name -> Scheduler.poll_and_fire(schema_name) end)`
     — the timer poll-and-fire loop. No `try`/`rescue` around the inner
     call today; the moduledoc states `poll_and_fire/1`'s own contract
     already guarantees it never raises.
  2. `maybe_refresh_active_instances(schemas)` — REQ-194's active-instance
     gauge refresh. **Not named by REQ-218's scope list** (the requirement
     names exactly six operations: the timer loop plus the five
     `maybe_run_*` sweeps) — left untouched by this design; see §7 Q1.
  3. `maybe_run_retention_sweep(schemas, state)` — `Enum.each(schemas, fn
     schema_name -> Scheduler.run_retention_sweep(schema_name) end)`,
     itself gated by an outer `if retention_enabled? and retention_due?`
     check that runs once, not per schema. No `try`/`rescue` around the
     inner call today.
  4. `maybe_run_alert_detection(schemas, observed_lag_ms,
     last_tick_started_at)` — gated by an outer `Application.get_env`
     enabled-check, then `Enum.each(schemas, fn schema_name -> try do
     Alerts.build_context_and_detect(schema_name, observed_lag_ms,
     last_tick_started_at) rescue _ -> :ok end end)`.
  5. `maybe_run_ordering_cycle(schemas)` — same shape as (4): outer
     enabled-check, then `Enum.each` with a per-schema `try do
     Letflow.Ordering.run_cycle(schema_name, prefix: schema_name) rescue _
     -> :ok end`.
  6. `maybe_run_ordering_sweeper(schemas)` — same shape, wrapping
     `Letflow.Ordering.sweep_gaps/2`.
  7. `maybe_run_ordering_metrics(schemas)` — same shape, wrapping
     `Letflow.Ordering.emit_lag_metrics/2`.
  All seven are SEQUENTIAL (one `GenServer` process, one schema at a time)
  — confirmed no `Task.async`/`Enum.map`-with-concurrency anywhere in this
  module.
* `lib/letflow/obs/alerts.ex` (ISS-0429, merged) —
  `build_context_and_detect/3`'s body: three `safe_*` Repo reads (`dlq_count`,
  `stuck`, `paused`, each independently rescued to a default inside the
  function itself), then `run_detection/2`, which — only when a threshold
  trips — calls `fire_hooks/4`. `fire_hooks/4`, per hook, calls
  `check_and_record_emission/4` (a synchronous `Repo.get_by` +
  conditional `Repo.insert`, still inside `build_context_and_detect/3`'s
  call frame) and, ONLY on `:ok` (not `:already_emitted`), calls
  `Task.Supervisor.start_child(Letflow.Obs.Alerts.TaskSupervisor, fn ->
  deliver_with_retry(hook, payload, trigger_key, 1) end)`. `start_child/2`
  itself is non-blocking — it hands the closure to the supervisor and
  returns immediately; the closure's own body (`deliver_with_retry/4`,
  which is what actually performs HTTP delivery and the mid-backoff
  `Process.sleep/1` ISS-0429 fixed) runs on a SEPARATE, unsupervised-by-
  Poller process, after `build_context_and_detect/3` has already returned
  to its caller. `build_context_and_detect/3`'s own `@spec` return type is
  `:ok` unconditionally — it does not wait for or reflect the dispatched
  task's outcome.
* `lib/letflow/plugs/admission.ex` (REQ-217, merged) — prior art for
  "wrap an existing call site, skip on rejection" shape: `call/2` does
  `case Admission.try_acquire(pool_selector) do {:ok, ref} -> admit(conn,
  ref, assign_key); {:error, :capacity} -> reject(conn, rejection_detail)
  end`. REQ-218's shape is simpler in every dimension that mattered for
  REQ-217: no HTTP response to build on rejection (Poller has no client to
  answer), no cross-process ref hand-off (`conn.assigns` +
  process-dictionary dual storage exists there solely to survive a raise
  crossing Bandit's request-pipeline boundary into `Plug.ErrorHandler`,
  Bandit machinery Poller has no analogue of), and no double-global-
  consumption hazard to guard against (each of Poller's six operations
  acquires and releases its own single ref, never two stacked refs the
  way the old global+tenant HTTP mount pair did before REQ-217's rework).
  The one HTTP-path property REQ-218 DOES reuse: rejection is a plain,
  synchronous branch taken instead of the normal call, never a crash.
* `test/letflow/scheduler/poller_test.exs` — `Letflow.Scheduler.Poller`'s
  `handle_info/2` is called directly, as a plain function, in most of this
  file's tests (sidesteps the documented `Ecto.Sandbox` ownership issue);
  two tests (`AC8`, ISS-0429) instead `start_supervised!(Poller)` and
  observe effects over real wall-clock ticks, relying on
  `use Letflow.DataCase, async: false`'s shared-sandbox mode. `PollerTest`
  itself never touches `Letflow.Admission` today.
* `test/support/admission_test_helpers.ex` (REQ-217) —
  `restart_admission!(pool_size, reserved_headroom)` restarts the real,
  application-supervised `Letflow.Admission` singleton (`Supervisor.
  terminate_child/2` + `restart_child/2` against `Letflow.Supervisor`,
  child id `Admission`) under overridden config, and registers an
  `on_exit/1` that restores it. This is exactly the mechanism REQ-218's
  tests need: `Letflow.Scheduler.Poller` calls `Letflow.Admission.
  try_acquire(:global)` with NO `server` argument (default `__MODULE__`),
  so it necessarily talks to the same named singleton this helper
  restarts — there is no second, differently-named `Letflow.Admission`
  instance to stand up for Poller specifically. Confirmed reusable
  as-is, unmodified, by this design (§6).

## 1. Insertion points — exact granularity

**Each of the six named operations gets its OWN `try_acquire(:global)` /
`release/1` pair, scoped to that operation's single call INSIDE its
`Enum.each` iteration — never around the whole `Enum.each` loop, and never
around more than one operation's call.** Concretely, six independent
wrap sites, one per operation, each wrapping only the named call listed:

| # | Operation (per REQ-218's scope list) | Function wrapped, call site | Existing per-schema isolation to preserve |
|---|---|---|---|
| 1 | Timer poll-and-fire loop | `Scheduler.poll_and_fire(schema_name)`, inside `handle_info/2`'s own top-level `Enum.each` | None today (contract-guaranteed non-raising) — acquire/release adds admission accounting only, no new rescue |
| 2 | Retention sweep | `Scheduler.run_retention_sweep(schema_name)`, inside `maybe_run_retention_sweep/2`'s `Enum.each` | None today — same as (1) |
| 3 | Alert detection | `Alerts.build_context_and_detect(schema_name, observed_lag_ms, last_tick_started_at)`, inside `maybe_run_alert_detection/3`'s `Enum.each` | `rescue _ -> :ok` around this exact call |
| 4 | Ordering cycle | `Letflow.Ordering.run_cycle(schema_name, prefix: schema_name)`, inside `maybe_run_ordering_cycle/1`'s `Enum.each` | `rescue _ -> :ok` around this exact call |
| 5 | Ordering sweeper | `Letflow.Ordering.sweep_gaps(schema_name, prefix: schema_name)`, inside `maybe_run_ordering_sweeper/1`'s `Enum.each` | `rescue _ -> :ok` around this exact call |
| 6 | Ordering metrics | `Letflow.Ordering.emit_lag_metrics(schema_name, prefix: schema_name)`, inside `maybe_run_ordering_metrics/1`'s `Enum.each` | `rescue _ -> :ok` around this exact call |

For each row, the required control flow, per schema, per operation, per
tick, in order:

1. Call `Letflow.Admission.try_acquire(:global)` (no `server` argument —
   uses the default, application-supervised singleton, matching how
   `Letflow.Plugs.Admission` and every other caller of this module already
   do it; REQ-218 introduces no second named instance).
2. On `{:ok, ref}`: perform the operation's named call exactly as it runs
   today, including its existing `rescue` clause where one exists (rows
   3–6) — the acquire/release wraps AROUND that existing `try`/`rescue`
   expression as a whole, it does not sit inside it or replace it. Release
   the ref (`Letflow.Admission.release(ref)`) unconditionally once that
   call — success, or its own already-established rescue path — has
   settled, before moving on to the next schema in the same `Enum.each`.
   Releasing via an `after` clause on the wrapping `try` (rather than only
   on the "happy" fall-through) is the required shape specifically so a
   release is guaranteed even if some future edit to the wrapped operation
   ever let an exception the operation's OWN `rescue` doesn't match escape
   — belt-and-suspenders against a leaked ref, not a claim that this can
   happen today (rows 3–6's own `rescue _ -> :ok` already matches every
   exception class, so in practice the `after` and the `rescue`'s own
   fall-through release at the same point; rows 1–2 have no inner
   `rescue` at all, so `after` is the ONLY mechanism guaranteeing release
   there).
3. On `{:error, :capacity}`: do not call the operation at all for this
   schema this tick. Log one line at `Logger.warning/1` level (§2) naming
   the schema and the operation, then continue the `Enum.each` to the next
   schema — this schema's turn for THIS operation is skipped for this
   tick only; nothing else is affected (§3).

This is the operation-call-scoped granularity, confirmed correct against
the requirement's own text in §3 below — NOT the whole-per-schema-
iteration granularity (which would mean one acquire/release per schema
covering all six operations at once) and NOT the whole-`Enum.each`-loop
granularity (one acquire/release per OPERATION covering all schemas in
that operation's loop at once). Both of those coarser alternatives are
ruled out by AC3 (a capacity rejection for one schema's one operation
must not prevent that SAME schema's OTHER operations, or a DIFFERENT
schema's SAME operation, from being attempted later in the same tick) —
see §3's full walk-through.

## 2. Skip behavior on `{:error, :capacity}`

Shape, per row above: a two-branch decision on `try_acquire(:global)`'s
return value — the `{:ok, ref}` branch performs the operation (existing
isolation intact) and always releases; the `{:error, :capacity}` branch
performs no Repo-touching work at all for that schema/operation pair,
logs, and falls through to the `Enum.each`'s next element. No branch
raises, halts the `Enum.each`, or returns early from the enclosing
`maybe_run_*`/`handle_info` function — this is a per-element skip inside
an otherwise-unchanged iteration, not a loop-level short-circuit.

**Logging: `Logger.warning/1`, one line per skipped schema/operation pair,**
distinct in both level and content from the existing `rescue _ -> :ok`
branches (rows 3–6), which log nothing today and are not changed to log
anything by this requirement (NOT IN THIS REQUIREMENT's own text scopes
changes to "any `maybe_run_*` function's own internal per-schema rescue
logic" to "wrapping it in acquire/release" only — adding logging to the
untouched `rescue` branches would exceed that scope). `Logger.warning/1`
(not `:info`/`:error`) per this codebase's own two real, on-point
precedents for the same event class — an expected condition where one
item is skipped and the loop continues, worth an operator's attention but
not a fault:
`lib/letflow/tenant_provisioning/backfill.ex:37` and `:44`
(`{:error, :tenant_not_provisioned}` / `{:error, :tenant_schema_missing}`
inside a `Enum.reduce_while`-style backfill loop — each logs at
`Logger.warning/1` and then continues via `{:cont, ...}`, i.e. skip-this-
one-continue-the-loop, exactly REQ-218's own shape) and
`lib/letflow/obs/alerts.ex:588` (`resolve_auth_header/1`'s `with`-`else`
fallback on auth-secret-resolution failure logs at `Logger.warning/1`,
`"alert hook auth_secret_ref resolution failed, sending without
Authorization"`, then degrades gracefully by returning `nil` rather than
halting delivery). Both precedents match REQ-218's skip event far more
closely than the earlier draft's `fetch_tenant_schemas/0` analogy, which
does not hold: `fetch_tenant_schemas/0`'s own `:error` path does not log
at all (it only calls `MetricsRegistry.mark_active_instances_refresh_failed/0`),
so it establishes no precedent for any specific `Logger` level.
`Logger.info/1` also has zero live call sites anywhere else in
`lib/letflow/`, confirming it is not this codebase's convention for any
comparable event. `Logger.error` remains reserved in this codebase for
actual failures/exhaustion (e.g. `alerts.ex:201` "alert detection
crashed", `alerts.ex:534` "alert delivery exhausted"), which a capacity
skip is not. The message must name both the schema and which of the six
operations was skipped (e.g. distinguishable free text per row,
`"schema=<schema_name> op=<operation-label>"`-shaped or equivalent,
optionally with keyword metadata in the `alerts.ex:588` style) so an
operator reading logs can tell which of the six admission sites is under
contention, per the requirement's own "so an operator can see
admission-driven skips happening" framing — the exact label vocabulary
(atom, string constant, etc.) is ELIXIR-DEV's to choose, not specified
further here since it carries no behavioral consequence.

## 3. Why per-operation-call granularity (not whole-iteration) is correct

Acceptance criterion 3 requires: *"an admission `{:error, :capacity}` for
one schema's operation within a tick does not prevent a DIFFERENT
schema's SAME operation, or that SAME schema's OTHER operations, from
being attempted later in the same tick."* This has two independent
sub-requirements, and each rules out a different coarser granularity:

* **"a DIFFERENT schema's SAME operation... attempted later"** rules out
  wrapping a whole OPERATION's `Enum.each` loop in one acquire/release
  pair (one `try_acquire(:global)` call per operation, shared across all
  schemas). Under that coarser design, a single rejection at the top of,
  say, `maybe_run_ordering_cycle/1` would skip EVERY schema's ordering
  cycle for the tick, not just one — directly violating this clause. The
  per-operation-call design in §1 instead calls `try_acquire/1` fresh,
  once per schema, inside the `Enum.each`, so schema B's turn for the same
  operation is an entirely independent admission decision from schema A's
  — B can succeed immediately after A was rejected, within the same tick,
  because A's rejection released nothing (nothing was acquired) and
  consumed no state that would affect B's own `try_acquire/1` call.
* **"that SAME schema's OTHER operations... attempted later"** rules out
  wrapping the whole PER-SCHEMA iteration across all six operations in one
  acquire/release pair (one `try_acquire(:global)` call per schema per
  tick, held across all six operations' calls for that schema). Under
  that coarser design, a single rejection for schema A would skip ALL SIX
  of A's operations for the tick, not just the one that happened to be
  active when the shared ref would have been acquired — again directly
  violating this clause, and also violating REQ-218's own §1
  scope text ("acquire ONE global admission slot... for that operation's
  single Repo-touching call, and release it immediately after that call
  returns" — singular "that operation," not "all of that schema's
  operations"). The per-operation-call design instead performs six fully
  independent `try_acquire/1`/`release/1` round-trips per schema per tick
  — one per row in §1's table — so a rejection on, e.g., row 3 (alert
  detection) for schema A has already fully resolved (acquired-then-
  released, or rejected-and-skipped) by the time row 4 (ordering cycle)
  begins its own independent `try_acquire/1` call for that same schema,
  with no shared state connecting the two decisions.

Both rejected coarser designs would also inflate how long a single held
ref blocks the global budget (one ref held across N schemas', or one
schema's six operations', full Repo round-trip time, instead of one
ref held only across a single Repo-touching call) — a secondary reason
the fine-grained design is preferable even where AC3 alone would not have
ruled a coarser option out, though AC3 is the dispositive requirement
text here, not this efficiency argument.

## 4. Composition with ISS-0429's async alert-hook dispatch

Row 3 in §1 wraps the ENTIRE `Alerts.build_context_and_detect/3` call
(the same call the existing `rescue _ -> :ok` already wraps today) in
one acquire/release pair — not some inner subset of that function's own
body. This is correct, not merely convenient, for the following reason:

`build_context_and_detect/3`'s own body is now (post-ISS-0429) fully
synchronous EXCEPT for the one `Task.Supervisor.start_child/2` call deep
inside `fire_hooks/4` (§0) — and `start_child/2` itself is non-blocking:
handing a closure to a supervisor and getting back a `{:ok, pid}` (or
error) is not a Repo-touching operation and does not wait for the
closure's own body to run or finish. By the time `build_context_and_detect/3`
returns control to `maybe_run_alert_detection/3`'s `Enum.each` — i.e. by
the time this design's `release/1` call runs for row 3 — any dispatched
`deliver_with_retry/4` task is either not yet started or running
independently on a `Letflow.Obs.Alerts.TaskSupervisor`-supervised process
that Poller does not wait on. So wrapping the WHOLE call (rather than
trying to carve out "everything except the dispatch line," which is not
mechanically possible from this call site anyway — `fire_hooks/4` is
private to `Letflow.Obs.Alerts` and not separately callable) already has
the effect the requirement wants: the admission slot is held for
exactly the synchronous "detect, decide, dispatch-or-don't" portion
(including the one synchronous `check_and_record_emission/4` Repo write)
and is released before the async delivery's own backoff/retry loop even
begins, let alone completes. No special-casing, and no change to
`Letflow.Obs.Alerts` itself, is needed to achieve this — it falls out of
`build_context_and_detect/3`'s existing `:ok`-unconditional, non-blocking-
dispatch contract (ISS-0429's own design) composed with an acquire/
release pair that simply brackets one ordinary function call, the same
way rows 1, 2, 4, 5, 6 each bracket their own ordinary function call.

This also means the held-ref duration for row 3 is now SHORTER than it
was before ISS-0429 (when the equivalent call blocked for the full
`deliver_with_retry/4` backoff schedule) — a beneficial side effect of
ISS-0429's own fix that this design does not need to do anything further
to obtain.

## 5. No interaction with REQ-217's HTTP-path admission gates

`Letflow.Plugs.Admission` (REQ-217) and `Letflow.Scheduler.Poller`
(REQ-218) are two independent callers of the SAME `Letflow.Admission`
singleton, coordinating only through that module's own global counter —
exactly the mechanism `Letflow.Admission` already exists to provide (its
moduledoc: "a single supervised `GenServer` holds... the global counter,"
composed identically regardless of caller). Both callers:

* Use the default `server` argument (`__MODULE__`) — there is one
  process, one counter, shared by construction.
* Never call `{:tenant, _}` from Poller (§1's table names only `:global`
  calls; REQ-217's `pool: :tenant` mount is HTTP-request-specific and
  untouched by this requirement — see NOT IN THIS REQUIREMENT).
* Need no new coordination primitive, lock, or cross-module call beyond
  `try_acquire/1,2` and `release/1,2` as REQ-216 already defined them —
  Poller acquiring a global unit simply makes that unit temporarily
  unavailable to a concurrent HTTP request's own `pool: :global` mount,
  and vice versa, which is the INTENDED accounting fix this requirement
  exists to close (§0 of REQ-218's own requirement text: "REQ-216's
  global cap... can only be a safe ceiling on HTTP-path concurrency if
  `reserved_headroom` already reserves enough slack for Poller's own
  use" — this design is what makes Poller's usage visible to that same
  ceiling, nothing more).

No change to `Letflow.Plugs.Admission`, `Letflow.Plugs.ApiPipeline`, or
any HTTP-path file is needed or made by this design.

## 6. Test approach

Reuses `test/support/admission_test_helpers.ex`'s
`restart_admission!(pool_size, reserved_headroom)` UNMODIFIED — confirmed
applicable because `Letflow.Scheduler.Poller` calls
`Letflow.Admission.try_acquire(:global)` with the default `server`
argument, the exact singleton this helper restarts. No new test-support
module or helper is needed.

Test shape per acceptance criterion, all under
`test/letflow/scheduler/poller_test.exs` (existing `Letflow.DataCase,
async: false` module — matches this helper's own "safe to call only from
an `async: false` test" requirement):

* **Forced-zero-then-restored cap (AC1 in REQ-218's list, "zero calls,
  then 3 on the next tick"):** `restart_admission!(pool_size: 1,
  reserved_headroom: 1)` yields `global_cap = max(1 - 1, 1) = 1` — not
  quite zero; achieving an effective zero-admission tick requires either
  (a) a `pool_size`/`reserved_headroom` pair that floors to `1` and then
  a probe `try_acquire(:global)` held OPEN (never released) before the
  tick runs, so the tick's own six-per-schema attempts all observe
  `global_in_use == global_cap`, or (b) confirming whether
  `reserved_headroom` alone can be driven to make `global_cap` exactly
  `0` — it cannot, since `Letflow.Admission.init/1` floors `global_cap`
  at `max(pool_size - reserved_headroom, 1)`, i.e. `global_cap` is never
  literally `0`. **Open question flagged for ELIXIR-DEV/TEST-DESIGNER**:
  use approach (a) — restart with a small cap (e.g. `pool_size: 3,
  reserved_headroom: 2`, `global_cap = 1`), then call
  `Letflow.Admission.try_acquire(:global)` directly in the test to hold
  the single available unit BEFORE invoking `Poller.handle_info(:tick,
  state)`, so every one of that tick's own `try_acquire(:global)` calls
  observes exhaustion. Assert `poll_and_fire/1`'s call count is `0` for
  that tick (requires a spy/mock or a real-effect proxy — this codebase
  has no mocking library per `poller_test.exs`'s own existing convention
  of asserting real row-count/side-effect outcomes rather than mock call
  counts; TEST-DESIGNER should follow that same real-effect convention,
  e.g. asserting no timer actually fired, no retention row moved, etc.,
  in place of a literal "call count" assertion — REQ-218's own acceptance
  criterion text says "mock/spy call count," which conflicts with this
  codebase's no-mocking-library precedent; flagged as an open question
  for TEST-DESIGNER to resolve, most likely by asserting the equivalent
  real-effect absence instead of a literal spy count). Then release the
  held probe ref (restoring `global_in_use < global_cap`) and run a
  second `handle_info(:tick, state)`, asserting the operations DO run
  (e.g. a due timer now fires).
* **Cap of exactly 1, sequential drain (AC2 in REQ-218's list):**
  `restart_admission!(pool_size: 3, reserved_headroom: 2)` (`global_cap =
  1`), 3 tenant schemas, no probe held. Each schema's own `try_acquire/1`
  →`release/1` round-trip for a given operation is acquire-then-release
  before the next schema's `try_acquire/1` runs (§1's per-iteration
  scoping guarantees this — the ref for schema 1 is released before
  schema 2's `Enum.each` iteration begins), so a cap of exactly 1 never
  blocks permanently; assert all 3 schemas' real effects for the timer
  poll-and-fire loop occurred within that one tick.
* **Partial-skip, not total-skip, mid-tick (AC3):** force capacity
  exhaustion for a subset of `try_acquire(:global)` calls only — e.g.
  hold a probe ref for exactly the duration of one specific
  schema/operation pair's attempt (achievable by holding the probe
  before the tick and releasing it partway through — for a
  deterministic test, the cleanest approach is asserting the STRUCTURAL
  guarantee directly: with `global_cap = 1` and no probe held, run a
  tick over 3 schemas and assert all 3 succeed for a given operation
  (proving one schema's success doesn't block the next), then separately
  hold a probe for the whole tick and assert all 3 are skipped for that
  operation while confirming a DIFFERENT operation in the same tick
  still succeeds once the probe is released between operations — the
  precise interleaving harness is TEST-DESIGNER's to construct; this
  design confirms the production code (§1, §3) provides the necessary
  independence (fresh `try_acquire/1` per schema per operation) for such
  a test to be constructible at all.
* **`{:tenant, _}` never called (AC4):** a static grep/AST test over
  `lib/letflow/scheduler/poller.ex`'s source text, matching this file's
  own existing precedent (`poller_test.exs`'s "no second ticker" test
  already greps `lib/letflow/scheduler/**/*.ex` for `use GenServer`) —
  assert the compiled/raw source does not contain `{:tenant,` anywhere.
* **Rescue still catches, ref still released, no leak (AC5):** for row 3
  (`maybe_run_alert_detection/3`, the requirement's own named example),
  force `Alerts.build_context_and_detect/3` to raise for one schema
  (e.g. via a schema/config state already known to make one of its
  internal calls raise past its own `safe_*` rescues, or a dedicated
  fault-injection fixture if the existing ones are all self-rescuing —
  open question for TEST-DESIGNER, since every `safe_*` helper in
  `alerts.ex` already rescues internally, so a raise reaching
  `build_context_and_detect/3`'s OWN caller-side `rescue _ -> :ok` in
  `poller.ex` may require reaching further, e.g. a raise from
  `run_detection/2` or `fire_hooks/4` itself rather than the three
  `safe_*` helpers) followed by, in the SAME tick, a normal
  `try_acquire(:global)`-consuming operation for a different schema
  succeeding — proving the ref from the raised call was in fact released
  (not leaked) rather than merely inferring it from the tick not hanging.
  A second, more direct assertion: after the tick, call
  `Letflow.Admission.try_acquire(:global)` (or inspect state via
  `:sys.get_state/1` on the `Letflow.Admission` process, mirroring
  `admission_pipeline_test.exs:298-301`'s own precedent for reaching
  into `Letflow.Admission`'s state directly) and confirm
  `global_in_use` has returned to its pre-tick value, not incremented by
  one per raised call.
* **`mix test`/`mix compile --warnings-as-errors` (AC6):** run as
  ordinary CI/local steps; no test-design implication beyond ensuring no
  new compiler warning is introduced (e.g. an unused `ref` binding on the
  `{:error, :capacity}` branch, or an unused `Logger` alias if `require
  Logger` is added without a corresponding call site — neither should
  occur given §1/§2's design, but ELIXIR-DEV should run
  `--warnings-as-errors` before considering the change complete, as
  every other requirement in this codebase already does).

## 7. Open questions

* **Q1 — `maybe_refresh_active_instances/1` (REQ-194) is NOT one of the
  six named operations.** REQ-218's own requirement text enumerates
  exactly six operations (the timer loop + five `maybe_run_*` sweeps) and
  never mentions `maybe_refresh_active_instances/1`, even though it is
  structurally identical (a per-schema `Enum.each` calling
  `Engine.count_instances_by_status/1`, itself Repo-touching, per-schema-
  rescued via `count_active_for_schema/1`'s own `rescue _error -> 0`).
  This design deliberately leaves it UNWRAPPED, matching the requirement's
  literal scope rather than silently extending admission coverage to a
  seventh operation the requirement didn't ask for. Flagged for REVIEWER/
  ORCH: is this an intentional omission in the requirement text (e.g.
  because its per-tenant query is judged low-cost/summary-only, matching
  its own moduledoc's "large, low-precision-tolerant summary gauge"
  framing), or a gap to fold into a follow-up requirement? Not resolved
  by this design — ELIXIR-DEV must NOT wrap it "for consistency" without
  a requirement-text or REVIEWER sign-off, per this project's own
  "don't silently resolve an open question by guessing" rule.
* **Q2 — exact `Logger` message wording/label vocabulary for skip
  events (§2)** is left to ELIXIR-DEV's discretion (no behavioral
  consequence, no acceptance criterion constrains the exact string) —
  only the level (`warning`, per §2's two cited precedents) and the
  requirement that both schema and operation be identifiable in the
  message are fixed by this design.
* **Q3 — AC1's literal "mock/spy call count" framing (§6)** conflicts
  with this codebase's no-mocking-library precedent already established
  in `poller_test.exs`'s own moduledoc/tests (asserting real row-count/
  side-effect outcomes, never a call-count mock). Flagged for
  TEST-DESIGNER to resolve by substituting an equivalent real-effect
  assertion (e.g. "no timer fired" / "a due timer fired") rather than
  introducing a mocking library or a spy wrapper around `Scheduler.
  poll_and_fire/1` this codebase has never used before, which would
  itself be a scope-creep risk for REVIEWER to weigh in on if
  TEST-DESIGNER judges a spy genuinely necessary.
* **Q4 — the exact fault-injection mechanism for AC5's "force a raise"
  test (§6)** is left to TEST-DESIGNER: every `safe_*` helper inside
  `Letflow.Obs.Alerts.build_context_and_detect/3` already rescues
  internally, so producing a raise that actually reaches `poller.ex`'s
  own `rescue _ -> :ok` (the boundary this AC needs to exercise) may
  require a different fault-injection point than the three `safe_*`
  helpers — e.g. forcing `run_detection/2` or `fire_hooks/4` itself to
  raise, which this design does not further specify.
