# 0037 — Event-store monthly partitioning and whole-partition retirement

Status: **ACCEPTED — REVIEWER sign-off recorded 2026-09-22** (see sign-off block at the
end of this file). Owner: CODE-DESIGNER (draft), REVIEWER (sign-off), ELIXIR-DEV
(implements). Filed for REQ-376.

Amends: `0003-ecto-schema-strategy.md` Decision C point 2 (the partitioning
deferral). Cross-references: `docs/issues/ISS-0014.yaml` (resolved 2026-08-17,
adopted option (a) — port row-level `archive/1` — and explicitly left partitioning
itself as a future, undecided item). This record is the "later" this decision was
deferred to.

## Question

ISS-0014 identified that R-Co's PAR-03 replaced its row-level `Store.archive()` with
`PartitionRetention.runArchivalAging()`/`runEphemeralDrop()`, a whole-partition
`DETACH`/`DROP` mechanism that only works on a partitioned `events`/`events_archive`.
0003 Decision C point 2 deliberately deferred partitioning ("unpartitioned first").
That deferral was reasonable while the tables had "no rows yet"; it is no longer
free — the platform has been live since 2026-08 and both tables now carry real rows
via REQ-025's `append/2` and REQ-026's row-level `archive/1`. This record ends the
deferral: does Letflow adopt Postgres-native monthly `PARTITION BY RANGE (created_at)`
partitioning for `events`/`events_archive`, and if so, what is the retirement
mechanism and how does it relate to `archive/1`?

## Decision

**Yes — both `events` and `events_archive` become Postgres-native monthly-partitioned
tables (`PARTITION BY RANGE (created_at)`), one partition per calendar month, per
tenant schema** (0003 Decision B's schema-per-tenant mechanism is unaffected —
partitioning is an intra-schema concern, orthogonal to the tenant-isolation
boundary). Full mechanics in `lib/letflow/design/req376-partition-event-retirement.md`;
this record states the decision and its consequences, not the implementation.

### Primary-key / idempotency-sidecar consequences (the question 0003 Decision C
point 2(a)/(b) flagged in advance)

- **No primary-key change needed.** `events`/`events_archive` were already given the
  composite `(event_id, created_at)` primary key from their first migration
  (`20260816120001_create_events.exs`, `20260816120005_create_events_archive.exs`),
  specifically so this future retrofit would not also be a PK-shape migration.
  `created_at` is the chosen partition key, and it is already part of every unique
  index on both tables (the PK itself; neither table has any other unique index) —
  Postgres's requirement that a partition key be part of every unique/primary-key
  index is already satisfied. Confirmed nothing else about the PK needs to change.
- **The `event_idempotency` sidecar table (0003 Decision C point 2(b)) is unaffected
  and stays exactly as shipped.** It is not itself partitioned by this decision (its
  own key is `idempotency_key`, unrelated to `created_at`); global idempotency
  uniqueness continues to be enforced there, not via a per-partition unique index on
  `events`. Nothing here reopens that choice.
- **`event_retention_policies` stays global/unpartitioned**, per its own migration's
  documented classification — unaffected by this decision; it is consulted by both
  the row-level and whole-partition mechanisms (see below), not restructured by
  either.

### Relationship to `Letflow.EventStore.archive/1` (AC6 — stated explicitly, per this
requirement's scope fence)

**Both mechanisms coexist, at two different granularities, feeding the same
destination (`events_archive`). `archive/1` is NOT retired or replaced.**

- `archive/1` (ISS-0014's already-shipped row-level move) remains the mechanism for
  **fine-grained, per-`event_type` early archival** — honoring `keep_days`/`keep_count`
  policies that select individual rows ahead of their containing month becoming old
  enough for whole-partition retirement. It continues to run from
  `Letflow.Scheduler.Poller`'s existing per-tick retention sweep, unchanged.
- The new whole-partition retirement function (`req376` design, §4) is a **coarser,
  calendar-month-granularity** mechanism: once an entire month is old enough that no
  `event_retention_policies` consideration below `keep_forever` plausibly still wants
  it hot (an operator-configured `min_partition_age_days`, deliberately conservative —
  see req376 design §4.2 for the exact cutoff rule), the whole month is retired in one
  DDL step rather than row-by-row. Any row `archive/1` has not already individually
  moved travels with its partition when the whole month retires — this is not a
  conflict: both mechanisms only ever move rows in the same direction (`events` →
  `events_archive`), and `archive/1`'s per-row phase 1 (`INSERT ... ON CONFLICT DO
  NOTHING` keyed on `(event_id, created_at)`) is naturally idempotent against a row
  that arrives in `events_archive` by the partition-retirement path instead — no
  double-write, no conflict, whichever mechanism gets to a given row first.
- **Chosen retirement primitive: `DETACH PARTITION` from `events`, followed by
  `ATTACH PARTITION` onto `events_archive` for the same month — never `DROP`.** This
  is the resolution to AC2's "DETACH (or DROP)" phrasing: DROP is rejected outright,
  not merely deprioritized, because it would permanently destroy the physical rows a
  still-referenced process instance's replay path depends on, which is exactly what
  EO-003 (a process instance with history in an already-retired month must still
  replay with no gap) forbids. Detach+reattach costs no more DDL-locking time than
  detach+drop would (`req376` design §4.3), preserves every row, and requires only
  that the read path also consult `events_archive` (req376 design §6) — which is a
  strict improvement over the status quo, where `read/2` already had a standing,
  previously-flagged gap (`req026-event-read-archive-platform-sentinels.md` §11 OQ-3:
  "no function reads events back out of `events_archive`") that this decision closes
  as a side effect rather than leaving open indefinitely.

### What this decision does NOT do

- Does not change 0003 Decision B (schema-per-tenant) or Decision C points 1/3
  (append-only enforcement, projection-table migration treatment) — untouched.
- Does not introduce a general "partition any table" framework — scoped to
  `events`/`events_archive` only, per REQ-376's own scope fence.
- Does not add a literal `DROP` path for any partition, ever, within this decision's
  scope — see EO-003 reasoning above. A future decision may add a second-tier
  purge-by-DROP for `events_archive`'s own oldest partitions once a real compliance
  requirement calls for it; this decision deliberately leaves that door open without
  walking through it.

## Reasoning summary (full detail in the design doc)

The deferral was correct when made (no rows, no pressure) and remains correct to end
now, on the same "the row count now justifies it" logic 0003 Decision C point 2
itself anticipated ("deferred... but the future retrofit's known costs are designed
around now"). This decision is that retrofit, arriving with the PK/idempotency
groundwork already in place exactly as 0003 intended, at effectively zero rework cost
to either.

## Implementation-discovered corrections (REVIEWER, WF-02 Step 2d)

Two structural Postgres restrictions ELIXIR-DEV's real-Postgres-16 verification
surfaced that this decision's mechanics section (the design doc, §4.3) did not
anticipate — neither changes this decision's substance, both are corrected in the
design doc itself (`lib/letflow/design/req376-partition-event-retirement.md` §4.3
steps 2 and 4, amended inline with dated REVIEWER notes) rather than restated here:

1. `DETACH PARTITION ... CONCURRENTLY` (step 2) cannot run while `events` carries its
   `events_default` DEFAULT partition — which it always does. Resolved by a
   self-healing, idempotent temporary detach/reattach of `events_default` around the
   real detach.
2. `ATTACH PARTITION` onto `events_archive` (step 4) requires the retiring partition to
   already carry `events_archive`'s `archived_at` column. Resolved by adding that
   column with a constant-literal default immediately before `ATTACH` (Postgres's
   fast-default optimization keeps it metadata-only, no full-table rewrite).

Both were independently assessed for security-invariant consequence by
SECURITY-REVIEWER (`handoffs/WF02-REQ376-20260922/step-02c-security-reviewer.json`,
PASS, no INV violated) and for architecture/idiom soundness by REVIEWER (see sign-off
below) — accepted as implemented in `Letflow.EventStore.PartitionMaintenance`. This
decision's "same physical table, just reparented, no row copy" framing for EO-003
still holds in substance: no row is ever copied or rewritten by either correction,
only catalog-level DDL sequencing and column list changed from the design's original
(under-specified) description.

## Sign-off

REVIEWER (WF-02 Step 2d, REQ-376, run WF02-REQ376-20260922) — 2026-09-22T11:20:00Z —
**PASS.** Reviewed the diff (`git diff main...HEAD`), ELIXIR-DEV's implementation
handoff (`step-02a-elixir-dev.json`) and SECURITY-REVIEWER's PASS
(`step-02c-security-reviewer.json`), this decision record, and the design doc in full.

- **Idiomatic vs. crutch:** N/A for `:gen_statem`/state-machine concerns — this
  requirement is DDL/maintenance work, not a process state machine. The
  catalog-state-detected retirement dispatch (§4.3.1, `catalog_state/2`) is an
  idiomatic use of Postgres's own catalogs as the single source of truth, not
  bespoke bookkeeping duplicating what Postgres already tracks — correct call.
- **Supervision:** unaffected. `PartitionMaintenance` is a plain context module
  (`Repo.query!`/`Repo.transaction/1`), consistent with REQ-045's Process-vs-row
  decision (`Letflow.Engine`'s moduledoc) — no new process, no `spawn`, no change to
  `Letflow.InstanceSupervisor`'s deliberately-empty state. `Letflow.Scheduler.Poller`'s
  new `last_partition_maintenance_run_at` field and `maybe_run_partition_maintenance/2`
  are a byte-for-byte structural mirror of the existing
  `last_retention_run_at`/`maybe_run_retention_sweep/2` pair (same config-gate/cadence-gate/
  `run_sweep`/`with_admission`/rescue-and-log shape) — no isolation regression, no new
  supervision surface.
  Approved.
- **Type-safety gaps:** none found beyond ELIXIR-DEV's own MINOR note (below).
- **Scope creep:** none. No generic "partition any table" framework — every mechanism
  is `events`/`events_archive`-specific, exactly per the design's own §1 scope fence.
  `EventStore.read/2`'s union-with-`events_archive` change is in scope (EO-003/AC4 and
  decision 0037's own "Relationship to `archive/1`" section require it explicitly, and
  it is documented, not silent) — it closes a pre-existing, independently-flagged gap
  (req026 §11 OQ-3) as a stated side effect, not an undocumented one.
- **Two flagged MAJOR deviations (events_default self-heal; archived_at fast-default
  column):** both **accepted as implemented**. Both are the only viable resolutions
  given the Postgres restrictions involved (confirmed against Postgres 16 documented
  behavior, not merely asserted); both preserve AC2's whole-unit/no-per-row-work
  property (the self-heal detach/reattach is itself metadata-only; the fast-default
  column add is metadata-only for existing rows, not a rewrite); both are
  self-healing/idempotent, consistent with §4.3.1's catalog-detected philosophy rather
  than introducing new bookkeeping. The self-heal's narrow write-failure window is an
  honest, bounded trade-off, materially better than the only alternative (dropping the
  `events_default` safety net entirely). Design doc §4.3 steps 2 and 4 amended in place
  (this same commit) to state the corrected mechanism, rather than leaving the
  original under-specified framing to mislead a future reader — required as a PASS
  condition, done directly by REVIEWER per this gate's own instructions (doc-only,
  not implementation-shaping, not worth a CODE-DESIGNER rework round).
- **MINOR note (Repo.query!/raising vs. typed-tuple convention in
  `PartitionMaintenance`):** acknowledged, not required to fix now. `retire_month/3`
  has no live caller anywhere in this diff (confirmed by grep) — REQ-377's own design
  (design doc OQ5) is what will decide who/what calls it and how often; tightening
  error-tuple typing ahead of that caller existing would be guessing at a contract
  REQ-377 hasn't written yet. Matches this codebase's own migration-file
  `repo().query!/1,2` convention. Revisit at REQ-377 implementation time, when a real
  caller's error-handling needs are known.
- **Decision-record consistency:** no conflict with any other `docs/migration/decisions/`
  record. Confirmed no framework/library choice here contradicts an existing decision.

No blocking gap found. Route to TEST-DESIGNER (WF-02 Step 3).

## Implementation-discovered correction #2 (ELIXIR-DEV rework, WF-02 Step 2a rework1, 2026-09-22)

TEST-DESIGN-VALIDATOR's Step 3b gate (`handoffs/WF02-REQ376-20260922/step-03b-test-design-validator.json`)
found, by independently re-running the real test suite against Postgres 16 three times
(seeds 0/1/42, all deterministic), that §4.4a's `keep_forever` relocation — as
implemented per the sign-off above — broke step 4's own `ATTACH` precondition: 4.4a's
rows landed in `events_archive_default` for the target month's own range, still sitting
there when `ATTACH` ran immediately afterward, and Postgres correctly refused it
(`23514 check_violation`).

This rework's own dispatch instructions proposed a specific fix — move 4.4a to run
*after* `ATTACH` succeeds, still targeting `events_archive_default` directly. ELIXIR-DEV
verified that proposal against real Postgres 16 before implementing it and found **it
does not work either**, for a reason deeper than ordering: a two-statement minimal
reproduction (`CREATE TABLE ... PARTITION BY RANGE`, a `DEFAULT` partition, `ATTACH` a
sibling covering a range, then `INSERT` an in-range row directly into the `DEFAULT`
partition) confirms Postgres's default-partition mechanism rejects an in-range `INSERT`
into a `DEFAULT` partition *whenever any sibling partition already claims that range* —
symmetric to the already-known "`ATTACH` rejects an already-populated-in-range default"
precondition. Combined, these two facts mean: **for the exact calendar month being
retired, `events_archive_default` can never durably hold a row in that month's range,
neither before, during, nor after that month's own dedicated partition is attached to
`events_archive` — no ordering of steps within the current schema resolves this.**

**Corrected resolution, implemented in `Letflow.EventStore.PartitionMaintenance`:**
§4.4a's original goal — physically relocating `keep_forever` rows into
`events_archive_default` so a *hypothetical future* per-partition-DROP purge tier could
one day drop a whole month's partition without losing protected data — is not
achievable via that destination for a month that keeps its own dedicated retired
partition, which every month does under this design (decision 0037 already commits to
**never** `DROP`ing a partition; only `DETACH`+`ATTACH`, permanently). Given that,
`keep_forever` rows need no separate physical relocation at all: they are already
carried across from `events` to `events_archive`, intact, by the same whole-partition
`DETACH`/`ATTACH` that carries every other row in that month, with no row copy — exactly
as durable as any other retained row, because nothing in this codebase ever drops a
retired partition. §4.4a is now **read-only**: it counts how many `keep_forever`-policy
rows the retiring partition carries (`count_protected_rows/2`, informational value for
`protected_rows_relocated`) and issues no `INSERT`/`DELETE`. This is a narrower, more
honest claim than the original design's, does not weaken any currently-live guarantee
(EO-002's count-preserved invariant still holds — verified against real Postgres, see
below — because the whole-partition transfer itself preserves the row), and does not
foreclose future work: if a per-partition-DROP purge tier is ever designed, protecting
`keep_forever` rows from *that* specific operation will need its own mechanism at that
time (most likely exempting a partition with protected rows from that future `DROP`
entirely, or relocating such rows to a table outside this date-range partition scheme
immediately before that specific `DROP` — genuinely new work, out of REQ-376's scope,
flagged here for whoever designs that tier).

`docs/agents/instructions/security-invariants.md` INV-7 is unaffected (no new
interpolation site; the removed `INSERT`/`DELETE` pair predated this change under the
same identifier-only-interpolation discipline the rest of this module already
documents). Design doc §4.4 updated in place (`lib/letflow/design/req376-partition-event-retirement.md`,
same commit) with the full empirical evidence, matching REVIEWER's own established
precedent (above) of amending these documents directly for implementation-discovered
corrections rather than leaving superseded framing to mislead a future reader.

**Verification (ELIXIR-DEV, this rework):**
- `MIX_ENV=test mix test test/letflow/event_store/partition_maintenance_test.exs --seed 0|1|42`
  — EO-002 passes on all three seeds (previously failed 3/3, deterministic
  `23514 check_violation`). The suite's other two pre-existing, unrelated failures
  (a UUID-binary-encoding bug in the "correction (a)" test, a flaky race in the
  `:pending_detach` induction) are TEST-DESIGNER's own separate rework and are expected
  to still fail here.
- A throwaway `mix run` script against a freshly provisioned tenant schema (real
  Postgres 16, `letflow-postgres-1`, port 5462) reproduced the exact EO-002 fixture
  shape end-to-end outside ExUnit: seeded one `keep_forever` row and one ordinary row in
  an eligible past month, called `retire_month/3` fresh (`{:ok, %{protected_rows_relocated: 1,
  resumed_from: :not_started}}`), confirmed the protected count across `events` UNION
  `events_archive` unchanged (1 before, 1 after) and `events`'s own total row count is 0
  post-retirement, then called `retire_month/3` again against the same now-retired month
  (`{:ok, %{protected_rows_relocated: 1, resumed_from: :already_retired}}`, confirming
  resumed-call reporting is accurate, not hard-coded) — printed `VERIFY: PASS`.
- `mix compile --warnings-as-errors --force` (MIX_ENV=test): clean, 0 warnings.
  `mix format --check-formatted`: exit 0.

This changes the retirement DDL sequence itself (removes an `INSERT`/`DELETE` pair from
the runtime path entirely), so it re-enters SECURITY-REVIEWER (Step 2c) and REVIEWER
(Step 2d) for re-gate before TEST-DESIGN-VALIDATOR re-runs Step 3b.

## Sign-off (re-gate, correction #2)

REVIEWER (WF-02 Step 2d re-gate, REQ-376, run WF02-REQ376-20260922) —
2026-09-22T12:05:00Z — **PASS.** This is an amendment to, not a replacement of, the
sign-off above — that PASS stays on record against the implementation it reviewed.
Reviewed `git diff HEAD~4..HEAD -- lib/letflow/event_store/partition_maintenance.ex`
in full, `step-02a-elixir-dev-rework1.json`, `step-02c-security-reviewer-regate.json`
(PASS), this decision's "Implementation-discovered correction #2" section, and the
design doc's §4.4/4.4a/4.5/§8 in full.

- **Design-doc internal consistency (task point 1):** confirmed consistent. §4.4/4.4a
  were rewritten in place, not merely annotated — every sentence describing the old
  relocate-then-something mechanism carries a same-dated `[IMPLEMENTATION-DISCOVERED
  CORRECTION, further, ...]` marker and is followed by the corrected, read-only
  framing; no paragraph anywhere in §4.4/4.4a still asserts physical relocation as the
  live mechanism (checked with `grep -n relocat` across both docs and the module —
  every remaining hit is either historical narration inside a correction note, 4.4b's
  own still-real relocation mechanism describing the *reconciliation* batch loop
  (unaffected by this rework, correctly untouched), or the `protected_rows_relocated`
  field name itself, already flagged MINOR/deliberately unrenamed). §4.5's EO-002 test
  shape needed no edit and none was made — it was already written as "count before,
  same count summed across `events` ∪ `events_archive` after," which is exactly what
  `count_protected_rows/2`'s read-only, post-`ATTACH` shape produces; it never assumed
  a relocation mechanism to begin with. §8's AC coverage map row for AC3/EO-002 already
  read "4.4a `keep_forever` accounting, read-only" before this re-gate (ELIXIR-DEV's own
  edit) — correct, left as is. Found one residual stale word in
  `lib/letflow/event_store/partition_maintenance.ex`'s own §4.4 index comment (line
  ~646, "§4.4a (keep_forever relocation, runs AFTER attach...)") — a code comment, not
  a design/decision doc, and not load-bearing for anyone's PASS, but worth the one-line
  fix for the same reason as everything else in this gate: no comment should describe a
  mechanism the code next to it no longer implements. Fixed directly (same commit) to
  "keep_forever accounting, read-only". Recompiled clean afterward
  (`MIX_ENV=test mix compile --warnings-as-errors --force`: 282 files, 0 warnings;
  `mix format --check-formatted`: exit 0) — comment-only change, no behavior risk.
- **Logical soundness of the core claim (task point 2), independently verified, not
  taken on ELIXIR-DEV's word:** the claim is TRUE, and only for this decision's current
  scope — which the docs already say explicitly, so no further caveat is required as a
  PASS condition. Reasoning: decision 0037's retirement primitive is `DETACH`+`ATTACH`
  only, never `DROP` (stated as a hard exclusion in "What this decision does NOT do,"
  not a soft default) — `DETACH`/`ATTACH` are pg_inherits/pg_class catalog operations;
  neither one deletes a row or rewrites a page. Every row physically present in a
  month's partition when it is detached from `events` is still physically present, in
  the same table (now reparented), when it is attached to `events_archive` — this holds
  for a `keep_forever` row exactly as it holds for any other row, with no
  `keep_forever`-specific step required, because the guarantee comes from the DDL
  primitive itself, not from anything row-selective. That is sufficient for EO-002
  *today* and stays sufficient *indefinitely into the future, unconditionally* — as
  long as no future code path ever issues `DROP` against a partition holding
  `keep_forever` rows, which is exactly what decision 0037 currently guarantees
  (no `DROP` exists anywhere in this codebase; confirmed by `grep -rn "DROP TABLE\|DROP
  PARTITION\|drop_partition" lib/letflow/event_store/` returning nothing beyond this
  module's own constraint-drop helper, `drop_bounds_constraint!/3`, which drops a
  `CHECK` constraint, not a partition or table). The claim's truth is therefore
  conditional on decision 0037's own current scope holding, and the docs already say so
  in exactly those terms — decision 0037's pre-existing "What this decision does NOT
  do" section already names the future-DROP-tier door as deliberately left open, and
  this rework's own "Implementation-discovered correction #2" section (added the same
  commit as the fix, before this re-gate) already states explicitly that "if a
  per-partition-DROP purge tier is ever built, protecting `keep_forever` rows from
  *that* specific operation will need its own mechanism at that time" and names the two
  most plausible resolutions (exempt partitions holding protected rows from that future
  `DROP`, or relocate protected rows to a table genuinely outside this partition scheme
  immediately before that specific `DROP`). The design doc's §4.4a "What this gives up,
  honestly stated" paragraph says the identical thing in the implementation's own words.
  **Ruling: this is already the correct and sufficient caveat, present in both the
  decision record and the design doc, added at the same time as the fix rather than
  left for later discovery — no additional statement is required as a condition of this
  PASS.** A future DROP-capable purge tier's own design work (not REQ-376's) is where
  the actual protection mechanism belongs, exactly as both docs already say; re-stating
  the same caveat a third time here would be redundant, not more correct.
- **Supervision / idiom / scope creep (task point 3):** no change since the first-pass
  PASS and the Step 2c re-gate's own carried-forward reasoning. The diff since my prior
  sign-off is confined to `partition_maintenance.ex`'s internal DML mechanism
  (INSERT+DELETE → one read-only `SELECT count(*)`, called from a different point in
  the same two call sites) plus doc updates — no new process, no new supervision
  surface, no new abstraction, no framework-shaped code introduced ahead of need. Net
  change is a reduction in code (one function shrinks from ~25 lines of
  transactional DML to ~10 lines of a single query), which is the opposite direction
  from scope creep.
- **Decision-record consistency:** no conflict with any other `docs/migration/decisions/`
  record introduced by this diff.

No blocking gap found. Route to TEST-DESIGN-VALIDATOR (Step 3b) for re-gate once
TEST-DESIGNER's own rework (the two unrelated test-code bugs) lands.
