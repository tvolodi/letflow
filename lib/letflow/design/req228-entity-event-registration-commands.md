# Design: REQ-228 — Entity event registration and record commands (events.zig + commands.zig)

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-228 full entry (owner, scope, the four numbered
  scope items, the NAMED OPEN DESIGN QUESTION, the eight acceptance criteria,
  `depends_on: [REQ-225, REQ-226, REQ-227, REQ-024]`).
- `lib/letflow/entities/definition.ex` (REQ-225) — the `Definition.t()`/
  `field_def()` document shape.
- `lib/letflow/entities/definitions.ex`, `lib/letflow/entities/entity_definition.ex`
  (REQ-226) — the `entity_definitions` persisted-row schema, the
  `Letflow.Entities.Definitions` CRUD context module (`create_definition/2`,
  `get_definition/2`, `activate_definition/4`), and its `prefix ::
  String.t()`-at-call-time tenant-scoping convention.
- `lib/letflow/entities/record/validator.ex` (REQ-227) — `build_record_schema/1`
  and `validate_record_payload/2`, and its moduledoc's explicit statement of
  the inner/outer validation split this design must also state.
- `lib/letflow/event_store/registry.ex` (REQ-024) — `register_type/2`,
  `validate_payload/3`, `get_type/2`; its moduledoc's tenant-resolution
  contract (`tenant_id`, not a raw prefix, resolved internally via
  `Letflow.TenantProvisioning.Registration`).
- `lib/letflow/event_store.ex` (REQ-025/REQ-140) — `append/2`'s full six-step
  `Ecto.Multi` (`active_instance_guard`, `assign_sequence`, `claim_idempotency`,
  `insert_event`, `maybe_store_oversized_payload`, `update_projection`),
  `interpret_transaction_result/1`'s error shapes, and the critical structural
  fact this design turns on: **`append/2` opens and commits its own
  `Repo.transaction/1` internally** — it is not a composable `Ecto.Multi`
  building block a caller can extend with an extra step.
- `lib/letflow/event_store/instance_projection.ex` (REQ-023/REQ-043) — the
  `instance_projections` schema `active_instance_guard/3` reads
  (`repo.get(InstanceProjection, instance_id, ...)`, `{:error,
  :instance_not_started}` when absent) and `update_projection/3` writes.
- `lib/letflow/event_store/instance_sequence.ex` and
  `lib/letflow/event_store/idempotency_record.ex` (REQ-023) — the per-instance
  sequence-lock row and the `event_idempotency` sidecar table, confirmed
  already present in `test/support/tenant_fixture.ex`'s expected-tenant-schema
  table list (`"event_idempotency"`, `"instance_projections"`,
  `"instance_sequence"`, `"entity_definitions"`) — no new idempotency
  mechanism is invented by this design; REQ-228 reuses this table exactly as
  every other event-append caller already does.
- `lib/letflow/event_store/platform_events.ex` (REQ-140) — the
  `Letflow.EventStore.PlatformEvents` adapter-module precedent: thin
  domain-specific wrappers around an `EventStore` append entry point, each
  minting its own deterministic idempotency key and translating the
  domain payload shape — the direct structural precedent this design's
  `Letflow.Entities.Records` module follows for `entity_type`/`record_id`
  idempotency-key construction.
- `lib/letflow/engine/task_activation.ex` — `append_multi/6`'s
  "append one `Multi.run/3` step onto a caller-supplied, still-open `Multi`"
  idiom — the direct structural precedent for this design's proposed
  `Letflow.EventStore.append_multi/3` (§3.3).
- REQ-228's cited R-Co sources (`src/entities/events.zig`,
  `src/entities/commands.zig`) are Windows paths
  (`c:\Users\tvolo\dev\ai-dala\R-Co\...`) **not reachable from this Linux
  sandbox** — confirmed by attempted lookup; this design relies entirely on
  REQ-228's own description text, which the requirement itself states already
  summarizes the relevant `commands.zig` behavior (idempotent-replay
  semantics, `getOrCreateEntityTypeInstance`/`ensureEntityInstanceProjection`
  naming) in enough detail to design from.

## 1. Scope (from REQ-228's own text)

1. Register `ENTITY_RECORD_CREATED`, `ENTITY_RECORD_UPDATED`,
   `ENTITY_RECORD_DELETED` via the **existing**
   `Letflow.EventStore.Registry.register_type/2` — no parallel registration
   mechanism.
2. `create`/`update`/`delete` command functions: validate (REQ-227's
   field_values check) → append exactly one event → update the
   `entity_record_latest` projection, all in one transaction.
3. Idempotency-key handling matching R-Co's ISS-0159/GH#480 fix: a duplicate
   submission returns the **original** record, not a fresh one.
4. The synthetic-instance-per-entity-type mapping (`entity_type_instances`):
   one synthetic `instance_projections` row per entity **type**.

Not in this requirement (confirmed explicitly, §8): no projection/replay
logic beyond the one `entity_record_latest` write inside the command
transaction (REQ-229's scope); no route or controller.

## 2. THE NAMED OPEN DESIGN QUESTION — resolved here, explicitly

**Question:** does the synthetic-instance mapping key one `instance_projections`
row per entity **type**, or one per entity **record**? R-Co's own design doc
left this open ("the table structure supports either model"); R-Co's actual
shipped `commands.zig` (`getOrCreateEntityTypeInstance`/
`ensureEntityInstanceProjection`) picked per-type.

**Resolution: per-entity-TYPE.** One `instance_projections` row (and one
`instance_sequence` row) is shared by every record of a given `entity_type`
within a tenant schema. A `create`/`update`/`delete` command for entity type
`"invoice"` always resolves to the *same* synthetic `instance_id`, regardless
of which `record_id` it targets.

**Justification, against REQ-228's own stated rationale (matching the actual
shipped implementation, not the design doc's abstract hedge):**

- REQ-228's own text states the default explicitly ("This requirement's
  default is to match the actual shipped implementation... rather than the
  more abstract design-doc hedge") — this is not a free design choice this
  artefact is re-opening, it is REQ-228 naming its own resolution and asking
  CODE-DESIGNER to state it rather than silently infer it from ported code.
- Per-record synthetic instances would mean minting a fresh
  `instance_projections` + `instance_sequence` row pair for every entity
  record ever created — for an entity type with, say, 100,000 records, that
  is 100,000 permanently-`:active` synthetic instance rows accumulating
  forever (an entity record is never "completed"/"cancelled" the way a
  workflow instance is — there is no terminal-state transition in this
  requirement's scope), a materially different storage/index shape than
  every other `instance_projections` consumer in this codebase produces.
- Per-type keeps `instance_projections`/`instance_sequence` row counts
  bounded by the number of **entity type definitions** a tenant has (already
  a small, human-curated set per REQ-225/226), not by record volume — this
  matches the actual cardinality `sequence_number`/`global_seq` ordering is
  useful for here: "the Nth entity-lifecycle event of type `invoice`" is a
  meaningful per-type stream to read back (REQ-229's replay path), whereas a
  per-record stream of typically 1–3 events (create, maybe update, maybe
  delete) gains nothing from `instance_sequence`'s row-lock protocol that a
  simple `entity_record_latest.last_event_global_seq` bookkeeping column
  does not already give it more cheaply (§5.3).
- AC5 (§9) demonstrates this directly: creating three records of the same
  entity type must produce exactly one synthetic instance row for that type,
  not three — this design's `entity_type_instances` get-or-create (§3.2)
  is built specifically to make that observable and testable.

This decision is stated here, in this design artefact's own dedicated
section, per REQ-228's explicit instruction that it not be left to be
inferred only from the implementation.

## 3. Module and file placement

Following the `Letflow.Entities.*` namespace precedent set by REQ-225/226/227:

| Module | File | Role |
|---|---|---|
| `Letflow.Entities.EventTypes` | `lib/letflow/entities/event_types.ex` | One-time seed step: the three `register_type/2` calls (§4). |
| `Letflow.Entities.Records` | `lib/letflow/entities/records.ex` | Context module: `create_record/2`, `update_record/2`, `delete_record/2` (§5). |
| `Letflow.Entities.Record.Latest` | `lib/letflow/entities/record/latest.ex` | `Ecto.Schema` for `entity_record_latest` (§6.1). |
| `Letflow.Entities.EntityTypeInstance` | `lib/letflow/entities/entity_type_instance.ex` | `Ecto.Schema` for `entity_type_instances` (§6.2). |
| *(extension)* `Letflow.EventStore` | `lib/letflow/event_store.ex` | New composable `append_multi/3` (§3.3) — an addition to the existing REQ-025/140-owned module, not a new module. |

`Letflow.Entities.Record.Latest` sits under `Letflow.Entities.Record.*`
alongside `Letflow.Entities.Record.Validator` (REQ-227) — both describe the
"one entity record" concern, one for inbound payload validation, one for the
persisted current-state row. `Letflow.Entities.Records` (plural, the CRUD
context module) mirrors `Letflow.Entities.Definitions`'s own
singular-schema/plural-context naming split exactly.

### 3.1 Why `append/2` cannot be reused unmodified for this transaction boundary

REQ-228 scope item 2 requires: validate → append exactly one event → update
`entity_record_latest`, **all in one transaction**, and AC2 requires a forced
failure between the event append and the projection update to leave **neither**
committed. `Letflow.EventStore.append/2` (§0) already performs an atomic
"append event + update `instance_projections`" sequence, but it does so inside
its **own**, internally-opened `Repo.transaction/1` call — by the time
`append/2` returns `{:ok, _}`, that transaction has already committed. There is
no way for a caller to staple one more `Multi.run/3` step onto an
already-committed transaction.

**Design decision:** add one new public function to `Letflow.EventStore`,
`append_multi/3`, structurally mirroring
`Letflow.Engine.TaskActivation.append_multi/6`'s existing
"append a `Multi.run/3` step onto a caller-supplied, still-open `Multi`" idiom
(§0). `append/2` and `append_platform_event/2` are left completely unmodified
— every existing caller of either is unaffected. `append_multi/3` factors the
*same* M1–M4 steps (`active_instance_guard`, `assign_sequence`,
`claim_idempotency`, `insert_event` — **not** M5/M6, see below) into a
function that takes and returns an `Ecto.Multi.t()`, so `Letflow.Entities.Records`
can add its own `entity_type_instance_guard` step before it and its own
`update_entity_record_latest` step after it, then call `Repo.transaction/1`
itself exactly once.

```
@spec append_multi(multi :: Ecto.Multi.t(), attrs :: EventStore.append_attrs(), opts :: [prefix: String.t()]) ::
        {:ok, Ecto.Multi.t()} | EventStore.append_error()
```

- `M5` (`maybe_store_oversized_payload`) is **included** when the payload
  exceeds the existing 4096-byte inline threshold — entity payloads are not
  exempt from that pre-existing invariant.
- `M6` (`update_projection`, i.e. `instance_projections.last_event_seq`) is
  **included** unchanged — the synthetic instance's own `instance_projections`
  row still needs its `last_event_seq` advanced exactly the way a real
  instance's does, so REQ-229's replay path has an authoritative
  last-applied-sequence marker per entity type.
- The one step `append_multi/3` does **not** perform that `append/2` does:
  opening/committing the transaction itself. Returning `{:ok, Ecto.Multi.t()}`
  (not `{:ok, append_result()}`) is the only shape difference from `append/2`
  — the four/six inner steps, their Multi step-name atoms, and every error
  tuple `interpret_transaction_result/1` already produces are unchanged, so
  `Letflow.Entities.Records` reuses `EventStore`'s existing
  `interpret_transaction_result/1`-shaped errors verbatim rather than
  inventing a parallel error taxonomy.
- This is a real extension to an existing, already-merged, REQ-025/140-owned
  module — flagged here explicitly for SECURITY-REVIEWER and REVIEWER, since
  it changes a tenant-data-append code path other requirements already
  depend on. No behavior of `append/2`/`append_platform_event/2` changes;
  `append_multi/3` is purely additive.

### 3.2 `entity_type_instance_guard` — the get-or-create step `append_multi/3` does not perform

`append_multi/3`'s own `active_instance_guard` (M1, reused from `append/2`)
requires an `instance_projections` row to **already exist** for the given
`instance_id` — it returns `{:error, :instance_not_started}` otherwise (§0).
For a synthetic per-type instance, that row will not exist before the first
record of that type is ever created. `Letflow.Entities.Records` must
therefore prepend its own `Multi.run(:entity_type_instance_guard, ...)` step,
**before** calling `append_multi/3`, that resolves-or-creates the synthetic
instance for `entity_type` (§6.2's `get_or_create/2`), so M1 always finds a
row by the time it runs. This step is race-safe (on_conflict: :nothing keyed
on the table's own `entity_type` unique index, §6.2), matching M2's own
insert-if-absent-then-lock idiom.

## 4. Event registration (scope item 1)

`Letflow.Entities.EventTypes.seed!/1` — one function, `prefix :: String.t()`
in, called once per tenant (the same "seed step" shape REQ-228's own text
names: "most naturally from this module's own one-time seed step"). Not a
route, not auto-run at boot for every request — a caller-invoked, idempotent
bootstrap analogous to `Letflow.TenantProvisioning.Backfill`'s own
`register_type/2` seed call sites (§0).

```
@type seed_result :: %{registered: [Registry.EventType.t()], skipped: [String.t()]}

@spec seed!(prefix :: String.t()) :: {:ok, seed_result()} | {:error, term()}
```

Idempotent across repeated calls: each of the three `register_type/2` calls
that returns `{:error, :duplicate_event_type_version}` is treated as "already
registered, not a failure" and its `name` is added to `skipped` rather than
aborting the whole seed; any other error return aborts immediately and is
returned as `{:error, reason}`. This lets `seed!/1` be safely re-invoked (e.g.
by a future migration-time bootstrap task) without needing its own
already-seeded guard.

### 4.1 The three `json_schema` payloads — the OUTER envelope, not the inner field_values check

Each `register_type/2` call's `json_schema` argument describes the **outer
event envelope** — `entity_type`, `entity_def_version`, `record_id`, and the
presence/typing of `field_values` as a bare JSON object — never the specific
per-entity-definition field constraints REQ-227's `build_record_schema/1`
derives per entity type. This is the exact inner/outer split REQ-227's own
moduledoc states its scope boundary against (§0); this design's moduledoc
(§4.2) restates it in the direction REQ-228's AC7 requires: which module
validates which.

| Event type | `schema_version` | Envelope shape (JSON-Schema-shaped map, `Registry.JsonSchema`'s supported keyword subset only — §0) |
|---|---|---|
| `ENTITY_RECORD_CREATED` | `1` | `{"type":"object","required":["entity_type","entity_def_version","record_id","field_values"],"properties":{"entity_type":{"type":"string"},"entity_def_version":{"type":"integer"},"record_id":{"type":"string"},"field_values":{"type":"object"}},"additionalProperties":false}` |
| `ENTITY_RECORD_UPDATED` | `1` | Identical shape to `ENTITY_RECORD_CREATED` — `field_values` on an update carries the record's full new field_values (whole-document replace, not a partial patch; see §5.2's non-goal note). |
| `ENTITY_RECORD_DELETED` | `1` | `{"type":"object","required":["entity_type","entity_def_version","record_id"],"properties":{"entity_type":{"type":"string"},"entity_def_version":{"type":"integer"},"record_id":{"type":"string"}},"additionalProperties":false}` — no `field_values` key at all; a delete event carries no payload data beyond identity. |

`entity_def_version` is `entity_definitions.logical_shape_version`'s ordinal
role for THIS design's purposes — the design does not mint a new numeric
versioning scheme; it is carried in the envelope so REQ-229's replay path can
tell which definition shape a historical event's `field_values` was validated
against, without this design needing to resolve that column's exact wire
representation (an explicit open question, §8 item 1).

### 4.2 Moduledoc statement of the inner/outer split (AC7)

`Letflow.Entities.EventTypes`'s moduledoc states explicitly: *"`register_type/2`'s
`json_schema` here validates only the outer event envelope — that
`entity_type`/`entity_def_version`/`record_id`/`field_values` are present and
correctly typed as a JSON object. It never inspects `field_values`'s own
keys. Per-entity-definition field constraint checking is
`Letflow.Entities.Record.Validator.validate_record_payload/2`'s (REQ-227) job
alone, run before this envelope validation, inside
`Letflow.Entities.Records`'s command functions (§5)."* This statement, plus
one test exercising each validator independently (AC7), is this design's
answer to AC7's explicit two-test requirement.

## 5. Command functions (scope item 2)

`Letflow.Entities.Records`, tenant-scoped via the same `prefix :: String.t()`
convention `Letflow.Entities.Definitions` already uses (§0) — no function
here accepts a separately-trusted `tenant_id`.

```
@type create_attrs :: %{
        required(:entity_type) => String.t(),
        required(:field_values) => Record.Validator.field_values(),
        required(:actor_id) => Ecto.UUID.t(),
        required(:idempotency_key) => String.t()
      }

@type update_attrs :: %{
        required(:entity_type) => String.t(),
        required(:record_id) => Ecto.UUID.t(),
        required(:field_values) => Record.Validator.field_values(),
        required(:actor_id) => Ecto.UUID.t(),
        required(:idempotency_key) => String.t()
      }

@type delete_attrs :: %{
        required(:entity_type) => String.t(),
        required(:record_id) => Ecto.UUID.t(),
        required(:actor_id) => Ecto.UUID.t(),
        required(:idempotency_key) => String.t()
      }

@type command_result :: %{
        record: Record.Latest.t(),
        is_duplicate: boolean()
      }

@type command_error ::
        {:error, {:definition_not_found, entity_type :: String.t()}}
        | {:error, {:record_payload_invalid, Record.Validator.violations()}}
        | {:error, {:record_not_found, record_id :: Ecto.UUID.t()}}
        | {:error, {:record_already_deleted, record_id :: Ecto.UUID.t()}}
        | {:error, :tenant_not_provisioned}
        | {:error, :invalid_schema_name}
        | {:error, {:payload_validation_failed, [Registry.ValidationFailure.t()]}}
        | {:error, term()}
```

(The `command_error` `:record_payload_invalid` arm's payload is REQ-227's own
`Record.Validator.violations()` list type (already a list, per that module's
own `@type violations :: [ValidationFailure.t()]`), cited here, not redefined.)

```
@spec create_record(create_attrs(), prefix :: String.t()) ::
        {:ok, command_result()} | command_error()

@spec update_record(update_attrs(), prefix :: String.t()) ::
        {:ok, command_result()} | command_error()

@spec delete_record(delete_attrs(), prefix :: String.t()) ::
        {:ok, command_result()} | command_error()
```

### 5.1 `create_record/2` — step order

1. Resolve `entity_type`'s current **active** `Letflow.Entities.EntityDefinition`
   via `Letflow.Entities.Definitions.get_definition_by_name/2` (REQ-226,
   reused unchanged) filtered to `status: :active` — `{:error,
   {:definition_not_found, entity_type}}` if none, before any DB write of any
   kind past that read.
2. `Letflow.Entities.Record.Validator.validate_record_payload/2` (REQ-227,
   the **inner** check) against the resolved definition and the incoming
   `field_values`. Non-empty violations → `{:error,
   {:record_payload_invalid, violations}}`, **zero events appended** (AC4) —
   returned before any `Ecto.Multi`/transaction is even built.
3. Mint `record_id = Ecto.UUID.generate()` fresh (never caller-supplied for
   `create_record/2` — a caller cannot dictate an existing record's id).
4. Build one `Ecto.Multi`:
   - `:entity_type_instance_guard` (§3.2) — get-or-create the synthetic
     instance for `entity_type`, producing `synthetic_instance_id`.
   - Fold in `Letflow.EventStore.append_multi/3` (§3.1) with
     `event_type: "ENTITY_RECORD_CREATED"`, `instance_id:
     synthetic_instance_id`, `actor_id`, `idempotency_key` (caller-supplied,
     §5.4), and `payload` JSON-encoding `%{entity_type: entity_type,
     entity_def_version: definition.logical_shape_version, record_id:
     record_id, field_values: field_values}` — this is where
     `Registry.validate_payload/3`'s **outer** envelope check (§4.1) runs,
     inside `append_multi/3`'s own pipeline, entirely independent of step 2's
     inner check.
   - `:upsert_record_latest` — `Multi.insert/3` a new `Letflow.Entities.Record.Latest`
     row (§6.1) from `changes.insert_event`'s resulting `event_id`/`created_at`
     (the pattern `store_oversized_payload`'s own `Multi.run/3` step already
     uses to read a prior step's result, §0) and the validated `field_values`.
5. `Repo.transaction/1` the composed `Multi` exactly once (AC2's atomicity:
   a forced failure injected at `:upsert_record_latest` rolls back
   `:insert_event`/`:assign_sequence`/`:claim_idempotency` in the same
   Postgres transaction — nothing commits).
6. On `{:error, :claim_idempotency, {:duplicate_idempotency_key, original_event},
   _changes}` (the shape `append_multi/3` reuses verbatim from `append/2`'s
   own `interpret_transaction_result/1`, §3.1): **do not** re-run steps 3–5.
   Decode `original_event.payload` (already a JSON object — no re-parse of a
   string; `Event.payload` is stored as `:map`, §0) and return `{:ok,
   %{record: %Record.Latest{record_id: original_event.payload["record_id"],
   entity_type: original_event.payload["entity_type"], field_values:
   original_event.payload["field_values"], ...}, is_duplicate: true}}` — see
   §5.4 for why decoding the stored event payload, not a fresh
   `entity_record_latest` read, is this design's chosen original-record
   lookup path.
7. Every other `Ecto.Multi` failure tag is passed through as the matching
   `command_error()` arm.

### 5.2 `update_record/2` and `delete_record/2` — same shape, two differences

Both follow §5.1's exact step order with two substitutions:

- Step 1 additionally does `Letflow.Entities.Record.Latest.get(record_id,
  entity_type, prefix)` (§6.1) — `{:error, {:record_not_found, record_id}}`
  if absent. `update_record/2` additionally rejects
  `{:error, {:record_already_deleted, record_id}}` if the existing row's
  `deleted: true` (§6.1's deletion representation) — an already-deleted
  record cannot be updated. `delete_record/2` treats deleting an
  already-deleted record as a **no-op success** returning the existing
  (already-deleted) row with `is_duplicate: false` — deletion is naturally
  idempotent at the domain level independent of the idempotency-key
  mechanism, so this is not itself an idempotency-key check.
- `event_type` is `"ENTITY_RECORD_UPDATED"` / `"ENTITY_RECORD_DELETED"`
  respectively; `update_record/2`'s payload carries the **full replacement**
  `field_values` (whole-document semantics, matching `entity_record_latest`
  being a current-state snapshot table, not an event-sourced diff store —
  REQ-228's text and REQ-229's projection design both describe
  `entity_record_latest` as holding "current field_values", singular,
  post-application). `delete_record/2`'s payload carries no `field_values`
  key at all (§4.1's envelope table) and its `:upsert_record_latest` step
  sets `deleted: true`, `field_values` **left unchanged** — REQ-229's own
  scope owns the definitive statement of a deleted record's snapshot
  representation; this design commits only to "the row is marked deleted,
  its last-known `field_values` are retained for audit/read purposes," an
  explicit design choice flagged for REQ-229's own moduledoc to confirm or
  supersede (§8 item 2).
- No re-validation of `field_values` shape against a schema change that
  happened after the original record's creation — `update_record/2` validates
  against `entity_type`'s **current** active definition (step 1/2 above,
  same as create), which may differ from the definition version the record
  was originally created under; this design does not attempt migration of
  historical field_values to a newer shape (out of scope; an explicit open
  question, §8 item 3).

### 5.3 `entity_record_latest` is written, not the sole state (design clarity for REQ-229)

This design's `:upsert_record_latest` `Multi` step is a plain
`Ecto.Repo` insert/update against `entity_record_latest`'s current row for
`(entity_type, record_id)` — no replay, no fold over prior events, no
consultation of `instance_sequence`. It is exactly, and only, "apply this one
event's effect to the current-state row," matching REQ-229's own scope
statement that `entity_record_latest`'s *table* is REQ-228's write path but
its *replay/rebuild* functions are REQ-229's. `last_event_global_seq` (§6.1)
is populated directly from `append_multi/3`'s own resulting `Event.global_seq`
(no independent counter minted here) so REQ-229's rebuild function has one
authoritative "last applied" marker to compare against the event log without
this design inventing a second sequencing scheme alongside `instance_sequence`.

### 5.4 Idempotency-key handling — the ISS-0159/GH#480 parity requirement (AC3)

**The original-record lookup happens by decoding the ORIGINAL EVENT's own
stored `payload`, not by a fresh `entity_record_latest` SELECT.**

Rationale: `append_multi/3`'s reused `claim_idempotency` step (M3, §0) already
performs the exact lookup ISS-0159/GH#480 needs — `IdempotencyRecord`'s
`uq_event_idempotency_key` unique index round-trips a duplicate submission's
`idempotency_key` back to the **first** successfully-committed `Event` row
(`resolve_duplicate/3`, §0), and that `Event.payload` is the complete,
already-validated JSON object this command originally appended — it already
contains `entity_type`, `record_id`, and `field_values` verbatim, because
those are exactly what step 4's payload construction (§5.1) put there. No
second table, no new unique index, and no re-derivation logic is needed:
**REQ-024's existing `event_idempotency` sidecar table (confirmed already
present per `test/support/tenant_fixture.ex`, §0) is the entire idempotency
lookup mechanism this design uses.**

This directly satisfies AC3's "verified against `commands.zig`'s actual
behavior, not only the design doc" instruction: the R-Co defect
ISS-0159/GH#480 fixed was exactly "a duplicate submission must resolve to the
original record's data, not merely detect that a duplicate occurred and
return an empty/error response" — decoding the original event's payload
(rather than merely branching on `is_duplicate: true` and returning nothing)
is this design's concrete mechanism for guaranteeing "same `record_id`, same
`field_values`" on every replay, not just "no second record created."

`idempotency_key` itself is **caller-supplied** (`create_attrs()`/
`update_attrs()`/`delete_attrs()`'s own `:idempotency_key` field, §5) — this
design does not mint one internally the way
`Letflow.EventStore.PlatformEvents`'s adapters do (§0), because entity
commands are the realistic caller-facing entry point REQ-228's own text
frames them as (an HTTP command body would carry its own client-generated
idempotency key, the same `Idempotency-Key`-header convention this
codebase's other command-shaped endpoints already use) — no route exists yet
to confirm this (§1's explicit non-goal), but the command function signature
itself must accept the key rather than derive it, so a future route can pass
one through unchanged.

## 6. New table shapes

### 6.1 `entity_record_latest` — `Letflow.Entities.Record.Latest`

The JSONB current-state projection table REQ-228's own text names but does
not fully specify (REQ-229 owns replay/rebuild functions against it; this
design owns its schema, since REQ-228's command functions are its only
writer until REQ-229 exists).

| Column | Type | Notes |
|---|---|---|
| `id` | `binary_id`, PK, autogenerate | Row's own surrogate key — not `record_id` itself, so a future re-projection (REQ-229) can `TRUNCATE`/reinsert without touching a caller-visible id it doesn't own. |
| `entity_type` | `string`, not null | The owning entity definition's `name` (REQ-225's `Definition.t().name`). |
| `record_id` | `binary_id`, not null | The record's own stable identity, minted once at `create_record/2` time (§5.1 step 3), never regenerated by update/delete. |
| `field_values` | `map` (jsonb), not null, default `%{}` | Current field_values snapshot — whole-document, per §5.2. |
| `deleted` | `boolean`, not null, default `false` | Set `true` by `delete_record/2`; `field_values` retained at its last pre-delete value (§5.2). |
| `entity_def_version` | `binary` | The `logical_shape_version` of the definition this row's current `field_values` was validated against (mirrors the event envelope's own field, §4.1) — lets a reader detect a stale-shape row without a join back to `entity_definitions`' history. |
| `last_event_global_seq` | `integer`, not null | The `Event.global_seq` (§0) of the most recent event folded into this row — REQ-229's rebuild-consistency marker (§5.3). Not `last_event_seq` (the per-instance `sequence_number`) — `global_seq` is the platform-wide monotone cursor, chosen because REQ-229's "does the projection match the log" check (its own AC3) is naturally phrased against the global log ordering, not a per-synthetic-instance-local one. |
| `inserted_at` / `updated_at` | `utc_datetime_usec` | Standard `timestamps()`. |

Constraints: `unique_index(:entity_record_latest, [:entity_type, :record_id])`
— exactly one current-state row per `(entity_type, record_id)` pair, the
`Multi.insert/3`-vs-`Multi.update/3` branch point `create_record/2` vs.
`update_record/2`/`delete_record/2` (§5.1/§5.2) key off. No `@schema_prefix`
(same per-tenant-schema convention every event-store table already follows,
§0) — every read/write passes `prefix: schema_name` explicitly.

```
@type t :: %__MODULE__{}

@spec get(record_id :: Ecto.UUID.t(), entity_type :: String.t(), prefix :: String.t()) ::
        {:ok, t()} | {:error, :not_found} | {:error, :invalid_schema_name}

@spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
@spec update_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
```

`insert_changeset/2` casts/requires `[:entity_type, :record_id, :field_values,
:entity_def_version, :last_event_global_seq]` (`:deleted` defaults `false`,
never cast on insert). `update_changeset/2` casts `[:field_values, :deleted,
:entity_def_version, :last_event_global_seq]` — `:entity_type`/`:record_id`
are structurally immutable after insert, matching
`Letflow.EventStore.InstanceProjection.update_changeset/2`'s own
immutable-identity-fields precedent (§0).

### 6.2 `entity_type_instances` — `Letflow.Entities.EntityTypeInstance`

The synthetic-instance-per-type mapping (§2).

| Column | Type | Notes |
|---|---|---|
| `entity_type` | `string`, PK | The mapping key — one row per distinct entity type name ever created in this tenant schema. Chosen as the primary key itself (not a separate `id` surrogate) since the table's entire purpose is this exact 1:1 mapping and nothing else ever needs to reference this row by a surrogate id. |
| `instance_id` | `binary_id`, not null | The synthetic `instance_projections.instance_id` this entity type's events append against (§2). Freshly minted (`Ecto.UUID.generate()`) the first time `entity_type` is seen — never derived deterministically from `entity_type`'s name, so no caller can predict or forge it. |
| `inserted_at` | `utc_datetime_usec` | `timestamps(updated_at: false)` — this mapping is immutable once created (an entity type is never re-pointed at a different synthetic instance). |

Constraint: `unique_index(:entity_type_instances, [:entity_type])` — the
literal AC5 guarantee ("exactly one instance_projections-equivalent row per
entity TYPE, not per record"). No `@schema_prefix`, same convention.

```
@type t :: %__MODULE__{}

@spec get_or_create(entity_type :: String.t(), prefix :: String.t()) ::
        {:ok, instance_id :: Ecto.UUID.t()} | {:error, term()}
```

`get_or_create/2`'s protocol (called as `create_record/2`/`update_record/2`/
`delete_record/2`'s `:entity_type_instance_guard` `Multi.run/3` step, §3.2),
race-safe under concurrent first-creation for the same brand-new
`entity_type` (mirrors M2's own insert-if-absent-then-read idiom, §0):

1. `repo.get(EntityTypeInstance, entity_type, prefix: schema_name)` — if
   found, return its `instance_id` immediately (no further writes).
2. Else, mint a fresh `instance_id`, and in order: (a)
   `repo.insert(EntityTypeInstance.insert_changeset(...), on_conflict:
   :nothing, conflict_target: :entity_type, prefix: schema_name)`; (b)
   `repo.insert(InstanceProjection.insert_changeset(%{instance_id:
   instance_id, status: :active, definition_id: instance_id}), on_conflict:
   :nothing, conflict_target: :instance_id, prefix: schema_name)` — the
   freshly-minted `instance_id` is reused as `definition_id` purely to
   satisfy `InstanceProjection.insert_changeset/2`'s `validate_required(
   [:instance_id, :status, :definition_id])` (§0); entity-type synthetic
   instances have no real `process_definitions` row to point at, and
   `definition_id` carries no FK constraint (§0's confirmed-not-assumed
   finding), so this is a safe, non-misleading placeholder — flagged
   explicitly here rather than silently chosen (§8 item 4); (c) re-read via
   `repo.get(EntityTypeInstance, entity_type, prefix: schema_name)` — the
   same "insert, then re-select to disambiguate outcome" idiom `claim_idempotency`
   itself already uses (§0) — and return **that** row's `instance_id`
   (whichever caller's insert actually won the race), never the
   locally-minted one blindly.

This mirrors `assign_sequence/3`'s exact insert-if-absent-then-lock structure
(§0) closely enough that `Letflow.Entities.EntityTypeInstance.get_or_create/2`
is a natural sibling to keep beside it conceptually, but stays in its own
`Letflow.Entities.*` module rather than growing `Letflow.EventStore` itself
with entity-specific concerns — `Letflow.EventStore.append_multi/3` (§3.1) is
the only `EventStore` extension this design introduces.

## 7. Error taxonomy

| Error | Meaning | Raised by |
|---|---|---|
| `{:error, {:definition_not_found, entity_type}}` | No active `entity_definitions` row for `entity_type`. | §5.1 step 1 |
| `{:error, {:record_payload_invalid, violations}}` | REQ-227's inner check failed. Zero events appended (AC4). | §5.1 step 2 |
| `{:error, {:record_not_found, record_id}}` | `update_record/2`/`delete_record/2` targeted a `record_id` with no `entity_record_latest` row. | §5.2 |
| `{:error, {:record_already_deleted, record_id}}` | `update_record/2` targeted an already-deleted record. | §5.2 |
| `{:error, {:payload_validation_failed, failures}}` | REQ-024's **outer** envelope check failed inside `append_multi/3` (should not occur on a well-formed command call — this design's own payload construction always satisfies §4.1's schema; retained because `Registry.validate_payload/3`'s contract can still surface it, e.g. a future envelope-schema tightening). | `append_multi/3`, forwarded unchanged |
| every `EventStore.append_error()` arm not listed above (`:tenant_not_provisioned`, `:instance_not_started`, `{:instance_terminated, _}`, `{:sequence_conflict, _}`, `Ecto.Changeset.t()`) | Forwarded verbatim from `append_multi/3` — `Letflow.Entities.Records` invents no parallel taxonomy for these (§3.1). | `append_multi/3`, forwarded unchanged |

## 8. Open questions (stated explicitly, not silently resolved)

1. **`entity_def_version` wire representation.** §4.1/§6.1 both carry this
   field, but this design does not pin down whether it is
   `entity_definitions.logical_shape_version` verbatim (currently a
   `:binary` column per REQ-226's schema, §0) or some other stable identifier
   REQ-226 exposes more conveniently for external event-payload consumption.
   Left for ELIXIR-DEV/REQ-229 to confirm against `EntityDefinition.t()`'s
   actual field, not silently picked here.
2. **Deleted-record snapshot representation.** §5.2 commits only to
   "`deleted: true`, `field_values` retained at last pre-delete value" as
   this design's minimum commitment for its own write path; REQ-229's own
   AC2 ("per this requirement's own stated representation of a deleted
   record, named explicitly in the moduledoc") is explicitly the
   authoritative statement — REQ-229's CODE-DESIGNER pass should confirm or
   supersede this design's default rather than treat it as already settled.
3. **No field_values schema-migration-on-update handling.** §5.2's third
   bullet: an `update_record/2` call validates against the entity type's
   *current* active definition, which may have evolved since the target
   record was created. This design does not attempt to reconcile or migrate
   a record's historical `field_values` shape — flagged, not solved.
4. **`InstanceProjection.definition_id` placeholder for synthetic instances.**
   §6.2 step 2(b) reuses the freshly-minted `instance_id` as `definition_id`
   solely to satisfy a `NOT NULL`/`validate_required` constraint that assumes
   every instance traces to a real `process_definitions` row. This is a
   placeholder value, not a meaningful reference — flagged for REVIEWER to
   confirm this is an acceptable reuse of an existing column rather than a
   sign `instance_projections`' schema itself should grow a nullable variant
   for non-workflow synthetic instances (out of this design's own scope to
   decide, since that column is REQ-023/043-owned).
5. **`Letflow.EventStore.append_multi/3`'s ownership.** §3.1 proposes adding
   a new public function to a module REQ-025/140 (not REQ-228) own. This
   design treats it as a necessary, narrowly-scoped, purely-additive
   extension (§3.1's own reasoning), but flags explicitly that REVIEWER
   should confirm this is the preferred path over an alternative this design
   did not pursue in depth: entity commands re-implementing M1–M4 privately
   inside `Letflow.Entities.Records` itself (duplicating `EventStore`'s
   internal locking protocol rather than extending it). This design's own
   preference is the extension (avoids protocol duplication/drift), stated
   as a recommendation, not a foreclosed decision.

## 9. Traceability — acceptance criteria to design elements

| # | Acceptance criterion (abridged) | Design element |
|---|---|---|
| 1 | Three event types each registered exactly once via `register_type/2`, verified against `event_type_registry` | §4, `Letflow.Entities.EventTypes.seed!/1` |
| 2 | Create appends exactly one event + updates `entity_record_latest` in one transaction; forced mid-transaction failure leaves neither committed | §5.1 steps 4–5, §3.1's single `Repo.transaction/1` call composing `append_multi/3` with `:upsert_record_latest` |
| 3 | Duplicate idempotency-key submission returns the ORIGINAL record both times (ISS-0159/GH#480 parity) | §5.4, §5.1 step 6 |
| 4 | Field_values failing REQ-227 validation → rejected, zero events appended | §5.1 step 2 (runs before any `Multi`/transaction exists) |
| 5 | `entity_type_instances` creates exactly one row per TYPE across three records of that type | §2, §6.2's `get_or_create/2` race-safe insert-if-absent |
| 6 | Design artefact explicitly states + justifies the per-type decision against R-Co's actual shipped code | §2 (this section itself) |
| 7 | Outer envelope schema and REQ-227's inner validation each independently exercised; moduledoc states which validates which | §4.1, §4.2, §5.1 steps 1–2 vs. step 4 |
| 8 | `mix test`/`mix compile --warnings-as-errors` pass | Implementation-phase verification, not a design-time artefact — ELIXIR-DEV/TEST-RUNNER's job |
| (scope) | No route/controller added | §1 confirms; no route/controller module appears anywhere in §3's module table |
| (scope) | No projection/replay logic beyond the one `entity_record_latest` write | §5.3 states the write is the full extent of this design's projection involvement; replay/rebuild is explicitly REQ-229's (§1, §8 item 2) |
