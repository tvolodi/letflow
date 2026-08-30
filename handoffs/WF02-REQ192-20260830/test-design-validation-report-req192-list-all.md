# TEST-DESIGN-VALIDATOR report — REQ-192 `list_all/1` + `GET /admin/services` gate

**Run:** WF02-REQ192-20260830 · **Step:** 3b · **Verdict:** FAIL

## What was checked

Full read of `handoffs/WF02-REQ192-20260830/step-03b-test-design-validator.json`
(dispatching handoff), `test-design-rationale-req192-list-all.md` (TEST-DESIGNER's
rationale), `test/specs/REQ-192.md` (the criterion -> test-case mapping), and both
test source files in full:

* `test/letflow/service_catalog_test.exs` (three new `describe` blocks, lines
  641-773)
* `test/letflow/routers/admin_services_test.exs` (new file, all 257 lines)

Also read `test/letflow/routers/tenants_test.exs` (lines 1-120) to verify the
`build_conn/4` + `Router.call/2` idiom TEST-DESIGNER cited is real.

## Scope-narrowing disposition

AGREE. The four-item re-scoping (cross-tenant visibility, SCA:/SC: cursor
isolation, admin-gate authorization, pagination) matches the dispatching
instructions verbatim. Not a coverage gap.

## Router-test idiom check

PASS. `admin_services_test.exs`'s `build_conn/4` (conn/2 + `assign(:auth_context,
...)` + `assign(:trace_id, ...)`), `dispatch/1` (`Module.call/2` with
`@opts = Module.init([])`), and full-body-403 assertion with `refute`-based
negative checks are a faithful, working reproduction of `tenants_test.exs`'s own
established pattern (lines 40-93 there). Not a fabricated precedent.

## Toolchain and real test run

`mix`/`elixir`/`erl` ARE available in this environment via
`source ~/.asdf/asdf.sh` — contrary to TEST-DESIGNER's stated assumption.
`mix compile --warnings-as-errors` passed clean. Database already existed and
migrations were already up.

```
mix test test/letflow/service_catalog_test.exs test/letflow/routers/admin_services_test.exs
...
Result: 38/39 passed
Failed: 1 test
```

The failure is deterministic and reproduces in isolation:

```
mix test test/letflow/service_catalog_test.exs:724
...
** (FunctionClauseError) no function clause matching in Base.url_decode64!/2
     The following arguments were given to Base.url_decode64!/2:
         # 1
         nil
Result: 0/1 passed, 32 excluded
```

**Root cause:** `test/letflow/service_catalog_test.exs`'s `"SCA: is not merely a
longer match of SC:"` test (line ~724, describe "REQ-192 list_all/1 <->
list_for_tenant/2: SCA:/SC: cursor cross-endpoint isolation (INV-9)") registers
only **one** `service_catalog` row (`register!(%{scope: :global})`) and then
calls `ServiceCatalog.list_for_tenant(%{page_size: 1}, tenant.id)`. With one row
and `page_size: 1`, that row is the entire result set — the sibling
pagination-correctness describe block two sections below asserts exactly this
semantic ("next_cursor is nil on the first page when the full result set fits
within page_size"). So `next_cursor` (bound to `sc_cursor`) is `nil`, and
`Base.url_decode64!(nil, padding: false)` has no matching function clause — the
test crashes rather than exercising its intended assertion. This is a
fixture-sizing bug, not a flawed test *idea*: the two sibling tests in the same
describe block already register 2 rows before minting a cursor; this one needs
the same fix (register a second row).

## Mutation check (independently performed, not copied from TEST-DESIGNER)

Applied a real mutant to `lib/letflow/service_catalog.ex`'s `list_all/1`:
inserted `|> where([e], e.scope == :global)` into its query pipeline, simulating
a regression where cross-tenant visibility is silently reintroduced (the exact
kind of regression the design doc says `list_all/1` exists to avoid).

With the mutant in place:

```
mix test test/letflow/service_catalog_test.exs:650 test/letflow/service_catalog_test.exs:671 test/letflow/routers/admin_services_test.exs
...
Result: 5/8 passed, 31 excluded
Failed: 3 tests
```

All three failures are exactly the cross-tenant-visibility tests: both
`list_all/1` context-module tests (lines 650/671) and the router-level
`PLATFORM_ADMIN` cross-tenant HTTP test in `admin_services_test.exs`. This
confirms those tests genuinely discriminate a correct implementation from a
regressed one — not vacuously true.

Reverted via `Edit` back to the original pipeline (no `where` call). Verified
the revert:

```
git status --porcelain lib/ test/
<empty output>

mix test test/letflow/service_catalog_test.exs:650 test/letflow/service_catalog_test.exs:671
...
Result: 2 passed, 31 excluded
```

The working tree is clean and the two probed tests re-run green after the
revert.

## Fixture isolation / self-sufficiency

PASS. Both files use `async: false` with `Sandbox.mode(Repo, :auto)` and
per-test `on_exit/1` cleanup for every `service_catalog` row and every
`Letflow.Identity.Tenant` row created. No shared mutable fixture found across
tests; no test depends on another test having run first (confirmed by running
`test/letflow/service_catalog_test.exs:724` in isolation, independent of test
order).

## Verdict

**FAIL** — one test in `test/letflow/service_catalog_test.exs` is not a
runnable test; it crashes deterministically on every run due to a
fixture-sizing bug unrelated to test design intent. All other 38 tests in both
files pass for real, the scope-narrowing is legitimate, the router idiom is
real, fixtures are self-sufficient, and the new coverage genuinely catches a
real mutation. Routed back to TEST-DESIGNER via
`handoffs/WF02-REQ192-20260830/step-03-test-designer.json` (rework_count now 1)
with the exact fix required (register a second row in the failing test, mirror
the two working sibling tests) and an instruction to actually run `mix test`
before resubmitting.

## Rework-1 recheck (2026-08-30) — PASS

Rechecked only the fixture-sizing defect per
`handoffs/WF02-REQ192-20260830/step-03b-test-design-validator.json`
(handoff id `...-recheck1`); the scope-narrowing, router-idiom, fixture-isolation,
and mutation-check findings above were not re-derived (unaffected by this
one-line change).

1. Read the fixed test myself
   (`test/letflow/service_catalog_test.exs:724-739`): it now calls
   `register!(%{scope: :global})` twice before minting the cursor with
   `page_size: 1`, exactly matching its two sibling tests in the same
   describe block (lines 695-708, 710-722), which already register 2 rows
   each.
2. Ran, for real, myself:

   ```
   source ~/.asdf/asdf.sh && mix test test/letflow/service_catalog_test.exs test/letflow/routers/admin_services_test.exs
   ...
   Finished in 8.1 seconds (0.00s async, 8.1s sync)
   Result: 39 passed
   ```

   0 failures, matching TEST-DESIGNER's reported count independently.
3. `git show 09402cd6 --stat` / full diff: exactly two files touched —
   `test/letflow/service_catalog_test.exs` (one line added: a second
   `register!(%{scope: :global})` call inside the one named test, nothing
   else) and the `step-03b-test-design-validator.json` handoff itself. No
   other test, no fixture helper, no `lib/` file touched.

**Verdict: PASS.** The fix is minimal, mirrors the working sibling tests
exactly, and the full two-file suite is genuinely 39/39 green. Routed to
TEST-RUNNER via `handoffs/WF02-REQ192-20260830/step-04-test-runner.json`.
