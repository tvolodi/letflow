defmodule Letflow.Routers.Metrics do
  @moduledoc """
  Metrics sub-router (REQ-078, design
  `lib/letflow/design/req078-supporting-routes.md` §11). Ports the *endpoint
  shape* of `src/api/routes/metrics.zig` (59 lines) and nothing else. Mounted
  at `/metrics` by `Letflow.Plugs.ApiPipeline`, so the full path is
  `GET /api/v1/metrics`.

  | Handler | Method/path      | Delegates                                                                                                                | Permission | Response |
  |---------|------------------|--------------------------------------------------------------------------------------------------------------------------|------------|----------|
  | metrics | `GET /metrics`   | `Letflow.Engine.count_instances_by_status/1`, `Letflow.Engine.count_tasks_by_status/1`, `Letflow.Definitions.count_definitions_by_status/1` | see below  | 200, JSON counter map |

  ## Divergences from R-Co's `metrics.zig` — all three are deliberate

  | Dimension | R-Co (`metrics.zig`) | Letflow | Why |
  |---|---|---|---|
  | **Auth** | unauthenticated — `metrics.zig:20` says so verbatim; mounted top-level at `main.zig:457` | **authenticated** — `/api/v1/metrics`, behind `Letflow.Plugs.AuthPipeline` | Every Letflow figure comes from a tenant schema; reaching one requires `Letflow.Api.Context.scoped_repo_opts/1`, which requires `conn.assigns[:auth_context]`. An unauthenticated endpoint could only be empty or cross-tenant. |
  | **Scope** | platform-global, in-memory `MetricsRegistry` | **per-tenant** — every figure computed inside the caller's own schema | See the tenant-exposure rule below. |
  | **Format** | Prometheus exposition text (`content_type = PROMETHEUS_CONTENT_TYPE`) | **JSON**, via `Letflow.Api.Response.ok/2` | `Letflow.Api.Response` defines only `application/json` and `application/problem+json`; adding a Prometheus-text helper is scope. JSON is this codebase's universal response convention. |

  > **Do not "correct" any of the three back toward R-Co.** Reverting the
  > scope divergence in particular would reintroduce a cross-tenant
  > disclosure — see the tenant-exposure rule.

  **No metrics subsystem is built here.** This endpoint computes a handful of
  `COUNT(*)` aggregates over tables that already exist in the caller's tenant
  schema. It builds no registry, no collector, no gauge, no histogram, no
  scrape target and no in-memory counter state. **S6 observability is the
  owning stage for Letflow's metrics subsystem** — see
  `docs/migration/stage-4-api-surface.md`'s group-(b) table and R-Co's own
  `obs_metrics` module (`src/api/routes/metrics.zig:9`,
  `collectGlobalPrometheusText`), which Letflow has not ported. When S6 lands,
  this endpoint is expected to be superseded or rewritten; **it is a
  placeholder shape, not the design.**

  Measured, not assumed, at the time REQ-078 was written: Letflow has **no**
  metrics registry and **no** telemetry (`grep -rln "telemetry\\|Telemetry" lib/`
  matched only design prose, never `.ex` code) and had **no** counting
  functions at all (`grep -rn "def count_\\|@spec count_" lib/letflow/`
  returned zero hits). So "expose whatever counters exist today" had the
  literal answer *none*, and the three `COUNT(*)` context functions REQ-078
  added are the honest floor — not a subsystem.

  ## Tenant-exposure rule: PER-TENANT-SCOPED

  Every counter this endpoint returns is computed **within the calling
  tenant's own schema**, via `Letflow.Api.Context.scoped_repo_opts/1`. **No
  platform-wide figure, and no figure derived from more than one tenant,
  appears in the response body at all.**

  This is not a stylistic choice.
  `Letflow.Api.Authorization.evaluate_access/2` short-circuits `:MetricsRead`
  to `%AccessDecision{kind: :Allow}` **unconditionally**, before the
  permission check ever runs (`lib/letflow/api/authorization.ex:281-282` — a
  faithful port of `authorization.zig`). Every authenticated caller of every
  tenant therefore holds `:MetricsRead` in practice. "Aggregate platform
  counters to `:MetricsRead` holders" would mean "platform-wide figures to
  every authenticated caller of every tenant" — a cross-tenant disclosure
  (INV-1). Per-tenant scoping is the only option compatible with that
  short-circuit.

  Consequence: **this route does not call `evaluate_access/2` at all.** A call
  whose result is a compile-time constant `:Allow` is not a gate; it is
  decoration that would read as a gate to the next maintainer. Tenant scoping
  is the real protection here, and it is structural. The absent permission
  gate is recorded with the other four REQ-078 endpoints that ship
  authenticated-but-ungated; **REQ-131 is the closer** for all of them.

  `"scope" => "tenant"` is a constant in the response body, present
  specifically so a reader of a captured response can see at a glance that it
  is not platform-wide.

  ## 200 is emitted only on a complete success

  **200 is emitted only when `scoped_repo_opts/1` returns `{:ok, _}` and all
  three counter functions return `{:ok, _}`. Any other result — from any of
  the four calls, whatever its reason — is `Response.internal_error/1`
  (500).** There is no fall-through-to-200 branch, and no partially-populated
  body is ever emitted: a counter that could not be computed must not be
  rendered as `0`, because a silent zero in a metrics response is
  indistinguishable from a true zero and is worse than an error.

  No 503 branch — Ecto/DBConnection surfaces pool exhaustion as a raised
  `DBConnection.ConnectionError`, not an error tuple.

  ## Known `web/` breakage (out of scope for REQ-078, but recorded)

  `web/src/api/metrics.ts:127` calls `client.getText('/metrics')` and
  `parsePrometheusText` parses the result. This endpoint serves **JSON at
  `/api/v1/metrics`**, so `web/src/pages/admin/MetricsPage.tsx` will break and
  needs a FRONTEND-DEV follow-up. REQ-078 is backend-only; this is a real,
  known breakage recorded here so it is not discovered in UAT.

  ## Ordering guarantee

  Honours the contract stated in `Letflow.Routers.Tenants`'s moduledoc section
  **"Ordering guarantee (design §6.1)"**: no `Repo` call of any kind happens
  before the scoped prefix has been resolved. Structural here — **this module
  performs no `Repo` call at all**; all three counts are inside context
  modules whose `opts` argument *is* the prefix.
  """

  use Plug.Router

  alias Letflow.Api.Context
  alias Letflow.Api.Response
  alias Letflow.Definitions
  alias Letflow.Engine

  plug(:match)
  plug(:dispatch)

  get "/" do
    handle_metrics(conn)
  end

  match _ do
    Response.not_found(conn)
  end

  # ── GET /metrics (design §11) ─────────────────────────────────────────────

  defp handle_metrics(conn) do
    with {:ok, opts} <- Context.scoped_repo_opts(conn),
         {:ok, instances} <- Engine.count_instances_by_status(opts),
         {:ok, tasks} <- Engine.count_tasks_by_status(opts),
         {:ok, definitions} <- Definitions.count_definitions_by_status(opts) do
      Response.ok(conn, metrics_map(instances, tasks, definitions))
    else
      # Positive rule, deliberately: ANY non-{:ok, _} from ANY of the four
      # calls is a 500. There is no fall-through-to-200 branch and no
      # partially-populated body -- see this module's moduledoc.
      _any_failure -> Response.internal_error(conn)
    end
  end

  # ── Response allowlist (INV-2) ────────────────────────────────────────────

  defp metrics_map(instances, tasks, definitions) do
    %{
      # Constant: this body is never platform-wide.
      "scope" => "tenant",
      "generated_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "instances" => counter_group(instances, [:active, :completed, :cancelled, :error]),
      "tasks" => counter_group(tasks, [:pending, :completed, :cancelled]),
      "definitions" => counter_group(definitions, [:draft, :active, :deprecated, :archived])
    }
  end

  # Every status key is always present (the context functions zero-fill their
  # closed enums), plus a derived "total". Hand-built key list, never a
  # pass-through of whatever atoms the query happened to return.
  defp counter_group(counts, statuses) do
    statuses
    |> Enum.map(fn status -> {Atom.to_string(status), Map.get(counts, status, 0)} end)
    |> Map.new()
    |> Map.put("total", Enum.reduce(statuses, 0, &(&2 + Map.get(counts, &1, 0))))
  end
end
