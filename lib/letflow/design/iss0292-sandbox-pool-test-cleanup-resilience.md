# Design: ISS-0292 — resilient cleanup helpers in `sandbox_pool_test.exs`

**Run:** WF03-ISS0292-20260823 (GH#585, queue task 292) · **Author:** CODE-DESIGNER ·
**Status:** Passes 1–3 below (§0–§8) are REJECTED — see `handoffs/escalations.yaml`
run_id `WF03-ISS0292-20260823`, `escalated_at: 2026-08-23T08:05:46Z`, for the full
CODE-DESIGN-VALIDATOR findings. Kept verbatim, not deleted, per the post-escalation
restart's own instruction that prior findings stay readable. **§9 below ("Pass 4 —
post-escalation restart") is the current, superseding design.** Do not implement §0–§8;
implement §9.

**Scope: TEST CODE ONLY.** Every change in this design lands in
`test/letflow/sandbox_pool_test.exs`. No `lib/` file, no migration, no `config/*.exs` is
touched — verified below (§0.2) rather than assumed.

---

## 0. Sources read

- `docs/agents/instructions/core-directives.md`, `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1, `docs/anti-patterns.md`.
- `test/letflow/sandbox_pool_test.exs` in full for the RT-9 async-provisioning describe block
  (`:480-620`), the file moduledoc (`:1-92`), and every call site of `query_without_holding/1`,
  `sandbox_schema_names/0`, `drop_sandbox_schemas_created_since!/1`.
- `test/support/tenant_schema_reaper.ex` in full — this repo's established
  "attempt-everything, rescue-and-continue-per-item, report once" pattern (`reclaim_row/1` /
  `sweep_orphans/2`). Reused below rather than inventing a new shape.
- `lib/letflow/sandbox_pool.ex:80-310` — `provision_timeout_ms/0`, `claim_call_timeout/1`,
  `release_call_timeout/0`, and their derivations. No `statement_timeout` / `lock_timeout` /
  connection-level timeout is set anywhere in `lib/letflow/`.
- `config/test.exs` in full — no `parameters:` entry sets a Postgres-side `statement_timeout`;
  the only `parameters:` key is `application_name` (ISS-0110/ISS-0217).
- `docs/issues/ISS-0220.yaml` (resolution_note) — the "measure, don't guess", "floor = worst
  legitimate observation, ceiling = ExUnit's per-test default, separation >= one worst
  observation" derivation discipline this design follows in §2.

### 0.1 Confirms this is TEST CODE ONLY, not a `lib/` defect

`query_without_holding/1`'s `Repo.query!` calls pass no `:timeout` option, so they run under
**Postgrex's own client-side default (15 000 ms)** — a library default, not something
`lib/letflow/sandbox_pool.ex` sets or influences. `SandboxPool.provision_timeout_ms/0` /
`release_call_timeout/0` bound the `GenServer.call/3` the *test* makes to the pool; they do not
reach the pool's own `Repo.query!`/`Ecto.Migrator.run/4` calls either, and are architecturally
separate from the plain `Repo.query!` calls this file's cleanup helpers issue directly (not
through `SandboxPool` at all — `sandbox_schema_names/0` and the DROP loop talk to Postgres
directly, bypassing the pool). No `statement_timeout`/`lock_timeout` GUC is set anywhere in
`lib/` or `config/`. The defect is entirely in how this **test file's own helpers** react to a
cancelled query, and in the DROP loop's control flow — nothing here motivates a `lib/` change.

### 0.2 No pattern already fits before reusing `TenantSchemaReaper`'s shape

`TenantSchemaReaper.reclaim_row/1` (test/support/tenant_schema_reaper.ex:228-242) is the
established "must attempt every item even if one fails" shape in this suite: a `rescue` around
the per-item body, returning `true`/`false` (never raising), logged, with the caller
(`sweep_orphans/2`) accumulating counts and never aborting the loop on one item's failure. That
shape is reused directly in §3 below rather than invented fresh. It has no retry (a reap is
naturally retried by the *next* sweep), which is why §2 below adds retry semantics on top of it
rather than copying it verbatim — this file's helpers have no "next sweep"; each `on_exit`/inline
call is a one-shot cleanup for one test.

---

## 1. The defect, restated precisely

1. `query_without_holding/1` (`:513-531`) runs `fun.()` in a bare `spawn_monitor`, no `rescue`.
   A `Repo.query!` that raises `Postgrex.Error{postgres: %{code: :query_canceled}}` (or any other
   Postgrex/DBConnection error) crashes the spawned process; the `:DOWN` branch turns that into
   `flunk/1`, which raises in the **caller's** process.
2. `sandbox_schema_names/0` (`:537-546`) and `drop_sandbox_schemas_created_since!/1`
   (`:552-560`) both call `Repo.query!` with no `:timeout` opt through `query_without_holding/1`
   — same exposure, inherited.
3. `drop_sandbox_schemas_created_since!/1`'s `for schema_name <- MapSet.difference(...) do
   query_without_holding(...) end` has no per-iteration rescue. One `flunk` raised inside the
   loop body (from item 1/2 above) propagates straight out of the whole `for`, so every schema
   ordered after the failing one in that diff set is **never attempted** — the RT-8 orphan leak.
   `for` gives no atomicity here; Postgres gives none either (each DROP is issued as its own
   separate `Repo.query!`, not inside a shared transaction).

---

## 2. Timeout: value and derivation

**New per-attempt Postgrex `:timeout`, `cleanup_query_timeout_ms/0`, returns
`SandboxPool.provision_timeout_ms/0`'s value (default `44_000`).**

No fresh multi-run timing sample exists for these specific metadata queries (`SELECT ...
information_schema.schemata`, `DROP SCHEMA ... CASCADE`) under CPU-throttled CI — stated
honestly rather than inventing one, per `core-directives.md`'s "No Speculation". The design
instead **reuses an already-measured, already-derived budget** rather than picking a new
un-derived number, for two independent reasons:

- It is provably generous for this workload. `provision_timeout_ms/0`'s `44_000` was sized
  (ISS-0220) as a *floor above the worst observed full sandbox provisioning* — `CREATE SCHEMA`
  plus 31 tenant-scoped migrations, ~150 round trips, worst observed 15 373 ms. A single
  `information_schema` `SELECT` or a single `DROP SCHEMA ... CASCADE` is one round trip, not
  ~150; a budget sized for the 150-round-trip case cannot be tight for the 1-round-trip case.
- It cannot silently drift out of sync with the pool's own budget the way a hand-picked literal
  would (matches this file's own stated philosophy at `:71-73`/`:84-86`: "Kept as a separate,
  visibly small constant rather than folded into the budget precisely so it can never quietly
  become a second un-derived provisioning allowance" / "derived from the pool's own public
  call-timeout derivation rather than hand-picked").

**Retry semantics: rescue `Postgrex.Error` and `DBConnection.ConnectionError`, retry the SAME
query exactly once with the SAME timeout, then propagate (do not swallow) if the retry also
raises.** One retry, not unbounded, because a query that fails twice at 44 000 ms each is
evidence of something genuinely stuck (lock contention, a dead connection), not transient
CPU-scheduling jitter — exactly the "retry-once-then-flunk only for genuinely stuck operations"
shape ISSUE-FIXER's diagnosis calls for.

**New outer rendezvous bound for these two attempts, `cleanup_query_rendezvous_timeout/0`,
independent of the existing `pool_op_rendezvous_timeout/0`:**

```
cleanup_query_rendezvous_timeout() = 2 * cleanup_query_timeout_ms() + @rendezvous_slack_ms
```

Default: `2 * 44_000 + 1_000 = 89_000` ms. **This value IS substituted into
`query_without_holding/1`'s own `receive ... after` bound, but only for the two cleanup call
sites this design touches** — see §3.1/§3.2 for the mechanism (a new optional second argument)
and §3.2 for the closed-gap arithmetic that replaces OQ-1 below. Every other call site in this
file (`SandboxPool` `GenServer` rendezvous at `:761`, `:828`, ... `:1178`) is unaffected: it keeps
calling the 1-arg form, which defaults to the unchanged `pool_op_rendezvous_timeout/0`.

**`pool_op_rendezvous_timeout/0` (`:90-92`) is UNCHANGED** — it governs `release/2` `GenServer`
rendezvous elsewhere in this file (`:761`, `:828`, ... `:1178`) and has no relationship to the
raw-SQL cleanup queries this design covers. Conflating the two was never the actual defect and
is not touched.

---

## 3. Exact helper changes

### 3.0 `query_without_holding/1` gains an optional second argument — the OQ-1 resolution

```
@spec query_without_holding(fun :: (-> term()), rendezvous_timeout_ms :: pos_integer()) :: term()
```

`query_without_holding/1` (spawn/monitor/`receive ... after`, `:513-531`) is extended to
`query_without_holding/2` with a default: `def query_without_holding(fun, rendezvous_timeout_ms
\\ pool_op_rendezvous_timeout())`. The `receive ... after` bound (currently the hardcoded
`pool_op_rendezvous_timeout()`) becomes `rendezvous_timeout_ms`. Every existing call site in this
file — all the `SandboxPool` `GenServer`-rendezvous ones (`:761`, `:828`, ... `:1178`) — keeps
calling the 1-arg form and is therefore byte-for-byte unaffected: same default, same behavior,
same value. This is the one real signature change this design introduces, and it is confined to
adding a defaulted argument, not altering any existing call site.

The two cleanup call sites (§3.1, §3.2) are the only callers that pass the second argument
explicitly, and they pass `cleanup_query_rendezvous_timeout()` (§2, `89_000` ms default) instead
of the default. This directly resolves OQ-1: the outer rendezvous window at those two call sites
is now derived *from* the inner retry budget (`2 * cleanup_query_timeout_ms() +
@rendezvous_slack_ms`) rather than being an unrelated fixed value the inner budget could
outgrow. Direction (a) from the rework request — shrinking `cleanup_query_timeout_ms()` itself to
fit under the unchanged `pool_op_rendezvous_timeout()` — was rejected: it would have meant
walking back §2's already-reviewed "reuse `provision_timeout_ms()`, don't hand-pick a number"
derivation, which the rework request explicitly said to leave as-is. Widening the outer bound
only for the two call sites that need it keeps §2's timeout value untouched and keeps every other
call site's behavior identical, at the cost of the one small, explicit signature change named
above — which is exactly the tradeoff CODE-DESIGN-VALIDATOR's option (b) called for.

**Closed-gap arithmetic (replaces the OQ-1 gap):**

```
worst-case inner total  = 2 * cleanup_query_timeout_ms()          = 2 * 44_000 = 88_000 ms
outer rendezvous bound   = cleanup_query_rendezvous_timeout()      = 88_000 + 1_000 = 89_000 ms
margin                   = outer bound - worst-case inner total    = 1_000 ms  (> 0)
```

Because the outer bound (`89_000`) is now strictly greater than the worst-case inner total
(`88_000`) by the full `@rendezvous_slack_ms` (`1_000` ms — the same slack constant §2 already
defined), the outer `receive ... after` at these two call sites cannot fire while
`resilient_cleanup_query!/2` or `resilient_drop_schema/1` still has legitimate retry budget
remaining, in any scenario — including the pathological one OQ-1 named, where both the initial
attempt and the retry individually consume their full `44_000` ms before failing. The spawned
process always has strictly more time to reply than it can possibly need.

### 3.1 `resilient_cleanup_query!/2` — new private helper, the shared retry primitive

```
@spec resilient_cleanup_query!(sql :: String.t(), params :: list()) :: Postgrex.Result.t()
```

Runs `Repo.query!(sql, params, timeout: cleanup_query_timeout_ms())`. On
`Postgrex.Error`/`DBConnection.ConnectionError`: log a warning (`Logger.warning/1`, same style as
`TenantSchemaReaper`) naming the SQL and the error, then retry once with the identical call. If
the retry also raises, **let it raise** (no second rescue) — this is what makes
`query_without_holding/1`'s existing `:DOWN` → `flunk` path fire for a genuinely-stuck query,
satisfying "must still flunk loudly if truly stuck." Always runs inside the existing
`query_without_holding/1` wrapper (unchanged contract: spawn, monitor, relay-or-flunk) — this
function only changes what happens *before* a crash would occur, not how a crash is reported.

Used by `sandbox_schema_names/0` in place of its bare `Repo.query!` call, called as
`query_without_holding(fn -> resilient_cleanup_query!(sql, params) end,
cleanup_query_rendezvous_timeout())` — the explicit second argument from §3.0. No other change to
that function; its `@spec`/return shape (`MapSet.t(String.t())`) is unchanged.

### 3.2 `resilient_drop_schema/1` — new private helper, never raises

```
@spec resilient_drop_schema(schema_name :: String.t()) :: :ok | {:error, term()}
```

Attempts `Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE), [], timeout:
cleanup_query_timeout_ms())`. On `Postgrex.Error`/`DBConnection.ConnectionError`: log a warning
and retry once, identically to §3.1. **Unlike §3.1, the retry's failure is also rescued** — it is
converted to `{:error, exception}` and *returned*, never raised. This is the deliberate
difference from §3.1: `resilient_cleanup_query!/2` still needs to be able to fail loudly (it has
no loop around it to continue), while `resilient_drop_schema/1`'s caller (§3.3) is the one place
in this file whose whole reason for existing is to keep going after one item's exhausted retries.

Called from inside `query_without_holding/2` (§3.0) as `query_without_holding(fn ->
resilient_drop_schema(schema_name) end, cleanup_query_rendezvous_timeout())` — **not** the bare
1-arg form. Because `resilient_drop_schema/1` never raises, the spawned process always reaches
its normal `send(test_pid, {ref, fun.()})` line regardless of which bound is in effect; the
explicit `cleanup_query_rendezvous_timeout()` argument matters for the pathological case where
both attempts individually consume their full `cleanup_query_timeout_ms()` budget before
failing — §3.0's arithmetic shows the outer bound (`89_000` ms) stays strictly above that
worst-case inner total (`88_000` ms) by the full `1_000` ms slack, so the `:DOWN`/`flunk` branch
cannot fire before `resilient_drop_schema/1` has had its fair chance to return on its own terms.
**Load-bearing note for ELIXIR-DEV:** `pool_op_rendezvous_timeout/0`'s own value is NOT raised —
only this one call site's second argument changes, per §3.0.

### 3.3 `sandbox_schema_names/0` — one-line body change

Unchanged signature and return shape (`MapSet.t(String.t())`). Its `Repo.query!(...)` call is
replaced with `resilient_cleanup_query!(...)` (§3.1), same SQL, same call wrapped in the same
`query_without_holding/1`. A genuinely-stuck listing still flunks (§3.1's "let it raise"), which
is correct here: there is no loop to protect, and an unreadable schema list is a real blocker for
whatever assertion or diff computation the caller was about to do.

### 3.4 `drop_sandbox_schemas_created_since!/1` — restructured to attempt every schema

```
@spec drop_sandbox_schemas_created_since!(baseline :: MapSet.t(String.t())) :: :ok
```

Signature and return type unchanged. Body restructured from the current `for ... do
query_without_holding(...) end` (which discards each result and aborts on the first crash) to an
accumulating reduce, matching `TenantSchemaReaper.sweep_orphans/2`'s shape (§0.2):

- Compute `schemas_to_drop = MapSet.difference(sandbox_schema_names(), baseline)` (unchanged —
  still one call, still via §3.1's now-resilient path).
- For every schema name in that set, call `query_without_holding(fn ->
  resilient_drop_schema(schema_name) end)` (§3.2) and **accumulate a list of `{schema_name,
  reason}` pairs for the ones that returned `{:error, reason}`** — the loop does not stop, does
  not raise, and does not short-circuit on any one iteration's failure. Every schema in the diff
  set is attempted exactly once (i.e. `resilient_drop_schema/1`'s own internal retry is the only
  retry a schema gets — the outer loop itself does not re-attempt a schema a second time in a
  second pass, so total attempts per schema is capped at 2, not unbounded).
- After the full pass: if the accumulated failure list is non-empty, `flunk/1` **once**, with a
  message naming every still-undropped schema and its last error — the single loud, final report
  ISSUE-FIXER's diagnosis asks for. If empty, return `:ok` exactly as today.

This is the change that closes the RT-8 gap: a cancelled/interrupted DROP for schema N no longer
prevents schemas N+1..last in the same diff set from being attempted.

### 3.5 `@moduletag timeout:` — closing the ExUnit-per-test-budget gap (3rd rework pass)

**Confirmed directly (not just from the validator's citation):** `test/letflow/sandbox_pool_test.exs`
has no `@moduletag timeout` and no `@tag timeout` anywhere in the file (grepped `:1-1200`, zero
hits), and its `use Letflow.DataCase, async: false` (`:52`) does not set one either (grepped
`test/support/data_case.ex`, zero hits) — so every test in this module currently runs under
ExUnit's built-in default of **60_000 ms**. `sandbox_schema_names/0` and
`drop_sandbox_schemas_created_since!/1` are called inline in test bodies throughout this file (not
only from `on_exit`), so raising the outer rendezvous bound at those two call sites to
`cleanup_query_rendezvous_timeout()` (`89_000` ms, §2/§3.0) is unsafe on its own: ExUnit's
per-test-process timeout supervisor can kill the test at 60_000 ms — well before either
`query_without_holding/2`'s own `89_000 ms after` clause or the retry logic inside it ever gets a
chance to finish — which is a *different* failure mode than the flunk-and-report path this design
builds (§3.1-§3.4), and can itself abort the accumulate-and-continue loop mid-pass, a new variant
of the very RT-8 leak this design exists to close.

**Fix: add one module-wide `@moduletag timeout: 120_000` (120 000 ms) directly below the existing
`use Letflow.DataCase, async: false` (`:52`).**

Module-wide, not per-`@tag`, because: (a) the validator's own line citations
(`:717, :763, :775, :879, :886, :904, :946, :961, :992, :1009, :1037`) show call sites spread
across at least eight distinct tests, several of which the design does not otherwise touch --
tagging each individually is both more edit surface and easier to miss one on a future addition;
(b) confirmed above that no test in this file already carries a tighter or looser `@tag timeout`
that a module-wide default would silently override -- there is nothing to clobber; (c) every test
in this module already shares one `async: false` characteristic and one `setup` (Sandbox `:auto`
mode, `:57-60`), so a shared timeout policy is consistent with how the file already treats the
whole module as one unit, not per-test.

**Value derivation, generous rather than tight (this is the terminal rework attempt, so slack is
intentionally large rather than shaved to the arithmetic minimum):**

```
worst-case single call to query_without_holding/2 (cleanup call sites) = 89_000 ms  (§2)
a single test could plausibly make more than one such call, or combine
  one with other unrelated waits already in the test body (validator's
  citation shows call sites are not isolated -- "often alongside other
  waits in the same test")
chosen @moduletag timeout                                              = 120_000 ms
margin over one worst-case cleanup call                                = 120_000 - 89_000 = 31_000 ms (>34% headroom)
```

`120_000` ms is chosen over a tighter value (e.g. `90_000`) specifically because: it clears the
single worst-case `89_000` ms call by a full `31_000` ms -- more than a third of that call's own
budget -- leaving room for the other, unrelated setup/assert/rendezvous work most test bodies also
do before or after the cleanup call, without requiring a per-test audit of exactly how much of
each test's 60_000 ms default was already being spent on non-cleanup work. It does not need to be
tight: the only reason a `@moduletag timeout` exists here is to guarantee ExUnit's own test-kill
supervisor can never fire before `query_without_holding/2`'s internal `89_000 ms after` bound gets
its chance, and a round, generous number is strictly safer for that goal than a number picked close
to the minimum. `120_000` ms is not tied to any other named constant in this file (deliberately --
it is ExUnit's outermost safety margin, not part of the retry/rendezvous arithmetic chain in §2/§3.0,
so it does not need to track `provision_timeout_ms/0` the way `cleanup_query_timeout_ms/0` does).

This closes the gap raised in CODE-DESIGN-VALIDATOR's 2nd-pass review. Combined with §2 (base
timeout), §3.0 (outer rendezvous bound), and §3.4 (loop shape), this design has now been reviewed
and corrected across all three of CODE-DESIGN-VALIDATOR's review passes; this is the terminal
iteration addressing all three. No further widening of §2's base value, no further change to the
loop shape, and no further change to OQ-2's out-of-scope status is intended or open.

---

## 4. What is explicitly unchanged

- `query_without_holding/1`'s spawn/monitor mechanics and its `:DOWN` → `flunk` branch —
  untouched. Its signature gains one *defaulted* second argument (§3.0); every existing call site
  keeps calling the 1-arg form and observes identical behavior. It remains the generic "run this
  0-arity fun without holding a checkout" wrapper; §3.1/§3.2 change what the `fun` arguments
  passed to it do (and, only for those two call sites, what rendezvous bound applies), not the
  wrapper's spawn/monitor/report mechanics.
- `pool_op_rendezvous_timeout/0` and `claim_rendezvous_timeout/1` (`:84-92`) — value unchanged,
  used only for `SandboxPool` `GenServer` rendezvous elsewhere in the file and as
  `query_without_holding/2`'s default, not passed explicitly by the cleanup helpers.
- Every other test case, every `on_exit(fn -> drop_schema!(...) end)` single-schema call site
  (`:201`, `:227`, ... `:458`) — `drop_schema!/1` is a distinct, unrelated helper (not grepped
  above as in scope; confirm at implementation time it is a different function before assuming
  this design covers it — see OQ-2).
- No `lib/letflow/` file, no `priv/repo/migrations/*`, no `config/*.exs` (§0.1).

---

## 5. Invariants

- **INV-T1 — every schema in a `drop_sandbox_schemas_created_since!/1` diff set is attempted
  exactly once**, regardless of any other schema's outcome in the same call. This is the
  property RT-8 violated and the one this design exists to establish.
- **INV-T2 — a genuinely-stuck cleanup query (both attempts exhausted) is never silently
  swallowed.** `sandbox_schema_names/0` still flunks directly (§3.3); the DROP loop still flunks,
  once, naming every unresolved schema (§3.4). No path returns `:ok`/a clean `MapSet` while
  hiding a real failure.
- **INV-T3 — no test-observable behavior changes on the success path.** Every existing assertion
  in this file that calls `sandbox_schema_names/0` or relies on
  `drop_sandbox_schemas_created_since!/1`'s `on_exit` cleanup sees identical results when no
  Postgres error occurs (the overwhelming common case) — the retry/rescue paths are additive and
  only ever engage after a real Postgrex/DBConnection error.

---

## 6. Files touched

| File | Change | Owner |
|---|---|---|
| `test/letflow/sandbox_pool_test.exs` | Add `cleanup_query_timeout_ms/0`, `cleanup_query_rendezvous_timeout/0`, `resilient_cleanup_query!/2`, `resilient_drop_schema/1` (§2, §3.1, §3.2); extend `query_without_holding/1` to `query_without_holding/2` with a defaulted second argument (§3.0); rewrite `sandbox_schema_names/0`'s body (§3.3) and `drop_sandbox_schemas_created_since!/1`'s body (§3.4); add `@moduletag timeout: 120_000` below `use Letflow.DataCase, async: false` at `:52` (§3.5) | ELIXIR-DEV (or TEST-DESIGNER, per whichever role this WF-03 run assigns test-file edits to) |

No other file.

---

## 7. Open questions

**OQ-1 — RESOLVED (was: the `2 * 44_000 = 88_000` vs `pool_op_rendezvous_timeout() = 45_000`
worst-case gap).** Closed by §3.0: `query_without_holding/1` gains a defaulted second argument,
and the two cleanup call sites (§3.1, §3.2) pass `cleanup_query_rendezvous_timeout()` (`89_000`
ms) explicitly instead of relying on the default `pool_op_rendezvous_timeout()` (`45_000` ms).
§3.0's arithmetic shows the outer bound now exceeds the worst-case inner total (`88_000` ms) by
the full `1_000` ms slack, so the outer `receive ... after` cannot fire while either helper still
has legitimate retry budget left, in any scenario — including the pathological one this OQ named.
No option left for ELIXIR-DEV to silently pick; §3.0 is prescriptive.

**OQ-2 — `drop_schema!/1`, the single-schema `on_exit` helper used at `:201` etc., was not read
in full and is NOT covered by this design.** It may share the same unguarded-`Repo.query!` /
no-`:timeout` exposure described in §1; if so it is the same defect in a different call site,
scoped out here because ISS-0292's filing and ISSUE-FIXER's diagnosis named only
`query_without_holding/1`, `sandbox_schema_names/0`, and `drop_sandbox_schemas_created_since!/1`.
Flagged as a candidate follow-up issue rather than silently expanded into this one's scope.

**OQ-3 — RESOLVED (was: no `@moduletag timeout` coverage, so ExUnit's 60_000 ms default could
kill a test before the new `89_000` ms outer rendezvous bound from §3.0 ever fires — raised by
CODE-DESIGN-VALIDATOR's 2nd-pass review).** Closed by §3.5: one module-wide
`@moduletag timeout: 120_000` added directly below `use Letflow.DataCase, async: false` (`:52`).
Confirmed by direct grep of both this file and `Letflow.DataCase` that no existing `@tag
timeout`/`@moduletag timeout` is present to conflict with or be overridden by this addition.
`120_000` ms clears the worst-case single cleanup call (`89_000` ms, §2/§3.0) by `31_000` ms of
margin, chosen generously rather than tightly because this is the terminal rework attempt (3 of 3)
for ISS-0292. This closes out all three of CODE-DESIGN-VALIDATOR's review passes; no further
arithmetic gap in this chain is anticipated.

---

## 8. Acceptance-criteria traceability

| Item from the task | Design element |
|---|---|
| Exact signatures/changes for `query_without_holding/1`, `sandbox_schema_names/0`, `drop_sandbox_schemas_created_since!/1` | §3 (§3.3, §3.4); `query_without_holding/1` gains one defaulted second argument, `query_without_holding/2` (§3.0) — every existing call site is unaffected — with two new helper functions (§3.1, §3.2) it now wraps |
| The `:timeout` value and justification | §2 — reuses `SandboxPool.provision_timeout_ms()` (44 000 ms default), justified by the round-trip-count argument, not a fresh guess |
| Exact retry/rescue semantics | §3.1 (retry-once-then-raise) and §3.2 (retry-once-then-return-`{:error,_}`) — deliberately different, and the difference is explained |
| Loop-continuation structure and final report | §3.4 — accumulate-and-continue, one final `flunk/1` naming every undropped schema |
| Explicit test-only scope statement | §0.1, and the top-of-file banner |
| Check for an existing "resilient cleanup" pattern to reuse | §0.2 — `TenantSchemaReaper.reclaim_row/1`/`sweep_orphans/2`, reused as the model for §3.4 |
| No implementation code in the design | Every code-shaped block above is a `@spec`, a named-constant formula, or a paste-in-place comment string — no `.ex` function body is written |
| ExUnit per-test-timeout budget does not kill a test before the new outer rendezvous bound fires | §3.5 / OQ-3 — module-wide `@moduletag timeout: 120_000`, derived with `31_000` ms margin above the worst-case `89_000` ms cleanup call |

---

## 9. Pass 4 (post-escalation restart) — SUPERSEDES §0–§8

**Run:** WF03-ISS0292-20260823, restart after `max_rework` (3/3) escalation ·
**Source of the mandated approach:** `handoffs/WF03-ISS0292-20260823/step-02-code-designer.json`
`task.description`, itself a synthesis of escalation options (a)/(c) — see
`handoffs/escalations.yaml` `run_id: WF03-ISS0292-20260823`, `next_step` (a), (b), (c).
**Status:** proposed — awaiting CODE-DESIGN-VALIDATOR.

### 9.0 Why passes 1–3 are rejected, restated in one sentence each

- **Pass 1** (§2–§3, `cleanup_query_timeout_ms() = 44_000`, retry-once, no outer-bound
  change): the retry-once total (`88_000` ms) could exceed the *unwidened*
  `pool_op_rendezvous_timeout()` (`45_000` ms) it still ran inside, so the outer
  `receive…after` could fire and `flunk` mid-retry — reproducing the exact orphan-leak
  defect the fix exists to close (OQ-1).
- **Pass 2** (§3.0, `query_without_holding/2`, `cleanup_query_rendezvous_timeout() =
  89_000`): fixed OQ-1 by widening the *outer* bound at the two cleanup call sites to
  `89_000` ms — but that now exceeded ExUnit's untouched **default 60_000 ms per-test
  timeout** (no `@moduletag`/`@tag timeout` existed anywhere in this file), so ExUnit's
  own test-kill supervisor could fire before the widened inner bound ever got a chance
  (OQ-3, found by CODE-DESIGN-VALIDATOR's 2nd pass).
- **Pass 3** (§3.5, `@moduletag timeout: 120_000`): fixed OQ-3 for a *single* worst-case
  cleanup call (`120_000 - 89_000 = 31_000` ms margin) — but RT-1..RT-5 call the
  cleanup helpers (or their internals: baseline `sandbox_schema_names/0`, final
  `sandbox_schema_names/0`, `on_exit`'s `drop_sandbox_schemas_created_since!/1` — which
  itself calls `sandbox_schema_names/0` again plus one `query_without_holding` per
  orphaned schema) **more than once per test body**. Two genuinely-stuck calls alone
  (`2 * 89_000 = 178_000` ms) exceed the `120_000` ms module timeout — the margin was
  derived against a single-call worst case, not this file's actual multi-call-per-test
  pattern.

Escalation verdict (`handoffs/escalations.yaml`, `diagnosis`): each pass's fix
introduced a new timing-budget gap **one layer further out** than the one it closed
(retry budget → outer rendezvous bound → ExUnit per-test timeout → per-test call
count). **Pass 4 does not add a fourth layer.** It fits the retry entirely inside the
one budget that was never the problem — the existing, unmodified
`pool_op_rendezvous_timeout()` (`45_000` ms) — and changes nothing outside
`sandbox_pool_test.exs`'s function bodies. No new named timeout constant is
introduced at all; the retry reuses Postgrex's own unconfigured client-side default,
exactly as today's code already implicitly does.

### 9.1 The one structural difference from passes 1–3

Passes 1–3 all added a **second, explicit timeout argument to `query_without_holding/1`**
(making it `/2`) so the *outer* rendezvous bound could be widened for the two cleanup
call sites. Pass 4 does **not** touch `query_without_holding/1` at all — no new arity,
no new argument, no new constant governing it. Instead, the retry loop runs entirely
**inside the 0-arity `fun` that is already passed into the existing, unmodified
`spawn_monitor`** (`:517`). From `query_without_holding/1`'s point of view nothing
changes: it still spawns one process, still waits on the same unmodified
`pool_op_rendezvous_timeout()` (`45_000` ms today), still relays a normal return or
turns a crash into `flunk`. The retry is invisible to it — which is exactly why this
approach cannot repeat the pass-1/pass-2 failure mode: there is no second outer bound
to keep in sync with a growing inner one, because the inner one now fits inside the
bound that was already there.

### 9.2 New helper: `retry_query_once/1` — the shared retry primitive

```
@spec retry_query_once(fun :: (-> term())) :: term()
```

Calls `fun.()`. On `Postgrex.Error` or `DBConnection.ConnectionError`: log a warning
(`Logger.warning/1`, same message shape as `TenantSchemaReaper.reclaim_row/1`,
`test/support/tenant_schema_reaper.ex:233-241` — naming the error and what was being
attempted), then call `fun.()` again — **the identical call, unchanged, with no
`:timeout` option added or overridden anywhere in this design**. If the second attempt
also raises, **let it propagate un-rescued** (no second `rescue`). Placed as a private
function alongside `query_without_holding/1` (`:513` area), used only from inside `fun`
arguments passed to `query_without_holding/1` — never called standalone, never wraps
`query_without_holding/1` itself.

This is the entire retry mechanism. There is no `cleanup_query_timeout_ms/0`, no
`cleanup_query_rendezvous_timeout/0`, no `@rendezvous_slack_ms`-derived constant added
for it (contrast passes 1–3's §2) — because neither `Repo.query!` call this design
touches (`sandbox_schema_names/0`'s `SELECT`, the DROP loop's `DROP SCHEMA … CASCADE`)
passes a `:timeout` option today, so both attempts of a retried call keep running under
**Postgrex's own unconfigured client-side default (`15_000` ms)** — literally the same
timeout behavior these two queries already have today, just possibly invoked twice
instead of once.

### 9.3 `sandbox_schema_names/0` — one-line body change, unchanged wrapper

```
@spec sandbox_schema_names() :: MapSet.t(String.t())
```

Signature and return shape unchanged (`:537-546`). Its inner `Repo.query!(...)` call
(the `SELECT … information_schema.schemata …`) is passed as the `fun` argument to
`retry_query_once/1` (§9.2) instead of being called directly; `retry_query_once/1`'s
result (the raw `Repo.query!` result) then flows into the same row-to-`MapSet`
conversion the function does today, unchanged. The surrounding
`query_without_holding(fn -> ... end)` wrapper is called exactly as today — **1-arg,
no second argument, no changed default** (`:538`).

If `retry_query_once/1` exhausts its one retry and still raises, that exception now
crashes the spawned process exactly as the current unrescued `Repo.query!` call
already does — `query_without_holding/1`'s existing `:DOWN` → `flunk` branch
(`:524-525`) is completely unmodified and still fires. This is deliberate: there is no
loop around `sandbox_schema_names/0` to protect, so a genuinely-stuck schema listing
must still flunk loudly, exactly per acceptance criterion "still surfaces as a real,
loud test failure."

### 9.4 New helper: `resilient_drop_schema/1` — never raises, used only by the DROP loop

```
@spec resilient_drop_schema(schema_name :: String.t()) :: :ok | {:error, Exception.t()}
```

Calls `retry_query_once/1` (§9.2) with a `fun` that issues the same
`DROP SCHEMA IF EXISTS "..." CASCADE` query the current code already issues for
`schema_name`. Adds exactly one `rescue` clause around that call, sitting *outside*
`retry_query_once/1` — i.e. `retry_query_once/1` itself is unchanged/shared and
unaware of this wrapper. On success, returns `:ok`. On the rescued exception (meaning
`retry_query_once/1`'s own retry was already exhausted), logs a warning naming
`schema_name` and the exception — same message shape as
`TenantSchemaReaper.reclaim_row/1` — and returns `{:error, exception}` instead of
letting the exception propagate.

This is the one place this design's shape diverges deliberately from
`retry_query_once/1`'s "let the second failure propagate" contract, for the same
reason pass 3's `resilient_drop_schema/1` (§3.2 above) diverged from its own
`resilient_cleanup_query!/2`: **this function's caller is a loop whose entire purpose
is to keep going after one item's exhausted retries** (§9.5), so its exhausted-retry
outcome must be a normal return value, not a crash. The added `rescue` layer matches
`TenantSchemaReaper.reclaim_row/1`'s exact shape (`repo.query!(...)` calls inside a
`def`, one `rescue` at the bottom, `Logger.warning` + a non-raising return, never
raises to the caller — `test/support/tenant_schema_reaper.ex:228-242`) rather than
inventing a new one.

Called as `query_without_holding(fn -> resilient_drop_schema(schema_name) end)` —
again 1-arg, unmodified. Because `resilient_drop_schema/1` never raises, the spawned
process always reaches its normal `send(test_pid, {ref, fun.()})` line
(`query_without_holding/1:517`) regardless of outcome; the unmodified `45_000` ms
outer bound is never at risk of firing on the exhausted-retry *success* path (it only
returns `{:error, _}`, it doesn't hang).

### 9.5 `drop_sandbox_schemas_created_since!/1` — attempt every schema, one combined report

```
@spec drop_sandbox_schemas_created_since!(baseline :: MapSet.t(String.t())) :: :ok
```

Signature and return type unchanged (`:552`). Body restructured from the current
`for schema_name <- MapSet.difference(...) do query_without_holding(...) end` (which
discards each result and aborts the whole `for` on the first crash — the RT-8 defect)
to an accumulating fold over `schemas_to_drop = MapSet.difference(sandbox_schema_names(),
baseline)` (unchanged computation, now benefiting from §9.3's retry transparently),
matching `TenantSchemaReaper.sweep_orphans/2`'s own accumulate-and-continue shape
(`test/support/tenant_schema_reaper.ex:146-163`) rather than inventing a new one:

- Walk every schema name in `schemas_to_drop` once, calling
  `query_without_holding(fn -> resilient_drop_schema(schema_name) end)` for each and
  accumulating a `{schema_name, reason}` pair into a failure list wherever the call
  returns `{:error, reason}`; a `:ok` result contributes nothing to the accumulator.
  The walk never stops and never raises mid-pass on any one iteration's outcome —
  the fold's accumulator is what carries state forward, not a raised exception.
- Every schema in `schemas_to_drop` is attempted **exactly once** by this walk (each
  attempt internally may retry once, per §9.2/§9.4 — so at most 2 raw `DROP` attempts
  per schema, never unbounded, never a second pass over the same schema).
- After the full pass, if the accumulated failure list is non-empty, raise **one**
  `flunk/1` naming every still-undropped schema and its last error — the single loud
  final report, closing acceptance criterion "genuinely-stuck schema... still surfaces
  as a real, loud test failure — not silently swallowed." If the list is empty, return
  `:ok` exactly as today.

This is the change that closes the RT-8 gap: a cancelled/interrupted DROP for schema N
no longer prevents schemas N+1..last in the same diff set from being attempted —
closing acceptance criterion (c), the critical one.

### 9.6 Arithmetic: the retry fits inside the existing, unwidened outer bound

**Every constant named below is read from the current source, not re-derived or
hand-picked:**

```
lib/letflow/sandbox_pool.ex:145   @default_provision_timeout_ms 44_000
lib/letflow/sandbox_pool.ex:264   release_call_timeout() = provision_timeout_ms()      = 44_000 ms (default)
test/letflow/sandbox_pool_test.exs:74   @rendezvous_slack_ms 1_000
test/letflow/sandbox_pool_test.exs:90-92
  pool_op_rendezvous_timeout() = release_call_timeout() + @rendezvous_slack_ms
                                = 44_000 + 1_000 = 45_000 ms   <- UNCHANGED by this design
```

**Per-attempt cost.** Neither `Repo.query!` call this design touches passes a
`:timeout` option (confirmed: `sandbox_schema_names/0`'s `SELECT`, `:539-543`; the
DROP loop's `Repo.query!`, `:555`) — both already run, today, under Postgrex's own
unconfigured client-side default. That default is `15_000` ms (Postgrex's documented
default for `Postgrex.query/4`'s `:timeout` option when the caller supplies none).
This design introduces no new timeout value here — retry #2 uses the exact same
un-overridden call as attempt #1.

```
worst-case retry_query_once/1 total  = attempt 1 + attempt 2
                                      = 15_000 + 15_000 = 30_000 ms
existing outer bound (unwidened)     = pool_op_rendezvous_timeout() = 45_000 ms
margin                               = 45_000 - 30_000 = 15_000 ms  (33% headroom)
```

Because `30_000 ms < 45_000 ms` with `15_000` ms of margin to spare, the unmodified
`query_without_holding/1`'s `after pool_op_rendezvous_timeout() -> … flunk(...)` branch
(`:526-529`) cannot fire while `retry_query_once/1` still has legitimate retry budget
remaining — including the pathological case where *both* attempts individually consume
the full `15_000` ms Postgrex default before failing. No constant anywhere in this
chain (`provision_timeout_ms/0`, `release_call_timeout/0`, `@rendezvous_slack_ms`,
`pool_op_rendezvous_timeout/0`) changes value. This is the property that makes this
design immune to the three-layer stacking failure passes 1–3 hit: there is only one
budget in play (the pre-existing `45_000` ms outer bound), the retry is sized to fit
strictly inside it with margin, and nothing about it depends on how many times a given
test body happens to call these helpers — each individual call is still bounded by the
same unmodified `45_000` ms it always was, worst case now `30_000` ms of that consumed
by an actual retry instead of near-zero.

**No `@moduletag timeout` is added, and ExUnit's default (60_000 ms) per-test timeout
is untouched** — required by this task's acceptance criteria, and consistent with 9.7's
residual-risk note below, which explains why that omission is deliberate rather than
an oversight.

### 9.7 Residual risk, stated explicitly rather than silently resolved (per this design's own no-speculation rule)

This design does **not** attempt to prove that an arbitrarily large number of
simultaneous retry-consuming calls within one test body can never approach ExUnit's
`60_000` ms default (e.g. three sequential `sandbox_schema_names/0` calls in one RT-1
body — baseline, final, and `on_exit`'s internal diff call — each independently hitting
its own worst-case `30_000` ms retry total would sum past `60_000` ms). This is an
explicit, named departure from passes 1–3's approach (which tried to size an
ever-widening outer budget against exactly this compounding scenario, and failed three
times because the budget it needed kept moving).

Pass 4 does not chase that budget for two stated reasons, not asserted as fact but
given here for CODE-DESIGN-VALIDATOR to weigh:

1. **The compounding event is a rare event compounding on itself.** A single
   `query_canceled`/connection error on one of these two queries has zero recurrence
   across the last 5 CI runs on `main` (cited in this task's acceptance criterion (a),
   already established by ISSUE-FIXER's Step 1 diagnosis and not re-litigated here).
   For the scenario in this section to actually threaten the `60_000` ms default, two
   or more *independent* calls within the *same* test body would need to hit that
   already-rare error *and* have their retry also fail — a compounding of independently
   rare events, not a realistic steady-state CI hazard.
2. **This task's own acceptance criteria forbid the mitigation passes 1–3 used.** "No
   new or widened `@moduletag` timeout, no change to ExUnit's default per-test timeout"
   is a hard constraint from `step-02-code-designer.json`'s `task.acceptance_criteria`,
   not a gap left unnoticed — closing this residual risk the way passes 1–3 tried to
   (an outer timeout widened to cover the compounding case) is explicitly out of
   bounds for this restart.

If CODE-DESIGN-VALIDATOR or a later run judges this residual risk unacceptable despite
(1)/(2), the only remaining lever consistent with "reduce the worst case instead of
widening the budget around it" (escalation option (c)) is to **remove the retry
entirely** for one or both call sites (single-attempt, same as today, relying solely on
§9.5's loop-continuation fix for criterion (c) and on a separate sweep-style mechanism
per escalation option (b) — not built by this design — for criterion (b)'s "cannot
recur" case). That trade-off is flagged here as **OQ-4** rather than decided silently.

**OQ-4 — not resolved by this design:** should the retry (§9.2) be removed entirely
(zero-retry, single-attempt, matching option (c) literally) if a future review judges
even the rare compounding risk in this section unacceptable, deferring all
transient-error resilience to a separate sweep mechanism (option (b), not part of this
design)? This design keeps the one retry because the task's mandated approach (step-02
handoff `task.description`, point 1) explicitly specifies "retry ... exactly once," but
the tension between that instruction and a theoretically compoundable multi-call risk
is named here rather than quietly assumed away.

### 9.8 TEST CODE ONLY — reverified independently for Pass 4

Reverified directly against Pass 4's own actual changes (not inherited from §0.1):

- `retry_query_once/1`, `resilient_drop_schema/1`, the `sandbox_schema_names/0` and
  `drop_sandbox_schemas_created_since!/1` body changes are all private functions
  inside `test/letflow/sandbox_pool_test.exs`, calling only `Repo.query!/1`/`/2` and
  `Logger.warning/1` — no call into `Letflow.SandboxPool` (`lib/letflow/sandbox_pool.ex`)
  itself, and no touched line references `SandboxPool.provision_timeout_ms/0` or
  `release_call_timeout/0` (confirmed by 9.6's citations being read-only references for
  arithmetic, not calls added to the implementation).
- No `:timeout` value, named or otherwise, is introduced anywhere in Pass 4 — the
  retry relies entirely on Postgrex's own unconfigured default, so there is nothing
  here that could motivate a `lib/letflow/sandbox_pool.ex` change, a
  `priv/repo/migrations/*` change, or a `config/*.exs` change (no `parameters:`/
  `statement_timeout`/`lock_timeout` GUC is touched, same as §0.1's finding, reconfirmed
  for Pass 4's actual diff rather than assumed to still hold).
- Grep confirms zero references to `Letflow.SandboxPool` module attributes or private
  functions from the new/changed code in this design (only the two public functions
  `provision_timeout_ms/0`/`release_call_timeout/0` are *read* for the arithmetic in
  §9.6, and only as already-existing call sites in this same test file, `:90-92`,
  unmodified).

### 9.9 Files touched — Pass 4

| File | Change | Owner |
|---|---|---|
| `test/letflow/sandbox_pool_test.exs` | Add `retry_query_once/1` (§9.2) and `resilient_drop_schema/1` (§9.4) as new private helpers near `query_without_holding/1` (`:513` area); change `sandbox_schema_names/0`'s body (§9.3, `:537-546`) to wrap its `Repo.query!` call in `retry_query_once/1`; rewrite `drop_sandbox_schemas_created_since!/1`'s body (§9.5, `:552-560`) from a bare `for` to an accumulating `Enum.reduce/3` plus one final `flunk/1`. **No change to `query_without_holding/1` itself** (`:513-531`, signature and body both unmodified) and **no `@moduletag`/`@tag timeout` added anywhere in the file.** | ELIXIR-DEV (or TEST-DESIGNER, per whichever role this WF-03 run assigns test-file edits to) |

No other file — reconfirmed at §9.8.

### 9.10 Invariants — Pass 4

- **INV-T1 — every schema in a `drop_sandbox_schemas_created_since!/1` diff set is
  attempted exactly once**, regardless of any other schema's outcome in the same call
  (§9.5). Unchanged from passes 1–3's statement of this invariant; the mechanism
  achieving it is the only thing that changed.
- **INV-T2 — a genuinely-stuck cleanup query (both attempts exhausted) is never
  silently swallowed.** `sandbox_schema_names/0` still flunks directly via the
  unmodified `query_without_holding/1` crash path (§9.3); the DROP loop still flunks,
  once, naming every unresolved schema (§9.5).
- **INV-T3 — no test-observable behavior changes on the success path.** Every existing
  assertion in this file that calls `sandbox_schema_names/0` or relies on
  `drop_sandbox_schemas_created_since!/1`'s `on_exit` cleanup sees identical results
  when no Postgres error occurs (the overwhelming common case, and per the cited CI
  scan, the only case observed in the last 5 runs) — the retry/rescue paths are
  additive and only ever engage after a real `Postgrex`/`DBConnection` error.
- **INV-T4 (new for Pass 4) — no timeout/retry constant used anywhere in this file
  changes value, and no new one is introduced.** `provision_timeout_ms/0`,
  `release_call_timeout/0`, `@rendezvous_slack_ms`, `pool_op_rendezvous_timeout/0`,
  `claim_call_timeout/1`, ExUnit's default per-test timeout — all unchanged, all
  reconfirmed by direct citation in §9.6/§9.8 rather than assumed. This is the
  structural property that distinguishes Pass 4 from passes 1–3 and is the reason it
  does not repeat their "fix stacks a new layer further out" failure mode.

### 9.11 Acceptance-criteria traceability — Pass 4

| Acceptance criterion (from `step-02-code-designer.json`) | Design element |
|---|---|
| Explicitly rejects a 4th outer-timeout-widening patch and states why | §9.0 |
| Retry happens inside the existing `pool_op_rendezvous_timeout()` budget, no change to that constant's value, arithmetic shown | §9.1 (structural: no new argument to `query_without_holding/1`), §9.6 (`30_000 ms <= 45_000 ms`, `15_000 ms` margin) |
| No new or widened `@moduletag` timeout, no change to ExUnit's default per-test timeout | §9.6 (last paragraph), §9.9 (files-touched note) |
| DROP loop continues past one schema's post-retry failure instead of aborting, reusing `tenant_schema_reaper.ex`'s rescue-log-continue shape | §9.4 (shape lifted from `reclaim_row/1`), §9.5 (`Enum.reduce/3` accumulate-and-continue, modeled on `sweep_orphans/2`) |
| A genuinely-stuck schema (fails twice) still surfaces as a real, loud test failure | §9.3 (`sandbox_schema_names/0` still crashes → `flunk` via unmodified `query_without_holding/1`), §9.5 (DROP loop's single combined `flunk/1` naming every still-failed schema) |
| Independently re-verifies TEST CODE ONLY scope | §9.8 |
| Exact file-by-file / line-level change list | §9.9 |
| No implementation code in the design | §9.2–§9.5 give only `@spec` signatures plus prose description of control flow (rescue/retry/accumulate shape and the reasoning behind it) for ELIXIR-DEV to implement — no fenced Elixir syntax block with a real `fn`/`case`/`if`/`rescue` function body appears anywhere in §9, matching the §3.1–§3.4 style CODE-DESIGN-VALIDATOR already confirmed as prose/@spec-only |
| Prior three rejected passes remain readable | §0–§8 preserved unedited above; §9.0 cross-references each by name and OQ number |
