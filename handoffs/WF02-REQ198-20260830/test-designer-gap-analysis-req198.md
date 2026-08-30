# TEST-DESIGNER gap analysis — REQ-198 (`expr.ex` 8 builtins)

Cross-checked all 11 acceptance criteria in `docs/requirements.yaml`'s REQ-198 entry
(lines 10826-10837) against ELIXIR-DEV's existing ~50-test pass in
`test/letflow/engine/expr_test.exs` (read in full). Following the REQ-197 precedent:
verify, fill genuine gaps only, no rewrite.

## AC-by-AC disposition

**AC1 (one test per builtin, concrete value) — already complete, no gap.**
`describe "parse/1 + eval/2 -- each of the 8 builtins, one test per (AC1)"`
(expr_test.exs:569-615) has one test per builtin, each parsed from real condition
syntax and asserting a concrete value: `length("hello")` → `5`, `lower("HELLO")` →
`"hello"`, `upper("hello")` → `"HELLO"`, `trim(...)` → `"hi there"`,
`contains(...)` → `true`, `startsWith(...)` → `true`, `endsWith(...)` → `true`,
`coalesce(1, 2)` → `1`. None is a bare "doesn't crash" assertion. A bonus nested-call
test is also present. No gap.

**AC2 (frobnicate(1) rejected as structured parse error) — already complete.**
`expr_test.exs:691-693` tests `frobnicate(1)` is a `{:parse_error, _}`, and
`expr_test.exs:707-710` additionally proves it surfaces through `parse_strict/1`'s
structured shape (`%{line:, column:, token_text:, message:}`), which is what "carries
REQ-197's structured error" actually requires. No gap.

**AC3 (wrong arity) — GAP FOUND AND FILLED.**
Before this pass, only `length`/`coalesce` had wrong-arity tests (lines 722-749),
matching ELIXIR-DEV's own report language ("length and coalesce"). AC3's literal
wording only names those two as its worked examples, but design doc §4's arity table
(traceability §10 row 3) specifies a wrong-arity example for every fixed-arity
builtin, and `required_arity/1` (§4) is a per-function lookup dispatched inside
`check_arity/2` — a mistake scoped to one function's table entry (e.g. `contains`
wrongly requiring 3 args instead of 2) would not be caught by exercising
`length`/`coalesce` alone. Added 12 tests (one under-arity + one over-arity per
remaining fixed-arity function: `upper`, `lower`, `trim`, `contains`, `startsWith`,
`endsWith`), appended inside the existing `"eval/2 -- wrong arity is rejected (AC3)"`
describe block, same style as the pre-existing length/coalesce tests (parse via
`Expr.parse/1`, assert the exact `{:wrong_arity, name, expected, got}` tuple).

**AC4 (null propagation) — already complete, no gap. Re-read carefully as
instructed.**
AC4's exact text: *"length(null) yields null, contains(null, "x") yields null, and
coalesce(null, null, 3) yields 3 -- **three explicit tests**"* — a narrow,
enumerated scope, unlike AC1's "at least one test per function" framing. All three
named cases are present verbatim (`expr_test.exs:622-637`), plus two bonus cases
(`contains("x", null)`, `coalesce(null, null)` all-null) that exceed the stated
minimum. The design's §3.2/§3.3 semantics tables do show a null row for
`lower`/`upper`/`trim`/`startsWith`/`endsWith` too, but AC4 does not ask for tests on
those specifically (that's AC1's job, and AC1 only requires one concrete-value test
per function — already satisfied). Adding null-prop tests for the other 5 functions
would not be filling an AC4 gap, it would be over-testing past what any AC asks for;
declined, consistent with "don't duplicate/manufacture coverage."

**AC5 (non-string argument is type_mismatch, not coerced) — already complete.**
AC5's wording uses "such as length(42)" — one representative example. Three
representative tests exist (`length(42)`, `lower(true)`, `contains(1, "x")`,
lines 650-664), spanning both the 1-arg and 2-arg type-mismatch tuple shapes. No gap.

**AC6 (case-conversion decision + non-ASCII test) — already complete.**
`expr_test.exs:672-679`, REVIEWER already spot-checked and confirmed correct
(`café`/`CAFÉ` byte-range reasoning). No gap.

**AC7 (now/date_add/date_diff excluded, tested rejected) — already complete, all 3
individually tested plus frobnicate.**
Contrary to the risk the task flagged ("just one representative case"), the file
already has 4 separate tests: `frobnicate(1)` (AC2), `now()`, `date_add(a, b)`,
`date_diff(a, b)` (lines 691-704), each asserting `{:error, {:parse_error, _}}`
individually — not one collapsed onto a single example. Plus an `evaluate_condition/2`
composition test proving `now()` collapses to `false` (line 712-714). No gap.

**AC8 (purity grep, quoted in PR) — process/PR-description obligation, not a runtime
test; already exceeded.**
AC8's own wording ("quoted in the PR") makes this a PR-description obligation, same
disposition REQ-197 gave its equivalent AC — TEST-DESIGNER does not need to add a test
for a PR-description requirement. However, this codebase already goes further than
that minimum: `describe "purity and determinism (AC8)"` (lines 522-541) contains a
*runtime* ExUnit test that greps the actual `expr.ex` source (docs/comments stripped)
for the same forbidden-call pattern the design doc's §7 procedure specifies, and
asserts zero matches by execution, not by static PR-description claim alone. This
predates REQ-198 (from REQ-050/REQ-197) and continues to cover REQ-198's added code
since it greps the whole file. No gap; the PR description for this handoff's merge
still needs to quote the actual grep invocation per AC8's literal text — that remains
ELIXIR-DEV/ORCH's merge-time obligation, not a new test-file artifact.

**AC9 (marker-iteration test) — already complete; hand-copy risk assessed and
accepted, not a gap.**
The test (`expr_test.exs:759-786`) iterates a literal 17-entry copy of
`@unsupported_call_markers`, not a live reference — REVIEWER flagged this as a
"hand-copy" risk. Checked `lib/letflow/engine/expr.ex` directly: `@unsupported_call_markers`
(line 173) has **no public accessor** — unlike `@builtin_function_names`, which does
via `builtin_function_names/0` (lines 150-151, itself unused/dead per REVIEWER's
separate finding). Critically, the design doc's own §5 "Verification obligation for
ELIXIR-DEV (AC9)" text explicitly pre-authorizes exactly this fallback: *"a test
iterating `@unsupported_call_markers` **(or a fixed literal copy of its 17 entries, if
the attribute itself is not exported)**"*. Since the attribute is in fact not
exported, the hand-copy is the design-sanctioned approach, not a shortcut taken
against it. Disposition: **no fix needed**. Exporting a new accessor for
`@unsupported_call_markers` to let the test consult it live would be a genuine
improvement worth flagging for a future pass (parallel to the existing unused
`builtin_function_names/0` cleanup note already on record), but doing so now would be
an `lib/` change outside this handoff's "test files only unless a genuine
implementation gap" scope — and it isn't a gap, since the design doc explicitly
allows the literal-copy fallback. Not routed back to ELIXIR-DEV.

**AC10 (EE-05 catch-false, wrong-arity builtin, gateway path) — already complete,
correctly at the gateway level.**
`describe "evaluate_condition/2 -- catch-false on a wrong-arity builtin call (AC10,
EE-05)"` (lines 793-801) calls `Expr.evaluate_condition/2` directly (the gateway
composition entry point that `Letflow.Engine.Transition`'s conditioned-edge evaluation
actually calls), not `eval/2` directly — `length() == 0` and `coalesce()` both assert
`== false`. This is the right layer: AC10 is specifically about the gateway path's
catch-false contract, not eval/2's raw error tuple (already covered separately by
AC3). No gap.

**AC11 (mix test / mix compile --warnings-as-errors pass, real output quoted) —
TEST-RUNNER's job, not TEST-DESIGNER's** (per this handoff's task framing and
core-directives: TEST-DESIGNER does not run tests). Not evaluated here.

## Summary of changes made

- **File touched:** `test/letflow/engine/expr_test.exs` only. No `lib/` changes — no
  genuine implementation gap was found against the design or any AC.
- **Added:** 12 wrong-arity tests (AC3 gap) for `upper`, `lower`, `trim`, `contains`,
  `startsWith`, `endsWith` — one under-arity + one over-arity test each, appended to
  the existing `"eval/2 -- wrong arity is rejected (AC3)"` describe block, matching
  its established style (parse real condition syntax, assert the exact
  `{:error, {:eval_error, {:wrong_arity, name, expected, got}}}` tuple).
- **Not added (deliberately, reasoned above):** null-propagation tests for
  lower/upper/trim/startsWith/endsWith beyond AC4's literally enumerated 3 cases; a
  live accessor for `@unsupported_call_markers`; any PR-description artifact for AC8
  (out of scope for a test file).

All pre-existing ~50 tests are unmodified — this is a pure addition.
