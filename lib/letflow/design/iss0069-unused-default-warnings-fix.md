# ISS-0069: Remove unused default values in test helpers (full sweep + gate)

## Rework context

Prior version covered only 4 instances, found incrementally; scope grew to
9 the same way. TEST-DESIGN-VALIDATOR's direction: one full repo-wide
sweep, not incremental discovery, plus close the gate gap that let this
class go unenforced.

## Diagnosis (pattern, confirmed across all 9 known instances)

`mix test --warnings-as-errors` emits "default values for the optional
arguments ... are never used" for `defp` heads like `defp
helper_name(arg \\ <literal>)` (e.g. `unique_idempotency_key(prefix \\
"...")`, `give_up_context(instance_id, overrides \\ %{})`) where every call
site already passes the argument explicitly, making the `\\` default dead
code. Same mechanical pattern as the already-resolved ISS-0044.

## Part 1 — Full repo-wide sweep (ELIXIR-DEV)

1. Enumerate every remaining instance in one pass — do not rely on the
   previously-found list of 9:
   ```
   mix test --warnings-as-errors 2>&1 | grep -B3 "default values"
   ```
   (or equivalent). Capture the full `file:line` + function-head list before
   fixing anything, so the sweep is auditable.
2. For each instance, confirm via reading the surrounding test file that
   every call site already supplies the argument explicitly — true for all
   9 instances diagnosed so far.
3. Fix mechanically, purely deletive, no call-site changes: remove the
   ` \\ <literal>` from the `defp` head only. Function body unchanged.
   - Before: `defp unique_idempotency_key(prefix \\ "reqNNN-idk") do`
   - After:  `defp unique_idempotency_key(prefix) do`
   - Before: `defp give_up_context(instance_id, overrides \\ %{}) do`
   - After:  `defp give_up_context(instance_id, overrides) do`
4. **Escalation**: if any instance is found where a call site DOES rely on
   the default (unlike every instance so far) — STOP for that instance. Do
   not delete the default and do not paper over it at the call site.
   Escalate to ISSUE-FIXER/CODE-DESIGNER for fresh diagnosis of that case
   before continuing the sweep.
5. Re-run the sweep command from step 1 after fixing found instances, to
   confirm zero remain (guards against under-counting from dedup across
   recompiles).

## Part 2 — Close the gate gap (ELIXIR-DEV)

**Only after Part 1 is complete and step 5 confirms zero remaining
instances.** Doing this first would fail `mix letflow.check` immediately.

In `mix.exs`, `aliases/0` currently has:
```
"letflow.check": ["format --check-formatted", "compile --warnings-as-errors", "test"]
```
Change the `test` step of `"letflow.check"` only, to run with
`--warnings-as-errors`, so this class (and recurrences) fails the gate going
forward:
```
"letflow.check": ["format --check-formatted", "compile --warnings-as-errors", "test --warnings-as-errors"]
```
Leave the plain `test` alias unchanged — `mix test` alone stays lenient for
local iteration; only the `letflow.check` composition becomes strict.

## Invariants

- No change to any test's assertions/behavior — warning-only cleanup.
- No call-site changes anywhere, except the escalation case (Part 1 step 4).
- `mix.exs` changes limited to the single `"letflow.check"` alias line.

## Out of scope (file as separate issue(s) after this run — do not fix here)

Different class, found by ISSUE-FIXER alongside this one: `ExUnit.Case.
register_test/4 deprecated`, an unused `tenant` variable, a `redefining
module` warning from migration recompilation. ORCH files these separately.

## Verification (ELIXIR-DEV / TEST-RUNNER)

1. `mix test --warnings-as-errors` — exit 0, zero warnings, same test count
   as before (5 properties, 1029 tests, 0 failures) unless the sweep itself
   changes that count for a documented reason.
2. `mix letflow.check` — full end-to-end pass, exit 0.
3. Diff review: confirm no `defp` arity change breaks a call site (compile
   step already covers this; call it out in ELIXIR-DEV self-review).

## Open questions

None — sweep is mechanical/self-verifying (re-run in Part 1 step 5 is the
completeness check); escalation path (Part 1 step 4) covers the one case
this design can't pre-resolve, not seen in any of the 9 instances so far.
