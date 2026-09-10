# 0026 — SolutionPack `entity_definitions` section: schema versioning, install semantics, and the form-schema gap

Status: decided (2026-09-10, `CODE-DESIGNER`, REQ-303), pending its own
`SECURITY-REVIEWER` and `REVIEWER` gates (sections below, not yet filled in).
Owner: `ORCH` (governs REQ-304's export-side and REQ-305's install-side
implementation; both must build against this record's answers rather than
re-deriving the mechanism).

## Independence from 0023 / the REQ-295..302 batch — stated explicitly

**This record is deliberately independent of `0023-entity-storage-hybrid.md`
and every requirement in the REQ-295..302 batch (0024, 0025).** Both this
requirement (S10 gap 13) and 0023 were found by the same 2026-09-09
architecture review, but they answer two unrelated questions:

- **0023's track is entity STORAGE shape** — per-entity-type physical
  tables, the promoted-column/blob hybrid, additive-only promotion. It is
  the subject of `Letflow.Entities.Records`/`Record.Projector` and
  `priv/repo/migrations/`.
- **This record's track (gap 13) is pack DELIVERY format** — whether and how
  an entity definition (the `Letflow.Entities.EntityDefinition` row plus its
  `definition_json`) travels inside a `Letflow.Definitions.SolutionPack`
  document, entirely within `Letflow.Definitions.SolutionPack` and
  `Letflow.Entities.Definitions`.

Closing 0023's work (how a promoted column's DDL runs, 0024; `ON DELETE`/
localized-text strategy, 0025) does not add a pack section, and this
record's `entity_definitions` pack section installs a definition via
`Letflow.Entities.Definitions.create_definition/2` regardless of what that
row's eventual promoted-column shape turns out to be. **Neither track is a
precondition of the other.** 0023/0024/0025 are optional context for this
record (format precedent only, e.g. how a decision record cites file:line
and structures its sign-off sections) — never a dependency. This record's
`depends_on` is `[]`, matching REQ-303's own `docs/requirements.yaml` entry.

## Question

Adding an `entity_definitions` section to `Letflow.Definitions.SolutionPack`'s
pack document raises five concrete questions, none of which the existing
code answers on its own:

1. **Schema versioning** — does `bpm_export_schema_version` change, and what
   do an old pack / new installer and a new pack / old installer mean to
   each other?
2. **Install semantics** — does a packed entity definition install
   `:inactive`-only or also get activated, and what happens on a name
   collision?
3. **The form-schema question** — is a standalone pack section for
   `form_schema` actually needed, or is the "gap" already closed by existing
   code?
4. **The `service_catalog_entries` precedent** — does `entity_definitions`
   follow the same reject-until-supported interim stance while export and
   install land in separate requirements?
5. **INV-1 tenant scoping** — does this design introduce any new
   caller-supplied tenant identifier?

## Re-verification performed (before deciding anything)

All of the following was read in full, in the current tree, on this branch,
before any answer below was written — not assumed from the requirement text:

- `lib/letflow/definitions/solution_pack.ex`:
  - `pack_document` `@type` (lines 186-195): confirmed **exactly four**
    content keys — `definitions`, `service_catalog_entries`, `variable_schemas`,
    `manifest`. No `entity_definitions` key exists anywhere in this type.
  - `check_unsupported_sections/1` (lines 539-540): confirmed the precedent —
    `%{service_catalog_entries: []} -> :ok`; any other (non-empty) value ->
    `{:error, :unsupported_pack_section}`. This is a **pure, pre-transaction**
    check (step 1 of `install/3`, before any query).
  - `parse_document/1` (lines 401-422) and `fetch_list/2` (lines 433-439):
    confirmed `fetch_list/2` defaults **any** missing list key — including a
    key it has never heard of, such as a future `entity_definitions` — to
    `[]` (`Map.get(map, key, [])`, plus an explicit `nil -> {:ok, []}` clause).
    This is a structural default in the shared list-fetch helper, not
    something specific to the three keys it is currently called for.
  - `pack_definition/1` (lines 377-385): confirmed it builds
    `%{definition_id:, process_key:, name:, version:, graph: definition.graph}`
    — `definition.graph` is embedded **verbatim**, not filtered or
    re-projected.
  - `parse_definition/1` (lines 454-468): confirmed it round-trips an
    arbitrary graph map via `fetch_object(raw, "graph")`, which accepts any
    map value and passes it through unchanged — no key-by-key reconstruction
    that could drop an attribute.
- `lib/letflow/definitions/export_import.ex`: confirmed `@export_schema_version
  "bpm/definition/v1"` (line 34) and the `@doc` for `export_schema_version/0`
  (lines 75-85, quote at lines 81-82) states "One version constant in this
  codebase, not two" — this module's own `@doc`, not `SolutionPack`'s,
  states the rationale, and `SolutionPack`'s moduledoc (lines 20-24) confirms
  it reuses it for exactly that reason.
- `lib/letflow/entities/definitions.ex` in full:
  - `create_definition/2` (lines 104-141): confirmed step 4 always inserts
    `status: :inactive` (`insert_entity_definition/6`, line 159 sets
    `status: :inactive` in the `attrs` map passed to `EntityDefinition.changeset/2`).
  - `activate_definition/4` (lines 393-425) and `promote_and_demote_siblings/2`
    (lines 433-455): confirmed it is a **separate call**, takes `name`
    (not an id) as its lookup key, calls
    `Letflow.Repository.Activation.activate_group/5` unchanged with
    `artifact_kind: :entity`, then demotes every sibling under
    `(tenant_id, name)` before promoting the target row — reusing
    `activate_group/5` unmodified, per the moduledoc.
- `lib/letflow/entities/entity_definition.ex`'s `changeset/2` (lines 93-101):
  confirmed the exact constraint shape —
  `unique_constraint(:name, name: :entity_definitions_tenant_name_shape_idx)`,
  backing a **`(tenant_id, name, logical_shape_version)`** composite unique
  index (confirmed in
  `priv/repo/migrations/20260906000001_create_entity_definitions.exs:60-68`),
  plus a second, unrelated `unique_constraint(:status, name:
  :entity_definitions_tenant_name_active_idx)` for the partial
  at-most-one-active-per-name index (ISS-0519 fix). **The relevant
  constraint for a "name collision" is the first one, and it is keyed on
  `(tenant_id, name, logical_shape_version)`, not on `name` alone** — see
  §2 below for why this matters.
- `lib/letflow/definitions/graph.ex`'s `check_form_schema_expressions/1`
  (CHK-20, lines 852-870): confirmed it is filtered to `:HUMAN_TASK` nodes
  only, delegating to `Letflow.Definitions.FormSchemaExpressions.validate_node_form_schema/2`.
- `lib/letflow/definitions/form_schema_expressions.ex` in full: confirmed
  (moduledoc lines 32-41, `extract_form_schema/1` lines 82-93) that
  `form_schema` is read from `attributes["form_schema"]` on a `:HUMAN_TASK`
  node — i.e. it is a key inside that node's `attributes` map, which itself
  is a key inside a node inside `graph`. It is never a standalone document
  or a separate list anywhere in this module.
- `lib/letflow/routers/tasks.ex` lines 87-107 and 561-573: confirmed
  (moduledoc, lines 91-93) `form_schema` is "sourced directly from the
  task's own `form_schema` column, which `Letflow.Engine.TaskActivation`
  (REQ-273) populates once, at activation, from the node's `form_schema`
  attribute in the version-pinned graph the instance was created or last
  promoted against" — i.e. resolved from the process **definition's graph**
  at task-activation time, not from any separate pack artefact.
- `lib/letflow/api/context.ex`'s `scoped_repo_opts/1` (lines 217-230):
  confirmed it derives `prefix` solely from `conn.assigns[:auth_context].tenant_id`
  (`tenant_id_from_auth_context/1`, lines 232-237) via
  `TenantProvisioning.schema_name_for_tenant/1` — no caller-suppliable
  parameter anywhere in this function's signature (`conn` only).
- `lib/letflow/design/`: grepped for any pre-existing REQ-303-adjacent
  artefact (`req303`, `entity_pack`, `solution_pack.*entity`) — none found.
  This record and its companion design doc are new.

**Conclusion of re-verification: the requirement's own framing holds.**
There is no `entity_definitions` key today; `fetch_list/2`'s default-to-`[]`
behavior is real and pre-existing; `check_unsupported_sections/1`'s
reject-non-empty precedent is real and pre-existing; `create_definition/2`
always inserts `:inactive`; `activate_definition/4` is a distinct call
keyed by `name`; the unique constraint is on `(tenant_id, name,
logical_shape_version)`, not `name` alone; and `form_schema` is confirmed to
live inside a `:HUMAN_TASK` node's `attributes` map, not as a standalone
artefact — see §3 below for the consequence.

## Decision

### 1. Schema versioning

**(a) `bpm_export_schema_version` does NOT change. It stays `"bpm/definition/v1"`.**

The version string identifies the **envelope format** (the pack document's
top-level JSON shape and its parse contract), not the set of optional
content sections a given pack instance happens to populate — the same
stance `service_catalog_entries` already establishes: that section has
existed in the type and in `parse_document/1` since before it was
"supported," under the same version string, with export always emitting
`[]` and install rejecting non-empty content structurally, not via a
version check. Adding `entity_definitions` is the same shape of change:
a new **optional** key, added the same way `service_catalog_entries` and
`variable_schemas` were each added without their addition alone forcing a
version bump. `Letflow.Definitions.ExportImport`'s "one version constant,
not two" rationale is about **not introducing a second, competing version
constant module** — it says nothing about bumping the existing one for a
new envelope key, and this record does not introduce a second constant
either; it reuses `ExportImport.export_schema_version/0` unchanged.

**(b) An OLD pack (no `entity_definitions` key) against a NEW installer:
`fetch_list/2`'s existing default-missing-key-to-`[]` behavior is RATIFIED,
not overridden.** A NEW installer parses an old pack's absent
`entity_definitions` key as `[]`, exactly the way it already treats an old
pack's `service_catalog_entries`/`variable_schemas` keys if a future
document omitted those. This requires **zero code change** to
`fetch_list/2` itself — REQ-305 must call `fetch_list(document,
"entity_definitions")` the same way the three existing keys are fetched,
inheriting the default for free. An old pack installs with zero entity
definitions, which is correct: it never claimed to carry any.

**(c) A NEW pack (`entity_definitions` present and non-empty) against an OLD
installer (one that has never heard of the section): the SAME
reject-non-empty-unsupported-content stance as `service_catalog_entries`
applies — NOT a version-bump rejection.** An old installer's
`parse_document/1` has no `"entity_definitions"` key in its own fetch list,
so it silently never looks at the incoming document's `entity_definitions`
array at all — under Elixir's plain `Map.get/3`-based parsing here, an
unrecognized key is not an error, it is simply never read. This means the
`check_unsupported_sections/1`-style hard-reject (used for
`service_catalog_entries`, whose key the parser DOES read structurally) is
not literally reachable for a key an old installer's parser never
extracts — **so the correct mechanism, and the one this record specifies
as the safety net, is that the OLD installer's `parse_document/1` MUST
still validate the raw document's `"entity_definitions"` key, at the same
pure/pre-transaction step as `service_catalog_entries`, precisely so
`check_unsupported_sections/1` (extended, see Consequences) rejects a
non-empty value.** In other words: an old installer's `install/3` (the
version deployed before REQ-305 lands) does NOT yet parse
`entity_definitions` at all, so tenant-supplied entity definitions would
be silently ignored rather than rejected — this is the "in the interim"
question, and it is answered in full in §4 below, which requires
`check_unsupported_sections/1` to be the rejection point, never a version
bump. No caller must ever discover only after the fact that named entity
definitions were silently dropped.

### 2. Install semantics for entity definitions

**A packed entity definition installs `:inactive`-only. `install/3` does
NOT call `activate_definition/4`.** This mirrors `create_definition/2`'s
own default and matches how process definitions are installed today — no
other pack-installed artefact type is auto-activated by
`SolutionPack.install/3` (a `packed_definition` becomes a `ProcessDefinition`
row via `Definitions.create/2`, which has no activation step either; a
`packed_variable_schema` is written via `register_variable_schemas/3`, also
with no activation concept). Auto-activating entity definitions specifically
would make "pack installed" mean something structurally different for this
one artefact type than for every other artefact type this module installs,
with no requirement text asking for that stronger claim. A separate
activation call (by name, via the existing
`Letflow.Entities.Definitions.activate_definition/4`) remains a distinct,
later operation — outside `SolutionPack.install/3`'s scope, exactly as it is
today for a freshly-created entity definition via the ordinary (non-pack)
create path.

**Name collision: aborts the WHOLE install transaction, matching
`SolutionPack.install/3`'s documented all-or-nothing, no-upsert stance.**
Quoting the moduledoc directly: *"`installed_definition.status` is always
`"installed"`. `Letflow.Definitions.create/2` has no upsert, no skip and no
idempotent branch: it inserts, or it returns
`{:error, :duplicate_name_version}`... which the route maps to a 409 that
aborts the entire install."* `create_definition/2` is the entity-definition
analogue of `Definitions.create/2` in this respect: on a UNIQUE-constraint
hit on `entity_definitions_tenant_name_shape_idx`
`(tenant_id, name, logical_shape_version)`, it returns
`{:error, {:persistence, changeset}}` (confirmed in the re-verification
above), never an upsert/skip. **This record specifies that REQ-305's
install path treats that `{:error, {:persistence, changeset}}` (or any
other `create_definition/2` error) exactly like `create_packed_definitions/3`
already treats a `Definitions.create/2` error today: `{:halt, error}` inside
the transaction, which `run_install/5`'s `with`/`else` clause turns into
`Repo.rollback(reason)` — the whole install (including any already-created
process definitions and variable schemas from the SAME pack) rolls back.**
This is the only answer consistent with the existing all-or-nothing
precedent, and this record proposes no divergence from it.

**One collision subtlety worth stating explicitly, since the constraint key
is `(tenant_id, name, logical_shape_version)`, not `name` alone:** a packed
entity definition whose `name` matches an existing row but whose
`logical_shape_version` differs (a genuinely different shape under the same
name) does **not** collide on this constraint and installs as a **new**
row — this is existing, correct `create_definition/2` behavior (the same
row-versioning model REQ-225/226 already established for the ordinary,
non-pack create path) and this record does not change it. "Name collision"
in the install-semantics sense above means the SAME `(name,
logical_shape_version)` pair already exists in the tenant, which is the
case that actually raises the UNIQUE violation and aborts the transaction.

### 3. The form-schema question — the gap is already closed; NO new section is needed

**Finding: `form_schema` is NOT a standalone artefact anywhere in this
codebase.** It is an optional attribute,
`attributes["form_schema"]`, on a `:HUMAN_TASK` node's `attributes` map,
inside a process definition's `graph` — validated at definition time by
`Letflow.Definitions.Graph`'s CHK-20
(`lib/letflow/definitions/graph.ex:852-870`), which delegates to
`Letflow.Definitions.FormSchemaExpressions.validate_node_form_schema/2`
(`lib/letflow/definitions/form_schema_expressions.ex:62-80`, confirmed in
full — it reads `Map.get(attributes, "form_schema")`, nothing else), and
resolved at task-activation time by `Letflow.Engine.TaskActivation` "from
the node's `form_schema` attribute in the version-pinned [definition]"
(`lib/letflow/routers/tasks.ex:97`, moduledoc).

`SolutionPack.pack_definition/1` (`solution_pack.ex:377-385`) already embeds
`definition.graph` **verbatim** into the packed definition's `graph` field —
it does not walk the graph's node list or filter any node's `attributes`.
`parse_definition/1` (`solution_pack.ex:454-468`) round-trips an arbitrary
`graph` map on the install side the same way, via `fetch_object/2`, which
accepts and passes through any map value unchanged.

**Consequence, stated explicitly: a process definition's `HUMAN_TASK` nodes'
`form_schema` attributes already travel through the EXISTING `definitions`
pack section with ZERO code change**, because nothing in the export or
install pipeline extracts, filters, or re-derives the graph's node
attributes — the whole `graph` map, `form_schema` attributes included,
rides along as part of `packed_definition.graph`. **This record decides:
no separate `form_schema` pack section is needed, is proposed, or should be
built.** The stage file's gap-13 framing ("no form-schema section" as a
defect) does not survive contact with the code as stated — re-verification
confirms the requirement's own pre-dispatch finding was correct, not merely
plausible. The real, narrower gap this record addresses is `entity_definitions`
only.

### 4. The `service_catalog_entries` precedent — YES, same reject-until-supported pattern, for the entire interim between REQ-304 and REQ-305

**`entity_definitions` follows the exact same "reject a section the
installer doesn't yet support, never silently discard tenant-supplied
content" pattern `service_catalog_entries` already establishes via
`check_unsupported_sections/1`.** Concretely, for the specific two-turn
split this requirement's own follow-ups create:

- **After REQ-304 (export side) lands, before REQ-305 (install side) lands:**
  `export/3` can now emit a populated `entity_definitions` array, but
  `install/3`'s `parse_document/1` and `check_unsupported_sections/1` have
  not yet been extended. During this window, `parse_document/1` MUST be
  extended (as part of REQ-304, or, if 0026 defers it, no later than the
  start of REQ-305 — see the Consequences section for which requirement
  owns this specific line) to `fetch_list(document, "entity_definitions")`
  the raw content into `parsed.entity_definitions` **structurally**, even
  before any create-side logic exists, so `check_unsupported_sections/1`
  can be extended in the SAME step to a clause equivalent to
  `defp check_unsupported_sections(%{entity_definitions: []}), do: :ok` /
  `defp check_unsupported_sections(_), do: {:error, :unsupported_pack_section}` —
  mirroring `service_catalog_entries`'s existing two-clause shape exactly.
  This guarantees a non-empty `entity_definitions` array is **hard-rejected**
  before any transaction opens, during the entire interim, rather than
  silently ignored via `fetch_list/2`'s default (which would otherwise
  parse-succeed and drop the content with no signal to the caller — the
  one outcome this pattern exists to prevent).
- **This is why this record's Consequences section (below) assigns the
  `parse_document/1`/`check_unsupported_sections/1` extension to REQ-305,
  to be done FIRST, before REQ-305's create-path logic, and states as an
  explicit caution that if REQ-304 (export) merges before REQ-305
  (install), any tenant that exports and then re-installs its own pack
  in that window gets a clean, typed `{:error, :unsupported_pack_section}` —
  never a silent no-op.**

### 5. INV-1 tenant scoping

**This design introduces no new caller-supplied tenant identifier anywhere
in the `entity_definitions` install (or export) path.** Every read this
design specifies (`Letflow.Entities.Definitions.get_definition_by_name/2`
for export) and every write this design specifies
(`Letflow.Entities.Definitions.create_definition/2` for install) already
takes an explicit `prefix :: String.t()` argument and derives `tenant_id`
from it via `TenantProvisioning.tenant_id_for_schema_name/1` — the same
mechanism `SolutionPack.export/3`/`install/3` already use for every other
section, and the same mechanism `Letflow.Api.Context.scoped_repo_opts/1`
already derives solely from the authenticated token's `tenant_id`
(confirmed in re-verification above: `conn.assigns[:auth_context].tenant_id`,
no parameter path). Neither `export/3` nor `install/3` gains a new
parameter of any kind for the `entity_definitions` section beyond the
`opts[:prefix]` keyword list they already thread through every other
section's reads/writes — this design adds no `tenant_id`, `schema_name`, or
`slug` parameter to any function signature named below. See the dedicated
SECURITY-REVIEWER sign-off section below, which addresses this point by
name, not as part of a general pass.

## Reasoning

Each answer's justification is stated inline with the answer above, because
each is specific to that sub-question. The one cross-cutting principle:
every mechanism this record specifies is a REUSE of an existing, already-
reviewed convention (`fetch_list/2`'s default, `check_unsupported_sections/1`'s
reject clause, `create_definition/2`'s own `:inactive` default, `opts[:prefix]`
scoping) rather than a new mechanism invented for this one section — the
same "one place that is allowed to know X" discipline 0024's Reasoning
section names, applied here to pack-parsing/install conventions instead of
DDL identifier safety.

## Consequences

- **`pack_document` `@type` (solution_pack.ex:186-195) gains a new
  `entity_definitions: [packed_entity_definition()]` key**, with its own
  `@typedoc`, distinct from `packed_definition`/`packed_variable_schema` —
  built by REQ-304. See the companion design doc,
  `lib/letflow/design/req303-solution-pack-entity-definitions.md`, for the
  exact field list (`entity_definition_id`, `name`, `display_name`,
  `definition_json`, `logical_shape_version` — enough of
  `Letflow.Entities.EntityDefinition`'s persisted fields to round-trip
  through `create_definition/2` on install).
- **`export/3` gains a way to name entity definitions to include** (REQ-304's
  scope; the companion design doc specifies the exact parameter shape) and
  populates the new key by reading each named entity definition via
  `Letflow.Entities.Definitions.get_definition_by_name/2` under
  `opts[:prefix]`.
- **`bpm_export_schema_version` is UNCHANGED** — no new constant, no bumped
  suffix. `ExportImport.export_schema_version/0` remains the sole source.
- **`parse_document/1` and `check_unsupported_sections/1` (solution_pack.ex)
  are extended to fetch and structurally validate `entity_definitions`** —
  this extension is assigned to **REQ-305 (install side), done FIRST within
  that requirement, before any create-path logic**, per §4 above. Until
  REQ-305 lands, a pack carrying a non-empty `entity_definitions` array
  installed against the pre-REQ-305 installer is silently accepted and the
  content silently dropped — **this is the one gap this record could not
  close by itself**, because REQ-304 (export) and REQ-305 (install) are
  separate requirements and this record implements neither. REQ-305's own
  acceptance criteria must therefore require this parse/reject extension to
  land before or atomically with its create-path logic, not after.
- **`install/3`'s transactional body gains a `create_packed_entity_definitions/3`-shaped
  step** (companion design doc names the exact function), calling
  `Letflow.Entities.Definitions.create_definition/2` per packed entity
  definition, all-or-nothing, per §2 above. No call to
  `activate_definition/4` is added anywhere in `install/3`.
- **No new pack section for `form_schema`** — per §3, none is needed.
- **No change to `Letflow.Entities.EntityDefinition`'s changeset, unique
  constraints, or migration** — this record proposes none.

## What this record does not decide

- **The exact field list and parameter shapes for `export/3`'s new
  input/output and `install/3`'s new create step.** Deferred to the
  companion design doc (`lib/letflow/design/req303-solution-pack-entity-definitions.md`),
  which gives concrete function signatures for REQ-304/REQ-305 to build
  against.
- **Whether REQ-304 itself should also add the `parse_document/1`/
  `check_unsupported_sections/1` extension early** (as a defensive measure,
  even though its own scope fence is export-only) — REQ-304's own
  `docs/requirements.yaml` entry already states its scope is export-only
  and does not touch `install/3`; this record does not override that scope
  fence, it only requires that REQ-305 land the parse/reject extension
  before or atomically with its own create-path work, per §4's Consequences
  note. If ORCH judges the interim risk (a real tenant exporting a pack
  with populated `entity_definitions` and re-installing it before REQ-305
  merges) worth closing sooner, that is a scheduling decision, not something
  this record resolves.
- **Route-layer wiring** (`lib/letflow/routers/solution_packs.ex`) for a new
  export parameter — left to REQ-304 per its own scope fence, which this
  record does not narrow or widen.
- **The entity-STORAGE track** (0023/0024/0025) — see "Independence" above;
  this record takes no position on promoted columns, DDL execution, or
  `ON DELETE`/localized-text strategy, and is not blocked by any of them.
- **Implementation.** No `lib/letflow/definitions/solution_pack.ex`,
  `lib/letflow/entities/`, `priv/repo/migrations/`, or test file is touched
  by this record — REQ-304 and REQ-305 build against the companion design
  doc.

## SECURITY-REVIEWER sign-off

**Verdict: (unfilled — SECURITY-REVIEWER to complete).**

Invariant to assess: **INV-1 (tenant data isolation)**, specifically the
point named in this record's §5 by name: *does this design introduce any
new caller-supplied tenant identifier anywhere in the `entity_definitions`
export or install path?* This record's own claim is "no" — every read/write
this design specifies goes through `Letflow.Entities.Definitions`' existing
`prefix`-taking functions (`get_definition_by_name/2`, `create_definition/2`),
which derive `tenant_id` from `prefix` via
`TenantProvisioning.tenant_id_for_schema_name/1`, and `prefix` itself
continues to come solely from `Letflow.Api.Context.scoped_repo_opts/1`
(derived solely from the authenticated token's `tenant_id`, confirmed at
`lib/letflow/api/context.ex:217-237` in this record's own re-verification).
SECURITY-REVIEWER must independently re-derive this — re-read
`lib/letflow/api/context.ex`'s `scoped_repo_opts/1`, the companion design
doc's exact function signatures for the new `export/3`/`install/3` surface,
and confirm no new function signature accepts a `tenant_id`/`schema_name`/
`slug` parameter anywhere in the entity-definitions path, addressing this
INV-1 point **by name** as REQ-303's acceptance criteria require — not as
part of a general pass over the record.

## REVIEWER sign-off

**Verdict: (unfilled — REVIEWER to complete).**

Scope: idiom/decision-record consistency review — confirm this record's
format matches 0022's/0023's/0024's/0025's own Question/Decision/Reasoning/
Consequences/What this record does not decide/sign-off shape; confirm the
independence claim from 0023/REQ-295..302 is stated correctly and does not
manufacture an unwarranted consistency obligation against those records
(0023 never mentions `entity_definitions`); confirm the companion design
doc contains no implementation code, only signatures/types per
CODE-DESIGNER's own scope fence; confirm `git diff --name-only` shows only
this decision record and the companion design doc touched, per the
requirement's scope fence.
