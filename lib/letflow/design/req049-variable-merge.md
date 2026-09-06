PROVENANCE (historical, not current decision authority):
# Design: REQ-049 — Variable scoping and merge (instance.zig mergeVariables, EE-09)

**Requirement:** REQ-049 (`docs/requirements.yaml`, stage S3)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** the `Letflow.Engine.VariableMerge` module's event/outcome types,
`merge/3`'s full `@spec`, the `VARIABLE_OVERWRITTEN`/`EXECUTION_ERROR` event shapes, the explicit
REQ-061 dependency-ordering resolution, and the full caller-composition call sequence with
REQ-024's `validate_payload/3`. Signatures and type shapes only — no implementation code, no
function bodies, no `.ex`/`.exs` code block contains real logic.

## 0. Sources read for this design, and an explicit access gap

- This handoff's `context.requirement_text.REQ-049` (quoted in full where load-bearing) and
  `task.acceptance_criteria` — read directly, not via `docs/requirements.yaml`, per
  `core-directives.md`'s "Load Scoped Context, Not Whole Files." One targeted lookup was made
  against `docs/requirements.yaml` to re-read REQ-049's own entry verbatim (confirming
  `depends_on: [REQ-044, REQ-024]`, not REQ-061) via
  `awk '/^  - id: REQ-049$/,/^  - id: REQ-050$/' docs/requirements.yaml`.
- `lib/letflow/design/req044-transition-kernel.md` (full) — the pure-kernel/persistence
  -orchestration separation precedent this design matches (§1's file-layout convention, §5's
  ordinary `{:ok,_}|{:error,_}`-vs-legitimate-output-value distinction, §8's purity/determinism
  bar and grep-checkable verification method, §10's dependency-ordering subsection shape this
  design's own §7 mirrors), and the already-shipped `Letflow.Engine.InstanceState`/`Token`
  structs this module's callers operate on (`InstanceState.variables :: map()`, explicitly
  reserved by REQ-044 §2 for this requirement's use).
- `lib/letflow/event_store/registry.ex` (full, current `main`, REQ-024, `status: done`) — the
  real `Letflow.EventStore.Registry.validate_payload/3` signature, behavior, and error union
  (read directly rather than assumed, per the handoff's explicit instruction). Confirmed:
  `validate_payload(event_type :: String.t(), payload :: String.t(), tenant_id :: Ecto.UUID.t())
  :: :ok | {:error, :tenant_not_provisioned} | {:error, :unknown_event_type} |
  {:error, {:payload_validation_failed, [ValidationFailure.t()]}} | {:error, term()}`. Two
  properties of this function are load-bearing for §7 below: (a) it performs `Repo` I/O
  internally (via its own call to `get_type/2`, which resolves `tenant_id` to a physical schema
  and queries `event_type_registry`) — **not pure**; (b) its `payload` argument must decode to a
  JSON **object** at the root — a non-object payload (string/number/boolean/array/null) is
  unconditionally rejected as a root `"type"` violation, confirmed directly from
  `decode_object_payload/1`.
- `lib/letflow/event_store/registry/json_schema.ex` (full) — confirmed
  `Letflow.EventStore.Registry.JsonSchema.validate/2` is `validate_payload/3`'s own internal
  pure delegate (no `Repo`, no I/O — its moduledoc states this explicitly), and confirmed its
  own `@spec` also requires `payload :: map()` at the root (same object-only constraint,
  inherited rather than independently imposed).
- `lib/letflow/event_store/registry/validation_failure.ex` (full) — the
  `Letflow.EventStore.Registry.ValidationFailure` struct (`field_path`, `constraint`, `actual`)
  this design's `EXECUTION_ERROR` event and `validation_outcome()` type both carry.
- `lib/letflow/event_store.ex` (full, current `main`, REQ-025, `status: done`) — confirmed
  `Letflow.EventStore.append/2`'s existing pipeline **already** calls
  `Registry.validate_payload(event_type, payload, tenant_id)` unconditionally, for every event
  type, before `Repo.transaction/2` opens. This is the actual DB-append entry point §8 below
  names as "the calling transaction" the requirement text refers to, and it is a **generic
  event-envelope schema gate** (does this event type's own registered schema accept this
  event's payload shape), not a per-variable business-value check — the two are orthogonal, and
  keeping them distinct is load-bearing for §7's resolution.
- `docs/guides/backend_developer_guide.md` (full) — §3.5's ordinary error-shape convention.
PROVENANCE (historical, not current decision authority):
- `docs/migration/stage-3-instance-engine.md` (full) — EE-09's scope boundary within S3, and
  confirmation that `src/engine/instance.zig`/`src/design/engine.md` are the (unreachable, see
  below) R-Co sources this requirement ports.
- `lib/letflow/design/promotion_plan.md` §9.3 and `lib/letflow/design/req039-sandbox-pool-fixture-loader.md`
  (targeted sections) — both independently confirm **no `variable_schemas` table, and no
  `process_definitions.variable_schema` column, exists anywhere in Letflow today** ("no Letflow
  equivalent today," `promotion_plan.md` §9.3). This is load-bearing for §7/§11's open question:
  REQ-049 has no existing storage mechanism to resolve "is a schema registered for variable key
  K" against — that mechanism does not exist yet in this codebase, in R-Co-derived form or
  otherwise, and this design does not invent one.
- `docs/anti-patterns.md` (current entries) — no entry currently bears on this module.

PROVENANCE (historical, not current decision authority):
**Access gap, stated explicitly rather than silently worked around, matching REQ-044 design doc
§0's precedent exactly:** this environment has no `R-Co/src/engine/instance.zig` or
`R-Co/src/design/engine.md` reachable (searched the whole filesystem for `instance.zig`/
`engine.md`/any `R-Co` directory — no match, same gap REQ-044's design hit). This design is
therefore built from `context.requirement_text.REQ-049`'s own text (already described by ORCH as
containing the load-bearing summary of `engine.md` section EE-09) plus the already-shipped
precedent in `req044-transition-kernel.md`, `lib/letflow/event_store/registry.ex`, and
`lib/letflow/event_store.ex`. Consequence, flagged inline at each place it matters: **the exact
per-key/whole-batch atomicity rule for a rejected merge, and the precise mechanism by which a
"registered variable schema" is looked up, are this design's own reasoned reconstructions from
the requirement text's wording** (see §3.2 and §7.3), not verified against `instance.zig`'s
literal `mergeVariables()` source.

## 1. Module/file layout

**One file, following REQ-044's per-concept-file convention (`transition.ex` for the dispatch
logic, `instance_state.ex`/`token.ex` for the shared structs):**

| File | Module | Contents |
|---|---|---|
| `lib/letflow/engine/variable_merge.ex` | `Letflow.Engine.VariableMerge` | All types (§2) and `merge/3` (§3) |

No new struct is needed the way `InstanceState`/`Token` needed their own files — this module has
no state of its own; it operates on `InstanceState.variables :: map()` (already defined by
REQ-044, `lib/letflow/engine/instance_state.ex`) and returns plain maps/tagged tuples. One file is
sufficient, matching `Letflow.Engine.Transition`'s own single-file scope (a kernel operating on
already-defined structs, not a struct definition itself).

**No Ecto schema, no migration, no DB table for this module.** `Letflow.Engine.VariableMerge` is
pure (§6) — it holds no data of its own and persists nothing. The events it produces (§4, §5) are
plain Elixir terms; the actual DB write happens via `Letflow.EventStore.append/2` (REQ-025,
already shipped), invoked by the caller (§8), not by this module.

## 2. Types

```elixir
@type merge_event ::
        {:variable_overwritten, key :: String.t(), old_value :: term(), new_value :: term()}

@type execution_error_event ::
        {:execution_error, key :: String.t(), rejected_value :: term(),
         reason :: :variable_schema_rejected,
         failures :: [Letflow.EventStore.Registry.ValidationFailure.t()]}

@type validation_outcome ::
        :ok | {:rejected, failures :: [Letflow.EventStore.Registry.ValidationFailure.t()]}

@type variable_validations :: %{optional(String.t()) => validation_outcome()}

@type merge_result ::
        {:ok, new_variables :: map(), events :: [merge_event()]}
        | {:rejected, unchanged_variables :: map(), events :: [execution_error_event()]}
```

**Naming divergence from the requirement text's literal `optional_schema` — stated explicitly,
not silently renamed.** The requirement text describes `merge/3`'s third parameter as
`optional_schema`, singular. This design instead types it as `variable_validations()` — a map
from variable key to an **already-computed validation outcome** for that key's incoming value,
not a raw JSON Schema document. Two reasons, both load-bearing:

1. **Purity.** A raw JSON Schema document by itself is inert data — actually checking a value
   against it (to produce AC2's "schema-compatible" vs AC3's "REJECTED" distinction) requires
   running a validator. If `merge/3` ran that validator itself, calling into REQ-024's own
   apparatus from inside this "pure function over (current_variables, incoming_variables,
   optional_schema)" would either (a) call `Letflow.EventStore.Registry.validate_payload/3`
   directly, which performs `Repo` I/O (§0) — breaking purity outright, the same bar REQ-044 §8
   establishes and this module must match — or (b) call the pure
   `JsonSchema.validate/2` delegate, which is I/O-free but still requires a resolved schema
   *document* the caller must have already fetched from wherever variable schemas end up being
   stored (§7.3's open question) — meaning the caller does the fetch either way. Given the
   caller must resolve the schema regardless, this design has the caller finish the job (run the
   actual check) too, so `merge/3` itself never needs to know how a schema was fetched or
   validated — it only needs the yes/no (or rejected-with-failures) outcome. This is the same
   "all state is passed in, caller resolves what the kernel can't" shape REQ-044 §5's
   `transition/3` signature already establishes (definition_snapshot fully resolved before the
   call, not fetched by the kernel).
2. **Per-key, not whole-batch.** AC1/AC2/AC3 all speak in terms of "a key K ... whose new value is
   schema-compatible / REJECTED" — repeatedly per-key, never "the whole incoming_variables map
   as one object." A single `optional_schema` document validating the entire incoming batch as
   one JSON object was considered and rejected: it does not fit AC1's per-key insert/overwrite
   framing, and REQ-024's own `validate_payload/3`/`JsonSchema.validate/2` have no notion of
   "this subset of keys is exempt, that subset is checked" within one document validation — every
   `properties` entry in a single schema is checked uniformly, which cannot express "no schema
   is registered for key A but one is for key B" (AC2's "or where no variable schema is
   registered" case) without per-key resolution regardless. `variable_validations()` being a map
   (not a single document) is therefore not an arbitrary choice — it is the shape AC2's own
   per-key opt-in wording requires.

`variable_validations` may be `nil` or `%{}` — both mean "no key in this call has a resolved
validation outcome," equivalent to every key defaulting to `:ok` (§3.2). This is how AC2's
"(or where no variable schema is registered)" is represented when *no* variable in the whole
codebase has any schema registered yet (Letflow's current, actual state — §0's `promotion_plan.md`
finding).

## 3. `merge/3` — public function signature and algorithm

```elixir
@spec merge(
        current_variables :: map(),
        incoming_variables :: map(),
        variable_validations :: Letflow.Engine.VariableMerge.variable_validations() | nil
      ) :: Letflow.Engine.VariableMerge.merge_result()
```

**Return shape follows `Letflow.Definitions.Graph.validate_graph/1`'s "legitimate output value,
not a function failure" convention (REQ-028 design doc §4, cited by REQ-044 design doc §5) —
*not* the ordinary `{:ok,_}|{:error,_}` convention `transition/3` uses.** A schema-rejected
variable value is an expected business outcome of a task returning bad data, not a violation of
`merge/3`'s own calling contract the way an unknown `token_id` is for `transition/3` — the same
distinguishing test REQ-044 §5 applied. `:rejected` is therefore its own result tag, not nested
inside `{:error, _}`.

### 3.1 Algorithm, described (not implemented)

PROVENANCE (historical, not current decision authority):
**Step 3 corrected 2026-08-20, `docs/migration/decisions/0007-variable-merge-validates-new-keys.md`
(GH#300/ISS-0077).** The original text below validated `overwrite_keys` only, exempting a
brand-new key from its own registered schema on the one write most likely to be malformed.
That was never a considered divergence from R-Co — it was an unverified claim (no R-Co source
was reachable when this design was written) that got implemented and shipped before anyone
checked it against `instance.zig`. Decision 0007 adopts R-Co's actual semantic. The superseded
original text is kept below, struck through in spirit but not in fact (see decision 0007 for
why: this codebase's convention is to correct a design doc in place while keeping the
superseded rationale legible, not to delete it), so a reader can see exactly what changed and
why.

1. Let `all_keys` = `Map.keys(incoming_variables)`, sorted ascending (`Enum.sort/1`, ordinary
   Erlang term order on binaries — lexicographic). Sorting exists purely for **determinism**
   (REQ-044 §8's bar: identical inputs → identical outputs, including event list order) — it is
   not semantically meaningful, matching REQ-044 §2's note on `InstanceState.tokens` order.
2. Partition `all_keys` into:
   - `new_keys` — keys **not** present in `current_variables` (`Map.has_key?/2` false).
   - `overwrite_keys` — keys already present in `current_variables`. This partition is used only
     in step 4, to decide which keys' application emits a `VARIABLE_OVERWRITTEN` event — **not**
     to decide which keys get validated in step 3.
PROVENANCE (historical, not current decision authority):
3. **Validation pass, over `all_keys` — new and overwrite alike — in sorted order**
   (`instance.zig:2389-2430`'s Phase 1: iterates every key of `output_variables`, checking
   `schema_map.get(key)` unconditionally, with no comparison against `current_vars` at all).
   For each key `K`:
   - Look up `outcome = Map.get(variable_validations || %{}, K, :ok)`.
   - `:ok` → `K` passes (covers both AC2 branches: an explicit `:ok` outcome, and an absent
     entry meaning "no schema registered for K").
   - `{:rejected, failures}` → **stop the validation pass immediately** (do not evaluate any
     further key in `all_keys`) and proceed to §3.3 (the rejected branch) for this `K`.

   *(Superseded original text: "Validation pass, over `overwrite_keys` only, in sorted order... 
   `new_keys` are **never** looked up in `variable_validations` at all, regardless of whether an
   entry happens to exist for one of those keys — AC1's 'A key K absent from the instance
   variable map is inserted' is unconditional, no schema exception carved out." That reading of
   AC1 was wrong: AC1 says an absent key is inserted, not that it is inserted *unvalidated* — the
   design conflated "no collision-detection exception" with "no validation exception," and only
   the former is actually in R-Co.)*
4. **If the validation pass completes with no rejection (§3.2, the `:ok` branch):** apply the
   merge — for each `K` in `new_keys`: insert `K => incoming_variables[K]` into a working copy of
   `current_variables`, no event. For each `K` in `overwrite_keys` (sorted order): record
   `old_value = Map.get(current_variables, K)`, overwrite `K => incoming_variables[K]` in the
   working copy, and construct `{:variable_overwritten, K, old_value, incoming_variables[K]}`
   (§4). Return `{:ok, new_variables, overwritten_events}`, where `overwritten_events` lists the
   constructed events in the same sorted-`overwrite_keys` order they were processed in (zero
   events if `overwrite_keys` was empty — this covers both AC1's "no VARIABLE_OVERWRITTEN event"
   for a pure-insert batch and AC2's empty-map no-op, §9).
5. **If the validation pass stops on a rejected key `K` (§3.3, the `:rejected` branch):** return
   `{:rejected, current_variables, [execution_error_event]}` where `current_variables` is
   returned **byte-for-byte as given** (not even the `new_keys` inserts that would otherwise have
   succeeded are applied) and `execution_error_event` is built per §5, from `K`,
   `incoming_variables[K]`, and the `failures` list `variable_validations[K]` carried.

### 3.2 Whole-batch atomicity — a reasoned reconstruction, flagged

PROVENANCE (historical, not current decision authority):
**All-or-nothing: one rejected key aborts the entire `incoming_variables` batch, not just that
key.** This reading is chosen because AC3 says the rejection "leaves **the variable map**
unchanged" (not "leaves that one key unchanged") and "transitions **the instance** to ERROR" — an
instance-level halt is inherently incompatible with some of the same batch's other variables
having already been silently merged moments earlier. Partial-merge-then-halt was considered and
rejected: it would mean a caller inspecting the post-rejection variable map sees some of this
task's outputs applied and others not, with no way to tell from the map alone which task
completion produced the partial state — a worse audit story than "nothing from this batch landed,"
and AC3's own verification method ("verified by reading the variable map back and confirming it
did not absorb the rejected value") reads naturally as "did not absorb **anything from this call**"
given the instance is about to halt anyway. **Not verified against `instance.zig`'s literal
`mergeVariables()` source (§0's access gap)** — flagged here, same as REQ-044 §12.1/§12.2's
precedent for a similarly-reconstructed rule, for REVIEWER/RELEASE-VALIDATOR to re-check if R-Co
source ever becomes reachable.

### 3.3 First-failure-wins ordering — a design decision, stated explicitly

When more than one key in `all_keys` would be rejected, §3.1 step 3's sorted-order scan
reports the **first** such key (lexicographically smallest key name) and its own `failures` list
only — the others are never evaluated (step 3's "stop immediately"). This is this design's own
tie-break, chosen for determinism (REQ-044 §8's bar — the same `incoming_variables`/
`variable_validations` pair must always report the same one rejected key, not depend on map
iteration order) rather than, e.g., collecting every rejected key's failures into one combined
`EXECUTION_ERROR` event. A combined-failures design was considered and rejected: EE-10 (REQ-061,
not yet built) is the requirement that actually defines `EXECUTION_ERROR`'s full shape and
handling; inventing a multi-key variant here would be exactly the kind of unstated assumption
`core-directives.md` warns against baking into a pure kernel a later requirement has to either
adopt or awkwardly diverge from. Single-key-per-rejection keeps this module's own `EXECUTION_ERROR`
contribution minimal and matches §6's "extension point, not closed enumeration" framing.

## 4. `VARIABLE_OVERWRITTEN` event shape (AC1, AC2)

```elixir
@type merge_event ::
        {:variable_overwritten, key :: String.t(), old_value :: term(), new_value :: term()}
```

- `key` — the variable name being overwritten (always a member of `overwrite_keys`, §3.1 step 2;
  never emitted for a `new_keys` insert, per AC1).
- `old_value` — the value `current_variables[key]` held immediately before this merge call
  (`term()`, since a workflow variable may hold any JSON-representable Elixir value: string,
  number, boolean, `nil`, list, or map).
- `new_value` — `incoming_variables[key]`, the value that replaced it.

One event per overwritten key, never more than one per key per `merge/3` call (§3.1 step 4 emits
exactly one construction per `overwrite_keys` member). Exactly matches AC1's "produces exactly one
VARIABLE_OVERWRITTEN event carrying the key, the old value and the new value."

## 5. `EXECUTION_ERROR` event shape (AC3)

```elixir
@type execution_error_event ::
        {:execution_error, key :: String.t(), rejected_value :: term(),
         reason :: :variable_schema_rejected,
         failures :: [Letflow.EventStore.Registry.ValidationFailure.t()]}
```

- `key` — the first rejected key found by §3.1 step 3's sorted scan (§3.3).
- `rejected_value` — `incoming_variables[key]`, the value that failed validation. **Not merged**
  — `current_variables` is returned unchanged (§3.1 step 5) — this field exists purely so the
  event (and whatever REQ-061 does with it) can record what was attempted and rejected.
- `reason` — a fixed atom, `:variable_schema_rejected`, identifying this as EE-09's own
  contribution to what will become EE-10's full `EXECUTION_ERROR` reason taxonomy.
  **Deliberately not a closed enumeration declared by this module** — the same "open extension
  point" shape REQ-044 §4/§12.5 used for `transition_event/0`/`pending_event/0`: REQ-061's own
  CODE-DESIGNER defines `EXECUTION_ERROR`'s full reason union (service-task failures, plugin
  failures, etc.); this module contributes exactly the one reason value its own scope produces,
  reusing the same 5-tuple shape's field names so REQ-061 can fold this into its own definition
  without a translation layer, not asserting ownership of the whole union.
- `failures` — `Letflow.EventStore.Registry.ValidationFailure.t()` list, taken directly from
  `variable_validations[key]`'s `{:rejected, failures}` payload — REQ-024's own struct, reused
  verbatim (never re-wrapped or re-shaped), satisfying AC4's "no second JSON Schema
  implementation" at the *data shape* level as well as the *validation logic* level (§7).

## 6. Dependency ordering: this module does not depend on REQ-061

**Mirrors `req044-transition-kernel.md` §10's REQ-043 resolution exactly, applied to REQ-049's own
gap.** REQ-049's own `depends_on` in `docs/requirements.yaml` is `[REQ-044, REQ-024]` — **not**
REQ-061 (EE-10 execution error handling, `status: pending` at the time this design was written,
not implemented by anyone yet). The requirement text's own AC3 says "the instance transitions to
ERROR via REQ-061's EE-10 path" — but `Letflow.Engine.VariableMerge` is pure (§3, §10) and must
not `alias`, `import`, or call any REQ-061 module, because none exists.

**How the signal is carried instead:** `merge/3`'s own return value **is** the signal.
`{:rejected, unchanged_variables, [execution_error_event]}` (§3) is the complete statement of
"this batch was rejected, the caller must transition the instance to ERROR" — no call into an
ERROR-transition function happens inside this module. The caller (§8) is the one that, upon
matching `{:rejected, _, _}`, invokes whatever REQ-061 eventually provides. Concretely, this is
not even a stretch for a future REQ-061 to consume: `Letflow.Engine.InstanceState.status` (REQ-044
§2) **already** includes `:error` in its 4-atom `status()` union, shipped and available today —
REQ-061's own job is to define *how* a caller reaches that status, not to add the atom.

**Verbatim moduledoc text — ELIXIR-DEV copies the following paragraph into
`Letflow.Engine.VariableMerge`'s `@moduledoc`:**

```
## Dependency ordering: this module does not depend on REQ-061

AC3 describes a rejected variable value as transitioning the instance to
ERROR "via REQ-061's EE-10 path." REQ-061 (EE-10, execution error handling)
is `status: pending` and unimplemented as of this module's own
implementation — this module's own `depends_on` is [REQ-044, REQ-024], not
REQ-061. `merge/3` is pure (see the purity section below): it never calls,
aliases, or references any REQ-061 module. A rejected batch is signalled
purely through `merge/3`'s own return value -- the `{:rejected,
unchanged_variables, [execution_error_event]}` tuple -- which the caller
(not this module) inspects and acts on, including invoking whichever
REQ-061 function eventually performs the actual ERROR transition.
`Letflow.Engine.InstanceState.status` already includes `:error` in its
existing 4-atom union (REQ-044), so REQ-061 has a pre-existing target value
to transition into; this module does not anticipate REQ-061's own API
beyond that already-shipped atom.
```

## 7. Reuse of REQ-024's `validate_payload/3` — literal fit, and how this design resolves it

AC4 requires: "schema validation goes through REQ-024's `validate_payload/3` rather than a second
JSON Schema implementation, confirmed by inspection and stated in the moduledoc." Read literally,
`validate_payload/3` cannot be called *from inside* `merge/3` (§2's naming-divergence reasoning:
it performs `Repo` I/O, and requires `event_type`/`tenant_id` arguments that do not exist in
`merge/3`'s own `(current_variables, incoming_variables, variable_validations)` signature).
**Resolution: `validate_payload/3` is called by the caller, before `merge/3`, as the mechanism
that produces the `variable_validations` map `merge/3` consumes — not called by `merge/3` itself.**
This satisfies AC4's substance (REQ-024's actual validator, not a second implementation, is what
decides `:ok` vs `:rejected` for every key) while keeping `merge/3` itself pure and testable
without a database, matching the requirement text's own "keeping it testable without a database"
framing.

### 7.1 Payload shape — why the caller wraps the value before calling `validate_payload/3`

`validate_payload/3`'s `payload` argument must decode to a JSON **object** at its root (§0) — a
workflow variable's new value may be a plain string, number, boolean, list, or `nil`, none of
which satisfy that constraint on their own. The caller wraps each candidate value in a
single-key JSON object before calling `validate_payload/3` — conceptually, the raw value
`incoming_variables[key]` becomes the JSON-encoded object `{"value": <that raw value>}` — and
validates it against a registered schema shaped to match (`%{"type" => "object", "properties" =>
%{"value" => <the real per-variable schema>}, "required" => ["value"]}`). The wrapping is a
caller-side convention this design states explicitly so ELIXIR-DEV doesn't have to invent it, not
something `merge/3` itself does or needs to know about (`merge/3` only ever sees the already-resolved
`validation_outcome()`, §2).

### 7.2 Mapping `validate_payload/3`'s result onto `validation_outcome()`

| `validate_payload/3` result | `validation_outcome()` | Rationale |
|---|---|---|
| `:ok` | `:ok` | Schema-compatible (AC2) |
| `{:error, {:payload_validation_failed, failures}}` | `{:rejected, failures}` | AC3's rejection, `failures` reused verbatim |
| `{:error, :unknown_event_type}` | `:ok` | No schema registered under that name — AC2's "(or where no variable schema is registered)" branch, mapped directly since "unknown" is exactly what "not registered" looks like from `validate_payload/3`'s own vantage point |
| `{:error, :tenant_not_provisioned}` | **not resolved here — caller's own open decision, §11.2** | A platform-level fault, not a schema-compatibility question; treating it as `:ok` would silently let an unprovisioned-tenant fault through as "no schema," which this design does not decide is correct |
| `{:error, term()}` (any other) | **not resolved here — caller's own open decision, §11.2** | Same reasoning as the row above |

### 7.3 Where the registered schema itself comes from — an explicit open question, not guessed

**Letflow has no `variable_schemas` storage of any kind today** — confirmed directly (§0):
`lib/letflow/design/promotion_plan.md` §9.3 and `lib/letflow/design/req039-sandbox-pool-fixture-loader.md`
both independently state "no Letflow equivalent today" for R-Co's `variable_schemas` table. This
design does not invent that storage or its lookup key convention (e.g., whether a variable
schema is registered in the existing `event_type_registry` table under a name derived from the
variable key, or in a new dedicated table) — that decision belongs to whichever future
requirement first needs to *register* a variable schema (none does yet; REQ-049's own scope is
the merge algorithm assuming a resolved `variable_validations` map is handed to it). Until that
requirement exists, every real caller of `merge/3` legitimately passes `variable_validations:
nil` (or `%{}`) for every call — meaning AC3's rejection path is exercised by
TEST-DESIGNER's tests via a directly-constructed `variable_validations` map (§8's "how tests
exercise this without the storage mechanism" note), not via an end-to-end registered-schema flow,
until that future requirement lands. Flagged here explicitly rather than silently assumed to
already exist somewhere.

## 8. Caller composition — full call sequence

**Not part of REQ-049's own implementation** (no such orchestration caller exists yet — REQ-047
task completion and REQ-056 service task response are the two named in the requirement text as
the flows that will eventually call `merge/3`; neither is built yet). Stated here as the
call-sequence contract those future requirements' CODE-DESIGNER must follow, per the handoff's own
instruction to design "who owns invoking it":

1. The caller has `current_variables` (from the live `InstanceState.variables`, REQ-044) and
   `incoming_variables` (the task/service-task/sub-process output map).
2. For each key `K` present in **both** maps (an overwrite candidate — brand-new keys are never
   validated, §3.1 step 3): resolve whether a schema is registered for `K` (§7.3's open
   mechanism), and if one is, call
   `Letflow.EventStore.Registry.validate_payload(schema_name_for(K), Jason.encode!(%{"value" =>
   incoming_variables[K]}), tenant_id)` (§7.1's wrapping), then map the result via §7.2's table
   into `variable_validations[K]`. Keys with no registered schema are simply omitted from
   `variable_validations` (§3.1 step 3's `Map.get(..., K, :ok)` default handles the omission).
3. Call `Letflow.Engine.VariableMerge.merge(current_variables, incoming_variables,
   variable_validations)`.
4. **On `{:ok, new_variables, events}`:** set the live `InstanceState.variables` to
   `new_variables` (synchronously, in the same call path — §11 depends on this happening before
   any subsequent gateway evaluation), and for each event in `events`, call
   `Letflow.EventStore.append/2` (REQ-025, already shipped) with `attrs.event_type =
   "VARIABLE_OVERWRITTEN"`, `attrs.payload = Jason.encode!(%{"key" => key, "old_value" =>
   old_value, "new_value" => new_value})`, plus the caller's own `instance_id`/`actor_id`/
   `idempotency_key`/`metadata` per `append/2`'s existing `append_attrs()` contract. **Note (not
   this module's problem to solve, flagged for the caller's CODE-DESIGNER):**
   `append/2` itself calls `validate_payload/3` again internally (§0) — this time validating the
   `VARIABLE_OVERWRITTEN` **event's own envelope shape** against whatever schema is registered
   for the `"VARIABLE_OVERWRITTEN"` event type, a *generic event-log gate* wholly separate from
   §7's per-variable business-schema check. Some event type named `"VARIABLE_OVERWRITTEN"` must
   therefore be registered (`register_type/2`) before any such append can succeed — a
   deployment/seed-data prerequisite this design does not itself satisfy, named here so it is not
   silently assumed to already exist.
5. **On `{:rejected, unchanged_variables, [execution_error_event]}`:** `InstanceState.variables`
   is **not** updated (it already equals `unchanged_variables`, since nothing changed). Append the
   `execution_error_event` via `Letflow.EventStore.append/2` with `attrs.event_type =
   "EXECUTION_ERROR"` (same registration prerequisite as step 4's note, for this event type
   instead) and `attrs.payload` encoding the event's 4 data fields (§5). Then invoke whichever
   REQ-061 function performs the actual ERROR transition (§6 — not this module's call, not named
   here since REQ-061 doesn't exist yet).

**How tests exercise the rejection path without the storage mechanism (§7.3):** TEST-DESIGNER's
tests call `merge/3` directly with a hand-constructed `variable_validations` map (e.g. `%{"amount"
=> {:rejected, [%ValidationFailure{field_path: "/value", constraint: "minimum", actual: -5}]}}`)
— `merge/3` has no idea, and does not need to know, whether that map came from a real
`validate_payload/3` call or a test fixture literal. This is exactly the "testable without a
database" property the requirement text names as the reason for the pure/orchestration split.

## 9. Empty-map no-op case (AC2's edge case)

`incoming_variables == %{}` → `all_keys = []` (§3.1 step 1) → both `new_keys` and
`overwrite_keys` are `[]` → the validation pass (step 3) has nothing to iterate, never finds a
rejection → step 4 applies: zero inserts, zero overwrites, zero events constructed. Returns
`{:ok, current_variables, []}` — the **same** `current_variables` value handed in (no copy
divergence, since zero keys were ever written), and an empty event list. This is not a
special-cased early return — it falls out of the general algorithm (§3.1) with no dedicated
branch, called out here as its own numbered item only because the task requires it as an explicit
design element, not because the algorithm treats it specially.

## 10. Determinism and purity (matching REQ-044 §8's bar)

**Determinism:** calling `merge(current_variables, incoming_variables, variable_validations)`
twice with `==`-equal arguments returns `==`-equal results, both times. Every decision in §3.1 is
a pure function of its typed input: `Map.keys/1` + `Enum.sort/1` are deterministic; the
validation-pass lookup (`Map.get/3`) reads only the argument-supplied `variable_validations`; no
clock read, no `:rand`/`:crypto` call, no UUID generation anywhere in `merge/3`'s call graph
(`event_id`/`created_at` minting is `Letflow.EventStore.append/2`'s job, REQ-025, outside this
module entirely).

**Purity:** `Letflow.Engine.VariableMerge` depends on Elixir/Erlang stdlib only (`Map`, `Enum`,
`Kernel`) plus the `Letflow.EventStore.Registry.ValidationFailure` struct (a plain, non-`Ecto`,
never-persisted type, §0) referenced purely for its `@type t` shape in `execution_error_event()`
and `validation_outcome()` — never invoked as a function call. No `alias Letflow.Repo`, no
`import Ecto.Query`, no `Ecto.Changeset`, no call to `Letflow.EventStore.Registry.validate_payload/3`
or `Letflow.EventStore.Registry.get_type/2` (both perform `Repo` I/O, §0) anywhere in this module.

**Verification method (grep/`mix xref`-checkable, matching REQ-044 §8's precedent literally):**

```bash
grep -n "Repo\.\|Logger\.\|DateTime\.\|System\.os_time\|System\.system_time\|HTTPoison\|Req\.\|File\.\|:rand\.\|:crypto\.\|Registry\.validate_payload\|Registry\.get_type\|Registry\.register_type" lib/letflow/engine/variable_merge.ex
```

must return zero matches. `mix xref graph Letflow.Engine.VariableMerge` should confirm neither
`Letflow.Repo` nor `Letflow.EventStore.Registry` (the DB-backed functions specifically) appears as
a callee, direct or transitive.

**ISS-0080 / GH#301 note (added 2026-08-20, not re-opening this shipped design):** this recipe
grepped the whole file, including the moduledoc's own prose describing what `merge/3` does *not*
call — a bare-symbol grep cannot distinguish a mention from a call site, so it returned false
positives against its own documentation. The shipped module's moduledoc now carries the corrected
recipe (strip `"""`-delimited doc blocks before grepping); this record is left as originally
written and is not itself re-verified against it.

## 11. Immediate visibility to subsequent CEL evaluation (AC4/EE-09 AC4, this task's AC5)

**Design element, not an argued claim:** `merge/3` is synchronous and pure (§10) — it returns
`new_variables` directly in its own return value, with no queuing, async task, or eventual-
consistency window of any kind. "Immediately visible to subsequent CEL condition evaluations"
reduces to an ordinary function-composition guarantee: **the caller must thread the returned
`new_variables` into the `InstanceState.variables` field of whatever `InstanceState` value is
subsequently passed to `Letflow.Engine.Transition.transition/3` (REQ-044) for a gateway node's
evaluation, within the same call sequence, before that `transition/3` call happens** (§8 step 4
states this as the caller's own obligation). Since `Transition.transition/3` is itself pure and
single-hop-per-call (REQ-044 §5), and neither it nor `merge/3` reads any state outside their own
arguments, there is no mechanism by which a gateway evaluation could observe a *stale*
`variables` map as long as the caller's own sequencing (merge, then rebuild `InstanceState` with
the new map, then transition) is followed — visibility is guaranteed by construction, not by a
runtime check either function performs.

**How this is demonstrated by a test, not merely argued (AC5's own requirement):** a test
constructs a `current_variables`/`incoming_variables` pair, calls `merge/3`, takes the returned
`new_variables`, builds a fresh `%InstanceState{... variables: new_variables}` carrying a token
positioned at an `:EXCLUSIVE_GATEWAY` node whose CEL condition (REQ-050, once it exists) reads one
of the merged keys, and calls `Transition.transition/3` against it in the same test — asserting
the gateway's evaluation observes the merged value. This composition needs no database (both
`merge/3` and `transition/3` are pure, §10) and no REQ-050 dependency to design *this* module —
TEST-DESIGNER can write the merge-then-observe half of this test now; the full gateway-reads-it
assertion is only completable once REQ-050 (currently a stub per REQ-044 §6.4) lands, flagged as
a forward dependency (§13) rather than something this design blocks on.

## 12. Cross-module dependencies

- **`Letflow.Engine.InstanceState`** (REQ-044, `status: done`) — the caller's `variables` field is
  this module's `current_variables`/`new_variables` values; `merge/3` itself never references the
  `InstanceState` struct directly (it takes/returns bare `map()`, §3), keeping this module usable
  wherever a variable map exists, not coupled to the engine's own struct shape.
- **`Letflow.EventStore.Registry.ValidationFailure`** (REQ-024, `status: done`) — reused verbatim
  as `execution_error_event()`'s and `validation_outcome()`'s failure-list element type (§4, §5,
  §7.2). No new failure-shape struct is declared anywhere in this module.
- **None on `Letflow.EventStore.Registry.validate_payload/3`, `get_type/2`, or `register_type/2`
  directly** — §7/§10 state this explicitly; those functions are called by the future caller
  (§8), never by `merge/3` itself.
- **None on `Letflow.Repo` or any `Ecto.Schema` module anywhere** — §10's purity contract.
- **None on REQ-061** — §6's dedicated subsection.
- **Forward dependents (not yet built):** REQ-047 (task completion — the first real caller, §8),
  REQ-056 (service task response — a second caller, same call sequence), REQ-061 (EE-10 — consumes
  the `{:rejected, ...}` signal and `execution_error_event`'s shape, §6), REQ-050 (gateway
  evaluation — the consumer whose CEL reads confirm §11's visibility guarantee once it exists).
  Whichever future requirement builds variable-schema registration/storage (§7.3, currently
  unowned) is also a forward dependent of the `variable_validations()` shape this module commits
  to.

## 13. Open questions — not resolved here

### 13.1 Where and how a "registered variable schema" is actually stored and looked up (§7.3)

No `variable_schemas` table or equivalent exists in Letflow today. This design defines the shape
`merge/3` consumes (`variable_validations()`, a per-key precomputed outcome) and the shape a
caller would produce it in by wrapping a call to `validate_payload/3` (§7.1, §7.2), but does not
build or name the storage/lookup mechanism itself. Left for whichever future requirement first
needs to *register* a variable schema.

### 13.2 `validate_payload/3`'s `:tenant_not_provisioned` / unexpected-error cases (§7.2)

Not mapped to either `:ok` or `{:rejected, _}` by this design — a genuine platform fault
(unprovisioned tenant, or an error shape not currently enumerated) is a different failure class
than "this value doesn't match the schema," and folding it into either `validation_outcome()`
branch would misrepresent it. Left for the future caller's own CODE-DESIGNER to decide (most
likely: abort the whole task-completion flow with its own distinct fault path, not feed it into
`merge/3` at all).

### 13.3 Whole-batch atomicity on rejection (§3.2) — reconstructed, not verified

PROVENANCE (historical, not current decision authority):
Flagged inline at §3.2. Re-check against `instance.zig`'s literal `mergeVariables()` if R-Co
source ever becomes reachable in this environment.

### 13.4 First-failure-wins ordering (§3.3) — this design's own tie-break

Flagged inline at §3.3. A future REQ-061 EE-10 CODE-DESIGNER may find R-Co's actual behavior
differs (e.g., collecting every rejected key in one call) — not verified here, same access gap.

### 13.5 `VARIABLE_OVERWRITTEN`/`EXECUTION_ERROR` event-type registration prerequisite (§8 step 4)

Both event type names must be registered via REQ-024's `register_type/2` before
`Letflow.EventStore.append/2` can successfully persist either event (§0's finding that `append/2`
itself gates on `validate_payload/3`). Not REQ-049's own scope to register them — flagged for
whichever requirement first exercises this path end-to-end (most plausibly REQ-047) to confirm
seed/registration happens before first use.

## 14. Acceptance-criteria traceability

| REQ-049 task acceptance criterion | Concrete design element |
|---|---|
| "merging a key absent... inserts it with no VARIABLE_OVERWRITTEN event; merging a key already present overwrites it AND produces exactly one VARIABLE_OVERWRITTEN event carrying the key, the old value and the new value" | §3.1 steps 2 and 4 (insert vs. overwrite classification, one event per overwritten key) + §4 (event shape) |
| "merging an empty map is a no-op producing zero events and leaving the variable map unchanged" | §9 (falls out of §3.1's general algorithm, stated explicitly) |
| "merging a value that a registered variable schema rejects leaves the variable map unchanged, transitions the instance to ERROR, and produces an EXECUTION_ERROR event" | §3.1 step 5 + §3.2 (whole-batch-unchanged reasoning) + §5 (event shape) + §6 (how the ERROR-transition signal is carried without a REQ-061 dependency) |
| "schema validation goes through REQ-024's validate_payload/3 rather than a second JSON Schema implementation, confirmed by inspection and stated in the moduledoc" | §7 (full resolution: caller-side invocation, not inside the pure kernel) + §7.2 (result-mapping table) + §12 (no direct dependency on `Repo`-backed Registry functions, moduledoc text in §6 covering the adjacent REQ-061 note; §7's own text is itself moduledoc-ready prose for ELIXIR-DEV to summarize) |
| "variables merged by a task completion are visible to a gateway condition evaluated later in the same completion, demonstrated by an explicit test rather than argued" | §11 (synchronous-composition guarantee + the exact test shape TEST-DESIGNER writes) |

**Also addressed, per the handoff's own "Key things... you must address explicitly" list:**

| Handoff item | Concrete design element |
|---|---|
| "Read req044-transition-kernel.md first — match its pure/persistence-orchestration precedent" | §0, §1, §3 (return-shape convention), §6, §10 |
| "Find REQ-024's actual validate_payload implementation — verify, don't assume" | §0, §7 (full signature/behavior read directly from `lib/letflow/event_store/registry.ex`) |
| "Design the pure merge function's full @spec" | §3 |
| "Design VARIABLE_OVERWRITTEN and EXECUTION_ERROR event shapes" | §4, §5 |
| "REQ-049 does NOT depend on REQ-061 — own explicit subsection, mirroring req044's REQ-043 note" | §6 |
| "Design the empty-map no-op case" | §9 |
| "Design how a caller composes this with REQ-024's validate_payload/3" | §7, §8 |
