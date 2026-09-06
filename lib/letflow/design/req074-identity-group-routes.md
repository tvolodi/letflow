# REQ-074 — Identity routes 2/4: groups and group membership

PROVENANCE (historical, not current decision authority):
Design for extending `lib/letflow/routers/identity.ex` (currently REQ-073's five
user-CRUD routes) with seven group-management routes, porting
`src/api/routes/identity.zig`'s `handleCreateGroup` (L343), `handleAddGroupMember`
(L399), `handleListGroups` (L447), `handleDeleteGroup` (L478),
`handleListGroupMembersArray` (L495), `handleListGroupMembers` (L526),
`handleRemoveGroupMember` (L551).

No implementation code below — signatures, data shapes, and test specs only.

## 0. Summary of composition

| Route | `Letflow.Identity` fn called | Response |
|---|---|---|
| `POST /groups` | `Identity.create_group/2` (NEW, §7.1) | 201, `group_map/1` |
| `POST /groups/:id/members` | `Identity.add_group_member/3` (NEW, §7.2) | 200/201, member-result map |
| `GET /groups` | `Identity.list_groups/1` (NEW, §7.3) | 200, `%{items: [group_map], total: n}` |
| `DELETE /groups/:id` | `Identity.delete_group/2` (NEW, §7.4) | 204, or 404 (not-found-or-has-members, §5) |
| `GET /groups/:id/members` | `Identity.list_group_members/3` (NEW, §7.5) | 200, cursor `Page.t(user_map)` — **the only member-listing endpoint, §1 finding** |
| `DELETE /groups/:id/members/:user_id` | `Identity.remove_group_member/3` (NEW, §7.6) | 204 |

All six resolve `:GroupsManage` via the **already-shipped**
`Letflow.Api.Authorization.endpoint_policy_key(method, "/groups" <> _rest)` clause
(`lib/letflow/api/authorization.ex:216-218`, matches `POST`/`GET`/`DELETE` against
any path starting `/groups` — covers every route in this table with zero new
clauses needed) → `required_permission/1` already maps `:GroupsManage` to
`:UsersGroupsRolesManage` (`authorization.ex:315-316`). **No gap here** — unlike
REQ-073's `POST /users/:id/status` gap, this policy-key wiring was built ahead of
this requirement and needs no change.

## 1. Finding: `handleListGroupMembers` vs `handleListGroupMembersArray` (AC6)

PROVENANCE (historical, not current decision authority):
**Evidence — R-Co's actual route table**, `src/main.zig:1377-1442` (the `groups`
resource dispatch block, confirmed the canonical route-registration point per
REQ-073's own design precedent of reading `routes.zig`/`main.zig` rather than the
handler file alone):

PROVENANCE (historical, not current decision authority):
```
GET    /groups                       -> identity_routes.handleListGroups        (main.zig:1380)
POST   /groups                       -> identity_routes.handleCreateGroup       (main.zig:1384)
GET    /groups/:id/members           -> identity_routes.handleListGroupMembersArray (main.zig:1393)
POST   /groups/:id/members           -> identity_routes.handleAddGroupMember    (main.zig:1397)
DELETE /groups/:id/members           -> INLINE bulk-remove-all-members logic    (main.zig:1400-1430)
                                         (lists up to 200 members via
                                         id_svc.listGroupMembers/4 directly, then
                                         loops id_svc.removeGroupMember/4 per member —
                                         NOT identity_routes.handleRemoveGroupMember)
DELETE /groups/:id                   -> identity_routes.handleDeleteGroup       (main.zig:1436)
```

PROVENANCE (historical, not current decision authority):
`grep -n "handleListGroupMembers(\|handleRemoveGroupMember" src/main.zig` (full
file, not just this block) returns **zero** registration hits for either symbol —
only `handleListGroupMembersArray` and the inline bulk-delete block appear. Both
`handleListGroupMembers` (L526, the cursor-paginated, `PLATFORM_ADMIN`-gated
variant) and `handleRemoveGroupMember` (L551, single-member removal) are exercised
**only** by `identity.zig`'s own unit tests calling the function directly
(`TC-IDN-02-03` at `identity.zig:1710`, `TC-IDN-02-04` at `identity.zig:1783`) —
never reachable through any HTTP route R-Co actually serves.

**Determination (AC6): these are effectively one served member-listing endpoint,
not two.** `handleListGroupMembersArray` is what R-Co serves at
`GET /groups/:id/members` — a bare JSON array, fixed at `page_size: 200`, no
cursor, no `next_cursor`. `handleListGroupMembers` is real, tested, working code
that is **never wired to any route** — dead from the route table's perspective,
the same "implemented but not served" shape AC6 warned about.

PROVENANCE (historical, not current decision authority):
**Design decision, following REQ-073's own established precedent (§2.2 of
`req073-identity-user-routes.md`, which replaced R-Co's offset pagination with
cursor pagination for the same reason):** REQ-074's own AC4 requires "listing
group members is cursor-paginated via REQ-067... across at least two pages" —
this is Letflow's own explicit acceptance criterion, not a literal-port
requirement, and it cannot be satisfied by porting the array shape R-Co actually
serves. So this design ports **one** endpoint, `GET /groups/:id/members`,
using **Letflow's cursor-pagination page shape** (`Letflow.Api.Pagination.Page`,
same as REQ-073's `list_users/2`) — i.e. it takes `handleListGroupMembers`'s
*mechanism* (cursor pagination, which R-Co already built but never routed) and
gives it the one route R-Co's table actually assigns to member-listing. It does
**not** port a second, separate bare-array endpoint, and it does **not** carry
forward `handleListGroupMembers`'s R-Co-only `PLATFORM_ADMIN`-exclusive gate
(§2.5 below explains why: `:GroupsManage`'s existing policy mapping, shared by
every other group route, already gates this uniformly).

This must ship in the `@moduledoc` verbatim (AC6), e.g.:

PROVENANCE (historical, not current decision authority):
> R-Co defines two member-listing handlers, `handleListGroupMembersArray`
> (bare array, served at `GET /groups/:id/members`, `main.zig:1393`) and
> `handleListGroupMembers` (cursor-paginated, never routed —
> `grep -n "handleListGroupMembers(" src/main.zig` has no hit). This module
> ports one endpoint, `GET /groups/:id/members`, using the cursor-paginated
> mechanism (matching REQ-067/AC4), not the served bare-array shape — the same
> kind of deliberate divergence REQ-073 made for `list_users/2`.

## 1b. Finding: `handleRemoveGroupMember` is also unrouted (flagged, not silently resolved)

PROVENANCE (historical, not current decision authority):
Same evidence as §1: `handleRemoveGroupMember` (single `(group_id, user_id)`
removal) has no route in `main.zig`. What R-Co's route table actually serves at
`DELETE /groups/:id/members` (no `:user_id` segment) is a **bulk remove-all**
operation — list up to 200 members, then call `removeGroupMember` once per
member, silently swallowing (`catch {}`) any per-member error. This is a
materially different operation (delete every membership row for the group) from
what the requirement's text and AC list describe (no acceptance criterion
mentions "remove all members"; the requirement names `handleRemoveGroupMember`
specifically, which is single-member).

**Design decision (flagged, since this is a genuine deviation from what R-Co's
live route table serves, not merely a redundant duplicate like §1):** this design
ports `handleRemoveGroupMember`'s single-member semantics at
`DELETE /groups/:id/members/:user_id` — a route R-Co's own table never actually
binds this handler to, but whose path shape is implied by the handler's own
`(group_id, user_id)` signature and is the only sensible single-member REST
verb. This design does **not** replicate the bulk-remove-all-members behavior
found live at R-Co's bodyless `DELETE /groups/:id/members` — that behavior is
not named anywhere in REQ-074's acceptance criteria, and silently defaulting to
"delete every membership in the group" on an unqualified DELETE would be a
surprising, higher-blast-radius operation to introduce without it being asked
for. **Recorded as an open question for REVIEWER, not silently decided past
them** — see OQ-1.

## 2. Route wiring — `lib/letflow/routers/identity.ex`

```
post   "/groups",                          do: <create handler>
get    "/groups",                          do: <list handler>
delete "/groups/:id",                      do: <delete handler>
post   "/groups/:id/members",              do: <add-member handler>
get    "/groups/:id/members",              do: <list-members handler, cursor-paginated>
delete "/groups/:id/members/:user_id",     do: <remove-member handler>
```

All six reuse the existing `with_authorized_scope/4` preamble (already defined
in this file by REQ-073) unchanged — `method`/`path_template` literal constants
per route, e.g. `with_authorized_scope(conn, "POST", "/groups", fn conn, opts ->
...)`, `with_authorized_scope(conn, "DELETE", "/groups/:id/members/:user_id", fn
conn, opts -> ... end)`. Every path template resolves to `:GroupsManage` via the
already-shipped wildcard clause (§0) — no `Authorization` module change needed.
`Plug.Router`'s macro dispatch matches routes in declaration order and
`"/groups/:id"` (delete) does not shadow `"/groups/:id/members"` or
`"/groups/:id/members/:user_id"` (different segment counts), so declaration
order among these six is not itself load-bearing — stated for completeness, not
because a conflict was found.

The existing catch-all `match _ -> Response.not_found(conn)` stays, unchanged,
below these six (and below REQ-073's existing five).

### 2a. Required `@moduledoc` additions (AC6)

Extend the existing per-route table (REQ-073's `req073-identity-user-routes.md`
§1a pattern) with one line per new route:

```
* POST   /groups                        -> Identity.create_group/2
* GET    /groups                        -> Identity.list_groups/1
* DELETE /groups/:id                    -> Identity.delete_group/2
* POST   /groups/:id/members            -> Identity.add_group_member/3
* GET    /groups/:id/members            -> Identity.list_group_members/3 (cursor-paginated — see §1 finding)
* DELETE /groups/:id/members/:user_id   -> Identity.remove_group_member/3
```

Plus the §1/§1b findings verbatim (the exact paragraph text is this design's
own — ELIXIR-DEV may tighten wording but must preserve both findings' substance:
which handler is unrouted, and what R-Co's live route actually does instead).

## 3. Per-handler composition

Every handler follows REQ-073's shared shape: **Step 1** (scoped prefix via
`Context.scoped_repo_opts/1`) then **Step 2** (authorization via
`with_authorized_scope/4`) run before any `Repo` call, identically to REQ-073's
five routes — no new preamble needed, this is the same `with_authorized_scope/4`
function, called with a different `path_template` literal per route.

### 3.1 — `POST /groups` (create)

1. (steps 1-2)
2. Validate body via `Validation.validate/2`:
   ```
   [
     %FieldConstraint{name: "name", required: true, type: :string, reject_empty_string: true, min_length: 1, max_length: 255},
     %FieldConstraint{name: "display_name", required: false, type: :string, reject_empty_string: true, min_length: 1, max_length: 255},
     %FieldConstraint{name: "description", required: false, type: :string, max_length: 1000}
   ]
   ```
   `{:errors, _}` → `Response.send_problem(conn, Validation.problem(field_errors))`.
PROVENANCE (historical, not current decision authority):
3. `display_name` defaults to `name` when omitted or empty (matches R-Co's
   `handleCreateGroup`, `identity.zig:361-371`: `if (dn) |v| if (v.len==0) name else v else name`)
   — this default is applied by `Identity.create_group/2` itself (§7.1), not the
   handler, so the handler passes `validated_attrs` through unchanged.
4. `Identity.create_group(validated_attrs, opts)` (NEW, §7.1) →
   - `{:ok, group}` → `Response.created(conn, group_map(group))`
   - `{:error, :duplicate_group_name}` → `Response.conflict(conn, "group name already exists")`
   - `{:error, %Ecto.Changeset{}}` → `Response.unprocessable(conn, "validation failed")`

PROVENANCE (historical, not current decision authority):
R-Co's `description` field: empty string is normalized to `nil` at the handler
layer (`identity.zig:373-380`) — same normalization applies here, inside
`Identity.create_group/2`'s changeset (`nil`-if-empty), not the router.

### 3.2 — `POST /groups/:id/members` (add member)

1. (steps 1-2)
PROVENANCE (historical, not current decision authority):
2. Validate body: accepts either `"user_id"` (string) or `"user_ids"` (array,
   first element only — matching R-Co's exact `identity.zig:415-430` fallback
   shape, ported verbatim since AC list doesn't call out a divergence here):
   ```
   [
     %FieldConstraint{name: "user_id", required: false, type: :string},
     %FieldConstraint{name: "user_ids", required: false, type: :array}
   ]
   ```
   Handler-level logic (not a `Validation` schema concern): if `"user_id"` key
   present, use it; else if `"user_ids"` present and is a non-empty array whose
   first element is a string, use that; else `422 user_id_required`/`422
   user_id_invalid` matching R-Co's exact two-tier fallback. **OQ-2**: whether
   this dual-shape body-parsing fallback is worth preserving vs. simplifying to
   `"user_id"`-only, since Letflow has no existing caller depending on the
   `"user_ids"` array shape — flagged, not silently simplified.
PROVENANCE (historical, not current decision authority):
3. `Identity.add_group_member(group_id, user_id, opts)` (NEW, §7.2) →
   - `{:ok, %{member: member, created: created?}}` → `Response.send_json(conn,
     (if created?, do: 201, else: 200), member_map)` — R-Co returns 200 on an
     already-existing membership (idempotent add), 201 on a genuine insert
     (`identity.zig:442`); ported identically.
   - `{:error, :group_not_found}` → `Response.not_found(conn)`
   - `{:error, :user_not_found}` → `Response.not_found(conn)` (**same body as
     group-not-found — both collapse to the generic 404 problem document via
     `Response.not_found/1`, which takes no detail parameter; this is what
     makes AC2's byte-identical-404 property hold by construction, not by
     coincidence — see §4**)

### 3.3 — `GET /groups` (list)

1. (steps 1-2)
2. `Identity.list_groups(opts)` (NEW, §7.3) → `{:ok, %{groups: groups, total:
   total}}` (never an error tuple — R-Co's own `handleListGroups` has no error
   branch besides `Forbidden`/`PoolExhausted`, both already handled by step 2's
   authorization gate and by the standard `Repo` call not itself failing).
PROVENANCE (historical, not current decision authority):
3. `Response.ok(conn, %{"items" => Enum.map(groups, &group_map/1), "total" =>
   total})`. **Not** cursor-paginated — R-Co's own `handleListGroups` is a flat,
   unpaginated list (fixed `page: 1, page_size: 200` in its response,
   `identity.zig:473`, no cursor mechanism at all) and no acceptance criterion
   for this requirement calls for cursor pagination on `GET /groups` (AC4 names
   only "listing group members," not "listing groups") — so this endpoint is
   ported as a flat list, matching R-Co exactly, unlike `GET /groups/:id/members`
   (§1) which AC4 explicitly requires to diverge into cursor form. Response
   shape is `%{"items" => [...], "total" => n}` (R-Co's own two-key shape,
   `identity.zig:462-475` minus its literal-but-unused `page`/`page_size: 200`
   keys, which encode no real pagination state and are not carried forward).

### 3.4 — `DELETE /groups/:id` (delete)

1. (steps 1-2)
2. `Identity.delete_group(id, opts)` (NEW, §7.4) →
   - `:ok` → `Response.no_content(conn)` (204)
   - `{:error, :not_found_or_has_members}` → `Response.not_found(conn)` — **see
     §5: R-Co's own `deleteGroupIfEmpty` collapses "group has members" and
     "group doesn't exist" into the identical 404, and this port preserves that
     collapse exactly, byte-for-byte indistinguishable, on purpose.**

### 3.5 — `GET /groups/:id/members` (list members, cursor-paginated — §1 finding)

1. (steps 1-2)
PROVENANCE (historical, not current decision authority):
2. Parse query params: `page_size` (via `Pagination.parse_page_size_param/1` +
   `validate_page_size/1`, same as REQ-073's `list_users/2`), `cursor` (opaque
   string, optional, new prefix `"G:"` for **G**roup-members, distinct from
   REQ-073's `"U:"` — matches R-Co's own unrouted `handleListGroupMembers`'s
   cursor prefix choice, `identity_service.zig:1107`: `"G:"`, so this design
   reuses R-Co's own prefix literal rather than inventing a new one).
3. If `cursor` present: `Pagination.decode_cursor(cursor, "G:", byte_size("G:"))`
   → `{:error, _}` → `Response.bad_request(conn, "invalid cursor")`.
PROVENANCE (historical, not current decision authority):
4. `Identity.list_group_members(group_id, %{cursor: decoded_or_nil, page_size:
   page_size}, opts)` (NEW, §7.5) →
   - `{:ok, %{members: users, next_cursor: next_cursor}}` →
     `Response.ok(conn, Pagination.page_response(Enum.map(users, &user_map/1),
     next_cursor))` — reuses REQ-073's existing `user_map/1` (private function
     already defined in this file) for each member row, since a group member
     *is* a user and no separate member-shaped response exists in R-Co either
     (`serializeUser/1` is what `handleListGroupMembersArray` calls per-item,
     `identity.zig:517`).
   - `{:error, :group_not_found}` → `Response.not_found(conn)` (**same INV-5
     collapse as R-Co: `identity_service.zig`'s `listGroupMembers` maps both
     `GroupNotFound` and `CrossTenantAccessDenied` to the identical
     `group_not_found` 404 at the handler layer, `identity.zig:503-504` — this
     port achieves the same collapse structurally, since `opts[:prefix]`
     already scopes the group lookup to the caller's own tenant schema, so a
     cross-tenant group id is indistinguishable from a nonexistent one at the
     `Repo.get` level; there is no separate `CrossTenantAccessDenied` case to
     port because the scoping mechanism itself prevents ever reaching a
     cross-tenant row in the first place — see §4**)

PROVENANCE (historical, not current decision authority):
**Not ported: R-Co's `handleListGroupMembers`'s own `actor.role !=
.PLATFORM_ADMIN → 403` gate** (`identity.zig:533`). This design's route uses the
same `:GroupsManage` policy key as every other group route (§0), gated
uniformly by `evaluate_access/2`, not a handler-local role literal — consistent
with how every other REQ-073/REQ-074 route in this file is gated, and avoiding a
second, router-bypassing authorization mechanism living only in this one
handler. **OQ-3**: flagged since this is a real behavioral narrowing-removal
(R-Co's dead code would have restricted this specific listing to
`PLATFORM_ADMIN` only, stricter than `:GroupsManage`'s role set) — not silently
dropped, listed for REVIEWER.

### 3.6 — `DELETE /groups/:id/members/:user_id` (remove member — §1b finding)

1. (steps 1-2)
PROVENANCE (historical, not current decision authority):
2. `Identity.remove_group_member(group_id, user_id, opts)` (NEW, §7.6) →
   - `:ok` → `Response.no_content(conn)` (204) — idempotent: removing a
     non-member of an existing group is still `:ok` (matches R-Co's
     `removeGroupMember`, which has no "member didn't exist" error variant —
     `registry.zig`'s `DELETE FROM group_members WHERE ...` with no row
     matched is not distinguished from one row matched, both `:ok`)
   - `{:error, :group_not_found}` → `Response.not_found(conn)`

## 4. Cross-tenant-membership test design (AC2, INV-1, INV-5) — load-bearing

The specific, load-bearing test: adding a tenant-B-only user id to a tenant-A
group must (a) fail with the byte-identical 404 a nonexistent user id gets, and
(b) insert **no** `group_members` row — verified by a direct table query, not
just the HTTP response.

```
test "adding a tenant-B-only user id to a tenant-A group fails exactly like a
      nonexistent user id, and inserts no membership row" do
  tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req074-cross-a")
  tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req074-cross-b")

  group_a = insert_group!(tenant_a, name: "engineers")
  tenant_b_user = insert_user!(tenant_b, username: "bob")

  conn_for = fn user_id ->
    build_conn(:post, "/groups/#{group_a.id}/members", tenant_a,
      roles: ["PLATFORM_ADMIN"], body: %{user_id: user_id})
  end

  resp_cross_tenant  = Letflow.Routers.Identity.call(conn_for.(tenant_b_user.id), @opts)
  resp_never_existed = Letflow.Routers.Identity.call(conn_for.(Ecto.UUID.generate()), @opts)

  assert resp_cross_tenant.status == 404
  assert resp_cross_tenant.status == resp_never_existed.status
  assert resp_cross_tenant.resp_body == resp_never_existed.resp_body

  # The load-bearing DB-level check (AC2's explicit "verified by querying the
  # membership table after the attempt", not just the response):
  assert Repo.aggregate(GroupMember, :count, prefix: tenant_a.schema_name) == 0
end
```

Structural guarantee this test is checking: `Identity.add_group_member/3`'s
implementation (§7.2) must resolve `user_id` existence via a `Repo.get(User,
user_id, prefix: tenant_a_prefix)` call scoped to tenant A's own schema — a
`tenant_b_user.id` value simply does not exist as a row under tenant A's
`:prefix`, so this is not a special-cased cross-tenant check, it is the same
"wrong schema, so absent" behavior INV-1's schema-per-tenant mechanism gives for
free, identically to REQ-073's `get_user/2` cross-tenant 404 (§4 of
`req073-identity-user-routes.md`). The membership insert must happen strictly
**after** this existence check (not concurrently, not speculatively) — this
ordering, not merely the test, is what guarantees zero rows on the failure path.

## 5. Delete-with-members test design (AC5)

PROVENANCE (historical, not current decision authority):
**R-Co's observed behavior, evidenced (§1b/registry.zig:1178-1217):**
`deleteGroupIfEmpty` runs `DELETE FROM groups WHERE id = $1 AND NOT EXISTS
(SELECT 1 FROM group_members WHERE group_id = groups.id) RETURNING 1`. If the
group has ≥1 member, zero rows match the `WHERE`, `queryRow` returns no row,
`deleteGroupIfEmpty` returns `false`, and `deleteGroup` (service layer,
`identity/service.zig:1012`) maps `!deleted` to `error.GroupNotFound` — the
**identical** error branch a truly nonexistent group id hits. **R-Co's behavior
is "refuse," and the refusal is indistinguishable from 404-not-found — there is
no separate "409 group has members" response anywhere in this path.** This is
the exact behavior to name in the moduledoc (AC5: "the observed R-Co behaviour
named in the moduledoc") — not "cascade," not "orphan," but "refuse, surfaced as
the same 404 a nonexistent group gets."

Port: `Identity.delete_group/2` (§7.4) issues the equivalent conditional delete
— `Repo.delete_all` (or a raw parameterized `DELETE ... WHERE NOT EXISTS`, see
§7.4's note on why `Repo.delete_all` alone can't express the guard) scoped by
`opts[:prefix]`, returning `:ok` only if a row was actually removed, `{:error,
:not_found_or_has_members}` otherwise — deliberately one unified error atom, not
two, so a caller of `Identity.delete_group/2` cannot accidentally branch on a
distinction the HTTP layer is required to erase anyway (matches R-Co's own
choice to not expose the distinction at all, not merely convention).

```
test "deleting a group with existing members returns the same 404 as deleting a
      nonexistent group, and the group row survives" do
  tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req074-delete-members")
  group = insert_group!(tenant, name: "has-members")
  user = insert_user!(tenant, username: "carol")
  insert_group_member!(tenant, group.id, user.id)

  conn = build_conn(:delete, "/groups/#{group.id}", tenant, roles: ["PLATFORM_ADMIN"])
  resp = Letflow.Routers.Identity.call(conn, @opts)
  resp_never_existed =
    Letflow.Routers.Identity.call(
      build_conn(:delete, "/groups/#{Ecto.UUID.generate()}", tenant, roles: ["PLATFORM_ADMIN"]),
      @opts
    )

  assert resp.status == 404
  assert resp.status == resp_never_existed.status
  assert resp.resp_body == resp_never_existed.resp_body
  assert Repo.get!(Group, group.id, prefix: tenant.schema_name)  # row survives -- refused, not cascaded
end

test "deleting an empty group succeeds" do
  tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req074-delete-empty")
  group = insert_group!(tenant, name: "no-members")

  conn = build_conn(:delete, "/groups/#{group.id}", tenant, roles: ["PLATFORM_ADMIN"])
  resp = Letflow.Routers.Identity.call(conn, @opts)

  assert resp.status == 204
  assert Repo.get(Group, group.id, prefix: tenant.schema_name) == nil
end
```

## 6. Tenant-isolation test design (AC3)

Two `describe` blocks, one for `GET /groups`, one for `GET /groups/:id/members`
— both follow REQ-073's `req073-identity-user-routes.md` §6 pattern exactly
(same-named rows in both tenants' schemas, assert only the caller's own tenant's
rows come back):

```
test "listing groups as tenant A returns only tenant A's groups, even with an
      identically-named tenant B group" do
  tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req074-iso-groups-a")
  tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req074-iso-groups-b")

  insert_group!(tenant_a, name: "engineers")
  insert_group!(tenant_b, name: "engineers")  # identical name, different tenant

  conn = build_conn(:get, "/groups", tenant_a, roles: ["PLATFORM_ADMIN"])
  resp = Letflow.Routers.Identity.call(conn, @opts)

  body = Jason.decode!(resp.resp_body)
  assert length(body["items"]) == 1
end

test "listing a group's members as tenant A returns only tenant A's member
      rows, even when tenant B has a group with the same id-shaped members" do
  tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req074-iso-members-a")
  tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req074-iso-members-b")

  group_a = insert_group!(tenant_a, name: "engineers")
  group_b = insert_group!(tenant_b, name: "engineers")
  user_a = insert_user!(tenant_a, username: "alice")
  user_b = insert_user!(tenant_b, username: "alice")  # same username, different tenant/schema
  insert_group_member!(tenant_a, group_a.id, user_a.id)
  insert_group_member!(tenant_b, group_b.id, user_b.id)

  conn = build_conn(:get, "/groups/#{group_a.id}/members", tenant_a, roles: ["PLATFORM_ADMIN"])
  resp = Letflow.Routers.Identity.call(conn, @opts)

  body = Jason.decode!(resp.resp_body)
  assert length(body["items"]) == 1
  assert hd(body["items"])["id"] == user_a.id
end
```

Isolation here rests on the same schema-per-tenant `:prefix` mechanism (INV-1)
as every other query in this file — `group_a.id` and `group_b.id` are different
UUIDs in different Postgres schemas, so there is no code path by which tenant
A's query could return tenant B's row even if the ids happened to collide
(they cannot, since `Ecto.UUID.autogenerate` is universally unique) — this
test is about the join query (`group_members` joined to `users`, both scoped by
the same `:prefix`) never crossing schemas, which a single-schema Postgres
instance would make trivially easy to get wrong via an accidental
public-schema fallback.

## 7. Pagination test design (AC4) — at least two pages

```
test "listing group members pages via cursor across at least two pages" do
  tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req074-page-members")
  group = insert_group!(tenant, name: "big-team")
  user_1 = insert_user!(tenant, username: "u1")
  user_2 = insert_user!(tenant, username: "u2")
  insert_group_member!(tenant, group.id, user_1.id)
  insert_group_member!(tenant, group.id, user_2.id)

  conn_1 = build_conn(:get, "/groups/#{group.id}/members?page_size=1", tenant, roles: ["PLATFORM_ADMIN"])
  resp_1 = Letflow.Routers.Identity.call(conn_1, @opts)
  body_1 = Jason.decode!(resp_1.resp_body)

  assert length(body_1["items"]) == 1
  refute is_nil(body_1["next_cursor"])

  conn_2 = build_conn(:get, "/groups/#{group.id}/members?page_size=1&cursor=#{URI.encode_www_form(body_1["next_cursor"])}", tenant, roles: ["PLATFORM_ADMIN"])
  resp_2 = Letflow.Routers.Identity.call(conn_2, @opts)
  body_2 = Jason.decode!(resp_2.resp_body)

  assert length(body_2["items"]) == 1
  assert hd(body_1["items"])["id"] != hd(body_2["items"])["id"]  # distinct members across pages
  assert is_nil(body_2["next_cursor"])  # last page
end
```

Mirrors REQ-073's own `list_users/2` two-page test shape (design §2.2/§7's
cursor mechanism) exactly, with the new `"G:"` prefix (§3.5) instead of
`"U:"` and `GroupMember`-join ordering (`inserted_at` ascending, `user_id`
ascending tiebreaker — same tiebreak-field convention as `list_users/2`'s
OQ-1, so this repeats that same open question rather than introducing a new
one — see OQ-4) instead of `User` ordering.

## 8. Domain-function gaps in `Letflow.Identity` (design decision, not silent)

Six new functions needed (matching REQ-073 §7's convention of "thin,
Repo-backed, no business logic beyond a changeset and a query"):

1. **`create_group(attrs :: map(), opts :: opts()) :: {:ok, Group.t()} |
   {:error, :duplicate_group_name} | {:error, Ecto.Changeset.t()}`** — inserts
   via a new `Group.create_changeset/2` (casts `name`, `display_name` defaulting
   to `name`, `description` defaulting to `nil`-if-empty). Maps a `name`
   unique-constraint violation to `{:error, :duplicate_group_name}` — **new
   unique index needed** (§8b) since the current `groups` table (`group.ex`)
   has no such constraint today (REQ-015's own moduledoc states plainly: "No
   changeset function is defined here — no requirement in this batch owns
   `groups` CRUD").

2. **`add_group_member(group_id, user_id, opts) :: {:ok, %{member: GroupMember.t(),
   created: boolean()}} | {:error, :group_not_found} | {:error, :user_not_found}`**
   — `Repo.get(Group, group_id, opts)` first (→ `:group_not_found`), then
   `Repo.get(User, user_id, opts)` (→ `:user_not_found` — **this existence
   check, scoped to `opts[:prefix]`, is the exact mechanism §4's cross-tenant
   test depends on**), then an idempotent insert (`Repo.insert(changeset,
   on_conflict: :nothing, conflict_target: [:group_id, :user_id], returning:
   true)` matching this codebase's established on-conflict idiom, e.g.
   `Identity.insert_or_fetch/4`'s own pattern) — `created?` distinguished the
   same way REQ-018's `provision_oidc_user/4` already had to solve this exact
   "on_conflict :nothing doesn't tell you which happened" problem for a
   client-generated `binary_id` PK (`Repo.get` re-check after insert, per
   `lib/letflow/identity.ex:423-442`'s comment) — **this exact mechanism should
   be reused, not re-derived, since it is already a documented, empirically-
   verified solution in this same module.**

PROVENANCE (historical, not current decision authority):
3. **`list_groups(opts) :: {:ok, %{groups: [Group.t()], total: non_neg_integer()}}`**
   — `Repo.all(Group, opts)` + `Repo.aggregate(Group, :count, opts)`, ordered
   by `name` ascending (no ordering specified by R-Co's handler beyond whatever
   the registry query's own `ORDER BY` does — **OQ-5**, not read from
   `registry.zig`'s `listGroups`, out of this requirement's named source-file
   scope; `name` ascending is this design's own reasonable default, flagged as
   unconfirmed against R-Co).

PROVENANCE (historical, not current decision authority):
4. **`delete_group(id, opts) :: :ok | {:error, :not_found_or_has_members}`** —
   **cannot** be expressed as a plain `Repo.delete/2` (which has no `WHERE NOT
   EXISTS` guard) — needs either (a) a raw parameterized `Repo.query/3` mirroring
   registry.zig's exact `DELETE ... WHERE id = $1 AND NOT EXISTS (...) RETURNING
   1` (INV-7-safe: `$1` is a bound param, not interpolated), or (b) an
   `Ecto.Query`-based `Repo.delete_all(from g in Group, where: g.id == ^id and
   not exists(from m in GroupMember, where: m.group_id == parent_as(:g).id))`
   equivalent using `Ecto.Query`'s `not exists/1` construct. Either is
   acceptable — **OQ-6**, ELIXIR-DEV's implementation choice, not
   security/correctness-relevant since both produce the identical guarded
   delete; (a) more directly mirrors R-Co's literal SQL, (b) stays inside
   `Ecto.Query` without a raw-SQL escape hatch. Returns `:ok` if
   `Repo.delete_all/2`'s (or the raw query's) affected-row-count is 1, `{:error,
   :not_found_or_has_members}` if 0 — this single check is what collapses both
   "doesn't exist" and "has members" into one code path, matching R-Co exactly
   (§5).

5. **`list_group_members(group_id, params :: %{cursor: Cursor.t() | nil,
   page_size: pos_integer()}, opts) :: {:ok, %{members: [User.t()], next_cursor:
   String.t() | nil}} | {:error, :group_not_found}`** — `Repo.get(Group,
   group_id, opts)` first (→ `:group_not_found`; this single scoped lookup is
   what collapses R-Co's separate `GroupNotFound`/`CrossTenantAccessDenied`
   cases into one, per §3.5's note), then a join query (`GroupMember` joined to
   `User` on `user_id`, both filtered by the same `opts[:prefix]`), ordered by
   `GroupMember.inserted_at` ascending then `user_id` ascending (tiebreaker,
   same OQ-1-shaped choice as `list_users/2`), `LIMIT page_size + 1`,
   cursor-encoded via `Pagination.build_raw_cursor_timestamp_key/4` with the
   `"G:"` prefix (§3.5), same mint-time-vs-row-time care as `list_users/2`'s
   `build_next_cursor/1` (§ REQ-073 design, "Updated 2026-08-22" note) — put the
   **mint time** in the cursor's expiry-checked slot, not `inserted_at`, for
   the identical reason that note gives (an old membership row must not make
   its cursor appear pre-expired the instant it's minted).

6. **`remove_group_member(group_id, user_id, opts) :: :ok | {:error,
   :group_not_found}`** — `Repo.get(Group, group_id, opts)` first (→
   `:group_not_found`), then `Repo.delete_all(from m in GroupMember, where:
   m.group_id == ^group_id and m.user_id == ^user_id, prefix: prefix)` —
   idempotent by construction (`delete_all` on zero matching rows is still
   `{0, nil}`, not an error), matching R-Co's own idempotent
   `removeGroupMember` (§3.6).

### 8a. New Ecto schema needed: `Letflow.Identity.GroupMember`

No `group_members` table exists in this codebase today (confirmed:
`grep -rl "group_members" priv/repo/migrations/` — zero hits; `lib/letflow/identity/`
has no `group_member.ex`). This design adds both:

**Migration** (tenant-scoped, following the `if prefix() do` guard convention
every other REQ-063-era migration in `priv/repo/migrations/` uses, e.g.
`20260819000001_create_groups_tenant_scoped.exs`):

```
create table(:group_members, primary_key: false, prefix: prefix()) do
  add :group_id, references(:groups, type: :binary_id, on_delete: :nothing), null: false
  add :user_id, references(:users, type: :binary_id, on_delete: :nothing), null: false
  timestamps(updated_at: false)  # added_at semantics -- no update path exists for a membership row
end

create unique_index(:group_members, [:group_id, :user_id], prefix: prefix())
create index(:group_members, [:user_id], prefix: prefix())
```

`on_delete: :nothing` (not `:delete_all`) on both FKs — deliberate, matching §5's
finding: R-Co's own `deleteGroupIfEmpty` **refuses** deletion of a
non-empty group at the application layer rather than relying on a DB-level
cascade, so a DB-level `ON DELETE CASCADE` here would be a silent behavioral
addition this design does not intend (`delete_group/2`'s own `NOT EXISTS` guard
is what prevents the delete from ever reaching a group with rows in
`group_members` in the first place — the FK's `on_delete` clause is only ever
exercised in the "how do I even express this delete" sense, never really
triggered against a non-empty group in practice, since `Identity.delete_group/2`
never issues the delete when members exist). This must also be registered in
`Letflow.TenantProvisioning.tenant_scoped_migrations/0`, per every prior
tenant-scoped migration's own comment convention — **new registration entry,
not modifying an existing one**.

**Schema module**, `lib/letflow/identity/group_member.ex` (new file, sibling to
`group.ex`/`user.ex`):

```
primary_key: false (composite via unique_index, no surrogate id needed --
  matches this table's own pure-join-table semantics; group_id/user_id
  are its two foreign keys)
schema "group_members" do
  belongs_to :group, Letflow.Identity.Group, type: :binary_id
  belongs_to :user, Letflow.Identity.User, type: :binary_id
  timestamps(updated_at: false)
end
```

**OQ-7**: whether `group_members` needs a surrogate `:id` primary key anyway
(some Ecto/Repo call patterns are more awkward without one, e.g.
`Repo.get_by/3` vs. a composite-key lookup) — left to ELIXIR-DEV; either shape
satisfies every function signature above identically, since none of them
returns or accepts a bare `GroupMember` id.

### 8b. `groups` table additions needed

Current `groups` table (`priv/repo/migrations/20260819000001_...exs` +
`20260820000010_drop_tenant_id_groups.exs`): only `id`, `name`, timestamps (no
`tenant_id` after D2). **Missing, needed for `create_group/2` (§8.1) and
`group_map/1`:** `display_name :string`, `description :string` (nullable), and
**a unique index on `name`** (needed for gap 1's `duplicate_group_name`
mapping — none exists today; `group.ex`'s own moduledoc confirms "No changeset
function is defined here"). New migration, additive (`alter table(:groups) do
add :display_name, :string; add :description, :string end` +
`create unique_index(:groups, [:name], prefix: prefix())`), tenant-scoped,
same `if prefix() do` guard.

PROVENANCE (historical, not current decision authority):
**Not added: `is_system` and `member_count` columns** (both present on R-Co's
`Group` struct, `identity.zig:990-1015`'s `serializeGroup`). `is_system` has no
setter anywhere in these seven handlers (nothing in this handler group ever
creates a system group) — omitted from `group_map/1`'s response entirely rather
than hardcoded to a a literal `false`, since a hardcoded literal would silently
misrepresent a future system-group feature if one is ever added. `member_count`
is a derived value (`COUNT(*)` over `group_members` for the group), not a
stored column — **OQ-8**: whether `group_map/1` should compute and include it
(an extra query per group in `list_groups/1`'s N-groups response, or a
`LEFT JOIN ... GROUP BY` in the query itself) or omit it from the response
allowlist entirely. Not resolved here — no acceptance criterion requires it,
but R-Co's shipped response shape includes it, so silently omitting it is a
divergence worth REVIEWER's eyes, not a given.

## 9. Response allowlist (INV-2-equivalent, even though not named INV-2 by this requirement)

`group_map/1` (new private function in `Letflow.Routers.Identity`, same
hand-built-map discipline as REQ-073's `user_map/1` — never a `Jason.Encoder`
derivation over `%Group{}`):

```
%{
  "id" => group.id,
  "name" => group.name,
  "display_name" => group.display_name,
  "description" => group.description,
  "created_at" => iso8601(group.inserted_at)
}
```

Nothing on `%Group{}` needs excluding today (no password/secret-shaped field
exists on this schema), but the allowlist discipline is applied anyway, per
this file's own established convention and per the requirement's instruction to
apply an INV-2-equivalent allowlist even though INV-2 isn't formally named for
this requirement. Group-member listing reuses REQ-073's existing `user_map/1`
unchanged (§3.5) — no separate member-shaped response type exists, matching
R-Co's own choice to serialize a member as a full `User` (`serializeUser/1`
called from both `handleListGroupMembersArray` and the paginated variant).

PROVENANCE (historical, not current decision authority):
Add-member's 200/201 response (§3.2) is a small ad hoc map, not `group_map/1`
or `user_map/1` — matches R-Co's own `serializeGroupMemberResult`
(`identity.zig:1017-1023`):
```
%{"group_id" => group_id, "user_id" => user_id, "created" => created?}
```
(`"added_at"` omitted — R-Co's own field is populated from the just-inserted
row's timestamp; **OQ-9**: whether to include it here by reading
`GroupMember.inserted_at` off the insert result, left to ELIXIR-DEV since no
acceptance criterion depends on this field's presence.)

## Open questions (not silently resolved)

- **OQ-1** (§1b) — this design ports `handleRemoveGroupMember`'s single-member
  semantics at `DELETE /groups/:id/members/:user_id`, a route R-Co's own table
  never actually binds to that handler (R-Co's live bodyless
  `DELETE /groups/:id/members` instead bulk-removes every member, silently
  swallowing per-member errors). Flagged for REVIEWER: is single-member removal
  the right port target given R-Co's live route does something else entirely,
  or should the bulk-remove-all behavior also be ported (at the bodyless path,
  additionally)? No acceptance criterion asks for bulk removal, so this design
  does not add it, but the divergence from R-Co's *actually served* behavior
  here is larger than §1's (which is a pagination-shape choice, not a different
  operation) and deserves explicit sign-off.
- **OQ-2** (§3.2) — whether to preserve R-Co's dual `"user_id"`/`"user_ids"[0]`
  body-parsing fallback, since no existing Letflow caller depends on the array
  shape.
- **OQ-3** (§3.5) — this design does not port `handleListGroupMembers`'s R-Co-only
  `PLATFORM_ADMIN`-exclusive gate, using the shared `:GroupsManage` policy
  instead; a real behavioral narrowing-removal versus R-Co's (unrouted, but
  still real) code, flagged for REVIEWER.
- **OQ-4** — cursor tiebreak field for `list_group_members/3` (`user_id`,
  matching `list_users/2`'s own OQ-1 shape) — same category of unconfirmed
  choice, not re-litigated per-endpoint.
PROVENANCE (historical, not current decision authority):
- **OQ-5** (§8.3) — `list_groups/1`'s sort order (`name` ascending, this
  design's own choice) not confirmed against `registry.zig`'s `listGroups` SQL,
  out of this requirement's named source-file scope.
- **OQ-6** (§8.4) — raw parameterized SQL vs. `Ecto.Query`'s `not exists/1` for
  `delete_group/2`'s guarded delete — ELIXIR-DEV's implementation choice, not
  security-relevant either way (both are INV-7-safe, bound params only).
- **OQ-7** (§8a) — whether `group_members` needs a surrogate `:id` PK.
- **OQ-8** (§8b) — whether `member_count` is computed and added to
  `group_map/1`'s response, given R-Co's shipped shape includes it but no
  acceptance criterion here requires it.
- **OQ-9** (§9) — whether the add-member response includes `"added_at"`.

## Dispatch mechanism (test infra)

Same as REQ-073 (OQ-6 there, restated here rather than re-derived): neither
existing OIDC test double can mint a token with any role but a fixed
`"VIEWER"` claim, which isn't even in `Authorization.roles_from_strings/1`'s
recognized set. Every test above dispatches via direct
`Letflow.Routers.Identity.call(conn, @opts)`, with `conn.assigns[:auth_context]`
(roles, `tenant_id`, `user_id`) set directly on the conn by the shared
`build_conn/3` test helper REQ-073 already established — this is the same
"real router," different-from-full-HTTP-pipeline distinction that design's §6
already justified; not re-derived here.
