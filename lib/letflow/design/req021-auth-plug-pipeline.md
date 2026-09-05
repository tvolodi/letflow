PROVENANCE (historical, not current decision authority):
# Design: REQ-021 — Auth Plug pipeline (auth.zig/tenant_status.zig equivalent)

**Requirement:** REQ-021 (`docs/requirements.yaml`, stage S1)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** the exact Plug module(s), their `init/1`/`call/2` shapes, the
exact `conn.assigns` keys the auth context and error responses use, the verification-adapter
decision (real `oidcc` call vs. test double, justified), the orchestration order (verify →
tenant resolution → realm-ownership guard → JIT provisioning → tenant-status write-pause →
attach context), and where in `lib/letflow/router.ex` this wires in. No implementation code —
no `.ex`/`.exs` code blocks with real function bodies. Signatures, type shapes, and prose
only.

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-021 (full entry, `depends_on: [REQ-016, REQ-017, REQ-018,
  REQ-019, REQ-020]`, all `done`) — description and all 5 acceptance criteria.
- `docs/guides/backend_developer_guide.md` — §2 (project structure), §3.5 (error handling —
  `{:ok,_}|{:error,_}` shape), §3.6 (SQL always parameterized), §6 (OIDC/ueberauth_oidcc
  partial-adoption decision, explicit statement that REQ-021's plug is Letflow's first real
  auth plug, not an extension of the never-built REQ-103).
PROVENANCE (historical, not current decision authority):
- `docs/migration/stage-1-identity.md` — S1 scope, `src/api/middleware/auth.zig`/
  `tenant_status.zig` named as the R-Co files this requirement ports.
- `docs/migration/decisions/0002-oidc-integration.md` — confirms `ueberauth_oidcc`/`oidcc`
  cover token verification/JWKS caching only; JIT provisioning, tenant↔realm binding, and the
  role registry are hand-rolled (already built by REQ-018/019/020).
PROVENANCE (historical, not current decision authority):
- `C:\Users\tvolo\dev\ai-dala\R-Co\src\api\middleware\auth.zig` (read in full to line 1231 of
  1756 — the remainder is repeated `Auth401Code`-branch detail on the same
  `authenticate/postAuthJitProvision/tryTenantRealmAuth` shape already captured) — the
  orchestration this design ports: `authenticate/3`'s bearer-header extraction → JWT-shape
  inspection → `identity_provider_manager.verifyBearerToken` → (on issuer mismatch)
  `tryTenantRealmAuth` (extract `iss` → realm slug → look up tenant by realm → re-verify with
  tenant's issuer) → `postAuthJitProvision` (decode claims → claim-mapping → JIT config →
  provision → role load). R-Co's `AuthResult` union (`authenticated | unauthenticated |
  forbidden`) and its `buildUnauthorizedAuth/buildForbidden` RFC-9457-shaped JSON bodies are
  the model for this design's error-response shapes (§5).
PROVENANCE (historical, not current decision authority):
- `C:\Users\tvolo\dev\ai-dala\R-Co\src\api\middleware\tenant_status.zig` (full file) —
  `checkTenantWritePause/4`: write-method allowlist (`POST`/`PUT`/`PATCH`/`DELETE`), no-op for
  an empty `tenant_id`, fail-open on pool exhaustion/query failure, 503 body when
  `status = "MIGRATING"`. Ported in §6 below, with one fail-open/fail-closed divergence
  flagged explicitly (§6.4).
- `lib/letflow/identity.ex` (full) — `provision_oidc_user/3`, `resolve_tenant_by_realm/1`,
  `resolve_realm_by_tenant/1`, `verify_realm_ownership/2` — all four called by this design, with
  their exact `@spec`s reproduced in §4.
- `lib/letflow/oidc/identity_context.ex` — `Letflow.Oidc.IdentityContext` struct, confirmed
  field is `realm` (not `external_realm`) — `lib/letflow/identity.ex` line 155
  (`insert_or_fetch/3`) reads `identity_context.realm` when building the `users` insert attrs'
  `external_realm` column value.
- `lib/letflow/oidc/claim_mapping.ex` (full) — `map_verified_claims/3`, confirmed zero-I/O,
  takes an already-map-shaped `claims` argument (matches `ueberauth_oidcc`'s claims shape,
  per that module's own moduledoc citing `deps/ueberauth_oidcc/lib/ueberauth_oidcc/raw_info.ex`).
- `lib/letflow/oidc/claim_mapping_config.ex`, `lib/letflow/oidc/jit_provisioning_config.ex` —
  `for_realm/1` on each, both reading `Application.fetch_env!/2` against distinct config keys
  (`:oidc_claim_mapping`, `:oidc_jit_provisioning`).
- `lib/letflow/identity/role_registry.ex` — confirmed standalone, zero coupling to
  `Letflow.Oidc.*` or `Letflow.Identity`'s OIDC-pipeline functions (its own moduledoc states
  this explicitly, REQ-020's design doc §6 restates it). Read in full to settle §4.4's "which
  roles" question below.
PROVENANCE (historical, not current decision authority):
- `lib/letflow/identity/tenant.ex` — `Letflow.Identity.Tenant` schema, `status` field
  `Ecto.Enum, values: [:active, :migrating]` (confirmed exact atom values — R-Co's
  `tenant_status.zig` compares the string `"MIGRATING"`; Letflow's column is an `Ecto.Enum`
  with atom values `:active`/`:migrating`, so the write-pause check in this design compares
  against the atom `:migrating`, not a string).
- `lib/letflow/application.ex` (full) — confirmed `Oidcc.ProviderConfiguration.Worker` is
  registered under `Application.get_env(:letflow, :oidc)[:provider_name]`
  (`Letflow.Oidc.DefaultProvider`), and that both `config/dev.exs` and `config/test.exs` point
  its `:issuer` at a `.invalid` placeholder host (`https://placeholder-keycloak.invalid/realms/
  bpm-default`) — confirmed no real, resolvable issuer is configured against this worker in
  this environment.
- `lib/letflow/router.ex` (full, 65 lines) — confirmed exactly 3 routes (`POST /instances`,
  `POST /instances/:id/actions`, `GET /instances/:id`), none tenant-scoped, `Plug.Router` with
  `plug Plug.Parsers` → `plug :match` → `plug :dispatch`, `Bandit` as the HTTP server (per
  `application.ex`).
- `deps/oidcc/src/oidcc_token.erl` (`validate_jwt/3`/`/4`, read in full around lines 953-1107)
  and `deps/oidcc/lib/oidcc/token.ex` (`Oidcc.Token.validate_jwt/3`, line ~348 — confirmed this
  Elixir wrapper exists and is the one the library's own docs illustrate with "Get Jwt from
  Authorization header," i.e. this is the intended API-bearer-token verification entry point,
  not just an ID-token/authcode-flow helper). `deps/oidcc/lib/oidcc/client_context.ex`
  (`Oidcc.ClientContext.from_configuration_worker/3-4`) and `deps/oidcc/src/
  oidcc_client_context.erl` (confirmed `client_secret :: unauthenticated` is a legitimate,
  library-supported option for building a `ClientContext` with no client secret — appropriate
  for a resource-server that only verifies tokens, never exchanges an authcode).
- `deps/ueberauth_oidcc/lib/ueberauth/strategy/oidcc.ex` (full) — confirmed this module
  (`Ueberauth.Strategy.Oidcc`) implements the OAuth **redirect/callback** flow
  (`handle_request!/1` → provider redirect, `handle_callback!/1` → authcode exchange). It is
  not the right library entry point for verifying an already-issued bearer token presented on
  every API request — see §3.1 for why this design targets `Oidcc.Token.validate_jwt/3`
  directly instead.
- `config/dev.exs`, `config/test.exs` (full) — confirmed exact `:oidc`, `:oidc_claim_mapping`,
  `:oidc_jit_provisioning` config shapes and the `.invalid` placeholder issuer.
- `docker ps` (run this session) — confirmed `r-co-keycloak-1` (`quay.io/keycloak/keycloak:26.2`)
  is a running, healthy container in this environment. See §3.2 for why this design does not
  direct ELIXIR-DEV to point Letflow's `:oidc` config at it.
- `docs/agents/instructions/security-invariants.md` — INV-1, INV-4, INV-7, INV-8 assessed in
  §9 below.
- `lib/letflow/design/req016-oidc-dependency-supervision.md`,
  `lib/letflow/design/req020-role-registry.md` — read in full for this project's established
  design-doc section shape, traceability-table format, and open-questions numbering
  convention, matched below.
- `docs/requirements.yaml` REQ-101/REQ-103 entries — confirmed REQ-103 (dev-bearer-token plug)
  was never built; MVP-1 was cancelled wholesale. §7 states this explicitly per acceptance
  criterion 5.

## 1. Scope boundary

**In scope:** one new Plug module (or a small composed pipeline of Plug modules) implementing,
in this exact order, per request:

1. Bearer-token extraction + verification (REQ-016's supervised `Oidcc.ProviderConfiguration.
   Worker` + REQ-017's claim mapping).
2. Tenant resolution from the token's realm claim (REQ-019's `resolve_tenant_by_realm/1`).
3. Realm-ownership guard (REQ-019's `verify_realm_ownership/2`) — **before** JIT provisioning,
   per adp-04a (task instruction, confirmed against `Letflow.Identity`'s own moduledoc: "REQ-021's
   future pipeline calls this before resolving/provisioning the user").
4. JIT provisioning/lookup (REQ-018's `provision_oidc_user/3`).
PROVENANCE (historical, not current decision authority):
5. Tenant-status write-pause check (`tenant_status.zig` port) — placed **after** step 4 in this
   design's call order (not interleaved earlier) — see §6.1 for why.
6. Attach an auth context (`user_id`, `tenant_id`, `roles`) to `conn.assigns` for downstream
   plugs (§5).

A request with a missing/malformed bearer token short-circuits at step 1 with 401, before any
DB or claim-mapping work runs (acceptance criterion 2).

**Out of scope (explicitly, matching REQ-021's own description and task framing):**
- No route in today's `router.ex` is changed to actually *require* this plug (§8) — none of
  the 3 existing routes are tenant-scoped or need auth, confirmed §0. This requirement builds
  and proves the pipeline against synthetic/test requests; wiring a real business route behind
  it is S4's job.
- No `Ueberauth.Strategy.Oidcc` browser-redirect flow (`handle_request!/1`/`handle_callback!/1`)
  is used or configured — see §3.1 for why the direct `oidcc` verification API is the right
  target for an API bearer-token plug, not the redirect-flow Strategy.
- No new DB migration. Every table this design reads (`tenants`, `users`) already exists
  (REQ-015/018/019).
- No role-binding-row persistence — `RoleRegistry`'s DB-backed role registry is confirmed
  standalone (§0) and is not called by this pipeline; §4.4 states explicitly which "roles"
  value populates the auth context and why `RoleRegistry` is not it.
- No production Keycloak wiring — §3.2 states explicitly this design directs ELIXIR-DEV to use
  a test double for AC1's fallback, and why, despite a real Keycloak container being reachable
  in this environment.

## 2. Module placement — DECISION: two new Plug modules, plus a router change

PROVENANCE (historical, not current decision authority):
| File | Module | Role |
|---|---|---|
| `lib/letflow/plugs/auth_pipeline.ex` | `Letflow.Plugs.AuthPipeline` | Steps 1-4 + 6 (verify → tenant resolve → realm guard → JIT provision → attach context) |
| `lib/letflow/plugs/tenant_status.ex` | `Letflow.Plugs.TenantStatus` | Step 5 (write-pause check, `tenant_status.zig` port) |
| `lib/letflow/router.ex` | `Letflow.Router` | Unchanged route table; new module attributes/imports only (§8) |

**Why two modules, not one, and why not folded into `router.ex` directly:**

PROVENANCE (historical, not current decision authority):
1. **R-Co itself keeps these as two separate files** (`auth.zig` vs. `tenant_status.zig`), each
   with its own moduledoc and its own single responsibility (`tenant_status.zig`'s own doc
   comment: "Call `checkTenantWritePause()` **after** auth resolves the `tenant_id`"). Mirroring
   that file-level separation is the same "keep R-Co's own boundary intact" reasoning
   `req020-role-registry.md` §1 used for `RoleRegistry`.
2. **They have different trigger conditions.** `AuthPipeline` runs unconditionally, once, at
   the top of every request that needs auth. `TenantStatus` only *acts* on write methods
   (`POST`/`PUT`/`PATCH`/`DELETE`) and is a no-op for `GET`/`HEAD` — conflating the two into one
   module's `call/2` would mean one function body doing "verify identity" AND "conditionally
   reject based on HTTP method," two orthogonal concerns matching R-Co's own file split.
3. **`Plug.Router`'s `plug/2` macro composes a list of plugs naturally** — two small,
   single-purpose `Plug` modules (`init/1` + `call/2}` each) is the idiomatic Plug shape, not a
   monolithic hand-rolled function doing both jobs. This matches `backend_developer_guide.md`'s
   general "match the shape of the actual problem" principle (§3.2, stated there for
   `:gen_statem` vs. plain Ecto, generalizes here to "one Plug per orthogonal concern").
4. **`lib/letflow/plugs/` is a new subdirectory** — no `plugs/` directory exists in `lib/letflow/`
   today (confirmed §0: `router.ex` is the only Plug-related file). Creating it now, rather than
   inlining both as private functions inside `router.ex`, keeps `router.ex` itself Plug-router
   composition only (its existing moduledoc: "Deliberately minimal") and gives S4's future
   tenant-scoped routes a place to add more plugs later without `router.ex` itself growing
   unboundedly. This is a new, not-yet-established directory — flagged as **OQ-1** (§10) since
   it is a structural precedent future requirements will follow.

## 3. Verification-adapter decision (answers task's explicit instruction to make this choice)

### 3.1 Direct `oidcc` API, not `Ueberauth.Strategy.Oidcc`

**Decision: `Letflow.Plugs.AuthPipeline`'s real implementation calls `Oidcc.Token.validate_jwt/3`
directly (backed by `Oidcc.ClientContext.from_configuration_worker/3` against the REQ-016-
supervised `Letflow.Oidc.DefaultProvider` worker) — not `Ueberauth.Strategy.Oidcc`.**

Reasoning, confirmed by reading both library surfaces (§0):
- `Ueberauth.Strategy.Oidcc` (`deps/ueberauth_oidcc/lib/ueberauth/strategy/oidcc.ex`) implements
  exactly two lifecycle callbacks: `handle_request!/1` (redirects the browser to the IdP's
  authorization endpoint) and `handle_callback!/1` (exchanges an authorization code for tokens
  after the IdP redirects back). Both assume a **browser-driven, multi-request OAuth
  authorization-code flow** — there is no request-scoped "verify this bearer token that already
  arrived in an `Authorization` header" entry point anywhere in that module.
- `oidcc`'s own docs, read directly from `oidcc_token.erl`'s `validate_jwt/3` doc comment
  (§0), state the intended use case explicitly: *"Validates a generic JWT (such as an access
  token)... Get Jwt from Authorization header"* — this is the library's own documented answer
  to exactly REQ-021's need (an already-issued bearer token on an incoming API request), and it
  is exposed to Elixir callers via `Oidcc.Token.validate_jwt/3` (confirmed present in
  `deps/oidcc/lib/oidcc/token.ex`).
- Building a `Oidcc.ClientContext` for this purpose does **not** require a real registered
  OIDC client with a client secret — `client_secret: :unauthenticated` is a first-class,
  library-supported option (`oidcc_client_context.erl`'s `unauthenticated_t()`/
  `unauthenticated_opts()` types, confirmed §0) for exactly the "resource server verifies
  tokens, never performs a token exchange itself" case this plug is in.

**Concrete call shape this design specifies** (prose, not code — ELIXIR-DEV writes the actual
calls):
1. `Oidcc.ClientContext.from_configuration_worker(provider_name, client_id, :unauthenticated,
   opts)` — `provider_name` read from `Application.fetch_env!(:letflow, :oidc)[:provider_name]`
   (the same atom REQ-016 registered, per that design's §8 cross-module-dependency note: "REQ-021
   must reuse `Application.get_env(:letflow, :oidc)[:provider_name]` rather than re-inventing or
   hardcoding the same atom"). `client_id` — see **OQ-2** (§10): no `client_id` currently exists
   in `config :letflow, :oidc`; this design flags that a `client_id` config value must be added
   (even a placeholder one, since `client_secret: :unauthenticated` still requires *some*
   `client_id` string per the type spec) rather than silently inventing one here.
2. `Oidcc.Token.validate_jwt(raw_token, client_context, %{signing_algs: [...]})` —
   `signing_algs` is a **required**, non-defaultable option (confirmed §0:
   `int_validate_jwt/4` raises `badarg` if both `signing_algs` and `encryption_algs` resolve to
   `[]`). This design does not hardcode a specific algorithm list — **OQ-3** (§10) flags that
   the exact allowed algorithm set (e.g. `["RS256"]`, matching Keycloak's default signing
   algorithm) is an ELIXIR-DEV/REVIEWER decision informed by whatever issuer configuration is
   actually used (§3.2), not invented here.
3. Result: `{:ok, claims}` (a `%{String.t() => term()}` map — the exact shape
   `Letflow.Oidc.ClaimMapping.map_verified_claims/3` already expects, §4.1) or `{:error, reason}`
   — every `{:error, _}` shape from `oidcc_token.erl`'s `error()` type collapses to a 401 in this
   design (§5); this design does not attempt to distinguish `token_expired` vs.
   `signature_invalid` vs. other sub-cases into different HTTP semantics (R-Co's `Auth401Code`
   enum has 12 members for this — **OQ-4**, §10, flags that finer-grained 401 sub-reasons are a
   possible future enhancement, not required by REQ-021's acceptance criteria, which only ask
   for "rejected with 401," not a specific error-code taxonomy).

### 3.2 Test double for AC1's stated fallback — DECISION: use a test double, not the reachable R-Co Keycloak container

**Decision: ELIXIR-DEV implements and exercises this pipeline's "valid OIDC bearer token" path
(AC1) against a test double standing in for `Oidcc.Token.validate_jwt/3`'s result — not against
the real, running `r-co-keycloak-1` container.**

Reasoning:
1. **Wrong realm/client, not just wrong reachability.** `docker ps` (§0) confirms
   `r-co-keycloak-1` is up and healthy, but it is **R-Co's own** Keycloak instance — there is no
   confirmation in this session that it has a `bpm-default` (or any Letflow-specific) realm/client
   configured to issue tokens Letflow's pipeline could meaningfully verify end-to-end.
   Provisioning a real realm/client for Letflow against that container is a nontrivial,
   multi-step, out-of-scope task (Keycloak Admin REST calls, realm JSON import, or manual
   console setup) that REQ-021's own acceptance criteria do not ask for — S1's stage doc
   (`docs/migration/stage-1-identity.md`) and REQ-016's design doc (§0's citation) both already
   established that realm provisioning against a real Keycloak is explicitly deferred past S1.
2. **Letflow's own configured issuer is a `.invalid` placeholder, confirmed unreachable by
   construction.** Both `config/dev.exs` and `config/test.exs`'s `:oidc` key point at
   `https://placeholder-keycloak.invalid/realms/bpm-default` (§0) — repointing this at
   `r-co-keycloak-1`'s real address is itself a config change this requirement's acceptance
   criteria do not call for, and doing so silently would create a hidden dependency on a
   container this project doesn't own or manage (it belongs to the sibling R-Co repo/compose
   stack, confirmed by its `r-co-` container-name prefix).
3. **REQ-021's own acceptance criterion 1 explicitly authorizes this**: *"a request with a
   valid OIDC bearer token (**or a test double standing in for ueberauth_oidcc's verification
   result, if a real Keycloak issuer isn't reachable in this environment — state explicitly
   which was used**)."* This design states explicitly, per that clause: **a test double is
   used**, for the two reasons above (wrong realm/client configured, and Letflow's own config
   deliberately points elsewhere) — not "unreachable" in the network sense (the container does
   answer), but unusable for this pipeline's actual verification target without out-of-scope
   provisioning work.

**Concrete adapter-boundary shape this design specifies**, so the test double is a real seam
and not an ad hoc `Mix.env() == :test` branch inside the plug:

- `Letflow.Plugs.AuthPipeline` calls verification through one indirection point — a
  **behaviour**, `Letflow.Oidc.TokenVerifier`, with one callback:
  ```
  @callback verify_bearer_token(raw_token :: String.t(), provider_name :: atom()) ::
              {:ok, claims :: %{optional(String.t()) => term()}} | {:error, term()}
  ```
- Two implementations:
  - `Letflow.Oidc.TokenVerifier.Oidcc` — the real adapter, wrapping §3.1's
    `Oidcc.ClientContext.from_configuration_worker/3` + `Oidcc.Token.validate_jwt/3` call
    sequence.
  - A test-only double (module name and exact fixture-claims shape left to TEST-DESIGNER,
    consistent with this project's convention — confirmed §0 — of test doubles living under
    `test/support/` or inline in the test file, not under `lib/`).
- Which implementation `AuthPipeline` calls is resolved via `Application.get_env(:letflow,
  :oidc)[:token_verifier]` (a new config key, defaulting to `Letflow.Oidc.TokenVerifier.Oidcc`
  in `config/dev.exs`/`config/prod.exs`, overridden to the test double in `config/test.exs`) —
  the same "config-sourced, not hardcoded" discipline REQ-016's design already established for
  `issuer`/`provider_name` (§0 citation). This is the exact seam TEST-DESIGNER needs to write
  AC1's test without a real Keycloak dependency, and it is also what lets a future requirement
  swap in a real, fully-provisioned Keycloak realm later without touching `AuthPipeline`'s own
  logic — only the config value changes.

This behaviour-based seam is itself a new architectural element this design introduces (not
present in any of REQ-016-020) — flagged as **OQ-5** (§10) for REVIEWER to confirm this is the
right level of indirection (vs., e.g., ELIXIR-DEV directly branching on `Mix.env()` inside
`AuthPipeline`, which this design considers a worse, less testable shape and does not
recommend).

## 4. `Letflow.Plugs.AuthPipeline` — steps 1-4 + 6

### 4.1 Module shape

```
@behaviour Plug

@spec init(opts :: keyword()) :: keyword()
@spec call(conn :: Plug.Conn.t(), opts :: keyword()) :: Plug.Conn.t()
```

Standard two-function `Plug` behaviour (`init/1` + `call/2`), matching `Plug.Parsers`'s own
shape already used in `router.ex` (§0) — no deviation from the library's own contract.
`init/1` is expected to be the trivial identity pass-through every existing pipeline-position
Plug in this codebase uses (`opts` returned unchanged — there is no per-request-independent
configuration this plug needs to precompute at compile time); ELIXIR-DEV writes the one-line
body. `call/2`
either:
- returns `conn` with `conn.assigns` populated per §5's keys (success path, falls through to
  the next plug in the pipeline), or
- calls `Plug.Conn.send_resp/3` + `Plug.Conn.halt/1` and returns the halted `conn` (failure
  path — 401 or the realm-mismatch rejection), matching `Plug.Router`'s own halt convention (a
  halted `conn` is not passed to `:dispatch`).

### 4.2 Step 1 — bearer-token extraction + verification

- Read the `authorization` header via `Plug.Conn.get_req_header(conn, "authorization")`.
PROVENANCE (historical, not current decision authority):
- Missing header, or present but not matching the case-sensitive `"Bearer "` prefix (matching
  R-Co's own case-sensitive RFC 6750 §2.1 check, `auth.zig` line 1182-1185, §0), or an empty
  token after stripping the prefix → **401, halt, stop. No further step in this pipeline runs**
  (acceptance criterion 2 — this is the literal "before tenant resolution or JIT provisioning
  runs" gate).
- Otherwise, call `Letflow.Oidc.TokenVerifier`'s configured implementation (§3.2) with the raw
  token string and the configured `provider_name`.
  - `{:error, _reason}` → **401, halt, stop.** No distinction made between "malformed,"
    "expired," "bad signature," etc. at this design's level (§3.1's OQ-4).
  - `{:ok, claims}` → proceed to step 2, carrying `claims` (a plain map) forward.

### 4.3 Step 2 — tenant resolution from realm claim

PROVENANCE (historical, not current decision authority):
- The **realm** is read from `claims["iss"]` (the JWT issuer claim — a Keycloak-issued token's
  issuer URL embeds the realm as its trailing path segment, matching R-Co's own
  `realmSlugFromIssuer/1` — `auth.zig` lines 954-963, §0) — **not** from a `tenant_id` claim.
  This mirrors R-Co's own two-tier resolution: the realm slug (used to look up the tenant) is
  derived from `iss`, while a `tenant_id` claim, if present, is only ever used as an optional
  *hint*/fallback in R-Co's `resolveTenantContext`, never as the authoritative resolution path
  (`auth.zig` lines 305-344). Extracting the realm slug from `iss` (matching
  `realmSlugFromIssuer/1`'s `"/realms/"`-marker split) is this design's specified mechanism —
  flagged as **OQ-6** (§10): whether Letflow's realm-extraction should instead use a distinct
  `realm`/`azp` claim path, matching `Letflow.Oidc.ClaimMappingConfig`'s own configurable
  `tenant_id_claim`-style approach, rather than a hardcoded `"/realms/"` URL-suffix parse. This
  design recommends the `iss`-URL-suffix approach as the direct, literal port of R-Co's own
  mechanism, but does not treat the alternative as closed.
PROVENANCE (historical, not current decision authority):
- Call `Letflow.Identity.resolve_tenant_by_realm(realm)`:
  ```
  @spec resolve_tenant_by_realm(idp_realm_id :: String.t()) ::
          {:ok, Tenant.t()} | {:error, :not_found}
  ```
  (exact signature, `lib/letflow/identity.ex`, confirmed §0.)
  - `{:error, :not_found}` → **401, halt, stop.** An unregistered realm is not distinguishable
    from "any other invalid token" at the HTTP-response level (matching R-Co's own
    `tryTenantRealmAuth`'s `issuer_unregistered` case collapsing to the same 401 status as every
    other auth failure, `auth.zig` lines 1043-1053, §0) — this design does not invent a
    different status code for this case.
  - `{:ok, %Tenant{id: tenant_id}}` → proceed to step 3, carrying the now-**trusted**
    `tenant_id` (the DB row's own primary key, not anything token-supplied) forward.

### 4.4 Step 3 — realm-ownership guard (BEFORE JIT provisioning, per adp-04a)

PROVENANCE (historical, not current decision authority):
- Call `Letflow.Identity.verify_realm_ownership(tenant_id, realm)`:
  ```
  @spec verify_realm_ownership(tenant_id :: Ecto.UUID.t(), external_realm :: String.t()) ::
          :ok | {:error, :realm_tenant_mismatch} | {:error, :not_found}
  ```
  (exact signature, confirmed §0 — re-queries the tenant's bound realm itself rather than
  trusting a caller-supplied value, per its own moduledoc: "a guard that trusted the same claim
  it's meant to check would be a no-op.")
  - `{:error, :realm_tenant_mismatch}` or `{:error, :not_found}` → **rejected. Not silently
    JIT-provisioned under the wrong tenant** (acceptance criterion 4, verbatim). This design
    specifies this rejection as a **401** (not 403) — consistent with how every other
    early-pipeline rejection in this design is a 401 (§5), and consistent with R-Co's own
    `Auth401Code.token_claim_invalid` variant existing for exactly this class of "token is
    structurally fine but its claims don't check out" failure (`auth.zig` line 155, §0) — this
    is flagged as **OQ-7** (§10) since 403 (distinguishing "authenticated but not authorized for
    this tenant" from "not authenticated at all") is a defensible alternative REVIEWER may
    prefer; this design's default is 401 to keep this pipeline's error surface uniform, not
    because 403 is wrong.
  - `:ok` → proceed to step 4.
- **Call-order guarantee this design makes explicit** (the task's own "guard BEFORE
  provisioning, per adp-04a" instruction): `provision_oidc_user/3` (§4.5) is never called unless
  `verify_realm_ownership/2` has already returned `:ok` in the same request. There is no code
  path in this design where JIT provisioning runs before, or in parallel with, the
  realm-ownership check.

### 4.5 Step 4 — JIT provisioning/lookup

- Build an `IdentityContext` from `claims` via REQ-017's pure mapping function:
  ```
  Letflow.Oidc.ClaimMapping.map_verified_claims(config, subject, claims) ::
    {:ok, IdentityContext.t()} | {:error, :sub_claim_missing}
  ```
  — `config` resolved via `Letflow.Oidc.ClaimMappingConfig.for_realm(realm)`; `subject` read
  from `claims["sub"]` (the standard OIDC subject claim — R-Co's own
  `postAuthJitProvision` passes `principal.provider_subject`, the equivalent
  already-verified-token subject, §0).
  - `{:error, :sub_claim_missing}` → **401, halt, stop.** A token that verified successfully
    but carries no usable `sub` claim is treated the same as any other invalid-token case at
    this design's level (matching this pipeline's general "collapse verification-adjacent
    failures to 401" pattern, §3.1's OQ-4 note).
  - `{:ok, identity_context}` → proceed.
- Resolve JIT config: `Letflow.Oidc.JitProvisioningConfig.for_realm(realm)`.
PROVENANCE (historical, not current decision authority):
- Call `Letflow.Identity.provision_oidc_user/3`:
  ```
  @spec provision_oidc_user(
          identity_context :: IdentityContext.t(),
          tenant_id :: Ecto.UUID.t(),
          jit_config :: JitProvisioningConfig.t()
        ) :: {:ok, %{user: User.t(), created: boolean()}} | {:error, provisioning_error()}
  ```
  (exact signature, confirmed §0) — `tenant_id` passed is the **step-2-resolved, DB-sourced**
  value (§4.3's "trusted" tenant_id), never `identity_context.tenant_id` (the token-claimed
  hint field) — matching `provision_oidc_user/3`'s own moduledoc: *"`tenant_id` is trusted as
  already-resolved/authoritative by the caller (REQ-019/021's territory) — it is not read from
  `identity_context.tenant_id`."* This design's call site is exactly the caller that moduledoc
  anticipates.
  - `{:error, :jit_disabled}` → **this design specifies: 403, not 401.** JIT-disabled means the
    token verified and the tenant/realm binding checked out, but this realm's policy does not
    allow account auto-creation — a genuine authorization-policy rejection, distinct from every
    prior step's "this token/claim is invalid" 401 cases. Flagged as **OQ-8** (§10): REQ-021's
    acceptance criteria do not name this specific case explicitly (only AC2's "missing/malformed
    token" 401 and AC4's "realm mismatch" rejection are named), so this design's 403 choice for
    `:jit_disabled` specifically is this design's own judgment call, not something the
    acceptance criteria mandate one way or the other — REVIEWER should confirm.
  - `{:error, :external_identity_collision}` or `{:error, %Ecto.Changeset{}}` (validation
    failure, e.g. a `username` collision) → **this design specifies: 500 (internal server
    error), not 401/403.** These are not caller-fixable auth failures — R-Co's own
    `postAuthJitProvision` catches every provisioning failure and **falls back to the original,
    non-JIT-provisioned `AuthContext`** rather than failing the whole request (`auth.zig` lines
    720-769, §0: every provisioning error branch returns `.{ .authenticated = auth_ctx }`,
    never a hard failure). **This design deliberately diverges from that fallback behavior** —
    see §4.6 for why, and **OQ-9** (§10) for the explicit flag that this divergence needs
    REVIEWER sign-off.
  - `{:ok, %{user: user, created: _}}` → proceed to step 5/6, carrying `user.id` and the
    resolved roles (§4.7) forward.

### 4.6 Why this design does NOT replicate R-Co's "fall back to original context on JIT failure"

R-Co's `postAuthJitProvision` treats JIT provisioning as strictly best-effort **after** initial
authentication already succeeded via a different mechanism (local `api_tokens` table lookup or
bootstrap token) — provisioning failure there degrades gracefully because R-Co's `AuthContext`
already has a usable `user_id`/`role` from the pre-JIT path (`auth_ctx`, the parameter
`postAuthJitProvision` receives). **Letflow has no equivalent pre-JIT authenticated identity —
OIDC JIT provisioning IS this pipeline's only path to a `user_id` at all** (there is no local
`api_tokens` table or bootstrap-token mechanism in Letflow's design; REQ-103, the module that
would have been the bootstrap-token equivalent, was never built, per REQ-021's own description
and this document's §7). Falling back to "the original context" the way R-Co does is therefore
not a graceful degradation for Letflow — there is no prior context to fall back to. A
provisioning failure here means the pipeline genuinely cannot produce a `user_id`, so this
design fails the request (500) rather than silently forging a partial/empty auth context that
downstream code might mistake for a real one. **Flagged explicitly as OQ-9 (§10)** since this is
a real, judgment-driven divergence from the literal R-Co behavior, not an oversight.

### 4.7 Which "roles" populate the auth context — DECISION: `IdentityContext.roles`, not `RoleRegistry`

**Decision: the `roles` field attached to `conn.assigns` (§5) is `identity_context.roles` —
REQ-017's already-resolved, token-claimed role-name list — not anything queried from
`Letflow.Identity.RoleRegistry`.**

Reasoning (per the task's explicit instruction to decide this and justify it, not silently
conflate the two):
- `RoleRegistry` is confirmed standalone (§0): its own moduledoc states it has "no coupling to
  the OIDC/claim-mapping pipeline," is not called by and does not call `Letflow.Identity`'s
  OIDC-pipeline functions, and its `resolve_role_in_tx/1` is explicitly designed to be invoked
  **from inside a future S3 `applyTransition`'s own transaction** (`req020-role-registry.md` §5)
  — a workflow-engine, transition-time role→group-UUID resolution, not a request-time
  "what roles does this authenticated user have" lookup.
  `RoleRegistry.list_roles/0` (returns every `tenant_role` binding, not "this user's roles") and
  `RoleRegistry.resolve_role_in_tx/1` (returns a single `group_id` for a role *name*, given as
  input — it does not take a user and does not return a list) are both the wrong shape for
  populating a per-request "roles this user has" value even if this design wanted to call them.
- `identity_context.roles` (`Letflow.Oidc.IdentityContext.roles :: [String.t()]`) is exactly
  "the role names this token's claims say this user has" — resolved by REQ-017's
  `map_verified_claims/3` from the token's `realm_access.roles`/`roles` claim path (or whatever
  `ClaimMappingConfig.roles_claim_paths` for this realm specifies). This is the closest existing
  value to "this request's caller's roles," and is already computed as part of step 4's own
  claim-mapping call (§4.5) — no extra query needed.
- **Consequence, stated explicitly so it isn't silently assumed away:** the `roles` value
  attached to the auth context is **token-claimed, not DB-persisted**. It reflects whatever
  Keycloak (or the test double) put in the token's roles claim at token-issuance time, not any
  Letflow-side authorization table. If a future requirement wants request-time roles to be
  cross-checked or overridden by `RoleRegistry`'s DB-backed bindings, that is a new, explicit
  design decision for that future requirement — this design does not attempt to merge or
  reconcile the two sources. Coupling `AuthPipeline` to `RoleRegistry` now, without an
  acceptance criterion asking for it, would be exactly the kind of unstated-assumption scope
  creep the task instruction warned against.

## 5. Auth context attachment — exact `conn.assigns` keys and error-response shapes

### 5.1 Success path

On full pipeline success (steps 1-4 all pass), `AuthPipeline.call/2` returns `conn` with:

```
conn.assigns[:auth_context] :: %{
  user_id: Ecto.UUID.t(),
  tenant_id: Ecto.UUID.t(),
  roles: [String.t()]
}
```

**Single assign key, `:auth_context`, holding one map with all three fields** — not three
separate top-level assign keys (`conn.assigns[:user_id]`, `conn.assigns[:tenant_id]`,
`conn.assigns[:roles]`). Reasoning: acceptance criterion 1 names the three fields as one
grouped concept ("an auth context (user_id, tenant_id, roles)"), and a single namespaced key
avoids the risk of a downstream plug/handler colliding with a bare `:tenant_id` or `:roles` key
for an unrelated purpose (e.g. a future S4 handler that reads a *route-parameter* `tenant_id`
under a plain `:tenant_id` assign — keeping the auth-derived value under one nested key avoids
that ambiguity structurally). This is this design's own choice (REQ-021's acceptance criteria
do not mandate a specific assign-key shape) — flagged as **OQ-10** (§10) for REVIEWER
confirmation, since it is the one place a plausible alternative (three flat keys) exists and
either would satisfy the literal acceptance-criterion wording.

### 5.2 401 — missing/malformed/invalid token, or realm-ownership failure

```
status: 401
content-type: application/json
body: {"error": "unauthorized", "detail": "<short, non-token-echoing reason string>"}
```

`detail` is a short, fixed, non-parameterized string per failure class (e.g. `"missing or
malformed Authorization header"`, `"invalid or expired bearer token"`, `"token realm does not
match tenant"`) — **never** includes the raw token, any raw claim value, or DB error detail
(INV-4 adjacent discipline, §9). `conn` is halted (`Plug.Conn.halt/1`) after `send_resp/3` —
`:match`/`:dispatch` never runs for a halted `conn` (standard `Plug.Router` behavior, no
deviation).

### 5.3 403 — JIT-disabled realm (§4.5)

```
status: 403
content-type: application/json
body: {"error": "forbidden", "detail": "JIT provisioning disabled for this realm"}
```

### 5.4 500 — provisioning failure (§4.6)

```
status: 500
content-type: application/json
body: {"error": "internal_error", "detail": "user provisioning failed"}
```

No changeset error detail, no DB error message included in the response body (would risk
leaking internal schema/constraint names to an external caller — a general hardening practice,
not a specifically-cited invariant here since INV-2's field-authorization concern is scoped to
S4 tenant-data responses, but consistent with that same general discipline applied early).

### 5.5 503 — tenant migrating, write request (`Letflow.Plugs.TenantStatus`, §6)

```
status: 503
content-type: application/json
retry-after: "30"
body: {"error": "tenant_migrating", "detail": "tenant is being migrated; writes are paused"}
```

PROVENANCE (historical, not current decision authority):
`Retry-After` header value: **`"30"`** (30 seconds, a fixed literal, not computed from any
migration-progress estimate — R-Co's own `tenant_status.zig` has no `Retry-After` header at all
in its ported implementation, confirmed §0: `checkTenantWritePause`'s `HandlerResult` sets only
`status_code`/`body`, no headers map). **This design adds the `Retry-After` header** since
REQ-021's acceptance criterion 3 explicitly requires it ("rejected with 503 and a Retry-After
header") even though R-Co's own source doesn't have one — this is a case where REQ-021's
acceptance criteria go beyond a literal port. The specific value `30` is this design's own
choice (no source specifies a duration) — flagged as **OQ-11** (§10) since any positive integer
technically satisfies "has a Retry-After header," but `30` is a reasonable, round default absent
a more specific business requirement.

PROVENANCE (historical, not current decision authority):
## 6. `Letflow.Plugs.TenantStatus` — step 5, `tenant_status.zig` port

### 6.1 Module shape and placement in the call order

```
@behaviour Plug

@spec init(opts :: keyword()) :: keyword()
@spec call(conn :: Plug.Conn.t(), opts :: keyword()) :: Plug.Conn.t()
```

Same trivial-`init/1`-pass-through convention as §4.1.

**Runs after `AuthPipeline`, reading `conn.assigns[:auth_context][:tenant_id]`** — not
integrated as a fifth in-line step inside `AuthPipeline.call/2` itself. Reasoning: R-Co's own
`checkTenantWritePause/4` doc comment states its calling convention explicitly — *"Call
`checkTenantWritePause()` **after** auth resolves the `tenant_id** and before dispatching to a
write handler"* (§0) — i.e. R-Co itself treats this as a distinct, later step consuming auth's
output, not a step fused into auth resolution. Keeping it a separate Plug in the pipeline (§2's
reasoning) makes this ordering explicit and structural (its position in the `plug` pipeline list,
§8) rather than implicit inside one large function.

### 6.2 Method check (first, cheapest short-circuit)

- `conn.method` is one of `"POST"`, `"PUT"`, `"PATCH"`, `"DELETE"` → proceed to §6.3.
PROVENANCE (historical, not current decision authority):
- Otherwise (`"GET"`, `"HEAD"`, or any other method) → **pass through unchanged, no DB query at
  all.** Matches R-Co's own `isWriteMethod/1` short-circuit (`tenant_status.zig` lines 23-28,
  §0) and acceptance criterion 3's second half verbatim ("a GET/HEAD request against the same
  tenant passes through").

### 6.3 Tenant status lookup

PROVENANCE (historical, not current decision authority):
- Read `conn.assigns[:auth_context][:tenant_id]`. If `AuthPipeline` did not run before this plug
  (so `:auth_context` is absent) — see **OQ-12** (§10): this design specifies that
  `TenantStatus` is only ever mounted after `AuthPipeline` in the same pipeline (§8), so this
  case should not occur in practice for any route that mounts both; if a future route mounts
  `TenantStatus` alone (without `AuthPipeline` ahead of it), this design does not currently
  define that behavior — flagged explicitly, not silently defaulted to "pass through" the way
  R-Co's own `tenant_id.len == 0` no-context case does (`tenant_status.zig` line 47, §0: "No
  tenant context (bootstrap / platform-admin calls) → allow through" — a case this design's
  environment doesn't have a direct equivalent for, since Letflow has no bootstrap-token
  concept, §4.6).
- Query `Letflow.Identity.Tenant`'s `status` field for the resolved `tenant_id` — via
  `Ecto.Query`/`Repo.get/2` (parameterized, INV-7), never `Repo.query/3` raw SQL. This design
  does not require a new `Letflow.Identity` function for this — `Repo.get(Tenant, tenant_id)`
  (or an equivalent minimal query selecting only `:status`) is sufficient; no new public
  function signature is specified here since this is a single-field read internal to this
  plug's own module, not a cross-module context-function call. **OQ-13** (§10) flags this as a
  place ELIXIR-DEV/REVIEWER may prefer promoting to a named `Letflow.Identity` function instead
  (e.g. `get_tenant_status/1`) for consistency with this project's "context module owns all
  `Repo` access for its schemas" convention — this design does not mandate either shape.
- `status == :migrating` → **503 + Retry-After (§5.5), halt.**
- `status == :active`, or tenant row not found (should not occur — `AuthPipeline` already
  resolved this tenant via `resolve_tenant_by_realm/1`, so a not-found here would indicate a
  race/deletion between steps, not a normal case) → pass through unchanged.

### 6.4 Fail-open vs. fail-closed — explicit divergence from R-Co, flagged

PROVENANCE (historical, not current decision authority):
R-Co's `checkTenantWritePause/4` is **fail-open** on every DB-level problem: pool exhaustion
returns `null` (pass through) and query failure returns `null` (pass through) — its own comments
say so explicitly (`tenant_status.zig` lines 49, 56: `"on pool exhaustion let through"`, `"on
query failure let through (fail-open)"`). **This design does not mandate the same fail-open
choice for Letflow** — a genuine DB error during this lookup is a case this design leaves to
ELIXIR-DEV/REVIEWER judgment, flagged as **OQ-14** (§10), rather than silently inheriting R-Co's
choice or silently reversing it. Argument for fail-open (matches R-Co, avoids an unrelated DB
hiccup blocking all writes platform-wide): argument for fail-closed (avoids a period of DB
instability silently bypassing a deliberate tenant-migration write-pause, which is a
data-integrity safeguard, not merely a UX nicety) — both are defensible, and REQ-021's
acceptance criteria do not resolve which one is correct. This design's own recommendation,
stated as a recommendation and not a mandate: **fail-closed is more consistent with this
plug's actual purpose** (protecting data integrity during migration is more load-bearing than
uptime for writes during a transient DB blip that would presumably already be affecting reads
too) — but this is explicitly left open for the next gate to confirm rather than decided
silently here.

## 7. `@moduledoc` requirement (answers acceptance criterion 5)

**Explicit acceptance-criterion requirement** (REQ-021's fifth acceptance criterion, quoted in
full): *"moduledoc explicitly states this plug supersedes REQ-103 (never built) as Letflow's
first real auth plug, and names which router.ex routes (if any) it is mounted in front of."*

`Letflow.Plugs.AuthPipeline`'s `@moduledoc` must, as literal prose (not left to be inferred from
absence of a REQ-103 reference):
1. State that this module is **Letflow's first real auth plug**, and that it **supersedes the
   never-built REQ-103 dev-bearer-token plug** (cancelled with the rest of the MVP-1 milestone,
   per REQ-101's status note in `docs/requirements.yaml`) — explicitly stating REQ-103 is **not**
   prior art this module extends, since it never landed (matching the task instruction's own
   emphatic framing, and `backend_developer_guide.md` §6's identical statement, §0).
PROVENANCE (historical, not current decision authority):
2. Cite `src/api/middleware/auth.zig` as the ported orchestration source.
3. Name explicitly which `router.ex` routes it is mounted in front of **today** — per §8 below,
   the answer is **none of the 3 existing routes** (all documented explicitly as not
   tenant-scoped and not requiring auth yet); state that the plug module exists,
   compiles, and is exercised by tests, but is not yet threaded into any live route's `plug`
   pipeline (§8's "available, not yet wired" framing).

PROVENANCE (historical, not current decision authority):
`Letflow.Plugs.TenantStatus`'s `@moduledoc` must similarly cite `src/api/middleware/
tenant_status.zig` and state its "after auth, before dispatch to a write handler" calling
convention (§6.1).

## 8. Router wiring — DECISION: modules exist and are tested; NOT wired into `router.ex`'s live `plug` pipeline yet

**Decision: `Letflow.Plugs.AuthPipeline` and `Letflow.Plugs.TenantStatus` are built, compiled,
and directly unit/integration-tested (TEST-DESIGNER exercises `call/2` against synthetic `conn`
structs built via `Plug.Test.conn/3`) — but `lib/letflow/router.ex` itself is **not modified**
to add a `plug Letflow.Plugs.AuthPipeline` / `plug Letflow.Plugs.TenantStatus` line ahead of
`:match`/`:dispatch`.**

Reasoning, directly answering the task's explicit framing question ("state explicitly whether
the plug is mounted globally-but-currently-inert, or added but not yet wired into the `plug`
pipeline at all, with reasoning") — **this design chooses the latter: added, but not yet wired
into the `plug` pipeline at all.**

1. **All 3 existing routes are confirmed non-tenant-scoped** (§0, `router.ex` read in full):
   `POST /instances` generates a fresh UUID and starts an unauthenticated process instance;
   `POST /instances/:id/actions` and `GET /instances/:id` operate on that same
   tenant-agnostic, in-memory-only instance. None of the three reads or writes anything under
   `tenants`/`users`, and none would have any tenant/user context to *use* even if
   `AuthPipeline` ran ahead of them today — S2/S3/S4 (the tenant-scoped workflow/task
   surface) are not built yet (confirmed by `docs/requirements.yaml`'s stage sequencing).
2. **Mounting the plug globally-but-inert (i.e. `plug Letflow.Plugs.AuthPipeline` unconditionally
   ahead of `:match`, applying to all 3 existing routes) would immediately break them** — every
   one of the 3 existing routes would now 401 on every request unless a valid, verifiable bearer
   token were supplied, since `AuthPipeline`'s step-1 short-circuit (§4.2) rejects any request
   with no `Authorization` header. That is a behavior change to already-`done`, already-tested
   S3-adjacent functionality (`POST /instances`, etc., covered by existing tests per
   `docs/requirements.yaml`'s earlier requirements) that REQ-021's own scope note explicitly
   says is not what this requirement is for: *"No routes exist yet in lib/letflow/router.ex
   that need real tenant-scoped data... this requirement's acceptance is about the plug
   pipeline itself working correctly against a synthetic/test request, not about protecting a
   real business route yet."* Silently breaking the 3 existing routes' unauthenticated tests
   would contradict that framing and would be exactly the kind of scope-boundary violation
   `core-directives.md`'s Unblock-Everything/scope-boundary distinction warns against (this is
   not "in the way of REQ-021's own acceptance criteria," it's collateral damage to unrelated,
   already-`done` functionality).
3. **"Globally-but-currently-inert" was considered and rejected** as a third option (e.g. mount
   the plug but have it recognize "no tenant-scoped route exists yet" and no-op) — rejected
   because there is no clean, non-hacky way to make a bearer-token-verification plug
   conditionally inert per-route from inside `Plug.Router`'s flat `plug`-list composition
   without either (a) a route-allowlist/denylist mechanism this design would have to invent with
   no acceptance criterion asking for it, or (b) `AuthPipeline` itself branching on
  `conn.request_path`, which is a worse, more special-cased shape than simply not mounting it
   yet. **Building the plug, proving it via direct tests, and leaving `router.ex` unmodified for
   S4 to actually wire in** is the smaller, more honest change matching what REQ-021 actually
   asks for.
4. **S4 (or whichever future stage adds the first tenant-scoped route) is the natural point to
   add `plug Letflow.Plugs.AuthPipeline` / `plug Letflow.Plugs.TenantStatus` to `router.ex`'s
   pipeline** — ahead of `:match`, so `conn.assigns[:auth_context]` is available to every route
   handler dispatched afterward, and `TenantStatus` positioned after `AuthPipeline` per §6.1's
   ordering. This design does not build that wiring now because doing so *would* require picking
   which of the 3 existing routes to protect, which is not this requirement's decision to make.

**This is the literal, explicit answer to REQ-021's own description text** ("note explicitly
which existing router.ex routes (if any) the plug is actually mounted in front of, versus left
available for S4 to attach to later") **and to acceptance criterion 5's naming requirement**
(§7): the plug modules are built and tested; zero `router.ex` routes are currently mounted
behind them; all 3 remain open, unauthenticated, exactly as they are today.

## 9. Security invariants — explicit assessment (INV-1, INV-4, INV-7, INV-8)

**INV-1 (tenant data isolation) — APPLIES (S1 has started), satisfied by construction, with the
scoping mechanism still provisional per this invariant's own stated status.** Every tenant-scoped
read in this design (`resolve_tenant_by_realm/1`, `verify_realm_ownership/2`,
`provision_oidc_user/3`, `TenantStatus`'s tenant-status lookup) goes through `Letflow.Identity`'s
existing, already-reviewed functions or a single-field `Repo.get(Tenant, tenant_id)` scoped to
the one `tenant_id` this pipeline itself resolved (§4.3) — no query in this design accepts a
caller-supplied `tenant_id` from outside the pipeline's own resolution chain. Per INV-1's own
"provisional status" note (single-default-schema deferral, §0/REQ-020 precedent), this design
does not (and cannot yet) enforce isolation via a Postgres `search_path`/`:prefix` mechanism —
that mechanism doesn't exist yet in this codebase (confirmed, same deferral REQ-020's design
documented). SECURITY-REVIEWER should assess this design under the same "not yet checkable via
an automated schema-scoping check, manual review only" framing INV-1's own text specifies for
pre-schema-provisioning S1/S2 work.

**INV-4 (secrets by reference only) — APPLIES.** No secret material (the OIDC client secret, if
one is ever added for a non-`:unauthenticated` client-context mode; the raw bearer token itself)
is logged, included in any error-response body (§5's fixed, non-parameterized `detail` strings),
or serialized into a handoff file. §3.2's `client_id` config (OQ-2) is not itself secret (a
public OAuth client identifier), so no new secret-handling surface is introduced by this design
beyond what REQ-016 already established for `:oidc` config.

**INV-7 (no SQL string interpolation) — APPLIES, satisfied by construction.** Every DB read this
design specifies goes through `Letflow.Identity`'s existing parameterized functions or a plain
`Ecto.Query`/`Repo.get/2` call (§6.3) — no `Repo.query/3` raw SQL anywhere in this design.

**INV-8 (no unhandled crashes on realistic failure paths) — APPLIES.** Every step in this
pipeline (§4.2-§4.5, §6.2-§6.3) is specified as a typed branch on an `{:ok, _} | {:error, _}` (or
equivalent tagged) result from the function it calls — `Oidcc.Token.validate_jwt/3`,
`resolve_tenant_by_realm/1`, `verify_realm_ownership/2`, `provision_oidc_user/3`,
`map_verified_claims/3` all already return typed results per their own `@spec`s (§0, §4). This
design introduces no bare `{:ok, x} = external_call()` pattern match anywhere in its own
call sequence. **One residual risk, stated explicitly rather than silently left implicit:** the
tenant-status `Repo.get/2` call in §6.3 is not wrapped in an explicit rescue for a genuine
connection-level failure (pool exhaustion, connection drop) — this matches this project's
already-established residual-risk precedent (`req019-tenant-realm-binding.md` OQ-4,
`req020-role-registry.md` §9's restatement of the same precedent for `list_roles/0`) rather than
inventing a new, inconsistent policy here. §6.4's fail-open/fail-closed open question (OQ-14) is
the specific place this residual risk becomes a live design decision for `TenantStatus`, not a
silently-assumed default.

## 10. Open questions (not silently resolved)

1. **OQ-1 — `lib/letflow/plugs/` is a new directory/naming precedent** (§2). No prior
   requirement in this codebase created a `plugs/` subdirectory; this design establishes the
   convention future requirements (S4's tenant-scoped routes) would presumably follow. Flagged
   for REVIEWER to confirm this is the right structural choice before it becomes an unreviewed
   precedent by default.
2. **OQ-2 — `config :letflow, :oidc` needs a new `client_id` key** (§3.1). Not currently present
   in `config/dev.exs`/`config/test.exs` (confirmed §0: today's `:oidc` key has only `:issuer`
   and `:provider_name`). This design specifies that ELIXIR-DEV adds a `client_id` entry
   (a placeholder value is acceptable, matching REQ-016's own placeholder-issuer precedent,
   since `client_secret: :unauthenticated` mode does not perform real credential
   authentication against the IdP) — but the exact placeholder value/naming is left to
   ELIXIR-DEV, not mandated here.
3. **OQ-3 — exact `signing_algs` allowlist** for `Oidcc.Token.validate_jwt/3`'s required option
   (§3.1). This design does not hardcode a value (e.g. `["RS256"]`) — left to ELIXIR-DEV/
   REVIEWER, informed by whatever issuer is actually configured for verification testing.
4. **OQ-4 — no fine-grained 401 sub-reason taxonomy** (§3.1, §4.2). R-Co's `Auth401Code` has 12
   members; this design collapses every verification failure to a single generic 401. Not
   required by REQ-021's acceptance criteria (which only specify the status code, not a
   sub-reason enum) — flagged in case a future requirement wants the finer granularity restored.
5. **OQ-5 — the `Letflow.Oidc.TokenVerifier` behaviour seam** (§3.2) is a new architectural
   element this design introduces, with no direct precedent in REQ-016-020. Flagged for
   REVIEWER to confirm this is the right level of indirection.
6. **OQ-6 — realm extraction from `iss` claim's URL suffix vs. a configurable claim path**
   (§4.3). This design recommends the literal R-Co port (parse `iss`'s `"/realms/"` suffix); an
   alternative (a configurable `realm_claim` path, mirroring `ClaimMappingConfig`'s pattern) is
   not built here.
7. **OQ-7 — realm-ownership-guard failure returns 401, not 403** (§4.4). Defensible either way;
   this design's default (401, for pipeline-error-surface uniformity) is not mandated by REQ-021's
   acceptance criteria, which only require "rejected," not a specific status code for this case.
8. **OQ-8 — `:jit_disabled` returns 403** (§4.5). Not directly named by any acceptance criterion;
   this design's own judgment call, flagged for REVIEWER confirmation.
PROVENANCE (historical, not current decision authority):
9. **OQ-9 — this design deliberately does NOT replicate R-Co's "fall back to pre-JIT context on
   provisioning failure" behavior** (§4.6), returning 500 instead, because Letflow has no
   equivalent pre-JIT authenticated identity to fall back to. This is the single largest
   behavioral divergence from a literal `auth.zig` port in this whole design — explicitly
   flagged for REVIEWER sign-off, not a minor detail.
10. **OQ-10 — single nested `:auth_context` assign key vs. three flat assign keys** (§5.1). This
    design's choice (nested) is not mandated by the acceptance criteria's wording; either
    satisfies it.
PROVENANCE (historical, not current decision authority):
11. **OQ-11 — `Retry-After: 30` is an arbitrary fixed value** (§5.5), added because AC3 requires
    the header but no source (R-Co's own `tenant_status.zig` has no such header) specifies a
    duration.
12. **OQ-12 — `TenantStatus` mounted without `AuthPipeline` ahead of it** (§6.3) is explicitly
    undefined behavior in this design — not expected to occur given §8's "both or neither
    mounted together" framing, but not defended against with an explicit guard clause either.
13. **OQ-13 — whether the tenant-status lookup (§6.3) should be promoted to a named
    `Letflow.Identity` function** (e.g. `get_tenant_status/1`) rather than an inline query inside
    `Letflow.Plugs.TenantStatus` itself, for consistency with this project's "context module
    owns `Repo` access" convention. Not mandated either way by REQ-021's acceptance criteria.
14. **OQ-14 — fail-open vs. fail-closed on a genuine DB error during the tenant-status lookup**
    (§6.4). R-Co is fail-open; this design recommends (but does not mandate) fail-closed for
    Letflow, and states the tradeoff explicitly rather than silently picking one.

## 11. Acceptance-criteria traceability

| REQ-021 acceptance criterion | Concrete design element |
|---|---|
| AC1: "a request with a valid OIDC bearer token (or a test double... state explicitly which was used) flows through verify → tenant resolution → realm-ownership guard → JIT provisioning and ends with an auth context (user_id, tenant_id, roles) available to the next plug in the chain" | §3.2 (test double decision, justified — real `r-co-keycloak-1` container reachable but wrong realm/client, explicitly not used); §4.2-§4.5 (the exact 4-step call sequence, in order); §5.1 (`conn.assigns[:auth_context]` exact shape: `user_id`, `tenant_id`, `roles`); §4.7 (roles = `IdentityContext.roles`, justified against `RoleRegistry`) |
| AC2: "a request with a missing or malformed bearer token is rejected with 401 before tenant resolution or JIT provisioning runs" | §4.2 (step 1's short-circuit — 401, halt, before any of steps 2-4 execute); §5.2 (exact 401 body shape) |
| AC3: "a write request (POST/PUT/PATCH/DELETE) against a tenant whose status is migrating is rejected with 503 and a Retry-After header; a GET/HEAD request against the same tenant passes through" | §6 (`Letflow.Plugs.TenantStatus` full design); §6.2 (method allowlist, GET/HEAD pass-through with zero DB query); §6.3 (`:migrating` → 503); §5.5 (exact 503 body + `Retry-After: 30` header) |
| AC4: "a request whose token's realm does not match the resolved tenant's bound realm is rejected, not silently JIT-provisioned under the wrong tenant" | §4.4 (`verify_realm_ownership/2` called and gating BEFORE §4.5's `provision_oidc_user/3` — explicit call-order guarantee stated); §1 item 3 (scope statement: guard before provisioning, per adp-04a) |
| AC5: "moduledoc explicitly states this plug supersedes REQ-103 (never built) as Letflow's first real auth plug, and names which router.ex routes (if any) it is mounted in front of" | §7 (exact required moduledoc content, both plug modules); §8 (the explicit "built and tested, zero routes currently mounted behind it, available for S4" answer this moduledoc must state) |
