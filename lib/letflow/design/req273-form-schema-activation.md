# REQ-273 — Populate `tasks.form_schema` at activation, shape-validated and version-pinned

**Requirement:** REQ-273 (`docs/requirements.yaml`, stage S8; full `description`, the
three constraints from decision record `0020` D3, the scope fence, and all 4
`acceptance_criteria` read directly from that entry).
**Owner (implementer):** `ELIXIR-DEV`.
**No implementation code below** — signatures, `@spec`-style types, and decision tables
only, matching this project's established design-doc convention (REQ-126, REQ-109).

---

## 0. Sources read for this design

- REQ-273's own `docs/requirements.yaml` entry.
- `lib/letflow/engine/task.ex` — `field(:form_schema, :map)` (line 70); `insert_changeset/2`
  (lines 85-108) already casts `:form_schema` in its allowed-keys list (line 95). **No
  schema/changeset change is needed** — the column and its cast path both already exist;
  only the *attrs map fed into* `insert_changeset/2` is missing the key.
- `lib/letflow/engine/task_activation.ex` — `resolve_assignee/1` (lines 108-121) and
  `insert_attrs/4` (lines 123-150), the REQ-047 "no invented default for an absent key"
  discipline (OQ-1, line 114): `assignee_type` is `Map.get(attributes, "assignee_type")`,
  `nil` when absent, never defaulted. This is the exact pattern this requirement's own
  `form_schema` key must follow.
- `lib/letflow/engine/variable_schema.ex` — moduledoc lines 20-27: `tasks.form_schema` is
  named explicitly as "a UI form-**rendering** payload; R-Co never validates submitted
  output against it," distinct from `variable_schemas` (the real validation authority).
- `lib/letflow/definitions/json_schema_shape.ex` — `JsonSchemaShape.check/1` (line 78),
  the existing pure shape predicate: `:ok | {:error, {:not_well_formed, path}} | {:error,
  :too_deep}`, never raises. Already the sole predicate `Letflow.Definitions` and
  `Letflow.Engine.VariableSchema.changeset/2` (`variable_schema.ex:228-240`) both call.
- `lib/letflow/tasks.ex` — `get_form_version/2` (lines 279-300), the REQ-126
  version-pinning read-path precedent (reads `instance_definition_snapshots.definition_ver`
  by `instance_id`, never the live `process_definitions` row).
- `lib/letflow/design/req126-form-version-pinning.md` — the design precedent this
  requirement's version-pinning explanation (§3 below) extends, one level down the stack
  (pinning a *graph-derived value*, not a snapshot column read at task-read time).
- `lib/letflow/engine.ex` — `start_instance/6` (lines 508-522): `graph` is built once, at
  instance-creation time, from `definition.graph` (the just-resolved *active* definition at
  that moment — `resolve_definition/2`, lines 474-481), then threaded into both the
  snapshot write and `activate/3`. `fetch_graph/2` (lines 2078-2081): for every activation
  that happens *after* instance creation (task-to-task chains, timer-driven activations,
  service-task-dispatch-driven activations), `graph` is rebuilt from
  `snapshot.graph` — i.e. from `Letflow.Definitions.SnapshotStore`'s row for that instance,
  **never** from a fresh `process_definitions` read. `TaskActivation.append_multi/6`'s call
  site at line 1340 (initial activation) and every other call site (lines 2365, 2544, 2643,
  2720, 3030, 3585 — via `append_multi_from_existing_records/6`) all receive `graph` built
  this same way.
- `lib/letflow/routers/tasks.ex` — `task_detail_map/3`'s "Response allowlists" section
  (lines 79-93): confirms `form_schema` is deliberately excluded from both response maps
  today, and that exclusion is explicitly framed as REQ-047's own still-open OQ-3, "a
  distinct concern from `form_id`/`form_version`." This requirement does not touch that
  file (§4 below).
- `docs/migration/decisions/0020-frontend-architecture.md` D3 (cited by REQ-273's own
  `description` for its three constraints).
- `docs/anti-patterns.md` (scanned; no entry directly on point).

---

## 1. Where `form_schema` is read and how it reaches `insert_attrs/4`

### 1.1 The one new read: `node.attributes["form_schema"]`

`resolve_assignee/1` already demonstrates the exact pattern to extend: it reads two keys
off `%Graph.Node{attributes: attributes}` (`attributes || %{}` guards a nil `attributes`
map, then two `Map.get/2` calls, no default invented for either). This requirement adds a
third read of the same shape, off the same `node.attributes` map already in scope inside
`insert_attrs/4` (the `node` argument is already a `%Graph.Node{}` — no new argument, no
new lookup, no new caller wiring).

**New/changed function:** `insert_attrs/4` keeps its existing 4-arg signature
(`instance_id`, `token_record_id`, `token`, `node`) — no signature change. Its body gains
one additional key resolution, structurally identical to `resolve_assignee/1`'s:

| Step | Source | Result if present | Result if absent or `nil` |
|---|---|---|---|
| Read raw value | `Map.get(node.attributes \|\| %{}, "form_schema")` | the raw attribute value (any JSON-decoded term: map, list, string, number, boolean, `nil`) | `nil` |
| Shape-check (only when non-nil) | `JsonSchemaShape.check/1` | `:ok` → proceed; rejection → typed error (§2) | not invoked — nothing to check |
| Value placed in `insert_attrs/4`'s returned map | the raw attribute value unchanged | `nil` |

No new default is invented at any step (mirrors OQ-1/REQ-047's discipline verbatim, cited
in REQ-273's own requirement text). A `HUMAN_TASK` node with no `"form_schema"` key, or an
explicit JSON `null`, produces `form_schema: nil` in `insert_attrs/4`'s returned map, which
flows unchanged through `Task.insert_changeset/2`'s existing `cast/3` (already includes
`:form_schema` in its allow-list, `task.ex:95`) into the inserted row — this satisfies
acceptance criterion 2 by construction, with zero new code in `task.ex` itself.

### 1.2 Return shape of `insert_attrs/4`

`insert_attrs/4`'s returned map gains exactly one new key, `form_schema`, alongside the
existing six (`instance_id`, `token_id`, `node_id`, `node_name`, `assignee_type`,
`assignee_ref`) — seven keys total. No other key's derivation changes.

---

## 2. Shape validation via `JsonSchemaShape.check/1` — where it runs and what happens on rejection

### 2.1 Reuse, not reinvention (constraint 2)

`insert_attrs/4` (or a small helper it calls, at CODE-DESIGNER's/ELIXIR-DEV's discretion —
this design does not mandate a particular internal decomposition, only the call target)
invokes `Letflow.Definitions.JsonSchemaShape.check/1` on the raw `"form_schema"` attribute
value whenever that value is non-nil. This is the same predicate `Letflow.Definitions`'s
registration path and `Letflow.Engine.VariableSchema.changeset/2`'s
`validate_change(:json_schema, &validate_json_schema_shape/2)` already call — no second
shape predicate is written anywhere in this change. `check/1` never raises on any input
(its own moduledoc/`@doc` guarantee), so no `try`/`rescue` is needed around the call.

### 2.2 Where the check must run relative to the write (constraint 2, AC3)

`append_multi/6` and `append_multi_from_existing_records/6` build `Ecto.Multi.run/3` steps
that only ever *succeed into an insert* — today, nothing in `insert_attrs/4`'s call chain
can fail the `Multi.run/3` step it participates in (`token_id_to_record_id/2` and
`insert_attrs/4` are both pure, total functions; the actual `Repo.insert/2` call is where a
changeset failure would normally surface). Shape validation must run **before** any
`Task.insert_changeset/2`/`Repo.insert/2` call is attempted for the offending node's task
row, and its failure must abort the *entire* `Multi.run/3` step (not just skip the one
task) — an `Ecto.Multi.run/3` step returning `{:error, reason}` rolls back every write the
enclosing transaction has staged, matching the "no tasks row written" half of AC3 exactly
(the same all-or-nothing guarantee `Multi.run/3` steps already provide elsewhere in this
module — e.g. `token_id_to_record_id/2`'s FK-zip step).

### 2.3 The typed error, and how it must name the offending node

**New error type**, returned instead of a map when shape validation fails within
`insert_attrs/4`'s (or its caller's) resolution step:

```
{:error, {:invalid_form_schema, node_id :: String.t(), reason :: JsonSchemaShape.check_result_error()}}
```

where `JsonSchemaShape.check_result_error()` is the non-`:ok` half of `check/1`'s existing
return type — `{:not_well_formed, path :: [String.t()]}` or `:too_deep`, reused verbatim,
not re-wrapped or re-stringified. `node_id` is `node.id` (the `Graph.Node.t()` field
already in scope), satisfying AC3's "naming the offending node" in the most direct way
available — no new node-identification scheme is invented.

**Propagation path (design table, not code):**

| Layer | Behavior on `{:invalid_form_schema, node_id, reason}` |
|---|---|
| `insert_attrs/4`'s caller inside `append_multi/6`'s `Multi.run(:task_records, fn repo, changes -> ... end)` | returns `{:error, {:invalid_form_schema, node_id, reason}}` from the `Multi.run/3` function instead of proceeding to build/insert any `Task.insert_changeset/2` for that hop's newly-pending tokens |
| `Ecto.Multi` | the whole transaction is rolled back — the standard `Multi.run/3` contract already relied on elsewhere in this module; no manual rollback logic is added |
| `Letflow.Engine.create/2` (and every other public entry point that reaches `append_multi/6`/`append_multi_from_existing_records/6`) | the `{:error, {:invalid_form_schema, ...}}` tuple propagates to that function's own caller unchanged, exactly as any other `Multi.run/3` failure already does today (this module invents no new propagation mechanism — it is the same `with`/`case` unwrapping every other `Multi` step failure already goes through) |

**Precedent this matches:** `Letflow.Engine.VariableSchema.validate_json_schema_shape/2`
(changeset validation, rejecting *before* a `variable_schemas` row can be inserted) and
`Letflow.Definitions.register_variable_schemas/3`'s own validate-before-insert discipline
(REQ-078, "OQ-3 ... CLOSED ... in favour of validate-before-insert" —
`variable_schema.ex` moduledoc lines 90-121) are both cited by REQ-273's own requirement
text as the reuse target. This design's `{:invalid_form_schema, node_id, reason}` shape is
the activation-path analogue of that same validate-before-insert discipline, one layer
down (task activation instead of a changeset), because `insert_attrs/4` builds a plain
map, not a changeset — there is no `Ecto.Changeset` in scope at this point in
`TaskActivation` to attach a field error to, so a typed tuple (not a changeset error list)
is the correct shape here, distinct from `VariableSchema`'s changeset-based rejection but
serving the identical "reject before any row is written" purpose. This distinction is
called out explicitly so ELIXIR-DEV does not attempt to force a changeset error shape onto
a function that builds a bare map.

---

## 3. Version pinning — how the same-version guarantee is achieved

### 3.1 The mechanism: activation never reads `process_definitions` directly for `graph`

REQ-273's constraint 3 requires the schema written to `form_schema` to come from the
**same definition version the task was created against**, never whatever is live at
read time (the same silent-substitution failure REQ-126 exists to prevent on the read
side). This requirement achieves that pinning **without any new pinning machinery**,
because the pinning already exists one layer below `TaskActivation` and this requirement
inherits it by construction:

| When | `graph` (fed into `TaskActivation.append_multi/6`'s `node.attributes` lookups) is built from | Cited call site |
|---|---|---|
| Instance creation (initial activation) | `definition.graph` — the specific `process_definitions` row `resolve_definition/2` resolved *once*, at the start of `create/2`'s own call, before any write happens; this same `graph` value is what `Letflow.Definitions.SnapshotStore.create/3` copies (verbatim, per REQ-126 design §0) into `instance_definition_snapshots.graph` in the same creation flow | `lib/letflow/engine.ex:508-522` (`start_instance/6`), `TaskActivation.append_multi/6` call at line 1340 |
| Every later activation for that same instance — task-to-task chains, timer-fired activations, service-task-dispatch-driven activations | `snapshot.graph` — read back from that instance's own `instance_definition_snapshots` row via `fetch_graph/2`, never from a fresh `process_definitions` lookup | `lib/letflow/engine.ex:2078-2081` (`fetch_graph/2`), consumed at every later `append_multi_from_existing_records/6` call site (lines 2365, 2544, 2643, 2720, 3030, 3585) |

Because `instance_definition_snapshots` is a write-once row (no `update_changeset/2` at
all — REQ-126 design §2.2, confirmed there against
`lib/letflow/definitions/instance_definition_snapshot.ex`) and a later promotion of a new
`process_definitions` version always creates a **new** row rather than mutating an
existing instance's snapshot, every `Graph.Node.t()` `TaskActivation` ever inspects — on
first activation or the hundredth — is a node from the *frozen* graph belonging to the
version the instance actually started from. `node.attributes["form_schema"]` read off
that node is therefore, by construction, the schema attached to that node **in the
version the instance was created against** — not whatever `attributes["form_schema"]` a
later-promoted version's graph might carry for a node with the same `node_id`.

### 3.2 Why no new pin/lookup column or table is needed (contrast with REQ-126)

REQ-126 needed a **new read** (`instance_definition_snapshots.definition_ver`) because its
job was to report a version *identifier* on an already-completed task read, independent of
any graph content. This requirement needs no equivalent new read: it is not reporting a
version identifier, it is reading a **node attribute value** that only ever exists inside a
`Graph.t()`, and the `Graph.t()` this requirement's write path already receives (via
`TaskActivation.append_multi/6`'s existing `graph` argument) is *already* the pinned one —
per §3.1, that has been true since before REQ-126 existed, for the same structural reason
REQ-126's own design §2.2 documents ("the snapshot already pins it, for a reason that
predates this requirement"). No new join, no new column, no new lookup function.
`insert_attrs/4`'s signature does not change to add a version parameter — the pinning is
already fully expressed in which `node` value the function is handed, which is unchanged
by this requirement.

### 3.3 Acceptance-criterion-4 test scenario (for TEST-DESIGNER), stated explicitly since it mirrors REQ-126 §7.2

1. Create process definition **v1** with a `HUMAN_TASK` node carrying
   `attributes["form_schema"] = <schema A>`.
2. Start an instance from v1 (`Letflow.Engine.create/2`) — activates a `tasks` row for
   that node; assert (read back from the DB) `form_schema == <schema A>`.
3. Promote a **new** version **v2** of the same process, changing that same node's
   `attributes["form_schema"]` to `<schema B>` (a distinct value).
4. Re-read the task row created in step 2 (still via a fresh DB read, not the in-memory
   struct) and assert `form_schema` is still `<schema A>` — proving the value was pinned
   at activation time and is never re-derived from the now-current `process_definitions`
   row. (No route change is needed to observe this — the assertion reads
   `Letflow.Repo.get/3` on the `tasks` table directly, since exposing `form_schema` over
   HTTP is explicitly out of scope, §4.)

---

## 4. Scope fence — explicit restatement

This requirement changes **only** `lib/letflow/engine/task_activation.ex` (the `attrs` map
`insert_attrs/4` builds) and the moduledoc location(s) named in §5. It does **not** touch:

- **`lib/letflow/engine/variable_merge.ex`** — `form_schema` is never read by, passed to,
  or referenced from `merge/3` or any of its helpers. Output-variable validation authority
  stays exactly where REQ-109 put it (`variable_schemas`, via
  `Letflow.Engine.VariableSchema.variable_validations/5`). No call from this requirement's
  code reaches `VariableMerge` in either direction.
- **`lib/letflow/engine.ex`'s completion path** — `complete_task/3` and every function it
  calls for merging/validating output on task completion are unchanged. `form_schema` is
  written once, at activation, and never read back by any completion-path function.
- **`lib/letflow/routers/tasks.ex`** — `task_detail_map/3`'s allowlist (13 keys, per its
  own "Response allowlists" section) keeps excluding `form_schema` exactly as it does
  today; that exclusion is a deliberate, still-open, separately-scoped concern (REQ-047
  §4.4 OQ-3) this requirement does not resolve. No key is added, removed, or reordered in
  either response map by this change.

Violating any of the three above would make a tenant-supplied rendering payload an
authority over what a tenant may submit — the exact INV-2 violation REQ-273's own
constraint 1 warns against. TEST-DESIGNER's coverage should include a negative assertion
(e.g. a `mix format`/`grep`-level check, or simply confirming no new reference exists) that
`variable_merge.ex`, `engine.ex`'s completion functions, and `routers/tasks.ex` have zero
new lines referencing `form_schema`.

---

## 5. Moduledoc requirement

Whichever module's function is changed to write the `form_schema` key — `TaskActivation`,
per §1-§2 above — gets a new moduledoc paragraph (placed alongside the existing "No
assignment resolution here" / "Zero `Repo` calls of its own" sections, matching that
module's existing per-concern-paragraph convention) stating, in substance:

> `form_schema` is populated here from `node.attributes["form_schema"]` verbatim. It is a
> UI rendering payload only, never a validation authority — this module does not, and must
> never, feed it into `Letflow.Engine.VariableMerge` or any output-variable validation
> path (see `lib/letflow/engine/variable_schema.ex`'s moduledoc, which names this exact
> distinction and the table this module writes into). The only structural check performed
> is `Letflow.Definitions.JsonSchemaShape.check/1`'s shape well-formedness predicate — not
> a JSON-Schema meta-schema validator and not a check against submitted task-completion
> output.

This directly satisfies REQ-273's own moduledoc acceptance criterion, and mirrors how
`Letflow.Engine.VariableSchema`'s own moduledoc already states the equivalent boundary
from the other table's side (variable_schema.ex lines 20-27), so a reader who lands on
either module sees the same boundary stated from both directions.

---

## 6. Acceptance-criteria coverage map

| AC (from `docs/requirements.yaml` REQ-273) | Covered by |
|---|---|
| Persisted `form_schema` equals node attribute, read back from DB | §1.1-§1.2 (new key in `insert_attrs/4`'s returned map, flowing through the existing `insert_changeset/2` cast) |
| Absent attribute → `nil`, never an invented default | §1.1 table, row 1 (`Map.get/2` with no default, mirroring `resolve_assignee/1`) |
| Malformed schema rejected at activation, typed error naming the node, no tasks row written, via `JsonSchemaShape.check/1` (not a hand-rolled predicate) | §2.1-§2.3 |
| Schema pinned to the version the task was created against, not a later-promoted version | §3.1-§3.3 |

---

## 7. Open questions (not silently resolved)

- **OQ-1** — Whether the `form_schema` resolution + shape-check should live as a private
  helper inline in `task_activation.ex` (structurally beside `resolve_assignee/1`) or as a
  small separate function with its own `@spec` (e.g. `resolve_form_schema/1 ::
  {:ok, map() | nil} | {:error, {:invalid_form_schema, String.t(), term()}}`). This design
  does not mandate one over the other — either satisfies every acceptance criterion above
  — but flags it for ELIXIR-DEV/REVIEWER to settle rather than picking silently, since
  `resolve_assignee/1` (returns a plain tuple, cannot fail) and this new resolution (can
  fail) are not quite the same shape and a reviewer may prefer they not share one function.
- **OQ-2** — Whether the `{:invalid_form_schema, node_id, reason}` error tuple should also
  be surfaced through `Letflow.Audit` (this module's existing `alias Letflow.Audit`) the
  way other activation-path rejections are audited, or whether it is sufficient that the
  transaction rolls back with no row written and the error return is the only trace. REQ-
  273's acceptance criteria do not require an audit entry; this design does not add one,
  but flags the question for REVIEWER since audit coverage of rejected activations is a
  security-adjacent concern SECURITY-REVIEWER may want addressed explicitly rather than by
  omission.
