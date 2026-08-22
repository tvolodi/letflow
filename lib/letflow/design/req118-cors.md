# REQ-118 — CORS support for the browser-origin SPA

Design for CORS handling on Letflow's Plug pipeline, so a built SPA served from any
origin other than Letflow's own (`http://localhost:5173` dev, `http://127.0.0.1:4173`
Playwright e2e, and whatever origin the real deployed SPA is eventually served from)
can call Letflow's API. No implementation code below — signatures and type shapes
only.

## 0. Key decisions

### 0.1 Credentials — NOT needed, `Access-Control-Allow-Credentials` omitted

Per the handoff's confirmed fact, `web/src/api/client.ts` holds the bearer token
in-memory only (`let _token: string | null = null`) and sends it as an
`Authorization: Bearer <token>` header on every authenticated request. It never
relies on the browser's automatic credential-attachment (cookies, HTTP auth,
TLS client certs) — the only three credential kinds CORS's `credentials` mode
governs.

Consequence: the browser will never attach cookies/credentials to a cross-origin
request to Letflow, so `Access-Control-Allow-Credentials: true` would have no
observable effect for this client (fetch calls in `client.ts` do not set
`credentials: 'include'` either — confirmed by grep, see §7 OQ if that ever
changes). Sending `Access-Control-Allow-Credentials: true` combined with a
non-wildcard origin is otherwise legal, but is unnecessary attack surface to
maintain (it would also forbid ever combining with a wildcard later, and each
response would carry a header that implies a security posture — "this origin may
read authenticated-cookie responses" — that is not true of this API). **Decision:
never emit `Access-Control-Allow-Credentials`.** The plug's response headers never
include it, in any code path.

This also means the request-side `Access-Control-Allow-Origin` value can safely be
the literal matched origin (never `*` — see §0.2) without needing the
credentialed-CORS restriction that forbids `*` when credentials are allowed; the
restriction doesn't apply here, but the origin allowlist below is still enforced by
Letflow's own default-deny allowlist, independent of the credentials question.

### 0.2 Config key, shape, default — runtime config, not compile_env

**Key:** `config :letflow, :cors_allowed_origins, [...]` — a list of exact origin
strings (scheme + host + optional port, no trailing slash, no path), e.g.
`["http://localhost:5173", "http://127.0.0.1:4173"]`.

**Compile-time (`Application.compile_env/3`, mirroring `:problems_base_uri`) is
REJECTED for this key.** `:problems_base_uri` is fine as compile-time because it's
a cosmetic string baked into a problem-document `type` URI with no security
consequence if stale. Allowed origins are the opposite: they gate which callers may
receive CORS headers on authenticated routes, and — per the handoff's own framing —
"origins can differ per deploy environment." A compile-time default baked at build
time would require a rebuild to add a new deploy environment's SPA origin, which
config/prod.exs's own established pattern for genuinely per-deployment values
(`Letflow.Repo`'s `:url`, `:http_port` — both sourced from `System.get_env/1` inside
`config/runtime.exs`, evaluated after compilation, before boot) already exists to
avoid. Mirror that shape instead: read allowed origins via
`Application.get_env(:letflow, :cors_allowed_origins, @default_origins)` **at
request time** (a plain module attribute is wrong here for the same reason
`compile_env` is wrong — it would freeze the release-time value), inside the plug's
`call/2`, not baked into a module attribute at compile time.

**Default value (compiled into the plug as the literal fallback passed to
`Application.get_env/3`, used only when nothing else configures the key):**
`["http://localhost:5173", "http://127.0.0.1:4173"]` — exactly the two dev-time
origins the requirement names (Vite dev server, Playwright's built-SPA preview
server). **No wildcard, ever, in this default or anywhere else in the module**
(AC2, and the handoff's explicit "a wildcard allowed-origin is not acceptable as a
default").

**Where set:**
- `config/dev.exs` / `config/test.exs`: no explicit `:cors_allowed_origins` entry
  needed — the plug's own default already covers both dev origins. (Test env still
  benefits from the key being present in principle for a test that wants to override
  it via `Application.put_env/3` inside a test — see §3.)
- `config/runtime.exs` (prod only, `if config_env() == :prod do ... end` block,
  same block as `DATABASE_URL`/`PORT`): new entry —
  `config :letflow, :cors_allowed_origins, (System.get_env("CORS_ALLOWED_ORIGINS") ||
  "") |> String.split(",", trim: true)`. An unset/empty env var in prod yields `[]`
  (deny all cross-origin — fail closed, not fail open to the dev default). This is a
  deliberate divergence from dev/test's baked-in default: prod must be told
  explicitly which origins to trust; falling back to `localhost:5173` in a real
  deployment would be a silent security hole.

### 0.3 Mount point — `Letflow.Router`, above BOTH forwards

**Mounted in `Letflow.Router`, before `plug(:match)`/`plug(:dispatch)`, not inside
`Letflow.Plugs.ApiPipeline`.** Reasoning: `GET /api/tenant-config`
(`Letflow.Routers.TenantConfig`, forwarded directly from `Letflow.Router`, outside
`ApiPipeline`) is the SPA's login-bootstrap call and is cross-origin from a built SPA
exactly like every `/api/v1/*` call — the handoff flags this explicitly. Mounting
CORS handling only inside `ApiPipeline` would leave the bootstrap call unable to
complete preflight/receive CORS headers, breaking the login flow before a token even
exists to send. Mounting it in `Letflow.Router` covers `/health`,
`/api/tenant-config`, and (falling through the forward) everything under
`/api/v1/*` with one plug, consistent with how `Letflow.Api.Context.assign_trace_id/1`
was deliberately kept OFF the router (different direction, same reasoning: pick the
mount point by which routes actually need the behavior). `GET /health` is not a
browser/SPA-facing endpoint (used by `deploy/redeploy-test.sh`) but emitting harmless,
correctly-scoped CORS headers on it is not a contract change worth special-casing
around — no test pins `/health`'s response headers today (`test/letflow/router_test.exs`
only asserts `status`/JSON body for that route), so adding a plug ahead of it does
not break `router_test.exs`'s existing assertions.

Concretely: add `plug(Letflow.Plugs.Cors)` in `Letflow.Router`, immediately after
`plug(:match)` and before `plug(:dispatch)` is the wrong position (Plug.Router's
`match`/`dispatch` pair brackets route dispatch, and a plug placed between them
still runs before the matched route handler, but placing a conn-level concern like
CORS ahead of both, right after `use Plug.Router`, is simpler to reason about and
matches this module's own convention of declaring `plug(:match)`/`plug(:dispatch)`
last). **Final order in `Letflow.Router`:**
```
use Plug.Router
plug(Letflow.Plugs.Cors)
plug(:match)
plug(:dispatch)
```

### 0.4 Preflight (OPTIONS) — implemented, with a test

**Implemented, not documented-as-unnecessary.** Reasoning: the SPA sends
`Authorization: Bearer <token>` on every authenticated request (per the handoff's
confirmed fact). A custom request header outside the CORS-safelisted set
(`Accept`, `Accept-Language`, `Content-Language`, `Content-Type` with a safelisted
value) makes a request "not simple" under the Fetch/CORS spec, so the browser sends
a preflight `OPTIONS` request with `Access-Control-Request-Method` and
`Access-Control-Request-Headers` before the real request, for any authenticated
`/api/v1/*` call using a non-GET method or the `Authorization` header (which is
every authenticated call — `Authorization` is never safelisted). Preflight handling
is therefore load-bearing for this SPA, not optional. AC3 is satisfied by
implementation + test, not by a documented-unnecessary note.

`Letflow.Plugs.Cors` intercepts `OPTIONS` requests whose `Origin` header is present
and matches the allowlist, and short-circuits with a `204 No Content` response
carrying the preflight response headers (see §1), calling `halt/1` so the request
never reaches `plug(:match)`/routing. An `OPTIONS` request with a non-matching or
absent `Origin` falls through unchanged (no CORS headers added) to
`Letflow.Router`'s existing `match _ do ... end` 404 catch-all (since none of
`Letflow.Router`'s declared routes handle `OPTIONS` explicitly) — this is correct:
a same-origin `OPTIONS` probe (e.g. from `curl`, not a browser) gets the same 404 it
would get today, unaffected by this change.

### 0.5 Rejection behavior for AC2's test — omit headers, don't 403

**Decision: the server does NOT actively reject an unlisted-origin request with a
non-2xx status.** CORS is a browser-enforced, response-header-driven mechanism —
the server's only lever is which headers it emits; the browser (not the server) is
what blocks the calling JS from reading the response when the `Origin` doesn't
match. Actively 403-ing an unlisted origin would (a) break legitimate non-browser
callers (server-to-server, curl, the mobile tier per S9 — none of which are subject
to or benefit from CORS enforcement and must not be denied by a mechanism that
exists only to inform browsers), and (b) add a second, redundant enforcement path
that must stay in sync with the allowlist for no correctness benefit, since the
browser already refuses to expose the response body/most headers to calling JS when
`Access-Control-Allow-Origin` doesn't match its own origin.

Concretely: for a matched origin, the plug adds `Access-Control-Allow-Origin: <the
matched origin>` (echoed, never `*`) plus the other response headers in §1. For an
unmatched or absent origin, the plug adds **no CORS headers at all** and the
request proceeds through the normal pipeline/router unchanged — the underlying
route still executes and returns its normal status (200/4xx/whatever the route
would return same-origin), just without `Access-Control-Allow-Origin`, which is
what causes a browser to block the calling JS from reading it.

**What AC2's test therefore asserts:** a cross-origin request (via `Plug.Test`,
`conn(...) |> put_req_header("origin", "http://evil.example.com")`) through
`Letflow.Router` does NOT carry an `Access-Control-Allow-Origin` response header
(`Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == []`) — this is
the concrete, observable proof that an unlisted origin is rejected from a CORS
standpoint, even though the HTTP status itself may still be 200/404/whatever the
underlying route naturally returns. This matches how CORS actually protects
data: the browser, not the status code, is the enforcement point.

## 1. `Letflow.Plugs.Cors`

New module, `lib/letflow/plugs/cors.ex`, following `Letflow.Plugs.ContentType`'s
`@behaviour Plug` shape (no `use Plug.Router`, no state machine — a stateless
per-request header-decision plug).

```
@behaviour Plug

@spec init(keyword()) :: keyword()
def init(opts)

@spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
def call(conn, opts)
```

**`call/2` behavior, by case:**

| Case | Condition | Action |
|---|---|---|
| No `Origin` header | `get_req_header(conn, "origin") == []` | Pass through unchanged — same-origin/non-browser request, no CORS headers added, no halt |
| `Origin` present, not in allowlist | origin value not in `allowed_origins()` | Pass through unchanged — no CORS headers added, no halt (§0.5) |
| `Origin` present, in allowlist, method == `"OPTIONS"`, `access-control-request-method` header present | preflight | `halt/1` with `204`, headers per preflight table below |
| `Origin` present, in allowlist, otherwise (simple/actual request) | actual cross-origin request | Add `access-control-allow-origin` (+ `vary: origin`) response headers, do NOT halt — request continues to `:match`/`:dispatch` |

**Response headers on a matched-origin actual request:**

| Header | Value |
|---|---|
| `access-control-allow-origin` | the exact matched `Origin` request-header value (never `*`, never a computed pattern) |
| `vary` | `origin` (appended, not overwritten — needed so any shared/CDN cache in front of Letflow does not serve one origin's CORS-headers response to another origin; `Plug.Conn.put_resp_header/3` used with a merge onto any existing `vary` value rather than a blind overwrite) |

**Response headers on a matched-origin preflight (`OPTIONS`) request — `204`, empty
body, then `halt/1`:**

| Header | Value |
|---|---|
| `access-control-allow-origin` | the exact matched `Origin` value |
| `vary` | `origin` |
| `access-control-allow-methods` | `GET, POST, PUT, PATCH, DELETE, OPTIONS` (the method set Letflow's routers actually use — matches `Letflow.Plugs.TenantStatus`'s `@write_methods` union with `GET`/`OPTIONS`) |
| `access-control-allow-headers` | `authorization, content-type` (the two request headers the SPA actually sends per `client.ts` — `Authorization` bearer token, `Content-Type: application/json`; not an echo of the request's `access-control-request-headers` value, to keep the allowlist explicit and auditable rather than reflecting whatever the caller asked for) |
| `access-control-max-age` | `600` (10 minutes — bounds how often a browser re-preflights; an arbitrary-but-reasonable operational value, no correctness dependency on the exact number, same class of decision as `:sandbox_pool`'s `max_concurrent_sandboxes: 5`) |

No `access-control-allow-credentials` header in any case (§0.1).

**Private helpers (signatures only):**

```
@spec allowed_origins() :: [String.t()]
defp allowed_origins()
# Application.get_env(:letflow, :cors_allowed_origins, @default_origins) — read at
# request time, not compile time. @default_origins is the module attribute literal
# listed in §0.2 (no Application.compile_env/3 involved).

@spec origin_allowed?(String.t() | nil) :: boolean()
defp origin_allowed?(origin)
# origin != nil and origin in allowed_origins() -- exact string match, no wildcard/
# subdomain/pattern matching of any kind.

@spec preflight_request?(Plug.Conn.t()) :: boolean()
defp preflight_request?(conn)
# conn.method == "OPTIONS" and get_req_header(conn, "access-control-request-method")
# != []
```

No dependency on `Letflow.Api.Response`/`Letflow.Api.Error` — this plug never emits
an RFC 9457 problem document (§0.5: CORS rejection is "omit the header," not "return
an error body"). `Plug.Conn.send_resp/3` is used directly for the 204 preflight
short-circuit, matching `Letflow.Plugs.TenantStatus`'s own direct-`send_resp`
pattern for its non-2xx paths.

## 2. Config additions

`config/runtime.exs`, inside the existing `if config_env() == :prod do ... end`
block, alongside `DATABASE_URL`/`PORT`:

```
config :letflow, :cors_allowed_origins,
  (System.get_env("CORS_ALLOWED_ORIGINS") || "") |> String.split(",", trim: true)
```

No change needed to `config/dev.exs` or `config/test.exs` — both rely on
`Letflow.Plugs.Cors`'s own compiled-in default (`["http://localhost:5173",
"http://127.0.0.1:4173"]`), which already covers Vite dev (`:5173`) and Playwright's
preview server (`:4173`). A test that needs a *different* allowlist (e.g. to prove
the config key is actually read, not just the default) uses
`Application.put_env(:letflow, :cors_allowed_origins, [...])` scoped with
`on_exit(fn -> Application.delete_env(:letflow, :cors_allowed_origins) end)` inside
that one test — no global config file change required for that case.

## 3. Router change

`lib/letflow/router.ex` — add one `plug(Letflow.Plugs.Cors)` line (see §0.3 for
exact position) and update the moduledoc's route table / prose to note the new
cross-cutting plug, following the existing style of documenting
`Letflow.Api.Context.assign_trace_id/1`'s deliberate mount-point choice. No route
table row changes (CORS is not a route, it is pipeline behavior applying to every
route including the two forwards).

## 4. Acceptance-criteria mapping

| AC | Design element |
|---|---|
| AC1 — CORS headers emitted, allowed-origin list from config not hardcoded | `Letflow.Plugs.Cors.call/2`'s matched-origin branch (§1) emits `access-control-allow-origin`/`vary`; `allowed_origins/0` reads `Application.get_env(:letflow, :cors_allowed_origins, @default_origins)` (§0.2, §1) |
| AC2 — default has no wildcard; test asserts unlisted origin rejected | `@default_origins = ["http://localhost:5173", "http://127.0.0.1:4173"]`, no `*` anywhere in the module (§0.2); rejection = no `access-control-allow-origin` header emitted for an unmatched `Origin` (§0.5) — test asserts `get_resp_header(conn, "access-control-allow-origin") == []` for a request with `origin: http://evil.example.com` |
| AC3 — preflight implemented+tested, or documented-unnecessary with reason | Implemented: preflight branch in `call/2` (§0.4, §1 preflight header table); test exercises an `OPTIONS` request with `access-control-request-method`/`access-control-request-headers` set and asserts `204` + the four preflight headers |
| AC4 — test exercises cross-origin request end-to-end through the router | Tests target `Letflow.Router.call/2` via `Plug.Test` (`conn(:get, "/api/tenant-config") \|> put_req_header("origin", ...) \|> Letflow.Router.call(@opts)`), not `Letflow.Plugs.Cors.call/2` in isolation — matching `test/letflow/router_test.exs`'s existing `Plug.Test`-through-`Letflow.Router` convention |
| AC5 — no change under `web/` | Design touches only `lib/letflow/plugs/cors.ex` (new), `lib/letflow/router.ex`, `config/runtime.exs` — `git diff --stat -- web/` must be empty at implementation time |

## 5. Cross-module dependencies

- `Letflow.Router` — gains one `plug(Letflow.Plugs.Cors)` line (§0.3, §3).
- `Letflow.Plugs.Cors` (new) — no dependency on `Letflow.Plugs.ApiPipeline`,
  `Letflow.Plugs.AuthPipeline`, `Letflow.Plugs.TenantStatus`, or
  `Letflow.Api.Response`/`Letflow.Api.Error` (§1). Depends only on `Plug.Conn` and
  `Application.get_env/3`.
- `config/runtime.exs` — new `:cors_allowed_origins` key in the existing prod block
  (§2), alongside `Letflow.Repo`'s `:url` and `:http_port`.
- No migration, no Ecto schema, no new dependency in `mix.exs` (hand-written plug,
  per the handoff's constraint — no network access for `mix deps.get`).

## 6. Invariants

- `access-control-allow-origin` is NEVER `*` and NEVER a computed/pattern-matched
  value — only ever the literal request `Origin` header value, and only after an
  exact-string match against the configured allowlist (§0.2, §1).
- `access-control-allow-credentials` is NEVER emitted, in any code path (§0.1).
- `allowed_origins/0` is read at request time via `Application.get_env/3`, never
  frozen at compile time via `Application.compile_env/3` or a bare module attribute
  (§0.2) — a production deploy changes its allowlist via `CORS_ALLOWED_ORIGINS`
  without a rebuild.
- The plug never halts a request solely because its origin is unlisted (§0.5) — it
  only halts for a matched-origin preflight `OPTIONS` (§0.4). An unmatched origin's
  request proceeds through the normal pipeline and gets the normal response, just
  without CORS headers.
- Preflight (`OPTIONS`) short-circuit happens before `plug(:match)`/`plug(:dispatch)`
  runs (§0.3, §0.4) — no router/sub-router logic executes for a preflight request.

## 7. Open questions

- **OQ-1 (non-blocking, doesn't change this design):** `web/src/api/client.ts` was
  confirmed by ELIXIR-DEV to never use `credentials: 'include'`. This design does
  not re-derive that from a fresh grep of `web/` (out of scope for CODE-DESIGNER per
  this run's "don't re-derive" instruction) — SECURITY-REVIEWER should spot-check it
  once at implementation time as part of confirming §0.1's premise still holds,
  since a future `web/` change silently adding `credentials: 'include'` would make
  the "credentials not needed" conclusion stale without this design noticing.
- **OQ-2 (config-only, no design impact):** the exact production SPA origin(s) for
  `CORS_ALLOWED_ORIGINS` are not yet known (no deploy environment exists yet per
  S8's "cutover strategy still open" note in `docs/migration/stage-8-frontend-cutover.md`).
  This is fine — the env var is unset until a real deploy exists, and prod's fail-closed
  empty-list default (§0.2) means no origin is trusted until someone deliberately sets
  it, which is the safe default to leave open.
- **OQ-3 (deliberately not designed):** whether `Access-Control-Expose-Headers` is
  needed (e.g. so client JS can read a custom response header like `x-trace-id` or a
  future `Location`/pagination cursor header cross-origin). Not required by this
  requirement's acceptance criteria and no known caller reads a non-safelisted
  response header from a cross-origin response today — left out rather than
  guessed at. If a future requirement needs `web/` to read such a header
  cross-origin, that's a `Letflow.Plugs.Cors` change with its own acceptance
  criterion, not something to silently add here.
