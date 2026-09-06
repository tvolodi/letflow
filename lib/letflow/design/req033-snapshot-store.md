PROVENANCE (historical, not current decision authority):
# Design: REQ-033 — Definition snapshot store (`snapshot.zig`, PD-08)

**Requirement:** REQ-033 (`docs/requirements.yaml` lines 1514–1554, stage S2,
`depends_on: [REQ-027]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ033-20260817`, WF-02 Step 1
**This document produces:** module/function signatures, the transaction shape, the full
error taxonomy, the idempotency decision, the tenant-scoping mechanism, and invariants —
**no implementation code**. No function bodies, no `.ex` files. Pseudocode blocks below
describe algorithm shape only, matching the convention already validator-approved in
`lib/letflow/design/req024-event-type-registry.md` §4.4 and, after its own rework,
`lib/letflow/design/req025-event-append.md` §6 — ELIXIR-DEV writes the real version.

---

## 0. Sources read for this design

**Letflow project docs, read in full:**

- `docs/requirements.yaml` — REQ-033's full entry (1514–1554) and REQ-027's full entry
  (the batch that shipped the two tables this design operates on).
- `docs/agents/instructions/security-invariants.md` — INV-1 (tenant isolation via
  `:prefix`, never a caller-supplied `tenant_id`), INV-7 (no raw-SQL string
  interpolation — `Ecto.Query` composition only), INV-8 (typed results on every
  external-I/O path).
- `docs/guides/backend_developer_guide.md` §3.5 (error shapes), §3.6 (SQL
  parameterization).
- `docs/migration/decisions/0003-ecto-schema-strategy.md` and its 2026-08-17 addendum
  (tenant_id-derivation rule) — read to check whether it applies here; §3 below explains
  why it does **not** apply to this requirement's writes.
- `lib/letflow/design/req025-event-append.md` — read as the most recent precedent for
  (a) the prose-only pseudocode convention for Section 6-equivalent algorithm
  descriptions, (b) the `opts: [prefix: ...]` calling convention for a tenant-scoped
  context function, and (c) the "insert, then re-select to disambiguate an
  `on_conflict: :nothing` outcome" idiom this design reuses in simplified form (§6.2).

**Letflow shipped code, read directly (not assumed):**

- `lib/letflow/definitions/instance_definition_snapshot.ex` — full file. Confirmed the
  actual schema: `@primary_key {:instance_id, :binary_id, autogenerate: false}`, fields
  `definition_id` (`Ecto.UUID`), `definition_name` (`:string`), `definition_ver`
  (`:string`), `graph` (`:map`), `snapshotted_at` (`:utc_datetime_usec,
  read_after_writes: true`). Confirmed `create_changeset/2` is the **only** changeset
  this module exposes (no update/delete path — write-once, per its own moduledoc),
  confirmed it already carries `unique_constraint(:instance_id, name:
  :instance_definition_snapshots_pkey)` and `foreign_key_constraint(:definition_id,
  name: :instance_definition_snapshots_definition_id_fkey)` — both load-bearing for this
  design's error taxonomy (§5.3). Confirmed the moduledoc's own text: "Turns a
  duplicate-instance_id insert into `{:error, changeset}` rather than a raised
  `Ecto.ConstraintError`, which is what lets REQ-033 return its
  `SnapshotAlreadyExists`-equivalent" and "Turns a dangling `definition_id` into
  `{:error, changeset}` ..., which is what lets REQ-033 return `DefinitionNotFound`" —
  both read and explicitly addressed below (§6.3's note on why this design does not
  literally return either of those two changeset-shaped errors, having chosen the
  pre-transaction-lock-read strategy and the idempotent-no-op reading instead).
- `lib/letflow/definitions/process_definition.ex` — full file. Confirmed the actual
  schema: `@primary_key {:id, :binary_id, autogenerate: true}`, and, relevant to this
  design, `field(:tenant_id, Ecto.UUID)`, `field(:name, :string)`, `field(:version,
  :string)`, `field(:graph, :map, default: %{"nodes" => [], "edges" => []})`. **No
  `@schema_prefix`** — moduledoc states "every read and write must pass `prefix:
  schema_name` explicitly at call time."
PROVENANCE (historical, not current decision authority):
- `priv/repo/migrations/20260816193002_create_instance_definition_snapshots.exs` — full
  file, read directly to settle the tenant-scoping question (§3) rather than assuming
  it matches REQ-025's `events`/`instance_projections` shape. Confirmed:
  - The table is created inside `if prefix() do ... end` — it is a **tenant-scoped
    table, one physical copy per tenant Postgres schema**, exactly like
    `process_definitions` (`20260816193001_create_process_definitions.exs`, not read in
    full here but its sibling-migration header and `process_definitions.ex`'s own
    moduledoc both confirm the same `if prefix()` pattern).
  - The table carries **no `tenant_id` column at all** — the migration's own header
    comment states this explicitly and explains why: "`tenant_id` is omitted because
    ADP-02's own table mapping lists `process_definitions`, `instance_projections`,
    `tasks`, `tokens`, `audit_entries` and `audit_log` — not this table ... `snapshot.zig`'s
    real INSERT writes no tenant column."
  - `process_definitions`, by contrast, **does** carry a `tenant_id` column (confirmed
    directly in `process_definition.ex`, above) — but this design never writes to
    `process_definitions`, only reads it under a lock (§6.1), so that column is never a
    write target of this requirement's code.
  - No `ON DELETE CASCADE` on `definition_id` — `on_delete: :nothing`, i.e. Postgres's
    default `NO ACTION`. Confirmed this is what AC4 exercises: a `DELETE` against a
    referenced `process_definitions` row raises `foreign_key_violation` (Postgrex
    `23503`), not a successful delete.
- `docs/migration/decisions/0003-ecto-schema-strategy.md` addendum — re-read specifically
  to confirm §3's conclusion: the addendum's rule ("the value written into a table's
  `tenant_id` column is derived by the writing context module from the Postgres schema
  it is already writing into") is a rule about **populating a `tenant_id` column that
  exists**. `instance_definition_snapshots` has no such column, so the addendum's
  mechanism has nothing to apply to for this table. `process_definitions` does have the
  column, but this design never writes it.

PROVENANCE (historical, not current decision authority):
**R-Co source (`src/design/definition.md`'s PD-08 section, `src/definition/snapshot.zig`):
genuinely unreachable on this host**, re-checked directly per this run's own
instructions rather than assumed stale from a prior run:

```
$ find / -maxdepth 3 -iname "R-Co" 2>/dev/null
(no output)
```

Confirmed absent, matching every prior REQ-02x/03x design's finding on this host. This
design therefore works from `docs/requirements.yaml`'s REQ-033 entry (itself a detailed
paraphrase of PD-08, per the task briefing) plus the direct quotations of PD-08 already
embedded — with line numbers — in `instance_definition_snapshot.ex`'s own moduledoc and
the migration's header comment (both read above), which this design treats as reliable
secondary sources.

---

## 1. Scope boundary

**In scope:** one new context module, `Letflow.Definitions.SnapshotStore`
(`lib/letflow/definitions/snapshot_store.ex`), exposing `create/3` and
`get_by_instance_id/2` (arities explained in §2.1). **No migration** — REQ-027 already
shipped both tables this module operates on, unchanged. No changes to
`InstanceDefinitionSnapshot` or `ProcessDefinition`.

**Explicitly NOT in scope, not silently dropped:**

| Not built here | Owned by |
|---|---|
| Calling `create/3` at instance-start time (EE-01), before any event is appended | S3 (the engine doesn't exist in Letflow yet) — per REQ-033's own "BOUNDARY NOTE" and AC5. This module builds only the store's create/retrieve operations in isolation, fully testable without any engine code. |
| Any update or delete path on `instance_definition_snapshots` | Nobody — deliberately absent everywhere, forever. PD-08: "Snapshots read-only after creation; no API endpoint permits modification." |
| `process_definitions` CRUD (`create/1`, `activate/1`, etc.) | REQ-030 (`status: pending` as of this design) |
| Graph/node/edge structural validation | REQ-028/029 (already merged) — this module does not re-validate the graph it copies; it captures `process_definitions.graph` verbatim, whatever REQ-028/029 already let into that row. |

---

## 2. Module and file layout

| Module | File | Kind |
|---|---|---|
| `Letflow.Definitions.SnapshotStore` | `lib/letflow/definitions/snapshot_store.ex` | New context module (public API: `create/3`, `get_by_instance_id/2`) |

No new Ecto schema modules. No new migration. No changes to any other module.

### 2.1 On the requirement text's "`create/2`" / "`get_by_instance_id/1`" naming

REQ-033's own description and acceptance criteria refer to "`create/2` (instance_id,
definition_id)" and "`get_by_instance_id/1`" — those numbers count the **domain**
parameters (two business identifiers; one business identifier), not this module's final
Elixir arity. Per §3 below, every call into this module must also carry `opts:
[prefix: schema_name]` to select the tenant's physical Postgres schema — the same
`opts`-carries-`:prefix` convention `Letflow.EventStore.append/2` already established
(`req025-event-append.md` §5.1), for the identical reason: `instance_id`/`definition_id`
are plain domain values with no tenant-identifying content of their own, so the target
schema must be threaded through explicitly rather than inferred.

**This design therefore builds `create/3(instance_id, definition_id, opts)` and
`get_by_instance_id/2(instance_id, opts)`** — one more positional parameter each than
the requirement text's shorthand implies, stated explicitly here so ELIXIR-DEV doesn't
read the requirement text literally and either (a) build a 2-arity/1-arity function with
no way to select a tenant schema, or (b) invent a different mechanism (e.g. a
`Process`-dictionary-based default prefix) not sanctioned anywhere in this codebase.
`opts`'s `:prefix` key is **required**, not optional with a default — there is no
sensible default tenant schema for either table (§0: both are `if prefix()`-gated,
per-tenant tables with no `public`-schema counterpart).

---

## 3. Why no `tenant_id` derivation is needed here (read before §4/§5)

Unlike `Letflow.EventStore.append/2` (`req025-event-append.md` §3–§4), this module
**never derives or writes a `tenant_id` value anywhere**:

- `instance_definition_snapshots` has **no `tenant_id` column at all** (§0) — there is
  nothing to derive a value for. Tenant isolation for this table's rows is enforced
  entirely by the Postgres schema (`:prefix`) boundary it is written into and read from,
  the same guarantee `req025-event-append.md`'s INV-AP-9 already established for
  `instance_sequence`/`event_idempotency` (two other tables in this codebase with no
  `tenant_id` column, isolated the same way).
- `process_definitions` **does** carry a `tenant_id` column, but this module only
  **reads** that table (the locked `SELECT`, §6.1) — it never inserts or updates a
  `process_definitions` row, so `0003-ecto-schema-strategy.md`'s addendum (which governs
  who populates a `tenant_id` column *at write time*) has no write for it to govern here.

**Consequence:** this module needs no equivalent of
`Letflow.TenantProvisioning.tenant_id_for_schema_name/1` (the pure reverse-mapping
function REQ-025 added). `opts[:prefix]` is used directly, unchanged, as the `prefix:`
value on every `Repo` call this module makes — both the locked read against
`process_definitions` and the insert/read against `instance_definition_snapshots`
target the **same** schema, because both tables live in the same tenant's Postgres
schema by construction (both are `if prefix() do` tables, §0).

**Flagged, not silently assumed:** it is a real, if extremely unlikely, possibility for
a caller to pass a `definition_id` that identifies a real `process_definitions` row
belonging to a *different* tenant's schema than the one named by `opts[:prefix]`. This
design does not treat that as a distinct error case — because the locked `SELECT` (§6.1)
runs `WHERE id = ^definition_id` **scoped to `opts[:prefix]`'s own physical schema**,
such a row is simply invisible to the query (Postgres schema isolation, not a
`tenant_id`-column check) and the call fails with the ordinary `:definition_not_found`
case (§5.3), which is the correct outcome for a genuinely cross-tenant `definition_id` —
no special-casing needed. See OQ-1 (§9) for the one edge this reasoning doesn't fully
close.

---

## 4. Public interface: `Letflow.Definitions.SnapshotStore`

### 4.1 `create/3`

```
@spec create(
        instance_id :: Ecto.UUID.t(),
        definition_id :: Ecto.UUID.t(),
        opts :: [prefix: String.t()]
      ) :: {:ok, InstanceDefinitionSnapshot.t()} | {:error, create_error()}
```

**Semantics, stated once here and not contradicted anywhere below:**

- On the first call for a given `instance_id`: locks the `process_definitions` row
  named by `definition_id` (§6.1), copies its `name`/`version`/`graph` into a fresh
  `instance_definition_snapshots` row (§6.2), and returns `{:ok, snapshot}` where
  `snapshot.graph` equals the source row's `graph` **as read inside this call's own
  lock** — satisfying AC1's "matches the source `process_definitions` row's graph at
  the moment of the call" literally, not "at some earlier or later moment."
- On a **retry** call for an `instance_id` that already has a snapshot: returns
  `{:ok, snapshot}` again — the **pre-existing** row, not a second insert, not an error.
  See §5 for why this design picks the idempotent reading over a
  `SnapshotAlreadyExists`-equivalent error, per AC2's own explicit invitation to choose.
- **No way to distinguish, from the return value alone, "this call just created the row"
  from "this call found an existing row created by an earlier call."** Both return the
  identical shape, `{:ok, %InstanceDefinitionSnapshot{}}`. This is a deliberate design
  choice, not an oversight — see §5's own paragraph on why this design does **not** add
  a `created: boolean()` flag the way `req025-event-append.md`'s `append_result()` adds
  `is_duplicate: boolean()`.

### 4.2 `get_by_instance_id/2`

```
@spec get_by_instance_id(
        instance_id :: Ecto.UUID.t(),
        opts :: [prefix: String.t()]
      ) :: {:ok, InstanceDefinitionSnapshot.t()} | {:error, :snapshot_not_found | :missing_prefix}
```

Read-only, no transaction needed (a single `Repo.get/3`-shaped lookup scoped by
`opts[:prefix]`). **Never returns `nil`** on a miss — AC3's own literal wording. Returns
`{:error, :snapshot_not_found}` instead.

### 4.3 `create_error()` — the full error taxonomy

One distinct, pattern-matchable tag per named failure mode, mirroring the granularity
`req025-event-append.md` §5.3 established as this codebase's convention (one tag per
named case, no generic `:conflict`/`:invalid` catch-all standing in for a named case):

```
@type create_error ::
        :missing_prefix
        # opts has no :prefix key, or its value is not a non-empty binary. Checked
        # first, before any I/O -- §6.1 step P0.
        | :definition_not_found
        # No process_definitions row exists for definition_id, scoped to opts[:prefix]'s
        # schema -- either because no such row exists anywhere, or because it exists only
        # in a *different* tenant's schema (§3's cross-tenant note). REQ-033's own named
        # "not-found error if definition_id doesn't exist" case. §6.1 step L1.
        | Ecto.Changeset.t()
        # A structural changeset failure this design's own pre-checks didn't already
        # catch -- defense in depth (e.g. instance_id/definition_id present but not
        # Ecto.UUID.cast/1-valid, caught by InstanceDefinitionSnapshot.create_changeset/2's
        # own cast). Matches req025's identical catch-all shape (§5.3 there).
        | term()
        # Catch-all for a genuinely unexpected DB error, matching this codebase's
        # established backend_developer_guide.md §3.5 convention.
```

**Deliberately absent from this union, stated explicitly (not silently omitted):**

- **No `SnapshotAlreadyExists`-equivalent tag.** REQ-033's AC2 offers this as one of two
  acceptable readings; §5 explains why this design picks the other one (idempotent
  no-op).
- **No `:instance_id_conflict`-shaped error for "same `instance_id`, different
  `definition_id` on the second call."** This design's idempotency check (§6.2) keys
  purely on `instance_id`, per REQ-033's own literal wording ("`ON CONFLICT
  (instance_id) DO NOTHING`") — it does not compare the second call's `definition_id`
  against the first snapshot's stored `definition_id` and does not surface a mismatch as
  an error. Flagged as OQ-2 (§9), not silently decided as clearly correct.

### 4.4 `get_by_instance_id/2`'s error set

Already fully stated in §4.2's `@spec` — `:snapshot_not_found` and `:missing_prefix`
are the only two cases; this function does no locking, no insert, and has no path to any
of `create/3`'s other error tags.

---

## 5. The idempotency decision (AC2) — stated explicitly, per AC2's own instruction

**Chosen: idempotent no-op.** `create/3` called twice with the same `instance_id`
returns `{:ok, snapshot}` both times, inserts zero additional rows on the second call,
and raises/returns no error. This design does **not** build a
`SnapshotAlreadyExists`-equivalent error case.

**Why, stated so ELIXIR-DEV/REVIEWER can evaluate the choice rather than discover an
unstated assumption mid-build:**

1. REQ-033's own description text is explicit about the mechanism, not just the
   intent: "`ON CONFLICT (instance_id) DO NOTHING` semantics for idempotency (a retry of
   the same `instance_id`'s snapshot creation is a no-op, not a second row)." `ON
   CONFLICT ... DO NOTHING` is, by definition, a silently-successful no-op at the SQL
   level — there is no natural way to layer a distinct `SnapshotAlreadyExists` *error*
   on top of a `DO NOTHING` outcome without adding a second disambiguating read whose
   only purpose is to manufacture an error the underlying SQL operation didn't produce.
2. AC2 itself states the tie-breaker: "since `definition.md`'s own text supports the
   idempotent reading for an EE-01 retry." The scenario this exists for — S3's future
   EE-01 instance-start code retrying `create/3` after a crash/timeout with no way to
   know whether its first attempt's transaction committed — is exactly the shape where
   "was this a race, or a genuine second attempt" is unanswerable from the caller's side,
   and where an idempotent no-op is the only response that lets a naive retry loop
   converge instead of needing its own error-classification logic.
3. `InstanceDefinitionSnapshot`'s own moduledoc (§0) states the OPPOSITE mechanism is
   also *possible* ("Turns a duplicate-instance_id insert into `{:error, changeset}`
   ..., which is what lets REQ-033 return its `SnapshotAlreadyExists`-equivalent") — that
   sentence describes what the schema module's `unique_constraint/3` declaration makes
   *available*, not what REQ-033 is obligated to use. This design uses the schema
   module's `create_changeset/2` unchanged (§6.2) but layers `Repo.insert/2`'s
   `on_conflict: :nothing` option on top, which suppresses the constraint violation at
   the DB level before `unique_constraint/3` ever gets a chance to convert it to a
   changeset error — so the `{:error, changeset}` path that sentence describes is real
   and reachable in principle, but is not the path this design's own `create/3` routes
   through for an ordinary same-`instance_id` retry.

**Why no `created: boolean()` flag on the success return, unlike `req025-event-append.md`'s
`is_duplicate: boolean()`:** REQ-025's `append/2` needed that flag because its own AC3
explicitly required the caller to be able to tell the two cases apart ("returns
`is_duplicate: true`"). REQ-033's AC2 has no equivalent literal requirement — it only
requires "no error, no second row." Adding an unrequested flag would be scope creep this
design deliberately avoids; if a future requirement (e.g. an S3 EE-01 caller that wants
to log "snapshot already existed" distinctly from "snapshot just created") needs that
signal, it can be added then as a non-breaking change to this function's success shape.

---

## 6. Behavior, in order

### 6.1 Pre-transaction phase

```
P0. Validate opts[:prefix] is present and a non-empty binary.
    Missing, nil, or "" -> {:error, :missing_prefix}
    Otherwise -> continue, bind prefix = opts[:prefix]
```

### 6.2 Transactional phase — one `Repo.transaction/2`, `prefix: prefix` on every operation

**A single `Repo.transaction/2` wrapping an anonymous function, not an `Ecto.Multi`.**
Flagged as a deliberate departure from `req025-event-append.md`'s `Ecto.Multi` shape:
that design used `Multi` because it had six dependent, individually-named steps whose
failure needed distinct handoff to the caller. This operation has exactly two dependent
steps sharing one lock's lifetime, with no need for `Multi`'s step-naming/introspection
machinery — a plain `Repo.transaction/2` closure is the simpler, equally correct tool
for two steps. ELIXIR-DEV may use `Ecto.Multi` instead if it turns out to read more
consistently with this module's siblings; the requirement is the transaction boundary
and step order below, not the specific Ecto API used to express it.

```
L1. Locked read of the source process_definitions row.
    Compose an Ecto.Query against ProcessDefinition: WHERE id == ^definition_id,
    with the query's lock option set to the FOR SHARE lock mode (Ecto's query-composition
    lock feature -- e.g. the `lock:` option on the query, or the equivalent
    Ecto.Query.lock/2 call -- never a hand-written SQL string, per INV-7). Execute it
    scoped to prefix: prefix, inside the open transaction, and hold whatever lock
    Postgres grants for the remainder of this transaction.

    No row found
      -> abort the transaction, returning {:error, :definition_not_found}. Nothing has
         been written anywhere (L2 never runs).

    Row found
      -> continue, bind source_definition (the locked process_definitions row: its
         name, version, and graph fields, read at this exact moment -- AC1's "at the
         moment of the call").

L2. Insert-or-ignore the snapshot row.
    Build the InstanceDefinitionSnapshot.create_changeset/2 attrs as:
      instance_id: the instance_id argument
      definition_id: the definition_id argument
      definition_name: source_definition.name
      definition_ver: source_definition.version
      graph: source_definition.graph
    Insert it, scoped to prefix: prefix, with the insert configured as an atomic
    insert-or-ignore keyed on instance_id (Repo.insert/2's on_conflict: :nothing,
    conflict_target: :instance_id) -- so a concurrent or repeat call for the same
    instance_id is silently suppressed at the DB level rather than raising or being
    converted to a changeset error by the schema module's own unique_constraint/3
    (§0's citation of that declaration; still present and still correct for any insert
    path that does NOT pass on_conflict: :nothing, but this call does).

L3. Re-select the authoritative row by instance_id, scoped to prefix: prefix, still
    inside the same transaction. This step exists because Repo.insert/2 with
    on_conflict: :nothing returns an ambiguous struct when the underlying insert is
    suppressed (its read_after_writes column, snapshotted_at, is not populated from a
    row that was never actually written) -- so this design never trusts L2's own return
    value directly, and instead always re-reads by the row's real primary key
    (instance_id) to get the authoritative, fully-populated row regardless of whether
    L2 really inserted or was suppressed. This is a simplified variant of the
    "insert-then-re-select" idiom req025-event-append.md §6.2.3 (M3) used for the same
    ambiguity -- simpler here because instance_id is instance_definition_snapshots' own
    primary key, so no surrogate id is needed to perform the re-select.

    Step succeeds with the row read at L3. This is always found -- either L2's own
    insert just created it, or a strictly earlier call already had.

Transaction commits -> return {:ok, snapshot} (the row read at L3).
```

### 6.3 Why this design does not route through either changeset-shaped error the schema
module's moduledoc names

`InstanceDefinitionSnapshot`'s moduledoc (§0) describes two changeset-error paths its
`unique_constraint/3`/`foreign_key_constraint/3` declarations exist to enable:
`SnapshotAlreadyExists` (from the `:instance_id` unique constraint) and
`DefinitionNotFound` (from the `:definition_id` foreign-key constraint). This design's
`create/3` reaches its equivalent two outcomes differently:

- **`:definition_not_found`** is produced by L1's locked read finding no row — the
  insert at L2 is never even attempted with a dangling `definition_id`, so the
  `foreign_key_constraint/3` declaration is never exercised on this call path. It
  remains in the schema module as defense-in-depth for any *other* future caller that
  inserts into this table without first taking L1's lock (none exists today), not
  because this design routes through it.
- **The idempotent no-op** (§5) is produced by L2's `on_conflict: :nothing`, which
  suppresses the conflict at the DB level before Postgres ever raises the error
  `unique_constraint/3` exists to catch and convert. The `unique_constraint/3`
  declaration is, likewise, unexercised by this call path and remains as
  defense-in-depth for a hypothetical future insert path that omits `on_conflict:`.

Stated explicitly so a future reader doesn't conclude this design contradicts the schema
module's own moduledoc — it uses the same changeset, just with an `on_conflict:` option
and a preceding lock that make both documented error paths structurally unreachable from
`create/3` specifically.

### 6.4 `get_by_instance_id/2`

```
get_by_instance_id(instance_id, opts):
  P0 (same as §6.1) -- missing/invalid opts[:prefix] -> {:error, :missing_prefix}

  Otherwise: a single read against InstanceDefinitionSnapshot, WHERE instance_id ==
  ^instance_id, scoped to prefix: opts[:prefix]. No lock, no transaction -- this table
  is write-once (§0), so there is no concurrent-write hazard a read needs to guard
  against here.

    no row found -> {:error, :snapshot_not_found}
    row found    -> {:ok, snapshot}
```

---

## 7. AC4 — the delete-rejection case is not this module's code

AC4 ("deleting a `process_definitions` row that an `instance_definition_snapshots` row
references is rejected by the database ... a snapshot is never removed as a side effect
of deleting its source definition") is satisfied entirely by **REQ-027's already-shipped
migration** (`on_delete: :nothing` on `instance_definition_snapshots.definition_id`, §0)
— there is no code in `SnapshotStore` that participates in or could weaken this
guarantee, because `SnapshotStore` exposes no delete path onto either table at all.
Stated here so TEST-DESIGNER knows the corresponding test exercises `Repo.delete/2`
(or the equivalent SQL) directly against a `process_definitions` row, asserts it raises/
returns `foreign_key_violation` (Postgrex `23503`), and then asserts the snapshot row is
still present and unchanged via `get_by_instance_id/2` — not a `SnapshotStore` function
under test for AC4's own delete attempt, since none exists to call.

---

## 8. Required moduledoc content (AC5 and others)

`Letflow.Definitions.SnapshotStore`'s `@moduledoc` must state, verbatim in substance:

1. **AC5, verbatim in substance:** the EE-01 instance-start integration point — the
   engine calling `create/3` "at instance-start time, before any event is appended" — is
   **S3 scope, not built here**. This module builds only the store's create/retrieve
   operations in isolation, fully testable without any engine code, matching
   `definition.md`'s own "Stage 2 boundary" rationale for why this file lives in the
   definition module rather than `src/engine/`.
2. **The idempotency choice (§5):** `create/3` is idempotent on `instance_id` — a retry
   with the same `instance_id` returns the pre-existing snapshot, not an error and not a
   second row — and this is a deliberate reading of REQ-033's AC2, not the only one AC2
   permits.
3. **Write-once, no update/delete path anywhere on this module** — matching
   `InstanceDefinitionSnapshot`'s own moduledoc; PD-08's "Snapshots read-only after
   creation; no API endpoint permits modification."
4. **No `tenant_id` derivation anywhere in this module** (§3), and why: neither table
   this module writes carries a `tenant_id` column that this module's own code
   populates — `instance_definition_snapshots` has none at all, and this module never
   writes to `process_definitions` (the one table that does have the column).
5. **`opts[:prefix]` is required on every call, with no default tenant schema** (§2.1).

---

## 9. Open questions — explicitly listed, not silently resolved

**OQ-1 (MINOR).** §3 argues that a `definition_id` belonging to a different tenant's
`process_definitions` row is indistinguishable, from `create/3`'s own vantage point,
from a `definition_id` that doesn't exist at all — both produce `:definition_not_found`,
because L1's locked read is scoped to `opts[:prefix]`'s physical schema and simply
cannot see a row living in a different tenant's schema. This is very likely the correct,
secure behavior (it leaks no information about another tenant's data), but it has not
been independently confirmed against PD-08's actual text (unreachable on this host, §0)
as the intended behavior for that specific scenario, as opposed to merely being this
design's own reasoned default. Flagged for SECURITY-REVIEWER to confirm as correct
rather than merely unobjectionable.

**OQ-2 (MINOR).** §4.3 states this design does not check whether a second `create/3`
call for an already-snapshotted `instance_id` supplies a *different* `definition_id`
than the first call did — the idempotency check keys purely on `instance_id`, per
REQ-033's own literal `ON CONFLICT (instance_id) DO NOTHING` wording. A caller bug that
retries `create/3` with the wrong `definition_id` would silently succeed, returning the
original (different-definition) snapshot with no signal that the two calls disagreed.
This mirrors the literal SQL semantics REQ-033's own description names, but is worth
REVIEWER's explicit sign-off given how close in shape it is to the exact "silently
attribute to the wrong X" failure mode `req025-event-append.md` §3 treated as
unacceptable for `tenant_id` specifically (there, resolved by rejecting the call
outright rather than silently reconciling). The two cases are not identical — this one
is about which of two potentially-legitimate `definition_id`s a snapshot ends up
recording, not about cross-tenant attribution — but the shape (silent
second-caller-loses-quietly semantics under `ON CONFLICT DO NOTHING`) is similar enough
to flag rather than wave through by analogy to REQ-033's plain SQL wording alone.

PROVENANCE (historical, not current decision authority):
**OQ-3 (MINOR).** L1's lock mode is specified as `FOR SHARE` per REQ-033's own text
("prevents a concurrent delete or exclusive-lock write from racing the snapshot
capture"). This design has not independently verified against PD-08's primary text
(unreachable on this host, §0) that `FOR SHARE` (rather than, say, `FOR UPDATE`) is the
exact lock mode PD-08 specifies — it is taken as given from the requirement text's own
quotation. If a future run regains access to R-Co's `definition.md`/`snapshot.zig` and
finds a different lock mode stated there, this section should be re-verified against the
primary source.

---

## 10. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Definitions.ProcessDefinition` | `SnapshotStore` → `ProcessDefinition` (REQ-027) | Read-only, locked (`FOR SHARE`) query against `process_definitions`, scoped by `opts[:prefix]` (§6.1 L1). No insert, update, or delete. |
| `Letflow.Definitions.InstanceDefinitionSnapshot` | `SnapshotStore` → `InstanceDefinitionSnapshot` (REQ-027) | Consumes `create_changeset/2` unchanged (§6.2 L2), with `on_conflict: :nothing` layered on at the `Repo.insert/2` call site — no new changeset added to that module. Also a plain scoped read (§6.2 L3, §6.4). |
| `Letflow.Repo` | `SnapshotStore` → `Repo` | Every operation passes `prefix: opts[:prefix]` explicitly; no `@schema_prefix` anywhere, matching both source schema modules' own moduledocs. |
| S3 / EE-01 instance-start mechanism (not yet built) | S3 → `SnapshotStore` | Will call `create/3` before appending the instance's first event. Not built or anticipated here (§1, §8). |

---

## 11. Acceptance-criteria traceability

| REQ-033 acceptance criterion | Concrete design element |
|---|---|
| 1. "`create/2` against a valid `definition_id` inserts a snapshot row whose graph matches the source `process_definitions` row's graph at the moment of the call" | §6.2 L1 (locked read) + L2 (copies `source_definition.graph` verbatim into the insert) — the lock held from L1 through L2's commit guarantees no concurrent write to the source row can be observed between the read and the copy |
| 2. "`create/2` called twice with the same `instance_id` is idempotent ... pick one behavior and state which in the moduledoc" | §5 (the idempotent reading, chosen and justified) + §6.2 L2/L3 (`on_conflict: :nothing` + re-select) + §8 item 2 (moduledoc requirement) |
| 3. "`get_by_instance_id/1` against an `instance_id` with no snapshot returns a not-found error, not `nil` silently" | §4.2's `@spec` (`{:error, :snapshot_not_found}`, never `nil`) + §6.4 |
| 4. "deleting a `process_definitions` row that an `instance_definition_snapshots` row references is rejected by the database ... a snapshot is never removed as a side effect" | §7 — satisfied entirely by REQ-027's already-shipped `on_delete: :nothing`; no `SnapshotStore` code participates, and none is needed |
| 5. "the moduledoc explicitly states the EE-01 instance-start integration point is S3 scope, not built here" | §8 item 1 |

---

## 12. Invariants

| id | Invariant | Enforced where |
|---|---|---|
| INV-SS-1 | `create/3` never writes a `tenant_id` value anywhere — neither table this module writes has a column this module populates | §3, §8 item 4 |
| INV-SS-2 | Every `Repo` call this module makes passes `prefix: opts[:prefix]` explicitly; `opts[:prefix]` is required, never defaulted | §2.1, §6.1 P0, §6.2, §6.4 |
| INV-SS-3 | `create/3`'s snapshot `graph` always reflects `process_definitions.graph` as read under this call's own `FOR SHARE` lock, never a value read before the lock or after it releases | §6.2 L1/L2 |
| INV-SS-4 | A retry `create/3` call for an already-snapshotted `instance_id` writes zero additional rows and returns the pre-existing row, never an error | §5, §6.2 L2/L3 |
| INV-SS-5 | `SnapshotStore` exposes no update or delete path onto `instance_definition_snapshots`, ever | §1, §8 item 3 |
| INV-SS-6 | `get_by_instance_id/2` never returns `nil` — a miss is always `{:error, :snapshot_not_found}` | §4.2, §6.4 |
