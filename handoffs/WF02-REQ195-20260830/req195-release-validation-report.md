# REQ-195 RELEASE-VALIDATOR report (independent re-verification)

**Date:** 2026-08-30
**Branch:** feature/WF02-REQ195-20260830
**Preceding handoff:** handoffs/WF02-REQ195-20260830/step-05-release-validator.json (TEST-RUNNER rework-1 recheck, PASS_ROUTING_TO_RELEASE_VALIDATOR)

## Verdict: PASS

All 12 acceptance criteria in `docs/requirements.yaml`'s REQ-195 entry were independently
re-derived against the real shipped code and a real, fresh test run -- not against the
history of prior PASSes.

## AC6 -- my own independent trace (the highest-scrutiny item)

Read `lib/letflow/audit.ex`'s `do_verify_chain/2` (lines 271-286) directly:

```elixir
defp do_verify_chain([%Entry{} = entry | rest], prev_recomputed_hash) do
  recomputed = compute_hash(fields_from_entry(entry))

  cond do
    recomputed != entry.chain_hash ->
      {:error, {:hash_mismatch, entry.id}}

    entry.prev_chain_hash != prev_recomputed_hash ->
      {:error, {:chain_broken, entry.id}}

    true ->
      do_verify_chain(rest, recomputed)
  end
end
```

Confirmed the ordering: the hash-recompute check (`recomputed != entry.chain_hash`) is the
first `cond` clause, evaluated and returned on before the `prev_chain_hash` linkage check is
ever reached. `fields_from_entry/1` includes `prev_chain_hash` itself as field 11 of the 11
hashed fields (confirmed against `canonical_string/1`, lines 320-335, and the moduledoc's
"Canonical hashed form" section).

**Traced why the ordering is genuinely load-bearing, not cosmetic**, using the exact scenario
the task specified: a single-column tamper of `prev_chain_hash` alone (leaving `chain_hash`
untouched). Since `prev_chain_hash` is one of the 11 hashed inputs, tampering it alone makes
`recomputed` (built from the *new* `prev_chain_hash`) diverge from the stored `chain_hash`
(built from the *original* `prev_chain_hash`) -- so `recomputed != entry.chain_hash` is TRUE.
Separately, `entry.prev_chain_hash` (now tampered) no longer equals `prev_recomputed_hash`
(the untampered previous entry's real hash) -- so `entry.prev_chain_hash != prev_recomputed_hash`
is ALSO true. Both `cond` branches are true simultaneously for this exact tamper; only clause
*order* decides which error `verify_chain/2` reports. With the shipped order, this reports
`{:error, {:hash_mismatch, entry.id}}`. Had the order been reversed (linkage checked first),
the identical tamper would report `{:error, {:chain_broken, entry.id}}` instead -- the wrong
attribution, and a real regression toward R-Co's own documented defect class (misreporting a
content-adjacent tamper as mere reordering/linkage noise rather than pinpointing the tampered
entry's own content disagreement).

Found `test/letflow/audit_dispositions_test.exs:261`, "tampering a persisted entry's
prev_chain_hash while leaving its own chain_hash untouched is reported as hash_mismatch" --
this is exactly the scenario I traced by hand, built independently as an adversarial test
(overwrites only `prev_chain_hash` via raw SQL with the immutability trigger disabled, asserts
`{:error, {:hash_mismatch, ^id_2}}` and explicitly `refute`s the `chain_broken` shape). I ran
this test myself (see below) -- it passed. My own hand-trace and this test's assertion agree
independently.

Also confirmed the two other adversarial cases in `test/letflow/audit_test.exs`:
- "modifying a persisted after_state directly, leaving both hash columns untouched, is caught
  as a hash_mismatch" (content-only tamper, hashes internally self-consistent -- R-Co's own
  linkage-only check would miss this entirely; this module's recompute catches it).
- "a deleted middle entry breaks the chain linkage, reported as chain_broken (not
  hash_mismatch)" (a genuine chain_broken case: every surviving row's own stored content/hash
  pair is internally consistent, only the linkage between them is broken by the deletion).

All three tamper classes (content-only, prev_chain_hash-only, deletion) are covered, each
mapped to the theoretically-correct error, and I independently confirmed by hand-tracing the
code (not just reading the moduledoc's claim) that the ordering the code implements is the one
that produces those correct mappings.

## actor_id spot-check (4 operations, chosen to avoid overlap with SECURITY-REVIEWER/REVIEWER's
already-checked set: `Engine.create/2`, `complete_task/3`, Definitions' four, Identity's six,
`Tasks.assign_task/3`)

1. **`Letflow.Engine.cancel_instance/3`** (`lib/letflow/engine.ex` ~L2890-3020) -- `actor_id` is
   a required field of `attrs` (`fetch_actor_and_idempotency_key/1` returns
   `{:error, :missing_actor_id}` when absent), threaded real (non-nil) into
   `record_instance_cancel_audit/4` and `Audit.append_multi/4`. Matches the design table's
   claim of "already an explicit argument."
2. **`Letflow.Identity.create_token/3`** (via private `insert_token/3`, `lib/letflow/identity.ex`
   ~L979-1013) -- `actor_id: nil` (design §3.1b Decision (b)), wrapped in a genuine new
   `Ecto.Multi` (`Multi.insert(:token, ...) |> Multi.merge(...) |> Repo.transaction()`),
   `after_state` built via `Audit.struct_state(token, [:token_hash])` -- confirmed `token_hash`
   is excluded (INV-4). Matches design.
3. **`Letflow.Engine.TaskActivation`'s private `do_insert/3`** (`lib/letflow/engine/task_activation.ex`
   ~L318-346, the single shared task-row-creation call site behind `append_multi/6` and
   `append_multi_from_existing_records/6`, resolving OQ-1) -- `actor_id: nil`, `after_state`
   real via `Audit.struct_state(task)`. Matches design's "no actor context reaches this call
   site today" disposition.
4. Cross-checked the design's §3.2 table itself against `lib/letflow/identity.ex` a second way:
   grepped every `actor_id: nil` occurrence in that file (create_user/2, update_user_profile/3,
   update_user_status/3, create_group/2, create_token/3, revoke_token/2 -- 6 sites) and
   confirmed each carries an inline `# REQ-195 -- actor_id: nil, ...` comment citing §3.1b, with
   no site silently deviating.

No discrepancies found in any of the four. Given this exact defect class (unverified actor_id
claims) was caught 3 separate times in this design/implementation's own history, this
independent spot-check finding zero further instances is meaningful, not just an easy pass.

## DB immutability trigger

Read `priv/repo/migrations/20260830020001_create_audit_entries_tenant_scoped.exs` in full: the
`BEFORE UPDATE`/`BEFORE DELETE` triggers are installed inside the `if prefix() do` tenant-scoped
guard, so every tenant schema gets its own trigger function and both triggers at provisioning
time. Confirmed the migration is registered in `Letflow.TenantProvisioning`'s
`tenant_scoped_migrations/0` manifest (`lib/letflow/tenant_provisioning.ex:469`,
`"20260830020001_create_audit_entries_tenant_scoped.exs"` present in that literal list). Ran
`test/letflow/audit_test.exs`'s two AC1 tests myself (raw SQL UPDATE/DELETE, not
`Repo.update/1`) -- both pass, asserting the specific Postgrex error message
`"audit_entries is immutable"`.

## Ecto.Multi same-transaction guarantee

Confirmed at two real call sites (`Letflow.Identity.insert_token/3` and
`Letflow.Engine.run_cancel_instance/5`, both quoted above/below) that the audit-append step is
`Multi.merge`d into the same `Multi` chain as the business mutation, submitted via a single
`Repo.transaction()` call -- not a second, separate transaction. `run_cancel_instance/5`'s
chain has 9 steps (`:open_tasks` ... `:projection`) before the audit `Multi.merge`, all inside
one `Repo.transaction()`.

## AC11 -- no route/controller file touched

`git diff main...HEAD --stat` (run myself): 38 files changed, none under `lib/letflow/routers/`.
Confirmed.

## Test-runner flake diagnosis spot-check

`git diff main...HEAD --stat` also confirms neither `test/letflow/engine/lua/executor_test.exs`
nor `test/mix/tasks/letflow_check_toolchain_test.exs` appears in this branch's diff --
supporting TEST-RUNNER's "pre-existing, not present in this branch's diff" attribution for all
3 (rework-1 recheck) / 2 (my own fresh run) named flakes.

## My own fresh test runs

1. Target REQ-195 test files (`test/letflow/audit_test.exs`,
   `test/letflow/audit_capture_test.exs`, `test/letflow/audit_dispositions_test.exs`,
   `test/letflow/support/tenant_fixture_test.exs`), run directly via `mix test`:
   **39/39 passed, 0 failures** (9 + 5 + 11 + 14 tests across the 4 files, matching exactly).
   Confirmed the C6 oracle-rot guard test executed and passed inside this run.

2. Full suite via `scripts/test_parallel.sh` (N=8, blocking foreground run, no backgrounding):

   ```
   partition 1: 309 tests, 3 properties, 0 failures, exit 0
   partition 2: 416 tests, 2 properties, 0 failures, exit 0
   partition 3: 446 tests, 0 properties, 0 failures, exit 0
   partition 4: 403 tests, 0 properties, 0 failures, exit 0
   partition 5: 393 tests, 0 properties, 0 failures, exit 0
   partition 6: 342 tests, 0 properties, 0 failures, exit 0
   partition 7: 222 tests, 1 property, 0 failures, exit 0
   partition 8: 265 tests, 0 properties, 2 failures, exit 2
   ---
   combined: 2796 tests, 6 properties, 2 failures (2800/2802 passed)
   ```

   Both failures are `Mix.Tasks.Letflow.CheckToolchainTest`'s rust-pin tests (partition 8),
   `:enoent` from `System.cmd("rustc", ["--version"], ...)` -- confirmed via the failure log
   this host has no `rustc` on PATH, matching the exact documented flake class and exact file
   TEST-RUNNER already named. (This run happened to not reproduce the REQ-156 Lua wall-clock
   timing flake TEST-RUNNER's rework-1 run hit in partition 1 -- consistent with it being a
   genuine host-scheduling-noise-sensitive timing flake, not a deterministic failure; it simply
   didn't trigger this time.) `Letflow.Support.TenantFixtureTest`'s C6 test (partition 3, 446
   tests, 0 failures) confirmed executing and tearing down cleanly in this run's own log. No new
   regression found beyond the 2 named pre-existing flakes.

3. `mix compile --warnings-as-errors`: exit 0, no output (clean).

## Conclusion

All 12 REQ-195 acceptance criteria confirmed genuinely met against the real shipped code and a
real fresh test run. AC6's check-order property was independently hand-traced (not just
reviewed) and found genuinely load-bearing per the task's specified adversarial scenario. Four
independently-chosen actor_id dispositions (avoiding overlap with SECURITY-REVIEWER's and
REVIEWER's already-checked set) all matched the design table with zero discrepancies. Routing
to DOC-UPDATER.
