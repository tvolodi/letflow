# REQ-182 Release Validation Report

**Agent:** RELEASE-VALIDATOR
**Run:** WF02-REQ182-20260829
**Branch:** feature/WF02-REQ182-20260829
**Result:** PASS

## Method

Independently re-derived each acceptance criterion against the actual code and
tests on disk (`lib/letflow/routers/webhooks.ex`, `lib/letflow/webhooks.ex`,
`lib/letflow/api/authorization.ex`, `test/letflow/routers/webhooks_test.exs`),
and re-ran the tests and the full suite myself rather than trusting
TEST-RUNNER's report.

## Acceptance criteria — independent findings

1. **`hmac_secret_once` appears exactly once on create, never on read.** Read
   `Letflow.Routers.Webhooks.handle_create/1`: the only place `hmac_secret_once`
   is added to any response is the one `POST` success branch, splicing it onto
   `subscription_json/1`'s map. `subscription_json/1` (used by both list and the
   PATCH-echo path) is a hand-built allowlist that has no `hmac_secret_once` or
   `secret_hash` key at all. `test/letflow/routers/webhooks_test.exs`'s AC1
   describe block has both required explicit tests (create-returns-once,
   list-never-includes-it, including a raw-body substring check for the
   plaintext) — both passing when I ran them. **MET.**

2. **PATCH accepts `{status: "PAUSED"}` and `{is_active: false}`, both reading
   back as PAUSED.** Read `Letflow.Webhooks.update/3`'s `reconcile_status/1` and
   `apply_status_update/3` clauses (unchanged from REQ-181, reused verbatim by
   the router's `handle_update/2`). AC2's two tests in the router test file
   PATCH each field independently and confirm both the PATCH response and a
   subsequent GET/list read back `"status" => "PAUSED"`. Both passing. **MET.**

3. **Every route requires `WebhooksManage`; 403 without it, 404 (never 403) for
   a cross-tenant real id.** Read `lib/letflow/api/authorization.ex` directly:
   `endpoint_policy_key/2` maps all four `/webhooks/subscriptions[...]` routes
   (GET, POST, DELETE pre-existing; PATCH added by this requirement, line 303)
   to `:WebhookSubscriptionsManage`; `required_permission/1` maps that to
   `:WebhooksManage` (line 425); `role_allows?/2`'s real matrix grants
   `:WebhooksManage` only to `PLATFORM_ADMIN` (catch-all) and `PROCESS_OPERATOR`
   (explicit), not `TASK_WORKER`/`AGENT_RUNNER`/`PROCESS_DESIGNER` — matching
   the moduledoc's claim exactly. AC3's four 403 tests (one per route, using
   `TASK_WORKER`) and the cross-tenant test (real id in tenant B, called from
   tenant A, both PATCH and DELETE) all passed; the cross-tenant response body
   was asserted byte-identical to a genuinely-nonexistent id's 404 body.
   **MET.**

4. **GET list returns `{items: [...]}` with the consumer-shaped fields.** Read
   `handle_list/1` and `subscription_json/1`: body is `%{"items" => [...]}`,
   each item allowlists `target_url`, `event_types`, `status`,
   `created_at` (plus `id`/`description`/failure-tracking fields). AC4's test
   creates a subscription with an explicit `event_types` value and asserts all
   four required fields present and correct. Passing. **MET.**

5. **DELETE removes the subscription; second DELETE is 404, not duplicate
   success.** Read `handle_delete/2` and `Letflow.Webhooks.delete/2`: delete
   goes through the same `get/2` fetch-or-`:not_found` helper as REQ-181, so a
   second call structurally cannot find a row to re-delete. AC5's two tests
   (list excludes the row after delete; second delete of the same id is 404)
   both passed. **MET.**

6. **Moduledoc discloses `webhooks.zig` was not inspected.** Read the
   moduledoc directly (`lib/letflow/routers/webhooks.ex` lines 13–19): states
   verbatim that R-Co's `webhooks.zig` "was **not inspected**" and names
   `web/src/api/dlq.ts`'s `webhooksApi` object and `web/src/types/api.ts`'s
   `WebhookSubscription` type as the binding contract instead. The dedicated
   moduledoc test (`Code.fetch_docs/1` + 4 assertions) passed. **MET.**

7. **`mix test` and `mix compile --warnings-as-errors` both pass.** Re-ran
   myself, not copied from TEST-RUNNER's report:
   - `mix test test/letflow/routers/webhooks_test.exs test/letflow/webhooks_test.exs`
     → **26 tests, 0 failures** (matches TEST-DESIGN-VALIDATOR's and
     TEST-RUNNER's own counts).
   - `mix compile --warnings-as-errors` → clean, exit 0, no output.
   - Full suite via `bash scripts/test_parallel.sh` (N=8 partitions, same
     aggregation TEST-RUNNER uses), run as a blocking foreground call (no
     Monitor/background wait):
     - First attempt raced with an interrupted prior invocation of mine (I
       killed a stray background job from an earlier auto-backgrounded call)
       and surfaced 3 extra failures in `Letflow.TenantSchemaReaperTest`, all
       `Postgrex.Error too_many_connections`/`DBConnection.ConnectionError` —
       transient DB-connection-pool contention from that interruption, not a
       code regression.
     - Re-ran clean 5 seconds later: `combined: 2512 tests, 5 properties, 3
       failures (2514/2517 passed)` — the exact same 3 pre-existing/
       environmental failures TEST-RUNNER's report names (2×
       `Mix.Tasks.Letflow.CheckToolchainTest` rust-pin checks, `:enoent` on
       `System.cmd("rustc", ...)`; 1× `Letflow.Engine.Wasm.PluginHandlerTest`
       AC7, `Wasmex.Native` external_resource assertion) — independently
       re-inspected in the raw partition logs, not assumed from the count
       alone. None reference `webhook`/`Webhooks`/`Subscription`, and none of
       the touched files appear in this branch's diff.
   - `mix format --check-formatted` → clean, exit 0.
   - `mix letflow.lint_handoffs` → `OK -- 0 new violations across 1401 handoff
     files` (only pre-existing grandfathered items, unrelated to this run).
   **MET.**

## Other checks

- No `docs/migration/decisions/` record contradicted: this is a route/
  controller-layer requirement built atop REQ-181's already-shipped context
  module with no schema change, consistent with REQ-178's precedent this
  design explicitly reuses.
- This is a WF-02 requirement-level run, not a stage-gate check, so no
  `docs/migration/stage-N-*.md` REVIEWER sign-off section applies.
- Confirmed `docs/requirements.yaml`'s REQ-182 entry (line 9244) is consistent
  with what was actually built.
- Current run-history volume confirmed via
  `docs/status/requirement_status.index.yaml`: `docs/status/requirement_status.v6.yaml`
  (status: current) — field order for the status-history event is `req,
  event, agent, at, note`, per that volume's existing entries.

## Verdict

**PASS.** All 7 acceptance criteria independently verified against real code,
real tests I ran myself, and a real full-suite run I executed myself
(foreground, blocking, re-run once to rule out a transient DB-connection
artifact from my own tooling). Routing to DOC-UPDATER via
`handoffs/WF02-REQ182-20260829/step-06-doc-updater.json` to flip REQ-182 to
`done` in `docs/requirements.yaml` and append the status-history event.
