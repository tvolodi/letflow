# Design: REQ-225 — Entity definition JSON shape and structural validation rules

**Requirement:** REQ-225 (`docs/requirements.yaml:13616-13701`, stage S6,
`depends_on: [REQ-202]`). Slice 1 of the ISS-0438 entity-subsystem port
(`lib/letflow/design/iss0438-entity-subsystem-scoping.md`).
**Owner (implementer):** ELIXIR-DEV.
**This document produces:** the `EntityDefinition`/`FieldDef`/`IndexDef`/`FKDef`/
`ConstraintDef` document-shape `@type`s, the 11 numbered structural-validation-rule
enumeration with exact trigger conditions and error shapes, the canonicalisation/hashing
call contract against the existing `Letflow.Repository.Canonicaliser` (REQ-202), the
concrete logical-shape-versioning rule, the entity-type ownership-model decision, and the
module/file placement. **No implementation code** — no `def ... do ... end` bodies, no
literal Ecto schema field lists, no working Elixir anywhere below; every fenced block is a
`@type`/`@spec` declaration or plain-English rule description. Persistence, CRUD, and the
`ArtifactKind` extension are REQ-226's job; record-payload validation is REQ-227's job;
event registration/commands are REQ-228's job. None of that is designed here.

---

## 0. Sources read for this design, and the R-Co access gap

- `docs/requirements.yaml`'s REQ-225 entry in full (description + all 7 acceptance
  criteria) and REQ-226's entry (read for boundary confirmation only — its
  `entity_definitions` schema sketch names `definition_json`, `content_hash`,
  `logical_shape_version`, `artifact_version_id` as REQ-226's own persisted columns,
  confirming this design's `EntityDefinition` document and the two derived values
  (content hash, logical shape version) are exactly what REQ-226 expects to receive
  from this module — nothing more, nothing less).
- `lib/letflow/design/iss0438-entity-subsystem-scoping.md` in full (519 lines) — the
  scoping artefact naming this slice's boundary, the ownership-model open question
  (§6 item 2), and the R-Co source citations (`definition.zig`, 370 lines;
  `validator.zig`'s definition-validation half, ~530 of 1005 lines) this slice ports.
- `lib/letflow/repository/canonicaliser.ex` in full (the entire module) — confirmed
  directly from source: `canonicalize_content/2` dispatches on an exact
  `"application/json"` content-type match, decodes with `Jason.decode/1`, sorts object
  keys, normalizes integer-valued floats to bare integers, leaves fractional floats and
  array order untouched, and re-encodes; `content_hash/1` is `:crypto.hash(:sha256, _)`
  on that canonical form, returning a raw 32-byte binary (not hex).
- `lib/letflow/repository/artifact_kind.ex` (28 lines, full) — confirmed the closed
  `@artifact_kinds` atom list does not yet include `:entity` (REQ-226's job, not this
  slice's).
- `lib/letflow/design/req202-artifact-repository.md` and `lib/letflow/design/
  req197-expr-arithmetic-and-errors.md` — skimmed for this codebase's design-doc
  conventions: numbered `##` sections, a `## 0. Sources read` opener, `@type`-only
  fenced blocks (never `def`), an explicit "open questions, not silently resolved"
  section, and a closing acceptance-criteria traceability table. This document follows
  that same shape.
- **THE GAP, stated honestly (same posture req197 §0 took):** R-Co's actual source tree
  (`definition.zig`, `validator.zig`) is **not reachable from this sandbox** — no R-Co
  checkout and no `*.zig` file exists anywhere on this host (confirmed by a filesystem
  search this session). Every field name, rule boundary, and cardinality limit below is
  therefore derived from REQ-225's own requirement text and the ISS-0438 scoping
  artefact's descriptions, not from re-reading the R-Co source directly. Every place
  this document had to pick a concrete detail the requirement text under-specifies
  (exact cardinality numbers, exact constraint-kind enum, exact field-type enum) is
  flagged as an **explicit open question in §9**, not silently invented as if it were a
  faithful port. A future agent with real R-Co access should reconcile §9 against the
  actual source before treating this design's numbers as ported rather than reasoned.

---

## 1. Entity-type ownership model — DECISION (resolves the named open question)

**Decision: tenant-scoped.** An `EntityDefinition` belongs to exactly one tenant; no
platform-scoped (cross-tenant, shared) entity type exists in this design.

**Reasoning:**

1. Every subsystem this slice's document sits directly on top of is already
   tenant-scoped by the same convention: `Letflow.Repository` (REQ-202,
   `repository_artifacts`/`artifact_versions` live in each tenant's own Postgres
   schema, per `docs/migration/decisions/0003-ecto-schema-strategy.md` Decision B) and
   `Letflow.EventStore.Registry` (`event_type_registry`, also per-tenant-schema). REQ-226
   will store `entity_definitions` the same way (its own requirement text already states
   "tenant-scoped, per-tenant Postgres schema ... the same placement REQ-202/REQ-203/
   REQ-211 use"). A platform-scoped entity type would be the first artifact-adjacent
   table in this whole dependency chain to break that pattern, with no stated need to.
2. R-Co's own design doc left this open ("Deferring to REQ-ANALYST") rather than
   choosing platform-scoped — it is not a case where this design contradicts a settled
   R-Co precedent by picking tenant-scoped.
3. A platform-scoped entity type would mean two tenants' business processes are forced
   to share one data-model shape (any tenant needing an extra field on a shared type
   would either be blocked or would need a bespoke per-tenant override mechanism this
   requirement does not specify) — a materially bigger, unscoped design question this
   slice's `depends_on: [REQ-202]` and 900-line-sized boundary give no room for. Nothing
   in REQ-225's acceptance criteria or ISS-0438's scoping artefact asks for cross-tenant
   sharing.
4. This decision is a document-shape/validation-rule consequence, not a persistence
   decision: it means `EntityDefinition.tenant_id` (or an equivalent tenant marker) is
   part of what REQ-226's persisted row carries, and it means name-uniqueness (Rule 1,
   §3) and self-referential-FK/FK-target resolution (Rule 11, §3) are evaluated
   *within* one tenant's set of definitions, never across tenants. This module itself
   takes no `tenant_id` parameter (it validates one document's internal structure only,
   per §7's function signatures) — tenant scoping is enforced by REQ-226's context
   module scoping its lookups by `tenant_id`, the same division of responsibility
   `Letflow.Repository.Canonicaliser` already has relative to `Letflow.Repository`
   (the canonicaliser knows nothing about tenants; the context module scopes queries).

This decision is stated here, prominently, per REQ-225 AC5 and the requirement's own
instruction not to let it be inferred only from code.

---

## 2. The EntityDefinition document shape

An `EntityDefinition` is a plain JSON-serialisable Elixir map (parsed from
`Jason.decode/1` output — atoms below name keys for readability; the actual document
uses string keys until validated, matching how `Letflow.Repository.Canonicaliser` and
every other artifact-content consumer in this codebase receives decoded JSON). This is a
**document shape**, not an `Ecto.Schema` — REQ-226 owns the persisted, denormalised
table; this module only describes and validates the shape of the JSON blob that becomes
`entity_definitions.definition_json` there.

```elixir
@typedoc "Top-level entity definition document. See §1 for the tenant-scoping decision."
@type entity_definition :: %{
        required(:name) => String.t(),
        required(:display_name) => String.t(),
        optional(:description) => String.t(),
        required(:fields) => [field_def()],
        optional(:indexes) => [index_def()],
        optional(:foreign_keys) => [fk_def()],
        optional(:constraints) => [constraint_def()]
      }
```

- `name`: the entity type's stable identifier. Format constrained by Rule 1 (§3).
  Immutable across logical-shape versions of the same entity type (REQ-226 keys
  `entity_definitions` on `(tenant_id, name, logical_shape_version)`).
- `display_name`: free-text, human-facing label. No format constraint beyond
  non-empty-string (checked as part of general type-checking, not one of the 11 numbered
  rules — see §3's preamble).
- `description`: optional free-text, no structural constraint.
- `fields`: the field list. Never absent (an entity with zero fields is meaningless);
  `required(:fields)` and Rule 8a's minimum-cardinality bound (§3) both enforce
  non-emptiness.
- `indexes`, `foreign_keys`, `constraints`: each optional; absence is equivalent to an
  empty list for every rule below.

```elixir
@typedoc "One field in an entity definition's `fields` list."
@type field_def :: %{
        required(:name) => String.t(),
        required(:type) => field_type(),
        optional(:required) => boolean(),
        optional(:queried) => boolean(),
        optional(:enum_values) => [String.t()],
        optional(:decimal_precision) => pos_integer(),
        optional(:decimal_scale) => non_neg_integer(),
        optional(:default) => term()
      }

@typedoc """
The closed set of field types this slice supports. `:json` is the one type that Rule 3
(§3) treats specially: a `:json` field may never also be `queried: true`.
"""
@type field_type :: :string | :integer | :decimal | :boolean | :date | :datetime | :enum | :json
```

- `name`: the field's identifier, unique within the definition (Rule 2, §3) and the
  target of index/FK/constraint field references (Rules 4/5, §3).
- `type`: one of the 8 `field_type()` atoms. Any other value fails general type-checking
  (§3 preamble), not one of the 11 numbered rules.
- `required`: defaults to `false` when absent. Whether a record must supply this field —
  consumed by REQ-227's record-payload validator, not checked further by this slice
  beyond being a plain boolean.
- `queried`: defaults to `false` when absent. Marks a field as promotable to a typed,
  indexable projection column (REQ-226/REQ-228's concern how that projection is built);
  this slice's only interest in `queried` is Rule 3's mutual-exclusion check against
  `type: :json` and Rule 4's index-coverage check (an index may only reference fields
  where `queried: true`; see Rule 4, §3).
- `enum_values`: required and non-empty when `type == :enum`; must be absent (or, if
  present, ignored — this design requires it **absent**, see Rule 6, §3) for every other
  type.
- `decimal_precision`/`decimal_scale`: required when `type == :decimal`; must be absent
  for every other type (Rule 7, §3).
- `default`: optional, untyped at this layer — REQ-227's record-payload validator is
  responsible for checking a supplied `default` value actually conforms to `type`
  (out of this slice's 11 structural rules; flagged as an open question in §9 rather
  than silently checked here, since REQ-225's scope is the definition document's own
  structure, not cross-referencing `default` against `type`).

```elixir
@typedoc "One entry in an entity definition's `indexes` list."
@type index_def :: %{
        required(:name) => String.t(),
        required(:fields) => [String.t(), ...],
        optional(:unique) => boolean()
      }
```

- `name`: the index's identifier, unique within the definition's `indexes` list (checked
  as part of Rule 2's field-uniqueness family — see §3 Rule 2's scope note).
- `fields`: a non-empty, ordered list of field names; every entry must name a field that
  exists in `fields` **and** has `queried: true` (Rule 4, §3).
- `unique`: defaults to `false`.

```elixir
@typedoc "One entry in an entity definition's `foreign_keys` list."
@type fk_def :: %{
        required(:name) => String.t(),
        required(:field) => String.t(),
        required(:references_entity) => String.t(),
        optional(:references_field) => String.t()
      }
```

- `name`: the FK constraint's identifier, unique within `foreign_keys`.
- `field`: must exist in this definition's `fields` (Rule 5, §3).
- `references_entity`: the target entity type's `name`. Must not equal this
  definition's own `name` (Rule 11, self-referential-FK rejection, §3) — see §9 for why
  this slice rejects self-reference outright rather than merely warning.
- `references_field`: defaults to `"id"` when absent (the implicit primary-key field
  every persisted entity record carries per REQ-226/REQ-228's projection design — this
  slice does not validate that the target entity/field actually exists, since that is a
  cross-definition, tenant-catalog lookup outside a single document's own structural
  validation; see §9).

```elixir
@typedoc "One entry in an entity definition's `constraints` list."
@type constraint_def :: %{
        required(:name) => String.t(),
        required(:type) => :unique,
        required(:fields) => [String.t(), ...]
      }
```

- `name`: the constraint's identifier, unique within `constraints`.
- `type`: this slice supports exactly one constraint kind, `:unique` (a uniqueness
  constraint across one or more fields' values, enforced by REQ-226/REQ-228's projection
  table). See §9 for why the constraint-kind enum is deliberately left this narrow
  rather than guessing at a wider R-Co set this sandbox cannot verify.
- `fields`: non-empty; every entry must exist in this definition's `fields` (checked by
  the same field-coverage family as Rule 5 — see §3 Rule 5's scope note).

---

## 3. The 11 structural validation rules

**Preamble — what is *not* one of the 11 numbered rules:** basic shape/type checking
(the document is a map with the required top-level keys; `fields` is a list of maps;
each field's `type` is one of the 8 known atoms; every string field is actually a
string) is a precondition every rule below assumes has already passed. A document that
fails basic shape checking is rejected with `{:error, [%Violation{rule: :malformed,
path: [...], message: "..."}]}` (see §7) — `:malformed` is not one of the 11 numbered
rules and is checked first, short-circuiting before any numbered rule runs, since a rule
like "field uniqueness" cannot be evaluated against a `fields` value that isn't even a
list.

**Resolving the 11-vs-9-named-categories mismatch, explicitly:** REQ-225's acceptance
criteria list AC2 names 9 categories ("name format, field uniqueness, queried+json
exclusion, index field coverage, FK field coverage, enum validity, decimal validation,
cardinality limits, self-referential-FK rejection") but the description says "11
numbered structural validation rules." This design resolves the gap by splitting
**cardinality limits** into its **4** separately-numbered, separately-fixture-testable
rules — one per collection (`fields`, `indexes`, `foreign_keys`, `constraints`) — since
each is a distinct maximum, checked independently, and AC2 itself requires "a fixture
that violates only that rule" for *each* of the 11 rules; a single combined "cardinality
limits" rule could not be violated by one fixture without ambiguity about which
collection tripped it. That yields 9 categories − 1 (cardinality, replaced) + 4
(cardinality's 4 sub-rules) = **12**, one more than 11, so this design additionally
folds **field uniqueness** and **index/constraint-name uniqueness** into **one** rule
(Rule 2) rather than two, since both are the identical "no two entries in a list share a
name" check applied to different lists, and REQ-225's own AC2 names only "field
uniqueness" (not a separate "index/constraint name uniqueness") as a category — treating
them as one rule with a `scope` field on the violation matches AC2's own singular
naming while still letting a fixture "violate only that rule." That yields the final
count of **11**:

| # | Rule | Category (per AC2) |
|---|---|---|
| 1 | Name format | name format |
| 2 | Name uniqueness (fields, and separately indexes/FKs/constraints) | field uniqueness |
| 3 | `queried` + `:json` mutual exclusion | queried+json exclusion |
| 4 | Index field coverage | index field coverage |
| 5 | FK field coverage | FK field coverage |
| 6 | Enum validity | enum validity |
| 7 | Decimal-field validation | decimal validation |
| 8a | Field-count cardinality limit | cardinality limits |
| 8b | Index-count cardinality limit | cardinality limits |
| 8c | FK-count cardinality limit | cardinality limits |
| 8d | Constraint-count cardinality limit | cardinality limits |
| 9 | Self-referential-FK rejection | self-referential-FK rejection |

(Rules are numbered 1–9 with 8 split into four lettered sub-rules — 11 independently
triggerable, independently fixturable checks total, matching AC2's "each of the 11 ...
is independently exercised by a fixture that violates only that rule.")

Every rule below produces `{:error, [violation()]}` (§7) with `rule` set to the atom in
the **Violation rule atom** column — this is what lets a caller "surface which rule
failed" per AC2, rather than a generic message.

### Rule 1 — Name format (`:name_format`)

Applies to `EntityDefinition.name` only (not `display_name`, which is free text).
**Trigger:** `name` does not match `^[a-z][a-z0-9_]{0,63}$` — i.e. not lowercase-start,
not restricted to `[a-z0-9_]`, or longer than 64 characters. **Violation:**
`%Violation{rule: :name_format, path: [:name], message: "must match ^[a-z][a-z0-9_]{0,63}$"}`.

### Rule 2 — Name uniqueness (`:duplicate_name`)

Applies independently to each of 3 scopes: (a) `fields` — no two `field_def()` entries
share a `name`; (b) `indexes` — no two `index_def()` entries share a `name`; (c)
`foreign_keys` ∪ `constraints` combined — no two entries across both lists share a
`name` (they occupy one DB-constraint-name namespace in REQ-226's projection). **Trigger:**
a duplicate `name` found within one of the 3 scopes above. **Violation:**
`%Violation{rule: :duplicate_name, path: [:fields, "<name>"], message: "duplicate name within scope :fields"}`
(`path`'s second element and the message's scope name vary per which of the 3 scopes
tripped).

### Rule 3 — `queried` + `:json` mutual exclusion (`:queried_json_conflict`)

**Trigger:** a `field_def()` has `type: :json` **and** `queried: true` simultaneously.
Reasoning: a `:json` field's value is an arbitrary nested document with no fixed scalar
shape, so it cannot be projected into a single typed, indexable column the way
`queried: true` requires. **Violation:** `%Violation{rule: :queried_json_conflict, path: [:fields, "<field name>"], message: "a :json field cannot be queried: true"}`.

### Rule 4 — Index field coverage (`:index_field_not_found` / `:index_field_not_queried`)

**Trigger (two sub-conditions, same rule number, distinguishable by the violation's
`message`):** (a) an `index_def().fields` entry names a field not present in `fields` at
all — `rule: :index_field_not_found`; (b) an `index_def().fields` entry names a field
that exists but has `queried` absent or `false` — `rule: :index_field_not_queried` (an
index can only be built over a field that is itself promoted to a queryable column).
**Violation:** `%Violation{rule: :index_field_not_found, path: [:indexes, "<index name>", :fields, "<field name>"], message: "..."}`
(or `:index_field_not_queried` with the analogous message).

### Rule 5 — FK field coverage (`:fk_field_not_found`)

**Trigger:** an `fk_def().field` names a field not present in this definition's `fields`,
**or** an entry in `constraints[].fields` names a field not present in `fields` (both
share this rule number and atom, since both are "a referenced field must exist in this
same definition" checks — distinguished by `path`'s prefix, `:foreign_keys` vs.
`:constraints`). **Violation:**
`%Violation{rule: :fk_field_not_found, path: [:foreign_keys, "<fk name>", :field], message: "field \"<field>\" not found in fields"}`.

### Rule 6 — Enum validity (`:invalid_enum`)

**Trigger (three sub-conditions, one rule number):** (a) `type: :enum` and
`enum_values` is absent, not a list, or an empty list; (b) `type: :enum` and
`enum_values` contains a duplicate value; (c) `type != :enum` and `enum_values` is
present at all (an `enum_values` key on a non-enum field is itself a structural error,
not silently ignored — per §2's field_def() note that `enum_values` "must be absent" for
non-enum types). **Violation:**
`%Violation{rule: :invalid_enum, path: [:fields, "<field name>", :enum_values], message: "..."}`.

### Rule 7 — Decimal-field validation (`:invalid_decimal`)

**Trigger (three sub-conditions, one rule number):** (a) `type: :decimal` and
`decimal_precision` or `decimal_scale` is absent; (b) `type: :decimal` and
`decimal_scale > decimal_precision` (a scale cannot exceed the total number of
significant digits); (c) `type != :decimal` and either `decimal_precision` or
`decimal_scale` is present. **Violation:**
`%Violation{rule: :invalid_decimal, path: [:fields, "<field name>"], message: "..."}`.

### Rule 8a — Field-count cardinality limit (`:too_many_fields`)

**Trigger:** `length(fields) > 200`. **Violation:**
`%Violation{rule: :too_many_fields, path: [:fields], message: "at most 200 fields allowed, got <n>"}`.
(See §9 for why 200 is this design's chosen concrete number, not a ported R-Co
constant.)

### Rule 8b — Index-count cardinality limit (`:too_many_indexes`)

**Trigger:** `length(indexes) > 32`. **Violation:**
`%Violation{rule: :too_many_indexes, path: [:indexes], message: "at most 32 indexes allowed, got <n>"}`.

### Rule 8c — FK-count cardinality limit (`:too_many_foreign_keys`)

**Trigger:** `length(foreign_keys) > 32`. **Violation:**
`%Violation{rule: :too_many_foreign_keys, path: [:foreign_keys], message: "at most 32 foreign keys allowed, got <n>"}`.

### Rule 8d — Constraint-count cardinality limit (`:too_many_constraints`)

**Trigger:** `length(constraints) > 32`. **Violation:**
`%Violation{rule: :too_many_constraints, path: [:constraints], message: "at most 32 constraints allowed, got <n>"}`.

### Rule 9 — Self-referential-FK rejection (`:self_referential_fk`)

**Trigger:** an `fk_def().references_entity` equals this definition's own `name`.
Rejected outright (not merely warned) — see §9 for the reasoning this design states
explicitly rather than silently choosing. **Violation:**
`%Violation{rule: :self_referential_fk, path: [:foreign_keys, "<fk name>", :references_entity], message: "an entity cannot declare a foreign key to itself"}`.

---

## 4. Canonicalisation and content hashing — reuses `Letflow.Repository.Canonicaliser`

This module performs **no canonicalisation or hashing of its own**. It delegates both
steps to the existing `Letflow.Repository.Canonicaliser` (REQ-202,
`lib/letflow/repository/canonicaliser.ex`), calling it exactly the way any other
JSON-content artifact producer in this codebase would:

1. Encode the (already-validated) `entity_definition()` document to JSON bytes via
   `Jason.encode!/1` — this module's own concern, since it is the one that holds the
   in-memory document.
2. Call `Letflow.Repository.Canonicaliser.canonicalize_content("application/json", json_bytes)`,
   yielding `{:ok, canonical_form}` (an already-validated document is always valid JSON,
   so `{:error, :invalid_json}` is not a reachable outcome from this call site — it is
   only reachable if `Jason.encode!/1` itself produced malformed bytes, which it cannot).
3. Call `Letflow.Repository.Canonicaliser.content_hash(canonical_form)`, yielding the raw
   32-byte SHA-256 binary REQ-226's `entity_definitions.content_hash` column stores
   directly.

**No second canonicalisation algorithm is designed here.** This module's own public
`canonicalize/1` and `content_hash/1` functions (§7) are thin wrappers with exactly the
two calls above — not a reimplementation of key-sorting, number-normalisation, or
SHA-256 hashing. This satisfies REQ-225 AC3's explicit requirement ("confirmed by `git
diff --stat` showing no new canonicaliser module added").

---

## 5. Logical-shape versioning

**Concrete rule:** two `entity_definition()` documents for the same `name` have the
**same** `logical_shape_version` if and only if they produce the **same canonical form**
(§4) after stripping the following **non-logical fields** first:

- `display_name` (display-only label).
- `description` (display-only, free text).
- The **order** of entries within `fields`, `indexes`, `foreign_keys`, and `constraints`
  (each list is treated as a **set**, keyed by each entry's `name`, for this comparison
  only — not for canonical-form hashing itself, which still hashes array order as
  significant per Canonicaliser rule 4; logical-shape comparison is a separate,
  higher-level comparison this module performs *before* delegating to the canonicaliser,
  by sorting each list by its entries' `name` field prior to encoding a
  "logical-shape probe" document).

Any other difference — adding, removing, or renaming a field/index/FK/constraint;
changing a field's `type`, `required`, `queried`, `enum_values`, `decimal_precision`,
`decimal_scale`; changing an index's `fields` or `unique`; changing an FK's `field`,
`references_entity`, or `references_field`; changing a constraint's `type` or `fields`
— **is** a logical change and requires REQ-226 to mint a new `logical_shape_version` for
that `name`.

**Non-bumping example 1 (field reordering):** `fields: [name_field, age_field]` vs.
`fields: [age_field, name_field]`, all other content identical — same logical shape,
because the field-list comparison is order-insensitive.

**Non-bumping example 2 (display-only change):** identical `fields`/`indexes`/
`foreign_keys`/`constraints`, differing only in `display_name: "Customer"` vs.
`display_name: "Customers"` — same logical shape, because `display_name` is stripped
before comparison.

**Bumping example 1 (field addition):** identical everything, except one document's
`fields` gains a new entry (e.g. a `required: true` `email` field the other lacks) —
different logical shape; the added field changes what a conforming record payload must
contain (REQ-227's concern), which is exactly the kind of change this rule is designed
to catch.

**Bumping example 2 (type change):** identical field lists except one field's `type`
changes from `:string` to `:integer` — different logical shape, since existing record
data and any index/FK built over that field would no longer be structurally consistent.

This module exposes `logical_shape_of/1` (§7) — a pure function from `entity_definition()`
to a `binary()` "logical shape digest," computed by canonicalising the order-normalised
probe document (per the rule above) through `Letflow.Repository.Canonicaliser` the same
way §4 does for the full document. REQ-226 is responsible for looking up whether that
digest has been seen before for a given `(tenant_id, name)` and, if not, incrementing
`logical_shape_version`; this module only computes the digest, it does not look anything
up or assign version numbers itself (no persistence in this slice).

---

## 6. Module and file placement

**New namespace: `lib/letflow/entities/`** — not `lib/letflow/repository/`, because this
module owns document-shape/validation-rule concerns specific to the entity subsystem,
not the generic, kind-agnostic content-addressed-storage concerns
`Letflow.Repository`/`Letflow.Repository.Canonicaliser` own. This mirrors
`Letflow.Definitions.PromotionDigest`'s own placement precedent (a
subsystem-specific document/digest module living under that subsystem's own namespace,
not under `Letflow.Repository`, even though it also produces a content digest).

| Module | File | Purpose |
|---|---|---|
| `Letflow.Entities.Definition` | `lib/letflow/entities/definition.ex` | The `entity_definition()`/`field_def()`/`index_def()`/`fk_def()`/`constraint_def()` `@type`s (§2) and the `t()` type alias for the top-level document. |
| `Letflow.Entities.Definition.Validator` | `lib/letflow/entities/definition/validator.ex` | The 11 structural validation rules (§3): `validate/1`, `Violation` struct. |
| `Letflow.Entities.Definition.Shape` | `lib/letflow/entities/definition/shape.ex` | Canonicalisation delegation (§4: `canonicalize/1`, `content_hash/1`) and logical-shape versioning (§5: `logical_shape_of/1`). |

Splitting the type module, the validator, and the shape/hashing module into 3 files
(rather than one ~400-line module) matches this codebase's existing convention of
separating a document's type/shape definition from its validation logic from its
content-addressing logic (e.g. `Letflow.Repository`/`Letflow.Repository.Canonicaliser`/
`Letflow.Repository.ArtifactKind` are three separate small modules under one namespace
for the same reason, per `artifact_kind.ex`'s own moduledoc on why it is a separate
module). REQ-226 adds a fourth module, `Letflow.Entities.Definition.Context` (or
similar; REQ-226's own design pass names it) under the same `lib/letflow/entities/`
namespace for persistence/CRUD — not created by this slice.

---

## 7. Public API — function signatures and the violation shape

```elixir
defmodule Letflow.Entities.Definition.Validator do
  @typedoc """
  One structural-validation failure. `rule` identifies exactly which of the 11 rules
  in §3 fired (its atom, from the "Violation rule atom" naming in each rule's
  subsection); `path` locates the offending element inside the definition document as
  a list of keys/indices-by-name (map keys as atoms, list-position lookups by the
  entry's own `name` string, matching this module's own `path` examples in §3);
  `message` is a human-readable detail string, never used by callers to distinguish
  which rule fired (that is `rule`'s job).
  """
  @type violation :: %__MODULE__.Violation{
          rule: atom(),
          path: [atom() | String.t()],
          message: String.t()
        }

  @doc """
  Runs the malformed-shape precondition check (§3 preamble) followed by all 11
  numbered rules (§3) against `definition`, collecting **every** violation found
  (not short-circuiting on the first) except that a `:malformed` failure
  short-circuits before any numbered rule runs, since the numbered rules assume a
  well-shaped document. Returns `:ok` only when zero violations are found.
  """
  @spec validate(definition :: Letflow.Entities.Definition.t()) ::
          :ok | {:error, [violation()]}
end
```

```elixir
defmodule Letflow.Entities.Definition.Shape do
  @typedoc "Raw 32-byte SHA-256 digest, matching `Letflow.Repository.Canonicaliser.content_hash/1`'s own return type."
  @type content_hash :: binary()

  @typedoc "Raw 32-byte SHA-256 digest of the order/display-stripped logical-shape probe document (§5)."
  @type logical_shape_digest :: binary()

  @doc """
  Encodes `definition` to JSON and delegates to
  `Letflow.Repository.Canonicaliser.canonicalize_content/2` +
  `Letflow.Repository.Canonicaliser.content_hash/1` (§4). Callers are expected to have
  already called `Validator.validate/1` and received `:ok` — this function does not
  itself validate.
  """
  @spec content_hash(definition :: Letflow.Entities.Definition.t()) :: content_hash()

  @doc """
  Computes the logical-shape digest per the rule in §5: strips `display_name`/
  `description`, sorts `fields`/`indexes`/`foreign_keys`/`constraints` by each entry's
  `name`, then canonicalises and hashes the resulting probe document via the same
  `Letflow.Repository.Canonicaliser` calls `content_hash/1` uses.
  """
  @spec logical_shape_of(definition :: Letflow.Entities.Definition.t()) :: logical_shape_digest()
end
```

A caller (REQ-226's context module) is expected to call `Validator.validate/1` first;
only on `:ok` does it call `Shape.content_hash/1` and `Shape.logical_shape_of/1` and
proceed to `Letflow.Repository.create/2`. This module never calls `Letflow.Repository`
itself — no persistence, per REQ-225's explicit scope boundary.

---

## 8. Functions deliberately NOT built (scope discipline)

- No `Ecto.Schema` for `EntityDefinition` (REQ-226's job — this is a document shape,
  not a persisted table row).
- No `create_definition/1`, `get_definition/1`, or any CRUD function (REQ-226).
- No record-payload validator (`validate_record/2` against a definition — REQ-227).
- No event registration or command functions (REQ-228).
- No cross-definition lookups (e.g. confirming an FK's `references_entity` actually
  exists as a real, previously-registered entity type in this tenant's catalog) — this
  slice validates one document's **internal** structural consistency only; REQ-226's
  context module is the natural place for a cross-definition existence check, since only
  it can query the persisted catalog (see §9, open question 3).
- No `:entity` addition to `Letflow.Repository.ArtifactKind`'s `@artifact_kinds` list
  (REQ-226's one-line addition, per that requirement's own scope text and the ISS-0438
  scoping artefact §4).

---

## 9. Open questions (stated explicitly, not silently resolved)

1. **Exact cardinality-limit numbers (Rules 8a-8d, §3) are this design's own concrete
   choice, not a ported R-Co constant.** R-Co's `validator.zig` source is unreachable
   from this sandbox (§0), so the 200/32/32/32 limits above cannot be verified against
   R-Co's actual constants. They are chosen to be generous enough not to block any
   realistic entity type while still being a real, enforceable, testable bound (AC2
   requires each rule to be independently fixture-triggerable, which requires *some*
   finite number). ELIXIR-DEV or a later auditor with real R-Co access should reconcile
   these against R-Co's actual `MAX_FIELDS`/`MAX_INDEXES`/`MAX_FOREIGN_KEYS`/
   `MAX_CONSTRAINTS`-equivalent constants (if they differ, that is a follow-up fix, not
   a blocker to this slice landing — REQ-225's AC2 only requires the rule exist and be
   independently testable, not that the specific number matches R-Co byte-for-byte).
2. **The `constraint_def().type` enum is deliberately narrowed to `:unique` only**,
   since this sandbox cannot verify what R-Co's actual constraint-kind set was (e.g.
   whether a `:check`-expression constraint kind existed). Expanding it later is a
   backward-compatible addition to `field_type()`'s sibling enum, not a breaking
   change to this design — flagged here rather than guessed at.
3. **Whether an FK's `references_entity` must resolve to a real, previously-registered
   entity type is explicitly deferred to REQ-226.** This slice checks only that the
   *local* `field` referenced by an FK exists in the same document (Rule 5) and that an
   FK does not target its own `name` (Rule 9) — both are checks a single document's own
   content can answer. Whether `references_entity` names a real entity type requires a
   tenant-catalog lookup this document-shape validator has no access to (it takes no
   `tenant_id` and performs no queries, per §1's design-boundary reasoning). REQ-226's
   own CODE-DESIGNER pass should state explicitly whether `createDefinition/2` checks
   this (and what happens on a dangling reference — reject, or allow forward
   declaration order-independence) rather than this slice guessing at REQ-226's own
   design.
4. **Self-referential-FK rejection (Rule 9) is an outright reject, not a warning**,
   because a genuinely self-referential entity relationship (e.g. an "employee reports
   to employee" hierarchy) is a real, legitimate BPM pattern this design cannot rule out
   a tenant needing — but REQ-225's own description explicitly names "self-referential-FK
   rejection" as one of the 11 rule categories (not "self-referential-FK warning"),
   so this design follows the requirement's own stated framing rather than silently
   loosening it to a softer allow-with-warning behavior. If a real tenant need for
   self-referential entity hierarchies surfaces later, that is a follow-up requirement
   revising this rule, not something this slice should quietly special-case now.
5. **Whether a `default` value's type-conformance to its field's `type` is checked here
   or deferred to REQ-227** (§2's `field_def().default` note) is resolved in this
   design as **deferred to REQ-227** — this slice's 11 rules are all named, closed-set
   structural checks per REQ-225's own description; a `default`-vs-`type` conformance
   check is not one of the 9 named categories, and REQ-227 already owns "does a value
   conform to this field's constraints" as its central concern. Flagged here so
   REQ-227's own design pass picks this up rather than it falling through both slices'
   scope silently.

---

## 10. Traceability — acceptance criteria to design elements

| AC | Criterion (paraphrased) | Design section |
|---|---|---|
| 1 | A conforming document passes structural validation with no errors | §2 (the shape every rule in §3 is checked against), §3 preamble (malformed-shape precondition), §7 (`validate/1` returns `:ok`) |
| 2 | Each of the 11 rules independently fixture-triggerable, with an identifiable (not generic) error | §3 (all 11 rules, each with an exact trigger condition and a distinct `rule` atom), §3's opening table resolving the 11-vs-9 count, §7 (`violation()` shape carries `rule`) |
| 3 | Canonicalising two structurally-equivalent documents (key order / whitespace) yields the same hash, via the existing `Letflow.Repository.Canonicaliser`, no second canonicaliser | §4 (delegation contract, both calls named explicitly), §7 (`Shape.content_hash/1`'s spec references the same two Canonicaliser calls, no independent logic) |
| 4 | Logical-shape-versioning rule stated concretely, with a non-bumping and a bumping example | §5 (concrete rule, 2 non-bumping + 2 bumping worked examples) |
| 5 | Entity-type ownership model (tenant-scoped vs. platform-scoped) stated explicitly with rationale | §1 (decision + 4-point reasoning, placed prominently as the design's own §1, not buried) |
| 6 | No `entity_definitions` migration, no persistence code, no route/controller added | §6 (module placement — 3 modules, none an `Ecto.Schema` or migration), §8 (explicit list of functions NOT built, including "no `Ecto.Schema`", "no CRUD", "no route") |
| 7 | `mix test` and `mix compile --warnings-as-errors` pass with real output quoted | Not a design-section concern — this is a build/test-execution AC for ELIXIR-DEV's implementation step, satisfied once code matching this design exists; the design itself introduces no dependency that would make either command fail (no new external deps, pure-Elixir modules calling only `Jason` and the existing `Letflow.Repository.Canonicaliser`, both already project dependencies) |
