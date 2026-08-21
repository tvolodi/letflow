# ISS-0111 fix design: `with_only_this_tenant_visible!/2` cross-invocation safety

## 0. Decision

**Option (a) — mutual exclusion via a Postgres session-level advisory lock** —
chosen. Option (b) (transaction-wrap-and-rollback) is **rejected on hard evidence**,
not preference: `Ecto.Migrator.run/4`'s own documented execution model makes it
structurally incompatible with being nested inside a caller-held transaction (§2).
Option (c) (defer to ISS-0107) is weighed and rejected as the *sole* action, though
ISS-0107 remains worth fixing independently (§4).

This changes only `test/letflow/identity_migration_test.exs` — no other file. Per the
task's own scope note, no `priv/repo/migrations/*.exs` file is touched.

---

## 1. Evidence: option (a)'s sandbox/pooling question, resolved

Investigated directly rather than assumed, per the acceptance criteria.

**Claim to check:** could an advisory lock's acquire and release land on two different
physical Postgres sessions, given `:auto` mode's real connection pool, making the
release silently no-op (worse than no lock)?

**Finding: yes, this is a real risk with the current code shape, and it is avoidable.**

- `config/test.exs` sets `pool: Ecto.Adapters.SQL.Sandbox`, `pool_size:
  System.schedulers_online() * 2` (or `TEST_POOL_SIZE`) — several real, independent
  connections exist once the pool operates in `:auto` mode.
- `Ecto.Adapters.SQL.Sandbox.mode/2`'s own moduledoc (test/specs/REQ-022.md quotes it
  directly): switching to `:auto` "checks in all existing connections" and makes every
  subsequent `Repo` call use "a real, ad hoc, committing connection" — i.e. in `:auto`
  mode, a bare `Repo.query!/2` call is **not** guaranteed to reuse the same physical
  connection as the previous bare `Repo.query!/2` call. `with_only_this_tenant_visible!/2`
  today issues three separate `Repo.query!/2` calls (backup-table DDL, move-out DELETE,
  move-back INSERT) with nothing pinning them to one session. A naive `pg_advisory_lock`
  acquire in the first call and `pg_advisory_unlock` in a later call would risk running
  on two different sessions.
- Traced the actual mechanism in `deps/ecto_sql/lib/ecto/adapters/sql.ex`
  (`checkout_or_transaction/4`, `get_conn/1`, `put_conn/2`): a connection is pinned to
  the *calling process* only for the duration of an explicit `Repo.checkout/2` (or
  `Repo.transaction/2`) call — via `Process.put({Ecto.Adapters.SQL, pool}, conn)`, read
  back by `get_conn_or_pool/2` on the next nested call from the *same process*. Outside
  such a wrapper, each `Repo.query!/2` call checks out and back in independently and can
  land on a different pool member.
- Conclusion: `pg_advisory_lock`'s acquire and its matching `pg_advisory_unlock` are
  session-scoped by Postgres definition (they released only by an explicit unlock **on
  the same backend**, or by that backend's connection closing) — so the fix must wrap
  the entire critical section (lock acquire → move-out → `fun.()` → move-back → lock
  release) in one `Repo.checkout/2` call, which pins one physical connection to the
  calling test process for that whole span. This is not automatic in the current code
  and must be added explicitly — see §3.
- A crash-safety bonus this investigation surfaced: Postgres unconditionally releases a
  session-level advisory lock when the owning backend/connection terminates (crash,
  supervisor kill, network drop) — no separate cleanup code is needed for the lock
  itself. This does **not** extend to the backup-table row dance, which is a separate
  concern (§3.3).

---

## 2. Evidence: option (b) is not viable for this specific migration

Investigated directly, per the acceptance criteria — not assumed.

`deps/ecto_sql/lib/ecto/migrator.ex`'s own moduledoc states the execution model
explicitly:

> In order to run migrations, at least two database connections are necessary. One is
> used to lock the "schema_migrations" table and the other one to effectively run the
> migrations.

Read further into the implementation: `run/4` calls `lock_for_migrations/4`, and the
actual migration work is dispatched through `async_migrate_maybe_in_transaction/7`,
which builds a closure and runs it via `Task.async/1` + `Task.await/2`
(`migrator.ex` ~line 342). `run_maybe_in_transaction/5`, executed **inside that spawned
Task**, calls `repo.transaction(fun, ...)` — a transaction opened on whatever
connection *that Task's own process* checks out from the pool, entirely independent of
whatever connection the calling ExUnit test process already holds (per §1's
process-keyed `get_conn/put_conn` mechanism — a different process has no entry under
that process dictionary key, so it must request its own connection from the pool, not
reuse the caller's).

**Consequence:** if `identity_migration_test.exs` wrapped the whole guarded scenario in
its own `Repo.transaction(fn -> ... Ecto.Migrator.run(...) ... end)` intending to roll
everything back, the migration's actual `DO $$ ... $$` block (including its
`DROP TABLE` statements and its `schema_migrations` bookkeeping) would still run and
**commit for real** on the Task's own separate connection/transaction, uncoupled from
the outer wrapper. Rolling back the outer transaction afterward would not undo it. This
is not a hypothetical edge case — it is exactly why `test/specs/REQ-022.md` documents
`replay_migrations/2` (which also calls `Ecto.Migrator.run/4`) failing with
`DBConnection.ConnectionError — could not checkout the connection ... reason:
:queue_timeout` under sandbox mode (a single-connection-per-owner pool cannot service
the Task's independent checkout request at all), and why that file's own fix was to
switch to `:auto` mode rather than trying to keep everything on one connection.

Postgres DDL genuinely is transactional (confirmed, as the task states) — that part of
option (b)'s premise is correct. The premise that breaks is "the entire guarded
scenario can be made to happen inside one transaction this test controls" — it cannot,
because `Ecto.Migrator.run/4` structurally opens its own, separate transaction on its
own, separate connection no matter what the caller does. **Option (b) is rejected on
this evidence**, not on preference.

---

## 3. Fix specification (option a)

### 3.1 New/changed private helpers in `test/letflow/identity_migration_test.exs`

```
@guard_lock_key "letflow:test:iss0060_tenant_schemas_guard"
```
A single fixed, literal lock key shared by every caller in this module (both
`with_only_this_tenant_visible!/2` and `restore_orphaned_guard_backup_rows!/0` — see
§3.3 for why the latter must also participate). Passed to Postgres via
`hashtext/1`, the same idiom `lib/letflow/tenant_provisioning.ex` already uses for
`pg_advisory_xact_lock(hashtext($1))` — consistent convention, no new pattern
introduced. Because the key is a compile-time literal (not tenant/user input), it can
be inlined into the SQL text directly; no bind parameter is required for it.

```
@spec acquire_guard_lock!() :: :ok
```
Issues `SELECT pg_advisory_lock(hashtext($1))` (bind param: `@guard_lock_key`) via
`Repo.query!/2`. Session-scoped, blocking: returns only once the lock is held on the
current session. Must only ever be called from inside a `Repo.checkout/2` (or
`Repo.transaction/2`) callback so it lands on the connection that will later call
`release_guard_lock!/0` (§1).

```
@spec release_guard_lock!() :: :ok
```
Issues `SELECT pg_advisory_unlock(hashtext($1))` (same bind param) via `Repo.query!/2`,
from the **same** `Repo.checkout/2` callback as the paired `acquire_guard_lock!/0`.

### 3.2 `with_only_this_tenant_visible!/2` — new body shape

Signature unchanged: `with_only_this_tenant_visible!(tenant_id :: Ecto.UUID.t(), fun ::
(-> result)) :: result` (same as today — returns whatever `fun.()` returns, propagates
any exception `fun.()` raises after running its cleanup, exactly as the current
`try/after` does).

Control flow (prose, not code — the nesting is the load-bearing part):

1. The entire body executes inside one `Repo.checkout/2` call — this is the new
   top-level wrapper and is what makes steps 2 and 5 share a session (§1's finding).
2. Acquire the guard lock (`acquire_guard_lock!/0`) — blocks here if another
   invocation (any process, any host, same Postgres instance/database) is mid-critical
   section under the same key.
3. `try` block: `ensure_backup_table!/0`, then the existing move-out DELETE-into-backup
   CTE (unchanged SQL), then a **nested** `try`/`after` around `fun.()` whose `after`
   runs the existing move-back INSERT-from-backup CTE (unchanged SQL) — this nested
   try/after is exactly today's existing structure, preserved verbatim so the
   guard-migration call itself is unaffected.
4. Outer `after` (paired with step 2): `release_guard_lock!/0` — runs whether the inner
   block succeeded or raised, guaranteeing the lock is never left held past this call
   on this session (and, per §1, would in any case be dropped automatically if this
   session's connection died first).
5. `fun.()` (the guarded `Ecto.Migrator.run/4` call, per §2) runs from within the
   `Repo.checkout/2` callback's process but does its actual migration work on its own,
   separately-checked-out connection via its internal `Task.async/1` — this does not
   conflict with holding the checked-out connection for the lock, since the pool has
   more than one member available in `:auto` mode (unlike the single-connection
   sandbox scenario `test/specs/REQ-022.md` hit) and the advisory lock itself is a
   database-wide primitive, not tied to a specific connection remaining idle.

Net effect: the move-out DELETE, the guarded migration call, and the move-back INSERT
are unchanged in their own SQL — what's new is that no other invocation of this same
function (in this process or any other, on this Postgres instance) can be inside that
same window concurrently, closing the exact hazard ISS-0111 describes.

### 3.3 `restore_orphaned_guard_backup_rows!/0` — required change

The task's acceptance criteria require this interaction to be addressed explicitly,
not left implicit. It must change, for a real race the lock would otherwise create:

**The problem if left unlocked:** this helper runs unconditionally at the top of every
test's `setup` block. If invocation B's `with_only_this_tenant_visible!/2` is
genuinely mid-critical-section (its move-out has committed, its guarded migration call
is still running) at the exact moment invocation A's `setup` calls
`restore_orphaned_guard_backup_rows!/0`, invocation A would see B's just-moved rows
sitting in the backup table and — with no lock of its own — restore them into
`public.tenant_schemas` immediately, **while B still believes them safely hidden**.
That reintroduces exactly the race ISS-0060 originally fixed, just relocated to a
second helper.

**Fix:** `restore_orphaned_guard_backup_rows!/0` must acquire and release the *same*
`@guard_lock_key` lock, in its own `Repo.checkout/2` wrapper, around its existing
DELETE-from-backup/INSERT-into-`tenant_schemas` CTE (unchanged SQL otherwise). Because
it contends for the identical key `with_only_this_tenant_visible!/2` holds:

- If no other invocation is mid-critical-section, the lock is acquired immediately and
  the helper proceeds exactly as today (heals any genuinely orphaned rows left by a
  past crash).
- If another invocation is genuinely mid-critical-section (holding the lock), this call
  blocks until that invocation's own `release_guard_lock!/0` runs (i.e. until it
  finishes its own move-back) — at which point the backup table is legitimately empty
  again in the normal case, so the restore is a no-op, correctly.
- If that other invocation instead crashed mid-window, its session (and thus its held
  lock) is already gone per §1's Postgres guarantee, so this call acquires immediately
  and correctly heals the genuinely orphaned row(s) left behind — the crash-self-heal
  behavior this function exists for is fully preserved, now race-free against a
  concurrently-running (not crashed) sibling invocation as well.

No other change to this helper is needed — signature, table shape, and restore SQL are
unchanged.

### 3.4 Summary of the acquire/release points (acceptance criterion 2, explicit)

| Call site | Acquire | Release | Same session guaranteed by |
|---|---|---|---|
| `with_only_this_tenant_visible!/2` | before the move-out DELETE | after the move-back INSERT (outer `after`) | single enclosing `Repo.checkout/2` |
| `restore_orphaned_guard_backup_rows!/0` | before the DELETE-from-backup/INSERT-into-`tenant_schemas` CTE | immediately after that CTE | single enclosing `Repo.checkout/2` |

---

## 4. Option (c) weighed and rejected as the sole action

ISS-0107 (`docs/issues/ISS-0107.yaml`, re-read for current status as part of this
design): **status `open`**, filed 2026-08-20/21, no `related_issues` entry or note
indicating active work, no fix in flight on this branch or any handoff this session has
touched. Fixing it (making the fake-`mix` fixture Windows-safe, or otherwise stopping
the nested `mix test` from silently inheriting the parent's database) would remove the
*precondition* for this entire hazard family (ISS-0110 and ISS-0111 alike), which is a
real efficiency argument for deferring narrow, single-symptom fixes to it.

However, per the task's own framing and matching ISS-0110's already-recorded reasoning
("real liveness tracking ... is the direction that removes the guess rather than
retuning it" — i.e. ship the targeted, unconditionally-correct fix now rather than wait
on an unscheduled prerequisite): the advisory-lock fix in §3 is self-contained, small,
confined to one test file, does not depend on ISS-0107 landing first, and remains
correct defense-in-depth even after ISS-0107 is eventually fixed (it would then simply
never contend, at negligible cost). Deferring ISS-0111 entirely to ISS-0107 would leave
a known, reproducible corruption path (§ISS-0111's own corroborating evidence: 10/14
failures in the run that discovered ISS-0109 traced to this exact mechanism) open for
an indeterminate time. **Recommendation: do not defer — implement §3 now.** ISS-0107
remains open and worth fixing separately; nothing here removes it from the queue.

## 5. Open questions

None load-bearing for implementation. One note for CODE-DESIGN-VALIDATOR /
ELIXIR-DEV: `Repo.checkout/2`'s callback is a zero-arity function returning its result
directly (confirmed against `deps/ecto/lib/ecto/repo.ex`'s generated `checkout/2`,
which just calls `adapter.checkout(meta, opts, fun)` — no special return-value
wrapping) — so `with_only_this_tenant_visible!/2`'s existing return-value contract
(returns `fun.()`'s result) is preserved unchanged by adding the `Repo.checkout/2`
wrapper around it.
