# REQ-403 — HTTP half of 0039 D5: install and list

**Status:** design, pending CODE-DESIGN-VALIDATOR.
**Depends on (already merged):** REQ-401 (`:ModulesManage` permission),
REQ-402 (`Letflow.Modules.Installs.install/3`, `list_installed/1`,
`Letflow.Modules.TenantModule` schema).
**Decision record:** `docs/migration/decisions/0039-platform-module-solution-layering.md`
D5.
**Supersedes:** REQ-403's own earlier open question about `GET /api/v1/me` — resolved
by ORCH 2026-09-24 (see "Decided by ORCH" section below).

No implementation code in this document — signatures, types, tables, and prose only.
CODE-DESIGN-VALIDATOR will FAIL any `def ... do ... end`/`schema do ... end`/literal
`test "..." do ... end` block found here.

---

## 1. Decided by ORCH (2026-09-24) — binding, not re-opened here

The existing `:MembershipsRead` (which deliberately excludes `CANDIDATE`, per
`lib/letflow/routers/me.ex`'s moduledoc) is **not** widened. No permission-less route
is added. No `GET /api/v1/me` root route is added. Instead, `CANDIDATE`'s ISS-0646
closed permission set grows by exactly one atom: `:MyModulesRead`, granted to every
role including `CANDIDATE` and `AGENT_RUNNER` through one role-agnostic
`role_allows?/2` clause. This document designs exactly that shape — it is not an open
question to re-litigate.

---

## 2. New module: `lib/letflow/routers/tenant_modules.ex`

### 2.1 Moduledoc content (prose requirements, not literal text)

Must state:
- Mounted at `/tenant/modules` by `Letflow.Plugs.ApiPipeline`, full path
  `/api/v1/tenant/modules`, forwarded the same way as the existing
  `forward("/tenant/settings", to: Letflow.Routers.TenantSettings)` line (§4 below) —
  a new top-level `forward("/tenant/modules", to: Letflow.Routers.TenantModules)`
  entry, placed near that existing line.
- One route: `POST /` (full path `POST /api/v1/tenant/modules`), gated by
  `:ModulesManage` (`PLATFORM_ADMIN` only, per REQ-401/D5).
- Deliberately mounted at `/tenant/modules`, NOT under `/api/v1/modules/` (REQ-404's
  future mount, out of scope here) — so this route can never collide with a future
  module whose catalog id happens to be `install`.
- Delegates to `Letflow.Modules.Installs.install/3`. The `prefix` argument comes
  **only** from `conn.assigns.scoped_opts` (set by `Letflow.Plugs.Authorize`,
  itself derived server-side from `conn.assigns.auth_context.tenant_id` via
  `Letflow.Api.Context.scoped_repo_opts/1`) — never from the request body, path, or
  query string (INV-1). Any `tenant_id`/`tenant`/`prefix` key present in the JSON
  body is read by nothing in this router and has no effect.
- `actor_id` passed to `install/3` is `conn.assigns.auth_context.user_id` (the
  authenticated caller — same source `Letflow.Routers.TenantSettings` and
  `Letflow.Routers.Me` use for identity, never a body field).

### 2.2 Route table

| Handler | Method/path | Policy key | Delegates to | Success | Error mapping |
|---|---|---|---|---|---|
| `handle_install` | `POST /` (`/api/v1/tenant/modules`) | `:ModulesManage` | `Letflow.Modules.Installs.install/3` | `201` | see §2.4 |

### 2.3 Request/response shapes

**Request body** (`conn.body_params`, must be a JSON object):

| Key | Type | Required | Notes |
|---|---|---|---|
| `module_id` | string | yes | passed as `install/3`'s first argument, untouched |
| `tenant_id` | any | no | **ignored** — never read (INV-1) |
| `tenant` | any | no | **ignored** — never read (INV-1) |
| `prefix` | any | no | **ignored** — never read (INV-1) |
| any other key | any | no | ignored, no rejection/audit needed (unlike `TenantSettings`'s PATCH, this body has exactly one meaningful key; silently ignoring extras is sufficient — no acceptance criterion asks for a rejected-key audit trail here) |

If `body_params` is not a map, or `module_id` is missing/not a string: `422` via
`Response.unprocessable/2` with a plain-language detail — same defensive shape
`Letflow.Routers.TenantSettings.handle_patch/1`'s fallback clause uses for a
non-map body.

**Success response** (`201`):

```
{"module_id": <string>, "version": <string>, "installed_at": <ISO-8601 string>}
```

Built from the returned `%Letflow.Modules.TenantModule{}` struct's `module_id`,
`version`, `installed_at` fields (the latter formatted via `DateTime.to_iso8601/1`,
matching how other routers in this tree serialize `utc_datetime_usec` fields for JSON
— grep an existing example, e.g. `Letflow.Routers.Tasks`, before implementing, rather
than inventing a new date-format convention here). No other `TenantModule` field
(`id`, `settings`) is exposed by this route.

### 2.4 Error mapping — `install/3`'s tagged-error union to HTTP

| `install/3` result | HTTP status | Response helper | Detail text source |
|---|---|---|---|
| `{:ok, tenant_module}` | 201 | `Response.created/2` | §2.3 body |
| `{:error, :unknown_module}` | 404 | `Response.not_found/1` | fixed, no module id leaked beyond what the caller already sent |
| `{:error, :already_installed}` | 409 | `Response.conflict/2` | plain-language, e.g. "module already installed" |
| `{:error, {:dependency_not_installed, dep_id}}` | 422 | `Response.unprocessable/2` | plain-language including `dep_id`, e.g. "missing dependency: <dep_id>" |
| `{:error, {:pack_install_failed, _reason}}` | 422 | `Response.unprocessable/2` | plain-language, no internal reason struct serialized to the client |
| `{:error, {:on_install_failed, _reason}}` | 422 | `Response.unprocessable/2` | plain-language, no internal reason struct serialized to the client |
| `{:error, %Ecto.Changeset{}}` | 422 | `Response.unprocessable/2` | changeset error message, same helper pattern as `TenantSettings.patch_tenant_settings/3`'s changeset branch |

Every branch above except the first is a `handler-level case`, not a new function
added to `Letflow.Modules.Installs` — that module's contract (`install/3`'s
`@spec ... :: {:ok, TenantModule.t()} | install_error()`) is unchanged by this
requirement.

### 2.5 `@spec`-only shape for the two private handler functions (no bodies)

```elixir
@spec handle_install(Plug.Conn.t()) :: Plug.Conn.t()
defp handle_install(conn)

@spec install_response_map(Letflow.Modules.TenantModule.t()) :: map()
defp install_response_map(tenant_module)
```

---

## 3. `Letflow.Routers.Me` — one new route

### 3.1 Addition to the existing moduledoc's route table (§ "Route" heading)

| Handler | Method/path | Delegates to | Permission | Response |
|---|---|---|---|---|
| `handle_list_memberships` | `GET /me/memberships` | `Letflow.Identity.list_memberships_for_subject/1` | `:MembershipsRead` | 200 *(existing, unchanged)* |
| `handle_list_modules` | `GET /me/modules` | `Letflow.Modules.Installs.list_installed/1` | `:MyModulesRead` | 200 *(new, this requirement)* |

### 3.2 New route declaration

`authz_get "/modules", :MyModulesRead do ... end` — same macro, same calling
convention as the existing `authz_get "/memberships", :MembershipsRead do ... end`
line already in this file (see `lib/letflow/api/authorized_router.ex`'s
`authz_get/3` macro: compile-time literal policy-key atom as the second argument,
never request-derived).

### 3.3 Handler behavior

- `prefix = Keyword.fetch!(conn.assigns.scoped_opts, :prefix)` — same
  server-derived-only source `handle_list_memberships/1` and
  `Letflow.Routers.TenantModules.handle_install/1` use. No path/query/header value
  is read by this handler for tenant selection (INV-1) — this is the property AC8
  checks by attaching tenant A's id as both an `x-tenant-id` header and a
  `tenant_id` query parameter on a request whose *token* is minted for tenant B, and
  asserting the response still reflects tenant B (empty).
- Calls `Letflow.Modules.Installs.list_installed(prefix: prefix)`.
- Response body: `{"installed_modules": [{"module_id": <string>, "version": <string>}, ...]}`
  — built by mapping each returned `%TenantModule{}` to a map containing **exactly**
  `module_id` and `version` (AC4's "each entry has exactly the keys module_id and
  version"). No `installed_at`, no `settings`, no `id` — this route intentionally
  returns strictly less than `TenantModules`' install-response shape (§2.3).
- No error branch beyond the ordinary `Letflow.Plugs.Authorize` `403`/scope-resolution
  `500` paths already common to every route in this file — `list_installed/1` has no
  `{:error, ...}` return per its own `@spec` (REQ-402 design), so there is nothing
  else to map here.

### 3.4 `@spec`-only shape for the new private handler functions (no bodies)

```elixir
@spec handle_list_modules(Plug.Conn.t()) :: Plug.Conn.t()
defp handle_list_modules(conn)

@spec installed_module_json(Letflow.Modules.TenantModule.t()) :: map()
defp installed_module_json(tenant_module)
```

---

## 4. `lib/letflow/plugs/api_pipeline.ex` — one new `forward`

Add, near the existing `forward("/tenant/settings", to: Letflow.Routers.TenantSettings)`
line (§ "Mount changes" pattern already established by every prior `forward` addition
in this file's history — REQ-078, REQ-335, REQ-352, REQ-374, REQ-377, REQ-384):

```
forward("/tenant/modules", to: Letflow.Routers.TenantModules)
```

with a short comment block above it, same shape as the REQ-384 comment above the
existing `forward("/me", ...)` line, citing REQ-403 and this design doc's path, and
stating explicitly: mounted here (not under `/modules`) specifically so it cannot
collide with a future per-module mount (REQ-404) whose `:id` segment could otherwise
literally be `install`.

`Letflow.Routers.Me` is already forwarded (`forward("/me", to: Letflow.Routers.Me)`,
REQ-384) — no pipeline change needed for §3's new route; it rides the existing mount.

---

## 5. `lib/letflow/api/authorization.ex` — permission/type/policy-key changes

### 5.1 `:MyModulesRead` — new core permission

Add `:MyModulesRead` to:
- `@type permission ::` union (after `:ModulesManage`, the most recently added entry)
- `@permissions` list (same position)
- `@type endpoint_policy_key ::` union (this route needs a literal policy-key atom
  the same way `:MembershipsRead` already does — see §5.3)
- `core_permissions/0`'s moduledoc count/prose (the running "plus REQ-NNN's
  `:XyzRead`" list at `core_permissions/0`'s own `@doc`) — append "plus REQ-403's
  `:MyModulesRead`"; the *numeric* count in that doc string is descriptive prose,
  not independently asserted anywhere except via `length(core_permissions())` per
  the doc's own note — no separate hardcoded number to hunt down.

### 5.2 `role_allows?/2` — one role-agnostic clause on the PUBLIC function, placed
first (AC6)

AC6's grep contract is literal: `git grep -n "def role_allows?(_role, :MyModulesRead),
do: true"` (note `def`, not `defp`) must return exactly one hit, and no
`def role_allows?(:` line anywhere in the file may mention `:MyModulesRead`. Today
`role_allows?/2` is the one **public** function in this module (a single generic
clause, `role, permission`, that delegates to the private `core_role_allows?/2` for
the closed per-role lists); no per-role dispatch happens on the public function name
at all today. So this is not a clause added to `core_role_allows?/2` — it is a new
**clause of the public `role_allows?/2` function itself**, added immediately before
the file's existing single `role_allows?/2` clause (the one whose body reads
`core_role_allows?(role, permission) or permission in
Letflow.Modules.Catalog.role_grants(role)`). Its head pattern-matches: first argument
the wildcard `_role` (matches every role), second argument the literal atom
`:MyModulesRead`; its body is the boolean literal `true`. Because Elixir tries same-
name/arity clauses top-to-bottom and a call whose second argument is the atom
`:MyModulesRead` matches this new clause's pattern before it ever reaches the
generic `role, permission` clause below it, `Letflow.Modules.Catalog.role_grants/1`
is never consulted for this one permission — harmless, since no module is expected
to also declare a permission literally named `:MyModulesRead` (Catalog atoms are a
disjoint namespace per REQ-401 D4), but worth stating so a future reader does not
mistake the short-circuit for an oversight.

This clause never touches `core_role_allows?/2` or any of its five per-role `defp`
clauses — no per-role list gets `:MyModulesRead` added to it, satisfying AC6's second
grep ("no line containing `def role_allows?(:` mentions `:MyModulesRead`": trivially
true, since none of the existing per-role clauses are even named `role_allows?` — they
are `core_role_allows?` — and this design adds no new clause to that private function
at all).

**Placement is load-bearing, not stylistic.** The new clause must be the first
`def role_allows?/2` clause in the file — i.e. above the existing generic clause —
so AC6's "its line number is lower than every other `def role_allows?(:` line"
check holds by construction (there being no other such line at all makes this
vacuously true today, but the ordering is still the one a future added role-specific
public clause would need to respect).

### 5.3 `endpoint_policy_key/2` and `required_permission/1` — two new identity pairs

Two new routes need their method/path pair (or, for `TenantModules`, nothing extra —
see note below) resolvable to a permission:

| Route | Policy-key atom passed to `authz_get`/`authz_post` | `endpoint_policy_key/2` clause needed? | `required_permission/1` clause needed |
|---|---|---|---|
| `POST /tenant/modules` | `:ModulesManage` | Yes — add `def endpoint_policy_key("POST", "/tenant/modules"), do: :ModulesManage`, grouped near the existing `/tenant/settings`-adjacent clauses or the REQ-401 `:ModulesManage` mention. `:ModulesManage` is not yet a member of `@type endpoint_policy_key ::` (REQ-401's moduledoc note: "no `endpoint_policy_key/2` clause... added for it in this requirement" — that gap is closed now) — add it there too. | `def required_permission(:ModulesManage), do: :ModulesManage` (identity clause, same shape as `:TenantsManage`/`:RolesManage`/`:MembershipsRead`) |
| `GET /me/modules` | `:MyModulesRead` | Yes — add `def endpoint_policy_key("GET", "/me/modules"), do: :MyModulesRead`, placed next to the existing `def endpoint_policy_key("GET", "/me/memberships"), do: :MembershipsRead` clause. Add `:MyModulesRead` to `@type endpoint_policy_key ::` union too. | `def required_permission(:MyModulesRead), do: :MyModulesRead` (identity clause, same shape as `:MembershipsRead`) |

**Why both `authz_get`'s literal atom AND an `endpoint_policy_key/2` clause are
needed for each route:** `Letflow.Plugs.Authorize` reads `conn.private[:policy_key]`
(set directly by the `authz_*` macro's literal argument — see
`lib/letflow/api/authorized_router.ex`'s moduledoc) and never calls
`endpoint_policy_key/2` at request time for a router using `AuthorizedRouter`.
`endpoint_policy_key/2` exists for the routers/tests that still resolve a policy key
from a bare `{method, path}` pair (its own extensive clause list, and whatever test
coverage exercises it directly) — `lib/letflow/routers/me.ex`'s existing
`GET /me/memberships` route already carries both an `authz_get` literal AND its own
`endpoint_policy_key("GET", "/me/memberships")` clause (see that file's line ~893),
so this design follows the same already-established pattern rather than inventing a
new one. **Open question, not silently resolved:** whether `endpoint_policy_key/2`
is actually load-bearing for anything reachable from `AuthorizedRouter` routes, or is
dead/test-only code for this router shape, is not re-derived in this document — add
the clause anyway, matching the existing `:MembershipsRead` precedent exactly, so
behavior stays consistent with every prior route in this file regardless of the
answer. ELIXIR-DEV should `git grep -n "endpoint_policy_key("` call sites before
implementing, to confirm no additional caller needs it and no test asserts against
its absence.

### 5.4 ISS-0646 CANDIDATE test update (AC7) — design-level statement, not test code

`test/letflow/api/authorization_test.exs`'s test at (currently) line 2170,
`"role_allows?/2 grants CANDIDATE exactly its six ExamSession*/ExamCertificateIssue
permissions, denying every other live permission"`, must be updated (by
TEST-DESIGNER/ELIXIR-DEV in a later step, not by this design doc) to:
- assert `role_allows?(:CANDIDATE, :MyModulesRead) == true`
- keep asserting `role_allows?(:CANDIDATE, perm) == true` for exactly the existing
  six: `:ExamSessionStart`, `:ExamSessionRead`, `:ExamSessionSave`,
  `:ExamSessionSubmit`, `:ExamSessionReportEvent`, `:ExamCertificateIssue`
- assert `role_allows?(:CANDIDATE, perm) == false` for every other **live**
  permission (i.e. `Authorization.permissions() -- [the seven above]`, computed, not
  a second hardcoded list — matching how this test file already derives its
  "every other live permission" set today)
- be renamed to say **seven**, not six, in its own description string

This is a test-content requirement carried into Step 3 (TEST-DESIGNER); it is stated
here only so CODE-DESIGN-VALIDATOR can confirm AC7 has a concrete design element to
check against, per Step 1's own acceptance criteria.

---

## 6. `docs/migration/decisions/0039-platform-module-solution-layering.md`

No change needed — D5's text ("Listing a tenant's installed modules needs only an
authenticated tenant user... The SPA reads the installed-module list from `GET /me`")
is satisfied by `GET /api/v1/me/modules` under the existing `/me` mount, consistent
with ORCH's 2026-09-24 resolution in §1 above (D5's own prose loosely says "`GET
/me`" but that is describing the `/me`-mount *concept*, not literally mandating a
root `/me` route — REQ-384 already established `/me` as a mount with sub-paths, not
a single flat endpoint, and ORCH's decision is the more specific, later-dated
resolution per Instruction Precedence).

---

## 7. Invariants

- **INV-1 (tenant scoping is server-derived only).** Both new handlers resolve
  `prefix` exclusively from `conn.assigns.scoped_opts` (itself derived from
  `conn.assigns.auth_context.tenant_id`, set by `AuthPipeline` from the verified
  JWT — never from request path/query/body/header). Neither handler reads
  `tenant_id`/`tenant`/`prefix`/`x-tenant-id` from the request for this purpose.
  `POST /tenant/modules` additionally must not let a body-supplied `tenant_id`/
  `tenant` key influence which schema is written to (AC2) — satisfied structurally,
  since `handle_install/1` never reads those body keys at all (§2.3).
- **Fail-closed by default.** No new route is declared with the plain
  `get`/`post` macros — both use `authz_get`/`authz_post`, so a route reachable
  without its literal policy key is impossible by construction (see
  `Letflow.Plugs.Authorize`'s moduledoc "Policy key resolution" section).
- **Response field minimality (INV-2-shaped, same discipline as `Me`'s existing
  route).** `GET /me/modules` returns exactly `module_id`/`version` per entry — no
  `settings`, no internal `id`. `POST /tenant/modules` returns `module_id`/
  `version`/`installed_at` — no `settings`, no internal `id`.
- **`:ModulesManage` stays `PLATFORM_ADMIN`-only.** This design adds no
  `role_allows?/2` clause granting `:ModulesManage` to any other role — it remains
  granted solely via `PLATFORM_ADMIN`'s unconditional catch-all, exactly as
  REQ-401 established and as D5 requires ("granted to `PLATFORM_ADMIN` only").
- **`:MembershipsRead`'s existing grant set is untouched (AC9).** No edit to any
  `:MembershipsRead` line in `role_allows?/2` — `git diff` over
  `lib/letflow/api/authorization.ex` must show zero lines changed in any clause
  mentioning `:MembershipsRead`.

---

## 8. Cross-module dependency summary

| This requirement's code | Depends on | Direction |
|---|---|---|
| `Letflow.Routers.TenantModules` | `Letflow.Modules.Installs.install/3` (REQ-402) | calls |
| `Letflow.Routers.TenantModules` | `Letflow.Api.Response` (`created/2`, `not_found/1`, `conflict/2`, `unprocessable/2`) | calls |
| `Letflow.Routers.TenantModules` | `Letflow.Api.AuthorizedRouter` (`authz_post/3`) | uses |
| `Letflow.Routers.Me` (new handler) | `Letflow.Modules.Installs.list_installed/1` (REQ-402) | calls |
| `Letflow.Plugs.ApiPipeline` | `Letflow.Routers.TenantModules` | forwards to |
| `Letflow.Plugs.Authorize` | `Letflow.Api.Authorization.evaluate_access/2`, `required_permission/1`, `role_allows?/2` | calls (unchanged mechanism, new data) |

No change to `Letflow.Modules.Installs`, `Letflow.Modules.TenantModule`,
`Letflow.Modules.Catalog`, or any migration — REQ-402's schema and context module are
consumed as-is.

---

## 9. Acceptance-criteria traceability

| AC | Design element(s) that cover it |
|---|---|
| AC1 | §2 route (`authz_post "/", :ModulesManage`); §5.2 keeps `:ModulesManage` `PLATFORM_ADMIN`-only (no grant added for the other five roles) → 403 for all non-`PLATFORM_ADMIN` tokens; §2.4's `install_error()` mapping table only ever writes a row on the `{:ok, _}` branch (REQ-402's own transaction, unchanged), so a 403 short-circuits in `Letflow.Plugs.Authorize` before the handler — and therefore before `install/3` — ever runs, guaranteeing no row write on any 403. |
| AC2 | §2.1/§2.3: `prefix` sourced only from `conn.assigns.scoped_opts`; `tenant_id`/`tenant`/`prefix` body keys explicitly never read (INV-1, §7). |
| AC3 | §2.4's full error-mapping table: `:unknown_module`→404, `:already_installed`→409, `{:dependency_not_installed,_}`→422. |
| AC4 | §3.3: response shape `{"installed_modules": [{"module_id","version"}]}`, exactly two keys per entry; §5.2's role-agnostic clause grants `:MyModulesRead` to all six roles including `CANDIDATE`/`AGENT_RUNNER`. |
| AC5 | §5.2's role-agnostic `core_role_allows?(_role, :MyModulesRead), do: true` clause — true for every `role()` by construction, not enumerated per-role. |
| AC6 | §5.2's placement requirement (first clause, before `:PLATFORM_ADMIN`'s) and the explicit "no per-role list gets the atom added" rule — matches AC6's grep contract exactly. |
| AC7 | §5.4: ISS-0646 test update spec (assert exactly seven permissions for `CANDIDATE`, including `:MyModulesRead`, denial of every other live permission, renamed description). |
| AC8 | §3.3: `prefix` resolved only from `conn.assigns.scoped_opts`; handler never reads `tenant_id` query param or `x-tenant-id` header (§7 INV-1 restated for this route explicitly, since AC8 is the test that exercises exactly this). |
| AC9 | §5.1 adds `:MyModulesRead` as a wholly new atom (never touches `:MembershipsRead`'s own union entry or any of its `role_allows?/2` clauses); §7's explicit "`:MembershipsRead`'s existing grant set is untouched" invariant; §4 confirms no `authz_get "/"` root route is added to `me.ex` — the only new route in that file is `authz_get "/modules", ...`. |
| AC10 (SECURITY-REVIEWER sign-off + `mix letflow.check`) | §7's full invariant list (INV-1 scoping, fail-closed route declaration, response-field minimality) gives SECURITY-REVIEWER a concrete checklist against both new routes; no gate-editing anywhere in this design (§5's `role_allows?`/`endpoint_policy_key`/`required_permission` additions are additive-only, verified by AC6/AC9's grep contracts rather than by trusting a claim). |

---

## 10. Open questions (not silently resolved)

1. **Exact JSON date format for `installed_at` in the 201 response (§2.3).** This
   design specifies `DateTime.to_iso8601/1`-shaped output but does not name a single
   existing call site as the copy-exact precedent — ELIXIR-DEV must grep an existing
   router serializing a `utc_datetime_usec` field (e.g. `Letflow.Routers.Tasks` or
   `Letflow.Routers.Instances`) and match that convention exactly, not invent a new
   one. Left open because this design doc's author did not exhaustively confirm
   which existing router is the canonical example.
2. **Whether `endpoint_policy_key/2` is actually consumed anywhere reachable from an
   `AuthorizedRouter`-based route (§5.3's note).** Added defensively, matching the
   `:MembershipsRead` precedent, without confirming a live caller exists for this
   router shape. If ELIXIR-DEV's grep in §5.3 finds it is genuinely dead for this
   class of router, that is a finding for REVIEWER (idiom/dead-code), not a reason
   to skip adding the clause here — consistency with the existing pattern wins over
   a local optimization this design doc doesn't have the authority to make alone.
