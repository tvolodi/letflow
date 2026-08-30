# TEST-DESIGNER rationale — REQ-192 `list_all/1` + `GET /admin/services` gate

**Run:** WF02-REQ192-20260830 · **Step:** 3

## What was actually asked of this pass

The dispatching agent's instructions explicitly re-scoped the full Step 3
handoff (`handoffs/WF02-REQ192-20260830/step-03-test-designer.json`, which
named a full AC1-AC10 surface across both new routers plus two new
`Letflow.Api.Error` constructors) down to four specific items:

1. `list_all/1` cross-tenant visibility (the core behavioral delta vs
   `list_for_tenant/2`).
2. `SCA:`/`SC:` cursor cross-endpoint isolation (INV-9).
3. `admin_services.ex`'s `GET /` (list-all) authorization enforcement
   specifically.
4. Standard pagination correctness for `list_all/1`.

This report, and the test code it describes, covers exactly those four
items. `Letflow.Routers.Services`'s `GET /services` and
`AdminServices`'s `POST`/`PATCH`/`DELETE` routes remain untested as of this
pass — not an oversight, an explicit scope boundary stated in the
dispatching instructions ("Do NOT duplicate list_for_tenant/2's existing
test coverage -- only add what's new/different for list_all/1 and the
router's admin-gate behavior on this new endpoint").

## Files written

* `test/letflow/service_catalog_test.exs` — three new `describe` blocks
  appended after the existing AC1-AC11 sections (before "AC11: no
  route/controller surface"), covering items 1, 2, and 4 at the
  context-module level. Reuses this file's own existing `insert_tenant!/1`
  and `register!/1` fixture helpers verbatim — no new fixture pattern
  introduced.
* `test/letflow/routers/admin_services_test.exs` — new file (none existed
  for this router before this pass). Covers item 3 (authorization
  enforcement) and re-verifies items 1 and 2 end-to-end through the HTTP
  layer, following `test/letflow/routers/tenants_test.exs`'s established
  `build_conn/4` + direct `Router.call/2` dispatch idiom (bypassing
  `Letflow.Plugs.AuthPipeline`, setting `conn.assigns.auth_context`
  directly) and its full-body 403 assertion style.
* `test/specs/REQ-192.md` — new file, the criterion -> test-case mapping
  and per-case rationale (why each test exists, not a restatement of the
  criterion), per WF-02 Step 3's own requirement.

## Key design-doc facts confirmed before writing tests (not assumed)

* Read `lib/letflow/api/pagination.ex`'s `check_prefix/2` directly: a
  cursor whose decoded payload doesn't start with the expected prefix
  returns `{:error, :wrong_endpoint}` — this is the exact tuple the
  INV-9 tests assert, not a guessed shape.
* Read `service_catalog.ex:339-405` (`list_all/1`) directly: it has no
  `tenant_id` parameter at all and omits the `where` clause entirely
  (rather than a permissive tautology) — confirming there is a genuine
  behavioral difference to test, not just an API surface difference.
* Read `lib/letflow/plugs/authorize.ex` directly: it has no `401` branch —
  only `403` (`Deny403`), `500` (missing/malformed `auth_context`,
  infrastructure failure), or allow. This is why the "unauthenticated"
  test case uses `roles: []` rather than inventing a `401` assertion this
  plug cannot produce — matching `tenants_test.exs`'s/`dlq_test.exs`'s own
  established convention for the same situation.
* Grepped `test/letflow/service_catalog_test.exs` for `list_for_tenant`
  before writing anything: **zero existing hits** — `list_for_tenant/2`
  itself has no direct pagination test in this codebase today, contrary to
  the original Step 3 handoff's assumption that such coverage already
  exists to "match the style of." No such style exists to match; the
  pagination tests written here follow this file's own general `describe`/
  fixture/`on_exit` conventions instead, and this gap in `list_for_tenant/2`'s
  own coverage is noted here rather than silently worked around by
  claiming a nonexistent precedent was followed.

## Mutation-driven coverage, not restated ACs

Per test case, the spec (`test/specs/REQ-192.md`) states why the test would
actually fail if the underlying logic regressed — e.g. the cross-tenant
visibility test includes a negative control (`list_for_tenant/2` does NOT
return the other tenant's row) specifically so the positive assertion
(`list_all/1` DOES return it) can't be vacuously true; the INV-9 tests
decode and check the real cursor prefix bytes before asserting rejection,
so a future accidental removal of the distinct-prefix mechanism (e.g. both
functions collapsing to share one prefix) would be caught by the assertion
on the minted cursor's own prefix, not just by the rejection check alone.

## Not run

Per this agent's mandate, no test in this pass was executed — `mix`/
`elixir`/`erl` are not on `PATH` in this environment (confirmed:
`which elixir erl` returns nothing), consistent with this being
TEST-RUNNER's responsibility, not TEST-DESIGNER's. TEST-RUNNER should run
`mix test test/letflow/service_catalog_test.exs
test/letflow/routers/admin_services_test.exs` and `mix compile
--warnings-as-errors` and report real output.

## Verdict requested

Route to TEST-DESIGN-VALIDATOR to confirm: every one of the four scoped
items has a runnable test, no skipped coverage within that scope, fixtures
are self-sufficient (each test creates and cleans up its own tenants/
entries via `on_exit/1`, no shared mutable fixture across tests), and the
explicit scope-narrowing (items 1-4 only, not the full original AC list) is
an acceptable disposition for this pass rather than a coverage gap to fail
on.
