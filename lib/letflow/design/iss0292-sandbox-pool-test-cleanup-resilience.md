# Design: ISS-0292 — resilient cleanup helpers in `sandbox_pool_test.exs`

**Run:** WF03-ISS0292-20260823 (GH#585, queue task 292) · **Author:** CODE-DESIGNER ·
**Status:** proposed — awaiting CODE-DESIGN-VALIDATOR

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
