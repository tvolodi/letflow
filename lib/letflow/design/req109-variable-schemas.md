# Design: REQ-109 — `variable_schemas` storage and per-key output-variable validation at `merge_output_variables/5` (closes ISS-0063 / GH#212)

**Requirement:** REQ-109 (stage S3, owner ELIXIR-DEV, `depends_on: [REQ-027, REQ-048, REQ-049, REQ-061]`, all `done`).
**Designer:** CODE-DESIGNER. **Design artefact only — no implementation code.** Every code block below is a
signature, a type, a table shape or a schema-field list. No function body, no `.ex`/`.exs` file content.

---

## 0. Sources read for this design, and what each one settled

Every citation below was re-read this session and the line numbers re-confirmed against the current
working tree / R-Co tree; nothing here is carried from memory.

PROVENANCE (historical, not current decision authority):
| Source | Line(s) confirmed this session | What it settles |
|---|---|---|
| `docs/requirements.yaml` REQ-109 | 4684–4936 (13 acceptance criteria) | The full scope, the three deliverables, what is deferred |
| R-Co `migrations/012_event_retention.sql` | 32–49 (`CREATE TABLE variable_schemas`, `UNIQUE (definition_id, variable_key)`, `idx_vs_definition`) | §2's DDL, column for column |
| R-Co `src/engine/instance.zig` | 2300–2304 (ISS-202 two-phase doc comment), 2318 (`mergeVariables` signature), 2345–2358 (the one `SELECT variable_key, json_schema … WHERE definition_id = $1::uuid`), 2400–2430 (per-key validate, unparseable-schema branch, collision detection) | §4's lookup shape, §6.3's malformed-schema rule, §11's OQ-1 divergence |
| R-Co `src/engine/instance.zig` | 4060–4070 (`error_type_str` 10-variant switch, `SCHEMA_VIOLATION` at 4062) | §11's OQ-4 naming divergence |
| `lib/letflow/design/req049-variable-merge.md` | §3.1, §3.2, §7.1, §7.2, §7.3, §8 (five steps), §13.1, §13.2 | The consumer contract this requirement produces the input for |
| `lib/letflow/engine.ex` | 1276–1290 (the `:merge` `Multi.run/3` step), 1526–1560 (`merge_output_variables/5`), **1543** (`VariableMerge.merge(current_variables, output_variables, nil)` — confirmed verbatim), 1150–1170 (`complete_error()`), 1216–1234 (`complete_task/3`) | §5's call-site change |
| `lib/letflow/engine/variable_merge.ex` | 12–13, 18–20, 24–29, 31–46, 100–117 (`validation_outcome()`, `variable_validations()`), 186 (`find_rejection/2`'s `Map.get(validations, key, :ok)`). **Purity self-check grep at 59–66 executed this session: it returns FOUR matches, not the zero it claims** (26, 56, 63, 106) — see §13.1 | §8's four in-place moduledoc corrections; the exact map shape produced; §13's corrected purity baseline |
| `lib/letflow/event_store/registry.ex` | **147** (`case JsonSchema.validate(decoded, schema) do` — confirmed verbatim), 129–156 (`validate_payload/3` @spec + body), 165–175 (`get_type/2`) | §4.3's validator choice and why `validate_payload/3` is bypassed |
| `lib/letflow/event_store/registry/json_schema.ex` | 31–32 (`@spec validate(payload :: map(), schema :: map()) :: [ValidationFailure.t()]`, guarded `when is_map(payload) and is_map(schema)`) | §4.3's wrapping requirement |
| `lib/letflow/engine/sub_process.ex` | **179–185** (the `%{key => value}` / `%{"type" => "object", "properties" => %{key => schema}, "required" => [key]}` pair, confirmed verbatim) | §4.3's wrapping convention — proven precedent, not invented here |
| `lib/letflow/event_store/instance_projection.ex` | **113** (`field(:definition_id, Ecto.UUID)`) | §5's lookup key needs no new plumbing |
| `lib/letflow/tenant_provisioning.ex` | **295** (`@tenant_scoped_migration_manifest [`), 296–354 (entries; last is `{20_260_821_000_001, …CreateInstanceStateSnapshots}`) | §2.3's manifest entry and version choice |
| `priv/repo/migrations/20260818110003_create_tasks.exs` | full file (header + `if prefix() do` + `on_delete: :restrict` rationale + FK-index rationale) | §2's migration precedent |
| `priv/repo/migrations/20260821000001_create_instance_state_snapshots.exs` | 29 (`NO tenant_id COLUMN (Decision 0006 D2…)`) | §2.1's no-`tenant_id` decision |
| `lib/letflow/engine/lua_script_audit.ex` | 113–120 (`error_reason()` incl. `:missing_prefix`), 152–158 (`validate_prefix/1` fail-closed, no `public` fallback) | §6.1's fail-closed precedent |
| `lib/letflow/definitions/snapshot_store.ex` | 50, 95, 137, 157 (same `:missing_prefix` precedent) | §6.1, corroborating |
| `lib/letflow/definitions/promotion_plan.ex` | **191** (`# Default variable_schema_fetcher — there is no variable_schemas table`), 195–196 (`default_variable_schema_fetcher/2` returns `nil`) | §9's comment-only edit |
| `lib/letflow/engine/pin_resolver.ex` | **262–263** (`variable_schema_lookup: fn _tenant_id, _process_key -> {:ok, %{version: "unversioned", json_schema: nil}} end`, inside `default_lookup/0` at 262). **Corrected in rework:** an earlier draft of this design said 235–237, inheriting that number from REQ-109's own description; 230–240 is the `Lookup` `@type` block, not the value. The substance was always right, only the citation was wrong — and AC10 item 4 has ELIXIR-DEV copy this location into a moduledoc, so the wrong number would have been baked in | §11's OQ-2 latency argument; §9.2 |
| `docs/issues/ISS-0063.yaml` | `scoping_note` (lines 93–140), NOT `superseded_scoping_note` (64–92, marked do-not-act-on) | §1's three-schemas disambiguation |
| `docs/agents/instructions/security-invariants.md` | INV-1 (lines 46–58) | §6's fail-closed and §7's tenant-isolation obligations |
| `docs/migration/stage-3-instance-engine.md` | 3–5 (`Status: done -- all Stage 3 requirements shipped…`) | §10's AC12 edit |

**No access gap this session.** Unlike REQ-049's design (its §0 recorded R-Co as unreadable at the
time), the R-Co tree at `c:\Users\tvolo\dev\ai-dala\R-Co` is fully readable and was read directly. Every
"reasoned reconstruction" caveat REQ-049 was forced into is, for this design, replaced by a literal
source citation.

---

## 1. The three R-Co concepts that carry the word "schema" — disambiguation (AC10)

A prior investigation (ISS-0063's `superseded_scoping_note`, explicitly marked **do not act on**)
conflated these and mis-scoped the issue onto REQ-047's OQ-3. This design names all three so the
mistake is not repeatable. **This block is the substance of what must appear in
`Letflow.Engine.VariableSchema`'s moduledoc** (AC10, item 1).

PROVENANCE (historical, not current decision authority):
| Concept | R-Co location | What it actually is | Scope |
|---|---|---|---|
| `tasks.form_schema` | populated at activation from `node.attributes["form_schema"]` (`src/engine/instance.zig:5490`, `extractFormSchemaJson`); served in the task-detail response (`src/api/routes/tasks.zig:896`) | A UI form-**rendering** payload. **R-Co never validates submitted output against it.** | **OUT.** REQ-047's OQ-3 stays open; answering it would not close ISS-0063. |
| `variable_schemas` | `migrations/012_event_retention.sql:32`; read by `mergeVariables` (`src/engine/instance.zig:2318`) | `(definition_id, variable_key) -> json_schema`. The real per-variable validation source. | **IN.** This requirement is about this table and nothing else. |
| `form_schema_registry` | `migrations/047_repository_form_schemas.sql`, REPO-05 | A field-level search/discovery index over form artifacts, keyed to `artifact_versions`. | **OUT.** Named because grepping "form schema" lands here first and would build the wrong mechanism. |

### 1.1 Deliverable 2 — the dedicated-table resolution (AC10, item 2)

`req049-variable-merge.md` §7.3 left open "whether a variable schema is registered in the existing
`event_type_registry` table under a name derived from the variable key, or in a new dedicated table."
**REQ-109 settles it as the dedicated table.** Reasons, to be recorded in
`Letflow.Engine.VariableSchema`'s moduledoc citing §7.3 as the question it closes:

1. R-Co has a distinct `variable_schemas` table keyed by `(definition_id, variable_key)` — this is a
   port, and the source system's own answer is a dedicated table.
2. Reusing `event_type_registry` would require inventing a variable-key→event-type-name mangling with
   no source counterpart.
3. It would pollute the event-type namespace with rows that are not event types, which every
   `get_type/2` caller would then have to filter around.

**This question is closed. Do not re-open it.** REQ-049 §13.1 is thereby closed as well (see §12).

---

## 2. Deliverable 1 — the migration (AC1, AC2)

**File:** `priv/repo/migrations/20260821000002_create_variable_schemas.exs`
**Module:** `Letflow.Repo.Migrations.CreateVariableSchemas`

Version `20260821000002` chosen because the highest existing migration is `20260821000001`
(`create_instance_state_snapshots.exs`, confirmed both on disk and as the manifest's last entry). It
must sort **after** `20260816193001_create_process_definitions.exs`, which it carries an FK onto —
satisfied by a wide margin. Confirm no collision against `main` at implementation time (the
`docs/anti-patterns.md` duplicate-version class that produced ISS-0061).

### 2.1 Table shape

Ported column for column from R-Co `migrations/012_event_retention.sql:32-49`.

| Column | Type (Ecto migration) | Constraints | Ported from / rationale |
|---|---|---|---|
| `id` | `:binary_id` | `primary_key: true` | R-Co `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`; Letflow generates in the Ecto schema (`@primary_key … autogenerate: true`), matching every other engine table |
| `definition_id` | `references(:process_definitions, column: :id, type: :binary_id, on_delete: :restrict)` | `null: false` | R-Co `NOT NULL REFERENCES process_definitions(id)`; see §2.2 on `on_delete:` |
| `variable_key` | `:string` | `null: false` | R-Co `TEXT NOT NULL` |
| `json_schema` | `:map` | `null: false` | R-Co `JSONB NOT NULL`. `:map` is Letflow's established jsonb spelling (`instance_projections.variables`, `tasks.form_schema`) |
| `description` | `:text` | nullable | R-Co `TEXT` (nullable) |
| `created_at` | `:utc_datetime_usec` | `null: false`, `default: fragment("(now() AT TIME ZONE 'utc')")` | R-Co `TIMESTAMPTZ NOT NULL DEFAULT NOW()`. **Literal `created_at`, not `timestamps()`** — same choice `20260816120001_create_events.exs:73` made for the identical R-Co column name, and AC2 names `created_at` explicitly. The `AT TIME ZONE 'utc'` spelling (not bare `now()`) follows that same migration's header rationale |

**No `tenant_id` column.** Decision 0006 D2; REQ-064 dropped `tenant_id` from all ten pre-existing
tenant-scoped tables, and `20260821000001_create_instance_state_snapshots.exs:29` established that new
tenant-scoped tables add none. The tenant *is* the Postgres schema.

### 2.2 `on_delete:` — pick one and say why in the migration file header

R-Co uses `ON DELETE CASCADE`. **This design chooses `:restrict`**, matching
`20260818110002_create_tokens.exs` and `20260818110003_create_tasks.exs`, whose headers state the
reason: no delete path for `process_definitions` exists anywhere in Letflow yet, so `:restrict` fails
loudly instead of silently discarding tenant data that nothing intended to discard. The migration file
header **must state this reason explicitly** rather than copying either side silently (REQ-109
description, Deliverable 1). When a definition-delete path is eventually built, revisiting this is that
requirement's job, and it should find this paragraph.

### 2.3 Tenant scoping — both halves are mandatory (AC1)

1. The whole `create table` / `create index` body sits inside `if prefix() do … end`, with
   `prefix: prefix()` on the table and on the index, exactly as
   `20260818110003_create_tasks.exs` does.
2. A manifest entry is added to `@tenant_scoped_migration_manifest`
   (`lib/letflow/tenant_provisioning.ex:295`), in version order at the end of the list:
   `{20_260_821_000_002, Letflow.Repo.Migrations.CreateVariableSchemas, "20260821000002_create_variable_schemas.exs"}`.
   The manifest's own count comment above the list is prose that ELIXIR-DEV should update or leave
   consistent, not silently invalidate.

Missing either half is the failure mode AC1 tests both ends of: the manifest entry by inspection, the
apply by provisioning a tenant and reading the table back.

PROVENANCE (historical, not current decision authority):
Corroboration that per-tenant is right and R-Co agrees: R-Co's own DDL comment at `012:27-30`
("ISS-0641 / GH-637: PER_TENANT … FKs to tenant-schema `process_definitions(id)`"), and
`R-Co src/definition/sandbox_pool.zig:126`, which clones `variable_schemas` per tenant schema.

### 2.4 Indexes

| Index | Columns | Rationale |
|---|---|---|
| `uq_variable_schema_definition_key` (unique) | `[:definition_id, :variable_key]` | R-Co `UNIQUE (definition_id, variable_key)`. AC2 proves it with an actual failing insert |
| `idx_vs_definition` | `[:definition_id]` | R-Co `idx_vs_definition`. Postgres does not index the referencing side of an FK — the same reasoning every prior FK-bearing Letflow migration states |

Both carry `prefix: prefix()`. Index names are per-schema in Postgres, so the R-Co name `idx_vs_definition`
can be reused verbatim without cross-tenant collision.

---

## 3. Deliverable 3a — the Ecto schema module

**File:** `lib/letflow/engine/variable_schema.ex`
**Module:** `Letflow.Engine.VariableSchema`

### 3.1 Schema field list

```
@primary_key {:id, :binary_id, autogenerate: true}
@foreign_key_type :binary_id

schema "variable_schemas"
  field :definition_id  :: Ecto.UUID
  field :variable_key   :: :string
  field :json_schema    :: :map
  field :description    :: :string
  field :created_at     :: :utc_datetime_usec
```

No `timestamps()` (the table has `created_at` only, §2.1). No `belongs_to :definition` association —
this requirement never preloads or traverses to `process_definitions`; the FK is a database-level
integrity constraint, and adding an association would invite a preload that escapes the explicit
`prefix:` discipline §6.1 requires. `definition_id` is a plain `Ecto.UUID` field, matching
`instance_projection.ex:113`'s own treatment of the same value.

### 3.2 Changeset

```
@spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
```

Cast `[:definition_id, :variable_key, :json_schema, :description]`; require
`[:definition_id, :variable_key, :json_schema]`; `unique_constraint([:definition_id, :variable_key], name: :uq_variable_schema_definition_key)`.

**A changeset is declared even though REQ-109 writes no rows.** It exists because AC3–AC6's tests seed
rows via `Repo.insert` against a provisioned tenant schema, and because REQ-078/REQ-082's shared
`Letflow.Definitions` registration function (§9.1) will need exactly this changeset rather than
inventing a second one. It is deliberately minimal: **no validation that `json_schema` is itself a
well-formed JSON Schema document.** That is a registration-time concern belonging to whichever of
REQ-078/REQ-082 lands first, and this requirement's read path handles a malformed stored schema at read
time instead (§6.3). Flagged as OQ-3 (§11) so the later requirement does not assume this changeset
already guarantees well-formedness.

### 3.3 Types

```
@type t :: %__MODULE__{
        id: Ecto.UUID.t() | nil,
        definition_id: Ecto.UUID.t() | nil,
        variable_key: String.t() | nil,
        json_schema: map() | nil,
        description: String.t() | nil,
        created_at: DateTime.t() | nil
      }

@typedoc "variable_key -> the stored JSON Schema document, as decoded jsonb."
@type schema_map :: %{optional(String.t()) => map()}

@typedoc "Every distinct, pattern-matchable failure this module's read path returns."
@type error_reason :: :missing_prefix | :invalid_definition_id
```

`error_reason()` is a **closed** two-atom union. There is deliberately no `{:error, term()}` catch-all:
a `Repo` failure (connection loss, missing table) raises, as it does everywhere else in the engine's
transactional path, rather than being flattened into a value that a caller could mistake for "no
schemas registered." Fail-closed (§6.1) is about *scoping*, and a raise is the strictest possible
fail-closed for infrastructure faults inside an open `Ecto.Multi`.

### 3.4 Moduledoc obligations (AC10 — four items, all in *this* file)

1. **All three R-Co "schema" concepts** with which is in scope — §1's table.
2. **The dedicated-table resolution** of `req049-variable-merge.md` §7.3, citing §7.3 as the question
   it closes — §1.1.
3. **REQ-078 and REQ-082 named as the carriers of the deferred registration path**, together with the
   note that neither description mentioned it before REQ-109 added the obligation — §9.1.
4. **`promotion_plan.ex` and `pin_resolver.ex` named as the two remaining unwired consumers**, with
   their *actual* current return values stated correctly — §9.2. In particular
   `pin_resolver.ex:262-263` returns `{:ok, %{version: "unversioned", json_schema: nil}}`, a **populated
   tuple whose `json_schema` is nil — not a nil return**; describing it as null-returning is wrong and
   AC10 is verified by reading this file.

---

## 4. Deliverable 3b — the lookup and the validations builder

All three functions live in `Letflow.Engine.VariableSchema`. The split is deliberate: one function does
I/O, one is pure, one composes them, so TEST-DESIGNER can exercise the mapping table (§4.4) without a
database — the same pure/orchestration split `req049-variable-merge.md` §7 established for `merge/3`.

### 4.1 `fetch_schemas/3` — the single SELECT

```
@spec fetch_schemas(
        repo :: module(),
        definition_id :: Ecto.UUID.t() | nil,
        opts :: [prefix: String.t() | nil]
      ) :: {:ok, schema_map()} | {:error, error_reason()}
```

- `repo` is passed in rather than aliased, because the call site runs inside `Ecto.Multi.run/3`, which
  hands its own `repo` to the step function (`engine.ex:1276`). Taking it as an argument keeps the read
  on the transaction's connection.
- **Order of operations is load-bearing (AC7):** validate `opts[:prefix]` **first**, before anything
  else and before any query is constructed or issued. Then validate `definition_id`. Only then query.
PROVENANCE (historical, not current decision authority):
- One query, not one per key, matching R-Co's own doc comment "Issues one SELECT on `variable_schemas`;
  no writes" (`instance.zig:2318`):
  `from(vs in VariableSchema, where: vs.definition_id == ^definition_id, select: {vs.variable_key, vs.json_schema})`,
  executed as `repo.all(query, prefix: prefix)`. Result reduced into a `schema_map()`.
PROVENANCE (historical, not current decision authority):
- **The query is not filtered by candidate key.** R-Co selects every row for the definition and filters
  in memory (`instance.zig:2345-2358` then `schema_map.get(key)`); this is a port, the row count per
  definition is small and bounded by the definition's declared variables, and one stable query plan is
  easier to reason about than a variable-length `IN` list. Adding `and vs.variable_key in ^keys` would
  be a safe optimisation if profiling ever shows it matters — noted, not adopted.
- `Ecto.Query` composition with bound parameters only. No string interpolation anywhere (INV-7,
  matching R-Co's own "Security: $1 = definition_id hex — no SQL string interpolation" comment).

### 4.2 `validations_for/3` — pure

```
@spec validations_for(
        schemas :: schema_map(),
        overwrite_candidate_keys :: [String.t()],
        incoming_variables :: map()
      ) :: Letflow.Engine.VariableMerge.variable_validations()
```

Pure: no `Repo`, no clock, no randomness. For each key `K` in `overwrite_candidate_keys`:

1. If `schemas` has no entry for `K` → **omit `K` from the result entirely.** Not `:ok` — omitted.
   `merge/3`'s existing `Map.get(variable_validations, K, :ok)` default (documented at the
   `variable_validations` typedoc, `variable_merge.ex:110-117`; implemented at `find_rejection/2`,
   `variable_merge.ex:186`; `req049` §3.1 step 3) already treats an absent entry as `:ok`. Omission is the contract; adding an
   explicit `:ok` would work identically but obscures which keys had a schema at all.
2. If `schemas[K]` is present but is **not a map** (§6.3) → omit `K`, same as (1).
3. Otherwise call the validator per §4.3 and map its result per §4.4 into `%{K => outcome}`.

The returned map's keys are a **subset of `overwrite_candidate_keys`**. It never contains a key absent
from `incoming_variables`, and never a brand-new key (§4.5).

### 4.3 The validator, and the wrapping convention (AC8)

**`Letflow.EventStore.Registry.JsonSchema.validate/2`, called directly.**

```
@spec validate(payload :: map(), schema :: map()) :: [ValidationFailure.t()]
```

`[]` means valid; a non-empty list is the failure list.

**No JSON Schema dependency is added to `mix.exs`, and no second validator is written.** This is a
stated, deliberate deviation from REQ-049 AC4's *wording* ("goes through REQ-024's
`validate_payload/3`") whose *substance* it still satisfies: `JsonSchema.validate/2` **is**
`validate_payload/3`'s own internal pure delegate — `registry.ex:147` is literally
`case JsonSchema.validate(decoded, schema) do`. Meanwhile `validate_payload/3` itself is bound to
`get_type/2` → `event_type_registry` (`registry.ex:165-175`), which §1.1 has just decided against.
Calling it would force exactly the name-mangling that decision rejected.

**Wrapping.** `JsonSchema.validate/2` is guarded `when is_map(payload) and is_map(schema)`
(`json_schema.ex:32`), and a workflow variable's value may be a string, number, boolean, list or `nil`.
The value is therefore wrapped in a single-key object, and the stored schema in a matching object
schema — the shape already proven at `sub_process.ex:179-185`:

- payload → `%{K => incoming_variables[K]}`
- schema → `%{"type" => "object", "properties" => %{K => schemas[K]}, "required" => [K]}`

**This replaces `req049-variable-merge.md` §7.1's `{"value" => <raw>}` wrapper convention**, which is
superseded (§12). Using the variable's own key as the wrapper key rather than a fixed `"value"` has a
concrete benefit: the `ValidationFailure.field_path` values that come back read `/amount` rather than
`/value`, so the failure list that reaches the `EXECUTION_ERROR` payload names the real variable.

### 4.4 Result mapping — `JsonSchema.validate/2` → `validation_outcome()`

This is the REQ-109 replacement for `req049-variable-merge.md` §7.2's table.

PROVENANCE (historical, not current decision authority):
| `JsonSchema.validate/2` result | `validation_outcome()` | Rationale |
|---|---|---|
| `[]` | `:ok` | Schema-compatible (REQ-049 AC2) |
| `[_ \| _] = failures` | `{:rejected, failures}` | REQ-049 AC3's rejection; `failures` reused **verbatim**, no re-wrapping — it is already `[ValidationFailure.t()]`, exactly what `variable_merge.ex:96-98`'s `execution_error_event()` and `ExecutionError` consume |
| *no row for `K`* | key **omitted** from the map | §4.2 step 1. This replaces §7.2's `{:error, :unknown_event_type} -> :ok` row, which no longer applies: "not registered" is now "no row for that `variable_key`", not an event-type miss |
| *stored schema not a map* | key **omitted** from the map | §6.3 — a Letflow-specific defensive rule, with a related (narrower) R-Co precedent at `instance.zig:2426-2428` |

**The table has exactly four rows, and none of them is unresolved.** `req049` §7.2's two unresolved rows
(`{:error, :tenant_not_provisioned}` and `{:error, term()}`) **dissolve** rather than merely re-mapping:
`JsonSchema.validate/2` is pure, performs no `get_type/2` lookup and no tenant resolution, so neither
error surface exists at all. That **closes `req049-variable-merge.md` §13.2** (§12).

### 4.5 `variable_validations/5` — the composed entry point the engine calls

```
@spec variable_validations(
        repo :: module(),
        definition_id :: Ecto.UUID.t() | nil,
        current_variables :: map(),
        incoming_variables :: map(),
        opts :: [prefix: String.t() | nil]
      ) :: {:ok, Letflow.Engine.VariableMerge.variable_validations()} | {:error, error_reason()}
```

Behaviour, in order:

1. **Validate `opts[:prefix]`** — `{:error, :missing_prefix}` on nil, non-binary or `""`, **before any
   other work and before any query** (§6.1, AC7).
2. **Compute overwrite candidates**: keys present in **both** `current_variables` and
   `incoming_variables`. Formally `Map.keys(incoming_variables)` filtered by
   `Map.has_key?(current_variables, K)` — the same `overwrite_keys` partition
   `req049-variable-merge.md` §3.1 step 2 defines, recomputed here because `merge/3` does not expose it.
PROVENANCE (historical, not current decision authority):
3. **Fast path**: if the candidate list is empty → `{:ok, %{}}`, **no query issued**. This is R-Co's own
   `if (output_variables.count() == 0)` fast path (`instance.zig:2331`) generalised to "nothing to
   validate." It runs *after* step 1, so AC7's fail-closed test still gets `{:error, :missing_prefix}`
   even with an empty candidate set.
4. `fetch_schemas/3` (§4.1). Propagate `{:error, reason}` unchanged.
5. `validations_for/3` (§4.2) over the candidate list. Return `{:ok, map}`.

**Overwrite-candidates-only is preserved, deliberately (AC5).** A brand-new key — absent from
`current_variables` — is **never validated**, even when a `variable_schemas` row exists for that exact
key. This is `req049-variable-merge.md` §3.1 step 3's rule and §8 step 2's call sequence, and AC5 pins it
with an explicit test. **It diverges from R-Co**, which validates every key that has a schema regardless
of collision — see OQ-1 (§11.1). This design follows the acceptance criterion, and flags the divergence
rather than silently re-deciding it.

---

## 5. The call-site change at `lib/letflow/engine.ex` (AC3, AC4, AC5, AC6)

### 5.1 What changes, precisely

`merge_output_variables/5` (`engine.ex:1536-1560`) today calls
`VariableMerge.merge(current_variables, output_variables, nil)` at **line 1543**. That `nil` becomes the
map §4.5 returns.

To get there the function needs `repo` and `prefix`, neither of which it currently takes:

- **`repo`** — `Ecto.Multi.run/3` already hands it to the `:merge` step function, which today discards it
  as `_repo` (`engine.ex:1276`). Bind it and thread it in.
- **`prefix`** — already a closure variable of `run_complete_task/6` (`engine.ex:1266-1272`), used by the
  sibling `:task`, `:instance_projection`, `:snapshot_and_state` and `:transition` steps. Thread it in
  the same way.

`merge_output_variables/5` therefore becomes `merge_output_variables/7`
(`projection, actor_id, idempotency_key, current_variables, output_variables, repo, prefix`). Its `@spec`
widens correspondingly. Its existing two return branches — `{:ok, {:merged, …}}` and
`{:ok, {:execution_error, error_args}}` — are **unchanged**, and one new branch is added (§5.3).

**`definition_id` needs no new plumbing**: it is `projection.definition_id`, and `projection` is already
this function's first argument and the already-locked row from the `:instance_projection` step
(`instance_projection.ex:113`).

**Stale `/5` references the arity change leaves behind — owner named so this does not fall through.**
Three artefacts refer to the function as `merge_output_variables/5` and become imprecise once it is `/7`:
REQ-109's own description and AC-adjacent text in `docs/requirements.yaml`; `docs/issues/ISS-0063.yaml`;
and GH#212. **No acceptance criterion requires fixing any of them, and ELIXIR-DEV must not widen scope to
do it.** They are assigned to **DOC-UPDATER**, in the same pass that flips REQ-109's status and closes
ISS-0063/GH#212 — that pass already edits all three files, so the correction costs one word each. The
substance (which call site, which argument) is unambiguous either way; this is precision, not a defect.

### 5.2 The resulting sequence — `req049` §8's five steps, now all reachable

Mapping this design onto `req049-variable-merge.md` §8's numbered call sequence:

| §8 step | Owner after REQ-109 |
|---|---|
| 1. Caller has `current_variables` and `incoming_variables` | `seed_state.variables` and `output_variables` — unchanged, already so today (`engine.ex:1284-1289`) |
| 2. For each key present in **both** maps, resolve the schema and validate; keys with no schema are omitted | **NEW: `VariableSchema.variable_validations/5`** (§4.5). Replaces §8 step 2's `validate_payload/3` + §7.1 wrapper with §4.3's direct `JsonSchema.validate/2` + `%{K => value}` wrapper |
| 3. Call `VariableMerge.merge/3` | `engine.ex:1543` — same call, real map instead of `nil` |
| 4. On `{:ok, new_variables, events}` | Unchanged. Already built and reachable (`engine.ex:1544-1545` → the existing `VARIABLE_OVERWRITTEN` append path) |
| 5. **On `{:rejected, unchanged_variables, [execution_error_event]}`** | Already built by REQ-061 (`engine.ex:1547-1560` → `ExecutionError.append_multi/3`), **and reachable for the first time as of this requirement.** This is the whole point of REQ-109 |

**Do not stop at step 4.** Step 5 is the branch ISS-0063 recorded as unreachable.

### 5.3 The new error branch, and how it fails closed

A `{:error, reason}` from `variable_validations/5` must **not** be folded into "no schemas." It aborts
the `Ecto.Multi`:

```
{:error, {:variable_schema_lookup_failed, VariableSchema.error_reason()}}
```

added to `complete_task/3`'s `complete_error()` union (`engine.ex:1150-1170`). Nothing is written; the
transaction rolls back; the task stays `pending` and the instance stays `active`. This is distinct from
`{:error, {:instance_execution_error, …}}`, which is a *business* outcome that commits an ERROR tail — a
scoping fault is not a business outcome and must not be recorded as one.

Note this differs in kind from the two `{:execution_error, _}` routings that already exist in this
function: those exist because REQ-061 needs the ERROR-transition tail to *commit*
(`req061` §5.3). A missing prefix has no tenant to commit into, so aborting is the only fail-closed
answer available.

### 5.4 What does **not** change

PROVENANCE (historical, not current decision authority):
- `VariableMerge.merge/3` — untouched. Its two-phase validate-all-then-apply semantic
  (`variable_merge.ex:14-20`, `req049` §3.2) is already implemented and is **not** re-implemented in the
  caller. R-Co's `instance.zig:2300-2304` is the source it ports.
- The `{:rejected, …}` → `ExecutionError.error_args()` construction at `engine.ex:1547-1560` — untouched.
- `dispatch_task_completion_hop_chain/6`'s `{:execution_error, _}` pass-through clause — untouched.
- The first-failure-wins ordering (`req049` §3.3) — a `merge/3` property, not touched here.
- The `:transition`, `:task`, `:snapshot_and_state` Multi steps — untouched.

---

## 6. Failure modes

### 6.1 Missing, nil or empty prefix — must fail closed (AC7, INV-1)

```
{:error, :missing_prefix}
```

A distinct, pattern-matchable atom, returned with **zero queries issued** — the check runs before the
query is even constructed (§4.5 step 1). Precedent, followed exactly:
`lua_script_audit.ex:152-158` and `snapshot_store.ex:157`, both of which state the reason in prose worth
restating here: unlike `Repo.all(query, prefix: nil)`, which silently resolves to Ecto's **default
schema** (`public`), an explicit guard fails loudly. Under INV-1 a `variable_schemas` read that lands in
`public` is not merely wrong, it is a cross-tenant read of whatever happens to be there. There is no
`public`-schema fallback and no default.

`""` is rejected alongside `nil` and non-binaries: an empty prefix is not a schema name, and passing it
through would produce either a bare unqualified table reference or a syntax error, neither of which is
fail-closed.

### 6.2 No rows for the definition (AC5, first half)

`fetch_schemas/3` returns `{:ok, %{}}`. `validations_for/3` returns `%{}`. `merge/3` receives `%{}`,
whose every key defaults to `:ok` (`find_rejection/2`'s `Map.get(validations, key, :ok)`,
`variable_merge.ex:186`; documented at the `variable_validations` typedoc, `variable_merge.ex:110-117`). Every overwrite candidate merges
untouched, `VARIABLE_OVERWRITTEN` events are appended as usual, no `EXECUTION_ERROR`. **This is the
behaviour that holds today with `nil`** — REQ-109 must not regress it, which is why AC5 tests it
explicitly. `nil` and `%{}` are equivalent inputs to `merge/3` by that module's own contract.

Corollary worth stating for whoever reads this after REQ-078/REQ-082: **until a registration path
exists, the table is empty in production and this is the only branch that fires.** REQ-109's own
acceptance criteria therefore seed rows directly via `Repo.insert` against a provisioned tenant schema.

### 6.3 Malformed stored `json_schema` (no AC, designed anyway)

The column is `NOT NULL` jsonb, so it always decodes to *some* JSON value — but jsonb permits an array,
string, number, boolean or `null`, none of which satisfy `JsonSchema.validate/2`'s
`when is_map(schema)` guard. Calling it with a non-map schema would raise `FunctionClauseError` **inside
an open transaction on the task-completion hot path**, turning one bad registration row into a hard
failure of every completion for that definition.

**Rule: a stored `json_schema` that is not a map is treated as no constraint — the key is omitted from
`variable_validations` (§4.2 step 2), exactly as if no row existed.**

PROVENANCE (historical, not current decision authority):
**This is a Letflow-specific defensive rule with a related — but strictly narrower — R-Co precedent, not
a literal port. Stated precisely so nobody over-claims the citation:** `instance.zig:2426-2428`'s
"Unparseable schema string → treat as no constraint" is the `else` arm of `std.json.parseFromSlice`, so
it fires **only when the stored text fails to parse as JSON at all**. A jsonb array, string or number
parses fine in R-Co and is handed to `json_schema.validate` as-is; R-Co's fallback never sees it. Letflow's
rule covers a wider class ("parsed, but not an object") because Letflow's constraint is different:
`JsonSchema.validate/2`'s `when is_map(schema)` guard turns that wider class into a raise, which R-Co's
untyped path does not have. The R-Co line is cited as the source system's *disposition* for an unusable
stored schema — tolerate and skip, do not fail the merge — which is the part being ported.

This is permissive by design and the permissiveness belongs at the *registration* end, not here — which
is why §3.2's changeset gap is flagged as OQ-3. It is not silent: ELIXIR-DEV should emit a `Logger.warning`
naming `definition_id` and `variable_key` so a bad row is discoverable, and **must not** log the schema
document or the variable's value (tenant data).

A `json_schema` that *is* a map but is not a valid JSON Schema document is `JsonSchema.validate/2`'s own
problem, handled by whatever that module already does with unknown keywords — out of scope here.

### 6.4 `definition_id` nil or not UUID-shaped

`instance_projection.ex:113` types `definition_id` as a plain nullable `Ecto.UUID` field, so a `nil` is
representable. `{:error, :invalid_definition_id}`, no query issued, routed as §5.3. Defensive rather than
expected (every instance `Engine.create/2` produces carries one), and it guards the same
`Ecto.Query.CastError`-in-a-`where` class that `engine.ex:1248-1253`'s `cast_task_id/1` already guards.

---

## 7. Tenant isolation (AC6, INV-1)

`variable_schemas` is a tenant-data path. The obligations:

1. **The table lives in the tenant schema**, not `public` (§2.3).
2. **Every read carries an explicit `prefix:`** — `repo.all(query, prefix: prefix)` in §4.1, with the
   prefix flowing from `complete_task/3`'s `opts[:prefix]` through `run_complete_task/6`'s closure,
   which `complete_task/3` has already resolved via
   `TenantProvisioning.tenant_id_for_schema_name(prefix)` (`engine.ex:1221`).
3. **A missing/nil/empty prefix fails closed** with zero queries (§6.1).
4. **No string interpolation** anywhere in the query (§4.1).
5. **The read is inside the same transaction and on the same `repo`** as the already-locked projection,
   so it cannot observe a different tenant's connection state.

AC6's test shape is the sharpest statement of the invariant: the *identical*
`(definition_id, variable_key, violating value)` completion is **rejected in tenant A and succeeds in
tenant B**, because A's schema has the row and B's does not. If that test passes in B, either the prefix
is being honoured or the table is empty in both — which is why AC6 requires both tenants provisioned and
A seeded.

Note that `definition_id` values are not themselves tenant-scoped identifiers; isolation comes entirely
from the schema prefix, not from the id. A `definition_id` guessed or replayed from tenant A finds
nothing in tenant B's schema.

---

## 8. In-place moduledoc corrections in `lib/letflow/engine/variable_merge.ex` (AC9, closes ISS-0075 / GH#296)

**Four** corrections, all in `variable_merge.ex` itself — AC9's three (§8.1, §8.2, §8.3) plus one this
design adds beyond AC9's literal enumeration (§8.4, line 106) because REQ-109 forbids leaving such text
stale and no other requirement owns it. AC9 requires each of its three to be verified by reading *that*
file directly, not inferred from `engine.ex`.

**All four are corrections IN PLACE. Nothing is deleted.** §13.1–13.3 state why the module's own purity
grep must not be used as the check on this section, and forbid deleting any of these lines to make that
grep pass.

### 8.1 Lines 24–29 — REQ-109's own supersession (AC9a)

Today: "`variable_validations` is a map of already-computed per-key outcomes the caller resolves … by
calling `Letflow.EventStore.Registry.validate_payload/3` (REQ-024) before invoking `merge/3`, not a
second JSON Schema implementation."

That sentence **is REQ-049 AC4's own required evidence artifact**, and it becomes **false about shipped
code** the moment REQ-109 lands. It must be **corrected in place**, not deleted: the caller is
`Letflow.Engine.VariableSchema` (REQ-109), which calls `JsonSchema.validate/2` directly. The **substance
must be preserved**: still not a second JSON Schema implementation — `JsonSchema.validate/2` is
`validate_payload/3`'s own internal delegate (`registry.ex:147`), and `validate_payload/3` itself is
bypassed because it is bound to the `event_type_registry` lookups §1.1 decided against. The corrected
text must no longer name `validate_payload/3` as the caller's mechanism, and must cite REQ-109's
rationale.

*ISS-0075 explicitly excludes this sentence — it is REQ-109's own supersession item, not an ISS-0075
claim. Both land in the same edit pass.*

### 8.2 Lines 31–46, "Dependency ordering" — ISS-0075 claim 1 (AC9b)

Today: REQ-061 "is `status: pending` and unimplemented as of this module's own implementation."
REQ-061 is `done`. Restate **in the past tense as the condition that held at this module's
implementation time**. **The surrounding rationale is correct and must be preserved, not deleted:**
`VariableMerge` does not and should not depend on REQ-061; a rejected batch is signalled purely through
`merge/3`'s own `{:rejected, …}` return value, which the caller inspects. That is still exactly how the
now-reachable path works (§5.2 step 5), and REQ-109 is the proof.

### 8.3 Lines 18–20 — ISS-0075 claim 2 (AC9c)

PROVENANCE (historical, not current decision authority):
Today: §3.2's abort-the-entire-batch semantic is "a reasoned reconstruction, not verified against
`instance.zig`'s literal source, since no R-Co source tree is reachable in this environment."

PROVENANCE (historical, not current decision authority):
The tree **is** reachable and **the reconstruction was correct**. **Replace** the caveat with a
**positive citation** — not merely delete it. `instance.zig:2300-2304` documents the ISS-202 two-phase
merge verbatim: "Phase 1: Validate ALL output variables … with NO state change. On any failure, return
early with violation. Phase 2: Apply all validated keys … only if Phase 1 succeeds. On failure, leave
variables untouched." Confirmed by direct read this session, and by the code beneath it
(`:2395` "Phase 1 succeeded", `:2470` `PHASE 2: APPLICATION`).

Replacing rather than deleting is what upgrades a documented guess into a verified port — and REQ-109 is
what makes that semantic observable in production for the first time. Landing 8.2 and 8.3 closes
ISS-0075 / GH#296.

### 8.4 Line 106, the `validation_outcome()` typedoc — a FOURTH in-place correction

**Beyond AC9's literal three counts, and required anyway.**

`variable_merge.ex:100-107`'s `@typedoc` for `validation_outcome()` ends: "this outcome is resolved by
the caller, **typically by wrapping a call to `Letflow.EventStore.Registry.validate_payload/3`
(REQ-024)**." That is stale about shipped code in exactly the way lines 24–29 are: after REQ-109 the
one real caller is `Letflow.Engine.VariableSchema`, which calls `JsonSchema.validate/2` directly and
never touches `validate_payload/3`.

It is softer than lines 24–29 ("typically", not an assertion about the caller's obligation), which is
presumably why neither AC9 nor ISS-0075 enumerates it — but it still names the wrong mechanism, and
REQ-109's description is explicit that such text must not be left "stale for REVIEWER's
decision-record-consistency check to catch." **Assigning it to nobody is not an option, so this design
assigns it here.**

**Correct in place, same rule as §8.1: not deleted.** Replace the `validate_payload/3` clause with the
real mechanism (`Letflow.Engine.VariableSchema`, REQ-109, via `JsonSchema.validate/2`). The rest of the
typedoc — that `:ok` covers both an explicit `:ok` and "no schema registered for this key," and that an
absent entry defaults to `:ok` — is **correct and must be preserved**; §4.2's omission rule depends on
it.

Landing this leaves `variable_merge.ex` with zero remaining statements that misdescribe the caller's
mechanism.

### 8.5 `lib/letflow/engine.ex`'s moduledoc (AC8, AC11)

Separate file, separate obligations. Three statements, all in `engine.ex`:

1. **The former hardcoded `nil` at line 1543 was design-sanctioned, not a defect** —
   `req049-variable-merge.md` §7.3 states outright that "until that requirement exists, every real
   caller of `merge/3` legitimately passes `variable_validations: nil`." REQ-109 **is** that
   requirement. Stating this is what stops it being re-filed as a regression a third time.
2. **Why `JsonSchema.validate/2` rather than REQ-024's `validate_payload/3`** (§4.3), **that
   `req049-variable-merge.md` §7.1 and §7.2 are superseded** (the `{"value" => …}` wrapper shape; the
   `:unknown_event_type` row), and **that §13.2's open question is CLOSED** because the pure delegate has
   no tenant-resolution error surface (§4.4).
3. **The REQ-059 pinning-vs-live-read open question, with its latency reasoning** — OQ-2 (§11.2).

Storage-side rationale goes in `Letflow.Engine.VariableSchema` (§3.4); engine-side rationale goes in
`Letflow.Engine`. AC8/AC10/AC11 verify them in their own files, so putting the wrong item in the wrong
file fails the gate even though the words exist somewhere.

---

## 9. Explicitly deferred, explicitly named

### 9.1 The registration (INSERT) path — REQ-078 and REQ-082

PROVENANCE (historical, not current decision authority):
REQ-109 builds the table, the Ecto schema, the lookup and the wiring. It builds **no path that writes a
`variable_schemas` row.** R-Co scoped it identically: variable schemas are "created during process
definition loading (existing mechanism, not part of ISS-202)"
(`R-Co src/design/engine-merge.md:173`), with the actual writes in
`R-Co src/api/routes/solution_packs.zig:299` (solution-pack install) and
`R-Co src/definition/fixture_loader.zig:32`.

Those map onto two already-pending S4 requirements, whose descriptions REQ-109 has already amended to
carry the obligation (confirmed in `docs/requirements.yaml` at 4341–4360 and 4522–4540, and both now
carry `REQ-109` in `depends_on`):

PROVENANCE (historical, not current decision authority):
- **REQ-078** — `solution_packs.zig` `handleInstall` (L110).
PROVENANCE (historical, not current decision authority):
- **REQ-082** — `definitions.zig` `handleImport` (L1126), plus `handleCreate`/`handlePut` where the
  submitted document carries them.

**One shared path, not two.** The registration logic lives in a **single** function on REQ-030's
`Letflow.Definitions`, called by both. Whichever lands first builds it; the second calls it and adds no
second implementation. Rows are scoped to the `definition_id` being written, so disjoint definitions
cannot collide; a re-import onto the **same** `definition_id` must **replace** that definition's rows
inside the same transaction rather than accumulate duplicates against the unique constraint.

**Consequence if this is dropped: the table ships empty and REQ-061's rejection branch stays exactly as
unreachable as it is today** — the entire failure mode REQ-109 exists to fix.

### 9.2 The two other waiting consumers — behaviour unchanged

Wiring either turns this into three requirements. Both are named in
`Letflow.Engine.VariableSchema`'s moduledoc (§3.4 item 4) as known remaining consumers, with correct
descriptions:

- `lib/letflow/definitions/promotion_plan.ex:195-196` — `default_variable_schema_fetcher/2`, returns
  `nil`.
- `lib/letflow/engine/pin_resolver.ex:262-263` (REQ-059) — `default_lookup/0`'s
  `variable_schema_lookup`, returns `{:ok, %{version: "unversioned", json_schema: nil}}` — **a populated
  tuple whose `json_schema` is nil, not a nil return.**

### 9.3 The one permitted edit — `promotion_plan.ex:191` (AC13)

The comment at line 191 currently reads "there is no `variable_schemas` table or
`process_definitions` column in Letflow today (design §9.3)". The first half becomes **false** the moment
§2's migration lands. It must be corrected to cite REQ-109 (the table now exists; this fetcher is simply
not wired to it, and wiring it is out of REQ-109's scope). The second half — no `process_definitions`
column — remains true and should be preserved.

**This is a comment edit, not wiring.** `default_variable_schema_fetcher/2`'s return value stays `nil`,
its `@spec` stays `:: nil`, and AC13 verifies both by reading the function back.

---

## 10. `docs/migration/stage-3-instance-engine.md` (AC12)

Line 3 currently reads `Status: done -- all Stage 3 requirements shipped, REQ-060 (last pending) merged
2026-08-19.` REQ-109 is S3 and pending, so that line is false the moment REQ-109 exists — not only when
it lands. Two edits:

1. The `Status:` line no longer claims all Stage 3 requirements shipped.
2. The stage's requirement list gains a REQ-109 entry, in the same format its siblings use.

AC12 verifies both by reading the file. Note REQ-110 is also S3 and pending; whoever lands first owns
the `Status:` line and the second should find it already correct.

---

## 11. Open questions — flagged, not resolved

### 11.1 OQ-1 — Overwrite-candidates-only diverges from R-Co, which validates every key

**RESOLVED 2026-08-20 — `docs/migration/decisions/0007-variable-merge-validates-new-keys.md`
(GH#300/ISS-0077). Answer: port-fidelity defect, not an intentional simplification — adopted
R-Co's semantic (validate every key).** No recorded rationale ever justified the divergence
(the paragraph below states the rule but argues no reason for it beyond "AC5 says so"), no
production traffic existed to protect (pre-S8, `docs/migration/decisions/0004-humanless-pipeline.md`),
and the divergence is a real validation bypass on exactly the write most likely to be wrong. See
the decision record for the full reasoning. `req049-variable-merge.md` §3.1,
`docs/requirements.yaml` REQ-109's AC5, and this document's own AC5/INV-VS-3 rows below are
corrected accordingly; the paragraph immediately following is preserved as the record of what
was originally decided and why it was reopened.

**Status (as originally written, preserved for history): this design follows the acceptance
criterion; the divergence is flagged for REVIEWER.**

`req049-variable-merge.md` §3.1 step 3 and §8 step 2 restrict validation to **overwrite candidates**, and
REQ-109's AC5 pins that with an explicit test ("a brand-new key … whose value would violate a seeded
schema for that same key is **still inserted unvalidated**"). §4.5 step 2 implements exactly that.

PROVENANCE (historical, not current decision authority):
**R-Co does not do this.** Confirmed by direct read this session: `mergeVariables`'s Phase 1
(`instance.zig:2390-2430`) iterates **every** key of `output_variables`, checks `schema_map.get(key)`
first, and only *afterwards* — at `:2432`, under a separate `if (current_vars.get(key))` — does
collision detection. Schema validation is unconditional on collision; the collision check governs only
whether a `VARIABLE_OVERWRITTEN` event is recorded. So in R-Co a brand-new key with a registered schema
**is** validated and **can** produce a `SCHEMA_VIOLATION`; in Letflow it cannot.

**Consequences if left as designed:** a definition can declare a schema for a variable, and the very
first write of that variable — the one most likely to be wrong — escapes it. Every subsequent write is
checked. That is a strange contract to explain to a process author, and it means "registered a schema
for `amount`" does not mean "`amount` is always valid."

PROVENANCE (historical, not current decision authority):
**Why this design does not resolve it:** AC5 is explicit and REQ-049 §3.1 is gate-approved shipped
behaviour in `variable_merge.ex`. Changing it would alter `merge/3`, which REQ-109's own description
forbids ("do not re-implement it in the caller"), and would fail AC5. **REVIEWER should decide whether
this is an intentional Letflow simplification or a port-fidelity defect worth its own requirement.**
REQ-049 §12.1 already flagged the same rule as unverified against `instance.zig` — this design supplies
the verification it asked for, and the answer is that it differs.

### 11.2 OQ-2 — Live merge-time read vs. REQ-059's start-time `:variable_schema` pin

**Status: carried forward from REQ-109's own description. Do not re-decide it here.**

REQ-059 (PIN-01/PIN-03, `done`) freezes exactly one `:variable_schema` pin per instance at start and
forbids substituting a current version for a pinned one, so that "a newer catalog version published
mid-flight does not affect an in-flight instance." A merge-time **live** read of `variable_schemas`
(§4.1) can expose an in-flight instance to a schema edited after it started.

PROVENANCE (historical, not current decision authority):
**R-Co does both**: the live read at merge (`instance.zig:2318`) and a digest pinned at start
(`pin_resolver.zig:428`/`:490`). **REQ-109 ports the live read** and routes the tension to REVIEWER.

**The conflict is LATENT, not live**, for three independent reasons, all of which must be recorded in
`lib/letflow/engine.ex`'s moduledoc (AC11) so REVIEWER disposes of it in one pass instead of
re-deriving it:

1. `default_lookup/0` returns `json_schema: nil` (`pin_resolver.ex:262-263`), so the one
   `:variable_schema` pin every instance records today carries **no schema content** — nothing
   meaningful is pinned, so nothing can be contradicted.
2. REQ-059 AC5's no-fallback guarantee is scoped to `PinResolver`, which this requirement does not touch.
3. The conflict activates only when `pin_resolver.ex`'s lookup is wired to the real table, which this
   requirement explicitly defers (§9.2).

No `docs/migration/decisions/` record is being re-decided — none of the six covers variable schemas. **If
REVIEWER judges this a live conflict with REQ-059, it goes to a decision record, not into this
requirement's code.**

### 11.3 OQ-3 — Nothing validates that a stored `json_schema` is a well-formed JSON Schema

§3.2's changeset requires `json_schema` to be present but does not check that it is a usable schema
document, and the column is jsonb, which accepts arrays, strings, numbers and booleans. §6.3 handles the
read side defensively (treat as no constraint, §6.3), which is correct for
the hot path but means a bad registration **silently validates nothing**.

**Unresolved: where the well-formedness check belongs.** Candidates: the shared `Letflow.Definitions`
registration function (§9.1), so a bad schema is rejected at import/install time with a useful error; or
a stricter changeset validation here. This design does not choose, because the registration path does not
exist yet and REQ-109 must not build it. **Flagged for whichever of REQ-078/REQ-082 lands first** — it
must not assume §3.2's changeset already guarantees this.

### 11.4 OQ-4 — Error-type naming: R-Co's `SCHEMA_VIOLATION` vs Letflow's `:variable_schema_rejected`

**Status: recorded for REVIEWER. Not this requirement's to change.**

PROVENANCE (historical, not current decision authority):
R-Co's error-code table — a 10-variant `error_type_str` switch beginning at
`R-Co/src/engine/instance.zig:4060`, with `.SCHEMA_VIOLATION => "SCHEMA_VIOLATION"` at `:4062`
(confirmed by direct read this session) — names this variant **`SCHEMA_VIOLATION`**. Letflow uses
**`error_type: :variable_schema_rejected`** (`lib/letflow/engine.ex:1548`, and
`variable_merge.ex:98`'s `reason :: :variable_schema_rejected`).

PROVENANCE (historical, not current decision authority):
**Provenance of the divergence:** `lib/letflow/engine/execution_error.ex:5` cites R-Co's
`setInstanceError()` at `~L3078` and its error-code table at `~L4067`, marking both approximate because
R-Co was believed unreachable when REQ-061 was written. R-Co **is** reachable and **both citations are
exact**: `setInstanceError` is at `instance.zig:3078`, and the table begins at `:4060`, so `~L4067` lands
inside it.

**Why it reaches this design:** REQ-109 is what makes `:variable_schema_rejected` reachable through
`complete_task/3`, so this is the first time that error type sits on a live end-to-end path.

**Not resolved here, in either direction.** Renaming a shipped error type is REQ-061's business and would
be scope creep on a gate-passed requirement; asserting Letflow's name is correct would be a silent
re-decision. Recorded so the next person to touch REQ-061's error-code vocabulary finds the discrepancy
documented rather than rediscovering it.

**One consequence worth REVIEWER's attention:** the engine-internal atom is a free choice, but any
consumer that pattern-matches the error-type *string* — an API response shape (S4 routes), a UI mapping
in `web/` — would see Letflow's name, not R-Co's. A migration-fidelity question therefore exists at the
**API boundary** even though it does not exist inside the engine. If S4's instance/task routes are meant
to be response-compatible with R-Co's, this needs an answer before those routes ship.

### 11.5 OQ-5 — `description` has no reader

The `description` column is ported because REQ-109's AC2 names it and R-Co has it, but nothing in
Letflow reads it: not `merge/3`, not the `EXECUTION_ERROR` payload, not any route (none exist yet). It is
presumably intended for an authoring UI or an error message. Ported for fidelity; noted so nobody assumes
it feeds the rejection message. If an S4 route or the `EXECUTION_ERROR` payload should surface it, that
is a later requirement's call.

---

## 12. Which REQ-049 design artefacts this requirement supersedes or closes

Tracked explicitly so REVIEWER's decision-record-consistency check has a single list, and so nothing is
left dangling. **`req049-variable-merge.md` is not edited by this requirement** (it is a shipped,
gate-approved design record); the supersessions are recorded in `engine.ex`'s and `variable_merge.ex`'s
moduledocs, which is what AC8 and AC9 verify.

PROVENANCE (historical, not current decision authority):
| REQ-049 artefact | Disposition | Where recorded |
|---|---|---|
| §7.1 `{"value" => <raw>}` wrapper convention | **Superseded** by §4.3's `%{K => value}` / `%{"type" => "object", "properties" => %{K => schema}, "required" => [K]}`, the shape already proven at `sub_process.ex:179-185` | `engine.ex` moduledoc (AC8) |
| §7.2 row `{:error, :unknown_event_type} -> :ok` | **Superseded** — "not registered" is now "no row for that `variable_key`", and the key is omitted rather than mapped (§4.4) | `engine.ex` moduledoc (AC8) |
| §7.2's two unresolved rows (`:tenant_not_provisioned`, `{:error, term()}`) | **Dissolved** — `JsonSchema.validate/2` is pure, does no `get_type/2` and no tenant resolution, so neither error surface exists (§4.4) | `engine.ex` moduledoc (AC8) |
| §7.3 "dedicated table or `event_type_registry`?" | **CLOSED** — dedicated table (§1.1) | `VariableSchema` moduledoc (AC10) |
| §7.3 "every real caller legitimately passes `nil`" | **No longer applies** — REQ-109 is the requirement it was waiting for. The historical `nil` was design-sanctioned, not a defect (§8.5 item 1) | `engine.ex` moduledoc (AC11) |
| §13.1 "where a registered variable schema is stored and looked up" | **CLOSED** by §2 + §4 | `VariableSchema` moduledoc (AC10) |
| §13.2 `validate_payload/3`'s `:tenant_not_provisioned` / unexpected-error cases | **CLOSED**, not merely re-mapped — the pure delegate has no such error surface (§4.4) | `engine.ex` moduledoc (AC8) |
| §13.3 whole-batch atomicity, "reconstructed, not verified" | **VERIFIED CORRECT** against `instance.zig:2300-2304` (§8.3) | `variable_merge.ex` moduledoc, AC9c |
| §3.1 step 3's overwrite-candidates-only rule (§12.1 flagged it unverified) | **VERIFIED, differed from R-Co, and RESOLVED 2026-08-20** — adopted R-Co's semantic (validate every key), decision 0007 | OQ-1 (§11.1) |
| §13.4 first-failure-wins ordering | **Untouched.** A `merge/3` property; REQ-109 does not exercise multi-key rejection ordering | — |
| §13.5 `VARIABLE_OVERWRITTEN`/`EXECUTION_ERROR` event-type registration prerequisite | **Untouched, and now load-bearing.** Both event types must be registered for AC3/AC4's appends to succeed. Already satisfied on the shipped path (REQ-047/REQ-061 exercise it today); named so TEST-DESIGNER's fixtures do not assume it silently | — |

---

## 13. Cross-module dependencies

**New module `Letflow.Engine.VariableSchema` depends on:**

- `Letflow.Repo` — only via the `repo` argument passed in (§4.1); no `alias Letflow.Repo`, so the
  transaction's connection is always used.
- `Ecto.Schema`, `Ecto.Changeset`, `Ecto.Query`.
- `Letflow.EventStore.Registry.JsonSchema` (REQ-024, `done`) — `validate/2` only. Not
  `Registry.validate_payload/3`, not `Registry.get_type/2` (§4.3).
- `Letflow.EventStore.Registry.ValidationFailure` (REQ-024, `done`) — for the `[ValidationFailure.t()]`
  type in `validation_outcome()`; never constructed here, only passed through verbatim.
- `Letflow.Engine.VariableMerge` (REQ-049, `done`) — for the `variable_validations()` type only. **No
  call to `merge/3`.** `VariableSchema` produces `merge/3`'s input; it never invokes it.

**`Letflow.Engine` gains** a dependency on `Letflow.Engine.VariableSchema`. Nothing else changes.

**`Letflow.Engine.VariableMerge` gains no dependency.** Its purity contract
(`variable_merge.ex:48-66`) must still hold after the §8 moduledoc edits. That contract is stated
correctly at line 56 — no `Repo` I/O, no `alias Letflow.Repo`, no `import Ecto.Query`, no
`Ecto.Changeset`, no call to `Registry.validate_payload/3` or `.get_type/2` — and it remains true
after REQ-109, because REQ-109 adds no call site to `variable_merge.ex` at all.

### 13.1 The module's own self-check grep does NOT return zero today — corrected baseline

The moduledoc at `variable_merge.ex:59-66` claims its grep "must return zero matches." **It does not,
and has not since the module shipped — independent of REQ-109.** Run this session against the current
working tree, the grep at line 63 returns **four** matches:

| Line | Match | Disposition |
|---|---|---|
| 26 | `Letflow.EventStore.Registry.validate_payload/3` in the lines 24–29 caller-mechanism paragraph | **Prose. Stays** — corrected in place per §8.1, never deleted. This is REQ-049 AC4's own evidence artifact |
| 56 | `Letflow.EventStore.Registry.validate_payload/3 or .get_type/2` in the Purity section | **Prose. Stays unchanged.** It is the purity *statement itself* — legitimate documentation that necessarily names the functions it promises are absent |
| 63 | the grep pattern string in the fenced block, matching itself | **Stays.** A self-matching pattern; nothing to fix here |
| 106 | `Letflow.EventStore.Registry.validate_payload/3` in the `validation_outcome()` typedoc | **Prose. Stays, corrected in place** per §8.4 |

**Every one of the four is documentation prose or the pattern itself. None is an executable call site.**
The grep is a blunt textual instrument that cannot distinguish a call from a mention of a call, which is
why its "zero matches" claim was never achievable for a module whose moduledoc discusses the very
functions it abstains from calling.

### 13.2 The actual obligation on ELIXIR-DEV — stated correctly

**The obligation is NOT "make the grep return zero."**

> **After §8's edits, `Letflow.Engine.VariableMerge` must introduce no new `Repo.` or `Registry.*` call
> site, and must remain free of executable I/O — no `alias Letflow.Repo`, no `import Ecto.Query`, no
> `Ecto.Changeset`, no invocation of `Registry.validate_payload/3`, `Registry.get_type/2` or
> `Registry.register_type/2`, no clock read, no `:rand`/`:crypto`. §8's edits are prose-only; `merge/3`'s
> body and every private function beneath it are untouched.**

Verify that by reading the module's `alias`/`import` list and its function bodies, not by counting grep
hits in the moduledoc.

**Do not delete or reword lines 26, 56 or 106 in order to make a grep pass.** Line 26 sits inside the
24–29 block AC9a requires **corrected in place, not deleted**; line 56 is the purity documentation
itself; line 106 is corrected in place by §8.4. Editing any of them to satisfy the measurement would be
`core-directives.md`'s "Never Satisfy a Gate by Editing What It Measures," and for line 26 it would
destroy REQ-049 AC4's evidence artifact — precisely what REQ-109 forbids.

### 13.3 The false self-check claim itself is out of scope here

`variable_merge.ex:59-66`'s "must return zero matches" assertion is factually wrong about shipped code
and predates REQ-109. It is **not** REQ-109's to fix — it is neither an acceptance criterion nor part of
ISS-0075's two claims, and repairing it would mean rewriting a verification recipe that REQ-049's gate
approved. It is being filed as its own issue by ORCH; reference that issue id from §8's edit pass if
one is available at implementation time, but **do not take on fixing it in this run.** §13.1's table
exists so that whoever does fix it finds the true baseline already recorded.

**Table-level FK dependency:** `process_definitions` (REQ-027, `done`), in the same tenant schema.

**Forward dependents:** REQ-078 and REQ-082 (registration, §9.1); eventually `pin_resolver.ex` and
`promotion_plan.ex` (§9.2).

---

## 14. Acceptance-criteria traceability

Every one of REQ-109's 13 acceptance criteria maps to a concrete design element. No "TBD".

| # | Acceptance criterion (abbreviated) | Design element |
|---|---|---|
| AC1 | Migration guarded by `if prefix() do` **and** registered in `@tenant_scoped_migration_manifest`; applies cleanly against a fresh tenant schema | §2 (file/version), **§2.3** (both halves, with the manifest tuple spelled out) |
| AC2 | Table carries `definition_id` (FK), `variable_key`, `json_schema`, `description`, `created_at`; duplicate `(definition_id, variable_key)` rejected by an actual failing insert | **§2.1** (column table), **§2.4** (`uq_variable_schema_definition_key`), §3.1 (matching schema fields) |
| AC3 | Seeded schema + violating value on an overwrite candidate through real `complete_task/3` → value not merged, status ERROR, exactly one `EXECUTION_ERROR` naming the key | **§5.2 step 5** (the newly reachable branch), §4.5 (the map that makes it fire), §4.4 (`{:rejected, failures}` mapping), §5.4 (the existing `ExecutionError.append_multi/3` path is untouched) |
| AC4 | Conforming value → key overwritten, status unchanged, `VARIABLE_OVERWRITTEN` appended, token advances | **§5.2 step 4**, §4.4 row 1 (`[] -> :ok`), §5.4 (transition path untouched) |
| AC5 | Overwrite candidate with **no** row merges untouched, no `EXECUTION_ERROR`. Second clause **superseded 2026-08-20** (OQ-1 §11.1 resolved, decision 0007): a brand-new key with a seeded schema is now validated and rejected on violation, matching R-Co, not "still inserted unvalidated" | **§6.2** (first half), **§4.5 step 2 + §4.2** (second half — now validates every key), OQ-1 §11.1 (resolved) |
| AC6 | Tenant A's row has zero effect in tenant B: identical completion rejected in A, succeeds in B | **§7** (five obligations), §4.1 (`prefix:` on the query), §2.3 (per-tenant table) |
| AC7 | Lookup with missing/nil/empty prefix fails closed, distinct pattern-matchable error, **issues no query** | **§6.1**, §4.5 step 1 (ordering: prefix check precedes the empty-candidate fast path), §3.3 (`:missing_prefix` in the closed `error_reason()` union) |
| AC8 | No new JSON Schema dep; grep shows `JsonSchema.validate/2`; `engine.ex` moduledoc states why not `validate_payload/3`, that §7.1/§7.2 are superseded, and that `req049-variable-merge.md` §13.2 is CLOSED | **§4.3** (validator choice + wrapping), **§4.4** (mapping table), **§8.5 item 2** (what goes in `engine.ex`), **§12** (the supersession list) |
| AC9 | `variable_merge.ex` moduledoc corrected **in place** on three counts (a) lines 24-29, (b) ISS-0075 claim 1, (c) ISS-0075 claim 2 | **§8.1**, **§8.2**, **§8.3** — each states corrected-in-place, what substance is preserved, and what replaces the stale text. **§8.4** adds a fourth in-place correction (line 106) beyond AC9's literal three, with its reason. **§13.1-13.3** record the true purity-grep baseline and forbid deleting any of the four matching lines to satisfy it |
| AC10 | `VariableSchema` moduledoc carries four things: three "schema" concepts; §7.3's dedicated-table resolution; REQ-078/REQ-082 as registration carriers; `promotion_plan.ex` + `pin_resolver.ex` as remaining consumers | **§3.4** (the four-item list, in this file), sourced from **§1**, **§1.1**, **§9.1**, **§9.2** |
| AC11 | `engine.ex` moduledoc states the former `nil` was design-sanctioned by §7.3, and records the REQ-059 tension as an open question with the latency reason | **§8.5 items 1 and 3**, **OQ-2 §11.2** (all three latency reasons) |
| AC12 | `stage-3-instance-engine.md`'s `Status:` no longer claims all S3 shipped; list includes REQ-109 | **§10** (both edits named) |
| AC13 | `promotion_plan.ex:191`'s comment cites REQ-109; `default_variable_schema_fetcher/2` still returns `nil` | **§9.3** (comment-only edit, return value and `@spec` explicitly unchanged) |

### 14.1 Handoff items also addressed

| Handoff item | Design element |
|---|---|
| "the migration and its tenant-scoping" | §2, §2.3 |
| "the `Letflow.Engine.VariableSchema` Ecto schema module" | §3 |
| "the lookup function and its return shape" | §4.1, §4.5 |
| "how the `variable_validations` map is built from `JsonSchema.validate/2` results per §7.2's mapping" | §4.2, §4.3, §4.4 |
| "exactly how `merge_output_variables/5`'s call site changes" | §5.1, §5.2, §5.3, §5.4 |
| "failure modes — no rows, nil/empty prefix, malformed stored schema" | §6.2, §6.1, §6.3 (plus §6.4, `definition_id`) |
| "`req049` §8 has FIVE steps — do not stop at step 4" | §5.2's table, step 5 |
| "say what documentation goes where" | §3.4 (`VariableSchema`), §8.1-8.4 (`variable_merge.ex`), §8.5 (`engine.ex`), §10 (stage doc), §9.3 (`promotion_plan.ex`) |
| "corrections in place, not deleted" | §8's preamble and each of §8.1/§8.2/§8.3/§8.4, reinforced by §13.2's explicit prohibition on deleting any of them to satisfy a grep |
| "carry the REQ-059 open question, do not re-decide it" | OQ-2 §11.2 |
| "note the `SCHEMA_VIOLATION` naming divergence for REVIEWER" | OQ-4 §11.4 |

---

## 15. Invariants this design commits to

| Id | Invariant |
|---|---|
| INV-VS-1 | Every `variable_schemas` read carries an explicit non-empty binary `prefix:`. A missing, nil or empty prefix returns `{:error, :missing_prefix}` and issues **zero** queries. No `public` fallback. (INV-1, AC7) |
| INV-VS-2 | Exactly **one** SELECT on `variable_schemas` per `complete_task/3` call — never one per key. Zero when the overwrite-candidate set is empty. Never a write. |
| INV-VS-3 | **Superseded 2026-08-20** (OQ-1 §11.1 resolved, decision 0007). Every key of `incoming_variables` — new or overwrite alike — appears in the produced `variable_validations` map when a `variable_schemas` row exists for it; only a key with no registered schema is omitted. (Was: only overwrite candidates appeared; a brand-new key never appeared, whatever rows existed.) |
| INV-VS-4 | A key with no row, or with a non-map stored `json_schema`, is **omitted** from the map — never mapped to an explicit outcome, never an error. (§4.2, §6.3) |
| INV-VS-5 | `VariableMerge.merge/3` is not modified, and its validate-all-then-apply two-phase semantic is not re-implemented in the caller. REQ-109 supplies input only. |
| INV-VS-6 | No JSON Schema implementation is added. The only validator invoked is `Letflow.EventStore.Registry.JsonSchema.validate/2`. `mix.exs` gains no dependency. (AC8) |
| INV-VS-7 | REQ-109 executes **no** INSERT, UPDATE or DELETE against `variable_schemas`. (§9.1) |
| INV-VS-8 | `default_variable_schema_fetcher/2` and `default_lookup/0`'s `variable_schema_lookup` return exactly what they return today. Only a comment changes. (§9.2, §9.3, AC13) |
| INV-VS-9 | A lookup failure aborts the `Ecto.Multi` with `{:error, {:variable_schema_lookup_failed, reason}}` — it is never folded into "no schemas" and never recorded as a business `EXECUTION_ERROR`. (§5.3) |
