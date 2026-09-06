# Design: REQ-054 — Instance state snapshots (`SnapshotWriter`) + REQ-053 replay-source selection

**Requirement:** REQ-054 (stage S3, extends REQ-053's already-shipped
`Letflow.Engine.Reconstruction.reconstruct_instance/2`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ054-20260819`, WF-02 Step 1
**This document produces:** the `instance_state_snapshots` migration/schema shape,
`Letflow.Engine.SnapshotWriter`'s public `@spec`s, and the modification to
`Letflow.Engine.Reconstruction.replay/3` that lets it start folding from a
deserialised snapshot instead of always from the graph's `:START` seed — no
implementation code.

---

## 0. Sources read for this design

`docs/agents/instructions/core-directives.md`, `docs/agents/workflows/WF-02_requirement_implementation.md`
Step 1, `docs/guides/backend_developer_guide.md`, `docs/anti-patterns.md`,
`.claude/agents/code-designer.md`. Shipped code read in full:
`lib/letflow/engine/reconstruction.ex` (REQ-053, the function this requirement
modifies), `lib/letflow/engine/instance_state.ex` (REQ-044, the exact struct to
serialise), `lib/letflow/engine/token.ex`, `lib/letflow/event_store/instance_projection.ex`
(confirms `last_event_seq` already exists as a per-instance row-based cursor),
`lib/letflow/engine/execution_error.ex` and `lib/letflow/engine.ex` (confirm
`error_detail` lives on `instance_projections`, not on `InstanceState.t()` — see §2.1),
`lib/letflow/tenant_provisioning.ex` (`@tenant_scoped_migration_manifest`,
`tenant_scoped_migrations/0`), `priv/repo/migrations/20260816193002_create_instance_definition_snapshots.exs`,
`priv/repo/migrations/20260818110003_create_tasks.exs`,
`priv/repo/migrations/20260818110002_create_tokens.exs` (FK/index/no-`tenant_id`
migration shape for a comparable schema-per-tenant business table). Design docs:
`lib/letflow/design/req053-state-reconstruction.md`,
`lib/letflow/design/req044-transition-kernel.md`,
`lib/letflow/design/req045-instance-start-engine-shell.md` §1 (the process-vs-row
resolution this design's open question cites). Decision records:
`docs/migration/decisions/0006-identity-tables-schema-per-tenant.md` (D2 — no
`tenant_id` on schema-isolated business tables). Stage doc:
`docs/migration/stage-3-instance-engine.md` (its "second Early finding" and where
REQ-045/REQ-054 apply it, both cited in §6 below).

## 1. Naming: two "snapshot" tables that must never be confused

**Stated here, and required verbatim-in-substance in `SnapshotWriter`'s moduledoc
(AC5):**

`instance_state_snapshots` (this requirement) is **not** the same thing as
`instance_definition_snapshots` (REQ-027/REQ-033, `Letflow.Definitions.SnapshotStore`).
The two are one word apart and a name collision here is a silent data-model error:

| | `instance_definition_snapshots` (REQ-027/033) | `instance_state_snapshots` (REQ-054) |
|---|---|---|
| Content | The immutable PD-08 **definition graph** (`process_definitions.graph`) bound to an instance at start | The periodic **execution state** (`InstanceState.t()`) at some point during the run |
| Cardinality | Exactly one row per instance, write-once (PK is bare `instance_id`) | Zero or more rows per instance, accumulating over the instance's life |
| Mutability | Write-once, never updated, never superseded | New rows are appended periodically; older rows are never updated in place either, but the *set* of rows for an instance grows |
| Read path | `SnapshotStore.get_by_instance_id/2` — called once per reconstruction, before any event is folded (§5.1 of the REQ-053 design) | `SnapshotWriter.latest_snapshot/2` (new, this requirement) — called once per reconstruction to pick a replay source (§4 below) |
| Owning module | `Letflow.Definitions.SnapshotStore` | `Letflow.Engine.SnapshotWriter` (new) |

## 2. `InstanceState.t()` → snapshot payload mapping

### 2.1 `error_detail` — flagged divergence from the requirement text (not silently resolved)

The requirement text names `error_detail` as one of the fields `take_snapshot`
serialises, alongside `status`, `tokens`, `variables`, and `pending_task_nodes`. Read
directly against the shipped `Letflow.Engine.InstanceState` struct (`lib/letflow/engine/instance_state.ex`),
**no `error_detail` field exists on `InstanceState.t()`** — its fields are exactly
`instance_id`, `status`, `tokens`, `variables`, `pending_task_nodes`, `join_counters`.
`error_detail` is a column on `instance_projections` (`Letflow.Engine.ExecutionError`,
`execution_error.ex:221-229`), populated by the write path, not by anything
`InstanceState.t()` carries.

**Resolution for this design:** `take_snapshot/N` serialises exactly
`InstanceState.t()`'s own fields — `status`, `tokens`, `variables`,
`pending_task_nodes`, and `join_counters` (REQ-051's parallel-join cohort tracking,
also part of `InstanceState.t()` and also omitted from the requirement text's list —
the same class of omission, flagged the same way). It does **not** take a separate
`error_detail` parameter and does not read `instance_projections` to backfill one.
Consequence: a snapshot taken while `status == :error` captures that status but not
the structured error detail; a reconstruction whose replay source is that snapshot
also will not have `error_detail` (REQ-053's `replay/3` never populates it into
`InstanceState.t()` either — it has nowhere to put it). This is a pre-existing gap in
what `InstanceState.t()` itself can represent, not one this requirement introduces or
enlarges; flagged for REVIEWER rather than silently adding a field to
`InstanceState.t()` that REQ-044/REQ-061's own designs never named.

### 2.2 Serialisation shape

```
@type snapshot_state :: %{
  status: InstanceState.status(),               # atom, serialised as its Ecto.Enum-compatible string
  tokens: [Token.t()],                            # list of %{node_id, token_id, branch_id, waiting_child_instance_id}
  variables: map(),
  pending_task_nodes: [Token.t()],
  join_counters: %{optional(String.t()) => JoinCounter.t()}
}
```

Stored as one `jsonb` column (`state`, §3). `Token.t()` and `JoinCounter.t()` are
plain structs with no `Ecto.Type` of their own (`instance_state.ex` moduledoc: "Plain
struct, not an `Ecto.Schema`") — `take_snapshot` is responsible for converting each
struct to a plain map before insert (`Map.from_struct/1` plus atom-key → string-key
JSON normalisation, matching how `Reconstruction.write_back/3` already converts
`InstanceState.tokens` to `current_nodes` for a different, narrower column) and
`latest_snapshot`/the replay-source path is responsible for the reverse (string-keyed
JSON map → `%Token{}`/`%JoinCounter{}` structs, `status` string → atom via the same
value set `InstanceProjection`'s `Ecto.Enum` already declares:
`active: "ACTIVE", completed: "COMPLETED", cancelled: "CANCELLED", error: "ERROR"`).
This round-trip (struct → plain map → jsonb → plain map → struct) is exactly what
AC2 ("deserialised state equals the `InstanceState` passed in, round-tripped
field-for-field") tests.

## 3. `instance_state_snapshots` table

Schema-per-tenant, per REQ-022 §4 / Decision 0006 D2 — **no `tenant_id` column**,
same as `events`, `tokens`, `tasks`, `instance_definition_snapshots`, and every other
business table added since D2 shipped.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | `:binary_id` | not null | client-generated (`Ecto.UUID.generate/0`, `autogenerate: true` at the schema layer — matches `Letflow.Engine.Task`'s `@primary_key {:id, :binary_id, autogenerate: true}`) | primary key. A bare `instance_id` PK (`instance_definition_snapshots`'s shape) does not fit here — this table is one-to-many per instance, not one-to-one. |
| `instance_id` | `:binary_id` | not null | — | `references(:instance_projections, column: :instance_id, type: :binary_id, on_delete: :restrict)` — matches `tasks`/`tokens`'s own `:restrict` choice and stated reason (`20260818110003_create_tasks.exs` header: "no delete path exists for `instance_projections` anywhere in Letflow yet, so `:restrict` fails loudly instead of silently losing tenant data"). Same reasoning applies verbatim here. |
| `sequence_number` | `:integer` | not null | — | the event-log `sequence_number` (per `Reconstruction.merged_event().sequence_number`, `pos_integer()`) this snapshot's state is current *as of* — i.e. every event with `sequence_number <= this value` has already been folded into `state`, and none with a greater value has. This is the value §4's replay-source selection filters `sequence_number > S` against. |
| `state` | `:map` (jsonb) | not null | — | §2.2's `snapshot_state()` shape, plain built-in `:map` Ecto type (a JSON *object*, not the array-typed `current_nodes` special case `InstanceProjection` needed its own `JSONArray` type for — no such special-casing needed here). |
| `taken_at` | `:utc_datetime_usec` | not null | `fragment("(now() AT TIME ZONE 'utc')")` | matches `instance_definition_snapshots.snapshotted_at`'s and REQ-023's own mitigation against an implicit local-timezone cast on a bare `NOW()`. No `updated_at` — a snapshot row is write-once, never updated in place (new snapshots are new rows, matching this requirement's own "mutable in the sense that new rows accumulate" framing — the *table* accumulates, individual *rows* do not change after insert). |

### Indexes

- `create index(:instance_state_snapshots, [:instance_id], name: :idx_iss_instance, prefix: prefix())`
  — mandatory: Postgres does not auto-index the referencing side of a FK (same
  reasoning as every prior FK-bearing migration in this schema — `tasks`, `tokens`,
  `instance_definition_snapshots`).
- `create index(:instance_state_snapshots, [:instance_id, :sequence_number], name: :idx_iss_instance_seq, prefix: prefix())`
  — the query this table exists to serve: "give me the latest snapshot for this
  instance" is `... WHERE instance_id = ^id ORDER BY sequence_number DESC LIMIT 1`,
  and this composite index makes that an index-only scan rather than a filter +
  sort. Not declared `unique` — see §6's open question; a future cadence-check
  design could legitimately want two snapshots at the same `sequence_number` to be
  structurally impossible, but this design does not assume that constraint without
  a resolved cadence mechanism to justify it (a row-based cadence check racing two
  concurrent writers, per §6, could otherwise violate a uniqueness constraint this
  design has no mechanism yet to prevent — better to leave it unconstrained now than
  add a constraint a later requirement discovers is wrong).

### Registration (REQ-022 §4 mandatory pattern)

New migration file, e.g. `priv/repo/migrations/20260821000001_create_instance_state_snapshots.exs`
(exact timestamp ELIXIR-DEV's choice, must sort after `20260818110003_create_tasks.exs`
per its FK on `instance_projections`), wrapped in `if prefix() do ... end` (REQ-022 §4's
mandatory tenant-scoped guard — a plain `mix ecto.migrate` must no-op on it), **and**
a new entry appended to `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`
list (`lib/letflow/tenant_provisioning.ex:283-`) plus `tenant_scoped_migrations/0`
picking it up automatically (no separate change needed there — it already maps over
the manifest). Both halves — the migration file's own guard, and the manifest entry —
are mandatory; a migration with one but not the other is either inert (never selected)
or corrupts `public` on a plain migrate run, per every prior tenant-scoped migration's
own header warning.

## 4. `Letflow.Engine.SnapshotWriter` — new module, `lib/letflow/engine/snapshot_writer.ex`

PROVENANCE (historical, not current decision authority):
Ports `snapshot_writer.zig` (R-Co's ISS-601, design artefact `src/design/iss601_state_snapshots.md`).
Sibling placement to `reconstruction.ex`/`transition.ex`/`instance_state.ex` under
`lib/letflow/engine/`.

### 4.1 `take_snapshot/3`

```
@type take_snapshot_opts :: [prefix: String.t()]

@spec take_snapshot(
        instance_id :: Ecto.UUID.t(),
        InstanceState.t(),
        sequence_number :: pos_integer(),
        opts :: take_snapshot_opts()
      ) :: {:ok, snapshot_id :: Ecto.UUID.t()} | {:error, term()}
```

(4-arg total, counting `opts`; requirement text's "take_snapshot/N" — N is 4.) One
`Repo.insert/2` of a new `instance_state_snapshots` row: `id` freshly generated,
`instance_id`, `sequence_number` as given, `state` per §2.2's serialisation, `taken_at`
DB-defaulted. No changeset-based public write surface is required here — unlike
`InstanceProjection`, this table has no update path and no user-facing validation
surface (the caller is always this module's own internal engine code, never an
API-facing form), so a bare `Repo.insert/2` against an `Ecto.Schema` struct (or an
internal, unexported changeset if ELIXIR-DEV finds a validation need — e.g.
`sequence_number > 0` — during implementation) is sufficient; CODE-DESIGNER does not
mandate a public `changeset/2` function the way schema modules with caller-supplied
untrusted attrs (e.g. `InstanceProjection`) need one.

Does **not** validate that `sequence_number` is greater than any prior snapshot's —
that ordering guarantee is the caller's responsibility (§5's `maybe_take_snapshot/N`
is the only caller in this codebase, and it only ever calls with a monotonically
increasing `last_event_seq`-derived value). A caller violating that ordering produces
a real but harmless second row at an out-of-order `sequence_number`; `latest_snapshot/2`
(§4.3) is defined as "highest `sequence_number`", not "most recently inserted", so it
tolerates this without corrupting replay correctness — flagged here rather than
silently assumed.

### 4.2 `maybe_take_snapshot/4`

```
@type cadence_opts :: [prefix: String.t(), interval: pos_integer()]

@spec maybe_take_snapshot(
        instance_id :: Ecto.UUID.t(),
        InstanceState.t(),
        current_sequence_number :: pos_integer(),
        opts :: cadence_opts()
      ) :: {:ok, :snapshotted | :skipped} | {:error, term()}
```

PROVENANCE (historical, not current decision authority):
`interval` defaults to `1000` (`snapshot_writer.zig`'s `DEFAULT_SNAPSHOT_INTERVAL`,
per the requirement text) when omitted from `opts`. Cadence check: snapshot when
`current_sequence_number` reaches or crosses a multiple of `interval` relative to the
instance's own last snapshot — see §6 for the open question on exactly *how* that
"events since last snapshot" count is obtained (the two candidate mechanisms differ in
what `maybe_take_snapshot/4`'s own body needs to query/hold, but not in this public
signature). Returns `{:ok, :snapshotted}` when it wrote a row (delegating to
`take_snapshot/4`), `{:ok, :skipped}` when the interval has not yet been reached —
both are success outcomes, not an error tuple, since "no snapshot needed yet" is
normal, expected control flow, not a failure.

**Call sites (both named by the requirement text, neither built by this
requirement):** after event appends (i.e. from wherever `Letflow.Engine`'s existing
event-append call sites — `create/2`, `complete_task/3`, and REQ-061's
`ExecutionError.append_multi/3` — currently persist an event) and on instance
completion. Wiring `maybe_take_snapshot/4` into those call sites is this
requirement's own implementation scope (ELIXIR-DEV, not a future requirement) — listed
here as call-site *locations*, not as a deferral.

### 4.3 `latest_snapshot/2`

```
@spec latest_snapshot(instance_id :: Ecto.UUID.t(), opts :: [prefix: String.t()]) ::
        {:ok, {InstanceState.t(), sequence_number :: pos_integer()}} | {:error, :snapshot_not_found}
```

New, small read function this requirement also needs (not named by the requirement
text's bullet list, but required by §5's replay-source selection — flagged as this
design's own necessary addition, same class of gap `req053`'s design doc §9 OQ-4
flagged for its own write-back insert path). One query: `instance_state_snapshots
|> where(instance_id: ^id) |> order_by(desc: :sequence_number) |> limit(1)`, then
deserialise `state` back into an `InstanceState.t()` via §2.2's reverse mapping.
`{:error, :snapshot_not_found}` when no row exists for the instance (the common case
for any instance that has not yet crossed one snapshot interval — REQ-053's replay
falls back to full-log replay from sequence 1 in this case, §5 below).

## 5. Modification to `Letflow.Engine.Reconstruction`

### 5.1 What changes and what does not

`reconstruct_instance/2`'s public `@spec` and `reconstruct_result()` shape are
**unchanged** — this requirement is purely an internal optimisation of how `replay/3`
arrives at its result, not a change to the function's contract. `read_full_log/2`
(§4 of the REQ-053 design) is **unchanged** in its query shape but gains one new
input: the replay-source selection (§5.2 below) determines the *lower bound* on which
events `read_full_log/2` needs to fetch — the design below states this as a new
`min_sequence_number` filter, not a change to the merge/dedup logic itself, which
still operates over whatever event range it is asked to read.

```
@spec read_full_log(
        instance_id :: Ecto.UUID.t(),
        prefix :: String.t(),
        min_sequence_number :: pos_integer()
      ) :: {:ok, [merged_event()]} | {:error, term()}
```

(3-arg, widened from REQ-053's 2-arg — same class of deliberate divergence
`reconstruction.ex`'s own moduledoc already documents for `write_back/3`'s opts-list
widening, §"Deliberate divergences" point 1. `min_sequence_number` defaults to `1`
for the full-replay path, so REQ-053's existing callers/tests that expect "replay
everything" keep working unchanged by passing `1`.) Both `Event` and `ArchivedEvent`
queries gain a `where([e], e.sequence_number > ^(min_sequence_number - 1))` clause
(i.e. `>= min_sequence_number`) alongside their existing `instance_id ==` filter.

### 5.2 `replay/3`'s new first step: replay-source selection

PROVENANCE (historical, not current decision authority):
Ports `reconstruction.zig`'s `determineReplaySourceForSnapshot()`. Inserted as a new
first branch in `replay/3`, **before** its existing `SnapshotStore.get_by_instance_id/2`
call (§5.1 of the REQ-053 design) — that call remains, unchanged, for graph
resolution; this is an entirely separate lookup, against a different table, for a
different purpose (state seed vs. graph seed). Rename the local var if needed to keep
the two "snapshot" lookups textually distinct in the diff (e.g. `graph_snapshot` vs.
`state_snapshot`), reinforcing §1's naming distinction inside the module's own source,
not just its prose.

```
@spec select_replay_source(instance_id :: Ecto.UUID.t(), prefix :: String.t()) ::
        {:full_replay, min_sequence_number :: 1}
        | {:from_snapshot, InstanceState.t(), min_sequence_number :: pos_integer()}
```

- `SnapshotWriter.latest_snapshot/2` returns `{:error, :snapshot_not_found}` →
  `{:full_replay, 1}`. `replay/3` proceeds exactly as REQ-053 built it: resolve the
  graph snapshot, seed state from `:START` (§5.2 of the REQ-053 design), fold every
  event from `read_full_log(id, prefix, 1)`.
- `SnapshotWriter.latest_snapshot/2` returns `{:ok, {state_snapshot, snap_seq}}` →
  `{:from_snapshot, state_snapshot, snap_seq + 1}`. `replay/3` still resolves the
  graph snapshot (needed by `Transition.transition/3` for every subsequent fold step
  regardless of state source — the graph and the state are independent axes), but
  seeds the fold with `state_snapshot` (deserialised, §2.2) instead of §5.2's
  `:START`-token construction, and folds only `read_full_log(id, prefix, snap_seq + 1)`
  — i.e. events with `sequence_number > snap_seq`.
- `fold_events/3`, `apply_event/3`, and every per-event-type replay clause (REQ-053
  design §5.3) are **unchanged** — they operate on an `InstanceState.t()` and a list
  of `merged_event()`s regardless of whether that state came from `:START` or from a
  deserialised snapshot. This is the mechanism that makes AC4 below checkable: the
  same fold code runs either way, so a divergence between the two paths can only come
  from the seed state itself (i.e. from `SnapshotWriter`'s serialise/deserialise
  round-trip, §2.2), not from two different fold implementations silently drifting.

### 5.3 Existence determination (interaction with REQ-053 §4's existing rule)

REQ-053's existing rule — "`instance_not_found` only when the merged event list is
empty **and** `SnapshotStore.get_by_instance_id/2` (graph) is `:snapshot_not_found`"
— is unchanged, but now additionally must not be confused with a *state*-snapshot
miss. A `{:full_replay, 1}` result from §5.2 (no state snapshot yet — the common,
zero-events-so-far case) is normal, not evidence of a missing instance; only the
existing graph-snapshot-plus-empty-event-list combination decides `:instance_not_found`.
No change to that decision's inputs, stated here only to make explicit that this
requirement introduces no new way to reach `:instance_not_found`.

### 5.4 Correctness bar (AC4): both paths must agree

The requirement's stated correctness bar — a snapshot-sourced reconstruction must
produce a state identical to full-log reconstruction of the same instance — is a
**test-design concern** (TEST-DESIGNER's job, not resolved by this design beyond
making it checkable): call `reconstruct_instance/2` once with a real snapshot present
(exercises `{:from_snapshot, ...}`) and once against the same instance with
`SnapshotWriter.latest_snapshot/2` stubbed/bypassed to force `{:full_replay, 1}` (or,
more directly, against a second instance with identical event history but no snapshot
row), then assert the two `InstanceState.t()` results are equal under §6 of the
REQ-053 design's own stated definition of "equal" (node-id-multiset over
`current_nodes`-equivalent fields, since `token_id`/`branch_id` are freshly minted on
every fold regardless of seed — this remains true whether the seed came from `:START`
or from a snapshot's deserialised tokens, since `apply_event/3`'s `TASK_COMPLETED`
clause always matches by `node_id`, never by the snapshot's stored `token_id`, so a
stored `token_id` surviving in a snapshot's `state` column is informational only, not
load-bearing for AC4's comparison — but *is* still round-tripped byte-for-byte by
AC2's narrower "serialise this exact struct, get the same struct back" test).

## 6. Open question — where does the "events since last snapshot" counter live?
## (flagged per the requirement text's explicit instruction; not resolved here)

`maybe_take_snapshot/4` (§4.2) needs to know, at each event-append call site, how many
events have accumulated since the instance's last snapshot, to decide whether
`current_sequence_number` has crossed a multiple of `interval`. Two candidate
mechanisms, deliberately left to ELIXIR-DEV rather than picked here:

1. **Pure row-based check, no in-memory counter.** `instance_projections.last_event_seq`
   (REQ-023, already shipped and already updated on every write path — confirmed at
   `lib/letflow/event_store/instance_projection.ex`'s schema, `field(:last_event_seq,
   :integer, default: 0)`) already tracks the latest sequence per instance. Combined
   with `SnapshotWriter.latest_snapshot/2`'s own `sequence_number` (§4.3), a purely
   row-based cadence check is possible with zero additional process state:
   `current_sequence_number - (latest_snapshot_sequence_number || 0) >= interval`.
   This fits `docs/migration/stage-3-instance-engine.md`'s second Early finding
   (quoted in full at that doc's lines 174-184) and, concretely, `req045-instance-start-engine-shell.md`
   §1's resolution of the adjacent process-vs-row question for EE-01 itself: instances
   are **plain transactional context-module calls, no `:gen_statem`, no
   `DynamicSupervisor`, no per-instance process** — REQ-045's own reasoning (every
   write already transactional; REQ-053's reconstruction, this requirement's own
   sibling, makes state cheaply rebuildable; no timer/backpressure/OS-resource) applies
   with equal or greater force to a per-instance snapshot *cadence counter*, which is
   even less than the full instance state REQ-045 already declined to keep in a
   process.
2. **In-process counter, R-Co's own shape.** R-Co's `SnapshotWriter` is a struct
   holding a pool handle (not per-instance state itself, but structurally the kind of
   thing that *could* hold a per-instance counter if REQ-045 had resolved to
   supervised per-instance processes). Since it did not (§1 above), an in-process
   counter has no natural home in Letflow's current instance-engine shape without
   inventing a process this stage's own resolved design question said not to
   introduce for EE-01's scope — and `stage-3-instance-engine.md`'s second Early
   finding is explicit that process-per-instance is **not** automatically the right
   call for every piece of engine state; it names "expensive-to-reconstruct in-memory
   state, timers, backpressure, an OS-level resource with no natural row
   representation" as the actual bar, none of which a plain event-count cadence
   check meets.

**This design does not pick between them.** Option 1 reads more consistent with
REQ-045's already-shipped resolution and introduces no new process, but CODE-DESIGN-VALIDATOR
and REVIEWER should confirm that reading rather than accept it by default — the
requirement text explicitly asks for this to be surfaced, not silently defaulted to
the option that merely looks more consistent on paper. If ELIXIR-DEV picks option 1,
`maybe_take_snapshot/4`'s `opts` (§4.2) needs no additional field beyond `prefix`/`interval`;
if option 2, a supervised counter's own lifecycle (start/lookup/crash-recovery) is a
second, currently-unscoped design question this document does not attempt to answer
either.

## 7. Invariants

- **INV-ISS-1 (both replay paths agree, AC4):** for any instance and any snapshot
  taken at a valid `sequence_number` on that instance's real event history,
  `reconstruct_instance/2`'s result via `{:from_snapshot, ...}` and via
  `{:full_replay, 1}` are equal under REQ-053 design §6's stated equality (node-id
  multiset over token positions, `variables`, `status`; pending-task-node set against
  `tasks`).
- **INV-ISS-2 (snapshot table is never read on the write path):** `take_snapshot/4`
  and `maybe_take_snapshot/4` only ever `INSERT` into `instance_state_snapshots` (via
  `take_snapshot/4`'s own single insert) or `SELECT` from it (via
  `latest_snapshot/2`'s cadence check under whichever §6 mechanism is chosen) — never
  `UPDATE`/`DELETE`. A row, once written, is immutable (matches §3's "write-once,
  never updated" column design).
- **INV-ISS-3 (round-trip fidelity, AC2):** `take_snapshot/4` followed by
  `latest_snapshot/2` on the same instance, with no intervening event, returns an
  `InstanceState.t()` structurally equal (`==`) to the one originally passed to
  `take_snapshot/4` — every field, not a subset (§2.2).
- **INV-ISS-4 (no `tenant_id`, Decision 0006 D2):** `instance_state_snapshots` carries
  no `tenant_id` column and `Letflow.Engine.SnapshotWriter`'s schema module casts none
  — the per-tenant Postgres schema (`prefix:`) is the sole isolation boundary, same as
  every table added since D2 shipped.

## 8. Cross-module dependencies

- `Letflow.Engine.SnapshotWriter` depends on `Letflow.Engine.InstanceState`,
  `Letflow.Engine.Token`, `Letflow.Engine.JoinCounter` (serialise/deserialise, §2.2),
  and `Letflow.Repo` (new `Ecto.Schema` module for `instance_state_snapshots`, e.g.
  `Letflow.Engine.InstanceStateSnapshot`, sibling to `Letflow.Engine.Task`/`Letflow.Engine.Token`
  under `lib/letflow/engine/`).
- `Letflow.Engine.Reconstruction` (REQ-053, modified by this requirement) depends on
  `Letflow.Engine.SnapshotWriter.latest_snapshot/2` — a new dependency edge from an
  already-shipped module onto this requirement's new module. No dependency the other
  direction: `SnapshotWriter` does not call into `Reconstruction`.
- `Letflow.Engine` (the EE-01/EE-03/EE-04 context module, REQ-045/047/048) gains new
  call sites into `SnapshotWriter.maybe_take_snapshot/4` at its existing event-append
  points and at instance completion (§4.2) — a new dependency edge from `Letflow.Engine`
  onto this requirement's new module, alongside its existing dependency on
  `Letflow.Engine.Transition`/`VariableMerge`/`ExecutionError`.
- No dependency on `Letflow.Definitions.SnapshotStore` (the *other* snapshot module,
  §1) beyond what `Reconstruction` already had — this requirement does not add or
  change that edge.

## 9. Acceptance-criteria coverage map

| AC | Covered by |
|---|---|
| Migration applies cleanly, schema-per-tenant | §3 (table/index/registration spec) |
| `take_snapshot` round-trips `InstanceState` field-for-field | §2.2 (serialisation shape), §4.1 (`take_snapshot/4`), INV-ISS-3 |
| `maybe_take_snapshot` cadence, default 1000, configurable | §4.2 (`cadence_opts`, `interval` default) |
| Snapshot+delta replay matches full replay, both-paths-agree test | §5.2 (`select_replay_source/2`), §5.4 (test framing), INV-ISS-1 |
| Moduledoc distinguishes the two snapshot tables | §1 |
| Moduledoc names the cadence-counter placement as an open question, citing the stage doc finding + REQ-045 | §6 |
