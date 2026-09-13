# ISS-0648 fix design: trigger column promotion at entity-definition activation

Status: design for CODE-DESIGN-VALIDATOR review. Fixes ISS-0648
(`docs/issues/ISS-0648.yaml`, BLOCKER, discovered by REVIEWER during REQ-336).
Touches `lib/letflow/entities/definitions.ex`,
`lib/letflow/tenant_provisioning.ex`, and (one small hardening item)
`lib/letflow/entities/definition/ddl.ex`. Does not touch
`lib/letflow/definitions/solution_pack_install.ex` or `solution_pack.ex` — see
§1 for why the trigger point is deliberately not there.

## 0. Re-verification performed before choosing a direction

Read in full, in the current tree, before deciding anything:

- `docs/migration/decisions/0023-entity-storage-hybrid.md`,
  `0024-entity-promotion-ddl-execution.md` (REQ-298's actual governing
  record for column promotion's mechanism and lifecycle),
  `0025-promoted-fk-ondelete-and-localized-text-search-strategy.md`,
  `0026-solution-pack-entity-definitions-section.md` (governs
  `SolutionPack.install/3`'s entity-definition handling).
- `docs/requirements.yaml`'s REQ-295, REQ-296 (implied), REQ-298 entries.
- `lib/letflow/tenant_provisioning.ex` — `register_column_promotion/4`,
  `run_column_promotion/1`, `do_run_column_promotion/2`,
  `ensure_entity_table/2`, `create_and_populate_entity_table/3`,
  `column_promotion_dual_write?/3`, `column_promotions_in_flight/2`,
  `document_from_persisted/1`, `table_name_for_entity_type/1`,
  `tenant_id_for_schema_name/1`.
- `lib/letflow/entities/definition/ddl.ex` — `promoted_columns/1`,
  `promotion_trigger/2`, `unique_constraint_clauses/1`,
  `generate_table_ddl/3`.
- `lib/letflow/entities/definition/validator.ex` — constraint-shape and
  constraint-field-existence rules (`constraint_shape_violations/1`, the
  `fk_field_not_found`-shaped constraint-field check at lines 381-397).
- `lib/letflow/entities/definitions.ex` — `activate_definition/4`,
  `promote_and_demote_siblings/2`.
- `lib/letflow/entities/records.ex` — `create_record/2`,
  `dual_write_promoted_columns/3`, `write_entity_table_row/3`.
- `lib/letflow/entities/record/projector.ex` — `write_snapshots/3`,
  `maybe_write_entity_table_snapshots/3`, `write_entity_table_snapshots/4`.
- `lib/letflow/definitions/solution_pack.ex` — `create_packed_entity_definitions/3`,
  and the design doc it cites, `req305-solution-pack-entity-definitions-install.md`.
- `priv/packs/bilimbaga/entity_definitions/*.json` (all 13), grepped for
  `constraints`.

## 1. Direction chosen: (a), automatic promotion — triggered from
`activate_definition/4`, not from pack install

**Fix direction (a) from the issue** — the platform automatically registers
and runs column promotion for every entity type that declares a real
enforcement need — is correct, but the issue's own phrasing ("solution_pack_install.ex
(or activate_definition/4)") leaves open *which* of those two is right. It is
`activate_definition/4`, not `SolutionPack.install/3`/`create_packed_entity_definitions/3`,
for three independent reasons, each grounded in an existing decision record
rather than asserted fresh:

1. **0024 itself names the trigger event as "an entity definition being
   edited," and separately as "a pack install."** Read literally this looks
   ambiguous between install-time and activation-time. But 0026 §"packed
   entity definitions install `:inactive`-only" already answers a directly
   adjacent question — *"whether a packed entity type is `:inactive`-only or
   also gets activated"* — with **inactive-only, deliberately, matching every
   other artefact type `SolutionPack.install/3` installs** (a `packed_definition`
   becomes a `ProcessDefinition` with no activation step either). That
   decision's reasoning is explicit: auto-activating entity definitions
   specifically "would make 'pack installed' mean something structurally
   different for this one artefact type than for every other artefact type
   this module installs, with no requirement text asking for that stronger
   claim." Making pack install *also* auto-promote columns is the same shape
   of asymmetric special-casing 0026 already rejected once, for the same
   artefact type, for the same reason — it would mean "pack installed"
   triggers real DDL/table creation for entity types specifically, silently,
   while every other artefact type installed by the same call stays inert
   until a separate, explicit step. 0026 is still the standing decision;
   this design does not reopen it.
2. **`Records.create_record/2` only ever resolves an entity type's *active*
   definition** (`fetch_active_definition/2` → `Definitions.get_active_definition_by_name/2`).
   An `:inactive` entity type accepts zero writes through the ordinary path —
   there is no `entity_record_latest` traffic, hence no correctness or
   uniqueness exposure, for any entity type sitting `:inactive` after
   install. Promoting columns (creating a real Postgres table, running
   backfill, taking per-schema advisory locks) for a type nothing can write
   to yet is pure wasted DDL work with no enforcement benefit — it does
   nothing ISS-0648 is about. The first moment enforcement actually matters
   is the same moment writes become possible: activation.
3. **`activate_definition/4` is the single existing choke point every entity
   type passes through before it is usable, pack-installed or not** — the
   HTTP route `POST /entities/definitions/:name/activate` is the only
   caller (`lib/letflow/routers/entities.ex:701`), and 0026's own
   re-verification (§"re-verification performed") independently confirmed
   this: "a separate activation call... remains a distinct, later operation
   — outside `SolutionPack.install/3`'s scope, exactly as it is today for a
   freshly-created entity definition via the ordinary (non-pack) create
   path." Hooking here means the fix applies uniformly to every entity type
   that ever becomes active — pack-installed or hand-authored through the
   ordinary create+activate flow — with one code path, not two (pack-install
   path plus a separately-written non-pack path). `SolutionPack.install/3`
   would need this same logic duplicated for the non-pack create path
   anyway, since a hand-authored entity type with a `constraint_def` has the
   exact same enforcement gap today and is not pack-install-specific at all
   (ISS-0648's own "BLAST RADIUS" paragraph already says this: "not specific
   to tag or to BilimBaga... ANY entity definition... in any tenant").

**Consequence:** `solution_pack_install.ex`/`solution_pack.ex` are unchanged
by this fix. 0026's "install stays inert" decision is preserved exactly;
this fix only strengthens what already-standing decision ("activation is the
real go-live moment") does at that moment.

## 2. Where the trigger goes and what determines which entity types need it

### 2.1 Trigger point

`Letflow.Entities.Definitions.activate_definition/4`
(`lib/letflow/entities/definitions.ex:407-425`), specifically inside
`promote_and_demote_siblings/2` — **after** the existing
`Ecto.Multi` (`demote_siblings` + `promote`) commits successfully, **not**
inside that same `Multi`/transaction. Column promotion's own state machine
(0024 §2) is explicitly per-tenant, non-atomic, potentially slow (a
first-time `CREATE TABLE` + full-history `rebuild_projection/2` replay), and
already designed to run in its own transaction with its own advisory lock
(`run_column_promotion/1`). Nesting it inside `activate_definition/4`'s
existing `entity_definitions`-table `Ecto.Multi.transaction/1` would hold
that lock and connection for the promotion's whole duration and couple two
independently-reviewed transactional boundaries together for no benefit —
0024 §1 already rejected "the promotion path itself" running DDL inline in
a request/response cycle as its own decision point (option (c)), for the
adjacent reason that doing so removes "a retry boundary distinct from the
definition edit that triggered it." Keeping this fix's call to promotion
strictly *after* the activation transaction commits preserves that same
retry boundary: activation succeeding is never contingent on promotion
succeeding (see §2.3 below), and a promotion retry never has to re-run
activation.

New private function on `Letflow.Entities.Definitions`:

```
@spec ensure_column_promotions(entity_definition :: EntityDefinition.t(), prefix :: String.t()) ::
        :ok
```

Called as the last step of `activate_definition/4`, after
`promote_and_demote_siblings/2` returns `{:ok, promoted}`, with `promoted`
(the just-activated row) and the same `prefix` `activate_definition/4`
already has. Its own return is always `:ok` — see §2.3 for why it can never
turn `activate_definition/4`'s own result into an error.

### 2.2 What determines which entity types need it

**Any entity definition with at least one `constraints` entry** — exactly
the issue's own proposed criterion, and the narrowest one that actually
closes ISS-0648 (a `queried: true` field with no `constraint_def` has no
correctness gap today; only a declared-but-unenforced `constraint_def` does).
Concretely: `document.constraints != []`, where `document` is
`TenantProvisioning.document_from_persisted(promoted)` (the same helper
`create_and_populate_entity_table/3` already uses — no new document-shape
derivation).

**What gets registered, and how many `register_column_promotion/4` calls.**
Column promotion is registered **per attribute**, not per constraint or per
entity type (`register_column_promotion/4`'s own signature: `entity_type,
attribute, column_spec, tenant_ids`). `ensure_column_promotions/2` therefore:

1. Loads `document = TenantProvisioning.document_from_persisted(promoted)`.
2. If `document.constraints == []`, returns `:ok` immediately — no-op for
   the common case (no constraints declared).
3. Otherwise resolves `tenant_id` via
   `TenantProvisioning.tenant_id_for_schema_name(prefix)`. On
   `{:error, :invalid_schema_name}` — realistically unreachable, since this
   `prefix` is the same value `activate_definition/4` already used
   successfully one line above to activate the row — logs a loud warning
   (§2.3) and returns `:ok` rather than raising.
4. Computes `promoted_columns = DDL.promoted_columns(document)` — the
   **same** set `create_and_populate_entity_table/3` already derives, via
   the same, already-reviewed function. This fix does not add a second way
   to decide which attributes promote.
5. Filters `promoted_columns` down to **only the attributes that appear in
   at least one `constraint_def.fields` entry** — not every promotable
   attribute on the entity type. Promoting a `queried: true` field with no
   constraint is REQ-299/300's query-performance territory, not this
   fix's concern; ISS-0648 is scoped to closing the *unenforced-constraint*
   gap, and expanding scope to "promote everything queryable on activation"
   would materially change the cost/blast-radius profile addressed in §5
   without a stated requirement asking for it (the same "no requirement
   text asking for that stronger claim" reasoning §1 already applies once).
6. For each such attribute, calls `register_column_promotion/4` with
   `tenant_ids: [tenant_id]` (this one tenant only — never `:all`; see §5)
   and the `column_spec()` built the same way `create_and_populate_entity_table/3`'s
   own caller already builds it elsewhere for a single-attribute promotion
   (`pg_type` via `DDL.field_type_to_pg_type/1`, `nullable: true` always per
   0023's additive-only rule, `references_entity` from the field's `fk_def`
   if any — none of the constrained attributes in the current corpus are
   also FK fields, see §4, so this is a straightforward reuse of the
   existing helper shape, not new logic).
7. For each row `register_column_promotion/4` returns
   `{:ok, [%ColumnPromotion{}]}` for, calls `run_column_promotion/1` with
   that row's `id`.

**Why `run_column_promotion/1` only — never `backfill_column_promotion/1`
or `activate_column_promotion/1`.** This is the design's central scoping
decision and is stated explicitly rather than left implicit:

- `run_column_promotion/1` alone already does everything ISS-0648 needs:
  it calls `ensure_entity_table/2`, which (for a brand-new entity type)
  calls `create_and_populate_entity_table/3`, which (a) issues the real
  `CREATE TABLE ... UNIQUE (...)` DDL via `DDL.generate_table_ddl/3` —
  the actual fix for the bug as filed — and (b) immediately backfills every
  existing record via `Projector.rebuild_projection/2` ("first population,"
  `create_and_populate_entity_table/3`'s own comment). The promotion row
  lands at `status: "ddl_applied"`.
- **Once `ddl_applied`, `TenantProvisioning.column_promotion_dual_write?/3`
  is `true`, and stays `true` through `"backfilling"`/`"backfilled"`** —
  `Records.dual_write_promoted_columns/3` (`records.ex:342-349`) queries
  `column_promotions_in_flight/2` (rows with `status in
  ["ddl_applied","backfilling","backfilled"]`) on **every** create/update
  and, if the promotion row is in that set, writes the record into the
  per-entity-type table via `write_entity_table_row/3` — which is exactly
  the `INSERT ... ON CONFLICT (record_id) DO UPDATE` against the real table
  carrying the real `UNIQUE` constraint. **As long as the promotion row
  never leaves this window, every future create/update for this entity
  type in this tenant is checked against the real constraint, forever** —
  which is the actual enforcement ISS-0648 is asking for, and it is already
  live at `ddl_applied`, with no further state transition needed.
- **Critical finding, load-bearing for this decision: do NOT call
  `activate_column_promotion/1`.** Traced `Records.dual_write_promoted_columns/3`
  and `TenantProvisioning.column_promotions_in_flight/2` together: the
  in-flight set is `["ddl_applied", "backfilling", "backfilled"]` —
  **`"active"` is excluded.** Once a promotion reaches `"active"`,
  `dual_write_promoted_columns/3` returns `{:ok, :skipped}` for that
  attribute on every subsequent write — no live code path writes to the
  per-entity-type table for an `"active"` promotion; `Letflow.Entities.Record.Projector`
  only writes to it during an explicit `rebuild_projection/2` replay
  (backfill), never on an ordinary live create/update. This appears to
  contradict 0024 §3 step 3's stated intent ("the write path... stops
  dual-writing the attribute into `field_values`... going forward" — i.e.
  single-write to the column, not zero-write), and if left uncorrected it
  would mean that promoting a constrained attribute all the way to
  `"active"` *stops* enforcing the constraint on new writes going forward —
  the opposite of what this fix exists to achieve, and strictly worse for
  ISS-0648's purpose than stopping at `ddl_applied`. **This design
  deliberately avoids ever exercising that path**: promotions this fix
  registers are left parked at `ddl_applied` permanently. They never reach
  `backfilled`/`active`, so `query_eligible` never becomes `true` for them —
  which is fine, because nothing in this fix's scope needs `Allowlist` to
  treat the attribute as a `:typed_column` (that is REQ-299/300's territory,
  unrelated to constraint enforcement, and Allowlist already treats it as an
  ordinary `:json_field` otherwise, which is correct and unaffected).
  **This is flagged as its own follow-up issue, not fixed here** — filed as
  ISS-0649 below (§7) — because fixing `dual_write_promoted_columns/3` to
  keep writing at `"active"` is a change to a live, already-shipped write
  path with its own review surface, out of proportion to and independent of
  "wire up the missing trigger call," which is all ISS-0648 itself asks for.
  RELEASE-VALIDATOR/REVIEWER should confirm this fix's acceptance criteria
  (§6) hold with promotions parked at `ddl_applied` specifically, not assume
  the state machine's "later" states.

### 2.3 What happens on failure: never blocks activation, always loud

**Activation itself always succeeds or fails purely on its own terms** —
`ensure_column_promotions/2`'s `:ok`-only return type (§2.1) is deliberate:
whatever `register_column_promotion/4`/`run_column_promotion/1` return,
`activate_definition/4`'s own `{:ok, promoted}` is unaffected. Reasoning:

- **Degrading gracefully, not blocking, matches 0024's own designed failure
  semantics exactly** — a promotion stuck at `"pending"` (registration
  succeeded, DDL never ran) or `"ddl_failed"` (DDL/backfill raised) is a
  **named, first-class, expected state** in 0024 §2, with its own repair
  story ("Repair is a retry of the same DDL step for that one row, not a
  whole-batch re-run"). 0024 §2 also states plainly what a tenant "stuck"
  this way keeps working: "That tenant is not 'unavailable' — normal reads
  and writes against that entity type continue exactly as before the
  promotion was attempted." Blocking activation on promotion success would
  make `activate_definition/4` fail an entity type into permanent
  uselessness (nothing can ever write it, since only `:active` definitions
  are writable) over a *degraded-but-designed-for* condition, which is a
  strictly worse outcome than what 0024 already accepts as normal operation.
- **Loud, not silent.** Every `{:error, reason}` from
  `register_column_promotion/4` or `run_column_promotion/1` is logged via
  `Logger.error/2` inside `ensure_column_promotions/2`, tagged with
  `entity_type`, `attribute`, `tenant_id`, and the reason — structured
  enough that an operator (or a future automated sweep) can find every
  entity type whose constraint is *declared* but not yet *enforced* for a
  given tenant, without a bespoke report tool: the `entity_column_promotions`
  table's own `status`/`last_error` columns (0024 §2) already are that
  report — `WHERE status NOT IN ('ddl_applied','backfilling','backfilled')
  AND entity_type IN (<any entity type with a constraint>)` is a query
  against existing schema, not new work. This design does not add new
  read-side tooling for that; it is left as an operational query, following
  the state-machine's own already-decided reporting shape (0024's own
  Consequences do not name a report tool either — the table's columns are
  it).
- **Retryable without re-running activation.** Because `ensure_column_promotions/2`
  is idempotent-safe to call again (registering a promotion that already has
  a `pending`/`ddl_applied`/... row for the same `(tenant_id, entity_type,
  attribute)` key hits the unique index on that triple — see §2.4), a
  fix-forward path (an ops script, or a future admin endpoint) can re-run
  `run_column_promotion/1` directly against the existing row id without
  needing to reactivate the definition.

### 2.4 Idempotency: repeated activation of the same entity type

`activate_definition/4` can run more than once for the same `(tenant_id,
name)` over its lifetime (a new version activated later, or the same version
re-activated). `register_column_promotion/4` inserts unconditionally
(`Repo.insert(ColumnPromotion.changeset(...))`); the `entity_column_promotions`
unique index is on `(tenant_id, entity_type, attribute)` (0024 §2). A second
`ensure_column_promotions/2` call for the same entity type in the same
tenant, for an attribute already registered, hits that unique constraint on
insert. `ensure_column_promotions/2` must therefore **check for an existing
row first** (a new, small, read-only accessor,
`TenantProvisioning.column_promotion_registered?/3` — `tenant_id,
entity_type, attribute -> boolean`, a trivial wrapper around the same
`fetch_column_promotion_by_natural_key/3` private helper
`column_promotion_query_eligible?/3`/`column_promotion_dual_write?/3`
already use, made a public-but-`@doc false` accessor the same way
`entity_table_exists?/2` is) and skip registration (proceeding straight to
`run_column_promotion/1` on the existing row's id if it is not yet
`ddl_applied`+) rather than treating the unique-index hit as a promotion
failure to log. This is not new state-machine logic — it is the same
"idempotent retry" the state machine's own `check_additive_only/3` +
`:idempotent_skip` branch already names for the DDL-issuing side; this adds
the equivalent idempotency check on the *registration* side, which
0024/REQ-295 did not need before because nothing previously called
`register_column_promotion/4` more than once for the same key.

## 3. A promotion-independent uniqueness check: considered and rejected

Direction (b) — a query-before-insert or an expression index on
`entity_record_latest.field_values`, added into `Records.create_record/2`'s
own validation path — is **not** the chosen direction, for reasons specific
to what re-reading 0023/0024/REQ-298 actually shows the platform already
committed to:

- **It would be a second, divergent enforcement mechanism, not a
  complement to the first.** REQ-298 already built real DDL-based
  enforcement (`unique_constraint_clauses/1` → `CREATE TABLE ... UNIQUE`) —
  the issue's own text confirms this compiles correctly; only the trigger
  to run it is missing. Bolting an *additional*, JSONB-query-based
  uniqueness check onto `create_record/2` alongside that would leave two
  independently-implemented uniqueness mechanisms in the codebase — the
  real Postgres constraint (once triggered) and a hand-rolled check-then-
  insert race (query-before-insert is inherently racy without the same
  constraint backing it, since two concurrent `create_record/2` calls could
  both pass the pre-check before either inserts) — that could silently
  diverge over time (e.g. a future promotion reaching `active` changes which
  table holds the authoritative value; the blob-based check would not know
  to look there). This is exactly `docs/anti-patterns.md`'s "documented
  equality that silently stopped being true" shape, applied to "two
  uniqueness mechanisms agree" instead of "two modules agree."
- **A partial/expression unique index directly on
  `entity_record_latest.field_values ->> 'name'`, scoped per entity type,**
  would be schema-per-tenant DDL outside the `Letflow.TenantProvisioning`
  promotion pipeline entirely — a second DDL-execution mechanism 0024
  explicitly considered and rejected building (option (b) in 0024 §1, "a
  dedicated migrator module," rejected because it would have to
  reimplement the exact identifier-safety argument `Letflow.TenantProvisioning`
  already owns). Building a *third* DDL-execution path (beyond
  `Letflow.TenantProvisioning`'s promotion pipeline and the tenant-scoped
  migration manifest) for this one case repeats that already-settled
  argument's mistake.
- **The real mechanism already exists and already passed both gates**
  (SECURITY-REVIEWER PASS + REVIEWER PASS on 0024, REQ-298's own acceptance
  criteria proven with real unique-violation tests). The only genuinely
  missing piece is one call that was never wired in — which is a materially
  smaller, lower-risk change than adding a second enforcement mechanism
  alongside a correct one that merely isn't invoked yet.

## 4. Blast radius: every currently-affected entity type

`grep -rn '"constraints"' priv/packs/*/entity_definitions/*.json` across the
one pack that exists today (`bilimbaga`) and inspecting each hit's actual
`constraints` value (several files mention the word "constraints" only in
free-text `description` prose, e.g. `category.json`, `exam.json`,
`session.json`, `session_event.json` — confirmed by reading each; these do
**not** declare a real `constraints` key and are excluded below). Real
`constraints` declarations, all `type: "unique"`:

| Entity type | Constraint name | Fields |
|---|---|---|
| `tag` | `uq_tag_name` | `["name"]` |
| `exam_manual_question` | `uq_exam_manual_question_rule_id_question_id` | `["rule_id", "question_id"]` |
| `exam_question_rule` | `uq_exam_question_rule_exam_id_sort_order` | `["exam_id", "sort_order"]` |
| `exam_question_rule_tag` | `uq_exam_question_rule_tag_rule_id_tag_id` | `["rule_id", "tag_id"]` |
| `exam_section` | `uq_exam_section_exam_id_sort_order` | `["exam_id", "sort_order"]` |
| `question_tag` | `uq_question_tag_question_id_tag_id` | `["question_id", "tag_id"]` |
| `session_answer` | `uq_session_answer_session_id_question_id` | `["session_id", "question_id"]` |
| `session_question` | `uq_session_question_session_id_question_id` | `["session_id", "question_id"]` |
| `session_question_score` | `uq_session_question_score_session_id_question_id` | `["session_id", "question_id"]` |

**9 entity types, all in the one pack that exists, all currently unenforced
the same way `tag` is.** Several are the many-to-many join-entity shape
REQ-298's acceptance criteria specifically named (`exam_question_rule_tag`,
`question_tag`) — REQ-298's own tests proved the DDL for that shape works;
this fix is what makes those tests' real-world equivalent actually run for
a pack-installed instance. This is the concrete scope TEST-DESIGNER should
size coverage against — not `tag` alone.

**Verified separately: every constrained field in this corpus is already
`queried: true` or an `fk_def` field**, so `DDL.promoted_columns/1` already
includes all of them (confirmed per-file: `tag.name` is `queried: true`;
every `*_id` field in the eight join/rule-position entity types is either an
`fk_def().field` or independently `queried: true`). §5 below still names the
one related latent gap this corpus happens not to trigger.

### 4.1 Related, out-of-corpus hardening: `promotion_trigger/2` should also
fire for constrained fields

`DDL.promotion_trigger/2` (`ddl.ex:384-390`) promotes a field only if it is
an `fk_def().field` or `queried: true` — **not** if it merely appears in a
`constraint_def.fields` list. `Validator`'s constraint-field check
(`validator.ex:381-397`) only confirms a constrained field *exists* among
`fields`, not that it is promotable. Today's corpus never exercises this gap
(§4 above), but nothing prevents a future entity definition from declaring
`constraints: [{fields: ["some_field"]}]` where `some_field` is neither
`queried: true` nor an FK — `unique_constraint_clauses/1` would still emit
`UNIQUE ("some_field")` unconditionally into `generate_table_ddl/3`'s output,
referencing a column `promoted_columns/1` never included, producing a
`CREATE TABLE` statement that fails at DDL-execution time with a genuine
Postgres "column does not exist" error (surfacing as `{:ddl_failed,
exception}}`, not silently). **Recommended fix, bundled into this same
change since it is a one-line addition to the same function this design
already reasons about:** add a third `cond` clause to `promotion_trigger/2`,
`MapSet.member?(constrained_field_names, Map.get(field, :name)) -> :constrained`
(a new trigger atom, treated identically to `:queried` by every existing
caller of `promotion_trigger/2`'s result — none of them currently branch on
which atom it returns except the `:fk`-vs-other split in `fk_column_pg_type/2`,
so `:constrained` needs the same "not `:fk`" treatment `:queried` already
gets there). This closes the gap defensively rather than leaving it to
surface as a confusing DDL failure the first time a future pack author
constrains a non-queried field. Not required to fix ISS-0648's filed bug
(§4's corpus doesn't trigger it) but cheap enough, and directly adjacent
enough to code this design already touches, to include in the same
requirement rather than file separately. CODE-DESIGN-VALIDATOR should treat
this as in-scope-but-optional: acceptable to defer to a follow-up if
ELIXIR-DEV/REVIEWER judge it adds risk to an otherwise-small fix.

## 5. INV-1 (tenant isolation): no new leak, no new scaling exposure

- **Single-tenant registration, never `:all`.** `ensure_column_promotions/2`
  calls `register_column_promotion/4` with `tenant_ids: [tenant_id]` — the
  one tenant whose `activate_definition/4` call is in flight — never
  `:all`. This matters twice: (a) it reuses exactly the safe `tenant_id`
  resolution 0024's SECURITY-REVIEWER gate already re-checked and PASSed
  (`tenant_id_for_schema_name/1`'s validated-format parse, independent of
  any caller-supplied identifier beyond the same `prefix`
  `activate_definition/4` already trusted to activate the row); (b) it means
  activating one tenant's entity type never triggers DDL fan-out against any
  *other* tenant's schema — the exact cross-tenant-request-triggers-cross-
  schema-DDL shape 0024 §1 rejected under option (c) is not reintroduced
  here, because this design's trigger point (activation) is itself already
  per-tenant-scoped (the `prefix` argument), unlike a hypothetical global
  "promote for every tenant that has this pack installed" sweep would be.
- **No new identifier-construction path.** `ensure_column_promotions/2`
  constructs no schema name, table name, or SQL identifier itself — every
  identifier-bearing operation flows through `register_column_promotion/4`/
  `run_column_promotion/1`, unchanged, which already resolve `schema_name`
  exclusively via `tenant_id_for_schema_name/1`/`Registration`, per 0024's
  already-PASSed design.
- **Scaling: bounded by constrained-attribute count, not tenant count.**
  Because the trigger is per-activation (one tenant, one entity type, at
  most `length(document.constraints |> Enum.flat_map(& &1.fields) |>
  Enum.uniq())` new promotion registrations — single digits in every entity
  type in the current corpus, §4), a single `activate_definition/4` call
  never does more work than "create one table (if not already present) plus
  run a full-history replay for that one entity type in that one tenant." A
  tenant with many entity types each declaring constraints pays this cost
  once per entity type, at the moment each is activated — an operator-paced
  event, not a request stampede. This is a materially smaller and better-
  bounded blast radius than a hypothetical "promote for every tenant with
  this pack installed" sweep would be (which this design does not do — see
  above).
- **No cross-tenant read exposure.** `ensure_column_promotions/2` reads only
  `promoted` (the just-activated row, already scoped to the caller's own
  tenant via `prefix`) and writes only `ColumnPromotion` rows keyed to that
  same `tenant_id`. Nothing added here reads or writes another tenant's
  `entity_column_promotions` rows or schema.

## 6. Migration/backfill concern: pre-existing dirty data is a real,
addressed risk — not "acceptable to ignore," and not silent

**This is not a hypothetical.** ISS-0648's own empirical proof already shows
a tenant can have accumulated real duplicate `tag` records (or any of the
other 8 entity types in §4) before this fix lands, because enforcement has
never run. Once this fix wires the trigger in, the **very next** activation
of an already-dirty entity type calls `run_column_promotion/1` for the first
time, which (via `ensure_entity_table/2` → `create_and_populate_entity_table/3`)
does two things in sequence inside one transaction: `CREATE TABLE ... UNIQUE
(...)`, then `Projector.rebuild_projection/2` to backfill every existing
record. **The backfill of a genuinely dirty entity type will hit its own
newly-created `UNIQUE` constraint** — two existing records with the same
`name` (say) both replay into `entity_tag`, and the second `INSERT` violates
the constraint the first successfully created.

**Traced what happens today if that occurs, because it changes this fix's
required scope:** `Projector.write_entity_table_snapshots/4`
(`projector.ex:332-379`) issues each backfill row via `Repo.query!(...)` —
the raising variant — inside `write_snapshots/3`'s `Repo.transaction/1`
(`projector.ex:270-293`). A raised `Postgrex.Error` from `query!` is **not**
a `Repo.rollback/1` call; `Repo.transaction/1` does not catch an arbitrary
raise, so the exception propagates out of `write_snapshots/3`, out of
`rebuild_projection/2`, out of `create_and_populate_entity_table/3`'s `with`
chain, out of `ensure_entity_table/2`, out of `do_run_column_promotion/2`,
and out of `run_column_promotion/1`'s own outer `Repo.transaction/1` (which
is a plain function call wrapping that transaction, not a rescue boundary)
— **as an unhandled exception, not the `{:error, {:ddl_failed, exception}}`
shape `do_run_column_promotion/2`'s other failure branches already produce.**
The `ColumnPromotion` row is left at `"pending"` forever (never reaches
`"ddl_failed"`, since `mark_ddl_failed_and_return/3` never runs — the raise
skips it entirely), with no `last_error` recorded.

**This must be fixed as part of this same design, not left for a later
issue** — it is not a new gap this design introduces, but it is the specific
mechanism by which item 6's stated risk ("a tenant already has real
duplicate records") turns from "the retry-and-repair story 0024 already
designed" into "an unhandled crash inside `activate_definition/4`'s call
chain, indistinguishable from a bug in this fix itself." **Required
companion fix, scoped to `create_and_populate_entity_table/3`/
`run_column_promotion/1`'s existing error handling, not new mechanism:**
wrap the `Projector.rebuild_projection/2` call inside
`create_and_populate_entity_table/3` (`tenant_provisioning.ex:1459`) so that
a raised exception from the backfill step is rescued into the same
`{:error, {:ddl_failed, exception}}` shape the DDL-issuing steps immediately
above it already use (`execute_create_table/1`, `execute_create_indexes/3`
both already follow exactly this rescue-into-`{:ddl_failed, _}` convention —
this is extending that same existing convention to cover the one step in
this `with` chain that does not yet follow it, not inventing a new failure
shape). Once rescued this way, the promotion row correctly reaches
`"ddl_failed"` with `last_error` set to the Postgres unique-violation detail
(record ids and the duplicated value are in the exception's own message),
which is exactly 0024 §2's designed repair story: **"Repair is a retry of
the same DDL step... not a whole-batch re-run"** — except here the real
repair a human/operator must do first is fix the duplicate *data*
(deactivate or merge the offending records), then retry the promotion.

**Decision: going-forward enforcement is correct; no separate pre-flight
integrity report tool is needed, because the failure path above already
becomes the report, once the rescue fix above lands.** Reasoning:

- Silently enforcing only for new duplicates while leaving pre-existing
  ones in place (without at least surfacing them) would leave the exact
  same "unenforced constraint" experience for any tenant unlucky enough to
  already be dirty — the failed promotion (once correctly surfaced as
  `ddl_failed` rather than a crash) **is** the integrity signal: a
  non-empty `WHERE status = 'ddl_failed'` row for a constrained entity type
  means "this tenant has data that violates its own declared constraint,"
  discoverable by the same operational query named in §2.3, with the
  specific violating values in `last_error`. Building a second, bespoke
  "scan for duplicates before promoting" tool would duplicate what the
  promotion attempt itself already tells you, for free, once it fails
  loudly instead of crashing.
- A tenant that is *not* dirty (the common case — REQ-336's own empirical
  test aside, most tenants installing `tag` for the first time have no
  records yet) pays no extra cost: promotion succeeds immediately, enforcing
  from that point forward.
- Building an active pre-flight dedup/merge tool (deciding *which* of two
  duplicate `tag` rows survives) is a product/data decision this fix should
  not make unilaterally — it depends on which record's downstream
  references (e.g. `question_tag` rows pointing at one of the two `tag`
  record_ids) should be preserved, which is out of scope for a promotion-
  trigger fix and is exactly the kind of judgment call `core-directives.md`
  says to flag rather than silently resolve. **Flagged here, not resolved
  here:** if REVIEWER/RELEASE-VALIDATOR find real dirty data in a live
  tenant once this fix ships, the dedup/merge decision is its own follow-up
  requirement, informed by whichever `ddl_failed` rows this fix's own
  failure-reporting surfaces.

## 7. Follow-up issues this design surfaces but does not fix here

Filed as separate follow-ups (not blocking this fix, per each section's own
reasoning above for why bundling them in would be disproportionate):

- **ISS-0649** (§2.2): `Records.dual_write_promoted_columns/3` +
  `TenantProvisioning.column_promotions_in_flight/2` stop writing to a
  promoted entity type's per-entity-type table once its `ColumnPromotion`
  row reaches `"active"`, contradicting 0024 §3 step 3's stated intent of a
  single (not zero) write continuing after cutover. This design avoids the
  bug by never activating the promotions it registers, but the bug is real
  and independent of ISS-0648, and will resurface the moment REQ-299/300 (or
  any other future work) drives a promotion through to `"active"` for
  query-performance reasons — at which point that entity type's constraint
  enforcement (and typed-column query correctness) would silently regress
  for every write after cutover. REVIEWER should confirm this gets filed.
- **Optional, bundled at CODE-DESIGN-VALIDATOR's discretion** (§4.1):
  `DDL.promotion_trigger/2` should treat "field appears in a
  `constraint_def.fields` list" as its own promotion trigger, closing the
  latent gap where a constrained-but-not-queried field would produce
  DDL referencing a non-existent column. Zero entity types in the current
  corpus trigger this; recommended as defensive hardening, not a blocker.

## Acceptance criteria for the following ELIXIR-DEV implementation turn

1. `activate_definition/4` calls a new `ensure_column_promotions/2` after
   `promote_and_demote_siblings/2` succeeds; `activate_definition/4`'s own
   `{:ok, EntityDefinition.t()}` / error return shape is byte-for-byte
   unchanged (no new member added to its `@spec`'s union) — proven by a test
   that stubs/forces `ensure_column_promotions/2`'s internals to fail and
   asserts `activate_definition/4` still returns `{:ok, _}`.
2. Activating the real `tag` entity definition (or an equivalent test
   fixture with one `constraint_def`) against a real provisioned tenant
   results in a real `entity_tag` table existing in that tenant's schema
   with a real `UNIQUE` constraint over `name`, proven the same way REQ-298's
   own acceptance criteria were proven: two `Records.create_record/2` calls
   with identical `field_values` after activation, asserting the **second**
   call returns an error (not `{:ok, ...}` with `is_duplicate: false`) —
   this is literally ISS-0648's own empirical repro, re-run and now expected
   to fail correctly.
3. The same test repeated for at least one many-to-many join entity type
   from §4 (`question_tag` or `exam_question_rule_tag`) — duplicate-pair
   rejection, per REQ-298's own worked-example shape, now actually reachable
   through activation rather than only through a hand-constructed
   `register_column_promotion/4` call in a test.
4. Only attributes that appear in a `constraint_def.fields` entry are
   registered for promotion by `ensure_column_promotions/2` — proven by a
   test on an entity type with a `queried: true` field that carries **no**
   constraint, asserting no `ColumnPromotion` row is created for it.
5. Promotions this fix registers are driven through `run_column_promotion/1`
   only — never `backfill_column_promotion/1`/`activate_column_promotion/1`
   — proven by asserting the resulting `ColumnPromotion` row's `status` is
   `"ddl_applied"` (or `"ddl_failed"`, see criterion 7), never
   `"backfilled"`/`"active"`, after activation.
6. Re-activating the same entity type a second time (same `tenant_id`,
   `entity_type`, already-registered attribute) does not raise or return an
   error from `ensure_column_promotions/2`, and does not attempt a second
   `register_column_promotion/4` insert for the same `(tenant_id,
   entity_type, attribute)` key — proven by a test that activates twice and
   asserts exactly one `ColumnPromotion` row exists for that key.
7. `create_and_populate_entity_table/3`'s call to
   `Projector.rebuild_projection/2` is wrapped so that a raised exception
   (e.g. a real unique-violation during backfill of pre-existing duplicate
   data) is rescued into `{:error, {:ddl_failed, exception}}`, matching
   `execute_create_table/1`/`execute_create_indexes/3`'s existing
   convention — proven by a test that provisions a tenant, writes two
   duplicate records for an entity type **before** any constraint exists
   (i.e. before this fix's trigger ever ran for it), then activates the
   definition and asserts `run_column_promotion/1` (invoked via activation)
   returns `{:error, {:ddl_failed, _}}` and the `ColumnPromotion` row is
   `status: "ddl_failed"` with a non-nil `last_error` — not a raised
   exception escaping the test.
8. Criterion 7's failure case does not fail `activate_definition/4` itself
   — the same test's `activate_definition/4` call still returns `{:ok, _}`,
   and a `Logger.error/2` (or equivalent captured-log assertion) fired with
   the entity type, attribute, tenant id, and reason.
9. No promotion is ever registered with `tenant_ids: :all` from this new
   code path — grep the diff for `register_column_promotion(` call sites
   this fix adds and confirm every one passes a single-element list built
   from the activating tenant's own resolved `tenant_id`, quoted in the
   completion report.
10. `SolutionPack.install/3`/`create_packed_entity_definitions/3` remain
    byte-for-byte unchanged — confirmed via `git diff main...HEAD --stat`
    showing no `lib/letflow/definitions/solution_pack*.ex` file touched,
    matching this design's §1 scope fence.
11. `mix letflow.check` passes, with real output quoted.
