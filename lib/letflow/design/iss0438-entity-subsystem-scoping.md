# ISS-0438 scoping decision — the dynamic entity/data-model subsystem

**Author:** CODE-DESIGNER, dispatched in a scoping-decision capacity per
`docs/agents/ORCHESTRATOR.md`'s MUST-NOT list (ORCH cannot make
module-boundary/implementation-scope decisions itself). This is a
port-vs-defer recommendation, not an implementation design — no
Elixir function bodies or literal Ecto schema field lists appear below,
per ISS-0438's own AC7 and this handoff's task.

**Sources actually read in full for this recommendation** (not
summarized from ISS-0438's own text): `C:\Users\tvolo\dev\ai-dala\R-Co\src\entities\mod.zig`
(127 lines), `definition.zig` (370 lines), `validator.zig` (1005 lines,
includes the ISS-0160/GH#481 record-payload validation half), `commands.zig`
(536 lines), `projector.zig` (213 lines), `events.zig` (106 lines) — **2,357
lines total**, plus `C:\Users\tvolo\dev\ai-dala\R-Co\src\entities\query\` (5
files: `types.zig`, `allowlist.zig`, `compiler.zig`, `cursor.zig`,
`field_grants.zig` — **1,064 lines**, the QRY-01..05 query DSL, which is
notably *not* mentioned anywhere in ISS-0438's own filed description —
see "A finding ISS-0438 itself missed" below) and the 737-line design
artefact `C:\Users\tvolo\dev\ai-dala\R-Co\src\design\entities.md`
(EXP-201/EXP-202). Total R-Co surface read: **4,158 lines**, not the
~3,400 ISS-0438 estimated (that estimate excluded `query/` entirely).

Also read in full: `lib/letflow/event_store/registry.ex` (307 lines),
`lib/letflow/repository.ex` (388 lines), `lib/letflow/repository/artifact_kind.ex`
(28 lines), `docs/migration/stage-5-scripting-plugins.md` (82 lines),
`docs/migration/stage-6-operational-cross-cutting.md` (413 lines),
`docs/migration/README.md`, `docs/issues/ISS-0438.yaml`,
`docs/issues/ISS-0439.yaml`, `docs/requirements.yaml`'s REQ-202/REQ-203
entries, and `lib/letflow/router.ex` lines 69-83 (the "Deferred routes"
table).

---

## 1. Recommendation: **IN SCOPE — port the generic (untyped) entity
subsystem as new S6 requirements, additive to S6's already-closed
batches**

This is a genuine "yes, build it" recommendation, not a default. The
reasoning:

1. **It is a real, working, already-battle-tested subsystem in R-Co**,
   not a stub. `validator.zig`'s record-payload validation half
   (ISS-0160/GH#481) exists specifically because an earlier version
   shipped with `createRecord`/`updateRecord` silently accepting any
   payload — a real defect, found and fixed upstream, whose fix is
   already sitting in the source Letflow would port. Porting now
   inherits that fix; porting later after independently discovering the
   same gap would not.
2. **Its two hard dependencies are not just "compatible in principle" —
   they are the *exact* two subsystems Letflow already ported and
   shipped as done**, REQ-202 (`Letflow.Repository`, artifact store) and
   REQ-024 (`Letflow.EventStore.Registry`, event type registry). See §3
   and §4 below for the concrete fit, not a hand-wave.
3. **It is not speculative product surface** — unlike ISS-0439 (the 1C
   typed-template question), which the user explicitly deferred for
   lack of a committed domain, the *generic* entity subsystem is
   general-BPM infrastructure (arbitrary structured business data
   backing a process), the same category as the artifact repository and
   the event store itself. ISS-0439's own recorded decision (quoted in
   full in §6) already names porting this generic substrate as the
   *prerequisite* step before any typed-template question can even be
   evaluated.
4. **The router table has carried two named-but-unbuilt rows since
   before S6 was even scoped**, and grepping both S5 and S6 stage docs
   confirms ISS-0438's central factual claim: neither file mentions
   "entities" or "entity_query" anywhere (re-verified directly, not
   trusted from the issue text — see the empty-result Grep runs this
   session performed against both files before drafting).

### Target stage: **S6 (Operational cross-cutting), as a new addendum
batch — not a reopening of "S6 is complete"**

`stage-6-operational-cross-cutting.md` currently reads "**S6 is now
complete**" (the scheduler/secrets/repository/audit/ordering batches),
followed by one already-precedented addendum note (2026-09-01, for
REQ-211/212, the instance-attachment subsystem) that explicitly does
**not** reopen or contradict that sentence — it documents a genuinely
new, later-discovered subsystem landing in the same stage. The entity
subsystem should land the same way: a second addendum paragraph
appended after the REQ-211/212 note, not an edit to the "S6 is
complete" line and not a new S6.5/S7-adjacent stage. Rationale for S6
specifically rather than S5 (the other half of the router table's own
"S5/S6" hedge):

- **The router table's own citation trail points at S6, not S5.**
  `src/design/entities.md`'s "Cross-module dependencies" table names
  `src/repository/*`, `src/event_store/*`, `src/api/pagination.zig`,
  `src/api/errors.zig` as depends-on — all S2/S6 subsystems. It names
  zero dependency on `src/lua/` or `src/wasm/` (S5's actual scope, per
  `stage-5-scripting-plugins.md`). The "S5/S6" hedge in the router table
  was written before either stage doc existed to check against; now
  that both do, the dependency graph resolves cleanly to S6 alone.
- **S6's two prerequisite subsystems are already done.** REQ-202
  (artifact store) and REQ-203 (per-tenant activation) — both `status:
  done` in `docs/requirements.yaml`, both closed 2026-08-30/31 — are
  exactly what §5 below shows entity definitions need. REQ-024 (event
  type registry, referenced by this handoff's own `artifacts_in`) is
  also done. There is no unresolved dependency blocking a start.
- S5 is scoped to Lua/WASM scripting hosts (`stage-5-scripting-plugins.md`
  §Scope: "Port `src/lua/`... and `src/wasm/`...") and has nothing to do
  with a data-model subsystem; the "S5/S6" hedge in the router table
  appears to be leftover uncertainty from before either stage was
  concretely scoped, not a real S5 dependency.

### Rough requirement-slice breakdown (actionable by REQ-ANALYST without
re-reading R-Co source)

Following the precedent this project's own S6 batches already set for
splitting a subsystem into core-then-route slices (REQ-176→178,
REQ-181→184, REQ-202→203, REQ-211→212), and R-Co's own module boundaries
(`definition.zig` / `validator.zig` / `commands.zig` / `projector.zig` /
`events.zig` / `query/`), a natural cut is **five to six
requirement-sized slices**:

1. **Entity definition schema + validator core** (`definition.zig` +
   `validator.zig`'s definition-validation half, ~370 + ~530 lines of the
   1005). Covers: the `EntityDefinition`/`FieldDef`/`IndexDef`/`FKDef`/
   `ConstraintDef` JSON shape (design doc §"Entity definition JSON
   schema"), the 11 numbered validation rules (name format, field
   uniqueness, queried+json exclusion, index/FK field coverage, enum/
   decimal validation, cardinality limits, self-referential-FK
   rejection), canonicalisation + hashing via the existing
   `Letflow.Repository.Canonicaliser`, and logical-shape versioning.
   Depends on: REQ-202 (`Letflow.Repository`), REQ-203 (activation).
   No DB writes of its own beyond what slice 2 adds — this slice could
   plausibly merge with slice 2 if REQ-ANALYST judges the combined size
   still fits one agent turn; sized separately here because
   `validator.zig` alone is 1005 lines in R-Co, larger than most
   single-slice precedents in this project's S6 batches.
2. **`entity_definitions` persistence + definition CRUD context module.**
   Covers: the `entity_definitions` table (design doc's migration
   section — id, tenant_id, name, display_name, definition_json,
   content_hash, logical_shape_version, artifact_version_id status,
   timestamps; unique `(tenant_id, name, logical_shape_version)`),
   `createDefinition`/`getDefinition`/`getDefinitionByName`/
   `listDefinitions`/`activateDefinition`-equivalent context functions,
   and the "register as `Letflow.Repository` artifact, kind = entity"
   integration point (§5 below states this needs an `ArtifactKind`
   extension — that extension belongs in this slice, since it is a
   one-line addition this slice's own work depends on). Depends on:
   slice 1.
3. **Entity RECORD payload validation** (`validator.zig`'s
   `validateRecordPayload`/`buildRecordSchema` half, ISS-0160/GH#481,
   ~475 of the 1005 lines). Covers: translating a definition's `fields`
   array into a JSON-Schema-shaped constraint set and validating a
   record payload against it, returning every violation (not just the
   first) as `(field_path, constraint, actual)` triples — the same
   shape `Letflow.EventStore.Registry.JsonSchema` already returns (see
   §4). This is the gap R-Co itself once shipped without (a real
   TODO left unimplemented, later closed) — a Letflow port should not
   reintroduce that same gap by treating this as optional/deferred.
   Depends on: slice 1 (needs the definition shape) and, if REQ-ANALYST
   judges Letflow's own `JsonSchema` module reusable rather than a
   second hand-rolled validator, REQ-024's existing
   `Letflow.EventStore.Registry.JsonSchema` (see §4's "reuse, don't
   duplicate" note).
4. **Entity event registration + record commands** (`events.zig` +
   `commands.zig`, ~640 lines). Covers: registering
   `ENTITY_RECORD_CREATED`/`ENTITY_RECORD_UPDATED`/`ENTITY_RECORD_DELETED`
   through `Letflow.EventStore.Registry.register_type/2` (see §4 for why
   this is the existing Registry, not a new mechanism), the
   create/update/delete command functions (validate → append exactly
   one event → update the `entity_record_latest` projection, in one
   transaction), idempotency-key handling matching R-Co's own
   already-fixed ISS-0159/GH#480 idempotent-replay behavior (look up the
   *original* record on a duplicate submit, not a freshly-minted one —
   an easy defect to reintroduce if the port works from the design doc
   alone rather than the actual `commands.zig` source), and the
   synthetic-instance-per-entity-type mapping (`entity_type_instances`).
   Depends on: slices 1-3.
5. **Projection + replay** (`projector.zig`, 213 lines). Covers:
   `entity_record_latest` (the JSONB-`current_state` projection table),
   `replayStream`-equivalent event-replay-to-snapshot logic, and
   `rebuildProjection`-equivalent full re-projection from the event log.
   Depends on: slice 4.
6. **(Optional, separable)** Entity query DSL (`query/` subdirectory,
   1,064 lines — QRY-01..05: closed-enum filter/sort operators, a
   per-tenant field allowlist loader with typed-column/JSONB-key
   shadowing, a parameterised SQL compiler with three explicit
   SQL-injection defence layers, a keyset-pagination cursor codec, and a
   field-grant loader for row-level field redaction). **This is a
   materially sized sixth subsystem ISS-0438's own filed description did
   not mention or size at all** — see the finding below. REQ-ANALYST
   should treat it as its own slice (or two: allowlist+compiler as one,
   cursor+field_grants as another) rather than folding it into slice 5,
   both because of its size and because it is the part of
   `Letflow.Routers.EntityQuery` (the second deferred router row) that
   actually needs a query compiler, as that row's own R-Co-source
   annotation says.

No route/controller layer is included in this breakdown — matching
REQ-202's own precedent (`Letflow.Repository`'s HTTP surface is
explicitly out of scope, "no consumer contract exists yet"), the same
reasoning applies here even more directly: **Letflow has no route
consuming entity data today**, and `router.ex`'s own two deferred rows
are placeholders, not commitments. REQ-ANALYST should size the HTTP
route layer (mirroring `entities.zig`'s handler list in the design doc's
"REST API routes" section) as a later, separate slice only once a real
consumer exists — the same "no consumer contract, don't build the
surface" discipline REQ-202 and stage-6's item 5 deferral already
apply.

### A finding ISS-0438 itself missed, worth flagging explicitly (AC2
actionability)

ISS-0438's own filed description sizes the subsystem at "~3400 lines"
covering only `definition.zig`/`validator.zig`/`commands.zig`/
`projector.zig`/`events.zig`/`mod.zig` — it never mentions `query/` even
though `query/` is separately listed in this handoff's own
`context.artifacts_in` and in the router table's second deferred row
(`Letflow.Routers.EntityQuery`, "same, plus query compiler"). Measured
directly this session: `query/` is **1,064 lines**, roughly a third of
the subsystem's total size, and is a real security-relevant
subsystem in its own right (a three-layer SQL-injection defence: closed
operator enum → allowlist-only column resolution → positional-parameter
binding, plus per-user field-level access control). REQ-ANALYST should
treat `query/` as its own explicitly-sized slice(s) (item 6 above), not
assume it is folded into "entities" incidentally. Flagging this
discrepancy per `core-directives.md`'s "Inheriting a claim from a record
instead of re-deriving it from the source" — ISS-0438's own summary is a
record, and this session re-derived the real size from the actual
`query/` files rather than trusting the "~3400 lines" figure.

---

## 2. Recommendation is genuinely "in scope" — the out-of-scope path
(AC3) is stated for completeness only

Per AC3's instruction, if this recommendation had gone the other way:
the two deferred router rows (`Letflow.Routers.Entities`,
`Letflow.Routers.EntityQuery`, `lib/letflow/router.ex` lines 79-80)
would need removal from the "Deferred routes" table, and a decision
record would be written to `docs/migration/decisions/0018-<slug>.md`
(confirmed: `0018` is the next free number — `docs/migration/decisions/`
currently holds `0001` through `0017` with no gaps, re-verified via
directory listing this session, not assumed from the handoff's own
claim). **That path is not being taken.** The recommendation is
port-now (§1), so no router-table edit and no decision record are
produced by this step — per the handoff's own instruction, a decision
record is written in a later step of this run, once this recommendation
clears CODE-DESIGN-VALIDATOR, not by CODE-DESIGNER here.

---

## 3. AC4 — how a port would register entity events through the
EXISTING `Letflow.EventStore.Registry`, concretely

**Yes — through the existing Registry, no parallel mechanism needed.**
Concretely, against the real module (`lib/letflow/event_store/registry.ex`,
307 lines, read in full):

- `Registry.register_type/2` takes `attrs` (a map bundling
  `name`/`schema_version`/`json_schema`/`description`) and `tenant_id`,
  and inserts a row into the tenant-scoped `event_type_registry` table.
  R-Co's own design doc states the three entity event types
  (`ENTITY_RECORD_CREATED`/`_UPDATED`/`_DELETED`) are "seeded in the
  migration... into `event_type_registry`... follow[ing] the same
  pattern as `INSTANCE_STARTED`, `TASK_COMPLETED`" — i.e. R-Co's own
  design already treats entity events as ordinary rows in the *same*
  registry table other platform events use, not a separate table or
  mechanism. Letflow's `Registry` module is the direct port of that
  same table (`lib/letflow/design/req024-event-type-registry.md`,
  named in this handoff's `context.artifacts_in`). A port should call
  `register_type/2` three times (once per entity event type) — most
  naturally from slice 4's own module (or a one-time seed step it
  triggers), the same shape any other platform event type registration
  takes, not a bespoke "entity event" registration path.
- `Registry.validate_payload/3` — R-Co's own `commands.zig` deliberately
  does **not** call R-Co's `registry.zig::validatePayloadAgainstSchema`
  from `createRecord`/`updateRecord`/`deleteRecord` for the
  *record*-level payload (`field_values`); it calls its own
  `validator_mod.validateRecordPayload` instead (see §"Record payload
  validation" in `validator.zig`, ISS-0160/GH#481's own module
  comment: "this deliberately does NOT hand-roll a second constraint
  engine... `json_schema.validateCollect`... does the actual
  checking"). That is a validation of the **record's field_values**
  against the **entity definition's derived schema** — a per-entity-type,
  dynamically-generated schema — which is a different concern from
  validating an **event's payload envelope** against its **registered
  event-type schema**. Both validations are real and both are needed:
  `Registry.validate_payload/3` would validate that an
  `ENTITY_RECORD_CREATED` event's payload has the right envelope shape
  (`entity_type`/`entity_def_version`/`record_id`/`field_values` as R-Co's
  design doc's "Payload structure" sections specify — all four keys
  present, correctly typed), while a Letflow equivalent of
  `validateRecordPayload` (slice 3) validates the `field_values`
  sub-document's own per-field constraints against the entity
  definition. **These are not competing mechanisms — the record
  validator's output (a conforming `field_values` JSON blob) becomes an
  input the event validator's envelope schema then wraps.** A port
  should therefore use `Registry.validate_payload/3` for the outer
  event envelope (register that envelope shape as each event type's
  `json_schema` at registration time) and a dedicated, ported
  `validateRecordPayload`-equivalent (slice 3) for the inner
  `field_values` constraints — reusing the *engine* both already share:
  **`Letflow.EventStore.Registry.JsonSchema`** is the natural target
  for slice 3 to call, exactly matching R-Co's own "reuse the shared
  JSON Schema validator rather than growing a second one" comment in
  `validator.zig` — Letflow already made the equivalent choice at
  REQ-024 design time (`Letflow.EventStore.Registry.JsonSchema`,
  described in that module's own moduledoc, §"JSON Schema validation
  library choice"). **One caveat, concrete, not hand-waved (per this
  AC's own instruction to name any real mismatch):**
  `Letflow.EventStore.Registry.JsonSchema`'s supported keyword table
  (`type`, `minimum`/`maximum`, `minLength`/`maxLength`, `enum`,
  `required`, `properties`, `items`, `additionalProperties`) does not
  list `maxLength` as absent — it is supported — so R-Co's record-schema
  keyword usage (`type`, `properties`, `required`,
  `additionalProperties: false`, `enum`, `maxLength`, `minimum`,
  `maximum` — read directly from `buildFieldSchema`/`buildRecordSchema`
  in `validator.zig`) is a **strict subset** of what
  `Letflow.EventStore.Registry.JsonSchema` already supports. No keyword
  gap exists. The one open question (not silently resolved — see §7) is
  whether reusing `JsonSchema` directly from slice 3's context module is
  architecturally acceptable given `JsonSchema` currently lives under
  the `Letflow.EventStore.Registry` namespace rather than a
  shared/top-level one.
- `Registry.get_type/2` — a port's read paths (fetching the currently
  registered schema version for an entity event type) map directly onto
  this existing function; no new fetch mechanism is needed.

**No schema/versioning mismatch was found that would block reuse.**
Registry's `schema_version` monotonicity invariant
(`schema_version_not_monotonic`/`duplicate_event_type_version`, a
Letflow-specific tightening beyond R-Co per the Registry moduledoc) is
compatible with entity events being registered once at
migration/seed-time with `schema_version: 1` and only incremented if
Letflow's own team later needs a v2 shape — the same lifecycle any other
platform event type already follows under this Registry.

---

## 4. AC5 — how R-Co's "entity definitions as Repository artifacts,
kind = entity" maps onto the real `Letflow.Repository`/`ArtifactKind`

**Concretely: `kind = "entity"` does NOT fit into `ArtifactKind`'s
current value list as-is — it needs a one-line extension, not a
structural change.**

Read directly from `lib/letflow/repository/artifact_kind.ex` (28
lines, the entire module): the value list is a hardcoded, closed atom
list —

```
@artifact_kinds [:definition, :form, :schema, :service_catalog, :script, :module, :scenario]
```

— seven atoms, none named `:entity`. This module's own moduledoc states
*why* it is a deliberately separate module (breaking a compile-time
dependency cycle between `Letflow.Repository` and
`Letflow.Repository.ArtifactVersion`) but says nothing suggesting the
list is meant to be closed forever — it exists precisely so the
"seven-atom value set can never drift" *between the schemas that
reference it*, not so the set itself can never grow. Adding `:entity`
as an eighth atom to `@artifact_kinds` is the same shape of change R-Co
itself made for this exact feature: the design doc states plainly,
"The existing `ALLOWED_KINDS` array in `src/repository/artifacts.zig`
gains `"entity"`" — R-Co's own `ArtifactKind`-equivalent went through
an identical one-line addition for the identical reason. This is
slice 2's job (§1), not a structural redesign of `Letflow.Repository`
or `ArtifactKind` itself.

Concretely, what a Letflow port gets for free from the *existing*,
already-shipped `Letflow.Repository` (388 lines, read in full) once
`:entity` is added to the value list:

- **`Letflow.Repository.create/2`** already implements exactly the
  "canonicalise → hash (SHA-256) → dedup-on-`content_hash` → version-sequence"
  pipeline R-Co's design doc describes for entity definitions
  ("Deterministic canonicalisation," "Logical shape versioning" —
  design doc §"Deterministic canonicalisation (EXP-201 acceptance)":
  "Entity definition JSON is canonicalised using the existing
  `src/repository/canonicaliser.zig`... Two definitions with identical
  logical content produce identical hashes"). A port's `createDefinition`
  (slice 2) should call `Letflow.Repository.create/2` with
  `artifact_kind: :entity`, `content_type: "application/json"`, and the
  definition JSON as `content` — not reimplement canonicalisation or
  hashing, both of which R-Co's own design doc explicitly says to reuse
  from the shared repository module, and which Letflow's port already
  has as `Letflow.Repository.Canonicaliser`.
- **Activation** (R-Co's "Only ACTIVE entity definitions can receive
  entity command events") maps onto REQ-203's already-shipped
  `artifact_activations`/`artifact_activation_history` machinery — the
  "current pointer" + append-only history + atomic multi-artifact
  activation Letflow already has, with `kind = :entity` simply becoming
  a new value flowing through activation the same way `:definition` or
  `:form` already do. No new activation mechanism is needed.
- **What is genuinely new, not covered by `Letflow.Repository` alone:**
  the `entity_definitions` table itself (R-Co's own design explicitly
  keeps a **denormalised, fast-lookup** row per definition version,
  separate from `artifact_versions` — "Entity definitions also get a
  dedicated row in `entity_definitions` for fast lookup (denormalised,
  rebuildable from repository artifacts)"). This is slice 2's own new
  migration, referencing `artifact_versions` the same way R-Co's schema
  does (`artifact_version_id` FK). This is the same "one subsystem's
  table denormalised for lookup speed, backed by the shared content
  store underneath" pattern REQ-202/REQ-203 already established for
  every other artifact kind — nothing new architecturally, just a new
  table.

No structural conflict was found between R-Co's design and Letflow's
actual `Letflow.Repository`/`ArtifactKind` shipped shape. The fit is
clean, modulo the one-line `ArtifactKind.values()` extension named
above.

---

## 5. AC6 — sequencing against ISS-0439

**This recommendation is exactly the trigger ISS-0439's own recorded
decision named as its prerequisite — restating that relationship, not
re-litigating it.**

ISS-0439 (read in full, 91 lines) is a deliberately-deferred
design-exploration issue about whether Letflow should add 1C-style
*typed* business-object templates (Directory/Document/Register/Report)
**over** the generic entity subsystem this issue (ISS-0438) covers.
Its own recorded decision text states, verbatim: *"Settle/port the
GENERIC entity subsystem first (ISS-0438), let real workflows use it
untyped, and WATCH WHAT TENANTS ACTUALLY BUILD. If Directory/Document/
Register patterns emerge from real usage, formalise them then."*
ISS-0439's YAML also carries a structural dependency field,
`depends_on_queue_tasks: [438]`, confirming this is not merely narrative
— the issue record itself is already wired to block on ISS-0438's
resolution.

This recommendation (§1, port now) is that trigger firing in the
"proceed" direction: **ISS-0438 resolving "in scope, port the generic
subsystem" is what ISS-0439 was waiting on to become concretely
assessable** — not resolved, not superseded, not reopened. ISS-0439
itself must stay exactly as filed (`status: open`, deliberately
deferred, no committed domain) until real tenant usage of the *now-porting*
generic subsystem produces the evidence ISS-0439's own "WHAT WOULD
CHANGE THIS" section names (a concrete tenant/domain needing typed
templates, or observed duplication of Directory/Register-shaped
patterns across tenants, or a deliberate ERP-market decision). Nothing
in this recommendation constitutes that evidence — porting the
substrate is a necessary precondition for ISS-0439 ever becoming
assessable, not itself sufficient grounds to revisit it. REQ-ANALYST
and any future agent picking up ISS-0439 should treat this artefact as
confirming ISS-0439's own reasoning stands unchanged, not as new input
to it.

---

## 6. Open questions (not silently resolved)

1. **Where should the ported `validateRecordPayload`-equivalent (slice
   3) call `Letflow.EventStore.Registry.JsonSchema` from, given that
   module currently lives under the `EventStore.Registry` namespace?**
   §4 shows the keyword-support fit is clean (a strict superset), but
   reaching into a sibling subsystem's nested module from a new
   `Letflow.Entities`-namespaced context module is a real cross-module
   coupling choice REVIEWER should weigh at slice-3 design time — either
   call it as-is (accepting the namespace mismatch, the same kind of
   cross-reach `Letflow.Repository.Attachments` already makes into
   `Letflow.Repository.upsert_content/6` per that module's own
   moduledoc precedent) or extract a shared top-level
   `Letflow.JsonSchema` module first. Both are legitimate; REQ-ANALYST
   should not silently pick one when drafting slice 3's requirement
   text — name it as an explicit design question for that slice's own
   CODE-DESIGNER pass.
2. **Entity type ownership model (tenant-scoped vs. platform-scoped
   definitions)** — R-Co's own design doc leaves this open ("Deferring
   to REQ-ANALYST") and this recommendation does not resolve it either.
   Given Letflow's existing schema-per-tenant convention (every other
   subsystem this session read — `Registry`, `Repository` — is
   tenant-scoped via `prefix`/`tenant_id`), tenant-scoped is the
   natural default, but REQ-ANALYST should state this explicitly in
   slice 1/2's requirement text rather than let it default silently.
3. **Synthetic-instance-per-entity-type vs. per-record** — R-Co's design
   doc explicitly defers this too ("Deferring this decision is safe —
   the table structure supports either model"), and this recommendation
   does not resolve it. R-Co's *actual shipped* `commands.zig` uses
   per-entity-type (`entity_type_instances`, one synthetic
   `instance_projections` row per type, per the
   `getOrCreateEntityTypeInstance`/`ensureEntityInstanceProjection`
   functions this session read in full) — a port should default to
   matching that actual implementation rather than R-Co's more abstract
   design-doc hedge, but REQ-ANALYST should state this choice
   explicitly in slice 4's requirement text.
4. **Whether `query/`'s field-grant mechanism (QRY-05,
   `entity_field_restrictions`/`user_entity_grants`) maps onto an
   existing Letflow authorization primitive** — this session did not
   read Letflow's authorization/RBAC modules in full (out of this
   handoff's `artifacts_in` scope) and cannot state concretely whether
   R-Co's bespoke per-field grant tables should be ported as new tables
   or mapped onto an existing Letflow permission mechanism. Flagged for
   slice 6's own design pass rather than guessed here.
5. **Bulk operations** — R-Co's design doc defers this to "a future
   enhancement (EXP-205 era)" and this recommendation does not disturb
   that deferral; not included in any slice above.

---

## 7. Acceptance-criteria mapping (ISS-0438, verbatim from this
handoff's `task.acceptance_criteria`)

| # | Criterion | Where addressed |
|---|---|---|
| 1 | Decision on scope (in/out + stage/slices, or a defer/reject decision-record path) | §1 (in scope, S6 addendum, 5-6 slices) |
| 2 | If in-scope: actionable enough for REQ-ANALYST without re-deriving R-Co source | §1's per-slice breakdown, each citing concrete file/line/function names |
| 3 | If out-of-scope: router.ex edit + decision-record path/number | §2 (stated for completeness; not the path taken) |
| 4 | EventStore.Registry relationship, concrete | §3 |
| 5 | Repository/ArtifactKind relationship, concrete | §4 |
| 6 | ISS-0439 sequencing | §5 |
| 7 | No implementation code in this artefact | This document contains no `.ex`/`.exs` code blocks and no literal Ecto field-list schemas — only prose descriptions of table/module shape, matching this handoff's own instruction |
