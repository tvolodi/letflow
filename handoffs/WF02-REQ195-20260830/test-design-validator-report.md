# TEST-DESIGN-VALIDATOR report -- REQ-195 (step 03b)

## Verdict: FAIL

## What was checked

- Read `handoffs/WF02-REQ195-20260830/step-03b-test-design-validator.json`,
  `handoffs/WF02-REQ195-20260830/test-designer-gap-analysis.md`, and REQ-195's full
  entry (all 12 ACs) in `docs/requirements.yaml`.
- Read `test/letflow/audit_test.exs`, `test/letflow/audit_capture_test.exs`,
  `test/letflow/audit_dispositions_test.exs`, and `lib/letflow/audit.ex` in full.
- Re-ran `mix test test/letflow/audit_test.exs test/letflow/audit_capture_test.exs
  test/letflow/audit_dispositions_test.exs` myself: **24 passed**, confirming
  TEST-DESIGNER's quoted number.
- Spot-checked AC6's hash_mismatch/chain_broken distinction directly against
  `audit_test.exs` -- correctly targeted and genuinely distinct (content tamper vs.
  linkage break), as TEST-DESIGNER's gap analysis claimed.
- Confirmed AC7's hand-computed hash test in `audit_dispositions_test.exs` is a
  genuine from-scratch reimplementation of the netstring + sorted-JSON + SHA-256
  canonical form, calling no private function of `Letflow.Audit`, asserted against
  two persisted entries' actual stored `chain_hash` (including the null-`prev_chain_hash`
  first-entry case) -- not a round-trip through the implementation's own logic.
- Confirmed every actor_id-nil disposition test (`Definitions.create/2`/`deprecate/2`/
  `archive/2`, all six `Identity` functions, `Tasks.assign_task/3`,
  `TaskActivation`'s `task.create` site) asserts a genuinely `nil` `actor_id`
  alongside real, field-checked `before_state`/`after_state` content --
  `password_hash`/`token_hash` exclusion confirmed where applicable.
- Confirmed no duplication: `audit_dispositions_test.exs` only adds the AC7
  cross-check and the actor_id-disposition call sites the other two files never
  touch.
- Read `lib/letflow/audit.ex`'s moduledoc in full. AC7 (11-field canonical order,
  the `-1:` sentinel, the microsecond-timestamp representation), AC8 (the
  Elixir-context-boundary decision and the rejected trigger trade-off), and AC10
  (the `lua_script_execution_audit` separation statement) are all genuinely and
  correctly stated. No doc-content gap.

## Mutation testing (mandatory per this task's instructions)

All four mutations were applied directly to shipped code, one at a time, and
reverted immediately after confirming the result; `git status --porcelain lib/
priv/` was confirmed empty after every single revert.

### Mutation 1 -- reverse `do_verify_chain/2`'s check order (REAL GAP FOUND)

Swapped the two `cond` clauses in `lib/letflow/audit.ex`'s `do_verify_chain/2` so
`entry.prev_chain_hash != prev_recomputed_hash` (linkage) is checked **before**
`recomputed != entry.chain_hash` (content recompute), reversing the moduledoc's
stated order.

Result: **all 24 tests still passed.** No test distinguishes which check runs
first, because no test constructs an entry where *both* checks would
independently fail. The one scenario that would expose this -- tampering a
persisted entry's `prev_chain_hash` column directly via raw SQL without also
recomputing that same entry's own `chain_hash` -- is described by name in both
the moduledoc ("Verification recomputes; it does not just check linkage (AC6)")
and in `audit_test.exs`'s own code comment next to the `chain_broken` test
(lines 244-252, explaining why a `prev_chain_hash`-only overwrite would be
`hash_mismatch`, not `chain_broken`), but no test actually performs it. Because
`prev_chain_hash` is itself one of the 11 hashed fields, tampering only that
column breaks the entry's own content hash *and* its linkage to the predecessor
simultaneously -- the existing `hash_mismatch` test only tampers `after_state`
(linkage stays trivially consistent) and the existing `chain_broken` test only
deletes a middle row (the surviving rows' own hash/linkage stay internally
consistent). Given this module's moduledoc explicitly calls the check-order
"deliberately NOT the R-Co behavior it replaces," and this is stated as "the
single most important test in this requirement," an order-reversal that no test
catches is a genuine, load-bearing coverage gap, not a nitpick.

### Mutation 2 -- break the canonical hash form (CAUGHT)

Changed `netstring_optional(nil)` from the documented `-1:` sentinel to the
colliding `0:` (empty-string) encoding in `lib/letflow/audit.ex`.

Result: `mix test test/letflow/audit_dispositions_test.exs` -- **9/10 passed**,
1 failure: the AC7 hand-computed hash test, with a real hash-value mismatch
quoted in the failure output. Confirms this test is a genuine independent
cross-check.

### Mutation 3 -- weaken the DB immutability trigger (CAUGHT)

Changed `audit_entries_immutable()` in
`priv/repo/migrations/20260830020001_create_audit_entries_tenant_scoped.exs`
from `RAISE EXCEPTION 'audit_entries is immutable'` to a no-op
(`RETURN NEW`/`RETURN OLD` depending on `TG_OP`), so UPDATE/DELETE both succeed.

Result: `mix test test/letflow/audit_test.exs` -- **7/9 passed**, both AC1 tests
failed (the raw UPDATE and raw DELETE tests both expected a rejected
`Postgrex.Error` and got a silent success instead).

### Mutation 4 -- break an actor_id-nil disposition (CAUGHT)

Changed `Tasks.assign_task/3`'s audit-recording private function
(`record_task_assign_audit/2` in `lib/letflow/tasks.ex`) from `actor_id: nil` to
`actor_id: updated.id`.

Result: `mix test test/letflow/audit_dispositions_test.exs` -- **9/10 passed**,
1 failure: the `assign_task/3` disposition test, asserting `entry.actor_id ==
nil`.

## Additional real failure found independently of the mutation exercise

`mix compile --warnings-as-errors` is clean. `mix format --check-formatted`
**fails** on `test/letflow/audit_dispositions_test.exs` -- several
`assert {:ok, ...} = LongFunctionCall(...)` lines exceed the formatter's line
length and need the standard multi-line assert form. This is mechanical and
unrelated to the mutation gap, but is a real, currently-failing tool-output
requirement (AC12's "real output" standard, and this project's own format gate).

`mix letflow.lint_handoffs` reports 0 new violations (25 pre-existing,
grandfathered to ISS-0190) -- clean.

## Disposition

FAIL. Two concrete, fixable items routed back to TEST-DESIGNER in
`handoffs/WF02-REQ195-20260830/step-03-test-designer-rework1.json`:

1. Add a test that tampers a persisted entry's `prev_chain_hash` directly (raw
   SQL, immutability trigger bypassed the same way the existing AC6 tests
   already do) while leaving that entry's own `chain_hash` untouched, and
   asserts `{:error, {:hash_mismatch, entry_id}}` (not `chain_broken`) --
   demonstrated to fail against the reversed-check-order mutation above and to
   pass against the real, reverted implementation, with the mutation reverted
   before handoff.
2. Fix the `mix format --check-formatted` failure in
   `test/letflow/audit_dispositions_test.exs`.

Everything else checked in this pass -- AC1-AC5, AC8-AC11's coverage, AC7's
doc half and its independent-computation test half, and the actor_id-nil
disposition tests -- is genuinely complete and correctly targeted, confirmed by
direct reading and by mutations 2-4 all being caught.
