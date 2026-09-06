# REQ-076 — Identity routes 4/4: API tokens, role registry, tenant onboarding

No implementation code below — signatures, data shapes, and test specs only.

---

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-076 (full entry, via handoff `context.requirement_text`)
  and its `task.acceptance_criteria` (8 items).
- `docs/guides/backend_developer_guide.md` (full).
- `docs/migration/stage-4-api-surface.md` (full, incl. every REVIEWER sign-off entry
  for REQ-065/070/071/072/073/074/075).
- `docs/migration/decisions/0003-ecto-schema-strategy.md`,
  `0006-identity-tables-schema-per-tenant.md` (schema-per-tenant, `tenant_id` dropped
  from per-tenant tables).
- `lib/letflow/design/req073-identity-user-routes.md`, `req074-identity-group-routes.md`,
  `req075-tenant-administration-routes.md`, `req022-tenant-schema-provisioning.md`,
  `req069-authorization.md` (read for conventions; full text via `Letflow.Api.Authorization`
  itself, below).
- Shipped Letflow code, read directly: `lib/letflow/identity.ex`,
  `lib/letflow/identity/{user,tenant,tenant_role,group,group_member}.ex`,
  `lib/letflow/identity/role_registry.ex` (REQ-020, already ships `list_roles/0` +
  `upsert_role/2`), `lib/letflow/api/authorization.ex`, `lib/letflow/api/response.ex`,
  `lib/letflow/routers/identity.ex`, `lib/letflow/routers/tenants.ex`,
  `lib/letflow/routers/onboarding.ex` (REQ-070 stub), `lib/letflow/routers/tenant_config.ex`,
  `lib/letflow/router.ex`, `lib/letflow/plugs/api_pipeline.ex`,
  `lib/letflow/plugs/auth_pipeline.ex`, `lib/letflow/tenant_provisioning.ex`.
PROVENANCE (historical, not current decision authority):
- **REWORK (attempt 2) additions**: `lib/letflow/plugs/auth_pipeline.ex` (full, re-read
  for §3.5's wiring), `lib/letflow/plugs/api_pipeline.ex` (full, confirms
  `Letflow.Plugs.AuthPipeline` has no per-path bypass), `docs/agents/instructions/security-invariants.md`
  INV-4/INV-5 (exact wording), `src/api/routes/onboarding.zig:379-409`
  (`handleGetOnboardingByHostname`, full body, confirms the PLATFORM_ADMIN gate runs
  **before** the hostname lookup), and — decisive for §8.4's resolution —
  `web/src/api/onboarding.ts:142-149`, `web/src/pages/admin/onboarding/OnboardingResultPage.tsx:1-30,84-156`,
  `docs/frontend/contract-gaps.md` row 20: the SPA's **only** caller of
  `GET /api/v1/onboarding?hostname=` is `OnboardingResultPage`, reached exclusively from
  `admin/onboarding/:onboardingId/result`, a page under the `admin/*` route tree that
  `web/src/components/layout/AppShell.tsx:30` already gates to `PLATFORM_ADMIN`, called
  to restore result-page state on reload **after** the same admin's own `POST
  /api/v1/onboarding` — i.e. the real, only, already-written caller is an authenticated
  PLATFORM_ADMIN session, not an anonymous pre-login page.
- **SCOPE EXTENSION (run `WF02-REQ076-20260822`) additions, for AC9/AC10 (§11/§12
  below)**: `docs/requirements.yaml` REQ-076's full entry re-read directly (not
  re-transcribed) around line 4239, in particular the "PARTIAL-PROVISIONING RECOVERY"
  paragraph and acceptance criteria 9/10 verbatim; `lib/letflow/tenant_provisioning.ex`
  full moduledoc, in particular its "No reconciliation path for a half-provisioned
  tenant" section (already names REQ-076 as the owning requirement) and its "Secondary
  open question" section; `lib/letflow/tenant_provisioning/registration.ex` full (the
  `Registration` schema `migrations_applied_at` field this recovery design detects on);
  `lib/letflow/plugs/tenant_status.ex` full (confirms the write-gate's exact `:migrating`
  mechanics: `@write_methods ~w(POST PUT PATCH DELETE)`, GET/HEAD pass through with **no**
  `Repo` call on that check at all); `lib/letflow/identity/tenant.ex` (confirms `:status`
  already has a three-value `Ecto.Enum` — `[:active, :migrating, :inactive]` — cast via
  `Tenant.tenant_changeset/2` and settable independently via `Tenant.status_changeset/2`;
  no schema change needed for AC10); `test/letflow/plugs/tenant_status_test.exs` (REQ-071
  AC4's own tests, confirms the existing plug-level and write/read test conventions this
  design's §12.3 tests extend, not duplicate); `lib/letflow/plugs/auth_pipeline.ex`'s
  `provision_user/3` (OIDC JIT-provisioning, queries/inserts into the tenant schema's own
  `users` table on every request) and `verify_api_token/2`'s call site (queries the
  tenant schema's own `api_tokens` table on every request) — both decisive for §12.2's
  "no reachable read gap in the empty-schema window" argument; `lib/letflow/routers/onboarding.ex`
  full (the already-shipped AC1–8 orchestration this section extends, not replaces —
  `handle_create/1`/`provision_and_bind/4`); `docs/migration/decisions/0006-identity-tables-schema-per-tenant.md`
  (confirms `users`/`api_tokens` are schema-per-tenant, load-bearing for §12.2's argument);
  `req022-tenant-schema-provisioning.md` §3.2 (the "No implicit chaining invariant," read
  again in full for its literal wording, since AC9's own text quotes it).
PROVENANCE (historical, not current decision authority):
- **R-Co source, read directly** (not assumed): `src/api/routes/identity.zig`
  `handleCreateToken` (L570-632), `handleListTokens` (L634-649), `handleRevokeToken`
  (L651-666), `handleListRoles` (L1169-1199), `handleUpsertRole` (L1201-1246),
  `serializeIssuedToken`/`serializeTokenPage`/`appendTokenItem` (L1051-1123);
  `src/identity/service.zig` `issueToken`/`listTokens`/`revokeToken` (L1210-1421),
  `isIssuableTokenRole` (L1566-1571), `generateTokenValue`/`hashToken` (L1614-1636);
  `src/identity/role_registry.zig` (full — `upsertRole`, `isValidRoleName`,
  `isValidUuidHex`); `src/api/middleware/auth.zig` (L1235-1250, L1446-1504, L1636-1638 —
  the live per-request `api_tokens` lookup, no cache); `src/api/routes/onboarding.zig`
  (full, 921 lines); `src/main.zig` (route table: `resource == "auth"` L1701-1727 for
  tokens, `resource == "roles"` L1696-1717 for roles, `resource == "onboarding"`
  L1584-1608); `migrations/008_identity.sql` (L139-156, `api_tokens` DDL),
  `migrations/019_idn04_api_token_management.sql` (`roles_json` column/constraint).

---

## 1. Scope and routing decisions (stated up front, all three are load-bearing)

### 1.1 Tokens and roles mount under the existing `Letflow.Routers.Identity` (no new router)

Full paths: `POST /api/v1/identity/tokens`, `GET /api/v1/identity/tokens`,
`DELETE /api/v1/identity/tokens/:id`, `GET /api/v1/identity/roles`,
`POST /api/v1/identity/roles`.

Reasoning: `Letflow.Api.Authorization` **already** carries a policy-key clause scoped
exactly this way — `endpoint_policy_key(method, "/tokens" <> _rest) when method in
["POST","GET","DELETE"], do: :TokensManage` (shipped under REQ-069, unreachable until
now) — using the same relative-to-`/identity`-mount convention REQ-073/074 established
(`"/users"`, not `"/identity/users"`). Tokens are user-scoped (`api_tokens.user_id` FK)
and, like users/groups, live inside the caller's own tenant schema (§2) — the same
`opts[:prefix]` discipline as every other `Letflow.Routers.Identity` handler. This is
NOT R-Co's own path shape (R-Co serves tokens at `/api/v1/auth/tokens`, under a
`resource == "auth"` branch, §3.2) — a deliberate divergence, since Letflow's own
`Letflow.Api.Authorization` module already committed to `/tokens` as the policy-key
literal before this requirement existed; matching that existing commitment avoids a
second, inconsistent policy-key convention for the same permission.

Roles has **no existing policy-key clause** — a gap this design adds (§4).

### 1.2 Onboarding stays a standalone top-level router (already stubbed at `/onboarding`)

`Letflow.Routers.Onboarding` (REQ-070 stub) is already forwarded from
`Letflow.Plugs.ApiPipeline` at `/onboarding` (`lib/letflow/plugs/api_pipeline.ex:63`).
This design fills it in. Full paths: `POST /api/v1/onboarding`,
`GET /api/v1/onboarding/:id`, `GET /api/v1/onboarding` (hostname query param). Matches
R-Co's own top-level `/api/v1/onboarding` resource shape (not nested under `/identity`)
— tenant creation is a platform-level operation, same risk class as `Letflow.Routers.Tenants`
(REQ-075), not a per-tenant-scoped one.

**Path-template literal convention for `endpoint_policy_key/2` calls**: follows
`Letflow.Routers.Tenants`'s established convention (full post-`/api/v1` literal, e.g.
`"/onboarding"`, not `"/"`) since Onboarding, like Tenants, is a standalone router with
no domain-grouping prefix segment of its own to be "relative to."

### 1.3 SCOPE BOUNDARY (requirement's own words, restated as a build constraint)

Onboarding does **not** build a new tenant-provisioning mechanism. `POST /onboarding`'s
only tenant-creation path is `Letflow.Identity.create_tenant/1` →
`Letflow.TenantProvisioning.provision_tenant_schema/1` →
`Letflow.TenantProvisioning.replay_migrations/2` — the **identical** three-call sequence
`Letflow.Routers.Tenants`'s `POST /tenants` handler already uses (REQ-075 §7.1, AC7
there). This design does not add a second orchestration. §5 and §8 cover what is and is
not ported beyond that (Keycloak realm/client provisioning, initial-admin-user creation,
idempotency-key machinery — none of it is built here; all explicitly deferred, not
silently dropped).

**SCOPE EXTENSION note (AC9/AC10, §11/§12):** §11's new `Letflow.TenantOnboarding` module
sequences the same two `TenantProvisioning` primitives — it is the same "one path, not
two" orchestration, now reused for recovery as well as creation (§11.2), not a second
provisioning mechanism.

---

## 2. Schema: `api_tokens` (new, tenant-scoped)

**Tenant-scoped, not global** — lives in each tenant's own Postgres schema, alongside
`users`/`groups`/`tenant_role` (Decision 0006). Reasoning: `api_tokens.user_id`
references `users.id`, and `users` is already per-tenant-schema (REQ-063/064) — a token
table in the default/public schema could not carry a real DB-level FK to a per-tenant
`users` table. Follows REQ-022 §4's mandatory migration guard pattern exactly (branch on
`Ecto.Migration.prefix()`, no-op on a plain global `mix ecto.migrate`) and must be
appended to `Letflow.TenantProvisioning.tenant_scoped_migrations/0`'s manifest — both
halves, per that section's own "both mandatory, not either/or" rule.

**Ecto schema module:** `Letflow.Identity.ApiToken` — `lib/letflow/identity/api_token.ex`.

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | `:binary_id` | `primary_key: true` | matches every other table |
| `user_id` | `:binary_id` | `references(:users, type: :binary_id)`, `null: false` | same-schema FK (both tables live in the tenant's schema together) |
| `name` | `:string` | `null: false` | server-generated (§3.1), never caller-supplied |
| `token_hash` | `:string` | `null: false`, `unique_index` | SHA-256 hex digest (64 lowercase hex chars) of the plaintext token. **Never the plaintext itself, anywhere in this table.** |
| `roles` | `{:array, :string}` | `null: false` | snapshotted at issuance (§3.1) — a plain Postgres text array, not `jsonb` (Decision-A-consistent Ecto-idiomatic simplification over R-Co's `roles_json`; no acceptance criterion needs JSON-specific querying) |
| `expires_at` | `:utc_datetime` | nullable | absent = never expires |
| `revoked_at` | `:utc_datetime` | nullable | set once, on `revoke_token/2`; idempotent (§3.3) |
| `last_used_at` | `:utc_datetime` | nullable | best-effort, updated by `verify_api_token/2` (§3.4) on a successful verification only |
| — | — | `timestamps(updated_at: false)` | `inserted_at` = issuance time (matches `created_at` in every AC/response name below) |

Indexes: `unique_index(:api_tokens, [:token_hash])` (the lookup path — §3.4 — and what
makes a hash collision structurally impossible to insert twice), `index(:api_tokens,
[:user_id])` (list/cascade-delete support).

**No `password_hash`-style sentinel needed** — `token_hash` has no "not yet set" state;
every row is created with a real hash in the same insert.

**Migration header comment (ELIXIR-DEV, required, matches REQ-022 §2's convention):**
states this table's tenant-scoping guard pattern, cites this design doc, and the
"NEVER the plaintext" invariant, so a future reader auditing `priv/repo/migrations/` for
INV-4 compliance finds it stated in the migration itself, not only here.

---

## 3. `Letflow.Identity` additions — API tokens

Same `opts :: [prefix: String.t()]` convention as every REQ-073/074 function (`:prefix`
always derived from `Letflow.Api.Context.scoped_repo_opts/1`, never from request data).

### 3.1 `create_token/3`

```
@spec create_token(
        user_id :: Ecto.UUID.t(),
        attrs :: %{roles: [String.t()], expires_at: DateTime.t() | nil},
        opts :: opts()
      ) ::
        {:ok, %{token: ApiToken.t(), plaintext: String.t()}}
        | {:error, :user_not_found}
        | {:error, :invalid_role_set}
        | {:error, :expires_at_in_past}
        | {:error, Ecto.Changeset.t()}
```

**Behavior, in order:**

1. `Repo.get(User, user_id, prefix: prefix)` → `nil` → `{:error, :user_not_found}`.
2. `attrs.roles` must be non-empty and every entry must be one of the **five** literal
   role-name strings `Letflow.Api.Authorization.roles/0` returns as strings (`"PLATFORM_ADMIN"`,
   `"PROCESS_DESIGNER"`, `"PROCESS_OPERATOR"`, `"TASK_WORKER"`, `"AGENT_RUNNER"`) — exact
   match, case-sensitive. Any entry outside that set (including an empty list) →
   `{:error, :invalid_role_set}`. **This function does NOT call
   `Authorization.roles_from_strings/1`** — that function's contract is "silently drop an
   unrecognized string," appropriate for untrusted bearer-token claims where a partial
   role set degrading gracefully is correct; here, a caller explicitly requesting an
   unrecognized role must be rejected loudly (422), not silently granted a narrower token
   than they asked for. A new, small membership-check helper is added for this purpose
   (private to `Letflow.Identity`, or a new public `Letflow.Api.Authorization` function —
   ELIXIR-DEV's choice, not security-relevant either way).
3. If `attrs.expires_at` is given: must be strictly after `DateTime.utc_now/0` at the
   moment of the check → otherwise `{:error, :expires_at_in_past}`.
4. Generate the plaintext token value: `"lf_tok_" <> (32 random bytes, lowercase hex)`
   — via `:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)`. **Deliberate
   prefix divergence from R-Co's `"bpm_tok_"`** — cosmetic only (project rebrand), stated
   here so it isn't mistaken for a missed literal match; nothing security-relevant
   depends on the prefix string.
5. `token_hash = :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)` —
   64 lowercase hex chars, same algorithm as R-Co's `hashToken/1` (SHA-256; ported
   exactly — a high-entropy 256-bit random value hashed for at-rest storage does not need
   a slow/salted password-hash function, matching R-Co's own choice, not weakened or
   strengthened).
6. `name = "token-" <> String.slice(token_hash, 0, 8)` — matches R-Co's own generated-name
   scheme exactly (`token_name = "token-{s}", .{token_hash[0..8]}`).
7. Insert an `%ApiToken{}` (`user_id`, `name`, `token_hash`, `roles: attrs.roles`,
   `expires_at: attrs.expires_at`) via `Repo.insert/2`, `prefix: prefix`.
8. Return `{:ok, %{token: inserted_token, plaintext: plaintext}}` — **`plaintext` is a
   bare value returned only in this function's own return tuple, never assigned to any
   struct field, never logged.** This is the single call site in the whole codebase that
   ever holds the plaintext after generation; the caller (the router handler, §6.1) must
   read it out of this tuple and place it directly into the 201 response body, never
   re-deriving or re-storing it.

PROVENANCE (historical, not current decision authority):
**Roles are snapshotted, not live-referenced** — matches R-Co's own documented behavior
(`service.zig:1210-1212`'s comment: "roles are SNAPSHOTTED at call time... subsequent
changes... do NOT affect this token's effective roles"). Ported as-is; no live
role-lookup join exists on this table by design.

PROVENANCE (historical, not current decision authority):
**R-Co's `isIssuableTokenRole` allows exactly the same five roles this design's step 2
checks against** (`.PLATFORM_ADMIN, .PROCESS_DESIGNER, .PROCESS_OPERATOR, .TASK_WORKER,
.AGENT_RUNNER => true, else => false`) — confirmed by direct read (`service.zig:1566-1571`).

PROVENANCE (historical, not current decision authority):
**Deliberate non-port, flagged (not silent): R-Co's `VIEWER`-default-when-empty is NOT
ported.** `service.zig:1224`'s own comment says empty `input.roles` defaults to
`&.{auth.Role.VIEWER}` — but `VIEWER` is not a member of R-Co's own `isIssuableTokenRole`
allow-set (`.VIEWER` is absent from that switch's `true` arm), so in R-Co's actual source
this default-and-then-validate sequence is unreachable without raising
`InvalidRoleSet` — i.e. R-Co's own empty-roles default is dead/self-contradicting code.
Separately, `VIEWER` does not exist anywhere in `Letflow.Api.Authorization.role/0`'s
five-value type at all (confirmed: `roles/0` returns exactly `[:PLATFORM_ADMIN,
:PROCESS_DESIGNER, :PROCESS_OPERATOR, :TASK_WORKER, :AGENT_RUNNER]`) — there is no
role to default to even if this design wanted to preserve the intent. So step 2 above
rejects an empty/missing `roles` list outright (`{:error, :invalid_role_set}`) rather
than defaulting to anything.

### 3.2 `list_tokens/1`

```
@spec list_tokens(opts :: opts()) :: {:ok, [ApiToken.t()]}
```

PROVENANCE (historical, not current decision authority):
`Repo.all(from(t in ApiToken, order_by: [desc: t.inserted_at]), prefix: prefix)` — matches
R-Co's own `ORDER BY created_at DESC` (`service.zig:1343`). Unpaginated, matching R-Co's
own `TokenListPage` (a flat `items` array, no cursor) — no acceptance criterion here asks
for cursor pagination on this endpoint. Always `{:ok, _}` — an empty result is `{:ok, []}`,
never an error.

### 3.3 `revoke_token/2`

```
@spec revoke_token(token_id :: Ecto.UUID.t() | String.t(), opts :: opts()) ::
        {:ok, ApiToken.t()} | {:error, :not_found}
```

`Repo.get(ApiToken, token_id, prefix: prefix)` → `nil` → `{:error, :not_found}`. Otherwise:
if `revoked_at` is already set, return `{:ok, token}` unchanged (idempotent — matches
R-Co's `SET revoked_at = COALESCE(revoked_at, NOW())`, which never overwrites an existing
revocation timestamp with a later one); otherwise `Repo.update/2` setting
`revoked_at: DateTime.utc_now()`.

### 3.4 `verify_api_token/2` — the propagation-guarantee mechanism (AC4)

```
@spec verify_api_token(plaintext :: String.t(), opts :: opts()) ::
        {:ok, %{user_id: Ecto.UUID.t(), roles: [String.t()]}}
        | {:error, :invalid}
        | {:error, :revoked}
        | {:error, :expired}
```

**Mechanism (this IS the propagation guarantee, stated exactly, not left implicit):**

1. `token_hash = :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)`.
2. `Repo.get_by(ApiToken, [token_hash: token_hash], prefix: prefix)` — a **live,
   uncached, per-call database read**, every single invocation. There is no ETS table,
   no `Cachex`/process-dictionary cache, no ProviderConfiguration-Worker-style periodic
   refresh anywhere in this design's call path — this function does exactly one `Repo`
   round trip per call, always against current data.
3. `nil` → `{:error, :invalid}`.
4. `%ApiToken{revoked_at: revoked_at}` when `revoked_at != nil` → `{:error, :revoked}`.
   **This is what makes revocation take effect on the very next call**: step 2's read is
   never stale by construction (nothing between "the revoking `UPDATE`" and "the next
   `verify_api_token/2` call's `Repo.get_by/3`" can observe a pre-revocation value,
   because there is no cache layer between them to be stale) — not "eventually
   consistent," not "correct after some expiry window," correct on literally the next
   call, matching AC4's own wording.
5. `%ApiToken{expires_at: expires_at}` when `expires_at != nil and DateTime.compare(expires_at, DateTime.utc_now()) != :gt` → `{:error, :expired}`.
6. Otherwise: best-effort `Repo.update/2` setting `last_used_at: DateTime.utc_now()` (a
   failure here — e.g. a genuine DB error on this one non-essential write — must not
   fail the whole verification; wrap narrowly, log, and continue to step 7 regardless).
7. `{:ok, %{user_id: token.user_id, roles: token.roles}}`.

PROVENANCE (historical, not current decision authority):
**REWORK (attempt 2): scope decision reversed — `Letflow.Plugs.AuthPipeline` wiring for
API tokens IS in this requirement's scope; see §3.5.** Attempt 1 deferred this to a
future requirement on the grounds that `src/api/middleware/auth.zig` is not one of
REQ-076's named source files. CODE-DESIGN-VALIDATOR correctly rejected that: AC4's
literal text is "a revoked token is rejected with 401 on the very next request," and
INV-4's framing in the requirement text itself is "a revoked credential that keeps
working is the failure mode that matters" — neither is satisfiable by a bare
`verify_api_token/2` function that no HTTP path ever calls, since nothing then produces
an HTTP 401. `verify_api_token/2` itself (this section, unchanged) is still the correct
primitive; §3.5 is the minimal wiring that makes it reachable from a real request.

### 3.5 `Letflow.Plugs.AuthPipeline` wiring for API tokens (AC4, resolves OQ-1's narrow case)

PROVENANCE (historical, not current decision authority):
**Scope discipline, stated up front:** this section changes `Letflow.Plugs.AuthPipeline`
(shipped under REQ-021/071, not a REQ-076 source file in the `identity.zig`/`onboarding.zig`
sense) by exactly one new branch, added alongside the existing OIDC bearer-token branch,
never replacing it. It solves only the single-tenant-identification mechanism named
below — it does **not** attempt the general problem of embedding tenant identity inside
an opaque bearer token, and does not touch any of the five existing OIDC steps
(`extract_bearer_token/1`'s output is shared; every step after it is new and separate).

**Dispatch — cheap and unambiguous, no format ambiguity with a JWT:**

`Letflow.Plugs.AuthPipeline.call/2`'s `with` chain gains a branch immediately after
`extract_bearer_token/1` succeeds: `raw_token` is inspected with
`String.starts_with?(raw_token, "lf_tok_")` (the literal, fixed prefix §3.1 step 4
generates — never present in a JWT, which is three `.`-joined base64url segments with no
fixed literal prefix). `true` → the new API-token branch below. `false` → the existing
five-step OIDC branch, **completely unchanged** (same functions, same order, same error
tags) — this dispatch is the only new thing on the OIDC path, and it changes nothing
about OIDC's own behavior when `raw_token` doesn't start with `"lf_tok_"`.

**API-token branch — five steps, mirroring the OIDC branch's own "tag the step" discipline:**

```
with {:ok, raw_token} <- extract_bearer_token(conn),
     true <- api_token?(raw_token),
     {:ok, slug} <- extract_tenant_slug_header(conn),
     {:ok, tenant} <- resolve_tenant_by_slug(slug),
     {:ok, schema_name} <- resolve_schema_name(tenant.id),
     {:ok, verified} <- verify_token_credential(raw_token, schema_name) do
  attach_auth_context(conn, tenant.id, verified.user_id, verified.roles)
else
  ...
end
```

1. **`extract_tenant_slug_header/1`** — reads the `x-tenant-slug` request header (via
   `Plug.Conn.get_req_header/2`, same idiom `extract_bearer_token/1` already uses).
   Exactly one non-empty value required; zero values, more than one value, or an
   empty-string value → `{:error, {:api_token, :header_missing}}`. This header is read
   **only** on the API-token branch — the OIDC branch never looks at it, so it is
   harmless/ignored on every OIDC-authenticated request. This is the "single
   mechanism" the rework instruction names: a caller authenticating with an API token
   must additionally send `X-Tenant-Slug: <tenant slug>`, since the bearer value itself
   (unlike a JWT's `iss` claim) carries no tenant hint (§3.4's own point, restated).
2. **`resolve_tenant_by_slug/1`** — `Letflow.Identity.get_tenant_by_slug/1` (already
   shipped, used identically by `Letflow.Routers.TenantConfig`, §8's own precedent).
   `{:ok, tenant}` → step 3. `{:error, :not_found}` (or any other error the function
   returns) → `{:error, {:api_token, :tenant_not_found}}`.
3. **`resolve_schema_name/1`** — `Letflow.TenantProvisioning.schema_name_for_tenant/1`,
   the exact same call `provision_user/3`'s OIDC-branch step 4b already makes
   (confirmed no-I/O, pure derivation from `tenant_id`). `{:error, :invalid_tenant_id}`
   → `{:error, {:api_token, :tenant_not_found}}` (same tag as step 2's miss — a tenant
   id that fails schema-name derivation is, from the caller's perspective, the same
   class of failure as an unresolvable slug; neither should produce a status-code or
   body difference from the other 401 branches, per the uniformity note below).
4. **`verify_token_credential/2`** — `Letflow.Identity.verify_api_token(raw_token,
   prefix: schema_name)` (§3.4, unchanged). `{:ok, %{user_id: user_id, roles: roles}}`
   → step 5. `{:error, :invalid}` → `{:error, {:api_token, :invalid}}`.
   `{:error, :revoked}` → `{:error, {:api_token, :revoked}}` — **this is the branch AC4's
   test exercises**: a request carrying a just-revoked token's plaintext reaches this
   exact call, on this exact live `Repo.get_by/3` (§3.4 step 2, no cache), every time.
   `{:error, :expired}` → `{:error, {:api_token, :expired}}`.
5. **`attach_auth_context/4`** (existing function, unchanged) — `tenant.id` (from step
   2, the schema-authoritative source, never a token-claimed value — same discipline
   the OIDC branch's own comment at step 4b already states for `tenant_id`),
   `verified.user_id`, `verified.roles`. No JIT provisioning step exists on this
   branch: `create_token/3` (§3.1 step 1) already requires `user_id` to reference an
   existing row, so the user this token authenticates as is guaranteed to already
   exist — there is nothing to provision.

**Error-response uniformity (matches the existing OIDC branch's own collapsing
discipline exactly — `{:verify,_}`/`{:realm,_}`/`{:tenant,_}`/`{:ownership,:not_found}`/
`{:claims,_}` already all collapse to the identical "invalid or expired bearer token"
401 body):**

```
{:error, {:api_token, :header_missing}}   -> reject(conn, 401, "unauthorized", "invalid or expired bearer token")
{:error, {:api_token, :tenant_not_found}} -> reject(conn, 401, "unauthorized", "invalid or expired bearer token")
{:error, {:api_token, :invalid}}          -> reject(conn, 401, "unauthorized", "invalid or expired bearer token")
{:error, {:api_token, :revoked}}          -> reject(conn, 401, "unauthorized", "invalid or expired bearer token")
{:error, {:api_token, :expired}}          -> reject(conn, 401, "unauthorized", "invalid or expired bearer token")
```

Deliberate: a missing header, an unresolvable slug, a garbage token, a revoked token,
and an expired token are all byte-identical 401s — the same anti-oracle discipline this
module's existing OIDC branch already applies to its own five failure tags, extended to
the new ones rather than inventing a differently-worded message that would let a caller
distinguish "your slug is wrong" from "your token is revoked" by response text.

**No realm-ownership check, no claim mapping, no JIT provisioning on this branch** — all
three are OIDC-specific concepts (realm-to-tenant binding, IdP claim shape, first-login
provisioning) that do not apply to a pre-existing internal user authenticating with a
token they were issued directly by an already-authenticated PLATFORM_ADMIN (§3.1's own
caller — `create_token/3` is itself `:TokensManage`/PLATFORM_ADMIN-gated, §4 point 1).

**`Letflow.Plugs.AuthPipeline`'s moduledoc** gains a new numbered step (inserted as an
alternate 1b/2b branch alongside its existing 5-step OIDC list) stating this mechanism
by name (`X-Tenant-Slug` header) and this exact scope boundary: *"the general problem of
resolving a tenant from an opaque bearer credential with no embedded tenant hint is not
solved here — only this one caller-supplied-header mechanism is. A future credential
type that needs a different resolution mechanism (e.g. a tenant segment embedded in a
path) is a new branch, not a generalization of this one."*

**OQ-1 (§10) narrowed, not closed:** whether a request header is the right long-term
mechanism for API-token tenant resolution — versus, e.g., encoding the tenant slug into
the token's own plaintext at issuance (`"lf_tok_" <> slug <> "_" <> hex`) so no header is
needed — is **not** decided here; the header mechanism above is sufficient to make AC4
demonstrable via a real HTTP round trip and does not foreclose a future redesign (a
header-based mechanism and a token-embedded one are not mutually exclusive at the wire
level — `AuthPipeline` could try the header first and fall back to a token-embedded hint
later without a breaking change to already-issued tokens, since `verify_api_token/2`
itself does not care how its `prefix:` opt was derived).

---

## 4. `Letflow.Api.Authorization` additions (small, additive — matches REQ-073 gap-6/REQ-075's own precedent of touching this already-shipped module)

PROVENANCE (historical, not current decision authority):
1. **No change needed for tokens.** `:TokensManage` (permission), `:TokensManage`
   (endpoint policy key), and the `"/tokens" <> _rest` clause already exist and already
   resolve correctly: `role_allows?(:PLATFORM_ADMIN, _)` is the only clause granting
   `:TokensManage` today (no `:PROCESS_DESIGNER`/other clause lists it) — this
   **already matches R-Co's actual behavior exactly**: `issueToken`/`listTokens`/
   `revokeToken` each open with `if (actor.role != .PLATFORM_ADMIN) return
   error.Forbidden;` (confirmed, `service.zig:1221`/`:1319`/`:1397`) — PLATFORM_ADMIN
   only, no other role. **Zero code change to this module for the token routes.**

PROVENANCE (historical, not current decision authority):
2. **New permission + endpoint policy key for roles, required.** R-Co's
   `handleListRoles`/`handleUpsertRole` allow **PROCESS_DESIGNER OR PLATFORM_ADMIN**
   (confirmed, `identity.zig:1174`/`:1209`: `if (actor.role != .PROCESS_DESIGNER and
   actor.role != .PLATFORM_ADMIN) return errorResult(..., 403, "forbidden");`) — a
   **strictly wider** grant than any existing permission in the matrix maps to for
   PROCESS_DESIGNER (`:UsersGroupsRolesManage`, which PROCESS_DESIGNER does **not**
   hold today — only PLATFORM_ADMIN's catch-all grants it). Reusing
   `:UsersGroupsRolesManage` would either wrongly grant PROCESS_DESIGNER access to
   `/users`/`/groups` too (if added to that permission's role list) or wrongly deny
   PROCESS_DESIGNER access to `/roles` (if left as-is) — neither matches R-Co. This
   design adds a **new, distinct** permission:
   - `@type permission` gains `:RolesManage`.
   - `@type endpoint_policy_key` gains `:RolesManage`.
   - `def endpoint_policy_key("GET", "/roles"), do: :RolesManage`
   - `def endpoint_policy_key("POST", "/roles"), do: :RolesManage`
   - `def required_permission(:RolesManage), do: :RolesManage`
   - `def role_allows?(:PROCESS_DESIGNER, permission)`'s existing list gains
     `:RolesManage` (append to the existing `[:DefinitionsWrite, :DefinitionsRead,
     :InstancesStart, :InstancesRead, :TasksRead]` list).
   - No other role's `role_allows?/2` clause changes — PLATFORM_ADMIN already has it via
     the unconditional catch-all; PROCESS_OPERATOR/TASK_WORKER/AGENT_RUNNER are
     unaffected (a permission atom absent from a closed `in [...]` list is `false` by
     construction, same mechanism REQ-075 §1.1 point 5 already relied on).

---

## 5. Role registry routes — reuse the existing, already-shipped `Letflow.Identity.RoleRegistry` (REQ-020) unchanged

`GET /identity/roles` → `Letflow.Identity.RoleRegistry.list_roles/0`.
`POST /identity/roles` → `Letflow.Identity.RoleRegistry.upsert_role/2`.

**No new domain function, no schema change.** `Letflow.Identity.RoleRegistry` already
exists (REQ-020, `lib/letflow/identity/role_registry.ex`) with exactly the two functions
this route group needs, already matching R-Co's actual behavior (§5.1 below). This design
only adds the HTTP handler layer (request validation + response shaping) on top of it.

### 5.1 The AC6 constraint question, settled by direct read (not assumed)

PROVENANCE (historical, not current decision authority):
**Requirement text asks: "confirm whether R-Co's upsert can define a role outside
authorization.zig's five-value Role enum, and port the actual constraint."**

PROVENANCE (historical, not current decision authority):
Read `src/identity/role_registry.zig` in full. `upsertRole/3`'s only two validations
(L121-122) are `isValidRoleName(name)` and `isValidUuidHex(group_id)`. `isValidRoleName`
(L224-237) checks: non-empty, ≤128 Unicode codepoints, no ASCII control characters
(`<= 0x1F` or `== 0x7F`). **There is no check anywhere in this function, or anywhere
else in `role_registry.zig`, against `auth.Role`'s five-value enum.** `name` is a
free-form string identifying a role-to-group binding — a **distinct concept** from
`authorization.zig`'s five-value RBAC `Role` enum used for endpoint permission gating
(`handleCreateToken`'s `roles` array, by contrast, **is** validated against that five-value
enum via `auth.Role.fromString/1`, confirmed at `identity.zig:602` — the two "role"
concepts are genuinely different registries in R-Co, not the same one read two ways).

**Confirmed answer: YES, R-Co's upsert can define a role name outside the five-value
enum** — the only constraint is the format check above.

**Letflow's already-shipped `RoleRegistry.validate_role_name/1` already matches this
exactly**, byte-for-byte in substance: non-empty (`name == ""`), `String.length(name) >
128`, `String.match?(name, ~r/[\x00-\x1F\x7F]/u)` — the same three checks, same limits,
same character classes. **No code change needed** — this design's only obligation is
recording the confirmation in the moduledoc (§6.2, AC6) so a future reader doesn't have
to re-derive it. `Letflow.Identity.TenantRole.name`'s uniqueness (a plain global unique
index) is REQ-020's own pre-existing constraint, unrelated to this question.

### 5.2 Flagged, not silently accepted: `RoleRegistry` is not tenant-scoped today

PROVENANCE (historical, not current decision authority):
`RoleRegistry.list_roles/0` and `upsert_role/2` take **no** `opts`/`:prefix` parameter —
`tenant_role` still lives in the global default schema, predating REQ-063/064's
per-tenant-schema cutover of `users`/`groups`/`tenant_role`'s siblings. **This design does
not change that** — REQ-020 (`RoleRegistry`) is an already-`done`, already-gated module,
and fixing its tenant-scoping is not named in REQ-076's source-file scope
(`role_registry.zig` was REQ-020's file, not `identity.zig`'s route-handler file this
requirement covers). Flagged as **OQ-2 (§10)**: role names/bindings are currently shared
globally across every tenant, which is very likely a real cross-tenant data-isolation gap
once more than one tenant actually uses named roles — recommend filing a follow-up issue,
not resolved here.

---

## 6. Router: extend `Letflow.Routers.Identity`

### 6.1 Route wiring (tokens + roles)

```
post   "/tokens",         do: <create token handler>
get    "/tokens",         do: <list tokens handler>
delete "/tokens/:id",     do: <revoke token handler>
get    "/roles",          do: <list roles handler>
post   "/roles",          do: <upsert role handler>
```

All five follow the router's existing `with_authorized_scope/4` preamble (scoped prefix,
then authorization, **no `Repo` call before both**) — identical discipline to every
existing handler on this module. Token handlers pass `opts` through to `Letflow.Identity`
(§3); role handlers call `Letflow.Identity.RoleRegistry` directly, **without** `opts`
(§5.2 — that module takes none).

**`POST /tokens` body:**
```
[
  %FieldConstraint{name: "user_id", required: true, type: :string, reject_empty_string: true},
  %FieldConstraint{name: "roles", required: true, type: :array},
  %FieldConstraint{name: "expires_at", required: false, type: :string}
]
```
`{:errors, field_errors}` → `send_problem(conn, Validation.problem(field_errors))`.
`expires_at`, if present, is parsed via `DateTime.from_iso8601/1` by the handler
(**before** calling `Identity.create_token/3` — `Letflow.Api.Validation.FieldConstraint`
has no datetime-shape validator, matching REQ-073 §2.1's identical note about
`Letflow.Api.Validation`'s constraint vocabulary); a parse failure →
`Response.unprocessable(conn, "expires_at_invalid")`.

`Identity.create_token(user_id, %{roles: roles, expires_at: parsed_expires_at}, opts)` →
- `{:ok, %{token: token, plaintext: plaintext}}` → `Response.created(conn,
  token_created_map(token, plaintext))` (§6.2 — the **one** response in this whole module
  that ever includes a token value).
- `{:error, :user_not_found}` → `Response.not_found(conn)`.
- `{:error, :invalid_role_set}` → `Response.unprocessable(conn, "roles_invalid")`.
- `{:error, :expires_at_in_past}` → `Response.unprocessable(conn, "expires_at_in_past")`.
- `{:error, %Ecto.Changeset{}}` → `Response.unprocessable(conn, "validation failed")`
  (defensive — every field this changeset could reject is already rejected above, listed
  for completeness matching this module's existing convention).

**`GET /tokens`** → `Identity.list_tokens(opts)` → always `{:ok, tokens}` →
`Response.ok(conn, %{"items" => Enum.map(tokens, &token_map/1)})` (§6.2 — **metadata
only, never `token_hash`, never a plaintext**).

**`DELETE /tokens/:id`** → `Identity.revoke_token(conn.params["id"], opts)` →
- `{:ok, token}` → `Response.ok(conn, token_map(token))` (revoked-state metadata, still
  no plaintext/hash — matches the same allowlist as list).
- `{:error, :not_found}` → `Response.not_found(conn)`.

**`GET /roles`** → `RoleRegistry.list_roles/0` → always a list (possibly empty) →
`Response.ok(conn, %{"items" => Enum.map(roles, &role_map/1)})`.

**`POST /roles` body:**
```
[
  %FieldConstraint{name: "name", required: true, type: :string, reject_empty_string: true},
  %FieldConstraint{name: "group_id", required: true, type: :string, reject_empty_string: true}
]
```
`{:errors, field_errors}` → same problem-document path. `RoleRegistry.upsert_role(name,
group_id)` →
- `{:ok, role}` → `Response.ok(conn, role_map(role))` (200, matches R-Co's own
  `handleUpsertRole`'s status code — an upsert, not strictly a create, so 200 not 201,
  matching R-Co's literal `.status_code = 200`).
- `{:error, :invalid_role_name}` → `Response.unprocessable(conn, "invalid_role_name")`.
- `{:error, :invalid_group_id}` → `Response.unprocessable(conn, "invalid_group_id")`.
- `{:error, :group_not_found}` → `Response.not_found(conn)`.
- `{:error, %Ecto.Changeset{}}` → `Response.unprocessable(conn, "validation failed")`
  (defensive, matching `RoleRegistry.upsert_role/2`'s own doc — every named path above
  already covers the realistic failure modes).

### 6.2 Response allowlists (AC1, AC2, AC3, INV-2, INV-4)

**`token_created_map/2`** — the **only** function in this codebase that ever puts a
token plaintext into a response body. Called exactly once, from the create handler's
success branch, on the freshly-returned `{token, plaintext}` pair — never re-derivable
from a persisted row (the row never holds the plaintext, §2):
```
%{
  "id" => token.id,
  "token" => plaintext,
  "name" => token.name,
  "user_id" => token.user_id,
  "roles" => token.roles,
  "expires_at" => iso8601_or_nil(token.expires_at),
  "created_at" => iso8601(token.inserted_at)
}
```

**`token_map/1`** — metadata only, used by list and by revoke's response. **Structurally
excludes `token_hash` and has no parameter through which a plaintext could ever reach
it** (its only argument is `%ApiToken{}`, whose own struct never carries a plaintext
field — the plaintext exists only as a local variable inside `create_token/3`'s own
return tuple, never assigned to any struct, never persisted, so no later map-builder
anywhere in this codebase has a plaintext value available to leak even by mistake):
```
%{
  "id" => token.id,
  "name" => token.name,
  "user_id" => token.user_id,
  "roles" => token.roles,
  "status" => token_status(token),   # "active" | "expired" | "revoked" -- computed, mirrors R-Co's own item.status
  "created_at" => iso8601(token.inserted_at),
  "expires_at" => iso8601_or_nil(token.expires_at),
  "revoked_at" => iso8601_or_nil(token.revoked_at),
  "last_used_at" => iso8601_or_nil(token.last_used_at)
}
```
**Satisfies the requirement text's literal minimum** ("id, name, created_at,
last_used_at, revoked_at") as a strict subset of the fields above — the additional
fields (`user_id`, `roles`, `status`, `expires_at`) are a deliberate, documented
superset matching R-Co's own richer `appendTokenItem` wire shape (§0 sources — R-Co's
actual list response carries `user_id`/`roles`/`status`/`expires_at` too, just not
`name`); nothing in INV-4 forbids exposing non-secret metadata, only the plaintext/hash.

**`role_map/1`**:
```
%{"id" => role.id, "name" => role.name, "group_id" => role.group_id, "created_at" => iso8601(role.inserted_at)}
```

---

## 7. Test designs (traceability targets for TEST-DESIGNER, not written here)

### 7.1 AC1/AC2/AC3 — the plaintext-once / hash-only / never-logged triad (INV-4)

- **AC1a**: `POST /tokens` → 201 body has a `"token"` key with a non-empty string value
  matching the `"lf_tok_" <> hex` shape.
- **AC1b**: immediately follow with `GET /tokens` (or `DELETE ... ; GET` — either
  demonstrates the "subsequent GET" wording) and assert the response body, JSON-decoded
  and walked recursively, contains **no** key literally named `"token"` and no value
  equal to the plaintext captured in AC1a's response — `refute Jason.decode!(resp) |> ...
  =~ plaintext` as a belt-and-suspenders substring check across the raw response body.
- **AC2**: after creation, `Repo.get!(ApiToken, id, prefix: ...)` — assert **every
  field on the struct** (not just `token_hash`) is `!= plaintext` (a loop over
  `Map.from_struct/1`'s values, or an explicit per-field assertion list) — literally
  "querying the row and asserting no column equals the returned plaintext," per AC2's
  own wording.
- **AC3**: capture logs (`ExUnit.CaptureLog`) across (a) a successful `POST /tokens` and
  (b) a deliberately-failed one (e.g. `user_id` pointing at a nonexistent user, or an
  invalid role) — assert the plaintext substring appears in neither captured log output
  nor either response's error body. This also exercises `Letflow.Api.Error`'s existing
  problem-document builder, which never receives the plaintext as an argument by
  construction (§6.1's error branches only ever pass fixed literal strings) — the test
  is a behavioral confirmation of that structural fact, not a hope.

### 7.2 AC4 — revocation propagation, real HTTP 401, no sleep/cache-flush (§3.4, §3.5)

**Primitive-level test (unchanged from attempt 1, kept as a lower-level companion, not a
substitute for the HTTP-level test below):**
```
test "a revoked token is rejected on the very next verification call" do
  {:ok, %{token: token, plaintext: plaintext}} = Identity.create_token(user.id, %{roles: [...], expires_at: nil}, opts)
  assert {:ok, _} = Identity.verify_api_token(plaintext, opts)

  {:ok, _revoked} = Identity.revoke_token(token.id, opts)

  assert {:error, :revoked} = Identity.verify_api_token(plaintext, opts)
end
```

**HTTP-level test (new, required — this is the one that actually demonstrates AC4's
literal "rejected with 401 on the very next request" through a real request, per §3.5):**
```
test "a revoked API token is rejected with 401 on the next HTTP request, no sleep or cache flush" do
  tenant = TenantFixture.provisioned_tenant!(...)
  user = insert_user!(tenant, ...)
  {:ok, %{token: token, plaintext: plaintext}} =
    Identity.create_token(user.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil}, prefix: tenant.schema_name)

  conn1 =
    conn(:get, "/api/v1/identity/tokens")
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("x-tenant-slug", tenant.slug)
    |> Letflow.Router.call(Letflow.Router.init([]))

  assert conn1.status == 200

  {:ok, _revoked} = Identity.revoke_token(token.id, prefix: tenant.schema_name)

  conn2 =
    conn(:get, "/api/v1/identity/tokens")
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("x-tenant-slug", tenant.slug)
    |> Letflow.Router.call(Letflow.Router.init([]))

  assert conn2.status == 401
end
```
`GET /api/v1/identity/tokens` is the chosen protected route: it requires only
`:TokensManage` (§4 point 1, PLATFORM_ADMIN-only), which the freshly-minted token
already carries via its own `roles: ["PLATFORM_ADMIN"]`, so no other fixture/permission
setup is needed beyond the token itself. No `Process.sleep/1`, no cache-clear call, no
process restart between `conn1` and `conn2` — `conn2` is a plain second request using the
same plaintext, immediately after `revoke_token/2` returns, demonstrating that
`Letflow.Plugs.AuthPipeline`'s new branch (§3.5) reaches `verify_api_token/2`'s
uncached, live `Repo.get_by/3` (§3.4 step 2) on literally the next HTTP call.

### 7.3 AC5 — tenant isolation (INV-1)

```
test "a token minted under tenant A cannot verify against tenant B's schema" do
  tenant_a = TenantFixture.provisioned_tenant!(...)
  tenant_b = TenantFixture.provisioned_tenant!(...)
  user_a = insert_user!(tenant_a, ...)

  {:ok, %{plaintext: plaintext}} = Identity.create_token(user_a.id, %{roles: [...], expires_at: nil}, prefix: tenant_a.schema_name)

  assert {:ok, _} = Identity.verify_api_token(plaintext, prefix: tenant_a.schema_name)
  assert {:error, :invalid} = Identity.verify_api_token(plaintext, prefix: tenant_b.schema_name)
end
```
The tenant-B lookup returns `{:error, :invalid}` (not `:revoked`/`:expired`) — the row
genuinely does not exist under tenant B's schema (per-schema table isolation, not a
status check), the same "cannot even see the row" mechanism REQ-072's own cross-tenant
tests already rely on.

### 7.4 AC6 — role-name constraint (§5.1)

One accepted, one rejected test, both through `RoleRegistry.upsert_role/2` (or the HTTP
handler — TEST-DESIGNER's choice):
```
test "a role name outside the five auth.Role values is accepted (format-only constraint)" do
  {:ok, group} = ...
  assert {:ok, %TenantRole{name: "CUSTOM_APPROVER"}} = RoleRegistry.upsert_role("CUSTOM_APPROVER", group.id)
end

test "a role name failing the format constraint is rejected" do
  assert {:error, :invalid_role_name} = RoleRegistry.upsert_role("", group.id)
  assert {:error, :invalid_role_name} = RoleRegistry.upsert_role(String.duplicate("a", 129), group.id)
  assert {:error, :invalid_role_name} = RoleRegistry.upsert_role("bad\x01name", group.id)
end
```
The moduledoc (§6, AC6) must name this observed constraint (format-only: non-empty,
≤128 codepoints, no control characters — no enum-membership check) as literal text, not
paraphrased.

### 7.5 AC7 — onboarding-by-hostname indistinguishability (§8.4, INV-5)

```
test "GET onboarding by hostname is indistinguishable for a never-bound vs. a real-other-tenant hostname, to a caller without :TenantsManage" do
  tenant_a = TenantFixture.provisioned_tenant!(...)
  {:ok, %{token: _t, plaintext: admin_plaintext}} =
    Identity.create_token(admin_user.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil}, prefix: tenant_a.schema_name)

  {:ok, bound_record} =
    Identity.create_onboarding(%{slug: "acme", display_name: "Acme", hostname: "acme.example.com"})

  # non_admin_plaintext: a token minted with a role that does NOT hold :TenantsManage
  # (e.g. PROCESS_DESIGNER) -- exercises Authorization.evaluate_access/2's denial path.
  conn_unbound =
    conn(:get, "/api/v1/onboarding?hostname=never-bound.example.com")
    |> put_req_header("authorization", "Bearer " <> non_admin_plaintext)
    |> put_req_header("x-tenant-slug", tenant_a.slug)
    |> Letflow.Router.call(Letflow.Router.init([]))

  conn_bound_elsewhere =
    conn(:get, "/api/v1/onboarding?hostname=" <> bound_record.hostname)
    |> put_req_header("authorization", "Bearer " <> non_admin_plaintext)
    |> put_req_header("x-tenant-slug", tenant_a.slug)
    |> Letflow.Router.call(Letflow.Router.init([]))

  assert conn_unbound.status == 403
  assert conn_bound_elsewhere.status == 403
  assert conn_unbound.resp_body == conn_bound_elsewhere.resp_body
end
```
Both requests reach `Authorization.evaluate_access/2` and are denied **before**
`Identity.get_onboarding_by_hostname/1` (§8.2) executes on either — the DB-round-trip
count is equal (zero) on both, satisfying INV-5's "How to verify" timing clause (§0), not
just the status/body clause. See §8.4 for the full argument, including why the
PLATFORM_ADMIN-caller pair (200 vs. 404) is deliberately **not** covered by this test —
that pair is not what AC7/INV-5 protects.

### 7.6 AC8 — onboarding routes through `TenantProvisioning`, no second path

Inspection-based (per AC8's own wording: "confirmed by inspection... stated in the
moduledoc") plus one behavioral test: `POST /onboarding` with a valid body → assert the
response's `tenant_id` resolves to a real, queryable Postgres schema (same
`information_schema.tables` pattern REQ-075 §7.1's own AC4 test already uses) — proving
the schema/migrations side-effect actually happened via the shared path, not merely that
a `tenants` row was inserted.

---

## 8. Onboarding

### 8.1 Schema: `onboarding_registry` (new, global/default schema)

Structurally global, like `tenants` and `tenant_schemas` (REQ-022 §2's own reasoning
extends directly: a hostname → tenant resolution must be queryable before any tenant's
own schema context is known). **No `prefix:` option in this migration.**

**Ecto schema module:** `Letflow.Identity.OnboardingRecord` —
`lib/letflow/identity/onboarding_record.ex`.

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | `:binary_id` | `primary_key: true` | this **is** the `onboarding_id` the requirement text and R-Co both use — no separate column |
| `tenant_id` | `:binary_id` | `references(:tenants, type: :binary_id)`, `null: false` | this design's onboarding flow is fully synchronous (§8.2) — the row is only ever inserted once the tenant already exists, so (unlike R-Co's saga) there is no `NULL`-until-completion window and no `:pending` state to represent |
| `slug` | `:string` | `null: false` | denormalized copy of `tenant.slug`, avoids a join for the by-id/by-hostname read paths |
| `hostname` | `:string` | `null: false`, `unique_index` | the binding this table exists to record — REQ-076 is the named owner of hostname→tenant binding (`lib/letflow/routers/tenant_config.ex`'s own moduledoc: "Owner of hostname->tenant binding: REQ-076") |
| — | — | `timestamps(updated_at: false)` | `inserted_at` = completion time (this design has no separate "pending" timestamp — §8.2) |

Indexes: `unique_index(:onboarding_registry, [:hostname])` (one tenant per hostname —
matches R-Co's own hostname-uniqueness intent, though R-Co enforces it differently, via
saga-level `DuplicateHostname`; here it is a DB constraint, a Decision-A-consistent
simplification), `index(:onboarding_registry, [:tenant_id])`.

**Not ported, stated explicitly (§8.5 has the full list and reasoning):** `idempotency_key`,
`request_hash`, `state` (`pending`/`completed`/`failed`), `response_status`,
`response_body` columns. R-Co's saga/idempotency machinery has no acceptance criterion
requiring it here, and building it would itself be new tenant-provisioning-adjacent
machinery this requirement's own SCOPE BOUNDARY paragraph warns against inventing.

### 8.2 `Letflow.Identity` additions — onboarding

```
@spec create_onboarding(attrs :: %{slug: String.t(), display_name: String.t(), hostname: String.t()}) ::
        {:ok, OnboardingRecord.t()}
        | {:error, :duplicate_slug}
        | {:error, :duplicate_hostname}
        | {:error, Ecto.Changeset.t()}
```

**Not a single atomic transaction across all three steps** (deliberately, matching
REQ-075's own already-REVIEWER-confirmed §7.1/OQ-5 determination that
`provision_tenant_schema/1`/`replay_migrations/2` are idempotent, retryable primitives,
not something a compensating rollback should wrap):

1. `Identity.create_tenant(%{slug: attrs.slug, display_name: attrs.display_name})` (REQ-075's
   existing function, unchanged, `oidc_mode: :disabled` — same placeholder REQ-075 §7.1
   already establishes) → `{:error, :duplicate_slug}` propagates unchanged.
2. `TenantProvisioning.provision_tenant_schema(tenant.id)` then
   `TenantProvisioning.replay_migrations(tenant.id)` — **the identical two-call sequence**
   `Letflow.Routers.Tenants`'s `POST /tenants` handler already performs (REQ-075 §7.1) —
   called from the **router handler**, not from a new `Letflow.Identity` function, for
   the same reason REQ-075 kept this orchestration at the handler layer: `provision_tenant_schema/1`/
   `replay_migrations/2` belong to `Letflow.TenantProvisioning`, and `Letflow.Identity`
   does not call into that module today (REQ-022 §6's own "no coupling" cross-module note)
   — this design does not introduce that coupling either. `Identity.create_onboarding/1`
   (below) is called by the router **after** both `TenantProvisioning` calls succeed, as
   the final step that records the completed binding.
3. `Identity.create_onboarding(%{tenant_id: tenant.id, slug: tenant.slug, hostname: attrs.hostname})`
   → inserts the `OnboardingRecord` row. A `hostname` unique-constraint violation →
   `{:error, :duplicate_hostname}`.

```
@spec get_onboarding(id :: Ecto.UUID.t() | String.t()) :: {:ok, OnboardingRecord.t()} | {:error, :not_found}
@spec get_onboarding_by_hostname(hostname :: String.t()) :: {:ok, OnboardingRecord.t()} | {:error, :not_found}
```
Plain `Repo.get/2` / `Repo.get_by/2` lookups, `nil` → `{:error, :not_found}`.

### 8.3 Router: `Letflow.Routers.Onboarding`

```
post "/" (mounted path: POST /api/v1/onboarding)
get  "/:id" (mounted path: GET /api/v1/onboarding/:id)
get  "/" (mounted path: GET /api/v1/onboarding, ?hostname= query param)
```

All three: `Authorization.evaluate_access/2` against a **reused** `:TenantsManage`
permission (not a new one) — same risk class and same PLATFORM_ADMIN-only intent as
`Letflow.Routers.Tenants` (REQ-075 §1.1): creating a tenant, and reading records that
disclose which hostnames/slugs exist platform-wide, is exactly the kind of "wrong role,
right nobody" operation REQ-075's own matrix already gates this way. **No new
permission added for onboarding** — three new `endpoint_policy_key/2` clauses only:
```
def endpoint_policy_key("POST", "/onboarding"), do: :TenantsManage
def endpoint_policy_key("GET", "/onboarding/:id"), do: :TenantsManage
def endpoint_policy_key("GET", "/onboarding"), do: :TenantsManage
```
Same "no `Repo` call before authorization" discipline as every other router in this
codebase (REQ-073 §"Step 2", REQ-075 §6.1).

**`POST /onboarding` body:**
```
[
  %FieldConstraint{name: "slug", required: true, type: :string, reject_empty_string: true, min_length: 3, max_length: 63},
  %FieldConstraint{name: "display_name", required: true, type: :string, reject_empty_string: true, min_length: 1, max_length: 255},
  %FieldConstraint{name: "hostname", required: true, type: :string, reject_empty_string: true, min_length: 1, max_length: 255}
]
```
`Identity.create_onboarding_flow(...)` (the three-step §8.2 sequence, orchestrated by
this handler) →
- success → `Response.created(conn, onboarding_map(record))`.
- `{:error, :duplicate_slug}` → `Response.conflict(conn, "slug already exists")`.
- `{:error, :duplicate_hostname}` → `Response.conflict(conn, "hostname already bound")`.
- `{:error, %Ecto.Changeset{}}` → `Response.unprocessable(conn, "validation failed")`.

**`GET /onboarding/:id`** → `Identity.get_onboarding(id)` → `{:ok, record}` →
`Response.ok(conn, onboarding_map(record))`; `{:error, :not_found}` → `Response.not_found(conn)`
(plain 404 — this route is authenticated/PLATFORM_ADMIN, not the anti-enumeration one;
§8.4 covers why the hostname route differs).

**`GET /onboarding?hostname=...`** — see §8.4; response shape is part of the still-open
decision there.

`onboarding_map/1`:
```
%{"id" => r.id, "tenant_id" => r.tenant_id, "slug" => r.slug, "hostname" => r.hostname, "created_at" => iso8601(r.inserted_at)}
```

### 8.4 AC7 — the indistinguishability requirement (INV-5), RESOLVED: Reading B, justified (not deferred)

**REWORK (attempt 2): this is a final decision, not a REVIEWER-sign-off flag.**
Attempt 1 left this as OQ-3, offering Reading A (public/pre-auth) and Reading B
(PLATFORM_ADMIN-authenticated, matching R-Co's literal code) as equally defensible and
punted the choice downstream. CODE-DESIGN-VALIDATOR correctly rejected that — the
requirement text says "confirmed by inspection," not "left to REVIEWER," for its sibling
AC8, and AC7 deserves the same rigor. Re-investigating with one more source than attempt
1 read — the actual, already-written frontend caller (§0) — settles it decisively.

**Reading A is ruled out by the real caller, not by preference.** `web/src/api/onboarding.ts:142-149`'s
`getOnboardingByHostname` has exactly one call site:
`OnboardingResultPage.tsx`, reached only from the `admin/onboarding/:onboardingId/result`
route, which `AppShell.tsx:30` already places under the `PLATFORM_ADMIN`-gated `admin/*`
tree — called to restore this same admin's own just-completed `POST /api/v1/onboarding`
result after a page reload. There is no anonymous/pre-login caller of this endpoint
anywhere in the already-written frontend contract. Building a public variant (Reading A)
would mean designing and shipping a route with **zero real callers**, purely on a
speculative future-caller reading of one sentence in the requirement's description —
exactly the kind of unbuilt-with-no-producer shape `Letflow.Routers.TenantConfig`'s own
moduledoc (§0, read again this pass) already refused to do for its `tenant_hostnames`
table ("a table with no writer is a partial backing subsystem shipped with no producer
— the REQ-056 failure mode"). The same reasoning applies to a public route with no
caller: don't build it.

PROVENANCE (historical, not current decision authority):
**R-Co's own source confirms Reading B is not a misreading of a "pre-authentication"
requirement — R-Co's actual code is PLATFORM_ADMIN-gated.** `onboarding.zig:379-409`
(§0, re-read in full this pass): `handleGetOnboardingByHostname`'s **first** line is
`if (actor.role != .PLATFORM_ADMIN) return errorResult(allocator, 403, "forbidden");` —
literally the same gate as `handleOnboarding` (L54) and `handleGetOnboarding` (L290).
There is no `main.zig` hardcoded-actor bug here (unlike the REQ-075 §1.2 precedent this
design's attempt-1 draft analogized to) — this handler receives a real `actor:
auth.AuthContext` and checks it, same as its two siblings. The requirement description's
"reachable by hostname rather than by an authenticated tenant, so it is a
pre-authentication lookup" describes the **query mechanism** (a bare hostname string,
not a resource id scoped to the caller's own tenant schema the way `Letflow.Api.Context`
scopes everything else in this codebase) — not the **authentication** requirement, which
R-Co's own code, read directly, keeps admin-gated. §8.3's existing PLATFORM_ADMIN /
`:TenantsManage` gate on this route was already correct; attempt 1 second-guessed a
correct read of its own source.

**The concrete two-response comparison AC7 demands — resolved, both sides constructible:**
AC7's literal wording ("indistinguishable from one for a hostname whose tenant exists but
is not the caller's") presupposes a caller who *has* a tenant of their own that a
different tenant's hostname could be "not." **PLATFORM_ADMIN is not that kind of
caller** — it is the platform-wide operator role, scoped to no single tenant, and its
whole reason for holding `:TenantsManage` (REQ-075 §1.1) is to see every tenant's data.
INV-5's rule ("a cross-tenant probe... returns a response indistinguishable from probing
a resource that never existed") protects a caller who does *not* have standing to see
resource X from learning whether X exists. A PLATFORM_ADMIN calling this route always
has standing — there is no "not the caller's" tenant from a PLATFORM_ADMIN's vantage
point, which is exactly why attempt 1's OQ-3 found the comparison had "no natural
counterpart." **The comparison AC7 actually protects is upstream of the lookup, not
inside it**: the population INV-5 must protect here is every **non**-PLATFORM_ADMIN
caller (an authenticated tenant user, or an unauthenticated one) — the party for whom
every hostname genuinely is "not the caller's," since they hold no cross-tenant standing
at all. §8.3's existing route ordering — `Authorization.evaluate_access/2` runs **before**
any `Repo` call (§8.3's own "no `Repo` call before authorization" line, already
specified) — means that population's two responses are:

```
GET /onboarding?hostname=<never-bound-anywhere>       , caller lacks :TenantsManage
  -> Authorization.evaluate_access/2 denies -> 403, ZERO Repo calls made

GET /onboarding?hostname=<bound-to-a-real-other-tenant>, caller lacks :TenantsManage
  -> Authorization.evaluate_access/2 denies -> 403, ZERO Repo calls made
```

Byte-identical status, byte-identical body (`Response.forbidden/2`'s fixed problem
document, carrying no hostname-derived content — the same `detail` literal on every
call, never interpolating the hostname), and — the timing-signal half of INV-5's
"How to verify" text (§0) — a **literally equal** number of DB round trips: zero, for
either hostname, because the authorization check short-circuits before
`Identity.get_onboarding_by_hostname/1` (§8.2) is ever called. This is the same
"role-check gate runs first, so the two branches are indistinguishable because one of
them never reaches the query at all" mechanism `Letflow.Api.Authorization` already
provides on every other route in this router (§8.3), not a new mechanism invented for
this AC. **This is the AC7 test** (rewritten in §7.5 below), and it requires no change
to §8.2's `get_onboarding_by_hostname/1` or §8.3's response handling — both already
specified this way; attempt 1's uncertainty was about whether that was *sufficient*, and
this section is the argument that it is.

**What PLATFORM_ADMIN itself sees is deliberately NOT indistinguishable, and that is
correct, not a gap:** a PLATFORM_ADMIN calling `GET /onboarding?hostname=<bound>` gets
200 with `onboarding_map/1`'s full detail (§8.3); calling it with `<never-bound>` gets a
plain 404 (§8.2's `{:error, :not_found}` path, unchanged from attempt 1's §8.4 draft).
That pair is **not** required to be indistinguishable — PLATFORM_ADMIN has standing to
know, exactly as it already does for `GET /onboarding/:id` (§8.3's own existing 404
for a nonexistent id, never claimed to be INV-5-protected either) and for every other
PLATFORM_ADMIN-gated lookup in `Letflow.Routers.Tenants` (REQ-075). Nothing in INV-5's
text (§0) requires an *authorized* viewer's own two responses to be indistinguishable
from each other — only that an unauthorized prober cannot tell the two apart, which the
403-before-`Repo`-call mechanism above guarantees.

### 8.5 What is deliberately NOT ported (all three onboarding handlers), stated explicitly

- **Keycloak realm/client provisioning** (`onboarding_mod.executeSaga`'s
  `provider_manager_mod.Manager` calls) — Letflow has no Keycloak-client module (Decision
  0002's partial-adoption scope covers token verification only; `stage-4-api-surface.md`'s
  "Identity infrastructure and authorization" section already names REQ-128..135 as the
  future Keycloak dev-stack work). Not attempted here.
- **Initial admin-user creation** (R-Co's `admin_username`/`admin_email`/`admin_display_name`
  input fields) — no acceptance criterion here requires it, and it would need either a
  Keycloak-backed user or an internally-created one whose initial role-grant mechanism
  (which of the five roles? via which of REQ-020's `RoleRegistry` bindings?) is
  unspecified by any AC. Deferred, not silently dropped — these three input fields are
  simply **not accepted** by this design's `POST /onboarding` body schema at all.
- **Idempotency-key header + conflict-on-mismatch semantics** — no AC requires it; the
  `hostname`/`slug` unique-index constraints (§8.1) already give this design's simpler
  synchronous flow a comparable "can't silently double-create" property (a genuine retry
  of an already-completed onboarding gets `{:error, :duplicate_slug}` or
  `{:error, :duplicate_hostname}`, a clear signal, not a silent double-provision) without
  the saga/idempotency-record machinery.
- **Background-thread saga + polling `state: pending/completed/failed`** — this design's
  flow is fully synchronous (matches REQ-075's own synchronous `POST /tenants`
  orchestration, which this design's §8.2 step sequence is deliberately parallel to). A
  slow provisioning step blocks the HTTP response rather than returning 201 immediately
  and polling — an acceptable simplification given `provision_tenant_schema/1`/
  `replay_migrations/2` are already fast, local-schema operations in this codebase (no
  external Keycloak round trip in the critical path, unlike R-Co's saga).
- **Realm-existence guard on GET** (`handleGetOnboarding`'s Keycloak
  `checkRealmExists` probe) — no realm exists to probe (no Keycloak client), not ported.

---

## 9. Acceptance-criteria traceability

| # | Acceptance criterion | Concrete design element |
|---|---|---|
| 1 | plaintext returned once, subsequent GET has no token field | §3.1 step 8 (plaintext never persisted/re-derivable) + §6.2 `token_created_map/2` (only place a plaintext ever appears) vs `token_map/1` (structurally excludes it) + §7.1 test |
| 2 | persisted row never equals the plaintext in any column | §2 (`token_hash` only, SHA-256 digest) + §3.1 step 5/7 + §7.1 AC2 test (full-struct field sweep) |
| 3 | plaintext in no log line, no error body | §3.1 (plaintext is a bare local value, no struct field) + §6.1's error branches (fixed literal strings only, never the plaintext) + §7.1 AC3 test (`CaptureLog` across success+failure) |
| 4 | revoked token rejected 401 next request, no sleep/cache-flush | §3.4 (`verify_api_token/2`'s live-lookup mechanism, no cache layer, stated explicitly) + §3.5 (`Letflow.Plugs.AuthPipeline` API-token branch — the real HTTP path that calls it) + §7.2 test (both the primitive-level test and the required HTTP-level test) |
| 5 | token from tenant A cannot auth tenant B | §2 (tenant-scoped `api_tokens` table, per-schema isolation) + §3.4 step 2 (`prefix`-scoped lookup) + §7.3 test |
| 6 | upsert-role constraint matches R-Co, moduledoc + accept/reject test | §5.1 (direct-read confirmation: format-only, no enum check; already matches shipped `RoleRegistry`) + §6's required moduledoc content (§9a below) + §7.4 test |
| 7 | GET onboarding by unknown hostname indistinguishable from exists-but-not-caller's | §8.4 (RESOLVED: Reading B, justified by the real frontend caller + R-Co's own PLATFORM_ADMIN gate + INV-5's protected-population argument) + §7.5 test (403/403, zero-Repo-calls-either-way comparison) |
| 8 | onboarding creates a tenant via `Letflow.TenantProvisioning`, not a second path | §1.3 (scope boundary) + §8.2 (identical three-call sequence to REQ-075's own `POST /tenants`) + §7.6 test (`information_schema` proof) + required moduledoc statement (§9a) |
| 9 (SCOPE EXTENSION) | idempotent recovery entry point for a half-provisioned tenant, in REQ-076's own orchestration layer, invocable by tenant_id, not an automatic sweep | §11.2 (`Letflow.TenantOnboarding.recover_provisioning/1` / `provision_and_migrate/1` — new module, not `TenantProvisioning`) + §11.3 (reused `migrations_applied_at IS NULL` predicate, no new column) + §11.4 (full test: force failure, assert survival, recover, assert convergence, recover again, assert idempotence) |
| 10 (SCOPE EXTENSION) | the half-provisioned tenant's status decided explicitly and stated in the moduledoc, with a write test and a read test, not conflicting with `TenantStatus` | §12.1 (decision: reuse existing `:migrating` value verbatim, zero change to `Letflow.Plugs.TenantStatus`) + §12.2 (the read-gap argument: accepted, structurally credential-less, with OQ-6 as the explicit non-silent flag) + §12.3 (required moduledoc content) + §12.4 (write test: 503 unchanged; read test: 200, existing data served) |

### 9a. Required `@moduledoc` content on `Letflow.Routers.Identity` (extended) and `Letflow.Routers.Onboarding` (AC6, AC8 — mirrors REQ-073 §1a / REQ-075 §2.1's precedent)

`Letflow.Routers.Identity`'s moduledoc route table (already required by REQ-073 AC6) must
gain five new lines for the token/role routes, in the same `* METHOD PATH -> Function`
shape, **plus** a literal statement of §5.1's confirmed role-name constraint (AC6: "the
observed constraint named in the moduledoc").

`Letflow.Routers.Onboarding`'s moduledoc must state, as literal prose (not paraphrased):
(a) the three routes' function mapping; (b) AC8's exact sentence in substance — *"tenant
creation routes through `Letflow.TenantProvisioning.provision_tenant_schema/1` and
`replay_migrations/2`, the same two calls `Letflow.Routers.Tenants`'s `POST /tenants`
uses — there is one tenant-provisioning path on this platform, not two"*; (c) §8.4's
Reading-B decision, in substance — the PLATFORM_ADMIN gate on the hostname route is
deliberate (matches R-Co's own `handleGetOnboardingByHostname` source exactly, and the
frontend's only real caller is already an authenticated admin session), and the
indistinguishability guarantee it satisfies protects a non-`:TenantsManage` caller (403
before any `Repo` call, for any hostname), not the admin's own 200-vs-404 view — so a
future reader doesn't mistake the admin-visible detail for an INV-5 gap; (d) the §8.5
"not ported" list.

`Letflow.Plugs.AuthPipeline`'s moduledoc (extended, not newly created — REQ-021/071
already ship it) gains the numbered API-token branch and scope-boundary sentence §3.5
specifies.

---

## 10. Open questions (not silently resolved)

- **OQ-1 (§3.5) — NARROWED, not closed.** This requirement now wires
  `Letflow.Plugs.AuthPipeline` for API tokens (reversing attempt 1's deferral) using a
  single mechanism: a required `X-Tenant-Slug` request header, resolved via
  `Letflow.Identity.get_tenant_by_slug/1`. What remains genuinely open, for a future
  requirement, is only whether a header is the best **long-term** mechanism versus, e.g.,
  embedding a tenant hint in the token's own plaintext at issuance — not whether AC4 is
  satisfiable at all (it now is, end-to-end, per §3.5/§7.2).
- **OQ-2** (§5.2) — `Letflow.Identity.RoleRegistry` (REQ-020, already shipped) has no
  tenant-scoping (`tenant_role` lives in the global default schema) — a likely real
  cross-tenant data-isolation gap once more than one tenant defines named roles. Not
  fixed here (out of REQ-076's named source-file scope); recommend filing a follow-up
  issue.
- **OQ-3 — RESOLVED (§8.4), removed from the open-questions list.** Attempt 1 flagged
  Reading A vs. Reading B as unresolved; attempt 2 resolved it to Reading B
  (PLATFORM_ADMIN-authenticated, matching both R-Co's own source and the real frontend
  caller) with a concrete, testable indistinguishability mechanism. No REVIEWER
  sign-off gate remains on this route's auth model — REVIEWER still reviews the change
  as a normal SECURITY-REVIEWER-gated tenant-data-path change, per the standard
  pipeline, not as an unresolved design fork.
- **OQ-4** (§3.1 step 4) — the `"lf_tok_"` plaintext-token prefix string is this design's
  own choice (cosmetic, not security-relevant); confirm no existing convention elsewhere
  in the codebase already establishes a different project-wide token-prefix string before
  ELIXIR-DEV picks this literal.
- **OQ-5** (§6.1, `POST /roles`'s 200-not-201 status) — confirmed against R-Co's literal
  `.status_code = 200` for `handleUpsertRole`; flagged only because every other
  "create"-shaped handler in this codebase (users, groups, tenants, tokens) returns 201 —
  this one intentionally does not, matching R-Co's own upsert (not strictly create)
  semantics. Not a gap; recorded so a reviewer doesn't "fix" it to 201 by pattern-matching
  against sibling routes.
- **OQ-6 (§12.2, SCOPE EXTENSION) — the accepted empty-schema read gap's argument is
  conditional, not permanent.** §12.2 accepts the theoretical "GET reaches an empty tenant
  schema" case as structurally unreachable because both of today's authentication
  mechanisms (OIDC JIT-provisioning, API tokens) must themselves query a tenant-schema
  table (`users`/`api_tokens`) that does not exist until migration completes. A future
  requirement that adds any credential mechanism *not* requiring that query first (e.g. a
  self-contained signed credential validated without a per-tenant-schema DB read) would
  invalidate this argument and must re-examine §12.2's decision — not assumed to hold
  automatically. No global Postgrex-error-to-JSON rescue layer is added to close the gap
  defensively in the meantime (would be a cross-cutting change outside this requirement's
  scope).

---

## 11. SCOPE EXTENSION (AC9) — idempotent partial-provisioning recovery entry point

### 11.1 Why this is not a `Letflow.TenantProvisioning` function

AC9's own wording, and `req022-tenant-schema-provisioning.md` §3.2's "No implicit
chaining invariant," are explicit: `provision_tenant_schema/1` and `replay_migrations/2`
remain two separate, composable primitives with neither calling the other, and no third
function inside `Letflow.TenantProvisioning` may call both. `Letflow.TenantProvisioning`'s
own moduledoc ("No reconciliation path for a half-provisioned tenant" section, §0) already
states this obligation belongs to "whoever builds the onboarding orchestration" and names
REQ-076 as that owner. This design therefore adds the recovery entry point to a **new**
module, not to `TenantProvisioning` and not inline in the router.

### 11.2 New module: `Letflow.TenantOnboarding` — `lib/letflow/tenant_onboarding.ex`

A small context module, sibling to `Letflow.Identity`/`Letflow.TenantProvisioning` but
owned by REQ-076 — the "own orchestration layer" AC9 requires. It holds the
provision-then-migrate sequencing that both the normal onboarding-creation path (§8.2/§8.3,
already shipped) and the recovery path (this section) need, so that sequence exists in
exactly one place rather than being duplicated between `Letflow.Routers.Onboarding` and
this new recovery entry point — the same "one path, not two" discipline AC8 already
established for tenant creation, extended here to provisioning-recovery.

#### 11.2.1 `provision_and_migrate/1` — the shared, idempotent two-primitive sequence

```
@spec provision_and_migrate(tenant_id :: Ecto.UUID.t()) ::
        {:ok, Registration.t()}
        | {:error, :tenant_not_found}
        | {:error, {:provisioning_failed, term()}}
        | {:error, {:migration_failed, Exception.t()}}
```

**Behavior, in order (every step reuses an already-idempotent primitive — confirmed by
direct read, not assumed, per §0's new sources):**

1. `TenantProvisioning.provision_tenant_schema(tenant_id)` — confirmed idempotent by its
   own doc and code (`tenant_provisioning.ex` "Calling this twice for the same `tenant_id`
   is not an error"): a second call returns `{:ok, %Registration{}}` with the same row, no
   duplicate `tenant_schemas` row (the table's own `unique_index(:tenant_id)` makes this
   structural, not just documented). `{:error, :tenant_not_found}` propagates unchanged
   (the tenant row itself is gone — not a state this recovery function can repair).
   `{:error, other}` → `{:error, {:provisioning_failed, other}}`.
2. `TenantProvisioning.replay_migrations(tenant_id)` — **always called with the default
   `migration_source` (arity-1 call, `nil` default)** — never a caller-supplied one; this
   recovery entry point exists to converge the tenant onto the **real** shipped migration
   manifest, not a test fixture's. Confirmed idempotent by construction:
   `Ecto.Migrator.run/4` tracks applied versions in a per-schema `schema_migrations` table
   (`prefix: schema_name`), so a second call against an already-fully-migrated schema
   applies zero new migrations and returns `{:ok, []}` — no duplicate tables, no error.
   `{:error, :tenant_not_provisioned}` cannot occur here (step 1 always ran first and
   either returned `{:ok, _}` or already propagated its own error). `{:error,
   {:migration_failed, exception}}` propagates unchanged — this is the branch a still-broken
   migration (e.g. a genuine schema-conflict, not the transient failure being recovered
   from) surfaces through; the recovery entry point does not swallow a real, persistent
   migration failure into a false success.
3. On `{:ok, _applied_versions}` from step 2: flip the tenant's status to `:active` if it
   is not already (§12.4 — the same status-flip step the normal onboarding-creation path
   performs on its own success branch, §12.3). Implemented via
   `Letflow.Identity.Tenant.status_changeset/2` + `Repo.update/2`, scoped to `%{status:
   :active}` only. **Idempotent**: if the tenant is already `:active` (e.g. the second
   invocation of this same recovery call), the update is a no-op write of the same value —
   no new failure mode, no observable state change.
4. Re-fetch the `Registration` row (`Repo.get_by(Registration, tenant_id: tenant_id)`) and
   return `{:ok, registration}` — this is the up-to-date row, with `migrations_applied_at`
   reflecting step 2's own `mark_migrations_applied/1` write (`TenantProvisioning`'s
   existing private helper, unchanged, called internally by `replay_migrations/2` itself —
   this design does not touch it).

**No compensating rollback anywhere in this function** — matches
`Letflow.Routers.Onboarding`'s own existing `provision_and_bind/4` precedent (§8.2) and
REVIEWER's ISS-0230 finding that a rollback here would orphan a real Postgres schema.

#### 11.2.2 `recover_provisioning/1` — the AC9 entry point itself

```
@spec recover_provisioning(tenant_id :: Ecto.UUID.t()) ::
        {:ok, Registration.t()}
        | {:error, :tenant_not_found}
        | {:error, {:provisioning_failed, term()}}
        | {:error, {:migration_failed, Exception.t()}}
```

A thin, deliberately separately-named public wrapper around §11.2.1:
`recover_provisioning(tenant_id) = provision_and_migrate(tenant_id)`. Two functions with
identical behavior, not one, because they answer two different questions for two different
readers: `provision_and_migrate/1` is "the shared step sequence" (an implementation detail
the normal creation path also happens to call, §12.3); `recover_provisioning/1` is the
name **this AC anchors to** — the one a test or an operator reaches for by name when a
tenant is known/suspected to be half-provisioned. Its `@doc` states, verbatim in
substance: *"Idempotent. Safe to call on a tenant that is not actually half-provisioned
(fully-converged input state is one of the states this function's own idempotence
guarantee covers, not an error case) — the detection of *which* tenants need recovery is
the caller's job (e.g. `WHERE migrations_applied_at IS NULL`, §11.3), not this function's;
this function performs the repair unconditionally once called."*

This is **not** an automatic sweep — nothing in this module or elsewhere calls
`recover_provisioning/1` on a schedule, timer, or `GenServer`/supervision-tree child. It is
invoked exactly the way AC9 specifies: directly, by a test (§11.4) or, operationally, by a
human running it via a `Mix` task or `iex -S mix` console call against a specific
`tenant_id` obtained by querying `migrations_applied_at IS NULL` — that query pattern is
recorded here (§11.3) so a future sweep requirement does not have to re-derive it, exactly
as `TenantProvisioning`'s own moduledoc already says; **building that query into a
scheduled job is explicitly out of this requirement's scope** (RECOVERY SCOPE BOUNDARY,
`docs/requirements.yaml` REQ-076).

### 11.3 Detection predicate (already established, reused verbatim — no new column)

`migrations_applied_at IS NULL` on the `tenant_schemas` (`Registration`) row, exactly as
measured against real Postgres in run `WF03-ISS0230-20260822` and recorded in
`Letflow.TenantProvisioning`'s own moduledoc. No new column, no new table, no new index.
An operator/future-sweep query shape (documented, not built): `from(r in Registration,
where: is_nil(r.migrations_applied_at), select: r.tenant_id)`. This design adds no
function wrapping that query — §11.2.2's `@doc` states the predicate in prose so a future
reader finds it here too, but the predicate itself is read-only convenience information,
not a new public API surface this requirement is obligated to ship.

### 11.4 AC9 test — full description (traceability target for TEST-DESIGNER, not written here)

```
test "a tenant left half-provisioned by a replay failure is recovered by the idempotent
      recovery entry point, and the entry point is idempotent on a second call (ISS-0230)" do
  tenant = <insert an active, unprovisioned Tenant row directly, e.g. via Identity.create_tenant/1>

  # 1. Force replay_migrations/2 to fail -- same controlled-failure mechanism
  #    WF03-ISS0230-20260822 already used: a deliberately-broken migration_source
  #    (e.g. test/support/req022_migration_fixture.ex-style fixture pointing at a
  #    migration module that raises), passed as replay_migrations/2's *second*,
  #    caller-supplied argument -- never the default manifest.
  {:ok, _registration} = TenantProvisioning.provision_tenant_schema(tenant.id)
  assert {:error, {:migration_failed, _}} =
           TenantProvisioning.replay_migrations(tenant.id, broken_migration_source())

  # 2. Assert survival: no rollback, tenants row intact, exactly one tenant_schemas
  #    row, migrations_applied_at nil -- the exact state WF03-ISS0230-20260822 measured.
  assert %Tenant{} = Repo.get(Tenant, tenant.id)
  assert %Registration{migrations_applied_at: nil} =
           Repo.get_by(Registration, tenant_id: tenant.id)
  assert Repo.aggregate(from(r in Registration, where: r.tenant_id == ^tenant.id), :count) == 1

  # 3. Invoke the recovery entry point -- default (real) migration manifest.
  assert {:ok, %Registration{migrations_applied_at: %NaiveDateTime{}}} =
           TenantOnboarding.recover_provisioning(tenant.id)

  # 4. Assert full convergence: schema actually migrated (spot-check via
  #    information_schema.tables under the tenant's own schema_name, the same
  #    pattern this design's own §7.6 AC8 test and TenantFixture.assert_schema_complete!/2
  #    already use), migrations_applied_at set, still exactly one tenant_schemas row,
  #    tenant.status == :active (§12).
  {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)
  assert TenantFixture.assert_schema_complete!(tenant.id)  # or equivalent direct check
  assert Repo.aggregate(from(r in Registration, where: r.tenant_id == ^tenant.id), :count) == 1
  assert %Tenant{status: :active} = Repo.get(Tenant, tenant.id)

  # 5. Invoke the SAME entry point AGAIN, against the now-healthy tenant --
  #    mandatory, not optional (AC9's own wording).
  assert {:ok, %Registration{}} = TenantOnboarding.recover_provisioning(tenant.id)
  assert Repo.aggregate(from(r in Registration, where: r.tenant_id == ^tenant.id), :count) == 1
  assert %Tenant{status: :active} = Repo.get(Tenant, tenant.id)
  # no error, no duplicate schema, no duplicate tenant_schemas row -- idempotence
  # demonstrated by the second call succeeding with unchanged cardinality.
end
```

---

## 12. SCOPE EXTENSION (AC10) — the tenant-status decision for the onboarding window

### 12.1 Decision: reuse the existing `:migrating` status verbatim — no new status value, no `Letflow.Plugs.TenantStatus` change

`Letflow.Identity.Tenant.status` (`lib/letflow/identity/tenant.ex`) already has a
three-value `Ecto.Enum`: `[:active, :migrating, :inactive]`. `Letflow.Plugs.TenantStatus`
already enforces, for **every** tenant regardless of how it entered `:migrating` (its own
moduledoc makes no distinction by cause): write methods (`POST`/`PUT`/`PATCH`/`DELETE`)
against a `:migrating` tenant get `503` with a `Retry-After` header; `GET`/`HEAD` pass
through unchanged, with **no** `Repo` call on that check at all (`tenant_status.ex:92`,
confirmed by direct read). This design adds **zero** lines to `Letflow.Plugs.TenantStatus`
— reusing an already-shipped, already-REVIEWER-signed-off mechanism is exactly what AC10's
own wording ("must not be a second status rule conflicting with TenantStatus") requires.

**Where `:migrating` is set and cleared (both new, both in REQ-076's own orchestration
layer, never in `TenantProvisioning` or `TenantStatus`):**

- **Set**, at tenant-creation time, by `Letflow.Routers.Onboarding.handle_create/1`
  (§8.2/§8.3, extended — not rewritten): its call to `Identity.create_tenant/1` gains one
  additional attr, `"status" => "migrating"`, alongside the existing `"slug"`/
  `"display_name"`. (`Tenant.tenant_changeset/2` already casts `:status` — confirmed, §0 —
  no schema/changeset change needed.) **Scoped to onboarding only** — `Letflow.Routers.Tenants`'s
  own `POST /tenants` (REQ-075) is untouched; that route's tenants continue defaulting to
  `:active` immediately, which this design does not revisit (out of REQ-076's scope).
- **Cleared** (flipped to `:active`), by `Letflow.TenantOnboarding.provision_and_migrate/1`
  step 3 (§11.2.1) — the **same** function both the normal creation path and the recovery
  path call, so there is exactly one place in the codebase that ever flips a REQ-076-created
  tenant back to `:active`, not two independently-written flip sites that could drift.
  `Letflow.Routers.Onboarding.provision_and_bind/4` (§8.2/§8.3) is extended to call
  `TenantOnboarding.provision_and_migrate(tenant.id)` in place of its own current direct
  two-call sequence to `TenantProvisioning.provision_tenant_schema/1` +
  `TenantProvisioning.replay_migrations/2` — same external behavior (same error tags in
  its own `else` branch: `{:error, {:provisioning_failed, _}}` and `{:error,
  {:migration_failed, _}}` both still fall into its existing `_provisioning_or_replay_error
  -> Response.internal_error(conn)` catch-all, unchanged), plus the new status-flip
  side-effect on success.

### 12.2 The read gap: accepted, not closed — argued explicitly, not asserted

`TenantStatus`'s `GET`/`HEAD` pass-through, applied to a tenant whose Postgres schema is
still **literally empty** (provisioned but not yet migrated), is the scenario
`TenantProvisioning`'s own moduledoc (§0) flags as unclosed. This design's decision:
**accept this scenario as structurally unreachable by any legitimately-authenticated HTTP
request, for the entire window it could exist in, and therefore accept whatever
uncontrolled failure mode results if it were ever reached anyway** — argued as follows,
not merely asserted:

1. **`users` and `api_tokens` are both schema-per-tenant tables** (Decision 0006, §0) —
   they are created by `replay_migrations/2`, the very step that has not yet run during
   this window.
2. **Every authenticated request, before it ever reaches `Letflow.Plugs.TenantStatus` or
   any router handler, must pass through `Letflow.Plugs.AuthPipeline`, and both of
   `AuthPipeline`'s branches issue a live query against one of those two just-named
   tables**, inside the tenant's own schema: the OIDC branch's `provision_user/3`
   JIT-provisions (queries, and on first login inserts) a `users` row; the API-token
   branch's `verify_api_token/2` (§3.4) queries `api_tokens` by hash. Confirmed by direct
   read of `lib/letflow/plugs/auth_pipeline.ex` (§0), not assumed.
3. **Therefore no caller can ever hold, or newly obtain, a credential that
   `AuthPipeline` accepts as scoped to a tenant whose schema is still empty** — OIDC JIT
   provisioning would itself fail (the `users` table it tries to query/insert into does not
   exist yet) before `AuthPipeline` could ever populate `conn.assigns.auth_context`, and an
   API token can only exist for a `user_id` that already exists in that same,
   not-yet-created `users` table (`Identity.create_token/3` step 1, §3.1, requires an
   existing `User` row). The half-provisioned window is therefore not just "hard to
   reach" but **structurally credential-less** — there is no `tenant_id` for which both
   "the schema is still empty" and "a request carries a credential `AuthPipeline` accepts
   for that tenant" are true at the same time, for the entire lifetime of this design's
   two authentication mechanisms.
4. **If it were somehow reached anyway** (a bug elsewhere, not a path this design
   constructs) — `AuthPipeline`'s own table query against a nonexistent relation raises a
   `Postgrex.Error` (`undefined_table`) that neither `AuthPipeline`, `Letflow.Router`, nor
   any global rescue/`Plug.ErrorHandler` in this codebase currently catches (confirmed:
   no such handler exists, §0) — the request crashes the handling process and Bandit's own
   default crash-response path returns an uncontrolled `500`, not a clean JSON problem
   document and not a `404`. This design deliberately does **not** add a new global
   Postgrex-error-to-JSON rescue layer to close that theoretical gap — doing so would be a
   cross-cutting change to `Letflow.Router`/`AuthPipeline` well outside this requirement's
   onboarding-orchestration scope, the same "don't invent a new subsystem for a
   structurally-unreachable case" discipline RECOVERY SCOPE BOUNDARY already applies to
   the sweep-scheduler question (§11.2.2). Recorded as **OQ-6** (§10's list, appended, not
   renumbered) rather than silently assumed to hold forever: a future requirement that adds
   any new way to mint a tenant-scoped credential *without* querying a tenant-schema table
   first (e.g. a signed, self-contained credential an intermediary issues) must re-examine
   this argument, since step 3 above is exactly what makes the gap unreachable today.

**What a read genuinely, routinely receives during `:migrating`, and why that part is not
a gap at all:** the case `:migrating` is actually reached by a real, legitimate,
already-authenticated caller — a tenant that finished onboarding successfully in the past
(schema fully migrated, `users`/`api_tokens` populated, real tokens exist) and is later put
back into `:migrating` for an administrative reason (§12.4 does not build such a path, but
`Tenant.status_changeset/2` already allows any caller with direct DB/console access to set
it) — `GET`/`HEAD` simply serve the tenant's existing, valid data unchanged, exactly
`TenantStatus`'s own documented "write-pause, not read-pause" design (§0). This is the
**intended** behavior, not an accepted gap: reads continuing against known-good data while
writes are paused during a migration window is the correct general-purpose semantics for a
status value that predates this requirement (REQ-021).

### 12.3 `@moduledoc` content this design requires (AC10's own "stated in the moduledoc" text)

`Letflow.TenantOnboarding`'s `@moduledoc` (new module, §11.2) must state, as literal prose:
(a) the status is `:migrating`, set at creation and cleared to `:active` by
`provision_and_migrate/1` on successful replay, reusing `Letflow.Identity.Tenant.status`'s
existing enum value and `Letflow.Plugs.TenantStatus`'s existing, unmodified write-gate —
no new status value, no plug change; (b) §12.2's full argument in substance — the
empty-schema read window is accepted as structurally credential-less given today's two
authentication mechanisms (OIDC JIT-provisioning, API tokens), both of which query a
tenant-schema table that does not exist until migration completes, and if that argument is
ever invalidated by a future credential mechanism, this decision must be revisited (OQ-6);
(c) the already-populated-schema `:migrating` case (an administratively re-migrated tenant)
serves reads normally and pauses only writes, which is intended, not a gap.
`Letflow.Routers.Onboarding`'s own `@moduledoc` (already shipped, AC1–8) gains one line
under its existing "One tenant-provisioning path, not two" heading, pointing at
`Letflow.TenantOnboarding.provision_and_migrate/1` as of this extension's status-flip
addition, without rewriting that heading's existing AC8 content.

### 12.4 AC10 tests — full description (traceability target for TEST-DESIGNER, not written here)

Both tests reuse `TenantFixture.provisioned_tenant!/1` (an already-fully-migrated tenant,
`users`/`api_tokens` tables present) rather than the truly-empty-schema state, per §12.2's
own argument that the empty-schema state cannot be reached by an authenticated HTTP
request at all — these tests instead demonstrate the state that genuinely **is**
HTTP-reachable while `:migrating`: a fully-provisioned tenant an operator has put back into
`:migrating` (the same status value, same plug, same mechanism §12.1 commits to reusing).

```
test "AC10 write: a POST against a :migrating tenant with a real, valid token is
      rejected 503 by the existing TenantStatus write-pause -- unchanged, reused (ISS-0230)" do
  tenant = TenantFixture.provisioned_tenant!()
  user = insert_user!(tenant, ...)
  {:ok, %{plaintext: plaintext}} =
    Identity.create_token(user.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil}, prefix: tenant.schema_name)

  {:ok, _migrating} =
    Repo.update(Tenant.status_changeset(tenant, %{status: :migrating}))

  conn =
    conn(:post, "/api/v1/identity/tokens")
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("x-tenant-slug", tenant.slug)
    |> put_req_header("content-type", "application/json")
    |> put_body_params(%{"user_id" => user.id, "roles" => ["TASK_WORKER"]})
    |> Letflow.Router.call(Letflow.Router.init([]))

  assert conn.status == 503
  assert Jason.decode!(conn.resp_body)["error"] == "tenant_migrating"
end

test "AC10 read: a GET against the same :migrating tenant with the same token passes
      through unchanged and serves existing data, per this design's accepted decision" do
  # same setup as above, tenant already flipped to :migrating
  conn =
    conn(:get, "/api/v1/identity/tokens")
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("x-tenant-slug", tenant.slug)
    |> Letflow.Router.call(Letflow.Router.init([]))

  assert conn.status == 200
  assert %{"items" => _} = Jason.decode!(conn.resp_body)
end
```

Both requests exercise the real `Letflow.Plugs.AuthPipeline` → `Letflow.Plugs.TenantStatus`
→ `Letflow.Routers.Identity` chain end-to-end (matching this design's own §7.2 HTTP-level
test convention), demonstrating both request directions AC10 names against a tenant
genuinely carrying the `:migrating` status — without needing (and, per §12.2, without being
able to construct) a credential against a schema still literally empty.
