# REQ-073 — Identity routes 1/4: user CRUD and status

PROVENANCE (historical, not current decision authority):
Design for mounting five real handlers into `lib/letflow/routers/identity.ex`
(currently a REQ-070 stub), porting `src/api/routes/identity.zig`'s
`handleCreateUser` (L21), `handleListUsers` (L101), `handleGetUser` (L130),
`handlePatchUser` (L149), `handleUpdateUserStatus` (L303).

No implementation code below — signatures, data shapes, and test specs only.

## 0. Summary of composition (every handler, every building block)

| Handler | Method/path | `Letflow.Identity` fn called | Auth policy key | Body validation | Response |
|---|---|---|---|---|---|
| create | `POST /users` | `Identity.create_user/2` (NEW — gap, §7) | `:UsersManage` | `Letflow.Api.Validation` schema (§2.1) | 201, `user_map/1` |
| list | `GET /users` | `Identity.list_users/2` (NEW — gap, §7) | `:UsersManage` | query-param parsing only (no body) | 200, `Pagination.Page.t(user_map)` |
| get | `GET /users/:id` | `Identity.get_user/2` (NEW — gap, §7) | `:UsersManage` | none (no body) | 200, `user_map/1` |
| patch | `PATCH /users/:id` | `Identity.get_user/2` then `Identity.update_user_profile/3` (NEW — gap, §7) | `:UsersManage` | `Letflow.Api.Validation` schema (§2.4) | 200, `user_map/1` |
| status update | `POST /users/:id/status` | `Identity.get_user/2` then `Identity.update_user_status/3` (NEW — gap, §7) | `:UsersManage` | `Letflow.Api.Validation` schema (§2.5) | 200, `user_map/1` |

All five resolve `:UsersManage` via `Letflow.Api.Authorization.endpoint_policy_key/2`
(already defined for `POST /users`, `GET /users`, `GET /users/:id`, `PATCH /users/:id`
— **gap**: `POST /users/:id/status` has no existing clause, §7 gap 4) and
`required_permission/1` maps `:UsersManage` to `:UsersGroupsRolesManage` (already
correct, no change needed).

## 1. Route wiring — `lib/letflow/routers/identity.ex`

PROVENANCE (historical, not current decision authority):
R-Co's route table (checked in `src/api/routes.zig`'s registration, not just the
handler file) binds these five handlers as:

```
POST   /users              -> handleCreateUser
GET    /users               -> handleListUsers
GET    /users/:id            -> handleGetUser
PATCH  /users/:id            -> handlePatchUser
POST   /users/:id/status     -> handleUpdateUserStatus
```

`Letflow.Routers.Identity` is mounted at `/identity` by `Letflow.Plugs.ApiPipeline`
(`forward("/identity", to: Letflow.Routers.Identity)`), so the full paths under
`/api/v1` are `/api/v1/identity/users`, `/api/v1/identity/users/:id`,
`/api/v1/identity/users/:id/status`. **`Letflow.Api.Authorization.endpoint_policy_key/2`
must be called with the path template relative to `/identity`** (i.e. `"/users"`,
`"/users/:id"`), matching its existing clauses — it is not called with the
`/identity`-prefixed or `/api/v1`-prefixed path. This must be a literal string
constant per handler (`"/users"` / `"/users/:id"`), not derived from `conn.request_path`,
so a handler's own policy key can never accidentally vary with the literal path
matched.

`Plug.Router`'s macro DSL for the five routes (name/method/path shape only, no
handler bodies):

```
post   "/users",           do: <create handler>
get    "/users",           do: <list handler>
get    "/users/:id",       do: <get handler>
patch  "/users/:id",       do: <patch handler>
post   "/users/:id/status", do: <status handler>
```

The existing catch-all `match _ -> Letflow.Api.Response.not_found(conn)` stays,
unchanged, below these five.

### 1a. Required `@moduledoc` content for `Letflow.Routers.Identity` (AC6)

This is a concrete build requirement, not merely a design-doc narrative aid: as
part of this change, ELIXIR-DEV must write (or extend, if REQ-070's stub already
has one) a `@moduledoc` on `Letflow.Routers.Identity` whose text names, for each
of the five routes below, exactly which `Letflow.Identity` function(s) the
handler calls — so a reader of the shipped module (not this design doc) can see
route-layer thinness for themselves. The moduledoc must contain, at minimum,
one line or table row per route in this shape:

```
* POST   /users              -> Identity.create_user/2
* GET    /users              -> Identity.list_users/2
* GET    /users/:id          -> Identity.get_user/2
* PATCH  /users/:id          -> Identity.get_user/2, then Identity.update_user_profile/3
* POST   /users/:id/status   -> Identity.get_user/2, then Identity.update_user_status/3
```

(content mirrors §0's summary table's "Handler"/"`Letflow.Identity` fn called"
columns exactly — §0's table is this same mapping restated for this design
doc's own readers; the moduledoc text above is what must actually ship in
`lib/letflow/routers/identity.ex`). CODE-DESIGN-VALIDATOR (on re-review) and
REVIEWER (at Step 2d) check this by reading the real `@moduledoc` string in the
committed file and confirming each of the five lines is present and names the
correct function(s) — a moduledoc that only describes the module in general
terms ("handles user CRUD routes") without naming the five function-per-route
mappings does not satisfy AC6.

Every handler follows the same five-step shape; only the step-3/4/5 specifics
differ per handler. Steps 1-2 are common to all five and are not repeated per
handler below except to note deviations.

**Step 1 — scoped prefix (all five handlers, first thing, before any Repo call):**
`opts = Letflow.Api.Context.scoped_repo_opts(conn)`. On `{:error, :missing_auth_context}`
or `{:error, :invalid_tenant_id}`: `Letflow.Api.Response.internal_error(conn)` — these
two error cases should be unreachable in practice (`AuthPipeline` already populates
`auth_context` and validates the tenant id upstream of this router), so treating them
as a 500 rather than inventing a route-specific status code is deliberate defensive
handling, not a designed-for path. Do **not** halt on any other status here; only
`{:ok, prefix: schema}` proceeds to step 2.

**Step 2 — authorization (all five handlers, before any read OR write; get/list
included, since `:UsersManage` gates read too, per the existing `endpoint_policy_key`
mapping):**
```
ctx = %Authorization.AccessContext{
  user_id: conn.assigns.auth_context.user_id,
  roles: Authorization.roles_from_strings(conn.assigns.auth_context.roles)
}
decision = Authorization.evaluate_access(ctx, Authorization.endpoint_policy_key(method, path_template))
```
`decision.kind == :Deny403` → `Letflow.Api.Response.forbidden(conn, "insufficient permissions")`,
**no `Repo` call of any kind before this point or after this branch** — this is what
AC4's "the write does not occur" is structurally guaranteed by, not merely tested
after the fact. `decision.kind == :Allow` → continue to step 3. (`:AllowWithRowFilter`
is not reachable for `:UsersManage` — `evaluate_access/2`'s row-filter branch only
fires for `:TasksList`.)

### 2.1 — `POST /users` (create)

1. (steps 1-2 as above)
2. Validate body via `Letflow.Api.Validation.validate/2` against schema:
   ```
   [
     %FieldConstraint{name: "username", required: true, type: :string, reject_empty_string: true, min_length: 1, max_length: 255},
     %FieldConstraint{name: "display_name", required: true, type: :string, reject_empty_string: true, min_length: 1, max_length: 255},
     %FieldConstraint{name: "email", required: true, type: :string, reject_empty_string: true, min_length: 1, max_length: 255},
     %FieldConstraint{name: "status", required: false, type: :string, allowed_values: ["active", "inactive"]}
   ]
   ```
   `{:errors, field_errors}` → `Letflow.Api.Response.send_problem(conn, Letflow.Api.Validation.problem(field_errors))`.
   PROVENANCE (historical, not current decision authority):
   No email-shape constraint beyond non-empty string — `validation.zig`'s
   `FieldConstraint` has no email-format checker and neither does
   `Letflow.Api.Validation`; email format is not checked at this layer (matches
   R-Co, which defers `InvalidEmail` to the service layer — here, to
   `Identity.create_user/2`'s changeset, §7 gap 1's function).
3. `Identity.create_user(validated_attrs, opts)` (NEW, §7 gap 1) →
   - `{:ok, user}` → `Letflow.Api.Response.created(conn, user_map(user))`
   - `{:error, :duplicate_username}` → `Letflow.Api.Response.conflict(conn, "username already exists")`
   - `{:error, %Ecto.Changeset{}}` → `Letflow.Api.Response.unprocessable(conn, "validation failed")`
     (a changeset failure here is a second validation tier below `Letflow.Api.Validation`'s
     structural checks — e.g. `Ecto.Enum` cast failure on a value `allowed_values`
     didn't already reject, which cannot happen given the schema above, so this
     branch is defensive, not a designed-for path — same posture as step 1's
     `:missing_auth_context`/`:invalid_tenant_id`)

R-Co's handler accepts `tenant_id`, `caller_supplied_user_id`,
`caller_supplied_created_at` fields with special-cased rejection
(`CallerProvidedUserId`/`CallerProvidedCreatedAt` errors) — **not ported**: Letflow's
tenant is derived exclusively from `scoped_repo_opts/1` (INV-1), never accepted in
the body, so there is no `tenant_id` body field to reject in the first place; and
`Letflow.Api.Validation`'s schema-based `validate/2` only ever returns the
schema's own named fields (`Map.take(body, fields)`, see `validation.ex:206-207`),
so a caller-supplied `user_id`/`created_at` in the raw body is silently dropped by
construction, not specially detected and rejected. This is a structural
simplification, not a partial port — flagged here so it isn't mistaken for a missed
R-Co behavior.

### 2.2 — `GET /users` (list)

1. (steps 1-2 as above)
2. Parse query params (no body): `search` (string, optional), `status` (string,
   optional, must be `"active"`/`"inactive"` or reject `422 status_invalid`),
   `page_size` (via `Pagination.parse_page_size_param/1` then
   `Pagination.validate_page_size/1`), `cursor` (opaque string, optional).
3. If `cursor` present: `Pagination.decode_cursor(cursor, "U:", 0)` (prefix `"U:"`
   for **U**sers, matching the one-letter-prefix convention `Pagination`'s moduledoc
   example uses for `"T:"`/`"I:"`). `{:error, _}` (any of `:invalid_base64` /
   `:wrong_endpoint` / `:expired` / `:invalid_cursor`) → `Letflow.Api.Response.bad_request(conn, "invalid cursor")`.
4. `Identity.list_users(%{search: search, status: status, cursor: decoded_cursor_or_nil, page_size: page_size}, opts)`
   (NEW, §7 gap 2) → `{:ok, %{users: users, next_cursor: next_cursor_string_or_nil}}`
   (never an error tuple — an empty/last page is `{:ok, %{users: [], next_cursor: nil}}`,
   not an error; this matches `Pagination.Page.t/1`'s own shape, which has no error
   variant).
5. `Letflow.Api.Response.ok(conn, Pagination.page_response(Enum.map(users, &user_map/1), next_cursor) |> Jason.Encoder... )`
   — concretely, `Pagination.Page` already `@derive`s `{Jason.Encoder, only: [:items,
   :next_cursor, :count]}`, so the handler builds `Pagination.page_response(mapped_users,
   next_cursor)` and passes that struct directly to `Response.ok/2` (`ok/2`'s `body`
   parameter type is `map()`; a `%Pagination.Page{}` struct satisfies `Jason.encode!/1`
   identically, since encoding a struct with a derived encoder does not require it to
   literally be a bare map — same pattern `Letflow.Api.Error`'s own
   `@derive {Jason.Encoder, ...}` struct establishes elsewhere in this codebase).

Sort order: by `inserted_at` ascending, then `id` ascending as a tiebreaker.

**Updated 2026-08-22 (REVIEWER, Step 2d) to match shipped behavior — this
paragraph originally specified putting `inserted_at` itself into
`build_raw_cursor_timestamp_key/4`'s `sort_timestamp_us` slot, i.e. the field
`decode_cursor/4` reads (at the fixed offset right after the `"U:"` prefix) for
its 24h mint-freshness check. ELIXIR-DEV correctly did not implement it that
way: `decode_cursor/4`'s expiry check means "how long ago was this cursor
minted," not "how long ago was this row inserted," and a user row older than
24h would make every cursor built from it appear pre-expired the instant it's
minted — a real bug, not a stylistic choice. The shipped
`Letflow.Identity.list_users/2` (private `build_next_cursor/1` /
`decode_users_cursor/1`) instead puts the actual mint time
(`System.system_time(:microsecond)`) in the `sort_timestamp_us` slot, and
carries `inserted_at`/`id` — this endpoint's real sort key and tiebreaker — in
the payload's `key`/`cursor_created_at_us` slots purely for their textual
position, not those parameters' literal names. SECURITY-REVIEWER confirmed
this weakens no security property (`handoffs/WF02-REQ073-20260822/step-02c-security-reviewer.json`).
This is the version to build against for any future endpoint copying this
cursor shape — do not resurrect the original inserted_at-as-sort_timestamp_us
reading. **Open question OQ-1** (tiebreak field choice, `id` vs. a distinct
timestamp) is unaffected by this correction and still stands — see §7.)

**Deliberate divergence from R-Co, stated explicitly (not silent):** R-Co's
`ListUsersQueryParams` is `page`/`page_size` (offset pagination). Letflow's AC1
explicitly requires "list returns a cursor page" per REQ-067's mechanism — cursor
pagination replaces R-Co's offset pagination for this endpoint, matching the
project's already-established S4 pagination strategy. This is the same kind of
considered, documented divergence `Letflow.Api.Response`'s moduledoc already
models for Content-Type.

### 2.3 — `GET /users/:id` (get)

1. (steps 1-2 as above)
2. `Identity.get_user(id, opts)` (NEW, §7 gap 3) →
   - `{:ok, user}` → `Letflow.Api.Response.ok(conn, user_map(user))`
   - `{:error, :not_found}` → `Letflow.Api.Response.not_found(conn)` (INV-5: this is
     the exact same call R-Co's cross-tenant path and never-existed path both reach,
     since `opts`'s `:prefix` already scopes the `Repo.get` to the caller's own
     tenant schema — see §4)

`:id` is read from `conn.params["id"]` (`Plug.Router`'s path-capture convention). No
UUID-shape pre-validation on `:id` is performed by this handler — an
`Ecto.UUID.cast/1` failure inside `Identity.get_user/2`'s own `Repo.get/3` call
(binary_id primary key) is handled the same way a genuinely-absent id is
(`Repo.get/3` returns `nil` for a syntactically invalid binary_id string passed to
a `:binary_id` column via Ecto — it does not raise; `Ecto.UUID` cast failures inside
`Repo.get/3` degrade to "not found," never an exception, matching every other
lookup-by-id path in this codebase), so no special-cased 422 is needed here, and
none is added.

### 2.4 — `PATCH /users/:id` (patch)

1. (steps 1-2 as above)
2. `Identity.get_user(id, opts)` first (existing-value pre-fetch, matching R-Co's
   own `handlePatchUser`, which reads `existing` before computing defaults for
   omitted fields) → `{:error, :not_found}` → `Letflow.Api.Response.not_found(conn)`,
   same as §2.3.
3. Validate body via `Letflow.Api.Validation.validate/2` against schema (all three
   fields optional — a PATCH may omit any subset):
   ```
   [
     %FieldConstraint{name: "display_name", required: false, type: :string, reject_empty_string: true, min_length: 1, max_length: 255},
     %FieldConstraint{name: "email", required: false, type: :string, reject_empty_string: true, min_length: 1, max_length: 255},
     %FieldConstraint{name: "status", required: false, type: :string, allowed_values: ["active", "inactive"]}
   ]
   ```
   `{:errors, field_errors}` → same problem-document path as §2.1.
4. `Identity.update_user_profile(id, validated_attrs, opts)` (NEW, §7 gap 4) — takes
   `validated_attrs` as a **partial** map (only keys present in the request body,
   per `Letflow.Api.Validation.validate/2`'s `Map.take(body, fields)` contract — a
   key genuinely absent from the request is absent from `validated_attrs`, not
   present with the existing value already substituted in by the handler); merging
   in the existing value for an omitted field is `Identity.update_user_profile/3`'s
   own changeset responsibility (`cast/3` over a `%User{}` already carrying the
   existing values naturally preserves any field `attrs` doesn't mention — no
   separate "existing" struct needs threading from the handler for this, unlike
   R-Co's own explicit `existing.display_name` fallback pattern, which exists in Zig
   only because Zig's JSON parsing has no equivalent to Ecto's cast-over-existing-struct
   idiom). →
   - `{:ok, user}` → `Letflow.Api.Response.ok(conn, user_map(user))`
   - `{:error, %Ecto.Changeset{}}` → `Letflow.Api.Response.unprocessable(conn, "validation failed")`
   - `{:error, :not_found}` → `Letflow.Api.Response.not_found(conn)` (defensive:
     the row could vanish between step 2's read and this write in a genuine race;
     R-Co's own handler has the identical two-lookup shape and the identical
     latent race, so this is not a new gap introduced by this port)

### 2.5 — `POST /users/:id/status` (status update)

1. (steps 1-2 as above — **gap 4, §7**: `Authorization.endpoint_policy_key/2` needs
   a new clause for `"POST", "/users/:id/status"` mapping to `:UsersManage`, since no
   existing clause matches this path/method pair)
2. `Identity.get_user(id, opts)` first, matching R-Co's `handleUpdateUserStatus`
   flow order (verify-then-update) → `{:error, :not_found}` → `not_found`, same as
   §2.3. (R-Co's own `handleUpdateUserStatus` does not pre-fetch — its
   `service.updateUserStatus` call handles the not-found case directly. This design
   adds the pre-fetch anyway, for one reason: it costs nothing extra under INV-5's
   already-established query-count symmetry, since `Identity.update_user_status/3`
   below also does a `Repo.get` internally as part of its own not-found handling
   either way — the two-call vs. one-call shape is not itself a query-count/timing
   signal difference across the cross-tenant-vs-never-existed comparison, because
   both queries always run against the identical `opts`-scoped prefix regardless of
   which id is probed.)
3. Validate body via `Letflow.Api.Validation.validate/2` against schema:
   ```
   [%FieldConstraint{name: "status", required: true, type: :string, allowed_values: ["active", "inactive"]}]
   ```
   `{:errors, field_errors}` → same problem-document path as §2.1.
4. `Identity.update_user_status(id, validated_status, opts)` (NEW, §7 gap 5) →
   - `{:ok, user}` → `Letflow.Api.Response.ok(conn, user_map(user))`
   - `{:error, :not_found}` → `not_found` (defensive, same race-window note as §2.4)
   - `{:error, %Ecto.Changeset{}}` → `unprocessable` (defensive — `allowed_values`
     already rejects anything the `Ecto.Enum` cast could reject, so unreachable in
     practice, listed for completeness matching the codebase's existing "list the
     defensive branch anyway" convention seen throughout `Letflow.Api.Authorization`
     and `Letflow.Identity`)

## 3. Response allowlist (AC5, INV-2)

`user_map/1` — a private function in `Letflow.Routers.Identity`, **not** a
`Jason.Encoder` derivation on `Letflow.Identity.User` — builds this exact map from
a `%User{}` struct, and only this map is ever passed to `Response.ok/created/2`:

```
%{
  "id" => user.id,
  "username" => user.username,
  "display_name" => user.display_name,
  "email" => user.email,
  "status" => Atom.to_string(user.status),
  "auth_source" => Atom.to_string(user.auth_source),
  "inserted_at" => DateTime shape TBD by ELIXIR-DEV's existing convention
                    for other timestamp-bearing responses (not decided here --
                    see OQ-2, §7),
  "updated_at" => same as inserted_at
}
```

**Exactly 8 keys.** Confirmed against `Letflow.Identity.User`'s full field list
(`lib/letflow/identity/user.ex:36-45`): `id`, `username`, `display_name`, `email`,
`password_hash`, `status`, `auth_source`, `external_id`, `external_realm`, plus
`inserted_at`/`updated_at` from `timestamps()`. **`password_hash`, `external_id`,
`external_realm` are deliberately excluded** — `password_hash` per INV-2's explicit
"never serialise password material" instruction; `external_id`/`external_realm`
are OIDC-linkage identifiers with no R-Co `serializeUser` precedent to check against
here, but are excluded on the same "field selection happens server-side, allowlist
not denylist" principle — nothing about them is secret, but they are not part of the
documented public user representation either, and adding them later is a deliberate
allowlist edit, not a default inclusion. **This is the concrete mechanism that
satisfies AC5's "adding a field to the Ecto schema without updating the allowlist
does not change the response" property**: `user_map/1` is a hand-built map keyed
literally, so a hypothetical tenth schema field simply has no corresponding key in
this function and never appears, with zero additional code required to keep it out.

## 4. Cross-tenant-404 test design (AC2, INV-5)

Mirrors REQ-072's own `context_test.exs` "cross-tenant 404 is byte-identical"
`describe` block (`test/letflow/api/context_test.exs:160-244`), but through the
real handler this time — REQ-072's own test predates any real handler existing
(REQ-070's stub), so it exercised `Repo.get/3` + `Response.not_found/1` one level
below HTTP dispatch. This test now dispatches through `Letflow.Routers.Identity.call/2`
directly (bypassing `Letflow.Plugs.AuthPipeline` — see §6's dispatch-mechanism
rationale), for the `GET /users/:id` handler specifically:

```
test "a caller authenticated for tenant A requesting a user id existing only in
      tenant B gets a byte-identical 404 to a never-existed id" do
  tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req073-cross-a")
  tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req073-cross-b")

  tenant_b_user =
    %User{} |> User.<changeset-tbd> |> Repo.insert!(prefix: tenant_b.schema_name)

  conn_a = fn id -> build_conn(:get, "/users/#{id}", tenant_a, roles: ["PLATFORM_ADMIN"]) end

  resp_cross_tenant = Letflow.Routers.Identity.call(conn_a.(tenant_b_user.id), @opts)
  resp_never_existed = Letflow.Routers.Identity.call(conn_a.(Ecto.UUID.generate()), @opts)

  assert resp_cross_tenant.status == 404
  assert resp_cross_tenant.status == resp_never_existed.status
  assert resp_cross_tenant.resp_body == resp_never_existed.resp_body
end
```

`build_conn/3` (a private test helper) assigns `:auth_context` (with `tenant_id:
tenant_a.tenant_id`) and `:trace_id` (pinned to a fixed literal, matching
`context_test.exs:190`'s own comment on why `trace_id` must be pinned — otherwise
the two responses' `trace_id` fields would differ even when every other byte
matches, which would be a false failure of this exact test, not a real difference)
directly on the conn before calling the router — see §6 for why direct sub-router
dispatch (not a full `Letflow.Router.call/2` HTTP round-trip through `AuthPipeline`)
is this design's chosen test-dispatch mechanism. The query-count-symmetry test
(`context_test.exs:209-236`'s telemetry-counter pattern) is **not** duplicated here
per-handler — REQ-072's own test already proves the underlying `Repo.get/3`-via-
`:prefix` mechanism is symmetric; this test's job is only to prove the **handler**
built on top of that mechanism doesn't introduce its own asymmetry (e.g. an extra
existence-check `Repo` call before calling `Identity.get_user/2`), which the
byte-identical-body assertion combined with §2's "no extra Repo call" wiring already
covers structurally — TEST-DESIGNER may add a telemetry-counter assertion here too
if it judges the structural argument insufficient; not mandated by this design.

## 5. Permission-denial test design (AC4)

For `POST /users`, `PATCH /users/:id`, `POST /users/:id/status` — three tests, one
per write handler, each with this shape (create shown; patch/status-update mirror
it against a pre-existing row instead of an absent one):

```
test "a caller lacking UsersGroupsRolesManage gets 403 on create, and no row is inserted" do
  tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req073-403-create")
  count_before = Repo.aggregate(User, :count, prefix: tenant.schema_name)

  conn = build_conn(:post, "/users", tenant, roles: [], body: %{username: "x", display_name: "X", email: "x@example.com"})
  resp = Letflow.Routers.Identity.call(conn, @opts)

  assert resp.status == 403
  assert Repo.aggregate(User, :count, prefix: tenant.schema_name) == count_before
end
```

For patch/status-update, the row-unchanged assertion re-fetches the specific row
by id and asserts every field is byte-identical to a snapshot taken before the
request, not merely that the row count is unchanged (a row count check alone would
miss an in-place field mutation, which is exactly the failure mode AC4 calls out:
"asserting the database is unchanged, not only the status code"):

```
before = Identity.get_user!(user.id, prefix: tenant.schema_name)   # or Repo.get! directly
resp = Letflow.Routers.Identity.call(patch_conn, @opts)
assert resp.status == 403
after_ = Repo.get!(User, user.id, prefix: tenant.schema_name)
assert after_ == before
```

`roles: []` (no roles at all, and separately a test with `roles: ["TASK_WORKER"]`
as a role that legitimately exists but doesn't grant `UsersGroupsRolesManage`) both
belong here — TEST-DESIGNER should cover at least one of each shape (absent-any-role
and wrong-role) since `Authorization.evaluate_access/2`'s `Deny403` branch is
reached identically by both, but a reviewer independently confirming AC4 should see
both shapes exercised, not just the degenerate empty-roles case.

## 6. Tenant-isolation list test design (AC3, INV-1)

```
test "listing users as tenant A returns only tenant A's users, even with similarly-named tenant B users" do
  tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req073-iso-a")
  tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req073-iso-b")

  insert_user!(tenant_a, username: "alice", display_name: "Alice Anderson")
  insert_user!(tenant_b, username: "alice", display_name: "Alice Anderson")  # same names, different tenant
  insert_user!(tenant_b, username: "alice2", display_name: "Alice Anderson 2")

  conn = build_conn(:get, "/users", tenant_a, roles: ["PLATFORM_ADMIN"])
  resp = Letflow.Routers.Identity.call(conn, @opts)

  assert resp.status == 200
  body = Jason.decode!(resp.resp_body)
  assert length(body["items"]) == 1
  assert Enum.map(body["items"], & &1["username"]) == ["alice"]
end
```

`insert_user!/2` is a small new test helper (test-only, `test/support/` or inline
in the test file — TEST-DESIGNER's call which) that inserts a `%User{}` directly
via `Repo.insert!(prefix: tenant.schema_name)`, bypassing `Identity.create_user/2`
entirely — this test is about read-side isolation, not create-side behavior, so it
should not depend on the create handler/function also being correct (test
independence). Note `tenant_a`'s username uniqueness index is per-schema (Decision
0006 §3.1), so inserting `username: "alice"` into both tenant A's and tenant B's
schema in the same test is legal — this is in fact the exact scenario that index
migration's own comment (`20260819000003_create_users_tenant_scoped.exs`) says was
the point of moving to per-tenant uniqueness.

## 7. Domain-function gaps found in `Letflow.Identity` (design decision, not silent)

`Letflow.Identity` today has exactly four public functions (`provision_oidc_user/4`,
`resolve_tenant_by_realm/1`, `resolve_realm_by_tenant/1`, `verify_realm_ownership/2`)
— all OIDC/tenant-realm plumbing, **zero** general user-CRUD functions. Every
handler above needs one that doesn't exist. Per the requirement text's own
instruction ("if a handler needs a domain function that does not exist, add the
thin function there rather than inlining a Repo query in the handler"), these five
are this design's required additions to `lib/letflow/identity.ex` — thin,
Repo-backed, no business logic beyond a changeset and a query, matching this
module's existing style:

1. **`create_user(attrs :: map(), opts :: opts()) :: {:ok, User.t()} | {:error, :duplicate_username} | {:error, Ecto.Changeset.t()}`**
   — inserts a new `%User{}` via a new changeset function on `Letflow.Identity.User`
   (`create_changeset/2`, sibling to the existing `jit_changeset/2` — casts
   `username`/`display_name`/`email`/`status` (default `"active"`), sets
   `auth_source: :internal`, and — **open question** — what `password_hash` value
   an internally-created user gets, since this handler group has no password-setting
   endpoint of its own; R-Co's `identity_service.createUser` presumably has an
   PROVENANCE (historical, not current decision authority):
   answer this design doesn't have visibility into without reading `identity/service.zig`,
   out of this requirement's named source-file scope. **OQ-3**: ELIXIR-DEV must pick
   a placeholder value (matching `jit_changeset/2`'s own `"__OIDC_ONLY__"` sentinel
   pattern, e.g. `"__NO_PASSWORD_SET__"` or similar) and record the choice — not
   silently invent one without a trace). Maps a `username` unique-constraint
   violation to `{:error, :duplicate_username}`, mirroring
   `username_unique_conflict?/1`'s existing constraint-name check
   (`lib/letflow/identity.ex:255-261`) — reusable as-is, or duplicated privately if
   reuse creates an awkward cross-module dependency (ELIXIR-DEV's call).

2. **`list_users(params :: %{search: String.t() | nil, status: :active | :inactive | nil, cursor: Pagination.Cursor.t() | nil, page_size: pos_integer()}, opts :: opts()) :: {:ok, %{users: [User.t()], next_cursor: String.t() | nil}}`**
   — queries `users` filtered by `status` (if present) and `search` (if present,
   `ILIKE` against `username` OR `display_name` OR `email` — R-Co's `search` param
   has no documented field scope visible from the handler signature alone; this
   three-field scope is this design's own choice, flagged as **OQ-4** since R-Co's
   `identity_service.listUsers` implementation (not read, out of this requirement's
   named source-file scope) may search a narrower or wider field set), ordered by
   `inserted_at` ascending then `id` ascending, `LIMIT page_size + 1` (the
   fetch-one-extra-to-detect-a-next-page idiom), builds `next_cursor` via
   `Pagination.build_raw_cursor_timestamp_key/4` + `Pagination.encode_cursor/1` when
   a `(page_size + 1)`-th row exists, `nil` otherwise.

3. **`get_user(id :: Ecto.UUID.t() | String.t(), opts :: opts()) :: {:ok, User.t()} | {:error, :not_found}`**
   — `Repo.get(User, id, opts)`, mapping `nil` to `{:error, :not_found}`. The
   simplest of the five; exists mainly so every handler (including patch and
   status-update's own pre-fetch step) shares one lookup function rather than each
   handler inlining its own `Repo.get`.

4. **`update_user_profile(id :: Ecto.UUID.t(), attrs :: map(), opts :: opts()) :: {:ok, User.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}`**
   — `Repo.get(User, id, opts)` (→ `{:error, :not_found}` on `nil`), then a new
   `profile_changeset/2` on `Letflow.Identity.User` (`cast(attrs, [:display_name,
   :email, :status])`, no `validate_required` — since every field is optional on a
   PATCH, an absent key must leave the existing value untouched, which `cast/3`
   already does for keys not present in `attrs`), then `Repo.update(changeset,
   opts)`.

5. **`update_user_status(id :: Ecto.UUID.t(), status :: :active | :inactive, opts :: opts()) :: {:ok, User.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}`**
   — `Repo.get(User, id, opts)` (→ `{:error, :not_found}` on `nil`), then a new
   `status_changeset/2` (`cast(%{status: status}, [:status]) |> validate_required([:status])`),
   then `Repo.update(changeset, opts)`. Could share `profile_changeset/2` (calling
   it with only `%{status: status}`) instead of a separate function — **OQ-5**, left
   to ELIXIR-DEV's judgement, since either shape satisfies this design's contract
   identically and neither is a security- or correctness-relevant choice.

Additionally, one gap outside `Letflow.Identity` itself:

6. **`Letflow.Api.Authorization.endpoint_policy_key/2` has no clause for
   `("POST", "/users/:id/status")`** — every other of the five paths already has a
   matching clause (`endpoint_policy_key("POST", "/users")`,
   `endpoint_policy_key("GET", path) when path in ["/users", "/users/:id"]`,
   `endpoint_policy_key("PATCH", "/users/:id")`, all → `:UsersManage`, per
   `lib/letflow/api/authorization.ex:211-213`). This design adds one clause:
   `def endpoint_policy_key("POST", "/users/:id/status"), do: :UsersManage`. This is
   a small, additive change to an already-shipped REQ-069 module — flagged here
   rather than silently patched in, since `Letflow.Api.Authorization` belongs to a
   different, already-`done` requirement.

## Open questions (not silently resolved)

PROVENANCE (historical, not current decision authority):
- **OQ-1** — cursor tiebreak field for `list_users/2`: this design uses `id` as the
  tiebreaker for two rows sharing an `inserted_at` value (§2.2). R-Co's own
  `pagination.zig` cursor-building helpers assume a distinct
  `sort_timestamp`/`cursor_created_at` pair; `users` has only one timestamp field
  usable for both roles. Confirmed workable, not confirmed to match any R-Co
  precedent (R-Co's list endpoint is offset-paginated, so no cursor precedent
  exists to check against here at all).
- **OQ-2** — exact JSON shape of `inserted_at`/`updated_at` in `user_map/1` (ISO
  8601 string via `DateTime.to_iso8601/1`, vs. some other existing convention
  elsewhere in this codebase for a timestamp-bearing API response). Not resolved
  here because no other REQ-073-adjacent response builder was found to check
  against during this design session — ELIXIR-DEV should grep for an existing
  precedent before picking one, and note the choice in its own handoff if none is
  found.
- **OQ-3** — placeholder `password_hash` value for an internally-created user
  (§7 gap 1).
PROVENANCE (historical, not current decision authority):
- **OQ-4** — exact field scope of the `search` query param for `list_users/2`
  (§7 gap 2) — this design's three-field (`username`/`display_name`/`email`) choice
  is not checked against R-Co's `identity_service.listUsers` implementation, which
  was out of this requirement's named source-file scope (`identity.zig` only).
- **OQ-5** — whether `update_user_status/3` shares `profile_changeset/2` or gets
  its own `status_changeset/2` (§7 gap 5) — not security- or correctness-relevant,
  left to ELIXIR-DEV.
- **OQ-6** — this design recommends (§ below) TEST-DESIGNER use direct
  `Letflow.Routers.Identity.call/2` dispatch with `conn.assigns[:auth_context]` set
  directly, bypassing the full `Letflow.Router` → `Letflow.Plugs.ApiPipeline` →
  `Letflow.Plugs.AuthPipeline` chain, for every test in this design (§4/§5/§6) —
  see §6 (dispatch mechanism) below for the full rationale. This is because neither
  existing test-only OIDC token double
  (`Letflow.Oidc.TokenVerifierDouble`/`Letflow.Oidc.ConfigurableTokenVerifierDouble`)
  can mint a token claiming `PLATFORM_ADMIN` (or any role other than the fixed
  `"VIEWER"`, which is not even in `Authorization.roles_from_strings/1`'s
  recognized set) — both are hardcoded to a single roles claim shape. Whether a
  fuller true-end-to-end path (through real bearer-token auth) should also be
  added by extending `ConfigurableTokenVerifierDouble` with a roles-parameterized
  token format is left to TEST-DESIGNER/CODE-DESIGN-VALIDATOR's judgement — not
  blocking, since direct sub-router dispatch is an established precedent in this
  codebase (REQ-070 AC2's `router_test.exs:104-113`, which dispatches directly
  through a real sub-router the same way this design's tests do — note
  REQ-072's `context_test.exs` is **not** a precedent for this specific
  mechanism: its tests bypass the router entirely, calling `Letflow.Api.Context`
  functions directly, rather than dispatching through a sub-router) and "through
  the real router" (AC1's wording) is satisfied by calling
  `Letflow.Routers.Identity.call/2` directly — that module *is* "the real
  router" the acceptance criterion names, distinct from "the real full
  HTTP+JWT pipeline," which AC1's text does not require.

## 6b. Dispatch mechanism for all five handlers' tests (referenced above)

Every test in §4/§5/§6 dispatches via a shared private test helper (name/shape,
not full code):

```
build_conn(method, path, tenant_fixture, roles: [...], body: %{} | nil) :: Plug.Conn.t()
```

which constructs a `Plug.Test.conn/3`, sets `content-type: application/json` +
JSON-encoded body when `body` is given, and assigns `:auth_context` (`%{user_id:
Ecto.UUID.generate(), tenant_id: tenant_fixture.tenant_id, roles: roles}`) and a
fixed `:trace_id` directly on the conn — mirroring `context_test.exs`'s own
`assign(:auth_context, %{...})` pattern (`context_test.exs:114`,`:183-187`)
verbatim, not a new mechanism. The conn is then passed to
`Letflow.Routers.Identity.call(conn, @opts)`, where `@opts =
Letflow.Routers.Identity.init([])` (matching `router_test.exs:30`'s existing
`@identity_opts` precedent exactly).

**This intentionally bypasses `Letflow.Plugs.ApiPipeline`'s `Plug.Parsers` step**
(since `Plug.Test.conn/3`'s connection is not run through the top-level `Router`),
so any test posting a JSON body must pre-populate `conn.body_params` itself, the
same way `Plug.Test.conn/3` + a raw JSON string body requires elsewhere in this
codebase when a router (not the full pipeline) is called directly — TEST-DESIGNER
should follow whatever this codebase's own established convention is for that
(`Plug.Parsers.call/2` invoked manually in the helper is one option; a literal
`%Plug.Conn{}` with `body_params` pre-assigned is another) — left as an
implementation-level test-helper decision, not a fork in this design's contract,
since either produces an identical `conn.body_params` for the handler to read.
