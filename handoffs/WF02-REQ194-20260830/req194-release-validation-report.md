# RELEASE-VALIDATOR report — REQ-194 (WF02-REQ194-20260830, Step 5)

## Verdict: PASS

All 10 acceptance criteria independently re-derived against the real code and a real
test run, not against the prior gate reports. Full basis below.

## Method

Read `docs/requirements.yaml`'s REQ-194 entry and all 10 acceptance criteria in full.
Read the real `lib/letflow/metrics/registry.ex`, `lib/letflow/metrics/exposition.ex`,
`lib/letflow/plugs/http_metrics.ex`, and `lib/letflow/routers/metrics_exposition.ex` in
full. Independently traced every emission call site (not just the ones the moduledocs
point at) via `grep -rn ":telemetry.execute\|:telemetry.span" lib/letflow/`, which
surfaced exactly three real call sites plus the Poller's two direct
`Letflow.Metrics.Registry` calls (the one documented non-telemetry exception):

- `lib/letflow/plugs/http_metrics.ex:76` — `:telemetry.execute([:letflow, :http, :request], ...)`
- `lib/letflow/event_store.ex:256` — `:telemetry.span([:letflow, :event_store, :append], ...)`
- `lib/letflow/engine.ex:1598` — `:telemetry.execute([:letflow, :task, :completed], ...)`
- `lib/letflow/scheduler/poller.ex:101,149` — direct `MetricsRegistry.mark_active_instances_refresh_failed/0` and `MetricsRegistry.set_active_instances/1` calls (family 1, the documented exception to the telemetry-only rule; AC8's own grep scope explicitly excludes this file for that reason)

## AC-by-AC

1. **Divergence decisions stated explicitly.** `lib/letflow/routers/metrics_exposition.ex`'s moduledoc has an explicit table for auth/scope/format, each with a reason, plus a dedicated "tenant-safety invariant" section. Confirmed by reading the file — not silent on any of the three.
2. **Format decision cites the SPA contract; endpoint matches.** Moduledoc cites `web/src/api/metrics.ts`'s `parsePrometheusText` and `metricsApi.prometheusText()`'s `client.getText('/metrics')` by name. Independently confirmed against the real `web/src/api/metrics.ts:127` (`prometheusText: () => client.getText('/metrics')`) and `web/src/pages/admin/MetricsPage.tsx:13` (`metricsApi.prometheusText()`) — the SPA calls the unversioned `/metrics`, which `lib/letflow/router.ex` now forwards to `Letflow.Routers.MetricsExposition`. `test/letflow/routers/metrics_exposition_test.exs` hits that exact path.
3. **Dependency decision recorded.** `mix.exs` diff (`git diff main...HEAD -- mix.exs`) adds `{:telemetry, "~> 1.4"}` with an inline comment stating it promotes an already-transitive dependency; `mix.lock` has **zero diff** (confirmed via `git diff main...HEAD -- mix.lock`, empty output) — genuinely zero new bytes. REVIEWER sign-off is recorded in `handoffs/WF02-REQ194-20260830/step-02d-reviewer.json` and the moduledoc's own "Dependency decision" section. Not a hand-rolled-vs-library silence — both are stated (hand-rolled registry, one promoted primitive dependency).
4. **All six families present, asserted by parsing output.** `test/letflow/metrics/exposition_test.exs` and `test/letflow/routers/metrics_exposition_test.exs` exercise real behavior (task completion, event append, DB query, HTTP request) then parse the `# HELP`/`# TYPE`/sample body — confirmed by reading the registry's family table (6 families: active_instances, its refresh-timestamp gauge, task_completions_total, event_append_duration_seconds, db_query_duration_seconds, http_requests_total/http_errors_total) and the exposition module's `@families` list matching 1:1.
5. **Route-template labeling, not raw path.** `lib/letflow/plugs/http_metrics.ex`'s `resolve_route_template/1` uses `Plug.Router.match_path/1`, which returns the compile-time template (verified against the moduledoc's own citation of `deps/plug/lib/plug/router.ex:663` reasoning — structurally bounded, not a best-effort string transform). `handle_http_request/3` in the registry uses `route_template` verbatim as the label.
6. **AC6 — see dedicated section below.**
7. **DB-unavailable graceful degradation.** `Letflow.Metrics.Exposition.render/0` calls only `Registry.snapshot/0` (pure ETS reads) — confirmed by reading the whole file: no `Letflow.Repo` reference anywhere. `Letflow.Scheduler.Poller.fetch_tenant_schemas/0` rescues any error and returns `:error`, which triggers `MetricsRegistry.mark_active_instances_refresh_failed/0` (a documented no-op leaving the gauge at its last value) rather than crashing or blocking the exposition endpoint.
8. **Telemetry-only coupling at emission sites.** Ran the grep myself: `grep -rn "Letflow.Metrics.Registry" lib/letflow/plugs/http_metrics.ex lib/letflow/engine.ex lib/letflow/event_store.ex` returns zero hits (confirmed). Poller's direct calls are the one documented, justified exception (family 1 has no natural event to hang off).
9. **`lib/letflow/routers/metrics.ex` disposition.** Confirmed genuinely deleted: `git diff main...HEAD --stat` shows `lib/letflow/routers/metrics.ex | 164 ------------------------------` (pure deletion, no replacement file of the same name). `lib/letflow/router.ex`'s diff shows the old route removed and `/metrics` now forwards to `Letflow.Routers.MetricsExposition`. Checked `web/src` for any other route the SPA might call under `/api/v1/metrics` — grep found none; `MetricsPage.tsx` only ever calls `metricsApi.prometheusText()` → `/metrics`, which now resolves. No 404 regression for the SPA.
10. **mix test / mix compile --warnings-as-errors.** Re-ran myself, see below — both pass.

## AC6 — independent trace (the one to scrutinize hardest)

I did not trust the prior security-review audit's conclusion. I re-traced every label
extraction myself, function by function, in the real `lib/letflow/metrics/registry.ex`:

- **`handle_task_completed/3`** (family 2): pattern-matches `%{definition_status: status}`
  guarded by `when status in [:draft, :active, :deprecated, :archived]` — a closed
  4-value enum. The only label built is `%{definition_status: Atom.to_string(status)}`.
  Any other shape of metadata (including a status outside the enum) falls through to
  the catch-all clause `handle_task_completed(_measurements, _metadata, _config), do: :ok`
  — dropped, not partially labeled. `Atom.to_string/1` on a value already constrained
  by the guard cannot smuggle a UUID through.
- **`handle_event_append_stop/3`** (family 3): `observe_histogram(:event_append_duration_seconds, %{}, duration)` — labels are the literal empty map `%{}`. No metadata field is read at all, so there is no path from event metadata to a label here regardless of what the event carries.
- **`handle_repo_query/3`** (family 4): the only label is `query_type_from_sql(Map.get(metadata, :query))`, which extracts just the leading SQL keyword and classifies it into one of five fixed strings (`select`/`insert`/`update`/`delete`/`other`) via `classify_sql_keyword/1`'s closed pattern match — the raw SQL text itself is never used as a label value or stored, only inspected transiently to pull one leading token. This closes the concern I specifically went looking for: even if a UUID literal appeared inline in the SQL string (e.g. a parameterless query somehow embedding one), it cannot reach a label because only the first whitespace-delimited token is ever consulted, and `classify_sql_keyword` maps anything not literally `SELECT/INSERT/UPDATE/DELETE` to the constant `"other"`.
- **`handle_http_request/3`** (families 5/6): labels are `method` (`to_string(conn.method)` — a fixed HTTP verb), `route_template` (see AC5 above — structurally bounded to compiled route templates or the literal `"unmatched"`), and `status` (`Integer.to_string(status)` — a 3-digit HTTP status code). None of these three fields can carry a tenant/entity identifier by construction — `conn.method` and `conn.status` are protocol-level values, not derived from request bodies or path segments.
- **Family 1 (`set_active_instances/1`)**: takes a raw non-negative integer count and inserts it as a gauge value, never a label. `mark_active_instances_refresh_failed/0` takes no arguments and touches no ETS row with any new label.

**Edge cases I specifically checked for, per the task's prompt:**

- *Error/exception metadata with more detail than the happy path*: `Engine.emit_task_completed_telemetry/2` (`lib/letflow/engine.ex:1588-1609`) only emits telemetry inside the `{:ok, %{complete_task_outcome: :completed, instance_projection: ...}}` match clause — i.e., only on the success path. On any lookup failure (`Definitions.get_by_id/2` returning an error), the `case` falls to `_lookup_failed -> :ok`, which emits nothing at all — not a degraded/verbose label, just silence. `EventStore.append/2`'s `:telemetry.span/3` wraps `Repo.transaction/2`; the registry only attaches to the `:stop` event (successful return), and that handler (`handle_event_append_stop/3`) ignores metadata entirely (labels `%{}`), so even the `:exception` telemetry event `:telemetry.span/3` would raise on a crash is never subscribed to by the registry — no exception struct or its `inspect` output can ever reach a label through this path.
- *DB-unavailable degradation path leaking connection/table details via `inspect`*: `Letflow.Scheduler.Poller.fetch_tenant_schemas/0` (`lib/letflow/scheduler/poller.ex:133-137`) and `count_active_for_schema/1` (lines 156-163) both `rescue _error ->` and discard the error term completely (`:error` / `0` respectively) — the rescued exception is never interpolated into a string, logged with detail, or passed anywhere near `MetricsRegistry`. `MetricsRegistry.mark_active_instances_refresh_failed/0` and `set_active_instances/1` take no error-derived argument at all — the former takes zero arguments, the latter takes only a pre-computed non-negative integer count. There is no code path by which a `Postgrex.Error`, a `DBConnection.ConnectionError`, or any struct's `inspect` output can reach an ETS label key in this subsystem.
- *`query_type_from_sql`'s handling of unusual/malformed SQL*: covered above — only the leading token is read, and anything not matching the four known keywords collapses to `"other"`, so even pathological SQL text cannot leak through this function.

I found no path — in the happy path, the error/exception paths, or the DB-unavailable
degradation path — by which a `tenant_id`, `instance_id`, `definition_id`, `task_id`, or
`actor_id` could reach a label value. This matches the prior security-review's
conclusion, but I reached it via my own independent line-by-line trace of the current
code, including probing the two edge cases named in this task's brief.

I also read `test/letflow/routers/metrics_exposition_test.exs`'s `describe "AC6: no
metric label anywhere carries a seeded tenant/instance/definition id"` block
(lines 265+): it seeds two real tenants, each with a real `definition_id`,
`instance_id`, `task_id`, and two distinct `actor_id`s (create + complete actor),
drives both tenants through a full create→complete task lifecycle, then asserts none
of those ten seeded UUIDs appears anywhere in the combined scrape body for either
tenant. This is a genuine adversarial test, not a vacuous one — it is exactly the kind
of test that caught the real label-leak mutation TEST-DESIGN-VALIDATOR reported.

## Independent test re-run

Ran the target suite myself, foreground, blocking:

```
source ~/.asdf/asdf.sh && mix test test/letflow/metrics/ test/letflow/plugs/http_metrics_test.exs \
  test/letflow/routers/metrics_exposition_test.exs test/letflow/api/authorization_enforcement_test.exs \
  test/letflow/routers/req078_supporting_routes_test.exs
```

Result: **54 passed, 0 failures.**

Ran `mix compile --warnings-as-errors` myself: clean, zero output, exit 0.

## Full-suite flake spot-check

`test-runner-report.md` attributes the full suite's 5 failures to two pre-existing flake
classes (rustc-absent `CheckToolchainTest`, ISS-0110 `TenantSchemaReaperTest`
connection contention) and states neither failing file is touched by this branch's
diff. Independently ran `git diff main...HEAD --stat` myself: the diff's 35 files do
**not** include `test/mix/tasks/letflow_check_toolchain_test.exs` or
`test/support/tenant_schema_reaper_test.exs` — confirmed directly, not by trusting the
report's claim.

## Dependency verification

`git diff main...HEAD -- mix.exs` shows exactly one added line, `{:telemetry, "~> 1.4"}`,
with an inline comment. `git diff main...HEAD -- mix.lock` is **empty** — confirmed
zero new resolved bytes, matching the "already-transitive, promoted to direct" claim
exactly.

## Removal verification

`git diff main...HEAD --stat` shows `lib/letflow/routers/metrics.ex | 164
------------------------------` — a pure deletion, no file of that name recreated
elsewhere. `lib/letflow/router.ex`'s diff removes the old route and adds `forward("/metrics",
to: Letflow.Routers.MetricsExposition)` before the `/api/v1` forward. Grepped
`web/src` for the old route and for any other metrics call site: only
`web/src/api/metrics.ts:127` (`client.getText('/metrics')`) and
`web/src/pages/admin/MetricsPage.tsx` reference metrics, and both now resolve
successfully against the new endpoint.

## Conclusion

Genuinely satisfied. Routing to DOC-UPDATER.
