# TEST-DESIGNER gap analysis -- REQ-195 (step 03)

Independent re-derivation of coverage against all 12 ACs in
`lib/letflow/design/req195-audit-entry-storage.md` §0's traceability matrix, plus the
handoff's own additional "actor_id: nil disposition" item, cross-checked against what
is *actually* in `test/letflow/audit_test.exs` and `test/letflow/audit_capture_test.exs`
(read in full), not against what the design/handoff *claims* is there.

## AC-by-AC disposition

| AC | Verdict | Where |
|---|---|---|
| AC1 (UPDATE+DELETE rejected, raw SQL) | **Already complete** | `audit_test.exs` "AC1" describe block: one raw `Repo.query!/2` UPDATE test, one raw DELETE test, both asserting `Postgrex.Error` with `"audit_entries is immutable"`. DELETE test additionally re-fetches the row to confirm it survived (not just that an error was raised for some unrelated reason). Both directions genuinely covered. |
| AC2 (activate/cancel/complete, real before/after content) | **Already complete** | `audit_capture_test.exs` has three separate describe blocks, one per named operation, each asserting specific field values inside `before_state`/`after_state` (`status`, `id`, `name` for activation; `status`, `instance_id` for cancellation; `status`, `output_variables`, `completed_by` for completion) -- not merely `{:ok, _}` or non-nil checks. |
| AC3 (audit-write failure rolls back the mutation) | **Already complete** | `audit_capture_test.exs` "AC3" block: one test against `Definitions.activate/2` (a `Repo.transaction/1`-based call site) and one against `Engine.complete_task/3` (an `Ecto.Multi`-based call site) -- both structurally different rollback paths, as the handoff asked. Both genuinely force the *audit insert itself* to fail (`DROP TABLE audit_entries` before calling the business function) and then assert the business row (definition status / task status / instance projection status) is unchanged -- not the reverse (nothing here forces the business mutation to fail and checks the audit row). |
| AC4 (tenant-scoped) | **Already complete** | `audit_test.exs` "AC4": two real tenant schemas provisioned via `TenantProvisioning.provision_tenant_schema/1` + `replay_migrations/2` (not simulated), a row written under tenant A, then `Repo.get(Entry, id_a, prefix: schema_b) == nil` and `Repo.all(Entry, prefix: schema_b) == []`. |
| AC5 (prev_chain_hash linkage + first-entry-null) | **Already complete** | `audit_test.exs` "AC5" has two tests: first-entry-null as its own dedicated test, and a separate three-entry chain test asserting each `prev_chain_hash` equals the immediately-prior `chain_hash`. |
| AC6 (recompute, not linkage-only) | **Already complete, and genuinely the strongest test in the suite** | `audit_test.exs` "AC6" has three tests: an untampered-chain sanity check, the critical content-tamper test (disables the trigger, directly overwrites a persisted `after_state` via raw SQL leaving both hash columns untouched, asserts `{:error, {:hash_mismatch, id_1}}`, and explicitly asserts the *second* entry is NOT reported as `:chain_broken` -- the exact distinction that proves this is a real recompute check and not "any 2-row chain fails"), and a separate chain-linkage test (deletes a middle entry, asserts `{:error, {:chain_broken, id_3}}`, with a code comment explaining why a `prev_chain_hash` overwrite alone would be `hash_mismatch` not `chain_broken`). Both error variants have dedicated, correctly-targeted tests. This is not a gap. |
| AC7 (canonical form documented + independent-computation cross-check) | **Doc half already complete; test half was a genuine gap -- FILLED** | `lib/letflow/audit.ex`'s moduledoc states the exact 11-field order, the `-1:` sentinel, and the microsecond-timestamp representation verbatim. But neither existing test file contained any hand-computed-hash cross-check (`grep` for `:crypto.hash`/`canonical`/`hand` in both files returned nothing) -- every existing AC6/AC5 test only ever compares the *implementation's own* `chain_hash` against itself (round-tripping through the same code), which is exactly what AC7's own wording says is insufficient ("not just round-tripping through the same code"). Filled in `audit_dispositions_test.exs`'s "AC7" describe block: a from-scratch reimplementation of the netstring + sorted-key-JSON + SHA-256 encoding, written without calling any of `Letflow.Audit`'s private functions, applied to two persisted entries (including the null-`prev_chain_hash` first-entry case) and asserted equal to the stored `chain_hash`. |
| AC8 (capture-mechanism decision + trade-off) | **Already complete** | Moduledoc's "Capture mechanism" section states the Elixir-boundary decision, what the trigger approach would buy, and why that cost isn't paid (session-GUC precedent already deferred by Decision 0003, and the SQL-business-logic concern) -- doc-content check passes. |
| AC9 (resource_id type decision + reason, non-uuid coverage) | **Already complete** | Migration file's header comment states the `:string` decision and the R-Co hazard it avoids, in full. `audit_test.exs` "AC9" additionally writes and reads back a genuinely non-uuid `resource_id` (`"tenant_role:approver"`) -- satisfies AC9's first disjunct directly (a passing test), so the design's "no such resource type exists today" factual statement isn't even needed as the fallback here; both bases are covered. |
| AC10 (lua_script_execution_audit stays separate) | **Already complete** | Moduledoc's final section states this verbatim, matching REVIEWER's own independent grep confirmation (`ac10_separation` field in the step-03 handoff). This is a doc-presence check per the design; no additional runtime test is required by design, and none was warranted (the isolation is structural -- zero shared code path -- not a runtime behavior to assert against). |
| AC11 (no route/controller file touched) | **Already complete, reconfirmed** | Reconfirmed myself: `git diff --stat main...HEAD -- lib/letflow/routers/` returns empty, and `git status --porcelain` shows only this step's own new test file as untracked. Mechanical, process-level check -- satisfied. |
| AC12 (mix test / mix compile --warnings-as-errors) | **Verified this session** | `MIX_ENV=test mix compile --warnings-as-errors` -- clean, no output. `mix test test/letflow/audit_test.exs test/letflow/audit_capture_test.exs test/letflow/audit_dispositions_test.exs` -- **24 passed, 0 failed**. Full-suite run in progress at handoff time (see below). |

## The handoff's additional item: actor_id: nil dispositions

Neither existing test file touched any of these call sites. All were genuine gaps,
now filled in the new `test/letflow/audit_dispositions_test.exs`:

- `Letflow.Definitions.create/2` -- `actor_id: nil`, `before_state: nil`, real
  `after_state` (status `draft`).
- `Letflow.Definitions.deprecate/2` -- `actor_id: nil`, real before (`active`) / after
  (`deprecated`) pair.
- `Letflow.Definitions.archive/2` -- `actor_id: nil`, real before (`deprecated`) / after
  (`archived`, including the stamped `archived_at`) pair.
- `Letflow.Identity.create_user/2` -- `actor_id: nil`, real `after_state`, and
  `password_hash` confirmed excluded (INV-2/INV-4 discipline).
- `Letflow.Identity.update_user_profile/3` and `update_user_status/3` -- `actor_id: nil`,
  real before/after pairs (one test covering both, chained).
- `Letflow.Identity.create_group/2` -- `actor_id: nil`, real `after_state`.
- `Letflow.Identity.create_token/3` and `revoke_token/2` -- `actor_id: nil`, real
  before/after pairs, `token_hash` confirmed excluded from both.
- `Letflow.Tasks.assign_task/3` -- `actor_id: nil`, real before (`assignee_ref: nil`) /
  after (`assignee_ref` = the assigned user id, `assignee_type: "USER"`) pair. Note:
  a HUMAN_TASK node's `role` attribute is mandatory (graph validation CHK-09), so an
  engine-created task's `assignee_ref` is never nil straight off dispatch --
  `assign_task/3`'s own first-assignment precondition (`%Task{assignee_ref: nil}`) is
  therefore unreachable via the ordinary create path. The test forces the row to that
  state via a direct `Repo.update_all/2` (same class of adversarial-state technique
  `audit_test.exs`'s own AC6 tests already use to bypass the immutability trigger) and
  then exercises `assign_task/3`'s real code path, `:audit` Multi step included, from
  there.
- `Letflow.Engine.TaskActivation`'s `task.create` capture site (`do_insert/3`,
  OQ-1) -- `actor_id: nil`, `before_state: nil`, real `after_state` (status `pending`),
  exercised via an ordinary `Engine.create/2` call that activates a `HUMAN_TASK` node.

## What was NOT duplicated

No new test re-covers AC1/AC4/AC5/AC6/AC9 (already fully covered in `audit_test.exs`)
or AC2/AC3's three named operations (already fully covered in `audit_capture_test.exs`)
-- `audit_dispositions_test.exs` only adds the AC7 independent-computation cross-check
and the actor_id-disposition call sites neither existing file touched.

## Toolchain verification

Ran via `source ~/.asdf/asdf.sh`, against the already-running `letflow-1-postgres-1`
docker container (host port 5463, per `.env`), `MIX_ENV=test`,
`MIX_TEST_PARTITION=99` (this workspace's own scratch partition, per README's
multi-workspace guidance -- does not touch any other workspace's or the shared dev
database).

- `MIX_ENV=test mix compile --warnings-as-errors` -- clean.
- `mix test test/letflow/audit_test.exs test/letflow/audit_capture_test.exs test/letflow/audit_dispositions_test.exs` --
  **24 passed, 0 failed**.
- Full-suite `mix test` run kicked off to confirm no regression from the new file;
  see the handoff/commit for its result once it completes (long-running background
  run at the time this document was written).

Two real bugs were caught and fixed while writing the new tests (both against my own
new test code, not against the shipped implementation): `Definitions.deprecate/2`/
`archive/2` return `{:ok, %ProcessDefinition{}}` directly (not `{:ok, %{definition:
_}}` like `activate/2` does) -- my first draft's pattern match was wrong, not the
implementation; and a HUMAN_TASK node's `role` attribute is mandatory graph-validation
input, so my first `assign_task/3` test's assumption that an engine-created task starts
with `assignee_ref: nil` was wrong -- fixed via the direct-update technique described
above.
