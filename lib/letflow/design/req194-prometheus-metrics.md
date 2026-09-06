# REQ-194 — Prometheus Metrics Subsystem (OBS-02): Design

Status: DESIGN (WF-02 Step 1). No implementation code below — `@spec`/`@type`/
interface tables and prose only, per CODE-DESIGNER's mandate.

PROVENANCE (historical, not current decision authority):
Queue task 367, GH#713. Resolves REQ-078's three recorded divergences (auth, scope,
format) between R-Co's `src/obs/metrics.zig` / `src/api/routes/metrics.zig` and
Letflow's placeholder `lib/letflow/routers/metrics.ex`.

---

## 0. Evidence read before deciding anything (per this requirement's own mandate)

- `lib/letflow/routers/metrics.ex` (REQ-078): serves authenticated, per-tenant JSON at
  `GET /api/v1/metrics`, computed from three `COUNT(*)`-style context functions
  (`Letflow.Engine.count_instances_by_status/1`, `Letflow.Engine.count_tasks_by_status/1`,
  `Letflow.Definitions.count_definitions_by_status/1`). Its own moduledoc states three
  *deliberate* divergences from R-Co (auth: authenticated vs R-Co's none; scope:
  per-tenant vs R-Co's global; format: JSON vs R-Co's Prometheus text) and says plainly:
  "S6 observability is the owning stage for Letflow's metrics subsystem... this endpoint
  is expected to be superseded or rewritten; it is a placeholder shape, not the design."
- `web/src/api/metrics.ts`: exports `parsePrometheusText/1` (a real "# HELP"/"# TYPE"/
  sample-line parser with label-set support, lines 38–124) and
  `metricsApi.prometheusText/0 = client.getText('/metrics')` (line 127) — an **unversioned**,
  top-level path, not `/api/v1/metrics`.
- `web/src/pages/admin/MetricsPage.tsx`: `usePrometheusMetrics/0` (lines 9–18) calls
  `metricsApi.prometheusText()` then `parsePrometheusText(text)`, refetching every 30s,
  and renders each parsed family/sample/label set in a table. This is a real,
  already-committed consumer of Prometheus text at `GET /metrics`, exactly the class of
  binding contract REQ-181/182 built to.
- `grep -rn ":telemetry.execute" lib/ test/` → **zero real call sites** (one hit is a code
  *comment* in `test/letflow/plugs/tenant_status_test.exs:70`, not a call).
- `mix.exs` deps (lines 38–48): `ecto_sql, postgrex, plug, bandit, jason, stream_data,
  ueberauth_oidcc, lua, wasmex` — no `telemetry`, `telemetry_metrics`, or `prometheus*`
  entry, confirming the requirement's claim.
- **But** `mix.lock` already carries `telemetry` at **v1.4.2** (line 19), pulled in
  *transitively* by `bandit`, `db_connection`, `ecto`, `ecto_sql`, `plug`,
  `thousand_island` — it is already fetched, compiled, and loaded into every running
  Letflow BEAM node today, purely because Bandit/Ecto/Plug themselves depend on it.
  Nothing in first-party `lib/` code calls it yet.
- `deps/ecto_sql/lib/ecto/adapters/sql.ex:900-1315`: Ecto/`ecto_sql` **already emits** a
  `:telemetry.execute/3` call for every query, at event name
  `Keyword.fetch!(config, :telemetry_prefix) ++ [:query]`. `Ecto.Repo.Supervisor.telemetry_prefix/1`
  (`deps/ecto/lib/ecto/repo/supervisor.ex:55-59`) derives this by `Module.split/1` +
  underscore, and no `letflow` config sets `:telemetry_prefix` explicitly
  (`config/{dev,test,runtime}.exs`), so for `Letflow.Repo` the default applies:
  `[:letflow, :repo, :query]`. Its metadata (`sql.ex:1302-1310`) carries `:query` (the raw
  SQL text), `:source` (table name, may be `nil`), `:result`, `:repo`, `:params`. Its
  measurements carry `:query_time`, `:decode_time`, `:queue_time`, `:total_time` (native
  time units). **This means the DB-query-latency family needs zero new instrumentation
  call sites in Letflow's own code** — only a registry attachment to an event Ecto
  already fires.
- `lib/letflow/api/authorized_router.ex:81-127`: `Plug.Router.match/3`
  (which `authz_get/3` etc. expand to) stores the path it matched — via `Plug.Router`'s
  own `plug(:match)`/`plug(:dispatch)` pair — in `conn.private[:plug_route]` as
  `{literal_path_template, dispatch_fun}`, and `Plug.Router.match_path/1`
  (`deps/plug/lib/plug/router.ex:324-327`) returns that literal template (e.g.
  `"/instances/:id"`, never a resolved UUID). `append_match_path/2`
  (`deps/plug/lib/plug/router.ex:520-528`) composes a **forwarded** router's own matched
  sub-path onto the base router's already-matched prefix, so calling
  `Plug.Router.match_path/1` at the *outermost* router (`Letflow.Router`), after
  dispatch has descended through `Letflow.Plugs.ApiPipeline` into e.g.
  `Letflow.Routers.Instances`, yields the **fully composed** template
  (`"/api/v1/instances/:id"`), not a partial fragment. This is the exact mechanism
  Axis-independent §2 below is built on.
- `lib/letflow/api/authorization.ex`: `:MetricsRead` is a real `endpoint_policy_key/2`
  clause (line 287, `endpoint_policy_key("GET", "/metrics")` — evaluated relative to the
  sub-router's own mount point, i.e. `/api/v1/metrics`'s tail) and is **unconditionally**
  short-circuited to `:Allow` (metrics.ex's own moduledoc lines 52-60, corroborated by
  `authorization.ex` around line 363). So "authenticated" for REQ-078's endpoint means,
  in practice, "any caller holding a valid session token for any tenant, full stop" — not
  a meaningful per-caller gate. The real protection REQ-078 relies on is **tenant
  scoping of the query itself**, not the permission check.
- `lib/letflow/event_store.ex:216-249`: `append/2` builds an `Ecto.Multi` and runs
  `Repo.transaction/2` directly — there is no pub/sub, no callback registry, no
  `Phoenix.PubSub`, nothing that already decouples "an event was appended" from the
  calling process. Instrumenting event-append latency therefore requires one new,
  explicit `:telemetry.execute/3` (or `:telemetry.span/3`) call site inside `append/2`
  itself — there is no existing hook to attach to, unlike the DB-query case.
- `lib/letflow/application.ex`: supervision tree is `Letflow.Repo` → `Ecto.Migrator` →
  `Oidcc.ProviderConfiguration.Worker` → `{Registry, name: Letflow.Registry}` →
  `Letflow.InstanceSupervisor` → three `Task.Supervisor`/registry pairs for
  Sandbox/Lua/Wasm plugin execution → `scheduler_children()` (conditionally
  `Letflow.Scheduler.Poller`) → `http_child()` (conditionally `Bandit`). A new
  ETS-owning registry process is a leaf, independently-startable component with no
  startup-order dependents (nothing needs to look it up during *its own* `init/1`), so
  it can be added anywhere before `http_child()`; §4 below places it directly after the
  generic `{Registry, name: Letflow.Registry}` child, mirroring that precedent.
- `lib/letflow/scheduler/poller.ex`: `handle_info(:tick, state)` (lines 60-71) already
  runs **more than one** per-tick job on the same supervised `GenServer` — the timer
  poll-and-fire loop, then `maybe_run_retention_sweep/2` (REQ-188's addition, widening
  `state` from `%{}` to carry `last_retention_run_at`). This is the exact, established
  precedent for "a new periodic job rides the existing ticker rather than spawning a new
  supervised child" that ORD-04 (REQ-199) also cites for its own lag sweeper.

---

## 1. The three axes — explicit, reasoned decisions

### AXIS 1 — FORMAT: **Prometheus exposition text.** Settled by the SPA evidence alone.

`web/src/api/metrics.ts` and `web/src/pages/admin/MetricsPage.tsx` are already-committed
code that parses and renders Prometheus text, not JSON, from `GET /metrics`. Serving
JSON there would mean either breaking that already-shipped consumer or requiring a
second, uncoordinated frontend change outside this requirement's scope (S8 owns `web/`,
and this requirement's own "NOT IN THIS REQUIREMENT" explicitly excludes touching it).
**Decision:** exposition body is Prometheus text exposition format, `Content-Type:
"text/plain; version=0.0.4"`.

### AXIS 2 — AUTH, and AXIS 3 — SCOPE: decided together, because they are the same tradeoff

REQ-078's own reasoning was substantive, not arbitrary: `:MetricsRead` is
unconditionally `:Allow` for every authenticated caller (`authorization.ex`), so
"authenticate, then serve a platform-wide figure" is equivalent to "serve every
tenant's figures to every other tenant's caller" — a straight INV-1 violation. Reverting
naively to R-Co's shape (unauthenticated + global + per-entity labels) would reintroduce
exactly that.

But the SPA/Prometheus-scraper contract (`metricsApi.prometheusText()`,
`client.getText('/metrics')`, no auth header logic in that call) and real-world
Prometheus scrape configs both assume **one global, unauthenticated scrape target** —
Prometheus's server itself has no per-tenant credential concept to attach to a scrape
job pointed at Letflow. Keeping REQ-078's authenticated-per-tenant shape at the SPA's
expected path would mean either the SPA silently starts sending an auth header a real
Prometheus scraper never would (divergent consumers of the same endpoint), or the
endpoint stays reachable by the SPA only — neither is "the SPA's binding contract
satisfied by a route a scraper can also use," which is what OBS-02 actually needs.

**The resolving question, asked directly and answered directly:** can a `definition_id`
(or `instance_id`/`tenant_id`) label leak one tenant's identifiers to another tenant's
scrape? **Yes, structurally, if any metric family's label set is allowed to carry a raw
per-entity identifier.** A global endpoint with even one such label turns "GET /metrics"
into a cross-tenant enumeration surface: any caller (now unauthenticated, so *anyone* who
can reach the endpoint) sees every tenant's `definition_id`/`instance_id` values and
volumes, which is worse than REQ-078's own feared failure mode (empty-or-cross-tenant —
this would be *always* cross-tenant, unconditionally, and reachable by non-tenants at
all).

**Decision:** the endpoint is **global and unauthenticated**, mounted at the top level
(same tier as `GET /health` and `GET /api/tenant-config` on `Letflow.Router`, **outside**
`Letflow.Plugs.ApiPipeline`/`Letflow.Plugs.AuthPipeline` entirely — there is no tenant
context to resolve and no session to check) — AND every metric family's label set is
**structurally restricted to a fixed, hand-built allow-list of non-identifying label
values** (mirroring `lib/letflow/routers/metrics.ex`'s own `counter_group/2`/`metrics_map/3`
pattern: "hand-built key list, never a pass-through of whatever atoms the query happened
to return"). No metric emitted by this subsystem ever carries a `tenant_id`,
`definition_id`, `instance_id`, `task_id`, `actor_id`, or any other per-entity or
per-tenant identifier as a label value, at any point — not filtered out at exposition
time, but **never extracted from event metadata into a label in the first place** at the
`:telemetry` handler layer (§3). This is the design's central tenant-safety invariant and
is called out again in §7 (moduledoc content) and mapped to a concrete test in §9.

This resolves the R-Co-vs-REQ-078 tension without picking either side wholesale: it
takes R-Co's shape (global, unauthenticated, one scrape target) exactly where the SPA
needs it, and keeps REQ-078's substance (no cross-tenant disclosure) by moving the
protection from "authenticate + scope the query" to "never let an identifying value
become a label," which is the only mechanism compatible with a genuinely global,
unauthenticated target. `Letflow.Routers.Metrics`'s per-tenant `:MetricsRead` route is
retired for this purpose, not repurposed (§8).

One concrete consequence for the "task-completions counter labelled by definition"
family (R-Co's literal wording): R-Co is single-tenant-shaped, so "by definition" there
means "by this specific globally-known workflow." In Letflow, a raw `definition_id` (or
name) is exactly the kind of per-tenant identifier §Axis-2/3 forbids on a global,
unauthenticated label. **This family is restated** (the same class of restatement
decision 0014 makes explicit for LUA-01/WASM-10, and that REQ-148's/REQ-169's designs
follow — state plainly that intent, not literal wording, is satisfied): the label
dimension becomes `definition_status` (`draft | active | deprecated | archived` — the
same closed enum `lib/letflow/routers/metrics.ex`'s own `counter_group/2` already zero-fills
for definitions), never a `definition_id` or name. This preserves the family's
operational value (are completions still landing against deprecated definitions?)
while being provably non-identifying: it is a 4-value closed enum, not a per-tenant
identifier space.

---

## 2. Route-template normalization rule (HTTP-request/HTTP-error labels)

**Mechanism, exactly:** after `Plug.Router`'s `:dispatch` plug has run (i.e., a route
either matched somewhere in the `Letflow.Router` → `Letflow.Plugs.ApiPipeline` →
sub-router chain, or nothing matched), read `Plug.Router.match_path/1` on the `conn`.
Per `deps/plug/lib/plug/router.ex:324-327` this returns the **literal compile-time path
template** recorded in `conn.private[:plug_route]` at the point each nested router's own
`:match` plug ran — `append_match_path/2` (same file, lines 520-528) means a route
matched inside a `forward`-ed sub-router (e.g. `Letflow.Routers.Instances`'s
`authz_get "/:id", :InstancesRead`) already comes back **fully composed** with its
parent's mount prefix (`"/api/v1/instances/:id"`), never a bare fragment and never the
literal request path (`"/api/v1/instances/550e8400-..."`). No custom regex/normalization
function is needed — Plug's own compiled route table is the source of truth, so two
requests to `/api/v1/instances/550e8400-...` and `/api/v1/instances/6ba7b810-...`
collapse to the exact same `route_template` label value structurally, not by a
best-effort string transform.

**When no route matched** (a 404 from the top-level `match _ -> Response.not_found`
clauses): `conn.private[:plug_route]` is unset. `Letflow.Plugs.HttpMetrics` (§4) falls
back to the literal constant `"unmatched"` as the `route_template` label in that case —
a single, bounded value, never the raw unmatched path (which *would* be attacker/client
controlled and unbounded cardinality, e.g. `/api/v1/instances/../../etc/passwd`).

**Capture point:** `Plug.Conn.register_before_send/2`, registered as early as possible
in `Letflow.Router`'s own plug pipeline (before the `/api/v1` forward, alongside
`Letflow.Plugs.Cors`), so it fires once per request after routing/dispatch has fully
resolved (including inside forwarded sub-routers) but before the response is actually
sent — giving access to both the final `conn.status` and the final
`conn.private[:plug_route]`.

**Exclusion:** requests to `GET /metrics` itself are not instrumented (no
self-observation feedback loop; a Prometheus scrape target that includes its own
scrape-serving cost in its own request-count series is a well-known anti-pattern this
design deliberately avoids). `GET /health` and `GET /api/tenant-config` ARE instrumented
(they are real HTTP routes on `Letflow.Router` with a bounded, known set of templates).

---

## 3. The six OBS-02 metric families

All names below are literal Prometheus metric names this design commits to (snake_case,
`letflow_` prefix, unit-suffixed per Prometheus convention). "Label allow-list" for each
family is the ONLY set of keys the registry's `:telemetry` handler ever extracts from
event metadata into that family's label tuple — never a pass-through of whatever
metadata keys happen to be present, mirroring `lib/letflow/routers/metrics.ex`'s existing
`counter_group/2` discipline (§1's tenant-safety invariant, enforced per-family here).

| # | Prometheus name | Kind | Label allow-list | `:telemetry` event | Measurement keys | Metadata keys read | Emission site |
|---|---|---|---|---|---|---|---|
| 1 | `letflow_active_instances` | gauge | none | `[:letflow, :metrics, :active_instances]` | `%{count: non_neg_integer()}` | `%{}` | `Letflow.Scheduler.Poller`'s tick (§5), NOT request-path code |
| 1b | `letflow_active_instances_last_refresh_timestamp_seconds` | gauge | none | (companion value written directly to the registry by the same refresh step; no separate telemetry event) | n/a | n/a | same refresh step as #1 |
| 2 | `letflow_task_completions_total` | counter | `definition_status` (`draft\|active\|deprecated\|archived`) | `[:letflow, :task, :completed]` | `%{count: 1}` | `%{definition_status: :draft \| :active \| :deprecated \| :archived}` | `Letflow.Engine.complete_task/3` (after a successful completion, `engine.ex:1457`) |
| 3 | `letflow_event_append_duration_seconds` | histogram | none | `[:letflow, :event_store, :append, :stop]` (via `:telemetry.span/3`'s `start`/`stop`/`exception` triad) | `%{duration: non_neg_integer()}` (native time units, per `:telemetry.span/3` contract) | `%{}` | `Letflow.EventStore.append/2` (`event_store.ex:216`), wrapping the existing `Repo.transaction/2` call |
| 4 | `letflow_db_query_duration_seconds` | histogram | `query_type` (`select\|insert\|update\|delete\|other`) | `[:letflow, :repo, :query]` (**Ecto's own, already emitted** — no new call site) | `:total_time` (native time units, read from the event's existing measurements map) | `:query` (raw SQL text — parsed for its leading verb only, never stored or exposed itself) | none — attachment only |
| 5 | `letflow_http_requests_total` | counter | `method`, `route_template`, `status` | `[:letflow, :http, :request]` | `%{duration: non_neg_integer()}` (native time units) | `%{method: String.t(), route_template: String.t(), status: 100..599}` | `Letflow.Plugs.HttpMetrics` (§4), via `register_before_send/2` |
| 6 | `letflow_http_errors_total` | counter | `route_template` | same event as #5 (`[:letflow, :http, :request]`) | same as #5 | same as #5, but only `route_template` is extracted as a label | same as #5 — the registry's handler increments #6 only when `metadata.status >= 500` |

**Histogram bucket boundaries** (families 3 and 4), a fixed, documented constant in
`Letflow.Metrics.Registry` — Prometheus's own conventional default-latency ladder,
seconds: `0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, +Inf`. Not
configurable at runtime (a fixed bucket ladder is required for `histogram_quantile`
queries to remain meaningful across scrapes); a future requirement may make it
overridable per-deployment if a real need arises — not decided here, named as an open
question (§10).

**`query_type` derivation (family 4):** the leading whitespace-trimmed token of
`metadata.query`, upper-cased, matched against `SELECT | INSERT | UPDATE | DELETE`;
anything else (DDL, `BEGIN`/`COMMIT`, etc.) maps to `other`. This is read-only string
inspection of the SQL *keyword*, never the SQL text itself, and is never stored beyond
producing one of five fixed enum values — no unbounded cardinality risk, and the SQL
text (which could theoretically embed a literal value, though Ecto's parameterized
queries mean it normally does not) is never retained or exposed.

**Task-completion emission is *not* on the request's own critical path for response
latency** in the following sense: the `:telemetry.execute/3` call for family 2 happens
synchronously inside `complete_task/3` after the DB transaction has already committed,
so it can only add microseconds of same-process ETS-counter-increment overhead (no
network call, no GenServer round-trip — see §5) — satisfying OBS-02's "must not block
request processing" AC without needing an async dispatch mechanism.

---

## 4. `Letflow.Plugs.HttpMetrics` — request/error instrumentation

New module, `lib/letflow/plugs/http_metrics.ex`. A plain Plug (`init/1`, `call/2`), NOT
routed through `Letflow.Api.AuthorizedRouter` (mounted on `Letflow.Router` directly,
ahead of both the `/api/v1` forward and the `/api/tenant-config`/`/health` routes, so it
observes every request Letflow serves except `/metrics` itself — §2's exclusion).

```
@spec init(keyword()) :: keyword()
@spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
```

`call/2` records `System.monotonic_time/0` on entry, then calls
`Plug.Conn.register_before_send/2` with a callback that:
1. Reads `route_template` via `Plug.Router.match_path/1` (falling back to the
   `"unmatched"` constant per §2) unless the request path is exactly `/metrics`
   (excluded, §2).
2. Reads the final `conn.status`.
3. Computes elapsed duration against the entry timestamp.
4. Calls `:telemetry.execute([:letflow, :http, :request], %{duration: elapsed},
   %{method: conn.method, route_template: route_template, status: conn.status})`.

This is the ONLY call site referencing the `[:letflow, :http, :request]` event name and
the ONLY module coupling HTTP transport concerns to `:telemetry` — it never references
`Letflow.Metrics.Registry` directly, satisfying REQ-194's "emitting call sites do not
reference the registry module" AC structurally (this is a `grep`-checkable property: `grep
-rn "Letflow.Metrics.Registry" lib/letflow/plugs/http_metrics.ex lib/letflow/engine.ex
lib/letflow/event_store.ex` must return zero hits after implementation).

---

## 5. `Letflow.Metrics.Registry` — the ETS-backed collector

New module, `lib/letflow/metrics/registry.ex`. A `GenServer` whose **only** job is to
own one named, public ETS table (`:letflow_metrics`, `:set`, `:named_table, :public,
{:write_concurrency, true}`) and, on `init/1`, call `:telemetry.attach_many/4` to
subscribe itself to every event in §3's table — but the actual counter/gauge/histogram
mutation on each event happens via a **plain module function called directly by the
`:telemetry` dispatch mechanism in the emitting process**, doing a direct
`:ets.update_counter/4` / `:ets.insert/2` call — **not** a `GenServer.call/cast` to the
Registry process. This is the standard low-overhead `:telemetry`-handler pattern (the
same shape `telemetry_metrics`' own reporters use internally) and is what makes "must
not block request processing" true even under concurrent load: no request ever waits on
a message queue owned by a single process; every increment is a lock-free (well,
per-key-locked by the BEAM's own ETS implementation) atomic operation in the caller's own
process.

```
@type metric_key :: {family_name :: atom(), labels :: %{optional(atom()) => String.t() | atom()}}
@type histogram_bucket_key :: {family_name :: atom(), labels :: map(), :le, float() | :infinity}

@spec start_link(keyword()) :: GenServer.on_start()
@spec init(term()) :: {:ok, term()}

# Attached as :telemetry event handler functions -- called in the EMITTING process,
# never routed through this GenServer's own mailbox.
@spec handle_active_instances(...) :: :ok
@spec handle_task_completed(...) :: :ok
@spec handle_event_append_stop(...) :: :ok
@spec handle_repo_query(...) :: :ok
@spec handle_http_request(...) :: :ok

# Read-side, called only by Letflow.Metrics.Exposition -- never mutates.
@spec snapshot() :: %{
        gauges: %{metric_key() => number()},
        counters: %{metric_key() => non_neg_integer()},
        histograms: %{
          {family_name :: atom(), labels :: map()} =>
            %{buckets: %{(float() | :infinity) => non_neg_integer()}, sum: float(), count: non_neg_integer()}
        }
      }

# Called only by Letflow.Scheduler.Poller's tick (§6) -- the one gauge NOT
# telemetry-driven, because it needs a DB-availability-aware refresh cadence
# rather than an event-driven increment.
@spec set_active_instances(count :: non_neg_integer()) :: :ok
@spec mark_active_instances_refresh_failed() :: :ok
```

`set_active_instances/1` also writes the companion
`letflow_active_instances_last_refresh_timestamp_seconds` gauge to
`DateTime.utc_now() |> DateTime.to_unix(:second)` (current wall-clock time, since the
refresh just succeeded). `mark_active_instances_refresh_failed/0` writes **nothing** —
it exists purely as a documented, explicit no-op call site so a future reader (and a
test) can see the DB-unavailable path was considered deliberately, not omitted; the gauge
and its timestamp are simply left at their last successfully-written values, which is
exactly the graceful-degradation behavior §6 requires.

Every `handle_*` function's parameter list is `(event_name, measurements, metadata,
config)` — the standard four-argument `:telemetry` handler signature
(`:telemetry.attach_many/4`'s contract) — and every one of them, without exception,
extracts labels via the fixed allow-list literal to that family from §3's table, never
`Map.take(metadata, Map.keys(metadata))` or any dynamic pass-through. This is the
concrete, `grep`-able implementation of §1's tenant-safety invariant: reviewing every
`handle_*` function body is sufficient to confirm no identifying value can ever reach a
label, because the label-producing code for each family names its allowed keys
literally.

Supervision: added to `lib/letflow/application.ex`'s children list directly after
`{Registry, keys: :unique, name: Letflow.Registry}` (no ordering dependents in either
direction — mirrors the `Wasm.ModuleVersionRegistry` placement precedent, whose own
surrounding comment already states "order between these two is not load-bearing" for a
component with no startup-time callers).

`:telemetry.attach_many/4` is called from `Letflow.Metrics.Registry.init/1` itself
(not from `application.ex` directly), so the attachment lifecycle is owned by the same
process that owns the ETS table — a Registry crash-and-restart re-attaches cleanly (via
the same `init/1`) and re-creates an empty table; this is an accepted, standard
Prometheus semantic (counters are expected to reset across a process restart — remote
consumers use `rate()`/`increase()`, which tolerate resets natively). This is stated
explicitly here so it is not later mistaken for a bug: **a Registry restart zeroes all
in-memory metrics.** This is different from, and does not conflict with, the DB-
unavailability graceful degradation of §6, which is about the *data source* being
temporarily unreachable while the Registry process itself stays up.

---

## 6. DB-unavailable graceful degradation, and the staleness decision

Of the six families, only #1 (`letflow_active_instances`) is fed by a periodic **query**
rather than a request/event-driven telemetry emission — because "how many instances are
currently active, platform-wide, right now" is not naturally an event Letflow already
raises anywhere (unlike task completions, event appends, DB queries, and HTTP requests,
which all correspond to something that already happens exactly once per occurrence).
This is therefore the only family that can observe "the database is unavailable" at all;
families 2–6 read purely from already-updated ETS state at scrape time and never touch
`Letflow.Repo` inside the exposition request path itself — so the exposition endpoint
handler (§8) is, structurally, incapable of failing on DB unavailability for those five
families; it only ever reads `Letflow.Metrics.Registry.snapshot/0`.

**Mechanism, extending `Letflow.Scheduler.Poller`** (not a new periodic child — same
precedent REQ-188's retention sweep and ORD-04's lag sweeper both already follow):
`handle_info(:tick, state)` gains one more step, `maybe_refresh_active_instances(schemas,
state)`, called with the *same* `tenant_schemas()` list already computed for that tick's
timer-poll loop (no second query). For each schema, sum
`Letflow.Engine.count_instances_by_status(prefix: schema)`'s `:active` key across all
tenant schemas into one platform-wide total.

- If `tenant_schemas()` itself raises (the DB is down — per
  `lib/letflow/routers/metrics.ex`'s own moduledoc note: "Ecto/DBConnection surfaces pool
  exhaustion as a raised `DBConnection.ConnectionError`, not an error tuple"), the whole
  step must be wrapped so this **never crashes `Letflow.Scheduler.Poller`** — a crashed
  Poller would stop firing due timers platform-wide, a vastly worse regression than a
  stale metric. On a caught failure: call
  `Letflow.Metrics.Registry.mark_active_instances_refresh_failed/0` (a documented no-op,
  §5) and otherwise change nothing; the timer poll-and-fire loop for that tick still
  proceeds normally (it is computed independently, before this new step, exactly as
  `maybe_run_retention_sweep/2` is today).
- If `tenant_schemas()` succeeds but one individual schema's
  `count_instances_by_status/1` call fails (a single tenant's schema is corrupted or
  mid-migration), that schema's contribution is treated as `0` for this tick and the
  overall refresh still proceeds and still calls `set_active_instances/1` with the
  partial sum — a partial platform aggregate is judged acceptable here specifically
  because it is a large, low-precision-tolerant summary gauge, unlike REQ-078's
  per-tenant JSON figures (where a single bad counter meant the whole authenticated
  response had to fail per that module's own "no partially-populated body" rule — that
  rule was about not silently presenting a `0` as a real per-tenant figure to that
  tenant's own caller; this is a platform-wide aggregate with no single tenant depending
  on its exact precision).
- On success: `set_active_instances/1` writes both the gauge and its refresh timestamp.

**Staleness decision: YES, expose it — unlike R-Co.** R-Co tracks an internal staleness
flag but never renders it (this requirement's own description calls this out as "the
honest gap R-Co left and Letflow should not"). Letflow exposes
`letflow_active_instances_last_refresh_timestamp_seconds` as its own first-class gauge
(§3 row 1b) rather than a boolean flag, following the idiomatic Prometheus exporter
convention (`node_exporter`'s own `_boot_time_seconds`-style pattern: a raw timestamp,
not a computed boolean) — this lets any consumer (the SPA, a real Prometheus server via
a standard `time() - letflow_active_instances_last_refresh_timestamp_seconds > threshold`
alerting rule) decide their own staleness threshold, rather than Letflow baking in one
arbitrary cutoff. This is a genuine, stated improvement over R-Co's own recorded gap.

---

## 7. Emission call sites requiring first-party changes to existing modules

Two of the six families need a new call site in code that already exists; the design
states exactly where and how, without giving implementation bodies:

- **`Letflow.Engine.complete_task/3`** (`engine.ex:1457`): after `run_complete_task/6`
  returns success (and only then — a failed completion is not a completion), the task's
  owning instance's definition status must be resolved (already available via whatever
  path `run_complete_task/6` uses to load the instance/definition — this design does not
  prescribe re-deriving it if it is already in scope at that point) and
  `:telemetry.execute([:letflow, :task, :completed], %{count: 1}, %{definition_status:
  status})` called. This call references only `:telemetry`, never
  `Letflow.Metrics.Registry` or `Letflow.Metrics.Telemetry` — `:telemetry.execute/3` is
  the entire coupling surface.
- **`Letflow.EventStore.append/2`** (`event_store.ex:216`): the existing
  `Repo.transaction/2` call (line ~246) is wrapped in `:telemetry.span/3` with event
  prefix `[:letflow, :event_store, :append]` — `:telemetry.span/3` automatically emits
  `:start`, and either `:stop` (with a `:duration` measurement, native time units,
  computed by `:telemetry` itself) or `:exception` on the wrapped function's return/raise,
  so the histogram handler attaches to the `:stop` event specifically
  (`[:letflow, :event_store, :append, :stop]`) and never needs to compute timing itself.
  This preserves `append/2`'s existing `{:ok, _}/{:error, _}` return contract exactly —
  `:telemetry.span/3` re-raises/returns the wrapped function's own result unchanged.

No other existing module needs a new call site: family 4 attaches to an event Ecto
already emits (§0), and family 5/6 come from the new `Letflow.Plugs.HttpMetrics` plug
(§4), not from any existing router/handler code.

---

## 8. The exposition endpoint

| | |
|---|---|
| Path | `GET /metrics` |
| Mount point | `Letflow.Router`, top level — same tier as `GET /health` and `GET /api/tenant-config`, declared before the `/api/v1` forward. **Not** under `Letflow.Plugs.ApiPipeline`, **not** behind `Letflow.Plugs.AuthPipeline`. |
| Format | Prometheus exposition text (Axis 1) |
| `Content-Type` | `text/plain; version=0.0.4` |
| Auth | **None** (Axis 2) — no session/token check of any kind |
| Scope | **Global, platform-wide** (Axis 3) — one process-wide ETS-backed registry, no per-tenant branching of any kind |
| Body source | `Letflow.Metrics.Exposition.render/0`, which calls `Letflow.Metrics.Registry.snapshot/0` and formats each of the six families as `# HELP`/`# TYPE`/sample lines — the exact shape `parsePrometheusText/1` already parses |
| DB dependency | **None at request time** — `render/0` never calls `Letflow.Repo`; see §6 |

New module, `lib/letflow/routers/metrics_exposition.ex`,
`Letflow.Routers.MetricsExposition` — a plain `Plug.Router` (or a single-function Plug;
either is acceptable, ELIXIR-DEV's call, since there is exactly one route), forwarded
from `Letflow.Router` at `"/metrics"`. It does **not** `use Letflow.Api.AuthorizedRouter`
(there is no policy key to declare — this route is deliberately outside the
authorization-enforcement table entirely, the same way `/health` and
`/api/tenant-config` already are) and does **not** use `Letflow.Api.Response` (that
module is JSON/problem+json only, per `lib/letflow/routers/metrics.ex`'s own moduledoc
— this endpoint needs a plain-text body, so it builds its response directly via
`Plug.Conn.put_resp_content_type/2` + `Plug.Conn.send_resp/3`).

```
@spec render() :: String.t()
```

`Letflow.Metrics.Exposition.render/0` is a pure function: `Registry.snapshot/0` in,
formatted text out — trivially unit-testable without any HTTP layer involved.

---

## 9. Disposition of `lib/letflow/routers/metrics.ex`

**Decision: removed entirely.** Its own moduledoc has said since REQ-078 that "when S6
lands, this endpoint is expected to be superseded or rewritten; it is a placeholder
shape, not the design" — S6 has now landed the real subsystem. Concretely:

- Delete `lib/letflow/routers/metrics.ex` and its test(s).
- Remove `forward("/metrics", to: Letflow.Routers.Metrics)` from
  `lib/letflow/plugs/api_pipeline.ex:66`.
- **No route the SPA calls returns 404 afterward:** the SPA never called
  `/api/v1/metrics` in the first place (REQ-078's own moduledoc records this as "Known
  `web/` breakage" — `MetricsPage.tsx` always called the unversioned `/metrics`, which
  returned 404 before this requirement and now returns the real Prometheus body). Nothing
  is made worse; the SPA's actual call site starts working for the first time.
- `Letflow.Api.Authorization`'s `:MetricsRead` permission atom, its role-grants, and its
  `endpoint_policy_key("GET", "/metrics")` clause (evaluated against the now-deleted
  sub-router's mount tail) are left in place, unused, rather than removed — pruning a
  `Permission` enum member is a cross-cutting change (role matrix, its own tests,
  possibly other requirements' assumptions) outside this requirement's stated scope item
  5, which names only the router file's disposition. **This is named explicitly as an
  open question (§10), not silently left inconsistent:** a future small cleanup
  requirement may retire `:MetricsRead` once nothing references it, but this requirement
  does not do so unilaterally.
- `test/letflow/api/authorization_enforcement_test.exs`'s route-table introspection
  (`__authz_routes__/0`-based) will no longer see a `/metrics` entry once the router is
  deleted — ELIXIR-DEV must confirm that test's own allowlist/expectations are updated to
  match (removing an entry it previously required, not adding a new exemption, since the
  new `GET /metrics` route is deliberately outside `AuthorizedRouter`'s tree altogether,
  same as `/health`).

---

## 10. Dependency decision (mirrors REQ-148's tv-labs/lua sign-off precedent)

**No new "metrics library" is added.** `telemetry_metrics` and
`telemetry_metrics_prometheus_core` were considered and rejected: this subsystem has
exactly six fixed, hand-specified metric families with hand-specified, tenant-safety-
critical label allow-lists (§1, §3) — the generic `Telemetry.Metrics.counter/2`-style
declarative API those libraries provide is built for dynamically-many, ad hoc metric
definitions, and would require exactly the same hand-written label-extraction code this
design already specifies to enforce the "never extract an identifying label" invariant —
adopting a generic reporter library buys no real reduction in the code that has to be
reviewed for that invariant, while adding an external dependency's own release cadence,
transitive tree, and (for `telemetry_metrics_prometheus_core` specifically) an HTTP-
exposition path of its own that would need to be reconciled with `Letflow.Router`'s
existing top-level route table rather than reused directly. **A hand-rolled ETS registry
(`Letflow.Metrics.Registry`, §5) and a hand-rolled exposition formatter
(`Letflow.Metrics.Exposition`, §8) are the decision**, stated here explicitly per this
requirement's own AC3 ("if instead a registry is hand-rolled, the moduledoc states that
as the decision — one or the other, not silence").

**One mix.exs change IS proposed, and is flagged for REVIEWER sign-off:** adding an
explicit `{:telemetry, "~> 1.4"}` line to `mix.exs`'s `deps/0`. This is **not** a new
package fetch or a new transitive dependency tree — `:telemetry` v1.4.2 is already
present in `mix.lock`, already compiled, and already running inside every Letflow BEAM
node today, pulled in transitively by `bandit`, `db_connection`, `ecto`, `ecto_sql`, and
`plug`. The only change is that Letflow's own first-party code (`http_metrics.ex`,
`engine.ex`, `event_store.ex`, `metrics/registry.ex`) would, for the first time, call
`:telemetry.execute/3`/`:telemetry.attach_many/4` directly — standard Elixir hygiene says
a library whose API you call directly belongs in your own explicit deps list rather than
being borrowed opportunistically off another dependency's transitive graph (a future
Bandit/Ecto major version could in principle drop or relocate that transitive pull,
silently breaking Letflow's own code with no direct dependency declaration to pin
against).

This is flagged prominently, exactly as REQ-148 flagged `{:lua, "~> 1.0"}`, **even though
its risk profile is materially smaller** — no new bytes are fetched, no new native/NIF/
Port surface, no new license to vet (Apache-2.0, already accepted transitively), a
~100-line pure-Elixir pub/sub library already exercised by Bandit/Ecto in this exact
process. The requirement's own AC3 draws no size-based exception ("if a metrics
dependency is added to mix.exs, REVIEWER sign-off is recorded"), so this design does not
unilaterally decide the exception applies to itself — REVIEWER's sign-off on this
specific `mix.exs` line must be recorded in this requirement's PR before ELIXIR-DEV's
work is considered mergeable, per WF-02 Step 2d.

---

## 11. Full traceability — REQ-194's 10 `docs/requirements.yaml` acceptance criteria

| # | Acceptance criterion (paraphrased) | Design element |
|---|---|---|
| 1 | Explicit auth/scope/format decisions, with reasons, in the module moduledoc — no silent pick, none unstated | §1 (all three axes reasoned through); `Letflow.Metrics.Registry`/`Letflow.Routers.MetricsExposition` moduledocs must restate §1 verbatim per this requirement's own convention (REQ-078's own moduledoc is the template) |
| 2 | Format decision cites `parsePrometheusText`/`metricsApi.prometheusText()`'s `client.getText('/metrics')` as a binding contract; endpoint path is one `MetricsPage.tsx` actually reaches; a test hits that exact path | §0 (evidence), §1 Axis 1, §8 (`GET /metrics`, unversioned, top-level) |
| 3 | If a dependency is added, REVIEWER sign-off recorded; if hand-rolled, moduledoc states that decision — one or the other, not silence | §10 (hand-rolled registry/exposition stated explicitly; `{:telemetry, "~> 1.4"}` flagged for REVIEWER sign-off) |
| 4 | All six OBS-02 families present in the exposition output after exercising the behavior, parsed from the response body | §3 (all six families specified); §9's test strategy note below |
| 5 | HTTP-request metric labels by route template, not raw path — two requests differing only by path param produce ONE label combination | §2 (route-template mechanism via `Plug.Router.match_path/1`), §3 row 5 |
| 6 | Auth/scope decisions enforced and tested: no cross-tenant observation, OR (since global+unauthenticated was chosen) no label ever carries a tenant-identifying value | §1 Axis 2/3 (decision + reasoning), §3 (per-family label allow-lists), §5 (`handle_*` functions' fixed-key extraction as the enforced mechanism) — test: assert, for every family, that its rendered label set intersected with `{tenant identifiers seen anywhere in two distinct tenants' fixtures}` is empty |
| 7 | Endpoint returns successfully with last-known values when DB is unavailable, tested with DB made unreachable | §6 (mechanism: `maybe_refresh_active_instances/2` failure isolation; exposition never touches `Repo` for families 2–6) |
| 8 | Instrumentation emitted via `:telemetry`; emitting call sites do not reference the registry module; confirmed by grep | §4, §5, §7 (each call site named; grep command given in §4) |
| 9 | Disposition of `lib/letflow/routers/metrics.ex` explicit (removed or retained-with-restated-role); no SPA-called route 404s afterward | §9 (removed; SPA-safety argument) |
| 10 | `mix test` and `mix compile --warnings-as-errors` both pass, real output quoted | Not a design element — ELIXIR-DEV/TEST-RUNNER responsibility; design's chosen `@spec`s give both commands something to enforce |

---

## 12. Open questions (named explicitly, not silently resolved)

1. `:MetricsRead`'s fate in `Letflow.Api.Authorization` after `lib/letflow/routers/metrics.ex`
   is deleted (§9) — left in place, unused, pending a future small cleanup requirement.
2. Histogram bucket boundaries (§3) are a fixed constant, not runtime-configurable — a
   future requirement may add per-deployment overrides if a real operational need
   surfaces; not built here.
3. `Letflow.Engine.complete_task/3`'s exact path to the completed task's definition
   status (needed for family 2's `definition_status` label) is not prescribed here in
   detail — ELIXIR-DEV should reuse whatever the existing function already resolves in
   scope at the point of a successful completion rather than issuing a new query, but the
   precise existing binding to reuse was not traced line-by-line in this design pass.
4. Whether `letflow_active_instances`'s refresh should run on every scheduler tick
   (this design's default) or on a coarser, separately-configurable cadence (mirroring
   `Scheduler.retention_due?/1`'s own pattern) is left to ELIXIR-DEV's judgment at
   implementation time — both are compatible with this design's `set_active_instances/1`
   contract; this design does not mandate a specific interval.
