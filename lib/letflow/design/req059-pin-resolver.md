PROVENANCE (historical, not current decision authority):
# Design: REQ-059 — Dependency pin resolution, recording and inheritance
# (`pin_resolver.zig`, PIN-01/02/03/04)

**Requirement:** REQ-059 (stage S3, `depends_on: [REQ-045 (done), REQ-053 (done)]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ059-20260819`, WF-02 Step 1
**This document produces:** module/function signatures, `@spec`s, error taxonomy,
event-payload shapes, the exact `Letflow.Engine.create/2` integration/reordering
ELIXIR-DEV must make, and explicit moduledoc content requirements — no
implementation code. **No `priv/repo/migrations` change of any kind is part of this
design** — see §0's SCOPE GAP and AC4's "no separate pin table" requirement; the event
log is the only place a pin ever lives.

---

## 0. Sources read for this design

PROVENANCE (historical, not current decision authority):
`docs/agents/instructions/core-directives.md`,
`docs/agents/workflows/WF-02_requirement_implementation.md` Step 1,
`docs/anti-patterns.md`, `.claude/agents/code-designer.md`,
`docs/guides/backend_developer_guide.md`, `docs/migration/stage-3-instance-engine.md`.
REQ-059/REQ-024/REQ-045/REQ-053/REQ-031's full entries in `docs/requirements.yaml`
(REQ-060 and REQ-062 also read, for the seams they name against this requirement).
Shipped code read in full: `lib/letflow/engine.ex` (`create/2` and its whole
pre-transaction/atomic-phase split), `lib/letflow/definitions/service_scope_validator.ex`
(REQ-031's injectable-lookup precedent this design's SCOPE GAP explicitly must mirror),
`lib/letflow/event_store/registry.ex` and
`lib/letflow/event_store/registry/json_schema.ex` (REQ-024's validator this design
reuses, not reimplements), `lib/letflow/definitions/promotion_plan.ex` (the only place
in this codebase that already defines which graph node attribute is a "catalog"
reference vs. a "module" reference), `lib/letflow/engine/reconstruction.ex` (REQ-053,
`read_full_log/3`, `merged_event()`, the `apply_event/3` per-event-type dispatch
table), `lib/letflow/definitions/process_definition.ex`, `lib/letflow/definitions/graph.ex`.
`lib/letflow/design/req053-state-reconstruction.md` (gate-approved, format this
document follows) and `lib/letflow/design/req031-service-scope-validator.md`'s sibling
`.ex` module for the injectable-lookup shape precedent. **This design itself did not
read `pin_resolver.zig` directly** — the R-Co tree at `c:\Users\tvolo\dev\ai-dala\R-Co`
is reachable and was read directly for REQ-110's later audit (§9 OQ-1), but at the time
this design was written every behavioural claim below was sourced from REQ-059's own
requirement text (which the requirement author verified against R-Co directly) plus
already-shipped Letflow code; §9 flags every place this matters.

## 1. Confirmed against shipped code, not assumed

- **`Engine.create/2`'s pre-transaction phase already has a clean insertion point.**
  `start_instance/5` (`engine.ex:367-384`) currently runs, in order: `create_snapshot/3`
  (writes `instance_definition_snapshots` — a real DB write), then `activate/3` (pure,
  builds the graph and dispatches off `:START`), then `persist/8` (the `Ecto.Multi`).
  **This ordering is wrong for this requirement's own zero-partial-write bar.** AC2
  requires a failed resolution write *zero* rows including `instance_definition_snapshots`
  — but `create_snapshot/3` already runs before any pin-related code could. §3 below
  specifies the reordering this design requires: pin resolution moves *before*
  `create_snapshot/3`, not after `activate/3`. This is a small, mechanical, unavoidable
  edit to `start_instance/5` and is a first-class part of this design, not an aside.
- **`activate/3` calls `build_graph(definition.graph)` (`engine.ex:400`) itself.**
  Once pin resolution also needs `Graph.t()` (to walk `SERVICE_TASK`/`SUB_PROCESS`
  nodes) and must run *before* `activate/3`, building the graph twice is wasteful and
  risks two independent `build_graph/1` error branches drifting apart. §3 specifies
  `start_instance/5` builds the graph once, up front, and both `PinResolver.resolve/4`
  and `activate/3` receive the already-built `Graph.t()` — `activate/3`'s own signature
  changes from `activate(instance_id, definition, initial_variables)` to
  `activate(instance_id, graph, initial_variables)` (mechanical).
- **The exact node-attribute convention for "catalog" vs. "module" references already
  exists in this codebase**, and this design reuses it rather than inventing a new one:
  `Letflow.Definitions.PromotionPlan.build_entries/6` (`promotion_plan.ex:229-244`)
  diffs `"service_id"` on `"SERVICE_TASK"` nodes for its `:service_binding` promotion
  dimension, and `"module_ref"` on `"SUB_PROCESS"` nodes for its `:module_ref`
  dimension. This is the **only** place in the shipped codebase that names which
  attribute key on which node type constitutes a catalog/module reference — this
  design's §4.1 enumeration is a direct, cited reuse of that same
  `(node_type, attribute_key)` pairing, not a fresh guess.
- **`REQ-024`'s reusable validator is `Letflow.EventStore.Registry.JsonSchema.validate/2`**,
  a pure `(payload :: map(), schema :: map()) -> [ValidationFailure.t()]` function with
  no `Repo`/tenant dependency — *not* `Letflow.EventStore.Registry.validate_payload/3`
  itself, which is tenant/DB-bound and keyed by a registered *event type* name, a
  different concept entirely from a *variable schema*. This design calls
  `JsonSchema.validate/2` directly (§5), matching REQ-059's own text ("reusing REQ-024's
  validator", not "reusing REQ-024's Registry").
- **`Letflow.Definitions.PromotionPlan`'s own `variable_schema_fetcher` convention**
  (`(tenant_id, process_key) -> map() | String.t() | nil`, defaulting to `nil` when no
  `variable_schemas` table/lookup exists — `promotion_plan.ex:191-196`) is this
  codebase's only precedent for how a "variable schema for this process" is obtained
  today (there is no `variable_schemas` table). §4.2 below adapts this exact shape.
- **`Reconstruction.read_full_log/3` (`reconstruction.ex:291-330`) is currently
  `defp`, not `@doc false`/public**, unlike `Engine.advance_until_stable/4`,
  `tokens_needing_dispatch/3`, `build_graph/1`, `find_start_node/1` (all made
  public/`@doc false` specifically so `Reconstruction` could reuse them without
  duplicating logic — `engine.ex`'s own comments cite req053 design §9 OQ-2 for this
  precedent). §6 below needs the identical events+`events_archive` merged read
  `read_full_log/3` already performs, and per that same established precedent, this
  design specifies **widening its visibility to public/`@doc false`** rather than a
  second, independently-written and inevitably-diverging copy of the same merge logic.

## 2. Module

`Letflow.Engine.PinResolver` — new module, `lib/letflow/engine/pin_resolver.ex`
(mirrors `lib/letflow/engine/*.ex` sibling placement, alongside `reconstruction.ex`,
`execution_error.ex`).

### Moduledoc — required content (verbatim-in-substance, per this design)

PROVENANCE (historical, not current decision authority):
1. Ports `pin_resolver.zig` (R-Co, PIN-01..PIN-04).

   **Sourcing note — this is a factual record, not required moduledoc content.**
   This item previously prescribed that the moduledoc state R-Co's source tree could
   not be reached at design time. That prescription is removed (REQ-112, ISS-0076 item 2
   sweep): the R-Co tree at `c:\Users\tvolo\dev\ai-dala\R-Co` is reachable, and
   `pin_resolver.ex`'s own moduledoc already carries REQ-110's later, source-verified
   findings (§9 OQ-1). Do not copy an "unreachable" environment claim into any future
   moduledoc from this document. At design time, every behavioural claim below traced
   to REQ-059's own requirement text (verified by the requirement's author against
   R-Co directly) or to already-shipped Letflow code, cited by file/line — not to a
   second, independent read of R-Co by this design itself.
2. **SCOPE GAP statement (AC8, verbatim structure required)** — must state, explicitly,
   with the future stage each belongs to:
   PROVENANCE (historical, not current decision authority):
   - PIN-01 AC1 (`service_catalog` version resolution) and PIN-01 AC2 (`module_ref`
     resolution against PLC-01) are **not satisfiable in Letflow today**: this module
     resolves `catalog_entry` and `module` references only against an **injectable**
     `Lookup` (§4), never a real catalog/registry — `src/repository/service_catalog.zig`
     is **stage S6** (operational cross-cutting / repository layer), not yet ported;
     PLC-01 (the process module catalog) is **unscoped to any stage** and does not
     exist in this codebase at all.
   - PIN-03 AC3 (execution proceeds on a pinned version after that version is
     DEPRECATED) is likewise unsatisfiable — there is no version/status column on
     anything in Letflow's catalog-shaped state to become DEPRECATED in the first
     place, the same underlying absence as the point above.
   - Cites R-Co's own precedent for holding exactly this gap: R-Co itself holds PIN-01
     and PIN-03 at TESTED rather than RELEASED over this identical absence, tracked
     there as **ISS-0672/GH-306**.
   - States that this module implements "the resolution/ordering/recording/inheritance
     MACHINERY against an injectable catalog and module lookup — the same pattern
     REQ-031 used for its identical missing-catalog gap"
     (`lib/letflow/definitions/service_scope_validator.ex`'s moduledoc, cited by name),
     and that an unresolvable reference returns a distinct `UnresolvedCatalogRef`/
     `UnresolvedModuleRef` error (§4.1), never a silent no-op or a stub that pretends
     to resolve.
3. States the `(node_type, attribute_key)` convention §1/§4.1 reuses from
   `PromotionPlan`, by module/line citation, so a future reader does not read the
   `"SERVICE_TASK"`/`"service_id"` and `"SUB_PROCESS"`/`"module_ref"` pairing as
   invented fresh here.
4. States plainly: **no migration, no Ecto schema, no DB table** is added by this
   requirement anywhere — "the event log is the record of record" (PIN-02 AC3) is not
   a slogan, it is this module's entire persistence story; every pin fact this module
   produces is a plain map embedded in an event payload REQ-045/REQ-060 append,
   nothing more.
5. States the `Engine.create/2` integration reordering from §1/§3 explicitly, by
   function name (`start_instance/5`, `create_snapshot/3`, `activate/3`) — a future
   reader diffing `engine.ex` against this module needs to find this stated, not
   re-derive it.
6. States the `merge_effective_pins/2` naming/scope note from §6: it is the
   **replay-time** effective-set computation (INSTANCE_STARTED base + zero or more
   INSTANCE_PINS_REBOUND deltas), pure, no I/O — **not** the child-inheritance
   computation (§7's `apply_inheritance/2`), which is a different function with a
   different job, despite REQ-059's own prose using "effective pin set" in both
   contexts. Two different functions, stated as such.
7. States §12's PIN-03 AC4 SCOPE GAP: no retry loop/budget/DLQ exists in this module;
   `PIN_RETRY_EXHAUSTED` is the reserved (not-yet-emitted, not-yet-registered) event-type
   name a future stage-S6 DLQ integration attaches to, and REQ-056 flagged this identical
   gap for its own dispatch retries.

## 3. `Engine.create/2` integration — the exact reordering (PIN-01 AC1/AC4, PIN-02 AC2)

`start_instance/5`'s new sequence (replacing `engine.ex:367-384`), every step before
`create_snapshot/3` performing **zero** `Repo` calls of any kind. This is a **call-order
specification**, not code — each numbered step names the function called, its inputs
(all already in scope by that point), and its success/failure contract. `start_instance/5`
runs these steps **in this exact order**, and — matching the short-circuit discipline
`with` already gives every other multi-step function in `engine.ex` today — the first
step to return anything other than its stated success shape becomes `start_instance/5`'s
own return value immediately, with no later step ever running:

1. `build_graph(definition.graph)` → `{:ok, graph}` on success (existing function,
   unchanged); its existing error shape on failure.
2. `PinResolver.resolve(graph, definition, pin_lookup(attrs, prefix), pin_overrides(attrs))`
   → `{:ok, own_pins, variable_json_schema}` (the 3-tuple form — see §5's INV-PIN-5) on
   success; a `resolve_error()` (§4) on failure.
3. `PinResolver.validate_initial_variables(initial_variables, variable_json_schema)` →
   `:ok` on success; `{:error, {:variable_schema_violation, failures}}` (§5) on failure.
4. `PinResolver.apply_inheritance(own_pins, parent_pins(attrs, prefix))` →
   `{:ok, pins, conflicts}` (§7) — this step has no failure branch of its own (see §7).
5. `create_snapshot(instance_id, definition, prefix)` → `{:ok, snapshot}` on success
   (existing function, unchanged); its existing error shape on failure. **This is the
   first step in the sequence that performs any `Repo` write** — steps 1-4 are pure or
   read-only against the event log only (step 2's `pin_lookup`/`pin_overrides` and step
   4's `parent_pins` read `attrs`; step 4's `parent_pins/2` helper, §8, reads the
   parent's event stream via `PinResolver.reconstruct_effective_pins/2`, §6 — never a
   catalog/module read, never a write).
6. `activate(instance_id, graph, initial_variables)` → `{:ok, new_instance_state}` on
   success (existing function, signature changed per §1: takes the already-built
   `graph` instead of building it again); its existing error shape on failure.
7. `persist(instance_id, definition, initial_variables, correlation_key, graph,
   new_instance_state, pins, conflicts, attrs, prefix)` — the existing `Ecto.Multi`
   (renamed `/10`, two new positional arguments `pins`/`conflicts` inserted before
   `attrs`/`prefix`) — its existing return shape, unchanged.

- **Every step up to and including step 4 is pure or read-only against
  the event log only** (§7's `parent_pins/2` reads the parent's own event stream via
  `merge_effective_pins/2`, §6 — no catalog/module read, no write of any kind). A
  failure at any of these steps returns before `create_snapshot/3` ever runs — AC2's
  "no `instance_definition_snapshots` row" is therefore satisfied by construction, not
  by a rollback.
- `persist/10`'s own body (the `Ecto.Multi`, `engine.ex:552-629`) changes in exactly
  one place: `append_instance_started_event/6` (renamed `/8`, taking `pins` and
  `conflicts` as two new arguments) embeds them into the JSON payload — §5's exact
  shape. No other Multi step changes.
- `pin_lookup/2`, `pin_overrides/2`, `parent_pins/2` are new small private helpers in
  `engine.ex` (not `PinResolver`) that read `opts`/`attrs` — §8 specifies their exact
  contract, since they are the surface a caller (today: only tests; later: REQ-062's
  child-creation call site) uses to supply real lookups/overrides/parent context.

## 4. `resolve/4` — pure enumeration + resolution (PIN-01)

```
@type kind :: :catalog_entry | :variable_schema | :module

@type source :: :resolved | :override | :inherited

@type pinned_version :: %{
  kind: kind(),
  ref: String.t(),
  resolved_id: String.t() | nil,
  version: String.t(),
  source: source()
}

@type override_entry :: %{kind: :catalog_entry | :module, ref: String.t(), resolved_id: String.t(), version: String.t()}

@type resolve_error ::
        {:error, {:unresolved_catalog_ref, ref :: String.t()}}
        | {:error, {:unresolved_module_ref, ref :: String.t()}}
        | {:error, {:graph_structure_invalid, term()}}

@spec resolve(
        graph :: Letflow.Definitions.Graph.t(),
        definition :: Letflow.Definitions.ProcessDefinition.t(),
        lookup :: Lookup.t(),
        overrides :: [override_entry()]
      ) :: {:ok, [pinned_version()], variable_json_schema :: map() | nil} | resolve_error()
```

(the 3-tuple form — see §5's INV-PIN-5 for why `variable_json_schema` is returned
alongside `pins` rather than embedded inside a `pinned_version()` entry)

`Lookup` (plain struct, mirrors `ServiceScopeValidator.Lookup` exactly, three fields
instead of two):

```
defmodule Letflow.Engine.PinResolver.Lookup do
  @enforce_keys [:catalog_lookup, :module_lookup, :variable_schema_lookup]
  defstruct [:catalog_lookup, :module_lookup, :variable_schema_lookup]

  @type catalog_lookup_result :: {:ok, %{resolved_id: String.t(), version: String.t()}} | {:error, :not_found}
  @type module_lookup_result  :: {:ok, %{resolved_id: String.t(), version: String.t()}} | {:error, :not_found}
  @type variable_schema_lookup_result :: {:ok, %{version: String.t(), json_schema: map() | nil}}
  # ^ deliberately total (no {:error, _} case) -- see §4.2.

  @type t :: %__MODULE__{
    catalog_lookup: (service_id :: String.t() -> catalog_lookup_result()),
    module_lookup: (module_ref :: String.t() -> module_lookup_result()),
    variable_schema_lookup: (tenant_id :: Ecto.UUID.t(), process_key :: String.t() -> variable_schema_lookup_result())
  }
end
```

`PinResolver.default_lookup/0` — the inert, always-fails-open-only-for-variable_schema
default `opts[:pin_lookup]` resolves to when a caller supplies none (§8):

```
@spec default_lookup() :: Lookup.t()
```

- `catalog_lookup`: `fn _service_id -> {:error, :not_found} end`
- `module_lookup`: `fn _module_ref -> {:error, :not_found} end`
- `variable_schema_lookup`: `fn _tenant_id, _process_key -> {:ok, %{version: "unversioned", json_schema: nil}} end`

This default lets any definition with **zero** `SERVICE_TASK`/`SUB_PROCESS` node
references continue starting exactly as before this requirement (the overwhelmingly
common case in every already-shipped test); any definition that *does* reference a
`service_id`/`module_ref` newly fails resolution under the default (correct — see the
SCOPE GAP: no stub pretends to resolve) unless the caller supplies a real `Lookup`.
**Integration note for ELIXIR-DEV/TEST-DESIGNER**: confirmed by direct read of
`test/letflow/engine_test.exs:581-609` (the one existing test whose graph reaches a
`SERVICE_TASK` node immediately off `:START`) that its node carries `endpoint`/
`timeout_ms` attributes only, **no** `service_id` — that test is unaffected by this
default. `test/letflow/engine/service_task_routing_test.exs:165`'s graph was also
confirmed to carry no `service_id` attribute. No currently-shipped test was found
exercising a `service_id`-bearing graph through `create/2` — but this is a point-in-time
finding (§1), not a guarantee about tests TEST-DESIGNER has not yet written; flagged so
a future `service_id`-bearing fixture doesn't silently break under the default without
someone realizing why.

### 4.1 Reference enumeration (cites §1's `PromotionPlan` precedent)

For each of the two `(node_type, attribute_key)` pairs — `("SERVICE_TASK",
"service_id")` → `kind: :catalog_entry`, `("SUB_PROCESS", "module_ref")` → `kind:
:module` — walk `graph.nodes` in original list order, collect the attribute's string
value where present (same non-empty-string gate as `ServiceScopeValidator.ref_id/2`:
missing key, `nil`, non-string, or empty string contributes nothing), and **deduplicate
by `ref`** — two different `SERVICE_TASK` nodes referencing the same `service_id`
produce exactly **one** `pinned_version` entry for that ref, first-occurrence order
kept for override-lookup purposes only (final list order is §4.3's sort, not
occurrence order).

For each distinct `{kind, ref}` pair, in the order collected:

1. If `overrides` contains a matching `{kind, ref}` entry: use it verbatim —
   `resolved_id`/`version` taken from the override, `source: :override`, **no**
   `lookup.catalog_lookup`/`lookup.module_lookup` call made for this ref at all (the
   override fully substitutes for resolution, consistent with `source: :override`
   meaning "not resolved by this module's own lookup path").
2. Otherwise, call `lookup.catalog_lookup.(ref)` (kind `:catalog_entry`) or
   `lookup.module_lookup.(ref)` (kind `:module`).
   - `{:ok, %{resolved_id: id, version: v}}` → `%{kind: kind, ref: ref, resolved_id: id, version: v, source: :resolved}`.
   - `{:error, :not_found}` → **halts resolution entirely**:
     `{:error, {:unresolved_catalog_ref, ref}}` / `{:error, {:unresolved_module_ref, ref}}`
     (PIN-01's SCOPE GAP text, verbatim). No partial `pinned_versions` list is ever
     returned on this path — the whole call fails.

### 4.2 The `variable_schema` entry — always exactly one (PIN-02 AC4)

Unconditionally, regardless of how many (including zero) `catalog_entry`/`module`
entries were produced: call
`lookup.variable_schema_lookup.(tenant_id, definition.name)` (`definition.name` **is**
`process_key` — confirmed §1, `PromotionPlan` looks up
`Repo.get_by(ProcessDefinition, name: process_key, ...)`) and append exactly one entry:

```
%{kind: :variable_schema, ref: definition.name, resolved_id: nil,
  version: lookup_result.version, source: (if overridden, :override, else :resolved)}
```

`variable_schema_lookup` is **deliberately total** (§ `Lookup.t()` above) — no
`{:error, _}` case exists in its result type — precisely so PIN-02 AC4's "still
records exactly one variable_schema entry" holds **unconditionally**, never
contingent on whether a real schema happens to be registered anywhere. This is a
considered design choice, not an oversight: `default_lookup/0`'s own
`variable_schema_lookup` returns `{:ok, %{version: "unversioned", json_schema: nil}}`
when nothing is registered, mirroring `PromotionPlan.default_variable_schema_fetcher/2`'s
existing "returns `nil`, no constraint" convention (§1) rather than inventing a new
not-registered error path no acceptance criterion asks for. **Flagged for
REVIEWER**: whether `variable_schema` should instead be allowed to fail (e.g. a
`process_key` with no registered schema *and* no default meaning) is not settled by
R-Co source in this environment — this design resolves it the way stated above and
names the alternative here rather than silently picking without a trace.

`overrides` may also carry a `kind: :variable_schema, ref: process_key` entry using the
same `source: :override` mechanism as §4.1 — included for symmetry, though no caller in
this requirement's own scope populates one.

### 4.3 Deterministic ordering (PIN-01 AC5 — load-bearing, not cosmetic)

The returned list is sorted by `{Atom.to_string(kind), ref}` ascending —
`"catalog_entry" < "module" < "variable_schema"` (plain string `<`), then `ref` string
comparison within a kind. Two `resolve/4` calls given the same graph/definition/lookup
results **always** produce byte-identical `Jason.encode!/1` output for the resulting
list, since (a) this sort is total and deterministic and (b) each `pinned_version` map
has a fixed key set — this is the property TEST-DESIGNER's explicit
serialised-payload-comparison test (REQ-059's own AC1 wording) exercises.

## 5. `validate_initial_variables/2` (PIN-01 AC3, reuses REQ-024's validator)

```
@spec validate_initial_variables(initial_variables :: map(), pins :: [pinned_version()]) ::
        :ok | {:error, {:variable_schema_violation, [Letflow.EventStore.Registry.ValidationFailure.t()]}}
```

Finds the single `kind: :variable_schema` entry in `pins` (§4.2 guarantees exactly
one exists — a `pins` list with zero or >1 such entries is a caller-contract
violation, not a validation outcome; raise, do not tag-tuple, since it can only mean
`resolve/4` was bypassed). If its (out-of-band, not itself embedded in
`pinned_version()` — see §9 OQ-1) `json_schema` is `nil` (no schema registered, the
`default_lookup/0` case): `:ok` unconditionally, no constraint. Otherwise calls
`Letflow.EventStore.Registry.JsonSchema.validate(initial_variables, json_schema)`
directly (§1) — `[]` → `:ok`; non-empty list → `{:error, {:variable_schema_violation,
failures}}`, the list of `ValidationFailure.t()` **as-is**, giving each failing field's
`field_path`/`constraint`/`actual` (PIN-01 AC3's "listing each failing field").

**INV-PIN-5 (why `json_schema` isn't itself a `pinned_version()` field):** `resolve/4`'s
own return value (§4) is exactly what gets embedded verbatim into the
`INSTANCE_STARTED` payload (§3) — carrying a full JSON Schema document inside every
`pinned_version` entry would duplicate it into every event's payload forever, when only
the *version* needs to be durably pinned (the schema *content* for a given version is
looked up again, identically, whenever needed — matching how `catalog_entry`/`module`
entries also carry no schema/config payload, only `resolved_id`/`version`). `resolve/4`
therefore returns the `json_schema` **separately**, alongside `pins`, as its own value
this design's §3 sequence must thread through unchanged from `resolve/4`'s call site to
`validate_initial_variables/2`'s call site (both occur back-to-back in `start_instance/5`,
so no extra storage is needed) — **§3's step 2/3 sequence above already reflects this**:
`resolve/4` returns `{:ok, own_pins, variable_json_schema}` (3-tuple), and
`validate_initial_variables/2` takes `variable_json_schema` as its second argument
directly rather than re-deriving it from `pins`. ELIXIR-DEV: implement the 3-tuple
form; the 2-arg lookup-through-pins description earlier in this section is the
*conceptual* algorithm, the 3-tuple is the *actual* signature to build.

## 6. `merge_effective_pins/2` — the REPLAY-time effective set (PIN-04 AC1/AC5/AC7)

**Naming note (moduledoc §2.6):** this is the function REQ-059's own description names
("`merge_effective_pins/N` computes that effective set" — the sentence immediately
following "REQ-053's reconstruction reads the effective pin set from INSTANCE_STARTED
plus the most recent INSTANCE_PINS_REBOUND event"). It is **pure** — takes
already-decoded event payloads, does **zero** I/O of its own — matching
`Reconstruction.apply_event/3`'s own purity contract exactly.

```
@type effective_pin :: %{
  kind: kind(), ref: String.t(), resolved_id: String.t() | nil, version: String.t(),
  source: source(), source_event_id: Ecto.UUID.t()
}

@spec merge_effective_pins(
        instance_started_pinned_versions :: [pinned_version()],
        pins_rebound_events :: [%{event_id: Ecto.UUID.t(), payload: map()}]
      ) :: [effective_pin()]
```

- Seeds one `effective_pin()` per `INSTANCE_STARTED` entry, `source_event_id` set to
  the `INSTANCE_STARTED` event's own `event_id` (passed in by the caller — see below).
- Folds `pins_rebound_events` **in ascending `sequence_number` order** (the caller's
  responsibility to pass them pre-sorted — this function trusts its input order, same
  discipline as `Reconstruction.fold_events/3`), applying every `{ref, prior_version,
  new_version, ...}` entry each event's payload carries: the matching `{kind, ref}`
  entry's `version` becomes `new_version` and `source_event_id` becomes that
  rebind event's `event_id`; `resolved_id`/`kind`/`source` (left as whatever the base
  set already carried — a rebind changes *version*, never *kind*) are untouched.
- **Discrepancy flagged, not silently resolved (§9 OQ-2):** REQ-059's own prose says
  reconstruction reads "the **most recent**" `INSTANCE_PINS_REBOUND` event (singular),
  but REQ-060's own description says each rebind event carries **only the entries that
  changed** in that one call — folding only the single most-recent event would silently
  lose earlier rebinds of *other* refs from earlier rebind calls. This design folds
  **all** `INSTANCE_PINS_REBOUND` events found, in order, as the only reading
  consistent with REQ-060's delta-only payload shape — REVIEWER should confirm this
  reading against REQ-059's literal "most recent" phrasing when REQ-060 is designed.
- **`Reconstruction.read_full_log/3` visibility widening (§1's finding, ELIXIR-DEV
  action item):** the caller of `merge_effective_pins/2` — a new
  `PinResolver.reconstruct_effective_pins/2` (below) — obtains
  `instance_started_pinned_versions`/`pins_rebound_events` by calling
  `Reconstruction.read_full_log/3` (widened to public/`@doc false`, following the exact
  precedent `advance_until_stable/4` etc. already set) and filtering for
  `event_type in ["INSTANCE_STARTED", "INSTANCE_PINS_REBOUND"]` — **no new
  events/`events_archive` query is written by this module**; the merged, archive-aware
  read is reused verbatim.

```
@spec reconstruct_effective_pins(instance_id :: Ecto.UUID.t(), opts :: [prefix: String.t()]) ::
        {:ok, [effective_pin()]} | {:error, :instance_not_found} | {:error, term()}
```

Calls `Reconstruction.read_full_log(instance_id, prefix, 1)` (min_sequence_number `1`
— **always** full history for pins, regardless of whether `Reconstruction`'s own
snapshot-aware replay (REQ-054) would use a later starting point for *state* replay:
pins are never captured in an `instance_state_snapshots` row, so a pin read must always
walk the full log). `{:ok, []}` (instance genuinely has no events) →
`{:error, :instance_not_found}`, matching `Reconstruction`'s own existence convention
(§1). Otherwise: extract the `INSTANCE_STARTED` event's `payload["pinned_versions"]`
(§3's embedded shape) plus every `INSTANCE_PINS_REBOUND` event, and call
`merge_effective_pins/2`.

**AC7 ("issues zero reads against any catalog or module registry") is satisfied by
construction, not merely by an unused injected lookup**: neither
`reconstruct_effective_pins/2` nor `merge_effective_pins/2` accepts a `Lookup.t()`
parameter at all — there is no capability to call a catalog/module lookup anywhere in
this call path, a strictly stronger guarantee than "a lookup was injected and recorded
as never called." TEST-DESIGNER should still write the injected-lookup-records-zero-calls
test REQ-059's AC7 literally asks for at the `Reconstruction`/`Engine` integration
level (confirming *that* level never reaches for a catalog either), but this module's
own signature is the primary evidence.

**PIN-04 AC4 scope note (S4 route, `GET /api/v1/instances/{id}/pins`):**
`reconstruct_effective_pins/2`'s `effective_pin()` result already carries
`source_event_id` per entry — "the source event identifier per entry" REQ-059's own
SCOPE BOUNDARY paragraph requires this function to expose for that future route. No
route is built here.

## 7. `apply_inheritance/2` — child pin inheritance (PIN-04 AC2/AC3)

**Distinct function from §6** (moduledoc §2.6) — this is the INSTANCE-START-time
computation a child instance's own `start_instance/5` call performs, not a replay-time
fold.

```
@type conflict :: %{kind: kind(), ref: String.t(), child_resolved_version: String.t(), inherited_version: String.t()}

@spec apply_inheritance(own_pins :: [pinned_version()], parent_pins :: [effective_pin()] | nil) ::
        {:ok, [pinned_version()], [conflict()]}
```

- `parent_pins == nil` (root instance, no parent — REQ-045's own `create/2` top-level
  call site always passes `nil`, per REQ-062's own design doc §8 statement that "REQ-059's
  own resolver must treat a `nil` parent as 'no inheritance, resolve fresh,' which is
  REQ-059's own concern to state, not \[REQ-062's\]"): `{:ok, own_pins, []}` unchanged,
  `own_pins`' own `source` values (`:resolved`/`:override` from §4) untouched.
- `parent_pins` given (child instance — the call site is REQ-062's own child-creation
  path, not built by this requirement; §8's `parent_pins/2` helper in `engine.ex` is
  where a real caller supplies this once REQ-062 lands): for every `{kind, ref}` in
  `parent_pins` **absent** from `own_pins`, add it to the result with `source:
  :inherited`, `resolved_id`/`version` taken from the parent's entry unchanged,
  dropping `parent_pins`' own `source_event_id` (not part of `pinned_version()`'s
  shape — this is a fresh entry being written into the CHILD's own `INSTANCE_STARTED`
  payload, so it gets no `source_event_id` of its own; §6's `effective_pin()` is a
  read-side-only type). For every `{kind, ref}` present in **both**: if versions match,
  no conflict, `own_pins`' entry is kept as-is (still `source: :resolved`/`:override` —
  agreement is not inheritance); if versions **differ**, the **inherited** version wins
  — `own_pins`' own entry is replaced by one built from the parent's, `source:
  :inherited` — and a `conflict()` record is appended to the returned conflicts list
  (PIN-04 AC3, "inheritance wins, which is easy to get backwards" — this design states
  the winning side explicitly rather than leaving it inferable).
- Final list re-sorted per §4.3's `{kind, ref}` order (inherited additions must not
  break the deterministic-ordering guarantee).
- `conflicts` (possibly `[]`) is what §3's `persist/10` embeds as the child's
  `INSTANCE_STARTED` payload's `pin_conflicts` key (§ below) — present (even if `[]`)
  whenever `parent_pins` was non-`nil`, omitted entirely (not even an empty-list key)
  when the instance has no parent, so a reader can distinguish "root instance" from
  "child instance with zero conflicts" from the payload shape alone.

## 8. `Engine.create/2` new `opts`/`attrs` surface (private helpers in `engine.ex`)

Three new private functions in `engine.ex`, called from `start_instance/5` (§3):

```
@spec pin_lookup(attrs :: map(), prefix :: String.t()) :: PinResolver.Lookup.t()
@spec pin_overrides(attrs :: map()) :: [PinResolver.Lookup.override_entry()]
@spec parent_pins(attrs :: map(), prefix :: String.t()) :: [PinResolver.effective_pin()] | nil
```

- `pin_lookup/2` — `Map.get(attrs, :pin_lookup, PinResolver.default_lookup())`. Not an
  `opts` keyword (unlike `prefix`) but an `attrs` field, matching this codebase's
  existing convention of putting caller-supplied behavioural injections on `attrs`
  rather than `opts` when they vary per-call rather than per-connection-pool (no
  existing precedent either way in `engine.ex` itself; `ServiceScopeValidator`'s own
  `Lookup` is threaded through `Definitions.activate/2`'s `opts`, the one directly
  comparable precedent — **flagged, §9 OQ-3**, since this design picked `attrs` and
  REVIEWER may prefer `opts` for consistency with that precedent).
- `pin_overrides/1` — `Map.get(attrs, :pin_overrides, [])`.
- `parent_pins/2` — `Map.get(attrs, :parent_instance_id)` and, if non-`nil`, calls
  `PinResolver.reconstruct_effective_pins/2` (§6) for that id and returns its `{:ok,
  pins}` result's `pins` (a `reconstruct_effective_pins/2` error here propagates as
  `create/2`'s own error, tagged `{:error, {:parent_pin_lookup_failed, reason}}` — a
  new `create_error()` variant); `nil` when `attrs[:parent_instance_id]` is absent —
  this is the exact field REQ-062's own design doc §8 states it will populate at its
  own (not-yet-built) child-creation call site, so this design's `attrs` key name
  (`:parent_instance_id`) is chosen to match that future caller rather than invented
  independently — **but REQ-062 has not landed as of this design and cannot confirm
  the name matches its own eventual code**, flagged §9 OQ-4.

## 9. Open questions (explicit, not silently resolved)

PROVENANCE (historical, not current decision authority):
- **OQ-1 — RESOLVED 2026-08-19 (REQ-110 audit, run `WF03-REQ110-20260819`):
  disposition `divergent_behavioural`.** This OQ originally recorded that every claim
  in this document came from REQ-059's own requirement text or shipped Letflow code
  and never from a read of `pin_resolver.zig` itself, and asked that
  ELIXIR-DEV/REVIEWER correct §4.1 before building against it if R-Co's actual
  `source: :override` mechanism differed materially. **R-Co was read directly during
  REQ-110** (`c:\Users\tvolo\dev\ai-dala\R-Co\src\engine\pin_resolver.zig`, 967 lines).
  It differs materially, and REQ-059 had already shipped against §4.1 by then.

  **What R-Co actually does.** Overrides arrive as `{kind, ref, version}` JSON with
  **no** `resolved_id` (`pin_resolver.zig:206`) and are applied as **Step 5, after**
  full normal resolution has produced every pin with `.source = .resolved`
  (`:296-299`, `:254-290`, `:265`) — an overlay onto an already-resolved set, never a
  substitute for resolving. `applyPinOverrides()` (`:602-691`) **verifies** each
  override against the catalog and requires its `version` to equal the
  currently-resolvable version (`:659-661`, `:681-683`); `kind: module` overrides are
  rejected unconditionally (`:642`); an override naming a ref not in the enumerated
  pin set is an error, not a no-op (`:662-664`, `:684-686`, `:707-723`). Failure is
  `UnresolvedPinOverride`, HTTP 422, aborting resolution entirely with no partial pin
  set (`:189-190`, `:598-601`). `.source = .override` is set on exactly one line, only
  after verification succeeded (`:719`).

  **§4.1 above still describes the shipped Letflow behaviour** — the override taken
  verbatim, no lookup call, no verification — and is deliberately left standing so the
  design continues to describe the code as it actually is. It is **not** what R-Co
  does. The delta is filed as **`docs/issues/ISS-0079.yaml` / GH#298** and routed
  through WF-03; REQ-110 was an audit and correctly made no engine-behaviour change.
  Do not treat "match R-Co exactly" as the answer: R-Co's blanket rejection of module
  overrides is an artefact of PLC-01 not existing in R-Co, not a principled rule.

  **A second producer of `:override` that this design never anticipated.** R-Co's
  `mergeEffectivePins()` also stamps `.source = .override` onto a pin rebound by
  PIN-05 (`pin_resolver.zig:138`, `:156`; asserted by R-Co's own unit test at `:914`).
  Letflow's `merge_effective_pins/2` leaves `source` untouched on a rebind, so a
  deliberately rebound pin still reports `source: :resolved`. Filed separately as
  **`docs/issues/ISS-0078.yaml` / GH#299** (§6's OQ-2 neighbourhood, not §4.1's).

  **Two adjacent deltas** were observed in §4.1/§4.3 while checking this OQ and are
  recorded in ISS-0079 rather than here, since neither is the override mechanism:
  Letflow deduplicates refs with `Enum.uniq()` where R-Co does not
  (`pin_resolver.zig:254-267`), and the two sort pin kinds in different orders
  (`pinLessThan`, `:730-735`, against `PinKind` at `:25`) — though R-Co can never
  produce a `module` pin (`:275-284`), so its ordering for that kind is unexercised
  and the difference is unobservable in R-Co today.
- **OQ-2 — "most recent" vs. "all" `INSTANCE_PINS_REBOUND` events (§6).** Flagged
  inline above; needs REVIEWER/REQ-060-designer confirmation.
- **OQ-3 — `attrs` vs. `opts` placement for `pin_lookup`/`pin_overrides`/
  `parent_instance_id` (§8).** Flagged inline; `ServiceScopeValidator`'s only directly
  comparable precedent uses `opts`.
- **OQ-4 — `attrs[:parent_instance_id]` key name is a forward guess against
  not-yet-built REQ-062.** REQ-062's own design doc (§8 of
  `lib/letflow/design/req062-sub-process-runtime.md`, on branch
  `feature/WF02-REQ062-20260819` as of this design, not yet merged to `main`) states
  its own child-creation call site will thread `parent_instance_id` to "wherever the
  child's `INSTANCE_STARTED` event is built" — consistent in spirit with this design's
  `attrs[:parent_instance_id]`, but the exact field/arity was not re-confirmed against
  REQ-062's own (also not-yet-implemented) code. Whichever of REQ-059/REQ-062 merges
  second should reconcile the two designs' exact call shape.
- **OQ-5 — `variable_schema_lookup` totality (§4.2).** Flagged inline; this design
  makes it total (no `{:error, _}` case) to satisfy PIN-02 AC4 unconditionally; an
  alternative reading (schema-required-and-missing is itself an error) was considered
  and rejected for lack of any acceptance criterion demanding it, but is named here for
  REVIEWER to confirm.
- **OQ-6 — override collision with inheritance.** §7 does not special-case an `own_pins`
  entry whose `source` is already `:override` when a conflicting parent inheritance
  would otherwise apply — per §7's stated rule, inheritance still wins (the parent's
  version replaces even a caller-supplied override). This is the literal reading of
  PIN-04 AC3's "inheritance wins" with no stated exception for overrides, but was never
  exercised against an R-Co source to confirm R-Co agrees — flagged, not silently
  assumed.

## 10. Acceptance-criteria → design element map (self-check)

| AC (REQ-059) | Design element |
|---|---|
| AC1 (ordering, byte-identical) | §4.3 |
| AC2 (zero rows on failure) | §3 (reordering before `create_snapshot/3`) |
| AC3 (variable_schema violation, reuse REQ-024) | §5 |
| AC4 (payload carries pins; exactly one variable_schema; no pin table) | §3 (payload embedding), §4.2, §2 point 4 |
| AC5 (PinMissing, no fallback) | §11 (`pin_for/3`, below) |
| AC6 (child inheritance + conflict recording) | §7 |
| AC7 (replay derives from events only, zero catalog reads) | §6 |
| AC8 (moduledoc SCOPE GAP citing ISS-0672/GH-306) | §2 point 2 |
| PIN-03 AC4 (exhausted retry budget → named hook, no partial DLQ) | §12, §2 point 7 |

## 11. `pin_for/3` — the no-fallback runtime accessor (PIN-03 AC1/AC5)

A small, separate function — not called anywhere in this requirement's own integration
(§3/§8), but the accessor PIN-03 describes for a **future** caller (e.g. REQ-056's
service-task dispatch, needing "the pinned version for this `service_id`" at dispatch
time, long after `INSTANCE_STARTED`) to use against an already-obtained effective pin
set, so that future caller never has occasion to invent its own "fall back to the
catalog's current version" logic:

```
@spec pin_for(pins :: [pinned_version()] | [effective_pin()], kind :: kind(), ref :: String.t()) ::
        {:ok, pinned_version() | effective_pin()} | {:error, {:pin_missing, kind(), String.t()}}
```

Plain `Enum.find/2` by `{kind, ref}`; absent → `{:error, {:pin_missing, kind, ref}}`.
**INV-PIN-6 (AC5, stated in the moduledoc verbatim):** no function anywhere in this
module — not `resolve/4`, not `merge_effective_pins/2`, not `apply_inheritance/2`, not
this function — ever queries a catalog/module/variable-schema lookup for a "current" or
"latest" value as a substitute when a pin is absent; `{:error, {:pin_missing, _, _}}` is
the only outcome for "no pin entry," always.

## 12. PIN-03 AC4 — exhausted retry budget, named hook (no DLQ in this stage)

R-Co's PIN-03 AC4 routes an exhausted `PinMissing` retry budget to the dead-letter
queue. **This is a SCOPE GAP, same shape and same underlying absence as the SCOPE GAP
statements already in §2 point 2 and §9 OQ-2's sibling gaps**: `OBS-05`'s DLQ is stage
S6 (operational cross-cutting), not yet ported — REQ-056 flagged this identical gap for
its own service-task dispatch retries (`docs/requirements.yaml` REQ-056 entry), and this
module inherits the same absence rather than re-deciding it independently. Per §1's
`ServiceScopeValidator`/`PromotionPlan` precedent of naming an explicit extension point
rather than building a partial substitute, this design specifies:

- **No retry loop, no retry budget, and no DLQ write of any kind exists in this module.**
  `pin_for/3` (§11) is a single, synchronous lookup — it has no notion of "retry" at all;
  a caller that wants retry-with-backoff semantics builds that entirely on its own side,
  calling `pin_for/3` again each attempt.
- **The named hook**: a caller implementing its own retry loop around `pin_for/3` (e.g.
  a future REQ-056 dispatch retry) is the one place a `PinMissing`-exhausted-retries
  event would be produced, and this design reserves the **event type name**
  `PIN_RETRY_EXHAUSTED` (not yet emitted by any code in this requirement's own scope,
  and not registered in `Letflow.EventStore.Registry` by this requirement) as the
  documented attachment point a stage-S6 DLQ integration hooks onto once `OBS-05` lands
  — matching the same "name the seam, don't half-build the destination" pattern
  `dispatch_exclusive_gateway/4`'s own stub uses elsewhere in this codebase (cited §1's
  peer precedent).
- **Moduledoc requirement (added to §2's numbered list, item 7):** the moduledoc must
  state this reserved event-type name and cite REQ-056's identical gap, so a future S6
  DLQ implementer finds the attachment point named here rather than re-discovering the
  gap independently.
- This is a documentation-only hook — **no code, migration, or `Registry` entry is
  created by this requirement**; PIN-03 AC4 is satisfied by naming the seam, consistent
  with how PIN-01 AC1/AC2 and PIN-03 AC3's SCOPE GAPs are already handled (§2 point 2).
