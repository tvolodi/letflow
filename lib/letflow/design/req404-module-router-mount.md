# REQ-404 — the D4/D5 module-router dispatch mount

**Status:** design, pending CODE-DESIGN-VALIDATOR.
**Depends on (already merged):** REQ-400 (`Letflow.Modules.Catalog`, `Letflow.Modules.Module`
behaviour, `Letflow.Modules.Fixture` test fixture), REQ-401 (Catalog-sourced permissions,
the `endpoint_policy_key(_, "/modules/" <> rest)` fallback clause and
`module_route_permission/3`, already on `main`), REQ-402 (`Letflow.Modules.Installs`,
`Letflow.Modules.TenantModule`), REQ-403 (`Letflow.Routers.TenantModules`, `:ModulesManage`,
`:MyModulesRead`, `GET /me/modules`).
**Decision record:** `docs/migration/decisions/0039-platform-module-solution-layering.md`
D3, D4 (`router/0`), D5 (per-tenant install, 404-not-403).

No implementation code in this document — signatures, types, tables, and prose only.
CODE-DESIGN-VALIDATOR will FAIL any `def ... do ... end` / `schema do ... end` / literal
`test "..." do ... end` block found here. `@spec`-only fenced blocks (no bodies) are used
where a concrete signature must be pinned down.

---

## 0. Two gaps found while reading the merged code, both must close in this requirement

These are not new scope invented by this design — they are prerequisites REQ-404's own
text points at ("the fixture module's one route is the proof") and a gap REQ-401's design
doc explicitly deferred to "REQ-403's own design" (never actually closed by REQ-403 — see
§0.2). Both are re-verified against the current tree, not assumed from memory.

### 0.1 `Letflow.Modules.Fixture.Router` does not enforce authorization yet

Read `test/support/modules/fixture/router.ex` (current state, merged under REQ-400/402):
it is a **plain** `use Plug.Router` with an unconditional `get "/items/:id"` — no
`Letflow.Api.AuthorizedRouter`, no `authz_get`, no policy key at all. If REQ-404 mounts
this router as-is, every caller who clears the D5 install-gate (i.e. every tenant with the
fixture installed) gets `200` regardless of role — AC2's "403 for a role the fixture does
not grant" would be impossible to satisfy, because nothing in the router evaluates
`role_grants` at all.

**Fix, in scope for this requirement (fixture is test support, not production module
content; necessary, not merely convenient — without it, every installed-tenant caller
gets `200` regardless of role and AC2's 403-branch is structurally untestable.
CODE-DESIGN-VALIDATOR flagged an earlier draft of this section for citing a false
precedent — `fixture_dependent/` and `fixture_failing_install/` (REQ-402/403) have no
`router/0` and no route at all, so no such conversion happened there; this fix's
justification rests solely on AC2's own testability requirement, not any precedent):**
`test/support/modules/fixture/router.ex` changes from `use Plug.Router` to
`use Letflow.Api.AuthorizedRouter`, and its one route changes from the plain
`get "/items/:id" do ... end` to `authz_get "/items/:id", :FixtureRead do ... end` —
identical response body, only the route macro and the `use` line change. This is the
same macro/policy-key shape every core router already uses (see
`lib/letflow/routers/tenant_modules.ex`'s `authz_post "/", :ModulesManage do ... end`).
`:FixtureRead` is already the exact atom `Letflow.Modules.Fixture.manifest().permissions`
and `route_policies` declare (`{"GET", "/items/:id", :FixtureRead}`) — no manifest change
needed, only the router file.

**This is a prerequisite ELIXIR-DEV must make**, not an assumption this design leaves
implicit — flagged explicitly for the report back to ORCH.

### 0.2 `Letflow.Api.Authorization.required_permission/1` has no fallback for a
Catalog-declared permission atom

Confirmed by reading `lib/letflow/api/authorization.ex` on `main` (current, post
REQ-401/402/403): `required_permission/1`'s last real clause is
`def required_permission(:Unknown), do: :MetricsRead` (line ~1103) — there is **no**
catch-all clause. `evaluate_access/2` calls `required_permission(endpoint)` unconditionally
for any `endpoint` that is not literally `:Unknown` or `:MetricsRead`. The moment a
module's own `authz_get "/items/:id", :FixtureRead` route reaches `Letflow.Plugs.Authorize`
(which happens the instant REQ-404 forwards a request into `Letflow.Modules.Fixture.Router`
once §0.1 is fixed), `Letflow.Plugs.Authorize` calls
`Authorization.evaluate_access(ctx, :FixtureRead)`, which calls
`required_permission(:FixtureRead)` — **no clause matches, `FunctionClauseError`,
request crashes with a 500** instead of resolving to 200/403.

REQ-401's own design doc (`lib/letflow/design/req401-catalog-sourced-permissions.md` §4/§7)
found this exact gap and explicitly deferred it: *"It will matter the moment REQ-403
actually mounts a module's router behind `Letflow.Plugs.Authorize`... Left as an explicit
open item for REQ-403's own design... the fix is almost certainly an identity fallback in
`required_permission/1`."* Re-checked REQ-403's own design doc
(`lib/letflow/design/req403-module-install-route.md`) in full: it adds two **core**
identity clauses (`:ModulesManage`, `:MyModulesRead`) but never adds the general
Catalog-atom fallback — because REQ-403 mounted `TenantModules` (a core router with a core
policy key), never a module's own `router/0`. The gap is still open on `main` today. It is
REQ-404 that actually mounts a module's `router/0` behind `Authorize` for the first time,
so closing it belongs here.

**Fix:** add one new, final clause to `required_permission/1`, placed after
`def required_permission(:Unknown), do: :MetricsRead` (last position — every existing
clause keeps its exact position and body, so no existing `(endpoint) -> permission`
resolution changes):

```elixir
@spec required_permission(Authorization.endpoint_policy_key() | atom()) :: atom()
def required_permission(endpoint)
```

Body (prose, not code): identity — return `endpoint` itself unchanged, for any atom that
reaches this final clause (i.e. every atom not already matched by a clause above it, which
by construction covers every closed-set `endpoint_policy_key()` member already handled
explicitly). This is safe because `Letflow.Modules.Catalog.validate/1`'s
`{:core_permission_collision, _}` rule (already enforced, REQ-400/401) guarantees a
module's own declared `permissions` never intersect `Authorization.core_permissions()` —
so an identity fallback can never accidentally under- or over-grant a *core* permission by
this path; it only ever resolves a genuinely Catalog-sourced atom (like `:FixtureRead`) to
itself, exactly the same "identity clause, policy-key name == permission name" pattern
already used for a dozen existing atoms in this file (`:EntitiesQuery`, `:HelpRead`,
`:ModulesManage`, etc — see file for the precedent).

**Scope note:** this is a one-clause, purely additive change to a core mechanism file
(`lib/letflow/api/authorization.ex`), not a module-boundary violation — D3's boundary check
is about `lib/letflow/modules/<id>/` directories, not `authorization.ex`.

---

## 1. New core file: `lib/letflow/routers/modules.ex`, `Letflow.Routers.Modules`

### 1.1 What kind of Plug this is, and why not `Letflow.Api.AuthorizedRouter`

This is a **plain `Plug`** (`@behaviour Plug`, `init/1` + `call/2`), not a `Plug.Router` and
not an `Letflow.Api.AuthorizedRouter`-based router. Reason, stated because it is load-bearing
for D5: `AuthorizedRouter`'s `plug(:match) -> plug(Letflow.Plugs.Authorize) -> plug(:dispatch)`
chain runs `Authorize` — i.e. a permission check — on every request before any handler code
runs. D5 requires the OPPOSITE order here: the "is this module installed for this tenant"
check must run and can return 404 **before** any permission evaluation, for every role
including `PLATFORM_ADMIN`. A router built on `AuthorizedRouter` cannot express that
ordering without a policy key already resolved, which itself would require knowing whether
the module is installed. So `Letflow.Routers.Modules` implements the dispatch/gate logic
itself, doing no authorization evaluation of its own, and forwards to the module's own
`router/0` — which (per §0.1) *is* `AuthorizedRouter`-based and does its own real
`Authorize`-driven permission check, exactly as every other module's router will.

### 1.2 Mounting (mirrors `Letflow.Modules.Fixture.Router`'s own moduledoc: mount prefix
`/api/v1/modules/<id>`)

`lib/letflow/plugs/api_pipeline.ex` gets one new line, placed near the existing
`forward("/tenant/modules", to: Letflow.Routers.TenantModules)` block (same file, same
"Mount changes" convention every prior `forward` addition uses — REQ-078, REQ-335, REQ-352,
REQ-374, REQ-377, REQ-384, REQ-403):

```
forward("/modules", to: Letflow.Routers.Modules)
```

with a short comment block above it citing REQ-404 and this design doc's path, and stating
explicitly: this is the mount `REQ-403`'s own `/tenant/modules` comment already named as
"REQ-404's future per-module mount" — distinct prefix, no collision.

Full external path for any module route: `/api/v1/modules/<module_id>/<rest...>`.
`Plug.Router`'s compiled `forward/2` macro expands `forward("/modules", to: ...)` into a
match on `"/modules/*glob"`, so `Letflow.Routers.Modules.call/2` receives a `conn` whose
`path_info` is exactly `[module_id | rest]` (a request to `/api/v1/modules` with no
trailing segment, or `/api/v1/modules/` with an empty glob, does not match this forward
pattern at all and falls through to `Letflow.Plugs.ApiPipeline`'s own existing
`match _ -> Letflow.Api.Response.not_found(conn)` catch-all — same 404 body, so this edge
case is covered by the *pipeline's* existing catch-all, not by anything new here).

### 1.3 `call/2` — behavior, stated as an ordered decision table (no code)

Preconditions guaranteed by `Letflow.Plugs.ApiPipeline`'s own plug chain, which this
dispatcher is mounted inside (see `api_pipeline.ex`'s `plug(Letflow.Plugs.AuthPipeline)`,
mounted before any `forward`): `conn.assigns.auth_context` (`user_id`, `tenant_id`, `roles`)
is always already populated by the time `Letflow.Routers.Modules.call/2` runs — an
unauthenticated request never reaches this far (`AuthPipeline` itself rejects it earlier).

| Step | Condition on `conn.path_info` / lookups | Result |
|---|---|---|
| 1 | `conn.path_info == []` (empty glob — see §1.2) | `Letflow.Api.Response.not_found(conn)` |
| 2 | `conn.path_info == [module_id \| rest]`. Compute `scoped_opts` via `Letflow.Api.Context.scoped_repo_opts(conn)` (the SAME function `Letflow.Plugs.Authorize` itself calls — see `lib/letflow/plugs/authorize.ex`), then `Plug.Conn.assign(conn, :scoped_opts, opts)` so `conn.assigns.scoped_opts` is populated before any check below runs, satisfying this requirement's own text ("checked with the `prefix` from `conn.assigns.scoped_opts`, INV-1") literally, not just in spirit. If `scoped_repo_opts/1` returns `{:error, :missing_auth_context \| :invalid_tenant_id}` | `Letflow.Api.Response.internal_error(conn)` — identical failure shape to `Letflow.Plugs.Authorize`'s own handling of the same error (see that module's `call/2`); this is a programmer-error case (AuthPipeline is expected to always produce a valid `auth_context`), never a normal request path, so it is not covered by any AC and is documented here only for completeness |
| 3 | `Letflow.Modules.Catalog.fetch(module_id)` returns `{:error, :not_found}` | `Letflow.Api.Response.not_found(conn)` |
| 4 | `Catalog.fetch/1` returns `{:ok, entry_module}`, but `function_exported?(entry_module, :router, 0)` is `false` (module has no `router/0` — optional callback, D4) | `Letflow.Api.Response.not_found(conn)` |
| 5 | `entry_module` has `router/0`, but `Letflow.Modules.Installs.installed?(module_id, opts)` (new function, §2) is `false` — tenant identified by `opts[:prefix]` (the same `scoped_opts` assigned in step 2) has no `tenant_modules` row for `module_id` | `Letflow.Api.Response.not_found(conn)` |
| 6 | All of the above cleared: module known, has a router, installed for this tenant | Dispatch: `Plug.forward(conn, rest, entry_module.router(), entry_module.router().init([]))`. `Plug.forward/4` is Plug's own public function backing every compiled `forward/2` macro call (`deps/plug/lib/plug.ex`) — it re-slices `path_info`/`script_name` so the target router sees `rest` as its own `path_info`, calls `target.call(conn, opts)`, then restores the outer `path_info`/`script_name` on return. `conn.assigns` (including `auth_context` and the `scoped_opts` assigned in step 2) passes through unchanged — the target router's own `AuthorizedRouter`-driven `Letflow.Plugs.Authorize` plug independently recomputes `scoped_opts` from `conn.assigns.auth_context` (idempotent — same value) and performs the REAL permission decision against the route's own literal `authz_*` policy key. |

Every 404 branch above calls the exact same zero-argument-detail function,
`Letflow.Api.Response.not_found(conn)` — no branch constructs a custom message or includes
`module_id`/tenant information in the body. This is what makes AC3's byte-identity
assertion true by construction: steps 1, 3, 4, and 5 are textually the same function call,
so their responses are byte-identical regardless of which branch produced them.

### 1.4 `@spec`-only shape (no bodies)

```elixir
@behaviour Plug

@spec init(keyword()) :: keyword()
def init(opts)

@spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
def call(conn, opts)
```

Plus whatever small private helpers the table above implies (e.g. a `defp gate/2` folding
steps 2-5 into one `with`-chain) — left to ELIXIR-DEV's own style, since their signatures
are not part of this module's public contract and no AC depends on their shape.

### 1.5 D3 compliance — the file never names a concrete module

Every module reference in this file is one of exactly four names:
`Letflow.Modules.Catalog`, `Letflow.Modules.Installs`, `Letflow.Modules.Module` (only
via `function_exported?/3`'s target being a *value* returned by `Catalog.fetch/1`, never a
literal module atom), and `Letflow.Modules.TenantModule` is not referenced here at all
(that's `Installs`' own internal concern). `entry_module` is always a runtime value
obtained from `Catalog.fetch/1` — the file contains no `alias Letflow.Modules.Fixture` or
equivalent, and no `case module_id do "fixture" -> ... end`-shaped branching. This is
exactly what AC5's grep contract checks
(`git grep -nP 'Letflow\.Modules\.(?!(Catalog|Installs|TenantModule|Module)\b)[A-Z]' --
lib/letflow/routers/modules.ex lib/letflow/plugs/api_pipeline.ex`) — zero hits by
construction, since `api_pipeline.ex`'s only change is a `forward` line naming
`Letflow.Routers.Modules` itself (not a `Letflow.Modules.*` name at all).

---

## 2. `lib/letflow/modules/installs.ex` — one new public function

Core mechanism file per D3 (already named there explicitly) — this addition does not
change its file placement or its existing `install/3`/`list_installed/1` contracts.

```elixir
@doc """
Whether `module_id` is installed for the tenant identified by `opts[:prefix]`.
Raises if `:prefix` is missing from `opts` (same "programmer error, not a runtime
{:error, ...} case" convention `list_installed/1` already uses).
"""
@spec installed?(module_id :: String.t(), opts()) :: boolean()
def installed?(module_id, opts)
```

Behavior: `true` iff a `tenant_modules` row with that `module_id` exists in the schema
named by `opts[:prefix]` — the same `Repo.exists?(from(m in TenantModule, where:
m.module_id == ^module_id), prefix: prefix)` shape `install/3`'s own private
`dependency_installed?/2` helper already uses internally (this new function may share
that helper's body, or `dependency_installed?/2` may be renamed and reused — an
implementation choice, not a design constraint, since both produce the identical query).
No new query shape, no new index needed: `tenant_modules_module_id_idx` (the existing
unique index backing `TenantModule.insert_changeset/2`'s `unique_constraint/2`) already
covers an equality lookup on `module_id` within one tenant schema.

**Why a dedicated function instead of `list_installed/1` + membership check (the
requirement text's own second option):** `Repo.exists?/2` is a single indexed-lookup query
regardless of how many modules a tenant has installed, whereas `list_installed/1` +
`Enum.any?/2` loads every installed row just to answer a boolean — a real, if today small,
efficiency difference, and it mirrors the existing internal `dependency_installed?/2`
pattern exactly rather than introducing a second way to ask the same question. Decided
here, not left as an open question, since `Installs` already has the query shape ready to
expose.

---

## 3. `test/support/modules/fixture/router.ex` — prerequisite change (§0.1)

| Before (current, on `main`) | After (this requirement) |
|---|---|
| `use Plug.Router` | `use Letflow.Api.AuthorizedRouter` |
| `get "/items/:id" do ... end` | `authz_get "/items/:id", :FixtureRead do ... end` |

Handler body (the `send_resp(conn, 200, Jason.encode!(%{fixture: true, id: id}))` line)
is unchanged. No manifest change (`Letflow.Modules.Fixture.manifest/0`'s `route_policies`
already declares `{"GET", "/items/:id", :FixtureRead}`, matching the new `authz_get`
literal exactly — this consistency is what `authorization_enforcement_test.exs`'s
existing walk (§4 below) checks once the fixture router is registered there).

---

## 4. Test-file changes needed (named here so TEST-DESIGNER/ELIXIR-DEV do not have to
re-derive them; this is the standard "acceptance criteria have concrete design
elements" requirement, not new test code written here)

### 4.1 `test/letflow/api/authorization_enforcement_test.exs`

Add `Letflow.Modules.Fixture.Router` to `@routers` and add
`Letflow.Modules.Fixture.Router => "/modules/fixture"` to `@mount_prefix`. Once §3's
change lands, this router's one `__authz_routes__/0` entry (`{"GET", "/items/:id",
:FixtureRead}`) resolves its full path to `/modules/fixture/items/:id`, and
`Authorization.endpoint_policy_key("GET", "/modules/fixture/items/:id")` already returns
`:FixtureRead` via the existing REQ-401 fallback clause (`module_route_permission/3`) —
so this addition passes against code already on `main`, no `@allowlist` entry needed.

### 4.2 New HTTP-level test file: `test/letflow/routers/modules_test.exs`

Full-pipeline dispatch via `Letflow.Router.call/2`, same established convention
`test/letflow/routers/entities_test.exs`'s moduledoc documents (real
`Authorization: Bearer ...` credential, `X-Tenant-Slug` header, so
`AuthPipeline -> TenantStatus -> Letflow.Routers.Modules -> (module's own) Authorize`
genuinely all run) — not a hand-built `conn` with `assigns` preset, for the same reason
that file gives: a preset `:scoped_opts` would prove nothing about the real dispatch path.
`async: false`, `use Letflow.DataCase` (`TenantFixture.provisioned_tenant!/1` needs
`Sandbox.mode(Letflow.Repo, :auto)`), matching `tenant_modules_test.exs`'s own
`async: false` justification.

| AC | Test shape |
|---|---|
| AC1 | For each `role <- Authorization.roles()` (includes `:PLATFORM_ADMIN`): a fresh, unprovisioned-for-fixture tenant; `GET /api/v1/modules/fixture/items/42` with a token minted for that role; assert `conn.status == 404`. |
| AC2 | Same tenant, install the fixture via `Letflow.Modules.Installs.install/3` directly (context-module call, not another HTTP round-trip — same "call the context module to set up state, hit HTTP for the behavior under test" convention `tenant_modules_test.exs` uses for its own fixture installs where relevant) with `depends_on: []` so no extra setup needed; then `GET /api/v1/modules/fixture/items/42` with a `:TASK_WORKER` token (the fixture's one `role_grants` role, read from `Letflow.Modules.Fixture.manifest().role_grants` rather than hardcoded, matching REQ-401's own test-design precedent) — assert `200` and the exact fixture body shape (`%{"fixture" => true, "id" => "42"}`); repeat with a role NOT in `role_grants` (e.g. `:PROCESS_DESIGNER`) — assert `403`. |
| AC3 | `GET /api/v1/modules/does-not-exist/anything` (no install needed — unknown module id) for any one role; capture `conn.resp_body`; separately capture the AC1 tenant's uninstalled-fixture 404 `resp_body`; assert the two are byte-identical (`==`), not just same status. |
| AC4 | Two tenants (`TenantFixture.provisioned_tenant!/1` twice, distinct prefixes); install the fixture into tenant A only; `GET /api/v1/modules/fixture/items/42` as one of tenant B's `:TASK_WORKER` users — assert `404` (not 403 — proves the D5 404-not-403 rule holds per-tenant, not globally, and that installing into A has no cross-tenant leak). |
| AC5 | Not a runtime test — a `git grep` invocation TEST-DESIGNER/ELIXIR-DEV runs and quotes the literal (empty) output in the handoff, plus SECURITY-REVIEWER's own independent re-run of the same grep at Step 2c. No ExUnit test needed for this AC. |
| AC6 | Not a new test — `mix letflow.check` is the existing aggregate gate; ELIXIR-DEV/TEST-RUNNER quote its real output. |

---

## 5. Invariants

- **D5's ordering invariant, restated precisely for this dispatcher:** no branch in
  `Letflow.Routers.Modules.call/2` (§1.3) ever calls `Letflow.Api.Authorization.evaluate_access/2`
  or any function that does. The only downstream code that evaluates a permission is the
  forwarded-to module's own `Letflow.Plugs.Authorize`, reached only after every 404 branch
  above has already been cleared. This is what makes "404 for every role including
  `PLATFORM_ADMIN`" true by construction rather than by enumeration — there is no role
  check anywhere before the forward.
- **INV-1 (tenant scoping is server-derived only).** `scoped_opts` in
  `Letflow.Routers.Modules` is derived exclusively from `conn.assigns.auth_context.tenant_id`
  via `Letflow.Api.Context.scoped_repo_opts/1` — the identical function and identical
  source `Letflow.Plugs.Authorize` itself uses. No path segment, query parameter, or
  header is read for tenant identification. `Letflow.Modules.Installs.installed?/2`
  (§2) takes only `module_id` and `opts[:prefix]` — no `tenant_id`/`schema` parameter,
  matching the existing grep contract `Letflow.Modules.Installs`' own moduledoc already
  states for `install/1`/`list_installed/1`.
- **D3 (module boundary).** §1.5 above. `Letflow.Routers.Modules` and the
  `api_pipeline.ex` forward line are core files; neither references any
  `lib/letflow/modules/<id>/` or `test/support/modules/<id>/` file by name — the only
  path in is through `Letflow.Modules.Catalog.fetch/1`'s runtime return value.
- **Response-body minimality / no information leak (D5's stated rationale, "a module's
  absence is not information to leak").** Every 404 in §1.3 is the same zero-argument
  `Letflow.Api.Response.not_found(conn)` call — the response cannot distinguish "module
  doesn't exist" from "module exists but isn't installed for you" from "module exists,
  installed, but has no `router/0`", by construction (AC3).
- **`Plug.forward/4`'s own transparency.** Forwarding does not swallow or wrap the target
  router's own response — whatever `entry_module.router().call/2` returns (200, 403, its
  own 404 for an unmatched sub-path, etc.) passes straight back through `Letflow.Routers.Modules`
  unchanged; there is no post-processing step after the forward in §1.3 step 6.

---

## 6. Cross-module dependency summary

| This requirement's code | Depends on | Direction |
|---|---|---|
| `Letflow.Routers.Modules` | `Letflow.Modules.Catalog.fetch/1` | calls |
| `Letflow.Routers.Modules` | `Letflow.Modules.Installs.installed?/2` (new, §2) | calls |
| `Letflow.Routers.Modules` | `Letflow.Api.Context.scoped_repo_opts/1` | calls |
| `Letflow.Routers.Modules` | `Letflow.Api.Response.not_found/1`, `internal_error/1` | calls |
| `Letflow.Routers.Modules` | `Plug.forward/4` | calls |
| `Letflow.Routers.Modules` | the entry module's own `router/0` return value (a runtime `module()`, never a compile-time reference) | dispatches to |
| `Letflow.Plugs.ApiPipeline` | `Letflow.Routers.Modules` | forwards to |
| `Letflow.Modules.Fixture.Router` (§3) | `Letflow.Api.AuthorizedRouter` (`authz_get/3`) | uses |
| `Letflow.Plugs.Authorize` (unchanged code, new reachable data) | `Letflow.Api.Authorization.required_permission/1` (new fallback clause, §0.2) | calls |

No change to `Letflow.Modules.Catalog`, `Letflow.Modules.Module`, `Letflow.Modules.TenantModule`,
`Letflow.Modules.Fixture`'s manifest, or any migration.

---

## 7. Acceptance-criteria traceability

| AC | Design element(s) that cover it |
|---|---|
| AC1 | §1.3 steps 1/3/4/5 (all 404, no role branching, §5's "no `evaluate_access` call before the forward" invariant); §0.1 is a prerequisite so the fixture even has an `authz_get`-gated route to test against for AC2's contrast, though AC1 itself needs no install at all. |
| AC2 | §0.1's fixture-router fix (enables real 200/403 split); §1.3 step 6 (forward preserves `conn.assigns`, module's own `Authorize` evaluates `:FixtureRead` against `role_grants`); §0.2's `required_permission/1` fallback (without it, step 6 would 500, not 200/403). |
| AC3 | §1.3's "every 404 branch calls the identical zero-arg `not_found/1`" statement; §1.2's "no glob" edge case also resolves to the pipeline's own identical `not_found` call. |
| AC4 | §1.3 step 5 (`installed?/2` scoped by `opts[:prefix]`, §1.5/§5 INV-1 — prefix from tenant B's own token, never tenant A's). |
| AC5 | §1.5's D3-compliance statement + the exact four-name allowlist the grep pattern encodes. |
| AC6 | §0.1 and §0.2 close the two runtime gaps that would otherwise make `mix letflow.check`'s underlying test suite fail (a 500 on AC2's path, or a router with no authz check at all making AC2 unwritable) — no other gate-shaped concern identified in this design. |

---

## 8. Open questions (not silently resolved)

1. **Whether `Letflow.Routers.Modules` should itself register into
   `authorization_enforcement_test.exs`'s `@routers` walk.** It is not
   `AuthorizedRouter`-based (§1.1), so it exposes no `__authz_routes__/0` and structurally
   cannot be added the way every other entry in `@routers` is — REQ-401's own design
   already established the correct mechanism for module routes specifically
   (`Letflow.Modules.Catalog.entry_modules/0` + each module's `route_policies`, a
   *separate* enumeration in the same test file, added by REQ-401 §5 AC5 — confirm this
   still exists and already covers the fixture's route once §3 lands; if it does not,
   that is a gap in REQ-401's own delivered scope, not this requirement's to silently
   patch). ELIXIR-DEV should read that section of the test file before writing §4.2's
   tests and report back if it is missing rather than re-deriving a third mechanism.
2. **`Letflow.Routers.Modules.init/1`'s actual return value.** Plug's convention is
   `init(opts) -> opts` (often unchanged) unless the plug needs to precompute something
   from static options at compile/startup time. Nothing in this design requires
   precomputation — `init(_opts), do: []` (accepting and ignoring whatever `forward/2`
   passes, since this plug takes no meaningful options) is the expected shape, but the
   exact triviality of the body is left to ELIXIR-DEV, not pinned down as a design
   constraint since no AC depends on it.
3. **Whether a module author who forgets a catch-all `match _` in their own `router/0`
   should be this requirement's problem.** Not covered by any AC (only the fixture, which
   also has no catch-all, is exercised, and every AC's request path matches its one real
   route). Left as a note for a future module's own design, not resolved here — an
   unmatched sub-path today would surface whatever `Plug.Router`'s own default behavior is
   for a router with no `match _`, unchanged by this requirement.
