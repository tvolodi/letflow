# TEST-DESIGNER gap-check -- REQ-194 (Prometheus metrics subsystem, OBS-02)

Full 10-AC cross-check of ELIXIR-DEV's 53 passing tests against
`docs/requirements.yaml`'s REQ-194 acceptance criteria, following REVIEWER's PASS at
step-02d. Design doc: `lib/letflow/design/req194-prometheus-metrics.md`.

## Verdict per AC

| AC | Status before this pass | Action taken |
|---|---|---|
| AC1 (auth/scope/format decision + reasons, in moduledoc) | **Already complete.** Read `lib/letflow/metrics/registry.ex` and `lib/letflow/routers/metrics_exposition.ex` moduledocs directly: both restate all three axes with a table of R-Co/REQ-078/decision/reason, and the tenant-safety invariant is called out by name (AC6 cross-ref). Not a test-content gap. | None. |
| AC2 (SPA-facing path + Prometheus text, hits the exact `GET /metrics`) | **Already complete.** `metrics_exposition_test.exs`'s "AC2" describe block hits `GET /metrics` (unversioned) via the real `Letflow.Router`, asserts `200`, `Content-Type: text/plain; version=0.0.4`, and the literal `# HELP`/`# TYPE` line shape for all seven exposed series. This satisfies the "at minimum, exact Prometheus text format shape" bar from the task brief; a full TS-parser round-trip isn't runnable from ExUnit. | None. |
| AC3 (dependency sign-off recorded) | **Already complete, process-only.** SECURITY-REVIEWER (step-02c) and REVIEWER (step-02d) both signed off on `{:telemetry, "~> 1.4"}` in this run's own handoffs; `Letflow.Metrics.Registry`'s and `Letflow.Routers.MetricsExposition`'s moduledocs both restate the hand-rolled decision explicitly (AC3 sections). No test needed -- this is a documentation/process criterion, not a runtime behavior. | None. |
| AC4 (all six families present, parsed from real response body) | **Already complete.** `metrics_exposition_test.exs`'s "AC4" test exercises all six families through real behavior (a real tenant, a real `Engine.complete_task/3` call, a real HTTP request, Ecto's own already-emitted query event, and a direct `:telemetry.execute/3` for the >=500 case which has no natural unauthenticated-500 route to hit), then asserts anchored per-line regexes (`^letflow_..._... ` / `\{...\}`) against `Exposition.render()`'s real output -- this is line-level parsing of the actual body, not a call-was-made assertion. | None. |
| AC5 (route-template collapsing, counted) | **Already complete.** Dedicated probe router + two different UUIDs on the same route template; asserts `length(matching_lines) == 1`, the collapsed line's counter equals 2, and neither raw UUID appears in the body. This is a real count, not an eyeball check. | None. |
| AC6 (adversarial cross-tenant label-safety scan) -- **the load-bearing one** | **Substantially present but had a real gap.** The existing test already: seeds two distinct tenants, drives each through a real `Engine.create/2` + `Engine.complete_task/3` (not synthetic telemetry calls), captures `tenant_id`/`definition_id`/`instance_id`/`schema_name` for both, exercises the HTTP path with a raw UUID in it, and does a full-body substring scan (not a per-family check) for every one of those values. **Gap found:** design section 1 and both moduledocs name the tenant-safety invariant as covering `tenant_id`, `definition_id`, `instance_id`, `task_id`, **and `actor_id`** explicitly -- the existing test never captured or scanned for `task_id` or either `actor_id` value used (the `create` call's actor and the `complete_task` call's actor use two different generated UUIDs). A leak specifically through a `task_id` or `actor_id` label would have passed the pre-existing test undetected. **Fix:** `complete_one_task!/1` now generates and returns `task_id`, `create_actor_id`, and `complete_actor_id` (two distinct values, so neither could pass by aliasing the other), and the AC6 test's leaked-identifier list now includes all of them for both tenants (14 identifiers scanned total, up from 8). Verified: this modified test still passes against the shipped code (see Verification below), i.e. it is not itself broken -- and since it's an additive assertion over the same real scrape body, it would have failed had a label carrying any of these five identifier classes existed. |
| AC7 (DB-unavailable, genuinely unreachable) | **Already complete.** `Repo.query!(~s(DROP SCHEMA IF EXISTS ... CASCADE))` physically drops the tenant's schema mid-test -- a genuine, unrecoverable Postgrex failure, not a mock/stub -- then asserts `Engine.count_instances_by_status/1` raises `Postgrex.Error` for real, the gauge is unchanged after `mark_active_instances_refresh_failed/0`, and `GET /metrics` still returns `200`. This is real DB unavailability, not a simulated error return. | None. |
| AC8 (telemetry-decoupling via grep) | **Already complete, and correctly scoped.** The existing grep-based test checks `http_metrics.ex`, `engine.ex`, `event_store.ex` for direct `Letflow.Metrics.Registry` references (moduledoc-stripped first, so documentation mentions don't false-positive). The task brief asked me to also check `lib/letflow/scheduler/poller.ex` -- I read the design doc and the shipped `registry.ex` moduledoc, both of which **explicitly and deliberately exclude poller.ex** from this invariant: family #1 (`active_instances`) is **not** telemetry-driven by design (§5/§6) -- `Letflow.Scheduler.Poller` calls `Letflow.Metrics.Registry.set_active_instances/1`/`mark_active_instances_refresh_failed/0` directly, on purpose, because that family needs a DB-availability-aware refresh cadence rather than an event-driven increment. Adding poller.ex to the grep-refute list would be asserting against the design's own stated architecture, not filling a gap. Confirmed this is not an oversight -- it's named explicitly in both the design doc and `registry.ex`'s own moduledoc ("AC8's own grep command... is deliberately scoped to http_metrics.ex/engine.ex/event_store.ex and deliberately excludes scheduler/poller.ex for exactly this reason"). | None (confirmed correct exclusion, not a gap). |
| AC9 (disposition of `metrics.ex` explicit; no SPA-called route 404s) | **Partially complete -- real gap found and filled.** The existing tests confirm `Letflow.Routers.Metrics` no longer loads and that `GET /health` still resolves. Missing: a direct check of what happens to REQ-078's own actual (now-removed) authenticated path, `GET /api/v1/metrics` -- the brief specifically asked to confirm this "genuinely 404s ... whichever REQ-078's implementation actually used." **Measured directly** (not assumed) via a throwaway probe test before writing the real assertion: an unauthenticated `GET /api/v1/metrics` through the real `Letflow.Router` returns **401** (`Letflow.Plugs.AuthPipeline`'s step-1 short-circuit runs before `:match`/`:dispatch`, so it never even reaches the now-absent `/metrics` forward entry) with body `{"error":"unauthorized","detail":"missing or malformed Authorization header"}` -- not the retired endpoint's `{"instances": ..., "tasks": ..., "definitions": ...}` JSON shape (confirmed from git history of the deleted `lib/letflow/routers/metrics.ex` at the commit that removed it). **New test added:** asserts status is `401` or `404` (covering both the unauthenticated-rejection path measured and the hypothetical authenticated-but-unmatched path), and that the body never contains the old `"instances"`/`"definitions"` JSON keys. This closes the literal wording of the AC ("no SPA-called route 404s" -- the SPA never called this path, but the AC's broader intent, per the design doc's own §9, is that the *old* endpoint's behavior is genuinely gone, which is now directly tested rather than inferred from the router source only). | Added `test/letflow/routers/metrics_exposition_test.exs`'s "the OLD REQ-078 path, GET /api/v1/metrics, no longer serves the retired per-tenant JSON body" test. |
| AC10 (`mix test`/`mix compile --warnings-as-errors`) | Process requirement for TEST-RUNNER at the next step. I ran both myself (toolchain + DB available in this environment) to verify my own additions don't regress anything -- see Verification below. | None (not my step to sign off, but pre-verified). |

## Summary of code changes

- `test/letflow/routers/metrics_exposition_test.exs`:
  - `complete_one_task!/1` now captures and returns `task_id`, `create_actor_id`,
    `complete_actor_id` (previously only `definition_id`/`instance_id`) -- these are
    real values from the real `Engine.create/2`/`Engine.complete_task/3` call chain,
    not synthetic.
  - AC6's test now scans for all five identifier classes design §1 names
    (`tenant_id`, `definition_id`, `instance_id`, `task_id`, `actor_id`) across both
    tenants -- 14 identifiers instead of 8.
  - AC9's describe block gains one new test asserting the retired
    `GET /api/v1/metrics` path is rejected (401/404) and never serves the old
    JSON shape.

No existing assertion was weakened, removed, or had its expected value changed.

## Verification (real output, this environment has both toolchain and Postgres)

```
$ mix compile --warnings-as-errors
(clean -- no output, no warnings)

$ mix test test/letflow/routers/metrics_exposition_test.exs
Result: 9 passed

$ mix test test/letflow/metrics/ test/letflow/routers/metrics_exposition_test.exs \
    test/letflow/plugs/http_metrics_test.exs test/letflow/api/authorization_enforcement_test.exs \
    test/letflow/routers/req078_supporting_routes_test.exs
Result: 54 passed
```

(54 = the previously-reported 53 plus the one net-new test case; the AC6 identifier
widening modified an existing test in place rather than adding a new `test` block.)

Before the AC9 fix was correctly worded, the first attempt at that new test failed
for real (`refute get_resp_header(resp, "content-type") == ["application/json; charset=utf-8"]`
-- a generic 401 error response legitimately also carries `application/json`
Content-Type, so that assertion was wrong, not the implementation). This was caught
by actually running the test, not by inspection, and fixed to assert on JSON body
shape (`"instances"`/`"definitions"` keys) instead, which is what actually
distinguishes the retired endpoint's response from a generic auth-rejection response.

A full `mix test` run across the whole suite was also started to confirm no
unrelated regression; see the TEST-RUNNER step for the authoritative full-suite
result if this run's background completion isn't captured here.
