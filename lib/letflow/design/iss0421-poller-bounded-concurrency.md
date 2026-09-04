# ISS-0421 (narrowed): bounded per-tenant concurrency in `Letflow.Scheduler.Poller`

## 0. Scope

Per `handoffs/WF03-ISS0421-20260904/step-01-issue-fixer-diagnosis.json`, ISS-0421's
original three concerns have narrowed to one. Concerns 2 (platform-wide SPOF) and 3
(default restart intensity) are already fully resolved by REQ-219
(`Letflow.Supervisor.Pollers`, `max_restarts: 5, max_seconds: 60`) and ISS-0451
(`Letflow.Supervisor.PollersBreaker`). This document addresses ONLY concern 1: the
seven per-tick sweeps in `lib/letflow/scheduler/poller.ex`'s `handle_info(:tick, state)`
each iterate every tenant schema serially via `Enum.each/2`, so wall-clock per tick
scales with tenant count and a single slow/hung tenant call blocks every tenant behind
it, in every one of the seven sweeps.

Affected file: `lib/letflow/scheduler/poller.ex` only. No change to
`lib/letflow/supervisor/pollers.ex`, `pollers_breaker.ex`, `application.ex`, or
`lib/letflow/admission.ex` (its existing public contract is reused, not modified).

The seven sweeps, in their current tick order (unchanged by this design):

1. Timer poll-and-fire loop (`Scheduler.poll_and_fire/1`) — admission op `:poll_and_fire`
2. `maybe_refresh_active_instances/1` (`Engine.count_instances_by_status/1`) — **not**
   admission-wrapped (REQ-218 deliberately left this one unwrapped)
3. `maybe_run_retention_sweep/2` (`Scheduler.run_retention_sweep/1`) — admission op
   `:retention_sweep`
4. `maybe_run_alert_detection/3` (`Alerts.build_context_and_detect/3`) — admission op
   `:alert_detection`
5. `maybe_run_ordering_cycle/1` (`Letflow.Ordering.run_cycle/2`) — admission op
   `:ordering_cycle`
6. `maybe_run_ordering_sweeper/1` (`Letflow.Ordering.sweep_gaps/2`) — admission op
   `:ordering_sweeper`
7. `maybe_run_ordering_metrics/1` (`Letflow.Ordering.emit_lag_metrics/2`) — admission op
   `:ordering_metrics`

## 1. Numbers this design is built on (confirmed against current code/config)

- `Letflow.Repo`'s `pool_size` is **10** in `config/dev.exs` (`pool_size: 10`) and in
  `config/runtime.exs` (`POOL_SIZE` env var, default `"10"`). This is the "10" ISS-0421
  and the ISSUE-FIXER diagnosis cite; still current. (`config/test.exs` sizes the pool
  differently, `System.schedulers_online() * 2`, per ISS-0194/decision 0009 — test-only,
  irrelevant to this arithmetic, which targets the dev/runtime figure the issue names.)
- `Letflow.Admission.init/1` (`lib/letflow/admission.ex:221-222`) computes
  `global_cap = max(pool_size - reserved_headroom, 1)`, with `reserved_headroom`
  defaulting to **2** (`@default_reserved_headroom`). With `pool_size: 10` this makes
  `global_cap = 8`. This is a **platform-wide** budget: `try_acquire(:global)` is also
  called from `lib/letflow/plugs/api_pipeline.ex` (REQ-217, HTTP requests), not just from
  Poller. Six of the Poller's seven sweeps (every one except
  `maybe_refresh_active_instances/1`) already route every per-tenant call through
  `with_admission/3`, which calls `Admission.try_acquire(:global)` and skips-and-logs on
  `{:error, :capacity}` rather than blocking.
- `maybe_refresh_active_instances/1` is the ONE sweep with no Admission backstop
  whatsoever — REQ-218's own moduledoc says so explicitly ("deliberately left
  UNWRAPPED — not one of REQ-218's six named operations"). Any concurrency bound for
  this sweep must be justified directly against `pool_size`, not against
  `Admission.global_cap`, because nothing stops it from actually acquiring a
  `DBConnection` checkout the way Admission's counting semaphore stops the other six.

This existing Admission budget is the load-bearing fact for the whole design below: it
already caps concurrent `DBConnection` consumption from six of the seven sweeps,
platform-wide, independent of whatever `max_concurrency` this design picks for
`Task.async_stream`. Task-level concurrency for those six sweeps only needs to avoid
wasting spawned processes that will immediately fail admission — it is not the thing
standing between the fix and pool exhaustion. `maybe_refresh_active_instances/1` is the
one sweep where the `Task.async_stream` bound IS the only thing standing between the fix
and pool exhaustion, so it gets separate, stricter treatment (§3).

## 2. Sweep ordering: stays sequential; concurrency is bounded WITHIN each sweep only

Decision: the seven sweeps continue to run one after another in exactly their current
order inside `handle_info(:tick, state)` — sweep 2 does not start until sweep 1's
`Task.async_stream` call has fully drained, and so on. Only the per-tenant iteration
*inside* a single sweep becomes concurrent (bounded).

Rejected alternative: letting two or more sweeps run concurrently with each other (e.g.
kicking off sweep 2's stream before sweep 1's has drained). Rejected for two reasons:

- Six of the seven sweeps share the SAME `Admission.global_cap` (8) budget. If two
  sweeps' streams were in flight at once, both would be drawing on that one budget
  simultaneously, and whichever sweep's tasks lose the race would see a burst of
  `{:error, :capacity}` skips — not a safety problem (Admission still holds), but a
  *correctness*-visible regression: retention/alert/ordering sweeps would silently
  no-op for a large fraction of tenants most ticks purely from Poller's own two sweeps
  competing with each other for the same 8 slots, which is worse than today's fully
  serial guarantee that every sweep, run to completion, covers every schema (barring a
  genuinely external capacity crunch from HTTP traffic). Keeping sweeps sequential means
  only one sweep is ever drawing on `Admission.global_cap` at a time, so its 8 slots are
  contested only by concurrent HTTP admission traffic — the same coexistence the six
  sweeps already have today, just now with up to 8 concurrent Poller-side draws instead
  of 1.
- It also does not help the DBConnection-pool arithmetic in §3
  (`maybe_refresh_active_instances/1`'s bound), which is calibrated assuming this sweep
  is never running at the same wall-clock moment as one of the six Admission-gated
  sweeps' peak concurrency. Concurrent sweeps would break that assumption and would need
  a much more conservative (or dynamically shared) bound to stay safe.

This is a pure `handle_info(:tick, state)` control-flow property: each of the seven
`maybe_run_*`/inline calls remains a single expression evaluated in order, exactly as
today; only the body of each now uses `Task.async_stream/3` internally instead of
`Enum.each/2`.

## 3. Concurrency bound per sweep, with arithmetic

Two bound classes, not one blanket number — this is a deliberate per-sweep judgment
call, not uniform treatment:

### 3a. The six Admission-gated sweeps (poll-and-fire, retention, alert detection,
ordering cycle/sweeper/metrics)

`max_concurrency: 8`, i.e. exactly `Admission.global_cap` (`pool_size(10) -
reserved_headroom(2)`).

Arithmetic: every per-tenant task in these six sweeps calls `with_admission/3`, which
calls `Admission.try_acquire(:global)` before doing any `Repo` work and releases it in
an `after` clause regardless of outcome. Admission's own `handle_call` enforces
`global_in_use < global_cap` as a hard, non-blocking gate — a 9th concurrent attempt
(from Poller or from HTTP) gets `{:error, :capacity}` and is skipped-and-logged, never
queued, never granted. This means **`Admission.global_cap` (8) is already the true
ceiling on concurrent `DBConnection` checkouts attributable to these six sweeps,
platform-wide, regardless of what `max_concurrency` this design chooses** — setting
`max_concurrency` above 8 cannot push checkouts past 8, it would only spawn extra BEAM
processes that immediately lose the admission race and log a skip. Setting
`max_concurrency` to exactly 8 is therefore the number that lets every task that *can*
be admitted get spawned, with zero tasks spawned that are certain to be rejected purely
by construction (there are never more than 8 grantable slots to compete for at once from
Poller's own side). Worst case, if HTTP traffic is also drawing on the same budget at
that instant, some of the 8 spawned tasks lose to HTTP and skip-and-log exactly as they
do today under `Enum.each` (this is pre-existing, unchanged behavior — `with_admission/3`
already handles it) — the only thing this design changes is that up to 8 tenants' calls
for the *same* sweep can be admitted and in flight together, instead of 1.

Net: peak DBConnection checkouts attributable to these six sweeps, at any instant, is
bounded by `Admission.global_cap = 8`, unchanged from the ceiling that already exists
today at the platform level (Admission was sized for that ceiling before this fix
existed) — this design does not raise that ceiling, it only lets Poller actually reach
it instead of using 1 of the available 8 at a time.

### 3b. `maybe_refresh_active_instances/1` (no Admission backstop)

`max_concurrency: 2`, i.e. exactly `Admission`'s own `reserved_headroom` (2).

Arithmetic: this sweep's per-tenant call (`Engine.count_instances_by_status/1`) is not
routed through `Admission.try_acquire/2` at all (REQ-218's deliberate exclusion, §1),
so nothing stops its concurrent tasks from each holding a real `DBConnection` checkout
for the query's duration. Because sweeps are sequential (§2), this sweep's own peak
concurrency never overlaps in wall-clock time with another *Poller* sweep's peak, but it
CAN overlap with concurrent HTTP admission traffic, which can independently be holding
up to `Admission.global_cap = 8` checkouts at that same instant. Worst case combined
peak checkout count across the whole platform during this sweep's window is therefore
`8 (HTTP, admission-gated) + N (this sweep)`. Choosing `N = 2` makes that worst case
`8 + 2 = 10 = pool_size` exactly — it never exceeds the pool, and it exactly saturates
`reserved_headroom`, the same 2-connection allowance `Admission`'s own design already
set aside for exactly this class of non-admission-gated Repo consumer (REQ-216's
moduledoc does not enumerate what consumes `reserved_headroom`, but the number exists
precisely so *something* outside Admission's own accounting can use the pool without
Admission's grants alone exhausting it — this sweep is such a consumer). A higher `N`
(e.g. 4) would make the worst case `8 + 4 = 12 > 10`, an actual pool-exhaustion risk
under DBConnection's own queuing/timeout behavior, not merely a slow tick — rejected.

This is a conservative, worst-case bound: it assumes HTTP traffic is simultaneously at
its own admitted peak of 8, which will not be true on every tick. `N = 2` is chosen
specifically so the design holds even in that coincidence, matching the same
no-hand-waving standard `Letflow.SandboxPool`'s moduledoc sets for its own
DBConnection-checkout arithmetic (peak-checkout claims stated as an exact number with
the derivation shown, not "should be fine").

**Open question, flagged for REVIEWER / ELIXIR-DEV, not silently resolved**: this
arithmetic assumes `reserved_headroom` (2) is not ALSO being consumed by some other,
unrelated non-admission-gated Repo caller (LiveView sockets, `Ecto.Migrator`, an IEx
console session, health checks) at the same instant. That risk pre-dates this design
(it is inherent in `reserved_headroom` being a single shared allowance for "everything
Admission doesn't gate") and is not introduced by it, but this design makes
`maybe_refresh_active_instances/1` a second identified consumer of that allowance
alongside whatever else already relies on it, and the codebase currently has no
inventory of every such consumer. If that inventory is ever produced, revisit whether
`N = 2` still holds or whether `reserved_headroom` itself needs raising.

### 3c. Sanity check: worst case across the whole tick

Because sweeps are strictly sequential (§2), the platform-wide peak attributable to
Poller at any single instant during a tick is `max(8, 2) = 8` (whichever of the six
Admission-gated sweeps or the one unwrapped sweep happens to be running), never their
sum — the six-sweep peak of 8 and the one-sweep peak of 2 are never concurrent with each
other. Combined with the worst-case external (HTTP) draw already accounted for in §3b,
the design's stated worst-case total never exceeds `pool_size = 10`.

## 4. Fault isolation (AC1: one slow/erroring tenant must not block others)

Two changes are required together — bounding concurrency alone is not sufficient,
because `Task.async_stream/3`'s default failure semantics are strictly harsher than
`Enum.each/2`'s ever were:

### 4a. `Task.async_stream/3` options

Every one of the seven call sites converts its `Enum.each(schemas, fn schema_name -> ...
end)` into a `Task.async_stream/3` call over `schemas` with these options, then fully
consumes the resulting stream (e.g. via `Stream.run/1` or an enclosing `Enum.each/2`
over the yielded `{:ok, _}` / `{:exit, _}` tuples — the stream is lazy and produces no
work at all until enumerated, so "fully consume it" is a hard requirement, not a style
preference):

- `max_concurrency:` — per §3a/§3b above (8 or 2 depending on the sweep).
- `timeout:` — a new, explicit per-task budget. Today's `Enum.each/2` has NO per-tenant
  timeout at all: a hung call blocks that sweep (and, serially, every sweep after it,
  and the next tick) forever. `Task.async_stream/3`'s own default (`5_000` ms) is an
  implicit, undocumented behavior change if left unset, so this design makes it an
  explicit, named, configured value instead: a new `Letflow.Scheduler` accessor,
  `sweep_task_timeout_ms/0`, reading `config :letflow, :scheduler,
  sweep_task_timeout_ms:` fresh on every call (matching every other `Letflow.Scheduler`
  accessor's existing "read config fresh" convention), defaulting to `10_000` (10 s).
  Same value is reused by all seven call sites — one config knob, not seven. 10 s is
  chosen as generous headroom over a single tenant's single Repo-touching call under
  normal conditions, while still being well under `poll_interval_ms()`'s default of
  `5_000` ms... **flagged inconsistency for REVIEWER**: the *default* `poll_interval_ms`
  (5 s) is actually shorter than the proposed default `sweep_task_timeout_ms` (10 s).
  This is a real open question this design does not resolve unilaterally: either (a)
  accept that a genuinely slow tenant's task can still be "in flight" when the next
  tick's timer fires (harmless — the next tick's own `Task.async_stream` call for the
  same sweep is a fully independent invocation with its own fresh task set; the old
  task is simply still running or gets killed at its own 10 s mark, per §4b), or (b)
  lower the default timeout to something under the default poll interval (e.g. `4_000`
  ms). This design recommends (a) — treating tick cadence and per-task timeout as
  independent budgets is simpler and matches `Letflow.SandboxPool`'s own established
  precedent of separating unrelated waits into unrelated named budgets (`max_wait_ms` vs
  `provision_timeout_ms`) rather than coupling them — but ELIXIR-DEV/REVIEWER should
  confirm rather than this being silently assumed.
- `on_timeout: :kill_task` — **required**, not optional. `Task.async_stream/3`'s default
  (`on_timeout: :exit`) raises an exit in the calling process (the Poller `GenServer`
  itself) when a task exceeds `timeout:`, which would crash the whole tick — the exact
  opposite of AC1. `:kill_task` instead kills only the offending task and yields
  `{:exit, :timeout}` for that input in the stream, letting every other already-admitted
  task and the sweep's own enumeration continue undisturbed.
- `zip_input_on_exit: true` — makes every yielded tuple `{schema_name, {:ok, result}}`
  or `{schema_name, {:exit, reason}}` instead of bare `{:ok, result}` / `{:exit,
  reason}`, so the consuming code can log which tenant schema a timeout or crash
  belongs to (matching the existing `Logger.warning(..., schema: schema_name, op: op)`
  style already used in `with_admission/3` for capacity skips — the same tagging
  discipline should apply to timeout/crash skips).

### 4b. Per-task rescue — required in addition to `on_timeout: :kill_task`

`on_timeout: :kill_task` only covers a task that runs past its `timeout:`. It does
nothing for a task that raises immediately (e.g. a bad per-tenant DB state, a schema
mid-migration). `Task.async_stream/3`'s documented behavior for an unhandled raise
inside a task is to terminate the whole stream and re-raise/exit with that same reason
in the calling process — i.e., today's "one tenant crashes the sweep" hazard would
become "one tenant crashes the *entire async_stream call*," which is worse (it takes
down every other in-flight task's result along with it), not better.

To prevent this, the anonymous function each call site passes to `Task.async_stream/3`
(the one that goes on to call `with_admission/3` or, for
`maybe_refresh_active_instances/1`, `Engine.count_instances_by_status/1` directly) must
itself be wrapped in a catch-all rescue at its own top level — catching any exception
class, logging it with the same `schema_name`/sweep-op tagging as the capacity-skip and
timeout-skip cases, and returning an ordinary value (e.g. `:ok` or `:skipped`) rather
than letting the exception reach `Task.async_stream/3`'s own supervision. This rescue is
added at the NEW `Task.async_stream/3` call sites specifically, one per sweep — it does
NOT replace or duplicate `with_admission/3`'s own existing `after`-based release
guarantee (that stays exactly as-is; admission release must still happen whether or not
the wrapped op raised), and it does NOT contradict the existing moduledoc comment that
`Scheduler.poll_and_fire/1`'s own contract already guarantees it never raises — this new
rescue is a second, independent safety net specifically because `Task.async_stream/3`'s
failure blast radius (the whole concurrent batch) is categorically larger than
`Enum.each/2`'s ever was (only the rest of that one serial loop), so relying solely on a
callee's own non-raising contract is a materially bigger bet than it was before this
fix. Four of the seven sweeps already wrap their op call in an inline `try/rescue ->
:ok` today (`maybe_run_alert_detection/3`, `maybe_run_ordering_cycle/1`,
`maybe_run_ordering_sweeper/1`, `maybe_run_ordering_metrics/1`) — for these, the
existing inline rescue already provides this property and does not need a second,
redundant one; the two that do NOT currently have one (the poll-and-fire loop's
`Scheduler.poll_and_fire/1` call, and `maybe_run_retention_sweep/2`'s
`Scheduler.run_retention_sweep/1` call) need one added at their `Task.async_stream/3`
call site as part of this fix. `count_active_for_schema/1` (used by
`maybe_refresh_active_instances/1`) already has its own rescue too.

### 4c. Net effect on AC1

With `max_concurrency` > 1 (both 8 and 2 qualify), several tenants' tasks are in flight
together; a slow tenant occupies only one of those N concurrency slots while the
scheduler keeps admitting new tenants into the remaining slots until `schemas` is
exhausted. Combined with `on_timeout: :kill_task` (bounds how long the slow slot stays
occupied) and the per-task rescue (bounds the blast radius of an outright crash to that
one task's result), no single tenant's slow or erroring call can prevent any other
tenant's call, in the same sweep, from starting or completing. This is a strictly
weaker guarantee than "no tenant is ever delayed at all" (a slot is still finite — the
`ceil(tenant_count / max_concurrency)`-th tenant in submission order still waits behind
one full batch), but it is the concrete, boundable property AC1 asks for, and it is a
strict improvement over today's fully serial behavior where a single hung tenant blocks
literally every tenant after it, in every one of the seven sweeps, for the rest of that
tick.

## 5. Preserving the single `tenant_schemas/0` query per tick (AC4)

Unchanged. `fetch_tenant_schemas/0` is still called exactly once per `handle_info(:tick,
state)` invocation, at the same call site it is today (inside the `case
fetch_tenant_schemas() do {:ok, schemas} -> ... end` clause), and the resulting
`schemas` list is still threaded, by reference, as a plain function argument into all
seven sweeps unchanged — none of them, concurrent or not, call `tenant_schemas/0` or
`Repo.all/1` again. Converting a sweep's internal iteration from `Enum.each/2` to
`Task.async_stream/3` does not change how many times its caller (`handle_info/2`)
computes or passes `schemas` — it only changes how the already-computed list is walked.
No new call site queries `Letflow.TenantProvisioning.Registration` or any other source
of the tenant schema list.

## 6. Interaction with REQ-219 / ISS-0451 (crash-loop isolation, circuit breaker)

Orthogonal, no changes needed to `lib/letflow/supervisor/pollers.ex`,
`pollers_breaker.ex`, or `application.ex`. Specifically:

- REQ-219's `max_restarts: 5, max_seconds: 60` override on
  `Letflow.Supervisor.Pollers`, and ISS-0451's `PollersBreaker` open/half-open/closed
  state machine, both key off the Poller `GenServer` process itself crashing (an
  unhandled exit reaching its supervisor). This design's per-task rescue (§4b) and
  `on_timeout: :kill_task` (§4a) together mean that a persistent per-tenant fault — the
  exact scenario those two mechanisms exist to contain — no longer reaches
  `handle_info/2` as an unhandled raise at all for the fault classes this design covers
  (a single tenant's op raising or hanging). That fault is now caught and logged inside
  the task, and the tick proceeds normally for every other tenant and every other sweep.
  This makes the Poller process itself less likely to hit REQ-219/ISS-0451's
  restart-intensity path for these specific fault classes than it was before — a
  reduction in how often that machinery is exercised, not a change to it.
- This does NOT make the restart-intensity override or the breaker redundant. The
  forced-crash test seam (`@poller_test_hooks_enabled?` / `force_poller_crash`, REQ-219
  §"addition") is untouched — it raises unconditionally as the FIRST expression of
  `handle_info/2`, before `fetch_tenant_schemas/0` or any sweep runs, so it is
  structurally outside anything this design changes. Any OTHER cause of the Poller
  process itself crashing (a bug in `handle_info/2`'s own control flow, an exception
  raised by `fetch_tenant_schemas/0`'s own rescue re-raising — it does not, but
  hypothetically — `schedule_next_tick/0`, or any future addition to this module) still
  hits REQ-219's restart-intensity override and, on a persistent fault, ISS-0451's
  breaker, exactly as today. The two mechanisms operate at different layers (process
  crash/restart vs. in-tick task fault containment) and remain both necessary: this
  design narrows what CAN reach the process-crash layer from inside a tick, it does not
  replace that layer.

## 7. Summary of required code-shape changes (for ELIXIR-DEV — no code given here)

- `Letflow.Scheduler`: add one new config accessor, `sweep_task_timeout_ms/0`, following
  the exact existing pattern of `poll_interval_ms/0`/`jitter_ms/0` (reads `config
  :letflow, :scheduler, sweep_task_timeout_ms:`, falls back to a `@default_...` module
  attribute of `10_000`, read fresh on every call — no caching).
- `Letflow.Scheduler.Poller`: at each of the seven per-schema iteration sites currently
  written as `Enum.each(schemas, fn schema_name -> ... end)`, replace the traversal with
  `Task.async_stream/3` over `schemas`, options `max_concurrency:` (8 for the six
  Admission-gated sweeps, 2 for `maybe_refresh_active_instances/1`), `timeout:
  Scheduler.sweep_task_timeout_ms()`, `on_timeout: :kill_task`, `zip_input_on_exit:
  true`; fully consume the resulting stream; wrap the two call sites lacking an existing
  inline rescue (the poll-and-fire loop, `maybe_run_retention_sweep/2`) in a top-level
  per-task rescue per §4b; log `{:exit, _}` yields (both timeout and crash) at
  `Logger.warning/2` tagged with `schema:` and `op:`, mirroring the existing
  `with_admission/3` capacity-skip log.
- No change to `with_admission/3` itself, to `Letflow.Admission`, to any
  `lib/letflow/supervisor/*` file, or to `application.ex`.
- No change to how `schemas` is computed or how many times it is computed per tick.

## 8. Open questions (explicitly not resolved here)

- §4a's `sweep_task_timeout_ms` default (10 s) vs. `poll_interval_ms`'s default (5 s)
  ordering — flagged, not silently decided; recommendation given (treat as independent
  budgets) but REVIEWER should confirm.
- §3b's `reserved_headroom` (2) being a single shared allowance for every
  non-admission-gated Repo consumer platform-wide, with no current inventory of who else
  draws on it besides this design's `maybe_refresh_active_instances/1` bound — flagged,
  not resolved; revisit if such an inventory is ever produced or if `N = 2` is observed
  to be too tight in practice.
- Whether `Task.Supervisor` (an explicit, named, supervised task pool, following
  `Letflow.SandboxPool`'s own precedent of never leaving `Task.await/2`-style blocking
  calls implicit) should back these `Task.async_stream/3` calls instead of the bare,
  unnamed pool `Task.async_stream/3` uses by default. This design does not require one:
  unlike `SandboxPool`, nothing here needs a task to outlive the calling process or to
  be observable/killable from outside the calling `handle_info/2` invocation — every
  task's lifetime is already bounded by `timeout:`/`on_timeout: :kill_task`, and the
  calling process (`Letflow.Scheduler.Poller`) blocks on `Task.async_stream/3` until it
  drains, so there is no async-orphan risk of the kind ISS-0224 fixed in `SandboxPool`.
  Flagged so REVIEWER can confirm this reasoning holds rather than assuming it silently.
