defmodule Letflow.Routers.MetricsExposition do
  @moduledoc """
  REQ-194 (design `lib/letflow/design/req194-prometheus-metrics.md`) -- the real
  Prometheus metrics subsystem `Letflow.Routers.Metrics` (REQ-078) always said would
  supersede it: "S6 observability is the owning stage for Letflow's metrics
  subsystem... this endpoint is expected to be superseded or rewritten; it is a
  placeholder shape, not the design." S6 has now landed it. `Letflow.Routers.Metrics`
  is **removed entirely** (design §9) -- see this module's own §"Disposition" below.

  Mounted by `Letflow.Router` at the TOP LEVEL, `GET /metrics`, declared before the
  `/api/v1` forward -- same tier as `GET /health` and `GET /api/tenant-config`. **Not**
  under `Letflow.Plugs.ApiPipeline`, **not** behind `Letflow.Plugs.AuthPipeline` --
  there is no tenant context to resolve and no session to check (design §8).

  ## REQ-078's three recorded divergences from R-Co, decided explicitly (AC1)

  | Axis | R-Co (`metrics.zig`) | REQ-078 (retired) | **This requirement's decision** | Reason |
  |---|---|---|---|---|
  | **Format** | Prometheus exposition text | JSON | **Prometheus exposition text**, `Content-Type: "text/plain; version=0.0.4"` | `web/src/api/metrics.ts`'s `parsePrometheusText/1` and `metricsApi.prometheusText/0 = client.getText('/metrics')` are already-committed SPA code that parses Prometheus text, not JSON, from an unversioned `GET /metrics`. Serving JSON would break that already-shipped consumer (design §1 Axis 1). |
  | **Auth** | unauthenticated | authenticated (`/api/v1/metrics`) | **Unauthenticated** -- no session/token check of any kind | `:MetricsRead` is unconditionally `:Allow` for every authenticated caller regardless of tenant (`lib/letflow/api/authorization.ex`), so "authenticate, then serve one figure" was never a meaningful per-caller gate -- REQ-078's real protection was tenant-scoping the query, not the auth check. A real Prometheus scrape target also has no per-tenant credential concept to attach a scrape job to, and the SPA's own call site (`client.getText('/metrics')`) sends no auth header. Reverting auth to none is safe ONLY because scope (below) is also resolved by removing all identifying labels, not by reintroducing R-Co's naive global-figures-to-everyone shape (design §1 Axis 2/3). |
  | **Scope** | platform-global, in-memory registry, no tenant label on any family | per-tenant (every figure computed inside the caller's own schema) | **Global, platform-wide** -- one process-wide `Letflow.Metrics.Registry`, no per-tenant branching of any kind | Making this endpoint global AND unauthenticated is safe **only** because of the invariant below -- global scope without it would turn `GET /metrics` into a cross-tenant enumeration surface, worse than REQ-078's own feared failure mode. |

  ## THE tenant-safety invariant this global, unauthenticated endpoint rests on (AC6)

  No metric family emitted by this subsystem EVER carries a `tenant_id`,
  `definition_id`, `instance_id`, `task_id`, `actor_id`, or any other per-tenant or
  per-entity identifier as a label value -- not filtered out at exposition time, but
  never extracted from event metadata into a label in the first place, at
  `Letflow.Metrics.Registry`'s `:telemetry` handler layer. Every family's label set is
  a fixed, hand-built allow-list (see that module's moduledoc and its `handle_*`
  function bodies -- each names its allowed label keys literally, which is what makes
  this a `grep`/code-review-able property rather than a runtime promise). One concrete
  consequence: R-Co's literal "task-completions counter labelled by definition" family
  is restated here as labelled by `definition_status` (`draft|active|deprecated|archived`,
  a closed 4-value enum), never `definition_id` or a definition name -- a raw
  `definition_id` is exactly the per-tenant identifier this invariant forbids on a
  global, unauthenticated label (design §1).

  If a future change to this subsystem is tempted to add a label carrying any
  per-tenant identifier, that is a direct reopening of the cross-tenant-disclosure
  risk this design closed -- flag it to SECURITY-REVIEWER/REVIEWER rather than adding
  it silently.

  ## Dependency decision (AC3)

  **Hand-rolled, not a metrics library** -- see `Letflow.Metrics.Registry`'s moduledoc
  for the full reasoning (design §10). The one dependency change this requirement
  makes is promoting the already-transitively-present `:telemetry` v1.4.2 to a direct
  `mix.exs` dependency; REVIEWER sign-off for that specific line is recorded in this
  requirement's PR per AC3.

  ## DB-unavailable graceful degradation (AC7, design §6)

  `render/0` (`Letflow.Metrics.Exposition`) never calls `Letflow.Repo` -- it only ever
  reads `Letflow.Metrics.Registry.snapshot/0`, which is pure ETS state. Of the six
  families, only `letflow_active_instances` is fed by a periodic DB query (a
  background scheduler tick, since "how many instances are active right now" is not
  an event Letflow already raises anywhere -- see `Letflow.Metrics.Registry`'s own
  moduledoc for exactly which process refreshes it); families 2-6 read purely from
  already-updated ETS state and never touch the database inside this endpoint's own
  request path, so this handler is structurally incapable of failing on DB
  unavailability. When that background refresh fails, the gauge and its
  companion `letflow_active_instances_last_refresh_timestamp_seconds` staleness gauge
  are simply left at their last successfully-written values (`Letflow.Metrics.Registry.mark_active_instances_refresh_failed/0`)
  -- this endpoint keeps serving 200 with the last-known figure, never an error.

  **Staleness decision: exposed, unlike R-Co.** R-Co tracks an internal staleness flag
  but never renders it. Letflow exposes
  `letflow_active_instances_last_refresh_timestamp_seconds` as its own first-class
  gauge (a raw Unix timestamp, `node_exporter`'s own `_boot_time_seconds` convention)
  rather than a boolean flag, so any consumer can compute and threshold staleness
  itself (`time() - letflow_active_instances_last_refresh_timestamp_seconds >
  threshold`) rather than Letflow baking in one arbitrary cutoff -- a raw
  timestamp lets any consumer define its own staleness threshold instead of
  trusting one fixed boolean the exporter decided for them (design §6).

  ## Disposition of `lib/letflow/routers/metrics.ex` (AC9)

  **Removed entirely**, per design §9 -- its own moduledoc anticipated exactly this
  ("when S6 lands, this endpoint is expected to be superseded or rewritten"). The SPA
  never called `/api/v1/metrics` in the first place (REQ-078's own moduledoc recorded
  this as known `web/` breakage: `MetricsPage.tsx` always called the unversioned
  `/metrics`, which 404'd before this requirement). No route the SPA calls 404s as a
  result of this removal -- the SPA's actual call site starts working for the first
  time. `Letflow.Api.Authorization`'s `:MetricsRead` permission atom and its
  `endpoint_policy_key("GET", "/metrics")` clause are left in place, unused, per
  design §10's open question -- pruning that enum member is a separate, cross-cutting
  cleanup this requirement does not do unilaterally.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/" do
    body = Letflow.Metrics.Exposition.render()

    conn
    |> put_resp_content_type("text/plain; version=0.0.4", nil)
    |> send_resp(200, body)
  end

  match _ do
    Letflow.Api.Response.not_found(conn)
  end
end
