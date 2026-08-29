# SECURITY-REVIEWER report — REQ-186 (timers schema and scheduler core)

Verdict: **PASS**

Scope test: this diff adds a migration touching a new business table
(`timers`), a Poller/Scheduler that reads/writes tenant-scoped data, and a
DLQ-landing write path — squarely a tenant-data path. Reviewed against
INV-1..INV-8 individually, reading the actual shipped code
(`lib/letflow/scheduler.ex`, `lib/letflow/scheduler/timer.ex`,
`lib/letflow/scheduler/poller.ex`,
`priv/repo/migrations/20260829020001_create_timers.exs`,
`lib/letflow/application.ex`, `lib/letflow/tenant_provisioning.ex`), not
trusting the design doc's or ELIXIR-DEV's own claims.

## INV-1 — Tenant data isolation — APPLIES, PASS

- `Letflow.Scheduler.claim_due_timer_ids/2` (scheduler.ex:179-192) builds the
  `FOR UPDATE SKIP LOCKED` claim query via `Ecto.Query` composition
  (`where/3`, `order_by/3`, `limit/3`, `select/3`, `lock/2`) and calls
  `Repo.all(query, prefix: tenant_schema)` — the tenant schema passed in by
  the caller (`Poller.handle_info/2`, one call per row of
  `TenantProvisioning.Registration`). No query in this module ever omits
  `prefix:`.
- `fetch_and_lock_timer/2` (scheduler.ex:257-262), the fire-transaction's own
  row re-fetch, likewise runs `Repo.one(prefix: tenant_schema)`.
- `do_fire/2`'s `Repo.update(prefix: tenant_schema)` (scheduler.ex:226) and
  `record_fire_failure/2`'s `Repo.update(prefix: tenant_schema)`
  (scheduler.ex:313) are both scoped identically.
- `Letflow.Scheduler.Poller.handle_info(:tick, state)` (poller.ex:51-58)
  iterates every schema returned by `tenant_schemas/0`
  (`Registration` filtered `where: not is_nil(r.migrations_applied_at)`,
  poller.ex:60-65) and calls `Scheduler.poll_and_fire(schema_name)`
  per schema — there is no code path where one tenant's schema name is
  substituted for another's inside a single iteration: `schema_name` is the
  loop variable itself, threaded straight through to every
  `Repo.*(..., prefix: tenant_schema)` call inside `poll_and_fire/1`'s call
  graph. No shared/global connection or cached prefix crosses iterations.
- Migration: `if prefix() do ... end` guard wraps the entire `create table`,
  both `create constraint/3` calls, and the partial index
  (migration lines 72-122) — confirmed by reading the file directly, not the
  header comment. `tenant_id` (line 75) is populated server-side in
  `Letflow.Scheduler.build_arm_changeset/2` (scheduler.ex:104-105,120-125)
  via `TenantProvisioning.tenant_id_for_schema_name(prefix)` — never accepted
  as a separate key from `arm_attrs()` (the `@type arm_attrs` at
  scheduler.ex:60-70 has no `:tenant_id` key, and `build_arm_changeset/2`'s
  `Map.take/2` allowlist at lines 108-119 does not include it either, so even
  a caller passing `tenant_id` in `attrs` would have it silently dropped
  before the changeset is built).
- `timers` is registered in
  `Letflow.TenantProvisioning.@tenant_scoped_migration_manifest`
  (tenant_provisioning.ex diff, confirmed) — both halves of the "guarded
  migration + registered manifest entry" requirement are present.

(a)/(b)/(c) of INV-1's how-to-verify are all confirmed: (a) every query
scoped via `prefix:`, (b) the table is unreachable outside that mechanism
(guarded, registered), (c) `tenant_id` derived server-side, never
caller-supplied.

## DLQ-landing — PASS

`land_exhausted_timer/3` (scheduler.ex:329-354) calls
`Dlq.enqueue(dlq_attrs, prefix: tenant_schema)` — `tenant_schema` is the same
argument threaded through `attempt_fire/2` → `record_fire_failure/2` →
`land_exhausted_timer/3`, originating from the same tenant-schema value the
current `poll_and_fire/1` call was invoked with. `Letflow.Dlq.enqueue/2`
itself derives `tenant_id` from `opts[:prefix]` server-side
(`dlq.ex:81-85`), so there is no way for a timer belonging to tenant A's
schema to land a DLQ row in tenant B's `dlq_entries` — the same `prefix`
value is used for the timer's own row update, the retry-increment update,
the fail transition, and the DLQ enqueue, all inside one `Repo.transaction/1`
(scheduler.ex:302-322).

## Migration tenant-scoping (Decision 0003 Decision B) — PASS

Confirmed by direct read of
`priv/repo/migrations/20260829020001_create_timers.exs`: `if prefix() do`
guard wraps `create table(:timers, ..., prefix: prefix())`, the partial index
`idx_timers_pending_fire_at` on `(fire_at) WHERE status = 'pending'`
(lines 100-104, `prefix: prefix()`), `chk_timers_status` CHECK admitting
exactly `pending`/`fired`/`cancelled`/`failed` (lines 106-109), and
`chk_timers_recurrence_shape` (lines 111-121) matching the design's
all-or-nothing shape verbatim (both `NULL`-quartet and non-null-quartet
branches, `fired_count >= 0`, `repeat_total >= 1 AND fired_count <=
repeat_total` when `repeat_total` is present). All three DDL objects are
built via `Ecto.Migration`'s `create table/2`, `create index/2`,
`create constraint/3` — no raw `execute/1`/string-built DDL anywhere in this
migration (a deviation from the design doc's own §1.3, which anticipated a
raw `execute/1` two-argument form; ELIXIR-DEV instead used the built-in
`constraint/3` builder, matching the more recent
`20260818090001_create_promotion_assertion_runs.exs` precedent cited in the
migration's own header comment — functionally equivalent, and arguably
safer since it uses Ecto's own DDL builder rather than hand-written SQL;
not a security defect).

## No raw/interpolated SQL (INV-7) — APPLIES, PASS

`grep -rn "Repo.query" lib/ priv/repo/migrations/` shows zero hits inside
`lib/letflow/scheduler.ex`, `lib/letflow/scheduler/poller.ex`,
`lib/letflow/scheduler/timer.ex`, or the new migration. The claim query
(scheduler.ex:183-191) is built entirely via `Ecto.Query` macros/functions
(`where/3`, `order_by/3`, `limit/3`, `select/3`, `lock/2`) — `lock("FOR
UPDATE SKIP LOCKED")` is a literal, non-interpolated string argument to
`Ecto.Query.lock/2`, not string-concatenated with any tenant- or
user-controlled value. The pre-existing `Repo.query!` hits elsewhere in the
codebase (`sandbox_pool.ex`, `tenant_provisioning.ex`,
`sandbox_pool/fixture_loader.ex`) are untouched by this diff (confirmed via
`git diff main...HEAD --stat`) and out of this review's scope.

## Crash isolation (INV-8) — APPLIES, PASS

Read the actual transaction/rescue boundaries, not the design's or the
moduledoc's own claims:

- `fire_timer/2` (scheduler.ex:200-217) wraps its whole body in
  `Repo.transaction/1`; any raise inside the anonymous function is caught by
  `Repo.transaction/1`'s own semantics (rolls back, but does *not* itself
  convert a raise to `{:error, _}` — it re-raises by default). The design
  doc's own §2.4 flags this exact point.
- `attempt_fire/2` (scheduler.ex:270-283) is the outer defense-in-depth
  layer the design doc calls for: `fire_timer(timer_id, tenant_schema)` is
  called inside an explicit `try ... rescue exception -> {:error,
  {:raised, exception}} end` (lines 272-276) — a raise that escapes
  `fire_timer/2`'s own `Repo.transaction/1` (e.g. the transaction's internal
  raise-and-reraise behavior) is caught here and converted to a normal
  `{:error, _}` value, never propagating further. Verified this is a real
  `try/rescue`, not a `with`/`case` that merely pattern-matches an already-ok
  shape.
- Any `{:error, _}` result routes to `safe_record_fire_failure/2`
  (scheduler.ex:293-297), itself wrapped in its own `rescue _exception ->
  :errored` — a second independent guard, so even a raise inside the
  failure-accounting transaction (`record_fire_failure/2`, e.g. a
  constraint violation on the retry-increment update or `Dlq.enqueue/2`
  itself raising) cannot escape `attempt_fire/2`.
- `poll_and_fire/1` (scheduler.ex:149-170) calls `attempt_fire/2` inside a
  plain `Enum.reduce/3` over the claimed id list — no `Enum.each` or `with`
  chain that halts on the first non-`:fired` result, and (per the two rescue
  layers above) no raise ever reaches this loop to short-circuit it
  implicitly either. Every claimed id is attempted regardless of any prior
  id's outcome.
- `Poller.handle_info(:tick, state)` (poller.ex:51-58) calls
  `Scheduler.poll_and_fire(schema_name)` once per tenant schema inside a
  plain `Enum.each/2` — since `poll_and_fire/1` is verified above to never
  raise (both rescue layers cover every path that could otherwise raise),
  one tenant's poll pass cannot crash the `Poller` process or prevent the
  next tenant schema's pass in the same tick from running.

Net: a raising fire attempt for one tenant/timer is trapped at two
independent layers before it could reach the per-tenant loop, and the
per-tenant loop itself has no short-circuit — so it cannot crash or block
another tenant's poll cycle, and cannot block remaining timers within the
same tenant's own poll cycle either.

## No data leakage — PASS (nothing serialized cross-tenant)

`Timer` structs are never returned across a tenant boundary — `poll_and_fire/1`
returns only a `poll_result()` map of counts (`tenant_schema`, `claimed`,
`fired`, `errored`, `exhausted`), no row contents. The `TIMER_FIRED` event
payload (scheduler.ex:236-244) contains only that timer's own
`id`/`node_id`/`timer_type`/`fire_at`/computed fields and is appended via
`EventStore.append(event_attrs, prefix: tenant_schema)` — landing in the
same tenant's own event store, not a cross-tenant or global one. The DLQ
`error_detail` map (scheduler.ex:340-346) is built entirely from the one
timer row already locked under that same tenant's own transaction. No route
or controller exists in this diff (confirmed: `git diff main...HEAD --stat`
shows no file under `lib/letflow/api/` or `lib/letflow/routers/`), so INV-2/
INV-5 remain NOT-APPLICABLE as before (S4 not started).

## Other invariants

- INV-2, INV-3, INV-5: NOT-APPLICABLE — no API response-shaping/lookup-by-ID
  endpoint exists in this diff (S4/S5 not reached by this change).
- INV-6: satisfied by this handoff's own existence and explicit per-invariant
  statement.

## One non-blocking flag (not a security defect, noted for REVIEWER)

`Letflow.Scheduler`'s own moduledoc (scheduler.ex:24-39) documents that it
substitutes `EventStore.platform_actor_id()` for the design doc's literal
`actor_id: nil`, because `EventStore.append/2`'s `fetch_uuid/3` helper
rejects a `nil` actor_id with `{:error, :missing_actor_id}`. Verified this
claim directly against `lib/letflow/event_store.ex`
(`fetch_uuid(attrs, :actor_id, :missing_actor_id)` at line 222) — confirmed
accurate, not a made-up justification, and not a security concern
(`platform_actor_id/0` is this codebase's own established sentinel for
system-initiated events, already used elsewhere per the moduledoc's own
citation). Flagging only because ELIXIR-DEV explicitly asked for
SECURITY-REVIEWER/REVIEWER eyes on it — REVIEWER's own idiom/consistency
gate is the more appropriate place to decide whether the design doc itself
needs a one-line correction.

## Verdict

**PASS.** No BLOCKER found on any applicable invariant (INV-1, INV-4, INV-7,
INV-8 all satisfied; INV-2/3/5 not-applicable, scope test explicitly run;
INV-6 satisfied by this handoff). Routes next to REVIEWER per WF-02 Step 2c's
gate sequence.
