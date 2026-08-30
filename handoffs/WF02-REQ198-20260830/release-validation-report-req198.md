# RELEASE-VALIDATOR report -- REQ-198

Run: WF02-REQ198-20260830, Step 5 (WF-02)
Branch: feature/WF02-REQ198-20260830
Date: 2026-08-30

## Verdict: PASS

Independently re-derived all 11 acceptance criteria against the real
`lib/letflow/engine/expr.ex` (1481 lines, read in full) and a self-run test
pass -- not copied from TEST-RUNNER's or any earlier gate's report.

## Independent checks performed and results

1. **AC1 (8 builtins, concrete tests)** -- `test/letflow/engine/expr_test.exs`
   lines 569-618 assert `length`, `lower`, `upper`, `trim`, `contains`,
   `startsWith`, `endsWith`, `coalesce` each with a concrete expected value.
   Confirmed the implementations at `apply_builtin/2` (expr.ex L1268-1305)
   match: `length` -> `byte_size/1`, `lower`/`upper` -> `String.downcase/upcase(s, :ascii)`,
   `trim` -> hand-rolled `ascii_trim/1`, `contains`/`startsWith`/`endsWith` ->
   `string_predicate/4` wrapping `String.contains?/2`, `String.starts_with?/2`,
   `String.ends_with?/2`, `coalesce` -> `Enum.find(values, nil, &(&1 != nil))`.

2. **AC2 (whitelist closed, frobnicate rejected)** -- traced the actual
   mechanism rather than trusting the claim: `identifier_token/1`/
   `identifier_token_kv/1` map exactly 8 literal names to `{:builtin_call, _}`;
   anything else (e.g. `frobnicate`) falls to the catch-all `{:var, ...}`
   clause. `parse_primary/1`'s `{:var, path}` clause matches unconditionally
   and does not consume a following `(`, so `frobnicate(1)` parses `frobnicate`
   as a bare variable and leaves `(1)` as unconsumed trailing tokens, which
   `parse/1` surfaces as `{:error, {:parse_error, {:trailing_input, _}}}` --
   a genuine parse error, never evaluated. Test at expr_test.exs:691 confirms
   this concretely; `parse_strict/1`'s structured-error variant tested at
   line 707. Also confirmed `now()`/`date_add()`/`date_diff()` -- R-Co's 3
   excluded builtins -- are absent from both `identifier_token/1` and
   `identifier_token_kv/1`'s mapping clauses (only the 8 REQ-198 names plus
   the pre-existing `and`/`or`/`not`/`true`/`false`/`null` appear), so they
   fall to the same `{:var, ...}` path and are rejected identically. Tests at
   lines 695-712 confirm concretely, including
   `evaluate_condition/2` collapsing `now()` to `false` (not raising).

3. **AC3 (wrong arity, ALL 8 functions)** -- `required_arity/1` (L1242-1244)
   declares `{:exactly, 1}` for length/lower/upper/trim, `{:exactly, 2}` for
   contains/startsWith/endsWith, `{:at_least, 1}` for coalesce, enforced by
   `check_arity/2` before `apply_builtin/2` ever dispatches. Verified test
   coverage is NOT partial: lines 723-836 test wrong-arity in both directions
   (too few / too many) for `length`, `coalesce` (0 args = error, 1 arg =
   valid), `upper`, `lower`, `trim`, `contains`, `startsWith`, `endsWith` --
   all 8, not a couple as a lazier implementation might have gotten away with.

4. **AC4 (null propagation)** -- `apply_builtin(:length, [nil])`,
   `string_predicate(_, nil, _, _)`/`string_predicate(_, _, nil, _)`, and
   `coalesce`'s `Enum.find` all checked directly in source and confirmed
   against R-Co's stated semantics. Tests at lines 622-639 assert
   `length(null) -> null`, `contains(null, "x") -> null` (both argument
   positions independently tested), `coalesce(null, null, 3) -> 3`.

5. **AC5 (non-string type errors, not coerced)** -- every `apply_builtin`
   clause has a final catch-all `{:error, {:eval_error, {:type_mismatch, ...}}}`
   clause for a non-binary argument (e.g. `apply_builtin(:length, [s])` falls
   through to the error clause for any non-nil, non-binary `s` -- no
   `to_string`/coercion anywhere in the call graph). Tests at lines 650-660
   confirm `length(42)`, `lower(true)`, `contains(1, "x")` all error.

6. **AC6 (ASCII-only casing, stated + tested)** -- moduledoc section
   "REQ-198: 8 pure builtin functions, ASCII-only case conversion (AC6)"
   (expr.ex L57-73) explicitly states the decision, names the exact R-Co
   divergence risk (`String.downcase/1`'s Unicode default vs `:ascii` mode),
   and gives the concrete "café"/"CAFÉ" example that the module's own tests
   use. `apply_builtin(:lower, ...)`/`(:upper, ...)` genuinely call
   `String.downcase(s, :ascii)`/`String.upcase(s, :ascii)`, not the Unicode
   default. Tests at lines 673-677 assert `lower("CAFÉ")` leaves `É`
   unchanged and `upper("café")` leaves `é` unchanged -- run and confirmed
   passing (see test run below).

7. **AC7 (now/date_add/date_diff absent)** -- grepped the real file myself
   for `DateTime\|System\.os_time\|System\.system_time`: the only match is
   inside the moduledoc's own quoted grep-command string (a doc example, not
   a call) -- zero actual clock reads. `now`, `date_add`, `date_diff` do not
   appear anywhere in `@builtin_function_names`, `identifier_token/1`,
   `identifier_token_kv/1`, or `apply_builtin/2`'s clauses.

8. **AC8 (purity grep zero matches)** -- ran the moduledoc's own documented
   grep command against the real file myself:
   `grep -n "Repo\.\|Logger\.\|DateTime\.\|System\.os_time\|System\.system_time\|HTTPoison\|Req\.\|File\.\|:rand\.\|:crypto\." lib/letflow/engine/expr.ex`
   -- only match is the moduledoc's own quoted copy of this same grep command
   (a documentation string, not executable code); zero real matches in the
   module's actual logic. Confirmed independently, not by reading the design
   doc's claim.

9. **AC9 (`@unsupported_call_markers` unweakened)** -- ran
   `git diff main...HEAD -- lib/letflow/engine/expr.ex` and separately
   `git show main:lib/letflow/engine/expr.ex | grep -n "@unsupported_call_markers" -A 20`:
   the 17-entry marker list (`has(`, `matches(`, `all(`, `exists_one(`,
   `exists(`, `int(`, `uint(`, `double(`, `string(`, `bool(`, `bytes(`,
   `duration(`, `timestamp(`, `size(`, `map(`, `map{`, `filter(`) is
   byte-identical between `main` and this branch -- the diff over that
   region is empty. Confirmed `contains(` and `startsWith(` do not collide
   with any existing marker prefix (none of the 17 markers is a prefix of
   either new name). Test at lines 852-878 iterates the full list (a local
   copy embedded in the test, matching the module's actual list) and asserts
   each is still rejected.

10. **AC10 (EE-05 catch-false on wrong arity)** -- `evaluate_condition/2`'s
    `with` chain (L1472-1479) collapses any eval-error (including
    `{:wrong_arity, ...}` from `check_arity/2`) to `false` via its uniform
    `else -> false` clause; no separate mechanism. Tests at lines 886-894
    confirm `evaluate_condition("length() == 0", %{}) == false` and
    `evaluate_condition("coalesce()", %{}) == false` -- both run and passed.

11. **AC11 (mix test / mix compile clean)** -- ran myself, real output:
    - `mix test test/letflow/engine/expr_test.exs test/letflow/engine/transition_test.exs`
      -> `Result: 160 passed (1 property, 159 tests)`, 0 failures.
    - `mix compile --warnings-as-errors --force` -> `Compiling 154 files
      (.ex)` / `Generated letflow app`, clean, no warnings.
    - `mix format --check-formatted` on the 3 touched files -> exit 0.
    - Re-ran the FULL suite myself via `scripts/test_parallel.sh` (N=8,
      foreground/blocking, not backgrounded): `combined: 2711 tests,
      6 properties, 2 failures (2715/2717 passed)` -- identical shape to
      TEST-RUNNER's own run. Inspected the partition-7 log directly myself
      (not just trusting the summary line): both failures are
      `Mix.Tasks.Letflow.CheckToolchainTest`, both `** (ErlangError) Erlang
      error: :enoent` from `System.cmd("rustc", ["--version"], ...)` at
      `test/mix/tasks/letflow_check_toolchain_test.exs:69`. Independently
      confirmed `rustc` is genuinely absent from this environment
      (`which rustc` empty, `rustc --version` -> "command not found").
      Confirmed via `git diff main...HEAD --stat` (re-run myself) that this
      branch's diff touches only `lib/letflow/engine/expr.ex`,
      `test/letflow/engine/expr_test.exs`, the REQ-198 design doc, and
      status/handoff bookkeeping files -- `test/mix/tasks/letflow_check_toolchain_test.exs`
      is not in the diff at all. The 2 failures are the documented
      environment-caused baseline, not a regression from this change.

## Conclusion

All 11 REQ-198 acceptance criteria are genuinely satisfied by the real
shipped code and a real, independently-executed test run. Routing forward
to DOC-UPDATER via `handoffs/WF02-REQ198-20260830/step-06-doc-updater.json`.
