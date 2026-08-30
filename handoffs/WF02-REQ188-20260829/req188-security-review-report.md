# REQ-188 Security Review — SECURITY-REVIEWER

**Run:** WF02-REQ188-20260829, Step 2c
**Verdict:** PASS
**Files reviewed:** `lib/letflow/scheduler.ex`, `lib/letflow/scheduler/timer.ex`,
`lib/letflow/scheduler/poller.ex`, against
`lib/letflow/design/req188-recurring-timers-and-retention.md` and
`docs/agents/instructions/security-invariants.md`.

## Scope test

Diff touches a tenant-scoped table (`timers`, via `maybe_rearm_timer/3` /
`build_rearm_attrs/2` / widened `rearm_changeset/2`) and a data-access path that
deletes/archives tenant business data (`run_retention_sweep/1` wrapping
`Letflow.EventStore.archive/1`). In scope.

## INV-1 — Tenant data isolation — APPLIES — PASS

**Retention sweep.** Read `Letflow.EventStore.archive/1` directly
(`lib/letflow/event_store.ex:989-1001`): `prefix = Keyword.get(opts, :prefix)` is
threaded into every subsequent call — `compute_archive_target_event_ids(prefix, ...)`,
`archive_phase1_insert(prefix, event_ids)` (whose internal `Repo.all`/`Repo.insert_all`
calls both pass `prefix: schema_name`), and `archive_phase2_delete(prefix, event_ids)`
(whose `Repo.delete_all` calls on `StoredPayload`, `ArchivedEvent`, and `Event` all pass
`prefix: schema_name`). No query in the archive path omits `:prefix`. The eligible
`event_id` set itself is computed per-schema (`eligible_by_cutoff/3`,
`eligible_beyond_count/3` etc. all take `schema_name` and query within it) — there is no
code path where an event_id computed against one schema's data could be deleted against
another schema's connection, since Postgres schema-scoping via `:prefix` changes which
physical table the query hits.

`Letflow.Scheduler.run_retention_sweep/1` (`scheduler.ex:564-566`) does nothing but
`EventStore.archive(prefix: tenant_schema, retention_days: retention_days())` — the
`tenant_schema` argument passed straight through, never rederived.

`Letflow.Scheduler.Poller.maybe_run_retention_sweep/2` (`poller.ex:76-83`) calls
`Enum.each(schemas, fn schema_name -> Scheduler.run_retention_sweep(schema_name) end)` —
confirmed a per-schema loop, one `run_retention_sweep/1` call per tenant schema, never a
combined/batched list passed as a single argument.

**Re-arm.** `build_rearm_attrs/2` (`scheduler.ex:391-407`) carries `tenant_id:
fired_timer.tenant_id` and `instance_id: fired_timer.instance_id` forward from the fired
timer's own struct — never re-derived from any other source, never accepted as a
separate caller-supplied field (satisfies 0003's addendum: `tenant_id` is not an
independently-writable field here, it is copied from the row that is itself already
scoped to `tenant_schema`). The insert (`scheduler.ex:380-382`) is
`Repo.insert(changeset, prefix: tenant_schema)` where `tenant_schema` is the same
argument `maybe_rearm_timer/3` received from `do_fire/2`, which received it from
`fire_timer/2`'s own parameter — the same schema the firing transaction is already
scoped to end to end. No cross-tenant path exists: the fired timer was fetched via
`fetch_and_lock_timer(timer_id, tenant_schema)` under that same `tenant_schema`, and the
new row is written back into that same prefix.

**Same-transaction proof.** `maybe_rearm_timer/3` is called as the last step of
`do_fire/2`'s `with` chain (`scheduler.ex:287`), and `do_fire/2` itself is only ever
invoked from inside `fire_timer/2`'s `Repo.transaction(fn -> ... end)` (`scheduler.ex:244-260`).
`maybe_rearm_timer/3` opens no transaction of its own — its `Repo.insert/2` call runs on
the ambient `Letflow.Repo` inside the already-open transaction function, so a changeset
failure there returns `{:error, changeset}` which the `with` chain's `else` clause turns
into `Repo.rollback/1`, rolling back the firing update, the `TIMER_FIRED` event append,
and the engine-advance step together with the failed re-arm — no window where the firing
commits without its re-arm, or vice versa. Confirmed against the actual code, not just
the moduledoc's claim.

(a) prefix-scoped: yes, both paths. (b) no table left reachable in `public`: no
migration in this diff — `timers` and `events`/`events_archive` already tenant-scoped
from REQ-186/REQ-023. (c) `tenant_id` derived from resolved context, not
caller-supplied-and-divergent: yes, carried forward from `fired_timer.tenant_id`, itself
originally derived from `:prefix` at arm time (`build_arm_changeset/2`, unchanged by
this diff).

## INV-2, INV-3, INV-5 — NOT APPLICABLE

S4 (API surface)/S5 (scripting sandbox) have not started; no lookup-by-ID endpoint or
API response type is touched by this diff.

## INV-4 — Secrets by reference only — APPLIES — PASS

```
grep -rn "System.get_env" ... (no hits in the three changed files -- none expected, no secret-adjacent config added)
grep -rniE "(password|secret|client_secret|token)\s*(=|:)\s*\"[^\"]{8,}" lib/letflow/scheduler.ex lib/letflow/scheduler/timer.ex lib/letflow/scheduler/poller.ex
```
Zero hits. No secret material is introduced, logged, or threaded through any of the
three changed files.

## INV-6 — New data-access paths prove their scoping — APPLIES — PASS

This report is that proof: INV-1's applicability and satisfaction are stated explicitly
above with the concrete grep/read evidence, not inferred from "it compiles."

## INV-7 — No SQL string interpolation — APPLIES — PASS

```
grep -rn "Repo.query" lib/letflow/scheduler.ex lib/letflow/scheduler/timer.ex lib/letflow/scheduler/poller.ex
```
Zero hits. All access is via `Ecto.Query`/`Repo.insert`/`Repo.update`/`Repo.all`, all
parameterised by construction.

## INV-8 — No unhandled crashes on realistic failure paths — APPLIES — PASS

```
grep -n "^\s*{:ok, .*} = " lib/letflow/scheduler.ex lib/letflow/scheduler/timer.ex lib/letflow/scheduler/poller.ex
```
Two hits, both **pre-existing code untouched by this diff** (confirmed via
`git diff main...HEAD -- lib/letflow/scheduler.ex`, neither line appears in the diff
hunks): line 148 (`build_arm_changeset/2`, REQ-186) and line 504
(`land_exhausted_timer/3`, REQ-187). REQ-188's own new code —
`maybe_rearm_timer/3`, `build_rearm_attrs/2`, `run_retention_sweep/1`,
`retention_due?/1`, the three retention config accessors, and `Poller`'s new
`maybe_run_retention_sweep/2` — introduces no bare `{:ok, _} = ...` match; every
tagged-tuple-returning call (`Repo.insert/2` in `maybe_rearm_timer/3`,
`EventStore.archive/1` in `run_retention_sweep/1`) is handled via `case`/`with`, and
`run_retention_sweep/1`'s own `{:error, term()}` return is passed straight through
unhandled-crash-free to its caller (`Poller`'s `Enum.each`, which per design §2.4/AC 6
is acceptable — an errored sweep for one schema does not raise, it simply returns a
value nobody currently inspects; this mirrors the existing `poll_and_fire/1` per-schema
loop's own tolerance and is not a new defect this diff introduces).

## Retention-disabled-by-default — explicitly re-verified per task instructions

`@default_retention_enabled false` (scheduler.ex:95, literal `false`, not a doc claim).
`retention_enabled?/0` is `scheduler_config()[:retention_enabled] || @default_retention_enabled`
— with no application config set, `scheduler_config()` returns `[]`,
`[][:retention_enabled]` is `nil`, `nil || false` evaluates to `false`. Confirmed no
`config/*.exs` in this repo sets `:retention_enabled` (`grep -rn "retention_enabled"
config/` → zero hits). `Poller.maybe_run_retention_sweep/2` is the only call site of
`run_retention_sweep/1` in the entire diff (confirmed by reading all three files in
full) and its `if Scheduler.retention_enabled?() and ...` guard is the only gate —
with the default config, this `if` never takes its `do` branch, so `run_retention_sweep/1`
(and therefore `EventStore.archive/1`) is invoked zero times per tick, for the lifetime
of the process, on an unconfigured deployment.

## Other acceptance criteria checked

- `git diff main...HEAD --stat` shows `lib/letflow/application.ex` with **zero** diff
  lines (confirmed via `git diff main...HEAD -- lib/letflow/application.ex` → empty
  output). No route/controller file added or touched (confirmed: stat output contains
  no router/controller path).
- The moduledoc's flagged `actor_id` sentinel section (REQ-187, pre-existing) is
  unchanged by this diff's additions; the new REQ-188 moduledoc section (partition
  deferral, SCH-04 deferral) states facts already independently verified in the design
  doc (ISS-0014 resolution, `graph.ex`'s `check_timer_duration/1` scope) and introduces
  no new claim that papers over a gap — both deferrals are honestly named, not silently
  dropped.

## Conclusion

All applicable invariants (INV-1, INV-4, INV-6, INV-7, INV-8) PASS. INV-2/3/5 remain
NOT-APPLICABLE (S4/S5 not started). No security defect found. Routing to REVIEWER for
the idiom/scope-creep gate.
