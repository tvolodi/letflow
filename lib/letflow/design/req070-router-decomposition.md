# REQ-070 — Router Decomposition Design

**Stage:** S4  
**Framework:** Plug/Bandit (executes `docs/migration/decisions/0001-web-framework.md`
addendum 2026-08-20 — Plug/Bandit stands; no Phoenix).  
**Owner:** CODE-DESIGNER  
**Validator:** CODE-DESIGN-VALIDATOR

---

## 0. Summary of Decisions

- **Shared middleware:** Option A — a single `Letflow.Plugs.ApiPipeline` module
  (`use Plug.Router`, which extends `Plug.Builder`) that is mounted once in the
  top-level router via `forward "/api/v1", to: Letflow.Plugs.ApiPipeline`. Sub-routers
  declare no middleware; the pipeline is applied to all ten tenant-scoped sub-routers
  at this single delegation point. See §3 for the full justification.
- **`/health`:** Handled directly in the top-level router, above the `forward "/api/v1"`
  delegation. It never reaches `Letflow.Plugs.ApiPipeline`. Contract preserved exactly:
  `{"status":"ok"}` at 200, no auth, no DB.
- **Catch-all 404:** Uses `Letflow.Api.Response.not_found/1` (REQ-066), emitting
  `application/problem+json` with RFC 9457 shape. Present in both the top-level router
  and in each sub-router stub.

---

## (a) Top-Level Router — `lib/letflow/router.ex`

### Module: `Letflow.Router`

`use Plug.Router`

**Plug chain** (complete, in declaration order):

| Position | Plug | Reason |
|---|---|---|
| 1 | `plug :match` | Standard Plug.Router — matches route and sets `conn.private[:plug_route]` |
| 2 | `plug :dispatch` | Executes the matched handler |

No other plugs in the top-level router. `Plug.Parsers` and all tenant-scoped middleware
move to `Letflow.Plugs.ApiPipeline` (§3), so they do not run on the `/health` path.

**Routes** (in match-order; Plug.Router matches top-to-bottom):

| Method | Path | Handler | Auth | DB |
|---|---|---|---|---|
| `GET` | `/health` | `Letflow.Api.Response.send_json(conn, 200, %{status: "ok"})` | none | none |
| `*` | `/api/v1/*_glob` | `forward "/api/v1", to: Letflow.Plugs.ApiPipeline` | delegated to pipeline | delegated |
| `*` | `_` (catch-all) | `Letflow.Api.Response.not_found(conn)` | none | none |

**`GET /health` contract preservation:**  
`Letflow.Api.Response.send_json/3` sets `Content-Type: application/json; charset=utf-8`
and sends status 200 with body `{"status":"ok"}`. This is byte-compatible with today's
behaviour (same function, same arguments). `deploy/redeploy-test.sh`'s post-deploy
health check depends on this exact contract; any body change breaks deployment.

**Catch-all — RFC 9457 404:**  
`Letflow.Api.Response.not_found(conn)` calls `Letflow.Api.Error.not_found/0` and
`send_problem/2`, emitting `Content-Type: application/problem+json; charset=utf-8` and
status 404 with the five-key RFC 9457 body: `type`, `title`, `status`, `detail`,
`trace_id`. This replaces the previous `{"error":"not_found"}` map.

**`Plug.Router.forward/2` path-stripping:**  
`forward "/api/v1", to: Letflow.Plugs.ApiPipeline` strips the `/api/v1` prefix from
`conn.path_info` and `conn.request_path` before invoking `Letflow.Plugs.ApiPipeline`.
Requests to `/api/v1/instances/abc` arrive at `ApiPipeline` with path `/instances/abc`.
(See OQ-1 for a verification note.)

**Moduledoc content requirements** (for ELIXIR-DEV to include verbatim):

1. Citation line:  
   `Executes docs/migration/decisions/0001-web-framework.md addendum (2026-08-20) —
   Plug/Bandit stands.`

2. Deferred route table — all eleven modules with owning stage:

   PROVENANCE (historical, not current decision authority):
   | Letflow module (pending) | R-Co source | Owning stage |
   |---|---|---|
   | `Letflow.Routers.Dlq` | `dlq.zig` | S6 (dead-letter queue subsystem) |
   | `Letflow.Routers.Services` | `services.zig` | S6 (service catalog) |
   | `Letflow.Routers.PlatformMigrations` | `platform_migrations.zig` | S6 (platform migration runner) |
   | `Letflow.Routers.Webhooks` | `webhooks.zig` | S6 (webhook dispatch subsystem) |
   | `Letflow.Routers.SimulationTest` | `simulation_test.zig` | S7 (simulation harness) |
   | `Letflow.Routers.ProcessModules` | `process_modules.zig` | S5 (process-module packaging) |
   | `Letflow.Routers.Entities` | `entities.zig` | S5/S6 (entity/data-model subsystem) |
   | `Letflow.Routers.EntityQuery` | `entity_query.zig` | S5/S6 (same, plus query compiler) |
   | `Letflow.Routers.AgentRequests` | `agent_task_specs.zig` et al. | post-S6 (runtime-agent subsystem) |
   | `Letflow.Routers.AgentResponses` | `agent_sandboxes.zig` et al. | post-S6 (runtime-agent subsystem) |
   | `Letflow.Routers.AgentEvents` | `agent_artifacts.zig` et al. | post-S6 (runtime-agent subsystem) |

3. Readiness statement:  
   PROVENANCE (historical, not current decision authority):
   `Readiness endpoint (R-Co routes/health.zig handleReady, backed by
   src/api/health/readiness.zig + subsystems.zig) is deliberately not ported — it
   requires S6 observability subsystem probes that do not yet exist. Only the liveness
   endpoint (GET /health) is preserved here.`

---

## (b) Per-Subsystem Sub-Router Stubs — `lib/letflow/routers/*.ex`

These are stubs. No real routes are declared here; owning requirements (REQ-071+) add
them. All ten modules share the same structure.

**NOTE:** `/health` is handled by the top-level router directly and is NOT forwarded to
any sub-router. It is auth-free and must remain outside the tenant-scoped middleware
pipeline. The ten sub-routers below are all tenant-scoped.

### Module structure (common to all ten)

`use Plug.Router`

Plug chain:
- `plug :match`
- `plug :dispatch`

Catch-all: `match _ do Letflow.Api.Response.not_found(conn) end`

Moduledoc template: "Stub — routes added by [owning requirement]. All unmatched
requests return the RFC 9457 404 problem document via
`Letflow.Api.Response.not_found/1`. Mounted at [path prefix] by
`Letflow.Plugs.ApiPipeline`."

### Sub-router roster

| Elixir module | Path prefix in `ApiPipeline` | File path | Owning requirement |
|---|---|---|---|
| `Letflow.Routers.Identity` | `/identity` | `lib/letflow/routers/identity.ex` | REQ-073/074/075/076 |
| `Letflow.Routers.Instances` | `/instances` | `lib/letflow/routers/instances.ex` | REQ-079/080 |
| `Letflow.Routers.Definitions` | `/definitions` | `lib/letflow/routers/definitions.ex` | REQ-081/082 |
| `Letflow.Routers.Tasks` | `/tasks` | `lib/letflow/routers/tasks.ex` | REQ-083/085 |
| `Letflow.Routers.Promotions` | `/promotions` | `lib/letflow/routers/promotions.ex` | REQ-077 |
| `Letflow.Routers.Onboarding` | `/onboarding` | `lib/letflow/routers/onboarding.ex` | REQ-076 |
| `Letflow.Routers.Audit` | `/audit` | `lib/letflow/routers/audit.ex` | REQ-078 |
| `Letflow.Routers.TenantConfig` | `/tenant-config` | `lib/letflow/routers/tenant_config.ex` | REQ-078 |
| `Letflow.Routers.Validation` | `/validation` | `lib/letflow/routers/validation.ex` | REQ-078 |
| `Letflow.Routers.Metrics` | `/metrics` | `lib/letflow/routers/metrics.ex` | REQ-078 |

**Invariant:** No sub-router module declares a path that belongs to another
sub-router's prefix. Enforced by structure — each module owns exactly its listed prefix
and nothing else.

**No sub-router imports or references `Letflow.Plugs.ApiPipeline`.** Middleware is
applied at the pipeline layer, not inside the sub-routers.

---

## (c) Shared Middleware Chain — `lib/letflow/plugs/api_pipeline.ex`

### Decision: Option A chosen

**Option A:** `Letflow.Plugs.ApiPipeline` (uses `use Plug.Router`, which extends
`Plug.Builder`) is the single declaration site for shared middleware. The top-level
router delegates the entire `/api/v1` prefix to it via one `forward` call. Sub-routers
receive requests only after the pipeline has run; they declare no middleware themselves.

**Option B rejected:** Inline plug declarations in `Letflow.Router` before `forward/2`
calls are structurally incompatible with the `/health` bypass requirement. In
`Plug.Router`, plugs declared before `:dispatch` execute for every matched route —
there is no built-in conditional that would prevent `Plug.Parsers` or
`Letflow.Plugs.AuthPipeline` from running on `GET /health` if they were declared at
the top-level router level. Option A avoids this by delegating `/api/v1` as a block
before any tenant-scoped plugs execute.

### Module: `Letflow.Plugs.ApiPipeline`

`use Plug.Router` (not `use Plug.Builder` — because it also declares `forward/2`
routes to sub-routers; `Plug.Router` composes `Plug.Builder`'s plug macro into itself).

**Plug chain** (the single declaration site — complete, in declaration order):

| Position | Plug | Notes |
|---|---|---|
| 1 | `plug Plug.Parsers, parsers: [:json], json_decoder: Jason, length: <cap>` | JSON body parsing with length enforcement; cap value per OQ-1 below. Placed before auth so body is available for auth token extraction from JSON payloads if needed. |
| 2 | `plug Letflow.Plugs.AuthPipeline` | Already built (REQ-021); bearer-token validation and role resolution. Must run before TenantStatus. |
| 3 | `plug Letflow.Plugs.TenantStatus` | Already built (REQ-021); checks tenant active/suspended state. Requires auth to have resolved the tenant identity first. |
| 4 | `plug :match` | Standard Plug.Router route matching. |
| 5 | `plug :dispatch` | Executes the matched forward/2 handler. |

**Deferred plugs** (listed in `ApiPipeline`'s moduledoc, not declared until owning
requirements land):

PROVENANCE (historical, not current decision authority):
| Deferred plug | R-Co source | Owning stage |
|---|---|---|
| `Letflow.Plugs.Trace` | `trace.zig` | S6 (observability infrastructure) |
| `Letflow.Plugs.ContentType` | `content_type.zig` | S4 (to port, no owning REQ yet) |
| `Letflow.Plugs.Validate` | `validate.zig` | S4 (REQ-068 shape already ported) |
| `Letflow.Plugs.RateLimit` | `rate_limit.zig` | S4 (to port) |
| `Letflow.Plugs.QuotaEnforcement` | `quota_enforcement.zig` | S4 (to port) |
| `Letflow.Plugs.OutboxCap` | `outbox_cap.zig` | S6 (outbox subsystem) |
| `Letflow.Plugs.AgentAuth` | `agent_auth.zig` | post-S6 (runtime-agent subsystem, out of scope) |

**Routes declared in `ApiPipeline`** (after `:dispatch`; paths are relative to
`/api/v1` after the top-level router strips that prefix):

```
forward "/identity",     to: Letflow.Routers.Identity
forward "/instances",    to: Letflow.Routers.Instances
forward "/definitions",  to: Letflow.Routers.Definitions
forward "/tasks",        to: Letflow.Routers.Tasks
forward "/promotions",   to: Letflow.Routers.Promotions
forward "/onboarding",   to: Letflow.Routers.Onboarding
forward "/audit",        to: Letflow.Routers.Audit
forward "/tenant-config", to: Letflow.Routers.TenantConfig
forward "/validation",   to: Letflow.Routers.Validation
forward "/metrics",      to: Letflow.Routers.Metrics
match _ -> Letflow.Api.Response.not_found(conn)
```

The `match _` here handles paths under `/api/v1` that don't match any sub-router
prefix (e.g., `GET /api/v1/unknown`). The top-level router's own catch-all handles
paths outside `/api/v1` entirely.

**Single declaration site verification:**  
`grep -rn "plug Letflow.Plugs.AuthPipeline\|plug Letflow.Plugs.TenantStatus\|Plug.Parsers" lib/letflow/`
MUST return lines only in `lib/letflow/plugs/api_pipeline.ex`. No sub-router file
contains these plug declarations. The single `forward "/api/v1"` in `lib/letflow/
router.ex` is the only external reference to `ApiPipeline`; the module's `defmodule`
body is the declaration site.

**Sub-routers this chain applies to:** All ten tenant-scoped sub-routers listed in §(b).
`GET /health` is excluded by design (handled before `forward "/api/v1"` is reached).
The top-level router's own `match _` catch-all is also excluded (never forwarded).

---

## (d) Test Surface

Six acceptance criteria mapped to concrete test files and approaches.

### AC-1 — `GET /health` returns 200 `{"status":"ok"}`, no auth, no DB

**File:** `test/letflow/router_test.exs`

**Approach:** `Plug.Test.conn(:get, "/health")` called against
`Letflow.Router.call(conn, [])`. Assert `conn.status == 200` and
`Jason.decode!(conn.resp_body) == %{"status" => "ok"}` and
`conn.resp_headers` contains `{"content-type", "application/json; charset=utf-8"}`.

The test file MUST NOT set up `Ecto.Sandbox` or start the Repo. Since `/health` calls
no Ecto function, the assertion passes regardless of DB availability. A reasonable
additional assertion: the test module is tagged `async: true` (confirming no Repo
dependency). Any DB call in the handler would crash in this context, which is the
intended failure mode.

### AC-2 — Sub-router isolation: one sub-router callable without top-level router

**File:** `test/letflow/routers/identity_test.exs` (representative; all sub-routers
have the same structure so testing one proves the pattern)

**Approach:** `Plug.Test.conn(:get, "/some/path")` called directly against
`Letflow.Routers.Identity.call(conn, [])`. Assert `conn.status == 404` and body has
RFC 9457 shape. This confirms `Letflow.Routers.Identity` is a standalone `Plug` with
no dependency on the top-level router or `Letflow.Plugs.ApiPipeline`.

Inspection confirmation (for REVIEWER): verify that each of the ten
`lib/letflow/routers/*.ex` files contains `use Plug.Router` and nothing else in its
plug chain besides `:match`/`:dispatch`.

### AC-3 — Unrouted path returns RFC 9457 404 problem document

**File:** `test/letflow/router_test.exs` (same file as AC-1)

**Approach:** `Plug.Test.conn(:get, "/this/does/not/exist")` called against
`Letflow.Router.call(conn, [])`. Assert:
- `conn.status == 404`
- `conn.resp_headers` contains a `content-type` header matching
  `"application/problem+json; charset=utf-8"` (exact string produced by
  `Plug.Conn.put_resp_content_type/2`)
- `Jason.decode!(conn.resp_body)` has keys `"type"`, `"title"`, `"status"`,
  `"detail"`, `"trace_id"` (RFC 9457 five-key shape) and `"status" == 404`

**Also test:** `Plug.Test.conn(:get, "/api/v1/nonexistent-subsystem")` via the full
stack (`Letflow.Router.call/2`). This exercises the `ApiPipeline`'s own catch-all,
confirming both 404 paths emit the same RFC 9457 shape. This second assertion
requires that the pipeline's shared middleware chain does not crash for an unauthenticated
request — note that `Letflow.Plugs.AuthPipeline` likely halts with 401 for an
unauthed request, so the observed status here may be 401 rather than 404 depending on
AuthPipeline's halt behavior. ELIXIR-DEV must check AuthPipeline's behaviour and either
(a) provide a test token or (b) write a separate AC-3 sub-case for authenticated
unrouted paths. If AuthPipeline halts with 401 before the sub-router's catch-all fires,
the correct assertion is 401 (not 404) for that sub-case; document the behaviour in
the test comment.

### AC-4 — Shared middleware declared in exactly one place

**Approach:** No separate runtime test needed — enforced by code structure and verified
by grep. REVIEWER runs:

```
grep -rn "plug Letflow.Plugs.AuthPipeline\|plug Plug.Parsers" lib/letflow/
```

Expected result: exactly two matching lines, both in
`lib/letflow/plugs/api_pipeline.ex`. Zero matches in
`lib/letflow/routers/*.ex`. Zero matches in `lib/letflow/router.ex`.

If ELIXIR-DEV wants an automated assertion, a `test/letflow/router_structure_test.exs`
module can read the source files as text and assert the above using `File.read!/1` +
`String.contains?/2` checks. This is optional but deterministic.

### AC-5 — Moduledoc lists all eleven deferred route modules with owning stages

**Approach:** REVIEWER inspection — not a runtime test. Confirm
`lib/letflow/router.ex`'s moduledoc contains all eleven entries from the table in §(a)
above, each with its owning stage, and includes the readiness-not-ported statement.

### AC-6 — No new framework dependency introduced

**Approach:** REVIEWER inspection + automated check. Confirm:
- `mix.exs` has no new dependency compared to the branch base.
- `lib/letflow/router.ex`'s moduledoc contains the citation:
  "Executes docs/migration/decisions/0001-web-framework.md addendum (2026-08-20) —
  Plug/Bandit stands."
- `grep -rn "phoenix\|Phoenix" mix.exs lib/letflow/router.ex` returns zero lines.

---

## Open Questions

### OQ-1 — `Plug.Parsers` length cap value

The requirement specifies "Plug.Parsers (JSON, :length-capped)" but does not name a
limit. The current `lib/letflow/router.ex` has no `:length` option on `Plug.Parsers`.
**ELIXIR-DEV must choose a value** when implementing `Letflow.Plugs.ApiPipeline`.

PROVENANCE (historical, not current decision authority):
Suggested default: `length: 2_000_000` (2 MB). Rationale: this is Plug's own default
(`Plug.Parsers` source: default `:length` is 8 MB, but stricter is safer until R-Co's
`content_type.zig` / `validate.zig` ports specify the actual envelope).  
R-Co's `content_type.zig` (119 lines, to port) may carry an explicit limit —
ELIXIR-DEV should check before picking a value and document it in the implementing
commit message.

This OQ is **not blocking CODE-DESIGN-VALIDATOR** — the design names `:length-capped`
as a requirement and defers the exact value to implementation.

### OQ-2 — `Plug.Router.forward/2` path-stripping at two levels

The design assumes that:
1. `forward "/api/v1", to: Letflow.Plugs.ApiPipeline` in `Letflow.Router` delivers
   `/instances/abc` (not `/api/v1/instances/abc`) to `ApiPipeline` for a request to
   `/api/v1/instances/abc`.
2. `forward "/instances", to: Letflow.Routers.Instances` in `ApiPipeline` delivers
   `/abc` (not `/instances/abc`) to `Letflow.Routers.Instances`.

This is the documented behaviour of `Plug.Router.forward/2` (it updates
`conn.path_info` and `conn.request_path`). ELIXIR-DEV MUST verify this with a unit
test against `Letflow.Plugs.ApiPipeline` using `Plug.Test.conn/3` before adding real
routes to sub-routers, as an incorrect assumption here would silently mismatch all
routes in all sub-routers.

This OQ is **not blocking CODE-DESIGN-VALIDATOR** — the behaviour is documented in
Plug's own source; the verification note is for ELIXIR-DEV's implementation step.

---

## Cross-Reference to Acceptance Criteria

| AC | Requirement AC | Design element |
|---|---|---|
| AC-1 | GET /health → 200 `{"status":"ok"}`, no auth, no DB, Repo-unavailable test | §(a) routes table; §(d) AC-1 test |
| AC-2 | Router decomposed per subsystem; sub-router mountable in isolation | §(b) sub-router roster; §(d) AC-2 test |
| AC-3 | Unrouted path → RFC 9457 404, `application/problem+json` header | §(a) catch-all; §(c) ApiPipeline catch-all; §(d) AC-3 test |
| AC-4 | Shared middleware declared in one place, grep-verifiable | §(c) single-site design; §(d) AC-4 grep command |
| AC-5 | Moduledoc lists eleven deferred routes + readiness-not-ported statement | §(a) moduledoc content requirements |
| AC-6 | No new framework dependency; Plug/Bandit per REQ-065 addendum, cited by name | §(a) citation requirement; §(d) AC-6 grep check |
