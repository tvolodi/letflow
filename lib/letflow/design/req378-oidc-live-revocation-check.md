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

**REWORK 2 note (2026-09-21):** TEST-RUNNER (step-04c, full suite) FAILed this design at
implementation time — not a validator gate — because §1-§2 as shipped have no seeding
path for `group_members`: a JIT-provisioned user's role exists only as a JWT claim until
*something* writes a `group_members` row for them, and nothing ever did. Every OIDC user
today (freshly provisioned or provisioned before this fix) hits this gap. Full citation:
`handoffs/WF03-ISS0736-20260921/step-04c-test-runner.json` `result.summary`, and
`test/reports/report-20260921-WF03-ISS0736-20260921.yaml`. **New §2.2 below closes this
gap** (a one-time, marker-gated sync of claimed roles into `group_members`, covering both
brand-new and pre-existing OIDC users, without ever re-syncing after the first time —
see §2.2's own reasoning for why that boundary is safe against REQ-378's own threat
model). §7 (migration), §8 (signature summary), §9 (AC mapping) and §10 (open questions)
are amended to match. §§0-1, §2 (its existing text, unchanged below §2.1), §3-§6, §4-§4.1
are otherwise untouched — this rework does not revisit anything CODE-DESIGN-VALIDATOR or
TEST-RUNNER already found correct.

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

## 2.2 Closing the JIT-provisioning gap — one-time claims-to-`group_members` sync (REWORK 2)

**Root cause (re-derived from TEST-RUNNER's citation, not re-argued):** §2.1's
`list_effective_role_names/2` is correct on its own terms — it faithfully reads whatever
`group_members` currently holds. The gap is that **nothing ever writes to
`group_members` from a JWT's claimed roles**, for any OIDC user, ever. Before this
requirement's fix, that didn't matter (roles came straight from the claim every
request); now that §1 makes `group_members` the sole source of truth, a user with zero
rows there — which is every OIDC user today, freshly provisioned or provisioned months
ago — reads `roles: []` regardless of what their token claims.

**The naive fix is unsafe.** Re-syncing `group_members` from the token's claimed roles
on *every* request/login (or whenever the live query currently returns `[]`) would
defeat REQ-378 outright: a `tenant_admin` revokes a user down to zero role-bearing
groups, the user's IdP-side token/session still carries the old claim (IdP-side
revocation is a separate, slower system this requirement does not touch — diagnosis
§0), the user's next login re-syncs from that stale claim, and the revocation is
silently undone the moment `group_members` is empty again. A row-count-based trigger
("sync whenever currently empty") is indistinguishable between "never yet synced" and
"synced once, then fully revoked" — both read as zero rows — so it cannot be the gate.

**The gate is therefore an explicit, persisted, one-time marker — not a row count.**

### 2.2.1 New column — `users.role_claims_synced_at`

Tenant-scoped migration (same shape/placement as
`20260907020001_add_scan_status_to_instance_attachments.exs`'s `if prefix() do` /
`tenant_scoped_migrations/0` registration pattern — `users` is itself tenant-scoped
per Decision 0006 D1, so this column follows the table it's added to):

```
alter table(:users, prefix: schema) do
  add :role_claims_synced_at, :utc_datetime_usec, null: true
end
```

`null: true`, **no default expression, no backfill statement** — every existing row
(every OIDC user provisioned before this fix ships, and every internal/non-OIDC user)
gets `NULL` for free, at zero migration cost, and `NULL` is exactly the correct meaning
for "not yet synced" for all of them, including internal users (who never reach the OIDC
sync path at all — see 2.2.3, so their permanently-`NULL` marker is inert, never read).
`Letflow.Identity.User` (schema module) gains one matching field:
`field(:role_claims_synced_at, :utc_datetime_usec)`. **Not added to any existing
changeset** (`jit_changeset/2`, `create_changeset/2`, `profile_changeset/2`,
`status_changeset/2`) — it is written exactly once, only by 2.2.2's new function, via a
direct `Ecto.Changeset.change/2` + `Repo.update/2` (same "not a caller-assignable field"
posture `jit_changeset/2`'s own moduledoc already documents for `password_hash`/
`auth_source`). This is a deliberate security note for SECURITY-REVIEWER: no router or
public changeset ever accepts `role_claims_synced_at` from request input — a caller
setting it early (e.g. to a client-supplied non-nil value) could otherwise suppress its
own seeding or, worse, nothing downstream re-checks it once non-null, so it must stay
fully unassignable outside 2.2.2.

### 2.2.2 New function — `Letflow.Identity.sync_role_claims_from_token/3`

```
@spec sync_role_claims_from_token(
        user :: User.t(),
        identity_context :: IdentityContext.t(),
        opts :: opts()
      ) :: User.t()
```

Always returns a `User.t()` — **never an error tuple, never raises past a genuine
connection failure**, matching this module's existing "seeding/lookup helpers don't fail
the caller's flow" convention (`RoleRegistry.resolve_role_in_tx/1`'s own doc states the
identical principle for the same reason: a role-lookup/seed problem must never abort
JIT provisioning itself). Behavior:

1. Resolve claimed role names to group ids: new private
   `resolve_group_ids_for_role_names(identity_context.roles, opts) :: [Ecto.UUID.t()]` —
   `Repo.all(from t in TenantRole, where: t.name in ^role_names, select: t.group_id,
   distinct: true)`, `prefix: Keyword.fetch!(opts, :prefix)`. Lives in `Letflow.Identity`
   itself, **not** `RoleRegistry`, for the identical reason §2 already gives for
   `list_effective_role_names/2`: it keeps `RoleRegistry`'s moduledoc invariant ("no
   coupling to the OIDC/claim-mapping pipeline") literally true — this is the second
   function that reasoning now covers, not a new exception to it. A claimed role name
   with no matching `tenant_role` row resolves to nothing for that name — not an error;
   the IdP is free to claim role names this tenant hasn't bound to a group yet.
2. For each resolved `group_id`, insert a `group_members` row for `user.id` via the
   **existing private helper** `insert_or_fetch_group_member/3` (`identity.ex`, backs
   `add_group_member/3` — reused directly at its lean private arity, not through
   `add_group_member/3`'s own public wrapper, which would add two redundant
   `Repo.get/3` existence checks for a `Group`/`User` this function already knows exist:
   the group id just came from a live `tenant_role` row, and `user` is the struct this
   function was called with). Already `on_conflict: :nothing` /
   `conflict_target: [:group_id, :user_id]` — idempotent, safe even if called twice.
3. Stamp `user.role_claims_synced_at = DateTime.utc_now()` via
   `Ecto.Changeset.change/2` + `Repo.update/2`, `prefix: Keyword.fetch!(opts, :prefix)`.
4. Steps 2-3 run inside one `Repo.transaction/1` (group-membership inserts and the
   marker stamp commit or roll back together — never a state where the marker is set
   but a resolved group's membership row wasn't written, or vice versa).

**On any failure inside the transaction** (logged via `Logger.error/1`, reason
included): return the **original, unmodified `user`** (marker still `nil`,
`group_members` unchanged) rather than propagating an error. This is deliberately
self-healing, not merely fail-open: because the marker is still `nil`, the **very next**
request for this same user re-enters this exact function (via 2.2.3's call sites) and
retries the sync — a transient DB error costs one request's worth of `roles: []` (a
false-negative 403, safe direction to fail in) and self-corrects, rather than requiring
an operator to intervene or a caller to specially retry.

### 2.2.3 Call sites — where the one-time sync is invoked

Both call sites gate on `role_claims_synced_at == nil` (2.2.4 below on why that gate is
what makes this safe), and both already have `identity_context` and `opts` in scope
today — no new parameter threading into `provision_oidc_user/4` or its callers:

- **`insert_or_fetch/4`**, inside the `if Repo.get(User, id, prefix: prefix) do` branch
  (the branch that confirms a genuine new-row insert, `auth_pipeline.ex:1550` region —
  this is the `created: true` path): unconditionally calls
  `sync_role_claims_from_token(inserted, identity_context, opts)` (a brand-new row's
  marker is always `nil`, so no gate check is needed here — the row cannot pre-exist)
  and uses its return value as the `user:` in `{:ok, %{user: synced_user, created:
  true}}` in place of the un-synced `inserted` struct.
- **`upsert_by_external_identity/4`**'s `%User{} = existing ->` branch, **and**
  `re_select_on_conflict/3`'s identical `%User{} = existing ->` branch (both currently
  return `{:ok, %{user: existing, created: false}}` unconditionally — both must change
  identically, since both are "found an existing row" outcomes, one from the fast path,
  one from the on-conflict race-loser path): becomes
  `user = if is_nil(existing.role_claims_synced_at), do:
  sync_role_claims_from_token(existing, identity_context, opts), else: existing` before
  returning `{:ok, %{user: user, created: false}}`. For the overwhelming majority of
  returning-user requests (marker already non-nil from a prior sync), this is a single
  extra struct-field read, zero extra queries — the `if` short-circuits before any new
  `Repo` call.

### 2.2.4 Why the marker-gate does not reintroduce REQ-378's vulnerability

This is the judgment call CODE-DESIGN-VALIDATOR and SECURITY-REVIEWER must both sign off
on explicitly (also restated in §10): **the sync runs at most once per user, ever**, on
whichever request first observes `role_claims_synced_at == nil` for that user — the
user's actual first-ever provisioning if they're new, or their first request after this
fix deploys if they predate it. From that point on, `role_claims_synced_at` is permanently
non-`nil` for that user (nothing in this design, or anywhere else in the codebase, ever
resets it back to `nil`), so:

- A user revoked down to zero `group_members` rows **after** their one-time sync already
  ran keeps a non-`nil` marker — the gate never re-fires for them, `group_members` stays
  at zero rows, `list_effective_role_names/2` correctly returns `[]`, and AC1's
  revoke-takes-effect-next-request property holds exactly as §1-§2 already established.
  The marker is what makes "zero rows because never synced" and "zero rows because
  revoked" distinguishable — the row count alone (what the naive fix would have gated
  on) cannot tell these apart; the marker can, because it is written once and never
  touched by revocation (`Identity.remove_group_member/3`, §4's table, does not touch
  `users` at all).
- A pre-existing OIDC user (provisioned before this fix, `role_claims_synced_at: nil`
  today) syncs exactly once, on their first post-deploy request — this **is** this
  design's answer to task item (d)/AC2 of this rework's own acceptance criteria (see
  §7): no separate backfill migration is needed, because the sync mechanism itself,
  gated by the marker rather than by "was this row inserted just now", already covers
  both populations with one code path. This is a deliberate, named decision, not the
  "accept the collateral" fallback the rework's task text offered as the alternative —
  chosen because it costs nothing extra (no migration to write, no window where a
  legitimate pre-existing user is denied) and does not weaken the security property
  (per the bullet above, a marker set on *this* first-post-deploy sync is exactly as
  permanent as a marker set at original provisioning time).

## 2.3 Test-assertion impact — three pre-existing tests' `roles == ["VIEWER"]` literal (REWORK 3)

**Verified directly against current source, not assumed** (this rework's own task):

- `Letflow.Api.Authorization.roles_from_strings/1` (`lib/letflow/api/authorization.ex:408-418`)
  reduces an untrusted string list through a private `role_from_string/1` clause set
  (`:420-426`) that pattern-matches exactly the six literal role-name strings in
  `role()`'s closed type (`:195-201`) and returns `nil` for anything else, which the
  `Enum.reduce/3` accumulator silently drops (`nil -> acc`) — never raises, never widens.
  `"VIEWER"` matches none of the six clauses, so `roles_from_strings(["VIEWER"])` returns
  `[]`. Confirmed by reading the function body directly, not inferred.
- Every call site that feeds `conn.assigns.auth_context.roles` into an actual access
  decision routes it through `roles_from_strings/1` first — `lib/letflow/plugs/authorize.ex:105`
  (`Authorization.AccessContext{..., roles: Authorization.roles_from_strings(conn.assigns.auth_context.roles)}`,
  immediately consumed by `evaluate_access/2` at `:112`), and identically at
  `lib/letflow/routers/entities.ex:2104` and `lib/letflow/routers/tasks.ex:258`. No
  call site anywhere in `lib/letflow/` passes the raw `auth_context.roles` string list
  into `evaluate_access/2` or any `role_allows?/2` check directly — `roles_from_strings/1`
  is the sole, mandatory gate between "what the token/live-query produced" and "what the
  access decision sees." `evaluate_access/2` (`authorization.ex:777-778` on) is confirmed
  the only function making the actual allow/deny decision on this path; it never inspects
  `conn.assigns.auth_context.roles` itself, only the already-filtered `AccessContext.roles`
  it's handed.
- Conclusion: both halves of ORCH's cited reasoning are correct. (a) This requirement's
  whole point is that the closed-set, permission-granting portion of the role list must
  come from live Letflow-local state (§1-§2.2), not raw JWT claims — an unrecognized/
  unmapped claim string like `"VIEWER"` was already inert for authorization purposes
  under the *old* implementation too (it never survived `roles_from_strings/1`), so its
  presence or absence in the raw `conn.assigns.auth_context.roles` list is not itself a
  security property; only what `roles_from_strings/1` outputs is. (b) The new design
  (§1-§2.2) correctly changes what `conn.assigns.auth_context.roles` contains — from
  "whatever strings the bearer JWT claimed" to "only role names presently backed by a
  `group_members` row for this user" — and for the `TokenVerifierDouble` fixture used by
  all three tests below (`test/support/token_verifier_double.ex:36`, which mints
  `realm_access.roles: ["VIEWER"]` and nothing else), none of the three tests' fixture
  setup (`insert_tenant_for_realm!/1` / `insert_bpm_default_tenant!/0`) seeds any
  `tenant_role` row named `"VIEWER"` or any `group_members` row for the provisioned user
  — confirmed by reading each test's own setup helpers, not assumed — so §2.1's live
  query and §2.2's one-time sync both correctly resolve to zero matching groups for this
  fixture, and `conn.assigns.auth_context.roles` becomes `[]` under the new design where
  it was `["VIEWER"]` under the old one. This is an intentional, in-scope consequence of
  REQ-378's contract change (the raw list is no longer claim-pass-through; it is now the
  live-resolved set), not a regression.

**The exact three pre-existing tests and their required literal change** — in each, only
the cited line's expected value changes; every other assertion in each test (the 403/
`refute conn.halted` outcome, `tenant_id`, `user_id`, `persisted`/`body` checks) is
**unchanged**, because the deny/allow outcome downstream of `roles_from_strings/1` was
already `[]`-equivalent for `"VIEWER"` even before this fix — only the *unfiltered* list
these three tests happen to assert against is changing shape:

| Test file | Line | Current assertion | Required new assertion | Other assertions in this test |
|---|---|---|---|---|
| `test/letflow/plugs/auth_pipeline_test.exs` | 167 | `assert roles == ["VIEWER"]` | `assert roles == []` | Unchanged: `refute conn.halted` (:164), `assert tenant_id == tenant.id` (:166), the `Repo.get(User, ...)`/`persisted.auth_source == :oidc` checks (:173-175) — this test calls `AuthPipeline` directly (not the full router/`Authorize` plug), so it was never a 403 test; it only asserts what reaches `conn.assigns[:auth_context]`, which is exactly the value this design changes |
| `test/letflow/plugs/api_pipeline_integration_test.exs` | 130 | `assert conn.assigns.auth_context.roles == ["VIEWER"]` | `assert conn.assigns.auth_context.roles == []` | Unchanged: `assert conn.status == 403` (:128), `assert conn.assigns.auth_context.tenant_id == tenant.id` (:129), `assert is_binary(conn.assigns.auth_context.user_id)` (:131) — the 403 already came from `roles_from_strings/1` dropping `"VIEWER"` before this fix; it still does, now for the same reason at both the raw-list and live-query layers |
| `test/letflow/routers/req077_promotion_pipeline_test.exs` | 1053 | `assert conn.assigns.auth_context.roles == ["VIEWER"]` | `assert conn.assigns.auth_context.roles == []` | Unchanged: `assert conn.status == 403` (:1051), `assert conn.assigns.auth_context.tenant_id == tenant.id` (:1052), `body["detail"] == "insufficient permissions"` and `refute Map.has_key?(body, "entries")` (:1056-1057) |

`test/specs/REQ-021.md` (:136) and `test/specs/REQ-077.md` (:169) are prose spec
documents that narrate the same fixture's `["VIEWER"]` output for human orientation, not
executable assertions — CODE-DESIGN-VALIDATOR/DOC-UPDATER should confirm whether updating
their prose to say `[]` is warranted for accuracy, but they carry no test-runner
pass/fail consequence and are not part of "the 3 tests" this rework scopes.

**Authorization to implement directly:** this is authorized as part of REQ-378's own
implementation, for ELIXIR-DEV to make directly in the implementation step that also
lands §1-§2.2 — **not** a separate TEST-DESIGNER task. All three edits are literal
expected-value corrections to pre-existing regression tests, updating what they assert
`conn.assigns.auth_context.roles` equals to match REQ-378's deliberately changed, in-scope
contract (§1-§2's whole point: that field stops being raw-claim pass-through). No new
test scenario, fixture, or coverage is being added — TEST-DESIGNER's role (writing new
test specs/coverage) is not implicated.

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

**REWORK 2 — amended.** §1-§2's live-read side still needs no migration: `users.status`
(REQ-073), `group_members` (REQ-074), `tenant_role`/`groups` (REQ-015/REQ-020) all
already exist with the shape §1-§2 depend on. **§2.2's seeding fix does need one new
column**, added by REWORK 2: `users.role_claims_synced_at :: utc_datetime_usec | nil`
(2.2.1) — a tenant-scoped migration (`if prefix() do` / registered in
`Letflow.TenantProvisioning.tenant_scoped_migrations/0`, matching
`20260907020001_add_scan_status_to_instance_attachments.exs`'s pattern exactly), nullable
with no default and no backfill statement. This is still not a place where "roles" are
denormalized onto `users` — the column stores only *when this user's claims were last
synced into `group_members`*, never a role name or list itself; roles remain exclusively
derived from `tenant_role`/`groups`/`group_members`, read live via §2.1's join, exactly
as the un-amended text above already established.

**Pre-existing-user backfill (task item d of this rework): explicitly NOT a separate
migration or an accepted-collateral tradeoff — it's the same one-time-sync mechanism.**
Because the new column's every existing row lands `NULL` (no default, no backfill
statement — 2.2.1), and 2.2.3's gate is "`role_claims_synced_at == nil`", every
pre-existing OIDC user is, from this migration's own perspective, indistinguishable from
a brand-new user the first time they're seen post-deploy: their first request after this
ships syncs their then-current token claims into `group_members` and stamps the marker,
exactly once, via the same code path 2.2.2-2.2.3 describe for new users. No separate
backfill script, no data migration touching `group_members` directly, and no window
where such a user is denied *indefinitely* — only their single first post-deploy request
sees `roles` sourced from a `group_members` row that didn't exist a moment before request
processing began (transparent to them: they still get `roles: [<claimed>]` on that same
request, per 2.2.2 running before §1's `verify_local_account_state/2` step reads live
roles in the same request's pipeline).

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

# lib/letflow/identity.ex (new, REWORK 2, §2.2.2)
@spec sync_role_claims_from_token(
        user :: User.t(),
        identity_context :: IdentityContext.t(),
        opts :: opts()
      ) :: User.t()
# Never an error tuple; on internal failure returns the original (still-unsynced) user
# unchanged so the next request retries (§2.2.2's self-healing note).

# lib/letflow/identity.ex (new private, REWORK 2, §2.2.2 step 1)
@spec resolve_group_ids_for_role_names(role_names :: [String.t()], opts :: opts()) ::
        [Ecto.UUID.t()]

# lib/letflow/identity.ex — insert_or_fetch/4 (REWORK 2, §2.2.3): the created:true
# branch's returned user is now sync_role_claims_from_token/3's return value in place of
# the raw inserted struct. upsert_by_external_identity/4's and re_select_on_conflict/3's
# %User{} = existing -> branches (both created:false) now conditionally call the same
# function when existing.role_claims_synced_at is nil. No @spec on either function
# changes — both still return {:ok, %{user: User.t(), created: boolean()}}.

# lib/letflow/identity/user.ex (new field, REWORK 2, §2.2.1)
field(:role_claims_synced_at, :utc_datetime_usec)
# Not added to jit_changeset/2, create_changeset/2, profile_changeset/2, or
# status_changeset/2 — written only via sync_role_claims_from_token/3's own
# Ecto.Changeset.change/2 + Repo.update/2, never from caller-supplied attrs.
```

No `.ex`/`.tsx` implementation bodies above — every code-shaped block is either an
`@spec`, an existing/unchanged function signature cited for orientation, or an
already-shipped GUI call path traced for AC2 (§4's table cites existing calls, it does
not introduce new ones).

## 9. Acceptance-criteria mapping (REQ-378)

| REQ-378 AC | Design element |
|---|---|
| AC1 — revoke-then-immediately-retry, no sleep/refresh wait | §1 (new pipeline step, uncached per-request query), §2.1 (no cache/ETS/memoization), §2.2 (REWORK 2 — the one-time seed never re-fires post-revocation, §2.2.4), §5 (cost accepted as one live round trip, same as the API-token precedent) |
| AC2 — reachable through `web/`'s own GUI, not only Keycloak | §4 (deactivate path: existing, already-shipped, re-confirmed correct); §4.1 (role-revoke path: `web/` fix to `groupsApi.removeMembers`'s signature and its `GroupsPage.tsx` call site, correcting the endpoint to the real `DELETE /api/v1/identity/groups/:id/members/:user_id` route — REWORK 1) |
| AC3 — 403 renders through existing `QueryStateBoundary`/`PermissionDenied` contract unchanged | §1.2 (403 via existing `reject/4`), §3 (no new renderer state, no new response shape, role-narrowing path reuses `evaluate_access/2`'s existing `Deny403`) |
| AC4 — SECURITY-REVIEWER signs off on the chosen mechanism before merge | Not this design's own step to satisfy — routed as this handoff's `next_action` to `CODE-DESIGN-VALIDATOR`, and the pipeline's next stage after implementation routes to `SECURITY-REVIEWER` per WF-03/AC4's own wording; §5 pre-flags the one-query-per-request cost for that review explicitly rather than leaving it implicit |

## 10. Open questions

None outstanding for ELIXIR-DEV to guess at. Four judgment calls this design made
explicitly (two from before this rework, two added by REWORK 2), restated here so
REVIEWER/SECURITY-REVIEWER can challenge them directly rather than discover them
mid-review:

- **(REWORK 2) The one-time sync is gated by a persisted marker
  (`role_claims_synced_at`), not by "current `group_members` row count is zero"** —
  reasoned in full in §2.2.4. This is the crux of REWORK 2's fix and is exactly the
  distinction TEST-RUNNER's finding turned on: a row-count gate cannot tell "never
  synced" from "revoked to zero" apart, and a marker gate can, because nothing ever
  resets the marker. If SECURITY-REVIEWER wants an even stronger guarantee (e.g. an
  audit-logged record of what was synced and when, beyond the bare timestamp), that is
  additive to this design (the `role_claims_synced_at` value itself, or a companion
  `Letflow.Identity.Audit` entry per REQ-195's existing pattern), not a structural
  change to the gate itself.
- **(REWORK 2) Pre-existing OIDC users are backfilled by the same one-time-sync
  mechanism, not by a separate data migration** — reasoned in §7 and §2.2.4's second
  bullet. Flagging explicitly because it means a pre-existing user's very first
  post-deploy request is the moment their `group_members` row first gets written — if
  SECURITY-REVIEWER considers even that one-request-delayed, self-service backfill an
  unacceptable window (versus a proactive migration seeding all pre-existing users'
  `group_members` from... nothing, since no historical claims are persisted anywhere in
  this codebase to backfill from — the diagnosis's own finding), that would need to be
  argued as a functional requirement change, not a design gap: there is no source of
  truth for a pre-existing user's claimed roles other than their own next token.

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
