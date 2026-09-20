# Design — REQ-378 / ISS-0736: live revocation/deactivation check on the OIDC auth path

Run-id: WF03-ISS0736-20260921
Stage: S4
Owner (design): CODE-DESIGNER. Diagnosis input: ISSUE-FIXER's `result.summary` in
`handoffs/WF03-ISS0736-20260921/step-01-issue-fixer-diagnosis.json` (cited throughout as
"the diagnosis" — root cause independently re-derived there from source reads, not
re-derived again here).

**REWORK 1 note (2026-09-21):** CODE-DESIGN-VALIDATOR FAILed the prior version of this
doc on exactly one BLOCKER — §4's role-revocation GUI-reachability claim for AC2 did not
match actual `web/` source (`handoffs/WF03-ISS0736-20260921/step-02b-code-design-validator.json`).
Only §4 is amended below (now split into §4 + new §4.1); §§0-3, §5-§10 are unchanged from
the version CODE-DESIGN-VALIDATOR already independently re-verified as correct.

## 0. Problem recap (from the diagnosis, not re-argued)

`Letflow.Plugs.AuthPipeline.authenticate_oidc/2` attaches
`conn.assigns[:auth_context][:roles]` from `identity_context.roles`
(`Letflow.Oidc.ClaimMapping.map_verified_claims/3`'s `resolve_roles/2`), which reads
**only the bearer JWT's own claims** — never any Letflow-local table. The
JIT-provisioned/looked-up `%Letflow.Identity.User{}` struct (`provisioned`, from
`provision_user/3` → `Identity.provision_oidc_user/4`) is used only for `.user.id`; its
`.status` field (REQ-073's :active/:inactive deactivation flag) is never read either. So
neither a `tenant_admin` revoking a role (via `Letflow.Identity.RoleRegistry`'s
`tenant_role`/`groups`/`group_members` tables) nor deactivating an account
(`users.status`) has any effect on an already-issued OIDC session until the token
expires — the defect the diagnosis widened beyond ISS-0736's role-only framing.

**Precedent to mirror** (diagnosis §6): `Letflow.Identity.verify_api_token/2` does one
uncached `Repo.get_by/3` per call, no ETS/process-dict/periodic-refresh cache anywhere in
the path, and returns the row's *current* `roles` on every call. This design gives the
OIDC branch the same shape: one live, uncached DB read per request, positioned so no
cache layer can serve a pre-revocation value.

## 1. Where the new step goes in `authenticate_oidc/2` (AC1, AC3)

Current `with` chain (`lib/letflow/plugs/auth_pipeline.ex:125-136`):

```
verify_token → extract_realm → resolve_tenant → guard_realm_ownership
  → map_claims → provision_user → attach_auth_context(..., identity_context.roles)
```

New chain — **one new step inserted between `provision_user` and
`attach_auth_context`**, exactly where the diagnosis recommends (it has both
`provisioned.user.id`/`.status` and `tenant.id` available there, and nothing after it
still depends on `identity_context.roles`):

```
verify_token → extract_realm → resolve_tenant → guard_realm_ownership
  → map_claims → provision_user → verify_local_account_state
  → attach_auth_context(..., live_roles)
```

`attach_auth_context/4`'s 4th argument changes from `identity_context.roles`
(JWT-claimed) to the new step's live-queried role list. `identity_context.roles` is
still computed (by unchanged `map_claims/2`) but is no longer the value that reaches
`conn.assigns[:auth_context][:roles]` — it becomes dead for authorization purposes on
this branch (kept as-is upstream since `IdentityContext` is a shared struct other code
may still read; not deleted).

### 1.1 New private function — `verify_local_account_state/2`

```
@spec verify_local_account_state(
        provisioned :: %{user: Letflow.Identity.User.t(), created: boolean()},
        tenant_id :: Ecto.UUID.t()
      ) ::
        {:ok, roles :: [String.t()]}
        | {:error, {:account, :inactive}}
        | {:error, {:account, :invalid_tenant_id}}
```

Behavior (mirrors `provision_user/3`'s own existing pattern at
`auth_pipeline.ex:311-326` of independently deriving `schema_name` from `tenant_id` —
same no-extra-I/O derivation, not threaded through as a new arg to avoid changing
`provision_user/3`'s signature):

1. `TenantProvisioning.schema_name_for_tenant(tenant_id)` → `{:ok, schema_name}` |
   `{:error, :invalid_tenant_id}` (existing function, unchanged; `{:error,
   :invalid_tenant_id}` maps to `{:error, {:account, :invalid_tenant_id}}` — a
   defensive-only branch, since step 4b already proved `tenant_id` resolves a schema
   moments earlier in the same request).
2. Branch on `provisioned.user.status` (an `Ecto.Enum` `:active | :inactive` value
   already present on the struct `provision_user/3` just returned — **no new query for
   this check**: `upsert_by_external_identity/4`'s existing-user branch,
   `get_by_external_identity/3`, already does a fresh `Repo.get_by/3` every request
   for the common case — diagnosis §5/§6 confirms provisioning already re-reads the row
   live per request; this step only reads a field of the struct that request already
   fetched, adding zero new round trips for the status half):
   - `:inactive` → short-circuits with `{:error, {:account, :inactive}}` **before** any
     role query runs — deactivation locks the account out entirely, not just out of
     role-gated routes.
   - `:active` → proceeds to 3.
3. `Letflow.Identity.list_effective_role_names(provisioned.user.id, prefix:
   schema_name)` (new function, §2) — **one new live, uncached `Repo` round trip per
   authenticated OIDC request**, same shape as `verify_api_token/2`'s single
   `Repo.get_by/3`. Returns `{:ok, roles}` with `roles` possibly `[]` (a user in no
   role-bearing group — not an error; `evaluate_access/2` denies naturally downstream
   per §3).

### 1.2 `handle_auth_error/2` — two new clauses (`auth_pipeline.ex:151-184`)

```
{:error, {:account, :inactive}} ->
  reject(conn, 403, "forbidden", "account is inactive")

{:error, {:account, :invalid_tenant_id}} ->
  Logger.error("verify_local_account_state/2: invalid tenant_id post-provisioning")
  reject(conn, 500, "internal_error", "account state verification failed")
```

**403, not 401, for `:inactive`** (AC3's explicit "403" wording, and REQ-378 AC1's
framing — "revoking access", not "the token is now invalid"): the bearer token itself
verified fine (it's a real, unexpired, correctly-signed token for a real, previously
known session) — what's being enforced is Letflow-local authorization state, the same
403-for-authorization-not-401-for-authentication line `evaluate_access/2`'s own
`Deny403` already draws for every other authorization failure on this pipeline. Using
401 here would incorrectly imply the credential itself is bad (inviting a client to
retry via re-login/refresh, which would *not* fix an inactive-status denial and would
misdirect the caller).

**Role revocation is not a short-circuit, it's a value swap**: unlike the `:inactive`
case, an empty or narrowed live role list is *not* itself an error tuple — it flows
through as `{:ok, []}` (or `{:ok, [...narrower set...]}`) to `attach_auth_context/4`
exactly like a full role list would, and `Letflow.Api.Authorization.evaluate_access/2`
(unchanged — see §3) denies with its own existing `Deny403` when the now-current role
set doesn't satisfy a route's policy. This is deliberately not special-cased in
`AuthPipeline` itself: the pipeline's only new job is making sure the role list it hands
downstream is *live*, not stale — the authorization decision itself stays entirely
`evaluate_access/2`'s existing job, unchanged.

## 2. Reuse vs. extension of `RoleRegistry`/`Identity.User` (task item b)

**`Letflow.Identity.User` needs no new column.** Roles are not, and will not become, a
column on `users` — they are derived, per `RoleRegistry`'s existing table shape,
from `group_members` (user ↔ group) joined to `tenant_role` (group → role name).
`users.status` (REQ-073, already present) is sufic for the deactivation half.

**`Letflow.Identity.RoleRegistry` is deliberately NOT extended.** Its moduledoc
(`role_registry.ex:11-17`) states verbatim: *"This module has no coupling to the
OIDC/claim-mapping pipeline: it does not alias or call any `Letflow.Oidc.*` module, and
it does not call or get called by `Letflow.Identity`'s OIDC-pipeline functions."* Adding
a function there that `AuthPipeline`'s OIDC branch calls (even transitively through
`Identity`) would falsify that claim in place. Instead, the new query is added directly
to `Letflow.Identity` — the module `AuthPipeline` already exclusively `alias`es for
every other OIDC-branch step (`verify_token`, `resolve_tenant`, `provision_user`, …),
and which already owns `Letflow.Identity.GroupMember`/`Group`/`TenantRole`'s schema
modules in the same `Letflow.Identity.*` namespace as their would-be caller. This keeps
`RoleRegistry`'s documented invariant true unchanged — no moduledoc edit needed there.

### 2.1 New public function — `Letflow.Identity.list_effective_role_names/2`

```
@spec list_effective_role_names(user_id :: Ecto.UUID.t(), opts :: [prefix: String.t()]) ::
        [String.t()]
```

- Query shape: `group_members` rows for `user_id = ^user_id`, inner-joined to
  `tenant_role` on `tenant_role.group_id == group_members.group_id`, `select: distinct
  tenant_role.name`, run with `prefix: Keyword.fetch!(opts, :prefix)` (same
  schema-per-tenant `prefix:` convention every other query in this file already uses —
  `verify_api_token/2`, `get_by_external_identity/3`, etc.). No join to `groups` itself
  needed (`tenant_role.group_id` already carries the FK; `groups.name` isn't part of the
  role-name output).
- Returns `[]` (never an error tuple, never raises past a genuine connection failure —
  matches `RoleRegistry.list_roles/0`'s own "empty list, not an error, when nothing
  matches" convention) when the user belongs to no role-bearing group.
- **No caching, no memoization, no ETS.** One `Repo.all/2` per call — this is the whole
  point (mirrors `verify_api_token/2`'s uncached single round trip exactly).

## 3. AC3 — 403 renders through the existing contract unchanged (task item d)

**Confirmed: no `web/` renderer change is needed**, and none is proposed. Both new
`AuthPipeline` failure branches (§1.2) reuse the *existing* `reject/4` helper
(`auth_pipeline.ex:332-339`), which already produces the same
`{"error": ..., "detail": ...}` JSON shape every other 401/403 branch on this pipeline
already returns — nothing downstream (`web/src/components/ui/QueryStateBoundary.tsx`,
`web/src/components/ui/PermissionDenied.tsx`) branches on which *server-side reason*
produced a 403, only on the HTTP status code itself (`classifyError.ts`'s existing
403→`PermissionDenied` mapping, unchanged by this design). The narrowed-role-set path
(§1.1 item 3 / §1.2's "value swap" note) produces its 403 via
`Letflow.Api.Authorization.evaluate_access/2`'s pre-existing `Deny403`, the exact same
code path every current role-insufficiency 403 already takes — this design adds zero
new response shapes, zero new status codes, zero new error tags visible past
`AuthPipeline`/`Authorization`'s own internals.

## 4. GUI reachability (AC2, task item c)

**REWORK 1 — this section amended in place** after CODE-DESIGN-VALIDATOR's FAIL
(`handoffs/WF03-ISS0736-20260921/step-02b-code-design-validator.json`, `result.issues[0]`)
independently re-verified that the role-revocation half's claimed GUI path was false
against actual `web/` source. Root cause, re-verified again here directly against
current source (not copied from the validator's own citation):

- `web/src/api/identity.ts:55-58`'s `removeMembers(id, userIds)` discards `userIds`
  (`void userIds`) and calls `client.delete(`/api/v1/admin/groups/${id}/members`)` — no
  `user_id` segment, so the backend can never tell which member to remove even if the
  route existed.
- No backend route matches `/api/v1/admin/groups/:id/members` at all. Re-verified
  directly against `lib/letflow/plugs/api_pipeline.ex:141`
  (`forward("/identity", to: Letflow.Routers.Identity)` — there is no `forward("/admin",
  ...)` mounting any group router anywhere in `api_pipeline.ex` or `router.ex`) and
  `lib/letflow/routers/identity.ex:182` (`authz_delete "/groups/:id/members/:user_id",
  :GroupsManage do handle_remove_member(conn, conn.params["id"], conn.params["user_id"],
  ...) end`). The real, only route for single-member removal is **`DELETE
  /api/v1/identity/groups/:id/members/:user_id`**.

**Scope note (deliberately not fixed here):** `groupsApi.addMembers`, `.list`, `.get`,
`.update`, `.delete`, `.members` in the same file also point at the nonexistent
`/api/v1/admin/groups/...` prefix (confirmed by the same `api_pipeline.ex`/`router.ex`
read above — no `/admin/groups` mount exists for any of them either). REQ-378's own
scope, this handoff's `task.description`, and CODE-DESIGN-VALIDATOR's single BLOCKER are
all limited to the role-**revocation** write path specifically, because that is the only
one this requirement's live-read-side fix (§1-§3) depends on being genuinely writable.
Fixing the sibling endpoints is a separate, pre-existing `web/` defect outside REQ-378's
acceptance criteria — flagged here explicitly for ORCH/REQ-ANALYST to queue as its own
follow-up requirement, not silently bundled into or silently left implied by this design.

Both halves of the fix (role revocation, account deactivation) are reachable through
`web/` GUI actions once the fix below lands — no new backend endpoint is needed (the
correct route already exists and already does the right write; only the frontend's path
and argument-threading are wrong):

| Action | GUI path | Frontend call (corrected) | Backend route | Backend write |
|---|---|---|---|---|
| Revoke a role (remove user from a role-bearing group) | `web/src/pages/admin/GroupsPage.tsx` — "Manage members" dialog → per-member `Button variant="danger"` (`removeMember.mutate`, line 85-86, 234) | `groupsApi.removeMembers(groupId, userId)` (single `userId: string`, not an array — see §4.1) | `DELETE /api/v1/identity/groups/:id/members/:user_id` (`authz_delete "/groups/:id/members/:user_id"`, `routers/identity.ex:182`, mounted at `/identity` per `api_pipeline.ex:141`) | `Identity.remove_group_member/3` deletes the `group_members` row read live by §2.1's new query on the user's very next request |
| Deactivate an account | `web/src/pages/admin/UserDetailPage.tsx` — status `<select>` (`data-testid="admin-user-status"`, line 107) + save | `usersApi.update(id, { status: 'INACTIVE', ... })` → `client.patch('/api/v1/users/:id', body)` | `authz_patch "/users/:id"` → `handle_patch/3` → `Identity.update_user_profile/3` | `User.profile_changeset/2` (casts `:status` among others) updates `users.status`, read live by §1.1 step 2 on the user's very next request |

The deactivation write path already exists and is already reachable via `web/`'s own
admin UI today — unchanged from the previous design pass, independently re-confirmed
correct by CODE-DESIGN-VALIDATOR. The revocation write path requires the `web/` fix in
§4.1 below before it is genuinely reachable; once that lands, no backend change and no
new endpoint are needed for either half — the gap REQ-378's read side (§1-§3) closes is
entirely about the auth pipeline never consulting what these writes already produce, not
about the write/GUI side, except for this one pre-existing frontend wiring bug §4.1 now
fixes as part of making AC2 true.

### 4.1 The `web/` fix — `groupsApi.removeMembers` and its `GroupsPage.tsx` call site

**`web/src/api/identity.ts`** — `removeMembers`'s signature changes from a discarded
`userIds: string[]` array to the single `userId: string` the real backend route actually
takes (the backend route is inherently single-member: `DELETE
/groups/:id/members/:user_id` has exactly one `:user_id` path segment, no batch form —
`Identity.remove_group_member/3` is not a bulk operation), and its path gains the
`/identity` mount prefix in place of the nonexistent `/admin`:

```
# web/src/api/identity.ts — groupsApi.removeMembers, corrected signature
removeMembers: (id: string, userId: string) => Promise<void>
  // implementation: client.delete<void>(`/api/v1/identity/groups/${id}/members/${userId}`)
```

(`client.delete<T>(path: string): Promise<T>` — `web/src/api/client.ts:250-252` — takes
no body, which is fine now: `userId` is threaded through the URL path itself, not a
request body, matching exactly how the real route reads `conn.params["user_id"]`.)

**`web/src/pages/admin/GroupsPage.tsx`** — the `removeMember` mutation's `mutationFn`
(line 85-86) currently wraps `userId` in a single-element array to match the old (wrong)
array signature; it changes to pass `userId` straight through to the corrected
single-argument `removeMembers`:

```
# web/src/pages/admin/GroupsPage.tsx — removeMember mutation, corrected mutationFn
const removeMember = useMutation({
  mutationFn: ({ groupId: id, userId }: { groupId: string; userId: string }) =>
    groupsApi.removeMembers(id, userId),   // was: groupsApi.removeMembers(id, [userId])
  ...
})
```

No other line in `GroupsPage.tsx` changes: the mutation's call site at line 234
(`removeMember.mutate({ groupId: groupId(activeGroup), userId: id })`) already passes the
correct `{ groupId, userId }` shape into the mutation — the bug was entirely inside the
`mutationFn` body and `identity.ts`'s `removeMembers` itself, not in how the button
invokes the mutation. `addMember`'s sibling mutation (line 74-75) and its
`groupsApi.addMembers` call are unchanged by this fix (see the scope note above — its own
`/admin/groups` path bug is a separate, out-of-scope defect).

**Not addressed by this design, and correctly not addressed** — a `tenant_admin`
_adding_ a role via `POST /users` `role_ids`/`GroupsPage`'s add-member flow: neither the
diagnosis nor REQ-378 requires this design to touch role-*grant* propagation timing
(only revocation), and grant timing already benefits equally from the same live query
once it exists (a newly added role is visible on the very next request too, as a side
effect of §2.1 being uncached — no separate design needed for that direction).

## 5. Performance / scope note (task item e)

This adds **exactly one new `Repo` round trip per authenticated OIDC request** (§2.1's
query) — the `:inactive` short-circuit (§1.1 step 2) costs nothing extra, since it reads
a field already present on the struct `provision_user/3`'s pre-existing query already
fetched this request. This is the same per-request-uncached-query shape the API-token
branch has carried since REQ-076 with no flagged performance concern
(`verify_api_token/2`, one `Repo.get_by/3` per call) — **stated explicitly, not silently
assumed**: this precedent already exists unchallenged in the codebase for the sibling
auth branch, so the same cost on the OIDC branch is being treated as acceptable as-is
here, consistent with that precedent. Flagging for REVIEWER/SECURITY-REVIEWER anyway
(per task item e's instruction) since "acceptable as-is" is this design's judgment call,
not a pre-existing decision record — REVIEWER should confirm no contrary
migration-stage guidance exists before sign-off; nothing in `docs/migration/stage-4-*.md`
found by this design run contradicts it.

## 6. Scope boundary — gap 3 is explicitly OUT of scope (test-designer/AC mapping note)

REQ-378 itself scopes to "gap 2" (server-side live-enforcement gap, the one this design
closes). **Gap 3 — client-side `session.roles` staleness in `web/`'s own auth state
after a silent OIDC token refresh (the SPA's in-memory role cache not being invalidated
when the *browser's* token silently refreshes with a still-broad claim set) — is
explicitly OUT of scope for this design.** This design does not touch, fix, mask, or
otherwise interact with gap 3: a revoked user's **UI** may still locally believe it has
a now-revoked role/permission until its next navigation-triggered re-render or explicit
reload, but every **API call** it makes will be denied with 403 by this design's
server-side check regardless of what the client-side UI still displays — which is
exactly what AC1 requires ("takes effect on that user's very next request") and exactly
what AC3 requires (the 403 renders through the existing contract) without requiring any
client-side cache-invalidation mechanism. A stale menu item that 403s when clicked is a
UX polish gap, not a security gap, and is not this requirement's concern per its own
"gap 2 only" scoping.

## 7. Migration / schema shape (task item f)

**No migration needed.** No new table, no new column. `users.status` (REQ-073),
`group_members` (REQ-074), `tenant_role`/`groups` (REQ-015/REQ-020) all already exist
with the shape §1-§2 depend on. `Letflow.Identity.User`'s schema is unchanged — the
diagnosis's finding that "there is nowhere on the `users` row itself to even store an
OIDC user's role" is correct and this design does not change that: roles stay
exclusively in `tenant_role`/`groups`/`group_members`, read live via a join, never
denormalized onto `users`.

## 8. Full signature summary

```
# lib/letflow/identity.ex (new)
@spec list_effective_role_names(user_id :: Ecto.UUID.t(), opts :: [prefix: String.t()]) ::
        [String.t()]

# lib/letflow/plugs/auth_pipeline.ex (new private function)
@spec verify_local_account_state(
        provisioned :: %{user: Letflow.Identity.User.t(), created: boolean()},
        tenant_id :: Ecto.UUID.t()
      ) ::
        {:ok, roles :: [String.t()]}
        | {:error, {:account, :inactive}}
        | {:error, {:account, :invalid_tenant_id}}

# lib/letflow/plugs/auth_pipeline.ex — authenticate_oidc/2's `with` chain gains one step
# (`{:ok, live_roles} <- verify_local_account_state(provisioned, tenant.id)`) between
# provision_user/3 and attach_auth_context/4; attach_auth_context/4's own signature is
# unchanged (still `attach_auth_context(conn, tenant_id, user_id, roles)`) — only the
# value passed as its 4th argument changes, from `identity_context.roles` to
# `live_roles`.

# lib/letflow/plugs/auth_pipeline.ex — handle_auth_error/2 gains two new `{:error, {:account, _}}`
# clauses (§1.2); no change to its existing clauses or its @spec (still conn -> conn).

# web/src/api/identity.ts — groupsApi.removeMembers, signature corrected (§4.1, REWORK 1)
removeMembers: (id: string, userId: string) => Promise<void>

# web/src/pages/admin/GroupsPage.tsx — removeMember mutation's mutationFn threads userId
# through instead of wrapping it in a discarded array (§4.1, REWORK 1); no signature
# change to the mutation's own call site (line 234) or to addMember (unchanged).
```

No `.ex`/`.tsx` implementation bodies above — every code-shaped block is either an
`@spec`, an existing/unchanged function signature cited for orientation, or an
already-shipped GUI call path traced for AC2 (§4's table cites existing calls, it does
not introduce new ones).

## 9. Acceptance-criteria mapping (REQ-378)

| REQ-378 AC | Design element |
|---|---|
| AC1 — revoke-then-immediately-retry, no sleep/refresh wait | §1 (new pipeline step, uncached per-request query), §2.1 (no cache/ETS/memoization), §5 (cost accepted as one live round trip, same as the API-token precedent) |
| AC2 — reachable through `web/`'s own GUI, not only Keycloak | §4 (deactivate path: existing, already-shipped, re-confirmed correct); §4.1 (role-revoke path: `web/` fix to `groupsApi.removeMembers`'s signature and its `GroupsPage.tsx` call site, correcting the endpoint to the real `DELETE /api/v1/identity/groups/:id/members/:user_id` route — REWORK 1) |
| AC3 — 403 renders through existing `QueryStateBoundary`/`PermissionDenied` contract unchanged | §1.2 (403 via existing `reject/4`), §3 (no new renderer state, no new response shape, role-narrowing path reuses `evaluate_access/2`'s existing `Deny403`) |
| AC4 — SECURITY-REVIEWER signs off on the chosen mechanism before merge | Not this design's own step to satisfy — routed as this handoff's `next_action` to `CODE-DESIGN-VALIDATOR`, and the pipeline's next stage after implementation routes to `SECURITY-REVIEWER` per WF-03/AC4's own wording; §5 pre-flags the one-query-per-request cost for that review explicitly rather than leaving it implicit |

## 10. Open questions

None outstanding for ELIXIR-DEV to guess at. Two judgment calls this design made
explicitly, restated here so REVIEWER/SECURITY-REVIEWER can challenge them directly
rather than discover them mid-review:

- **403 (not 401) for `:inactive`** — reasoned in §1.2. If SECURITY-REVIEWER disagrees
  (e.g. wants inactive accounts to look identical to "invalid token" to avoid confirming
  account existence to a caller who still holds a stale-but-structurally-valid token),
  that is a one-line change in `handle_auth_error/2`'s new clause, not a structural
  redesign — flagging so it's a deliberate sign-off, not a default nobody chose.
- **Empty role list flows through as a normal `{:ok, []}`, not a distinct error** — the
  design relies entirely on `evaluate_access/2`'s existing behavior when handed `[]`
  (already exercised today for legitimately roleless-but-authenticated users, if any
  route allows that) to produce the AC1/AC3-required 403. This was independently
  re-confirmed for `evaluate_access/2` up to its documented call shape (diagnosis §3);
  not re-read line-by-line against every route's policy in this design pass — flagged
  for ELIXIR-DEV/REVIEWER to spot-check against at least one role-gated route in the
  actual test run.
