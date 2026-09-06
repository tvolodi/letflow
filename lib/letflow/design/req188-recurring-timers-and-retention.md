# REQ-188 — Recurring timers (SCH-07) and the periodic retention runner

**Status:** design (Step 1, WF-02, run WF02-REQ188-20260829)
**Depends on (already shipped):** REQ-186 (`lib/letflow/design/req186-scheduler-core.md`
— `timers` table, `Letflow.Scheduler.create/2`, `poll_and_fire/1`, the recurrence-quartet
CHECK constraint), REQ-187 (`Letflow.Scheduler.fire_timer/2`/`do_fire/2`'s one-transaction
fire path, `TaskActivation.cancel_pending_timers/2`, `Engine.advance_after_timer_fired/3`),
REQ-026 (`Letflow.EventStore.archive/1`, `event_retention_policies`).

## 0. Moduledoc-mandated deferral statements (must appear verbatim-in-substance in the
   shipped `Letflow.Scheduler` moduledoc)

Two things are explicitly OUT of scope for this requirement, and the reason each is out
of scope must be stated in the moduledoc, not silently omitted:

1. PROVENANCE (historical, not current decision authority):
   **R-Co's `src/scheduler/partition_maintenance.zig` and `partition_retention.zig` are
   NOT ported.** Both operate on a `PARTITION BY RANGE` events table via
   `DETACH`/`ATTACH`/`DROP`. Letflow's `events` table is not partitioned —
   `docs/migration/decisions/0003-ecto-schema-strategy.md`'s Dimension C, point 2
   ("Partitioning: deferred, not built in from day one") deliberately defers
   partitioning, and `docs/issues/ISS-0014.yaml` (resolved 2026-08-17) already
   adjudicated this exact question: it adopted **option (a)** — port row-level
   `archive/1` as-is — and explicitly **rejected option (c)** — porting
   `PartitionRetention`'s whole-partition model now — "because it would force
   partitioning early, contradicting 0003 Decision C's deliberate deferral, and would
   need REVIEWER sign-off / a new decision record." This requirement schedules the
   `archive/1` that already exists; partition-based retention stays deferred pending a
   future partitioning decision record, named here so the omission is a recorded
   boundary, not a silent gap.
2. **SCH-04 escalation timers are deferred.** SCH-04 requires a `:HUMAN_TASK` node
   carrying an `escalation_timer_duration` attribute. Verified directly against
   `lib/letflow/definitions/graph.ex` for this design: CHK-12
   (`check_timer_duration/1`, line 738) validates `duration_iso8601` on `:TIMER` nodes
   only; no check anywhere in `graph.ex` references `escalation_timer_duration`, and no
   such attribute exists on `:HUMAN_TASK` today. The definition-side input this
   escalation mechanism would consume does not exist, so escalation timers need a
   definitions-side requirement first — named here rather than silently dropped.

Both statements are non-negotiable acceptance-criterion text (REQ-188 AC 8) — whoever
writes `Letflow.Scheduler`'s moduledoc extension must include them.

## 1. PART 1 — SCH-07 recurring timers

### 1.1 Scope and non-goals

- In scope: given a **fired** timer whose recurrence quartet
  (`repeat_expression`/`repeat_interval_us`/`repeat_total`/`fired_count`) is non-null
  (REQ-186's `chk_timers_recurrence_shape` already guarantees all-or-nothing), compute
  the next occurrence's `fire_at` and insert a new `"pending"` timer row, in the SAME
  `Repo.transaction/1` `Letflow.Scheduler.fire_timer/2` already opens.
- **Explicitly not in scope, and not built here:** parsing the ISO 8601 repeat-syntax
  text itself (`"R/PT1H"`, `"R3/PT1H"`) into an interval/count pair. See open question
  OQ-1 below — this design takes `repeat_interval_us` as already-computed and
  authoritative, and treats `repeat_expression` purely as a carried-forward audit
  string. No requirement to date defines how a recurring timer's FIRST occurrence gets
  armed (REQ-186/187's own TIMER-node arming path, `transition.ex`, only ever sets
  `duration_iso8601`-derived `fire_at` with no recurrence fields) — that is out of
  scope for REQ-188 too; this design only covers the fire→re-arm loop for a timer row
  that already carries the quartet, however it got there.

### 1.2 New function: `Letflow.Scheduler.maybe_rearm_timer/3`

```
@spec maybe_rearm_timer(
        fired_timer :: Letflow.Scheduler.Timer.t(),
        fired_at :: DateTime.t(),
        tenant_schema :: String.t()
      ) :: {:ok, :rearmed | :not_recurring | :series_complete} | {:error, Ecto.Changeset.t()}
```

Called once, from inside `do_fire/2` (private, unchanged signature/location), as the
LAST step of its existing `with` chain — after `Engine.advance_after_timer_fired/3`
succeeds, before `do_fire/2` returns `{:ok, :fired}`. Never called anywhere else; never
opens its own transaction (it runs on the caller's `Repo`/`prefix`, inside the caller's
already-open `Repo.transaction/1` function, matching how `append_timer_fired_event/4`
and the engine-advance call already behave).

Behavior, by case, driven entirely off `fired_timer` (the struct captured BEFORE
`fire_changeset/2`'s update — none of the recurrence fields change on fire, so the
pre-update struct is equivalent and avoids a second read):

1. `fired_timer.repeat_expression == nil` → `{:ok, :not_recurring}`. No row inserted.
   (The CHECK constraint guarantees `repeat_interval_us`/`repeat_total`/`fired_count`
   are also `nil` in this case — a single field check is sufficient.)
2. `fired_timer.repeat_expression != nil`: let
   `new_fired_count = fired_timer.fired_count + 1`.
   - If `fired_timer.repeat_total != nil` and
     `new_fired_count >= fired_timer.repeat_total` → `{:ok, :series_complete}`. No row
     inserted — the series has reached its cap. (For `repeat_total: 3`: the row armed
     with `fired_count: 0` fires once → `new_fired_count = 1 < 3` → re-arm with
     `fired_count: 1`; that row fires → `new_fired_count = 2 < 3` → re-arm with
     `fired_count: 2`; that row fires → `new_fired_count = 3`, not `< 3` → no re-arm.
     Exactly 3 firings, 3 timer rows total, matching AC 2's "fourth poll creates no new
     timer" via a `SELECT count(*) FROM timers` after 3 fire cycles.)
   - Otherwise (unbounded, `repeat_total == nil`, or still under the cap): build and
     insert a new row (§1.3) with `fired_count: new_fired_count`, returning
     `{:ok, :rearmed}` on success or `{:error, changeset}` on a changeset/DB failure
     (which — per `with`'s short-circuit — rolls back the whole `fire_timer/2`
     transaction, exactly like any other step failing).

**`fire_at` anchor — nominal, not actual.** The new row's `fire_at` is
`DateTime.add(fired_timer.fire_at, fired_timer.repeat_interval_us, :microsecond)` — the
timer's own SCHEDULED fire time plus the interval, never `fired_at`/`now` (the moment it
actually fired). This is deliberate: anchoring to the nominal schedule prevents drift
accumulation from poll latency, and is what AC 1 literally asserts ("fire_at equal to
the fired timer's fire_at plus one hour" — the fired timer's `fire_at`, not the actual
firing timestamp).

### 1.3 New row shape (mirrors `build_arm_changeset/2`'s existing pattern exactly)

A new private helper, `build_rearm_attrs/2` (`fired_timer`, `new_fired_count` ->
insert-ready attrs map), constructs:

| Field | Value |
|---|---|
| `id` | fresh `Ecto.UUID.generate/0` |
| `tenant_id` | `fired_timer.tenant_id` (carried forward, never re-derived) |
| `instance_id` | `fired_timer.instance_id` (carried forward) |
| `token_id` | `fired_timer.token_id` (carried forward, may be `nil`) |
| `timer_type` | `fired_timer.timer_type` (carried forward) |
| `node_id` | `fired_timer.node_id` (carried forward — same node re-arms) |
| `fire_at` | computed per §1.2's anchor rule |
| `status` | forced `"pending"` — never caller-controlled, same discipline as `build_arm_changeset/2` forcing `status` |
| `repeat_expression` | `fired_timer.repeat_expression` (carried forward unchanged) |
| `repeat_interval_us` | `fired_timer.repeat_interval_us` (carried forward unchanged) |
| `repeat_total` | `fired_timer.repeat_total` (carried forward unchanged, may be `nil`) |
| `fired_count` | `new_fired_count` (computed, §1.2) |
| `created_at` | `DateTime.utc_now() \|> DateTime.truncate(:microsecond)` |

`Letflow.Scheduler.Timer.rearm_changeset/2` (already declared, currently a stub reserved
for this requirement — casts only `[:status, :fire_at, :repeat_expression,
:repeat_interval_us, :repeat_total, :fired_count]`) must be WIDENED by this
requirement's implementer to also cast `[:id, :tenant_id, :instance_id, :token_id,
:timer_type, :node_id, :created_at]` — the same full field list `arm_changeset/2` casts
— since `build_rearm_attrs/2` produces a complete new-row map, not a partial update.
Add `validate_required/2` for
`[:id, :tenant_id, :instance_id, :timer_type, :node_id, :fire_at, :status,
:repeat_expression, :repeat_interval_us, :fired_count, :created_at]` (`repeat_total`
stays optional/nullable — the unbounded-repeat case). The insert itself is
`Repo.insert(changeset, prefix: tenant_schema)`, a plain call inside the already-open
transaction function (same idiom `fetch_and_lock_timer/2`/`Repo.update` already use in
this module) — no `Ecto.Multi` introduced, matching `fire_timer/2`'s existing
plain-function transaction shape.

### 1.4 Cancellation — no new code, inherited from REQ-187 as-is

AC 3 ("a recurring timer whose instance is cancelled does not re-arm") requires **zero**
new logic. `TaskActivation.cancel_pending_timers/2` (REQ-187) sets every `"pending"`
timer for the instance to `"cancelled"`. `claim_due_timer_ids/2` (REQ-186, unchanged)
only ever selects `WHERE status = 'pending'`. A cancelled recurring timer is therefore
never claimed by any future poll, never fires, and `maybe_rearm_timer/3` is never
invoked for it — the chain terminates structurally, not via a new cancellation check.
This design deliberately adds no recurrence-aware branch to the cancellation path.

The other SCH-03 race — the timer already claimed and mid-fire when a concurrent
`cancel_instance/3` commits first — is also unchanged: `Engine.advance_after_timer_fired/3`
already returns `{:error, {:instance_not_active, _status}}` in that race (REQ-187), and
`maybe_rearm_timer/3` sits AFTER that call in `do_fire/2`'s `with` chain (§1.2), so if
the engine-advance step fails, re-arm is never attempted and the whole transaction rolls
back together — no fired timer AND no orphaned new-row on a cancelled instance.

### 1.5 "At most once per cycle" and SCH-05 restart interaction — structural, not new code

AC 4 (interval shorter than the poll interval) and the SCH-05 restart-catch-up note are
BOTH satisfied by the existing claim-then-fire architecture, with no additional
timestamp bookkeeping:

- `Letflow.Scheduler.Poller`'s `:tick` handler calls `poll_and_fire/1` once per tenant
  schema per tick. `poll_and_fire/1` calls `claim_due_timer_ids/2` exactly ONCE per
  invocation, producing a fixed list of timer ids to attempt THIS cycle.
- A newly re-armed row (§1.2/§1.3) is inserted AFTER that fixed list was already
  computed (it is a brand-new row with a brand-new `id`, created inside the very
  transaction that is firing the PREVIOUS occurrence). It is structurally impossible
  for the current cycle's `claim_due_timer_ids/2` call to have already included it —
  the row did not exist when that query ran.
  - Consequence for AC 4: even if the new row's computed `fire_at` is already `<= now`
    at the moment it commits (interval shorter than the poll interval), it simply waits
    for the NEXT `:tick` to be claimed — one firing per tick, never N catch-up firings
    in one tick, for exactly one chain.
  - Consequence for SCH-05 (restart after a missed window): at any moment a recurring
    chain has AT MOST ONE `"pending"` row outstanding (the row for its next occurrence
    — a new row is created only when the previous one fires, never speculatively ahead
    of it). So even if that one row's `fire_at` is far in the past after a long outage,
    `claim_due_timer_ids/2` claims it once, `fire_timer/2` fires it once, and exactly
    one re-armed successor row is created — never a burst of N backlogged occurrences
    for the same chain. Catching up to the present (if the interval is short relative
    to the outage) happens one tick, one firing, at a time, across however many ticks
    it takes — never within a single tick.

## 2. PART 2 — periodic retention runner

### 2.1 Config (extends `Letflow.Scheduler`'s existing `scheduler_config()` accessor
   pattern — `Application.get_env(:letflow, :scheduler, [])`)

| Key | Accessor | Default | Meaning |
|---|---|---|---|
| `:retention_enabled` | `Letflow.Scheduler.retention_enabled?/0` | `false` | Opt-in switch. A retention sweep deletes rows (moves them out of `events`); no Letflow deployment has ever run one, so the default must never invoke `archive/1`. |
| `:retention_interval_ms` | `Letflow.Scheduler.retention_interval_ms/0` | `86_400_000` (24h) | Minimum wall-clock gap between two retention sweeps. Independent of, and typically much larger than, `poll_interval_ms/0`. |
| `:retention_days` | `Letflow.Scheduler.retention_days/0` | `90` | The global-fallback `retention_days` value passed to `EventStore.archive/1` for every tenant schema (see OQ-2 — there is no per-tenant override column). |

```
@spec retention_enabled?() :: boolean()
@spec retention_interval_ms() :: pos_integer()
@spec retention_days() :: non_neg_integer()
```
All three follow the exact `scheduler_config()[:key] || @default` shape the four
existing accessors (`poll_interval_ms/0` etc.) already use — no new config-reading
mechanism introduced.

### 2.2 New function: `Letflow.Scheduler.run_retention_sweep/1`

```
@spec run_retention_sweep(tenant_schema :: String.t()) ::
        {:ok, Letflow.EventStore.archive_result()} | {:error, term()}
def run_retention_sweep(tenant_schema) when is_binary(tenant_schema)
```

Unconditional — does NOT itself check `retention_enabled?/0` (that gate lives in the
caller, §2.3, exactly so it stays directly unit-testable the same way
`Letflow.Scheduler.poll_and_fire/1` already is, per `application.ex`'s own documented
precedent that "any test of the Poller GenServer itself starts its own instance
explicitly" / "Letflow.Scheduler's own tests call `poll_and_fire/1` directly"). Body:
`EventStore.archive(prefix: tenant_schema, retention_days: retention_days())`. This is
the function AC 6's test calls directly to assert row-count movement into
`events_archive`, and the function AC 5's test asserts is called ZERO times when
`retention_enabled?/0` is `false`.

### 2.3 New function: `Letflow.Scheduler.retention_due?/1`

```
@spec retention_due?(last_run_at :: DateTime.t() | nil) :: boolean()
```

Pure, directly testable (no DB access), with two cases: a `nil` `last_run_at` means
"never run before," so it is due immediately — mirroring `Poller.init/1`'s own
zero-delay-first-tick philosophy for `:tick`. A non-`nil` `last_run_at` is due once the
elapsed wall-clock time since it (in milliseconds) reaches or exceeds
`retention_interval_ms()`; otherwise it is not yet due.

### 2.4 `Letflow.Scheduler.Poller` — same process, extended state, no new child

**This is the one deliberate, explicitly-flagged change to `Poller`'s documented
"no meaningful state carried between ticks" property.** Its `state` widens from `%{}` to
`%{last_retention_run_at: DateTime.t() | nil}`, initialized to `nil` in `init/1`
alongside the existing `Process.send_after(self(), :tick, 0)` call. This must be called
out explicitly in `Poller`'s own moduledoc as a REQ-188 addition, not silently changed
in place — the moduledoc's existing "no meaningful state" sentence becomes false and
must be corrected to describe exactly this one field and why it exists (retention
cadence bookkeeping, nothing else).

`handle_info(:tick, state)` (existing callback, same message, same trigger) gains one
step, AFTER its existing `Enum.each(tenant_schemas(), &Scheduler.poll_and_fire/1)` line
and BEFORE `schedule_next_tick/0`:

The added step's behavior, described by four properties (no fenced code — it is a
description of the change, not the change itself):

| Property | Behavior |
|---|---|
| Guard | Runs only when both `Scheduler.retention_enabled?()` and `Scheduler.retention_due?(state.last_retention_run_at)` are true; otherwise `state` is left completely unchanged. |
| Schema source | Iterates the same `schemas` list `tenant_schemas()` already produced for this tick's timer-poll loop — computed once, reused, not queried a second time. |
| Sweep call | When the guard passes, calls `Scheduler.run_retention_sweep/1` once per schema in that list. |
| State update | When the guard passes, the resulting state's `last_retention_run_at` becomes `DateTime.utc_now()`; when the guard fails, the state carried into `schedule_next_tick/0` is byte-for-byte the same `state` the callback received. |

**No new supervised child, no new process.** `lib/letflow/application.ex`'s
`scheduler_children/0` is untouched — it still starts exactly
`[{Letflow.Scheduler.Poller, []}]` when `:start_scheduler` is enabled, unchanged from
REQ-186. `git diff --stat` against `application.ex` for this requirement's commits must
show no changes to that file at all (AC 7).

**Default-disabled proof (AC 5).** With `:retention_enabled` unset (defaults `false`),
`retention_enabled?()` is `false` on every tick, the `if` above never takes its `do`
branch, `run_retention_sweep/1` — and therefore `EventStore.archive/1` — is called zero
times, for the lifetime of the process, regardless of how many ticks elapse. This is
asserted directly (not assumed) by exercising `handle_info(:tick, state)` as a plain
function call (ExUnit can call a `@impl true` `handle_info/2` clause directly without
starting the GenServer process, sidestepping the `Ecto.Sandbox` ownership issue
`application.ex`'s own comment already documents for why the Poller is disabled by
default in `config/test.exs`) and asserting on `EventStore.archive/1`'s call count/side
effect (row counts unchanged), or equivalently by calling `run_retention_sweep/1`
directly and asserting `retention_enabled?()` gates its invocation in the surrounding
`Poller` code path.

## 3. DB — no schema changes

No new migration. `timers`' recurrence-quartet columns and `chk_timers_recurrence_shape`
(REQ-186) already exist and are not altered. `event_retention_policies`
(REQ-026, `20260817181240_create_event_retention_policies.exs`) already exists and is
read internally by `EventStore.archive/1`'s own precedence logic (`keep_forever` >
`keep_days` > `keep_count` > the `retention_days` global fallback this requirement
supplies) — unchanged by this requirement.

## 4. Files touched

| File | Change |
|---|---|
| `lib/letflow/scheduler.ex` | Add `maybe_rearm_timer/3`, `build_rearm_attrs/2`; extend `do_fire/2`'s `with` chain with one more step; add `run_retention_sweep/1`, `retention_due?/1`, `retention_enabled?/0`, `retention_interval_ms/0`, `retention_days/0`; extend moduledoc per §0. |
| `lib/letflow/scheduler/timer.ex` | Widen `rearm_changeset/2`'s cast/required lists per §1.3. |
| `lib/letflow/scheduler/poller.ex` | State shape `%{} → %{last_retention_run_at: DateTime.t() \| nil}`; extend `init/1` and `handle_info(:tick, state)` per §2.4; extend moduledoc to flag the state change. |
| `config/*.exs` | Optional — no key requires an explicit entry to be correct (`retention_enabled?/0` already defaults `false`), but `config/test.exs` MAY add an explicit `config :letflow, :scheduler, retention_enabled: false` comment-documenting the default if ELIXIR-DEV judges it clearer; not required by any acceptance criterion. |
| `lib/letflow/application.ex` | **Not touched** (AC 7). |
| Routes/controllers | **Not touched** (AC 9). |

## 5. Invariants

- INV-REARM-1: a re-armed row is inserted in the same `Repo.transaction/1` as the
  firing it re-arms from — never a separate transaction, never fire-and-forget.
- INV-REARM-2: `fired_count` on a chain's rows is strictly increasing by 1 per
  occurrence; once `fired_count >= repeat_total` (when `repeat_total` is set), no
  further row is ever created for that chain.
- INV-REARM-3: a cancelled instance's recurring chain produces no further rows — proven
  structurally (§1.4), not by an explicit check in the re-arm path.
- INV-REARM-4: at most one `"pending"` row exists per recurring chain at any time.
- INV-RETENTION-1: `EventStore.archive/1` is called exactly zero times over the
  process's lifetime whenever `retention_enabled?() == false` — no code path may
  invoke it unconditionally.
- INV-RETENTION-2: enabling retention adds no new supervised process and no new
  independent ticker — it executes on the same `Letflow.Scheduler.Poller` GenServer
  REQ-186 already ships.

## 6. Acceptance-criteria map

| AC (abridged) | Design element |
|---|---|
| 1. `"R/PT1H"` re-arm, same transaction, rollback leaves nothing | §1.2 `maybe_rearm_timer/3` inside `do_fire/2`'s existing `with`; §1.3 row shape; INV-REARM-1 |
| 2. `"R3/PT1H"` stops after 3rd firing | §1.2 case 2, worked through explicitly |
| 3. Cancelled instance does not re-arm | §1.4 (no new code — inherited from REQ-187) |
| 4. Interval shorter than poll interval fires at most once/cycle | §1.5 |
| 5. Retention disabled by default → zero `archive/1` calls | §2.1 default, §2.4 default-disabled proof, INV-RETENTION-1 |
| 6. Retention enabled → `archive/1` invoked, rows moved | §2.2 `run_retention_sweep/1`, §2.4 |
| 7. No second ticker process; `application.ex` untouched | §2.4, §4 |
| 8. Moduledoc names partition_maintenance/partition_retention deferral (0003 Decision C, ISS-0014 (a)/(c)) and SCH-04 deferral (CHK-12 gap) | §0 |
| 9. No route/controller touched | §4 |
| 10. `mix test`/`mix compile --warnings-as-errors` pass | Verified at Step 2a/4/5, not this step |

## 7. Open questions (not silently resolved)

- **OQ-1.** No requirement to date defines how a recurring timer's FIRST occurrence is
  armed (who computes `repeat_interval_us` from `repeat_expression`'s ISO 8601 repeat
  grammar, and calls `Scheduler.create/2` with the quartet populated). This design
  assumes that machinery exists elsewhere (a future definitions-side requirement) and
  only builds the fire→re-arm loop for a row that already carries the quartet. If
  Letflow itself needs to parse `"R[n]/<duration>"` text, that parser does not exist yet
  (unlike `Letflow.Definitions.Graph.parse_iso8601_duration/1`, which only parses a bare
  duration, not the `R.../` repeat prefix) and is not built here.
- **OQ-2.** `retention_days` is one deployment-wide config value, not a per-tenant
  table column. `event_retention_policies` (REQ-026) is a GLOBAL table keyed by
  `event_type` only, with no `tenant_id` column — it already cannot express a
  per-tenant override, so this requirement does not attempt to add one. "The tenant's
  configured retention" in AC 6 is satisfied by applying that single global value
  uniformly, once per tenant schema.
- **OQ-3.** `do_fire/2` calls `Engine.advance_after_timer_fired/3` unconditionally
  today (REQ-187), for every timer type, not only ones sitting on a graph `:TIMER`
  node. Whether that is the correct behavior for a recurring "reminder"/"escalation"
  -type timer that never represents a graph node at all is inherited unchanged and not
  decided by this requirement — §1.2 places `maybe_rearm_timer/3` after that call
  without altering it.
- **OQ-4.** The retention sweep's cadence state (`last_retention_run_at`) is tracked
  GLOBALLY on the `Poller` (one shared clock for all tenants), not per tenant schema —
  chosen for simplicity over the alternative of one cadence per schema. Flagged as an
  explicit choice, reversible if a future requirement needs per-tenant retention
  cadences.
