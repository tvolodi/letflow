# Design: ISS-0578 — bounded retry-with-backoff around `clone_tenant_schema!/1`'s clone transaction

**Run:** fix/ISS-0578-20260910 (GH#1185, queue task 578) · **Author:** CODE-DESIGNER ·
**Status:** proposed — awaiting CODE-DESIGN-VALIDATOR.

**Scope: TEST-SUPPORT CODE ONLY.** Every change in this design lands in
`test/support/tenant_template.ex`. No `lib/letflow/` file, no `priv/repo/migrations/*`, no
`config/*.exs` is touched. See §6 for the explicit, re-verified confirmation and the
SECURITY-REVIEWER scoping statement.

---

## 0. Sources read

- `docs/agents/instructions/core-directives.md`, `docs/agents/workflows/WF-02_requirement_implementation.md`
  Step 1, `docs/anti-patterns.md`.
- `test/support/tenant_template.ex` in full — `do_clone/2` (:554-642), `clone_tenant_schema!/1`
  (:179-190), `build_template!/0`'s own cleanup-on-failure `rescue`/best-effort-cleanup shape
  (:299-311), `ensure_template!/0`'s advisory-lock `try/after` shape (:83-144).
- `test/support/tenant_fixture.ex` (:330-460) — `provision_schema!(:clone, tenant_id)` (:360-372,
  the only caller of `clone_tenant_schema!/1`) and `report_and_raise/3` (:448 on) — confirms
  `clone_tenant_schema!/1`'s `{:ok, schema_name} | {:error, {:clone_failed, reason}}` return shape
  is pattern-matched directly by its caller and must not change.
- `lib/letflow/design/iss0292-sandbox-pool-test-cleanup-resilience.md` §9 ("Pass 4") in full — the
  established precedent in this codebase for retry-with-backoff around a test-helper's raw
  `Repo.query!` calls on `Postgrex.Error`/`DBConnection.ConnectionError`, including its
  rescue-by-struct-type (not message-substring) rule, its "retry loop lives inside the fun, no new
  outer timeout layer" structural lesson (learned the hard way across 3 rejected passes), and its
  `@spec`-only / no-function-body style for a design document. This design reuses that precedent's
  shape rather than inventing a new one.
- `lib/letflow/design/iss0515-tenant-template-build-race-fix.md` — confirms this codebase's own
  prior naming for the connection-error class this design targets (`Postgrex.Error: query_canceled`,
  `DBConnection.ConnectionError`) and that no retry existed anywhere in this file before ISS-0578.
- `docs/anti-patterns.md` — grepped for `retry`/`backoff`/`ConnectionError`/`test_parallel` and for
  the ISS-0219/ISS-0409/ISS-0416/ISS-0458/ISS-0468/ISS-0194/ISS-0287/ISS-0515 chain by number; no
  entry documents a retry/backoff convention that this design would contradict, and no entry
  forbids retrying test-provisioning DDL. The one on-point precedent is the ISS-0292 design itself
  (not `anti-patterns.md`), reused above.
- `config/test.exs` and `scripts/test_parallel.sh` (pool-sizing arithmetic, :106-185) — confirms,
  independently of ISSUE-FIXER's diagnosis, that `N * pool_size` is already clamped against
  Postgres `max_connections` (ISS-0194/ISS-0287/ISS-0515). This design's retry adds at most one
  extra `DROP SCHEMA` query per failed clone attempt on the *same already-checked-out-then-freed*
  connection slot — it does not hold a connection open any longer than today's single attempt did,
  and does not change pool-sizing arithmetic anywhere. Not touched, per ISSUE-FIXER's explicit
  instruction.

### 0.1 Root cause, restated (ISSUE-FIXER's diagnosis, not re-litigated)

`do_clone/2` issues 150-250+ sequential SQL round trips inside one `Repo.transaction/1` call, one
connection checkout, zero retry anywhere. Under `scripts/test_parallel.sh`'s N-way parallel
execution, a transient TCP/connection hiccup (confirmed to occur on real hardware under load) is
disproportionately likely to land mid-clone given how many round trips it makes relative to any
other operation in this file, and when it does, `do_clone/2`'s own top-level `rescue exception ->
{:error, {:clone_failed, exception}}` (`:640-642`) converts it into an ordinary error return with
no retry — the observed symptom (a randomly-shifting set of failing test files across runs).
Pool sizing is not implicated and is not touched by this design.

---

## 1. Exact retry strategy

### 1.1 Attempt count

**3 total attempts** (the initial attempt plus **2 retries**), matching ISSUE-FIXER's
recommendation ("retrying the whole clone transaction 2-3 times before surfacing the error") at
its stated ceiling. Named explicitly as a total-attempts count, not "2-3 retries", to remove the
exact ambiguity ISSUE-FIXER's own phrasing left open — `@clone_max_attempts` below is defined as
the total number of times `do_clone/2` itself is invoked, never more.

Not unbounded, and not fewer than 3, for the same reasoning ISS-0292 §2 already established for
this class of fix in this codebase: a single retry-once budget is the minimum that distinguishes
"transient hiccup" from "stuck," but `do_clone/2`'s round-trip count (150-250+) is roughly an order
of magnitude larger than the 1-2 round-trip cleanup queries ISS-0292 covered, so a single hiccup is
statistically more likely to land somewhere in *this* operation across a run — one extra retry
(3 total attempts instead of 2) is proportionate to that larger exposure surface without chasing an
unbounded retry loop that would mask a genuinely broken template/database.

### 1.2 Backoff

**Fixed, short sleep between attempts — `@clone_retry_backoff_ms`, `200`ms — not exponential.**
No fresh multi-run timing sample exists for how quickly a transient TCP/pool-connection hiccup
under `scripts/test_parallel.sh` actually clears, stated honestly per `core-directives.md`'s
"No Speculation" rather than inventing one (matching ISS-0292 §2's own honesty about not having a
fresh sample for its timeout value). `200`ms is chosen, not derived from a measured floor, for two
stated reasons a later reviewer can weigh:

- This is test-infrastructure code, not a user-facing path — the cost of over-waiting is a slower
  test suite, not a worse user experience, so there is no pressure to shave this to a measured
  minimum the way a production retry budget would need.
- Exponential backoff exists to protect a shared resource from *retry storms* under sustained
  contention (many independent callers backing off from each other). A single test process
  retrying its own single clone operation 2 more times, `200`ms apart, adds at most `400`ms of
  total extra wall-clock time to one clone in the rare case both retries are needed — negligible
  next to a clone's own multi-hundred-round-trip baseline cost, and not a scenario where escalating
  the wait between attempts buys anything a fixed short wait does not.

**Flagged as OQ-1** (§7) rather than silently asserted as sufficient: if a future run's CI logs
show the `200`ms gap is too short for the hiccups actually observed in practice, that is a
measurement this design does not have and should not guess past.

### 1.3 Exact error match — by struct/module, not message substring

Retry triggers on and only on:

- `%Postgrex.Error{}` (any postgres field/code — this design does **not** narrow to specific SQLSTATE
  codes, because the failure mode is a broken/dropped connection surfacing as a generic driver
  error, not a specific constraint or syntax error `do_clone/2` could otherwise legitimately raise
  as an application-level defect)
- `%DBConnection.ConnectionError{}`

matched by **exception struct/module alone** (`rescue exception in [Postgrex.Error,
DBConnection.ConnectionError] -> ...`), never by matching on `Exception.message/1`'s text (e.g.
never a `String.contains?(..., "tcp recv: closed")` check). This is the same rule ISS-0292 §9.2
already established for this codebase's one existing precedent, and for the same reason stated
there: matching on the exception's own struct type is precise and version-stable, while matching on
a driver's free-text message string is fragile against wording changes across Postgrex/library
versions and against the many *different* wordings a real connection failure can produce (closed
socket, reset by peer, timeout, EOF mid-read, ...) — struct-type matching catches all of them
uniformly without needing to enumerate substrings.

Anything else `do_clone/2` can raise or return (e.g. an `ExUnit.AssertionError` from
`rename_indexes_to_template_names!/2`'s own explicit raise at `:701-705`, a `Registration.changeset/2`
validation failure, any other exception struct) is treated as **non-retryable** and returned
immediately on the first attempt — retrying an application-level defect would only delay surfacing
a real bug behind up to 2 extra full clone attempts, which is exactly the failure mode ISS-0292 §9.0
names as the thing three prior rejected designs kept reproducing one layer further out. This design
does not repeat that: it retries the narrow class of error ISSUE-FIXER's diagnosis names, nothing
broader.

---

## 2. Cleanup semantics before a retry

### 2.1 What is run, and where

Before re-invoking `do_clone/2`, run exactly one statement:

```
DROP SCHEMA IF EXISTS "<clone_schema>" CASCADE
```

against the **same literal `clone_schema` value** the failed attempt was given — `clone_schema` is
derived once, before the retry loop starts, from `TenantProvisioning.schema_name_for_tenant/1`
(the deterministic `"tenant_" <> 32-hex` shape keyed on `source_tenant_id` — **not** regenerated
per attempt, unlike `build_template!/0`'s randomized staging name, precisely because
`clone_tenant_schema!/1`'s contract is to produce a stable, tenant-derived schema name every time —
see `Letflow.TenantProvisioning.schema_name_for_tenant/1`, `lib/letflow/tenant_provisioning.ex:214-219`,
the actual source of this determinism guarantee — it derives the schema name deterministically from
`source_tenant_id` alone (a canonicalized-UUID-to-hex transform), so the same tenant id always yields
the same schema name, on every call). This is exactly why the pre-retry DROP is
needed here in a way `build_template!/0` never needed one: `build_template!/0` sidesteps the
same-name-collision hazard entirely by minting a fresh random name per attempt (design
`iss0427-...md` §0.7); `clone_tenant_schema!/1` cannot do that without breaking its own documented
contract, so instead each retry must first guarantee the target name is clear.

Runs via a **plain top-level `Repo.query!/1` call, outside any `Repo.transaction/1` block** — i.e.
on whatever connection the pool hands back for that one statement, not on the connection the failed
attempt was using. The failed attempt's own connection is presumed dead (that is the failure this
design exists to recover from); `Repo.query!/1` called fresh, after the failed `do_clone/2` call has
already returned/raised and released its own checkout, causes the pool to hand back a connection in
whatever state it is in — a live one if the pool has others available, or a newly-established one if
not. This mirrors `build_template!/0`'s own cleanup call shape exactly (`Repo.query!(~s(DROP SCHEMA
IF EXISTS "#{staging_schema}" CASCADE))`, `:304`) — same statement shape, same "plain query outside
the failed transaction" placement, reused rather than inventing a new idiom.

No `IF NOT EXISTS`/existence pre-check is needed before the DROP: `DROP SCHEMA IF EXISTS ... CASCADE`
already tolerates the schema not existing at all (e.g. the very first attempt failed before
`CREATE SCHEMA` itself ran) — it is a no-op in that case, exactly as `build_template!/0`'s own reuse
of this idiom already relies on.

### 2.2 Cleanup-failure handling — best-effort, not a nested safety net

If the `DROP SCHEMA IF EXISTS ... CASCADE` cleanup statement **itself** raises
(`Postgrex.Error`/`DBConnection.ConnectionError` or otherwise), that exception is **rescued and
discarded** (`rescue _cleanup_failure -> :ok`) — no nested retry, no second cleanup attempt. This is
the same "cleanup is itself best-effort" rule `build_template!/0`'s own rescue block already states
explicitly at `:296-298` ("Cleanup is itself best-effort for the same reason") and applies here for
an identical reason: a cleanup statement that fails twice in a row is evidence of a real, sustained
outage (the database is genuinely unreachable), not the single transient hiccup this design exists
to paper over — and this design's own outer retry loop (§3) will surface that as a real, loud
failure on its next `do_clone/2` attempt (which will itself fail to `CREATE SCHEMA` against a
possibly-still-present schema, or fail outright if Postgres is truly down) rather than the cleanup
step silently absorbing an outage that should be visible.

Do not add a nested try/rescue-with-its-own-retry around the DROP. One rescue, discard, move on to
the next `do_clone/2` attempt (or, if attempts are exhausted, to §4's final return) — matching
`build_template!/0`'s own single-level rescue shape exactly, not a deeper structure.

---

## 3. Where the retry wrapper lives

### 3.1 New private function: `do_clone_with_retry/2`

```
@spec do_clone_with_retry(source_tenant_id :: Ecto.UUID.t(), clone_schema :: String.t()) ::
        {:ok, schema_name :: String.t()}
        | {:error, {:clone_failed, term()}}
```

Placed as a new private function directly above `do_clone/2` (`:554` area, "Clone (design §2.3
steps 1-8)" section banner). Wraps `do_clone/2` unchanged — `do_clone/2`'s own body, its `rescue`
clause, and its `{:ok, ^clone_schema} -> {:ok, clone_schema}` / `{:error, reason} -> {:error,
{:clone_failed, reason}}` case mapping are **not modified** at all by this design. `do_clone_with_retry/2`
calls `do_clone/2` up to `@clone_max_attempts` (`3`) times, inspecting each call's return value:

- `{:ok, schema_name}` → return it immediately, no further attempts, no cleanup run (the success
  path is untouched — this design's whole point is that the success path behaves identically to
  today when no connection hiccup occurs, matching ISS-0292's own INV-T3-style "no test-observable
  behavior change on the success path" invariant, restated as INV-1 in §5 below).
- `{:error, {:clone_failed, reason}}` where `reason` matches `%Postgrex.Error{}` or
  `%DBConnection.ConnectionError{}` (§1.3) **and** attempts remain → run §2's cleanup, sleep
  `@clone_retry_backoff_ms`, then call `do_clone/2` again (attempt count incremented).
  Note: `do_clone/2`'s own `rescue`/`Repo.transaction/1`-error-branch already normalizes *every*
  failure mode — a raised exception, a transaction abort, or a `Repo.transaction/1` `{:error,
  reason}` return — down to this one `{:error, {:clone_failed, reason}}` shape (`:636-642`), so
  `do_clone_with_retry/2` never needs to distinguish those internally; it only ever inspects the
  outer `{:error, {:clone_failed, reason}}` tuple's `reason` term.
- `{:error, {:clone_failed, reason}}` where `reason` does **not** match either retryable struct
  type → return it immediately (§1.3's non-retryable case), no cleanup run, no further attempts.
- `{:error, {:clone_failed, reason}}` where `reason` **does** match but attempts are exhausted →
  return it as-is (§4).

### 3.2 `clone_tenant_schema!/1` — one-line body change

```
@spec clone_tenant_schema!(source_tenant_id :: Ecto.UUID.t()) ::
        {:ok, schema_name :: String.t()}
        | {:error, {:clone_failed, term()}}
```

Signature and return shape **unchanged** (`:179-181`). Its body's `do_clone(source_tenant_id,
clone_schema)` call (`:184`) becomes `do_clone_with_retry(source_tenant_id, clone_schema)` — the
only line in `clone_tenant_schema!/1` that changes. Its own `with`/`else`/outer `rescue` structure
(`:182-190`, handling `TenantProvisioning.schema_name_for_tenant/1`'s own possible `{:error,
reason}` before `do_clone_with_retry/2` is ever called) is untouched — that precondition failure is
a different, non-retryable error class (an invalid `source_tenant_id`), already out of scope for
this design.

---

## 4. After retries are exhausted

Unchanged surfacing path. `do_clone_with_retry/2` returns the **last** attempt's `{:error,
{:clone_failed, reason}}` tuple exactly as received from `do_clone/2` — no wrapping, no new error
shape, no "retries exhausted" marker added to the tuple. This flows back through
`clone_tenant_schema!/1` unchanged (§3.2), which is exactly the same value shape
`provision_schema!(:clone, tenant_id)` (`test/support/tenant_fixture.ex:360-372`) already
pattern-matches on today:

```
case Letflow.Test.TenantTemplate.clone_tenant_schema!(tenant_id) do
  {:ok, schema_name} -> schema_name
  {:error, reason} -> report_and_raise(@phase_replay_failed, tenant_id, [...])
end
```

**No change to `tenant_fixture.ex` is required or made by this design.** A real, persistent failure
(one that survives all 3 attempts) still reaches `report_and_raise/3` exactly as it does today,
producing the same `ExUnit.AssertionError` report and the same `Logger.error` marker line
(`tenant_fixture.ex:448` on) — this design changes *how many times* `do_clone/2` is attempted before
that reporting path fires, not what that reporting path does or looks like.

---

## 5. Invariants

- **INV-1 — success-path behavior is byte-for-byte unchanged.** When no connection hiccup occurs
  (the overwhelming common case), `do_clone_with_retry/2` calls `do_clone/2` exactly once, gets
  `{:ok, schema_name}` on the first attempt, and returns it immediately — no cleanup statement is
  ever run, no sleep ever happens, and no behavior visible to `clone_tenant_schema!/1` or
  `provision_schema!/2` changes at all.
- **INV-2 — a non-retryable failure surfaces exactly as fast as today.** Any `do_clone/2` failure
  whose `reason` is not a `Postgrex.Error`/`DBConnection.ConnectionError` struct returns immediately
  on the first attempt, with zero added latency and zero cleanup statements run — this design never
  slows down or masks a real application-level defect.
- **INV-3 — every retry attempt targets a clean, guaranteed-absent schema name.** The `DROP SCHEMA
  IF EXISTS "<clone_schema>" CASCADE` cleanup (§2.1) runs before every retry attempt (never before
  the first attempt), so `do_clone/2`'s own `CREATE SCHEMA "<clone_schema>"` (no `IF NOT EXISTS`,
  `:559`) never collides with debris a prior failed attempt in the same retry loop may have left
  behind.
- **INV-4 — retries are capped, never unbounded.** At most `@clone_max_attempts` (`3`) total calls
  to `do_clone/2` per `clone_tenant_schema!/1` invocation, and at most 2 cleanup statements (one
  before each of the 2 possible retries) — matching INV-1-style boundedness reasoning already
  established in this file's own `build_template!/0` (single build attempt, no retry at all) and in
  ISS-0292's precedent (bounded retry, never unbounded).
- **INV-5 — a genuinely-stuck clone still surfaces as a real, loud failure.** After
  `@clone_max_attempts` attempts, the last `{:error, {:clone_failed, reason}}` is returned unchanged
  and flows into `report_and_raise/3` exactly as today (§4) — no path silently returns `:ok` or
  swallows a persistent failure into a false success.
- **INV-6 — no timeout/pool-sizing constant anywhere in this codebase changes value.** No
  `pool_size`, `TEST_POOL_SIZE`, `TEST_MIN_POOL_SIZE`, or any `config/test.exs`/
  `scripts/test_parallel.sh` value is touched by this design — reconfirmed in §6, matching
  ISSUE-FIXER's explicit instruction not to re-litigate ISS-0194/ISS-0287/ISS-0515's already-correct
  arithmetic.

---

## 6. Scope confirmation — test-support only, not a SECURITY-REVIEWER gate

Re-verified directly against this design's own actual changes, not assumed:

- Every function this design adds or changes (`do_clone_with_retry/2`, the one-line
  `clone_tenant_schema!/1` body edit) lives in `test/support/tenant_template.ex`, which is compiled
  only under `elixirc_paths(:test)` (per that module's own moduledoc, `:11`) — never reachable from
  `lib/letflow/`, never referenced from `lib/letflow/application.ex`'s supervision tree, and not a
  GenServer.
- No `lib/letflow/` file is touched. No `priv/repo/migrations/*` file is touched. No `config/*.exs`
  file is touched (§0's read of `config/test.exs`/`scripts/test_parallel.sh` was read-only, to
  confirm pool-sizing is out of scope, not edited).
- This is **not** a tenant-data-path change in the `docs/agents/instructions/security-invariants.md`
  sense: no API route is touched, no migration is added or changed, no response shaping changes, no
  production secret or credential is touched. The schema this design's cleanup statement drops
  (`clone_schema`, the deterministic per-tenant test schema name) is itself already a test-only,
  throwaway artifact created and destroyed entirely within `test/support/` — `Letflow.TenantProvisioning.provision_tenant_schema/1`
  and `replay_migrations/2` (the real, production tenant-provisioning primitives) are not modified,
  not called by this design's new code, and remain exactly as untouched as
  `test/support/tenant_template.ex`'s own moduledoc already states they are for the rest of the
  file (`:16-21`).
- Recommendation to CODE-DESIGN-VALIDATOR: **SECURITY-REVIEWER sign-off can be skipped** for this
  design per the above, unless CODE-DESIGN-VALIDATOR itself disagrees with this scoping — flagged
  explicitly rather than silently assumed, per this task's own instruction.

---

## 7. Open questions

**OQ-1 — `@clone_retry_backoff_ms = 200` is not derived from a measured hiccup-clearance time.**
No fresh multi-run timing sample exists (stated honestly in §1.2) for how long a real transient
TCP/connection hiccup under `scripts/test_parallel.sh` actually takes to clear. `200`ms is a
reasoned, not measured, choice, justified in §1.2 by this being test-infrastructure code (where
over-waiting costs suite wall-clock time, not correctness or user experience) rather than a
production retry budget. If a future run's data shows `200`ms is too short (hiccups still not
cleared) or unnecessarily long (suite time noticeably affected across many partitions run
concurrently), that is new information this design does not have, named here rather than guessed
past.

**OQ-2 — whether `@clone_max_attempts = 3` (2 retries) is enough, given `do_clone/2`'s very large
round-trip count.** ISSUE-FIXER's diagnosis recommended "2-3 times"; this design picks the upper
end of that stated range (§1.1) because of `do_clone/2`'s unusually large exposure surface relative
to ISS-0292's 1-2-round-trip queries, but does not have a measured "how often does a hiccup land
twice in the same clone's 3 attempts" data point either. Not expected to be revisited without new
evidence, but named rather than silently treated as definitely sufficient.

---

## 8. Files touched

| File | Change | Owner |
|---|---|---|
| `test/support/tenant_template.ex` | Add `@clone_max_attempts 3` and `@clone_retry_backoff_ms 200` module attributes (placed near the existing `@template_schema`/`@advisory_lock_key`/`@built_marker_key` attributes, `:40-55` area); add new private function `do_clone_with_retry/2` (§3.1) directly above `do_clone/2` (`:554` area); change `clone_tenant_schema!/1`'s body (`:184`) to call `do_clone_with_retry/2` instead of `do_clone/2` (§3.2). `do_clone/2` itself (`:554-642`) is **not modified**. | ELIXIR-DEV |

No other file.

---

## 9. Acceptance-criteria traceability

| Item from ISSUE-FIXER's recommendation / task | Design element |
|---|---|
| Bounded retry-with-backoff around `clone_tenant_schema!/1`'s outer `Repo.transaction/1` call | §1.1 (3 total attempts), §1.2 (200ms fixed backoff), §3.1 (`do_clone_with_retry/2` wraps the whole `do_clone/2` call, which is itself the function containing the `Repo.transaction/1` call) |
| Catch `Postgrex.Error`/`DBConnection.ConnectionError` specifically | §1.3 (struct/module match, not message substring — explicit precision requested by the task) |
| Retry the whole clone transaction 2-3 times before surfacing the error | §1.1 |
| Clean up any half-built schema before retrying (no `IF NOT EXISTS` on `CREATE SCHEMA`) | §2.1 (`DROP SCHEMA IF EXISTS "<clone_schema>" CASCADE`, same deterministic name every attempt) |
| Cleanup runs in a new connection context, since the failed one is presumably dead | §2.1 (plain top-level `Repo.query!/1`, outside the failed transaction, after the failed attempt has already released its checkout) |
| How cleanup failures themselves are handled | §2.2 (best-effort, single rescue-and-discard, no nested retry — matches `build_template!/0`'s own precedent) |
| Exact wrapper location and signature | §3.1 (`do_clone_with_retry/2`, `@spec`, placement) and §3.2 (`clone_tenant_schema!/1`'s one-line change) |
| Unchanged error-reporting behavior for a real, persistent failure | §4 (`report_and_raise/3` path untouched, same tuple shape) |
| Confirm test-support-only scope; SECURITY-REVIEWER skip recommendation | §6 |
| Do not touch pool-sizing arithmetic | §0 (read-only confirmation), INV-6 (§5) |
| No implementation code in the design | §§1-4 give only `@spec` signatures, named constants, and prose/bullet descriptions of control flow and reasoning — no fenced block contains a `def`/`case`/`if`/`rescue` function body; the one literal SQL string shown (§2.1) is the statement text itself, not Elixir code, matching how `do_clone/2`'s own existing SQL strings are quoted in its moduledoc-adjacent comments elsewhere in this file |
