# Design: ISS-0583 — `TASK_COMPLETED` schema_version 1→2 backfill

**Run:** fix/ISS-0583-20260911 (GH#1200, queue task 583) · **Author:** CODE-DESIGNER ·
**Status:** proposed — awaiting CODE-DESIGN-VALIDATOR.

**Scope: one production file, `lib/mix/tasks/letflow.backfill_event_type_versions.ex`
(extended, not replaced), plus new test coverage. No change needed to
`lib/letflow/tenant_provisioning/backfill.ex` or `lib/letflow/event_store/registry.ex` —
both are already fully generic over event-type name/version (see §2). No migration, no
schema change, no new public function signature (the existing `Backfill.run/1` is
reused verbatim). See §6 for the SECURITY-REVIEWER scope call.**

---

## 0. Premise re-verification (this is a retry — REQ-292 previously hadn't merged)

Confirmed directly against current `main` (commit `18f68e12`, PR #1204, merged):

- `lib/letflow/tenant_provisioning.ex` lines 770-822: the `TASK_COMPLETED` entry in
  `@platform_event_type_seed_attrs` is genuinely `schema_version: 2`, with
  `merged_variable_events.items.properties.event.enum` = `["variable_overwritten",
  "computed_field_disagreement", "visible_when_false_value_discarded"]` and
  `required: ["event"]` (only `event` required at the item level — `key`/`field`/
  `old_value`/`new_value`/`submitted_value`/`server_value`/`discarded_value` all
  optional).
- `lib/letflow/engine/form_expression_reevaluation.ex` genuinely exists and defines
  `reevaluation_event() :: {:computed_field_disagreement, field_name(), submitted_value ::
  term(), server_value :: term()} | {:visible_when_false_value_discarded, field_name(),
  discarded_value :: term()}` (lines 112-115), consumed by `eval_computed_fields/…` and
  `eval_visible_when_fields/…` (lines 309-413).
- `git show 18f68e12 -- lib/letflow/tenant_provisioning.ex` confirms the **exact pre-bump
  v1 schema** (needed verbatim for the test's downgrade fixture, §5):
  `"event" => %{"type" => "string", "enum" => ["variable_overwritten"]}`, `"key" =>
  %{"type" => "string"}`, item-level `"required" => ["event", "key"]`. Top-level
  properties/required (`task_id`/`node_id`/`output_variables`/`merged_variable_events`/
  `activated_nodes`, all four non-`merged_variable_events` keys required) are identical
  between v1 and v2 — **v2 only widens the `merged_variable_events` item schema**, exactly
  the same shape as `DEFINITION_PROMOTED`'s v1→v2 bump (ISS-0332 precedent). v2 is a
  strict superset: any payload valid under v1 is valid under v2 (the `event` enum only
  grew, `key` moved from required to optional, no other property removed or narrowed).
  Safe to backfill unconditionally for every pre-existing tenant, including one with zero
  `TASK_COMPLETED` events on record.

Premise holds. Proceeding with a real backfill design, not a decline.

## 1. Problem statement (brief)

Identical in shape to ISS-0332. A tenant provisioned before commit `18f68e12` has its
`event_type_registry` row for `TASK_COMPLETED` pinned at `schema_version: 1`. REQ-292's
server-side re-evaluation logic (wired into `Letflow.Engine.run_complete_task/6`'s
`Ecto.Multi`, `:form_expression_reevaluation` step, lines 1887-1906 of `engine.ex`) is
tenant-agnostic — it runs for every tenant regardless of registry state, and it emits a
`computed_field_disagreement` or `visible_when_false_value_discarded` merge event whenever
a submitted computed value disagrees with the server's recomputation, or a submitted value
for a `visible_when: false` field is discarded. For a v1-pinned tenant, encoding either of
these into the `TASK_COMPLETED` payload's `merged_variable_events` array and validating it
against the v1 schema fails: v1's `event` enum only admits `"variable_overwritten"`, so
`Registry.JsonSchema.validate/2` (invoked via `Registry.validate_payload/3`, called from
`Letflow.EventStore.append/2` at `event_store.ex:228`) rejects the array element.

**Exact observed error shape** (traced through `engine.ex`, not paraphrased from the issue
text, which slightly over-simplifies it): `append_task_completed_event/5` (`engine.ex:3916`)
calls `EventStore.append(event_attrs, prefix: prefix)` and on failure wraps the reason as
`{:error, {:event_append_failed, reason}}` (`engine.ex:3939`). That `Multi.run` step's
failure propagates as `Repo.transaction`'s `{:error, failed_step, reason, changes}` envelope,
which `interpret_complete_result/1`'s catch-all clause (`engine.ex:4053-4055`) unwraps to
plain `{:error, reason}`. So the **caller-visible return of `Engine.complete_task/3`** for
this defect is:

```
{:error, {:event_append_failed, {:payload_validation_failed, [%Registry.ValidationFailure{...}, ...]}}}
```

— i.e. `{:payload_validation_failed, failures}` is nested one level deeper than the issue
text's shorthand ("the standard `{:error, {:payload_validation_failed, failures}}` tagged
tuple") suggests. TEST-DESIGNER must assert the full `{:event_append_failed, {...}}` wrapper
at the `Engine.complete_task/3` call site — asserting the bare, unwrapped tuple will not
match. (`Registry.validate_payload/3` itself does return the bare tuple when called
directly, which is what ISS-0332's own AC2 test does against `Registry.validate_payload/3`
directly rather than through `Engine.complete_task/3` — this issue's AC2 explicitly wants
the real `Engine.complete_task/3` path exercised instead, per the task brief, so the extra
wrapper layer is real and must be asserted.)

No crash, no partial commit — `Ecto.Multi`/`Repo.transaction/1` rolls the whole task
completion back cleanly; the task row stays `:pending` and the instance stays `:active`.
Matches the issue's own characterization on this point.

## 2. Why the existing backfill mechanism needs no structural change

Re-read `lib/letflow/tenant_provisioning/backfill.ex` in full (55 lines). `Backfill.run/1`
takes a single argument, `event_type_attrs :: map()` — **it is not `DEFINITION_PROMOTED`-
specific in any way**. Its body:

1. `Repo.all(Registration)` — every provisioned tenant's registration row, regardless of
   which event types it has ever registered.
2. For each, `Registry.register_type(event_type_attrs, tenant_id)` — `register_type/2`
   (`registry.ex:93-112`) resolves `attrs["name"]`/`attrs[:name]` generically (it's an
   `EventType.changeset/2` cast, not a hardcoded field), applies the monotonicity check
   against whatever rows already exist **for that `name`** in that tenant's
   `event_type_registry`, and inserts a new row if the version is monotonically higher.
3. Six outcome branches (`{:ok, _}` / `:duplicate_event_type_version` /
   `:schema_version_not_monotonic` / `:tenant_not_provisioned` / `:tenant_schema_missing` /
   catch-all `{:error, other}`) — all generic, none inspect `attrs["name"]`.

Likewise `Registry.register_type/2` and `Registry.get_type/2` (`registry.ex`) are generic
over `name`; `Registry.JsonSchema.validate/2` is a generic schema-driven validator with no
`DEFINITION_PROMOTED`/`TASK_COMPLETED` special-casing anywhere.

**Conclusion: `Letflow.TenantProvisioning.Backfill` and `Letflow.EventStore.Registry` are
untouched by this fix.** The only DEFINITION_PROMOTED-specific thing in the whole mechanism
is the literal `@definition_promoted_v2_attrs` map hardcoded inside the **mix task**
(`lib/mix/tasks/letflow.backfill_event_type_versions.ex`) — that is exactly, and only, what
needs a `TASK_COMPLETED` sibling.

## 3. The fix: extend the mix task to sweep a list of event-type attrs, not one

### 3.1 New module attribute — `@task_completed_v2_attrs`

Add a second module attribute to `Mix.Tasks.Letflow.BackfillEventTypeVersions`, placed
immediately after the existing `@definition_promoted_v2_attrs`, named
`@task_completed_v2_attrs`. Its value is a **verbatim copy** of the `TASK_COMPLETED` entry
currently seeded by `lib/letflow/tenant_provisioning.ex` lines 771-822 (`name:
"TASK_COMPLETED"`, `schema_version: 2`, the same `description:` string — REQ-292's bump
rationale — and the identical `json_schema:` map, including the three-member `event` enum
and the `required: ["event"]` item-level relaxation). Same key-shape convention the existing
`@definition_promoted_v2_attrs` already uses: atom keys at the top level
(`name:`/`schema_version:`/`description:`/`json_schema:`), string keys inside the nested
`json_schema` value (matching `EventType.changeset/2`'s `Ecto.Changeset.cast/4` tolerance —
no behavior difference from atom keys, purely follows the file's existing convention).

Do **not** paraphrase or shorten the `description:` string — keep it byte-identical to
`tenant_provisioning.ex`'s copy, for the same auditability reason
`@definition_promoted_v2_attrs`'s own description is presently a near-verbatim echo of its
`tenant_provisioning.ex` counterpart (compare the two files' current DEFINITION_PROMOTED
description text — ELIXIR-DEV should diff them at implementation time to confirm exact
match, not just family resemblance).

### 3.2 Generalize the sweep list

Add a third module attribute, `@event_type_backfills`, defined as the two-element list
`[@definition_promoted_v2_attrs, @task_completed_v2_attrs]`. This makes the task a
general "sweep N event-type version bumps" mechanism rather than hardcoding a second,
structurally-duplicated call — the natural generalization once a second entry exists, and
sets up cleanly for any future ISS-0332-shaped follow-up without another mix-task rewrite.

### 3.3 `run/1` behavior — iterate, aggregate, report per-type, halt once at the end

Replace the current single-call body of `@impl Mix.Task def run(_args)` with logic that:

1. Calls `Mix.Task.run("app.start")` (unchanged).
2. Iterates `@event_type_backfills`, calling `Letflow.TenantProvisioning.Backfill.run/1`
   once per entry (**sequentially**, not concurrently — matches `Backfill.run/1`'s own
   internal `Enum.reduce_while` sequencing; no reason to introduce parallelism the
   underlying function doesn't already provide, and doing so would interleave
   `Mix.shell().info` output confusingly).
3. For each entry's result, prints one `Mix.shell().info` line naming the event type
   (`attrs.name` or `attrs[:name]`) and its updated/skipped counts on success, or one
   `Mix.shell().error` line naming the event type and the `{tenant_id, reason}` on
   failure — **do not stop the loop on a per-type failure**: `DEFINITION_PROMOTED` and
   `TASK_COMPLETED` backfills are independent operations against independent
   `(name, schema_version)` rows; a `Backfill.run/1` halt for one type (e.g. some tenant's
   `TASK_COMPLETED` registry is corrupted in some unforeseen way) carries no reason to
   also skip attempting `DEFINITION_PROMOTED` for every other tenant. This is a genuine,
   reasoned divergence from the single-call precedent's implicit one-shot semantics —
   flagged here explicitly rather than silently decided, per this design's own
   "no silent implementation code, no silently resolved open question" discipline.
4. After all entries are attempted, if **any** produced `{:error, {:backfill_failed, ...}}`,
   `System.halt(1)` (matches existing behavior: non-zero exit on any real failure, so a
   CI/ops caller still sees this as a failed run) — otherwise exits normally (implicit `:ok`
   return, matching the current function's `@spec run(argv :: [String.t()]) :: :ok`, which
   does not change).

No new public function is introduced; `run/1`'s own `@spec` is unchanged
(`Mix.Task.run/1`'s contract is always `:ok` or a halt, per `Mix.Task` convention — the
existing `@spec run(argv :: [String.t()]) :: :ok` already covers both, same as today).

### 3.4 `@moduledoc`/`@shortdoc` updates

`@shortdoc` gains a second issue reference: `"Backfills event type schema versions for
pre-existing tenants (ISS-0332, ISS-0583)"`. `@moduledoc` gains a second paragraph
describing the `TASK_COMPLETED` v1→v2 bump (REQ-292) alongside the existing
`DEFINITION_PROMOTED` v1→v2 paragraph (REQ-077/ISS-0332), and states plainly that the task
now sweeps a list of event-type version bumps rather than a single hardcoded one — an
onward reader should not have to diff the source to learn this task covers two event types.

## 4. Backfill mechanics recap (unchanged, reused verbatim — see ISS-0332's own design
doc §3-4 for the original derivation; not re-derived here)

- `register_type/2`'s monotonicity + duplicate checks mean: a tenant already at v2 is
  `{:error, :duplicate_event_type_version}` → counted `skipped`, not an error. A tenant at
  some hypothetical v3+ is `{:error, :schema_version_not_monotonic}` → also `skipped`. A
  tenant with a `Registration` row but no live physical schema (ISS-0343's race) is
  `{:error, :tenant_schema_missing}` → `skipped` with a `Logger.warning`. Only a genuinely
  unexpected `{:error, other}` (e.g. a changeset validation failure against the hardcoded
  attrs themselves, which should never happen for a byte-verbatim copy of a schema that
  already passed `EventType.changeset/2` once at seed time) halts that type's sweep via
  `{:error, {:backfill_failed, tenant_id, other}}`.
- Idempotent by construction: re-running the mix task after a successful backfill just
  produces `skipped` counts for every tenant (duplicate-version branch), never an error.

## 5. Test design — replicate ISS-0332's established pattern; do not invent a new one

### 5.1 Registry-level coverage (mirrors `test/letflow/tenant_provisioning/backfill_test.exs`
exactly) — extend that same file with a new `describe` block

Add `describe "TASK_COMPLETED backfill (ISS-0583)"` to
`test/letflow/tenant_provisioning/backfill_test.exs`, with the same fixture/test shape
already used for `DEFINITION_PROMOTED`:

- `defp task_completed_v1_attrs/0` — the exact pre-bump v1 map from §0 above (string-keyed,
  mirroring the file's existing `v1_attrs/0`/`v2_attrs/0` convention): `event` enum
  `["variable_overwritten"]` only, item-level `required: ["event", "key"]`.
- `defp task_completed_v2_attrs/0` — the exact v2 map from `tenant_provisioning.ex`
  lines 788-821 (string-keyed copy, matching the file's `v2_attrs/0` convention — this is a
  **second, independent verbatim copy** from the same source of truth as §3.1's
  `@task_completed_v2_attrs`; TEST-DESIGNER and ELIXIR-DEV must each copy from
  `tenant_provisioning.ex` directly, not from each other, so a transcription slip in one
  doesn't silently validate the other).
- `defp downgrade_task_completed_to_v1!(schema_name)` — mirrors `downgrade_to_v1!/1`
  exactly, but deletes/reinserts `"TASK_COMPLETED"` rows instead of
  `"DEFINITION_PROMOTED"`.
- Test 1 (AC1 — bump applies): provision a tenant (`TenantFixture.provisioned_tenant!/1`),
  downgrade `TASK_COMPLETED` to v1, assert `Registry.get_type("TASK_COMPLETED",
  tenant_id)` returns `schema_version: 1`, run `Backfill.run(task_completed_v2_attrs())`,
  assert `updated >= 1`, assert `Registry.get_type/2` now returns `schema_version: 2`.
- Test 2 (idempotency, mirrors the existing `DEFINITION_PROMOTED` AC3 test): a tenant
  already at v2 (the default post-`replay_migrations` state on current `main`) is
  `skipped`, not errored, and its version is unchanged.
- These two tests satisfy AC1 of the GH#1200 issue text ("every pre-existing tenant …
  demonstrated with a real before/after query quoted") at the `Registry.get_type/2` level.
  AC1's own "before/after query quoted" instruction is satisfied by these tests' own
  `assert {:ok, %EventType{schema_version: N}} = Registry.get_type(...)` assertions, which
  is the same evidentiary form ISS-0332's original AC1 test already used and that
  RELEASE-VALIDATOR/UAT-RUNNER can re-run and quote directly from test output — no new
  `psql` query script is needed; do not invent one.

Do **not** duplicate the `ISS-0343`-vanished-schema test — that scenario is
`Backfill.run/1`-generic (already exercised for `DEFINITION_PROMOTED`) and adds no new
information when repeated for `TASK_COMPLETED`; ISS-0332's own file only exercises it once.

### 5.2 End-to-end coverage through the real `Engine.complete_task/3` path (this is AC2's
distinguishing requirement — the issue explicitly wants the real code path, not a direct
`Registry.validate_payload/3` call as ISS-0332's own AC2 used)

New test file: `test/letflow/tenant_provisioning/task_completed_backfill_test.exs`. This
design's own choice (not a cited project policy — `docs/guides/test_developer_guide.md`
only defines T-1/T-2, and `engine_form_expression_reevaluation_test.exs`'s own "DIRECTIVE
T-4" label in its moduledoc is that file's private terminology for its own fixtures, not a
project-wide directive): this new file should **duplicate**, not import, the handful of
engine-plumbing helpers it needs from `test/letflow/engine_form_expression_reevaluation_test.exs`
rather than reaching into another test module's private functions. Reasoning on its own
merits — no `test/support/` module currently exports these helpers (`insert_tenant!/0`,
`provisioned_tenant/0`, `graph_with_form_schema/1`, the computed/visible_when form-schema
fixture, `start_instance_with_pending_task!/2`, `complete_attrs/1`) for cross-file reuse;
they are private functions of one `ExUnit.Case` module today, and importing private
functions across test modules is not a pattern this codebase uses elsewhere. Duplicating
a few small helpers into the new file is the smaller, more local change than promoting them
to shared `test/support/` right now. This is a recommendation, not a hard mandate — see the
hedge already given below (TEST-DESIGNER may factor a shared helper module out at their own
discretion if a cleaner shared home emerges):

- `insert_tenant!/0` + `provisioned_tenant/0` (real provisioning via
  `TenantProvisioning.provision_tenant_schema/1` + `replay_migrations/1`, `on_exit` schema
  drop — copy verbatim from `engine_form_expression_reevaluation_test.exs` lines 36-73).
- `graph_with_form_schema/1` (copy verbatim, lines 84-100).
- A form schema fixture that reliably triggers a `computed_field_disagreement`: reuse
  `schema_computed_and_visible_when()`'s existing shape from
  `engine_form_expression_reevaluation_test.exs` (a computed `"bonus"` field the server
  recomputes from `"amount"`, submitted with a deliberately wrong client value — exactly
  the fixture `engine_form_expression_reevaluation_test.exs`'s own AC2 test already uses
  at lines 320-362) — copy this fixture's definition into the new file too, per the same
  self-containment reasoning above.
- `start_instance_with_pending_task!/2` and `complete_attrs/1` (copy verbatim from the
  same source file).
- `downgrade_task_completed_to_v1!/1` (same helper as §5.1, duplicated into this file by
  the same reasoning — or factored into a shared `test/support/` helper module if
  TEST-DESIGNER judges the duplication burdensome across two files; either is acceptable,
  note this as a TEST-DESIGNER discretion call, not a CODE-DESIGNER-mandated shared
  module).

Test flow (single test, or split into "before" + "after" — TEST-DESIGNER's call on
granularity, both satisfy AC2 as long as the causal link is asserted within one test's
scope so a flaky pass in isolation can't hide a regression):

1. `provisioned_tenant()` → `%{tenant_id:, schema_name:}`.
2. `downgrade_task_completed_to_v1!(schema_name)`.
3. `start_instance_with_pending_task!(schema_name, graph_with_form_schema(schema_computed_and_visible_when()))`
   → `{instance_id, task, _definition}`.
4. Submit `complete_attrs(%{output_variables: %{"amount" => 5, "bonus" => 999, ...}})` (the
   exact disagreement-triggering payload from the existing AC2 fixture) via
   `Engine.complete_task(task.id, attrs, prefix: schema_name)`.
5. **Pre-backfill assertion (reproduces the defect):**
   `assert {:error, {:event_append_failed, {:payload_validation_failed, failures}}} =
   Engine.complete_task(...)` — per §1's traced error shape, **not** the issue text's bare
   shorthand. Also assert the task row is still `status: :pending` (no partial commit —
   mirrors the existing `AC1 cross_field_validation` test's `untouched_task.status ==
   :pending` pattern at line 303-304 of `engine_form_expression_reevaluation_test.exs`).
6. `assert {:ok, %{updated: updated, skipped: _}} = Backfill.run(task_completed_v2_attrs())`
   and `assert updated >= 1`.
7. **Post-backfill assertion (confirms the fix):** re-issue the *same* `complete_task/3`
   call (same `task.id`, since step 5's attempt rolled back and left the task `:pending` —
   confirm the `idempotency_key` inside `complete_attrs/1` is either omitted or freshly
   unique per call per that helper's own existing convention, so this second call isn't
   itself rejected as a duplicate idempotency key) and assert `{:ok, result}`, then assert
   the `computed_field_disagreement` event rides inside
   `task_completed_events(schema_name, instance_id)`'s payload — same shape ISS-292's own
   AC2 test already asserts (`event.payload["merged_variable_events"]` filtered to
   `"event" == "computed_field_disagreement"`, `"field" == "bonus"`, `"submitted_value" ==
   999`, `"server_value" == 6`).
8. A second variant of the same test (or a second `describe` block) repeats steps 1-7
   substituting the `visible_when_false_value_discarded`-triggering payload (the existing
   AC3 fixture: submit `"note"` while `"amount" => -1` makes `note`'s `visible_when` false)
   — AC2 of GH#1200 accepts either kind as satisfying the criterion, but covering both
   costs little given the fixtures already exist verbatim in
   `engine_form_expression_reevaluation_test.exs` and closes the gap completely rather than
   leaving one kind design-untested.

## 6. Scope confirmation and SECURITY-REVIEWER call

**Scope is confined to:**
- `lib/mix/tasks/letflow.backfill_event_type_versions.ex` (extended per §3).
- `test/letflow/tenant_provisioning/backfill_test.exs` (new `describe` block, §5.1).
- `test/letflow/tenant_provisioning/task_completed_backfill_test.exs` (new file, §5.2).

No migration, no `Letflow.TenantProvisioning.Backfill` change, no `Registry` change, no
`FormExpressionReevaluation` change (that module is read-only context for this fix, its
output is what needs a schema wide enough to accept, not something this fix alters).

**SECURITY-REVIEWER: YES, route this through SECURITY-REVIEWER** — same call ISS-0332's own
pipeline made (confirmed via `handoffs/WF03-ISS0332-20260826/step-03b-security-reviewer.json`
— that run *did* gate this exact mechanism through SECURITY-REVIEWER before ELIXIR-DEV's
change shipped). Reasoning, stated explicitly rather than defaulted:

- The mix task iterates and mutates **every provisioned tenant's** `event_type_registry`
  row in a single run (`Repo.all(Registration)` with no tenant filter) — a tenant-isolation-
  adjacent surface even though it runs offline/operator-invoked rather than through an HTTP
  route. A bug that let one tenant's backfill attempt read or write another tenant's schema
  (e.g. a `prefix:` mix-up) would be exactly the class of cross-tenant leak
  `security-invariants.md`'s INV-1 (tenant isolation) exists to catch — and this fix, unlike
  ISS-0332's *original* introduction of `Backfill.run/1`, still touches the file that drives
  which event types get swept, worth a second INV-1 look even though the underlying
  `Backfill.run/1`/`Registry.register_type/2` code performing the actual per-tenant
  `prefix:`-scoped writes is unchanged by this fix.
- It widens what payloads a tenant's own event stream will subsequently accept
  (loosening a JSON-Schema validation gate is itself a security-relevant control change,
  not merely a data migration) — worth confirming the widened v2 schema genuinely can't
  admit anything unsafe beyond what REQ-292's SECURITY-REVIEWER sign-off (referenced in
  REQ-292's own done-event, "recording SECURITY-REVIEWER's explicit INV-2 sign-off statement
  verbatim") already covered for newly-provisioned tenants — this fix should get the
  equivalent sign-off for the backfilled path.
- Low marginal cost: the JSON schema being backfilled is a byte-verbatim copy already
  reviewed once for REQ-292; SECURITY-REVIEWER's job here is mostly to confirm §3.1's
  "verbatim copy" claim actually holds byte-for-byte and that the mix task's new
  `Repo.all(Registration)`-driven sweep doesn't cross a `prefix:` tenant boundary anywhere
  new — a short, bounded review, not a large one.

## 7. Open questions (none block ELIXIR-DEV — flagged for completeness)

- Should `@event_type_backfills` eventually move to a `Registry`-queryable "pending
  version bumps" table instead of a hardcoded mix-task list, so a future ISS-0332-shaped
  gap doesn't need a third manual mix-task edit? Out of scope here — the issue's own AC3
  explicitly wants the existing mechanism reused/extended, not redesigned; noted for a
  possible future requirement, not decided here.
- §5.2 step 8's "cover both event kinds" is a recommendation, not a hard requirement of
  GH#1200's AC2 text (which says "or") — TEST-DESIGNER may descope to one kind if turn
  budget is tight; flagged so that choice is made deliberately, not by omission.

## 8. Files to be created/modified by ELIXIR-DEV / TEST-DESIGNER

- Modify: `lib/mix/tasks/letflow.backfill_event_type_versions.ex` (§3).
- Modify: `test/letflow/tenant_provisioning/backfill_test.exs` (§5.1, new `describe` block).
- Create: `test/letflow/tenant_provisioning/task_completed_backfill_test.exs` (§5.2).
- No `priv/repo/migrations/` changes.
