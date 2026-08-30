# REQ-197 test suite -- TEST-DESIGN-VALIDATOR report

**Verdict: PASS.**

Cross-checked all 12 acceptance criteria in `docs/requirements.yaml`'s REQ-197 entry
(read directly, lines 10754-10766) against `test/letflow/engine/expr_test.exs` and
`test/letflow/engine/transition_test.exs` as committed in `b8ff4fc6`
("test(REQ-197): close AC1/AC2/AC3/AC4/AC5/AC6/AC7 coverage gaps in expr.ex tests").
Did not rely on `handoffs/WF02-REQ197-20260830/test-coverage-gap-analysis.md`'s or
`test/specs/REQ-197.md`'s own claims alone -- read the actual test bodies and, for the
riskiest claims, the actual `lib/letflow/engine/expr.ex`/`transition.ex` source.

## AC-by-AC mapping (independently re-derived)

- AC1 (each operator, concrete value) -- `describe "parse/1 + eval/2 -- each arithmetic
  operator, one test per (AC1)"`, 6 tests, `expr_test.exs:207-237`. Confirmed each parses
  real condition syntax via `Expr.parse/1`, not a hand-built AST.
- AC2 (precedence) -- `describe "... operator precedence (AC2)"`, `expr_test.exs:245-267`,
  transcribes the design doc's own worked examples and asserts both the AST shape and the
  evaluated value.
- AC3 (int/float promotion) -- `expr_test.exs:275-280`, `7 / 2.0 == 3.5` contrasted
  directly against AC1's `7 / 2 == 3`.
- AC4 (int div/mod by zero, float div by zero) -- `expr_test.exs:289-299` (int cases,
  new) plus the pre-existing `"positive dividend / 0.0 -> :infinity"` test
  (`expr_test.exs:352-355`, untouched, cross-referenced as AC4's third case).
- AC5 (null asymmetry) -- `expr_test.exs:307-319`. Verified this is a REAL, observable
  two-way split, not two paths collapsing to the same shape: the comparison test asserts
  `{:ok, nil}` (`expr_test.exs:310`), the arithmetic test asserts
  `{:error, {:eval_error, {:null_in_arithmetic, :add, nil, 1}}}` (`expr_test.exs:316-317`)
  -- different result tags (`:ok` vs `:error`), different payload shapes. Confirmed by
  reading `lib/letflow/engine/expr.ex:1069-1071` (`apply_arith/3`'s nil-check clause,
  checked first per its own comment) that this is the real code path, not a test-only
  fiction.
- AC6 (`parse_strict/1` structured failure) -- `expr_test.exs:327-341`. **Independently
  re-derived the expected values** by loading `expr.ex` directly rather than trusting
  the claim of prior independent verification:
  ```
  $ elixir -e 'Code.require_file("lib/letflow/engine/expr.ex"); IO.inspect(Letflow.Engine.Expr.parse_strict("amount + "))'
  {:error, %{line: 1, message: "unexpected end of input", column: 10, token_text: "", ...}}
  ```
  Matches the test's asserted map exactly (`line: 1, column: 10, token_text: "",
  message: "unexpected end of input"`).
- AC7 (`evaluate_condition/2` catch-false + `transition.ex` gateway unchanged) --
  two `evaluate_condition/2` tests added at `expr_test.exs:465-477`, plus a new
  `describe "dispatch_exclusive_gateway -- REQ-197 arithmetic error falls through via
  catch-false (REQ-197 AC7)"` block at `transition_test.exs:412-438`. **Read this block
  directly**: it builds a real `graph/2`+`node/2`+`edge/4` fixture with an
  `:EXCLUSIVE_GATEWAY` node and an integer-division-by-zero condition on the first edge,
  calls `Transition.transition(g, state, {:advance_token, "t1"})`, and asserts the token
  fell through to the second edge's target -- this genuinely exercises
  `Transition`'s real `dispatch_exclusive_gateway` code path (not `expr.ex` in
  isolation), following the exact fixture pattern the pre-existing REQ-050 AC3 tests
  in the same file already use.
- AC8-AC11 -- confirmed as already-satisfied (purity grep test / doc-content, no
  executable surface) per the gap-analysis's own reasoning; spot-checked AC9/AC10/AC11's
  moduledoc sections exist as claimed (`expr.ex` moduledoc, "now()... deliberately not
  added (AC9)", "benchmark.zig... (AC10 restated)", "R-Co's `src/expr` is not a CEL
  implementation (AC11)") and that the pre-existing
  `translate_cel_to_expr/1 -- unsupported CEL feature boundary` describe block still
  covers the behavioural half of AC11.
- AC12 (`mix test`/`mix compile` pass, output quoted) -- this is TEST-RUNNER's job per
  the gap-analysis; re-run myself below, real output quoted.

## Other required checks

- **Signed-infinity/NaN regression block byte-identical**: confirmed via `git show
  --stat b8ff4fc6` -- only `test/letflow/engine/expr_test.exs`,
  `test/letflow/engine/transition_test.exs`, `test/specs/REQ-197.md`, and this run's own
  handoff files were touched by this commit; no edit to `lib/letflow/engine/expr.ex` or
  `lib/letflow/engine/transition.ex`. The signed-infinity/NaN describe block's mutant
  sensitivity was independently re-confirmed below (mutation 1), which also proves it
  was not accidentally weakened.
- **No skip/pending/TODO**: `grep -rn "@tag :skip\|:pending\|TODO.*test\|@tag :pending"`
  across both test files found no skip/pending test tags (one unrelated match, a
  `pending_task_nodes` keyword option name in an unrelated test helper).
- **Fixtures self-sufficient / no cross-test pollution**: `expr_test.exs` is a pure
  module test (`async: true`, no `Letflow.Repo`/`Ecto.Sandbox`, no shared process state);
  every new test builds its own AST/condition/variables map inline. The new
  `transition_test.exs` block uses the same self-contained `graph/node/edge/
  instance_state` helper functions the surrounding REQ-050 tests already use, with no
  shared mutable fixture.
- **No hardcoded secrets/connection strings**: none present in either file (grepped).
- **Scope**: only test files (+ spec/handoff docs) touched this step -- confirmed above.

## Commands run for real

```
$ mix test test/letflow/engine/expr_test.exs test/letflow/engine/transition_test.exs
Result: 100 passed (1 property, 99 tests)

$ mix compile --force --warnings-as-errors
Compiling 154 files (.ex)
Generated letflow app
(clean, no warnings)

$ mix letflow.lint_handoffs
letflow.lint_handoffs: OK -- 0 new violations across 1489 handoff files
(25 pre-existing grandfathered, traced to ISS-0190)
```

## Mutation testing (mandatory, applied in a throwaway `git worktree`, never in the
working tree)

Set up via `git worktree add <scratch>/mutwt HEAD` (commit `b8ff4fc6`), symlinked
`deps/`/`_build/` from the main checkout to avoid a redundant `mix deps.get`.

**Mutant 1 -- signed-infinity sign-flip regression (per the parent task's explicit
instruction).** Reverted `apply_float_arith/3`'s 3-clause signed-infinity/NaN split
(`expr.ex:1112-1115`) back to the old buggy single unsigned `:infinity` fallback for
ALL float div-by-zero regardless of sign:

```elixir
defp apply_float_arith(:div, l, r) when r == 0.0, do: {:ok, :infinity}
defp apply_float_arith(:div, l, r), do: {:ok, l / r}
```

Result: `mix test test/letflow/engine/expr_test.exs test/letflow/engine/transition_test.exs`
-> **94/100 passed, 6 failures**, all six in the pre-existing
`"eval/2 -- signed float division-by-zero (REQ-197 §4.3, OQ-1 sign-flip fix)"` describe
block (`neg_infinity` case, the NaN-ordering test, both REGRESSION tests, the `0.0/0.0
-> :nan` case, and the NaN self-inequality test). Confirms this describe block still
genuinely discriminates correct signed-infinity/NaN handling from the exact bug
REVIEWER previously caught.

**Mutant 2 -- null-in-arithmetic asymmetry.** Changed `apply_arith/3`'s nil-guard clause
(`expr.ex:1069-1071`) to silently coerce `nil` to `0` instead of erroring:

```elixir
defp apply_arith(op, lv, rv) when lv == nil or rv == nil do
  lv2 = if lv == nil, do: 0, else: lv
  rv2 = if rv == nil, do: 0, else: rv
  apply_arith(op, lv2, rv2)
end
```

Result: **99/100 passed, exactly 1 failure** -- `"eval/2 -- null asymmetry: comparison
propagates, arithmetic errors (AC5) null in arithmetic is an error, regardless of the
other operand's type"`. Confirms AC5's arithmetic-side test is load-bearing and would
catch this exact class of regression.

Both mutants reverted with `git checkout -- lib/letflow/engine/expr.ex` after each
measurement. Final state verified: `git status --porcelain lib/ test/` returned empty
(confirmed twice, once per mutant), and the full suite was re-run green
(`100 passed (1 property, 99 tests)`) before the worktree was removed via
`git worktree remove --force`. The main working tree (`git status --porcelain`) was
never touched and remained clean throughout.

## Disposition

PASS. Routed to TEST-RUNNER via `handoffs/WF02-REQ197-20260830/step-04-test-runner.json`
(top-level `status: "PENDING"`, grepped and confirmed before commit).
