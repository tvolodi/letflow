# ISS-0069: Remove unused default values in test helpers (full sweep + gate)

## Rework context (round 1)

Prior version covered only 4 instances, found incrementally; scope grew to
9 the same way. TEST-DESIGN-VALIDATOR's direction: one full repo-wide
sweep, not incremental discovery, plus close the gate gap that let this
class go unenforced.

## Rework context (round 2 — this revision)

Part 1 (the full sweep) is confirmed complete and correct as committed
(commit e95746e) — zero "default values" warnings remain, 1029 tests
passing. **Not touched by this revision.**

Part 2 as previously specified was wrong. It changed `letflow.check`'s
`test` step to `test --warnings-as-errors` and its own Verification
section then claimed `mix letflow.check` would exit 0 end-to-end. ELIXIR-DEV
actually ran both `mix test --warnings-as-errors` and `mix letflow.check`
on this branch (Part 1 + old Part 2 applied) and both exit 1 — not because
of anything new, but because `docs/issues/ISS-0044.yaml` (already
`status: resolved`) had already independently diagnosed two *other*
warning classes as **permanently deferred, not fixed**, both of which only
surface under `mix test` (never under `mix compile --warnings-as-errors`,
which ISS-0044 confirmed and re-confirmed stays clean regardless):

- **ISS-0044 Group 1**: `ExUnit.Case.register_test/4 is deprecated`, once
  per StreamData `property` block (5 instances: `test/letflow/oidc/claim_mapping_property_test.exs`
  x2, `test/letflow/engine/transition_test.exs`, `test/letflow/process_instance_test.exs`,
  `test/letflow/parallel_approval_test.exs`). Originates entirely inside
  `stream_data` 0.6.0's own vendored `property` macro
  (`deps/stream_data/lib/ex_unit_properties.ex`), not any Letflow file.
  ISS-0044 traced the fix to a `stream_data` 0.6.0 → up to 1.4.0 bump (a
  4-major-version jump, register_test/6 and generator-API compatibility
  unverified) — explicitly scoped as its own future requirement.
- **ISS-0044 Group 3**: `redefining module Letflow.Repo.Migrations.CreateEventTypeRegistry`.
  A deliberate, documented mechanism: `test/letflow/event_store/registry_test.exs`'s
  `Code.require_file/1` workaround (needed because `priv/repo/migrations/*.exs`
  is outside `:test`'s `elixirc_paths`) racing `mix ecto.migrate --quiet`'s own
  earlier module load, both invoked by the `test` alias. ISS-0044 confirmed
  this can never fire under `mix compile --warnings-as-errors` (the migration
  dir isn't compiled by that command at all) but fires every run under
  `mix test`.

Neither group is this issue's to fix — both are already-diagnosed,
already-deferred, out of scope per this doc's own "Out of scope" section
(and per ISS-0044's resolution note). Blanket `test --warnings-as-errors`
in the `letflow.check` composition fails on these two pre-existing classes
regardless of Part 1's correctness, so the old Part 2's "exit 0" claim was
false and unachievable without also solving the stream_data bump — which
is explicitly not this issue's scope.

**Revision below replaces Part 2 with a targeted gate**: catch recurrences
of *this issue's specific warning class* (unused default args in test
helpers) without blanket-failing on the two unrelated, already-deferred
classes. Part 1, Invariants (except the `mix.exs`-scope line, updated
below), and the sweep methodology are unchanged.

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

## Part 2 (revised) — Close the gate gap with a targeted check, not blanket `--warnings-as-errors`

**Only after Part 1 is complete and step 5 confirms zero remaining
instances.**

**Step 1 — revert the blanket flag.** `mix.exs`'s `"letflow.check"` alias
currently reads (as committed by the round-1 Part 2):
```
"letflow.check": ["format --check-formatted", "compile --warnings-as-errors", "test --warnings-as-errors"]
```
Change the third step away from `"test --warnings-as-errors"` — replace it
with the new task from Step 2 below, `"letflow.check.test"`. Leave the
`"compile --warnings-as-errors"` step exactly as-is (ISS-0044 already
confirmed this step is, and stays, fully clean regardless of Groups 1/3 —
it never touches `test/` or `priv/repo/migrations/`).

The plain `test` alias (`test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]`)
is untouched by this design, same as before — it stays lenient for local
iteration.

**Step 2 — add a new custom Mix task, `mix letflow.check.test`.**
New file `lib/mix/tasks/letflow.check.test.ex`, module `Mix.Tasks.Letflow.Check.Test`.
Purpose: run the test suite exactly as the existing `test` alias does, but
gate specifically on the "unused default value in an optional argument"
warning class (this issue's own class), while explicitly tolerating the two
warning classes ISS-0044 already diagnosed as permanently deferred (and any
other warning class not this one — e.g. the separately-out-of-scope unused
`tenant` variable).

- **Input**: none meaningful (invoked with no args from the `letflow.check`
  alias; `run/1` accepts and ignores the arg list Mix passes, matching the
  standard `Mix.Task` `run/1` shape).
- **Behavior**:
  1. Shell out to run the equivalent of the `test` alias's own composition
     (`ecto.create --quiet`, `ecto.migrate --quiet`, `test`) as a subprocess,
     streaming its combined stdout+stderr live to the invoking terminal (CI
     / agent output must not be hidden or buffered away — a developer or
     agent reading `mix letflow.check` output still sees every warning,
     including the deferred ones, same as today).
  2. Capture that combined output while streaming it, and capture the
     subprocess's own exit code.
  3. After the subprocess exits, scan the captured output for the literal,
     stable substring `"default values for the optional arguments"` — this
     is the fixed prefix of the compiler warning for this exact class, per
     Part 1's own sweep grep and ISS-0044's Group 2 diagnosis. Case-sensitive
     exact substring match; no regex needed since the class always starts
     with this exact phrase.
  4. Do **not** scan for or react to any other warning text — in particular
     never match on `"register_test/4 is deprecated"` or `"redefining
     module"` (ISS-0044 Groups 1/3) or `"variable \"tenant\" is unused"`
     (separately out of scope) — those remain visible in the streamed
     output but never fail this task.
- **Exit-code contract**:
  - Exit `0` only if: the subprocess exited `0` (no real test
    failures/errors) **and** the target substring is absent from the
    captured output.
  - Exit `1` if the subprocess exited nonzero (real test failure/error) —
    regardless of the substring check.
  - Exit `1` if the subprocess exited `0` but the target substring is
    present anywhere in the captured output — this is this issue's own
    warning class recurring. Print one diagnostic line identifying that a
    "default values for the optional arguments" warning was found (grep the
    captured output for the matching line(s) and print them) so the failure
    is immediately actionable, not just "check failed".

**Step 3 — update the alias.**
```
"letflow.check": ["format --check-formatted", "compile --warnings-as-errors", "letflow.check.test"]
```

## Invariants

- No change to any test's assertions/behavior — warning-only cleanup.
- No call-site changes anywhere, except the escalation case (Part 1 step 4).
- `mix.exs` changes limited to the single `"letflow.check"` alias line's
  third step (`"test --warnings-as-errors"` → `"letflow.check.test"`). The
  `"compile --warnings-as-errors"` step and the plain `test` alias are
  unchanged.
- Exactly one new file: `lib/mix/tasks/letflow.check.test.ex`. No other
  existing task or alias is touched.
- The new task must never suppress or hide any warning's text from the
  streamed output — it changes only which warnings affect the *exit code*,
  not what a human/agent reading the output can see.

## Out of scope (file as separate issue(s) after this run — do not fix here)

Different classes, already independently diagnosed and permanently deferred
by `docs/issues/ISS-0044.yaml` (`status: resolved`), not this issue's to
fix and not something the new gate should fail on:
- `ExUnit.Case.register_test/4 is deprecated` (ISS-0044 Group 1) — blocked
  on a `stream_data` 0.6.0 → up to 1.4.0 version bump, its own scoped
  future requirement.
- `redefining module ... CreateEventTypeRegistry` (ISS-0044 Group 3) — a
  deliberate, documented test-workaround mechanism, non-blocking by design,
  no fix needed or possible without removing the workaround it depends on.

Also out of scope, found by ISSUE-FIXER alongside this one and unrelated to
either ISS-0044 or this issue's own class: one unused `tenant` variable
warning. ORCH files these separately if not already covered by an open
issue.

**This "Out of scope" list is the record that ties `letflow.check`'s
permanently-partial warning coverage to a named, already-tracked blocker
(ISS-0044) rather than leaving it silently unexplained** — a future
reader of `mix.exs`'s `letflow.check.test` task or this design doc has a
concrete reference for why the gate is deliberately narrower than "zero
warnings of any kind."

## Verification (ELIXIR-DEV / TEST-RUNNER)

1. `mix test` (plain, no flag) — exit 0, same test count as before (5
   properties, 1029 tests, 0 failures) unless the sweep itself changes that
   count for a documented reason. Zero "default values for the optional
   arguments" warnings. Confirm the following residual warnings are present
   and are exactly the expected, already-deferred/out-of-scope set — their
   presence is correct, not a regression: 5x `register_test/4` deprecation
   (ISS-0044 Group 1), 1x `redefining module ... CreateEventTypeRegistry`
   (ISS-0044 Group 3), 1x unused `tenant` variable (separately out of
   scope). Any *other* warning text appearing here that isn't one of these
   three known classes is a real regression and must block this run.
2. `mix letflow.check` — full end-to-end pass, **exit 0**. This is now
   achievable and must actually be run and confirmed, not assumed: the
   `format` and `compile --warnings-as-errors` steps are unaffected and
   stay clean; the new `letflow.check.test` step exits 0 per its own
   contract (real subprocess exit 0, and the "default values for the
   optional arguments" substring absent) even though the underlying test
   run still emits the three known-deferred/out-of-scope warning classes
   from item 1 above — those no longer fail the gate, by design.
3. **Negative-control check (proves the gate isn't a no-op)**: locally
   (uncommitted) reintroduce a `\\ <literal>` default on a `defp` test
   helper whose only call site already passes the argument explicitly (any
   throwaway example is fine), re-run `mix letflow.check`, and confirm it
   now exits 1 with the diagnostic line from Step 2/point 4 above
   identifying the reintroduced warning. Revert the local change before
   finishing — this step verifies the task, it isn't a fix.
4. Diff review: confirm no `defp` arity change from Part 1 breaks a call
   site (the `compile` step already covers this; call it out in
   ELIXIR-DEV's self-review), and confirm `lib/mix/tasks/letflow.check.test.ex`
   matches the behavior/exit-code contract specified in Part 2 above (in
   particular: it must not match on any substring other than "default
   values for the optional arguments").

## Open questions

- The substring match in `letflow.check.test` (`"default values for the
  optional arguments"`) is tied to this Elixir/OTP toolchain's exact
  compiler wording. `docs/migration/decisions/0005-pin-formatting-toolchain.md`
  pins the toolchain version, which mitigates drift risk, but a future
  toolchain bump should re-verify this exact string still matches (or
  update it) rather than silently going warning-blind on this class. Not
  resolved here — flagged for whoever next touches the toolchain pin.
- Sweep completeness (Part 1) is otherwise mechanical/self-verifying
  (re-run in Part 1 step 5 is the completeness check); escalation path
  (Part 1 step 4) covers the one case this design can't pre-resolve, not
  seen in any of the 9 instances so far.
