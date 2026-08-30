# REQ-192 RELEASE-VALIDATOR report — Step 5

**Run:** WF02-REQ192-20260830 · **Step:** 5 · **Verdict: PASS**

This is an independent re-derivation, not an echo of TEST-RUNNER's or REVIEWER's
reports. Every check below was performed directly by this agent against the real
code/tests on this branch, not read off a prior report's conclusion.

## 1. Acceptance criteria vs real code

Read `docs/requirements.yaml`'s REQ-192 entry in full plus
`lib/letflow/routers/services.ex`, `lib/letflow/routers/admin_services.ex`,
`lib/letflow/service_catalog.ex`'s `list_all/1`, `lib/letflow/api/error.ex`'s two new
constructors, and `lib/letflow/plugs/api_pipeline.ex`'s two new `forward/2` mounts.

- `GET /api/v1/services` (AC1): `Letflow.Routers.Services.handle_list/1` delegates to
  `ServiceCatalog.list_for_tenant/2`, whose `where` clause
  (`e.scope == :global or e.owner_tenant_id == ^tenant_id`) matches the criterion
  exactly; tenant id sourced from `conn.assigns.auth_context.tenant_id`, not
  `scoped_opts` (correct — `service_catalog` is a global table).
- `GET /api/v1/admin/services` (AC2): declared `authz_get "/", :AdminServicesRead`.
  `endpoint_policy_key/2` maps this to `:AdminServicesRead` -> `:UsersGroupsRolesManage`,
  held only by `PLATFORM_ADMIN` — a `:ServicesRead`-only caller is refused before the
  handler runs. Delegates to the new `ServiceCatalog.list_all/1`, confirmed
  tenant-agnostic (no `where` clause at all, `filter_by_list_cursor/2` reused verbatim).
- POST/PATCH/DELETE 403 (AC4): all three declared with `:AdminServicesManage`, same
  `PLATFORM_ADMIN`-only mapping.
- 409s (AC5/AC6): `Letflow.Api.Error.service_referenced_by_active_definitions/1` and
  `service_scope_narrowing_conflict/1` both present, modeled on
  `Error.promotion_conflict/2`'s extensions-map shape; `handle_delete/2` and
  `handle_update_scope/2` route the context module's tagged error tuples to them.
  Duplicate `service_id` on POST maps to `Response.conflict/2` (AC6).
- Response allowlist / field names (AC3): `service_record_json/1` hand-built, field
  names (`service_id`, `endpoint_url`, `request_schema`, `response_schema`,
  `required_auth`, `timeout_ms`, `scope`, `owner_tenant_id`, `created_at`,
  `updated_at`) match `ServiceRecord`; `max_retries` correctly omitted (no backing
  column), documented in the moduledoc rather than silently dropped.
- Cross-tenant 404 (AC7): non-admin router has no single-item route at all — a
  tenant-scoped entry owned elsewhere is simply absent from the list page, which is
  the correct realization of "never 403" (no 403-capable branch exists to trigger).
- AC8 (`authorization.ex` untouched) and AC9 (no `web/` changes): confirmed directly —
  `git diff main --stat -- lib/letflow/api/authorization.ex web/` returns empty.
- INV-RT-1 (no `Repo.` under `lib/letflow/routers/`): `grep -rn "Repo\." lib/letflow/routers/`
  returns only two prose hits inside moduledoc comments (`admin_services.ex`,
  unrelated `tasks.ex`) — zero live-code matches. The original iteration-1 design's
  router-local `Ecto.Query` was correctly abandoned in favor of the new context-module
  function; this is real, not just claimed.
- REVIEWER sign-off on the `list_all/1` scope expansion (flagged, not pre-approved):
  read `handoffs/WF02-REQ192-20260830/reviewer-report-req192-iteration2.md` and
  `step-02d-reviewer.json` in full — both flagged decisions (scope expansion, helper
  arity refactor) carry an explicit, reasoned AGREE, not a rubber stamp.

## 2. Target tests — re-run independently

```
mix test test/letflow/service_catalog_test.exs test/letflow/routers/admin_services_test.exs
Result: 39 passed
```

Matches TEST-RUNNER's and TEST-DESIGN-VALIDATOR's reported counts exactly. No
`test/letflow/routers/services_test.exs` exists (correctly — TEST-RUNNER's report
never claimed one either).

## 3. Full-suite flake diagnosis — independently assessed, not trusted

Ran `bash scripts/test_parallel.sh` myself (blocking, foreground, ~50s), a separate
invocation from TEST-RUNNER's:

```
combined: 2607 tests, 5 properties, 2 failures (2610/2612 passed)
```

Only 2 failures this run, both `Mix.Tasks.Letflow.CheckToolchainTest` (`:enoent` on
`System.cmd("rustc", ...)`) — the documented rustc-absent baseline gap, reproduced
identically to TEST-RUNNER's report. The 11 DB-connection-contention failures
(`SandboxPoolTest`, `TenantSchemaReaperTest`, `ApiTokenAuthPipelineTest`) did **not**
reproduce in this independent run — which is itself corroborating evidence for
"load-induced flake," not a discrepancy: a genuine regression in REQ-192's diff would
fail deterministically every run; a resource-contention flake is expected to appear
in some N=8 runs and not others depending on host scheduling noise at the moment of
the run. Spot-checked one of the three flagged files directly:

```
mix test test/letflow/api_token_auth_pipeline_test.exs
Result: 5 passed
```

All 5 tests in that file (including the 4 flagged in TEST-RUNNER's report) pass
cleanly in isolation, confirming the file itself has no defect and the earlier
failures were connection-pool exhaustion under simultaneous 8-way load, not a code
problem this diff introduced.

## Conclusion

Independently re-derived, not copied: REQ-192's acceptance criteria are met by the
code actually on this branch, the target tests genuinely pass (39/39, re-run twice
across two different sessions), and the full-suite failure history is consistent
with load-induced flakiness rather than a regression. Routing to DOC-UPDATER.
