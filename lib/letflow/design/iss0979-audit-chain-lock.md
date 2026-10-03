# ISS-0979 — Audit chain-tail race: decision + lock design

CODE-DESIGNER, 2026-10-03. Resolves `docs/issues/ISS-0979.yaml` (MINOR,
`owner: "ELIXIR-DEV (decision first)"` — decision already made by
ELIXIR-DEV per this issue's handoff; this document designs the fix that
decision calls for). Design document only — no implementation code.
`@spec`s, schema field lists, and migration-shape descriptions only.

## 0. Decision (ELIXIR-DEV's, restated for this document's own record)

**Genuine, not theoretical.** `Letflow.Audit.fetch_chain_tail/2` (private,
called by `insert_entry/3`) issues a plain, unlocked `SELECT ... ORDER BY
timestamp DESC, id DESC LIMIT 1` against `audit_entries`. Two independent
transactions writing audit entries for the *same tenant* but *different*
resource rows (e.g. two admins' concurrent `POST /users` calls, each
locking a different `users` row — no shared row lock serializes them) can
both execute this `SELECT` before either commits, both observe the same
`chain_hash` as tail, both compute a `chain_hash`/`prev_chain_hash` pair
against it, and both `INSERT` successfully — no unique constraint on
`chain_hash` or `prev_chain_hash` exists to turn the second `INSERT` into a
constraint violation. Confirmed across all 19 current call sites of
`insert_entry/3`/`append_multi/4` (`lib/letflow/identity.ex` ×6,
`lib/letflow/engine.ex` ×4, `lib/letflow/definitions.ex`,
`lib/letflow/definitions/promotion.ex`, `lib/letflow/audit/public_read.ex`,
`lib/letflow/routers/tenant_settings.ex`,
`lib/letflow/repository/activation.ex`, `lib/letflow/routers/instances.ex`,
`lib/letflow/engine/service_task_dispatcher.ex`,
`lib/letflow/engine/task_activation.ex`, `lib/letflow/tasks.ex`) — none
takes any tenant-wide lock; each only locks the specific business row it is
mutating. This design fixes the race.

## 1. What was read before deciding the mechanism

- `lib/letflow/audit.ex` (full file) — `insert_entry/3`'s algorithm
  (resolve `tenant_id`, call `fetch_chain_tail/2`, compute `chain_hash`,
  insert), `append_multi/4`'s `Multi.run/3` wrapping, `fetch_chain_tail/2`'s
  unlocked query. No unique constraint on `chain_hash`/`prev_chain_hash` in
  `priv/repo/migrations/20260830020001_create_audit_entries_tenant_scoped.exs`
  — only immutability triggers (`BEFORE UPDATE`/`BEFORE DELETE`, raising),
  no `BEFORE INSERT` check of any kind.
- `lib/letflow/routers/tenant_settings.ex:100-170`
  (`maybe_record_rejected_keys/5`) and `lib/letflow/routers/instances.ex`
  (`record_attachment_access_denied_audit/5`) — both call
  `Audit.insert_entry(Letflow.Repo, attrs, prefix)` directly, with **no**
  `Repo.transaction/1` wrapper anywhere in the caller — by design (ISS-0980's
  own header comment on the first of these two: "no `Repo.transaction/1`
  wrapper to rescue around here — this write is intentionally
  non-transactional/best-effort"). Both wrap the whole call in `rescue` and
  log-and-swallow on `{:error, reason}`, matching INV-8/INV-4 — the HTTP
  response already in flight must never turn into a 500 because of an
  audit-write hiccup.
- `lib/letflow/event_store.ex:598-636` (`assign_sequence/3`,
  `lock_and_increment_sequence/3`) — the exact precedent ISS-0979's own
  issue text points at (ISS-0970's "mirroring ISS-0970's precedent for the
  events table"). Two-step protocol: (i) `repo.insert(insert_changeset,
  on_conflict: :nothing, conflict_target: :instance_id, prefix: schema_name)`
  — insert-if-absent, one atomic statement, not a racy
  check-then-insert; (ii) a fresh `SELECT ... FOR UPDATE` (Ecto's
  `lock("FOR UPDATE")` composition, never a hand-written SQL string) against
  the now-guaranteed-to-exist row, re-read from the table itself (not the
  insert's own possibly-stale returned struct), then an `update_all/3`
  under the still-held lock. This whole sequence runs inside M2 of
  `append/2`'s `Ecto.Multi`, i.e. always inside an already-open
  `Repo.transaction/1`.
- `priv/repo/migrations/20260816120002_create_instance_sequence.exs` — the
  `instance_sequence` table's own shape: tenant-scoped (`if prefix() do`
  guard), `primary_key: false`, a single `:binary_id` primary key column
  (`instance_id`), **no** `timestamps()` and no secondary index — explicitly
  because it is "the hot row every append takes a `SELECT ... FOR UPDATE`
  on... an `updated_at` would add a write to the most contended row in the
  system for no consumer."
- `lib/letflow/tenant_provisioning.ex:493/572/@tenant_scoped_migration_manifest`
  — confirms the two-part registration convention every tenant-scoped
  migration must follow (the migration file's own `if prefix() do` guard,
  *and* an entry in `tenant_scoped_migration_manifest/0`, "both halves
  mandatory") and `replay_migrations/2`'s existence as the already-built
  mechanism for applying a newly-added tenant-scoped migration to tenants
  provisioned before the migration existed — this design does not need to
  invent that mechanism, only use it.
- `priv/repo/migrations` directory listing — latest tenant-scoped-manifest
  entry is `20260926010001`; this design's new migration takes
  `20261003000001` (today, continuing the manifest's monotonic-timestamp
  convention, with no collision against any listed file).

## 2. Design-space evaluation (issue's four options)

1. **Advisory lock keyed on `tenant_id`** (`pg_advisory_xact_lock`) —
   rejected. Would work mechanically, but introduces a *new* locking
   primitive this codebase has never used anywhere (`rg
   "pg_advisory"` across `lib/` and `priv/` returns nothing) — a surprise
   for any future reader comparing this path's locking to every other
   contended-row path in the codebase (`instance_sequence`,
   `service_task_dispatches`, the various `lock("FOR UPDATE")` call sites
   in `engine.ex`), all of which lock a real row through Ecto's
   `lock/2` composition, never a session-level advisory primitive. Also
   requires its own never-forget-to-release discipline across both the
   transactional and non-transactional call shapes (same wrapping burden as
   option 2 below, with none of option 2's "looks like every other locked
   row in this codebase" benefit).
2. **`SELECT ... FOR UPDATE` on a per-tenant sentinel row** (this design's
   choice; see §3) — the issue's own option 2, with its stated empty-chain
   gap closed by the sentinel-row variant it names as the fallback.
   Reuses, verbatim, the `instance_sequence` precedent's own two-step
   protocol (§1) — insert-if-absent, then lock the now-guaranteed row,
   never the absent-until-first-write `audit_entries` tail row itself. No
   new locking primitive; `rg "lock(\"FOR UPDATE\")"` already finds eight
   call sites across `engine.ex`/`event_store.ex` — this becomes the ninth
   and tenth, not a new idiom.
3. **Mirror ISS-0970's precedent directly** — this *is* what option 2
   does; ISS-0970's own document (§1 of this document) is itself about
   cross-table timestamp-ordering (a different problem: comparing two rows
   from different tables), not about the `instance_sequence`
   locking mechanism ISS-0970's design doc cites as already-reviewed
   precedent. The reusable pattern ISS-0970 points at is
   `event_store.ex`'s `assign_sequence/3`/`lock_and_increment_sequence/3`
   pair — adopted directly in §3.
4. **Unique constraint on `(tenant schema, prev_chain_hash)`** — rejected.
   Converts a silent fork into a retryable constraint-violation error, but
   (a) none of `insert_entry/3`'s 19 call sites are built to retry — most
   run inside an `Ecto.Multi` step whose failure aborts the whole
   surrounding transaction (design intent: "a failure here... aborts and
   rolls back every other step already in `multi`", per `append_multi/4`'s
   own moduledoc) and would need a caller-level retry loop added to every
   call site, not just the one shared primitive; (b) this is exactly the
   "ironic" failure mode the issue's own text flags — ISS-0946 through
   ISS-0984 just finished hardening every call site's handling of
   `insert_entry/3` raises/errors (ISS-0969, ISS-0980, ISS-0981, ISS-0983,
   ISS-0984), and introducing a brand-new error class those call sites were
   never audited against reopens exactly that class of gap this design is
   not willing to reopen. A unique constraint is also strictly weaker than
   option 2: it detects a fork after the fact (as a transaction failure)
   rather than preventing the second transaction from ever computing a
   forked value in the first place.

**Chosen: option 2** — a per-tenant sentinel row, insert-if-absent then
`FOR UPDATE`-locked, wrapping the tail-read-then-insert sequence. Lowest
risk (reuses an already-reviewed codebase pattern verbatim), closes the
race at its source (the second transaction blocks *before* it ever reads a
stale tail, rather than being told after the fact that it guessed wrong),
and — per §4 below — fixes all 19 call sites by changing only the one
shared primitive they all go through.

## 3. Mechanism

### 3.1 New table: `audit_chain_locks` (tenant-scoped)

New migration `priv/repo/migrations/20261003000001_create_audit_chain_locks.exs`,
following the `instance_sequence` migration's own shape exactly (§1):

- Tenant-scoped (`if prefix() do` guard around the whole `change/0` body —
  mandatory per `req022-tenant-schema-provisioning.md` §4's pattern).
- `primary_key: false` table, single column:
  - `tenant_id :binary_id`, declared `primary_key: true` in the `create
    table/3` block (same `primary_key: false` + explicit-column-as-PK shape
    `instance_sequence` uses for `instance_id`).
- No other columns. No `timestamps()` — same rationale
  `20260816120002_create_instance_sequence.exs`'s own header states
  verbatim for its row: this is the hot row every `insert_entry/3` call
  locks, and an `updated_at` write on it would add a write to the most
  contended row in the tenant schema for no consumer that reads it.
- No indexes beyond the primary key (single-row-per-tenant table; the PK
  lookup is the only query shape this table ever serves).
- Registered in `Letflow.TenantProvisioning.tenant_scoped_migration_manifest/0`
  as `{20_261_003_000_001, Letflow.Repo.Migrations.CreateAuditChainLocks,
  "20261003000001_create_audit_chain_locks.exs"}`, appended after the
  existing `20_260_926_010_001` entry — both halves (migration file's own
  guard, manifest registration) mandatory per that module's own comment.
- Existing, already-provisioned tenants get this table via
  `Letflow.TenantProvisioning.replay_migrations/2`'s already-built
  catch-up mechanism (§1) — no new backfill mechanism needed; this design
  does not invent one.

### 3.2 New Ecto schema: `Letflow.Audit.ChainLock`

New file `lib/letflow/audit/chain_lock.ex`, same shape/style as
`Letflow.EventStore.InstanceSequence` (one-struct, `primary_key: false`
with an explicit non-autogenerated binary-id key field, no changeset beyond
what insert-if-absent needs):

```
@spec insert_changeset(t(), %{tenant_id: Ecto.UUID.t()}) :: Ecto.Changeset.t()
```

- `@primary_key {:tenant_id, :binary_id, autogenerate: false}`
- `schema "audit_chain_locks" do end` — no other fields.
- `insert_changeset/2`: casts/validates `:tenant_id` only (`cast` +
  `validate_required`), matching `InstanceSequence.insert_changeset/2`'s own
  minimalism (no business rule belongs in this schema module).

### 3.3 `Letflow.Audit.insert_entry/3` — revised algorithm

Signature unchanged: `@spec insert_entry(repo :: module(), attrs ::
entry_attrs(), prefix :: String.t()) :: {:ok, Entry.t()} | {:error, term()}`.

Revised body, described as a sequence of steps (no code):

1. Resolve `tenant_id` from `prefix` via
   `TenantProvisioning.tenant_id_for_schema_name/1`, exactly as today — this
   step is pure (no I/O, per that function's own moduledoc, §1 of
   `iss0970...` cited above) and happens *before* entering the
   transaction in step 2, so a bad `prefix` still short-circuits with
   `{:error, :invalid_schema_name}` with no DB round-trip, same as today.
2. On success, wrap the remainder of the function's work — steps 3-6 below
   — in one `repo.transaction/1` call. This is the one new structural
   element `insert_entry/3` did not have before. Ecto's nested-transaction
   behavior (a `repo.transaction/1` call issued from code that is already
   running inside an outer `repo.transaction/1` — true for every
   `append_multi/4` call site, since `Multi.run/3` steps execute inside the
   `Repo.transaction/1` call that submits the `Multi`) does not open a second
   database transaction; it runs the given function inline within the
   already-open one, so the lock taken in step 4 is held until the
   *outermost* transaction (the caller's `Ecto.Multi` submission, or — for
   the two non-transactional call sites in §4.2 — this function's own new
   transaction) commits or rolls back. For the two call sites that call
   `insert_entry/3` directly with no surrounding transaction
   (`tenant_settings.ex`, `instances.ex`), this step is what gives
   `insert_entry/3` a transaction boundary for the first time — see §4.2 for
   why this does not change their raise/no-raise contract.
3. Inside the transaction: insert-if-absent the tenant's `ChainLock` row —
   `repo.insert(ChainLock.insert_changeset(%ChainLock{}, %{tenant_id:
   tenant_id}), on_conflict: :nothing, conflict_target: :tenant_id, prefix:
   prefix)`. One atomic statement; whichever of two concurrent first-writers
   for a brand-new tenant loses the race gets `on_conflict: :nothing`'s
   silent no-op, not an error — same shape as `event_store.ex`'s
   `assign_sequence/3`.
4. Re-read that same row, scoped by `tenant_id`, with `lock("FOR UPDATE")`
   composed via Ecto's query DSL (never a hand-written SQL string, per
   INV-7) — not the struct step 3's `insert` returned (which may be stale
   or a no-op placeholder on the losing side of step 3's race), the same
   "insert-if-absent, then re-SELECT-and-lock from the table itself" split
   `lock_and_increment_sequence/3` uses. This call blocks until any other
   transaction currently holding this same tenant's `ChainLock` row's lock
   commits or rolls back — the serialization point that prevents the fork.
5. With the lock held, call the existing `fetch_chain_tail/2` (unchanged —
   still the plain unlocked `SELECT ... ORDER BY timestamp DESC, id DESC
   LIMIT 1`, now safe because no other transaction can be mid-way through
   its own `insert_entry/3` call for this tenant while this lock is held),
   compute `fields`/`chain_hash` exactly as today (no change to the
   canonical-hash-form logic), and `repo.insert(changeset, prefix: prefix)`
   the new `Entry` row.
6. The transaction function's own return value is `{:ok, entry}` or
   `{:error, changeset}` — whatever `repo.insert/2` on the `Entry` itself
   produces (step 3's insert-if-absent outcome is never surfaced to the
   caller; its only job is guaranteeing the lock row exists).
7. After `repo.transaction/1` returns, unwrap its own two-case result shape
   back to `insert_entry/3`'s documented `{:ok, Entry.t()} | {:error,
   term()}` contract: `repo.transaction/1`'s `{:ok, inner}` unwraps to
   `inner` directly (since `inner` is already `{:ok, entry}` or `{:error,
   changeset}` from step 6 — not re-wrapped a second time); `repo.transaction/1`'s
   own `{:error, reason}` (only reachable if the inner function calls
   `repo.rollback/1`, which no step above does) is not a reachable branch in
   practice, but is still handled by passing `reason` through as
   `{:error, reason}` rather than left unmatched, so `insert_entry/3` has no
   case clause gap. A raise inside steps 3-6 (e.g. a changeset's own
   validation never raises, but a connection-level fault could) propagates
   out of `repo.transaction/1` and out of `insert_entry/3` exactly as it
   would have propagated out of the old, unwrapped code — `repo.transaction/1`
   does not catch or convert raises, it only guarantees the DB-side rollback
   happens before the raise continues to the caller. This is the detail
   §4.2 depends on: wrapping in a transaction changes what gets rolled back
   on a raise (now includes step 3's lock-row insert, previously nothing
   since there was no step 3), but does not change whether a raise reaches
   the caller as a raise.

`append_multi/4` is unchanged — it already just calls `insert_entry(repo,
attrs, prefix)` inside its own `Multi.run/3` step; every behavior change
above is internal to `insert_entry/3`.

### 3.4 Why this closes the fork

Two concurrent `insert_entry/3` calls for the same tenant (different
business rows, so no shared business-row lock serializes them, per the
issue's own scenario) now both attempt step 4's `FOR UPDATE` lock on the
*same* `ChainLock` row. Postgres grants it to exactly one of them; the
second blocks at step 4 until the first's enclosing transaction commits or
rolls back. By the time the second acquires the lock and reaches step 5,
the first's `Entry` row (if its transaction committed) is already visible
to the second's `fetch_chain_tail/2` read (same transaction isolation level
this table already runs under — `READ COMMITTED`, per the issue's own
description of the current defect — sees any already-*committed* write by
the time a blocking lock is released by its holder's commit). The second
transaction therefore always computes its `prev_chain_hash` against the
first's actual, now-persisted `chain_hash`, never against a stale read —
the chain cannot fork.

## 4. Scope: the shared primitive, not the 19 call sites

### 4.1 Transactional call sites (17 of 19)

Every call site that reaches `insert_entry/3` via `append_multi/4` inside
an `Ecto.Multi`, or that calls `insert_entry/3` directly inside its own
`Repo.transaction/1` block, needs **zero** code changes. The lock is
acquired and released entirely inside `insert_entry/3`'s own revised body
(§3.3); callers already pass the same `repo`/`attrs`/`prefix` arguments
they always have, and the function's documented return contract (§3.3 step
7) is unchanged.

### 4.2 Non-transactional call sites (2 of 19):
`lib/letflow/routers/tenant_settings.ex:143`,
`lib/letflow/routers/instances.ex:1328`

Both call `Audit.insert_entry(Letflow.Repo, attrs, prefix)` with no
enclosing `Repo.transaction/1`, and both wrap the call in `rescue` plus a
`case` on `{:ok, _}/{:error, _}`, per ISS-0980's hardening. These also need
**zero** code changes:

- `repo` at both call sites is `Letflow.Repo` itself (a module implementing
  `Ecto.Repo`'s callbacks), so `repo.transaction/1` inside `insert_entry/3`
  (§3.3 step 2) opens a brand-new, short-lived transaction scoped to just
  this one `insert_entry/3` call — exactly the same "one call, one implicit
  transaction" shape these two call sites already assumed existed (Postgres
  auto-wraps any single statement in an implicit transaction; now there are
  a few statements instead of one, explicitly wrapped, committing or
  rolling back together instead of each auto-committing independently).
- The `{:ok, entry} | {:error, term()}` return contract is unchanged (§3.3
  step 7), so the existing `case Audit.insert_entry(...) do {:ok, _entry}
  -> :ok; {:error, reason} -> ...log and swallow... end` pattern at both
  call sites requires no edit.
- The existing `rescue` clause at both call sites requires no edit either:
  a raise from inside `insert_entry/3` (e.g. a DB-connection-level fault)
  still propagates out of `insert_entry/3` as a raise (§3.3 step 7's last
  sentence) — `repo.transaction/1` only adds "the lock-row insert-if-absent
  also rolls back" to what gets undone on that raise, it does not convert
  the raise into a return value these call sites would need a new branch
  for.
- Latency: a short lock-wait is now possible at these two call sites where
  none existed before (previously, two concurrent best-effort audit writes
  for the same tenant simply raced with no interaction at all). This is the
  intended serialization, not a regression — these two call sites are
  already documented as "must not delay the caller beyond whatever
  `insert_entry/3` itself takes" (per `instances.ex`'s own comment, §1), and
  "whatever `insert_entry/3` itself takes" now includes a lock wait bounded
  by how long one other concurrent `insert_entry/3` call for the same
  tenant takes to commit — microseconds to low milliseconds at this
  codebase's actual write volumes, not an unbounded wait.

### 4.3 All 19 call sites, enumerated (confirms none needs its own change)

`lib/letflow/identity.ex` ×6, `lib/letflow/engine.ex` ×4,
`lib/letflow/definitions.ex`, `lib/letflow/definitions/promotion.ex`,
`lib/letflow/audit/public_read.ex`, `lib/letflow/routers/tenant_settings.ex`
(§4.2), `lib/letflow/repository/activation.ex`,
`lib/letflow/routers/instances.ex` (§4.2),
`lib/letflow/engine/service_task_dispatcher.ex`,
`lib/letflow/engine/task_activation.ex`, `lib/letflow/tasks.ex` — every one
of these calls either `Audit.insert_entry/3` or `Audit.append_multi/4`
and nothing else of this module's surface; the fix lives entirely inside
those two functions' own shared implementation (in practice, entirely
inside `insert_entry/3`, since `append_multi/4` is a one-line `Multi.run/3`
wrapper around it).

## 5. Regression test design (TEST-DESIGNER's scope — shape specified here)

Needs genuine injected concurrency, not a sequential simulation of it.

### 5.1 Test: concurrent inserts cannot fork the chain

- Provision one tenant schema (existing test support fixture — whichever
  helper the existing `Letflow.Audit` test module already uses to get a
  `prefix`).
- Spawn N (N >= 8, to make a race window miss implausible even on a fast
  CI box — this codebase's existing concurrency regression tests, e.g.
  around `instance_sequence`/`service_task_dispatches` locking, are the
  precedent for N in this range; TEST-DESIGNER confirms the exact N that
  existing precedent uses) concurrent `Task.async/1` processes, each
  calling `Audit.insert_entry/3` (not `append_multi/4` — exercising the
  non-`Multi` call shape directly is sufficient, since §3.3's fix lives
  inside `insert_entry/3` itself regardless of which of the two public
  entry points reaches it) with the **same** `prefix`, each with distinct
  `resource_id`/`action` attrs (so there is no business-row lock
  incidentally serializing them — mirroring the issue's own "different
  user rows" scenario) but otherwise valid `entry_attrs()`.
- `Task.await_many/1` all N, assert every call returned `{:ok, %Entry{}}`
  (no call should error under contention with this fix in place).
- Load all N+ resulting `Entry` rows for the tenant ordered by
  `timestamp ASC, id ASC` (or, more robustly against timestamp-granularity
  ties — see note below — by walking the chain structurally): assert
  **every** entry's `prev_chain_hash` matches exactly one other entry's
  `chain_hash` (or is `nil`, for exactly one entry: the pre-existing tail if
  any, or the first of the N if the tenant's chain was empty going in) —
  i.e. the multiset of `prev_chain_hash` values among the N new entries
  contains no duplicate non-nil value. A duplicate is exactly what a fork
  looks like: two entries both claiming the same `prev_chain_hash`.
- Additionally call `Audit.verify_chain/2` for the tenant afterward and
  assert `{:ok, :valid}` — this exercises the existing recompute-and-link
  verifier as an independent confirmation that the chain is not just
  duplicate-free but actually linear and hash-consistent end to end.

### 5.2 Test: the fix is actually exercised (not coincidentally passing)

Per the issue's own ask for "a mutation-style check that the fix is
actually exercised, not just coincidentally passing" — two options,
TEST-DESIGNER picks one (or both):

- **Preferred — artificial delay injection.** Add a test-only seam: an
  optional delay hook `insert_entry/3` consults between steps 4 and 5 of
  §3.3 (acquiring the lock, and reading the tail) — e.g. an
  `Application.get_env/3`-read `:post_lock_delay_fun` (test-only config,
  defaulting to a no-op in every non-test environment, matching this
  codebase's existing convention for test-only seams — TEST-DESIGNER
  confirms the exact precedent/idiom already in use elsewhere, e.g.
  however `ServiceTaskDispatcher`'s own concurrency tests inject timing).
  With the seam forcing one of the N racers to hold the lock for an
  artificially widened window, the other N-1 are proven to have actually
  blocked at step 4 (observable via wall-clock timing assertions: the
  blocked callers' `insert_entry/3` calls take at least as long as the
  injected delay) rather than having simply never collided by chance.
- **Alternative — direct unit test of `fetch_chain_tail/2` staying
  unlocked.** A narrower test that calls `fetch_chain_tail/2` (currently
  private; would need the test to either go through `insert_entry/3`'s
  public surface or the test module's existing convention for exercising
  private functions) does not by itself prove concurrency safety — this
  option is listed for completeness but §5.1 plus the delay-injection
  variant above is the design TEST-DESIGNER should prefer.

### 5.3 What this test would have caught before this fix

Running §5.1 against the pre-fix `fetch_chain_tail/2` (no lock) is expected
to intermittently (not deterministically — it is a genuine race) produce
two entries sharing the same `prev_chain_hash`, failing the no-duplicate
assertion. TEST-DESIGNER is not asked to prove this by actually reverting
the fix and running the suite (that is this design document's own
reasoning, not a CI-gated step) — but should note in the test's own
comments that this is the failure mode the test is written to catch, per
this codebase's convention of a test file explaining what regression it
guards against (e.g. `iss0970...`'s own precedent of citing the exact prior
defect by issue number in test comments).

## 6. Invariants this design must not violate

- INV-7 (no hand-written SQL interpolating tenant/user-controlled data):
  the new lock-row query and the `ChainLock` insert are both built via
  Ecto's query DSL / `Ecto.Schema`'s `cast`-based changeset — no raw SQL
  anywhere in this design.
- AC3 (`append_multi/4`'s own stated guarantee: an audit-write failure
  aborts and rolls back every other step in the same `Multi`) — unaffected;
  `insert_entry/3`'s new internal transaction nests inside the caller's
  existing one with no change to that failure propagation.
- INV-4/INV-8 (never surface a raw exception/reason that could carry
  connection/query text to an HTTP response; audit-write failure must never
  turn an already-decided response into a 500) — unaffected at both
  non-transactional call sites per §4.2's analysis.
- `Letflow.Audit.Entry`'s immutability triggers, `audit_entries`'
  existing three indexes, and the canonical hash form (moduledoc's "Canonical
  hashed form" section) are all untouched by this design — no change to
  `Entry`, no change to `compute_hash/1`/`canonical_string/1`.

## 7. Open questions for CODE-DESIGN-VALIDATOR / TEST-DESIGNER

- **OQ-1**: §5.1's N (concurrent racers) — this document suggests "N >= 8,
  matching whatever existing concurrency-regression-test precedent in this
  codebase uses" rather than naming an exact number, since the right N is a
  test-infrastructure judgment (CI box parallelism, flake tolerance) this
  document does not have enough information to fix precisely. TEST-DESIGNER
  must name the actual N chosen and cite the precedent it matches.
- **OQ-2**: §5.2's delay-injection seam's exact shape (config key name,
  where it's read from inside `insert_entry/3`, how it's set from a test)
  is left to TEST-DESIGNER to match this codebase's actual existing
  precedent for test-only timing seams — this document does not know of a
  specific existing one to point at by name (a search for
  one is TEST-DESIGNER's to do, not asserted here as already confirmed to
  exist).
- **OQ-3**: whether `ChainLock`'s `tenant_id` column should carry a foreign
  key back to `tenants.id` — `instance_sequence`'s own migration explicitly
  declines a foreign key on its own per-instance key ("same platform-sentinel
  reason as `events`"), but that reason (`instance_id` can reference a
  sentinel value with no real row) does not obviously apply to `tenant_id`
  here, which should always be a real tenant. Left open rather than
  decided either way — ELIXIR-DEV should confirm against
  `audit_entries.tenant_id`'s own precedent (also no FK, per that
  migration's existing shape) before adding one here that audit_entries
  itself does not have.
