# REQ-434 — Design: email-first login, a platform tenant-login directory and a credential-free discovery route

Stage S4 (backend) / S8 (SPA). Owner: `CODE-DESIGNER` -> `ELIXIR-DEV` (REQ-435, REQ-436,
REQ-437, and the new trusted-proxy requirement REQ-CIP, §15.0) and `FRONTEND-DEV` (REQ-438). Status: design only. No implementation code appears
in this document: signatures, `@spec`/`@type`/`@callback` shapes, table shapes and prose
only.

Governing decision record: `docs/migration/decisions/0042-email-first-login-tenant-directory.md`
("0042"). 0042 holds the amendments to 0006 §3.3/§7 item 3, 0038 and 0035, the standing
prohibitions, the accepted bounded inference and the `PENDING` gates. Where REQ-435..438's own
text and this design differ, this design governs and each difference is listed in §0.3 so
`REQ-VALIDATOR` can reconcile it; none is resolved silently.

The requirement's description items (a)-(l) are specified in §§1-8, 9, 11 and 14; the
item-to-section map is in §16.

---

## 0. Premises, verification ledger and discrepancies

### 0.1 Existing code this design relies on (each read, not assumed)

| Claim | Citation | Result |
|---|---|---|
| `resolve_tenant_by_realm/1` resolves a tenant from a realm (post-login, unchanged) | `lib/letflow/identity.ex:148-155` | verified |
| `provision_oidc_user/4` takes `tenant_id` already and calls `upsert_by_external_identity/4` | `identity.ex:127-138` | verified |
| JIT insert path is **not** transactional: `Repo.insert(on_conflict: :nothing)` then `Repo.get`, then `sync_role_claims_from_token` | `identity.ex:1766-1809` | verified; drives §3.5 |
| `create_user/2` is a `Multi` (`:user`, then `Audit.append_multi`) wrapped in `try/rescue` returning `{:transaction_failed, exception}` | `identity.ex:227-276` | verified |
| `update_user_profile/3`, `update_user_status/3` read the user **outside** the transaction, then run a `Multi` (`:user`, audit) inside `try/rescue` | `identity.ex:337-377`, `:389-429` | verified; drives §3.4 |
| The three functions take only `opts :: [prefix: String.t()]`; no tenant id | `identity.ex:93` (`@type opts`), `:229`, `:338`, `:390` | verified |
| Identity has no `delete_user` function | `def` listing of `identity.ex` (no match) | verified |
| `users.email` is `NOT NULL`, no unique index on email | `priv/repo/migrations/20260819000003_create_users_tenant_scoped.exs:67`; `User` schema `lib/letflow/identity/user.ex:39` | verified (nil-email branch is defensive only) |
| `users.status` is `:active \| :inactive`; `profile_changeset/2` also casts `:status` | `user.ex:41`, `:125-129` | verified; PATCH `/users/:id` can change status |
| POST `/users` and POST `/users/:id/status` are `authz_post ... :UsersManage`; handlers receive `conn.assigns.scoped_opts` | `lib/letflow/routers/identity.ex:158-160`, `:174-176` | verified |
| Request email limits: `max_length: 255` | `routers/identity.ex:250-257` | verified; sets the discoverable length bound |
| `scoped_opts` is assigned by the authorize plug; `scoped_repo_opts/1` derives `:prefix` solely from `auth_context.tenant_id` | `lib/letflow/plugs/authorize.ex:122`; `lib/letflow/api/context.ex:219-237` | verified |
| `schema_name_for_tenant/1` and `tenant_id_for_schema_name/1` are both pure (no I/O) | `lib/letflow/tenant_provisioning.ex:214-219`, `:242-259` | verified |
| `list_registrations/0` returns `Registration` rows with `tenant_id`, `schema_name` | `tenant_provisioning.ex:274-276`; `lib/letflow/tenant_provisioning/registration.ex:26-27` | verified |
| `tenant_scoped_migrations/0` is the registry of per-tenant replayed migrations | `tenant_provisioning.ex:733-738` | verified |
| `Tenant` has `slug`, `display_name`, `status :active\|:migrating\|:inactive`, `idp_realm_id`; **no format constraint on `slug`** beyond length 1-255 (router) | `lib/letflow/identity/tenant.ex:67-79`, `:104-108`; `routers/tenants.ex:214-221` | verified; slug is opaque text |
| `TenantMembership.normalize_subject_key/1` is `String.trim` then `String.downcase`; the email-shape regex is a **private** module attribute | `lib/letflow/identity/tenant_membership.ex:82-85`, `:94-102` | verified; drives §1.5 |
| `tenant_memberships` is plaintext `subject_key`, FK `on_delete: :nothing`, unique `(subject_key, tenant_id)` | `priv/repo/migrations/20260922000011_create_tenant_memberships.exs:25-35` | verified |
| `/api/tenant-config?realm=<slug>` resolves by **slug**, requires a non-nil `idp_realm_id`, else falls to the default realm; authority is server-built | `lib/letflow/routers/tenant_config.ex:230-249`, `:268-274`, `:327-331` | verified; drives the match eligibility rule |
| `Letflow.Router` plugs: `Cors`, `HttpMetrics`, `:match`, `:dispatch`; no `Plug.Parsers` | `lib/letflow/router.ex:95-98` | verified |
| Mounts: `/api/tenant-config` `:111`, `/api/mobile/tenant-config` `:118`, `/metrics` `:124`, `/api/public` `:133`, `/api/v1` `:135`, catch-all `:137-139` | `router.ex` | verified (REQ-352's design cites `:114`/`:116`; stale) |
| `PublicReadRateLimit.call/2`: global then per-IP buckets, `Response.rate_limited("rate limit exceeded")`, halt | `lib/letflow/plugs/public_read_rate_limit.ex:36-52` | verified |
| `Bucket`: one ETS table `:letflow_public_read_rate_limit`, key type `:global \| {:ip, ip}`, check-then-write over `:ets.lookup`/`:ets.insert`, **no eviction** | `lib/letflow/plugs/public_read_rate_limit/bucket.ex:31-33`, `:58-78` | verified |
| Rate limiter is the first plug **inside the sub-router's own chain** (after the top router's `Cors`/`HttpMetrics`) | `lib/letflow/routers/public_read.ex:55-57` | verified; "first plug in the chain" is read this way |
| Deferred `Letflow.Plugs.RateLimit` row | `lib/letflow/plugs/api_pipeline.ex:59`; `Admission` at `:88` and `:135` | verified |
| `Response.rate_limited/2`, `not_found/1`, `send_json/3`; `send_problem` embeds `conn.assigns[:trace_id] \|\| ""` (no trace plug on public mounts, so constant) | `lib/letflow/api/response.ex:60-79`, `:96-123`, `:185-186`, `:201-203` | verified |
| Infrastructure supervisor: `Bucket` child at `:229`; `Obs.Alerts.TaskSupervisor` is the **last** child; the test asserts exactly 20 children | `lib/letflow/supervisor/infrastructure.ex:229`, `:329`; `test/letflow/supervisor/infrastructure_test.exs:70`, `:117` | verified |
| Master-key startup pattern (missing/malformed/all-zero/all-F raise) and the test-env injection | `config/runtime.exs:30-72`; `config/test.exs:18-22`; `.env.example:11` | verified; model for the pepper |
| No mail library in `mix.exs` | `grep -in "swoosh\|bamboo\|smtp\|mailer" mix.exs` (no match) | verified |
| No OpenAPI artefact exists to update | `grep -rl "openapi" lib test` (no match); decision 0010 defers to S6 | verified; REQ-437 item 5 is a recorded no-op |
| SPA: `resolveRealmFromUrl()` reads the stored slug **before** `?realm=` | `web/src/auth/tenantConfig.ts:40-51` | verified |
| SPA: `buildRedirectArgs` returns `{redirect_uri, state?}` or `undefined`; embeds `?realm=` in `redirect_uri` | `web/src/auth/oidcRedirectArgs.ts:21-35` | verified |
| SPA: `ProtectedRoute` on `!isAuthenticated` calls `getOidcManager().then(m => m.signinRedirect(buildRedirectArgs(path)))` | `web/src/auth/ProtectedRoute.tsx:13-23` | verified |
| SPA: `getOidcManager()` is a module singleton (`_resolvedManager`), built once from `fetchTenantConfig(hostname)` | `web/src/auth/OidcManager.ts:46-54`; `tenantConfig.ts:27`, `:53-67` | verified; drives §8.4 |
| SPA: `AuthProvider` calls `getOidcManager()` eagerly on mount when `VITE_OIDC_AUTHORITY` is set | `web/src/auth/AuthProvider.tsx:99-122` | verified; drives §8.4 |
| SPA: per-slug managers and a per-slug config cache already exist for the switcher | `web/src/auth/tenantOidcRegistry.ts:20-29`; `tenantConfig.ts:89-` | verified |
| SPA: session-expired handler does **not** clear the stored realm; only `logout()` does | `AuthProvider.tsx:85-95` vs `:131-141` | verified; REQ-438 item 5 wording differs, see §0.3 |
| SPA: the OIDC callback uses `getOidcManager()` and `resolveRealmFromUrl() ?? sessionStorage` | `web/src/pages/OidcCallbackPage.tsx:68-80` | verified |
| `oidc-client-ts` v3 accepts `login_hint` in the sign-in args | `web/package.json:35`; `node_modules/oidc-client-ts/dist/types/oidc-client-ts.d.ts:243` | verified |
| `/auth/callback` is a top-level public route; `/` is wrapped in `ProtectedRoute` | `web/src/router.tsx:44-53` | verified |
| No app-wide `IntlProvider`; new pages wrap their own, catalogs en/ru/kk | `web/src/i18n/EntitiesIntlProvider.tsx`, `entitiesMessages.ts:34-35` | verified |
| Mobile bootstrap (MOB-2), REQ-124's `/api/mobile/tenant-config` | `docs/mobile/requirements.md:50-`; `router.ex:118` | verified |
| QA runs Keycloak 26.2 with realms `bpm-default`, `bilimbaga` | `docker-compose.yml:26`; `ai-dala-infra/landscape/services.md:177`; `.../hosts/ubuntu-16gb-nbg1-1.md:217` | verified |
| (rework 2, D-2) Real deployment topology: Cloudflare edge -> host nginx -> published container port -> Bandit | `deploy/nginx/letflow-test.conf:6-8` (Cloudflare terminates, "always_use_https at Cloudflare edge"), `:20-25` (`proxy_pass http://127.0.0.1:3113`), `deploy/docker-compose.test.yml:8-9` (`127.0.0.1:3113:4000`), `lib/letflow/supervisor/http.ex:37` (Bandit serves `Letflow.Router` directly, no Plug in front) | verified |
| (D-2) nginx sets `X-Real-IP $remote_addr` and `X-Forwarded-For $proxy_add_x_forwarded_for`, with **no** `set_real_ip_from`/`real_ip_header`, so `$remote_addr` is the **Cloudflare edge address**, not the visitor | `deploy/nginx/letflow-test.conf:23-24` (no realip directive anywhere in the file) | verified from the file; that Cloudflare supplies `CF-Connecting-IP` is external knowledge (U3) |
| (D-2) The tree has **no** client-IP resolution: `conn.remote_ip` is the only IP read, by `PublicReadRateLimit` alone; no `RemoteIp` dependency, no `x-forwarded-for`/`x-real-ip` handling in `lib/` or `config/` | `grep -rn "remote_ip\|x-forwarded\|x-real-ip\|RemoteIp\|cidr" lib config mix.exs` -> only `lib/letflow/plugs/public_read_rate_limit.ex:4,44` (plus design prose) | verified. Behind the real topology `conn.remote_ip` is therefore the proxy hop (the docker bridge peer of the published port), shared by every visitor; the exact container-side address was not observable from the repo (U4) |
| (rework 2, D-1) The existing `PublicReadRateLimit.call/2` consumes `global` **then** per-IP (`with :ok <- global, :ok <- ip`) and `Bucket` has one table, check-then-write, no eviction | `lib/letflow/plugs/public_read_rate_limit.ex:36-52`; `public_read_rate_limit/bucket.ex:31-33`, `:58-78` | verified; the same ordering defect exists on `/api/public` (carried as 0042 OQ-12, not fixed here) |
| (rework 2, D-3) Ecto logs queries with bound parameters at `:debug` by default; the repo sets no `log:` default for `Letflow.Repo`; the logger level is `:debug` in test and `LOG_LEVEL`-controlled (`debug` accepted) elsewhere; a per-call `log: false` is already used in this tree | `config/runtime.exs:75-101`; `lib/letflow/sandbox_pool.ex:964`, `lib/letflow/tenant_provisioning.ex:386` (`log: false`) | verified: no `log:` config for the Repo found in `config/`; Ecto's default param logging is Ecto behaviour (not read from the repo's deps in this pass) |

### 0.2 Claims that could not be verified from the repository

- **U1.** "Keycloak Organizations is a Keycloak feature from 26.0." External knowledge; not
  derivable from the repo. Recorded as such in 0042, "Alternatives rejected" item 3.
- **U2.** Keycloak's default for `loginWithEmailAllowed`. `priv/keycloak/realms/bpm-default.json`
  contains zero occurrences of the key, so the effective setting is the Keycloak default, which
  was not verified. Treated as a UAT precondition (§8.3), not an assumption.
- **U3.** That Cloudflare forwards the visitor address in the `CF-Connecting-IP` header and
  publishes the edge address ranges nginx must trust. External knowledge; the nginx file shows a
  Cloudflare edge exists but not what it sends. REQ-CIP (§15.0) must verify against the live
  edge or Cloudflare's published documentation and records the result in its handoff.
- **U4.** The container-side peer address Bandit sees for traffic arriving through the published
  port (`127.0.0.1:3113:4000`). Depends on the Docker network driver and host configuration and
  cannot be read from the repository; REQ-CIP's UAT step must observe it on the real host and set
  `LETFLOW_TRUSTED_PROXIES` accordingly. QA's own nginx vhost (`3201`) is not in this repository
  and is likewise unverified.

### 0.3 Differences from REQ-434..438's own text (design governs; flagged, not silently resolved)

| # | Requirement text | Finding | Design position |
|---|---|---|---|
| D1 | REQ-434 (c)/REQ-435 item 4: a reverse prefix->tenant lookup is rejected as "an extra query" | `tenant_id_for_schema_name/1` is pure and performs no query (`tenant_provisioning.ex:242-259`) | Keep the requirement's chosen option (explicit `:tenant_id` opt) but with the corrected rationale and a fail-closed consistency guard (§3.2). |
| D2 | REQ-435 item 3: JIT hook "in the SAME Ecto.Multi/transaction as the source write" | The JIT insert is currently not in any transaction (`identity.ex:1766-1809`) | A new `Repo.transaction` wrapper around the JIT insert, its created-check and the directory upsert (§3.5). |
| D3 | REQ-435 item 7: backfill "iterates all active tenants" | Entries for an `:inactive` tenant would be missing, so reactivation would leave its users undiscoverable | Backfill iterates **all registered tenants** (`list_registrations/0`); status is filtered at query time (§4). |
| D4 | REQ-438 item 5: session-expired and logout paths "still clear the stored realm" | Only `logout()` clears it; session-expired retains it and re-logs into the same realm (`AuthProvider.tsx:85-95`, `:131-141`) | Logout unchanged (clears, lands on the email-first page when the flag is on). Session-expired unchanged when a realm is stored; when none is stored and the flag is on, it goes to `/login` (§11.4). |
| D5 | REQ-436 AC "after unrelated keys are evicted" implies eviction of live keys | Evicting a non-idle key would let an attacker refill a victim bucket | Only **lossless** eviction (idle, fully refilled keys) plus fail-closed refusal of *new* keys at the cap (§12.3). The AC is satisfied through a clock-injection seam. |
| D6 | REQ-436 builds three bucket kinds | The per-address minimum send interval (RQ-6) needs a fourth, `:email_send` | Added to REQ-436's work package (§12); `REQ-VALIDATOR` must accept the amendment or move it to REQ-437. |
| D7 | REQ-437 item 5 (OpenAPI coverage) | No OpenAPI artefact exists (decision 0010) | No-op, recorded in REQ-437's handoff (§15.3). |
| D8 | REQ-434 (e) response "realm slug" | `slug` here means `tenants.slug`, the value `?realm=` and `/api/tenant-config` accept, not `idp_realm_id` | Stated explicitly in §5. |
| D10 | REQ-434 description item 4: new mount reuses `PublicReadRateLimit.Bucket` "or a mount-point-agnostic successor" | The design builds a sibling module with its own table (§12.1); it neither reuses `Bucket` nor refactors it into a shared agnostic module | Treated as the successor option, justified: **shared** = token-bucket algorithm (restated, cross-referenced), `conn.remote_ip` keying, `Response.rate_limited` and halt convention, 0028 §6 placement; **new** = own ETS table, `:login_discovery`-prefixed keys, lossless eviction, key cap, atomic check-and-write. Not a refactor of `Bucket`, which would alter `/api/public` (§12.1). `REQ-VALIDATOR` must accept this reading of item 4. |
| D9 | REQ-438 CURRENT BEHAVIOUR | Also true: a pre-existing eager `getOidcManager()` can bind the singleton to the default realm before an email is typed | Hand-off uses the per-slug registry, not the singleton (§8.4). |
| D11 | REQ-436 / REQ-437 `depends_on` (`docs/requirements.yaml`: REQ-436 `[REQ-434]`, REQ-437 `[REQ-435, REQ-436]`) and REQ-434 OQ-5 ("trusted-proxy handling not part of this record") | In the real topology `conn.remote_ip` is a proxy hop (§0.1), so the per-IP bucket the Mode B inference rests on is one shared bucket for all users (`SECURITY-REVIEWER` D-2). | New requirement **REQ-CIP** (working name; id assigned by `REQ-ANALYST`; §15.0) becomes a `depends_on` of **REQ-436 and REQ-437** and a precondition for enabling the flag. `docs/requirements.yaml` is outside this change's file scope: `ORCH`/`REQ-ANALYST` must register REQ-CIP and amend both `depends_on` lists; `REQ-VALIDATOR` must accept. REQ-436/437 `Standing prohibition 8` wording ("keyed on `conn.remote_ip`") is amended to the resolved client IP (0042). |
| D12 | REQ-437 (always-mounted route) | A boot-time precondition needs a server-side switch | New config `enabled` on the mount (default `false` in `:prod`, `true` in dev/test); disabled -> the route-level `404` (already in the closed status set). §12.6. |
| D13 | REQ-436 limiter keys on "the client IP"; AC "global bucket trips independently" | Global-before-IP order drained the global bucket with refused requests (`SECURITY-REVIEWER` D-1) | Per-IP first, global only for IP-admitted requests; IPv6 aggregated to /64; two key caps (§12.2-12.4). The AC "global bucket trips independently of IP" is kept, reinterpreted as "independently of any *single* IP" (a test uses many IPs). |
| D14 | REQ-437 telemetry/AC silent on outcome counters; REQ-438 429 state "retry affordance" | `SECURITY-REVIEWER` C-1 and C-2 | Outcome counters (§12.7) are added to REQ-436/437; the SPA 429 state additionally offers the `?realm=` route (§11.5, REQ-438). `REQ-VALIDATOR` must accept both additions. |

---

## 1. (a) Directory schema

### 1.1 Table `tenant_login_directory` (public schema only)

| Column | Type | Constraints |
|---|---|---|
| `email_key` | `bytea` | `NOT NULL`; `CHECK (octet_length(email_key) = 32)` |
| `tenant_id` | `uuid` (`binary_id`) | `NOT NULL`; real FK `REFERENCES tenants(id) ON DELETE CASCADE` |
| `inserted_at` | `timestamp` (naive UTC) | `NOT NULL` |

- **Primary key:** composite `(email_key, tenant_id)`. This is the "unique (email key, tenant_id)"
  the requirement asks for, and its leading column serves the lookup, so no separate unique
  index is created.
- **Secondary index:** `(tenant_id)`, solely so the FK cascade on tenant deletion does not scan
  the whole table.
- **No surrogate `id`, no `updated_at`:** rows are insert-or-delete only (as
  `TenantMembership` is, `tenant_membership.ex:10-14`); nothing references a row; the pair is
  the identity. This is a deliberate, stated deviation from the `id` + `timestamps()`
  convention of `tenant_memberships`.
- **Pointer table.** No password, role, session, user id, `external_id`, user display name or
  profile field. The only tenant data reachable through it is `slug` and `display_name`, via a
  join at query time (§5.4).
- **Placement and INV-1.** Created by an ordinary migration with **no** `prefix()` guard and
  **not** added to `tenant_scoped_migrations/0` (`tenant_provisioning.ex:733`), so it exists in
  `public` only. Same tier as `tenants`, `tenant_memberships`, `public_read_handles` (0006 D3).
  No function on this table takes `opts[:prefix]` except the writers' *read of the tenant's own
  `users` table* (§3.6).
- Migration is reversible (`change/0`-style, as the backend guide §3.7 requires).

### 1.2 Schema module

`Letflow.Identity.TenantLoginDirectoryEntry` (`lib/letflow/identity/tenant_login_directory_entry.ex`).
Moduledoc in the style of `tenant_membership.ex`, including an explicit "what this table is
not" paragraph (not an identity record; not read by `AuthPipeline`; not `tenant_memberships`).

```
@type t :: %Letflow.Identity.TenantLoginDirectoryEntry{
        email_key: <<_::256>>,
        tenant_id: Ecto.UUID.t(),
        inserted_at: NaiveDateTime.t()
      }
```

Schema shape: `@primary_key false`; `field :email_key, :binary, primary_key: true`;
`belongs_to :tenant ..., primary_key: true`. One changeset, `create_changeset/2` (casts
`[:email_key, :tenant_id]`, requires both, `unique_constraint` on the pair). **No update
changeset** (insert/delete only).

### 1.3 Distinction from `tenant_memberships`, and the one-table-or-two decision

| Aspect | `tenant_memberships` (REQ-384) | `tenant_login_directory` |
|---|---|---|
| Meaning | Admin-granted switch target linking two existing accounts | Login-routing index of where an email has an active account |
| Who writes | Explicit `PLATFORM_ADMIN` action only (0038 point 2) | Automatically, from the Identity context's user lifecycle transactions |
| Lifecycle | Persists until an admin revokes it | Exists only while an active user with that email exists |
| Key | Plaintext normalised email (`subject_key`) | Keyed HMAC of the normalised email |
| Read by | `GET /me/memberships`, authenticated, caller's own email only | `POST /api/login-discovery`, unauthenticated, caller-supplied email |
| FK on tenant delete | `:nothing` | `ON DELETE CASCADE` |

**Decision: two tables, one shared normalisation function**
(`TenantMembership.normalize_subject_key/1`, `tenant_membership.ex:82-85` -- "one
implementation on both sides", its own moduledoc `:24-30`). Unifying would make 0038's
conditions 1 and 2 false for the merged table and would put an auto-populated index under an
admin-only write authority.

### 1.4 Distinction from `public_read_handles`

Unrelated (0028): that table maps an unguessable capability handle to a resource; this maps a
caller-typed email to tenants. The directory is never a `Letflow.PublicRead` kind.

### 1.5 Shared shape predicate

REQ-435 changes `tenant_membership.ex` minimally: extract the existing private regex check into
a public `@spec email_shape?(term()) :: boolean()` and make the existing `validate_email_shape/2`
call it. Behaviour of `create_changeset/2` is unchanged and its existing tests pass unmodified.
`Letflow.LoginDirectory` uses the same predicate, so the writer and the lookup agree on what a
valid address is, with one implementation.

---

## 2. (b) Email key form

### 2.1 Function

`email_key = HMAC-SHA256(pepper, "letflow:login-directory:v1:" <> normalised_email)`, 32 raw
bytes. `normalised_email` is `TenantMembership.normalize_subject_key/1`'s output (trim then
Unicode `String.downcase`). The domain-separation prefix means the same pepper can never
produce a value usable in another context.

Validity (`Letflow.LoginDirectory.email_key/1` returns `:invalid` when any fails): the input is
a binary; its trimmed byte size is 1..255 (255 equals the POST `/users` `max_length`,
`routers/identity.ex:250-257`, so every creatable address is discoverable); `email_shape?/1` is
true. Anything else maps to the **sentinel key** (§5.3).

### 2.2 Pepper by reference (INV-4, decision 0016)

- Source: environment variable `LETFLOW_LOGIN_DIRECTORY_PEPPER`, 64 lowercase hex characters
  decoding to 32 bytes. Read **once at boot** in `config/runtime.exs` into
  `config :letflow, :login_directory_pepper, <32 bytes>`, with the same checks as the master key
  (`config/runtime.exs:30-72`): absent -> raise; not 64 hex -> raise; all-zero or all-`0xFF`
  -> raise; **equal to the secrets master key -> raise** (a distinct secret).
- Required in every environment including CI: `config/test.exs` injects a fixed non-trivial
  value when the variable is unset, exactly as it does for the master key
  (`config/test.exs:18-22`). `.env.example` documents the name and format and carries no
  working value (as `.env.example:11` does for the master key). This satisfies REQ-435 item 6
  ("fails closed when absent in non-test environments").
- Resolved at the point of use via `Application.fetch_env/2`; never logged, never in a struct
  field or return value. If it is somehow absent at call time, `email_key/1` and
  `sentinel_key/0` return `{:error, :pepper_unavailable}` to their caller (not a raise); the
  endpoint maps it to the neutral response with the all-zero constant key (§5.3 step 3) and a
  fixed error log, and the writers return `{:error, :pepper_unavailable}` (INV-8).
- **Why not the `sec://tenant/...` store (0016 §C):** those references are tenant-scoped
  (`<tenant>` segment checked against the caller's tenant), the platform pepper has no tenant,
  and resolving it would need the database at a point where only configuration exists. The
  "reference" here is the environment-variable name, the same class as
  `LETFLOW_SECRETS_MASTER_KEY` (0016 §B). Flagged to `REVIEWER`.

### 2.3 Trade-off against plaintext (as in `tenant_memberships.subject_key`)

| | Keyed HMAC (chosen) | Plaintext |
|---|---|---|
| Database read access alone yields an email list | No (needs the pepper, which lives in application environment, not the database) | Yes, a cross-tenant email list outside every tenant's erasure reach |
| Equality lookup on a typed address | Yes | Yes |
| Delivery to the address | Uses the address the caller just typed, never a stored one | Could use the stored one (not needed) |
| Browse, export, debug by address | No | Yes |
| Prefix/domain/partial match | Not possible (and not offered) | Possible (and a hazard) |
| Pepper rotation | Rebuild required (§2.4) | n/a |
| Dictionary attack with DB + pepper | Possible | Not needed |

### 2.4 Erasure and rotation procedures (documented, not built)

- **Erasure of one person:** deactivate the user (entry removed in the same transaction, §3.7).
  There is no other path to a plaintext address in this table.
- **Erasure of a tenant:** tenant row deletion cascades. Tenant deactivation hides entries at
  query time without deleting them.
- **Pepper rotation:** set the new pepper; in one maintenance window delete all directory rows
  and run the backfill (§4); while the window is open discovery returns the neutral response for
  everyone and the SPA falls back to `?realm=`/stored slug. A dual-pepper window is not built
  (0042 OQ-6). **Amended by 0043 D-C:** a key id and a dual-read window ARE now required
  (REQ-435); this paragraph's rebuild procedure survives only as the emergency rotation.

---

## 3. (c) Population signals

### 3.1 Signal inventory

| Signal | Code path | Directory effect |
|---|---|---|
| Admin creates a user | `Identity.create_user/2` (`identity.ex:227`) via POST `/api/v1/users` (`routers/identity.ex:158`) | upsert if active and email valid |
| First OIDC login (JIT) | `Identity.provision_oidc_user/4` (`identity.ex:127`), `created: true` path only | upsert if the new row is active (`jit_config.default_status`) and email valid |
| Profile edit (email and/or status) | `Identity.update_user_profile/3` (`identity.ex:337`); `profile_changeset/2` casts `:status` too (`user.ex:125-129`) | per the plan rules (§3.3) |
| Status change | `Identity.update_user_status/3` (`identity.ex:389`) via POST `/users/:id/status` | per the plan rules |
| Tenant deactivation / reactivation | `Identity.deactivate_tenant/1`, `reactivate_tenant/1` (`identity.ex:1048-1055`) | **none**: filtered at query time |
| User deletion | **No code path exists** (no `delete_user`) | n/a |
| Tenant deletion | No Identity function; FK cascade only | rows cascade |
| Existing user, changed email at the IdP | Not synced by Letflow today (`upsert_by_external_identity/4` returns the existing row unchanged, `identity.ex:1746-1759`) | none; documented limitation |
| Realm-only Keycloak accounts never seen by Letflow | none | **not in the directory** until first login or a backfill; documented limitation |

### 3.2 Tenant id source (verified gap resolved)

`create_user/2`, `update_user_profile/3`, `update_user_status/3` gain **required opt
`:tenant_id`**, supplied by the callers in `lib/letflow/routers/identity.ex` from
`conn.assigns.auth_context.tenant_id` (the same field `scoped_repo_opts/1` reads,
`context.ex:232-237`), never from a request parameter. `provision_oidc_user/4` already receives
`tenant_id` (`identity.ex:119-126`) and needs no new opt.

```
@type user_write_opts :: [
        prefix: String.t(),
        tenant_id: Ecto.UUID.t(),
        login_directory: :enabled | :skip
      ]
```

- **Consistency guard (fail closed).** Before any write, the function checks
  `schema_name_for_tenant/1`, which returns `{:ok, name} | {:error, :invalid_tenant_id}`
  (pure, no I/O, `tenant_provisioning.ex:212-219`), so the guard matches the result against the
  pinned prefix, `{:ok, ^prefix}`, and never compares the tuple to a string. Any other result is
  a failure with a distinct error: `{:error, :invalid_tenant_id}` (malformed `tenant_id`, passed
  through unchanged) -> `{:error, :invalid_tenant_id}`; `{:ok, other_name}` (valid id, different
  schema) -> `{:error, :tenant_prefix_mismatch}`. Both write nothing. This is the check a
  prefix-derived value could never perform (0006 R2), and the reason the explicit opt is kept.
- **Missing opt:** `{:error, :tenant_id_required}` (typed, not a raise), unless
  `login_directory: :skip`.
- **`login_directory: :skip`** exists only for test fixtures that create users in synthetic
  schema prefixes that have no `tenants` row (the FK would otherwise reject the write). A
  grep-based test asserts `login_directory: :skip` appears only under `test/` and never in
  `lib/`, so production code cannot opt out.
- **Rejected alternative:** a reverse `tenant_id_for_schema_name/1` derivation (0042
  "Alternatives rejected" 8, with the corrected rationale in §0.3 D1).

New error shapes added to the three specs: `{:error, :tenant_id_required}`,
`{:error, :invalid_tenant_id}`, `{:error, :tenant_prefix_mismatch}`,
`{:error, {:login_directory, term()}}`. The router handlers'
`case` expressions gain arms mapping the first three to `Response.internal_error/1` (they are
unreachable from the router, which always passes the opt, but a non-exhaustive `case` would
raise) and `{:login_directory, _}` to `Response.internal_error/1`.

### 3.3 The plan function (pure, the single source of truth for add/remove)

```
@type plan_step ::
        {:upsert, email :: String.t()}
        | {:remove_if_unreferenced, email :: String.t()}

@spec Letflow.LoginDirectory.plan_user_change(
        before :: Letflow.Identity.User.t() | nil,
        after_user :: Letflow.Identity.User.t()
      ) :: [plan_step()]
```

A user is **eligible** when `status == :active` and `email_key/1` is `{:ok, _}` for its email.
Rules, with `K(x)` the key of `x`'s email:

| Event | `before` | `after` | Steps |
|---|---|---|---|
| create / JIT insert, eligible | `nil` | eligible | `{:upsert, after.email}` |
| create / JIT insert, not eligible | `nil` | not eligible | none |
| active -> inactive | eligible | not eligible | `{:remove_if_unreferenced, before.email}` |
| inactive -> active | not eligible | eligible | `{:upsert, after.email}` |
| email change while active (key differs) | eligible | eligible, `K` differs | `{:remove_if_unreferenced, before.email}`, `{:upsert, after.email}` |
| email change, same key (case or whitespace only) | eligible | eligible, `K` equal | none |
| email change while inactive | not eligible | not eligible | none |
| email + status change in one PATCH | any | any | derived by the same rules from the two eligibilities and keys |
| no email/status change | any | same | none |

### 3.4 Where the hooks live (verified gap 4) and the in-transaction pre-read

The hooks live **inside** the Identity functions, in the same transaction as the source write,
not in router handlers. For `update_user_profile/3` and `update_user_status/3` the `before`
state used by the plan must come from a read **inside** the transaction with a row lock
(`FOR UPDATE` on the user), not from the existing pre-transaction `Repo.get`
(`identity.ex:340`, `:392`), otherwise two concurrent edits compute plans from the same stale
`before` and leave a ghost entry. So each function's `Multi` gains a first step that fetches and
locks the user, the changeset is applied to that locked row, and `{:error, :not_found}` is
returned if it vanished. The existing outer `rescue` (ISS-0983 hardening,
`test/letflow/audit_dispositions_test.exs:526-610`) is preserved.

Transaction step order per function (names are the `Multi` step names):

| Function | Steps |
|---|---|
| `create_user/2` | `:user` insert -> `:login_directory` -> `:audit` |
| `update_user_profile/3` | `:locked_user` -> `:user` update -> `:login_directory` -> `:audit` |
| `update_user_status/3` | `:locked_user` -> `:user` update -> `:login_directory` -> `:audit` |
| `provision_oidc_user/4` (created path) | one `Repo.transaction` around: insert, created-check, `:login_directory` (§3.5) |

A failure in `:login_directory` or `:audit` rolls back the user write and the entry together.
`create_user/2` and the update functions map `{:error, :login_directory, reason, _}` to
`{:error, {:login_directory, reason}}`. The directory writes are **not separately audited**:
the `user.*` audit rows already record the source change, and a directory audit row would carry
the key. (INV-4.)

### 3.5 The JIT path (D2)

`insert_or_fetch/4` (`identity.ex:1766-1809`) becomes: open a transaction; run the existing
insert (`on_conflict: :nothing`); run the existing created-check; **only when it reports a
genuinely created row**, run the `:login_directory` plan; commit; then run
`sync_role_claims_from_token/3` outside the transaction exactly as today. Rules:

- **Username-conflict recovery inside the transaction (decided: savepoint-mode insert).** The
  existing recovery (`identity.ex:1811-1846`: `username_unique_conflict?/1`, then
  `get_by_username/2`, then `re_select_on_conflict/3`) runs after `Repo.insert` returns
  `{:error, changeset}`. A unique violation on the separate `username` index aborts a Postgres
  transaction ("current transaction is aborted"), so every recovery query would fail. The insert
  therefore runs with the Ecto/Postgres option `mode: :savepoint`, which wraps that one statement
  in a savepoint and rolls back to it on error, leaving the outer transaction usable;
  `get_by_username/2` and `re_select_on_conflict/3` then run unchanged inside the same
  transaction. Their outcomes: same identity -> `{:ok, %{user: _, created: false}}` (no directory
  write; the winner wrote it); different identity or `nil` holder -> `{:error, changeset}`
  unchanged, which rolls the transaction back (nothing was written, so nothing is lost). The
  `on_conflict: :nothing` path raises no error and needs no savepoint. Chosen over "recover
  outside the transaction and then write the entry" because that would need the transaction to
  be abandoned and reopened (a second attempt at the insert, or a directory write detached from
  the user write), re-creating the atomicity gap D2 closes; the savepoint keeps one transaction
  and leaves the recovery code as is. Read-committed isolation means the in-transaction re-select
  sees the winner's committed row.
- `created: false` outcomes (existing row, race loser via `re_select_on_conflict/3`) write
  nothing: a returning user adds no entry, and the race winner already wrote it (idempotent,
  AC "a second login adds none").
- A directory failure aborts the transaction and surfaces as
  `{:error, {:login_directory, reason}}`; `AuthPipeline` already maps any
  `{:provision, reason}` to a generic 500 (`auth_pipeline.ex:178-180`). This is the
  fail-closed-on-index-integrity choice; the best-effort alternative is 0042 OQ-10.
- An email that fails the shape check or exceeds 255 bytes writes no row and is **not** an
  error. `jit_config.default_status` other than `:active` writes no row.
- Hot-path cost: the directory is touched only on a created row; the per-request path for
  returning users is unchanged.

### 3.6 Removal rule (verified gap 2) and its query

`remove_if_unreferenced` deletes the entry **only if no other active user in that tenant schema
has the same normalised email**. After the user write (same transaction) the changed user's row
already carries its new email/status, so the check is simply: does any `users` row in that
tenant `:prefix` have `status = active` and `lower(btrim(email))` equal to the normalised bound
parameter? None -> delete `(key, tenant_id)`; some -> `:kept`. The query is parameterised
Ecto (INV-7), runs with the tenant's `:prefix` (INV-1; the only tenant-schema read in the whole
feature besides the backfill), and uses no new index (`users.email` has none; the table is small
and the path runs at admin-write rate). Known, documented limitation: `lower(btrim(...))` in
Postgres and `String.trim/downcase` in Elixir agree for ASCII addresses but may differ for
non-ASCII case folding and non-space whitespace; the consequence is a false "no other active
user" and a removed entry for a case-folding-only duplicate of a non-ASCII address.

### 3.7 Serialisation: advisory lock per `(tenant_id, email_key)`

Both `upsert_entry/2` and `remove_entry_if_unreferenced/3` first take a **transaction-scoped
advisory lock** derived from `(tenant_id, email_key)` (a bound-parameter two-integer lock, a
fixed namespace constant plus a hash of the pair; collisions only over-serialise). When a plan
touches two keys (an email change) the locks are acquired in ascending key-byte order to avoid
deadlock. Without it, two concurrent deactivations of two users sharing an email can each see the
other as still active and both keep the entry, and a concurrent create can lose its entry to a
concurrent removal. With it each decision observes the other's committed outcome. Both functions
return `{:error, :not_in_transaction}` if called outside a transaction.

### 3.8 Behaviour table (events -> directory)

| Event | Directory result |
|---|---|
| Create active user, valid email | entry for `(K, tenant_id)` exists (one row, idempotent) |
| Create inactive user | no entry |
| JIT first login, active | entry added; second login adds none |
| Deactivate the only active user with email E | entry removed in the same transaction |
| Deactivate U1 while U2 (active, same E) exists | entry kept; deactivating U2 afterwards removes it |
| Reactivate | entry (re)added |
| Change email, old not used by another active user | old entry removed, new added |
| Change email, old still used by another active user | old kept, new added |
| Tenant -> `:inactive` / `:migrating` | no write; lookup returns no match for it; reactivation restores discoverability instantly |
| Tenant row deleted | cascade |
| Forced failure after the user write (audit) | neither the user change nor the entry change persists |

### 3.9 Query logging: `log: false` on every directory query (rework 2, D-3)

Ecto's default query logger writes the statement **and its bound parameters** at `:debug`
(§0.1), and `LOG_LEVEL=debug` is accepted in any environment (`config/runtime.exs:75-101`). The
removal check of §3.6 binds the **plaintext normalised email**; the lookup, the upserts, the
removal delete and the advisory lock bind the **HMAC key** (and tenant id). Either in a log line
contradicts Standing prohibition 9 (INV-4). Required, no exceptions:

- **Every** `Repo` call that touches `tenant_login_directory`, or that carries a normalised email
  or an `email_key` as a bound value, passes the per-call option `log: false` (the form already used
  at `lib/letflow/tenant_provisioning.ex:386`, `lib/letflow/sandbox_pool.ex:964`). Enumerated:
  `lookup_by_key/1` (the one discovery query); `upsert_entry/2` (insert, and the advisory-lock
  statement); `remove_entry_if_unreferenced/3` (the other-active-user check on the tenant `users`
  table, the advisory lock, the delete); the backfill's per-tenant `users` read and its chunked
  `insert_all`; and any `Multi` step in `:login_directory` (the option is passed to each `Multi`
  operation or `Repo` call inside the step).
- **Telemetry is not affected.** `log: false` only suppresses the Logger line; the Repo query
  telemetry events still fire, so the "exactly one `Repo` query per request" assertions (§10.3,
  REQ-437) keep working. Query-count tests must therefore count telemetry events, never log lines.
- **Structural guard.** A test greps `lib/letflow/login_directory.ex`,
  `lib/letflow/login_directory/`, and `lib/letflow/identity/tenant_login_directory_entry.ex` and
  fails when a `Repo.` call that is not marked `log: false` appears (the same style as the
  `Repo.query` grep of INV-7). The behavioural proof is the captured-log test below.
- **Behavioural proof.** `ExUnit.CaptureLog.capture_log(level: :debug, fn -> ... end)` (the test
  environment's logger level is `:debug` precisely so this works, `config/runtime.exs:75-77`)
  around: a create, an email-change, a deactivation (the removal query), a JIT first login, a
  backfill run, a discovery lookup with a known, an unknown and a malformed address; asserts the
  output contains **neither the plaintext email, nor its lowercase form, nor the hex or base64
  rendering of its `email_key`**. This is in both REQ-435 and REQ-437's test lists (§15.1, §15.3).
- **Not covered, stated.** (1) The **tenant `users` writes themselves** (insert/update of
  `users.email` inside `create_user/2` etc.) bind the plaintext email and are logged at `:debug` by
  Ecto today, independent of this feature; they are not directory queries, are unchanged, and are
  carried as 0042 OQ-13 for `ORCH` to file. (2) PostgreSQL's own statement log
  (`log_statement`, `log_min_duration_statement`) is database configuration outside this
  repository; the same OQ-13 records it as a deployment check.

---

## 4. (d) Backfill

- **Mix task:** `mix letflow.backfill_login_directory [--dry-run]`
  (`lib/mix/tasks/letflow.backfill_login_directory.ex`), thin, delegating to
  `Letflow.LoginDirectory.Backfill.run/1` (`lib/letflow/login_directory/backfill.ex`), following
  `letflow.backfill_platform_roles.ex` -> `Identity.RoleBackfill` (the established pairing). No
  `LETFLOW_DEV_DB_CONFIRMED` guard (same precedent as `letflow.backfill_platform_roles`).

```
@type backfill_report :: %{
        tenants: [%{tenant_id: Ecto.UUID.t(), users_read: non_neg_integer(),
                    inserted: non_neg_integer()}],
        failed: [%{tenant_id: Ecto.UUID.t(), reason: atom()}],
        dry_run: boolean()
      }
@spec Letflow.LoginDirectory.Backfill.run(opts :: [dry_run: boolean()]) ::
        {:ok, backfill_report()} | {:error, :pepper_unavailable}
```

- **Enumeration (D3):** `TenantProvisioning.list_registrations/0` -> every registered tenant
  regardless of status, because status is filtered at query time and reactivation must not need
  a re-run. The prefix is the registration's `schema_name` (equivalently
  `schema_name_for_tenant/1`, pure); never string-interpolated into SQL (INV-7).
- **Read:** for each tenant, `users` rows with `status == :active` and non-nil email, selecting
  the email only, with `prefix: schema_name` (INV-1). Keys are computed in Elixir via
  `email_key/1`; invalid-shape or over-length emails are skipped.
- **Write:** chunked `insert_all` into `tenant_login_directory` with
  `ON CONFLICT (email_key, tenant_id) DO NOTHING`. The number inserted is the driver's returned
  count, so a second run reports 0 and the row set is identical (idempotent).
- **`--dry-run`:** reads and computes, writes nothing, prints per-tenant counts.
- **Failure isolation (INV-8):** each tenant runs under a rescue; a failure is recorded in
  `failed` (reason atom only, never the exception text or an email) and the next tenant runs.
  `run/1` returns `{:ok, report}` even when `failed != []`; the Mix task prints the summary and
  then halts non-zero if `failed != []`.
- **Output and logs:** counts and tenant ids only; no email (INV-4).
- **Pepper:** if absent, `run/1` returns `{:error, :pepper_unavailable}` before touching any
  tenant.
- **Documented limitations:** (1) insert-only: it never removes. A backfill racing a concurrent
  deactivation can leave a ghost entry for the race window; this is the one way a row can
  outlive its source user, stated in 0042 RQ-4. A `--prune` mode (delete rows older than the
  run's start whose key is not in the active set) is **not** built and is listed in §17. (2) It
  sees only what Letflow owns: Keycloak-only accounts are invisible (RQ-2). (3) It does not
  take the per-key advisory lock (cost); run it in a maintenance window.

---

## 5. (e) The lookup endpoint contract

### 5.1 Mount and router

- `forward("/api/login-discovery", to: Letflow.Routers.LoginDiscovery)` added to
  `lib/letflow/router.ex`, **after** `/api/public` (`:133`) and **before** `forward("/api/v1",
  ...)` (`:135`), like `/api/tenant-config` (`:111`). `Letflow.Plugs.AuthPipeline` is not
  modified; the route is public by mount position (0028).
- `Letflow.Routers.LoginDiscovery` is a plain `Plug.Router` (not `AuthorizedRouter`; no
  authorization-matrix entry is needed because `Letflow.Api.Authorization` only enumerates
  `/api/v1` routes). Its own chain, in order: (1) `plug :enabled_gate` (below), (2)
  `Letflow.Plugs.ClientIp` (REQ-CIP, §12.6; resolves the client address, reads no body), (3)
  `Letflow.Plugs.LoginDiscoveryRateLimit` (the limiter stays the first plug that does any *work*
  after the gate; `ClientIp` is a pure header/peer read), (4) `:match`, (5) `:dispatch`. No
  `Plug.Parsers`, no `assign_trace_id` (so no `x-trace-id` header and a constant `trace_id` in any
  problem body, as `tenant_config.ex:127-139` documents).
- **The disabled-mount gate (D12).** A module-level function plug `enabled_gate/2`, declared as the
  **first** `plug` line of `Letflow.Routers.LoginDiscovery` itself: **no new module and no new
  file**. Justification: `router.ex` mounts are unconditional static `forward/2` lines
  (`router.ex:111-137`) with no per-mount guard, so the switch cannot live in the parent without
  breaking that structure; a function plug in the mounted router runs before every other plug of
  the chain, needs no separate test file (its test is the mount-switch case in
  `login_discovery_test.exs`), and reads `Application.get_env(:letflow, Letflow.Routers.LoginDiscovery)[:enabled]`
  **at request time** (so a test toggles it without recompiling). When `enabled` is not exactly
  `true`: it emits the `:disabled` outcome (§12.7), responds with `Letflow.Api.Response.not_found/1`
  (byte-identical to `Letflow.Router`'s catch-all and to the `match _` below), and halts. It runs
  **before** `ClientIp`, the limiter, `:match` and body reading, for any method and any path, so a
  disabled mount resolves no client address, touches no limiter state, issues zero `Repo` queries
  and reveals nothing beyond what an unmounted path reveals. When enabled it is a no-op.
- Routes: `post "/"` and `match _` -> `Letflow.Api.Response.not_found/1`, byte-identical to
  `Letflow.Router`'s catch-all, for any other method or sub-path. (Route-level, not
  input-dependent.)
- `Letflow.Router`'s moduledoc route table gains the row for this mount (Auth **none**, DB global
  `tenant_login_directory` + `tenants`).

### 5.2 Request

`POST /api/login-discovery`, `Content-Type: application/json`, body
`{"email": "<string>"}`. Extra keys are ignored; the query string is never read. The body is read
with a bounded read (`max_body_bytes`, default 2048); the router calls no raising parser.
Non-JSON content type, an unreadable or oversize body, invalid JSON, a missing or non-string
`email`, an empty string, a string over 255 bytes after trim, or a string failing
`email_shape?/1` are all the **malformed class** (§5.3).

### 5.3 Handler sequence (identical for every input class)

1. Bounded body read; any failure -> malformed class (no early return).
2. JSON decode with a non-raising decoder; failure -> malformed class.
3. `email_key/1`; on `:invalid` or a failed decode, use `sentinel_key/0` (the keyed HMAC, with
   the same pepper and the same cost class as a real key, of a fixed string that no valid
   normalised address can equal because it contains no `@`; the writers never write a key for
   an invalid address and refuse to write the sentinel, so it can never match a row). If the
   pepper is unavailable at runtime (unreachable after boot validation, §2.2) the handler logs a
   fixed error and uses the all-zero 32-byte constant key, which no writer ever writes, so the
   single-query structure and the neutral response are preserved.
4. Per-email limiter consult (`LoginDiscoveryRateLimit.consume_email(key, :request)`); a refusal
   sends REQ-436's 429 (§12) and stops. The sentinel shares one bucket, which only throttles
   garbage senders.
5. **Exactly one** database round trip: `lookup_by_key(key)` (§5.4). A failure becomes
   `{:error, :lookup_failed}` and is treated as "no matches" (INV-8).
6. `decide(mode, result)` (pure, §7) -> `:neutral | {:match, tenant_ref}`.
7. `Dispatch.submit/3` -- **always** exactly one notifier-task submission per request, matched or
   not, so request timing does not depend on a match (§13).
8. Send the response.

There is no branch that returns before step 5 other than the limiter refusal (which is
input-independent for IP and global buckets and byte-identical for the email bucket).

### 5.4 The single query and the closed projection

```
@type email_key :: <<_::256>>
@type tenant_ref :: %{slug: String.t(), display_name: String.t()}

@spec Letflow.LoginDirectory.email_key(term()) ::
        {:ok, email_key()} | :invalid | {:error, :pepper_unavailable}
@spec Letflow.LoginDirectory.sentinel_key() :: email_key() | {:error, :pepper_unavailable}
@spec Letflow.LoginDirectory.lookup_by_key(email_key()) ::
        {:ok, [tenant_ref()]} | {:error, :lookup_failed}
@spec Letflow.LoginDirectory.lookup_by_email(term()) ::
        {:ok, [tenant_ref()]} | {:error, :lookup_failed}
```

`lookup_by_email/1` is the convenience composition (invalid input -> sentinel) that REQ-435's
tests call; the endpoint uses `email_key/1` + limiter + `lookup_by_key/1` so the limiter can sit
between them. The query: directory joined to `tenants`, `email_key == ^key`,
`tenants.status == :active`, `tenants.idp_realm_id` not null and not empty (otherwise
`/api/tenant-config?realm=<slug>` would silently resolve to the default realm,
`tenant_config.ex:230-249`), `select` building the two-field map directly (the `Tenant` struct is
never loaded, so `idp_realm_id`/`id`/`settings` are unrepresentable past the query), ordered by
`display_name` then `slug` (deterministic), `limit` 50 (bounds work; the primary key bounds
real cardinality). No `:prefix`: the query touches only public tables. Never a second query.

### 5.5 Responses (hand-built, literal keys)

Common headers on every response from this route, success and refusal: `Cache-Control: private,
no-store`, `Referrer-Policy: no-referrer`, `X-Robots-Tag: noindex, nofollow` (as
`routers/public_read.ex:80-` sets them). CORS headers come from the top-level `Letflow.Plugs.Cors`
(`router.ex:95`), identically for every response, so the SPA can call it cross-origin.

| Outcome | Status | Content-Type | Body |
|---|---|---|---|
| Neutral | `202` | `application/json; charset=utf-8` | exactly `{"result":"accepted"}` |
| Single match (Mode B only) | `200` | `application/json; charset=utf-8` | `{"result":"tenant","tenant":{"slug":"<slug>","display_name":"<display_name>"}}` (key order as the encoder emits; no other key) |
| Rate limited (any bucket) | `429` | `application/problem+json` | `Response.rate_limited("rate limit exceeded")` problem document, constant `Retry-After` |
| Wrong method / sub-path | `404` | `application/problem+json` | `Response.not_found/1` |

`slug` here is `tenants.slug` (D8): the value `?realm=` and `GET /api/tenant-config?realm=` accept.
It is opaque text (no charset constraint, §0.1) and `display_name` is free text: the SPA treats
both as untrusted strings, renders text only, and URL-encodes the slug (as
`buildRedirectArgs` already does, `oidcRedirectArgs.ts:27-28`).

No response ever contains: `idp_realm_id`, a tenant UUID, an authority URL, a user id, a status,
a count, a `Location` header, a cookie.

---

## 6. (f) Anti-enumeration, honestly bounded

- **Structural, not wall-clock.** For every input class the server performs the same operations:
  one HMAC, one consult of each limiter bucket, exactly one database query, one notifier-task
  submission, one fixed-shape response. A malformed input uses the sentinel so it issues the
  same query. There is no early return and no second query on any path.
- **Single-match is disclosed by design (Mode B).** A response of `200` with a tenant tells the
  caller "this email has an active account in exactly one tenant, X". This is the accepted
  bounded inference; its exact extent is 0042 "Accepted bounded inference". It is **not**
  claimed indistinguishable from unknown. In Mode B the pairs that must be indistinguishable are
  multi-tenant, unknown, malformed, inactive-only and lookup-failed. In Mode A all of them plus
  single-match are.
- **Mitigations:** per-IP, global and per-email request buckets; a per-address send bucket;
  no bulk/list/search route; one email per request; POST body only; neutral outcomes for all
  non-single cases; the closed projection; configuration-only switch to Mode A.
- **The "always redirect unknown emails to `bpm-default`" trick is rejected.** It leaks any
  non-default tenant's membership by contrast: every address that is *not* redirected to the
  default realm is revealed as a member of some other tenant, for all such tenants, in every
  mode, and unknown addresses get the wrong realm (the ISS-0727 defect). 0042 "Alternatives
  rejected" item 1.
- **Email-bombing.** In modes that send mail, an attacker can make Letflow email arbitrary
  victims. Controls: the per-email request bucket, the per-address send bucket (minimum
  interval), a fixed message template with no attacker-controlled text beyond the recipient
  address, and a bounded notifier concurrency (§13). Residual: one message per address per
  interval to a victim.

---

## 7. (g) Disclosure modes

Application config, not code:

| Key | Values | Default | Source |
|---|---|---|---|
| `config :letflow, Letflow.Routers.LoginDiscovery, mode:` | `:uniform_plus_email`, `:redirect_single` | `:redirect_single` (**ratified default**, 0042 Sign-off 2026-10-04) | `config/config.exs` default; deployment override from env `LETFLOW_LOGIN_DISCOVERY_MODE` in `config/runtime.exs`, unknown value -> raise at boot |
| `... max_body_bytes:` | positive integer | 2048 | config |

An unrecognised value read at request time is treated as `:uniform_plus_email` (the most
conservative) and logs a fixed message once; runtime.exs validation makes that unreachable in a
deployment.

The original user requirement, recorded as written: "respond uniformly and deliver the tenant
list by email unless the email matches exactly one tenant". That is **Mode B**, the user's stated
shape. Reconciliation with the anti-enumeration goal: Mode B discloses only the exactly-one case
(bounded in §6 and 0042) and is uniform for everything else; Mode A removes the disclosure at the
cost of UX and a mailer. **The default (Mode B) was ratified by `REVIEWER` and
`SECURITY-REVIEWER` on 2026-10-04 (Q1).** If it is later changed to Mode A, only the `config.exs`
default changes.

Pure decision and delivery rules (`Letflow.LoginDiscovery`):

```
@type mode :: :uniform_plus_email | :redirect_single
@type decision :: :neutral | {:match, Letflow.LoginDirectory.tenant_ref()}
@type delivery :: :none | {:deliver, [Letflow.LoginDirectory.tenant_ref(), ...]}

@spec Letflow.LoginDiscovery.mode() :: mode()
@spec Letflow.LoginDiscovery.decide(mode(), {:ok, [Letflow.LoginDirectory.tenant_ref()]}
                                            | {:error, :lookup_failed}) :: decision()
@spec Letflow.LoginDiscovery.delivery(mode(), {:ok, [Letflow.LoginDirectory.tenant_ref()]}
                                              | {:error, :lookup_failed}) :: delivery()
```

| Active matches | Mode A decision | Mode A delivery | Mode B decision | Mode B delivery |
|---|---|---|---|---|
| 0 / lookup failed | `:neutral` | `:none` | `:neutral` | `:none` |
| 1 | `:neutral` | `{:deliver, [t]}` | `{:match, t}` | `:none` |
| >= 2 | `:neutral` | `{:deliver, list}` | `:neutral` | `{:deliver, list}` |

Option C (`picker_unauth`) is **not a mode** and has no response field (0042 "Alternatives
rejected" 2).

---

## 8. (h) Keycloak interplay

### 8.1 `login_hint`

On a single match the SPA stores the slug and calls `signinRedirect` with `login_hint` = the
typed email (oidc-client-ts v3 supports it in the sign-in args, `oidc-client-ts.d.ts:243`).
`buildRedirectArgs` (`oidcRedirectArgs.ts:21-35`) gains an **optional** second parameter
`{ loginHint?: string }`; the return type becomes `{ redirect_uri; state?; login_hint? }`.
Existing callers and tests pass unchanged. `login_hint` populates the username field only.

### 8.2 `kc_idp_hint` is deliberately unused

It selects a brokered identity provider *inside* a realm. No realm brokers an IdP today and
brokering is out of scope (§14 (k)).

### 8.3 Realm configuration precondition and who checks it

Realms whose users log in by username need Keycloak's "Login with email" (realm setting
`loginWithEmailAllowed`) enabled for a typed email to log in. The repository's realm fixture does
not set it (U2). **Checked by `UAT-RUNNER`** per realm on QA (`bpm-default`, `bilimbaga`), and by
REQ-438's real-flow e2e step. Recorded as 0042 OQ-8.

### 8.4 Which OIDC manager performs the hand-off (D9)

The hand-off must use `getOrCreateManagerForTenant(slug)` (`tenantOidcRegistry.ts:20-29`), **not**
`getOidcManager()`: the latter is a singleton that may already be bound to the default realm by
`AuthProvider`'s eager call (`AuthProvider.tsx:99-122`) or by `fetchTenantConfig`'s own cache
(`tenantConfig.ts:27`, `:53-67`). The callback page, after the full-page return from Keycloak, is
a fresh load whose `getOidcManager()` resolves the same slug through the stored value
(`OidcCallbackPage.tsx:68-80`). Both managers are built by the same `buildOidcSettings`
(`OidcManager.ts:10-`), so they are equivalent; that this equivalence works for a *first* sign-in
(the registry was written for the switcher) is **not verified by reading** and is what REQ-438's
real-flow e2e acceptance test must prove.

---

## 9. (i) Security invariants

INV-3 (untrusted runtime sandboxing) **does not apply**: no Lua, WASM or tenant-authored script is
involved.

| INV | Mechanism that discharges it | Where it is shown / tested |
|---|---|---|
| **INV-1** tenant data isolation | The directory is a global table outside every tenant schema (public migration, absent from `tenant_scoped_migrations/0`, `tenant_provisioning.ex:733`). The discovery path issues no query with a tenant `:prefix` and reads only `tenant_login_directory` and `tenants`. Writers run inside the Identity functions whose `:prefix` derives from `auth_context.tenant_id` (`context.ex:219-237`) and which assert `schema_name_for_tenant(tenant_id) == prefix`. The backfill reads each tenant schema only through the registration's derived `schema_name`. `tenant_id` on this global table is its only scoping (0006 D3), supplied explicitly (never from a request parameter) and cross-checked against the prefix. | REQ-435 tests: information_schema shows the table in `public` only; two-tenant isolation; request-body `tenant_id` ignored. REQ-437 test: no query on the path carries a `:prefix`. |
| **INV-2** server-side field authorisation | Closed allowlist: hand-built maps, literal keys; `lookup_by_key/1` selects exactly `slug` and `display_name` into a plain map, so `idp_realm_id`, `id`, `settings`, status are unrepresentable beyond the query; the neutral body is a constant; the directory schema has no sensitive field. | REQ-437 tests assert the exact key set; REQ-435 test asserts the schema and returned structs carry no user/credential field. |
| **INV-4** secrets by reference; no secret/PII in logs | Pepper by environment-variable reference, boot-validated, never logged or serialised (§2.2). No raw email, key, body or IP in logs, telemetry labels, audit rows or error messages: failures log fixed strings or atoms; the directory writes no audit rows; the limiter keys hold only the HMAC and an IP in memory; the notifier default adapter logs nothing identifying; **every directory query passes `log: false` so Ecto's `:debug` bound-parameter logging never carries the email or key (§3.9)**; outcome counters carry fixed-atom labels only (§12.7); notifier tasks use the closure form so OTP crash reports print no recipient (§13). | Captured-Logger tests in REQ-435/436/437 grep for the address and body, **run with `capture_log(level: :debug)` (§3.9)**; notifier-raise test asserts no email in the crash log (§13); `grep -rn "System.get_env" config/ lib/` shows env-sourced only. |
| **INV-5** not-found/forbidden indistinguishability | First email-keyed instance. Mechanism: one query for every class (sentinel for malformed); the same operations for every input; constant neutral bytes; the 429 is byte-identical for IP, global and per-email refusal; no 401/403; notifier submission unconditional. Honest bound: Mode B discloses the single-match case (0042). | The response-equivalence matrix (§10); REQ-437 byte-comparison and query-count tests. |
| **INV-6** new data-access paths prove their scoping | This document and 0042 are the scoping proof; `SECURITY-REVIEWER` is a mandatory gate on 0042 and on REQ-435/436/437 and must record which of INV-1..INV-9 apply and why. | Gate verdicts (0042 Sign-off); REQ-435/437 handoffs. |
| **INV-7** no SQL string interpolation | Every query is Ecto composition with bound parameters, including the "other active user" check and the advisory lock (bound parameters, no concatenation); the backfill passes the schema as the `prefix:` option, never into a SQL string; migrations use no `Repo.query`. | `grep -rn "Repo.query" lib/letflow/login_directory* lib/letflow/identity/tenant_login_directory_entry.ex priv/repo/migrations/<new>` shows no unbound use (REQ-435 AC). |
| **INV-8** no unhandled crashes on realistic failure paths | Typed results throughout: non-raising JSON decode, bounded body read, `email_key/1` tagged returns, `lookup_by_key/1` wraps the query so any DB failure becomes `{:error, :lookup_failed}` and the neutral response (not a 500), the notifier runs in a supervised task isolated from the request process and bounded in time and concurrency, notifier crash/exit/timeout leaves the response unchanged, a missing pepper maps to neutral plus a fixed error log, the JIT and update paths return tagged errors, the backfill isolates per-tenant failures. | REQ-437 notifier-failure tests (raise, exit, timeout); REQ-435 forced-failure rollback tests; backfill failure-isolation test. |
| **INV-9** tenant-controlled outbound URL validation | The server builds no redirect and makes no outbound HTTP request from tenant-supplied text on this path: the response carries `slug` and `display_name` as data and no `Location`; the SPA derives the authority from the server-built `/api/tenant-config` (authority from deployment config plus `idp_realm_id`, `tenant_config.ex:268-274`, `:327-331`), never from the discovery response. The notifier port is the only egress; the default adapter sends nothing, and a future adapter that adds links must build them from a deployment base URL, never from tenant text, and passes its own `SECURITY-REVIEWER` gate. | REQ-437 test: no `Location` header, no URL-shaped field; adapter requirement gate. |

---

## 10. Response-equivalence matrix

Terms: **N** = the neutral response (202, `application/json; charset=utf-8`, body
`{"result":"accepted"}`, common headers). **M(t)** = the match response (200, same
Content-Type and headers, body carrying tenant `t`). **429** = REQ-436's single refusal.
"Deliveries" is the number of `deliver_tenant_list/2` calls the notifier double records.
"Queries" is the number of `Repo` queries issued by the request (telemetry), measured for the
whole request including the limiter and notifier submission.

### 10.1 Mode A: `:uniform_plus_email`

| Input class | Status | Body | Content-Type | Queries | Deliveries | Must be byte-identical to |
|---|---|---|---|---|---|---|
| Known, single active tenant | 202 | N | json | 1 | 1 (list of 1) | all other rows in this table (except 429/404) |
| Known, multiple active tenants | 202 | N | json | 1 | 1 (list of n) | same |
| Unknown | 202 | N | json | 1 | 0 | same |
| Malformed (missing, non-string, empty, over-long, no `@`, wrong content type, invalid JSON, oversize body) | 202 | N | json | 1 | 0 | same |
| Inactive/migrating-tenant-only (or unbound realm) | 202 | N | json | 1 | 0 | same |
| Active + inactive tenant | 202 | N | json | 1 | 1 (list of the active ones only) | same; treated exactly as active-only |
| Lookup/database failure | 202 | N | json | 1 attempted | 0 | same |
| Per-IP, global or per-email bucket exhausted | 429 | the one problem body | `application/problem+json` | 0 (IP/global) or 0 (email, refused before the query) | 0 | identical across the three causes |
| Wrong method or sub-path | 404 | standard not-found problem | `application/problem+json` | 0 | 0 | the router catch-all |

**Equivalence class in Mode A: every row with status 202 is byte-identical.**

### 10.2 Mode B: `:redirect_single` (ratified default)

| Input class | Status | Body | Content-Type | Queries | Deliveries | Must be byte-identical to |
|---|---|---|---|---|---|---|
| Known, single active tenant | **200** | **M(t)** | json | 1 | 0 | nothing (disclosed by design, 0042) |
| Known, multiple active tenants | 202 | N | json | 1 | 1 (list of n) | unknown, malformed, inactive-only, failure |
| Unknown | 202 | N | json | 1 | 0 | multi, malformed, inactive-only, failure |
| Malformed (same members as Mode A) | 202 | N | json | 1 | 0 | same group |
| Inactive/migrating-tenant-only (or unbound realm) | 202 | N | json | 1 | 0 | same group |
| Active + inactive tenant | **200** | **M(active t)** | json | 1 | 0 | the single-active-tenant case |
| Active + >= 1 other active, plus inactive | 202 | N | json | 1 | 1 (active ones only) | the multi case |
| Lookup/database failure | 202 | N | json | 1 attempted | 0 | same group |
| Any bucket exhausted | 429 | the one problem body | problem+json | 0 | 0 | identical across causes |
| Wrong method or sub-path | 404 | standard not-found problem | problem+json | 0 | 0 | the router catch-all |

**Equivalence class in Mode B: {multi, unknown, malformed, inactive-only, lookup-failure} are
byte-identical to each other. Single-match is deliberately distinguishable.**

### 10.3 Timing envelope

- **Binding guarantee (structural):** identical operation sequence for every input class (§5.3):
  one HMAC, one consult per limiter bucket, exactly **one** `Repo` query, exactly one notifier
  task submission, no early return; the notifier never runs on the request path. Asserted by
  query-count telemetry and by a notifier double that sleeps 2 s without delaying the response.
- **Wall-clock sanity bound (not binding, quarantinable):** over at least 200 alternating
  requests the **median latency difference is below 25 ms** and there is no systematic skew
  (sign of the paired difference not consistently one-sided). Pairs to compare: Mode A, known vs
  unknown; Mode B, **multi-tenant vs unknown** (the pair that must be indistinguishable; the
  single-match row is excluded by design). The test is tagged (for example `@tag :timing`) so it
  can be quarantined without weakening the structural test. The 25 ms bound is the requirement's
  recommendation; `REQ-VALIDATOR` is asked to confirm it is generous enough not to flake.
- **No `Retry-After` variance:** the 429 carries one constant value regardless of the bucket.

---

## 11. (l) SPA fallback precedence

### 11.1 Table

| Rank | Source | Today (cited) | Decided here (to be ratified) |
|---|---|---|---|
| 1 | Explicit `?realm=` query parameter | read **second** (`tenantConfig.ts:40-51`) | read **first**; if present it wins, is written to `bpm_realm_slug`, overriding any stale stored value |
| 2 | Stored `bpm_realm_slug` (sessionStorage) | read **first** (`tenantConfig.ts:41-42`) | used when no `?realm=` |
| 3 | Email-first screen | does not exist | shown when the flag is on and ranks 1-2 are absent |
| 4 | Default-realm fallback: `GET /api/tenant-config?host=` then `bpm-default` | `tenantConfig.ts:53-67`; server `tenant_config.ex:241-249` | unchanged, used when the flag is off (or in single-tenant/dev) |

Host lookup is ranked **below** the email-first screen because it never identifies a tenant:
Letflow has no host->tenant binding (REQ-076; `tenant_config.ex:90-125`), so it always yields the
default realm. When only one of `?realm=` and the stored slug is present, behaviour is unchanged.

### 11.2 Override mechanics

`resolveRealmFromUrl()` reads `?realm=` first; when present it overwrites the stored value and
returns it; otherwise it returns the stored slug; otherwise `null`. The callback URL
(`/auth/callback?realm=<slug>`, `oidcRedirectArgs.ts:27-28`) carries the slug it was started with,
so ranks 1 and 2 agree in the normal round trip.

### 11.3 Flag

`VITE_EMAIL_FIRST_LOGIN` (build-time, read through one helper, `isEmailFirstLoginEnabled()`);
only the value `true` enables it; absent means off, i.e. today's behaviour exactly. Multi-tenant
deployments set it in their build environment.

**Enablement preconditions (rework 2; binding on any deployment outside dev).** Setting the flag
to `true` in a QA or production build requires **all** of the following, each recorded in the
enabling change's handoff:

1. **Trusted-proxy client IP is configured and verified (D-2).** REQ-CIP is `done`;
   `LETFLOW_TRUSTED_PROXIES` is set for that deployment; nginx forwards the real visitor address
   (§12.6); and a UAT step shows two requests from two real source addresses land in different
   per-IP buckets. The backend refuses to boot with the mount enabled in `:prod` and an empty trust
   list (§12.6), so this precondition is mechanically enforced on the server side; the SPA flag is
   not, which is why it is also listed here.
2. **0042 OQ-3 is answered (C-5):** a named human or organisational controller, the lawful basis
   and the retention period for the directory's personal data are recorded in 0042. Not decidable
   inside this pipeline; owner and escalation in 0042 OQ-3. The flag stays off outside dev until it
   is answered.
3. **The multi-tenant dead end is resolved (0042 OQ-9):** either a real notifier adapter exists or
   the organisation-code entry of §11.5 (shipped with REQ-438) is accepted as the interim path,
   recorded by `ORCH`.
4. **Realm "Login with email" is verified per realm (§8.3, OQ-8).** E2E runs that pre-restore a session
(`tryRestoreE2eSession`, `AuthProvider.tsx:60-76`) have `isAuthenticated` true from the first
render, so they never reach `ProtectedRoute`'s redirect branch and are unaffected whatever the
flag says (REQ-438 must still assert this). RQ-5.

### 11.4 `ProtectedRoute` and `AuthProvider` wiring

| Flag | Realm resolvable (rank 1 or 2) | `ProtectedRoute` on `!isAuthenticated` |
|---|---|---|
| off | any | unchanged: `getOidcManager()` then `signinRedirect(buildRedirectArgs(path))` |
| on | yes | unchanged (same call) |
| on | no | navigate (replace) to `/login` with the pre-redirect path in router location state |

- `/login` is a new top-level public route in `web/src/router.tsx`, a sibling of `/auth/callback`
  (`router.tsx:44-47`), outside `ProtectedRoute`. An already-authenticated visitor to `/login` is
  sent to `/`.
- The pre-redirect path is carried in router state, validated with `isSafeRestorePath`
  (`safeRestorePath.ts`) at consumption (an unsafe path is dropped), and passed to
  `buildRedirectArgs` as `capturePath` so it round-trips as OIDC `state` and is restored by the
  callback (`OidcCallbackPage.tsx:105-107`).
- **Logout** (`AuthProvider.tsx:131-141`): unchanged. It clears the stored realm; after the
  Keycloak sign-out lands back on `/`, `ProtectedRoute` finds no realm and, with the flag on,
  routes to `/login`.
- **Session-expired** (`AuthProvider.tsx:85-95`) (D4): unchanged when a realm is stored (the user
  re-logs into the same tenant). When none is stored and the flag is on, it navigates to `/login`
  instead of calling `signinRedirect` against the default realm.
- The OIDC callback page, `getOidcManager()` and the in-app tenant switcher are unchanged.

### 11.5 The page (REQ-438 item 1) -- states and contract

- Fields: one email input; **no** password, token or other credential input anywhere on the page.
  Client-side shape validation only.
- Response type, a closed union: `{ result: 'accepted' }` or
  `{ result: 'tenant', tenant: { slug: string, display_name: string } }`. Anything else, or a
  parse failure, is the *malformed-response* error state.
- States: idle; submitting; **neutral** (one fixed message that never says whether the address
  exists; identical DOM for an unknown address and a multi-tenant address); **tenant** (store
  `bpm_realm_slug` exactly as `resolveRealmFromUrl()` does, then hand off per §8); **429**,
  **network failure** and **malformed response** each a distinct non-leaking error state with a
  retry affordance (a 429 does not reveal whether the address is known).
- **The 429 state offers the `?realm=` route (C-2).** Because an attacker can keep one victim
  address's per-email bucket exhausted (§12.8), the 429 state must not be a dead end: besides
  "retry later" it shows an **organisation code** control (a text input for the tenant slug, not a
  credential) whose submit navigates to `/?realm=<url-encoded slug>` (rank 1 of §11.1, which
  bypasses discovery entirely and goes to the realm's Keycloak login). The control is a **static
  part of the page present in every state** (idle, neutral, 429, network failure, malformed
  response), so it adds no state-dependent DOM and the neutral DOM for an unknown and a
  multi-tenant address stays identical (§15.4); it also serves as the interim route for the
  multi-tenant dead end (0042 OQ-9). It validates only non-empty and length <= 255 (slugs have no
  charset constraint, §0.1); an unknown slug is handled by the existing
  `/api/tenant-config?realm=` fallback behaviour, unchanged.
- No tenant picker is built: neither mode returns names for the multi-match case. (REQ-438's open
  question on picker presence is answered: none.)
- All strings come from a new catalog covering `en`, `ru`, `kk` (decision 0021): a new
  `web/src/i18n/loginMessages.ts` and a page-local provider in the style of
  `EntitiesIntlProvider.tsx`, reusing `resolveUiLocale` from `entitiesMessages.ts`.

---

## 12. Rate limiter design (REQ-436's decisions)

### 12.1 Choice: a new sibling module with its own table, not namespaced keys on the existing Bucket

This is the "mount-point-agnostic successor" option of REQ-434 item 4 (§0.3 D10), not reuse of
`Bucket`. Shared: the token-bucket algorithm (restated), `conn.remote_ip` keying, the
`Response.rate_limited` + halt convention, 0028 §6 placement. New: table, key namespace, lossless
eviction, key cap, atomic check-and-write.

Decided: `Letflow.Plugs.LoginDiscoveryRateLimit.Bucket` with its own named ETS table
(`:letflow_login_discovery_rate_limit`). The existing `Bucket`
(`public_read_rate_limit/bucket.ex`) and `PublicReadRateLimit` are **not modified** (git diff
empty; their tests pass unmodified). Reasons: (a) adding eviction to the shared module would put
`/api/public`'s IP keys under the same caps and sweep; (b) independence of the two mounts
(flooding one must not 429 the other) is then true by construction: different table, different
keys; (c) 0028 permits reuse only "if that module lands mount-point-agnostic"
(`0028...md:147-149`), which it has not. Every key this limiter writes begins with
`:login_discovery`. Cost: the ~20-line token-bucket arithmetic is restated, with a comment
cross-referencing the original; the alternative refactor would touch `/api/public`.

### 12.2 API

```
@type ip_bucket_id ::
        {:v4, :inet.ip4_address()}
        | {:v6_64, {0..65535, 0..65535, 0..65535, 0..65535}}

@type bucket_key ::
        {:login_discovery, :global}
        | {:login_discovery, :ip, ip_bucket_id()}
        | {:login_discovery, :email_hmac, binary()}
        | {:login_discovery, :email_send, binary()}

# Pure. IPv4 -> {:v4, addr}. IPv6 -> {:v6_64, first four 16-bit groups} (the /64 network).
# IPv4-mapped IPv6 (::ffff:a.b.c.d) is first converted to {:v4, a.b.c.d}.
@spec Letflow.Plugs.LoginDiscoveryRateLimit.ip_bucket_id(:inet.ip_address()) :: ip_bucket_id()

# Letflow.Plugs.LoginDiscoveryRateLimit  (@behaviour Plug)
@spec init(keyword()) :: keyword()
@spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
@spec consume_email(email_key :: binary(), kind :: :request | :send) :: :ok | :rate_limited
@spec send_rate_limited(Plug.Conn.t()) :: Plug.Conn.t()
@spec validate_config!(keyword()) :: :ok

# Letflow.Plugs.LoginDiscoveryRateLimit.Bucket  (GenServer owning the table)
@spec start_link(keyword()) :: GenServer.on_start()
@spec consume(bucket_key(), capacity :: pos_integer(), refill_per_sec :: number(),
              now_ms :: integer()) :: :ok | :rate_limited
@spec sweep(now_ms :: integer()) :: non_neg_integer()   # rows removed
@spec size(kind :: :ip | :email) :: non_neg_integer()   # :email counts :email_hmac + :email_send rows
```

`now_ms` defaults to the monotonic clock; it is a parameter so tests can advance time without
sleeping (the seam REQ-436's "evicted" test needs, D5).

`call/2` runs **before** the body is read, in this order (rework 2, D-1):

1. Resolve the client address: `conn.assigns.client_ip` as set by `Letflow.Plugs.ClientIp`
   (§12.6), or `conn.remote_ip` when that assign is absent. Never a raw forwarded header read here.
2. Map it with `ip_bucket_id/1` (IPv6 aggregated to its /64, so rotating through a /64 is one
   bucket) and consume the **per-IP** token. On refusal: emit the `:rate_limited_ip` counter
   (§12.7), `send_rate_limited/1`, halt. **The global bucket is not touched.**
3. Only an IP-admitted request consumes the **global** token. On refusal: counter
   `:rate_limited_global`, `send_rate_limited/1`, halt. (The IP token already spent is the
   caller's own; the refusal is still input-independent.)

Consequence (the D-1 property): a single source flooding at any rate drains only its own IP
bucket; the global bucket is spent only at the rate IP buckets admit (at most
`ip_refill_per_sec` per distinct source after the initial burst), so one source cannot 429 the
platform. A distributed flood (many /64s) can still drain the global bucket; that is the bounded
residual 0042 states ("a botnet can still probe at the global rate"), now not worsened by refused
requests. `consume_email/2` is called by the endpoint after it computes the key; its refusal emits
`:rate_limited_email`. **All refusals (IP, global, email)
use the single `send_rate_limited/1`**, which sets the common security headers, a constant
`Retry-After` (config `retry_after_seconds`, default 60), and
`Response.rate_limited("rate limit exceeded")`; one constructor makes the three byte-identical by
construction, with no email-dependent body or header.

### 12.3 Bounded per-email state

- **Lossless eviction.** A row whose effective tokens have refilled to capacity is
  behaviourally identical to an absent row (an absent key is treated as a full bucket,
  `bucket.ex:66`), so deleting it changes nothing. A periodic `sweep/1` (timer in the owning
  GenServer, `sweep_interval_ms`) deletes exactly those rows. The sweep reads each kind's
  capacity and refill from config.
- **Two key populations, two caps (re-derived for the per-IP-first order, D-1).** With the per-IP
  token consumed *before* the global one (§12.2), IP keys are no longer gated by the global bucket,
  so the earlier single invariant ("every key creation first consumed a global token") no longer
  holds for them. The populations are therefore bounded separately:
  - **Email-kind keys (`:email_hmac`, `:email_send`)** are created only by a request that already
    passed the IP bucket **and** the global bucket (the endpoint consults them after `call/2`
    returns, the send bucket inside the task the endpoint submitted). Each admitted request creates
    at most one `:email_hmac` and one `:email_send` key. Non-idle email-kind keys are thus bounded by
    the global admission rate times the longest full-refill window:
    `max_email_keys >= 2 * (global_capacity + ceil(global_refill_per_sec * (T_email_full_max +
    sweep_interval_s)))`, where `T_email_full_max` is the larger of
    `email_capacity/email_refill` and `send_capacity/send_refill` in seconds (the IP bucket is
    excluded; it is not part of this population). The factor 2 is one request-bucket key plus one
    send key per admitted request. `validate_config!/1` raises at boot (`Bucket.init/1`) when the
    configured values violate it, so this population can never fill with non-evictable rows under
    admitted traffic. With the defaults: `2 * (60 + 10 * (900 + 30)) = 18 720 <= 50 000`.
  - **IP keys** are created by *any* request, admitted or not, so no config relationship can bound
    them: an attacker who controls many source addresses controls the count. A non-idle IP key
    exists only while its bucket has not refilled, i.e. for at most `T_ip_full = ip_capacity /
    ip_refill` seconds (20 s with the defaults) plus one sweep interval, so the count is bounded
    by distinct /64s seen in the last ~50 s. The bound is therefore a hard cap, **`max_ip_keys`**
    (default 100 000, about 10 MB of ETS), enforced by the backstop below. `validate_config!/1`
    checks only that it is positive and not smaller than `ip_capacity`.
- **Backstop (per population).** When creating a *new* key would exceed that population's cap
  (`max_ip_keys` or `max_email_keys`), an inline sweep runs; if still full, the new key is
  **refused** (`:rate_limited`, fail closed). A live key is never evicted, so a victim bucket can
  never be refilled faster than its normal refill. For email-kind keys this refusal is unreachable
  via admitted traffic (the invariant above); it is reachable by a direct test call that bypasses
  the global bucket, which is how REQ-436's "10x the cap never exceeds the cap" test exercises it.
  For IP keys it **is** reachable by a flood from more than `max_ip_keys` distinct /64 networks
  within ~50 s: new, previously unseen sources are then refused (counter `:rate_limited_ip`, with
  the global token **not** consumed, so the refusal cannot drain the global bucket), while sources
  that already hold a bucket are unaffected. That is a deliberate fail-closed bound, stated as an
  accepted residual in 0042 (a flood of that size can already drain the global bucket
  at the global rate, so it adds no new capability to the attacker).
- **Race.** `consume` is a compare-and-swap (a conditional replace of the exact tuple read, bounded
  retries, fail closed on exhaustion) rather than the existing check-then-write
  (`bucket.ex:63-75`), because under-counting lets a small burst through, and for the per-email and
  send buckets that burst is the email-bombing amplification. Not "fixed" with a lock. Insertion of
  a new key uses an insert-if-absent primitive.
- **Multi-node:** the table is per node, as 0028 OQ-4 records for `/api/public`.

### 12.4 Config

`config :letflow, Letflow.Plugs.LoginDiscoveryRateLimit, ...`, code defaults per the
`PublicReadRateLimit` precedent (`public_read_rate_limit.ex:36-41`):

| Key | Default | Meaning |
|---|---|---|
| `global_capacity` / `global_refill_per_sec` | 60 / 10 | tighter than `/api/public`'s 200 / 50 |
| `ip_capacity` / `ip_refill_per_sec` | 10 / 0.5 | |
| `email_capacity` / `email_refill_per_sec` | 5 / 1/60 | per-address request bucket |
| `send_capacity` / `send_refill_per_sec` | 1 / 1/900 | one notifier send per address per 15 minutes |
| `max_email_keys` | 50 000 | must satisfy `2 x (global_capacity + ceil(global_refill x (T_email_full_max + sweep_s)))`; defaults give 2 x (60 + 10 x 930) = 18 720 |
| `max_ip_keys` | 100 000 | hard cap on distinct per-/64 IP rows (§12.3) |
| `sweep_interval_ms` | 30 000 | |
| `retry_after_seconds` | 60 | constant on every 429 |
| `enabled` (on `Letflow.Routers.LoginDiscovery`, §12.6) | `false` in `:prod`, `true` in dev/test | disabled mount returns the route-level 404 |
| `trusted_proxies` (on `Letflow.Plugs.ClientIp`, §12.6) | `[]` | CIDR list of proxies whose `X-Real-IP` is honoured |

`config/test.exs` raises the global and per-IP capacities so the suite's shared node-wide table
does not make unrelated tests flaky; limiter tests override with `Application.put_env` and use
unique documentation-range IPs (the technique `public_read_rate_limit_test.exs` documents).

### 12.5 Relationship to 0040

This limiter does not discharge the deferred `Letflow.Plugs.RateLimit` row
(`api_pipeline.ex:59`) and does not modify `AuthPipeline` or `ApiPipeline` (git diff of
`lib/letflow/plugs/auth_pipeline.ex` and `lib/letflow/plugs/api_pipeline.ex` is empty).

### 12.6 Trusted-proxy client IP (D-2): mechanism, configuration, precondition

**Problem (verified, §0.1).** The only IP the tree reads is `conn.remote_ip`. Behind the real
topology (Cloudflare -> nginx -> published container port -> Bandit) that is the proxy hop, the same
for every visitor, so every user would share one per-IP bucket (10 tokens, 0.5/s) and one visitor
could 429 everyone, and the per-IP bound the Mode B inference rests on would not exist.

**Mechanism.** New mount-agnostic plug `Letflow.Plugs.ClientIp` (REQ-CIP, §15.0):

```
@type cidr :: {:inet.ip_address(), prefix_len :: 0..128}

# Plug
@spec init(keyword()) :: [trusted_proxies: [cidr()]]        # from opts, else app config
@spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()       # assigns :client_ip
# Pure
@spec resolve(peer :: :inet.ip_address(), x_real_ip_values :: [String.t()], [cidr()]) ::
        :inet.ip_address()
@spec parse_cidrs(String.t()) :: {:ok, [cidr()]} | {:error, :invalid_cidr}
@spec trusted?(:inet.ip_address(), [cidr()]) :: boolean()
```

Rules (all fail safe toward the *stricter, shared* bucket, never toward a spoofable one):

1. `conn.assigns.client_ip` is always set. By default it is `conn.remote_ip` (an empty trust list,
   or a peer not in the list: every forwarded header is ignored, today's behaviour exactly).
2. Only when the TCP peer `conn.remote_ip` is inside a configured trusted CIDR is a forwarded
   value honoured, and only the **`X-Real-IP`** header: exactly one header value that parses as a
   single IPv4 or IPv6 address. Zero values, more than one value, a comma list or any parse failure
   -> `client_ip = conn.remote_ip`.
3. **`X-Forwarded-For` is never read.** It is a client-appendable chain; trusting its left side is a
   spoof, and trusting its right side needs the full proxy-hop list. `X-Real-IP` is set (overwritten,
   not appended) by the one proxy we control, so a visitor-supplied `X-Real-IP` is discarded by
   nginx before it reaches the app (`deploy/nginx/letflow-test.conf:23` already sets it).
4. `conn.remote_ip` itself is **not** rewritten: other code (`PublicReadRateLimit`, `/api/public`)
   keeps its current, unchanged behaviour; REQ-CIP does not touch it (its own limitation remains
   0042 OQ-12/OQ-5's tail, noted not fixed).

**Where it is configured (three places, all owned by REQ-CIP).**

| Layer | Setting | File |
|---|---|---|
| Application | env `LETFLOW_TRUSTED_PROXIES`: comma-separated CIDRs (for example the loopback and the Docker network gateway the proxy arrives from); read once at boot into `config :letflow, Letflow.Plugs.ClientIp, trusted_proxies: [cidr]`; an invalid entry raises at boot; unset = `[]` | `config/runtime.exs`, `config/test.exs` (test default `[]`), `deploy/.env.example` (documents the name, no real value) |
| nginx | the visitor address must reach `$remote_addr` before `X-Real-IP` is set: `set_real_ip_from` the Cloudflare edge ranges and `real_ip_header CF-Connecting-IP` (ngx_http_realip_module), keeping the existing `proxy_set_header X-Real-IP $remote_addr` (without this `$remote_addr` is the Cloudflare edge, `letflow-test.conf` has no realip directive, §0.1). Whether Cloudflare sends `CF-Connecting-IP` and its ranges are external knowledge (U3) and must be verified by the REQ-CIP implementer | `deploy/nginx/letflow-test.conf` (QA's vhost is not in this repository, U4: recorded as an infrastructure action in the handoff) |
| Mount switch | `config :letflow, Letflow.Routers.LoginDiscovery, enabled: boolean()`, env `LETFLOW_LOGIN_DISCOVERY_ENABLED` (`true`/`false`; other value raises); default `false` when `config_env() == :prod` | `config/runtime.exs`, `config/config.exs` |

**Precondition for enabling the flag, enforced mechanically on the server.** `config/runtime.exs`
raises at boot when `config_env() == :prod`, `LETFLOW_LOGIN_DISCOVERY_ENABLED` is true and
`LETFLOW_TRUSTED_PROXIES` is empty or unset (message names both variables, no values). Outside
`:prod`, the same combination logs one fixed warning at boot. The SPA flag `VITE_EMAIL_FIRST_LOGIN`
cannot be checked by the server, so the broader precondition list is in §11.3. A disabled mount
returns the route-level `404` for every request (§5.1), so the SPA built with the flag on against a
backend that has not enabled the mount lands in its malformed-response state, not in a lockout.

**Residuals.** (1) If the proxy is mis-trusted (a CIDR too broad, so an untrusted peer can send
`X-Real-IP`), the limiter keys become spoofable; the list is deployment-owned, defaults to empty,
and is reviewed in REQ-CIP's `SECURITY-REVIEWER` pass. (2) Visitors behind one NAT or one /64 share
a bucket; inherent to per-IP limiting. (3) Multi-proxy chains (a second trusted hop) are not
supported: one trusted hop, `X-Real-IP`.

### 12.7 Non-identifying outcome counters (C-1)

So that the Mode A kill switch (0042 Decision 3) can actually be triggered, the discovery path
emits **one telemetry event per request**, `[:letflow, :login_discovery, :outcome]`, with
measurement `%{count: 1}` and a single metadata key `outcome` whose value is exactly one of the
fixed atoms: `:tenant` (the 200 single-match), `:accepted` (the 202 neutral, any cause),
`:rate_limited_ip`, `:rate_limited_global`, `:rate_limited_email`, `:disabled` (the 404 of a
disabled mount, emitted by `enabled_gate/2`, §5.1; **always** emitted, not optional, with the same
single `outcome` metadata key and nothing else), `:not_found` (wrong method or path, enabled
mount only).

- **Non-identifying (INV-4):** the metadata carries no email, key, IP address, slug, tenant id or
  count; the 202 is deliberately *not* split into multi/unknown/failed, because that split would
  correlate a counter with an address class. The limiter emits the three `:rate_limited_*`
  outcomes; the endpoint emits `:tenant`, `:accepted` and `:not_found`; the gate emits `:disabled`.
- **Use:** the ratio `:tenant` / total and the `:rate_limited_*` rates are the abuse signals an
  operator watches (a sudden rise in `:tenant` or in `:rate_limited_ip`) to decide to set
  `LETFLOW_LOGIN_DISCOVERY_MODE=uniform_plus_email`. How those events reach `/metrics` follows the
  existing `Letflow.Metrics.Registry` / `HttpMetrics` pattern (`router.ex:95-98`), chosen by the
  implementer and reported in the handoff; if no registry hook fits, the telemetry events alone
  satisfy this requirement and the gap is recorded rather than skipped.
- The HTTP responses are unchanged: the 429 stays byte-identical across causes; only the *internal*
  counter label differs.

### 12.8 Accepted residual: a targeted per-email lockout (C-2)

The per-email bucket (`email_capacity` 5, refill 1 per 60 s) is keyed on the HMAC of an address the
caller supplies, so an attacker who knows a victim's address can send requests (from any IPs)
that keep that address's bucket empty at a cost of about one request per minute, so the victim's
own email-first attempt receives a `429`. **Accepted, recorded in 0042**, because the alternative
(no per-address bucket) removes the email-bombing control of RQ-6. Mitigations that make it
bounded rather than a denial of login: (a) it affects only that address, only on the email-first
path; (b) the SPA's 429 state offers the organisation-code (`?realm=`) route, which bypasses
discovery (§11.5); (c) `?realm=` and the stored slug (ranks 1-2, §11.1) never touch the route;
(d) the `:rate_limited_email` counter makes sustained targeting visible (§12.7). It does not
disclose whether the address exists (the 429 is identical for known and unknown addresses).

---

## 13. Notifier port

```
# Letflow.LoginDiscovery.Notifier  (behaviour)
@callback deliver_tenant_list(
            recipient_email :: String.t(),
            tenants :: [Letflow.LoginDirectory.tenant_ref(), ...]
          ) :: :ok | {:error, term()}

# Letflow.LoginDiscovery.Dispatch
@spec submit(recipient_email :: String.t() | nil, mode :: mode(),
             result :: {:ok, [tenant_ref()]} | {:error, :lookup_failed}) :: :ok
```

- `recipient_email` is the **normalised address the caller typed in this request**, never a stored
  value (the directory stores none), and is held only in the task's memory.
- **Always one submission per request** (§5.3 step 7): `submit/3` always calls
  `Task.Supervisor.start_child/2` on `Letflow.LoginDiscovery.TaskSupervisor`; the task decides
  inside whether anything is to be delivered (`delivery/2`, §7) and, if so, first consumes the
  per-address `:send` bucket (a refusal skips the send silently). The request process never
  awaits it. `start_child` returning `{:error, _}` (for example the supervisor's `max_children`
  cap, config `max_concurrent`, default 100) or exiting is ignored. So request timing does not
  depend on a match or on mail latency.
- **Isolation (INV-8):** the adapter runs under `try`/`rescue`/`catch` and a hard timeout
  (`timeout_ms`, default 5000, via an inner task that is killed on expiry); a raise, exit or
  timeout is dropped with a fixed log line containing no email, tenant, slug or exception text.
- **Function-form `start_child`, never MFA with arguments (C-4).** OTP/Elixir crash reports for a
  task print the started function **and its arguments** (`Function: {M, F, A}` / `Args: [...]`).
  `submit/3` and the inner timeout task therefore always use `Task.Supervisor.start_child(sup,
  fun)` with a zero-arity closure, **never** `start_child(sup, module, function, [email, ...])` or
  any form that places the recipient, tenant list or key in an argument list. The closure body
  calls the adapter and runs under the `try`/`rescue`/`catch` above, so a crash that is not caught
  (for example a kill from the timeout) prints only the function reference. The same rule binds the
  `Bucket` sweep timer and any other process started on this path: no process on the discovery path
  is started with the email as an MFA argument. A structural test greps `lib/letflow/login_discovery/`
  for `start_child`/`Task.start`/`spawn` calls with a non-closure form. **Raise test:** the
  notifier double is set to raise (and, separately, to exit and to sleep past `timeout_ms`) with
  the typed email in the exception message and in its own state; under `capture_log(level: :debug)`
  the complete captured output (including any task crash report) is asserted to contain **neither**
  the email nor its lowercase form; the request response is unchanged and the request process is
  alive.
- **Default adapter** `Letflow.LoginDiscovery.Notifier.Noop`: delivers nothing, returns `:ok`, and
  emits only a non-identifying counter or fixed log line. Config:
  `config :letflow, Letflow.LoginDiscovery.Notifier, adapter: ..., timeout_ms: ..., max_concurrent: ...`.
  A **test double** (`test/support/`) records `(email, tenants)` calls and can be set to raise,
  exit, or sleep.
- **Message contract for any real adapter:** fixed template; the only request-derived text is the
  recipient address; slugs and display names appear as plain text; any link is built from a
  deployment base URL, never from tenant text (INV-9). The real SMTP/mail adapter is **not** built
  here (0042 OQ-4); until it exists, delivering paths degrade to the neutral response.
- **Supervision:** one new dedicated `Task.Supervisor`, `Letflow.LoginDiscovery.TaskSupervisor`,
  added to `Letflow.Supervisor.Infrastructure` before its last child (`Obs.Alerts.TaskSupervisor`
  must stay last, `infrastructure.ex:318-329`), following the REQ-220 "one dedicated
  `Task.Supervisor` per subsystem" convention. The REQ-436 `Bucket` GenServer is a second new
  child (placed beside `PublicReadRateLimit.Bucket`, `infrastructure.ex:229`).

---

## 14. (j) Mobile NOTE and (k) future NOTE (recorded, not specified)

- **(j) Mobile tier NOTE.** The mobile bootstrap resolves the tenant from a deep-link subdomain
  or manual slug entry (`docs/mobile/requirements.md` MOB-2, `:50-`; REQ-421; REQ-124's
  `/api/mobile/tenant-config`, `router.ex:118`) and is **unaffected**. The new endpoint is
  additive and unauthenticated, so a later mobile requirement may adopt it in place of manual slug
  entry. Constraint recorded now: neither the endpoint nor its response may assume a browser (JSON
  only, no cookies, no `Location` redirects, no HTML, no dependence on `Origin` or CORS for
  correctness). `docs/mobile/` is not edited here, and no mobile behaviour is specified.
- **(k) Future, explicitly out of scope.** SSO across realms or a single identity spanning
  tenants (0006 D1 and 0038 keep one account per realm); a platform-level Keycloak broker realm
  (hence `kc_idp_hint` unused); migration to Keycloak Organizations (0042 OQ-2). Not specified.

---

## 15. Per-requirement work packages

The shared rule for all four: where the requirement text and this design differ, this design
governs and the difference is flagged to `REQ-VALIDATOR` (§0.3), not silently resolved.

### 15.0 REQ-CIP -- trusted-proxy client IP (owner `ELIXIR-DEV`; NEW, working name; `depends_on` of REQ-436 and REQ-437)

Id assigned by `REQ-ANALYST`; `docs/requirements.yaml` is amended by `ORCH`/`REQ-ANALYST`, not in
this change (§0.3 D11). Proposed `depends_on: [REQ-434]`; REQ-436 gains `REQ-CIP`; REQ-437 gains
`REQ-CIP` (and keeps `REQ-435`, `REQ-436`). Mandatory `SECURITY-REVIEWER` gate (INV-4/INV-5:
spoofable limiter key). Spec: §12.6.

**Create:** `lib/letflow/plugs/client_ip.ex` (plug, `resolve/3`, `parse_cidrs/1`, `trusted?/2`;
no new dependency, CIDR matching is a small pure function over `:inet`);
`test/letflow/plugs/client_ip_test.exs`;
`test/letflow/client_ip_runtime_config_test.exs` (env parsing, modelled on
`secrets_runtime_config_test.exs`).

**Change:** `config/runtime.exs` (`LETFLOW_TRUSTED_PROXIES`, `LETFLOW_LOGIN_DISCOVERY_ENABLED`, the
`:prod` boot refusal), `config/config.exs` (`enabled` default), `config/test.exs`,
`deploy/.env.example` (names only), `deploy/nginx/letflow-test.conf` (realip directives, §12.6);
the QA vhost, which is outside this repository, is recorded in the handoff as an infrastructure
action with the exact directives. **Not changed (git diff empty):** `lib/letflow/plugs/
public_read_rate_limit.ex` and its `bucket.ex`, `auth_pipeline.ex`, `api_pipeline.ex`.

**Tests required:** empty trust list -> `client_ip == conn.remote_ip` whatever `X-Real-IP` and
`X-Forwarded-For` say; peer outside the list sending `X-Real-IP` -> ignored; trusted peer with a
valid single `X-Real-IP` (v4 and v6) -> that address; trusted peer with no, two, comma-list or
unparsable `X-Real-IP` -> `remote_ip`; `X-Forwarded-For` never changes the result in any
combination; CIDR matching table (v4/v6 boundaries, /0, /32, /128, v4-mapped); `parse_cidrs/1`
rejects malformed entries; runtime config: unset, valid list, invalid entry raises, mount enabled in
`:prod` with an empty list raises (message names the variables, contains no value), enabled with a
list boots, `:dev`/`:test` with an empty list only warns; the plug reads no body; **an integration
test through the real `Letflow.Routers.LoginDiscovery` chain (after REQ-437) showing two requests
from two different `X-Real-IP` values behind one trusted peer fall into different per-IP buckets**
(placed in REQ-437's list as well); the UAT step on the real host (U3, U4): two real source
addresses, two buckets, and the observed container-side peer address recorded; `mix compile
--warnings-as-errors`, `mix format --check-formatted`, `mix test`, `mix letflow.check_boundaries`.

### 15.1 REQ-435 -- directory data layer, writers, backfill (owner `ELIXIR-DEV`)

**Create**

| File | Purpose |
|---|---|
| `priv/repo/migrations/<timestamp later than 20261003000001>_create_tenant_login_directory.exs` | §1.1; public schema only; reversible |
| `lib/letflow/identity/tenant_login_directory_entry.ex` | §1.2 schema |
| `lib/letflow/login_directory.ex` | `Letflow.LoginDirectory` context: `email_key/1`, `sentinel_key/0`, `lookup_by_key/1`, `lookup_by_email/1`, `upsert_entry/2`, `remove_entry_if_unreferenced/3`, `plan_user_change/2`, `apply_plan/3` |
| `lib/letflow/login_directory/backfill.ex` | §4 |
| `lib/mix/tasks/letflow.backfill_login_directory.ex` | §4 |
| `test/letflow/login_directory_test.exs` | key form, lookup, isolation, FK cascade, query count |
| `test/letflow/login_directory/plan_user_change_test.exs` | every row of §3.3 as a pure test |
| `test/letflow/login_directory/backfill_test.exs` | idempotency, dry-run, failure isolation, no-email output |
| `test/mix/tasks/letflow.backfill_login_directory_test.exs` | task output, non-zero exit on failure |
| `test/letflow/login_directory_runtime_config_test.exs` | pepper boot checks, modelled on `secrets_runtime_config_test.exs` |
| additions to `test/letflow/routers/identity_test.exs` and a hooks test file | tenant_id source, same-transaction behaviour |

**Change**

| File | Change |
|---|---|
| `lib/letflow/identity.ex` | `create_user/2`, `update_user_profile/3`, `update_user_status/3`: required `:tenant_id`, guard, `:login_directory` Multi step, in-transaction locked pre-read for the two update functions; `insert_or_fetch/4`: transaction wrapper (§3.5); new error shapes in the `@spec`s; moduledoc |
| `lib/letflow/identity/tenant_membership.ex` | export `email_shape?/1`; `validate_email_shape/2` calls it; behaviour unchanged |
| `lib/letflow/routers/identity.ex` | the three handlers pass `:tenant_id` from `conn.assigns.auth_context.tenant_id`; new `case` arms (§3.2) |
| `lib/mix/tasks/letflow.seed.exam_fixtures.ex` (`:237`) | pass the resolved tenant's id |
| `test/support/simulation/seed.ex` (`:192`) | pass `tenant_id` or `login_directory: :skip` |
| `test/letflow/audit_dispositions_test.exs` (12 call sites), `test/letflow/entities/query_cursor_field_grants_test.exs`, `test/letflow/entities/query_joins_test.exs`, `test/letflow/plugs/iss0736_oidc_live_revocation_test.exs`, `test/letflow/routers/instances_test.exs`, `test/letflow/routers/me_test.exs` (2) | every caller passes `:tenant_id`, or `login_directory: :skip` where the fixture prefix has no `tenants` row; **a grep of `lib/` and `test/` for the three functions is quoted in the handoff** |
| `config/runtime.exs`, `config/test.exs`, `.env.example` | pepper (§2.2) |

**Tests required** (each maps to a REQ-435 acceptance criterion; additionally: a JIT
username-race test, run with the directory hook enabled, in which a competing identity or the
same identity already holds the `username`, asserting no "current transaction is aborted" error,
`created: false` and no directory entry for the same-identity loser, the original changeset error
and no entry for a different-identity collision, and the transaction still committing the
winner-less path cleanly; plus guard tests for malformed `tenant_id` -> `:invalid_tenant_id` and
valid-but-mismatched id -> `:tenant_prefix_mismatch`, §3.2): migration up/down and
public-only (information_schema query); create via POST `/api/v1/users` writes one entry for
`('Alice@Example.com ')` in the same transaction, and a forced audit failure leaves neither user
nor entry (technique of `audit_dispositions_test.exs:526-610`); tenant-id source with two tenants
and a body/query `tenant_id` that changes nothing; JIT adds on first login and none on the second;
status change to inactive removes inside its own transaction and a forced failure after the status
write leaves both unchanged; no-email/invalid-email writes nothing; the other-active-user rule
(U1/U2 scenario and the profile email-change scenario); the same email in tenants A and B yields
two entries, `lookup_by_email/1` returns them in deterministic order, excludes `:inactive`,
`:migrating` and unbound-realm tenants, in exactly one query (telemetry); cross-tenant isolation
and no user/credential field in the schema or returned structs; HMAC key never equals the
plaintext and differs under a different pepper, and normalisation equivalence (`'A@X.com '` and
`'a@x.com'` collide); pepper boot checks (absent, malformed, trivial, equal to master key);
`plan_user_change/2` table; **concurrency**: concurrent deactivation of two same-email users ends
with the entry removed, and concurrent create-versus-deactivate keeps the entry (the harness must
exercise real cross-connection locking; if the SQL sandbox cannot, `TEST-DESIGNER` records the
gap rather than skipping silently); backfill idempotency with three tenants and overlapping
emails (second run inserts 0, row set identical, inactive users yield no row, `--dry-run` inserts
nothing and prints counts, a tenant whose read raises is reported-and-skipped, an `:inactive`
tenant's users are included); FK cascade; **query logging (D-3, §3.9): every `Repo` call in the
directory modules carries `log: false` (grep guard), and a `capture_log(level: :debug)` test over
create, email-change, deactivation (the removal query), JIT first login and a backfill run finds
neither the plaintext email, its lowercase form, nor the hex/base64 of its `email_key`; a
test also asserts the query-count telemetry still fires with `log: false`;** captured-Logger and
task-output grep finds no email (INV-4); `grep` shows no string-built SQL (INV-7); `login_directory: :skip` appears only under
`test/`; `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test` and
`mix letflow.check_boundaries` pass.

### 15.2 REQ-436 -- limiter (owner `ELIXIR-DEV`)

**Dependencies (D-2):** `depends_on` gains `REQ-CIP` (§15.0); the plug reads the client address
from `conn.assigns.client_ip` and falls back to `conn.remote_ip`, so the module is testable with the
stub router alone, but it must not ship ahead of REQ-CIP.

**Create:** `lib/letflow/plugs/login_discovery_rate_limit.ex`;
`lib/letflow/plugs/login_discovery_rate_limit/bucket.ex`;
`test/letflow/plugs/login_discovery_rate_limit_test.exs`;
`test/letflow/plugs/login_discovery_rate_limit/bucket_test.exs`;
`test/support/login_discovery_probe_router.ex` (a minimal stub `Plug.Router` with `ClientIp` and
then the plug first, because REQ-437's real router does not exist yet; REQ-437 re-asserts the real
chain).

**Change:** `lib/letflow/supervisor/infrastructure.ex` (new `Bucket` child beside `:229`; moduledoc
child list) and `test/letflow/supervisor/infrastructure_test.exs` (child count `20` -> `21` and
the order assertion, `:70`, `:117`); `config/test.exs` (suite-friendly capacities).
**Not changed (git diff empty):** `lib/letflow/plugs/auth_pipeline.ex`,
`lib/letflow/plugs/api_pipeline.ex`, `lib/letflow/plugs/public_read_rate_limit.ex`,
`lib/letflow/plugs/public_read_rate_limit/bucket.ex`.

**Tests required:** every ETS key written begins with `:login_discovery` and the existing
`/api/public` keys and table are untouched; **independence both ways** (flood the login-discovery
global bucket -> a `/api/public` request is not 429; flood `/api/public`'s global bucket -> the
login-discovery stub still serves; the same for per-IP with one IP); the `(ip_capacity+1)`th
request from one client address returns 429, a spoofed `X-Forwarded-For` does not change the key
(only `conn.assigns.client_ip` does), the global bucket trips independently of any *single* IP
(driven from many distinct addresses); **ordering (D-1): a single IP sending 10 x
`global_capacity` requests is refused after its own `ip_capacity` and leaves the global bucket
with at least `global_capacity - ip_capacity` tokens (assert the global token count directly), a
second address is still admitted afterwards, and `:ets.info`/`size/1` shows no global token was
consumed by an IP-refused request; the flood never produces a `:rate_limited_global`
outcome for the second address; IPv6: addresses sharing a /64 share one bucket, addresses in
different /64s do not, an IPv4-mapped IPv6 address maps to the same bucket as its IPv4 form
(`ip_bucket_id/1` table test); `max_ip_keys`: distinct-/64 requests beyond the cap are refused
without consuming a global token and without evicting existing keys, existing sources are
unaffected; `max_email_keys`: `validate_config!/1` accepts the defaults and rejects a
configuration violating `2 x (global_capacity + ceil(global_refill x (T_email_full_max +
sweep_s)))`; counters (C-1): each refusal emits exactly one `[:letflow, :login_discovery,
:outcome]` event with `outcome` `:rate_limited_ip`/`:rate_limited_global`/`:rate_limited_email`
and no other metadata (no email, key, IP);** **the 429 status, headers and body are byte-identical
for IP, global and per-email refusals** and do not depend on the email; the plug refuses before
the body is read (an invalid or unreadable body still gets 429); bounded state (10x `max_keys`
distinct per-email keys never exceed `max_keys`, `:ets.info`-based count; a hot key keeps being
limited after unrelated keys became idle and were swept, using the injectable clock; a non-idle
key is never evicted); the sweep is lossless (a swept key behaves as a fresh bucket); `consume`
never admits more than `capacity` under N concurrent callers (the compare-and-swap property); the
Nth request for one address across different IPs trips the per-email bucket and a different
address is unaffected; `validate_config!/1` rejects a configuration that violates the §12.3
invariant; the `:send` kind has an independent bucket; no email, key or IP in captured Logger
output; `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test` and
`mix letflow.check_boundaries` pass.

### 15.3 REQ-437 -- endpoint, mode logic, notifier port (owner `ELIXIR-DEV`)

**Create:** `lib/letflow/routers/login_discovery.ex`; `lib/letflow/login_discovery.ex` (`mode/0`,
`decide/2`, `delivery/2`); `lib/letflow/login_discovery/notifier.ex` (behaviour);
`lib/letflow/login_discovery/notifier/noop.ex`; `lib/letflow/login_discovery/dispatch.ex`;
`test/support/login_discovery_notifier_double.ex`;
`test/letflow/routers/login_discovery_test.exs` (the §10 matrices, both modes);
`test/letflow/login_discovery_test.exs` (pure `decide/2`/`delivery/2` tables);
`test/letflow/login_discovery/dispatch_test.exs` (notifier failure isolation);
`test/letflow/routers/login_discovery_timing_test.exs` (tagged sanity bound).

**Dependencies (D-2):** `depends_on` gains `REQ-CIP` (§15.0); the router's chain starts with
`Letflow.Plugs.ClientIp` (§5.1); the route is **disabled by default in `:prod`** and the boot-time
refusal of §12.6 applies. Emits the C-1 counters for `:tenant`, `:accepted`, `:not_found` and (from `enabled_gate/2`, defined in `lib/letflow/routers/login_discovery.ex`, §5.1) `:disabled` (§12.7).

**Change:** `lib/letflow/router.ex` (forward and route-table row); `lib/letflow/supervisor/infrastructure.ex`
(`Letflow.LoginDiscovery.TaskSupervisor`, before the last child) and
`test/letflow/supervisor/infrastructure_test.exs` (count `21` -> `22`);
`config/config.exs` (mode default `:redirect_single`, notifier adapter `Noop`),
`config/runtime.exs` (`LETFLOW_LOGIN_DISCOVERY_MODE`, boot validation), `config/test.exs` (double
adapter). **No** OpenAPI file exists to change (D7); the handoff records that fact.
`lib/letflow/plugs/auth_pipeline.ex` is **not** modified (git diff empty).

**Tests required:** Mode A byte-comparison across known-single, known-multi and unknown (same
status, same Content-Type, byte-identical bodies); Mode B single-match returns exactly the keys
`result`, `tenant.slug`, `tenant.display_name` and nothing else, multi and unknown are
byte-identical neutral, the double records exactly one delivery for multi and zero for unknown;
the malformed inputs (missing email, non-string, empty, 10 000-character, no `@`, wrong content
type, invalid JSON, oversize body) all return the neutral response, identical in status and bytes
to unknown, never a 500, in both modes; an inactive-tenant-only address is byte-identical to
unknown in both modes, and active-plus-inactive behaves as active-only; **structural timing**:
exactly one `Repo` query per request (telemetry) for matched, unmatched, inactive and malformed
input, no path returning before that query, a notifier double that sleeps 2 s does not delay the
response; sanity timing per §10.3 (tagged); cross-tenant isolation (no query on the path carries a
tenant `:prefix`; the route touches only `tenant_login_directory` and `tenants`); no input produces
401 or 403 (enumeration over the §10 classes); router plug-order proof by behaviour (a
rate-limited request returns 429 even with an invalid body; the 429 equals REQ-436's bytes);
notifier raise, exit and timeout leave the HTTP response unchanged and the request process alive,
**and (C-4, §13) with the typed email in the raised message and the double's state, the full
`capture_log(level: :debug)` output, including the task crash report, contains no email; a grep
guard shows no `start_child`/`Task.start`/`spawn` with an MFA or argument-list form under
`lib/letflow/login_discovery/`;**
the default adapter delivers nothing and logs no email or tenant name; no email address and no raw
body in captured Logger output, **captured at `level: :debug` over known, unknown, multi and
malformed requests, and no `email_key` hex/base64 either (D-3, §3.9); every `Repo` call in
`lookup_by_key/1` carries `log: false`;** **outcome counters (C-1, §12.7): exactly one
`[:letflow, :login_discovery, :outcome]` event per request with `:tenant` for the Mode B
single-match, `:accepted` for every 202 (known, multi, unknown, malformed, failure alike, so the
event does not split them), `:not_found` for a wrong method/path, and metadata containing only
`outcome`; the mount switch (D12): with `enabled: false` every method/path returns the standard 404
(byte-identical to the router catch-all), issues zero queries, never invokes `ClientIp` or the
limiter (no limiter state created), and emits exactly one `:disabled` outcome event whose metadata
is only `outcome`; toggling `enabled` at runtime in the test needs no recompile; the client-IP integration test of §15.0 (two `X-Real-IP` values behind a
trusted peer land in two per-IP buckets; with an empty trust list a spoofed `X-Real-IP` changes
nothing);** the `depends_on` of REQ-437 contains `REQ-CIP` (§0.3 D11); `mix compile --warnings-as-errors`, `mix format --check-formatted`,
`mix test` and `mix letflow.check_boundaries` pass; the `SECURITY-REVIEWER` verdict is recorded
against INV-1, INV-2, INV-4, INV-5, INV-6, INV-8, INV-9 (and INV-7 for the touched SQL).

### 15.4 REQ-438 -- SPA email-first page (owner `FRONTEND-DEV`)

**Create:** `web/src/pages/LoginPage.tsx` (route `/login`);
`web/src/api/loginDiscovery.ts` (typed client beside `memberships.ts`, closed response union);
`web/src/auth/emailFirstFlag.ts` (`isEmailFirstLoginEnabled()`);
`web/src/i18n/loginMessages.ts` and a page-local intl provider (en/ru/kk);
tests: `web/src/pages/__tests__/LoginPage.test.tsx`, `web/src/auth/__tests__/ProtectedRoute.emailFirst.test.tsx`,
`web/src/auth/__tests__/precedence.test.ts`, `web/src/api/__tests__/loginDiscovery.test.ts`,
`web/src/__tests__/login-i18n-grep.test.ts` (in the style of `entities-i18n-grep.test.ts`, fails
on a seeded hardcoded string and passes on the real page), and a Playwright path under
`web/tests/e2e/` for the real flow.

**Change:** `web/src/router.tsx` (public `/login` beside `/auth/callback`);
`web/src/auth/ProtectedRoute.tsx` (§11.4 table);
`web/src/auth/tenantConfig.ts` (`resolveRealmFromUrl` order, §11.2);
`web/src/auth/oidcRedirectArgs.ts` (optional `loginHint`, §8.1);
`web/src/auth/AuthProvider.tsx` (session-expired no-realm branch only, §11.4).
**Not touched:** anything under `lib/`, `priv/`, `apps/` (git diff empty).

**Tests required:** flag on with no `?realm=` and no stored slug renders the email-first page and
makes zero `signinRedirect` calls; the precedence table, one test per row (`?realm=a` with stored
`b` -> redirect for `a`, stored value updated to `a`, no email-first page; stored only -> redirect
for it; `?realm=` only -> as before; neither -> email-first page; flag off and neither -> today's
default-realm redirect); the existing `ProtectedRoute`, `buildRedirectArgs`, `tenantConfig` and
`AuthProvider.logout-clears-realm` tests pass **unmodified**; a mocked single-tenant response
stores `bpm_realm_slug`, then calls the **per-slug** manager's `signinRedirect` once with
`redirect_uri` containing `?realm=<slug>` and `login_hint` equal to the typed email, and the page
has zero `input[type=password]`; an unknown-address response and a multi-tenant response render
identical neutral DOM (snapshot equality); network failure, 429 and malformed response each render
a distinct non-leaking error state with retry, and the 429 does not reveal whether the address is
known; **(C-2, §11.5) the 429, network-failure and malformed-response states each offer the
organisation-code control, and submitting a code navigates to `/?realm=<url-encoded code>` with no
discovery call; the control is present in the idle and neutral states too, and the neutral DOM for
an unknown and a multi-tenant address remains identical (snapshot equality, control included);** the pre-redirect path (for example `/instances/123?tab=x`) survives the email-first page
and is restored after login, an unsafe path is dropped (`isSafeRestorePath`); the i18n-grep test;
a session pre-restored by `tryRestoreE2eSession` never reaches the redirect branch; `cd web &&
npm run check` passes; the real-flow e2e against a Keycloak with two tenants' realms shows a
bilimbaga user arriving at the bilimbaga realm login with the username pre-filled (or the infra
gap is recorded as a blocker, as ISS-0727 was). A UAT scenario fixture is added only if it
satisfies `mix letflow.check_uat_scenario_schema`, otherwise the gap is recorded.

---

## 16. Traceability: REQ-434 acceptance criteria and description items

| Criterion / item | Where satisfied |
|---|---|
| 0042 exists, Status `decided`, "Amends" names 0006 §3.3/§7 item 3, 0038 "What remains foreclosed", 0035's observation, each quoted with what remains unchanged | 0042 "Amends" |
| 0042 "Standing prohibitions" (AuthPipeline, `/api/public`, separate mount, closed response, no bulk, no 401/403) | 0042 "Standing prohibitions" 1-6 |
| 0042 "Accepted bounded inference": learnable, not learnable, 0040 relation, 0028 §6 as limiter precedent | 0042 "Accepted bounded inference" |
| Design exists and specifies (a)-(l), citations, zero implementation code | this file; §0.1 ledger; §1 (a), §2 (b), §3 (c), §4 (d), §5 (e), §6 (f), §7 (g), §8 (h), §9 (i), §14 (j)(k), §11 (l) |
| INV table for INV-1, 2, 4, 5, 6, 7, 8, 9; INV-3 does not apply | §9 |
| Response-equivalence matrix (known single, known multi, unknown, malformed, inactive-only, active-plus-inactive) with status, body and timing envelope per mode | §10 |
| Files and tests for REQ-435/436/437/438; mobile and future NOTEs recorded without specifying | §15; §14 |
| Verdicts by CODE-DESIGN-VALIDATOR, SECURITY-REVIEWER, REVIEWER; each open question answered or carried | 0042 "Answers to REQ-434's open questions", "Open questions this record does not answer", "Sign-off" (re-run after rework 2) |
| Rework 2 map: D-1 -> §12.2, §12.3, §12.4, §15.2; D-2 -> §0.1, §12.6, §15.0, §11.3, §0.3 D11; D-3 -> §3.9, §9 INV-4, §15.1, §15.3; C-1 -> §12.7; C-2 -> §12.8, §11.5, §15.4; C-3 -> 0042 prohibition 14; C-4 -> §13, §15.3; C-5 -> §11.3, 0042 OQ-3 | this file and 0042 |
| Diff touches only `docs/migration/decisions/`, `lib/letflow/design/`, requirements bookkeeping | this change adds exactly `docs/migration/decisions/0042-...md` and this file |

Description-item map: (a) §1, (b) §2, (c) §3, (d) §4, (e) §5, (f) §6, (g) §7, (h) §8, (i) §9,
(j) §14, (k) §14, (l) §11. Requirement open questions RQ-1..RQ-7: 0042 answers table.

---

## 17. Open questions (design level; none is silently resolved)

| # | Question | Default adopted for the build | Who ratifies |
|---|---|---|---|
| Q1 | Mode B as the default disclosure mode | `:redirect_single`, switchable to A by config (ratified 2026-10-04; per-tenant selection added by 0043 D-A) | `REVIEWER`, `SECURITY-REVIEWER` |
| Q2 | Pepper by environment variable rather than the `sec://` store | env var, boot-validated (§2.2) | `REVIEWER` |
| Q3 | JIT directory failure aborts the first login (fail closed) versus best-effort after commit | transactional, fail closed (§3.5) | `REVIEWER` |
| Q4 | Backfill iterates all registered tenants, not only active (D3) | all registered | `REQ-VALIDATOR` |
| Q5 | The `:email_send` bucket kind belongs to REQ-436, not REQ-437 (D6) | REQ-436 | `REQ-VALIDATOR` |
| Q6 | Session-expired path (D4) | unchanged with a stored realm; `/login` when none and flag on | `REQ-VALIDATOR`, `FRONTEND-DEV` |
| Q7 | A `--prune` mode for the backfill to remove ghost entries | not built | `REVIEWER` |
| Q8 | Dual-pepper rotation window | not built; rebuild procedure (§2.4). **Amended by 0043 D-C: key id + dual-read now required (REQ-435)** | `ORCH` |
| Q9 | Multi-tenant dead end while no mailer exists (0042 OQ-9): ship an adapter first, add manual organisation-code entry, or both | none in this requirement set | `ORCH`, `REVIEWER` |
| Q10 | Trusted-proxy client IP behind Cloudflare and nginx (0042 OQ-5) | **resolved by design:** new REQ-CIP (§15.0, §12.6), `depends_on` of REQ-436/437, boot refusal in `:prod` without a trust list. Open sub-items: Cloudflare `CF-Connecting-IP`/ranges (U3) and the container-side peer address (U4) are verified by the implementer and UAT; QA's vhost is outside the repo; `ORCH`/`REQ-ANALYST` must register REQ-CIP and amend both `depends_on` lists | `ORCH`, `REQ-VALIDATOR` |
| Q11 | Whether the first-sign-in hand-off through the per-slug manager works end to end (§8.4) | to be proven by REQ-438's real-flow e2e | `FRONTEND-DEV`, `UAT-RUNNER` |
| Q12 | `lower(btrim())` vs Elixir normalisation parity for non-ASCII addresses (§3.6) | accepted limitation | `REVIEWER` |
| Q13 | Human or legal owner and lawful basis for the directory's personal data (0042 OQ-3) | **blocking precondition (C-5):** the flag stays off outside dev until answered (§11.3 item 2); proposed policy owner `ORCH`; the controller is not decidable here and is escalated to the project owner (human); not answerable inside this pipeline | project owner (human), `ORCH` to escalate; `REVIEWER` to confirm it is recorded |
| Q14 | Realm "Login with email" per realm (0042 OQ-8) | checked by `UAT-RUNNER` | `UAT-RUNNER` |
| Q15 | Pre-existing unbounded `{:ip, ip}` growth in the `/api/public` `Bucket` (0042 OQ-12) | not fixed here; to be filed | `ORCH` |
| Q16 | Existing tenant `users` writes and PostgreSQL's own statement log still expose plaintext emails at `:debug`/server level (0042 OQ-13, §3.9) | not changed here; ORCH to file | `ORCH` |
| Q17 | The same global-before-IP ordering exists in `PublicReadRateLimit.call/2` on `/api/public` (§0.1) | not changed here (0042 OQ-12 extended) | `ORCH` |
| Q18 | Accepted residual: targeted per-email lockout (§12.8) and the new-IP refusal at `max_ip_keys` (§12.3) | accepted, mitigated by the organisation-code route and counters | `SECURITY-REVIEWER` (re-run) |

Gate verdicts are recorded in 0042's "Sign-off" section only; this is rework 2 following
`SECURITY-REVIEWER`'s FAIL (D-1, D-2, D-3, C-1..C-5), and the gates re-run.
