# Design: REQ-045 — Instance start and engine execution shell (EE-01)

**Requirement:** REQ-045 (`docs/requirements.yaml`, stage S3)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ045-20260818`, WF-02 Step 1
**This document produces:** the process-vs-row decision (resolved, not deferred),
`Letflow.Engine.create/2`'s full signature/behaviour/error taxonomy, the required
moduledoc content (ACs 5–7), the tenant_id-derivation contract, the atomicity
mechanism, one small cross-cutting addition to `Letflow.Definitions.Graph`, and every
acceptance criterion mapped to a concrete design element. No implementation code —
signatures/shapes only, matching `req043`/`req044`'s own convention.

---

## 0. Sources read for this design

Read in full: `docs/guides/backend_developer_guide.md`;
`docs/migration/stage-3-instance-engine.md` (both Early findings, and the "Where these
two findings land" section naming REQ-045 explicitly); `lib/letflow/process_instance.ex`;
`lib/letflow/instance_supervisor.ex`; `lib/letflow/engine/transition.ex`;
`lib/letflow/engine/instance_state.ex`; `lib/letflow/engine/task.ex`;
`lib/letflow/engine/token.ex` (the pure struct — see §5.1 on the `token_record.ex`
naming mismatch); `lib/letflow/engine/variable_merge.ex`;
`lib/letflow/event_store/instance_projection.ex`; `lib/letflow/event_store.ex` (full,
`append/2`'s contract); `lib/letflow/definitions/snapshot_store.ex`;
`lib/letflow/definitions.ex` (`get_by_id/2`, `get_active_by_name/2`, and the private
`graph_struct_from_map/1` — see §4); `lib/letflow/definitions/graph.ex`;
`lib/letflow/definitions/instance_definition_snapshot.ex`;
`lib/letflow/tenant_provisioning.ex`; `lib/letflow/event_store/registry.ex` (§9 OQ-3);
`lib/letflow/design/req043-instance-engine-schema.md` (full — the tokens/tasks schema
this design writes into, and its own OQ-1/OQ-4/OQ-5); `req044-transition-kernel.md`'s
citing module (`transition.ex` itself, read directly) for moduledoc-shape precedent.

PROVENANCE (historical, not current decision authority):
`C:\Users\tvolo\dev\ai-dala\R-Co\src\design\engine.md` Section EE-01 (`engine.md:18-406`)
read in full and confirmed reachable this session — the requirement text's paraphrase of
the algorithm matches the primary source closely; deviations are noted inline below.
`src/engine/instance.zig` was located by glob but its content was not needed beyond what
`engine.md` §5 already specifies at the same level of detail this design operates at
(algorithm-shape, not line-by-line Zig).

**Naming correction (post-authoring, ORCH):** this section originally claimed
`lib/letflow/engine/token_record.ex` did not exist and that `Letflow.Engine.Token` still
named both the REQ-044 pure struct and req043 §5's Ecto schema — an unresolved, blocking
name collision. **That claim was wrong; the file exists and the collision was already
resolved**, on `main`, before this design run started (`git log -1 --
lib/letflow/engine/token_record.ex` shows it present since REQ-043's own merge, most
recently touched by REQ-064's tenant_id-drop commit `3d19e8c`). `lib/letflow/engine/token.ex`
(`Letflow.Engine.Token`) is exactly and only the pure REQ-044 struct
(`node_id`/`branch_id`/`token_id`/`waiting_child_instance_id`, no `Ecto.Schema`).
`lib/letflow/engine/token_record.ex` (`Letflow.Engine.TokenRecord`) is req043 §5's
persisted-token Ecto schema, renamed at REQ-043's own rebase/integration time for exactly
this reason — see that module's own moduledoc and `docs/anti-patterns.md`'s "Two branches
picking the same module name" entry for the incident this design's own drafting apparently
failed to find. Every reference below to `Letflow.Engine.Token` as a *persisted, Ecto-backed*
row has been corrected to `Letflow.Engine.TokenRecord`; references to the pure struct
(e.g. `%Letflow.Engine.Token{...}` construction in §6 step 8) are unchanged and correct as
originally written. §9 OQ-1 is downgraded from BLOCKING to a resolved note reflecting this.

---

## 1. Process-vs-row decision — RESOLVED: plain transactional context module, no process

**Decision: `create/2` is a plain function on a new context module, `Letflow.Engine`,
backed entirely by Ecto transactions. No `:gen_statem`, no `DynamicSupervisor`, no
per-instance process is introduced by this requirement.**

Reasoning, applying `stage-3-instance-engine.md`'s second Early finding directly to
EE-01's own scope (not to REQ-056/057's, which the same finding names as the strong case
for a process):

1. **Every write EE-01 performs is already transactional.** `SnapshotStore.create/3`
   (REQ-033) opens its own `Repo.transaction/1`; the `instance_projections` insert +
   `INSTANCE_STARTED` event append (§6 below) is a second, single `Ecto.Multi`. Neither
   needs a live process to hold open state across calls — `create/2` is a single
   request/response round-trip with no multi-step conversation a caller has across
   several messages the way `submitted -> approve` in `process_instance.ex` does.
2. **REQ-053's reconstruction (not yet built, but named explicitly by the stage doc as
   the reason EE-01's case is weak for a process) makes instance state cheaply
   rebuildable from the event log at any time** — there is no expensive-to-reconstruct
   in-memory state EE-01 would be protecting by keeping a process alive.
3. **No timer, no backpressure, no OS-level resource, no external-plugin call.** EE-01
   is a bounded sequence of DB operations that either all succeed or all roll back — the
   textbook case the stage doc's finding says a "plain Postgres row" fits better than a
   supervised process buying "a narrower guarantee than it sounds."
4. `lib/letflow/process_instance.ex`'s own real justification for being a process was
   the *multi-call* state machine (`draft --submit--> submitted --approve/reject-->
   ...`, four separate client calls against one identity). EE-01 has no analogous shape:
   it is one call that produces a fully-formed instance row (already past START, already
   through its first non-START dispatch). Whatever *later* engine operations
   (`complete_task`, `advance`, cancellation) turn out to need a process is each of those
   later requirements' (REQ-046, REQ-052, REQ-056/057) own decision to make against
   their own shape — not pre-empted here.

**What this means concretely for the two existing modules (AC5):**

- `lib/letflow/process_instance.ex` is **SUPERSEDED**, not extended. Its hardcoded
  four-atom state graph (`draft/submitted/approved/rejected`) becomes REQ-027 definition
  data (`process_definitions.graph`), snapshotted per instance by REQ-033. Its
  `transition/5` helper's persistence job is taken over by this requirement's
  `Ecto.Multi` (§6) plus REQ-044's pure `transition/3`. `Letflow.ProcessInstance` itself
  is not deleted by this requirement (REQ-046, named explicitly by the stage doc as "the
  retirement/rewiring reviewable unit," owns physically removing it) — this requirement
  only stops adding to its pattern and builds the real replacement alongside it.
- `lib/letflow/instance_supervisor.ex` is **GENERALIZED, not superseded** — but not by
  *this* requirement, because this requirement introduces no process for
  `InstanceSupervisor` to supervise. Its `DynamicSupervisor` shape is confirmed still
  correct in principle for whichever later S3 requirement (REQ-056 service task dispatch,
  REQ-057 plugin registry — the stage doc's own strong-case subsystems) does need a
  supervised process; `start_instance/1`'s eventual generalization to take a
  definition-driven instance is deferred to that requirement, not built here. REQ-045
  does not modify `instance_supervisor.ex` at all.
- `Letflow.Events.TransitionEvent` (and its migration
  `20260814000001_create_transition_events.exs`) is **deliberately kept in place, not
  retired by this requirement.** REQ-023's `events` table is the durable event log for the
  new engine (this requirement appends `INSTANCE_STARTED` there, §6); `TransitionEvent`
  is `process_instance.ex`'s own private log and has no reader or writer outside that
  module. Retiring it is REQ-046's job, bundled with `process_instance.ex`'s own removal
  (deleting the table out from under a still-shipping module would break it first) — not
  this requirement's, which touches neither the module nor its table.

---

## 2. New module: `Letflow.Engine`

**File:** `lib/letflow/engine.ex`. Namespace choice already opened by req043 §5.1 (OQ-5,
flagged there for REVIEWER, not yet confirmed) — this design proceeds on that namespace
as instructed by req043's own moduledoc ("REQ-045 is expected to add `lib/letflow/
engine.ex`"), and additionally recommends REVIEWER close req043's OQ-5 in the same review
pass that gates this requirement, since this is the requirement that actually exercises
the choice.

**Required moduledoc content (ACs 5, 6, 7 — every point below must appear in substance,
not merely be true):**

1. The AC5 content from §1 above: which of `process_instance.ex`/`instance_supervisor.ex`
   is superseded vs. generalized, and the `TransitionEvent`/its migration retained-not-
   retired statement, with the "REQ-046 does the actual retirement" pointer.
2. The AC6 content from §1's decision paragraph, verbatim in substance: "Whether a
   running instance is a supervised `:gen_statem` process or a plain transactional
   context module was this stage's largest open design question
   (`docs/migration/stage-3-instance-engine.md`'s second Early finding). This module
   resolves it for EE-01's own scope only: `create/2` is a plain function, no process —
   see this design doc §1 for the full reasoning. The answer may legitimately differ for
   later engine subsystems (REQ-056 service task dispatch, REQ-057 plugin registry),
   which the same finding names as the strong case for a process; this module does not
   pre-empt those requirements' own decisions."
3. The AC7 content: "`POST /api/v1/instances` and every other HTTP route belong to S4
   (api-surface) — this module builds a context-module function only, returning tagged
   tuples, matching the boundary REQ-036/REQ-042/every other S2-S3 context module already
   established."

---

## 3. `create/2` — signature

```
@type create_attrs :: %{
        optional(:definition_id)      => Ecto.UUID.t(),
        optional(:definition_name)    => String.t(),
        optional(:correlation_key)    => String.t() | nil,
        required(:initial_variables)  => map()
      }
```

Exactly one of `:definition_id` / `:definition_name` must be present — this design does
not accept both, and does not accept neither (§4 step 2). `:definition_name` resolution
uses `Letflow.Definitions.get_active_by_name/2` (REQ-030) directly — there is no separate
"name+version" lookup function to build: `get_active_by_name/2` already returns *the*
single ACTIVE row for a name (REQ-030's PD-07 uniqueness invariant), which is exactly
what "resolve by name to the active definition" means. The requirement text's "(or
name+version...)" phrasing is read as shorthand for this existing function, not as a
mandate for a new `get_active_by_name_and_version/3` — flagged here as a reading, not
silently assumed (§9 OQ-2).

```
@type opts :: [prefix: String.t()]

@type create_error ::
        {:error, :tenant_id_not_accepted}
        | {:error, :invalid_schema_name}
        | {:error, :missing_definition_reference}
        | {:error, :both_definition_id_and_name}
        | {:error, :invalid_initial_variables}
        | {:error, :definition_not_found}
        | {:error, :definition_not_active}
        | {:error, :duplicate_correlation_key}
        | {:error, {:snapshot_failed, term()}}
        | {:error, {:graph_structure_invalid, term()}}
        | {:error, {:activation_failed, term()}}
        | {:error, {:event_append_failed, term()}}
        | {:error, Ecto.Changeset.t()}
        | {:error, term()}

@type create_result :: %{
        instance_id: Ecto.UUID.t(),
        definition_id: Ecto.UUID.t(),
        status: :active,
        current_nodes: [String.t()],
        variables: map(),
        started_at: DateTime.t()
      }

@spec create(attrs :: create_attrs(), opts :: opts()) ::
        {:ok, create_result()} | create_error()
```

`create/2` — never `create/1`; this design follows `EventStore.append/2`/
`Definitions.create/2`'s established two-argument `(attrs, opts)` shape rather than the
requirement text's informal `create/1` shorthand, matching every other REQ-025/030-style
context function in this codebase (flagged as a naming reconciliation, not a behavior
change).

---

## 4. `create/2` — algorithm (pre-transaction phase, pure/read-only)

Steps 1–5 run with **zero DB writes attempted**, mirroring `EventStore.append/2`'s own
"registry and metadata validation run before the transaction opens" discipline (design
doc precedent already cited by that module's own moduledoc).

1. **Reject `:tenant_id`** in `attrs` (both atom and string key) —
   `{:error, :tenant_id_not_accepted}` — matching `EventStore.append/2` and
   `Definitions.create/2`'s identical contract (§7).
2. **Definition reference shape.** Exactly one of `:definition_id`/`:definition_name`
   must be present in `attrs`: neither present ->
   `{:error, :missing_definition_reference}`; both present ->
   `{:error, :both_definition_id_and_name}` (defensive — not a literal AC, matching this
   codebase's established "ambiguous caller intent is a typed error, not a silent
   precedence pick" idiom, e.g. `EventStore.read/2`'s `up_to_sequence`-wins rule being
   the one *documented* exception rather than the default).
3. **Resolve `opts[:prefix]`.** `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`
   — `{:error, :invalid_schema_name}` on failure (same pattern as `EventStore.append/2`,
   `Definitions.create/2`, `SnapshotStore.create/3`). The resulting `tenant_id` is not
   stored anywhere by this requirement (`instance_projections`/`tasks`/`tokens` carry no
   `tenant_id` column post-Decision-0006-D2, confirmed directly against the shipped
   `Letflow.Engine.Task`/`InstanceProjection` schema files) — this call exists purely to
   validate `prefix` resolves to a well-formed tenant schema name before any I/O, the
   same "prove the prefix is legitimate first" role it plays in every sibling context
   module.
4. **Validate `initial_variables` (AC3).** `Map.get(attrs, :initial_variables)` must be
   a plain map (`is_map/1` true, `is_struct/1` false — same double-guard
   `EventStore.append/2`'s `validate_metadata/1` already established for "map, not a
   struct wearing a map's clothing") — anything else (`nil`, a list, a binary, a struct)
   is `{:error, :invalid_initial_variables}`. `%{}` passes. This check runs before
   definition resolution (step 5) — a caller who gets both wrong sees the
   `initial_variables` error first, deterministically, not a race between the two
   checks (design choice, stated so ELIXIR-DEV picks one fixed order rather than an
   ad-hoc one — matches `EventStore.append/2`'s own fixed `with` chain ordering).
5. **Resolve and validate the definition (AC1, AC2).**
   `Letflow.Definitions.get_by_id/2` (if `:definition_id` given) or
   `Letflow.Definitions.get_active_by_name/2` (if `:definition_name` given), both called
   with `opts` unchanged (they take the same `prefix:` option). A `{:error, :not_found}`
   from either maps to `{:error, :definition_not_found}` — a distinct, EE-01-scoped atom,
   not `Definitions`' own `:not_found` re-exported verbatim (this module owns its own
   error taxonomy, matching every other context module's convention of not leaking a
   dependency's internal atom names as its own public contract). On a found definition,
   check `definition.status == :active` — anything else (`:draft`, `:deprecated`,
   `:archived`) is `{:error, :definition_not_active}` (AC5's "not-active error," EE-01
   AC5/`engine.md`'s `DefinitionNotActive`). **Zero rows are written by either branch of
   this step** (AC2's "writes zero rows across instance_projections,
   instance_definition_snapshots and events").

If all five steps succeed, `create/2` proceeds to the transactional phase (§5, §6) with:
`definition` (the resolved `%ProcessDefinition{}`), `initial_variables` (validated map),
`correlation_key` (`Map.get(attrs, :correlation_key)`, may be `nil`), `prefix`.

---

## 5. `create/2` — snapshot phase (must precede the event append, AC1)

6. **Generate `instance_id` client-side**: `Ecto.UUID.generate()` — mirrors
   `engine.md` §5 step c's "pre-generate the UUID client-side" design choice (the same
   reasoning R-Co states: the same `instance_id` must be passable to both the snapshot
   call and the projection insert before either commits). Never minted inside REQ-044's
   pure `Transition`/`InstanceState` modules — this is the one place in the whole EE-01
   call graph an id is generated, matching `Letflow.Engine.Transition`'s own purity
   contract ("every id is always supplied by the caller, never minted here" —
   `create/2` is that caller).
7. **Call `Letflow.Definitions.SnapshotStore.create(instance_id, definition.id,
   prefix: prefix)`** (REQ-033) — **before any `instance_projections` row or any event
   exists**, honouring both `engine.md` §5's explicit ordering rationale ("If the INSERT
   subsequently fails, the snapshot row is an orphan but causes no harm") and
   `SnapshotStore`'s own moduledoc, which explicitly deferred this exact call site to
   S3/EE-01. This call opens and commits its **own** `Repo.transaction/1` (SnapshotStore's
   established internal shape, not folded into this requirement's later `Ecto.Multi` —
   see §9 OQ-4 for why these are not merged into one transaction).
   - `{:error, :definition_not_found}` here (a genuine, if narrow, TOCTOU race against
     step 5's own read) maps to `{:error, :definition_not_found}` unchanged.
   - Any other `SnapshotStore.create/3` error (`:missing_prefix` — unreachable, already
     validated; `:invalid_instance_id`/`:invalid_definition_id` — unreachable, both are
     `Ecto.UUID.generate()`/`definition.id` values, never caller input; an
     `Ecto.Changeset.t()` from the changeset path) is wrapped as
     `{:error, {:snapshot_failed, reason}}` — a new, EE-01-scoped wrapper atom, so a
     caller inspecting `create/2`'s own error shape doesn't need to know
     `SnapshotStore`'s internal taxonomy to recognize "the snapshot step is what failed."
   - **Idempotency is not relied upon by `create/2` itself** — `instance_id` is freshly
     generated once per call (step 6), so `SnapshotStore`'s own idempotent-retry
     behaviour (a second `create/3` call for the *same* `instance_id` returning the
     pre-existing row) is dormant here; it exists for `SnapshotStore`'s own retry story,
     not something this requirement's algorithm depends on to converge.

---

## 6. `create/2` — the atomic phase (Ecto.Multi, AC1 AC4)

8. **Build the initial pure engine state.** Convert `definition.graph` (a `map()`, per
   `ProcessDefinition.graph`'s field type) into a `%Letflow.Definitions.Graph{}` struct
   via **`Letflow.Definitions.Graph.from_map/1`, a new public function this design adds**
   (§8 below — not literal `.ex` code, a cross-module addition this design specifies).
   Find the graph's `:START` node (`Enum.find(graph.nodes, &(&1.node_type == :START))` —
   guaranteed to exist and be unique by REQ-028's CHK-04, since `definition.graph` already
   passed `validate_graph/1` at `Definitions.create/2` time; a `nil` result here is
   treated the same defensive, never-raising way `Transition.dispatch_start/4` itself
   already treats a missing START edge — `{:error, {:graph_structure_invalid,
   :no_start_node}}`, not a crash). Build:
   ```
   token_id = Ecto.UUID.generate()
   root_token = %Letflow.Engine.Token{token_id: token_id, node_id: start_node.id, branch_id: instance_id}
   instance_state = %Letflow.Engine.InstanceState{
     instance_id: instance_id, status: :active,
     tokens: [root_token], variables: initial_variables, pending_task_nodes: []
   }
   ```
   `branch_id: instance_id` is the root-branch convention req043 §3.2 already documents
   ("root branch = `instance_id` hex") — this design is the first to actually construct
   one, so it states the convention explicitly rather than inventing a different one.
9. **Advance the token off START and through any further auto-advancing nodes (AC7,
   updated — see §9 OQ-1a).** `activate/3` calls
   `Letflow.Engine.Transition.transition(graph, instance_state, {:advance_token,
   token_id})` in a loop (`advance_until_stable/4`), one hop per call — matching
   `Transition`'s "single hop per call" contract — re-selecting whichever token still
   rests on an auto-advancing node type (`:START`, `:EXCLUSIVE_GATEWAY`,
   `:PARALLEL_GATEWAY`) after each hop, until no such token remains: either every token
   is gone (`:END` reached, instance completed) or every remaining token rests on
   `:HUMAN_TASK` or an undispatched type. A `{:error, reason}` return from any hop —
   `:unknown_node_id` (structurally impossible given CHK-04/CHK-01, but never raised, so
   still handled), `:node_type_not_yet_implemented`, or the loop's own defensive
   `:hop_limit_exceeded` — aborts the whole `create/2` call with
   `{:error, {:activation_failed, reason}}`, **writing nothing**: this is why step 9
   runs entirely *before* the `Ecto.Multi` below opens, not inside one of its steps — a
   pure-function failure discovered mid-transaction would otherwise force a rollback of
   the projection insert this step doesn't even need yet. See §9 OQ-1a for the full
   history and the concrete limitation that remains today (only
   `:SERVICE_TASK`/`:TIMER`/`:SUB_PROCESS` first/intermediate nodes still fail
   `create/2`).
10. **Open one `Ecto.Multi`** (matching `EventStore.append/2`'s own established shape —
    a `Multi.run/3` step per operation, `Repo.transaction/1` once):
    - **M1 — insert `instance_projections`.**
      `InstanceProjection.insert_changeset(%InstanceProjection{}, %{instance_id:
      instance_id, status: :active, definition_id: definition.id, correlation_key:
      correlation_key, current_nodes: [start_node.id |> then_advanced_node_id],
      variables: initial_variables})` — wait: `current_nodes` must reflect the
      **post-step-9** token position(s), i.e. `Enum.map(new_instance_state.tokens, &
      &1.node_id)`, not the START node — `Repo.insert(prefix: prefix)`. A
      `uq_instance_correlation` collision (AC4) surfaces as an
      `Ecto.Changeset` unique-constraint error (already wired by
      `InstanceProjection.insert_changeset/2`'s own `unique_constraint/2`, req043 §2.3) —
      mapped by this Multi's result-interpretation step to
      `{:error, :duplicate_correlation_key}`, a distinct EE-01-scoped atom (AC4's "distinct
      duplicate-correlation error"). A `nil` `correlation_key` never triggers this
      constraint (the index is `WHERE correlation_key IS NOT NULL`, req043 §2.1,
      confirmed) — two `create/2` calls with `correlation_key: nil` both succeed (AC4).
    - **M2 — insert the root `tokens` row** for `root_token` (post-step-9 `node_id`,
      `branch_id: instance_id`, `status: :active`) via
      `Letflow.Engine.TokenRecord.insert_changeset/2` (req043 §5.2's Ecto schema, shipped
      as `lib/letflow/engine/token_record.ex` — see §9 OQ-1, resolved). Must run
      after M1 (`tokens.instance_id`'s FK target must already exist in the same
      transaction — Postgres FK checks see uncommitted same-transaction rows, so
      ordering within the `Multi` is sufficient, no deferred-constraint trick needed).
    - **M3 — append the `INSTANCE_STARTED` event.** `Letflow.EventStore.append/2`
      (REQ-025), called with `attrs: %{instance_id: instance_id, event_type:
      "INSTANCE_STARTED", payload: Jason.encode!(%{definition_id: definition.id,
      correlation_key: correlation_key, initial_variables: initial_variables}),
      actor_id: <caller-supplied — see §9 OQ-3b>, idempotency_key: <caller-supplied or
      derived — see §9 OQ-3b>}, opts: [prefix: prefix]`. Must run after M1: `append/2`'s
      own `active_instance_guard` (M1 of *its* internal `Multi`) requires the
      `instance_projections` row to already exist and be non-terminal — this Multi's M1
      is what that guard reads, in the same outer transaction (Ecto's nested
      `Repo.transaction/1` call from inside an already-open transaction runs in the same
      connection/transaction, per Ecto's documented reentrant-transaction behaviour — no
      second real transaction is opened). **`append/2` cannot succeed today without an
      `INSTANCE_STARTED` row already registered in `event_type_registry` for this
      tenant** — flagged as a genuine, load-bearing precondition this requirement does
      not itself satisfy (§9 OQ-3a).
    - `Multi.run/3`'s result-interpretation step (mirroring `EventStore.append/2`'s own
      `interpret_transaction_result/1`) maps: M1's changeset unique-constraint failure ->
      `{:error, :duplicate_correlation_key}`; M2's changeset failure ->
      `{:error, {:activation_failed, changeset}}` (a token-row structural failure, not
      expected in practice given CHK-04, but not silently trusted either); M3's
      `append_error()` -> `{:error, {:event_append_failed, reason}}`; anything else ->
      the raw `{:error, reason}` pass-through, same catch-all discipline
      `EventStore.append/2`'s own `interpret_transaction_result/1` uses.
11. **On `{:ok, _}`**, `create/2` returns
    `{:ok, %{instance_id: instance_id, definition_id: definition.id, status: :active,
    current_nodes: [<post-step-9 node ids>], variables: initial_variables, started_at:
    <M1's inserted row's started_at>}}`.

**Atomicity summary (AC1, AC4):** steps 1–5 write nothing; step 7 (snapshot) commits in
its own transaction, deliberately before the Multi opens (AC1's explicit ordering
requirement, §5); steps 9's pure dispatch runs before the Multi opens so a dispatch
failure never needs a rollback; the Multi (M1+M2+M3) is the single atomic unit that
either fully commits (projection row + token row + event, all together) or fully rolls
back — matching the requirement text's "the event append and the row insert atomic
(Ecto.Multi or Repo.transaction)" instruction. A snapshot row surviving a rolled-back
Multi is the same benign orphan `engine.md` §5's own ordering rationale already accepts
(§5 above).

---

## 7. `tenant_id` derivation contract

No new function. `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` (already
shipped, reused unchanged) is called once, at step 3, purely to validate `opts[:prefix]`
resolves to a well-formed tenant schema name before any I/O — its result is not persisted
anywhere by this requirement, since none of `instance_projections`/`tasks`/`tokens`
carries a `tenant_id` column (Decision 0006 D2, confirmed directly against the three
shipped schema files). This mirrors `SnapshotStore`'s own "no tenant_id derivation
anywhere in this module" stance (its moduledoc, quoted: "Tenant isolation for both tables
is enforced entirely by the Postgres schema (`:prefix`) boundary, not by a column
value") — `Letflow.Engine.create/2` extends the identical reasoning to its own three
target tables. `attrs` still rejects a caller-supplied `:tenant_id` key (§4 step 1),
matching the *contract shape* every REQ-025/030-style function uses, even though the
derived value has no column to land in here — consistency of the public API surface
across context modules, not because this module needs the value for storage.

---

## 8. Cross-module addition: `Letflow.Definitions.Graph.from_map/1`

**New public function on the already-shipped `Letflow.Definitions.Graph` module**
(REQ-028), not a new module. `Letflow.Definitions`'s own `graph_struct_from_map/1` (a
*private* function, confirmed by direct read of `lib/letflow/definitions.ex`) already
implements exactly this conversion (`%{"nodes" => [...], "edges" => [...]}` -> `%Graph{}`)
for `Definitions.create/2`'s own internal use — `create/2` (this requirement) needs the
identical conversion for `definition.graph`/the snapshot's `graph` field, and cannot call
a private function across module boundaries.

```
@spec from_map(graph_map :: map()) :: {:ok, t()} | :error
```

Same signature and behaviour as `Definitions.graph_struct_from_map/1`'s current body
(node/edge list extraction, `@node_type_map` string->atom mapping, `:unknown_node_type`
fallback for an unrecognized type string) — moved to `Graph`, the struct's own module,
rather than duplicated a second time in `Letflow.Engine`. `Letflow.Definitions.create/2`
and `activate/2`'s `run_service_scope_validator/3` are expected to be refactored to call
`Graph.from_map/1` instead of their own private copy, once this function exists — a
small, mechanical, behavior-preserving change to an already-shipped module. **Flagged for
REVIEWER explicitly** (this is the one place this requirement's design reaches into
already-shipped REQ-030 code, even if only to deduplicate, not to change behavior) — see
§9 OQ-5.

---

## 9. Open questions — explicitly listed, not silently resolved

**OQ-1 (RESOLVED before this design ran — corrected post-authoring by ORCH).**
`Letflow.Engine.Token` (pure REQ-044 struct) and req043 §5's Ecto schema for the `tokens`
table were indeed a genuine name collision at REQ-043's own rebase/integration time (see
`docs/anti-patterns.md`'s "Two branches picking the same module name" entry for the
incident). It was already resolved on `main`, before REQ-043 merged: the Ecto schema was
renamed `Letflow.Engine.TokenRecord` and shipped at `lib/letflow/engine/token_record.ex`,
leaving `Letflow.Engine.Token`/`token.ex` exclusively the pure struct. This design's own
first drafting pass (§0) incorrectly claimed the file didn't exist and re-flagged the
already-closed collision as blocking; corrected in place rather than left standing,
since it was a verifiable fact-check failure (the file is present in this branch's own
git history), not a live open design question. §6 M2 now cites
`Letflow.Engine.TokenRecord.insert_changeset/2` directly — no REVIEWER action needed on
this point.

**OQ-1a (MINOR, disclosed limitation — SUPERSEDED 2026-08-18/19, WF02-REQ045-20260818
rework, run `WF02-REQ045-20260818`).** *Original text, kept for history:* step 9's
single `transition/3` call meant `create/2` failed outright
(`{:error, {:activation_failed, {:gateway_not_yet_implemented, ...}}}`, writing
nothing) for any definition whose first node past `:START` was
`:EXCLUSIVE_GATEWAY`/`:PARALLEL_GATEWAY` (REQ-050/051 not yet shipped) or
`:SERVICE_TASK`/`:TIMER`/`:SUB_PROCESS` (no dispatch clause at all). Only definitions
whose first real node was `:HUMAN_TASK` or `:END` could be started successfully.

**What actually changed:** REQ-050 (`:EXCLUSIVE_GATEWAY` condition dispatch) and
REQ-051 (`:PARALLEL_GATEWAY` split/join) both shipped to `main` after this design was
originally authored. Critically, both gateway dispatch clauses
(`dispatch_exclusive_gateway/4`, `dispatch_parallel_gateway/4` in
`lib/letflow/engine/transition.ex`) **auto-advance the token past the gateway within
the same `transition/3` call** — they never return `:gateway_not_yet_implemented`.
This broke §6 step 9's fixed "exactly one/two `transition/3` calls" assumption: a
gateway first node no longer errors, it silently under-advances (the token lands
mid-graph with the instance still `:active` instead of reaching its real resting
state), discovered post-rebase when this branch was integrated onto a `main` that had
since shipped both requirements.

**The fix (this rework):** `activate/3`'s dispatch is no longer a fixed hop count. It
now runs a worklist loop (`advance_until_stable/4`, `lib/letflow/engine.ex`), seeded
with the root token_id, that repeatedly pops one pending token_id and calls
`Transition.transition/3` against it. After each hop it diffs the token list against
what it was immediately before that hop (`tokens_needing_dispatch/3`) to decide which
token_ids still need dispatching: a token needs another hop exactly when it just
arrived somewhere its own node's dispatch hasn't run yet — this covers a plain
`:START`/`:EXCLUSIVE_GATEWAY`/`:PARALLEL_GATEWAY` pass-through advance (the dispatched
token_id's `node_id` changed) *and* a `:PARALLEL_GATEWAY` split or join firing (brand
new token_ids appear that weren't in the previous token list at all, per
`dispatch_parallel_split/4`/`fire_join/5`) — and never when the dispatched token
stayed at the same `node_id` (`:HUMAN_TASK`'s genuine "no automatic outgoing
traversal" contract) or was removed outright (`:END`, or a join's `:wait` outcome
consuming the arriving branch without producing a new token). This diff-based rule is
deliberately node-type-agnostic in `Letflow.Engine` itself — it never hardcodes which
`node_type`s "auto-advance," so it needs no update the next time `transition.ex` gains
a new dispatch clause. The loop ends the instant the worklist is empty. A defensive,
generously-sized hop bound (`length(graph.nodes) * 4 + 10`, not just
`length(graph.nodes) + 1` — a split can put several tokens in flight walking separate
branches at once, so the legitimate hop budget can exceed the raw node count) prevents
an unbounded loop should a malformed/cyclic graph somehow reach this code despite
REQ-028's structural validators rejecting true cycles — not an expected-to-trigger
path, a totality fallback only, matching this codebase's "never raise, never hang"
discipline.

**Current, real remaining limitation:** only `:SERVICE_TASK`/`:TIMER`/`:SUB_PROCESS`
first (or intermediate, pre-`:HUMAN_TASK`/`:END`) nodes still fail `create/2` today,
via `:node_type_not_yet_implemented` — no requirement has shipped a dispatch clause
for any of these three node types yet (REQ-056/057/062 are the named future owners).
`:HUMAN_TASK`/`:END`/`:EXCLUSIVE_GATEWAY`/`:PARALLEL_GATEWAY` first nodes all now
succeed.

**OQ-2 (MINOR).** §3's reading of "definition_id (or name+version...)" as
`get_active_by_name/2` (no separate version parameter) rather than a new
name+version-specific lookup. Flagged for REVIEWER to confirm this reading against the
requirement text's intent, not silently assumed correct.

**OQ-3a (BLOCKING, operational).** `EventStore.append/2`'s M3 step (§6) cannot succeed
unless `"INSTANCE_STARTED"` is already a registered `event_type_registry` row for the
calling tenant (`Registry.validate_payload/3` fails closed with
`{:error, :unknown_event_type}` otherwise, confirmed by direct read of
`lib/letflow/event_store.ex`). No shipped requirement seeds this row. This is a genuine
prerequisite `create/2` depends on but cannot itself satisfy from inside its own call
(seeding a registry row is an administrative/tenant-provisioning-time operation, not
something a single instance-start call should be doing on the caller's behalf). Flagged
for REVIEWER: either a tenant-provisioning-time seed step (extending
`Letflow.TenantProvisioning.provision_tenant_schema/1` or a parallel seeding function) is
a prerequisite requirement this stage is currently missing, or ELIXIR-DEV must add one
narrowly-scoped seed call as part of this requirement's own test setup — this design does
not silently assume either.

**OQ-3b (MINOR).** `EventStore.append/2`'s `attrs` requires `actor_id` and
`idempotency_key`, neither named by REQ-045's own acceptance criteria. This design leaves
both as `create_attrs()` fields the caller must supply (a `%{... actor_id: ...,
idempotency_key: ...}` pair alongside `initial_variables`) rather than inventing a
platform sentinel or auto-generated value unprompted — flagged for REVIEWER to confirm
`create_attrs()` should carry these two additional required keys (S4's future HTTP
handler would need to plumb an authenticated actor through regardless, so this is likely
correct, but not decided unilaterally here since it wasn't named in the acceptance
criteria text).

**OQ-4 (MINOR).** The snapshot call (§5) and the `Ecto.Multi` (§6) are two separate
transactions, not one combined transaction — a crash between them leaves a committed,
orphaned `instance_definition_snapshots` row with no matching `instance_projections` row.
This is the same shape `engine.md` §5's own ordering rationale explicitly accepts
("the orphan is inert"), not a defect this design introduces — restated here so
REVIEWER can confirm the acceptance, not merely infer it.

**OQ-5 (MINOR).** §8's `Graph.from_map/1` addition touches already-shipped REQ-030 code
(`lib/letflow/definitions.ex`)'s private-function structure, even though it changes no
observable behavior of `Definitions.create/2`/`activate/2`. Flagged for REVIEWER to
confirm a design step is authorized to specify a refactor of a different, already-merged
requirement's module, versus this design instead duplicating the ~20-line conversion
function directly inside `Letflow.Engine` (the safer-but-duplicative alternative, not
chosen here because this codebase's own conventions consistently prefer a single
authoritative implementation, e.g. `VariableMerge`'s explicit refusal to
"reimplement REQ-036's canonicalization as a private duplicate").

---

## 10. Acceptance-criteria traceability

| REQ-045 AC | Concrete design element |
|---|---|
| AC1 — snapshot before event; row seeded correctly | §5 step 7 (ordering), §6 M1 (projection insert), §6 M3 (event append after M1) |
| AC2 — not-active definition rejected, zero rows | §4 step 5 (pre-transaction check, before any write) |
| AC3 — nil/list rejected, `{}` accepted, three tests | §4 step 4 (`is_map/1 and not is_struct/1` guard) |
| AC4 — duplicate correlation rejected; nil correlation unconstrained | §6 M1 (`uq_instance_correlation`, partial index on non-null), error mapping to `:duplicate_correlation_key` |
| AC5 — moduledoc states supersede/generalize + TransitionEvent disposition | §1 (decision), §2 point 1 (required moduledoc content) |
| AC6 — moduledoc names the process-vs-row question, cites the stage doc, leaves it to CODE-DESIGNER | §1 (this design *is* that resolution), §2 point 2 (required moduledoc content restates it) |
| AC7 — first task activation fires immediately via `transition/3` | §6 step 9 (`transition/3` called in a loop, `advance_until_stable/4`, until a stable resting state is reached — §9 OQ-1a, updated) |
| Scope boundary — HTTP is S4 | §2 point 3 (required moduledoc content) |
