# REQ-075 — Identity routes 3/4: tenant administration

**Read this design as higher-risk than REQ-073/074.** These six handlers manage the
`tenants` table itself — the global, single-default-schema registry that IS the
tenant-isolation boundary (`docs/migration/decisions/0003-ecto-schema-strategy.md`
Decision B: schema-per-tenant). REQ-072's `Letflow.Api.Context.scoped_repo_opts/1`
mechanism, which REQ-073/074's every handler threads as `opts` into every
`Letflow.Identity` call, **does not appear anywhere in this design** — there is no
tenant to `:prefix`-scope by, because these handlers decide which tenants exist in
the first place. The only protection is a role check. Get the role check wrong and
the blast radius is every tenant on the platform, not one.

PROVENANCE (historical, not current decision authority):
Ports `src/api/routes/identity.zig`'s `handleCreateTenant` (L222),
`handleListTenants` (L674), `handleGetTenant` (L695), `handlePatchTenant` (L713),
`handleDeactivateTenant` (L822), `handleReactivateTenant` (L851).

No implementation code below — signatures, data shapes, and test specs only.

---

## 0. Summary of composition

| Handler | Method/path | Domain fn(s) called | Auth | Response |
|---|---|---|---|---|
| create | `POST /tenants` | `Identity.create_tenant/1` (NEW, §7.1) → `TenantProvisioning.provision_tenant_schema/1` → `TenantProvisioning.replay_migrations/2` | `:TenantsManage` | 201, `tenant_map/1` |
| list | `GET /tenants` | `Identity.list_tenants/1` (NEW, §7.2) | `:TenantsManage` | 200, `Pagination.Page.t(tenant_map)` |
| get | `GET /tenants/:slug` | `Identity.get_tenant_by_slug/1` (NEW, §7.3) | `:TenantsManage` | 200, `tenant_map/1` |
| patch | `PATCH /tenants/:slug` | `Identity.get_tenant_by_slug/1` then `Identity.patch_tenant/2` (NEW, §7.4) | `:TenantsManage` | 200, `tenant_map/1` |
| deactivate | `POST /tenants/:slug/deactivate` | `Identity.deactivate_tenant/1` (NEW, §7.5) | `:TenantsManage` | 200, `tenant_map/1` |
| reactivate | `POST /tenants/:slug/reactivate` | `Identity.reactivate_tenant/1` (NEW, §7.5) | `:TenantsManage` | 200, `tenant_map/1` |

All six resolve **one** new `endpoint_policy_key` — `:TenantsManage` — gated by
**one** new `permission` — also named `:TenantsManage` — granted to `PLATFORM_ADMIN`
only (§1). None of the six domain functions takes an `opts`/`:prefix` parameter:
`tenants` lives in the Postgres default schema, not inside any tenant's own schema,
so there is nothing to `:prefix`-scope.

---

## 1. The authorization model (AC1, AC6)

### 1.1 Mechanism: reuse `evaluate_access/2`, gated through the permission matrix — do not bypass it

The requirement's own background note floats "a bare role-check, not the permission-key
abstraction" as a possibility. This design does **not** take that path. Instead:

1. Add one permission to `Letflow.Api.Authorization.@permissions` / `@type permission`:
   `:TenantsManage`.
2. Add one endpoint-policy key to `@type endpoint_policy_key`: `:TenantsManage`
   (same atom name as the permission — matching the existing precedent where
   `:MetricsRead`, `:AuditRead` etc. reuse the same name for both when there's a
   1:1 mapping; `:UsersManage`/`:GroupsManage` are the counter-example precedent
   where policy key and permission differ, both fine, this design picks the
   simpler 1:1 form since there's no reason for two names here).
3. Add six `endpoint_policy_key/2` clauses (all method/path pairs below) all
   `-> :TenantsManage`.
4. Add one `required_permission/1` clause: `def required_permission(:TenantsManage), do: :TenantsManage`.
5. Add **no** clause for `:TenantsManage` to `role_allows?/2` for
   `:PROCESS_DESIGNER`, `:PROCESS_OPERATOR`, `:TASK_WORKER`, or `:AGENT_RUNNER` —
   each of those clauses is a closed `permission in [...]` list; a permission atom
   not in the list is `false` by construction, no code change needed to exclude it.
   `role_allows?(:PLATFORM_ADMIN, _permission)` already returns `true`
   unconditionally (existing clause, `authorization.ex:347`) — so `:TenantsManage`
   is granted to `PLATFORM_ADMIN` for free and denied to every other role for free,
   through the **existing** matrix mechanism, no new branch/bypass required.

This is why the design does not need a new "bare role check": routing a new
permission through the existing matrix, with zero role clauses added anywhere
except `PLATFORM_ADMIN`'s pre-existing catch-all, produces exactly "PLATFORM_ADMIN
only, everyone else denied" — the same guarantee a hand-written
`actor.role == :PLATFORM_ADMIN` check would give, but consistent with
REQ-073/074's established pattern and auditable in the same matrix table a future
reader already knows to check.

New `endpoint_policy_key/2` clauses (path relative to this router's own mount —
see §2 for where that is):

```
def endpoint_policy_key("POST", "/tenants"), do: :TenantsManage
def endpoint_policy_key("GET", path) when path in ["/tenants", "/tenants/:slug"],
  do: :TenantsManage
def endpoint_policy_key("PATCH", "/tenants/:slug"), do: :TenantsManage
def endpoint_policy_key("POST", "/tenants/:slug/deactivate"), do: :TenantsManage
def endpoint_policy_key("POST", "/tenants/:slug/reactivate"), do: :TenantsManage
```

### 1.2 R-Co's own route table hardcodes the actor role — this is NOT ported (flagged, not silently fixed)

PROVENANCE (historical, not current decision authority):
Checked `src/main.zig`'s live route table (per REQ-073/074's own precedent of
verifying against the route table, not just the handler file), specifically the
`resource == "tenants"` branch (`main.zig:1489-1533`) and the sibling
`resource == "users"` branch. **Both hardcode `actor.role = .PLATFORM_ADMIN`
unconditionally**, regardless of the real caller:

```zig
const actor = api_auth.AuthContext{
    .user_id = user_id,
    .role = .PLATFORM_ADMIN,     // <-- hardcoded, not derived from the real caller
    .is_bootstrap = false,
    .token_id = user_id,
    .principal = user_id,
};
```

PROVENANCE (historical, not current decision authority):
`user_id` itself is read from an unauthenticated `X-Bpm-User-Id` request header
(`main.zig:302`), defaulting to the all-zero UUID if absent. So in R-Co's actual
shipped route table, every one of `identity_service.getTenantAdmin`'s/
`patchTenant`'s/etc. internal `if (actor.role != .PLATFORM_ADMIN) return
error.Forbidden` checks is **dead code on this call path** — `actor.role` is
always `.PLATFORM_ADMIN` by the time it reaches them, by construction, no matter
who the real caller is. This is very likely a legacy/scaffolding gap in R-Co
(predating its own OIDC/Keycloak layer), not a pattern with any security intent
behind it.

PROVENANCE (historical, not current decision authority):
**This is not ported.** Letflow's real gate must derive the caller's actual role
from `conn.assigns[:auth_context][:roles]` (populated by `Letflow.Plugs.AuthPipeline`
from the verified bearer token's claims, per REQ-069/REQ-021), on every request, and
enforce PLATFORM_ADMIN via `evaluate_access/2` exactly as §1.1 specifies — never a
hardcoded or defaulted role. Flagging this explicitly so it is understood as a
deliberate hardening over R-Co's actual behavior, not an oversight if a reviewer
diffs handler bodies against `identity.zig` and finds the internal role checks
"redundant" with this design's route-level gate — they are not redundant in
Letflow, because Letflow's route-level gate is real.

### 1.3 AC1's exact demand: zero tenant data in a non-admin's list response

`Letflow.Api.Response.forbidden/2` takes `(conn, detail :: String.t())` — `detail`
is entirely caller-chosen (`lib/letflow/api/response.ex:131-132`); nothing about its
signature could ever leak query results by accident. The actual guarantee AC1 needs
is **ordering**, not the response helper's shape: the list handler must call
`Authorization.evaluate_access/2` and branch to `Response.forbidden/2` **before**
calling `Identity.list_tenants/1` (or any other DB read) at all — matching
REQ-073 §2's "no `Repo` call of any kind before this point or after this branch"
discipline exactly. `detail` for this handler is a fixed literal string
(`"insufficient permissions"`, matching REQ-073/074's own literal), never built
from anything request- or query-derived.

Response shapes, stated explicitly so "zero tenant data" is checkable byte-for-byte:

```
Non-admin, GET /tenants:
  403, Content-Type: application/problem+json
  body: {"type": "...", "title": "Forbidden", "status": 403,
         "detail": "insufficient permissions", "trace_id": "..."}
  (Letflow.Api.Error's problem-document shape — see Letflow.Api.Error's own
  moduledoc for the exact field set; no "items"/"count"/"next_cursor" key, no
  tenant object, anywhere in this body, for any caller, on any of the six routes.)

PLATFORM_ADMIN, GET /tenants:
  200, Content-Type: application/json
  body: {"items": [tenant_map(t) | t <- tenants], "next_cursor": "..." | null, "count": N}
```

The test for AC1 (§6.2 below) asserts the **full** non-admin response body against
the exact problem-document literal above (modulo `trace_id`, pinned per REQ-073's own
test-helper convention) — not merely `resp.status == 403` — so a future accidental
change that starts including `"count"` or partial tenant data in a 403 body would fail
this test immediately.

---

## 2. Route wiring — new module `lib/letflow/routers/tenants.ex`

PROVENANCE (historical, not current decision authority):
**Not added to `Letflow.Routers.Identity`.** R-Co's own route table treats `tenants`
as a top-level resource (`resource == "tenants"`, `main.zig:1489`), a sibling of
`users`/`groups`/`identity`, not nested under it — and semantically these six
handlers operate on the platform's tenant registry, categorically different from
`Letflow.Routers.Identity`'s per-tenant user/group management. A new sub-router
keeps the "operates outside all tenant scoping" fact visible at the file/module
level, not buried inside a router whose every other route IS tenant-scoped.

```elixir
defmodule Letflow.Routers.Tenants do
  # use Plug.Router, plug :match, plug :dispatch (matching every other sub-router)
end
```

Mount: `Letflow.Plugs.ApiPipeline` adds `forward("/tenants", to: Letflow.Routers.Tenants)`
— full paths under `/api/v1` become `/api/v1/tenants`, `/api/v1/tenants/:slug`,
`/api/v1/tenants/:slug/deactivate`, `/api/v1/tenants/:slug/reactivate`. This matches
R-Co's own path shape (`/api/v1/tenants/...`) exactly — no `/identity` or other
segment prefix.

`Plug.Router` macro shape (name/method/path only):

```
post   "/",                    do: <create handler>
get    "/",                    do: <list handler>
get    "/:slug",                do: <get handler>
patch  "/:slug",                do: <patch handler>
post   "/:slug/deactivate",     do: <deactivate handler>
post   "/:slug/reactivate",     do: <reactivate handler>
match  _, do: Letflow.Api.Response.not_found(conn)
```

(Paths are relative to this router's own mount, so `"/"` here is `/api/v1/tenants`
after `Letflow.Plugs.ApiPipeline`'s `forward/2` strips the `/tenants` prefix —
matching every existing sub-router's own convention.)

### 2.1 Required `@moduledoc` content (AC6, AC7)

Mirrors REQ-073's AC6 precedent (§1a there) — this is a concrete build requirement
CODE-DESIGN-VALIDATOR and REVIEWER check against the shipped file text, not merely
design-doc narrative. `Letflow.Routers.Tenants`'s `@moduledoc` MUST contain, at
minimum, these elements as literal text (not paraphrased):

1. The route-to-function table (§0's summary table, restated).
2. **AC6's own risk statement, verbatim in substance**: *these six handlers operate
   on the global `tenants` table, entirely outside REQ-072's per-tenant
   `:prefix`-scoping mechanism — there is no tenant context to scope by, because
   these handlers decide which tenants exist. PLATFORM_ADMIN (via
   `Authorization.evaluate_access/2`'s `:TenantsManage` permission, §1.1) is the
   ONLY protection against cross-tenant enumeration/reads/writes here. This makes
   this route group higher-risk than every other S4 route: a gating bug elsewhere
   in S4 leaks at most one tenant's own data to that tenant's own misbehaving
   caller; a gating bug here leaks or corrupts every tenant on the platform,
   because there is no second isolation layer (no `:prefix`, no row-level tenant
   filter) standing behind the role check if it fails.*
3. **AC3's own-tenant rule, stated explicitly** (§3 below has the full analysis):
   *R-Co's `getTenantAdmin`/`patchTenant`/every other handler in this group requires
   `actor.role == PLATFORM_ADMIN` unconditionally, with no exception for a caller
   whose own home tenant happens to be the target — reading or patching your own
   tenant's record through these routes requires PLATFORM_ADMIN exactly like reading
   or patching any other tenant's record. This is ported as-is: there is no
   "manage your own tenant" carve-out in this implementation either.*
4. **AC7's relationship to REQ-076**, stated explicitly (§7.1 below has the full
   analysis): *`POST /tenants` (this requirement) and REQ-076's onboarding endpoint
   are two HTTP entry points into the same underlying provisioning primitives
   (`Letflow.TenantProvisioning.provision_tenant_schema/1` +
   `Letflow.TenantProvisioning.replay_migrations/2`) — not two divergent tenant-
   creation code paths. This one is the PLATFORM_ADMIN-driven direct-creation path;
   REQ-076's is the self-service signup path. Both must call the same
   `Letflow.TenantProvisioning` functions; neither reimplements schema creation or
   migration replay itself.*
PROVENANCE (historical, not current decision authority):
5. **AC5's deactivation-status statement**, stated explicitly (§4 below has the full
   analysis): *a tenant with `status: :inactive` rejects a subsequent authenticated
   request from that tenant's own (non-PLATFORM_ADMIN) caller with
   `403 tenant_inactive`, checked in `Letflow.Plugs.TenantStatus` before the request
   reaches any sub-router — for every HTTP method, not only writes, matching R-Co's
   own `enforceTenantActiveForOperation`/`isTenantInactive` behavior (checked at
   `src/identity/service.zig:133-151` and `src/api/middleware/auth.zig:1663-1674`).
   PLATFORM_ADMIN callers are exempt from this check, also matching R-Co
   (`service.zig:138`, `auth.zig:1663`).*

---

## 3. AC3 — own-tenant access rule (determined from R-Co source, not assumed)

PROVENANCE (historical, not current decision authority):
**Read directly, in full:** `src/identity/service.zig` — `getTenantAdmin` (L505-520),
`patchTenant` (L523-568), `createTenant` (L445-469), `listTenantsAdmin` (L490-503),
and `applyTenantLifecycleAction` (L110-130, backing both deactivate and reactivate).

**Every one of these five functions' first line is:**
```zig
if (actor.role != .PLATFORM_ADMIN) return error.Forbidden;
```
**with no subsequent check anywhere in any of the five function bodies that compares
the target tenant/slug against the caller's own tenant.** There is no
`actor.tenant_id == target_tenant.id` branch, no "unless it's your own" fallback, no
second code path reached only for a self-referential request. The check is a bare
role comparison, full stop, identical across all five functions.

**Determination: a caller who is not PLATFORM_ADMIN may not read, patch, deactivate,
or reactivate their OWN tenant's record through these handlers, any more than any
other tenant's.** "Tenant admin" is not a distinct role in this system's five-role
model (`PLATFORM_ADMIN | PROCESS_DESIGNER | PROCESS_OPERATOR | TASK_WORKER |
AGENT_RUNNER`, `lib/letflow/api/authorization.ex:48-53`) — a user belonging to some
tenant who holds e.g. `PROCESS_DESIGNER` is exactly the caller this rule denies,
whether the target slug is their own tenant's or a stranger's.

This is ported as-is (§2.1 point 3), and is the exact behavior §1.1's mechanism
produces automatically: `Authorization.AccessContext` carries only `user_id` and
`roles` (INV-2 — no request-derived "target tenant" field can ever reach
`evaluate_access/2`), so the decision is structurally incapable of varying by which
slug is in the path. No design choice is required to "add" the own-tenant exception's
absence — it falls out of reusing the existing pure-function authorization mechanism
unchanged.

### Both-directions test design (AC3)

```
test "PLATFORM_ADMIN can GET/PATCH their own home tenant's record, same as any other" do
  admin_tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req075-own-admin")
  conn = build_conn(:get, "/#{admin_tenant.tenant.slug}", admin_tenant, roles: ["PLATFORM_ADMIN"])
  resp = Letflow.Routers.Tenants.call(conn, @opts)
  assert resp.status == 200
  # ... same for PATCH with a valid display_name body
end

test "a non-PLATFORM_ADMIN caller is denied GET/PATCH on their OWN home tenant's record" do
  own_tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req075-own-denied")
  conn = build_conn(:get, "/#{own_tenant.tenant.slug}", own_tenant, roles: ["PROCESS_DESIGNER"])
  resp = Letflow.Routers.Tenants.call(conn, @opts)
  assert resp.status == 403
  # ... same for PATCH; assert own_tenant's row unchanged after, per §5
end
```

`build_conn/3`'s `tenant_fixture` argument supplies `auth_context.tenant_id`, which
here equals `admin_tenant.tenant_id`/`own_tenant.tenant_id` — i.e. the caller's own
home tenant IS the target slug in both tests, which is the point: the outcome tracks
role only, never whether target == caller's own tenant.

---

## 4. AC5 — deactivation's interaction with `Letflow.Plugs.TenantStatus`

### 4.1 What R-Co actually does (read directly, not assumed)

Two source locations settle this:

PROVENANCE (historical, not current decision authority):
* `src/identity/service.zig:133-151`, `enforceTenantActiveForOperation/3`:
  ```zig
  pub fn enforceTenantActiveForOperation(...) UpdateTenantStatusError!void {
      if (principal.role == .PLATFORM_ADMIN) return;   // exempt
      const tenant = ...; // selectTenantById(principal.tenant_id)
      if (tenant.status == .INACTIVE) return error.TenantInactive;
  }
  ```
PROVENANCE (historical, not current decision authority):
* `src/api/middleware/auth.zig:1663-1674`, inside `authenticate/3` itself (i.e. run
  on **every** authenticated request, not gated to write methods):
  ```zig
  if (role != .PLATFORM_ADMIN) {
      const inactive = isTenantInactive(allocator, db_pool, resolved_tenant.tenant_id);
      if (inactive) return .{ .forbidden = buildForbidden(allocator, "tenant_inactive") };
  }
  ```
  `buildForbidden/2` → **403**, `error: "tenant_inactive"`
  (`src/design/tenant-lifecycle-controls.md:258`'s own table confirms: `TenantInactive
  | 403 | tenant_inactive`).

So R-Co's real rule: an INACTIVE tenant's non-PLATFORM_ADMIN caller is rejected with
**403 `tenant_inactive`**, checked once per request in the auth middleware itself,
for **every HTTP method** (GET included) — not gated to writes. PLATFORM_ADMIN
callers are exempt (so a platform admin whose own home tenant happens to be
deactivated can still act).

### 4.2 Comparison with Letflow's existing `Letflow.Plugs.TenantStatus` — a real gap, flagged not silently resolved

`Letflow.Plugs.TenantStatus` (REQ-021, mounted by REQ-071) today only:
- checks `status == :migrating` (no `:inactive`/`:deactivated` value exists in
  `Letflow.Identity.Tenant`'s `Ecto.Enum` list yet — currently `[:active, :migrating]`);
- only runs for `@write_methods` (`POST/PUT/PATCH/DELETE`) — `call/2`'s first clause
  guard, `lib/letflow/plugs/tenant_status.ex:44`;
- responds **503** with `Retry-After`, not 403;
PROVENANCE (historical, not current decision authority):
- has no PLATFORM_ADMIN exemption (R-Co's `:migrating` write-pause and its
  `:inactive` rule are two different mechanisms in R-Co too — `tenant_status.zig`'s
  write-pause has no PLATFORM_ADMIN carve-out either, so this asymmetry is not new).

R-Co's real `:inactive` rule is broader (all methods) and differently-coded (403,
not 503) than Letflow's existing `:migrating` write-pause. **This design's
determination and recommendation** — stated as a recommendation for REVIEWER
sign-off, per this requirement's own instruction to be conservative about
ambiguities with platform-wide consequences, since it changes an already-shipped,
already-`done` module's behavior contract (REQ-021):

1. Add `:inactive` to `Letflow.Identity.Tenant`'s `Ecto.Enum` values list:
   `values: [:active, :migrating, :inactive]`. **No migration needed** — the
   `status` column is a plain `:string` (`priv/repo/migrations/20260816000001_create_tenants.exs`),
   not a native Postgres enum type and carries no DB `CHECK` constraint; the
   allowed-value set is enforced purely at the `Ecto.Enum` application layer.
2. Extend `Letflow.Plugs.TenantStatus.call/2` with a **new, separate check** that
   runs for **every** method (not gated by `@write_methods`) and **before** the
   existing `:migrating` write-only check: if the resolved tenant's `status ==
   :inactive` AND the caller's roles (from `conn.assigns.auth_context.roles`) do
   **not** include `"PLATFORM_ADMIN"`, reject with `403`, body
   `{"error": "tenant_inactive", "detail": "tenant is deactivated"}` — matching
   R-Co's error code literally (`"tenant_inactive"`) so a client written against
   R-Co's contract still recognizes it. PLATFORM_ADMIN callers pass through
   unaffected, matching `enforceTenantActiveForOperation`'s exemption.
3. This is a genuinely new code path in an already-`done` module
   (`Letflow.Plugs.TenantStatus`), not a one-line tweak — **flagged explicitly for
   REVIEWER sign-off before ELIXIR-DEV implements it**, per
   `core-directives.md`'s "don't silently re-decide what a decision record already
   settled" spirit extended to an already-shipped behavior contract. If REVIEWER
   determines a narrower change is preferable (e.g. gating this new check to write
   methods only, to minimize surface change to a shipped module, accepting a
   documented divergence from R-Co's all-methods rule), that is REVIEWER's call to
   make explicitly, not this design's to silently narrow.

**AC5's own moduledoc-naming requirement is satisfied by §2.1 point 5 above.**

### 4.3 Test design (AC5)

```
test "a caller whose home tenant is :inactive gets 403 tenant_inactive on GET /instances (any endpoint, not just tenant-admin routes)" do
  tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req075-inactive")
  Repo.update!(Tenant.changeset_setting_status_to_inactive(tenant.tenant, :inactive))
  # dispatch through Letflow.Plugs.ApiPipeline (not a bare sub-router call) so
  # Letflow.Plugs.TenantStatus is actually exercised
  conn = build_conn(:get, "/api/v1/instances", tenant, roles: ["PROCESS_DESIGNER"])
  resp = Letflow.Plugs.ApiPipeline.call(conn, @pipeline_opts)
  assert resp.status == 403
  body = Jason.decode!(resp.resp_body)
  assert body["error"] == "tenant_inactive"
end

test "a PLATFORM_ADMIN caller whose home tenant is :inactive is exempt" do
  tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req075-inactive-admin")
  Repo.update!(...) # set :inactive
  conn = build_conn(:get, "/api/v1/instances", tenant, roles: ["PLATFORM_ADMIN"])
  resp = Letflow.Plugs.ApiPipeline.call(conn, @pipeline_opts)
  refute resp.status == 403
end
```

This test dispatches through `Letflow.Plugs.ApiPipeline`, not a bare sub-router —
deliberately different from REQ-073/074's OQ-6 precedent of direct sub-router
dispatch, because the property under test (AC5) lives in a plug mounted **above**
every sub-router, not inside any single router's own handler; a sub-router-only
dispatch would never invoke `Letflow.Plugs.TenantStatus` at all and the test would
pass vacuously regardless of whether the new check exists.

---

## 5. AC2 — cross-tenant rejection, four verbs, row-unchanged (INV-1's spirit)

**Framing note on INV-1**, stated explicitly rather than silently glossed over:
`security-invariants.md`'s INV-1 as literally written ("every access to tenant
business data is scoped ... via `:prefix`") describes the REQ-072 mechanism, which
by design does not apply to this global table (§ intro). The requirement text's own
use of "(INV-1)" for this acceptance criterion is therefore a re-purposing of the
term to mean "no unauthorized cross-tenant access to another tenant's row," enforced
here by **role gating**, not by `:prefix` scoping — worth stating so a reader
checking this design against `security-invariants.md`'s literal text doesn't
conclude the design misapplies INV-1; SECURITY-REVIEWER should confirm this framing
at Step 2c.

Four tests, one per verb, each against a caller authenticated for a *different*
tenant than the target (role: anything other than PLATFORM_ADMIN — a caller from
tenant A acting on tenant B's slug):

```
test "GET /tenants/:slug on another tenant's record is rejected, row unchanged" do
  tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req075-cross-a")
  tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req075-cross-b")
  before = Repo.get!(Tenant, tenant_b.tenant_id)

  conn = build_conn(:get, "/#{tenant_b.tenant.slug}", tenant_a, roles: ["PROCESS_DESIGNER"])
  resp = Letflow.Routers.Tenants.call(conn, @opts)

  assert resp.status == 403
  assert Repo.get!(Tenant, tenant_b.tenant_id) == before
end
```

Mirror this shape for `PATCH /tenants/:slug` (body: valid `display_name` change —
proves the row is untouched despite a well-formed patch body), `POST
/tenants/:slug/deactivate`, and `POST /tenants/:slug/reactivate` (this last one
against a target tenant pre-set to `:inactive`, so a bug that let it through would
be visible as a flipped `status`, not just an unexpected 200). **Four separate
tests**, per AC2's own wording ("each of the four verbs covered by its own test") —
not one parameterized test looping over methods, so a failure names its verb
directly in the test name, matching this project's existing per-verb test
granularity precedent (REQ-073 §5).

---

## 6. Per-handler composition and remaining test designs

### 6.1 Common steps (all six handlers)

**Step 1 — authorization (before any Repo call of any kind):**
```
ctx = %Authorization.AccessContext{
  user_id: conn.assigns.auth_context.user_id,
  roles: Authorization.roles_from_strings(conn.assigns.auth_context.roles)
}
decision = Authorization.evaluate_access(ctx, Authorization.endpoint_policy_key(method, path_template))
```
`decision.kind == :Deny403` → `Letflow.Api.Response.forbidden(conn, "insufficient permissions")`,
**no Repo call before this point or after this branch** — same discipline as
REQ-073 §"Step 2", and the mechanism §1.3 relies on for AC1. There is no "Step 1 —
scoped prefix" here at all (unlike REQ-073/074) — that is the load-bearing structural
difference this whole design exists to get right; do not add a
`scoped_repo_opts/1` call to any of these six handlers.

### 6.2 `GET /tenants` (list) — AC1

1. (Step 1 above)
2. Parse query params (no body): `search` (string, optional — matches by `slug` OR
   `display_name`, `ILIKE`), `page_size`/`cursor` via `Pagination`, same cursor
   convention as REQ-073's `list_users/2` (`"T:"` prefix for **T**enants — matches
   `Pagination`'s established one-letter-prefix convention; not `"TN:"` or similar,
   since a single letter is the existing pattern for every prior list endpoint).
3. `Identity.list_tenants(%{search: search, cursor: ..., page_size: page_size})`
   (NEW, §7.2) → `{:ok, %{tenants: tenants, next_cursor: next_cursor_or_nil}}`.
4. `Response.ok(conn, Pagination.page_response(Enum.map(tenants, &tenant_map/1), next_cursor))`.

Test (AC1, full-body assertion):
```
test "listing tenants as a non-PLATFORM_ADMIN caller returns 403 and no tenant data whatsoever" do
  tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req075-list-403")
  other = TenantFixture.provisioned_tenant!(slug_prefix: "req075-list-403-other")

  conn = build_conn(:get, "/", tenant, roles: ["PROCESS_DESIGNER"])
  resp = Letflow.Routers.Tenants.call(conn, @opts)

  assert resp.status == 403
  assert Jason.decode!(resp.resp_body) == %{
    "type" => "...",  # Letflow.Api.Error's forbidden problem-type URI, literal
    "title" => "Forbidden",
    "status" => 403,
    "detail" => "insufficient permissions",
    "trace_id" => "<pinned literal, per build_conn/3's fixed trace_id>"
  }
  refute resp.resp_body =~ other.tenant.slug
  refute resp.resp_body =~ "items"
  refute resp.resp_body =~ "count"
end
```
The `refute ... =~` lines are redundant with the full-equality assertion above them
but are kept deliberately — they are what makes "no count, no total" checkable even
if a future edit to `Letflow.Api.Error`'s problem-document shape changes an
unrelated field and the exact-equality assertion needs updating; the substring
refutations still catch the one thing AC1 actually cares about.

### 6.3 `GET /tenants/:slug` (get)

1. (Step 1)
2. `Identity.get_tenant_by_slug(slug)` (NEW, §7.3) →
   - `{:ok, tenant}` → `Response.ok(conn, tenant_map(tenant))`
   - `{:error, :not_found}` → `Response.not_found(conn)`

(No INV-5 cross-tenant-404-vs-never-existed test is meaningful here the way it was
for REQ-073's `GET /users/:id` — there is no tenant-scoping to bypass in the first
place; "not found" here means the slug genuinely doesn't exist, full stop, for any
PLATFORM_ADMIN caller. §5's cross-tenant test is the one that matters for this
route, and it's a 403-before-lookup case, not a 404-after-lookup case.)

### 6.4 `PATCH /tenants/:slug` (patch)

1. (Step 1)
2. `Identity.get_tenant_by_slug(slug)` → `{:error, :not_found}` → `not_found`.
3. Validate body via `Letflow.Api.Validation.validate/2`:
   ```
   [%FieldConstraint{name: "display_name", required: false, type: :string,
                      reject_empty_string: true, min_length: 1, max_length: 255}]
   ```
   `{:errors, field_errors}` → `send_problem(conn, Validation.problem(field_errors))`.

   PROVENANCE (historical, not current decision authority):
   **`slug` and `idp_realm_id` are deliberately absent from this schema** — mirrors
   R-Co's own explicit immutability rejection (`handlePatchTenant`'s `422
   immutable_field_update` for both fields, `identity.zig:713-810`). Letflow's
   `Letflow.Api.Validation.validate/2` only ever returns the schema's own named
   fields (`Map.take`), so a caller-supplied `slug`/`idp_realm_id` in the raw body
   is silently dropped by construction rather than specially detected and
   rejected with a `422` — the same structural-simplification pattern REQ-073 §2.1
   already established and documented for this exact validator's behavior. Not a
   partial port; flagged so it isn't mistaken for a missed R-Co check.

   **`status` is also deliberately absent from this schema — and this is a
   real divergence from `Letflow.Identity.Tenant.update_changeset/2`'s current
   cast list, flagged explicitly:** that changeset (shipped under REQ-019, before
   this requirement existed) casts `[:display_name, :status]`. If this handler's
   `patch_tenant/2` (§7.4) reused `update_changeset/2` as-is, a plain `PATCH
   /tenants/:slug` with `{"status": "inactive"}` in the body would let a
   PLATFORM_ADMIN — or, if the validator ever regressed, anyone whose request
   reached the changeset — flip `status` outside the dedicated
   deactivate/reactivate action endpoints entirely, bypassing whatever audit-shaped
   handling those two endpoints carry (and, once §4.2 ships, bypassing the
   `:inactive`-check-with-PLATFORM_ADMIN-exemption reasoning built specifically
   around the two action endpoints being the only writers of that value). **This
   design specifies a NEW changeset, `Tenant.admin_patch_changeset/2`, casting only
   `[:display_name]`** — deactivate/reactivate remain the only two paths that can
   ever write `:status`. Recorded here as a required addition to
   `lib/letflow/identity/tenant.ex`, not a silent reuse of the existing changeset.

4. `Identity.patch_tenant(slug, validated_attrs)` (NEW, §7.4) →
   - `{:ok, tenant}` → `Response.ok(conn, tenant_map(tenant))`
   - `{:error, %Ecto.Changeset{}}` → `Response.unprocessable(conn, "validation failed")`
   - `{:error, :not_found}` → `not_found` (defensive race-window case, matching
     REQ-073's own precedent for the identical shape)

PROVENANCE (historical, not current decision authority):
**Not ported**: R-Co's `handlePatchTenant` also accepts `hostname`/`redirect_uris`
and syncs them to Keycloak via a `provider_manager_mod.Manager` (`identity.zig:770-793`).
Letflow has no equivalent Keycloak realm-management client module yet (Decision
0002's partial-adoption scope covers token verification only) — this design does
**not** attempt to add one. `hostname`/`redirect_uris` patch support is out of this
requirement's scope; flagged as **OQ-1** below, not silently dropped without a
trace.

### 6.5 `POST /tenants/:slug/deactivate` and `POST /tenants/:slug/reactivate`

1. (Step 1)
2. `Identity.deactivate_tenant(slug)` / `Identity.reactivate_tenant(slug)` (NEW,
   §7.5) →
   - `{:ok, tenant}` → `Response.ok(conn, tenant_map(tenant))`
   - `{:error, :not_found}` → `not_found`
   - `{:error, :invalid_transition}` → `Response.unprocessable(conn,
     "invalid tenant status transition")` — **open question, §OQ-2**: R-Co's
     `applyTenantLifecycleAction` unconditionally sets the target status
     (`.deactivate -> .INACTIVE`, `.reactivate -> .ACTIVE`) with no visible
     transition-guard logic in the function body read above (no check that the
     tenant isn't already in the target state) — so whether `InvalidTransition`
     is even reachable from this call path in R-Co, or is a defensive error variant
     for some other caller of `updateTenantStatusBySlug` not visible in the slice
     read for this design, is unresolved. This design's `deactivate_tenant/1`/
     `reactivate_tenant/1` should treat re-deactivating an already-`:inactive`
     tenant (or reactivating an already-`:active` one) as a **no-op success**
     (idempotent, matching this codebase's own established idempotency precedent
     for `TenantProvisioning.provision_tenant_schema/1`), not an error — ELIXIR-DEV
     should confirm this reading is consistent with R-Co's actual
     `updateTenantStatusBySlug` if that function's body is in scope to check, and
     flag to REVIEWER if it disagrees.

No request body validation needed for either — R-Co's `isValidLifecyclePayload`
check exists in the Zig handler but the requirement's own acceptance criteria don't
call out a body shape for these two routes, and this design does not invent one:
both are treated as body-less `POST`s (`conn.body_params` ignored if present).
Flagged as **OQ-3** in case REVIEWER wants a documented body shape ported.

Cross-tenant rejection tests for these two: §5. Deactivation's own-request-blocking
effect: §4.3.

---

## 7. Domain-function gaps (`Letflow.Identity`)

None of these six functions exist today (confirmed: `grep -n "def create_tenant\|def
list_tenants\|def get_tenant\|def update_tenant" lib/letflow/` — zero hits anywhere
in `lib/`). All operate on the default-schema `tenants` table with **no `opts`
parameter** — the one structural difference from every REQ-073/074 domain function.

### 7.1 `create_tenant/1`

```
@spec create_tenant(attrs :: %{slug: String.t(), display_name: String.t(), idp_realm_id: String.t() | nil}) ::
        {:ok, Tenant.t()} | {:error, :duplicate_slug} | {:error, Ecto.Changeset.t()}
```
Inserts via `Tenant.create_changeset(%Tenant{}, attrs, oidc_mode)` — **oidc_mode
resolution is OQ-4**: `create_changeset/3` requires an `oidc_mode :: :enabled |
:disabled` argument (existing signature, `tenant.ex:79`) that this handler has no
obvious source for (no global OIDC-enabled/disabled config key exists yet, per that
same module's own moduledoc note referencing `req019-tenant-realm-binding.md` §8
OQ-1 — an **already-open, pre-existing** question this design does not attempt to
resolve, only re-surfaces because `create_tenant/1` is the first real caller that
must supply a concrete value). Maps a `slug` unique-constraint violation to
`{:error, :duplicate_slug}` (mirrors REQ-073's `username_unique_conflict?/1`
pattern, applied to the `tenants_slug_index` constraint instead).

**Then, orchestrated by the `POST /tenants` handler itself (not inside
`create_tenant/1` — matching `Letflow.TenantProvisioning`'s own moduledoc's
"two separate, composable primitives, neither calls the other" invariant, which
extends naturally to a third: tenant-row-creation also doesn't call either)**:
```
{:ok, tenant} = Identity.create_tenant(validated_attrs)
{:ok, _registration} = TenantProvisioning.provision_tenant_schema(tenant.id)
{:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)
```
On success: `Response.created(conn, tenant_map(tenant))`. A `provision_tenant_schema/1`
or `replay_migrations/2` failure after the tenant row is already committed is a real
partial-failure state (a `tenants` row exists with no matching schema) — **OQ-5**:
this design does not specify a compensating rollback (deleting the just-created
tenant row) for that case; ELIXIR-DEV/REVIEWER should decide whether to add one or
accept the partial state as operationally recoverable (a provisioning retry path
would need `provision_tenant_schema/1`'s own idempotency anyway, which already
exists).

**AC7 — relationship to REQ-076, stated precisely:** REQ-076's own
`docs/requirements.yaml` entry states its onboarding subsystem's backing subsystem
IS `Letflow.TenantProvisioning` (its description: "whose backing subsystem is
REQ-022's Letflow.TenantProvisioning"). So both this handler and REQ-076's
`handleOnboarding` port must call the identical
`provision_tenant_schema/1`/`replay_migrations/2` pair — this design's `POST
/tenants` orchestration above IS the shared shape REQ-076 should also follow, not
a competing one. The two differ only in: (a) caller identity/authorization
(PLATFORM_ADMIN direct creation here vs. a self-service signup flow's own
authorization model, REQ-076's to define), and (b) whatever additional onboarding-
specific steps REQ-076 layers on top (e.g. initial-admin-user creation, initial
realm binding choices) — this design does not attempt to scope REQ-076's own
requirements, only states that both must terminate in the same
`Letflow.TenantProvisioning` calls, per this requirement's own AC7 text ("one
provisioning path rather than two").

AC4's `information_schema` test:

```
test "tenant creation results in a provisioned schema with REQ-022's migrations replayed" do
  conn = build_conn(:post, "/", nil, roles: ["PLATFORM_ADMIN"],
                     body: %{"slug" => "req075-create-e2e", "display_name" => "Create E2E"})
  resp = Letflow.Routers.Tenants.call(conn, @opts)
  assert resp.status == 201
  tenant_id = Jason.decode!(resp.resp_body)["id"]

  {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant_id)

  # AC4's own wording: "querying information_schema for a table in the new
  # schema -- not by trusting the 201." Pick a table every tenant-scoped
  # migration replay always creates -- events, per
  # TenantProvisioning.tenant_scoped_migrations/0's first manifest entry.
  %{rows: rows} = Repo.query!(
    "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 AND table_name = 'events'",
    [schema_name]
  )
  assert rows != []
end
```
(`build_conn/3`'s first argument, `tenant_fixture`, is `nil` here since the caller's
own tenant identity is irrelevant to this handler's authorization — only `roles`
matters, per §1.1's pure-role gate; `build_conn/3` must accept a `nil`/omitted
tenant fixture for exactly this case, a small extension to REQ-073's existing helper
shape — TEST-DESIGNER's call on the concrete signature.)

### 7.2 `list_tenants/1`

```
@spec list_tenants(params :: %{search: String.t() | nil, cursor: Pagination.Cursor.t() | nil, page_size: pos_integer()}) ::
        {:ok, %{tenants: [Tenant.t()], next_cursor: String.t() | nil}}
```
Same shape as REQ-073's `list_users/2` minus `opts`/`status` filter (no `status`
query filter requested by this requirement's ACs) — `ILIKE` against `slug` OR
`display_name` when `search` present, ordered `inserted_at` ascending then `id`
ascending, `LIMIT page_size + 1` fetch-one-extra idiom.

### 7.3 `get_tenant_by_slug/1`

```
@spec get_tenant_by_slug(slug :: String.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
```
`Repo.get_by(Tenant, slug: slug)`, `nil` → `{:error, :not_found}`.

### 7.4 `patch_tenant/2`

```
@spec patch_tenant(slug :: String.t(), attrs :: map()) ::
        {:ok, Tenant.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
```
`Repo.get_by(Tenant, slug: slug)` (→ `{:error, :not_found}` on `nil`), then
`Tenant.admin_patch_changeset(tenant, attrs)` (NEW changeset, §6.4 — casts only
`[:display_name]`), then `Repo.update/1`.

### 7.5 `deactivate_tenant/1` and `reactivate_tenant/1`

```
@spec deactivate_tenant(slug :: String.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
@spec reactivate_tenant(slug :: String.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
```
`Repo.get_by(Tenant, slug: slug)` (→ `{:error, :not_found}` on `nil`), then a new
`Tenant.status_changeset/2` (casts only `[:status]`, `validate_required([:status])`)
set to `:inactive`/`:active` respectively, then `Repo.update/1`. Idempotent per
§6.5's OQ-2 reasoning (re-deactivating an already-`:inactive` tenant succeeds as a
no-op, same final state).

**`Tenant.status_changeset/2` is a second new changeset alongside
`admin_patch_changeset/2` (§6.4)** — deliberately two separate, narrow changesets
rather than one broader one, so `PATCH /tenants/:slug` structurally cannot write
`:status` and `deactivate`/`reactivate` structurally cannot write `:display_name` —
matching this codebase's established "structural impossibility over runtime
rejection" preference (`Tenant`'s own moduledoc already uses exactly this idiom for
`idp_realm_id`'s immutability).

---

## 8. Response allowlist — `tenant_map/1`

Private function in `Letflow.Routers.Tenants`, matching REQ-073's `user_map/1`
precedent exactly:

```
%{
  "id" => tenant.id,
  "slug" => tenant.slug,
  "display_name" => tenant.display_name,
  "status" => Atom.to_string(tenant.status),
  "inserted_at" => <matches whatever convention ELIXIR-DEV finds/sets per
                     REQ-073's own still-open OQ-2 on this exact point>,
  "updated_at" => same
}
```

PROVENANCE (historical, not current decision authority):
**6 keys.** `Letflow.Identity.Tenant`'s full field list is `id`, `slug`,
`display_name`, `status`, `idp_realm_id`, plus `inserted_at`/`updated_at`. **`idp_realm_id`
is deliberately excluded** — it is an OIDC/Keycloak realm identifier, not secret
material in the INV-2/INV-4 sense, but R-Co's own `serializeTenant` (not read in
full for this design — out of the named source-file scope, `identity.zig` only
covers the handler layer) may or may not include it; absent a confirmed precedent,
this design excludes it on the same "allowlist, not denylist — add explicitly if
needed later" principle REQ-073 §3 already established for `user_map/1`'s excluded
fields. Flagged as **OQ-6** for REVIEWER: confirm against `serializeTenant`
(`identity.zig`, not yet read for this design) whether `idp_realm_id` should be
included.

---

## 9. Open questions (not silently resolved)

- **OQ-1** — `hostname`/`redirect_uris` PATCH support and Keycloak realm sync
  (§6.4): not ported, no Keycloak-client module exists in Letflow yet. Confirm this
  is acceptable scope for REQ-075, or whether a stub/gap should be filed for a
  future requirement.
- **OQ-2** — whether re-deactivating an already-`:inactive` tenant (or reactivating
  an already-`:active` one) is a no-op success or an `:invalid_transition` error
  (§6.5) — this design recommends no-op/idempotent, not confirmed against R-Co's
  `updateTenantStatusBySlug` implementation (out of this requirement's named
  source-file scope).
- **OQ-3** — whether `POST .../deactivate` and `.../reactivate` should validate any
  request body shape, matching R-Co's `isValidLifecyclePayload` check (§6.5) — this
  design treats both as body-less.
- **OQ-4** — `oidc_mode` argument source for `Tenant.create_changeset/3` inside
  `create_tenant/1` (§7.1) — a pre-existing open question (REQ-019 §8 OQ-1),
  re-surfaced here because this is its first real caller.
- **OQ-5** — no compensating rollback specified for a tenant row committed but its
  schema provisioning/migration-replay subsequently failing (§7.1).
- **OQ-6** — whether `tenant_map/1` should include `idp_realm_id` (§8), not
  confirmed against R-Co's `serializeTenant` (out of this requirement's named
  source-file scope).
PROVENANCE (historical, not current decision authority):
- **OQ-7 (§4.2, the largest open question in this design)** — the exact shape of
  `Letflow.Plugs.TenantStatus`'s new `:inactive` check: this design recommends
  all-methods (not write-only), 403 (not 503), PLATFORM_ADMIN-exempt, matching
  R-Co's `auth.zig`/`service.zig` behavior precisely — but this changes an
  already-shipped, already-`done` module's (REQ-021) behavior contract, which is
  exactly the class of change this project's core directives say must get explicit
  REVIEWER sign-off rather than being silently decided by a downstream requirement's
  design doc. **Do not implement §4.2 without REVIEWER confirming this shape
  first.**
