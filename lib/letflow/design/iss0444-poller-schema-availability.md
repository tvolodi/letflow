# ISS-0444 — Make `Scheduler.poll_and_fire/1`'s "never raises" contract true, close the identical retention-sweep gap

Design for a fix to `lib/letflow/scheduler.ex` (and, per §4, `run_retention_sweep/1`
in the same module). No R-Co analogue — this is new resilience work, not a port. No
implementation code below — signatures, `@spec`/`@type` shapes, and prose only.

## 0. Inputs read in full before this design (confirmed, not assumed)

* `handoffs/WF03-ISS0444-20260903/step-01-issue-fixer-diagnosis.json` — ISSUE-FIXER's
  diagnosis, including a real reproduction: `Scheduler.claim_due_timer_ids("nonexistent_schema_xyz_999",
  10)` raises `%Postgrex.Error{postgres: %{code: :undefined_table}}` against the real
  test Postgres instance.
* `lib/letflow/scheduler.ex` (current state, read in full) —
  * `poll_and_fire/1`'s own `@doc`: *"Never raises — every per-timer failure is
    caught internally and folded into the returned counts (design §2.2, §2.5)."*
    Its body calls `claim_due_timer_ids(tenant_schema, max_timers_per_cycle())` as
    its **first** statement, unguarded, then `Enum.reduce/3`s over the returned ids
    calling `attempt_fire/2`, which already has its own outer `try/rescue` (confirmed
    at `attempt_fire/2`'s body: `try do fire_timer(...) rescue exception -> {:error,
    {:raised, exception}} end`) plus `safe_record_fire_failure/2`'s own second-layer
    rescue. So every failure mode **after** a successful claim is already isolated —
    only the claim step itself (`claim_due_timer_ids/2`) has no boundary.
  * `claim_due_timer_ids/2`'s current `@spec`: `(tenant_schema :: String.t(), limit
    :: pos_integer()) :: [Ecto.UUID.t()]`. Body: builds an Ecto query, `Repo.all(query,
    prefix: tenant_schema)`, no `try`/`rescue`. Called directly (not only via
    `poll_and_fire/1`) by `test/letflow/scheduler_test.exs:578-579`, which asserts
    `length(Scheduler.claim_due_timer_ids(schema_name, N)) == N` — this call site
    expects a plain list back, not a tuple. `claim_due_timer_ids/2` carries **no**
    "never raises" doc claim of its own — only `poll_and_fire/1` does.
  * `poll_result()` type: `%{tenant_schema: String.t(), claimed: non_neg_integer(),
    fired: non_neg_integer(), errored: non_neg_integer(), exhausted: non_neg_integer()}`.
    No existing field or variant represents "this schema could not be queried at
    all." Confirmed (grepping `test/letflow/scheduler_test.exs` and
    `scheduler_req188_test.exs`) that every existing test reads this map by field
    access (`result.claimed`, `result.fired`, ...), never by whole-map equality or
    `Map.keys/1` — so **adding** a new field is additive and does not break any
    existing assertion.
  * `run_retention_sweep/1`: `@spec (tenant_schema :: String.t()) :: {:ok,
    EventStore.archive_result()} | {:error, term()}`. Body: a one-line delegation,
    `EventStore.archive(prefix: tenant_schema, retention_days: retention_days())`,
    no `try`/`rescue` of its own. Unlike `poll_and_fire/1`, this function's own
    `@doc` makes **no** "never raises" claim — but its `@spec` already advertises an
    `{:error, term()}` outcome as part of its ordinary contract, which is the
    natural place to fold a caught schema-unavailable failure into, with **no type
    change needed** (see §4).
* `lib/letflow/event_store.ex` — `archive/1`'s `@spec` already includes
  `{:error, term()}` in its return type (in addition to `{:error,
  :missing_retention_days}` / `{:error, :invalid_schema_name}`), and its body itself
  has no `try`/`rescue` around `compute_archive_target_event_ids/2` (the first
  Repo-touching call after the two `with`-guarded checks) or the phase-1/phase-2
  archive steps. So the identical `:undefined_table` raise is reachable through
  `archive/1` too, for the reasons ISSUE-FIXER traced (§4 here re-derives blast
  radius, does not merely repeat it).
* `lib/letflow/scheduler/poller.ex` (current state, read in full) — the moduledoc
  states explicitly: *"A raise inside one tenant schema's
  `Letflow.Scheduler.poll_and_fire/1` call is not additionally guarded here — that
  function's own contract (design §2.2) already guarantees it never raises, so a
  second, redundant `try/rescue` around the `Enum.each` below would duplicate an
  already-established isolation boundary for no additional safety property."* This
  is the architectural statement the current code violates — confirming ISSUE-FIXER's
  framing that the gap must close **inside `Letflow.Scheduler`**, not by adding a
  redundant `poller.ex` call-site rescue that this moduledoc already declined to add
  (and whose reasoning remains correct once the fix below lands — see §5).
  `with_admission/3`'s own comment: *"`fun` is responsible for its OWN existing
  rescue boundary, if any; this wrapper adds admission accounting only, never a
  rescue of its own."* `maybe_run_retention_sweep/2` wraps
  `Scheduler.run_retention_sweep(schema_name)` in `with_admission/3` with **no**
  local `rescue` (unlike `maybe_run_alert_detection/3` /
  `maybe_run_ordering_*` , each of which has its own `rescue _ -> :ok` around its
  named call) — confirming ISSUE-FIXER's finding that retention sits in the same
  unguarded position `poll_and_fire/1` was in before this fix.
* `lib/letflow/engine/pin_rebind.ex:372-390` — `lock_projection_nowait/2`'s own
  narrow rescue, the closest existing precedent for "rescue one specific Postgres
  error code, re-raise everything else": its `rescue` clause matches `error in
  Postgrex.Error`, then tests via `match?/2` whether the error's `postgres.code` is
  specifically `:lock_not_available` — if so, it resolves to `{:error,
  {:concurrent_modification, instance_id}}`; for any other `Postgrex.Error` code
  (or, by the same `rescue`-clause type-matching semantics, any other exception
  type, which would not match this clause at all), it re-raises the original
  exception with its original stacktrace via `reraise/2` rather than swallowing it.
  This is a **narrower** pattern than `maybe_run_alert_detection/3`'s bare `rescue _
  -> :ok` (which matches every exception class). §1 below adopts this same narrow
  shape for this defect.
* `lib/letflow/tenant_provisioning/backfill.ex:37-49` — `Backfill.run/1`'s
  `Enum.reduce_while/3` loop: on `{:error, :tenant_schema_missing}` (identical
  underlying condition — a `Registration` row whose physical schema no longer
  exists), logs via `Logger.warning/1` with a **single interpolated string**
  argument only (`"ISS-0343 backfill: tenant #{tenant_id}'s Registration row exists
  but its physical schema no longer exists ..., skipping"`) — no second, keyword-list
  metadata argument.
* `lib/letflow/obs/alerts.ex:585-593` — `resolve_auth_header/1`'s `with`-`else`
  fallback: `Logger.warning("alert hook auth_secret_ref resolution failed, sending
  without Authorization", component: "alert_delivery", ref: ref)` — a short message
  string **plus** a keyword-list metadata argument (`component:`/`ref:`).
* `lib/letflow/scheduler/poller.ex`'s own `with_admission/3` (REQ-218, this same
  cycle) already chose, for the structurally closest in-repo precedent (a capacity
  skip naming a schema and an operation): `Logger.warning("poller admission capacity
  exhausted, skipping schema/operation", schema: schema_name, op: op)` — message
  string **plus** keyword metadata, i.e. the `alerts.ex:588` shape, not the
  `backfill.ex:37` shape. This is the closer precedent for THIS fix specifically,
  because it is (a) in the same file this fix also touches (`poller.ex` is
  unaffected in code but its own established local convention for
  schema-plus-context logging is a live signal for the sibling module `scheduler.ex`
  emits into the same log stream), and (b) already keying on the exact
  `schema_name` value this fix also has in scope. §3 below adopts this shape.

## 1. Decision — rescue boundary lives inside `claim_due_timer_ids/2`, not `poll_and_fire/1`, and not `poller.ex`

**Placement:** the `try/rescue` is added around `claim_due_timer_ids/2`'s existing
`Repo.all(query, prefix: tenant_schema)` call, inside `claim_due_timer_ids/2` itself
— not by wrapping `poll_and_fire/1`'s call to it, and not at the `poller.ex` call
site.

**Why not `poller.ex`'s call site (the pattern the other five `maybe_run_*` sweeps
use):** ISSUE-FIXER's own diagnosis already establishes the reason correctly and
this design re-confirms it directly against source rather than taking it on faith:
`poller.ex`'s moduledoc makes an explicit architectural claim that `poll_and_fire/1`
carries its OWN never-raises contract, precisely so `poller.ex` does **not** need a
redundant per-operation rescue for this one call (unlike the other five sweeps,
whose callees — `Letflow.Obs.Alerts`, `Letflow.Ordering` — carry no such contract of
their own). Patching only `poller.ex` would leave `poll_and_fire/1`'s own `@doc`
claim false for every other caller — direct test calls
(`scheduler_test.exs`/`scheduler_req188_test.exs` call `Scheduler.poll_and_fire/1`
directly, never through `Poller`), a future HTTP admin endpoint, a future manual
"replay this tenant's timers" tool — anything that isn't `Poller`. A call-site-only
fix would be cosmetic: it stops today's ONE crash path without making the
documented claim source-of-truth, which is exactly the "sign the design step was
skipped in substance" failure mode this project's gates exist to catch.

**Why `claim_due_timer_ids/2` and not `poll_and_fire/1`'s own body:** `claim_due_timer_ids/2`
is the single function that actually performs the Repo call that can raise
`:undefined_table` — no other statement in `poll_and_fire/1`'s body touches the
database before `attempt_fire/2` (already self-rescuing) runs. Placing the rescue at
the exact site of the risky I/O, rather than one level up, is also this codebase's
own established idiom: `lock_projection_nowait/2` (pin_rebind.ex) rescues around its
own `repo.one(query, ...)` call, not around its caller; `fetch_tenant_schemas/0`
(poller.ex) rescues around its own `tenant_schemas()` call, not around
`handle_info/2`. Rescuing one level up in `poll_and_fire/1` instead would work
functionally but would misattribute the isolation boundary to the wrong function in
a way this codebase's own precedent does not do — every existing per-call rescue in
this file and its siblings sits at the call that can actually fail.

**Effect on `claim_due_timer_ids/2`'s public contract:** returns the SAME type,
`[Ecto.UUID.t()]`, unchanged — the `@spec` is not widened to a tuple. On a
`:undefined_table`/`:undefined_schema` `Postgrex.Error`, it returns `[]` (an empty
list is the type's own existing valid "no due timers claimed" value, and is not
observably different in TYPE from any other tick that happens to find zero due
timers — see §2 for how `poll_and_fire/1` still surfaces the DISTINCTION to its own
caller/logs despite this). This choice is what keeps
`test/letflow/scheduler_test.exs:578-579`'s existing `length(Scheduler.claim_due_timer_ids(schema_name,
N)) == N` assertions passing unmodified (a tuple-returning `claim_due_timer_ids/2`
would break both call sites and their `length/1` usage) — preserving all existing
test coverage is an explicit requirement of this fix.

**Exact rescue clause — narrow, matching `pin_rebind.ex`'s precedent, not
`maybe_run_alert_detection/3`'s bare `rescue _`:** the function gains a `rescue`
clause matching specifically `error in Postgrex.Error`, whose body then tests
whether `error.postgres.code` is one of `:undefined_table` / `:undefined_schema`
(via a `match?/2` guard against the `%Postgrex.Error{postgres: %{code: code}}`
shape, mirroring `pin_rebind.ex`'s own literal structure) — when it is, the clause
resolves to `[]` (after the logging call in §3); when the caught error is a
`Postgrex.Error` with any OTHER code, or any other exception type entirely (neither
matches this `rescue` pattern and would propagate unrescued, per Elixir's own
`rescue`/type-matching semantics), the clause instead re-raises the original
exception with its original stacktrace preserved (`reraise/2`), exactly as
`pin_rebind.ex`'s own precedent does for any Postgres error code other than the one
it specifically targets.

Placed around exactly the one line `Repo.all(query, prefix: tenant_schema)` inside
`claim_due_timer_ids/2` — nothing else in that function is inside the `rescue`'s
scope (the query-building pipeline above it cannot raise a `Postgrex.Error`, it is
pure `Ecto.Query` composition with no I/O).

**Why narrow (both error codes, re-raise everything else) and not a bare `rescue _`:**
this is a DB-schema-availability check, not a "swallow anything from this
operation" boundary the way `maybe_run_alert_detection/3`'s bare rescue is (that
callee, `Letflow.Obs.Alerts`, carries no contract of its own and is deliberately
insulated wholesale). A bare `rescue _` here would also silently swallow a
genuinely-different bug — e.g. a query built with a malformed `limit`, a
`FunctionClauseError` from a future refactor, a real `:undefined_column` from a
migration drift — folding all of those into "zero due timers claimed" with no
distinguishing log line, which would make a real regression indistinguishable from
routine empty-poll ticks. Matching BOTH `:undefined_table` and `:undefined_schema`
(not just the one code ISSUE-FIXER's repro actually observed) is deliberate:
ISSUE-FIXER's own diagnosis notes Postgres reports the whole-schema-missing case as
`42P01`/`:undefined_table` on the fully-qualified relation name (confirmed by the
literal repro), but the issue's own filed text names both `undefined_table` and
`undefined_schema` as one observed error shape — matching both codes future-proofs
against a Postgres/Postgrex version where a schema-qualified reference to a
genuinely absent SCHEMA (as opposed to a present schema missing one table) surfaces
distinctly, without widening the match to anything else.

**Note on `moduledoc` staleness (per the task's item 5):** `poller.ex`'s moduledoc
statement that `poll_and_fire/1`'s own contract already guarantees no-raise, and
that this is WHY no redundant `try/rescue` sits around the `Enum.each`, does **not**
need updating by this fix — that statement was already true in *intent* and becomes
true in *fact* once this design lands; the architecture it describes (poller.ex
trusts a real contract) is exactly what this fix restores, not something it changes.
No edit to `poller.ex` is needed or made by this design.

## 2. `poll_result()` — decision: reuse the existing all-zero shape, no new field

**Decision: `poll_result()`'s `@type` is UNCHANGED.** A schema-unavailable tick
reports `%{tenant_schema: tenant_schema, claimed: 0, fired: 0, errored: 0,
exhausted: 0}` — numerically identical to a tick that legitimately finds zero due
timers for a present, healthy schema. The only externally-visible signal
distinguishing the two cases is the one `Logger.warning/1` line (§3), emitted once,
at the true source of the failure (`claim_due_timer_ids/2`'s own rescue clause),
regardless of which caller reached it.

**Why this satisfies the "no existing outcome covers this" observation without
inventing a new type slot:** `claimed`/`fired`/`errored`/`exhausted` are all
counts of timer-level outcomes (per `poll_and_fire/1`'s own doc: "per-timer failure
... folded into the returned counts"). A schema-unavailable tick has ZERO timers to
count outcomes for — there is no timer-level event that occurred and needs a slot.
"Zero due timers found" and "schema unavailable, nothing could be attempted" are
both, correctly, "zero timer-level outcomes occurred this tick for this schema" —
collapsing them to the same numeric shape is not a loss of information a caller
needs, it is an accurate description of both situations at the granularity
`poll_result()` was designed to report at.

**Two alternatives considered and rejected:**

1. **A new `poll_result()` field, e.g. `schema_available: boolean()`.** Rejected:
   distinguishing "zero because nothing was due" from "zero because the schema
   couldn't be queried" at the STRUCT level would require `poll_and_fire/1` to
   learn this fact from `claim_due_timer_ids/2` without a second Repo round-trip
   (an extra existence-check query purely to re-derive what the rescue already
   knows would double DB load for the common, healthy-schema case) — the only way
   to pass that signal back without widening `claim_due_timer_ids/2`'s own return
   type to a tuple (rejected below) is an inter-call side channel (e.g. the process
   dictionary), which has no precedent anywhere in this codebase and is a
   meaningfully riskier mechanism than the value it buys, since no acceptance
   criterion in ISS-0444's own text or the Step-1 diagnosis requires a
   machine-readable `poll_result()` distinction — only that the tick not crash and
   that the skip be observable (which the log line already provides).
2. **A distinct `{:error, :schema_unavailable}` top-level return instead of a map.**
   Rejected: `poll_and_fire/1`'s `@spec` return type is currently unconditionally
   `poll_result()` (never a tagged tuple), and every existing caller
   (`Poller.handle_info/2`, every test) pattern-matches or field-accesses a bare
   map, never a tuple — changing the TOP-LEVEL shape to sometimes-a-tuple is
   exactly the kind of "preserves all existing test coverage" violation the task
   explicitly rules out, for no benefit the log line does not already provide.

**`poll_and_fire/1`'s body is unchanged** beyond the effect of §1's fix already
propagating through it: it calls `claim_due_timer_ids/2` exactly as today, gets
`[]` back instead of a raise when the schema is unavailable, and its existing
`Enum.reduce/3` over an empty list naturally produces the existing all-zero
`poll_result()` — no new branch, no new field, no new logic is added to
`poll_and_fire/1` itself. All of this fix's code changes are localized to
`claim_due_timer_ids/2` (§1) and, for the retention half, `run_retention_sweep/1`
(§4).

## 3. `Logger.warning/1` call shape

Matching `lib/letflow/scheduler/poller.ex`'s own `with_admission/3` precedent (§0),
itself modeled on `alerts.ex:588`'s message-plus-keyword-metadata shape (the closer
match of the two precedents named in the task brief — see §0's side-by-side): a
single `Logger.warning/2` call, whose first argument is the plain message string
`"scheduler: tenant schema unavailable, skipping timer poll for this tick"`, and
whose second argument is a keyword list carrying two metadata keys — `schema:`,
bound to the `tenant_schema` value already in scope at the rescue site, and
`reason:`, bound to the atom `:schema_unavailable`.

Placed as the last statement inside `claim_due_timer_ids/2`'s rescue clause (§1),
immediately before returning `[]` — i.e. the rescue clause becomes: match the
narrow `Postgrex.Error` pattern, log once, return `[]`; anything else re-raises
unchanged with no log line (a re-raised, genuinely-unexpected error should surface
through this codebase's normal crash/supervision path, not be silently logged and
swallowed).

`require Logger` must be added to `Letflow.Scheduler`'s module head (not currently
present — confirmed by grep; `scheduler.ex` has no existing `Logger` usage) as part
of this fix.

**Why `warning` and not `error`:** matches this codebase's own established
convention (`alerts.ex:201`/`:534` reserve `Logger.error` for actual delivery
failure/exhaustion; a schema-unavailable skip-and-continue is an expected,
recoverable operational condition, the same class `backfill.ex:37-49` and
`alerts.ex:588` already both log at `warning`).

## 4. Scope — fix `run_retention_sweep/1` too, in this same design

**Decision: IN SCOPE.** The identical defect class applies with no additional
complexity, per the task's own steer ("lean toward fixing both if the SAME rescue
pattern genuinely applies to both call sites with no additional complexity"):

* `run_retention_sweep/1`'s `@spec` ALREADY includes `{:error, term()}` as a valid
  return (§0) — unlike `claim_due_timer_ids/2`, no type widening is needed at all
  here; catching the raise and returning `{:error, {:schema_unavailable,
  tenant_schema}}` (or an equally-shaped tuple — exact reason term left to
  ELIXIR-DEV, no acceptance criterion constrains its literal shape) is a
  same-type, same-arity fix.
* The reachable path is `run_retention_sweep/1` → `EventStore.archive/1` →
  `compute_archive_target_event_ids/2` (first Repo-touching call after the two
  `with`-guarded checks in `archive/1`'s body, §0) — the SAME `Postgrex.Error`
  `:undefined_table`/`:undefined_schema` shape, for the SAME underlying reason
  (querying a `prefix:` schema that does not physically exist).
* **Rescue placement:** inside `Letflow.Scheduler.run_retention_sweep/1` itself
  (this module, matching §1's "fix at the function whose own contract needs to
  hold" reasoning) — NOT inside `EventStore.archive/1`. `archive/1` is a
  general-purpose context function with several OTHER callers/contexts implied by
  its own moduledoc (per-event-type retention policies, idempotent re-invocation);
  widening ITS rescue behavior is a larger, less-scoped change than
  `run_retention_sweep/1` (the one function REQ-188's Poller integration actually
  calls) catching the same narrow error at its own call site: `run_retention_sweep/1`'s
  existing body (the single delegating call to `EventStore.archive/1`) gains the
  identical shape of `rescue` clause specified in §1 for `claim_due_timer_ids/2` —
  matching `error in Postgrex.Error`, testing `postgres.code` against
  `[:undefined_table, :undefined_schema]` via the same `match?/2` guard shape, and
  on a match: emitting the §3 `Logger.warning/1` call (with `run_retention_sweep/1`'s
  own message text, "skipping retention sweep for this tick" rather than "skipping
  timer poll," but the same `schema:`/`reason:` metadata keys) and then resolving
  to `{:error, {:schema_unavailable, tenant_schema}}` instead of `[]` (matching this
  function's own existing `{:error, term()}` branch already in its `@spec`, §0); on
  any non-matching `Postgrex.Error` code or any other exception type, re-raising via
  `reraise/2` exactly as §1 does. Same narrow match, same log shape (§3), as
  `claim_due_timer_ids/2`'s — deliberate consistency, not independent invention.
* **Not "additional complexity" because:** no new type, no new `poll_result()`-style
  field decision is needed (unlike §2's genuinely nuanced call for the timer-poll
  path) — `run_retention_sweep/1`'s `{:error, term()}` branch already exists in its
  `@spec` and its ONLY current caller, `maybe_run_retention_sweep/2` in `poller.ex`,
  already discards the return value entirely (`Enum.each(schemas, fn schema_name ->
  with_admission(schema_name, :retention_sweep, fn -> Scheduler.run_retention_sweep(schema_name)
  end) end)` — the block's result is unused), so returning `{:error, {:schema_unavailable,
  _}}` instead of raising requires ZERO changes to `poller.ex` for this fix to take
  effect there; the crash simply stops happening.
* **Not filing a second issue:** per the task's framing, filing a fresh issue for a
  defect ISSUE-FIXER has already fully traced (root cause, exact call chain, exact
  error shape, exact fix shape — all confirmed in §0 of this design against current
  source, not merely repeated from the diagnosis) would itself risk violating "No
  Issue Left Local-Only" in spirit: the cost of fixing it now (one small, symmetric
  rescue clause reusing an ALREADY-EXISTING `{:error, term()}` branch) is lower than
  the cost of writing, triaging, and later re-diagnosing a new issue for something
  already understood down to the exact code. This design therefore does not create
  a new `docs/issues/ISS-####.yaml` entry.

**Retention-specific test-coverage note (for TEST-DESIGNER, not resolved here):**
retention defaults to disabled (`@default_retention_enabled false`) — a regression
test for this half of the fix must explicitly enable retention
(`Application.put_env(:letflow, :scheduler, retention_enabled: true, ...)`) and
either use a `retention_due?/1` value that is due, or call
`Scheduler.run_retention_sweep/1` directly (bypassing `Poller`'s own
enabled/due gating) the same way `scheduler_test.exs` already calls
`claim_due_timer_ids/2` directly — direct-call testing is the lower-friction option
and does not require touching `Poller`'s own state machine at all.

## 5. Interaction with REQ-218's admission wiring — none

`with_admission/3` (REQ-218, `poller.ex`) wraps `Scheduler.poll_and_fire(schema_name)`
and `Scheduler.run_retention_sweep(schema_name)` calls with an admission
acquire/`after`-release pair, and is explicitly documented as adding "admission
accounting only, never a rescue of its own" — this fix changes NOTHING about
`with_admission/3`, `Letflow.Admission`, or either call's position inside it. Both
fixed functions still return a bare value (`poll_result()`, entirely unchanged per
§2; `{:ok, _} | {:error, _}` for `run_retention_sweep/1`, already its declared
type) exactly where `with_admission/3`'s wrapped `fun.()` already expects a return
value — no signature change reaches `poller.ex` at all. `with_admission/3`'s
`after`-release fires unconditionally as it always has, since neither fixed
function raises past it any longer.

## 6. Test approach (for TEST-DESIGNER — not implemented here)

* **Fail-first repro (WF-03 Step 4's own requirement):** on the pre-fix branch,
  `Scheduler.claim_due_timer_ids("some_syntactically_valid_but_never_provisioned_schema",
  10)` raises `Postgrex.Error`; `Scheduler.poll_and_fire/1` called with the same
  schema string also raises (propagating from `claim_due_timer_ids/2`). Construct
  the schema string so it passes `TenantProvisioning.tenant_id_for_schema_name/1`'s
  format regex (a syntactically valid tenant-schema-shaped string) but has NO
  physical `CREATE SCHEMA` ever run for it — ISSUE-FIXER's own diagnosis already
  flags this exact fixture gap (no existing test constructs a schema-shaped string
  that was never provisioned; every existing fixture is sandboxed-and-present).
* **Post-fix, timer-poll path:** the same call returns `[]` (`claim_due_timer_ids/2`)
  / a `poll_result()` map with all-zero counters (`poll_and_fire/1`) instead of
  raising; one `Logger.warning/1` line is emitted (assert via `ExUnit.CaptureLog`).
* **Post-fix, retention path:** with retention explicitly enabled (§4's note),
  `Scheduler.run_retention_sweep/1` against the same never-provisioned schema string
  returns `{:error, {:schema_unavailable, _}}` instead of raising; one
  `Logger.warning/1` line is emitted.
* **Blast-radius / tick-survives test (the actual production symptom):** drive
  `Letflow.Scheduler.Poller.handle_info(:tick, state)` directly (this test file's
  own established pattern, §0) over a schema list containing BOTH a real, sandboxed,
  provisioned schema with a genuinely due timer AND the never-provisioned schema
  string, in either order (assert both orderings, since `Enum.each/2`'s abort-on-raise
  behavior pre-fix would only be exercised by ONE ordering — the never-provisioned
  schema sorting before the real one — and this fix must be shown correct
  regardless of `tenant_schemas()`'s row ordering, not simply the ordering that
  happened to reproduce the bug). Assert: `handle_info/2` returns normally (no
  raise escapes it), the real schema's due timer actually fires (its own `TIMER_FIRED`
  event exists / its own row's `status` is `"fired"`), and the `Poller` process
  itself is never crashed/restarted (if driven via `start_supervised!(Poller)`
  rather than a direct `handle_info/2` call — TEST-DESIGNER's choice which harness
  to use, per this file's own existing mixed convention, §0 of req218's design).
* **No regression to existing coverage:** `scheduler_test.exs:570-580`'s
  `claim_due_timer_ids/2` `length/1` assertions, and every existing `poll_and_fire/1`
  field-access assertion, must continue to pass unmodified (§1/§2's own design
  choices are constructed specifically so this holds).
* **Mutation-testing discipline (per WF-03 Step 4):** since this fix ADDS a rescue
  clause to an existing function rather than a brand-new module, the "does not
  exist yet" carve-out does not apply — the pre-fix code already exists and simply
  lacks the rescue, so the ordinary fail-then-pass rule (not the mutation-testing
  alternative for brand-new modules) governs here: run the new test against the
  actual pre-fix commit, confirm it fails with the real `Postgrex.Error`, then
  confirm it passes on the fix commit.

## 7. Open questions

* **Q1 (§2) — `poll_result()` left unchanged (no new field).** This design's firm
  decision is: no new field, the schema-unavailable case reuses the existing
  all-zero shape, and the `Logger.warning/1` line is the sole distinguishing
  signal. This handoff did not carry a separate formal `task.acceptance_criteria`
  array beyond the Step-1 diagnosis's own framing of "what a fix needs to change" —
  if ORCH/CODE-DESIGN-VALIDATOR holds a formal acceptance-criteria list for
  ISS-0444 that explicitly requires a machine-readable `poll_result()` signal
  distinct from "zero timers due," flag back to this design rather than having
  ELIXIR-DEV invent one unreviewed; §2 documents why the two alternatives that
  would provide one (a new field via a process-dictionary hand-off, or a tagged-
  tuple return) were both rejected, and that reasoning would need to be
  specifically overridden, not silently worked around.
* **Q2 (§4) — exact reason-term shape for `run_retention_sweep/1`'s `{:error, _}`.**
  `{:error, {:schema_unavailable, tenant_schema}}` is this design's suggested shape
  (symmetric with `poll_result()`'s conceptual "schema unavailable" outcome even
  though §2 recommends not encoding it as a field there); ELIXIR-DEV may choose an
  equally-clear equivalent since no existing caller inspects `run_retention_sweep/1`'s
  return value today (§4) and no acceptance criterion fixes the literal shape.
* **Q3 (§1) — matching both `:undefined_table` and `:undefined_schema`** is based on
  the issue's own filed text naming both as one observed shape; ISSUE-FIXER's
  actual reproduction observed only `:undefined_table`. If REVIEWER judges matching
  a code that has never been directly observed in this codebase's own Postgrex
  version to be unwarranted speculation rather than reasonable future-proofing,
  narrowing the match to `:undefined_table` alone is a one-line change with no
  other design impact.
