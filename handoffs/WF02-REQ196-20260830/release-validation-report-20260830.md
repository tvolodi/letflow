# RELEASE-VALIDATOR independent re-verification — REQ-196 — 2026-08-30

## Verdict: PASS

All 9 acceptance criteria are genuinely met. This is an independent re-derivation,
not a re-statement of prior gate reports.

## What was independently re-run/re-checked

1. **Full suite, real toolchain, real run** (`bash scripts/test_parallel.sh`, N=8,
   real Postgres via already-running `letflow-1-postgres-1`/`letflow-1-keycloak-1`
   containers, real asdf `elixir 1.20.3`/`erlang 29.0.5` shims):

   ```
   partition 1: 321 tests, 2 properties, 2 failures, exit 2
   partition 2: 375 tests, 1 property, 0 failures, exit 0
   partition 3: 482 tests, 2 properties, 0 failures, exit 0
   partition 4: 404 tests, 0 properties, 0 failures, exit 0
   partition 5: 361 tests, 0 properties, 0 failures, exit 0
   partition 6: 376 tests, 0 properties, 0 failures, exit 0
   partition 7: 256 tests, 1 property, 0 failures, exit 0
   partition 8: 247 tests, 0 properties, 0 failures, exit 0
   combined: 2822 tests, 6 properties, 2 failures (2826/2828 passed)
   ```

   Identical to TEST-RUNNER's reported counts. Not trusted on that basis alone —
   independently reproduced from a fresh invocation of the same script.

2. **The 2 failures, read directly from this run's own partition-1 log**
   (`/tmp/letflow_test_parallel.m72uEX/partition-1.log`): both are
   `Mix.Tasks.Letflow.CheckToolchainTest` "rust pin (REQ-165)" tests, both raising
   `** (ErlangError) Erlang error: :enoent` from
   `System.cmd("rustc", ["--version"], ...)` at
   `test/mix/tasks/letflow_check_toolchain_test.exs:69/76`, before any assertion
   runs. Independently confirmed `which rustc` exits 1 (not installed) in this
   sandbox, while `which mix`/`which elixir` resolve to real asdf shims. Confirmed
   via `git diff main...HEAD --stat -- test/mix/tasks/letflow_check_toolchain_test.exs`
   (empty output) that this file is untouched by REQ-196's diff. This is a real
   environment-baseline gap, not a regression this branch introduced.

3. **REQ-196's own target tests**, run in isolation:
   `mix test test/letflow/routers/req196_audit_route_test.exs
   test/letflow/routers/req078_supporting_routes_test.exs test/letflow/audit_test.exs
   test/letflow/audit_capture_test.exs test/letflow/audit_dispositions_test.exs`
   → **71 passed, 0 failures.**

4. **`mix compile --warnings-as-errors`** → clean, no output, exit 0.

5. **`mix letflow.lint_handoffs`** → `OK -- 0 new violations across 1572 handoff
   files (25 pre-existing grandfathered, traced to ISS-0190)`. Specifically
   re-grepped `handoffs/WF02-REQ196-20260830/step-04-test-runner.json` and confirmed
   its top-level `"status"` field reads `"COMPLETED"` (not `"DONE"`) — ORCH's claimed
   fix to the handoff-schema bug it caught mid-run is independently confirmed, not
   trusted.

6. **`git diff main...HEAD --stat`** (19 files) confirmed REQ-196's actual diff is
   `lib/letflow/audit.ex`, `lib/letflow/routers/audit.ex`,
   `test/letflow/routers/req196_audit_route_test.exs`,
   `test/letflow/routers/req078_supporting_routes_test.exs`, plus
   design/handoff/status docs. Explicitly re-verified **zero** diff against main for:
   `lib/letflow/api/authorization.ex`, `priv/repo/migrations/`,
   `lib/letflow/audit/entry.ex`, and everything under `web/`.

## Acceptance criteria — checked against the real shipped code, one by one

1. **Non-null before_state/after_state, inverse of prior always-null.**
   `lib/letflow/audit.ex`'s `list_entries/1` selects `Entry` rows directly (no
   forced-null mapping anywhere in the query pipeline); `lib/letflow/routers/audit.ex`'s
   `audit_item/1` passes `entry.before_state`/`entry.after_state` straight through.
   `test/letflow/routers/req196_audit_route_test.exs`'s "AC1" describe block asserts
   `refute is_nil(item["before_state"])` / `refute is_nil(item["after_state"])` for a
   seeded state-changing entry, and this test passed in both the isolated and full-suite
   runs above. **Met.**

2. **resource_type varies by kind.** `where_resource_type/2` in `audit.ex` filters on
   the real `Entry.resource_type` column (no constant anywhere in the module); the
   route's "AC2" test seeds `"definition"`, `"instance"`, `"task"` rows and asserts
   `resource_types == ["definition", "instance", "task"]` on one response. Passed.
   **Met.**

3. **resource_type filter genuinely discriminates.** `where_resource_type(query,
   resource_type)` adds `where(query, [e], e.resource_type == ^resource_type)` only
   when a non-empty value is present; absent it is a no-op (full unfiltered scan).
   "AC3" tests assert a `resource_type=task` request returns only `"task"` rows and
   an absent one returns all kinds. Passed. **Met.**

4. **Field-for-field match against `web/src/api/audit.ts`.** Read `RawAuditPage`
   (`items`, `next_cursor`, `count`) and `RawAuditEntry` (`audit_id`, `actor_id`,
   `action`, `resource_type`, `resource_id`, `timestamp`, `before_state`,
   `after_state`) directly from `web/src/api/audit.ts`. `page_body/2` and
   `audit_item/1` in `lib/letflow/routers/audit.ex` produce exactly those keys, no
   more, no `payload`, no `pipeline_run_id` — hand-built map, not a raw
   `Jason.Encoder` derivation over `%Entry{}` (which would leak `tenant_id`,
   `chain_hash`, `prev_chain_hash`, `trace_id`, `inserted_at`). **Met.**

5. **:AuditRead still enforced, no change to authorization.ex.**
   `authz_get "/", :AuditRead do ... end` unchanged in the route; `git diff
   main...HEAD -- lib/letflow/api/authorization.ex` is empty (confirmed above).
   `test/letflow/routers/req196_audit_route_test.exs`'s "AC5" and
   `req078_supporting_routes_test.exs`'s "AC2" both assert 403 for a
   TASK_WORKER-only caller; both passed. **Met.**

6. **Tenant isolation.** The route's only tenant input is
   `conn.assigns.scoped_opts`'s `:prefix`, passed straight to `list_entries/1`,
   which requires `:prefix` as a non-optional map key — structurally no
   request-derived tenant selection is possible. "AC6" test seeds entries in two
   tenants and asserts tenant A's response contains neither tenant B's `audit_id`
   nor `resource_id`. Passed. **Met.**

7. **Moduledoc no longer states always-null/constant.** Read
   `lib/letflow/routers/audit.ex`'s full moduledoc: it explicitly states the
   *inverse* — `resource_type` "carries the real, per-row resource kind... no
   longer the constant `"instance"`", and before/after_state "carry the real
   prior/resulting state... no longer always `null`." The one remaining mention of
   "constant `\"instance\"`" is contrastive prose describing what the *old*
   behavior was, not an assertion about current behavior — correctly framed, not a
   stale caveat. **Met.**

8. **No file under `web/` touched.** `git diff main...HEAD --stat -- web/` is
   empty (confirmed above). **Met.**

9. **`mix test` and `mix compile --warnings-as-errors` both pass with real output
   quoted.** Both independently re-run above; full-suite 2826/2828 with the 2
   documented pre-existing rustc-absent failures unrelated to this diff;
   compile clean. **Met.**

## Other things checked

- `git diff main...HEAD --stat -- test/mix/tasks/letflow_check_toolchain_test.exs`
  is empty — the failing tests are not touched by this branch, confirming
  TEST-RUNNER's flake diagnosis independently rather than accepting its
  characterization.
- `handoffs/registry.json` format confirmed 2-space indent, no BOM, before writing
  the step-06 handoff — preserved exactly.
- Grepped `handoffs/WF02-REQ196-20260830/step-04-test-runner.json`'s top-level
  `"status"` field directly: `"COMPLETED"`. ORCH's claimed fix (commit 25de8c3e per
  the dispatch) is independently confirmed, not trusted on its own say-so.

## Conclusion

REQ-196 is genuinely done. Routing to DOC-UPDATER via
`handoffs/WF02-REQ196-20260830/step-06-doc-updater.json`.
