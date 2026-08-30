# RELEASE-VALIDATOR independent re-verification -- REQ-197

run_id: WF02-REQ197-20260830
verdict: **PASS**
timestamp_utc: 2026-08-30T10:05:34Z

## Basis for the verdict (independently re-derived, not read from TEST-RUNNER's report)

### 1. Full test suite, re-run for real (isolated, single instance)

`source ~/.asdf/asdf.sh && bash scripts/test_parallel.sh` run alone (a later
accidental duplicate concurrent run of my own produced 16 failures purely from
Postgres `too_many_connections` self-contention -- confirmed via
`grep "too_many_connections" /tmp/letflow_test_parallel.dOg98p/partition-1.log`,
discarded as my own artifact, not evidence of anything):

```
partition 1: 353 tests, 3 properties, 0 failures, exit 0
partition 2: 390 tests, 0 properties, 0 failures, exit 0
partition 3: 314 tests, 2 properties, 0 failures, exit 0
partition 4: 304 tests, 1 property, 0 failures, exit 0
partition 5: 359 tests, 0 properties, 0 failures, exit 0
partition 6: 245 tests, 0 properties, 0 failures, exit 0
partition 7: 325 tests, 0 properties, 2 failures, exit 2
partition 8: 361 tests, 0 properties, 0 failures, exit 0
combined: 2651 tests, 6 properties, 2 failures (2655/2657 passed)
```

Exactly reproduces TEST-RUNNER's reported combined result and per-partition
breakdown.

### 2. Independently diagnosed the 2 failures myself (not trusted from the report)

`grep -n "enoent\|CheckToolchain" /tmp/letflow_test_parallel.5C0J0A/partition-7.log`
shows both failures are `** (ErlangError) Erlang error: :enoent` raised from
`test/mix/tasks/letflow_check_toolchain_test.exs:69` inside
`running_rust_raw/0`, called from `running_rust_version/0` (line 76) -- i.e.
`System.cmd("rustc", ...)` failing because `rustc` does not exist on PATH.
Confirmed independently: `which rustc` -> exit 1 (absent).
Confirmed independently: `git diff main...HEAD --stat -- test/mix/tasks/letflow_check_toolchain_test.exs`
returns nothing -- this branch does not touch that file. Matches TEST-RUNNER's
diagnosis; not a REQ-197 regression.

### 3. Targeted REQ-197 tests, re-run for real

`mix test test/letflow/engine/expr_test.exs test/letflow/engine/transition_test.exs`
-> `Result: 100 passed (1 property, 99 tests)`, 0 failures. Matches.

### 4. `mix compile --force --warnings-as-errors`

Clean: `Compiling 154 files (.ex)` / `Generated letflow app`, no warnings, no
errors.

### 5. Purity grep, re-run myself against the real file (not the test's copy)

```
grep -n "Repo\.\|Logger\.\|DateTime\.\|System\.os_time\|System\.system_time\|HTTPoison\|Req\.\|File\.\|:rand\.\|:crypto\." lib/letflow/engine/expr.ex
```
returns exactly one line: line 76, which is the moduledoc's own quoted copy of
this grep command (a documented, deliberate self-reference -- the same pattern
exists in `transition.ex`'s moduledoc at line 49, matching stated precedent).
Confirmed this is the correct call, not a loophole: `expr_test.exs`'s own AC8
test (line 522-541) strips `"""..."""` doc blocks and `#`-comment lines before
grepping the same pattern against the same file, and asserts zero matches --
so the real code (excluding documentation prose) is genuinely impurity-free.
Zero real code matches, confirmed by reading the stripped-file logic and the
raw grep output myself.

### 6. Read `lib/letflow/engine/expr.ex` in full and checked each of the 12 ACs against the real code

- **AC1** (each of `+ - * / %` and unary `-`): `apply_int_arith/3` (1088-1094),
  `apply_float_arith/3` (1109-1119), `apply_neg/1` (1126-1131). Per-operator
  tests exist in `expr_test.exs` describe block "AC1" (line 207).
- **AC2** (precedence): `parse_additive`/`parse_multiplicative`/`parse_unary`
  chain (889-935) matches or/and/not/cmp/+-/*÷%/unary-/primary. Tests at
  `expr_test.exs` describe "AC2" (line 245).
- **AC3** (int/float promotion): `apply_arith/3`'s final clause (1081-1083)
  promotes via `lv * 1.0, rv * 1.0`. Tests at line 275.
- **AC4** (div/mod by zero + signed infinity): `apply_int_arith(:div/:mod, l, 0)`
  errors (1091, 1093); `apply_float_arith(:div, ...)` implements the full
  REVIEWER-mandated 3-way sign split -- positive dividend -> `:infinity`,
  negative dividend -> `:neg_infinity`, `0.0/0.0` -> `:nan` (1112-1115) -- this
  is the corrected, SIGNED version (not the original unsigned-:infinity-only
  bug REVIEWER caught). `infinity_marker()` typedoc (82-98) documents the
  REVIEWER gate as RESOLVED at rework iteration 2. Regression tests exist at
  `transition_test.exs`/`expr_test.exs`'s "signed float division-by-zero"
  describe block (line 351) reproducing REVIEWER's exact sign-flip scenario.
- **AC5** (null asymmetry): comparison clause (`eval/2` ordering, line
  1027-1028) -- nil operand -> `{:ok, nil}` (propagates); `apply_arith/3`'s
  FIRST clause (1069-1071) -- nil operand -> `{:error, {:null_in_arithmetic,
  ...}}`. Confirmed asymmetric as required. Tests at line 307.
- **AC6** (structured parse failure): `parse_strict/1` (473-497) returns
  `%{line, column, token_text, message}` via `package_failure/1` and
  `describe_parse_error/1`. Tests at line 327, field-by-field.
- **AC7** (EE-05 catch-false): `evaluate_condition/2` (1183-1192) collapses
  every failure mode to `false` via a bare `with`/`else _ -> false`.
  `transition.ex`'s `evaluate_conditioned_edges/3` (662-676) calls
  `Expr.evaluate_condition/2` directly with no separate error branch --
  confirmed by reading `transition.ex` myself. Explicit regression describe
  block in `transition_test.exs` (line 412) titled exactly for REQ-197 AC7,
  plus `expr_test.exs` line 465/472 covering malformed-arithmetic and
  division-by-zero-through-the-gateway-path cases.
- **AC8** (purity): see §5 above -- confirmed independently, not just via the
  test file.
- **AC9** (`now()` not added + stated reasoning): confirmed by reading the
  actual moduledoc text (lines 35-55) myself -- explicitly states R-Co's
  `evaluator.zig` documents `now()` as "inherently impure; all other built-ins
  are pure", that adding it would break both the purity grep and REQ-050's
  determinism guarantee, and states the decided disposition (an injected
  `eval_context` timestamp from the caller, never a clock read inside
  `expr.ex`) rather than leaving the question open.
- **AC10** (`benchmark.zig` not ported): moduledoc lines 12-20 name it
  explicitly as a Zig latency-benchmarking harness (1,000 warm-up / 10,000
  measured iterations, 10us target, debug-print only, imported by nothing),
  states it has no production behaviour and is "deliberately not ported at
  all".
- **AC11** (not a CEL implementation / EXP-102 cutover): moduledoc section
  header "R-Co's `src/expr` is not a CEL implementation (AC11)" (lines 22-33)
  states R-Co's EXP-102 "cut over *from* a vendored CEL (`vendor/cel`) *to*
  `src/expr`, retiring CEL entirely", and that `@unsupported_call_markers`
  rejects CEL vocabulary neither system implements -- read verbatim myself,
  not inferred from a summary.
- **AC12** (`mix test`/`mix compile --warnings-as-errors` pass): confirmed in
  §3/§4 above with real, freshly-run output.

## Verdict

**PASS.** All 12 acceptance criteria genuinely hold against the real code and
tests as they exist on this branch today, independently re-derived rather than
taken on the chain's word. The 2 full-suite failures are confirmed,
independently, to be an environment-caused (rustc absent) pre-existing gap in
`test/mix/tasks/letflow_check_toolchain_test.exs`'s own error handling, in a
file this branch's diff does not touch. Routed to DOC-UPDATER.
