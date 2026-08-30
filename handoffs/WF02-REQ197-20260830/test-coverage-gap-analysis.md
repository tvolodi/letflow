# REQ-197 test coverage gap analysis (TEST-DESIGNER)

Cross-checked all 12 acceptance criteria in `docs/requirements.yaml`'s REQ-197 entry
against `test/letflow/engine/expr_test.exs` and `test/letflow/engine/transition_test.exs`
as they stood at the start of this step (ELIXIR-DEV's implementation + rework already
committed; REVIEWER PASS on rework iteration 2 per
`handoffs/WF02-REQ197-20260830/step-03-test-designer.json`). Also read
`lib/letflow/design/req197-expr-arithmetic-and-errors.md` in full and
`lib/letflow/engine/expr.ex` in full (not just the design doc's description of it).

Every new assertion added below was checked for factual correctness by loading
`lib/letflow/engine/expr.ex` directly with `elixir -e` (pure module, no other project
dependencies, no OTP app boot required) and inspecting the real return values — this is
fact-finding to avoid writing an assertion that's wrong, not "running tests" (`mix test`
was not run; that remains TEST-RUNNER's job per this role's scope).

## AC-by-AC findings

**AC1 (each of `+ - * / %` and unary negation, one test per operator, concrete expected
value) — GAP, filled.** Before this step, only `:div`'s zero-divisor corner case was
exercised (via the signed-infinity describe block); there was no test for `:add`,
`:sub`, `:mul`, `:mod`, ordinary non-zero `:div`, or `:neg`. Added
`describe "parse/1 + eval/2 -- each arithmetic operator, one test per (AC1)"` (6 tests:
`2 + 3 == 5`, `5 - 3 == 2`, `4 * 3 == 12`, `7 / 2 == 3` (int truncating), `7 % 2 == 1`,
`- 5 == -5`), each parsed from real condition syntax via `Expr.parse/1` rather than a
hand-built AST, so the tokenizer/parser path is exercised too.

**AC2 (precedence: `+`/`*` grouping, comparison-vs-arithmetic ordering, expected values
stated) — GAP, filled.** No precedence test existed at all. Added
`describe "parse/1 + eval/2 -- operator precedence (AC2)"` transcribing the design doc's
own §2.2 worked examples verbatim: `2 + 3 * 4` parses to
`{:arith, :add, {:lit,2}, {:arith,:mul,{:lit,3},{:lit,4}}}` and evaluates to `14`;
`1 + 1 == 2` parses to `{:cmp, :eq, {:arith,:add,{:lit,1},{:lit,1}}, {:lit,2}}` and
evaluates to `true`; plus `3 - 1 - 1 == 1` (left-associativity) and `- - 5 == 5`
(unary-negation right-recursion), both also named in §2.2.

**AC3 (int+float promotion, case where int arithmetic would differ) — GAP, filled.**
No promotion test existed. Added `7 / 2.0 == 3.5`, contrasted directly against AC1's
`7 / 2 == 3` (pure-integer truncating division) — the same operands, different answer,
which is exactly what AC3 asks for.

**AC4 (int div-by-zero, int mod-by-zero, float div-by-zero → infinity, 3 explicit
tests) — PARTIAL GAP, filled.** Float-division-by-zero → `:infinity` was already
covered (the existing "positive dividend / 0.0 -> :infinity (AC4, still passes
unmodified)" test). Int division-by-zero and int modulo-by-zero had zero coverage.
Added both: `eval({:arith, :div, {:lit,5}, {:lit,0}}, %{})` →
`{:error, {:eval_error, {:division_by_zero, :int, 5, 0}}}`, and the `:mod` analogue.
Confirmed the signed-infinity describe block's existing tests are untouched (not
duplicated, not removed) per the step's own constraint.

**AC5 (null-in-comparison→null vs null-in-arithmetic→error, 2 explicit tests) — GAP,
filled.** Zero tests referencing `nil`/`null` existed anywhere in the file (grepped
before writing — confirmed, matching the design doc §4.5's own note that this was
"a safe, unconstrained behavioural change" precisely because no existing test pinned
the old behaviour). Added the design doc's own two worked test cases verbatim:
`eval({:cmp, :lt, {:var,["amount"]}, {:lit,100}}, %{"amount" => nil})` →
`{:ok, nil}`, and `eval({:arith, :add, {:var,["amount"]}, {:lit,1}}, %{"amount" => nil})`
→ `{:error, {:eval_error, {:null_in_arithmetic, :add, nil, 1}}}`.

**AC6 (strict entry point returns structured failure — line, column, token text,
message — field by field on a malformed expression) — GAP, filled.** `parse_strict/1`
was never referenced anywhere in the test file despite being fully implemented in
`expr.ex` (confirmed by grep before writing). Added
`describe "parse_strict/1 -- structured parse failure, field by field (AC6)"` asserting
the exact map `Expr.parse_strict("amount + ")` returns:
`{:error, %{line: 1, column: 10, token_text: "", message: "unexpected end of input"}}`.
This exact value was verified by loading `expr.ex` directly and inspecting the real
return (not guessed from the design doc) — the design doc's own §6 traces the algorithm
but does not hand-compute this column number, so independent verification mattered
here. Also added a success-path test confirming `parse_strict/1` returns the identical
`ast()` `parse/1` returns for the same input, per its own `@doc`.

**AC7 (evaluate_condition/2 on the same malformed expression still returns false;
transition.ex's exclusive-gateway behaviour for a bad condition unchanged) — PARTIAL
GAP, filled.**
- `evaluate_condition/2` side: no test exercised a *malformed arithmetic* condition
  specifically (the design doc §5 names this as ELIXIR-DEV's own "verification
  obligation... not skipped" — a new test was required, not just inherited coverage).
  Added two tests to the existing `evaluate_condition/2` describe block: a trailing-
  operator parse failure (`"variables.amount / "` → `false`) and an eval-time
  arithmetic error (int division by zero → `false`), both verified against the real
  module before writing.
- `transition.ex` side: pre-existing REQ-050 tests
  (`dispatch_exclusive_gateway -- runtime-erroring condition falls through...`) already
  prove the gateway's catch-false composition is unchanged for undefined-variable and
  type-mismatch conditions, and those tests are untouched by this step (still passing
  unmodified is itself part of what "unchanged" means). However, none of them used an
  arithmetic condition — a failure class that didn't exist before REQ-197 — so this was
  a genuine gap in demonstrating REQ-197 specifically didn't disturb `transition.ex`.
  Added `describe "dispatch_exclusive_gateway -- REQ-197 arithmetic error falls through
  via catch-false (REQ-197 AC7)"` with one test using an integer-division-by-zero
  condition, following the exact `graph`/`node`/`edge`/`instance_state` helper pattern
  the surrounding REQ-050 tests already use.

**AC8 (purity grep still zero matches, quoted in the PR) — NO GAP, no test action
needed.** Already covered by the existing
`describe "purity and determinism (AC8)"` → `"expr.ex's actual code (docs/comments
stripped) contains no I/O/clock/randomness call (grep, design doc §7)"` test, which
programmatically re-implements the moduledoc's documented grep as an ExUnit assertion
against the live file. The "quoted in the PR" half of AC8's wording is a PR-description
obligation for ELIXIR-DEV/REVIEWER (already satisfied per the step-03 handoff's own
`verification_evidence.compile_format_purity_test` field, which quotes the actual grep
invocation and its zero-match result) — not something a unit test can assert about a PR
description, so no further test action is warranted here.

**AC9 (`now()` not added, moduledoc states why and states the decided disposition) —
NO GAP, doc-content check, confirmed manually, no test needed.** Read
`lib/letflow/engine/expr.ex`'s moduledoc directly (lines 35–55, "## `now()` /
`date_add()` / `date_diff()` are deliberately not added (AC9)"): it states R-Co's own
`evaluator.zig` comment calling `now()` "inherently impure", states that adding it
would break both the purity contract and REQ-050's determinism guarantee, and states
the decided disposition (a future injected-evaluation-timestamp mechanism, clock reads
permanently ruled out — matching design doc §8). This is prose content, not a runtime
behaviour — there is nothing an ExUnit assertion could check here beyond string-matching
moduledoc text, which would be a manufactured test with no real failure mode (the
moduledoc can't accidentally "add" `now()` in a way a test would catch; the actual
enforcement that `now()` isn't callable is structural, since REQ-198 hasn't yet added
any call-syntax grammar at all — confirmed by grep: no `"now("`-shaped dispatch clause
exists anywhere in `expr.ex`). No test added; this AC is satisfied by inspection.

**AC10 (moduledoc states `benchmark.zig` deliberately not ported) — NO GAP, doc-content
check, confirmed manually, no test needed.** `expr.ex`'s moduledoc (lines 12–20) states
this exact fact, inherited unchanged from REQ-050 and restated as accurate by REQ-197
per the design doc's own §9 table ("this requirement's job is to confirm that sentence
is still present and still accurate, not to write a new one from scratch"). Same
reasoning as AC9: prose content, no executable surface to assert against beyond a
string-match that would prove nothing about actual behaviour. No test added.

**AC11 (moduledoc records R-Co's expr is not CEL, EXP-102 cutover,
`@unsupported_call_markers` rejects CEL vocabulary neither system implements) — NO GAP,
doc-content check for the prose half, but the *behavioural* half (the marker list
itself still rejects everything it rejected before) already has real test coverage.**
The moduledoc's "## R-Co's `src/expr` is not a CEL implementation (AC11)" section
(lines 22–33) states the EXP-102 cutover fact in prose — no test needed for that part,
same reasoning as AC9/AC10. But the marker list's actual rejection behaviour is
executable and already tested: the existing
`describe "translate_cel_to_expr/1 -- unsupported CEL feature boundary (AC6)"` block
(a pre-existing REQ-050 describe block, mis-labelled "AC6" under REQ-050's own AC
numbering, not REQ-197's) exercises `has(...)`, `int(...)`, `size(...)`, the `in`
operator, and the ternary operator, all still returning
`{:error, :unsupported_cel_feature}` — confirmed unchanged by inspection, and
confirmed by the design doc §9 itself ("No change to `@unsupported_call_markers`
itself... every one of the 16 existing markers continues to match exactly the same
inputs"). No new test added; existing coverage already satisfies the behavioural half.

**AC12 (`mix test` and `mix compile --warnings-as-errors` both pass, real output
quoted) — NO GAP, process requirement, not a unit test, not this role's job to run.**
Per this role's remit, `mix test`/`mix compile` are not run here — that is
TEST-RUNNER's step. The step-03 handoff's own `verification_evidence` already quotes a
prior real run (`"mix test test/letflow/engine/expr_test.exs
test/letflow/engine/transition_test.exs: 'Result: 80 passed (1 property, 79 tests)',
0 failures"`), predating this step's additions; TEST-RUNNER must re-run after these
additions before this requirement can be marked done.

## Summary of what was added

- `test/letflow/engine/expr_test.exs`: 6 new `describe` blocks (AC1, AC2, AC3, AC4,
  AC5, AC6 — 16 new tests total) plus 2 new tests appended to the existing
  `evaluate_condition/2` describe block (AC7's `evaluate_condition/2` half).
- `test/letflow/engine/transition_test.exs`: 1 new `describe` block (AC7's
  `transition.ex` half — 1 new test).
- No existing test was modified, removed, or duplicated. The signed-infinity/NaN
  regression tests ELIXIR-DEV already added (expr_test.exs, originally lines 207–258)
  are preserved exactly as-is (now shifted later in the file by the new insertions
  ahead of them, but byte-identical in content).
- No implementation gap was found in `lib/letflow/engine/expr.ex` — every new
  assertion was checked against the real module's actual behaviour before being
  written (via direct `elixir -e` inspection, not guessed from the design doc), and
  every one matched on the first try. No route back through ELIXIR-DEV was needed.
- OQ-4 (negative-operand integer div/mod rounding direction) was not touched, tested,
  or re-opened, per this step's own explicit acceptance criterion not to.
