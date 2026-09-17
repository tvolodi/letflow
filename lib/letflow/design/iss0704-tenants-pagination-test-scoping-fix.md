# ISS-0704 — Scope the `GET /tenants` pagination assertion to its own fixture row

**Module (test-only fix):** `test/letflow/routers/tenants_test.exs`
**Issue:** ISS-0704 / GitHub #1479 / letflow-queue task 704
**Stage:** S10 (bug fix — test-infra correctness, no production behavior change)
**Author:** CODE-DESIGNER, 2026-09-17

## Confirmed diagnosis (from ISSUE-FIXER, Step 1 — not re-derived here)

`test/letflow/routers/tenants_test.exs:356-366` ("GET /tenants as PLATFORM_ADMIN lists
tenants in the paginated allowlisted shape") fails deterministically: the shared test
Postgres database holds 129+ orphaned real `tenants` rows left behind by an unrestored
`Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` flip elsewhere in the same file
(and in `identity_test.exs`). The failing test issues an *unscoped* page-1 listing
(`GET /`, default `page_size = 50` → `LIMIT 51`, `Letflow.Identity`'s
`asc: inserted_at, asc: id` sort) and then scans for its own fixture's slug in that
page. With enough older real rows sorting ahead of the fixture, the fixture falls off
page 1 and the `Enum.any?/2` assertion fails. The neighboring test two lines down
already avoids this exact failure mode by scoping its own request with `?search=...`.

## Scope of this design

**In scope:** change the one assertion's request to scope itself to the fixture's own
row, exactly as the neighboring test already does. This makes the test correct
regardless of how many other `tenants` rows exist in the shared database, without
touching pagination/listing production code.

**Out of scope (do not design here):**
- Restoring `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :manual)` via `on_exit` in
  `tenants_test.exs` / `identity_test.exs` to stop future orphaned-row accumulation.
  Recommend as a separate follow-up issue (see "Follow-up recommendation" below) —
  broader test-infra hygiene work, not this fix.
- Deleting the 129+ already-orphaned rows from the shared test database. Operational
  data cleanup, not a code change. Recommended as a one-off DBA/ops action, not part of
  this deliverable.

## Design for ELIXIR-DEV / TEST-DESIGNER

**File:** `test/letflow/routers/tenants_test.exs`
**Test:** `describe "GET /tenants as PLATFORM_ADMIN"` → `test "lists tenants in the
paginated allowlisted shape"` (currently lines 356-366)

### Exact change

Replace the unscoped `build_conn(:get, "/", tenant, ...)` request with one scoped by
`?search=<the fixture's own unique slug>` — identical query-param mechanism to the
`"search filters by slug/display_name substring"` test immediately below it (lines
368-378), which already proves this mechanism works against this same route/handler.

Current (lines 356-366):

```
test "lists tenants in the paginated allowlisted shape" do
  tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req075-list-ok")

  resp = build_conn(:get, "/", tenant, roles: ["PLATFORM_ADMIN"]) |> dispatch()

  assert resp.status == 200
  body = Jason.decode!(resp.resp_body)
  assert is_list(body["items"])
  assert is_integer(body["count"])
  assert Enum.any?(body["items"], &(&1["slug"] == tenant.tenant.slug))
end
```

Required shape after the fix (exact behavior to implement — not literal code per
CODE-DESIGNER's no-implementation-code constraint, but precise enough to apply without
judgment calls):

1. Keep `TenantFixture.provisioned_tenant!(slug_prefix: "req075-list-ok")` unchanged —
   `TenantFixture.provisioned_tenant!/1` already generates a unique, unpredictable
   suffix on top of the given `slug_prefix` (confirm this against the fixture's own
   implementation before writing the test; if it does not already guarantee
   uniqueness per call, that is a pre-existing fixture gap outside this issue's scope —
   flag it rather than silently working around it, but do not expect to find it, since
   the neighboring `"search filters by slug/display_name substring"` test already
   relies on the same guarantee).
2. Change the request path from `"/"` to `"/?search=" <> tenant.tenant.slug` (URL-query
   form; use the fixture's actual generated slug, not the static `"req075-list-ok"`
   prefix, since the prefix alone is shared across multiple tests in this file and a
   substring match against just the prefix could match more than one row — matching
   the neighboring test's own choice to search on its *own* full generated slug value).
3. Keep the response-shape assertions (`resp.status == 200`, `is_list(body["items"])`,
   `is_integer(body["count"])`) unchanged — this test's purpose is still to verify the
   paginated allowlisted response shape, not just presence.
4. Change the final assertion from `Enum.any?(...)` (scanning an unscoped page for a
   needle that might have paged out) to `Enum.any?(body["items"], &(&1["slug"] ==
   tenant.tenant.slug))` retained as-is in form, but now correct because `body["items"]`
   is the `search`-filtered result set, not the raw page-1 listing — with the search
   term matching only this fixture's slug, at most a handful of rows (realistically
   exactly one) can appear in `body["items"]`, so the `Enum.any?` no longer depends on
   `LIMIT 51` ordering against however many orphaned rows exist in the table.
5. Do not change `roles: ["PLATFORM_ADMIN"]`, the `describe` block, or any other test
   in the file.

### Why `?search=` and not an alternative (e.g. sort/filter by id, or increase page size)

- `?search=` is the mechanism this router/handler already implements and the
  neighboring test already exercises successfully against the identical endpoint —
  zero new production-code surface, zero new risk.
- Alternatives considered and rejected as out of scope or higher-risk: increasing
  `page_size` (masks the symptom, does not fix it — still breaks once orphaned rows
  exceed the new limit); sorting differently (would require production-code changes to
  `Letflow.Identity`, explicitly out of scope per point 2 below); deleting orphaned
  rows in a test `setup` block (reaches into shared-database cleanup, which is exactly
  the broader hygiene work explicitly deferred to the follow-up issue).

## Confirmation: no production code changes required

`lib/letflow/identity.ex`'s listing/pagination logic (`asc: inserted_at, asc: id` sort,
`Letflow.Api.Pagination`'s `LIMIT 51` page-size handling) is confirmed correct and
unchanged by this design. The failure is entirely a test-scoping defect: the test was
asserting against an *unscoped* page-1 result in an environment where the shared table
holds far more rows than production pagination is designed to display in one page,
which is expected, correct pagination behavior, not a bug. No change to
`lib/letflow/identity.ex` or `lib/letflow/api/pagination.ex` is part of this design or
should be made under ISS-0704.

## Follow-up recommendation (not designed here)

File a separate follow-up issue to restore
`Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :manual)` (via `on_exit`) after every test
in `tenants_test.exs` and `identity_test.exs` that flips it to `:auto` for real-schema
DDL/migration replay, to stop further orphaned real-row accumulation in the shared test
database. The existing 129+ orphaned rows are a separate, non-code, operational cleanup
task also worth tracking but not gating this fix.

## Open questions

None. The fix is fully specified by the neighboring test's existing pattern; no
judgment calls remain for the implementing agent.
