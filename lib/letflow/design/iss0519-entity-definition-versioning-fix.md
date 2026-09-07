# ISS-0519 fix design: `entity_definitions` versioning-under-one-name safety

Status: design for CODE-DESIGN-VALIDATOR review. Implements the fix for
ISS-0519 (`docs/issues/ISS-0519.yaml`), building on ISSUE-FIXER's diagnosis at
`handoffs/WF03-ISS0519-20260907/step-01-issue-fixer-diagnosis.json`. Touches
`lib/letflow/entities/definitions.ex`, `lib/letflow/entities/records.ex`,
`lib/letflow/entities/entity_definition.ex`, and adds one new migration.

## 1. Background (from diagnosis, not re-derived here)

Two distinct bugs share one root cause -- `entity_definitions`' versioning
model (one row per `(tenant_id, name, logical_shape_version)`, REQ-225/226)
never had a hard, DB-enforced "at most one row is the active one, per name"
guarantee:

1. **Filed crash**: `Definitions.get_definition_by_name/2`
   (`definitions.ex:201-210`) runs an unfiltered, unordered, unlimited
   `Repo.one/2` against `name`. Once 2+ rows share a `name` (REQ-225/226's own
   intended multi-version-under-one-name workflow), it raises
   `Ecto.MultipleResultsError`.
2. **Deeper latent bug**: `Definitions.activate_definition/4`
   (`definitions.ex:319-339`) sets the newly-promoted row's `status` to
   `:active` but never demotes any sibling row under the same `(tenant_id,
   name)` back to `:inactive`. `entity_definitions.status` can therefore hold
   2+ simultaneously-`:active` rows for one name, so filtering
   `get_definition_by_name/2` to `status: :active` would narrow the crash
   window but not close it -- REQ-203's real "exactly one active version"
   guarantee lives in `artifact_activations` (`Letflow.Repository.Activation`),
   not in this column.

## 2. Scoping decision: ship (A) + (B) + (C) together, in one fix

**Decision: bundle all three.** Do not split (C) into a follow-up issue.

Reasoning:

- The originally filed defect is the crash, but its safe fix is not separable
  from the active-row semantics. (A) alone (order-by + limit on
  `get_definition_by_name/2`) does stop the `Ecto.MultipleResultsError` crash
  in isolation, but it leaves the call site that actually matters for
  correctness -- `Records.fetch_active_definition/2`, reached from the
  user-facing `Records.delete_record/2` path named in ISS-0519's own repro --
  silently able to resolve to the *wrong* version (an old but still merely
  "not the newest" row is never the bug here; the real risk is (A)'s
  newest-row heuristic disagreeing with which version is actually activated).
  Only (B), routed through `Activation.resolve/3`, gives that call site a
  correctness guarantee, not just a crash guarantee.
- (B) cannot be implemented as "authoritative" in anything but name if (C) is
  deferred: `Activation.resolve/3` is authoritative for *which
  `artifact_version_id` is active*, but (B)'s own lookup step (`entity_definitions`
  row matching that `artifact_version_id`) still requires `entity_definitions`
  status data to not be silently self-contradictory for anyone who -- per this
  column's own moduledoc framing as a "read-convenience denormalisation" --
  reasonably queries `status: :active` directly instead of going through `Activation.resolve/3`. Shipping (B) without (C) leaves that denormalisation
  provably wrong (diagnosis item 4) for the remaining life of the follow-up
  issue.
- (C)'s two halves are small and low-risk, not a large, separately-schedulable
  body of work: the demote-siblings step is a few extra lines inside
  `activate_definition/4`'s existing transaction-free flow (made transactional
  as part of this fix, see §5.3), and the partial unique index is a single
  additive migration with no backfill risk, since `entity_definitions.status`
  already has no more than one `:active` row per name in any *quiescent*
  dataset seen to date (the bug is a gap on the demotion path, not a
  currently-populated bad state from routine use) -- see §5.4 for the
  pre-migration data-integrity check this design still requires before it is
  allowed to be treated as risk-free.
- All three changes touch the same three files/one migration and share one
  root cause narrative; splitting them would mean re-deriving this same
  context in a second WF-03 run for no isolation benefit (they are not
  independently deployable in a way that reduces risk -- (B) shipped alone
  without (C) is the "correctness guarantee in name only" state described
  above).

## 3. Fix (A): `get_definition_by_name/2` -- deterministic latest-row resolution

**File**: `lib/letflow/entities/definitions.ex`

Keep the function's existing contract exactly as documented today ("the" row
by name, independent of status -- required by the passing test at
`test/letflow/entities/definitions_test.exs:196-211`, which looks up a
freshly-inserted, not-yet-activated row, and by `activate_definition/4`'s own
internal use at `definitions.ex:321`, which must find the row-to-promote
*before* it is active).

Change only the query: add an explicit deterministic ordering plus a limit of
1, so that when 2+ rows share `name` (the normal multi-version condition this
table is designed to hold), the function resolves to the newest row instead
of raising `Ecto.MultipleResultsError`. Ordering key: `inserted_at` descending,
then `id` descending as a tiebreaker -- the exact same ordering idiom already
used by `list_definitions/2` (`definitions.ex:240`, `ORDER BY inserted_at
DESC, id DESC`), so this introduces no new ordering convention into the
module.

No `@spec` change (input/output types stay identical to today's signature at
`definitions.ex:197-200`). No doc-string semantic change beyond noting the
new determinism guarantee explicitly (see §7 for the exact wording
constraint: the doc must not claim this returns "the active" row -- it still
means "the newest row by this name, regardless of status").

| Aspect | Before | After |
|---|---|---|
| Query predicate | `where: e.name == ^name` | unchanged |
| Ordering | none | `order_by: [desc: e.inserted_at, desc: e.id]` |
| Result limit | none (relies on `Repo.one/2` to enforce singularity, which it does not under 2+ rows) | `limit: 1`, then `Repo.one/2` (now safe -- at most 1 row reaches it) |
| Behavior on 1 matching row | returns that row | unchanged |
| Behavior on 2+ matching rows | raises `Ecto.MultipleResultsError` | returns the row with the greatest `(inserted_at, id)` |
| Behavior on 0 matching rows | `{:error, :not_found}` | unchanged |

## 4. Fix (B): new `get_active_definition_by_name/2`, routed through `Activation.resolve/3`

**File**: `lib/letflow/entities/definitions.ex` (new function), `lib/letflow/entities/records.ex` (call-site change)

### 4.1 New function shape

```
@type get_active_definition_error ::
        {:error, :not_found}
        | {:error, :invalid_schema_name}

@spec get_active_definition_by_name(name :: String.t(), prefix :: String.t()) ::
        {:ok, EntityDefinition.t()} | get_active_definition_error()
```

Semantics: resolves the `entity_definitions` row that corresponds to
`name`'s *currently activated* `artifact_version_id`, per REQ-203's
authoritative pointer (`artifact_activations`), not per this table's own
`status` column.

Implementation shape (prose, not code):

1. Call `Letflow.Repository.Activation.resolve(:entity, name, prefix)`.
2. On `{:error, :not_activated}` -> return `{:error, :not_found}`, matching
   this module's and `Records.fetch_active_definition/2`'s existing
   not-found-translation convention (`records.ex:363-367`, `definitions.ex:186`
   /`209`).
3. On `{:error, :invalid_schema_name}` -> propagate unchanged.
4. On `{:ok, %Repository.ArtifactVersion{version_id: version_id}}` -> query
   `entity_definitions` filtered to `tenant_id == ^tenant_id and
   artifact_version_id == ^version_id` (both predicates -- the belt-and-
   suspenders tenant-scoping discipline already used by `list_definitions/2`,
   §217-223 of the same file's own moduledoc reasoning). This predicate is
   guaranteed to match **at most one row**: each `create_definition/2` call
   mints exactly one fresh `artifact_version_id` per inserted row (REQ-226
   design §4's dedup trace, cited directly by the diagnosis), so
   `artifact_version_id` is effectively unique per `entity_definitions` row
   even without its own DB constraint. Use `Repo.one/2` here (not
   `limit: 1` + order-by) since the predicate's own uniqueness is the
   guarantee, not an ordering tie-break -- but see the open question in §8
   about whether to defensively add `limit: 1` anyway.
5. On no matching row (should not occur under the current data model except
   via manual data corruption or a `resolve/3` pointer to a version this
   module never wrote -- i.e. a version_id from a different artifact_kind's
   migration mistake) -> `{:error, :not_found}`, not a `Repo.get!`-style raise
   -- this function must never raise on a data-integrity edge case a caller
   cannot prevent.

### 4.2 `Records.fetch_active_definition/2` call-site change

**File**: `lib/letflow/entities/records.ex:358-372`

Replace the current two-step "unfiltered `get_definition_by_name/2` +
post-hoc `%EntityDefinition{status: :active}` pattern match" with a single
call to `Definitions.get_active_definition_by_name/2`. The pattern-match
branch that currently distinguishes "found but not active"
(`{:ok, %EntityDefinition{}}` at `records.ex:363-364`) from "not found"
(`{:error, :not_found}` at `records.ex:366-367`) collapses into one branch,
since `get_active_definition_by_name/2` already folds "found but not active"
into `{:error, :not_found}` (there is no `entity_definitions` row that is
simultaneously "found by this lookup" and "not active" once the lookup itself
is defined as "the active one").

| Current (`records.ex:358-372`) | New |
|---|---|
| `Definitions.get_definition_by_name(entity_type, prefix)` then match `{:ok, %EntityDefinition{status: :active}}` vs `{:ok, %EntityDefinition{}}` vs `{:error, :not_found}` vs `{:error, :invalid_schema_name}` | `Definitions.get_active_definition_by_name(entity_type, prefix)` then match `{:ok, definition}` -> `{:ok, definition}`; `{:error, :not_found}` -> `{:error, {:definition_not_found, entity_type}}`; `{:error, :invalid_schema_name}` -> propagate |
| 4 match arms | 3 match arms (the "found but inactive" arm is unreachable in the new contract and is removed, not kept dead) |

`fetch_active_definition/2`'s own `@spec`/return contract to its callers
(`{:ok, EntityDefinition.t()} | {:error, {:definition_not_found, String.t()}} |
{:error, :invalid_schema_name}`) is unchanged -- this is purely an internal
implementation swap, invisible to `Records`' own callers.

## 5. Fix (C): demote siblings on activation + DB-enforced invariant

### 5.1 `activate_definition/4` sequencing change

**File**: `lib/letflow/entities/definitions.ex:299-339`

Current sequence: (1) find the row to promote via `get_definition_by_name/2`;
(2) call `Activation.activate_group/5`; (3) on success, `Repo.update` that one
row's `status` to `:active`, un-transacted relative to step 2.

New sequence, all three of steps 2-4 below folded into one `Repo.transaction/1`
(via `Ecto.Multi`, matching this codebase's established idiom for
multi-write atomicity -- `Activation.activate_group/5` itself, and
`Letflow.Audit.append_multi/4`, both already use `Ecto.Multi`):

1. Find the row to promote via `get_definition_by_name/2` (unchanged --
   still needs "the latest row by this name", now safe under fix (A)).
2. Call `Activation.activate_group/5` (unchanged, still the sub-step whose
   success gates everything after it -- REQ-203's own machinery is not
   touched by this fix).
3. **New**, inside one transaction together with step 4: demote every OTHER
   `entity_definitions` row under the same `(tenant_id, name)` (i.e.
   `where: e.tenant_id == ^tenant_id and e.name == ^name and e.id != ^entity_definition.id and e.status == :active`)
   to `status: :inactive`, via `Repo.update_all/3` (a set-based update, not a
   per-row changeset loop -- there is no per-row validation logic beyond the
   single-field `status` flip, so `update_all/3` is the right-weight tool and
   avoids N+1 changeset round-trips for what is expected to almost always be
   0 or 1 sibling row).
4. **Unchanged logic, now transactional**: set the promoted row's own
   `status` to `:active` via its existing changeset/`Repo.update` path.

Ordering of 3 vs. 4 within the transaction matters for the partial unique
index in §5.2: demote-siblings (3) MUST run and commit its effect (within the
same still-open transaction, i.e. be visible to the next statement in the
same transaction) *before* promote-self (4) attempts to set the new row to
`:active` -- otherwise, if the promoted row is a *new* row and a sibling is
still `:active`, step 4's own `UPDATE ... SET status = 'active'` would
transiently create a second `:active` row under the same `(tenant_id, name)`
and violate the partial unique index (§5.2) before step 3's demotion runs,
aborting the whole transaction. Sequencing 3 before 4 (in that order, in the
same transaction) means at every intermediate statement boundary at most one
row is ever `:active` for a given `(tenant_id, name)`, so the constraint is
never even transiently violated. This is a real ordering requirement, not
stylistic -- get it backwards and every activation of a second-or-later
version will fail its own DB constraint.

`activate_group/5`'s own call (step 2) stays outside this new
`entity_definitions`-only transaction, unchanged from today -- it already
has its own internal `Ecto.Multi`/`Repo.transaction/1` (REQ-203, `activation.ex:280-309`)
and this fix does not merge the two transactions into one. This mirrors the
existing design's own stated boundary (`definitions.ex:44-46`,
"not itself wrapped in `activate_group/5`'s transaction") -- unchanged by
this fix, just now the `entity_definitions`-side effect (demote + promote) is
internally atomic with itself, where before it was a single non-transactional
update.

### 5.2 Partial unique index

**New migration**, additive only, no backfill logic required beyond the
pre-check in §5.4.

| Property | Value |
|---|---|
| Table | `entity_definitions` |
| Index columns | `(tenant_id, name)` |
| Partial predicate | `WHERE status = 'active'` |
| Purpose | DB-enforced "at most one active version per `(tenant_id, name)`" -- makes §5.1's application-level demote-then-promote sequencing a real, unbypassable invariant rather than an application-level hope, matching the diagnosis's own recommended enforcement mechanism |
| Constraint name (Ecto convention, mirrors `entity_definitions_tenant_name_shape_idx` in `entity_definition.ex:61`) | `entity_definitions_tenant_name_active_idx` |
| Changeset wiring | `EntityDefinition.changeset/2` (`entity_definition.ex:72-79`) gains one more `unique_constraint/3` clause: `unique_constraint(:status, name: :entity_definitions_tenant_name_active_idx)`, translating a violation into a changeset error on `:status` (parallel to the existing `:name` clause's translation of the tenant/name/shape constraint) rather than letting it surface as a raw `Ecto.ConstraintError` |
| Migration file location convention | `priv/repo/migrations/`, timestamp-prefixed after the existing `20260906000001_create_entity_definitions.exs`, e.g. `<next-timestamp>_add_entity_definitions_active_partial_index.exs` (exact timestamp chosen by ELIXIR-DEV at implementation time per this project's existing timestamp-ordering convention) |

### 5.3 Why `update_all/3`, not a `Multi`-step-per-sibling loop

Sibling count is expected to be 0 (first activation of a name) or 1 (every
subsequent activation, once (C) is in effect) in the steady state -- never
unbounded, since the invariant this very fix establishes caps it at 1 going
forward. A set-based `update_all/3` inside the transaction correctly handles
both today's already-corrupted multi-active-row data (see §5.4) and the
future steady state in one statement, without needing to branch on "how many
siblings are there right now."

### 5.4 Required pre-migration data-integrity check

Before the partial unique index migration can run without failing outright,
any tenant schema that already has 2+ simultaneously-`:active` rows under one
`(tenant_id, name)` (the exact latent-corruption state diagnosis item 4
describes as currently possible, though not confirmed present in any real
tenant today) would violate the new index at creation time. ELIXIR-DEV must
either:

- confirm via a query against every existing tenant schema that no such
  duplicate currently exists (expected outcome, since this bug requires a
  specific activate-version-2-after-version-1 sequence that may not have
  occurred yet in any real tenant), in which case the index migration ships
  as a plain additive migration with no data-remediation step; or
- if any duplicate is found, add a one-time remediation step (deterministically
  demote every row except the most-recently-`activated_at` one per
  `(tenant_id, name)`, using the same `artifact_activation_history` table
  REQ-203 already maintains as the source of truth for "which version was
  activated most recently") to the SAME migration, before the index is
  created.

This check is a build-time verification step for ELIXIR-DEV, not a design
decision this document can resolve without running it against real data --
flagged explicitly rather than assumed clean (see open questions, §8).

## 6. Files touched (summary)

| File | Change |
|---|---|
| `lib/letflow/entities/definitions.ex` | (A) add `order_by`/`limit` to `get_definition_by_name/2`'s query. (B) add new `get_active_definition_by_name/2` function + its `@type`/`@spec`. (C) rewrite `activate_definition/4`'s body to wrap demote-siblings + promote-self in one `Ecto.Multi`/`Repo.transaction/1`. |
| `lib/letflow/entities/records.ex` | (B) change `fetch_active_definition/2`'s implementation to call `Definitions.get_active_definition_by_name/2` instead of `get_definition_by_name/2` + post-hoc pattern match; `@spec`/external contract unchanged. |
| `lib/letflow/entities/entity_definition.ex` | (C) add one more `unique_constraint/3` clause to `changeset/2` for the new partial index. |
| `priv/repo/migrations/<new>_add_entity_definitions_active_partial_index.exs` | (C) new additive migration: partial unique index `(tenant_id, name) WHERE status = 'active'`, named `entity_definitions_tenant_name_active_idx`. Includes remediation step only if §5.4's pre-check finds existing duplicates. |

## 7. Documentation updates required alongside the code change

- `get_definition_by_name/2`'s doc-string (`definitions.ex:192-196`) must be
  updated to state the new deterministic-latest-row behavior under 2+ rows,
  and must explicitly NOT claim this returns "the active" row (that is now
  `get_active_definition_by_name/2`'s job) -- avoid the same kind of
  ambiguity that produced ISS-0519 in the first place.
- `activate_definition/4`'s doc-string (`definitions.ex:299-305`) must state
  the new demote-then-promote sequencing and that it is now internally
  transactional (still a separate transaction from `activate_group/5`'s own).
- `EntityDefinition`'s moduledoc (`entity_definition.ex:17-21`, "`status` is a
  local read-convenience denormalisation... kept in sync by
  `activate_definition/4`") should be updated to state that, as of this fix,
  "kept in sync" is now actually enforced (demote-on-promote + DB partial
  unique index), not merely intended -- so a future reader trusts this
  column's invariant claim.
- REQ-226/REQ-228's design docs (`lib/letflow/design/req226-...md` §6 OQ-3,
  `lib/letflow/design/req228-...md` lines 335-338) should be annotated
  (not silently resolved) to point at this fix as OQ-3's actual resolution --
  a DOC-UPDATER concern, not something this design doc itself edits.

## 8. Testability -- tests ELIXIR-DEV must write

| # | Target | Scenario | Expected result |
|---|---|---|---|
| T1 | (A) regression | Create 2 `entity_definitions` rows under the same `name` (two distinct `logical_shape_version`s, e.g. via `create_definition/2` twice with a document shape change between calls), then call `get_definition_by_name/2` on that name | Returns `{:ok, row}` where `row` is the one created second (greatest `inserted_at`/`id`), NOT `Ecto.MultipleResultsError` -- this is the direct regression test for the exact crash ISSUE-FIXER found |
| T2 | (A) existing-test compatibility | Re-run `test/letflow/entities/definitions_test.exs:196-211` unmodified | Still passes -- single-row case is unaffected by adding `order_by`/`limit` |
| T3 | (A) via `activate_definition/4` | Create 2 versions under one name, activate the newer one | `activate_definition/4` still resolves "the row to promote" correctly (i.e. its internal `get_definition_by_name/2` call keeps working under 2+ rows) |
| T4 | (B) new function, happy path | Create + activate a definition by name | `get_active_definition_by_name/2` returns `{:ok, row}` matching the activated `artifact_version_id` |
| T5 | (B) new function, never activated | Create (but do not activate) a definition by name | `get_active_definition_by_name/2` returns `{:error, :not_found}` |
| T6 | (B) new function, multi-version | Create 2 versions under one name, activate only the OLDER one (out-of-order activation) | `get_active_definition_by_name/2` returns the OLDER row, not the newer one -- proves this function tracks `Activation.resolve/3`'s pointer, not `inserted_at` recency (the key behavioral difference from fix (A)'s function) |
| T7 | (B) call-site regression | Reproduce ISS-0519's originally filed repro path (`Records.delete_record/2` against a `name` with 2+ `entity_definitions` rows) | No longer raises `Ecto.MultipleResultsError`; resolves the correct active definition or returns the documented not-found error |
| T8 | (C) demote-on-promote | Create 2 versions under one name; activate version 1; assert its row is `:active`; activate version 2; re-fetch version 1's row | Version 1's row is now `:inactive`; version 2's row is `:active`; at no point (verifiable via a raw count query for `status = :active AND name = ...` after each activation) are 2 rows simultaneously `:active` |
| T9 | (C) DB constraint, direct | Attempt to set 2 rows under the same `(tenant_id, name)` to `status: :active` directly via 2 separate `Repo.update` calls bypassing `activate_definition/4` (simulating a hypothetical future bug reintroducing the gap) | Second update fails with a changeset error on `:status` (unique_constraint translation), not a raw `Ecto.ConstraintError` and not a silent success |
| T10 | (C) concurrent activation (if the test suite already has a precedent for this kind of test -- `activate_group/5`'s own `test_pause_after`/`test_pause_fun` seam is exactly this precedent) | Two concurrent `activate_definition/4` calls for different versions of the same name | Exactly one wins as `:active` at the end; no transient window leaves 2 rows `:active` (verify using the same `test_pause_after` seam idiom this module's sibling already uses, if ELIXIR-DEV judges it warranted -- flagged as a nice-to-have, not mandatory, since `activate_group/5`'s own row-level `FOR UPDATE` lock plus this fix's single-transaction demote+promote sequencing already provide serialization without needing a new seam) |

## 9. Open questions (not resolved here -- flag forward, do not guess)

- **OQ-1**: §5.4's pre-migration data-integrity check must actually be run by
  ELIXIR-DEV against real tenant data before the migration ships; this design
  cannot state in advance whether remediation is needed.
- **OQ-2**: §4.1 step 4 uses `Repo.one/2` on a predicate this design argues is
  effectively-unique without its own DB constraint (`artifact_version_id` has
  no unique index of its own on `entity_definitions`). Whether to additionally
  add `limit: 1` there as pure defense-in-depth (at negligible cost) is left
  to ELIXIR-DEV's judgment -- either is compatible with this design's stated
  contract, since the predicate's uniqueness is expected to hold regardless.
- **OQ-3**: Whether `get_active_definition_by_name/2` belongs on
  `Letflow.Entities.Definitions` (as designed here, alongside its sibling
  lookup functions) versus being expressed as a thin wrapper living on
  `Letflow.Entities.Records` directly (its only current caller) is a
  module-boundary judgment call; this design places it on `Definitions`
  because REQ-228's own design already named the by-name active-lookup as
  logically belonging to REQ-226's context module (see the diagnosis's
  citation of `req228-...md` lines 335-338), and future callers beyond
  `Records` are plausible (any consumer needing "the active definition for
  this entity type").
