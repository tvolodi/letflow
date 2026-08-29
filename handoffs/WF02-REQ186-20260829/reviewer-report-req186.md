# REVIEWER report — REQ-186 (WF02-REQ186-20260829 Step 2d)

Verdict: **PASS**

## 1. Idiomatic Ecto/OTP usage vs. sibling modules

- `Letflow.Scheduler` mirrors `Letflow.Dlq`'s shape exactly: plain Ecto
  context module, no process, `opts :: [prefix: ...]` threaded through every
  `Repo` call, `tenant_id` derived server-side via
  `TenantProvisioning.tenant_id_for_schema_name/1`, never caller-supplied.
  `fetch_and_lock_timer/2` (`Timer |> where(...) |> lock("FOR UPDATE") |>
  Repo.one(prefix: ...)`) is the same "lock, then branch on status" idiom as
  `Dlq`'s `fetch_and_lock_entry/3` — `Ecto.Query`'s `lock/2` composition, no
  hand-written SQL, matching INV-7.
- `claim_due_timer_ids/2`'s `FOR UPDATE SKIP LOCKED` is expressed the same
  way, as a literal string argument to `lock/2` — no divergence.
- `Letflow.Scheduler.Timer` mirrors `Letflow.Dlq.Entry`'s multi-changeset
  shape: one changeset per write path (`arm_changeset/2`,
  `fire_changeset/2`, `retry_increment_changeset/2`, `fail_changeset/2`,
  plus `rearm_changeset/2` reserved for REQ-188), `status`/`timer_type` kept
  as plain `:string` with the DB CHECK as backstop, `@primary_key {:id,
  :binary_id, autogenerate: false}` matching `Dlq.Entry`, no `timestamps/1`.
- `Letflow.Scheduler.Poller` is a supervised `GenServer` ticker using
  `Process.send_after/3`, config read fresh every tick via
  `Application.get_env/3` (no compile-time caching) — matches
  `SandboxPool`'s `:provision_timeout_ms` precedent cited in the design.
  Two-transaction failure-accounting shape (fire transaction, then a
  *separate* retry-increment transaction) correctly reproduces the
  ISS-303/ISS-0618 fix rather than doing it by hand inside one transaction.
- Both `attempt_fire/2`'s outer `try/rescue` and `safe_record_fire_failure/2`'s
  own `rescue` are real defense-in-depth over `Repo.transaction/1`'s own
  rollback-on-raise behavior — not a `case`-based hand-rolled state machine
  standing in for a real OTP construct. No `gen_statem` is implicated here;
  this table is CRUD-lifecycle, matching `Dlq.Entry`'s own precedent for not
  needing one.

## 2. Supervision

- No isolation was collapsed. `Letflow.Scheduler.Poller` is one new,
  ordinarily-supervised `GenServer` child of `Letflow.Application`'s
  existing supervisor — not a singleton bypassing supervision, not a bare
  `spawn`. It carries no per-instance state (`@type state :: %{}`), so it
  does not compete with `Letflow.InstanceSupervisor`'s per-instance
  isolation model — the two are orthogonal (Poller drives ticks; each
  timer's own isolation unit is its `Repo.transaction/1`, not a process).
- **No new `Task.Supervisor` was added.** Verified directly: `grep
  Task.Supervisor` across `application.ex`/`scheduler.ex`/`poller.ex` shows
  only the five pre-existing supervisors plus scheduler.ex's own moduledoc
  *stating* it deliberately doesn't add a sixth. This matches REQ-185 §7's
  and REQ-186's design's own explicit decision (transaction/rescue boundary
  only) and REQ-185's REVIEWER sign-off record.
- `scheduler_children/0`'s `config :letflow, start_scheduler: false` gate
  under test is a reasonable, narrowly-scoped deviation from the design
  doc's literal text — the design doc doesn't mention it because it's a
  test-environment concern the design (rightly) left to the implementer,
  and the moduledoc comment states the concrete failure mode
  (`DBConnection.OwnershipError` under `Sandbox`'s `:manual` mode,
  supervisor restart-intensity exceeded, verified live per the comment) that
  motivates it. This is the same shape as `http_child/0`'s existing
  `start_http` gate — not a new pattern, an application of an existing one.

## 3. Scope creep

`git diff main...HEAD --stat` touches exactly: the four new files REQ-186's
design §0 names (migration, `scheduler.ex`, `scheduler/timer.ex`,
`scheduler/poller.ex`), the one `application.ex` diff (the `scheduler_children/0`
addition plus its child-spec line), the one `tenant_provisioning.ex` diff
(manifest entry + `TIMER_FIRED` seed-list entry), `config/test.exs`'s
`start_scheduler: false` line, the design doc itself, handoff/report
bookkeeping files, and three test-support files updated only for accounting
(table count 24→25, event-type count 9→10, in `tenant_fixture.ex`/
`tenant_fixture_test.exs`/`tenant_provisioning_event_seed_test.exs`).

No route or controller file appears anywhere in the diff. No change to
`lib/letflow/engine/transition.ex` (REQ-187's territory — confirmed absent).
No change to `lib/letflow/dlq.ex` itself — REQ-186 only *calls*
`Dlq.enqueue/2`, exactly as REQ-185 §8 specifies; the module itself is
untouched. No `mix.exs` change (no Oban, consistent with REQ-185's Decision
2). No abstraction ahead of scope: `rearm_changeset/2` is defined but never
called, which is intentional and explicitly flagged as reserved for REQ-188
rather than smuggled-in unused machinery — it's a named atom, not
behavior, and the design doc itself calls this out as deliberate so REQ-188
doesn't have to guess a name. This is a defensible, narrow anticipation, not
scope creep proper (no logic, no schema surface, no supervision change rides
along with it).

## 4. Decision-record consistency

- Decision 0003 Decision B: `timers` lives inside each tenant's Postgres
  schema (the migration's `if prefix() do` guard, `tenant_id` retained as an
  intra-schema, never-caller-supplied column) — matches exactly.
- REQ-185's seven decisions, checked one by one against the shipped code:
  supervised `GenServer` ticker (✓ `Poller`), no Oban (✓ no `mix.exs`
  change, no job-queue dependency), `FOR UPDATE SKIP LOCKED` claim (✓
  `claim_due_timer_ids/2`), no startup-sweep lock (✓ no such code path
  exists — the ordinary claim query is the only catch-up mechanism, per
  `init/1`'s zero-delay first tick), per-tenant-schema iteration (✓
  `Poller.tenant_schemas/0` enumerates `Registration` rows with non-nil
  `migrations_applied_at`, iterates via `Enum.each`), per-timer transaction
  isolation with no new process boundary (✓, see §2 above), exhausted timer
  → `dlq_entries` with `entry_type: "timer"` (✓ `land_exhausted_timer/3`).
  None of these are silently re-decided anywhere in the diff.
- Config defaults match REQ-185/REQ-186 exactly: `poll_interval_ms` 5000,
  `jitter_ms` 0, `max_timers_per_cycle` 64, `max_fire_retries` 3 — all four
  read fresh per call via `Application.get_env(:letflow, :scheduler, [])`,
  no compile-time caching, matching `SandboxPool`'s cited precedent.

## 5. Design-vs-implementation fidelity

Schema columns/types/nullability, both CHECK constraints (verbatim SQL
matches design §1.3/§1.4), the partial index, the no-`timestamps/1`
decision, the changeset-per-write-path shape, `poll_and_fire/1`'s
never-raises contract, the claim-then-per-timer-fire two-transaction
structure, the `fired_late`/`scheduled_fire_at`/`actual_fired_at` payload
shape, and the DLQ `enqueue_attrs()` field mapping (`entry_type: "timer"`,
`reference_id: timer.id`, `error_detail` map, `first_failed_at ==
last_failed_at` per the design's own stated OQ-1 imprecision) all match the
design doc's text line for line. `TIMER_FIRED`'s registration in
`tenant_provisioning.ex`'s seed list matches the design's stated
name/schema_version/description/json_schema shape field-for-field.

## 6. The `actor_id` deviation (SECURITY-REVIEWER's flagged item)

**Decision: needs a design-doc correction, and I made it directly** (same
precedent this pipeline used for REQ-168 and for REQ-181's `created_at`
cast fix). The design doc's §6 literally said `actor_id: nil`, reasoning
that "no human/API actor initiates a timer firing" — but that's not
achievable: `Letflow.EventStore.append/2`'s own `fetch_uuid/3` helper
rejects a `nil` `actor_id`, which I verified directly at
`lib/letflow/event_store.ex` lines 221-222/337 (`fetch_uuid(attrs,
:actor_id, :missing_actor_id)`, returning `{:error, :missing_actor_id}` on
a `nil`/uncastable value). `EventStore.platform_actor_id/0` (line 771/791,
a real, already-established sentinel UUID for exactly this "no human actor"
case, per `PlatformEvents`'s own moduledoc point 4) is the correct
substitution, and it's what `scheduler.ex`'s shipped `fire_timer/2` uses.
This isn't a stylistic quibble — the design's literal text, if followed, is
non-functional (every timer fire would error on `:missing_actor_id` and
never succeed), so leaving the doc uncorrected would mislead a future
reader who trusts the design doc over the code. I edited
`lib/letflow/design/req186-scheduler-core.md` §6 to state the corrected
`actor_id: EventStore.platform_actor_id()` value with the same reasoning
above, explicitly marked as a post-implementation correction (not silently
rewritten history) — committed alongside this review.

## Files read

- `lib/letflow/scheduler.ex`, `lib/letflow/scheduler/timer.ex`,
  `lib/letflow/scheduler/poller.ex`
- `priv/repo/migrations/20260829020001_create_timers.exs`
- `lib/letflow/application.ex`, `lib/letflow/tenant_provisioning.ex` (diffs)
- `lib/letflow/design/req186-scheduler-core.md`,
  `lib/letflow/design/req185-scheduler-firing-architecture.md`
- `docs/requirements.yaml` (REQ-186 entry, ~line 9624)
- `lib/letflow/dlq.ex` (comparison), `lib/letflow/event_store.ex` (actor_id
  verification)
- `config/test.exs`, test-support diffs (`test/support/tenant_fixture.ex`,
  `test/letflow/support/tenant_fixture_test.exs`,
  `test/letflow/tenant_provisioning_event_seed_test.exs`)
