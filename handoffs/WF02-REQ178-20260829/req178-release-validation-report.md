# REQ-178 RELEASE-VALIDATOR report

Run: WF02-REQ178-20260829. Verdict: **PASS**. Independently re-derived (not
copied from TEST-RUNNER's Step 4 report) on 2026-08-29.

## Environment

- `source ~/.asdf/asdf.sh` (Elixir 1.20.3 / OTP 29 per `.tool-versions`).
- `sudo docker compose up -d` -- postgres and keycloak already running.
- Postgres reachable on port 5463 (`.env`'s `LETFLOW_DB_PORT`).

## Independent re-verification, per acceptance criterion

1. **List shape / field names.** Read `lib/letflow/routers/dlq.ex`'s
   `dlq_entry_json/1` directly and diffed its key set against
   `web/src/types/api.ts`'s `DlqEntry` (lines 306-329) and
   `web/src/api/dlq.ts`'s `dlqApi.list` return type. Field names match
   (`id`, `entry_type`, `instance_id`, `reference_id`, `reason`,
   `full_reason`, `retry_count`, `status`, `created_at`, etc.). The
   `DlqEntry` TS fields with no backing `Letflow.Dlq.Entry` column
   (`item_type`, `original_payload`, `processor_metadata`, `max_retries`)
   are correctly omitted, as the moduledoc discloses. Body is exactly
   `{"items", "next_cursor"}` (`handle_list_result/2`, dlq.ex:138-143).
   Confirmed by test AC1 (`test/letflow/routers/dlq_test.exs:104-127`),
   re-run and passing.

2. **Independent filters.** Read `handle_list/1` (dlq.ex:111-136): status,
   entry_type (from `source_type` query param), search, instance_id,
   cursor, page_size are each mapped and passed to `Dlq.list/2`
   independently. Re-ran the 5 filter tests
   (`test/letflow/routers/dlq_test.exs:134-215`) -- all pass, each
   demonstrating narrowing.

3. **Permission / cross-tenant-404.** Confirmed in
   `lib/letflow/api/authorization.ex`: `endpoint_policy_key` maps any
   `/dlq`-prefixed GET/POST to `:DlqReadRetryDiscard` (line 284-285),
   `required_permission(:DlqReadRetryDiscard)` maps to `:DlqOperate`
   (line 413), and `role_allows?/2` grants `:DlqOperate` only to
   `:PLATFORM_ADMIN` (catch-all, line 443) and `:PROCESS_OPERATOR`
   (explicit clause, lines 456-467) -- `:PROCESS_DESIGNER`, `:TASK_WORKER`,
   `:AGENT_RUNNER` do not hold it. Matches the moduledoc's claim
   verbatim. Re-ran the 3 AC3 tests (403 for TASK_WORKER on both
   retry/discard, cross-tenant real id -> 404 identical to a genuinely
   absent id) -- all pass.

4. **404 vs 409 vs 500.** Read `handle_write_result/2` (dlq.ex:183-197):
   `{:error, :not_found}` and `{:error, :invalid_id}` both -> 404;
   `{:error, {:invalid_state, _}}` -> `Response.conflict/2` (409), never
   falling through to a generic 500 since the `case`/function-clause set
   is exhaustive over `Letflow.Dlq.retry/2`/`discard/2`'s declared
   4-shape `@spec`. Re-ran the 4 AC4 tests (404 nonexistent x2, 409
   already-resolved/-discarded x2, each asserting state left unchanged)
   -- all pass.

5. **Moduledoc disclosure.** Read `lib/letflow/routers/dlq.ex`'s
   moduledoc directly (lines 2-80): explicitly states R-Co's `dlq.zig`
   "was not inspected" and that `web/src/api/dlq.ts` /
   `web/src/types/api.ts` were the binding contract instead. Confirmed
   also by the dedicated test at
   `test/letflow/routers/dlq_test.exs:366-376`, re-run and passing.

6. **mix test / mix compile.** Re-ran myself (not trusted from the
   report):
   - `MIX_ENV=test mix compile --warnings-as-errors --force` -> exit 0,
     "Compiling 153 files (.ex) / Generated letflow app", zero warnings.
   - `MIX_ENV=test mix test test/letflow/routers/dlq_test.exs
     test/letflow/dlq_test.exs` -> `Result: 31 passed`, exit 0, no
     `Failed:` section -- matches TEST-RUNNER's figure exactly.
   - Full suite, `scripts/test_parallel.sh` (8 partitions, run as a
     normal blocking foreground call, not backgrounded): `combined: 2486
     tests, 5 properties, 3 failures (2488/2491 passed)` -- identical
     count to TEST-RUNNER's Step 4 report. Inspected the 3 failing-test
     logs directly (partition-2.log, partition-5.log): 2 are
     `Mix.Tasks.Letflow.CheckToolchainTest` (`System.cmd("rustc",
     ["--version"], ...)` -> `:enoent`, no rustc on PATH in this
     sandbox) and 1 is `Letflow.Engine.Wasm.PluginHandlerTest`'s AC7
     (`Wasmex.Native` external_resource check, same root cause -- no
     Rust toolchain to have compiled wasmex's NIF from). All three are
     pre-existing/environmental, none touch any file in this branch's
     diff (`git diff main...HEAD --stat`: only `docs/`, `handoffs/`,
     `lib/letflow/design/`, `lib/letflow/plugs/api_pipeline.ex`,
     `lib/letflow/routers/dlq.ex`, `test/letflow/dlq_test.exs`,
     `test/letflow/routers/dlq_test.exs`, `test/specs/REQ-178.md`).

## Additional checks

- `docs/requirements.yaml`'s REQ-178 entry and its acceptance criteria
  match Step 1's quoted text verbatim -- no drift.
- No `docs/migration/decisions/` record is contradicted by this diff
  (no new permission atom, no new endpoint_policy_key clause, no schema
  change -- all explicitly disclaimed in the moduledoc and confirmed by
  reading `authorization.ex` and the diff stat above).
- This is a WF-02 single-requirement run, not a stage gate, so no
  `docs/migration/stage-N-*.md` REVIEWER sign-off section applies here.

## Verdict

All 6 acceptance criteria hold against the actual current code and a
from-scratch test run, not against the status/history narrative. **PASS.**
Routing to DOC-UPDATER to flip REQ-178 to `done`.
