# REQ-291 — `visible_when`, `computed` and cross-field validation in the x-ui vocabulary

Design only. No implementation code. Bare signatures, `@type`/`@spec` shapes, and
verbatim citations of *existing* real code are given where needed; no full function
bodies appear anywhere below.

## 1. Re-verification (2026-09-09, this session)

All factual claims in the requirement text were re-derived from source, not trusted.

1. **`docs/frontend/x-ui-widget-vocabulary.md` exists** (REQ-284). Read in full. Its §6
   ("Field logic is deferred, not rejected") is the exact deferral this requirement
   resolves:

   > "Field logic is excluded from REQ-284 only because D1a's own sequencing
   > (steps 8-12) makes it a separate track... A later reader must not treat this
   > vocabulary's silence on field logic as D1a having been re-closed here — it has
   > not."

   §2 ("This is the complete vocabulary") is scoped explicitly to `x-ui.widget`, not
   `x-ui` as a whole, so adding `x-ui.visible_when`/`x-ui.computed`/
   `x-ui.cross_field_validation` does not contradict it. §7's "client-side validation
   is a UX affordance only" is the same boundary this requirement's cross-field
   validation key must restate for logic, not just for widget-derived JSON-Schema
   validation.

2. **`docs/migration/decisions/0020-frontend-architecture.md` D1a and Sequencing steps
   8/11**, read in full (the *original*, not the superseded reconstruction — the file
   states the original replaced the reconstruction on 2026-09-09). Load-bearing text
   carried into §3-§6 below:
   - Step 8 (this requirement): "extend the `x-ui` vocabulary with `visible_when`,
     `computed` and cross-field validation, expressed in `Letflow.Engine.Expr`'s
     grammar; validate expressions at definition time so a bad one fails at
     authoring, not at render."
   - Step 11 (REQ-292, NOT this requirement): server-side re-evaluation is "the
     authority half and is not optional."
   - D1a constraint 3 (submit disposition, §5 below): "A client-supplied value for a
     `computed` or hidden field is therefore an *input to be checked*, never a value
     to be stored on trust." This is decision-record text, not something this
     requirement is free to re-pick — see §5.
   - D1a's security-boundary sentence (§6 below): "A field whose *visibility* is
     security-relevant must not be sent to the client at all; the server omits it
     from the schema... it is why the closed grammar is not allowed to reference
     anything the client was not already given."

3. **`lib/letflow/engine/expr.ex`'s moduledoc and public API**, read in full. Confirmed:
   - It is a closed CEL-subset grammar by decision (`now()`/`date_add()`/`date_diff()`
     excluded as impure; `@unsupported_call_markers` closed). Nothing below adds a
     token, operator or builtin — **`lib/letflow/engine/expr.ex` is not touched by this
     design at all.**
   - `translate_cel_to_expr/1` (`@spec translate_cel_to_expr(cel_condition :: String.t())
     :: {:ok, expr_source :: String.t()} | {:error, :unsupported_cel_feature} |
     {:error, :translate_error}`) strips every literal `"variables."` substring
     (`strip_variables_prefix/1`, line ~257-260: `String.replace(cel_condition,
     "variables.", "")`) unconditionally, whether or not the input actually contains
     it — this is why a form-field expression **need not** carry the prefix at all for
     this function to behave identically either way (§4 below pins the actual
     decision).
   - `parse_strict/1` (`@spec parse_strict(expr_source :: String.t()) :: {:ok, ast()} |
     {:error, parse_failure()}`) is the diagnosable-failure entry point REQ-288 already
     established as the one definition-time callers use — `parse_failure()` is
     `%{line: pos_integer(), column: pos_integer(), token_text: String.t(), message:
     String.t()}`.
   - `eval/2`'s own doc: "An undefined variable (missing key at any step of `path`) is
     an eval error, not a nil-propagating case" (`resolve_var/3` returns
     `{:error, {:eval_error, {:undefined_variable, full_path}}}` on a missing key, via
     plain `Map.fetch/2` — a *present* key holding an explicit JSON `null` resolves
     successfully to the value `nil`, which then eval-errors downstream in any
     operation that requires a non-nil type, e.g. arithmetic or ordering comparison).
     This is the exact mechanic §4.3 below turns into a single stated behaviour.
   - `ast()` is a **public, documented `@type`** (`{:lit, value()} | {:var, [String.t()]}
     | {:not, ast()} | {:and, ast(), ast()} | {:or, ast(), ast()} | {:cmp, cmp_op(),
     ast(), ast()} | {:arith, arith_op(), ast(), ast()} | {:neg, ast()} | {:call,
     builtin_name(), [ast()]}`). No module in `lib/` today pattern-matches on it
     externally (`transition.ex` only calls the fully-composed `evaluate_condition/2`),
     but nothing about the type's visibility forbids it — §4.2/§4.4 below build a
     read-only external walker over exactly this public shape, in the *new* module,
     not inside `expr.ex`.

4. **`lib/letflow/definitions/json_schema_shape.ex`**, read in full. It is `Letflow`'s
   named hook for "untyped, untrusted JSON reaching a renderer" (per decision 0020 D3
   point 2, and `lib/letflow/engine/task_activation.ex`'s own moduledoc, which calls it
   "the only structural check performed" on `form_schema`). **Re-verified fact that
   changes this design's shape:** `JsonSchemaShape.check/1` today runs **only at task
   activation** (`Letflow.Engine.TaskActivation.resolve_form_schema/1`,
   `lib/letflow/engine/task_activation.ex:155-169`), **never at definition
   create/update/validate time.** `Letflow.Definitions.Graph.validate_node_attributes/1`
   — the definition-time attribute-check pass — has exactly 5 checks today
   (`check_human_task_role/1`, `check_service_task_endpoint/1`,
   `check_service_task_timeout/1`, `check_timer_duration/1`,
   `check_sub_process_interface/1`) and **none of them touch `form_schema` at all.**
   `JsonSchemaShape` is still the right *predicate* to reuse (per D1a/D3's own naming
   of it for "this class of problem") but it is not itself the hook point — the hook
   point is a **new CHK-20 check added to `validate_node_attributes/1`**, mirroring
   CHK-18's `check_sub_process_interface/1` pattern exactly (a `SUB_PROCESS`-only,
   `attributes`-driven check delegating to its own leaf module). See §2.

5. **REQ-288's actual violation shape**, re-verified from `lib/letflow/definitions/graph.ex`
   (not assumed): `check_cel_syntax/1` (CHK-17) produces
   `%Graph.Violation{code: :invalid_cel_syntax, message: "Edge '#{edge.id}' " <>
   <reason>}`, where `cel_grammar_error/1`'s reason for a `parse_strict/1` failure is
   literally:
   ```
   "condition failed validation at line #{line}, column #{column} " <>
     "(near '#{token_text}'): #{message}"
   ```
   i.e. **no new `Violation` struct field was added for line/column/token_text/message
   — they are folded into the one `message` string**, and the `Violation.code()` type
   is a closed, flat `@type code :: :missing_start_node | ... | :invalid_cel_syntax |
   ...` union that every new violation kind extends by adding an atom, never by adding
   a struct field. §3 follows this convention exactly (folds `parse_failure()` into
   `message`, adds new atoms to `Violation.code()`).

## 2. Where this hooks in: a new CHK-20, not `JsonSchemaShape` directly

New leaf module, mirroring `Letflow.Definitions.SubProcessInterface`'s established
shape (pure, no `Repo`/`Logger`/clock, one list-returning entry point per node,
delegates from `Graph`'s per-node-type check list):

```
Letflow.Definitions.FormSchemaExpressions
```

Entry point:

```
@spec validate_node_form_schema(node_id :: String.t(), attributes :: map() | nil) ::
        [Letflow.Definitions.Graph.Violation.t()]
```

Total and defensive, same discipline as `SubProcessInterface.validate_node_interface/2`:
never raises; returns `[]` when `attributes` is not a map, when `attributes["form_schema"]`
is absent/`nil`, or when `JsonSchemaShape.check(form_schema)` does not return `:ok`.

**Explicit, load-bearing scope decision on the last case:** if `form_schema` fails
`JsonSchemaShape.check/1`'s shape predicate, `validate_node_form_schema/2` returns `[]`
— it does **not** raise a new violation for the shape failure itself. General
`form_schema` shape validation stays exactly where REQ-273 put it (activation time,
`TaskActivation.resolve_form_schema/1`); this requirement's scope fence is "the
definition-time validation of these three keys," not "move `form_schema` shape
validation earlier." Moving that check earlier is a real, separately-worth-doing
improvement (a malformed `form_schema` currently reaches `create`/`update` undetected
and only fails at the first activation) but it is out of this requirement's fence and
is flagged here as an **open question for a future requirement**, not silently done
as a side effect. Walking a form_schema this predicate has already rejected would mean
inventing ad-hoc defensive walking rules that duplicate `JsonSchemaShape`'s own
depth/shape logic for no benefit, since the reject is a foregone conclusion at
activation regardless.

**Graph wiring** (`lib/letflow/definitions/graph.ex`, additive only):

- New private check, with signature:

  ```
  @spec check_form_schema_expressions(t()) :: [Violation.t()]
  ```

  filtered to `:HUMAN_TASK` nodes only (the only node type
  `Letflow.Engine.TaskActivation` ever resolves `form_schema` for — "the signal itself
  is the guard," `task_activation.ex`'s own moduledoc §"No assignment resolution
  here"/"INV-EE47-1": a task row, and therefore a rendered form, only ever exists for a
  `:HUMAN_TASK` node), exactly matching `check_sub_process_interface/1`'s own shape
  (filter nodes by `node_type`, `flat_map` each into
  `FormSchemaExpressions.validate_node_form_schema(node.id, node.attributes)`'s result)
  — no new algorithmic shape, so no body is sketched here; ELIXIR-DEV writes it by
  direct analogy to the existing `check_sub_process_interface/1` function this design
  cites by name and line range in §1 point 4.

- Added to `validate_node_attributes/1`'s check list (currently 5 entries, becoming 6):
  `[&check_human_task_role/1, &check_service_task_endpoint/1,
  &check_service_task_timeout/1, &check_timer_duration/1,
  &check_sub_process_interface/1, &check_form_schema_expressions/1]`.

**Why this requires zero changes to `lib/letflow/definitions.ex`:** all three call
sites REQ-288 named (`create/2` line 547, `validate_update_graph/1` under `update/2`
line 1631, `validate_definition_graph/2` line 1238) already call
`Graph.validate_node_attributes(graph)` unconditionally as part of the same `with`/
concatenation REQ-288 documented. Adding a 6th check function to that list's existing
`Enum.flat_map/2` fold applies to all three call sites automatically, with the exact
same "strict everywhere, no split disposition" shape REQ-288 chose for CHK-17 (design
doc `req288-expr-definition-validator.md` §3) — re-derived independently here, not
copied on faith, and it holds for the same reason: `check_form_schema_expressions/1`
has no notion of "only newly-changed" content, so the identical re-classification
argument REQ-288 already made for `update/2` applies unchanged. No new test is owed
for that argument (it is the same argument, not a new one), but the design doc/test
suite below explicitly re-asserts `update/2`'s behaviour on this new check too, since
"a single blanket answer is ambiguous between the two write paths" was the standard
REQ-288 held itself to, and this addition inherits it.

## 3. New `Violation.code()` atoms (extends the closed union in `graph.ex`, additive only)

Four new atoms, added to `Letflow.Definitions.Graph.Violation`'s existing closed
`@type code :: :missing_start_node | ... | :human_task_no_fallback_edge` union
(alphabetically-unordered like the existing list — it is not sorted today):

```
| :form_schema_x_ui_logic_malformed
| :form_schema_expression_invalid
| :form_schema_expression_out_of_scope
| :form_schema_computed_field_cycle
```

- `:form_schema_x_ui_logic_malformed` — a present `x-ui.visible_when` is not a string;
  a present `x-ui.computed` is not a string; a present `x-ui.cross_field_validation` is
  not a map, or is a map missing `"expression"` (string) or `"message"` (string), or
  has either as a non-string.
- `:form_schema_expression_invalid` — the expression string failed
  `translate_cel_to_expr/1`/`parse_strict/1` (§4.1).
- `:form_schema_expression_out_of_scope` — the expression parsed but references a
  variable path outside the field's declared scope (§4.2).
- `:form_schema_computed_field_cycle` — a `computed`-field dependency cycle (§4.4),
  raised once per node (one violation names the whole cycle), not once per edge in the
  cycle.

All four follow REQ-288's own established convention (§1 point 5 above): **no new
`Violation` struct field.** Every detail (field name, key name, parse
line/column/token_text/message, the out-of-scope variable name, or the ordered list of
field names in a cycle) is folded into the one `message` string. `violation_map/1`
(`lib/letflow/routers/definitions.ex:1212-1213`) is generic over `code`/`message` and
needs no change — re-verified: it pattern-matches only `%Graph.Violation{code: code,
message: message}` and builds a map from those two fields, with no `code`-specific
branch anywwhere in that function.

Message format, mirroring `cel_grammar_error/1`'s exact shape (§1 point 5):

- Invalid syntax: `"Field '#{field_name}' x-ui.#{key} expression failed validation at
  line #{line}, column #{column} (near '#{token_text}'): #{message}"`.
- Out of scope: `"Field '#{field_name}' x-ui.#{key} expression references undeclared
  variable '#{var_name}' — not a property of this form_schema"`.
- Malformed key: `"Field '#{field_name}' x-ui.#{key} is malformed: <specific reason,
  e.g. 'expected a string' or 'cross_field_validation.message must be a string'>"`.
- Cycle: `"Computed-field dependency cycle: #{Enum.join(cycle_field_names, " -> ")} ->
  #{List.first(cycle_field_names)}"`.

## 4. The four semantics REQ-291 requires pinned precisely

### 4.1 The three vocabulary keys, their shape, and syntax validation

Under each field's subschema in `form_schema.properties.<field_name>`, nested in the
same `"x-ui"` object REQ-284 already established for `widget`/`mask`
(`schema['x-ui']`, never a top-level `schema.widget` — REQ-284's own §"the vocabulary
is closed" naming convention, re-used rather than inventing a sibling location):

| Key | Shape | Semantics |
|---|---|---|
| `x-ui.visible_when` | `String.t()` — an `Expr`-grammar expression | Evaluates to a boolean; `false` hides the field (§4.5). Absent key ⇒ field is always visible (no change from today). |
| `x-ui.computed` | `String.t()` — an `Expr`-grammar expression | The field's value is populated by evaluating this expression; the field becomes not user-editable when present (client-rendering concern, not validated here — §"non-goals"). Absent key ⇒ field is a normal user-editable field. |
| `x-ui.cross_field_validation` | `%{"expression" => String.t(), "message" => String.t()}` | `expression` must evaluate to a boolean; `false` means the form does not validate and `message` is the text shown to the user. Attached to the field whose subschema carries it, but semantically may reference any in-scope sibling (§4.2) — it is not restricted to referencing only its own field's value. Absent key ⇒ no cross-field rule from this field. |

Each present key's expression string(s) is validated at definition time exactly like
REQ-288 validates an edge condition: `Expr.translate_cel_to_expr/1` then, on success,
`Expr.parse_strict/1`. Any `{:error, _}` at either stage produces a
`:form_schema_expression_invalid` violation naming the field, the key, and — for a
`parse_strict/1` failure specifically — the line/column/token_text/message (§3). A
`translate_cel_to_expr/1` failure (`:unsupported_cel_feature` / `:translate_error`)
uses the same violation code with a message adapted from `cel_grammar_error/1`'s own
two non-`parse_strict` branches (§1 point 5), so an author sees "this uses a construct
the grammar doesn't support" rather than a raw parse position.

This produces **one test per key** (three tests, not one covering all three, per the
requirement's own acceptance-criteria wording): a `visible_when` with an unbalanced
paren, a `computed` using an `@unsupported_call_markers` construct, and a
`cross_field_validation.expression` with a bare trailing operator — each on its own
otherwise-valid `form_schema`/graph, each asserted to produce exactly one
`:form_schema_expression_invalid` violation naming the right field.

### 4.2 Variable scope and naming: no `"variables."` prefix; flat, sibling-only scope

**Decision: form-field expressions do NOT carry the `"variables."` prefix.** An
expression is written directly against sibling field names, e.g. `amount > 1000`, not
`variables.amount > 1000`.

Justification:
- `translate_cel_to_expr/1`'s `"variables."`-stripping exists to let a gateway-edge
  author write CEL against a `variables.<name>` convention that mirrors the process
  instance's own `variables` map — a convention specific to *process* variables. A
  form field is not a process variable; it is a rendering-payload field local to one
  `form_schema` document. Carrying an unrelated convention's prefix into a different
  namespace (form fields) would suggest a shared namespace that does not exist — a
  form field named `amount` and a process variable named `amount` are two different
  things that happen to share a string.
- `translate_cel_to_expr/1` is still called unmodified either way (§4.1) — its
  `String.replace(_, "variables.", "")` is a no-op on an expression that never
  contains that substring, so choosing "no prefix" costs nothing in the translation
  step and needs no special-casing there.
- If a field name or a substring of an expression happens to literally contain
  `"variables."` (e.g. a field literally named `variables.foo`, which JSON-Schema
  property-key syntax permits but §4.2's own scope rule below makes moot — see next
  point), `translate_cel_to_expr/1`'s blind string replace would still silently strip
  it. This is an existing `Expr` behaviour this requirement does not change or need to
  work around, because:

**Scope rule:** the set of names a field expression may reference is **exactly the
top-level keys of the same `form_schema`'s `"properties"` map** — i.e. the flat set of
sibling field names in that one form, addressed as **single-segment bare identifiers**.
A multi-segment dotted path (`{:var, [_, _ | _]}` in `Expr`'s `ast()`, i.e. any `path`
with more than one element) is **always** out of scope, unconditionally — there is no
nested-field addressing model for form-field expressions (`form_schema.properties`
values other than the top level are not addressable this way at all, even if the
top-level document has nested `properties`/`items` per `JsonSchemaShape`'s own
recursion). This closes the "field literally named `variables.foo`" edge case above by
construction: that name could never be referenced correctly anyway, single-segment or
not, since JSON-Schema property keys containing a literal `.` are legal JSON but would
tokenize as multiple `Expr` path segments the moment anyone tried to write them as a
bare identifier — an authoring hazard this scope rule does not need to solve, since it
is already excluded as multi-segment.

Checking this (the "checkable half of D1a's own rule that an expression may not
reference anything the client was not already given," verbatim from the requirement
text): after a successful `parse_strict/1`, walk the returned `ast()` (§4.4's walker,
`collect_var_paths/1`) collecting every `{:var, path}` node's `path`. For each
collected `path`:
- if `length(path) != 1`, it is out of scope (multi-segment);
- if `length(path) == 1`, `hd(path)` must be a member of
  `Map.get(form_schema, "properties", %{}) |> Map.keys()` (as `String.t()` keys,
  matching JSON's own string-keyed map shape) — if not, `:form_schema_expression_out_of_scope`.

Test: a `visible_when` referencing a name that is not a key of `form_schema.properties`
(e.g. `other_form_field_that_does_not_exist > 5`) is rejected at definition time with
`:form_schema_expression_out_of_scope`, naming the field and the undeclared variable.

### 4.3 Absent/null input to a `computed` field: single behaviour — evaluates to `nil`

**Decision: a `computed` field whose expression evaluation fails for *any* reason —
an absent (undefined) referenced field, a referenced field holding an explicit JSON
`null` that then causes a type-mismatch eval error (e.g. `null + 1`), or any other
`Expr.eval/2` `{:error, {:eval_error, _}}` outcome — evaluates the field to `nil`.**
This is one behaviour, not a per-cause table, stated as such precisely because
`Expr.eval/2` itself (re-verified §1 point 3) does not give a caller an easy way to
distinguish "the variable was absent" from "the variable was present but of the wrong
type for this operation" without inspecting the specific eval-error reason atom by
hand for every possible reason `Expr.eval/2` can produce (`:undefined_variable`,
`:type_mismatch`, and others REQ-197/REQ-198 added) — collapsing all of them to one
outcome (`nil`) is what keeps REQ-292 (Elixir), REQ-293 (TypeScript) and REQ-294 (Dart)
from having to reproduce `Expr`'s full internal eval-error taxonomy identically in
three languages just to agree on this one case. `nil` was chosen over "leave the
field's previous value unchanged" or "raise/reject the form" because it matches
`Expr.eval/2`'s own "an undefined variable is an eval error" discipline: the field
genuinely has no computable value yet, and `nil` is the same sentinel JSON already uses
for "no value" everywhere else in this pipeline (`form_schema` itself, `variable_schema.ex`'s
own absent-key convention per `TaskActivation.resolve_form_schema/1`'s "absent or
explicit JSON `null` stays `nil`, never `%{}`" precedent, cited directly).

This is a decision this requirement's own validator does not execute (it is an
evaluator-runtime behaviour, and REQ-291 implements no evaluator — see "Non-goals"),
but it is **pinned here in both the vocabulary document's prose and a small,
independently-testable accessor** so REQ-292/293/294 cannot each independently guess:

```
@spec computed_field_absent_or_null_input_result() :: :nil_value
```

on `Letflow.Definitions.FormSchemaExpressions` (or a small dedicated constants module
if `CODE-DESIGN-VALIDATOR`/REVIEWER prefers not to load a validation module with a
non-validation accessor — an open question left to ELIXIR-DEV's judgement, not a
semantic one). A unit test asserts this returns `:nil_value`, **and** a second test
asserts the vocabulary document's own text states it in prose (grep/`File.read!`
pattern, precedented — see §7 below) — satisfying "the document states a single value
... and is tested" without this requirement building the evaluator that would
otherwise be the more obvious place to test actual runtime behaviour.

### 4.4 Computed-field evaluation order and cycle detection (catches cycles of any length)

**Dependency graph:** nodes are the field names that carry a `x-ui.computed` key in one
`form_schema`; a directed edge `A -> B` exists when field `A`'s `computed` expression's
`ast()` contains a `{:var, [B]}` reference and `B` also carries a `x-ui.computed` key
(references to a non-computed sibling field are not edges in this graph — they are
plain scope-checked variable reads, §4.2, and never participate in cycle detection,
since a non-computed field's value does not itself depend on evaluation order).

**Evaluation order (stated for REQ-292/293/294, not executed by this requirement):**
`computed` fields evaluate first, in any topological order of this dependency graph
(the graph having been proven acyclic at definition time makes at least one such order
exist; this requirement does not mandate a specific tie-breaking order among
independent computed fields, since none of the three evaluator requirements need one —
open question noted for whichever of REQ-292/293/294 lands first to record its own
choice, non-load-bearing since independent computed fields cannot observe each other's
evaluation order by construction). `visible_when` and `cross_field_validation`
expressions evaluate **after** every `computed` field has produced its value, in any
order relative to each other and relative to nothing else — they are always leaves of
this dependency graph (nothing in the model lets another expression reference a
`visible_when` or `cross_field_validation` "result," only a field's own value).

**Cycle detection (definition time, this requirement's actual scope):** standard
depth-first-search cycle detection over the dependency graph above — a "currently on
the DFS stack" set and a "fully visited" set, matching `Graph`'s own CHK-06
gateway-cycle check's algorithm shape (design doc `req028-graph-structural-validator.md`
§6) in spirit, but implemented independently in the new module (not calling into
`Graph`'s private CHK-06 code, which operates over `Graph.Edge.t()`, a different
shape). Visiting a neighbour already on the current DFS stack — including the node
itself, for a direct self-reference — is a cycle; this uniformly catches a 1-node
self-reference, a 2-node cycle (`A -> B -> A`) and a 3-node cycle (`A -> B -> C -> A`)
with the same check, not a special-cased length-2 test, because DFS-with-a-stack-set
does not special-case cycle length at all. One `:form_schema_computed_field_cycle`
violation is emitted per node's `check_form_schema_expressions/1` call the first time a
cycle is found in that node's graph (not one per edge in the cycle), naming every field
in the discovered cycle in the message (§3).

```
@spec collect_var_paths(Expr.ast()) :: [[String.t()]]
@spec build_computed_dependency_graph(properties :: map()) :: %{optional(String.t()) => [String.t()]}
@spec find_cycle(graph :: %{optional(String.t()) => [String.t()]}) :: [String.t()] | nil
```

(`collect_var_paths/1` is the one shared AST walker feeding both §4.2's scope check and
this cycle-graph construction — written once in `FormSchemaExpressions`, not
duplicated.)

Tests: a two-field cycle (`fieldA.computed` references `fieldB`, `fieldB.computed`
references `fieldA`) and a three-field cycle (`fieldA -> fieldB -> fieldC -> fieldA`),
each asserted to produce exactly one `:form_schema_computed_field_cycle` violation
naming all fields in the cycle. A non-cyclic diamond (`fieldA` and `fieldB` both
`computed` from `fieldC`, `fieldD` computed from both `fieldA` and `fieldB`) is a
required *negative* test — proving the algorithm does not false-positive on a DAG that
merely re-converges, which a naive "any node visited twice" check (rather than a
stack-set check) would wrongly flag.

### 4.5 Submit disposition: both a hidden field's and a computed field's value ARE submitted

**Decision, already made by decision 0020 D1a and re-stated here, not re-opened:**
neither a hidden field's value nor a computed field's value is dropped client-side.
Both are retained and submitted. Quoting D1a's constraint 3 directly (§1 point 2):

> "A client-supplied value for a `computed` or hidden field is therefore an *input to
> be checked*, never a value to be stored on trust."

This sentence only makes sense if the client *does* submit the value — an input that
was never sent cannot be "checked." It is also the only reading consistent with
REQ-292's own acceptance-criteria text (not this requirement's to satisfy, only to not
contradict), which asks what happens "when the server's recomputation of a computed
field disagrees with the value the client submitted" — presupposing a submitted value
exists to disagree with.

So: **submitted, not dropped, for both** `visible_when`-hidden fields and `computed`
fields. The server (REQ-292) is what turns "submitted" into "trusted or not" — this
requirement does not implement that authority, only states the client-side disposition
precisely enough that REQ-293/294 do not each invent their own filtering step that
would silently disagree with REQ-292's stated assumption.

Pinned the same way as §4.3, via accessors on `Letflow.Definitions.FormSchemaExpressions`:

```
@spec hidden_field_submit_disposition() :: :submitted_as_untrusted_input
@spec computed_field_submit_disposition() :: :submitted_as_untrusted_input
```

Two tests (the requirement's own "each is covered by a test," read as one test per
field kind, matching the "one test per key" discipline used elsewhere in this
requirement): one asserting `hidden_field_submit_disposition/0 ==
:submitted_as_untrusted_input`, one asserting `computed_field_submit_disposition/0 ==
:submitted_as_untrusted_input`, plus the doc-text assertions of §7.

## 5. The security boundary (documentation-only criterion — no new runtime check here)

The vocabulary document (§6 below) must state, in its own words, quoting or citing
0020 D1a directly:

> Client-side hiding (`visible_when: false`) is a UX affordance only, and never access
> control. A field whose visibility is security-relevant must be **omitted from the
> schema entirely** on the server side before the schema is served to any client — the
> server never relies on `visible_when` to keep a security-relevant field away from a
> user who should not see it.

**This is prose-only in this requirement's scope**, matching REQ-284 §7's own
precedent (a "UX affordance only" statement with no enforcing code, because there is
nothing at *this* layer — a pure, no-`Repo` graph validator — that could enforce a
schema-shaping decision made at a different layer, by a different requirement
(REQ-286, "form schema exposure," is the module that actually decides what a served
schema contains). Nothing in `FormSchemaExpressions` reads or writes tenant data, has
no `Plug.Conn`, and cannot know "is this field security-relevant" — that predicate does
not exist anywhere in the codebase today and inventing one is out of this
requirement's fence. Stated as an explicit non-goal, not a silent omission.

## 6. `docs/frontend/x-ui-widget-vocabulary.md` changes (exact sections)

1. **§6 heading and body replaced.** Old heading "Field logic is deferred, not
   rejected" and its body (quoted in full in §1 point 1 above) are replaced with a new
   §6, "Field logic: `visible_when`, `computed`, and cross-field validation
   (REQ-291)," whose body:
   - States plainly that REQ-291 is the resolution of the former deferral (pointer,
     not a second deferral).
   - Reproduces §4.1's table (the three keys, their shape, their one-line semantics).
   - States §4.2's scope/prefix decision verbatim ("no `variables.` prefix; flat,
     sibling-`properties`-key scope only; a dotted path is always out of scope").
   - States §4.3's absent/null decision verbatim ("evaluates to `nil`, uniformly,
     regardless of the specific cause").
   - States §4.4's evaluation-order rule verbatim ("`computed` fields evaluate first,
     in a definition-time-proven-acyclic dependency order; `visible_when` and
     cross-field validation evaluate after, and can never participate in a cycle").
   - States §4.5's submit-disposition decision verbatim, with the D1a quote.
   - States §5's security-boundary paragraph verbatim, citing 0020 D1a by name.
   - States that all of the above is validated at definition time (not just render
     time), naming `Letflow.Definitions.FormSchemaExpressions` and the four new
     `Violation.code()` atoms so a reader hitting one of them in a `422` response can
     find this document.
2. **§8 "Scope fence"** gains one bullet: "`x-ui.visible_when`/`x-ui.computed`/
   `x-ui.cross_field_validation`'s *evaluation* (client-side interactivity or
   server-side re-evaluation) is not implemented by this document's own requirement
   (REQ-284) or by REQ-291 — REQ-291 validates the expressions exist and are
   well-formed and in-scope at definition time only; REQ-292 (server), REQ-293
   (TypeScript client) and REQ-294 (Dart client) implement evaluation."
3. No other section of the document changes. §1-§5 and §7 (widgets, registration,
   unrecognised-name fallback, no-code-execution, client-validation-is-UX-only) are
   untouched — they describe `x-ui.widget`, a different key, and REQ-291 does not
   revisit them.

## 7. Test coverage plan (mapped 1:1 to acceptance criteria)

All new tests live in `test/letflow/definitions/form_schema_expressions_test.exs`
(new file, mirroring `test/letflow/definitions/sub_process_interface_test.exs`'s
existence as its own file rather than folded into `graph_test.exs`) plus a handful of
`Graph`-level integration tests appended to `test/letflow/definitions/graph_test.exs`
proving the CHK-20 wiring (one node-attributes-level test per new violation code, at
minimum one routed through `validate_node_attributes/1` directly) and one test in
`test/letflow/definitions_test.exs` proving the `update/2` re-classification behaviour
(§2's "no changes owed but re-asserted" point) — storing a definition whose
`form_schema` has a since-invalidated-by-this-check expression is not directly
constructible pre-REQ-291 (there was no check before), so this test instead proves the
forward case: a definition update touching an unrelated node, where a *different* node
in the same graph carries a bad `x-ui` expression, is rejected — establishing the same
"no diff-against-stored-graph carve-out" behaviour REQ-288 established for edges, now
proven for form-field expressions too.

| Acceptance criterion | Test(s) |
|---|---|
| Vocabulary doc gains 3 keys + §6 replaced | Doc-content test (`File.read!("docs/frontend/x-ui-widget-vocabulary.md")`, precedented by `test/letflow/engine/service_task_wiring_test.exs:839` and others per §1's grep) asserting the old deferral heading is gone and the new content markers (key names, "REQ-291") are present. |
| Invalid expr per key — 3 tests | `visible_when`/`computed`/`cross_field_validation.expression` each independently made syntactically invalid, one test each, asserting `:form_schema_expression_invalid` naming the right field. |
| Scope/prefix stated + out-of-scope test | Doc-content assertion for the prose; one behavioural test referencing an undeclared sibling name, asserting `:form_schema_expression_out_of_scope`. |
| Absent/null single behaviour, stated + tested | Doc-content assertion; `computed_field_absent_or_null_input_result/0 == :nil_value` unit test. |
| 2-node and 3-node cycle rejected | Two behavioural tests (§4.4) plus the diamond-DAG negative test. |
| Hidden/computed submit disposition, stated + tested | Doc-content assertion; two unit tests on the two accessor functions (§4.5). |
| Security boundary stated, citing 0020 D1a | Doc-content assertion for the exact quoted sentence (or a close paraphrase citing "0020" and "D1a" literally, so the citation itself is checkable by substring). |
| Out-of-scope-variable rejection (D1a's checkable half) | Same test as the scope-check row above — one test satisfies both wordings of this criterion in the requirement text, which describe the same check from two angles. |
| `expr.ex` unmodified | `git diff` on `lib/letflow/engine/expr.ex` at implementation time — a repo-level fact, not a unit test; the test suite includes no test that imports or invokes anything not already public on `Expr` today (`translate_cel_to_expr/1`, `parse_strict/1`, the public `ast()` type). |
| No `web/` changes | `git diff --stat -- web/` at implementation time — likewise a repo-level fact. |
| `mix letflow.check` passes | Run at implementation time; quoted verbatim in the implementation report, not asserted here. |

## 8. Non-goals (scope fence, restated precisely)

- **No evaluator.** `FormSchemaExpressions` never calls `Expr.eval/2`. It calls
  `translate_cel_to_expr/1` and `parse_strict/1` only — the same two functions REQ-288
  already established as the definition-time-only pair, explicitly distinct from
  `evaluate_condition/2`'s runtime call graph (§1 point 3). Nothing here computes what
  a `computed` field's value *would be*, only whether its expression is well-formed
  and in-scope.
- **No `lib/letflow/engine/expr.ex` change.** Confirmed by `git diff` at
  implementation time. No new public function, no new `ast()` variant, no widened
  `@unsupported_call_markers`.
- **No `web/` change.** The vocabulary document (`docs/frontend/`) is documentation
  Letflow's backend repo owns, not `web/` source — updating it is not a "frontend
  code" change per `CLAUDE.md`'s FRONTEND-DEV ownership boundary, and this requirement
  is owned by `ELIXIR-DEV`.
- **No move of `JsonSchemaShape.check/1`'s call site.** Stays at activation
  (`TaskActivation.resolve_form_schema/1`); flagged in §2 as a real, separate future
  improvement, not done here.
- **No decision about how a client renders `computed`-field non-editability**, how a
  hidden field's DOM/widget disappears, or any other rendering behaviour — those are
  REQ-293 (TypeScript)/REQ-294 (Dart) concerns operating on a schema this requirement
  only makes safe to author, never render.

## 9. Open questions (explicit, not silently resolved)

1. **Where do `computed_field_absent_or_null_input_result/0`,
   `hidden_field_submit_disposition/0` and `computed_field_submit_disposition/0`
   live** — on `FormSchemaExpressions` itself (co-located with the validator that
   shares the same requirement) or a separate, purely-declarative
   `Letflow.Definitions.FormFieldLogicSemantics` module with no validation logic at
   all? Both satisfy every acceptance criterion in §7; this is a naming/organisation
   choice for ELIXIR-DEV, not a semantic one, and is called out rather than picked
   silently per this project's design-doc convention for genuinely equivalent options.
2. **Tie-breaking evaluation order among independent `computed` fields** (§4.4) is
   explicitly left unspecified, since nothing in REQ-291/292/293/294's stated
   acceptance criteria depends on it — flagged so a future requirement does not
   discover a real ordering dependency and have to retrofit a rule where none exists
   today.
3. **Moving `JsonSchemaShape.check/1` to definition time** (§2) is flagged as a
   worthwhile follow-on, not performed here.
