# REQ-288 — `Letflow.Engine.Expr` as the definition-time validator

Design only. No implementation code. Bare signatures and verbatim citations of
*existing* real code are given where needed; no full function bodies appear anywhere
below.

## 1. Re-verification (2026-09-08, this session)

All factual claims in the requirement text were re-derived from source, not trusted.

**Call-site line numbers**, `lib/letflow/definitions.ex` (current, this session):

- `create/2`: `Graph.validate_edge_conditions(graph)` — **line 547**, inside the `with`
  chain, guarded by `check_graph_result/1`:
  ```
  :ok <- check_graph_result(Graph.validate_edge_conditions(graph)) do
  ```
  (line 547 exactly, confirmed by direct read of `lib/letflow/definitions.ex:535-550`).
- `validate_update_graph/1` (private, called from `update/2`):
  `Graph.validate_edge_conditions(graph)` — **line 1631**, same
  `check_graph_result/1` guard shape, inside `validate_update_graph/1`'s own `with`
  chain (`lib/letflow/definitions.ex:1625-1637`). `update/2` itself calls
  `validate_update_graph(attrs)` only when `Map.has_key?(attrs, :graph)` — an update
  that does not touch `:graph` never reaches this call at all.
- `validate_definition_graph/2`: `Graph.validate_edge_conditions(graph).violations` —
  **line 1238**, concatenated with `validate_graph/1` and `validate_node_attributes/1`'s
  violations (`lib/letflow/definitions.ex:1232-1247`). This is the function backing
  `POST /api/v1/definitions/:id/validate` (`lib/letflow/routers/definitions.ex:348-354`).

All three line numbers match the requirement text's citations exactly — no drift found.

**Reachability grep**, before considering any change:

```bash
grep -rn "Engine.Expr" lib/
```
Returns exactly two `lib/` hits (design docs excluded from this grep target, since it
was run as `lib/` only, not `lib/letflow/design/`):
```
lib/letflow/engine/expr.ex:1:defmodule Letflow.Engine.Expr do
lib/letflow/entities/query/types.ex:16:  mirroring `Letflow.Engine.Expr.cmp_op()`'s own closed-union-of-atoms idiom
lib/letflow/engine/transition.ex:15:  condition via `Letflow.Engine.Expr.evaluate_condition/2`. `:PARALLEL_GATEWAY`
lib/letflow/engine/transition.ex:89:  alias Letflow.Engine.Expr
```
i.e. the module's own definition, one doc-comment mention in
`lib/letflow/entities/query/types.ex` (naming `cmp_op()` as a type-shape precedent,
not a call), and `lib/letflow/engine/transition.ex`'s alias plus one moduledoc mention.
**Zero actual call sites of any `Letflow.Engine.Expr` function exist in `lib/` outside
`transition.ex`.** `lib/letflow/definitions/` and `lib/letflow/definitions.ex` return
zero hits today — confirmed by:
```bash
grep -rn "Engine.Expr" lib/letflow/definitions/ lib/letflow/definitions.ex
```
(zero output). This is AC1's "zero before, at least one after" baseline.

**`transition.ex` is confirmed the only other caller, and is out of scope.**
`lib/letflow/engine/transition.ex`'s `dispatch_exclusive_gateway/4` calls
`Letflow.Engine.Expr.evaluate_condition/2` (its own moduledoc, line 15, and the
runtime dispatch code near `transition.ex:670-690`) — the pure, always-boolean,
never-raising runtime path. This requirement's scope fence explicitly excludes
changing this path, and nothing in this design touches `transition.ex` or
`evaluate_condition/2`.

**`valid_cel_syntax?/1` is confirmed still the live structural check**, at
`lib/letflow/definitions/graph.ex:370-380`, called from `check_cel_syntax/1`
(`lib/letflow/definitions/graph.ex:1103-1116`), which is one of the 6 functions
`validate_edge_conditions/1` (`lib/letflow/definitions/graph.ex:347-361`) composes over
via `Enum.flat_map/2`. `valid_cel_syntax?/1` is **public**, carries its own REQ-029 AC4
test suite (`test/letflow/definitions/graph_test.exs:972-1001`,
`test/specs/REQ-029.md` §"Acceptance criterion 4"), and no `lib/` caller other than
`check_cel_syntax/1` invokes it (`grep -rn "valid_cel_syntax?" lib/` shows exactly
`graph.ex`'s own definition and its one call site).

**Current `Violation` shape**, `lib/letflow/definitions/graph.ex:114-157`:
```
@enforce_keys [:code, :message]
defstruct [:code, :message]
@type t :: %__MODULE__{code: code(), message: String.t()}
```
Exactly two fields, both required. `check_cel_syntax/1` currently constructs
`:invalid_cel_syntax` violations as:
```
%Violation{code: :invalid_cel_syntax, message: "Edge '#{edge.id}' has a condition that is not syntactically valid CEL: #{inspect(edge.condition)}"}
```
`validate_definition_graph/2` returns `%{definition_id: ..., valid: violations == [],
violations: violations}` unchanged in shape; the HTTP layer
(`lib/letflow/routers/definitions.ex:1212-1215`) renders each violation through
`violation_map/1`, which extracts **only** `code` and `message`:
```
defp violation_map(%Graph.Violation{code: code, message: message}) do
  %{"code" => Atom.to_string(code), "message" => message}
end
```
No other `Graph.Violation` field is ever serialized to JSON today.

## 2. The mechanism

**Single change point.** `check_cel_syntax/1` (`lib/letflow/definitions/graph.ex:1103`)
is the one function that decides CHK-17's per-edge outcome, and it is the only caller
of `valid_cel_syntax?/1`. All three call sites in `lib/letflow/definitions.ex` reach
`check_cel_syntax/1` exclusively through `validate_edge_conditions/1`
(`graph.ex:347-361`) — there is no second, parallel condition-syntax check anywhere in
`lib/letflow/definitions/` or `lib/letflow/definitions.ex`. Changing what
`check_cel_syntax/1` does therefore changes the outcome at all three call sites
*uniformly and automatically*, with no per-caller plumbing — this is why the design
places the change here rather than in `Definitions.create/2`,
`Definitions.validate_update_graph/1`, or `Definitions.validate_definition_graph/2`
individually (see §3 for why uniform application is also the *chosen* disposition, not
merely the path of least resistance).

**Routing.** `check_cel_syntax/1`'s per-edge decision changes from:

- today: `not blank_condition?(edge.condition) and not valid_cel_syntax?(edge.condition)`
  → violation

to:

- new: for every edge with a non-blank condition, run
  `Letflow.Engine.Expr.translate_cel_to_expr/1` on `edge.condition`; on
  `{:ok, expr_source}`, run `Letflow.Engine.Expr.parse_strict/1` on `expr_source`; a
  violation is produced iff `translate_cel_to_expr/1` returns
  `{:error, :unsupported_cel_feature}` or `{:error, :translate_error}`, **or**
  `parse_strict/1` returns `{:error, parse_failure}`. Success at both stages (an `{:ok,
  _ast}` from `parse_strict/1`) means no violation for that edge. `valid_cel_syntax?/1`
  itself is **not called** from this new path — it is retained (still public, still
  covered by its own REQ-029 test suite, since it has external test-suite obligations
  of its own and no requirement asks for its removal) but is no longer wired into
  CHK-17's outcome.

**Folding `parse_failure` into `Violation` without changing the endpoint's shape
(AC10).** `Letflow.Engine.Expr.parse_failure()` is
`%{line: pos_integer(), column: pos_integer(), token_text: String.t(), message:
String.t()}` (`lib/letflow/engine/expr.ex:530-535`). `Graph.Violation.t()` stays
**exactly** `%{code: code(), message: String.t()}` — no new struct field is added.
Decision: the four `parse_failure` fields (this design also surfaces
`translate_cel_to_expr/1`'s own two distinct rejection reasons, `:unsupported_cel_feature`
and `:translate_error`, as fixed English clauses in the same slot) are folded into the
existing single `message` string, in a fixed, parseable format:

```
"Edge '<edge.id>' condition failed validation at line <line>, column <column>
(near '<token_text>'): <parse_failure.message>"
```

for a `parse_strict/1` failure, and

```
"Edge '<edge.id>' condition uses a CEL construct this grammar does not support
(unsupported call, `in`, or `?`)"
```

for `{:error, :unsupported_cel_feature}`, and

```
"Edge '<edge.id>' condition could not be translated to a well-formed expression"
```

for `{:error, :translate_error}`. `code` stays `:invalid_cel_syntax` in all three
cases — **no new `Violation.code()` variant is added**, since the existing HTTP
contract (`violation_map/1`, `render_validation/2`'s 200/422 branches) is defined over
the current closed `code()` union and AC10 requires the endpoint's response *shape*
(status code, top-level keys, `errors[].code`/`errors[].message` shape) to stay
unchanged. `violation_map/1` needs **no code change** at all under this design, because
`code`/`message` are the only two fields it ever reads — the line/column/token_text
values reach the caller (and AC3's test) via the `message` string, not via a new field.

This is the deliberate design choice examined and rejected as an alternative: adding
`line`/`column`/`token_text` as new **optional** fields on `Graph.Violation` (backward
compatible for existing `%Violation{code: c, message: m}` pattern matches, since
Elixir struct patterns match a subset of fields). Rejected because it would require
`violation_map/1` to also change (to decide whether/how to surface the new fields in
JSON), which is exactly the endpoint-shape churn AC10 forbids touching as part of this
requirement — embedding into `message` keeps the endpoint's `render_validation/2` and
`violation_map/1` **completely unmodified**, satisfying AC10 by construction rather
than by careful equivalence-checking.

**AC3's line/column test** asserts against the `message` string using a regex/pattern
extraction of `line <N>, column <M>` (or, if a test prefers not to string-match, the
test may call `Letflow.Engine.Expr.translate_cel_to_expr/1` and `parse_strict/1`
directly on the same input and assert the returned `parse_failure.line`/`.column`
equal fixed known values, then separately assert the `Graph.Violation.t()` produced by
`check_cel_syntax/1`/`validate_edge_conditions/1` for the identical edge condition has
a `message` containing that same line/column pair). Either form satisfies "asserts the
specific line and column for an expression with a known error position, not merely
that a violation exists" — the test spec (§5) requires the numeric assertion, not a
particular assertion style.

## 3. THE CENTRAL DECISION — call-site disposition (AC6, AC7)

**Decision: the stricter grammar check applies uniformly at all three call sites.
There is no carve-out for either write path.** Stated individually, as AC6 requires:

| Call site | File:line | Disposition |
|---|---|---|
| `create/2` | `lib/letflow/definitions.ex:547` | **Strict grammar check applies.** A new definition with a CEL-syntax-valid-but-grammar-invalid condition is rejected at creation with `{:error, {:graph_validation_failed, violations}}`. Zero rows written (unchanged INV-DS-3 all-or-nothing behaviour — only the *content* of `violations` changes, not `create/2`'s error shape). |
| `validate_update_graph/1` under `update/2` | `lib/letflow/definitions.ex:1631` | **Strict grammar check applies, unconditionally, whenever `attrs` carries `:graph`.** This is the sharp case AC7 names: `validate_update_graph/1` re-validates the *entire* submitted graph, not a diff against the stored one, so a stored definition whose edge condition already fails the grammar (but passed the old structural check when originally created) becomes un-updatable via any request that includes `:graph` in `attrs` — including one that only edits an unrelated node's label. The author gets `{:error, {:graph_validation_failed, violations}}` and the update is rejected outright; there is no partial-apply, no warning-only mode, and no "only re-check edges whose condition text changed" carve-out. |
| `validate_definition_graph/2` (`POST /api/v1/definitions/:id/validate`) | `lib/letflow/definitions.ex:1238` | **Strict grammar check applies** — this endpoint's own moduledoc contract (`lib/letflow/definitions.ex:1194-1198`) requires it to produce "the same outcome as calling REQ-028/029's validators directly on the same graph" (AC4 of REQ-078); since `validate_edge_conditions/1` is the one function all three sites share (§2), this invariant holds *automatically* under a single shared change and would have to be deliberately broken (by special-casing one caller) to produce a different outcome here than at `create/2`/`update/2`. |

**Justification for uniform application, addressing the AC7 risk directly rather than
avoiding it:**

1. **Decision record 0020 (Sequencing step 8) frames the goal as authoring-time
   validation, and authoring includes editing, not only creating.** Its own text:
   "authored CEL-subset expressions must be validated at DEFINITION time... so a bad
   expression fails at authoring rather than at render/evaluation time." `update/2` IS
   an authoring action on a stored definition — carving it out would mean a bad
   condition introduced (or left over from before this requirement) during an update
   still only fails at evaluation time for that specific edit, which is precisely the
   gap step 8 exists to close. A carve-out at the update path would satisfy the letter
   of "new definitions are validated" while leaving the exact failure mode the decision
   record names — silent wrong-edge routing discovered only at runtime — open for every
   already-stored definition indefinitely, since nothing else ever re-validates a
   definition that is never updated again either.
2. **A split disposition (e.g. strict at `create/2` and the validate endpoint, lenient
   at `update/2`) was considered and rejected** because it reintroduces exactly the
   ambiguity AC6 forbids ("a single blanket answer... does not satisfy this criterion
   — it is ambiguous between the two write paths") in a different shape: it would mean
   two DIFFERENT write paths disagree with each other on the same graph content, which
   is harder to reason about for an author than "any request that writes `:graph`
   enforces the same check," and it would break `validate_update_graph/1`'s and
   `validate_definition_graph/2`'s shared reliance on `validate_edge_conditions/1`
   agreeing with itself.
3. **The alternative that would avoid AC7's risk — checking only edges whose
   `condition` text actually changed, in `update/2`, via a diff against the
   currently-stored graph — is deliberately NOT chosen.** It would require `update/2`
   to fetch and diff against the prior stored graph before validating, which
   `validate_update_graph/1` does not do today (it validates the submitted graph
   in isolation, `lib/letflow/definitions.ex:1625-1637`) and which is a materially
   larger, separate piece of design (definition-diffing) this requirement's SCOPE
   FENCE ("backend only... does not change Transition's runtime evaluation path") does
   not authorize opening. Flagged here as an OPEN QUESTION for a future requirement if
   the AC7 consequence proves too disruptive to real tenant workflows in practice — see
   §6.
4. **This is the behaviour-change-on-existing-data disposition the requirement
   requires to be stated explicitly (not left implicit):** the stricter check
   re-classifies STORED definitions as invalid, not only newly-submitted ones, at both
   `update/2` (immediately, on the next graph-touching update) and
   `validate_definition_graph/2` (immediately, on the next validate call) — `create/2`
   only ever sees new content, so "stored data" reclassification is specific to the
   other two. This is recorded in the module's moduledoc per the requirement's
   instruction — see §3.1.

### 3.1 Moduledoc recording obligation

`lib/letflow/definitions/graph.ex`'s moduledoc (the "8 named checks" section,
currently at lines 32-53) gains a new subsection, `## CHK-17 grammar tightening
(REQ-288)`, stating verbatim:

- CHK-17 (`check_cel_syntax/1`) routes through `Letflow.Engine.Expr.translate_cel_to_expr/1`
  → `parse_strict/1` as of REQ-288, not `valid_cel_syntax?/1`.
- The disposition table above (all three call sites, named individually, uniform
  strict application).
- The explicit behaviour-change-on-existing-data statement from point 4 above:
  stored definitions ARE re-classified as invalid on the next `update/2` (with
  `:graph` in `attrs`) or `validate_definition_graph/2` call — this is a deliberate,
  not incidental, consequence.
- A pointer to §3's reasoning above (by requirement id) rather than re-deriving it at
  the call site.

## 4. Grammar freeze — no change to `lib/letflow/engine/expr.ex`

**`lib/letflow/engine/expr.ex` is not modified by this requirement.** `git diff` for
this branch shows this file **unmodified** — zero lines changed. `translate_cel_to_expr/1`
and `parse_strict/1` already exist, complete, from REQ-197 (design doc
`lib/letflow/design/req197-expr-arithmetic-and-errors.md` §6) — this requirement
*reads* them from a new caller, it does not add, remove, or alter any token, operator,
builtin, `@unsupported_call_markers` entry, or accepted grammar construct. This is
consistent with the EXP-102 freeze the moduledoc states (§"R-Co's `src/expr` is not a
CEL implementation", `expr.ex:23-35`): no work item in this design touches
`@unsupported_call_markers`, `@builtin_function_names`, `do_tokenize/2`,
`do_tokenize_positioned/4`, or any `parse_*`/`parse_*_p` clause. If implementation
finds any real definition in the repo's fixtures or a stored tenant row failing under
the stricter check, ELIXIR-DEV reports it as a finding (per the requirement text) —
it is never grounds to add a token/operator/builtin to close the gap.

## 5. Test plan (all 10 ACs)

| AC | Test(s) | Notes |
|---|---|---|
| AC1 (reachability) | Not a runtime test — a literal shell-command assertion recorded in the requirement's completion evidence: `grep -rn "Engine.Expr" lib/letflow/definitions/` returns zero hits on `main` before this change and at least one hit (the new call inside `check_cel_syntax/1`, or an alias/import in `graph.ex`) after. Both commands and both outputs quoted in the handoff, per the AC's own wording. |
| AC2 (3 rejected constructs, before/after) | New `describe` block in `test/letflow/definitions/graph_test.exs`, e.g. `describe "check_cel_syntax/1 — REQ-288 grammar tightening"`. Three fixed condition strings: (a) `"variables.status in [\"A\", \"B\"]"` (bare `in`, an `@unsupported_call_markers`-class CEL construct — actually caught by `contains_in_operator?/1` inside `translate_cel_to_expr/1`, giving `{:error, :unsupported_cel_feature}`); (b) `"variables.frobnicate(variables.x)"` (an unknown function/identifier-then-`(` shape that is not one of the 8 REQ-198 builtins — `parse_strict/1` produces `{:unexpected_token, _}` or `{:invalid_identifier, _}` since bare-identifier-then-`(` with a non-builtin name is not valid call syntax in this grammar); (c) `"variables.a == variables.b =="` (lexically balanced — no unbalanced bracket/quote, no bare leading/trailing operator by `valid_cel_syntax?/1`'s own bracket/operator-only rules — but not parseable: trailing `==` with no right operand, `parse_strict/1` returns `:unexpected_end_of_input`). For each of the 3: assert `Graph.valid_cel_syntax?/1` returns `true` (proving the OLD check would have accepted it — the "shown passing under `valid_cel_syntax?/1`" half of AC2), and assert `Graph.check_cel_syntax/1`'s current test's equivalent (`Graph.validate_edge_conditions/1` on a minimal graph carrying that condition on an `EXCLUSIVE_GATEWAY`'s non-default edge) now returns a `:invalid_cel_syntax` violation for that edge (proving the NEW check rejects it). `check_cel_syntax/1` itself is private, so the assertion goes through `validate_edge_conditions/1`'s public surface, matching the existing test file's own convention at `graph_test.exs:952`. |
| AC3 (line/column/token_text/reason) | One test picks a condition with a syntactically unambiguous, hand-countable error position — e.g. `"variables.amount >\n  "` (a trailing comparison operator with no right operand, across two lines, so line 2 is exercised) or a single-line case like `"variables.amount > )"` (unexpected `)` token at a known column). Assert (per §2's "AC3's line/column test" note) either (a) directly on `Letflow.Engine.Expr.parse_strict/1`'s returned `parse_failure.line`/`.column`/`.token_text` for the post-translation `expr_source`, cross-checked against the `Violation.message` string produced by `check_cel_syntax/1` for the identical edge condition containing that same line/column pair, or (b) a single assertion against the `Violation.message` using a regex capturing `line (\d+), column (\d+)` and asserting the captured groups equal the expected fixed integers. The test must name the expected numeric line and column up front (not merely assert "some digits appear"). |
| AC4 (differential_corpus.json all 15 pass) | New test iterating `test/fixtures/simulation/differential_corpus.json` (parsed via `Jason.decode!/1` or the project's existing JSON-fixture-loading helper, matching whatever `req209-expr-differential-corpus-regression.md`'s existing corpus test already uses for this same file, so as not to invent a second loader). For each of the 15 entries' `condition_text`, assert `Letflow.Engine.Expr.translate_cel_to_expr/1` returns `{:ok, _}` AND the resulting `expr_source` is accepted by `Letflow.Engine.Expr.parse_strict/1` (`{:ok, _ast}`), i.e. the same routing `check_cel_syntax/1` now performs. This may be asserted either directly against `Expr` or through `Graph.check_cel_syntax/1`'s behaviour on 15 synthetic edges — the direct-against-`Expr` form is preferred since it needs no synthetic graph construction per entry. |
| AC5 (no evidence claim) | Not a separate test — a **written caveat placed directly in the AC4 test's own `@moduledoc`/comment and in the requirement's completion evidence**, stating verbatim the limit: all 15 `condition_text` entries use only comparisons, `&&`/`||`, `!`, parentheses, and dotted `variables.` paths — no CEL macro, no `in`, no `?`, no unknown function name, no unterminated construct appears anywhere in the fixture. Per core-directives.md's "Re-derive under the conditions the property is actually about," this test passing is evidence the *grammar itself* has not regressed on known-good input; it is explicitly **not** evidence that any *stored tenant row* passes the stricter check, since the fixture was never populated from tenant data and contains no example of the constructs this requirement newly rejects. |
| AC6 (per-call-site disposition stated) | Not itself a runtime test — verified by reading the moduledoc addition (§3.1) and confirming, textually, that `create/2` (547), `validate_update_graph/1` (1631), and `validate_definition_graph/2` (1238) are each named individually with their own disposition sentence, not one shared sentence covering all three implicitly. |
| AC7 (update/2 sharp edge) | New test in `test/letflow/definitions_test.exs` (or wherever `update/2`'s existing test `describe` blocks live): (1) construct a graph whose `EXCLUSIVE_GATEWAY` has a non-default edge with a condition accepted by `valid_cel_syntax?/1` but rejected by `parse_strict/1` (reuse one of AC2's three fixture strings); (2) insert it via a path that bypasses the new stricter `create/2` check — either by inserting directly via `Letflow.Repo`/the schema (not through `Definitions.create/2`, since `create/2` itself now also rejects it, per §3's uniform disposition) so the row exists in the DB exactly as if it had been created before this requirement shipped; (3) call `Definitions.update/2` with `attrs` carrying `:graph` containing only an unrelated change (e.g. a different node's `label`), leaving the offending edge's condition untouched; (4) assert the call returns `{:error, {:graph_validation_failed, violations}}` with a `:invalid_cel_syntax` violation naming the untouched edge — proving the chosen "applies everywhere, including to untouched conditions" disposition is real and tested, not asserted. A second assertion in the same test confirms `attrs` not carrying `:graph` at all (e.g. only `:description` changed) succeeds normally, showing the sharp edge is specific to graph-touching updates, matching `validate_update_graph/1`'s own existing `Map.has_key?(attrs, :graph)` guard (`lib/letflow/definitions.ex:1626`). |
| AC8 (fixture-limits caveat stated explicitly) | Same artifact as AC5 — the caveat is written into the test file and the completion evidence, not left to be inferred from the test passing. |
| AC9 (endpoint shape unchanged) | HTTP-level test against `POST /api/v1/definitions/:id/validate` (extending the existing router test suite for this endpoint, matching its current test file's conventions): (a) a definition whose graph is fully valid returns `200` with `%{"status" => "valid", "findings" => [], "definition_id" => _, "validated_at" => _}` — unchanged from today; (b) a definition with an edge condition that fails only under the new stricter check (accepted by the old `valid_cel_syntax?/1`, rejected by `parse_strict/1`) returns `422` with the existing problem-details shape, `errors` being a list of `%{"code" => "invalid_cel_syntax", "message" => <string containing the line/column per §2>}` maps — proving `violation_map/1` needed no change and the top-level response shape is identical to before this requirement, only the population of `findings`/`errors` differs for previously-passing-now-failing input. |
| AC10 (`mix letflow.check` passes) | Run `mix letflow.check` after implementation; quote real output in the handoff. Not simulated here since this is a design document, not an implementation — ELIXIR-DEV/TEST-RUNNER produce the real quoted output at their steps. |

## 6. Open questions

- **OQ-1 (flagged, not resolved here):** if AC7's chosen disposition (uniform
  application, including to untouched pre-existing conditions on `update/2`) proves
  disruptive to real tenant definitions once this ships — i.e. RELEASE-VALIDATOR or a
  later UAT finds tenant definitions that are now permanently stuck unable to accept
  *any* edit until their author also fixes an unrelated, pre-existing bad condition —
  the diff-based "only re-check edges whose condition text changed" alternative named
  in §3 point 3 is the documented fallback design, but it is explicitly **out of
  scope** for this requirement to build. This is not a request for permission to
  guess; it is recorded so ELIXIR-DEV does not have to rediscover the alternative was
  considered and deliberately deferred, and so a future requirement can pick it up
  without re-deriving the reasoning in §3.
- **OQ-2:** whether `valid_cel_syntax?/1`, now unwired from `check_cel_syntax/1`, should
  eventually be deprecated/removed is explicitly NOT decided here — it still carries
  its own REQ-029 AC4 test obligations and no requirement asks for its removal. Left
  as-is; flagged only so a future cleanup pass does not assume it is dead code without
  checking for other callers first.
