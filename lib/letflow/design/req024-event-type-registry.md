PROVENANCE (historical, not current decision authority):
# Design: REQ-024 — Event type registry (registry.zig / ES-05)

**Requirement:** REQ-024 (`docs/requirements.yaml`, stage S2)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** the JSON Schema validation library decision + migration
shape + module/function signatures + Ecto.Schema shape only. No implementation code, no
function bodies, no changeset bodies. ELIXIR-DEV writes the actual `.exs`/`.ex` files
from this.

**Revision note (rework iteration 1):** CODE-DESIGN-VALIDATOR FAILed the prior draft
(commit `0b3057f`) on one BLOCKER — §4's interface note asserted `register_type/2`,
`validate_payload/3`, `get_type/2` should each take `prefix :: String.t()` directly from
the caller, citing `Letflow.TenantProvisioning.replay_migrations/2` as precedent. That
citation was wrong: `replay_migrations/2` actually takes `tenant_id`, not `prefix`, and
resolves `schema_name` internally, returning `{:error, :tenant_not_provisioned}` when
unprovisioned. This revision applies fix option (a): all three functions now take
`tenant_id :: Ecto.UUID.t()` and resolve the physical schema internally via
`Letflow.TenantProvisioning.Registration`, matching `replay_migrations/2`'s actual
convention, with `{:error, :tenant_not_provisioned}` added to each function's error
union. Changed sections: §4 (opening interface note, rewritten), §4.1, §4.2, §4.3
(specs + behavior steps), §6 (cross-module dependencies), §7.2 (index entry) and new
§7.3, §8 (traceability table rows 2–4). Unchanged: §1 (JSON Schema library decision),
§2, §3 (migration shape), §4.4/§4.5 (validator algorithm/struct), §5 (Ecto schema) —
none of these referenced the wrong convention or need to change to fix the BLOCKER.

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-024 (full entry, including both OPEN QUESTIONs) and
  REQ-025 (full entry, to confirm exactly how the first downstream consumer —
  `Store.append/1`(or `/2`) — expects to call `validate_payload/2`-equivalent).
- `docs/guides/backend_developer_guide.md` — §2 (project structure), §3 (naming/coding
  conventions, esp. §3.5 error shapes, §3.6 SQL parameterization, §3.7 migrations), §5
  (multi-tenancy, points at 0003).
- `docs/migration/decisions/` (listed directly: `0001-web-framework.md`,
  `0002-oidc-integration.md`, `0003-ecto-schema-strategy.md`,
  `0004-humanless-pipeline.md` — **0004 is already taken by the humanless-pipeline
  decision**, per `CLAUDE.md`'s own citation, so a new record from this design, if one
  were needed, would be `0005-*.md`, not `0004-*.md` as REQ-024's own description text
  loosely implied by citing "0002/0003's own precedent" without naming a number).
- `docs/migration/decisions/0003-ecto-schema-strategy.md` (full) — Decision A
  (Ecto-idiomatic redesign), Decision B (schema-per-tenant, `tenant_id` retained
  intra-schema, general rule for all business tables absent a stated exception),
  Decision C (event-store tables' own migration strategy). **Dimension A's own text
  explicitly classifies `event_type_registry` as a "regular CRUD table"**, in the same
  bucket as `process_definitions` — corroborating (not settling — see §7) this design's
  per-tenant default for the table.
- `lib/letflow/tenant_provisioning.ex` and
  `lib/letflow/design/req022-tenant-schema-provisioning.md` (full) — the schema-per-tenant
  `:prefix` mechanism this table must use, the required tenant-scoped-migration guard
  pattern (§4 of that doc), and `tenant_scoped_migrations/0` (§3.4), which this
  requirement's migration is the **first real contributor to** (REQ-023 — the next
  candidate — has not merged as of this design; confirmed via `git log main` and
  `handoffs/registry.json`'s REQ-023 entry, still `status: pending`/reserved by a
  parallel process).
- Existing `lib/letflow/` conventions read directly: `lib/letflow/identity.ex` +
  `lib/letflow/identity/tenant.ex`/`user.ex` (top-level context module + same-named
  subdirectory schema pattern; plain `attrs :: map()` passed to `Changeset.changeset/2`,
  not a dedicated params struct), `priv/repo/migrations/20260816000004_create_users.exs`
  and `…090045_create_tenant_schemas.exs` (migration shape: `primary_key: false` +
  explicit `binary_id`, required `#`-comment header, **plain `timestamps()`
  (`inserted_at`/`updated_at`), not renamed to `created_at`**, is this codebase's
  established default for a generic timestamp pair — `tenant_schemas`' rename to
  `provisioned_at` was a one-off exception for a column with distinct domain meaning,
  not the general rule), `lib/letflow/design/req028-graph-structural-validator.md` §9.1
  (jsonb columns decode to Elixir maps via Postgrex/Jason, no reason to keep JSON as an
  undecoded string the way Zig's allocator-lifetime constraints forced — same reasoning
  applied to this design's `json_schema` column, §3).
- `mix.exs` / `mix.lock`, read directly: `{:jason, "~> 1.4"}` is already a dependency
  (`jason` `1.4.5` pinned in `mix.lock`); `ex_json_schema` (or any other JSON-Schema
  library) is **not** present in either file — confirmed by `grep`, not assumed.
PROVENANCE (historical, not current decision authority):
- **R-Co source, read directly (per this requirement's own instruction — port behavior,
  not code):**
  - `src/event_store/registry.zig` (the real `registerType`/`validatePayload`/`getType`/
    `lastValidationFailures` implementation, `RegistryError` set, `ValidationFailure`/
    `EventTypeRecord`/`RegisterParams` structs, and the private
    `validateRegisterParams`/`validatePayloadAgainstSchema` helpers).
  - `src/design/event_store.md`'s `registry.zig` section (public interface + `ES-05`
    error-to-HTTP-status mapping table).
  - `src/tools/json_schema.zig` in full — R-Co's own hand-rolled validator:
    `validate`/`validateCollect` (the runtime constraint engine) and
    `validateSchemaShape` (the separate SPC-02 well-formedness check, **not** invoked by
    `registerType`/`registry.zig` at all — it belongs to a different feature, the
    sub-process interface contract, hooked from `graph.zig`'s `checkSubProcess`).
  - `src/design/spc-01-sub-process-interface-contract.md`'s "JSON Schema well-formedness
    rule" table (§1 below quotes it directly — the authoritative statement of the
    platform's supported keyword set).
  - `migrations/002_event_type_registry.sql` — R-Co's actual DDL: `id UUID PRIMARY KEY
    DEFAULT gen_random_uuid()`, `name TEXT NOT NULL`, `schema_version INTEGER NOT NULL
    DEFAULT 1`, `json_schema JSONB NOT NULL DEFAULT '{}'`, `description TEXT`,
    `created_at`/`updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`, `UNIQUE (name,
    schema_version)`, an index on `name`, and a seed `INSERT` of 20 built-in platform
    event types. **No `tenant_id` column anywhere in this file** — confirmed directly
    (relevant to §7's open question). The seed data and the `idx_etr_name` index are
    addressed explicitly in §3/§6 below (not silently dropped or silently ported).

These source reads directly produced §1 (the JSON Schema library decision) and §4 (the
`JsonSchema` validator module), which are the load-bearing sections of this design.

## 1. The JSON Schema validation library decision (centerpiece of this design)

**Decision: hand-roll a minimal validator matching R-Co's actual supported keyword
subset, as a new pure module `Letflow.EventStore.Registry.JsonSchema`. Do NOT add
`ex_json_schema` (or any other JSON Schema library) to `mix.exs`. No new
`docs/migration/decisions/*.md` record is written for this choice — reasoning for why
that bar isn't met is in §1.4.**

### 1.1 What R-Co's own validator actually does (the thing being ported)

PROVENANCE (historical, not current decision authority):
`src/tools/json_schema.zig`'s own moduledoc is explicit that R-Co never implemented full
JSON Schema: "Full JSON Schema draft-07 compliance is still NOT required. `$ref`,
`allOf`/`anyOf`/`oneOf`/`not`, `patternProperties`, `pattern`, `format`, `dependencies`,
and tuple-form `items` are deliberately NOT implemented; unknown keywords remain
silently ignored, so a schema using them is accepted rather than spuriously rejected."
`src/design/spc-01-sub-process-interface-contract.md`'s well-formedness table
independently confirms the exact same supported set:

| Keyword | Valid value type |
|---|---|
| `type` | string in `string,number,integer,boolean,object,array,null`, or non-empty array of such strings |
| `minimum` / `maximum` | JSON number |
| `minLength` / `maxLength` | non-negative JSON integer |
| `enum` | JSON array |
| `required` | array of non-empty strings |
| `properties` | object whose values are themselves well-formed schemas (recursive) |
| `items` | well-formed schema (object) |
| `additionalProperties` | JSON boolean (**only `false` is enforced at runtime** — the subschema form is not implemented) |

Unknown keywords — explicitly including `$ref`, `allOf`/`anyOf`/`oneOf`/`not`,
`patternProperties`, `pattern`, `format`, `dependencies`, `title`, `description` — are
**"permitted and inert"**: the runtime validator silently ignores them rather than
enforcing or rejecting them. This permissiveness is a load-bearing, deliberate platform
contract stated in two independent R-Co documents (the module's own moduledoc and the
SPC-02 design doc), not an implementation gap.

### 1.2 Why `ex_json_schema` is rejected

`ex_json_schema` implements real draft-04/06/07 semantics for exactly the keywords R-Co
deliberately leaves inert: `$ref` resolution, `pattern` (regex), `format`,
`allOf`/`anyOf`/`oneOf`/`not`, `patternProperties`. Adopting it would mean a
`json_schema` document using any of those keywords is **enforced** under Letflow but
**silently ignored** under R-Co — a real behavioral divergence for any event type whose
schema happens to use one of those keywords, not a cosmetic implementation detail. This
is precisely the class of divergence `docs/migration/decisions/0001-web-framework.md`/
`0002-oidc-integration.md`/`0003-ecto-schema-strategy.md` all steer away from: 0002 in
particular chose a **partial** library adoption (`ueberauth_oidcc` for token
verification only, hand-rolled JIT provisioning/tenant binding/role registry) *because*
a fuller library would have brought in behavior beyond what R-Co's own hand-rolled
surface actually does. The same reasoning applies here with less ambiguity than 0002
faced: R-Co's hand-rolled validator isn't a *stand-in* for behavior a library could
better approximate — it **is** the exact target behavior to port, keyword-for-keyword,
with a table (§1.1) that states it unambiguously. There's no approximation gap library
adoption would close; there's only a widening it would introduce.

Two further practical points:
PROVENANCE (historical, not current decision authority):
- **Error shape.** AC3 requires field-level failures as `(field_path :: RFC 6901
  pointer, constraint, actual value)`. R-Co's own `validateCollect` already produces
  exactly this shape (`Violation{path, constraint, actual}`). `ex_json_schema`'s own
  error struct (`%ExJsonSchema.Validator.Error{error: ..., path: ...}`) has a different
  internal taxonomy across the three drafts it supports; converting it into R-Co's
  shape would require writing an adapter layer of comparable size to just porting
  `json_schema.zig` directly — without buying behavioral parity in exchange (see above).
- **Footprint precedent.** `lib/letflow/design/req028-graph-structural-validator.md`
  (REQ-028, already merged) hand-wrote its own graph-structural validator rather than
  reaching for a general graph-processing library for a narrow, well-specified domain
  need, and that choice was never escalated to a decision record either. This design's
  choice is the same shape of decision at the same scale.

### 1.3 Concrete shape of the port

PROVENANCE (historical, not current decision authority):
`Letflow.EventStore.Registry.JsonSchema` (§4.4) mirrors `json_schema.zig`'s
`validateCollect`/`collectInto` keyword-for-keyword: `type` (mismatch short-circuits
further checks at that level — matches R-Co's cascade-avoidance behavior exactly),
`enum`, `minimum`/`maximum` (numbers only), `minLength`/`maxLength` (strings, codepoint
count), `required` (per-missing-member violation, not just one), `properties`
(recursive), `items` (uniform-subschema recursive, indexed pointers), `additionalProperties:
false` only (the subschema form is not implemented, matching R-Co exactly), RFC 6901
pointer construction with `~0`/`~1` escaping. Unsupported keywords are silently ignored
— ported as an explicit behavior, not an oversight. `validateSchemaShape`
(SPC-02/well-formedness-at-definition-time) is **not** ported by this requirement — it
belongs to the sub-process interface contract (SPC-01/02), a different feature with its
own future requirement; `registerType` in R-Co never calls it either (confirmed
directly from `registry.zig` — `registerType` only calls the lightweight
`isJsonObject` structural check, not `validateSchemaShape`). Scoping note recorded here
so nobody assumes `register_type/2` rejects a structurally-object-but-semantically-odd
schema like `%{"type" => 42}` — it does not, matching R-Co.

### 1.4 Why this doesn't rise to a new decision record

`docs/migration/decisions/0001`/`0002`/`0003` all record a **new external
framework/library dependency being added to `mix.exs`** (Plug/Bandit, `ueberauth_oidcc`,
and — for 0003 — the Ecto/`:prefix` mechanism strategy that governs every future
migration). This decision adds **zero new entries to `mix.exs`** — `jason` (already a
dependency) is the only external package involved, used only for `Jason.decode/1` on
the raw payload string, a pre-existing, already-adopted capability, not a new one. What
this design actually decides is an **internal algorithm choice** (hand-write the
validator vs. call a library) with no dependency-graph, licensing, or upgrade-cadence
consequence for the project — exactly the category of decision REQ-028's own
un-escalated hand-rolled-graph-validator choice already sets precedent for. Per
REQ-024's own instruction, escalation is reserved for "a genuinely new library
dependency" — this isn't one, so no `docs/migration/decisions/0005-*.md` (see §0's note
on the free number) is written.

PROVENANCE (historical, not current decision authority):
**What ELIXIR-DEV's `@moduledoc` on `Letflow.EventStore.Registry` must state (traced at
§8, AC5):** that JSON Schema payload validation is implemented by this project's own
`Letflow.EventStore.Registry.JsonSchema` (not a library), that this choice was made at
CODE-DESIGNER design time (cite this file, §1), and a one-line pointer to §1.1's keyword
table so a future reader immediately knows the validator's supported surface without
reading `json_schema.zig` itself. This is how AC5 ("names the JSON Schema validation
library choice as an explicit open question for CODE-DESIGNER, not a silently made
decision") is satisfied at the point the requirement was drafted/validated (the
requirement text itself never pre-picked a library — confirmed, §0) **and** carried
forward faithfully into the implementation artifact once CODE-DESIGNER (this document)
resolves it: the moduledoc documents that a decision was made and why, rather than
either (a) staying silent about there ever having been a choice, or (b) claiming the
question is still open when it no longer is.

## 2. Module naming and file layout

**No `lib/letflow/event_store/` directory exists yet** (confirmed: REQ-023, which would
otherwise have created it first, has not merged — `git log main` and
`handoffs/registry.json` both confirm `status: pending`/reserved-but-not-landed as of
this design). This design is the first to populate that namespace and sets its
convention, following the established `Letflow.Identity`/`Letflow.TenantProvisioning`
shape (top-level context module in `lib/letflow/<domain>.ex`, no — see below, this
domain nests one level deeper since `event_store` is itself the domain directory named
by the handoff's own `owned_modules: ["lib/letflow/event_store"]`):

| Module | File | Kind |
|---|---|---|
| `Letflow.EventStore.Registry` | `lib/letflow/event_store/registry.ex` | Context module (public API: §5) |
| `Letflow.EventStore.Registry.EventType` | `lib/letflow/event_store/registry/event_type.ex` | Ecto schema for `event_type_registry` rows |
| `Letflow.EventStore.Registry.ValidationFailure` | `lib/letflow/event_store/registry/validation_failure.ex` | Plain struct (not `Ecto.Schema` — never persisted), §4.3 |
| `Letflow.EventStore.Registry.JsonSchema` | `lib/letflow/event_store/registry/json_schema.ex` | Pure validator module (no `Repo`, no I/O), §4.4 |

PROVENANCE (historical, not current decision authority):
**Why `JsonSchema` nests under `Registry` rather than living at `Letflow.EventStore.JsonSchema`
or a new `lib/letflow/tools/` namespace:** R-Co's own `json_schema.zig` sits under
`src/tools/` specifically because it is shared by two unrelated features
(`registry.zig`'s ES-05 payload validation and `graph.zig`'s SPC-01/02 sub-process
interface contract) — Zig's module-path constraints even force a workaround
(`registry.zig`'s own comment: "Named module rather than a relative import because
registry.zig sits under the event_store module whose root is store.zig"). Elixir has no
equivalent module-path constraint, and **REQ-024's actual scope has exactly one
consumer** (Registry's own `validate_payload/3`) — a `lib/letflow/tools/` namespace for
a single caller would be premature structure with no second consumer yet to justify it
(YAGNI). If/when a future SPC-01/02 requirement needs the same keyword-checking
primitive, that requirement's own CODE-DESIGNER can promote/alias it then, informed by
whatever `graph.zig`'s Elixir port actually needs at that point — not decided here. This
is a design choice, stated explicitly per this role's own instruction not to leave
placement ambiguous, not deferred as an open question (there's a clear default and a
clear, cheap path to revisit it later).

`Letflow.EventStore.Registry.EventType` is named for what the row *is* (an event type
definition), the same singular-of-domain-concept naming `Letflow.Identity.Tenant`/`User`
already establishes — not literally "the table name singularized" (which would produce
an awkward `EventTypeRegistry` nested under `Registry`, i.e.
`Letflow.EventStore.Registry.EventTypeRegistry`, doubling "Registry" in the fully
qualified name for no benefit).

## 3. Migration: `event_type_registry` (`priv/repo/migrations/`)

**Tenant-scoped** (schema-per-tenant via REQ-022's `:prefix` mechanism) — per Decision
B's general rule for business tables, applied here as the default per §7's open
question (not fully settled by this design alone — flagged for REVIEWER
re-confirmation).

**Filename:** next-in-sequence real UTC-clock timestamp after
`20260816090045_create_tenant_schemas.exs` (ELIXIR-DEV generates the actual timestamp at
implementation time, matching `req022-tenant-schema-provisioning.md`'s own precedent for
this instruction). Module name `Letflow.Repo.Migrations.CreateEventTypeRegistry`.

PROVENANCE (historical, not current decision authority):
| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | `:binary_id` | `primary_key: true` | Decision A convention, matches every other table in this codebase |
| `name` | `:string` | `null: false` | Event type name. Length (1..128 chars) is an **application-level** (changeset) invariant, not a DB `CHECK` — matches this codebase's existing convention of enforcing string-shape rules at the changeset layer (e.g. `users.username`), and matches R-Co's own `TEXT NOT NULL` column (no DB-level length CHECK there either — R-Co's 128-char cap is enforced in `validateRegisterParams`, application-level, per `registry.zig`) |
| `schema_version` | `:integer` | `null: false` | **No DB `DEFAULT 1`** unlike R-Co's column — Letflow's `register_type/2` requires the caller to supply `schema_version` explicitly and validates it (§4.1), so an implicit default would mask a caller error rather than surface it. Deliberate divergence, stated explicitly. |
| `json_schema` | `:map` | `null: false, default: %{}` | Stored as Postgres `jsonb` via Ecto's `:map` type (decoded to/from an Elixir map automatically by Postgrex — same convention `req028-graph-structural-validator.md` §9.1 establishes for the `graph` column). `default: %{}` matches R-Co's `DEFAULT '{}'` (the fully-permissive empty schema). |
| `description` | `:text` | nullable | Free-text, no length cap (matches R-Co's plain `TEXT`, nullable) |
| — | `:naive_datetime` | `null: false` (×2) | Plain `timestamps()` — `inserted_at`/`updated_at`, **not** renamed to `created_at`/`updated_at` despite REQ-024's description text and R-Co's literal column names using "created_at". This matches the established Letflow-wide default already used for `tenants`/`users` (`timestamps()`, no rename) rather than `tenant_schemas`' one-off `provisioned_at` rename (justified there by `provisioned_at` carrying meaning beyond generic "inserted" — no equivalent domain-specific meaning applies to this table's timestamp pair). Stated explicitly since it's a real naming divergence from R-Co's literal column name, not an oversight. |

**Indexes:**
- `create unique_index(:event_type_registry, [:name, :schema_version])` — matches
  R-Co's `uq_event_type_version` constraint exactly. This is what `register_type/2`'s
  duplicate-collision backstop (§4.1) and both read paths (`validate_payload/3`,
  `get_type/2`) rely on.
- **No separate `index(:event_type_registry, [:name])`** (R-Co's `idx_etr_name`) — the
  unique index above already has `name` as its leading column, so Postgres can serve a
  `WHERE name = $1` lookup from it directly. Same redundancy-avoidance simplification
  `req022-tenant-schema-provisioning.md` §2 already applied to `tenant_schemas`'
  indexes, applied here for the identical reason. Stated explicitly, not a silent
  omission.

**Seed data — explicitly out of scope.** R-Co's `002_event_type_registry.sql` seeds 20
built-in platform event types (`INSTANCE_STARTED`, `TASK_ACTIVATED`, ...) inline via
`INSERT ... ON CONFLICT DO NOTHING`. **Nothing in REQ-024's acceptance criteria or
column list asks for this**, and seeding is meaningless before any code exists that
actually emits these event types (S3's instance engine, not yet built). This design
does not add a seed step to the migration — flagged here explicitly so it reads as a
scoping decision, not a gap nobody noticed. Whichever future requirement first needs a
platform event type registered (most likely REQ-025's own append-path testing, or S3)
should either call `register_type/2` directly at test/seed time or introduce its own
seed mechanism — not assumed here.

**Required tenant-scoped-migration guard pattern (mandatory — see
`req022-tenant-schema-provisioning.md` §4 in full before writing this file):** this
migration's `change/0` must branch on `Ecto.Migration.prefix()`'s truthiness — create
the table with `prefix: prefix()` when a prefix was supplied to the enclosing migrator
run, no-op otherwise — so a plain global `mix ecto.migrate` run safely skips it. **This
migration is the first real (non-`CreateTenantSchemas`) entry
`Letflow.TenantProvisioning.tenant_scoped_migrations/0` (currently `[]`) will ever
carry** — ELIXIR-DEV's implementation work for this requirement includes appending
`{version, Letflow.Repo.Migrations.CreateEventTypeRegistry}` to that function's body, in
`lib/letflow/tenant_provisioning.ex`, in addition to writing the migration file itself
(§4 of the req022 design: "both halves are mandatory, not either/or" — a migration
following the guard pattern but absent from this list is inert forever; present in the
list without the guard corrupts `public` on every plain migrate run). **Coordination
note:** REQ-023 is reserved by a parallel process per `handoffs/registry.json` and may
land concurrently: if REQ-023's own edit to `tenant_scoped_migrations/0` lands first (or
second), ELIXIR-DEV must merge both `{version, module}` entries into the list rather
than one overwriting the other — an ordinary rebase/merge-conflict concern at
implementation time, not a design-time blocker, named here so it isn't a surprise.

## 4. Public function signatures (`Letflow.EventStore.Registry`)

**Interface note on arity and tenant-scope resolution, read before the individual specs
below:** REQ-024's description names `register_type/2 (or /3)`, `validate_payload/2`,
`get_type/1`. Those numbers describe R-Co's own call shape after dropping Zig's
`self`/`allocator` parameters (2 and 1 conceptual arguments respectively) — but R-Co's
`Registry` is a **struct already bound to one pool/schema at `init/2` time**, so
`event_type`/`payload` alone are enough to identify what to query. Letflow's `Registry`
is a **stateless context module** (no analogous per-call-site pre-bound struct exists
anywhere else in this codebase — `Letflow.Identity`, `Letflow.TenantProvisioning` are
both plain function-only modules too), and per REQ-024's own AC1, this table is
schema-per-tenant — every DB call this module makes must resolve a tenant's physical
schema before querying. The requirement text never addresses how tenant scope threads
through these three functions (an omission, not a deliberate exclusion — confirmed by
re-reading the full entry, §0). Resolving that gap is exactly the kind of real interface
decision this role is asked to make, not defer.

**Correction (rework iteration 1):** the prior draft of this section asserted the
second/third argument should be `prefix :: String.t()`, supplied by the caller, "the
same way `Letflow.TenantProvisioning.replay_migrations/2` does." That citation was
factually wrong — re-read directly against `lib/letflow/tenant_provisioning.ex` for this
rework: `replay_migrations/2` (lines 153–181) takes `tenant_id`, not `prefix`. It
internally resolves `schema_name` via `Repo.get_by(Registration, tenant_id: tenant_id)`
(line 161) and returns `{:error, :tenant_not_provisioned}` (line 163) if no
`Registration` row exists for that tenant — the module owns both prefix derivation and
the not-provisioned error case; no public function in `tenant_provisioning.ex` takes a
raw prefix string from an external caller (`schema_name_for_tenant/1` is a pure
derivation with no provisioning check; `provision_tenant_schema/1` also takes
`tenant_id`, not `prefix`). This design now follows fix option (a) from
CODE-DESIGN-VALIDATOR's rework instructions: match `replay_migrations/2`'s actual
convention exactly, rather than the convention this draft previously (incorrectly)
attributed to it.

- `register_type/2` **stays literally `/2`** — `attrs :: map()` (bundling
  name/schema_version/json_schema/description, matching `Letflow.TenantProvisioning`'s
  own `attrs` idiom rather than a dedicated `RegisterParams` struct — see §4.1) plus
  **`tenant_id :: Ecto.UUID.t()`** (not `prefix`) as the second argument.
- `validate_payload/2` becomes **`validate_payload/3`** — `event_type`, `payload`, and
  **`tenant_id`** are three genuinely separate conceptual inputs once tenant scope is
  made explicit; there is no non-distorting way to bundle two of the three into one
  argument the way `register_type/2` bundles four record fields into one `attrs` map
  (attrs are already naturally one cohesive "the record being created" concept;
  `event_type` + `payload` are not the same kind of thing and forcing them into one map
  purely to preserve a `/2` label would be exactly the kind of shape-over-substance
  distortion `core-directives.md`'s "Never Satisfy a Gate by Editing What It Measures"
  principle warns against, applied to interface design rather than a literal gate).
- `get_type/1` becomes **`get_type/2`** — `event_type` plus **`tenant_id`**, same
  reasoning.

**Tenant-scope resolution mechanism (new in this rework iteration):**
`register_type/2` and `get_type/2` each independently resolve `tenant_id` to a physical
`schema_name` as their first behavior step, via
`Repo.get_by(Letflow.TenantProvisioning.Registration, tenant_id: tenant_id)` — the exact
same lookup `replay_migrations/2` performs inline. A `nil` result (no `Registration` row
for that `tenant_id`) short-circuits the function with `{:error, :tenant_not_provisioned}`,
added to all three functions' error unions (§4.1–§4.3). `validate_payload/3` does
**not** duplicate this lookup itself — it has no direct `Repo` call of its own (its only
DB access is via its own internal call to `get_type/2`, §4.2 step 2), so it simply
forwards `tenant_id` to `get_type/2` and propagates whatever error `get_type/2` returns,
`:tenant_not_provisioned` included. Stated explicitly so ELIXIR-DEV doesn't triplicate
the lookup: only two of the three functions (`register_type/2`, `get_type/2`) contain
the resolution step themselves.

**Why duplicate the lookup between `register_type/2` and `get_type/2` rather than
extracting a shared helper:** `Letflow.TenantProvisioning` currently exposes no public
function with the exact contract this design needs (`tenant_id -> {:ok, schema_name} |
{:error, :tenant_not_provisioned}`) — `schema_name_for_tenant/1` is pure derivation with
no provisioning check, and the actual check-and-resolve logic lives inline inside
`replay_migrations/2`, not factored out. Extracting it into a new shared
`Letflow.TenantProvisioning` function would mean this design reaching into and modifying
a sibling requirement's already-merged module beyond the one edit already anticipated
there (`tenant_scoped_migrations/0`, §3) — judged out of REQ-024's scope. The two-call-site
duplication (a single `Repo.get_by/2` line, not a complex algorithm) is accepted here
rather than triggering that refactor; named as a real cross-module dependency in §6 and
flagged in §7.3 for REVIEWER to decide whether a future fast-follow should extract it.

This divergence (arity note + resolution mechanism) is called out here, in the
traceability table (§8), and must be mentioned in `Letflow.EventStore.Registry`'s own
`@moduledoc` (two sentences: "arities differ from REQ-024's literal text because
tenant-scope threading is mandatory, and the second/third argument is `tenant_id`, not a
raw prefix string — the module resolves the physical schema internally via
`Letflow.TenantProvisioning`, returning `{:error, :tenant_not_provisioned}` if the
tenant has no provisioned schema yet — see
`lib/letflow/design/req024-event-type-registry.md` §4") so CODE-DESIGN-VALIDATOR and
REVIEWER see the reasoning rather than an unexplained mismatch against the requirement
text.

### 4.1 `register_type/2`

```
@spec register_type(attrs :: map(), tenant_id :: Ecto.UUID.t()) ::
        {:ok, EventType.t()}
        | {:error, :tenant_not_provisioned}
        | {:error, Ecto.Changeset.t()}
        | {:error, :duplicate_event_type_version}
        | {:error, :schema_version_not_monotonic}
        | {:error, term()}
```

`attrs` keys: `"name"`/`:name` (`String.t()`), `"schema_version"`/`:schema_version`
(`pos_integer()`), `"json_schema"`/`:json_schema` (`map()`), `"description"`/
`:description` (`String.t() | nil`, optional) — standard `Ecto.Changeset.cast/4` string-
or-atom-key tolerance, matching every other `attrs`-taking function in this codebase.

**Behavior, in order:**

1. **Resolve `tenant_id` to `schema_name`** (§4's opening note): `Repo.get_by(
   Letflow.TenantProvisioning.Registration, tenant_id: tenant_id)`. `nil` → return
   `{:error, :tenant_not_provisioned}` immediately — no changeset work attempted.
   Otherwise bind the row's `schema_name` field for use as the `prefix:` option value in
   steps 4–5 below.
2. Build `EventType.changeset(%EventType{}, attrs)` (§5, `EventType`'s own changeset):
   `cast([:name, :schema_version, :json_schema, :description])`,
   `validate_required([:name, :schema_version, :json_schema])`,
   `validate_length(:name, min: 1, max: 128)`,
   `validate_number(:schema_version, greater_than: 0)`. **This is where R-Co's "name
   empty" / "name > 128 chars" / "schema_version 0 invalid" `RegistryError` variants
   land** — as ordinary changeset errors, matching AC2's own implicit carve-out (AC2
   only requires the *(name, schema_version) duplicate* case to be a distinct,
   non-generic error; it does not ask every validation failure to get its own atom).
   **R-Co's `InvalidJsonSchema` (structural "is this even a JSON object" check) is
   subsumed for free by `Ecto.Type.cast/2` on the `:map` field type** — a non-map
   `json_schema` value fails `cast/4` itself, landing in the same
   `{:error, %Ecto.Changeset{}}` path, with no bespoke `:invalid_json_schema` atom
   needed. This is the same "constraint moves from a comment/hand-check into an
   enforced type" pattern `0003-ecto-schema-strategy.md`'s TEXT→`Ecto.Enum` swap
   already established as a legitimate Decision-A-style simplification, applied here to
   R-Co's leading-byte `isJsonObject` hack.
3. If the changeset is invalid at this point, return `{:error, changeset}` immediately
   — no DB round-trip.
4. **Monotonicity pre-check (a Letflow-specific rule beyond R-Co — see the callout
   below):** query the current maximum `schema_version` already registered for `name`
   under `schema_name` (the value resolved in step 1 — `Repo.aggregate/4`-shaped:
   `MAX(schema_version) WHERE name = $1`, `prefix: schema_name`). Let `current_max` be
   that value, or `0` if no rows exist yet for `name`.
   - If `changeset.schema_version < current_max` → return
     `{:error, :schema_version_not_monotonic}`.
   - If `changeset.schema_version == current_max` (only possible when `current_max > 0`,
     i.e. a row with that exact `(name, schema_version)` pair already exists) → return
     `{:error, :duplicate_event_type_version}` directly — no need to even attempt the
     `INSERT` for this case, since it is already known to collide.
5. Otherwise (`schema_version > current_max`), attempt the insert
   (`Repo.insert(changeset, prefix: schema_name)`). The unique index on `(name,
   schema_version)` (§3) is the race-safe backstop for the rare concurrent-registration
   case the step-4 pre-check can't fully close (two concurrent `register_type/2` calls
   both reading the same `current_max` before either commits, both attempting
   `current_max + 1`) — map a `unique_constraint` violation on this index to
   `{:error, :duplicate_event_type_version}`, the same way
   `Letflow.TenantProvisioning.insert_or_fetch_registration/2` maps a foreign-key
   violation to a clean atom rather than leaking a raw `%Ecto.Changeset{}` constraint
   error. **Accepted, explicitly-stated race-window limitation:** two concurrent calls
   registering *different*, non-adjacent out-of-order versions for the same `name`
   (e.g. version 5 and version 3 committing in either order) are not fully serialized by
   this design — the unique index only protects against an *exact* `(name,
   schema_version)` collision, not out-of-order-but-distinct versions racing past the
   step-4 `MAX` check. This is a best-effort ordering guarantee, not a
   transaction-with-advisory-lock hard invariant (unlike
   `provision_tenant_schema/1`'s `pg_advisory_xact_lock` use) — stated explicitly as an
   accepted risk rather than silently glossed over, matching the same
   accepted-risk-disclosure pattern `req022-tenant-schema-provisioning.md` §3.1 already
   uses for its own `hashtext` collision note. If this ever needs to be a hard
   invariant, a future requirement can add the same advisory-lock pattern around steps
   4–5; not built here since REQ-024's acceptance criteria don't ask for it.
6. Return `{:ok, %EventType{}}` on success.

PROVENANCE (historical, not current decision authority):
**Callout — `:schema_version_not_monotonic` is a new rule, not a straight R-Co port.**
R-Co's own `registerType`/`validateRegisterParams` has **no** "greater than all existing
versions" check at all — only the exact-`(name, schema_version)`-collision check exists
in R-Co (confirmed directly, `registry.zig`). REQ-024's own description text, however,
explicitly adds this rule ("schema_version (integer > all existing versions for this
name; 0 invalid) before insert") — a genuine Letflow-specific tightening beyond R-Co's
behavior, not something this design silently introduced. Since the requirement names the
rule but doesn't name an error atom for the "not-an-exact-duplicate-but-still-not-greater"
case, this design picks `:schema_version_not_monotonic` (distinct from
`:duplicate_event_type_version`, since the two are semantically different: one is "this
exact row already exists," the other is "this row doesn't exist but is out of order") —
recorded here as an explicit choice, not left ambiguous for ELIXIR-DEV to invent
independently.

### 4.2 `validate_payload/3`

```
@spec validate_payload(event_type :: String.t(), payload :: String.t(), tenant_id :: Ecto.UUID.t()) ::
        :ok
        | {:error, :tenant_not_provisioned}
        | {:error, :unknown_event_type}
        | {:error, {:payload_validation_failed, [ValidationFailure.t()]}}
        | {:error, term()}
```

`payload` is a **raw JSON-encoded binary string** (matches R-Co's `payload: []const u8`
literally, and matches this function's realistic caller — REQ-025's `Store.append/1`(or
`/2`), which receives payload bytes from an HTTP request body before any decoding
happens). This is a deliberate choice, not left ambiguous: `validate_payload/3` owns the
`Jason.decode/1` step itself.

**Behavior, in order:**

PROVENANCE (historical, not current decision authority):
1. `Jason.decode(payload)`. Structural guard, ported from R-Co's `isJsonObject`
   pre-check + its malformed-JSON fallback, **collapsed into one check** since Elixir's
   `Jason.decode/1` already fully parses (unlike Zig's cheap leading-byte peek): if
   decoding fails, **or** decoding succeeds but the result is not a map (payload was a
   JSON array/string/number/bool/null at the root), return
   `{:error, {:payload_validation_failed, [%ValidationFailure{field_path: "/",
   constraint: "type", actual: payload}]}}` immediately — `actual` is the raw payload
   string in this specific case (matches R-Co's fallback, which reports the raw bytes
   when parsing itself fails, before any value-level `actual` can be extracted).
   **This is a platform-level invariant about what an event payload must look like
   (event payloads are always JSON objects), enforced here in `Registry`, not inside
   `JsonSchema` (§4.4) — matches R-Co's own module boundary exactly**, where this check
   lives in `registry.zig`'s `validatePayloadAgainstSchema`, not in the generic,
   schema-driven `json_schema.zig`.
2. Call `get_type/2` (§4.3) with `event_type` and `tenant_id`, forwarded as-is —
   `validate_payload/3` does not resolve `schema_name` itself (§4's opening note). On
   `{:error, :unknown_event_type}` **or `{:error, :tenant_not_provisioned}`**, propagate
   that error directly (ES-05: unregistered event types are always rejected — matches
   R-Co's `validatePayload`, whose `getType` call's error propagates unchanged; the
   `:tenant_not_provisioned` case has no R-Co analogue since R-Co's `Registry` is always
   already bound to a valid schema at `init/2` time — this is a Letflow-specific
   propagation made necessary by tenant-scope resolution now happening per-call, §4).
3. On `{:ok, %EventType{json_schema: schema}}`, call
   `JsonSchema.validate(decoded_payload, schema)` (§4.4) — returns a (possibly empty)
   list of `ValidationFailure.t()`.
4. Empty list → return `:ok`. Non-empty list → return
   `{:error, {:payload_validation_failed, failures}}`.

**No `last_validation_failures/1`-equivalent function exists in this module — by
design, not omission.** REQ-024's own description explicitly suggests this: "e.g. via a
struct returned alongside the error rather than hidden mutable state, since Elixir has
no implicit 'valid until next call' memory model the way Zig's slice-ownership does."
R-Co's `Registry.last_failures` field + `lastValidationFailures/1` accessor exists
*only* because Zig's `RegistryError!void` return type has no room to carry a payload
alongside the error — Elixir's tagged-tuple return type has no such constraint, so the
failures travel with the error itself (`{:error, {:payload_validation_failed,
failures}}`), fully replacing the two-call stateful-accessor pattern with a single
call whose result is self-contained. This is the interface's answer to AC3 directly:
the caller never needs a second call to learn *why* validation failed, and there is no
window where a second, unrelated `Registry` call from another process could silently
invalidate a failure list the way R-Co's shared-mutable-field version could in a
multi-request Zig server (not actually a concern there either, since R-Co's `Registry`
is per-request-scoped in practice, but the point stands that Elixir's approach has
strictly no such hazard by construction).

**Validated against the most recent `schema_version` only — not an exact
caller-specified version.** REQ-024's description flags this as ELIXIR-DEV's/this
role's interface choice to make and state. R-Co's own `validatePayload` has **no**
`schema_version` parameter at all — it unconditionally calls `getType` (which is
itself hardcoded to `ORDER BY schema_version DESC LIMIT 1`), so R-Co's actual, real
behavior is "always validate against the most recent version," full stop. Per this
project's established bias (0001/0002/0003 all favor "port actual behavior, not more"),
this design matches that exactly: `validate_payload/3` has no exact-version parameter.
An exact-version overload was considered and rejected — no R-Co precedent, no REQ-024
acceptance criterion asks for it — but could be added later as an additive
`validate_payload/4` without breaking this signature, if some future requirement needs
it. Not built here.

**`RegistryError.InvalidJsonSchema`'s validate-time case (R-Co: "the STORED schema no
longer parses — a registry-integrity fault") is structurally impossible in Letflow and
is not ported as a reachable error case.** R-Co's `json_schema` column is raw `TEXT`,
so a corrupted stored value really can fail to re-parse at read time. Letflow's
`json_schema` column is `jsonb` (§3) — Postgres itself guarantees every value in a
`jsonb` column is well-formed JSON at write time; there is no code path by which
`get_type/2` (§4.3) could ever return a schema value that fails to decode, because it
was never encoded as text in the first place. This is a direct, positive consequence of
the storage-representation choice §3 makes, stated explicitly rather than left as a
silently-vanished error case someone might later wonder about.

### 4.3 `get_type/2`

```
@spec get_type(event_type :: String.t(), tenant_id :: Ecto.UUID.t()) ::
        {:ok, EventType.t()}
        | {:error, :tenant_not_provisioned}
        | {:error, :unknown_event_type}
        | {:error, term()}
```

**Behavior, in order:**

1. **Resolve `tenant_id` to `schema_name`** — identical mechanism to §4.1 step 1:
   `Repo.get_by(Letflow.TenantProvisioning.Registration, tenant_id: tenant_id)`. `nil` →
   return `{:error, :tenant_not_provisioned}` immediately.
PROVENANCE (historical, not current decision authority):
2. `SELECT * FROM event_type_registry WHERE name = $1 ORDER BY schema_version DESC
   LIMIT 1` (parameterized, `prefix: schema_name` — the value resolved in step 1, not a
   caller-supplied argument) — matches R-Co's `getType` query exactly (order/limit
   clause, §0's `registry.zig` read). Zero rows → `{:error, :unknown_event_type}`
   (**never `nil`, never a raised exception** — this is AC4's literal requirement, and
   matches R-Co's `RegistryError.UnknownEventType`). One row → `{:ok, %EventType{}}`.

### 4.4 `Letflow.EventStore.Registry.JsonSchema.validate/2`

```
@spec validate(payload :: map(), schema :: map()) :: [ValidationFailure.t()]
```

Pure, no I/O, no `Repo` — safe to unit-test directly against literal maps with no
database, matching R-Co's own reasoning for keeping `validatePayloadAgainstSchema`/
`validateCollect` free of `Pool`/`allocator` concerns wherever possible. Empty list
result means "conforms"; a non-empty list is the complete set of violations (ES-05:
"report EVERY failure," not just the first — matches AC3 and R-Co's `validateCollect`
exactly, not the single-message `validate/2`-in-Zig sibling that only reports the
first violation and is *not* the function being ported here — R-Co itself keeps both
for different callers; only the collecting one is relevant to ES-05/this requirement).

**Algorithm shape (recursive worker over `(pointer :: String.t(), value :: term(),
schema :: map())`, not literal code — ELIXIR-DEV writes the real version, per this
role's own restriction against implementation code in a design doc):**

```
collect(pointer, value, schema):
  if schema has "type":
    if value's runtime shape doesn't match the declared type (or any member of a
       declared type array) per the type-name table in §1.1:
      append violation(pointer, "type", value)
      return   # stop descending -- a type mismatch makes every other keyword at
               # this level meaningless, matches R-Co's collectInto exactly
  if schema has "enum" (must be a list): if value isn't deep-equal to any member,
    append violation(pointer, "enum", value)
  if value is a number:
    if schema has "minimum" and value < it: append violation(pointer, "minimum", value)
    if schema has "maximum" and value > it: append violation(pointer, "maximum", value)
  if value is a string (codepoint count, not byte count -- String.length/1):
    if schema has "maxLength" and count > it: append violation(pointer, "maxLength", value)
    if schema has "minLength" and count < it: append violation(pointer, "minLength", value)
  if value is a map:
    if schema has "required" (list of names):
      for each required name absent from value:
        append violation(join_pointer(pointer, name), "required", nil)
    if schema has "properties" (map of name -> subschema):
      for each (name, subschema) where value has that key:
        collect(join_pointer(pointer, name), value[name], subschema)
    if schema has "additionalProperties" == false (boolean; subschema form ignored,
       matches R-Co exactly -- only the `false` form is enforced):
      for each key in value not listed in schema["properties"]:
        append violation(join_pointer(pointer, key), "additionalProperties", value[key])
  if value is a list:
    if schema has "items" (a single subschema -- tuple-form items is NOT implemented,
       matches R-Co exactly):
      for each (index, element) in value:
        collect(join_pointer(pointer, to_string(index)), element, schema["items"])
  # every other schema keyword (unrecognized, or a recognized-but-unimplemented one
  # like $ref/allOf/pattern/format) is silently ignored -- ported deliberately, §1.1
```

PROVENANCE (historical, not current decision authority):
`join_pointer/2` implements RFC 6901 §3 escaping (`~` → `~0`, `/` → `~1`) exactly as
`json_schema.zig`'s `joinPointer` does. The document root's own pointer is `""` inside
the recursion and rendered as `"/"` by the caller when needed (matches
`appendFailureRaw`'s `if (v.path.len == 0) "/" else v.path` convention) — concretely,
`validate/2`'s own top-level call passes `""` as the initial pointer, and
`Registry.validate_payload/3`'s own root-type-mismatch shortcut (§4.2 step 1) is the one
place that already uses the literal `"/"` string directly, since it never enters this
recursive worker at all for that specific failure mode.

**`actual` value convention:** unlike R-Co (which serializes `actual` to a JSON-text
string via `std.json.Stringify.valueAlloc`), this port keeps `actual` as the **raw,
already-decoded Elixir term** (`term()`, not `String.t()`) — a legitimate Decision-A-style
simplification: R-Co serializes because its `ValidationFailure.actual` field is
allocator-owned `[]const u8` (no room for a typed union in that struct); Elixir's
`ValidationFailure.actual :: term()` (§4.5) has no such constraint, and keeping the raw
term avoids a pointless encode-then-later-maybe-decode round trip for any caller that
wants to inspect the actual value programmatically (e.g. an HTTP layer rendering an RFC
9457 problem-details body, REQ-024's own likely eventual consumer per `event_store.md`'s
HTTP-status-mapping table). Stated explicitly as a divergence, not silent.

### 4.5 `Letflow.EventStore.Registry.ValidationFailure`

```
@type t :: %__MODULE__{
        field_path: String.t(),
        constraint: String.t(),
        actual: term()
      }
defstruct [:field_path, :constraint, :actual]
```

Plain struct, not `Ecto.Schema` — never persisted, exists only to carry validation
result data through the return tuple. `field_path` is always an RFC 6901 pointer
(`"/"` for the document root, `"/foo/0/bar"` for nested/indexed locations); `constraint`
is always one of the keyword-name string literals listed in §4.4's algorithm sketch
(`"type"`, `"enum"`, `"minimum"`, `"maximum"`, `"minLength"`, `"maxLength"`,
`"required"`, `"additionalProperties"`) — never a free-form message string, matching
R-Co's own machine-checkable (not prose) constraint-name convention exactly, which is
what makes AC3's "not just a boolean false" testable at all (a test can assert on the
literal constraint atom/string, not parse a sentence).

## 5. `Letflow.EventStore.Registry.EventType` (Ecto schema)

`@primary_key {:id, :binary_id, autogenerate: true}`, `schema "event_type_registry" do`
— fields:

| Field | Ecto type | Notes |
|---|---|---|
| `name` | `:string` | |
| `schema_version` | `:integer` | |
| `json_schema` | `:map` | `default: %{}` |
| `description` | `:string` | nullable |
| (timestamps) | — | plain `timestamps()`, `inserted_at`/`updated_at` — see §3's column table for the naming-divergence-from-R-Co note |

`changeset/2`:

```
@spec changeset(t :: %__MODULE__{}, attrs :: map()) :: Ecto.Changeset.t()
```

`cast(attrs, [:name, :schema_version, :json_schema, :description])`,
`validate_required([:name, :schema_version, :json_schema])`,
`validate_length(:name, min: 1, max: 128)`,
`validate_number(:schema_version, greater_than: 0)`,
`unique_constraint([:name, :schema_version], name: :event_type_registry_name_schema_version_index)`
(the exact generated index name Ecto derives from §3's `unique_index/2` call — ELIXIR-DEV
confirms the literal name against the actual migration once written; this is a
mechanical Ecto naming-convention detail, not an open design question).

## 6. Cross-module dependencies

- `Letflow.Repo` — all DB access goes through the existing single `Ecto.Repo`, every
  call passing `prefix: schema_name` explicitly, where `schema_name` is resolved
  internally from the caller's `tenant_id` (§4's opening note) — never supplied directly
  by the caller (no dynamic-repo/multi-repo config exists, matching
  `req022-tenant-schema-provisioning.md` §6's own note).
- **`Letflow.TenantProvisioning.Registration` (the Ecto schema struct — a genuine
  cross-module read dependency this design did not previously name, added in rework
  iteration 1):** `register_type/2` (§4.1 step 1) and `get_type/2` (§4.3 step 1) each
  query it directly, `Repo.get_by(Registration, tenant_id: tenant_id)`, to resolve
  `schema_name` and detect an unprovisioned tenant. This duplicates — rather than
  reuses — the exact lookup `replay_migrations/2` performs inline
  (`tenant_provisioning.ex` lines 160–163), because `Letflow.TenantProvisioning`
  currently exposes no public function with the standalone contract
  (`tenant_id -> {:ok, schema_name} | {:error, :tenant_not_provisioned}`) this design
  needs. Reasoning for accepting the two-call-site duplication instead of extracting a
  shared helper is in §4's opening note; flagged again in §7.3 for REVIEWER.
- `Jason` (`~> 1.4`, already a dependency) — `validate_payload/3`'s own `Jason.decode/1`
  call on the raw `payload` argument (§4.2 step 1). No other module in this design uses
  `Jason` directly — `json_schema`/`EventType`'s own map field is decoded by
  Postgrex/Ecto automatically on read, never by this module calling `Jason` itself.
- `Letflow.TenantProvisioning.tenant_scoped_migrations/0` — this requirement's migration
  must be appended to that function's body (§3's "Required tenant-scoped-migration guard
  pattern" callout). This is a **forward** dependency (this requirement edits
  `lib/letflow/tenant_provisioning.ex`, a file REQ-022 owns) — the same shape of
  cross-requirement edit `req022-tenant-schema-provisioning.md` §6 already anticipated
  ("Every REQ-023-onward requirement that adds a tenant-scoped table ... includes a
  one-line edit to this module").
- **REQ-025 (`Store.append/1`/`/2`, not yet built)** — the first real caller of
  `validate_payload/3`, per REQ-025's own description ("call REQ-024's
  `validate_payload/2` before any write"). REQ-025's own CODE-DESIGNER should read §4's
  interface note (arity is actually `/3`, not `/2`, once tenant-scope threading is
  accounted for) and this document's §4.2 in full before assuming the literal `/2` the
  REQ-025 requirement text (drafted before this design existed) currently cites. Critically
  (corrected in this rework iteration): the third argument is `tenant_id`, **not** a raw
  prefix string — `Store.append/1` supplies the tenant_id it already has (the same way
  every other tenant-scoped context function in this codebase is called), and must treat
  `{:error, :tenant_not_provisioned}` as a real, handled outcome, not assume it away.
- **No dependency on `Letflow.EventStore` (a `Store`/`append` context module)** — that
  module doesn't exist yet (REQ-025's own scope); this design does not anticipate or
  stub its shape.

## 7. Open questions (explicit — NOT resolved here)

### 7.1 Is `event_type_registry` per-tenant or platform-wide global?

**Restated per REQ-024's own framing, not treated as settled by this design alone.**
Neither `0003-ecto-schema-strategy.md` nor `event_store.md` states this table's
tenant-schema classification explicitly the way `1147_par01_events_partitioning.sql`
explicitly classifies `events`/`events_archive` as `PER_TENANT`. This design **defaults
to schema-per-tenant**, per Decision B's stated general rule for business tables absent
a stated exception, applied consistently with how this design otherwise treats the
table (§3's migration, §4's tenant-scope threading throughout).

**Corroborating (not settling) evidence found during this design's own source reads,
recorded here so REVIEWER doesn't have to re-derive it from scratch:**
`0003-ecto-schema-strategy.md` Dimension A's own text explicitly groups
`event_type_registry` with `process_definitions` as "regular CRUD tables" (both
"sampled from `004_definitions.sql` and `002_event_type_registry.sql`") — and
`process_definitions` is unambiguously per-tenant per Decision B/adp-02. Separately,
R-Co's own `002_event_type_registry.sql` (§0) has **no `tenant_id` column at all**, even
though it predates migration 060 (schema-per-tenant) — meaning if `event_type_registry`
ever became tenant-scoped in R-Co's actual history, it did so purely via the
schema-per-tenant physical-schema mechanism (no intra-schema `tenant_id` column layer
the way `process_definitions`/`users` grew one), not via the adp-0x tenant-column
pattern. **Neither point is a citation of an explicit classification statement** the way
`1147`'s comment is for `events`/`events_archive` — this remains this design's own
inference, not a settled fact, and is flagged for REVIEWER re-confirmation exactly as
REQ-024's own text instructs, not presented as closed.

### 7.2 Interface-arity divergence from REQ-024's literal `/1`/`/2` text

Already stated in full at §4's opening interface note — restated here only as an index
entry so this section is a complete list of every open/flagged item in one place.
`register_type/2` stays literally `/2`; `validate_payload/3` and `get_type/2` diverge
from the requirement's literal `/2`/`/1` because tenant-scope threading (AC1) is
mandatory and the requirement text never addressed it. The second/third argument is
`tenant_id :: Ecto.UUID.t()` — resolved internally to a physical `schema_name` via
`Letflow.TenantProvisioning.Registration` — **not** a raw prefix string supplied by the
caller (this parameter identity was corrected in rework iteration 1; see §4's "Correction"
callout for the full history). Not silently resolved — reasoning given in full at §4.

### 7.3 Should the tenant_id→schema_name-with-provisioning-check lookup be extracted
into a shared `Letflow.TenantProvisioning` function?

**New in rework iteration 1, not resolved here.** `register_type/2` and `get_type/2`
each independently run `Repo.get_by(Registration, tenant_id: tenant_id)` (§4.1 step 1,
§4.3 step 1) — the same lookup `replay_migrations/2` already performs inline. Three call
sites across two modules now share this exact logic with no single source of truth.
This design accepts the duplication rather than refactoring `Letflow.TenantProvisioning`
(a sibling, already-merged requirement's module) beyond the one edit already anticipated
there (§3/§6, `tenant_scoped_migrations/0`) — reasoning in full at §4's opening note and
§6. Left for REVIEWER to decide whether a future fast-follow requirement should extract
a shared `Letflow.TenantProvisioning` function (e.g. a `resolve_schema_name/1`-shaped
`tenant_id -> {:ok, schema_name} | {:error, :tenant_not_provisioned}`) that both this
module and a refactored `replay_migrations/2` could call — not decided or assumed here.

## 8. Acceptance-criteria traceability

| REQ-024 acceptance criterion | Concrete design element |
|---|---|
| "priv/repo/migrations gains an event_type_registry migration (schema-per-tenant per REQ-022) applying cleanly" | §3 — full migration spec (columns, types, constraints, indexes, required guard pattern, required `tenant_scoped_migrations/0` edit) |
| "register_type/2 rejects a second registration with the same (name, schema_version) with a distinct, testable error, not a generic changeset failure" | §4.1 steps 4–5 — `{:error, :duplicate_event_type_version}`, both the pre-check path and the unique-constraint-violation backstop path, neither of which leaks a raw `%Ecto.Changeset{}` for this specific case. Tenant scope threads via `tenant_id` (step 1, resolved internally to `schema_name`) — not a raw prefix string, corrected in rework iteration 1, see §4. |
| "validate_payload/2 against a payload missing a required field returns a failure result whose detail names the specific field_path (JSON Pointer form) and constraint, not just a boolean false" | §4.2 (behavior) + §4.4 (the `required` keyword's per-missing-member violation, RFC 6901 `field_path`, literal `constraint` string) + §4.5 (`ValidationFailure` struct shape) — note the arity divergence to `/3`, and that the third argument is `tenant_id` (not prefix), resolved internally by the `get_type/2` call it delegates to — §4's interface note, corrected in rework iteration 1 |
| "get_type/1 against an unregistered name returns an explicit :unknown_event_type-shaped error rather than nil or an exception" | §4.3 — `{:error, :unknown_event_type}` on zero rows, never `nil`/a raise — note the arity divergence to `/2`, and that the second argument is `tenant_id` (not prefix), resolved internally to `schema_name` in step 1 — §4's interface note, corrected in rework iteration 1 |
| "the moduledoc names the JSON Schema validation library choice as an explicit open question for CODE-DESIGNER, not a silently made decision" | §1 (full decision + reasoning) + §1.4's closing paragraph, which states exactly what `Letflow.EventStore.Registry`'s `@moduledoc` must say and why that satisfies this criterion even though the choice is now made, not left open (the requirement text itself never silently pre-picked a library — confirmed at §0 — and the moduledoc must document, not hide, that CODE-DESIGNER resolved it here) |
