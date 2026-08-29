# TEST-DESIGNER notes — REQ-181 (`test/letflow/webhooks_test.exs`)

## Resume context

This step resumed after a real implementation bug was found mid-coverage-writing:
`Letflow.Webhooks.Subscription.insert_changeset/2`'s `cast/3` whitelist omitted
`:created_at`, so `create/2`'s insert failed with a Postgres `not_null_violation`. Fixed
by ELIXIR-DEV in commit `3046e44` (adds `:created_at` to `insert_changeset/2`'s
`cast/2`/`validate_required/2`; `lib/letflow/design/req181-webhooks-core.md` §2.4
corrected to match) and re-approved by REVIEWER at commit `5337911`. This step verifies
test coverage against that fix.

## Final test run

```
mix test test/letflow/webhooks_test.exs
Finished in 9.5 seconds (0.00s async, 9.5s sync)
Result: 14 passed
```

0 failures. All 14 tests green against the fixed `create/2`/`insert_changeset/2`.

## Mutation testing (see `test/specs/REQ-181.md`'s "Mutation testing" section for full detail)

Three mutations applied to `lib/letflow/webhooks.ex`, each run, confirmed caught (test
failures), then reverted individually:

1. Skip the hash step (`secret_hash: secret_hash` -> `secret_hash: plaintext`) —
   **caught**, 12/14 passed (2 AC2 tests failed).
2. Flip the `%Subscription{status: :ACTIVE}, :PAUSED` branch in
   `apply_status_update/3` to write `%{status: :ACTIVE, paused_at: nil}` instead of
   pausing — **caught**, 11/14 passed (3 AC3 tests failed).
3. Make `delete/2` fabricate `{:ok, %Subscription{id: id}}` on a second delete instead
   of `{:error, :not_found}` — **caught**, 13/14 passed (1 AC5 test failed).

A fourth mutation was also tried and **not caught**: removing `lock("FOR UPDATE")` from
`fetch_and_lock_subscription/3` (the row lock backing `update/3`'s transaction) — all 14
tests still passed unchanged. This is a real, disclosed coverage gap: this suite has no
concurrent-access test exercising the actual purpose of that lock (preventing a
lost-update race under concurrent `update/3` callers). Recorded explicitly in
`test/specs/REQ-181.md` rather than silently dropped from the reported mutation set —
flagged for TEST-DESIGN-VALIDATOR to weigh (note: `Letflow.Dlq.retry/2`/`discard/2`,
which established this same lock-then-check idiom, appears to have the identical gap in
its own test file, so this is not a newly-introduced double standard specific to
REQ-181).

## Revert verification

```
git diff 5337911 -- lib/letflow/webhooks.ex lib/letflow/webhooks/subscription.ex
```
produced no output (clean, matches the REVIEWER-approved commit) after all four
mutations were applied and reverted, confirming no mutation leaked into the committed
diff.

## Artifacts produced this step

- `test/letflow/webhooks_test.exs` (14 tests, AC1-AC6 covered)
- `test/specs/REQ-181.md` (criterion -> test-case mapping, mutation-testing record)

Both committed at `acb9177` and pushed to `feature/WF02-REQ181-20260829`.
