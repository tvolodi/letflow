# REQ-292 — Server-side re-evaluation of `visible_when`, `computed` and cross-field
validation on task completion (0020 D1a step 11, the authority half)

Design only. No implementation code. Bare signatures, `@type`/`@spec` shapes, and
verbatim citations of *existing* real code are given where needed; no full function
body appears anywhere below.

## 1. Re-verification (2026-09-11, this session)

Every factual claim the requirement text made was re-derived from source, per its own
"re-verify at start" instruction, not trusted.

1. **`complete_task/3`'s current signature and line**, `lib/letflow/engine.ex:1814-1838`
   (`@spec complete_task(task_id :: Ecto.UUID.t(), attrs :: complete_attrs(), opts ::
   complete_opts()) :: {:ok, complete_result()} | complete_error()`), confirmed
   unchanged from the requirement's description. It delegates to `run_complete_task/6`
   (`lib/letflow/engine.ex:1870`), which builds one `Ecto.Multi` (`:task`,
   `:instance_projection`, `:snapshot_and_state`, `:merge`, `:transition`, then
   `build_complete_task_tail_multi/5` via `Multi.merge/2`) and commits it in one
   `Repo.transaction/1` (`lib/letflow/engine.ex:1878-1930`). This is the transactional
   path this design hooks into — no new transaction, no router change.

2. **The "existing `variable_schema_violation` error path" the requirement's own text
   names does not exist on `complete_task/3` under that literal name** — it is on
   `create/2`'s `create_error()` union (`lib/letflow/engine.ex:398-399`,
   `{:error, {:variable_schema_violation, [...]}}`), a different function. The pattern
   `complete_task/3` actually already has, and the one this design mirrors, is
   `merge_output_variables/7` (`lib/letflow/engine.ex:2864-2905`) calling
   `Letflow.Engine.VariableSchema.variable_validations/5`
   (`lib/letflow/engine/variable_schema.ex:279-287`,
   `@spec variable_validations(repo :: module(), definition_id :: Ecto.UUID.t() | nil,
   current_variables :: map(), incoming_variables :: map(), opts :: [prefix: String.t()
   | nil]) :: {:ok, Letflow.Engine.VariableMerge.variable_validations()} | {:error,
   error_reason()}`), whose rejection surfaces through `apply_variable_merge/6`
   (`lib/letflow/engine.ex:2918-2945`) as **`{:ok, {:execution_error, error_args}}`**
   with `error_args.error_type == :variable_schema_rejected` — not a bare `{:error,
   _}` tuple. `build_complete_task_tail_multi/6`'s first clause
   (`lib/letflow/engine.ex:3248-3261`) routes any `{:execution_error, error_args}` from
   the `:transition` step through `Letflow.Engine.ExecutionError.append_multi/3`: the
   instance flips to `:error`, the task **stays `:pending`** (not completed), and no
   downstream transition/task-activation/event runs. This is the real "existing
   validation authority" mechanism this requirement's own text asked to mirror, and
   §3 below reuses it verbatim for the two new failure classes rather than inventing a
   parallel one.

3. **`Expr.evaluate_condition/2`'s `@spec`**, `lib/letflow/engine/expr.ex:1479`:
   `@spec evaluate_condition(cel_condition :: String.t(), variables :: map()) ::
   boolean()` — confirmed it collapses every failure branch (translate error, parse
   error, eval error, and a non-boolean `eval/2` result) to a bare `false`
   (`lib/letflow/engine/expr.ex:1480-1488`, its `else` clause is a single `_ -> false`).
   **Not used anywhere in this design.** The diagnosable path used instead:
   `Expr.translate_cel_to_expr/1` (`lib/letflow/engine/expr.ex:211-215`, `@spec
   translate_cel_to_expr(cel_condition :: String.t()) :: {:ok, expr_source ::
   String.t()} | {:error, :unsupported_cel_feature} | {:error, :translate_error}`),
   `Expr.parse_strict/1` (`:550`, `@spec parse_strict(expr_source :: String.t()) ::
   {:ok, ast()} | {:error, parse_failure()}`), and `Expr.eval/2` (`:1121-1122`, `@spec
   eval(ast(), variables :: map()) :: {:ok, value()} | {:error, {:eval_error, reason ::
   term()}}`). Confirmed `lib/letflow/engine/expr.ex` is not modified anywhere in this
   design — only these three already-public functions are called, exactly as
   `Letflow.Definitions.FormSchemaExpressions` (REQ-291, REQ-288's own precedent) also
   does at definition time.

4. **REQ-291's landed vocabulary**, `lib/letflow/definitions/form_schema_expressions.ex`
   (merged, `status: done` in `docs/requirements.yaml`) and its design doc
   `lib/letflow/design/req291-x-ui-logic-keys.md`, read in full. Confirmed available and
   load-bearing for this design:
   - **Shape**: `x-ui.visible_when` (`String.t()` expr), `x-ui.computed` (`String.t()`
     expr), `x-ui.cross_field_validation` (`%{"expression" => String.t(), "message" =>
     String.t()}`), nested under `form_schema.properties.<field>.x-ui`.
   - **No `"variables."` prefix; flat, sibling-`properties`-key scope only** (§4.2) — a
     field expression may reference only single-segment bare identifiers that are
     top-level keys of the same `form_schema`'s `"properties"` map. This design's
     evaluation context (§4 below) is built to match that scope exactly.
   - **Absent/null input to a `computed` field's expression evaluates to `nil`,
     uniformly** (§4.3), pinned via the already-public accessor
     `FormSchemaExpressions.computed_field_absent_or_null_input_result/0 ::
     :nil_value`. This design's `computed` re-evaluation (§4.2 below) calls that
     accessor rather than re-deciding the value, per "REQ-292/293/294 do not each
     independently guess."
   - **Both a hidden field's and a computed field's value ARE submitted, not dropped
     client-side** (§4.5), pinned via `FormSchemaExpressions.hidden_field_submit_disposition/0`
     and `.computed_field_submit_disposition/0`, both `:submitted_as_untrusted_input`.
     This is exactly the input shape §3/§4 below check.
   - **Computed-field dependency graph and cycle detection are already public
     functions** on `FormSchemaExpressions`: `build_computed_dependency_graph/1 ::
     properties :: map() -> %{optional(String.t()) => [String.t()]}` and `find_cycle/1
     :: graph -> [String.t()] | nil` (`lib/letflow/definitions/form_schema_expressions.ex:322-397`),
     both re-used directly by this design (§4.1) rather than re-implemented — the
     definition-time module built exactly the graph shape a submit-time evaluator
     needs, and REQ-291 exposed both as public `def`s (not `defp`), so this is a real
     reuse, not a coincidence to route around. `collect_var_paths/1`
     (`:270-288`, also public) is not called directly by this design (no new AST
     walking need arises), listed here only to confirm it exists and is not
     duplicated.
   - **No topological-sort function is exposed** — REQ-291 explicitly left "tie-breaking
     evaluation order among independent `computed` fields" open (§4.4 "open question 2"
     of that design), stating only that `computed` fields evaluate before
     `visible_when`/`cross_field_validation`, in *some* topological order of the
     (proven-acyclic) dependency graph. §4.1 below adds the one new piece of graph logic
     this requirement needs: a topological order, built once, locally, over
     `FormSchemaExpressions.build_computed_dependency_graph/1`'s output.

5. **REQ-126 (`lib/letflow/design/req126-form-version-pinning.md`) and how `form_schema`
   pinning actually reaches a task row**, re-derived from
   `lib/letflow/engine/task_activation.ex:155-216` rather than assumed:
   `TaskActivation.insert_attrs/4` calls `resolve_form_schema/1`
   (`:155-170`), which reads `node.attributes["form_schema"]` off the `Graph.Node.t()`
   the caller already resolved from the **instance's pinned graph** (the snapshot fixed
   at instance creation — REQ-126's own `form_id`/`form_version` pinning target), and
   writes the result once into the newly-inserted `Letflow.Engine.Task` row's
   `form_schema` column (`lib/letflow/engine/task.ex:70`). **`tasks.form_schema` is
   therefore already the pinned-version schema by construction, immutable from the
   moment the task row is inserted** — no separate `form_version` lookup is needed at
   completion time; the already-locked `task` row this Multi's own `:task` step
   fetches (`fetch_and_lock_task/3`) carries it directly as `task.form_schema`. This is
   the mechanism §5's pinning acceptance criterion relies on, and it needs no new code:
   reading `changes.task.form_schema` inside the new Multi step (§2) is sufficient by
   itself, because a later `mix letflow.check`-passing definition update can never
   retroactively change what an already-inserted task row's `form_schema` column holds.

6. **`VariableSchema` / `variable_schemas` validation authority is not touched.**
   Confirmed `variable_validations/5`'s call site (`merge_output_variables/7`,
   `lib/letflow/engine.ex:2877-2905`) is unchanged by this design — §2 below only
   changes **what `output_variables` map is handed to it**, never how it validates.
   Grepping this design's own new module (§4) for any reference to `form_schema`'s
   `"type"`/`"required"`/`"minimum"`/etc. JSON-Schema *validation* keywords returns
   none — this design reads only `x-ui.visible_when`/`x-ui.computed`/
   `x-ui.cross_field_validation`, three keys `JsonSchemaShape`/`variable_schemas`
   never touch either.

7. **`ExecutionError.error_type()` is an open union**
   (`lib/letflow/engine/execution_error.ex:96-102`, `@type error_type ::
   :variable_schema_rejected | :no_matching_gateway_edge | ... | atom()`) — confirmed a
   new calling path may add its own atom without widening that type or touching any
   existing exhaustive `case`, matching this design's plan (§3) to add two new atoms.

## 2. Where this hooks into `run_complete_task/6` — one new `Multi.run/3` step, one
   modified step, zero changes to `:transition`/`build_complete_task_tail_multi`/
   `complete_task_row`/`append_task_completed_event`'s call graph

**New step, inserted between `:snapshot_and_state` and `:merge`:** a
`Multi.run(:form_expression_reevaluation, fn _repo, changes -> ... end)` step whose
entire body is one call: `FormExpressionReevaluation.reevaluate(task.form_schema,
seed_state.variables, output_variables)`, where `task` comes from `changes.task` (the
Multi's own already-locked `:task` step) and `seed_state` from
`changes.snapshot_and_state.seed_instance_state`. `output_variables` is the same
closure variable `run_complete_task/6` already carries (the caller's literal
submission, unchanged, still used unmodified by `complete_task_row/6` later for
`tasks.output_variables` — see §6's "what does not change" for why that column keeps
recording the raw submission rather than the server-corrected one). This step never
fails structurally (it always returns `{:ok, _}`, per `Ecto.Multi.run/3`'s own
contract) — its *domain* result, which can be a rejection, is carried inside the
`{:ok, _}` payload, the same discipline `merge_output_variables/7` and
`dispatch_task_completion_hop_chain/7` already use for `{:execution_error, _}` (§1
point 2).

**`:merge` step, modified** (`lib/letflow/engine.ex:1886-1900`) — the *only* change to
this existing step's body: it now also reads `changes.form_expression_reevaluation`
(the new step's result). On `{:error, reevaluation_error}`, the step short-circuits to
`{:ok, {:execution_error, error_args}}` without ever calling `merge_output_variables/7`
at all — `error_args` built by a new private helper,
`build_reevaluation_execution_error_args/5` (§7), from `reevaluation_error`,
`projection`, `actor_id`, `idempotency_key`, and `seed_state.variables` (unchanged,
since nothing merges). On `{:ok, %{output_variables: corrected_output_variables,
events: form_events}}`, the step calls `merge_output_variables/7` exactly as it does
today, with **one argument swapped**: `corrected_output_variables` in place of the raw
`output_variables` closure variable, then pipes the result through a new private helper
`prepend_form_expression_events/2`.

`merge_output_variables/7` itself is **not modified** (§1 point 6) — it is only ever
called with a possibly-different `output_variables` argument value than before.
`prepend_form_expression_events/2`
(`@spec prepend_form_expression_events({:ok, {:merged, map()} | {:execution_error,
map()}} | {:error, term()}, [FormExpressionReevaluation.reevaluation_event()]) ::
{:ok, {:merged, map()} | {:execution_error, map()}} | {:error, term()}`) is, on the
`{:merged, %{merge_events: merge_events} = m}` branch only, the identity function
except that it returns `{:ok, {:merged, %{m | merge_events: form_events ++
merge_events}}}` — i.e. the two new `reevaluation_event()` kinds ride inside the
**same** `merge_events` list `VariableMerge.merge/3` already produces
`:variable_overwritten` events into. On every other branch (an `{:execution_error, _}`
from a `variable_schema_rejected` rejection of the *corrected* submission, or the
pre-existing, effectively unreachable `{:error, :variable_schema_lookup_failed}` case,
§1 point 2's "GH#310/ISS-0091" note) it is the identity function and `form_events` are
dropped — the submission is already being rejected on other grounds, so there is
nothing left to log a disagreement against; flagged as a deliberate, non-load-bearing
simplification, not silently done (§9 open question 1).

**Because `:merge`'s external output shape is completely unchanged**
(`{:ok, {:merged, %{new_variables: _, merge_events: _}}} | {:ok, {:execution_error,
_}} | {:error, _}`, exactly as before this design), **`:transition`'s own `Multi.run/3`
body, `dispatch_task_completion_hop_chain/7`, `build_complete_task_tail_multi/6`, and
`complete_task_row/6` need zero code changes.** The only other touch point is
`encode_merge_events/1` (§3).

## 3. New module: `Letflow.Engine.FormExpressionReevaluation`

Pure, no-`Repo`/`Logger`/clock function — same purity discipline as
`Letflow.Definitions.FormSchemaExpressions` (§1 point 4), its submit-time counterpart.
File: `lib/letflow/engine/form_expression_reevaluation.ex`.

```
@typedoc "A field name — a top-level key of form_schema's \"properties\" map."
@type field_name :: String.t()

@typedoc """
Informational outcome of re-evaluation, embedded into the same TASK_COMPLETED
event payload merge_events already ride in (never persisted as its own DB row —
INV-EE48-5, lib/letflow/engine.ex:3819-3821). Not an error: completion proceeds.
"""
@type reevaluation_event ::
        {:computed_field_disagreement, field_name(), submitted_value :: term(),
         server_value :: term()}
      | {:visible_when_false_value_discarded, field_name(), discarded_value :: term()}

@typedoc """
A genuine failure of re-evaluation: either a real cross-field-validation business
rejection, or an expression that could not be EVALUATED at all (distinct from
evaluating to `false` — see moduledoc "Failure vs. false").
"""
@type reevaluation_error_type ::
        :form_cross_field_validation_failed | :form_expression_evaluation_failed

@type reevaluation_error :: %{
        error_type: reevaluation_error_type(),
        field: field_name(),
        reason: String.t(),
        details: map()
      }

@doc """
Re-evaluates every visible_when, computed and cross-field-validation expression on
`form_schema` (the task's PINNED schema — task.form_schema, REQ-126) against
`current_variables` (the instance's authoritative variables before this call) merged
with `output_variables` (this call's literal, untrusted submission). Returns a
corrected `output_variables` map (computed fields forcibly overwritten with the
server's own recomputation; a submitted value for a visible_when: false field
dropped) plus a list of informational reevaluation_event()s -- or a
reevaluation_error() naming the first (sorted field-name order) rejection found.

form_schema == nil, or a form_schema with no "properties" map, is a no-op:
{:ok, %{output_variables: output_variables, events: []}} -- unchanged from today's
behaviour for tasks with no form-field logic.
"""
@spec reevaluate(
        form_schema :: map() | nil,
        current_variables :: map(),
        output_variables :: map()
      ) ::
        {:ok, %{output_variables: map(), events: [reevaluation_event()]}}
        | {:error, reevaluation_error()}
def reevaluate(form_schema, current_variables, output_variables)

## Private helpers (signatures only -- ELIXIR-DEV writes bodies)

# Working evaluation context: Map.merge(current_variables, output_variables) --
# same "current, overridden by incoming" shape VariableMerge.merge/3 itself uses,
# built once, then threaded through the three passes below, each pass updating it
# with server-recomputed computed-field values before the next pass reads it.
@spec build_working_variables(current_variables :: map(), output_variables :: map()) :: map()
defp build_working_variables(current_variables, output_variables)

# One topological order of build_computed_dependency_graph/1's output (already
# proven acyclic at definition time, REQ-291 -- re-checked defensively here via
# FormSchemaExpressions.find_cycle/1 before sorting; a cycle found at this point
# is impossible for a schema that actually passed definition-time validation, and
# is treated as :form_expression_evaluation_failed, never as a silent no-op or an
# infinite loop, on the belt-and-suspenders principle -- see moduledoc).
@spec topological_order(graph :: %{optional(field_name()) => [field_name()]}) ::
        {:ok, [field_name()]} | {:error, :cycle_detected}
defp topological_order(graph)

# Pass 1 (REQ-291 §4.4 order: computed fields evaluate first). For each computed
# field in topological order: parses+evaluates x-ui.computed against `working`
# (already reflecting any earlier computed field's own recomputation in this same
# pass); a parse/translate failure here is :form_expression_evaluation_failed
# (defensive -- REQ-291's definition-time gate should make this unreachable for a
# pinned schema); an Expr.eval/2 {:error, {:eval_error, _}} is NOT a failure for
# this key specifically -- REQ-291 §4.3 pins it to `nil`
# (FormSchemaExpressions.computed_field_absent_or_null_input_result/0). Always
# overwrites `working[field]` to the server-derived value, whether or not the
# client submitted one, and whether or not it agrees with what was submitted.
# Emits {:computed_field_disagreement, field, submitted, server_value} into the
# accumulated event list only when output_variables had this key AND its value
# differs from the recomputed one -- no event for an absent submission or an
# agreeing one.
@spec eval_computed_fields(
        properties :: map(),
        topo_order :: [field_name()],
        working :: map(),
        output_variables :: map()
      ) ::
        {:ok, working :: map(), [reevaluation_event()]}
        | {:error, reevaluation_error()}
defp eval_computed_fields(properties, topo_order, working, output_variables)

# Pass 2 (after every computed field has produced its value, REQ-291 §4.4). For
# each field carrying x-ui.visible_when: {:ok, true} or the key absent -> no
# action. {:ok, false} -> field name added to the drop-set (§ "drop", below);
# additionally, if output_variables had this key, emits
# {:visible_when_false_value_discarded, field, discarded_value}. An
# Expr.eval/2 {:error, {:eval_error, _}} (or a translate/parse failure) is a real
# FAILURE, distinguishable from {:ok, false} by construction (they are different
# clauses of the same case), and aborts with
# :form_expression_evaluation_failed -- a failing visible_when must never read as
# "hide the field" (moduledoc "Failure vs. false", the requirement's own AC4).
@spec eval_visible_when_fields(
        properties :: map(),
        working :: map(),
        output_variables :: map()
      ) ::
        {:ok, drop_fields :: MapSet.t(field_name()), [reevaluation_event()]}
        | {:error, reevaluation_error()}
defp eval_visible_when_fields(properties, working, output_variables)

# Pass 3. For each field carrying x-ui.cross_field_validation, in sorted
# field-name order (determinism, matching VariableMerge's own Enum.sort/1
# discipline): {:ok, true} -> no action. {:ok, false} -> aborts with
# :form_cross_field_validation_failed, reason == the field's own declared
# "message". An Expr.eval/2 eval-error (or translate/parse failure) -> aborts
# with :form_expression_evaluation_failed, same "never silently false" rule as
# Pass 2. The first (sorted order) rejection found wins and short-circuits --
# the remaining fields' cross_field_validation is not evaluated once one fails.
@spec eval_cross_field_validations(properties :: map(), working :: map()) ::
        :ok | {:error, reevaluation_error()}
defp eval_cross_field_validations(properties, working)

# Applies Pass 2's drop_fields to output_variables: Map.drop(output_variables,
# MapSet.to_list(drop_fields)), plus overwrites every computed field's key
# (regardless of drop -- see "computed AND hidden" in §4) with its Pass-1
# recomputed value from `working`, UNLESS that same field is also in
# drop_fields (visible_when governs last -- a hidden field's value, computed or
# not, is dropped, §4).
@spec build_corrected_output_variables(
        properties :: map(),
        output_variables :: map(),
        working :: map(),
        drop_fields :: MapSet.t(field_name())
      ) :: map()
defp build_corrected_output_variables(properties, output_variables, working, drop_fields)
```

`reevaluate/3`'s body composes these five helpers as: build `properties` (`Map.get(form_schema,
"properties", %{})`, `%{}` on a non-map `form_schema`/`nil`) → `build_working_variables/2`
→ (if no field in `properties` carries any of the three `x-ui` logic keys: short-circuit
`{:ok, %{output_variables: output_variables, events: []}}`, no graph/topo work at all) →
`build_computed_dependency_graph/1` (reused, `FormSchemaExpressions`) → `topological_order/1`
→ `eval_computed_fields/4` → `eval_visible_when_fields/3` → `eval_cross_field_validations/2`
→ `build_corrected_output_variables/4`, folding events from the computed and visible_when
passes into one list, sorted by field name for determinism before being returned (matching
`VariableMerge`'s own `Enum.sort/1` discipline, §1 point 2).

### Moduledoc content this design mandates (not left to ELIXIR-DEV's discretion — the
requirement's own acceptance criteria require these stated in the moduledoc, not merely
implied by code):

1. **"Failure vs. false."** States explicitly, in these words or equivalent: *"An
   `Expr.eval/2` failure (`{:error, {:eval_error, _}}`) on a `visible_when` or
   `cross_field_validation` expression is never treated as `false`. It aborts task
   completion with `:form_expression_evaluation_failed`, distinguishable from a
   legitimate `{:ok, false}` result by construction — the two are different clauses of
   the same `case`, never collapsed the way `Expr.evaluate_condition/2` collapses every
   failure to `false`. A `computed` field's evaluation failure is the one documented
   exception: REQ-291 §4.3 already pins that specific case to `nil`, not to a
   completion-aborting error."**
2. **The computed-field disagreement disposition** (§5.1 below), quoting 0020 D1a's own
   text verbatim.
3. **The visible_when-false disposition** (§5.2 below).
4. **The `variable_schemas`/`form_schema` boundary** (§1 point 6's statement, restated
   in the module's own words): this module evaluates *expressions*; it never validates a
   submitted value's type or constraints against `form_schema`'s own JSON-Schema
   keywords, which remains `variable_schemas`' sole authority.

## 4. Precedence when a field is both `computed` and hidden by its own or another
   field's `visible_when`

Not addressed by REQ-291 (out of its scope — it validates shape/scope, not runtime
interaction). Decided here, since REQ-292's own acceptance criteria require every
interaction to resolve to one concrete behaviour, not an unstated case:

**Compute first, then apply visibility.** Pass 1 (§3) always recomputes a `computed`
field's server value into `working`, unconditionally. Pass 2 then independently decides
whether that field's *contribution to this call's persisted variables* is dropped, based
on its own `visible_when` (or another field's, if a `visible_when` expression happens to
reference it — nothing prevents that syntactically). If dropped, the field's
just-recomputed value is **not** written into `corrected_output_variables` for this
call — `build_corrected_output_variables/4` (§3) drops it exactly like a plain hidden
field's submission, per the last bullet's own precedence rule. Whatever this variable
already held in `current_variables` (from a prior call) is therefore left completely
untouched — "drop" means "this call contributes nothing for this key," never "erase
prior state." A computed field that is dropped this call still gets its `working`-map
entry used as an input to any *other* field's expression evaluated in the same pass
(Pass 1's own inter-computed dependency graph, §1 point 4) — dropping only changes what
gets **persisted**, never what gets **evaluated**, matching D1a's "evaluate on the
client [here: server]; validate/authorize separately" framing applied one layer down.

## 5. The three DECIDE-AND-DOCUMENT dispositions (the requirement's own open questions,
   closed here, not left to the reader)

### 5.1 Computed-field disagreement: **not an error, not a silent overwrite — the
   server's value wins and the disagreement is logged**

**Already decided by decision 0020 D1a itself** (`docs/migration/decisions/0020-frontend-architecture.md`,
"Constraints on the shared grammar," point 3), quoted verbatim: *"When the server's
re-evaluation disagrees with the value a client submitted, **the server's value is used
and the disagreement is recorded** — it is not an error returned to the user, and not a
silent overwrite... Not an error, because the commonest cause is benign: a stale cached
schema, or a variable that changed after the form was rendered, and failing the
submission would punish a user for a race they cannot see. Not silent, because a
*persistent* disagreement is the signature of ... drift ... and it must be visible
somewhere an operator can find it."* This design does not re-open that question — it
implements it: §3's `{:computed_field_disagreement, field, submitted_value,
server_value}` event, riding inside the `TASK_COMPLETED` event's
`merged_variable_events` payload key (§6), is exactly "visible somewhere an operator can
find it" — queryable via the existing event store, with zero new DB table or index.
Task completion **proceeds normally**; this is never routed through
`ExecutionError.append_multi/3`.

### 5.2 A submitted field whose `visible_when` evaluates `false` server-side: **the
   submitted value is dropped from what gets persisted, and the drop is logged — not
   an error**

Not pre-decided by 0020 D1a in these exact words (D1a decides the `computed` case
explicitly; the `visible_when` case is this requirement's own open question to close,
per its text). Decided here, by direct analogy to §5.1, for the same reasoning D1a
already gave for the sibling case, restated for this one:

- **Not an error.** The commonest cause is identical to §5.1's: a stale client-cached
  schema, or a field whose `visible_when` inputs changed server-side after the form was
  rendered (e.g. a concurrent process-variable update from another completed task).
  Rejecting the whole submission over a benign race would punish a user for something
  they could not see, exactly D1a's own argument. It is also the reading consistent with
  D1a's "a hidden field is not a secret" — the value being dropped is not evidence of an
  attack, it is evidence of a stale or generous client.
- **Not silent overwrite, because there is nothing to overwrite** — unlike a `computed`
  field, a plain hidden field has no server-computed replacement value. "Drop" here means
  the submitted value for that key is excluded from `corrected_output_variables`
  entirely (§3, §4) — this call contributes nothing for that key to the instance's
  variables, leaving whatever `current_variables` already held (possibly nothing)
  untouched.
- **Not silent, full stop** — logged via `{:visible_when_false_value_discarded, field,
  discarded_value}` (§3), same delivery mechanism as §5.1's event, for the same
  operator-visibility reason.

This is the disposition an implementer must not re-derive independently — it is pinned
here and restated in the new module's own moduledoc (§3) precisely because "the rule is
stated in the moduledoc rather than only implied by the code" is this exact
acceptance criterion's own wording.

### 5.3 A server-side expression evaluation that FAILS (distinct from evaluating to
   `false`): **not a silent `false` — an execution error, routed through the exact
   same authority mechanism `variable_schema_rejected` already uses**

The requirement's own text names this "the one most likely to be got wrong," citing
`Expr.evaluate_condition/2`'s `@spec` collapsing every failure to `false` (§1 point 3).
This design never calls `evaluate_condition/2` (confirmed §1 point 3) — every
`visible_when`/`cross_field_validation` evaluation goes through the three-function
diagnosable path (`translate_cel_to_expr/1` → `parse_strict/1` → `eval/2`), and Pass 2/
Pass 3 (§3) each have a **distinct `case` clause** for `{:error, {:eval_error, _}}` (and
for a translate/parse failure, defensively — should be unreachable against a pinned,
definition-time-validated schema, but not assumed) versus `{:ok, false}` — the two
outcomes can never be conflated because they are never routed through the same branch.

**Disposition:** routed through `ExecutionError.append_multi/3` — the **same**
authority mechanism `variable_schema_rejected` already uses (§1 point 2), with a new
`error_type` atom `:form_expression_evaluation_failed`. This is a genuine
`{:ok, {:execution_error, error_args}}` outcome from the `:merge` step (§2): the
instance flips to `:error`, the task stays `:pending`, and the specific failing field
and expression are named in `error_args.reason`/`error_args.details` for operator
diagnosis — the same shape a real bug (as opposed to a benign business rejection) gets
under this codebase's existing convention. This is deliberately **not** the same
disposition as §5.1/§5.2 (a logged event, completion proceeds): an evaluation failure
means the pinned schema itself could not be evaluated against the actual variables it
was handed — an operationally different, more serious condition than "the client
disagreed with a value" or "the client submitted a field it should not have," and one
that must stop the transaction rather than complete silently, matching the requirement's
own framing that a failing check "must not silently read as 'hide the field'."

**`:form_cross_field_validation_failed`** (also new, §3 Pass 3) is a distinct third
atom for the case where an expression evaluates cleanly to `{:ok, false}` — a genuine
business-rule rejection, not an evaluation failure. It is routed through the same
`ExecutionError.append_multi/3` mechanism (mirroring `variable_schema_rejected`'s own
"a real rejection blocks completion" precedent) but is conceptually distinct from
`:form_expression_evaluation_failed` in `error_args.reason`/`details`, so an operator
reading an `EXECUTION_ERROR` event can tell "the form's own business rule rejected this
submission" apart from "the expression itself could not be evaluated" at a glance.

## 6. Event payload wiring — `encode_merge_events/1` extended, two new clauses

`lib/letflow/engine.ex:3849-3857`'s `encode_merge_events/1` (called from
`append_task_completed_event/5`, `:3822-3833`, building the `TASK_COMPLETED` event's
`merged_variable_events` payload key) gains two new clauses, additive only — its
existing `{:variable_overwritten, key, old_value, new_value}` clause is untouched. Each
new clause matches one `reevaluation_event()` tuple shape (§3) and maps it to a plain
JSON-encodable map with an `"event"` discriminator key, exactly mirroring the existing
clause's own shape (`%{event: "variable_overwritten", key: key, old_value: ...,
new_value: ...}`):

| Tuple matched | Map produced |
|---|---|
| `{:computed_field_disagreement, field, submitted_value, server_value}` | `%{event: "computed_field_disagreement", field: field, submitted_value: submitted_value, server_value: server_value}` |
| `{:visible_when_false_value_discarded, field, discarded_value}` | `%{event: "visible_when_false_value_discarded", field: field, discarded_value: discarded_value}` |

No algorithm, no branching — ELIXIR-DEV writes these two clauses by direct structural
analogy to the existing one.

`payload["merged_variable_events"]` in the `TASK_COMPLETED` event therefore becomes the
one place both event kinds are durably, queryably recorded — no new table, no new
migration, no new event type string. This satisfies "visible somewhere an operator can
find it" (§5.1/§5.2) without adding any new persistence surface for
SECURITY-REVIEWER/REVIEWER to separately reason about.

## 7. `ExecutionError.error_type()` — two new atoms (additive; the type stays open,
   §1 point 7)

```
| :form_cross_field_validation_failed
| :form_expression_evaluation_failed
```

Not required by `error_type()`'s own `| atom()` tail to compile, but added to the
`@type` declaration's explicit list anyway (matching the existing five named atoms'
own documentation-value precedent, `lib/letflow/engine/execution_error.ex:96-102`) so a
future reader of that module sees this requirement's two new failure classes listed
alongside the others, not only discoverable by grepping call sites.

`error_args` for both (built by `build_reevaluation_execution_error_args/5`, §2, a new
private `lib/letflow/engine.ex` helper mirroring `apply_variable_merge/6`'s own
`error_args` construction at `lib/letflow/engine.ex:2932-2941`):

```
%{
  instance_id: projection.instance_id,
  error_type: reevaluation_error.error_type,        # atom, §3/§5.3
  affected: {:field, reevaluation_error.field},
  reason: reevaluation_error.reason,                # e.g. the cross_field_validation
                                                      # "message", or a diagnostic string
                                                      # naming the expression/field for
                                                      # the evaluation-failure case
  variables: current_variables,                      # seed_state.variables, unchanged --
                                                      # nothing was merged
  details: reevaluation_error.details,
  actor_id: actor_id,
  idempotency_key: idempotency_key
}
```

## 8. INV-2 traceability (for SECURITY-REVIEWER)

The property SECURITY-REVIEWER must independently assess (per this requirement's own
acceptance criteria): **can any client-supplied value reach a persisted variable without
server-side re-derivation?**

- **`computed` fields**: never. Pass 1 (§3) unconditionally overwrites `working[field]`
  with the server's own `Expr.eval/2` result before `build_corrected_output_variables/4`
  ever runs — the client's submitted value for a `computed` key is read only for the
  disagreement comparison (§5.1), never written through to `corrected_output_variables`.
- **`visible_when`-hidden fields**: never persisted this call, regardless of source
  (§5.2, §4) — dropped from `corrected_output_variables` entirely.
- **Every other field** (no `computed`, visibly `true` or no `visible_when`): passes
  through unchanged — this design adds no new authority over those, deliberately (§1
  point 6): they remain exactly as governed by `variable_schemas`
  (`variable_validations/5`, unmodified) as they are today. This design's own authority
  is scoped to the three `x-ui` logic keys only, never to value-shape validation.
- **`cross_field_validation`**: never merges a value; it only accepts or rejects the
  whole submission (§5.3) — no new write path exists for it to smuggle a value through.

So: the only two mechanisms by which a client-supplied value could reach a persisted
variable "without server-side re-derivation" — a `computed` field's raw submission, or a
hidden field's raw submission — are exactly the two this design forces through
server-side re-derivation (recompute, or drop) before `merge_output_variables/7` (the
existing, unmodified variable_schema authority) ever sees them. Nothing added by this
design *widens* what reaches a persisted variable; every change narrows it.

## 9. Open questions (explicit, not silently resolved)

1. **`form_events` dropped when `merge_output_variables/7` itself rejects the corrected
   submission** (§2's `prepend_form_expression_events/2` note) — a computed-field
   disagreement or a visible_when-drop that happened to occur in the same call as an
   unrelated `variable_schema_rejected` failure is not separately logged. Flagged as a
   deliberate simplification (the completion is already being rejected and reported via
   a different, already-visible `EXECUTION_ERROR` event), not a silent omission — a
   future requirement could thread `form_events` into that rejection's own `details` if
   this is judged worth doing later.
2. **Whether `:form_cross_field_validation_failed` and
   `:form_expression_evaluation_failed` should be split into affected-field-level detail
   beyond `error_args.details`** (e.g. a structured `%{expression: ..., field: ...}` vs.
   a single formatted string) is left to ELIXIR-DEV's implementation judgement — both
   satisfy every acceptance criterion in §10 below; this is not a semantic decision.
3. **REQ-291's own open question 2** (tie-breaking evaluation order among independent
   `computed` fields with no dependency between them) is inherited, not re-opened:
   §3's `topological_order/1` may return any one valid topological order (e.g. Kahn's
   algorithm's natural queue order over `Map.keys/1`'s own — unspecified — iteration
   order); nothing in this design's own acceptance criteria depends on which one, for
   the same reason REQ-291 gave (independent computed fields cannot observe each other's
   evaluation order by construction).

## 10. Acceptance-criteria mapping

| Acceptance criterion | Design element |
|---|---|
| Every `visible_when`/`computed`/cross-field-validation expression re-evaluated on completion, proven by 3 tests | §2's new `:form_expression_reevaluation` Multi step, §3's `reevaluate/3` and its three passes (`eval_computed_fields/4`, `eval_visible_when_fields/3`, `eval_cross_field_validations/2`) |
| Falsified `computed` value does not win; disposition implemented + stated in moduledoc | §5.1, §3's Pass 1 unconditional overwrite, §3's moduledoc mandate item 2 |
| `visible_when: false` submitted field handled by a documented rule | §5.2, §3's Pass 2, §3's moduledoc mandate item 3 |
| Eval FAILURE distinguishable from `false`, proven by a test | §5.3, §3's Pass 2/Pass 3 distinct `case` clauses, §1 point 3's confirmation `evaluate_condition/2` is unused, §3's moduledoc mandate item 1 |
| Uses the PINNED schema (form_version, REQ-126), not the current one | §1 point 5 — `task.form_schema`, read from the already-locked `:task` Multi step, is pinned by construction at task-insertion time |
| `variable_schemas` remains sole validation authority; no `form_schema` type/constraint validation | §1 point 6, §3's moduledoc mandate item 4, §8 |
| SECURITY-REVIEWER assesses INV-2 (client value reaching a persisted variable without re-derivation) | §8 |
| No `web/` file modified | This design touches only `lib/letflow/engine.ex` and adds `lib/letflow/engine/form_expression_reevaluation.ex` |
| `mix letflow.check` passes | Implementation-time verification, not a design-time claim |
| `lib/letflow/engine/expr.ex` unmodified | §1 point 3 confirms only already-public functions are called; no new token/operator/builtin |

## 11. Scope-fence checklist (re-stated from the requirement's own text, for
    CODE-DESIGN-VALIDATOR)

- [ ] Backend only — no file under `web/` named anywhere in §2-§7.
- [ ] `lib/letflow/engine/expr.ex` not touched — §1 point 3, §10.
- [ ] `tasks.form_schema`'s own persistence (REQ-273) unmodified — this design only
      *reads* `task.form_schema`, never writes it.
- [ ] `variable_schemas`' validation authority unmodified — §1 point 6, §8.
- [ ] No new DB table/migration — §6's event payload reuses the existing
      `TASK_COMPLETED` event and `merged_variable_events` payload key.
