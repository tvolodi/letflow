# TEST-DESIGN-VALIDATOR report — REQ-198 (`expr.ex` 8 builtins)

**Result: PASS**

## Scope

Independently re-verified TEST-DESIGNER's gap-analysis pass
(`handoffs/WF02-REQ198-20260830/test-designer-gap-analysis-req198.md`) against all
11 acceptance criteria in `docs/requirements.yaml`'s REQ-198 entry (lines
10826-10837, read directly), and against `test/letflow/engine/expr_test.exs` and
`lib/letflow/engine/expr.ex` (both read in full myself).

## AC-by-AC verification

- **AC1** (one test per builtin): `describe "parse/1 + eval/2 -- each of the 8
  builtins..."` (lines 569-615) — 8 tests, each via `Expr.parse/1` on real
  condition syntax, concrete expected values. Confirmed.
- **AC2** (`frobnicate(1)` rejected as structured parse error): lines 691-693,
  707-710. Confirmed, including the `parse_strict/1` structured-shape check.
- **AC3** (wrong arity): confirmed the 12 newly-added tests (lines 759-841) for
  `upper`/`lower`/`trim`/`contains`/`startsWith`/`endsWith` (one under-arity +
  one over-arity each), each parses a real condition via `Expr.parse/1` first
  and asserts the exact `{:error, {:eval_error, {:wrong_arity, name, expected,
  got}}}` tuple against the real parsed AST — not a hand-built AST that could
  mask a parser bug. Combined with the pre-existing `length`/`coalesce` tests,
  all 8 fixed/variadic-arity builtins now have dedicated wrong-arity coverage.
- **AC4** (null propagation): lines 621-641, all 3 AC-named cases present
  verbatim plus 2 bonus cases. AC4's own wording enumerates exactly 3 required
  tests — confirmed no gap.
- **AC5** (non-string argument type_mismatch): lines 650-664, 3 representative
  tests across 1-arg and 2-arg shapes. Confirmed.
- **AC6** (ASCII-only case conversion decision + non-ASCII test): lines
  672-679. Moduledoc (`lib/letflow/engine/expr.ex` lines 64-73) states the
  ASCII-only decision explicitly. Confirmed correct and load-bearing (see
  mutation testing below).
- **AC7** (now/date_add/date_diff excluded and rejected): lines 691-714, 4
  individual tests plus a gateway-level catch-false composition test.
  Confirmed, and confirmed load-bearing via mutation (below).
- **AC8** (purity grep, quoted in PR): a PR-description obligation per its own
  wording; the runtime grep-based test at lines 522-541 already exceeds the
  minimum and covers the whole file including REQ-198's additions. Confirmed
  no gap. Note for merge time: the PR description must still quote the actual
  grep invocation/output per AC8's literal text.
- **AC9** (marker-iteration test): independently re-read
  `lib/letflow/engine/expr.ex`'s real `@unsupported_call_markers` (lines
  173-191) and counted 17 entries: `has(`, `matches(`, `all(`, `exists_one(`,
  `exists(`, `int(`, `uint(`, `double(`, `string(`, `bool(`, `bytes(`,
  `duration(`, `timestamp(`, `size(`, `map(`, `map{`, `filter(`. Compared
  entry-by-entry against the test file's literal copy (lines 853-871) — same
  17 entries, same order. Not a stale subset. The design doc
  (`lib/letflow/design/req198-expr-builtin-functions.md` §5) was checked and
  does pre-authorize a literal-copy fallback when the attribute has no public
  accessor; confirmed `@unsupported_call_markers` has no accessor (only
  `@builtin_function_names` does, via the separately-flagged unused
  `builtin_function_names/0`). Disposition confirmed correct, not a defect.
- **AC10** (gateway-level catch-false on wrong-arity builtin): read lines
  886-893 directly — both tests call `Expr.evaluate_condition/2` (the gateway
  entry point at line 1471, composition `translate_cel_to_expr/1` ->
  `parse/1` -> `eval/2`), not `eval/2` directly. Confirmed genuinely at the
  gateway level, distinct from AC3's `eval/2`-level wrong-arity tests.
- **AC11**: verified myself below (TEST-RUNNER's nominal job, but I ran it
  independently as this validator's own required check).

## Fixture/hygiene checks

- No `@tag :skip`, no `TODO`/`pending` anywhere in the file (grepped).
- `async: true` (line 12) is valid — pure module, no `Letflow.Repo`/
  `Ecto.Sandbox` dependency anywhere in the file (confirmed by reading; also
  matches the file's own moduledoc justification).
- No shared mutable fixture state — every test builds its own literal AST or
  parses its own condition string inline; no `setup` block introducing shared
  state across tests.
- No hardcoded secrets/connection strings.
- Tests are self-sufficient — no test depends on another having run first.

## Real toolchain verification

```
$ mix compile --warnings-as-errors
(clean, no output)

$ mix format --check-formatted
(exit 0, clean)

$ mix test test/letflow/engine/expr_test.exs test/letflow/engine/transition_test.exs
Running ExUnit with seed: 512101, max_cases: 16
Excluding tags: [:keycloak, :wasm_hang]
................................................................................................................................................................
Finished in 0.4 seconds (0.4s async, 0.00s sync)
Result: 160 passed (1 property, 159 tests)

$ mix letflow.lint_handoffs
...
letflow.lint_handoffs: OK -- 0 new violations across 1499 handoff files (25 pre-existing grandfathered, traced to ISS-0190).
```

## Mutation testing (applied directly to the working tree, reverted after each)

**Mutant 1 — AC3 arity-table risk.** Changed `required_arity/1`'s `:length`
clause from `{:exactly, 1}` (shared with `lower`/`upper`/`trim`) to its own
clause returning `{:exactly, 2}`, simulating a per-function arity-table
mistake as AC3's own risk framing describes.
Result: **5 of 132 tests failed** — the `length()`/`length(a, b)` wrong-arity
tests, AC1's `length("hello")` test, and others exercising `length/1`
semantics via the now-wrong arity gate. Reverted with `git checkout --
lib/letflow/engine/expr.ex`; `git status --porcelain lib/` empty; full file
re-ran green (132 passed).

**Mutant 2 — AC6 ASCII-casing risk.** Changed `apply_builtin(:lower, ...)`
from `String.downcase(s, :ascii)` to plain `String.downcase(s)` (Unicode
default).
Result: **1 of 132 tests failed** — exactly the AC6 `lower("CAFÉ")` test
(`left: {:ok, "café"}`, `right: {:ok, "cafÉ"}`), confirming this test is
load-bearing for the ASCII-only decision. Reverted; `git status --porcelain
lib/` empty; full file re-ran green (132 passed).

**Mutant 3 — AC7 scope-violation risk.** Added a `now` clause to
`identifier_token/1` (`defp identifier_token("now"), do: {:builtin_call,
:now}`), simulating an accidental whitelist-scope violation admitting a
clock-dependent builtin.
Result: **2 of 132 tests failed** — `"now() is rejected as a parse error"`
(now parses successfully instead: `{:ok, {:call, :now, []}}`) and
`"evaluate_condition/2 collapses now() to false, never raises"` (raised
`FunctionClauseError` in `required_arity/1` instead of returning `false`,
since `:now` was never added to `apply_builtin`/`required_arity` — this is
itself a second-order confirmation that the AC7 rejection tests are the only
thing keeping an incomplete accidental whitelist addition from raising in
production). Reverted; `git status --porcelain lib/` empty; full suite
(`expr_test.exs` + `transition_test.exs`) re-ran green (160 passed, 1
property, 159 tests).

All three mutants were reverted via `git checkout -- lib/letflow/engine/expr.ex`
and confirmed via `git status --porcelain lib/` (empty each time) and a full
green re-run — no mutant is present in the tree at the end of this validation.

## Verdict

PASS. All 11 ACs have genuine, runnable, passing test coverage. AC3's gap-fill
is independently confirmed correct and non-cosmetic (parses real syntax, real
AST, exact error tuple). AC9's hand-copy is confirmed to be a genuine,
exhaustive, design-sanctioned 17-entry match, not a stale subset. AC10 is
confirmed to exercise the gateway (`evaluate_condition/2`), not `eval/2`
directly. Three independent mutations targeting this requirement's core risk
surface (arity-table entry, ASCII-casing decision, whitelist-scope violation)
were each caught by name-identifiable tests. Routing to TEST-RUNNER.
