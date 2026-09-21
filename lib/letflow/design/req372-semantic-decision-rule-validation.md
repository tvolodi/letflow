# REQ-372 — Semantic decision-rule validation (field-existence + type-compatibility)

Design artefact for REQ-372 (WF-02 run WF02-REQ372-20260921), authored by CODE-DESIGNER.
Backend-only. No `web/` change is designed here — canvas/problem-list presentation is an
explicit follow-on FRONTEND-DEV requirement, same two-step shape as REQ-288 → REQ-291.

## 0. Re-verification performed before designing (per task instructions)

All four re-verification points the handoff required were checked directly against
current source on `feature/WF02-REQ372-20260921`, not inferred from the requirement's own
prose:

1. **`Letflow.Definitions.Graph.Violation`'s shape and `validate_edge_conditions/1`'s call
   sites** (`lib/letflow/definitions/graph.ex`): `Violation` is still exactly
   `defstruct [:code, :message]` (lines 180-227), `code()` is a closed union currently at
   28 variants (last added by REQ-291: `:form_schema_computed_field_cycle`).
   `validate_edge_conditions/1` (line 420) still runs exactly 6 checks
   (`check_gateway_condition_presence/1`, `check_unpermitted_edge_condition/1`,
   `check_default_condition_conflict/1`, `check_single_default_edge/1`,
   `check_cel_syntax/1`, `check_human_task_fallback_edge/1`) and its three call sites in
   `lib/letflow/definitions.ex` are unchanged from REQ-288's own account: `create/2`
   (line 558), `validate_update_graph/1` under `update/2` (confirmed at the `:ok <-
   validate_update_graph(attrs)` step of `update/2`, line 1624), and
   `validate_definition_graph/2` (line 1253, the read-only
   `POST /api/v1/definitions/:id/validate` endpoint — **not** a draft-save path; see §3.1
   for why this matters).
2. **`VariableSchema`'s declared-field type vocabulary**
   (`lib/letflow/engine/variable_schema.ex`): `json_schema` is stored as an arbitrary
   well-formed-at-every-level JSON object (`JsonSchemaShape.check/1`,
   `lib/letflow/definitions/json_schema_shape.ex` — structural well-formedness only, no
   keyword vocabulary enforcement). The **runtime-meaningful** `"type"` vocabulary is
   defined by `Letflow.EventStore.Registry.JsonSchema.matches_type?/2`
   (`lib/letflow/event_store/registry/json_schema.ex:82-93`): exactly `"string"`,
   `"number"`, `"integer"`, `"boolean"`, `"object"`, `"array"`, `"null"`, or a list of
   these. **There is no distinct `"money"` type** — a money-valued field is declared as
   `{"type": "number"}` (or `"integer"`) with, by convention, an inert `"format"`
   annotation (`format` is explicitly "permitted and inert", never enforced, per that
   module's moduledoc). §2 below states the comparability table in terms of this real
   vocabulary, not an invented one.
3. **HUMAN_TASK routing-by-field**: grepped `lib/letflow/` for any mechanism resolving a
   HUMAN_TASK `role`/assignment attribute against a declared process field. None exists.
   `check_human_task_role/1` (`graph.ex` CHK-09) requires `attributes["role"]` to be a
   non-blank **plain string**, never an expression, and nothing under `lib/letflow/engine/`
   evaluates any HUMAN_TASK attribute through `Expr`. §4 records this as an explicit
   out-of-scope decision, not a silent omission.
4. **The release/promotion submission call path**: read `lib/letflow/definitions/
   promotion.ex` in full and the relevant slice of `lib/letflow/definitions.ex`.
   `Letflow.Definitions.Promotion.promote_definition/3` /
   `promote_active_definition/5` are the **cross-tenant** solution-pack promotion path
   (REQ-037/077) — they copy `source_row.graph` verbatim into a new target-tenant row via
   `ProcessDefinition.create_changeset/2` and call **no** `Graph` validator at all today.
   That is a different operation from what this requirement's own source scenario
   describes. `test/fixtures/uat/scenarios/platform/definition-type-error-blocked.yaml`
   step 5 says the author "**submits the corrected process for release to the live
   workspace**" — i.e. moves it from DRAFT to ACTIVE **within the same tenant**. That
   operation is `Letflow.Definitions.activate/2` (`lib/letflow/definitions.ex:745`, PD-03).
   **Confirmed by reading `run_activate_transaction/4` (line 2280) and
   `run_service_scope_validator/3` (line 2305): `activate/2` today calls no `Graph`
   validator of any kind** — not `validate_graph/1`, not `validate_node_attributes/1`, not
   `validate_edge_conditions/1`. It only optionally runs an injected
   `service_scope_validator`. This is the gap this requirement's release-time re-check
   fills; see §3.2. `Letflow.Definitions.Promotion` is confirmed **not** the call path
   this requirement's AC6 targets, and is out of scope for this design.

## 1. New module: `Letflow.Definitions.SemanticValidation`

**Naming rationale**: sibling to `Letflow.Definitions.SubProcessInterface` and
`Letflow.Definitions.FormSchemaExpressions` — both are already-established
"produce `Graph.Violation.t()` structs for a concern `graph.ex` itself doesn't own,
consumed by `Letflow.Definitions`" modules living in `lib/letflow/definitions/`.
`SemanticValidation` follows the identical shape: a pure function taking a `Graph.t()`
(plus this module's one extra input, the declared fields) and returning
`Graph.result()`. File: `lib/letflow/definitions/semantic_validation.ex`.

**Purity**: same invariant as `Graph` itself (its moduledoc's AC5) — no `Repo`, no
`Ecto.Changeset`, no `Logger.*`, no clock, no I/O. The impure part (reading
`variable_schemas` fresh) is entirely the **caller's** job
(`Letflow.Engine.VariableSchema.fetch_schemas/3`, already public, already issues exactly
one query with no caching layer — see §3 for why this by itself satisfies AC6's
"re-runs in full, never a cached prior result").

### 1.1 Types

```
@type type_family :: :numeric | :string | :boolean | :array | :object | :unknown

@type declared_fields :: Letflow.Engine.VariableSchema.schema_map()
# i.e. %{optional(String.t()) => map()} -- variable_key -> its stored json_schema map,
# exactly Letflow.Engine.VariableSchema.fetch_schemas/3's {:ok, schema_map} payload.
```

### 1.2 Public functions (signatures only — no bodies)

```
@spec validate(graph :: Letflow.Definitions.Graph.t(), declared_fields :: declared_fields()) ::
        Letflow.Definitions.Graph.result()
```
The single entry point. `Letflow.Definitions.Graph.result()` is reused verbatim
(`%{valid: boolean(), violations: [Graph.Violation.t()]}`) — see §2.4 for why the
`Violation` struct itself is reused rather than a new struct invented. Walks every
`EXCLUSIVE_GATEWAY`-sourced edge with a non-blank `condition` (§2.1), and for each one
collects every field-existence violation (§2.2) and every type-compatibility violation
(§2.3) across the **whole graph in one pass** — `Enum.flat_map/2` over all qualifying
edges, no `Enum.find/2`/early return anywhere in the call chain, mirroring every existing
`Graph` check's "never short-circuits" convention. Maps to **AC1, AC2, AC3, AC4, AC5**.

**Ordering contract (states the same convention `graph.ex`'s own moduledoc states for
PD-05/PD-06, extended by one more link)**: this function assumes, but does not verify,
that `Graph.validate_graph/1` **and** `Graph.validate_edge_conditions/1` have already
been run against the same `graph` value and both returned `valid: true`. It does not
call either. The reason `validate_edge_conditions/1` specifically must already be clean:
CHK-17 (`check_cel_syntax/1`) is what guarantees every non-blank edge `condition` is
syntactically valid CEL — `translate_cel_to_expr/1` + `parse_strict/1` are guaranteed to
succeed only under that precondition. Calling `validate/2` against a graph with a
grammar-invalid condition will not crash (§1.2's `parse_source/1` internal helper
defensively skips an edge whose condition fails to translate/parse, contributing zero
violations for that edge from this pass — the same "total and defensive" convention
`validate_edge_conditions/1`'s own moduledoc states for a dangling-edge source), but the
CEL-syntax violation is CHK-17's to report, not this module's job to duplicate or paper
over. Enforcing "run `validate_graph/1` → `validate_edge_conditions/1` →
`SemanticValidation.validate/2`, in that order" is entirely the caller's job — see §3.

```
@spec levenshtein_distance(a :: String.t(), b :: String.t()) :: non_neg_integer()
```
Classic Wagner–Fischer dynamic-programming edit distance over `String.graphemes/1` (not
byte-based — a multi-byte grapheme counts as one edit unit, consistent with this
codebase's other string-length work, e.g. `variable_key`'s own byte-vs-character
handling note in `definitions.ex`, deliberately chosen to be the opposite there for a
column-width reason that does not apply here). **Case-sensitive** — `"Customer_Name"`
and `"customer_name"` are one substitution apart, not identical; declared field names and
authored references are both raw strings as typed, and silently case-folding would let a
real typo (`Customer_Name` vs `customer_name`) go unreported as "close enough" while
still failing the actual existence check. This is a real string-distance measure, not a
placeholder — satisfies AC2's explicit "not a placeholder or first-alphabetical
fallback" requirement.

```
@spec nearest_declared_field(typed_name :: String.t(), declared_field_names :: [String.t()]) ::
        String.t() | nil
```
Returns the element of `declared_field_names` with the minimum
`levenshtein_distance/2` against `typed_name`; `nil` iff `declared_field_names == []`
(nothing to suggest — e.g. a process with zero declared variables at all). **Tie-break**:
the alphabetically-first (`String.<`) candidate among those sharing the minimum distance
— deterministic regardless of map/list iteration order, explicitly NOT "first in
declaration order" (which would be a hidden dependency on `declared_fields`' insertion
order, itself dependent on a `Map.new/1` call inside `fetch_schemas/3` with no
documented ordering guarantee). **No maximum-distance cutoff** — a suggestion is always
produced whenever at least one field is declared, even for a very distant typed name.
This is a deliberate simplicity choice, not an oversight — see §5 OQ-1.

No other public functions. Everything else (AST walking, type-family resolution, operand
classification) is private to this module.

## 2. The semantic checks themselves

### 2.1 Which edges are walked

Exactly the edges `Graph`'s own CHK-13 (`check_gateway_condition_presence/1`) and CHK-17
(`check_cel_syntax/1`) already treat as "an EXCLUSIVE_GATEWAY's own condition": every
edge whose `source` resolves (via a first-occurrence-wins node-id index built locally,
the same construction `Graph.build_node_index/1` uses — reimplemented locally rather than
calling `Graph`'s private helper, since `SemanticValidation` only depends on `Graph.t()`,
`Graph.Node.t()`, `Graph.Edge.t()` — all public — never on `Graph`'s private functions;
this keeps the module boundary the same shape REQ-032/REQ-291's delegate modules already
use) to a node whose `node_type == :EXCLUSIVE_GATEWAY`, AND whose `condition` is
non-`nil` and non-blank after `String.trim/1`. HUMAN_TASK-sourced conditions are **not**
walked by this requirement — see §4.

### 2.2 Field-existence check (AC1, AC2)

For each qualifying edge: `translate_cel_to_expr/1` → `parse_strict/1` its `condition`
(defensive-skip on either error, per §1.2's ordering contract note), then walk the
resulting `Letflow.Engine.Expr.ast()` recursively collecting every `{:var, path}` node
(`path :: [String.t()]`, `variables.` prefix already stripped by `translate_cel_to_expr/1`
— confirmed at `expr.ex:161-163`).

**Only `hd(path)` — the root segment — is checked for existence** against
`Map.keys(declared_fields)`. `VariableSchema.variable_key` is a single flat string with
no nested-path concept (`fetch_schemas/3` selects one row per `(definition_id,
variable_key)` pair, not per JSON-pointer path into a schema's `"properties"`), so a
multi-segment reference (`variables.customer.name`, `path == ["customer", "name"]`) can
only ever be checked at its root (`"customer"`); this design does **not** attempt to
resolve `"name"` against `"customer"`'s own `json_schema["properties"]["name"]` — that
would be a materially different check (validating against a nested schema, not "is this
top-level field declared") and REQ-372's own AC1/AC2 examples (`cusotmer_name`) are both
single-segment. Recorded as an explicit scope decision, not a silent gap — see §5 OQ-2.

Violation, one per undeclared root segment per `{:var, _}` occurrence (not deduplicated
across multiple occurrences of the same misspelled name in one condition, or across
edges — matching CHK-05/CHK-16's "N occurrences → N violations" convention already used
elsewhere in this file, not a "one violation per distinct undeclared name" convention):

```
%Graph.Violation{
  code: :undeclared_variable_reference,
  message: "Edge '<edge.id>' (from EXCLUSIVE_GATEWAY node '<edge.source>') condition " <>
    "references undeclared variable '<typed_root_segment>'" <>
    <suggestion_clause> <> # "; nearest declared field: '<name>'" or "" if nil
    "; rule as authored: \"<edge.condition>\""
}
```

`<typed_root_segment>` is `hd(path)` **verbatim as authored** (AC1's "exact typed
string"). The suggestion clause calls `nearest_declared_field/2` against
`Map.keys(declared_fields)`; omitted entirely (not "nearest declared field: none") when
`nearest_declared_field/2` returns `nil`.

### 2.3 Type-compatibility check (AC3)

For each qualifying edge's parsed `ast()`, walk it collecting every `{:cmp, op, left,
right}` node (all 6 `cmp_op()` values — `:eq, :neq, :lt, :lte, :gt, :gte` — treated
identically; see §5 OQ-3 for why this check is deliberately not narrowed to only the 4
ordering operators). For each `{:cmp, op, left, right}` node, resolve each operand's
`type_family()` (or an exemption sentinel) via `operand_family/2` (private, takes one
operand's `ast()` node plus `declared_fields`):

  * `{:lit, nil}` → **exempt** (`:null_literal`) — a `field == null` / `field != null`
    guard is common, legitimate authoring and must never be flagged regardless of
    `field`'s declared type. This exemption applies to **either** side of the
    comparison.
  * `{:lit, v}` where `is_number(v)`, or `{:lit, infinity_marker}` (`:infinity` /
    `:neg_infinity` / `:nan` — REQ-197's arithmetic sentinels, never authorable directly
    but defensively covered since they inhabit `ast().value()`) → `:numeric`.
  * `{:lit, v}` where `is_binary(v)` → `:string`.
  * `{:lit, v}` where `is_boolean(v)` → `:boolean`.
  * `{:var, path}` → look up `hd(path)` in `declared_fields`; **not found** →
    **exempt** (`:unresolvable` — this operand is already independently reported by
    §2.2's field-existence check against the same edge; the comparability check does not
    also fire against an operand whose type cannot even be known, avoiding a redundant
    second violation for the same root cause). **Found** → `declared_type_family/1`
    (§2.3.1) of its stored `json_schema`.
  * Anything else (`{:arith, ...}`, `{:call, _, _}`, `{:neg, _}`, a nested `{:cmp, ...}`
    used as a boolean sub-operand under `and`/`or` rather than directly compared) →
    `:unknown` — **exempt**. Deliberately not typed from `Expr`'s own builtin/arithmetic
    return shapes in this version; see §5 OQ-4.

If **either** side resolved to an exempt sentinel (`:null_literal` or `:unresolvable`) or
to `:unknown`, the node produces **no violation** — skip. Otherwise, both sides are one
of `:numeric | :string | :boolean | :array | :object`:

  * `left == :object or right == :object` → **violation** (structural types are never a
    sensible comparison operand in this grammar — REQ-197's `eval/2` has no defined
    structural-equality semantic for a CEL condition, and `array`/`object` operands can
    only ever have reached a gateway condition through a declaration mistake).
  * `left == :array or right == :array` → **violation**, same reasoning.
  * Otherwise (`left`/`right` both drawn from `{:numeric, :string, :boolean}`) →
    **violation iff `left != right`** — the three primitive families are pairwise
    incompatible and each is only compatible with itself. (`:array`/`:object` are handled
    above precisely so they don't fall into this same-family branch and get treated as
    mutually "comparable" with themselves by accident.)

This is the full table (rows/columns are `type_family()`, "—" = same-family cell already
covered by the general rule above, not a separate case):

| vs.      | numeric | string | boolean | array | object |
|----------|---------|--------|---------|-------|--------|
| numeric  | OK      | VIOLATION | VIOLATION | VIOLATION | VIOLATION |
| string   | VIOLATION | OK   | VIOLATION | VIOLATION | VIOLATION |
| boolean  | VIOLATION | VIOLATION | OK | VIOLATION | VIOLATION |
| array    | VIOLATION | VIOLATION | VIOLATION | VIOLATION | VIOLATION |
| object   | VIOLATION | VIOLATION | VIOLATION | VIOLATION | VIOLATION |

(`:unknown`, `:null_literal`, `:unresolvable` are not rows/columns — they exempt the
whole comparison from this table entirely, per the skip rule above.) **At minimum,
numeric vs. string is recorded non-comparable**, satisfying AC3's explicit floor.

Violation shape:

```
%Graph.Violation{
  code: :incompatible_comparison_operand_types,
  message: "Edge '<edge.id>' (from EXCLUSIVE_GATEWAY node '<edge.source>') condition " <>
    "compares incompatible types: '<left_repr>' (<left_family>) <op> '<right_repr>' " <>
    "(<right_family>); rule as authored: \"<edge.condition>\""
}
```

`<left_repr>`/`<right_repr>`: `"variables.<path joined with \".\">"` for a `{:var, path}`
operand, `inspect(value)` for a `{:lit, value}` operand. `<op>` is the CEL-spelling of the
operator (`==`, `!=`, `<`, `<=`, `>`, `>=`), not the internal atom, for readability against
`edge.condition`'s own authored text.

#### 2.3.1 `declared_type_family/1` — resolving a stored `json_schema`'s family

```
@spec declared_type_family(json_schema :: map()) :: type_family()
```
(private)

  * `json_schema["type"]` is a binary → `family_of_type_name/1` (below) of that string.
  * `json_schema["type"]` is a list → `family_of_type_name/1` mapped over every element,
    `"null"` entries dropped (they mark nullability, contribute no family of their own —
    an author declaring `["string", "null"]` means "a string, or absent", not "string or
    null-typed"), duplicates collapsed via `MapSet`. Zero families remain (e.g. the
    declared type was `["null"]` alone, or an empty list) → `:unknown`. **More than one**
    family remains (e.g. `["string", "number"]`, a genuinely polymorphic field) →
    `:unknown` — deliberately conservative: this design does not attempt to reason about
    "comparable against at least one of several declared types"; see §5 OQ-5. Exactly one
    family remains → that family.
  * `json_schema["type"]` missing, or present but neither a binary nor a list (JSON
    Schema's `"type"` keyword is optional; a stored document with no `"type"` key at all
    is well-formed per `JsonSchemaShape.check/1`, which never inspects `"type"`) →
    `:unknown`.

`family_of_type_name/1` (private, total — never raises, matches
`Letflow.EventStore.Registry.JsonSchema.matches_type?/2`'s own vocabulary exactly since
that is the runtime-authoritative type-name list per §0 point 2):

```
"string"  -> :string
"number"  -> :numeric
"integer" -> :numeric
"boolean" -> :boolean
"object"  -> :object
"array"   -> :array
"null"    -> (dropped before this function is reached, see above -- not a real input here)
_other    -> :unknown   # an unrecognized type-name string, same "inert" stance as
                         # Letflow.EventStore.Registry.JsonSchema.matches_type?/2's own
                         # catch-all clause
```

### 2.4 Why `Graph.Violation` is reused, not a new struct

`Graph.Violation` is `defstruct [:code, :message]` — every existing check already folds
all identifying detail (edge id, node id, offending attribute value, line/column for the
CEL grammar check) into the `message` string rather than adding struct fields per check
(CHK-11's `timeout_ms` value, CHK-12's `duration_iso8601` value, CHK-17's
`line`/`column`/`token_text` are **all** message-string content, never new struct
fields — see `graph.ex`'s own "CHK-17 grammar tightening" moduledoc section for this
precedent stated explicitly: "`parse_failure`'s `line`/`column`/`token_text`/`message`
folded into the existing `Violation.message` string rather than added as new struct
fields, so `violation_map/1` and the HTTP response shape are unchanged by construction").
This design follows the identical convention: edge id, source node id, the typed variable
name, the suggestion, the operand type families, and the authored rule text are all
`message` content. **Two new `Violation.code()` atoms are added to `graph.ex`'s existing
closed union** (a `@type` edit only, zero logic change to `graph.ex` — mirrors how
REQ-032/REQ-291 added their own codes to this same union for checks that also live
outside `graph.ex`, in `SubProcessInterface`/`FormSchemaExpressions`):

```
@type code ::
        ...
        | :form_schema_computed_field_cycle   # (existing, REQ-291, last in the union)
        | :undeclared_variable_reference        # NEW, REQ-372
        | :incompatible_comparison_operand_types # NEW, REQ-372
```

No change to `graph.ex`'s `validate_graph/1`, `validate_node_attributes/1`, or
`validate_edge_conditions/1` — `SemanticValidation.validate/2` is a fourth, independent
top-level check function, composed by the caller (§3), the same way `validate_graph/1`,
`validate_node_attributes/1`, `validate_edge_conditions/1` are three independent
functions already composed by `create/2`/`validate_definition_graph/2` rather than one
calling another.

## 2.5. AMENDMENT (2026-09-21): the zero-declared-fields exemption

**Trigger**: TEST-DESIGNER's Step 3 handoff
(`handoffs/WF02-REQ372-20260921/step-03-test-designer.json`) ran the full
`mix letflow.check.test` suite against §3.2's `activate/2` wiring exactly as this design
specified it, and found 31 of 32 total suite failures share one root cause: `activate/2`'s
new hard gate (`run_semantic_validation/2` → `SemanticValidation.validate/2`) flags
**every** `{:var, path}` reference in a gateway condition as `:undeclared_variable_reference`
whenever a definition's `declared_fields` is the empty map — because
`Map.has_key?/2` against `%{}` is `false` for any key. Since `VariableSchema` registration
is optional today (§0 point 2 of this design — nothing in the pre-REQ-372 codebase ever
required it) and the overwhelming majority of pre-existing process-definition fixtures
across the suite (`test/letflow/simulation/req207_vortex_test.exs`,
`req208_meridian_test.exs`, `req206_swiftroute_test.exs`,
`test/letflow/scheduler_req188_test.exs`, `test/letflow/engine_test.exs`, and many more)
never registered a `VariableSchema` row at all, `activate/2` as designed in §3.2 blocks
activation for essentially every pre-existing definition with zero declared fields. This
was not covered by OQ-1 through OQ-6 above — those flag deliberate scope narrowings within
"a schema was declared, is it being checked correctly"; none of them anticipated "no
schema was ever declared for this process at all." This is a real gap in this design, not
a defect in the implementation or the tests, and is amended here rather than left for
ELIXIR-DEV to guess at.

### 2.5.1 Decision

**When `declared_fields == %{}` (the definition has zero `variable_schemas` rows —
`VariableSchema.fetch_schemas/3` returned an empty map), `SemanticValidation.validate/2`
skips both violation classes entirely and returns `%{valid: true, violations: []}`
unconditionally, without walking any edge.** This is decision (a) of the two the
triggering handoff posed, not some third alternative — deliberately, for the reasons
below.

### 2.5.2 Reasoning

  * **A process that never registered a schema has no schema to validate against.**
    §2.2's field-existence check and §2.3's type-compatibility check both exist to catch
    an authored reference or comparison that is *wrong relative to a schema the author
    actually declared* — a typo against a real declared field, or a comparison between
    two real declared types. When zero fields are declared, there is no author intent to
    be wrong *against*: every `{:var, path}` reference is "undeclared" in exactly the
    same trivial, content-free way, and every comparison operand involving a variable
    resolves to `:unresolvable` (already exempt per §2.3's own operand-family rules) —
    the type-compatibility check already degrades gracefully to zero violations in this
    case by construction (§2.3's `:unresolvable` exemption), so this amendment's only
    real effect is on the field-existence check, which had no equivalent exemption.
  * **Treating "no schema declared" as "every reference is a typo" inverts REQ-372's own
    intent.** The requirement's source UAT scenario
    (`test/fixtures/uat/scenarios/platform/definition-type-error-blocked.yaml`) is about
    an author who **did** declare fields and **did** make a mistake relative to that
    declaration (`cusotmer_name` vs a declared `customer_name`). It says nothing about
    a process that never adopted `VariableSchema` at all — REQ-372 does not, anywhere in
    its acceptance criteria, assert that `VariableSchema` registration becomes mandatory
    as a side effect of this requirement. Making it mandatory-by-implication (every
    unregistered process now fails to activate) is new, unrequested behavior this
    requirement's own scope does not authorize — the same class of problem §3.1 already
    flagged for `create/2`/`update/2` (don't silently add a gate stricter than what was
    asked).
  * **Retroactively registering a `VariableSchema` for ~31 pre-existing fixtures is out of
    this requirement's scope.** `VariableSchema` registration is, per §0 point 2, a
    separate, optional mechanism with its own lifecycle; REQ-372 is scoped to *validating*
    an existing schema when one exists, not to *mandating* one exist. Forcing every
    pre-existing definition (fixture or real tenant data) to backfill a full schema before
    it can ever activate again is a materially different, much larger requirement than
    REQ-372 as written and validated (REQ-VALIDATOR gated the original requirement text,
    not this implication) — it would also silently break real, already-activated tenant
    workflows outside the test suite the same way it breaks fixtures.
  * **This is the narrowest fix that satisfies the triggering handoff's own AC4**
    ("the fix, once implemented, must not require any of the ~31 pre-existing failing
    fixtures to be individually modified — the amendment must work by construction").
    Skipping both checks when `declared_fields == %{}` is a single guard at the top of
    `validate/2`, touches no fixture, and requires no seeding of `variable_schemas` rows
    anywhere.

### 2.5.3 Where the exemption lives

The guard is added inside `SemanticValidation.validate/2` itself — **not** at either
call site (`activate/2`'s `run_semantic_validation/2` helper, §3.2, or
`validate_definition_graph/2`, §3.3) — so both call sites get the exemption uniformly by
construction, with no risk of one caller remembering the special case and the other
forgetting it. `validate/2`'s own `@spec` is unchanged in shape
(`Graph.t(), declared_fields() :: Graph.result()`); only its documented behavior gains one
new sentence, first in its body's logical order (checked before any edge is walked, not
folded into `edge_violations/2`'s per-edge logic — a whole-graph decision, not a per-edge
one):

```
@spec validate(graph :: Graph.t(), declared_fields :: declared_fields()) :: Graph.result()
```
Behavior amendment: if `declared_fields == %{}`, returns `%{valid: true, violations: []}`
immediately — no node/edge is walked, `field_existence_violations/3` and
`type_compatibility_violations/3` (§1.2/§2.2/§2.3) are not invoked at all for this call.
For any `declared_fields` with at least one entry (`map_size(declared_fields) > 0`),
behavior is **exactly** as specified in §1.2/§2.2/§2.3 above, unchanged — including the
case where a graph references variables that are *all* absent from a *non-empty*
`declared_fields` (that remains a real violation; the exemption is keyed on "zero fields
declared for this process at all," not on "this particular reference wasn't found").

`field_existence_violations/3`'s own signature and per-call behavior are **unchanged** —
it still assumes a non-empty-or-empty `declared_fields` map and still flags every
undeclared root segment exactly as §2.2 specifies; the amendment prevents it from ever
being *called* with an empty map, rather than changing what it does when given one. No
other function in this module changes.

### 2.5.4 Compatibility with the 10 original acceptance criteria — confirmed

All 10 of REQ-372's original acceptance criteria (restated in the triggering handoff's
own `task.acceptance_criteria` and mapped in §6 above) are re-checked against this
amendment:

  * **AC1** (undeclared-variable violation names field + step/edge) — the example this AC
    is proven against necessarily involves a definition that **did** declare fields
    (there must be a "declared VariableSchema fields" set for a reference to be *absent
    from* — the AC's own wording). `declared_fields` is therefore non-empty in every AC1
    test case; §2.5.3's exemption does not trigger; behavior unchanged. **Compatible.**
  * **AC2** (typo-suggestion via real string distance) — same reasoning as AC1: the
    one-typo example (`cusotmer_name` vs declared `customer_name`) requires `customer_name`
    to be declared, so `declared_fields` is non-empty. **Compatible.**
  * **AC3** (non-comparable type-pair violation, numeric vs text) — requires both operands
    to resolve to a real declared type family, which requires at least the compared
    field(s) to be declared; `declared_fields` is non-empty in every AC3 test case.
    **Compatible.**
  * **AC4** (both violation classes from one call) — by construction requires a definition
    with at least one declared field for the type-compatibility half to be triggerable at
    all (§2.3's `:unresolvable` exemption means an operand referencing an undeclared field
    can never itself produce a type-compatibility violation); `declared_fields` is
    non-empty in every AC4 test case. **Compatible.**
  * **AC5** (zero violations validates cleanly, including after both AC4 violations are
    fixed in the same test) — this AC's own fixture starts as AC4's (non-empty
    `declared_fields`) and stays non-empty through the fix; the "clean" result it asserts
    was already `%{valid: true, violations: []}` for a non-empty-`declared_fields` graph
    with no actual violations, which is unaffected by a guard that only fires on the empty
    case. **Compatible** — and this amendment adds a **second**, independent way to reach
    `valid: true` (the empty-`declared_fields` short-circuit) without touching the way
    AC5's own non-empty-`declared_fields` case reaches it.
  * **AC6** (re-runs in full at `activate/2`, reflects fresh state, not cached) — this AC's
    own test mutates `variable_schemas` between two calls and asserts the second call
    reflects the fresh state; both states in that test have **at least the mutated field
    itself** declared (the test changes a field's presence/type, it does not empty the
    schema down to zero rows), so `declared_fields` is non-empty on both calls in every
    AC6 test case. **Compatible** — and if a *future* test exercises exactly "was clean and
    non-empty, then every `variable_schemas` row was deleted between calls," the fresh
    empty-map short-circuit still correctly reflects the fresh (now-empty) state on the
    second call, same "no cache" guarantee, just resolving to the exemption's own new
    branch instead of §2.2/§2.3's branch. Still re-runs in full, still reflects fresh
    state — AC6's actual guarantee. **Compatible.**
  * **AC7** (HUMAN_TASK scope stated explicitly) — untouched by this amendment; §4's
    decision and reasoning are unchanged. **Compatible.**
  * **AC8** (`expr.ex` unmodified) — this amendment touches no `Expr` code, adds no
    token/operator/builtin; it is a single guard inside `SemanticValidation.validate/2`
    that runs *before* any `Expr` call. **Compatible.**
  * **AC9** (no `web/` file modified) — this amendment is confined to
    `lib/letflow/design/req372-semantic-decision-rule-validation.md` (this file); no
    `web/` path is touched. **Compatible.**
  * **AC10** (`mix letflow.check` passes) — this is exactly the AC this amendment exists
    to unblock: per the triggering handoff's own diagnosis, 31 of 32 current failures are
    this single root cause, and the ~31 pre-existing fixtures this amendment is designed
    not to require touching (§2.5.2's fourth point) are the ones currently failing
    AC10. Once ELIXIR-DEV implements §2.5.3's guard, those 31 failures resolve without any
    fixture edit. **Compatible by construction — this is the fix.**

No original acceptance criterion is weakened, narrowed, or made harder to satisfy by this
amendment: AC1–AC6 all describe definitions with real, non-empty declared fields, so the
new empty-`declared_fields` branch is simply never reached by any of their test cases, and
AC7–AC9 are unrelated to `declared_fields` at all.

### 2.5.5 Interaction with §3's call-site wiring

No change to §3.1, §3.2, or §3.3 is required. §3.2's `run_semantic_validation/2` and
§3.3's `validate_definition_graph/2` both already call `SemanticValidation.validate/2`
once per invocation with whatever `declared_fields` map `VariableSchema.fetch_schemas/3`
freshly returns (possibly `%{}`); §2.5.3's guard lives entirely inside `validate/2` and
requires no caller-side change. AC6's "re-runs in full, never cached" guarantee (§3.2) is
unaffected — see §2.5.4's AC6 analysis above.

## 3. Call-site wiring (design, not implementation — exact changes ELIXIR-DEV makes)

Both call sites below live in `lib/letflow/definitions.ex` — **not** listed in this
run's `owned_modules`, but necessarily touched; flagged explicitly here since the
handoff's `owned_modules` list only names the new/verified files, not every file a
correct implementation must edit.

### 3.1 Key decision: draft-save (`create/2`, `update/2`) is deliberately NOT gated

REQ-288's own call-site disposition (this file's §0 point 1) made the **CEL-grammar**
check (CHK-17) strict at `create/2` **and** `update/2` — a grammar-invalid condition
blocks the save outright, zero rows written. This design does **not** extend that same
strictness to the new semantic checks, and that is a deliberate divergence, not an
oversight:

  * The requirement's own source UAT scenario
    (`test/fixtures/uat/scenarios/platform/definition-type-error-blocked.yaml`) step 1
    has the author "add two broken rules... **The author then saves the draft**" and
    step 2 then "**reads the problems shown on screen**" — the save itself succeeds;
    the problems surface as a **separate read**, not as a rejected save. Step 3 similarly
    "corrects only the misspelled field name... **and saves again**" while the second
    rule is still broken. EO-002 states the consequence precisely: "A process holding a
    broken rule **cannot be saved as ready for use. It stays a draft**" — i.e. the gate is
    on the DRAFT → ACTIVE transition (`activate/2`), not on persisting a DRAFT edit at
    all. Blocking `create/2`/`update/2` outright (REQ-288's own convention for grammar
    validity) would make it impossible for an author to save one fix at a time and
    re-check — directly contradicting EO-001's "the author is not made to fix one
    problem to discover the next," which requires the draft to be inspectable, and
    therefore saved, mid-repair.
  * Consequence: `create/2` and `update/2` (`validate_update_graph/1`) are **unchanged
    by this requirement**. A draft may be created/updated holding an undeclared-variable
    or type-incompatible condition; it is simply reported, not rejected, until release.
  * `validate_definition_graph/2` (the read-only check endpoint, §3.3) is where the
    frontend follow-on requirement is expected to read the problem list after each save
    — the same shape REQ-288/REQ-291 already established for this endpoint, extended
    here with this pass's own violations.

**Flagged for REVIEWER**: this is a real behavioral divergence from REQ-288's own
call-site strictness precedent for the sibling `create/2`/`update/2` paths, made on the
strength of this requirement's own UAT scenario language rather than symmetry with
REQ-288. If REVIEWER disagrees, the fix is mechanical (add the same three-line `with`
clause `validate_definition_graph/2` gets in §3.3, to `create/2` and
`validate_update_graph/1` too) but changes this requirement's authoring UX materially,
so it is called out rather than silently decided either way.

### 3.2 `activate/2` — the release/promotion submission gate (AC6)

`activate/2` (`lib/letflow/definitions.ex:745`) today calls no `Graph` validator (§0
point 4). This design adds the semantic check — and **only** the semantic check; the
already-existing three structural/attribute/edge-condition checks are **not** newly
added here, since REQ-372's scope fence is this pass specifically, and adding
`validate_graph/1`/`validate_node_attributes/1`/`validate_edge_conditions/1` to
`activate/2` for the first time would be new behavior this requirement doesn't ask for
and doesn't have an AC for; flagged as §5 OQ-6, an adjacent gap this run does not close.

Call-site change (described, not written), inside `run_activate_transaction/4`'s
`:draft` branch (currently lines 2296-2300): today, once `run_service_scope_validator/3`
returns `:ok`, that branch calls `activate_draft/3` directly. This design inserts one
new step between those two: after `run_service_scope_validator/3` returns `:ok` (its
existing `{:error, reason} -> Repo.rollback(reason)` outcome is untouched), the branch
calls the new `run_semantic_validation/2` helper (below) before `activate_draft/3` runs.
`run_semantic_validation/2` returning `:ok` proceeds to `activate_draft/3` exactly as
before; any `{:error, reason}` it returns takes the same `Repo.rollback(reason)` path the
`:draft` branch already uses for `run_service_scope_validator/3`'s own error outcome — no
new rollback shape, just one more producer feeding the branch's existing error handling.

New private helper (signature only):

```
@spec run_semantic_validation(ProcessDefinition.t(), prefix :: String.t()) ::
        :ok
        | {:error, :graph_structure_invalid}
        | {:error, {:semantic_validation_failed, [Graph.Violation.t()]}}
        | {:error, {:semantic_validation_precondition_failed,
             :missing_prefix | :invalid_definition_id}}
```

Body (described, not written): `Graph.from_map(definition.graph)` (reusing
`convert_graph/1`'s existing private helper), then
`Letflow.Engine.VariableSchema.fetch_schemas(Repo, definition.id, prefix: prefix)` — a
**fresh** query, issued fresh on every `activate/2` call, inside the very transaction
that has `definition`'s row locked `FOR UPDATE` — this by itself is what makes AC6 hold:
there is no cache anywhere in this path, `fetch_schemas/3` is a plain `Repo.all/2` (§0
point 2), and `SemanticValidation.validate/2` is pure, so the only way the result can
differ between two calls is if the underlying `variable_schemas` rows or the graph
itself actually changed — which is exactly what AC6's test asserts. Then
`SemanticValidation.validate(graph, declared_fields)`; `valid: true` → `:ok`; `valid:
false` → `{:error, {:semantic_validation_failed, violations}}`.
`{:semantic_validation_precondition_failed, reason}` covers `fetch_schemas/3`'s own
`{:error, :missing_prefix}` / `{:error, :invalid_definition_id}` — defensively handled
(same "unreachable in practice, kept typed anyway" convention `variable_schemas.ex:477`'s
own comment states for its `validate_definition_id/1` guard) since `prefix` was already
validated by `activate/2`'s own opening `TenantProvisioning.tenant_id_for_schema_name/1`
call and `definition.id` is a UUID already fetched from a real, locked row.

`activate/2`'s `@spec` return union gains two new error shapes (added, nothing removed):
`{:error, {:semantic_validation_failed, [Graph.Violation.t()]}}` and
`{:error, {:semantic_validation_precondition_failed, term()}}`.

`interpret_activate_result/1` (`lib/letflow/definitions.ex:2390-2400`) gains two new
typed pass-through clauses (described, not written; same shape as its existing
`{:service_scope_violation, _}` and `{:sequence_conflict, _}` clauses — explicit
per-shape matching, INV-8, no catch-all):

  * a clause pattern-matching `{:error, {:semantic_validation_failed, _violations}}`,
    returning that same tuple unchanged;
  * a clause pattern-matching `{:error, {:semantic_validation_precondition_failed,
    _reason}}`, returning that same tuple unchanged.

Both are pure pass-throughs (identical in shape and intent to the existing
`{:service_scope_violation, _}` / `{:sequence_conflict, _}` clauses immediately above
them) — neither clause transforms, wraps, or logs the error; they exist only so
`interpret_activate_result/1`'s explicit per-shape matching stays exhaustive over
`activate/2`'s enlarged return union (INV-8: no catch-all clause is added).

### 3.3 `validate_definition_graph/2` — extended with this pass's own violations

`validate_definition_graph/2` (`lib/letflow/definitions.ex:1253`) currently concatenates
3 violation lists. This design adds a 4th, requiring one additional query
(`VariableSchema.fetch_schemas/3`) — consistent with this function's own moduledoc
statement "Issues exactly one query... plus" (that line's own count needs updating to
"two queries" by ELIXIR-DEV, since this adds the `fetch_schemas/3` read).

```
@spec validate_definition_graph(id :: Ecto.UUID.t(), opts :: keyword()) ::
        {:ok, %{definition_id: Ecto.UUID.t(), valid: boolean(), violations: [Graph.Violation.t()]}}
        | common_error()
```

Change (described, not written): the function's existing `with` chain — resolve
`definition` by `id`/`opts`, convert its stored graph via `convert_graph/1` — gains one
more step before the violations are assembled: a `VariableSchema.fetch_schemas/3` call
for `definition.id` under the same `prefix` already threaded through `opts`, binding the
declared-fields map. The violations list, currently the concatenation of
`Graph.validate_graph/1`, `Graph.validate_node_attributes/1`, and
`Graph.validate_edge_conditions/1`'s three violation lists, gains a fourth term appended
in the same style: `SemanticValidation.validate/2`'s own violations, called with the
converted graph and the newly-fetched declared-fields map. The function's existing
success shape (`{:ok, %{definition_id:, valid:, violations:}}`, `valid` computed as
`violations == []`) is unchanged in structure — only the violations list feeding it grows
by one more concatenated term. `fetch_schemas/3`'s own `{:error, :missing_prefix}` /
`{:error, :invalid_definition_id}` outcomes propagate through the `with` chain's existing
short-circuit behavior unchanged, folding into this function's existing `common_error()`
clause in its `@spec` (both are already `TenantProvisioning`-adjacent failure shapes this
function's `@spec` union already has room for via `common_error()`; ELIXIR-DEV confirms
the exact union member at implementation time — flagged rather than guessed here since
this design doc must not invent `common_error()`'s membership).

This is the "earlier clean validation" half of AC6's own test shape (call
`validate_definition_graph/2`, or `SemanticValidation.validate/2` directly, confirm
clean; then mutate `variable_schemas` or the stored graph; then call `activate/2` and
assert it reflects the new state) — both call sites independently re-fetch, so either
ordering of "which one is the earlier read" in the test satisfies the same underlying
guarantee.

## 4. HUMAN_TASK routing/assignment-by-field: OUT OF SCOPE (AC7)

**Explicit decision, stated here and to be restated verbatim in substance in
`SemanticValidation`'s own moduledoc**: this requirement's semantic checks (§2) walk
**only** `EXCLUSIVE_GATEWAY` edge conditions. No HUMAN_TASK attribute is walked, and no
HUMAN_TASK-routing-by-field mechanism is designed here.

**Reasoning**: §0 point 3 confirmed, by direct source read, that no such mechanism
exists anywhere in `lib/letflow/` today — `check_human_task_role/1` (CHK-09) requires
`attributes["role"]` to be a non-blank **plain string** constant, never an `Expr`
expression, and no HUMAN_TASK attribute is ever routed through `Letflow.Engine.Expr` at
activation, task-creation, or anywhere else in the engine. There is therefore no
existing "authored rule expression" on a HUMAN_TASK node for this pass to validate
against `VariableSchema` at all — the scenario's own preconditions text ("routes to a
reviewer using a field the process does not hold") describes a feature that would first
require a **separate, prerequisite** requirement to invent a HUMAN_TASK
assignment-by-field expression mechanism (a new node-attribute shape, a new consumption
point in the engine, its own grammar/scope decisions) before any validation of it could
be designed. Silently assuming HUMAN_TASK-role-as-expression already exists, or silently
inventing the mechanism as a side effect of this validation requirement, would both be
wrong per this task's own explicit instruction not to guess. **This gap is filed
separately, not solved here.**

## 5. Open questions (explicit, not silently resolved)

  * **OQ-1** (no max-distance cutoff on `nearest_declared_field/2`): a very-different
    typed name still gets a "nearest" suggestion, however unhelpful. Acceptable per
    AC2's own wording (no cutoff requested) but flagged in case REVIEWER wants a
    threshold (e.g. only suggest when distance ≤ half the declared name's length) added
    later as a small follow-up.
  * **OQ-2** (nested `{:var, path}` references, `length(path) > 1`, are checked only at
    `hd(path)`): a reference like `variables.customer.middle_name` is treated as "is
    `customer` declared" only; whether `customer`'s own `json_schema["properties"]` also
    declares `middle_name` is never checked by this pass. If nested-property validation
    is wanted, it is a distinct follow-up requirement, not implied by REQ-372's own
    AC1/AC2 examples (both single-segment).
  * **OQ-3** (all 6 `cmp_op()` values treated identically by §2.3, not narrowed to the 4
    ordering operators): comparing a money amount to a customer name with `==` is just
    as semantically nonsensical as with `>`, and REQ-372's own text doesn't distinguish
    equality from ordering — narrowing scope to only ordering operators would leave the
    `==`/`!=` case of the exact same authoring mistake unreported. Flagged in case
    REVIEWER reads "comparison" more narrowly than this design does.
  * **OQ-4** (`{:arith, ...}`/`{:call, _, _}` operands are always `:unknown`/exempt, never
    typed from `Expr`'s own builtin signatures): `length(variables.customer_name) >
    variables.amount` could in principle be flagged (an integer-returning builtin against
    a money field is fine; `upper(variables.customer_name) > variables.amount` is the
    same class of mistake this requirement targets) but doing so requires this module to
    encode `Expr`'s builtin/arithmetic return-type rules independently of `Expr` itself,
    which risks drifting out of sync with `Expr`'s own evaluation semantics (REQ-197/198)
    over time. Deliberately deferred rather than guessed at.
  * **OQ-5** (a declared field with more than one non-null `"type"` family, e.g.
    `["string", "number"]`, resolves to `:unknown` — always exempt, never flagged even
    against a genuinely incompatible partner): a stricter design could flag only when
    ALL of the declared families are incompatible with the other operand. Deferred as
    added complexity with no AC requiring it — REQ-372's own AC3 example is a single-type
    field on both sides.
  * **OQ-6** (`activate/2` still never runs `validate_graph/1` /
    `validate_node_attributes/1` / `validate_edge_conditions/1`, only the new semantic
    pass): a definition could in principle reach `activate/2` with STRUCTURAL violations
    a caller inserted by some other, buggier path (though `create/2`/`update/2` already
    block those at save time today, so this is likely unreachable in practice). Adding
    those three checks to `activate/2` for the first time is a reasonable adjacent
    hardening but is not requested by REQ-372 and is left to a separate requirement.

## 6. Acceptance-criteria mapping (explicit, per task instructions)

| AC | Design element |
|----|----------------|
| 1. undeclared-variable violation names field + step/edge | §2.2 violation shape (`edge.id`, `edge.source`, `hd(path)` verbatim) |
| 2. suggestion via real string-distance, one-typo example | §1.2 `levenshtein_distance/2` + `nearest_declared_field/2`; §2.2 suggestion clause |
| 3. non-comparable type pair (numeric/money vs text) produces violation; table stated explicitly | §2.3 + §2.3.1 full table, `:numeric` vs `:string` row |
| 4. two independent violations in one call | §1.2 `validate/2`'s "collects across the whole graph in one pass, no early return" |
| 5. zero violations validates cleanly, incl. after both fixed | §1.2 `Graph.result()` reuse (`valid: violations == []` by construction, same as every other `Graph` check) |
| 6. re-runs in full at release/promotion submission, reflects fresh state | §3.2 `activate/2` wiring — fresh `fetch_schemas/3` read every call, pure `validate/2`, no cache anywhere |
| 7. HUMAN_TASK scope stated explicitly with reasoning | §4 |
| 8. `expr.ex` unmodified | §0/§1/§2 — only `translate_cel_to_expr/1` and `parse_strict/1`, both already-public, are called; no grammar/token/operator/builtin change proposed anywhere in this design |
| 9. no `web/` file modified | This entire design is backend-only (§ intro); no `web/` path appears anywhere above |
| 10. `mix letflow.check` passes | Implementation-phase obligation (ELIXIR-DEV/TEST-RUNNER), not a design-time artifact — noted so the mapping table is complete; §2.5 amendment (2026-09-21) is what makes this achievable without editing ~31 pre-existing fixtures |
