# Design: REQ-229 — Entity record projection and replay (projector.zig)

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-229's full entry (scope items 1–3, the six
  acceptance criteria, `depends_on: [REQ-228]`, the explicit NOT-IN-SCOPE
  note on query DSL/routes).
- `handoffs/WF02-REQ229-20260906/step-00-git-setup.json`'s task text — the
  scope correction this design's §1 restates and makes authoritative.
- `lib/letflow/entities/record/latest.ex` (REQ-228) — the `entity_record_latest`
  schema, its exact columns, and its own moduledoc's explicit statement that
  "rebuild/replay from the event log is REQ-229's own scope."
- `lib/letflow/entities/records.ex` (REQ-228) — `create_record/2`/
  `update_record/2`/`delete_record/2`, their event-type-per-command mapping
  (`ENTITY_RECORD_CREATED`/`UPDATED`/`DELETED`), their shared per-entity-**type**
  synthetic `instance_id` (via `EntityTypeInstance.get_or_create/2` — one
  `instance_projections` row per entity type, not per record, per REQ-228
  design §2), and `upsert_record_latest/3`'s exact per-event-kind write
  shape (`:create` inserts; `:update`/`:delete` update, `:delete` sets
  `deleted: true` and leaves `field_values` unchanged).
- `lib/letflow/entities/event_types.ex` (REQ-228) — `seed!/1`'s registration
  of the three event types and its moduledoc's inner/outer validation split.
- `lib/letflow/event_store.ex` — `read/2` (ascending `sequence_number` read
  for one `instance_id`, `{:error, :instance_not_found}` vs `{:ok, []}`
  distinction, `$ref` payload resolution) and `Letflow.EventStore.Event.t()`'s
  actual fields (`event_id`, `instance_id`, `event_type`, `payload` (already
  a decoded `:map`), `sequence_number`, `global_seq`, `created_at`).
- `lib/letflow/engine/reconstruction.ex` (REQ-053/054/059,
  `Letflow.Engine.Reconstruction`) — the established replay-by-event-fold
  idiom this design reuses structurally: `reconstruct_instance/2`'s
  read-then-fold-then-optionally-write-back shape, `read_full_log/3`'s
  merged/ordered event read, `replay/4`'s fold-with-a-clause-per-event-type
  structure, its `@doc false`-exported-for-reuse-not-duplication precedent,
  and its moduledoc's stated discipline that an unrecognized `event_type`
  during fold is a hard `{:error, {..., :unrecognized_event_type, ...}}`,
  never a silent skip. This design's `replay_record/3`/`rebuild_projection/2`
  are the entity-record-scoped analogue of `reconstruct_instance/2`/
  `write_back/3`, deliberately matching the same shape rather than inventing
  a new one (per this task's own instruction to find and reuse the existing
  precedent).
- REQ-229's own cited R-Co source (`src/entities/projector.zig`) is a
  Windows path not reachable from this Linux sandbox — this design relies on
  REQ-229's own description text plus the REQ-228 design/implementation it
  depends on.

## 1. THE TABLE-OWNERSHIP CORRECTION (read this section first)

REQ-229's `docs/requirements.yaml` description text states it "owns the
table's schema" for `entity_record_latest`. **This is stale relative to what
actually shipped.** REQ-228 already created and owns:

- The migration: `priv/repo/migrations/20260906010001_create_entity_record_latest.exs`.
- The schema module: `lib/letflow/entities/record/latest.ex`
  (`Letflow.Entities.Record.Latest`), including its `insert_changeset/2`,
  `update_changeset/2`, and `get/3` functions.

REQ-228's own command functions (`create_record/2`/`update_record/2`/
`delete_record/2`) needed to write to `entity_record_latest` inside their own
transaction (REQ-228 AC2's atomicity requirement), so the table had to exist
before REQ-229 could be built — REQ-228's design doc §6.1 and its
`Record.Latest` moduledoc both say this explicitly ("this module is a plain
write/read target... Rebuild/replay from the event log is REQ-229's own
scope").

**This design does not create, modify, or re-specify that migration or that
schema module.** No new migration file, no new `Ecto.Schema`, no change to
`Letflow.Entities.Record.Latest`'s fields or changesets appears anywhere in
this design. REQ-229's actual remaining scope, confirmed against the
task handoff's own scope-correction text, is exactly two functions that
operate against the **existing** `entity_record_latest` table and the
**existing** event log, independent of the live command path:

1. **Replay** — reconstruct one entity record's current snapshot purely from
   its own event stream, independent of whatever `entity_record_latest`
   currently holds (§3).
2. **Rebuild** — full tenant-scoped (or entity-type-scoped) re-projection of
   `entity_record_latest` from the event log, discarding and rewriting rows
   (§4) — the recovery path if the projection table is ever suspected
   inconsistent with the log.

No route, no controller, no query DSL appears anywhere in this design (§6).

## 2. Module and file placement

| Module | File | Role |
|---|---|---|
| `Letflow.Entities.Record.Projector` | `lib/letflow/entities/record/projector.ex` | New module (this design): `replay_record/3` (§3), `rebuild_projection/2` (§4). |

Placed under the existing `Letflow.Entities.Record.*` namespace (REQ-228
design §3), alongside `Letflow.Entities.Record.Validator` (REQ-227, inbound
payload validation) and `Letflow.Entities.Record.Latest` (REQ-228, the
persisted current-state schema). `Projector` is a natural third sibling
under the same "one entity record" concern: `Validator` checks a payload
before it becomes an event, `Latest` is the live write target one event
updates at a time, `Projector` is the read-the-log-independently and
rebuild-the-table concern — all three describe facets of the same
`entity_type` + `record_id` identity, none of them own a schema of their
own (`Projector` reads/writes `entity_record_latest` through
`Letflow.Entities.Record.Latest`'s own changesets, exactly as REQ-228's
`Letflow.Entities.Records` context module already does — no second
insert/update path is invented). Not named `Letflow.Entities.Records.Projector`
(under the plural context module) because `rebuild_projection/2` operates at
a different scope (entity-type/tenant-wide, not one record's command) than
`Letflow.Entities.Records`'s per-call command functions — keeping it a
sibling of `Record.Latest` rather than a child of the command context module
avoids implying it is itself a command.

No `@schema_prefix` on anything here (this module defines no schema at
all); every call takes an explicit `prefix :: String.t()`, matching every
other tenant-scoped module in this subsystem (REQ-228 design §0's
convention, restated).

## 3. `replay_record/3` — replay one record's event stream to a snapshot (scope item 2)

### 3.1 Where a record's events actually live

Per REQ-228 design §2 (already-shipped, restated here for this design's own
reasoning): every event for entity type `T` — regardless of which
`record_id` it concerns — is appended against the **same** synthetic
`instance_projections` row, keyed by `entity_type_instances.entity_type ==
T`. There is no per-record `instance_id`. Replaying one record's stream is
therefore: (a) resolve `T`'s synthetic `instance_id`, (b) read that
instance's **entire** event log via the existing `Letflow.EventStore.read/2`,
(c) filter down to the events whose payload's own `"record_id"` key matches
the target record, preserving `read/2`'s existing ascending
`sequence_number` order (§0). This reuses `EventStore.read/2` completely
unchanged — no new event-store read path is added for this requirement,
unlike REQ-053/054's `Letflow.Engine.Reconstruction.read_full_log/3`, which
needed a new merged-archive query because workflow-instance replay must
survive `archive/1`. Whether `archive/1` is ever invoked against a synthetic
per-type entity instance is not confirmed anywhere in this codebase as of
this design (§7 item 1) — flagged as an open question rather than silently
assumed either way; `EventStore.read/2` alone (no archive merge) is this
design's stated default until that is confirmed.

### 3.2 Types

```
@type snapshot :: %{
        entity_type: String.t(),
        record_id: Ecto.UUID.t(),
        field_values: map(),
        deleted: boolean(),
        entity_def_version: binary(),
        last_event_global_seq: pos_integer(),
        last_event_sequence_number: pos_integer(),
        last_event_type: String.t()
      }

@type replay_error ::
        {:error, :invalid_schema_name}
        | {:error, :tenant_not_provisioned}
        | {:error, :entity_type_not_found}
        | {:error, :record_not_found}
        | {:error, {:corrupt_event_stream, reason :: term()}}
        | {:error, term()}
```

`snapshot()` is a **plain map**, deliberately not `Letflow.Entities.Record.Latest.t()`
itself — a replayed snapshot has no `id`/`inserted_at`/`updated_at` (it was
never persisted), and reusing the Ecto struct type would misleadingly imply
those fields are meaningful on a value that may never touch the database
(`replay_record/3` alone never writes anything — §3.3). `rebuild_projection/2`
(§4) is the function that turns a `snapshot()` into an actual
`Letflow.Entities.Record.Latest` row, via that schema's own existing
`insert_changeset/2` (unchanged, REQ-228-owned).

### 3.3 Function

```
@spec replay_record(
        entity_type :: String.t(),
        record_id :: Ecto.UUID.t(),
        prefix :: String.t()
      ) :: {:ok, snapshot()} | replay_error()
```

Read-only — issues zero writes to any table, including `entity_record_latest`.
Step order:

1. Validate `prefix` resolves to a provisioned tenant schema
   (`TenantProvisioning.tenant_id_for_schema_name/1`, the same guard
   `Letflow.Entities.Record.Latest.get/3` already runs) —
   `{:error, :invalid_schema_name}` / `{:error, :tenant_not_provisioned}`
   otherwise, before any query.
2. Look up `entity_type`'s synthetic instance: `Repo.get(EntityTypeInstance,
   entity_type, prefix: prefix)` — a **read-only** lookup, unlike REQ-228's
   own `EntityTypeInstance.get_or_create/2` (§0), because a replay call must
   never mint a fresh synthetic instance as a side effect of asking "what
   happened to this record." No row found → `{:error, :entity_type_not_found}`
   (this entity type has never had a single record created, so the target
   record cannot exist either).
3. `Letflow.EventStore.read(instance_id, prefix: prefix)` (§3.1) — every
   event ever appended for entity type `entity_type`, ascending
   `sequence_number`, `$ref` payloads already resolved (`read/2`'s own
   existing contract, §0). An `{:error, :instance_not_found}` return here
   would only occur if `entity_type_instances` and `instance_projections`
   have drifted out of sync (an invariant REQ-228's own get-or-create
   protocol maintains, §0) — surfaced unchanged as `{:error, :instance_not_found}`,
   not remapped.
4. Filter the returned `[Event.t()]` list to those whose
   `event.payload["record_id"] == record_id` (string-compared; `record_id`
   is cast to string once before filtering, since `Event.payload` round-trips
   `record_id` as a JSON string per REQ-228 design §4.1's envelope, never as
   a native `Ecto.UUID`). Order is preserved from step 3 (already ascending
   `sequence_number`).
5. Empty filtered list → `{:error, :record_not_found}` (this entity type
   exists, but no event has ever been appended for this specific
   `record_id`).
6. Fold the filtered list left-to-right into a `snapshot()`, one clause per
   `event.event_type`, exactly mirroring `Letflow.Engine.Reconstruction`'s
   own per-event-type fold-clause structure (§0):

   | Fold state before | `event_type` | Resulting snapshot |
   |---|---|---|
   | (none — first event) | `"ENTITY_RECORD_CREATED"` | `field_values: payload["field_values"]`, `deleted: false`, `entity_def_version:` decoded from `payload["entity_def_version"]` (hex string → binary via `Base.decode16!/2`, the exact decode `Letflow.Entities.Records`'s own `duplicate_result/1` already performs against the same field, §0 — this design reuses that decode convention rather than inventing a second one), `last_event_global_seq: event.global_seq`, `last_event_sequence_number: event.sequence_number`, `last_event_type: event.event_type`. |
   | (none — first event) | `"ENTITY_RECORD_UPDATED"` or `"ENTITY_RECORD_DELETED"` | `{:error, {:corrupt_event_stream, {:missing_created_event, record_id}}}` — a record's stream must always begin with `ENTITY_RECORD_CREATED` (REQ-228's command path never appends any other event type first); any other first event means the log itself is inconsistent, not a case to silently tolerate. |
   | not deleted | `"ENTITY_RECORD_CREATED"` (a second one) | `{:error, {:corrupt_event_stream, {:duplicate_created_event, record_id}}}` — `record_id` is minted once per record (REQ-228 design §5.1 step 3) and never reused; a second `CREATED` for the same `record_id` cannot happen via the command path. |
   | not deleted | `"ENTITY_RECORD_UPDATED"` | `field_values` replaced wholesale with `payload["field_values"]` (whole-document semantics, REQ-228 design §5.2), `entity_def_version` re-decoded from this event's own payload (a record's definition version can advance across updates, REQ-228 design §5.2's third bullet), `deleted` unchanged (`false`), `last_event_*` fields advanced to this event. |
   | not deleted | `"ENTITY_RECORD_DELETED"` | `deleted: true`; `field_values` **left unchanged** at its pre-delete value; `entity_def_version` **re-decoded from this DELETE event's own payload** (identical rule to the `UPDATED` clause above — a record's definition version can still advance between its last update and its deletion, and the DELETE event's own payload already carries the definition version active at delete time, §3.4 justifies this against REQ-228's own already-shipped write path); `last_event_*` fields advanced to this event. |
   | already deleted (`deleted: true`) | any of the three | `{:error, {:corrupt_event_stream, {:event_after_delete, record_id, event.event_type}}}` — REQ-228's command path structurally forbids updating a deleted record (`ensure_not_deleted/2`) and treats deleting an already-deleted record as a no-op that appends **no** new event (`delete_record/2`'s own no-op branch, §0) — so a well-formed log never has any event after a `DELETED` for the same `record_id`. Surfacing this as corruption (rather than silently taking the later event, or silently keeping the delete) matches `Letflow.Engine.Reconstruction`'s own stated discipline of never silently tolerating a log shape the command path is not supposed to produce (§0). |
   | any | any `event_type` string not one of the three registered entity event types | `{:error, {:corrupt_event_stream, {:unrecognized_event_type, event.event_type, event.event_id}}}` — mirrors `Letflow.Engine.Reconstruction`'s own unrecognized-event-type discipline verbatim (§0), for the same reason: a later requirement that adds a fourth entity event type must add its own fold clause here explicitly, never fall through silently.

7. Return `{:ok, snapshot}` once every filtered event has been folded.

### 3.4 Deleted-record snapshot representation — AC2's own explicit choice

**Choice: a `deleted: true` flag on the same row/snapshot. `field_values`
is retained at its last pre-delete value; `entity_def_version` is
re-decoded from the DELETE event's own payload, not carried forward from
whatever it was before the delete.** No tombstone row, no removal from
`entity_record_latest`, no separate table.

**Justification against REQ-228's already-shipped write path (not a fresh
design-time choice — a consistency requirement):** `Letflow.Entities.Records.upsert_record_latest/3`'s
`:delete` clause (§0, `records.ex` ~line 289) already does exactly this on
the live command path — `Latest.update_changeset(%{field_values:
ctx.field_values, deleted: true, entity_def_version:
ctx.definition.logical_shape_version, ...})`. The two fields follow
**different** rules there, and `replay_record/3`'s fold must mirror both
exactly:

- `ctx.field_values` is deliberately the **existing** record's last-known
  `field_values` (`delete_record/2`'s own `ctx` construction reuses
  `existing_record.field_values` unchanged, §0) — genuinely carried forward,
  not recomputed from the delete event.
- `ctx.definition` is **not** carried forward from the pre-delete row.
  `delete_record/2` calls `fetch_active_definition/2` fresh, the exact same
  currently-active-definition lookup the `:update` clause uses (§0) — so
  `entity_def_version` on delete reflects whatever definition version is
  active *at delete time*, which may have advanced since the record's last
  update. `base_payload/1` is called unconditionally for all three event
  kinds (§0, `records.ex` ~lines 259–266), so the `ENTITY_RECORD_DELETED`
  event's own payload already carries this freshly-computed
  `entity_def_version` value — the fold has everything it needs to re-decode
  it exactly as the `UPDATED` clause does, and must do so rather than
  treating it as unchanged.

If `replay_record/3` chose a different representation for a deleted record
(e.g. `field_values: %{}`, omitting the row entirely, or carrying forward
the pre-delete `entity_def_version` instead of re-decoding the DELETE
event's own value), REQ-229's own AC1 ("replaying a record's full event
stream... produces a snapshot matching the record's actual current
field_values") and AC3 ("rebuildProjection... restores exactly the state
the replay function would independently compute") would both be internally
contradictory with what `entity_record_latest` already, observably contains
for a deleted record today — including, specifically, a deleted record
whose entity type's active definition advanced between that record's last
update and its deletion. Matching REQ-228's existing behavior field-by-field
is therefore not a preference — it is the only choice under which "replay
matches the live projection" is even a coherent statement. This is the
requirement's own explicit representation — `field_values` frozen at its
last non-delete value, `entity_def_version` always reflecting the
definition active at the time of the **last event affecting the record**
(create, update, or delete, whichever came last) — stated here and restated
verbatim in `Letflow.Entities.Record.Projector`'s moduledoc, per AC2's own
instruction that it be "named explicitly in the moduledoc."

## 4. `rebuild_projection/2` — full re-projection (scope item 3)

### 4.1 Types

```
@type rebuild_opts :: [prefix: String.t(), entity_type: String.t() | nil]

@type rebuild_result :: %{
        entity_types_rebuilt: [String.t()],
        records_rebuilt: non_neg_integer()
      }

@type rebuild_error ::
        {:error, :invalid_schema_name}
        | {:error, :tenant_not_provisioned}
        | {:error, :entity_type_not_found}
        | {:error, {:corrupt_event_stream, reason :: term()}}
        | {:error, term()}

@spec rebuild_projection(prefix :: String.t(), opts :: rebuild_opts()) ::
        {:ok, rebuild_result()} | rebuild_error()
```

`opts[:entity_type]`: `nil` (default, absent) rebuilds **every** entity type
present in this tenant's `entity_type_instances` table (the full-tenant
recovery path, AC4's tenant-scope framing); a given `String.t()` rebuilds
**only** that one entity type (AC3's own test scope: "after an artificial
corruption of the projection table's rows for one entity type"). No third
mode (e.g. a single `record_id`) — a single-record recovery is already
`replay_record/3` plus one manual write, not this function's job.

### 4.2 Step order

1. Validate `prefix` (same tenant-schema guard as §3.3 step 1).
2. Resolve the set of `entity_type` values to rebuild:
   - `opts[:entity_type]` given → `Repo.get(EntityTypeInstance, entity_type,
     prefix: prefix)`; not found → `{:error, :entity_type_not_found}`;
     otherwise the singleton list `[entity_type]`.
   - `opts[:entity_type]` absent/`nil` → `Repo.all(EntityTypeInstance,
     prefix: prefix) |> Enum.map(& &1.entity_type)` — every entity type this
     tenant schema has ever created a record for.
3. For **each** `entity_type` in that set, independently (§4.3):
   a. Read that type's full event log once (`EventStore.read/2`, §3.1 —
      the exact same call `replay_record/3` makes, just unfiltered by
      `record_id`).
   b. Group the events by `payload["record_id"]` (`Enum.group_by/2`),
      preserving each group's own ascending `sequence_number` order (the
      source list is already ascending; `group_by/2` preserves relative
      order within each group).
   c. Fold **each** `record_id`'s own event group into a `snapshot()`, via
      the exact same fold table §3.3 step 6 defines — this design shares
      one private fold implementation between `replay_record/3` and
      `rebuild_projection/2` (mirroring `Letflow.Engine.Reconstruction`'s
      own `@doc false`-exported-for-reuse precedent, §0) rather than
      maintaining two independently-drifting copies of the same six-clause
      table. Any `{:corrupt_event_stream, _}` from any one record's fold
      aborts that entity type's rebuild entirely (§4.3) — a rebuild does
      not silently skip a corrupt record and report success for the rest.
   d. Discard and rewrite `entity_record_latest` rows for this
      `entity_type` only (§4.3): `Repo.delete_all(from r in Latest, where:
      r.entity_type == ^entity_type, prefix: prefix)`, then
      `Repo.insert_all(Latest, computed_rows, prefix: prefix)`, where
      `computed_rows` is every folded `snapshot()` converted to
      `Latest.insert_changeset/2`-shaped attrs (reusing that existing,
      REQ-228-owned changeset function — no second validation path is
      invented for the bulk-insert case; `insert_all/3` still runs each
      row through the changeset for validation before flattening to raw
      inserts, matching how `Letflow.Entities.Records.upsert_record_latest/3`
      already validates every single-row write, §0).
4. Return `{:ok, %{entity_types_rebuilt: [...], records_rebuilt: n}}` — `n`
   summed across every rebuilt entity type.

### 4.3 Transaction/batching strategy — one `Repo.transaction/1` per entity type, not one for the whole call

**Decision: each entity type's read-fold-delete-rewrite (§4.2 step 3a–3d)
runs inside its own single `Repo.transaction/1` call. A multi-entity-type
`rebuild_projection/2` call (no `opts[:entity_type]` filter) iterates types
one at a time, each committing independently — it is not one giant
transaction spanning the whole tenant.**

Reasoning:

- **Lock duration.** `Repo.delete_all/2` followed by `Repo.insert_all/3`
  against `entity_record_latest`, scoped to one `entity_type`, holds no
  Postgres lock longer than that one type's own row range. A tenant with,
  say, 20 entity types and tens of thousands of records total would hold a
  single transaction's locks (and its snapshot's row-visibility window)
  across the *entire* table for the whole operation if all 20 types were
  rewritten inside one transaction — materially longer than any other
  write path in this subsystem holds a lock (REQ-228's own command
  functions each touch exactly one record's row per transaction, §0).
  Per-type transactions bound the worst case to one type's own record
  count.
- **Partial-success recoverability.** If the events for one entity type
  turn out to be genuinely corrupt (§3.3's `{:corrupt_event_stream, _}`
  fold errors), a per-type transaction boundary means every **other**
  type's rebuild that already completed stays committed — the operator
  gets a clear "type X failed, types A/B/C/... succeeded" result rather
  than an all-or-nothing failure that discards correctly-rebuilt data for
  unrelated entity types just because one type's log had a problem. This
  matches the recovery-path framing of the requirement itself (§1 item 2:
  "the recovery path if `entity_record_latest` is ever suspected
  inconsistent") — a recovery tool that itself becomes all-or-nothing
  across unrelated data is a worse recovery tool.
- **Matches AC3's own observable unit.** AC3's scenario is stated entirely
  in terms of "one entity type" (create corruption for one type, rebuild,
  verify that type). Nothing in REQ-229's acceptance criteria requires
  cross-type atomicity, so this design does not manufacture a stronger,
  more expensive guarantee than the requirement asks for.
- **Within one entity type**, `delete_all` + `insert_all` **do** need to be
  atomic with each other (a crash between the two must not leave that
  type's `entity_record_latest` rows empty) — hence the one
  `Repo.transaction/1` per type, not zero.
- On a mid-loop failure (one type's transaction returns `{:error, reason}`),
  `rebuild_projection/2` **stops** and returns that error immediately
  (`{:error, reason}`, not a partial `{:ok, _}`) rather than silently
  continuing past a failed type — the caller can safely re-invoke
  `rebuild_projection/2` scoped to just the failed `entity_type` once
  fixed, since every already-succeeded type's transaction has already
  committed independently and re-running it is a harmless full
  discard-and-rewrite of that type alone.

### 4.4 Tenant scoping (AC4)

Every query in §4.2 — `EntityTypeInstance` lookup/list, `EventStore.read/2`,
`Repo.delete_all`/`Repo.insert_all` against `Latest` — passes `prefix:
prefix` explicitly, the same per-tenant-Postgres-schema convention every
other table in this subsystem already follows (REQ-228 design §0/§6). There
is no code path in this design that queries any of these tables without an
explicit `prefix`, and no query filters by a separately-trusted `tenant_id`
column instead of the schema itself — tenant B's `entity_record_latest` rows
live in a structurally different Postgres schema, not merely a different
row range of the same schema, so a `prefix`-scoped `rebuild_projection/2`
call for tenant A cannot read or write tenant B's rows regardless of any
`entity_type` value collision between tenants (the identical entity type
name `"invoice"` in two tenants resolves to two entirely separate
`entity_type_instances`/`entity_record_latest` tables).

## 5. Shared private fold helper (referenced by both public functions)

```
@typep merged_event :: %{
         event_type: String.t(),
         payload: map(),
         sequence_number: pos_integer(),
         global_seq: pos_integer(),
         event_id: Ecto.UUID.t()
       }

@spec fold_record_events(entity_type :: String.t(), record_id :: Ecto.UUID.t(), events :: [merged_event()]) ::
        {:ok, snapshot()} | {:error, {:corrupt_event_stream, term()}}
```

`@doc false`, not part of this module's public API — the single
implementation of §3.3 step 6's fold table, called once per record by
`replay_record/3` (already-filtered single-record list) and once per
distinct `record_id` group by `rebuild_projection/2` (§4.2 step 3c). Mirrors
`Letflow.Engine.Reconstruction`'s own `@doc false`-exported-for-reuse
precedent (§0) — the fold logic exists in exactly one place so the two
public functions cannot silently drift apart on how a given event sequence
folds.

## 6. Confirmed non-goals (scope boundary)

- **No migration, no `Ecto.Schema` change.** §1 states this as the
  requirement's own headline correction. `entity_record_latest`'s columns,
  indexes, and constraints are entirely REQ-228's, unchanged by this design.
- **No route, no controller, no Plug pipeline entry.** Nothing in §2's
  module table is a route or controller module; `Letflow.Entities.Record.Projector`
  is a plain library module, called directly (e.g. by a future
  operator-facing task or a future REQ-230/231-adjacent route, neither of
  which exists yet) — confirmed by `git diff --stat` showing no
  `lib/letflow_web/**` (or equivalent router/controller path) file touched
  by this requirement's implementation commits (AC5).
- **No query DSL.** `rebuild_projection/2`'s `opts[:entity_type]` filter is
  a single closed keyword option, not a general filter/query language —
  REQ-230/231's closed-enum operator DSL and per-tenant field allowlist are
  untouched by this design.

## 7. Open questions (stated explicitly, not silently resolved)

1. **Does `Letflow.EventStore.archive/1` ever run against a synthetic
   per-entity-type instance?** Not confirmed anywhere in this codebase as
   of this design. If it does, both `replay_record/3` and
   `rebuild_projection/2` would need the same `events` +
   `events_archive` merged read `Letflow.Engine.Reconstruction.read_full_log/3`
   already implements (§0), rather than plain `EventStore.read/2` alone —
   left for ELIXIR-DEV to confirm against `archive/1`'s actual eligibility
   criteria before implementation, not silently assumed either way here.
2. **`entity_def_version`'s wire representation** is still an open question
   REQ-228's own design §8 item 1 left unresolved (whether
   `payload["entity_def_version"]` is always a stable hex-encoded
   `logical_shape_version` or some other identifier). §3.3 step 6 commits
   to decoding it via `Base.decode16!/2`, matching `Letflow.Entities.Records.duplicate_result/1`'s
   own existing decode — if REQ-228's own open question is later resolved
   differently, this design's decode step needs the same update, in the
   same place (§5's shared fold helper), not two places.
3. **Very large single-entity-type record counts.** §4.2/§4.3's per-type
   `Enum.group_by/2` plus in-memory fold holds that type's entire event log
   and every resulting snapshot in memory for the duration of one
   transaction. No NFR target exists in this codebase for entity-record
   volume (unlike `Letflow.Engine.Reconstruction`'s own informational-only
   NFR-04 disclaimer for workflow-instance replay, §0) — this design does
   not propose a streaming/paginated rebuild, and flags this as a scaling
   limit to revisit if a tenant's single entity type ever grows large
   enough for it to matter, rather than solving it speculatively now.

## 8. Traceability — acceptance criteria to design elements

| # | Acceptance criterion (abridged) | Design element |
|---|---|---|
| 1 | Replaying create+two-updates (no delete) produces a snapshot matching current field_values | §3.3 step 6's `CREATED`/`UPDATED` fold clauses; §3.4's field_values-retention consistency argument |
| 2 | Replaying a stream ending in `DELETED` correctly reflects deletion, per a representation named explicitly in the moduledoc | §3.4 (the `deleted: true`-flag choice and its justification); §2's note that `Projector`'s moduledoc restates this verbatim |
| 3 | `rebuildProjection` discards+rewrites `entity_record_latest` for one entity type, matching what `replay_record/3` would independently compute, after artificial corruption | §4.2 steps 3a–3d (shared fold helper, §5, guarantees the two functions cannot compute different answers); §4.3's per-type transaction scope matches this AC's own one-type framing |
| 4 | `rebuildProjection` is tenant-scoped — no cross-tenant read/write | §4.4 |
| 5 | No route/controller added or modified | §6, first two bullets |
| 6 | `mix test`/`mix compile --warnings-as-errors` pass with real output | Implementation-phase verification — ELIXIR-DEV/TEST-RUNNER's job, not a design-time artefact |
| (scope) | Table/schema NOT owned by this requirement (correction) | §1 |
| (scope) | No query DSL | §6, third bullet |
