# Fix design: ISS-0046 — struct-update type-inference warnings in `transition.ex`

**Run:** WF03-ISS0046-20260818
**Workflow step:** WF-03 Step 2 (fix design), following ISSUE-FIXER's Step 1 diagnosis in
`handoffs/WF03-ISS0046-20260818/step-01-diagnose.json`.
**Produced by:** ISSUE-FIXER, acting as CODE-DESIGNER per this run's explicit task
instruction, under the sizing rule in `docs/agents/ORCHESTRATOR.md` §10. See §0 below for
why this is in scope for that exception. This document contains no `.ex`/`.exs` code
blocks carrying real function bodies — line-range instructions and literal
before/after text only, per this role's constraint (the "after" snippets shown are
single-line parameter-list edits, not new logic).

## 0. Sizing-rule justification for ISSUE-FIXER acting as both CODE-DESIGNER and
   CODE-DESIGN-VALIDATOR

Checked against `docs/agents/ORCHESTRATOR.md` §10's six-point checklist, applied here to
the *fix* rather than to ORCH's own direct-action case (this run's task explicitly
authorizes reusing this checklist for the design/design-validator merge decision):

1. **Exactly one file** — yes: `lib/letflow/engine/transition.ex` only.
2. **No new public function, module, or `@spec`** — yes: the fix adds a struct pattern
   match to the existing parameter list of 3 already-existing **private** functions
   (`dispatch_start/4`, `dispatch_end/3`, `dispatch_human_task/3`). No new function, no
   new module, no new `@spec` (none of the three carries a `@spec` today, and none is
   added by this fix — see §4's note on why not).
3. **No migration** — yes, none touched.
4. **Does not touch a supervision-tree file** — yes, `transition.ex` is a pure,
   `Repo`-free, `GenServer`-free module (design doc `lib/letflow/design/
   req044-transition-kernel.md` §8's purity contract, unchanged by this fix).
5. **Does not touch a tenant-data path** — yes, confirmed: SECURITY-REVIEWER's own scope
   test (no migration, no API route, no secrets, no response-shaping code) will still be
   run as a real gate in Step 3 rather than assumed here, but the design itself touches
   nothing in that category.
6. **Changes no behaviour a test asserts** — yes: adding a struct pattern match to a
   parameter that, in every real call path through `transition/3` → `dispatch_node/4`,
   already always receives a well-formed `%InstanceState{}`/`%Token{}` value changes
   nothing about what any of the three functions return for any input the existing test
   suite constructs. `test/letflow/engine/transition_test.exs`'s expected values are
   untouched (verified by inspection here; TEST-RUNNER re-confirms empirically in Step 4).

All six pass, so this design is written and self-validated by ISSUE-FIXER in one pass
rather than routed to a separate CODE-DESIGNER/CODE-DESIGN-VALIDATOR pair, per the
explicit instruction in this run's task. Both roles' checks are still performed in full
below (§5 is the design-validator pass) rather than skipped.

## 1. Root cause (carried forward from ISSUE-FIXER's Step 1, restated for traceability)

`mix compile --warnings-as-errors` fails with 3 warnings, all in `transition.ex`, all
"a struct for `<Struct>` is expected on struct update ... but got type: `dynamic(...)`
... you must also pattern match on `%<Struct>{}`":

| # | Function | Line | Struct-update expression | Struct warned about |
|---|---|---|---|---|
| 1 | `dispatch_start/4` | 218 | `%Token{token \| node_id: edge.target}` | `Letflow.Engine.Token` |
| 2 | `dispatch_end/3` | 235 | `%InstanceState{instance_state \| tokens: remaining_tokens, status: new_status}` | `Letflow.Engine.InstanceState` |
| 3 | `dispatch_human_task/3` | 246 | `%InstanceState{instance_state \| pending_task_nodes: new_pending}` | `Letflow.Engine.InstanceState` |

**Correction against ISS-0046's own filed hypothesis** (already flagged in the Step 1
diagnosis, restated here since it drives this design): ISS-0046 attributed all 3 warnings
to `InstanceState` and to `dispatch_node/4`'s catch-all clause never pattern-matching
`instance_state`/`token`. Neither part is accurate. Warning #1 is actually about `Token`,
not `InstanceState`. And the actual mechanism is one call-level below `dispatch_node/4`:
`transition/3` itself (line 144) already pattern-matches `%InstanceState{} = instance_state`
in its own head, so `instance_state` **is** narrowed by the time it reaches
`dispatch_node/4`. The narrowing is lost when `dispatch_node/4` (whose own `@spec` types
its parameters as `InstanceState.t()`/`Token.t()` but whose clause heads bind
`instance_state`/`token` as bare variables) hands off to `dispatch_start/4`,
`dispatch_end/3`, and `dispatch_human_task/3` — three private functions with **no `@spec`
of their own** and no struct pattern match in their own parameter lists. Elixir 1.20's
type checker (re)infers each function's parameter types from that function's own
head/body, not from the caller's already-narrowed type; a `@spec` declaration alone does
not narrow a struct-update's subject type (empirically confirmed in Step 1 via a
throwaway two-variant test in `elixirc`, cleaned up after — a `@spec`-only version still
warned, a pattern-match version compiled clean).

Fix shape: add an explicit struct pattern match to each of the three functions' own
parameter lists, matching the idiom `dispatch_node/4`'s own clauses already use for their
4th (`node`) parameter (e.g. `%Node{node_type: :START} = node`).

## 2. Edit — `lib/letflow/engine/transition.ex`

All line numbers below are from the file's current state on branch
`feature/WF03-ISS0046-20260818` (read in full by this agent before writing this design).

### 2a. `dispatch_start/4` — line 212

Current text (verbatim, line 212):

```
  defp dispatch_start(definition_snapshot, instance_state, token, node) do
```

New text:

```
  defp dispatch_start(definition_snapshot, %InstanceState{} = instance_state, %Token{} = token, node) do
```

**Correction made during implementation (Step 3), recorded here rather than left
silently inconsistent with what was actually built:** this design originally specified
only `%Token{} = token` for this function, reasoning that the compiler's Step-1
reproduction showed only 1 warning inside `dispatch_start/4` (on the `Token` update at
line 218) and none on the `InstanceState` update at line 219 (then-line-220 after the
`%Token{}` edit). Applying only the `%Token{} = token` change and re-running
`rm -rf _build/dev/lib/letflow && mix compile --warnings-as-errors` surfaced a **4th
warning**, not present in Step 1's original 3-warning reproduction: `instance_state` at
line 220 (`%InstanceState{instance_state | tokens: new_tokens}`) now warned with "type:
dynamic(%{..., tokens: term()})... from: replace_token(instance_state.tokens,
new_token)". The most likely explanation, not independently re-verified further since
the empirical fix is what matters: Elixir 1.20's type checker did not previously reach
far enough into this function's inference to report a second, independent struct-update
issue in the same function body before Step 1's original run — once the `Token` issue
was resolved, the checker's analysis proceeded further and surfaced the pre-existing
`InstanceState` issue that had been present all along but not yet reported. Whatever the
precise mechanism, the empirical fact is: `%InstanceState{} = instance_state` is also
required here, alongside `%Token{} = token`, for a clean compile. Both are now in the
parameter list. ELIXIR-DEV/TEST-RUNNER should treat this design's original 3-warning
count as Step 1's honestly-reported starting point, not as a promise that no further
warning could be uncovered by fixing the first one — always re-run the compile gate
after each incremental edit rather than assuming a fix is complete once its
originally-targeted warning is gone.

**No behavior change:** every real caller reaches `dispatch_start/4` only via
`dispatch_node/4`'s `:START` clause, which itself receives `instance_state` from
`transition/3`'s own already-narrowed `%InstanceState{} = instance_state` head match, and
`token` from `transition/3`'s `find_token/2` lookup over
`instance_state.tokens :: [Token.t()]` — both values flowing into this parameter list are
always already well-formed structs at runtime. The pattern matches assert facts already
true of every real call, not a new restriction.

### 2b. `dispatch_end/3` — line 230

Current text (verbatim, line 230):

```
  defp dispatch_end(instance_state, token, _node) do
```

New text:

```
  defp dispatch_end(%InstanceState{} = instance_state, token, _node) do
```

**Why `instance_state`, not `token`, here:** the only struct-update warning inside
`dispatch_end/3`'s body (line 235) is on `instance_state`. `token` is only read via
`token.token_id` (a field access, not a struct update) at line 230 — Elixir's type
checker does not require struct-pattern narrowing for a plain field read the way it does
for `%Struct{var | ...}` update syntax, and no warning was emitted for `token` in this
function in Step 1's reproduction, so `token` is left as-is.

**No behavior change:** every real caller reaches `dispatch_end/3` only via
`dispatch_node/4`'s `:END` clause, whose own `instance_state` parameter is itself always
a `%InstanceState{}` at runtime (narrowed once already at `transition/3`'s head, per §1).
Same reasoning as 2a — the pattern match documents an already-true runtime fact.

### 2c. `dispatch_human_task/3` — line 244

Current text (verbatim, line 244):

```
  defp dispatch_human_task(instance_state, token, _node) do
```

New text:

```
  defp dispatch_human_task(%InstanceState{} = instance_state, token, _node) do
```

**Why `instance_state`, not `token`, here:** the only struct-update warning inside
`dispatch_human_task/3`'s body (line 246) is on `instance_state`. `token` itself is never
read at all inside this function's body except to be appended whole
(`instance_state.pending_task_nodes ++ [token]`) — no field access, no struct update — so
no warning is emitted for it and no pattern match is needed for `token` here either.

**No behavior change:** same reasoning as 2a/2b — every real caller's `instance_state` is
already a `%InstanceState{}` at runtime.

## 3. What this fix does NOT touch (explicit negative scope)

- `dispatch_node/4` itself (lines 151–197) — its own clause heads and its own `@spec` are
  unchanged. ISS-0046's filed hypothesis assumed the fix needed to touch this function's
  catch-all clause; per §1's corrected root cause, the narrowing loss happens one call
  level below it, so `dispatch_node/4` needs no edit.
- `dispatch_exclusive_gateway/4`, `dispatch_parallel_gateway/4` (lines ~331, ~356 per the
  design doc's section numbering) — these are stub functions that never perform a
  struct-update; they already have their own `@spec` and produce no warning.
- `find_token/2`, `find_node/2`, `replace_token/2` (the module's own helper functions) —
  none perform a struct-update against a bare/unnarrowed variable; `find_node/2` and
  `replace_token/2` already carry their own `@spec`; `find_token/2` has none but is not
  the site of any warning (it only returns a value, it does not itself construct a
  struct-update expression).
- `lib/letflow/engine/instance_state.ex`, `lib/letflow/engine/token.ex` — the struct
  definitions themselves are correct and unchanged; the defect is in how the transition
  kernel's dispatch functions consume these structs, not in how they are defined.
- No new `@spec` is added to `dispatch_start/4`, `dispatch_end/3`, or
  `dispatch_human_task/3` by this fix — adding one was considered and rejected, since
  Step 1's empirical test showed a `@spec` alone does not fix the warning (only the
  pattern match does), and `dispatch_node/4`'s own existing comment ("Every clause below
  is a specialization of this one `@spec` — no per-clause `@spec` is separately
  declared") already establishes this module's convention of not giving every private
  helper its own redundant `@spec`. Adding one to only these three, and not to
  `dispatch_start/4`'s sibling stub functions, would be inconsistent gold-plating beyond
  what fixes the actual warning.

## 4. Idiom consistency check

`dispatch_node/4`'s own 5 non-catch-all clauses already pattern-match their `node`
parameter against `%Node{node_type: :X} = node` (or, for the catch-all, `%Node{node_type:
node_type, id: node_id}`). This fix applies the exact same idiom — an explicit struct
pattern match on the parameter a function's own body performs a struct-update against —
to the three private functions one level down. No new pattern is introduced to the
module; this is the module's own established idiom applied one call-level deeper than it
currently reaches.

## 5. Design-validator pass (CODE-DESIGN-VALIDATOR checks, self-run per §0)

**Note on this section's own currency:** this §5 pass was originally run against the
design's pre-implementation state (3 warnings, 3 edits). §2a records a correction found
empirically during Step 3 implementation (a 4th warning surfaced only after the first
edit was applied and the compile gate re-run) — that correction was re-verified directly
against a real `mix compile --warnings-as-errors` exit-0 run, which is a strictly
stronger check than this section's original static cross-reference against Step 1's
warning list. The design-validator checks below still hold for the corrected 4-edit
version; re-stated per point rather than left referring only to the original 3.

- **Covers every warning:** yes, re-confirmed against the actual post-fix compile run
  (not just the original static list) — `rm -rf _build/dev/lib/letflow && mix compile
  --warnings-as-errors` exits 0 with zero warnings after all edits in §2 (2a now
  contains 2 pattern matches, fixing 2 warnings; 2b and 2c fix 1 each — 4 total,
  matching the corrected warning count discovered during implementation).
- **No implementation code beyond the minimal signature-line edit:** yes — each edit is a
  one-line parameter-list change; no function body logic is altered.
- **Unambiguous enough to build from:** yes — exact current line numbers, exact current
  text, exact new text given for all 3 edits; no open question left for ELIXIR-DEV to
  resolve.
- **No scope creep:** yes — §3 explicitly enumerates what is not touched, addressing the
  temptation (from ISS-0046's own filed hypothesis) to also edit `dispatch_node/4`.
- **Consistent with the module's own established idiom:** yes — §4.
- **Matches `req044-transition-kernel.md`'s design, does not contradict it:** yes — that
  design doc's §6 dispatch table and §6.1–§6.3 per-case behavior descriptions are
  unaffected; this fix only adds type-narrowing, changing no documented behavior.

## 6. Regression-test guidance for TEST-DESIGNER (Step 4)

Per WF-03 Step 4, the regression test must be shown to fail against pre-fix code and pass
post-fix. Since this fix's defect is a **compile-time** gate failure (not a runtime
assertion), TEST-DESIGNER's "test" for this fix is the compile gate itself, run at both
commits — not a new `ExUnit` test file:

- Confirm, on the pre-fix commit (`git stash`/checkout of `transition.ex` before this
  fix's edits, or the commit immediately prior to the fix commit), that
  `rm -rf _build/dev/lib/letflow && mix compile --warnings-as-errors` fails with exactly
  the 3 warnings in §1's table — this is the "fail-first" proof.
- Confirm, on the post-fix commit, that the same clean-rebuild command exits 0 with no
  warnings.
- Confirm the full suite (`mix test`) still passes with the same test count as before the
  fix (no test added, none removed — this fix touches no test file), proving no behavior
  regressed for any existing test case.
- If TEST-DESIGN-VALIDATOR/TEST-RUNNER prefer an `ExUnit`-level artifact for this class of
  regression (a compile-gate check is unusual for that role's normal "write a failing
  test" framing), a lightweight option: assert directly in
  `test/letflow/engine/transition_test.exs` that `dispatch_start/4`'s Token-typed
  parameter, `dispatch_end/3`'s and `dispatch_human_task/3`'s InstanceState-typed
  parameters, all still produce correct `{:ok, %InstanceState{}, []}` results for the
  existing `:START`/`:END`/`:HUMAN_TASK` test cases — this does not itself reproduce the
  *compile-time* warning (ExUnit doesn't run `--warnings-as-errors`), so it is
  supplementary at best; the compile-gate check above is the actual fail-then-pass proof
  for this specific defect class and should not be skipped in favor of an ExUnit-only
  substitute.

## 7. Open questions

None. All 3 edits are fully specified above; no unresolved ambiguity is left for
ELIXIR-DEV/TEST-DESIGNER to guess at.
