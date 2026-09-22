# REQ-385 — Task-form version-mismatch fallback (EO-004 analysis)

**Requirement:** REQ-385 (`docs/requirements.yaml`, stage S9; full `description` and all
4 `acceptance_criteria` read directly from that entry). letflow-queue task 745, GH#1633.
**Owner (implementer):** `ELIXIR-DEV` — but per the requirement's own framing, this design
pass is the deliverable that decides whether there is anything for ELIXIR-DEV to build.
**Depends on:** REQ-126 (`status: done`), whose design
(`lib/letflow/design/req126-form-version-pinning.md`) and shipped implementation are the
subject of this analysis.
**No implementation code below** — this design's conclusion is itself largely "do not
build," per AC3/AC4; where code changes are named at all (none are proposed), they would
be signatures/shapes only, matching every other design doc in this directory.

---

## 1. Verdict (AC1)

**No real analog exists. EO-004's scenario-level guarantee is vacuously satisfied under
REQ-126's frozen-at-creation architecture.** There is no live version-resolution step
anywhere on the task-form read path that could "return a version that doesn't match the
version requested," because nothing is ever *requested* by version on this path in the
first place — `tasks.form_schema` is written exactly once, at task-activation time, and
is never re-derived, re-joined, or re-fetched against any catalog on any subsequent read.
A comparison step needs two independently-obtained values to compare; this path produces
only one value, once, and returns that same stored value forever after. "Cannot confirm
the version returned matches the version requested" presupposes a request-time version
parameter and a resolution outcome that could diverge from it — neither exists here.

The one candidate failure mode the requirement's own description names — a `tasks` row
whose `instance_definition_snapshots` row is missing — is real as a *join-miss*
(confirmed reachable in the schema, §3 below) but does **not** constitute a version
mismatch or an unconfirmable form: `form_schema` does not come from that join at all (§2).
A missing snapshot row degrades only the `form_version` **display label** to `nil`; the
form itself is already correct, already rendered from data written before that join could
ever fail, and requires no confirmation because nothing about its correctness depends on
the join succeeding. Treating a `nil` metadata label as "cannot confirm the version" would
misrepresent a label gap as a content problem, which is worse than not building anything
(AC3's "not... silently marking the acceptance criterion done without a check" — the
distinction below is exactly that check, performed and recorded, not skipped).

Reasoning and evidence for both halves of this verdict follow in §2–§4. §5 records why no
change is proposed, closing AC2 (conditionally not triggered), AC3, and AC4.

---

## 2. Why `form_schema` has no "version requested" to fail

### 2.1 The write path — one write, at activation, never repeated

`Letflow.Engine.TaskActivation.resolve_form_schema/1` (`lib/letflow/engine/task_activation.ex`)
reads `node.attributes["form_schema"]` off the `Graph.Node.t()` the caller hands it, and
that `Graph` always comes from `Letflow.Engine.fetch_graph/2` — per this module's own
moduledoc: "never a fresh `process_definitions` read... already pinned to the version the
instance was created against." `insert_attrs/4` (same file) folds the result into the
seven-key attrs map passed to `Task.insert_changeset/2`, whose `cast/3` list includes
`:form_schema` — the **only** changeset in `lib/letflow/engine/task.ex` that casts this
column. `complete_changeset/2` and `assignment_changeset/2` (the only two other changesets
on this schema) do not touch it. There is no second call site, anywhere in `lib/`, that
ever writes `tasks.form_schema` a second time (confirmed by grep — `form_schema:` appears
only in `insert_attrs/4`'s literal attrs map and in test fixtures).

### 2.2 The read path — one column read, no join, no catalog lookup

`Letflow.Routers.Tasks`'s moduledoc states it directly (§ "Response allowlists"):
`form_schema` is "sourced directly from the task's own `form_schema` column... No `Task`
changeset ever writes this column a second time... so reading the column back is
automatically the version pinned at activation — no live re-fetch of the current process
definition, and no additional pinning mechanism, is involved." `handle_get_by_id/3` calls
`Tasks.get_task/2`, whose only two joins (per REQ-126's design §4.1) are against
`InstanceProjection` (`correlation_key`) and `InstanceDefinitionSnapshot`
(`definition_ver`, for `form_version` — a **different** field, see §3). Neither join
touches `graph` or re-derives `form_schema`. The SPA's own render path confirms this holds
all the way to the screen: `web/src/pages/tasks/TaskInboxPage.tsx:347-354` reads
`task.form_schema` straight off the task payload with no version-comparison logic, no
re-fetch, and no second request of any kind.

### 2.3 What "confirm the version" would require, and why it cannot exist here

For EO-004's guarantee to be meaningful, there would need to be a point where the server
resolves a form **by version reference** — some `(form_id, form_version)` pair supplied
or implied by the request — against a live source, such that the resolution could return
a *different* version than the one implied, or fail to resolve at all. `PinResolver`
(`lib/letflow/engine/pin_resolver.ex`) is exactly this shape for `SERVICE_TASK`/
`SUB_PROCESS` references — an external, mutable catalog resolved via `resolve/4` against
an injectable `Lookup`, per REQ-126's design §2.3 (already documented as the point of
contrast). Forms have no such resolution step: the "form" *is* the `tasks.form_schema`
value, decided once, forever, at row-insert time. There is nothing later in the task's
lifecycle that asks "what is node X's form now" — every read is "what is *this task's own*
`form_schema` column," a question with exactly one possible answer per task row,
unconditionally. A confirmation step cannot be built for a resolution that structurally
never happens.

---

## 3. The one real-but-unrelated failure mode: snapshot-row-missing

REQ-126 design §5 (`lib/letflow/design/req126-form-version-pinning.md`) documents this
case for `form_version` (not `form_schema`): `get_task/2`'s `left_join` against
`instance_definition_snapshots` returns `nil` for `definition_ver` when no matching
snapshot row exists for the task's `instance_id`, and that design labels this
"structurally near-impossible" but explicitly non-crashing (INV-8) rather than
unreachable-by-construction.

### 3.1 Confirming reachability against the actual constraints (per AC1's evidentiary bar)

This design re-checked, rather than assumed, that "near-impossible" characterization
against the live schema:

- `tasks.instance_id` **does** carry a real DB-level FK —
  `priv/repo/migrations/20260818110003_create_tasks.exs:61-63`:
  `references(:instance_projections, column: :instance_id, on_delete: :restrict)`. This
  guarantees a `tasks` row's `instance_id` always names a real, currently-existing
  `instance_projections` row (restrict, not nullify/cascade — the instance projection
  cannot be deleted out from under an existing task).
- `instance_definition_snapshots.instance_id` carries **no** FK in either direction — its
  own moduledoc states this is deliberate ("No foreign key on `instance_id`,
  deliberately" — no `process_instances` table to reference, and the snapshot must be
  insertable before `InstanceStarted` is even appended). There is therefore **no DB-level
  constraint** forcing a snapshot row to exist for every `instance_id` that later gets a
  `tasks` row, and none preventing one from being deleted later (the table exposes no
  delete changeset, but nothing stops a raw `DELETE`/manual DB operation outside
  application code).
- The **applicable** guarantee is therefore purely at the application call-order level,
  not the schema level: `Letflow.Engine.create/5` calls `SnapshotStore.create/3` (which
  inserts the snapshot row) strictly before `activate/3` (which can produce the first
  `tasks` row for that instance) — confirmed by REQ-126 design §0's own read of
  `lib/letflow/engine.ex`. Every code path that can create a `tasks` row
  (`TaskActivation.append_multi/6`, `append_multi_from_existing_records/6`) runs inside
  that same instance's lifecycle, strictly after its snapshot insert. `SnapshotStore`
  exposes no delete function at all (`InstanceDefinitionSnapshot`'s moduledoc: "write-once
  ... no delete path"), so no *application* code path can remove a snapshot row once
  written.
- **Conclusion:** within the application's own write paths, a `tasks` row with no
  matching snapshot row is unreachable — not merely unlikely. The only way to produce
  this state is to bypass `Letflow.Engine`/`Letflow.Definitions.SnapshotStore` entirely
  (a raw SQL `DELETE FROM instance_definition_snapshots` or a hand-crafted `tasks` insert
  in a test, exactly as REQ-126 design §7.3 already describes doing for test coverage).
  This matches, and slightly sharpens, REQ-126's own "structurally near-impossible"
  phrasing: it is impossible through any `lib/letflow/` write path, reachable only through
  direct data manipulation outside the application.

### 3.2 Why this case is not a version-mismatch even when artificially triggered

Even in the artificial case where a snapshot row is deleted out from under an existing
task: `tasks.form_schema` was already written, at activation time, into the `tasks` row
itself (§2.1) — deleting the *snapshot* row afterward does not touch it, cannot un-write
it, and the task read path never re-derives `form_schema` from the snapshot (§2.2). The
task continues to serve the exact same, exactly-correct `form_schema` it always has. Only
`form_version` — an informational label describing which definition version the instance
started from, added by REQ-126 for MOB-3's cache-key display purposes, never consumed to
*fetch* anything — goes to `nil`. A client cannot render the "wrong" form in this state,
because the same one value it always rendered is still what's returned; it can only fail
to *display a version label*. That is a metadata-completeness gap, not the "form doesn't
match what was requested" failure EO-004 describes, and building a "cannot confirm
version" fallback message keyed on this join-miss would attach a MAJOR-severity,
form-hiding UI behavior to a condition that has no bearing on whether the form shown is
correct.

---

## 4. Could a wrong form ever actually be served? (exhaustive check)

To close out AC1 with the same rigor a positive finding would get, this design also
checked for any *other* condition — not the one the requirement's description names —
under which `GET /tasks/:id` could serve a `form_schema` that disagrees with "the version
the task was created against":

- **Malformed `form_schema` at activation time**: `resolve_form_schema/1` shape-checks a
  non-nil value via `JsonSchemaShape.check/1` before accepting it; a failure aborts the
  entire `Multi.run/3` step (`insert_attrs/4`'s `{:error, {:invalid_form_schema, ...}}`
  branch), so the whole task-activation transaction rolls back — no partial/corrupt
  `tasks` row with a bad `form_schema` can ever commit. No confirmation-at-read-time is
  needed because a write-time check already forecloses this.
- **Promoting a new process-definition version after task creation**: REQ-126 design
  §7.2's own test scenario proves the read is immune to this by construction — `form_id`/
  `form_version` (and, by the same mechanism, `form_schema`, written earlier in the same
  activation) derive from the instance's own frozen snapshot, never from the current
  `process_definitions` row. A later promotion cannot retroactively change what an
  already-activated task serves.
- **A second write ever touching `tasks.form_schema`**: ruled out in §2.1 — no changeset
  other than `insert_changeset/2` casts the column, and it is called exactly once per task
  row, at `do_insert/3` (`TaskActivation`'s single call site for creating a `tasks` row —
  confirmed by that module's own "REQ-195 (OQ-1)" comment: "the single call site... that
  creates a `tasks` row anywhere in this codebase").
- **`node_id` renamed/reused across definition versions**: irrelevant — the snapshot's
  `graph` (and, transitively, the `form_schema` copied out of it at activation) is a full
  verbatim copy taken once at instance-start (`SnapshotStore.create/3`, per REQ-027/033),
  not a live reference that a later version's node with the same id could shadow.

No condition was found, real or hypothetical-but-reachable, under which the server could
serve a `form_schema` that disagrees with the version a task was actually created against.

---

## 5. What is not being built, and why (AC2/AC3/AC4)

**AC2 does not apply** — it is conditioned on "if a real analog exists," and §1–§4 above
establish it does not. No new `GET /tasks/:id` response shape, no new error code, no new
SPA out-of-date-message component, and no MAJOR-severity form-hiding fallback are added by
this requirement.

**AC3 is satisfied by this document** — the conclusion ("EO-004 is vacuously satisfied
because there is no live resolution step to fail") is recorded here, with the reasoning in
§1–§4, distinct from either (a) building a check against a condition that cannot occur, or
(b) marking the acceptance criterion done with no analysis at all. The distinction drawn
in §3.2 — a real, confirmed-reachable join-miss exists, but it is not the failure EO-004
describes — is the substance of "record the conclusion" this criterion asks for; a
shallower pass could have conflated the join-miss with a version mismatch and built a
fallback for the wrong condition.

**AC4 is satisfied by non-action** — no change is proposed to `task_activation.ex`'s
`resolve_form_schema/1`, to `tasks.node_id`, or to
`instance_definition_snapshots.definition_ver`'s role on the read path. §3.1's reachability
check was read-only investigation (grep, migration read, moduledoc read) — it did not
require and did not perform any modification to confirm.

### 5.1 What this leaves for the origin scenario's own review report

Per AC3's second clause, the origin UAT scenario
(`test/fixtures/uat/scenarios/...` for `gui-review-2026-09-20-tenant-switch-cache-isolation`
/ its EO-004 entry) should be updated to record this same conclusion in its own review
report — that is a `DOC-UPDATER`/UAT-report-owning-agent action outside this design
document's own scope, but is named here so the conclusion does not stop at this file.

---

## 6. Open questions (not silently resolved)

- **OQ-1** — Whether a *future*, genuinely different concern — the malformed-`form_schema`
  rejection path in §4's first bullet (an activation-time failure, not a read-time one) —
  should surface **any** operator-facing signal today (e.g. a task stuck un-activatable
  because its node's `form_schema` attribute fails shape-check). This is unrelated to
  EO-004 (which is about a *read* confirming a *version*, not a *write* rejecting a
  *malformed value*), and this design does not propose building it, but flags it since it
  is the nearest genuinely-failable neighbor of the concern EO-004 raised. Left for
  REVIEWER/a future requirement to decide is in scope, not assumed here.
- **OQ-2** — Whether the origin UAT scenario file itself (not just its review report)
  should have EO-004 reworded to describe the join-miss/`form_version`-nil case accurately
  (a metadata-completeness note, not a version-mismatch guarantee) rather than left
  phrased in terms that presuppose a live-resolution architecture Letflow does not have.
  This design doc does not edit the scenario file — that edit, if wanted, belongs to
  whichever role owns `test/fixtures/uat/scenarios/` (BA-<VERTICAL> / REQ-ANALYST
  territory), flagged here rather than done silently.
