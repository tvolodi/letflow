# REQ-188 REVIEWER report (WF-02 Step 2d) — PASS

**Files reviewed:** `lib/letflow/scheduler.ex`, `lib/letflow/scheduler/timer.ex`,
`lib/letflow/scheduler/poller.ex`, `lib/letflow/design/req188-recurring-timers-and-retention.md`,
`docs/requirements.yaml` REQ-188 entry (line 9818+).

## 1. Idiomatic Elixir/Ecto/OTP usage

- `build_rearm_attrs/2` (scheduler.ex L391-407) mirrors `build_arm_changeset/2`'s
  existing shape field-for-field: same "force `id`/`status`/`created_at`, carry
  caller-supplied fields through `Map`/direct-map construction" pattern, same
  `Repo.insert(changeset, prefix: tenant_schema)` call idiom, no `Ecto.Multi`
  introduced (matches the design's explicit instruction not to introduce one).
- `maybe_rearm_timer/3` uses pattern-matched function clauses for the
  `repeat_expression == nil` case (not an `if`/`case` on a "kind" field), consistent
  with this module's existing style (`fire_timer/2`'s pattern-matched `case` on
  `Timer{status: ...}`). The `with`-chain integration in `do_fire/2` (L262-292)
  appends `maybe_rearm_timer/3` as the last step using the same
  `{:ok, _} <- ...` short-circuit idiom the chain already uses for the event-append
  and engine-advance steps — no new control-flow shape introduced.
- `Timer.rearm_changeset/2` was a pre-declared stub (per REQ-186/187) and is widened
  exactly as instructed, mirroring `arm_changeset/2`'s cast/required-field lists.
- Poller's state widening (`%{} → %{last_retention_run_at: DateTime.t() | nil}`) is
  the minimum needed for the one new capability, documented explicitly in the
  moduledoc as a deliberate departure from "no meaningful state," and threaded through
  `init/1`/`handle_info/2` with no new message types. The retention-sweep tick step
  (`maybe_run_retention_sweep/2`, L76-83) is structurally identical to the existing
  timer-poll step immediately above it in `handle_info/2` — same `Enum.each(schemas,
  fn schema_name -> ... end)` shape, reusing the same `schemas` list rather than
  re-querying. No idiom crutch found (no hand-rolled state machine, no `case` doing
  `gen_statem`'s job — this module was never a `gen_statem` candidate, it's a plain
  ticker `GenServer`, consistent with REQ-185's own architecture decision).

## 2. Supervision integrity

`git diff --stat main...HEAD` and a direct diff confirm `lib/letflow/application.ex`
has **zero** changes. No new child spec, no new supervised process, no unsupervised
`spawn`. Retention runs on the same already-supervised `Letflow.Scheduler.Poller`
process REQ-186 ships. INV-RETENTION-2 holds as designed.

## 3. Scope creep

`git diff --stat main...HEAD` touches only: `lib/letflow/scheduler.ex`,
`lib/letflow/scheduler/timer.ex`, `lib/letflow/scheduler/poller.ex`, the design doc,
and this run's own `handoffs/` artifacts. Confirmed empty diffs for
`lib/letflow/application.ex` and `lib/letflow/definitions/graph.ex` (escalation timers
correctly left untouched, per the moduledoc's own deferral statement). No
route/controller file added or modified. No abstraction (behaviour, macro, generic
plumbing) introduced ahead of what SCH-07/the retention runner need — `build_rearm_attrs/2`
is a plain private helper, not a generic "changeset builder" framework.

## 4. Decision-record consistency

Read `docs/issues/ISS-0014.yaml` and `docs/migration/decisions/0003-ecto-schema-strategy.md`
Dimension C directly. The moduledoc's two deferral statements are accurate, not
paraphrased into something stronger than the record supports:

- Partition-maintenance deferral: correctly states ISS-0014 "adopted option (a) — port
  row-level `archive/1` as-is — and rejected option (c) ... porting `PartitionRetention`'s
  whole-partition model now, 'because it would force partitioning early, contradicting
  0003 Decision C's deliberate deferral'" — this is a near-verbatim, accurately-scoped
  quote of ISS-0014's actual resolution text, not an inflated claim (e.g. it does not
  claim 0003 "forbids" partitioning, only that it "defers" it, matching the record).
- SCH-04 deferral: correctly cites `graph.ex`'s `check_timer_duration/1` (CHK-12) at
  line 738 validating `duration_iso8601` on `:TIMER` nodes only, with no
  `escalation_timer_duration` attribute existing on `:HUMAN_TASK` — verified directly
  against `graph.ex` (grep confirms no other reference to
  `escalation_timer_duration` anywhere in the file).

No decision record was silently re-decided; 0003 Decision C stays deferred, no new
partitioning was introduced.

## 5. Design-vs-implementation fidelity

- Re-arm mechanism: same `Repo.transaction/1` as the firing (INV-REARM-1) — confirmed,
  `maybe_rearm_timer/3` runs on the caller's `Repo`/`prefix` inside `do_fire/2`'s
  existing transaction function, no new transaction opened.
- `fire_at` anchoring: `build_rearm_attrs/2` computes
  `DateTime.add(fired_timer.fire_at, fired_timer.repeat_interval_us, :microsecond)` —
  the timer's own scheduled time, not `fired_at`/`now` — matches design §1.2 exactly.
- `retention_enabled?/0` defaults to `false` (`@default_retention_enabled false`,
  no config file sets `:retention_enabled`) — confirmed, matches INV-RETENTION-1.
- "At most once per cycle" structural property: `claim_due_timer_ids/2` runs once per
  `poll_and_fire/1` call, producing a fixed id list before the re-armed row (a brand-new
  row/id created inside the very transaction firing the previous occurrence) can exist
  — matches design §1.5's structural argument, no new bookkeeping added or needed.
- `repeat_total` cap logic (`series_complete` at `new_fired_count >= repeat_total`)
  matches the design's worked 3-firing example exactly.

## Verdict: PASS

No defect found. Routing to TEST-DESIGNER for mutation-driven test coverage against
REQ-188's original acceptance criteria.
