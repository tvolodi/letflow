# TEST-DESIGN-VALIDATOR report -- REQ-194 (WF02-REQ194-20260830, Step 3b)

**Verdict: PASS.** Routed to TEST-RUNNER at `handoffs/WF02-REQ194-20260830/step-04-test-runner.json`.

## What I independently re-derived (not trusted from TEST-DESIGNER's note)

### 1. Full suite run, for real

```
$ source ~/.asdf/asdf.sh
$ mix test test/letflow/metrics/ test/letflow/plugs/http_metrics_test.exs \
    test/letflow/routers/metrics_exposition_test.exs \
    test/letflow/api/authorization_enforcement_test.exs \
    test/letflow/routers/req078_supporting_routes_test.exs
...
Finished in 17.9 seconds (0.6s async, 17.2s sync)
Result: 54 passed
```

Matches TEST-DESIGNER's reported 54.

### 2. AC1 (moduledoc decisions) -- read directly

Read `lib/letflow/routers/metrics_exposition.ex`'s moduledoc in full: it contains an
explicit three-row decision table (Format/Auth/Scope) each with R-Co's value, REQ-078's
value, this requirement's decision, and a stated reason. `lib/letflow/metrics/registry.ex`'s
moduledoc restates the AC3 dependency decision and the tenant-safety invariant by name.
Genuinely present, not asserted-and-trusted.

### 3. AC6's widened adversarial scan -- read the test source directly

Read `test/letflow/routers/metrics_exposition_test.exs` in full. `complete_one_task!/1`
(lines 110-146) now returns `definition_id`, `instance_id`, `task_id`, `create_actor_id`,
`complete_actor_id` -- two distinct actor UUIDs so neither can pass by aliasing the
other. The AC6 test (lines 265-322) scans a real `Exposition.render()` body for 14
identifiers across two real tenants (tenant_id x2, definition_id x2, instance_id x2,
schema_name x2, task_id x2, create_actor_id x2, complete_actor_id x2) -- all five
identifier classes design §1 names. This is a full-body substring scan over real seeded
data, not a tautology or per-family check.

### 4. AC9's retired-route test -- confirmed real pipeline, not mocked

Read `lib/letflow/router.ex`: `/metrics` is forwarded at the top level, before
`/api/v1`; `/api/v1` forwards to `Letflow.Plugs.ApiPipeline`, whose plug order (line
50-55) is `Plug.Parsers -> :assign_trace_id -> Letflow.Plugs.AuthPipeline ->
Letflow.Plugs.TenantStatus -> :match -> :dispatch`. `AuthPipeline` runs before
`:match`/`:dispatch`, and there is no `/metrics` forward entry left under
`ApiPipeline` (it was `Letflow.Routers.Metrics`, now removed). So an unauthenticated
`GET /api/v1/metrics` genuinely gets rejected by the real `AuthPipeline` short-circuit
before any dispatch table is even consulted -- the test's 401/404 branching reflects
real plug order, not a loophole. The test calls `Letflow.Router.call(conn, @router_opts)`
(the real top-level router, `@router_opts = Letflow.Router.init([])`), not a stub. Body
assertions (`refute resp.resp_body =~ ~s("instances")` / `"definitions"`) correctly
target the retired endpoint's actual JSON shape rather than a weaker content-type check
(TEST-DESIGNER's note already documents catching and fixing that content-type mistake
by actually running the test).

### 5. AC8's poller.ex exclusion -- confirmed design-sanctioned by reading source directly

Read `lib/letflow/metrics/registry.ex`'s moduledoc (the "Family 1 is deliberately NOT
`:telemetry`-driven" section) and design doc references therein: family 1
(`active_instances`) is explicitly, by design, fed by `Letflow.Scheduler.Poller`
calling `Registry.set_active_instances/1` directly, not via `:telemetry`. The AC8 grep
test correctly excludes `scheduler/poller.ex` from its refute list. Confirmed not a
rationalized gap.

### 6. No existing assertion weakened

Diffed the note's description of changes against the actual file: `complete_one_task!/1`
gained new captured values (additive), AC6's identifier list grew from 8 to 14
(additive), and one new test was added for AC9. No existing assertion's expected value
changed.

### 7. `mix compile --warnings-as-errors` / `mix format --check-formatted`

Both clean (no output) in this environment.

### 8. `mix letflow.lint_handoffs`

`OK -- 0 new violations across 1544 handoff files (25 pre-existing grandfathered)`.

### 9. `handoffs/registry.json` format

2-space indent, no BOM, confirmed via `xxd`/hexdump before touching anything (and I did
not modify it -- not part of this step's required edits).

## Mutation testing (mandatory for this requirement's safety stakes)

All three mutations applied directly to shipped `lib/` code, run against the real test
suite, confirmed caught, then reverted with `git checkout --` and `git status
--porcelain lib/ test/` confirmed empty after each revert (and again after all three,
with a final full 54-test green re-run).

### Mutation 1 -- label-allowlist break (THE load-bearing safety test)

Changed `lib/letflow/engine.ex`'s `emit_task_completed_telemetry/2` to also pass
`definition_id` in `:telemetry.execute/3`'s metadata, and changed
`lib/letflow/metrics/registry.ex`'s `handle_task_completed/3` to label
`task_completions_total` with `%{definition_status: to_string(def_id)}` -- i.e. the
`definition_status` label KEY stays the same but its VALUE becomes the real
`definition_id` instead of the enum status. `mix compile --warnings-as-errors` stayed
clean (this class of bug is invisible to the compiler, which is exactly why the runtime
test matters).

Traced the leak precisely: the scrape body under mutation contained the literal line

```
letflow_task_completions_total{definition_status="b16005c3-11cc-4a68-b004-97bdf72b5968"} 1
```

-- a real definition UUID exposed as a label value on the global unauthenticated
endpoint. AC6's test failed with:

```
expected no label to leak "7448b516-e715-491b-be2e-da59cabe039b", but it appeared in the scrape
```

(a different tenant's definition_id in that specific run, since AC6 seeds two tenants --
both tenants' definition_ids leak under this mutation, and AC6 caught it on the first
one it scanned). This is a genuine substring hit against the real scrape body returned
by `Exposition.render()`, not an incidental failure of an unrelated test -- AC4 also
failed collaterally (its regex expected `definition_status="active"`, which no longer
matches), but AC6 is the test that must never have a false negative here, and it did not.
2 of 9 tests in the file failed: AC4 (collateral, expected regex format) and AC6 (the
actual safety catch). Reverted both files; `git status --porcelain lib/ test/` empty
afterward; full 54-test suite re-confirmed green.

**This is the single most important verification in this validation: the load-bearing
adversarial scan test genuinely, verifiably catches a real cross-tenant identifier leak
through the task-completions family's label, with the leaked value traced by hand into
the actual response body.**

### Mutation 2 -- route-template normalization break

Changed `lib/letflow/plugs/http_metrics.ex`'s `resolve_route_template/1` to return
`"/" <> Enum.join(conn.path_info, "/")` (the raw path) instead of
`Plug.Router.match_path/1`'s compiled template. Result: 7/9 passed, 2 failed -- AC5
(route-template normalization; two different UUIDs no longer collapsed to one label
set) and AC6 (the raw instance UUID used in AC6's own HTTP probe leaked into the
`route_template` label). Both caught as expected. Reverted; `git status --porcelain`
empty afterward.

### Mutation 3 -- DB-unavailable degradation break

Changed `lib/letflow/metrics/registry.ex`'s `mark_active_instances_refresh_failed/0`
from a documented no-op to one that resets the `active_instances` gauge to 0 (simulating
"drop the last-known value on failure" instead of preserving it). Result: 8/9 passed,
1 failed -- AC7 ("active_instances retains its last-known value..."), which asserted
`gauge_line_after == gauge_line_before` and correctly caught the regression. Reverted;
`git status --porcelain` empty afterward.

## Conclusion

All 10 ACs traced to real, runnable, passing tests (or a documented, design-sanctioned
non-applicability for AC3/AC8-poller). No weakened assertions. AC6, AC9, AC5, AC7 all
independently re-verified as genuine, non-tautological coverage via real mutation
testing on shipped code. PASS -- routing to TEST-RUNNER.
