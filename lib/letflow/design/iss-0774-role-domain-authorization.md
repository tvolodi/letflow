# ISS-0774 — `tenant_role` conflates platform-permission roles and process-routing role names

CODE-DESIGNER design for BLOCKER `docs/issues/ISS-0774.yaml` (GH-1681, Q-772). Fix
target: `Letflow.Api.Authorization.role_from_string/1`, `Letflow.Identity`
(`list_effective_role_names/2`, `sync_role_claims_from_token/3`),
`Letflow.Identity.RoleRegistry` (`upsert_role/3`, `resolve_role_in_tx/1`).

Explicitly **not** in scope: ISS-0773 (silent zero-grant role-claims-sync lockout —
already fixed, merged, PR #1680, commit `9546ef2d`). Any interaction between that fix
and this one is called out where it matters (§4) but nothing in ISS-0773's own fix is
touched here.

## 0. Root cause (re-derived from source, not re-stated from the issue alone)

`tenant_role` (`lib/letflow/identity/tenant_role.ex`) is a single table with a single
`name :: String.t()` column, written from two structurally unrelated call sites for two
structurally unrelated purposes:

1. **Platform-permission provisioning.** An operator granting a user one of
   `Letflow.Api.Authorization.roles/0`'s six fixed values
   (`"PLATFORM_ADMIN"`/`"PROCESS_DESIGNER"`/`"PROCESS_OPERATOR"`/`"TASK_WORKER"`/
   `"AGENT_RUNNER"`/`"CANDIDATE"`) calls `RoleRegistry.upsert_role/3` to bind that literal
   string to a group, then adds the user to that group. `Letflow.Identity.
   list_effective_role_names/2` (REQ-378) reads these names back out via a
   `group_members ⋈ tenant_role` join and feeds them through
   `Authorization.roles_from_strings/1` into the platform permission-check path
   (`Letflow.Plugs.Authorize` → `Authorization.evaluate_access/2`).
2. **Process-definition HUMAN_TASK routing.** A process definition's `HUMAN_TASK` step
   names an arbitrary routing role (e.g. `role: role-ops-manager` in
   `test/fixtures/simulation/swiftroute/process_route_approval.yaml`). Provisioning that
   definition's routing calls the **same** `RoleRegistry.upsert_role/3` to bind that
   **same-shaped** string to a group, for the **engine's own**
   `RoleRegistry.resolve_role_in_tx/1` lookup (role name → `group_id`, used at
   transition/task-creation time to pick who a `HUMAN_TASK` assigns to) — a mechanism
   with **zero relationship** to `Authorization`/`roles_from_strings/1`/platform
   permission checks.

Nothing in the schema, in `RoleRegistry.upsert_role/3`'s contract, or in
`list_effective_role_names/2`'s query marks which domain a given `tenant_role` row
belongs to — the two kinds of row are byte-for-byte indistinguishable except by
eyeballing whether the string happens to match one of the six platform-role literals.
`roles_from_strings/1` is deliberately strict (§"Untrusted input" in
`Letflow.Api.Authorization`'s own moduledoc — no `String.to_existing_atom/1`, unrecognized
strings silently dropped, by design, for the *token-claims* input it was built for). That
same strictness, applied to a `tenant_role.name` value that was never a platform-role
candidate in the first place, is what silently reduces a process-routing-role-only user's
`roles` to `[]` — and `evaluate_access/2` cannot distinguish "this caller genuinely holds
no role" from "this caller's only role means something `Authorization` was never told
about."

**This is a data-modeling gap, not a bug in `roles_from_strings/1`'s own contract.** The
fix has to happen at the point the two domains are conflated — `tenant_role` itself and
its two producers/one relevant consumer — not by loosening `roles_from_strings/1`'s
already-correct-for-its-actual-input strictness.

## 1. The decision (AC1)

**Process-routing role names confer NO platform permission, ever, by themselves.** A
process-routing-role-only user must be granted a platform role explicitly and
additionally (today, ordinarily `TASK_WORKER`) to reach any platform API route,
including `GET /tasks/inbox` — this is unchanged from the platform's behavior before
this bug was found; what changes is that the platform now (a) makes the two domains
**structurally distinguishable** at the data layer instead of distinguishable only by
guessing at a string's shape, and (b) gives provisioning tooling a **positive,
callable check** that catches "this user holds a process-routing role and no platform
role" before it ships as a silent, permanent 403 — closing exactly the gap that let
T-0140 reach production undetected.

This is candidate direction **(a)** from the issue's `fix_direction`, made concrete.
Candidates (b) and (c) are addressed below (§1.2, §1.3) — this is a real decision with
rejected alternatives named, not a default.

### 1.1 Mechanism, in one sentence

Split `tenant_role.name`'s single domain into two, explicit, DB-level `kind`s
(`:platform_role` | `:process_routing_role`); make `RoleRegistry.upsert_role/4` require
and validate `kind` at write time (a `:platform_role` row's `name` must be one of
`Authorization.roles/0`'s six literal strings, rejected otherwise); make
`list_effective_role_names/2` — the one function whose output ever reaches
`roles_from_strings/1` — read **only** `kind: :platform_role` rows; add a new,
provisioning-facing check, `RoleRegistry.check_platform_role_coverage/2`, that a
provisioning script/test can call to get an explicit, actionable answer to "does this
user hold a platform role at all, given everything they currently hold" — returning the
gap by name (which process-routing roles they hold, and that none of the six platform
roles cover them) instead of a caller having to infer it from a downstream 403.

### 1.2 Why not (b) — extend `role_from_string/1` so a process-routing name confers a baseline permission

Rejected. Three independent reasons:

1. **Silent privilege widening, not a fix.** Every process definition author who picks a
   `HUMAN_TASK` routing role name — a decision made entirely inside
   `docs/*/process-definitions` content, with no `Authorization`-domain review at all —
   would be minting platform API access (`:TasksRead`, per the issue's own suggested
   grant) for every member of that role's group, as a side effect neither the process
   author nor a security reviewer ever explicitly granted. `Letflow.Api.Authorization`'s
   own moduledoc already documents a closely analogous discipline elsewhere in this same
   module (the `:HelpRead`/`CANDIDATE` deviation, and the "don't silently re-decide what a
   decision record already settled" instinct behind ISS-0646's closed-set invariant test)
   — this fix should not introduce the exact class of implicit widening this codebase
   otherwise goes out of its way to avoid and flag.
2. **No natural stopping point for "baseline."** `:TasksRead` is the issue's own example,
   but nothing about a process-routing role name says "grants read access to `/tasks`
   specifically" rather than any other permission — the mapping would be an arbitrary
   platform-side decision bolted onto tenant-authored content, and the next requirement
   that wants a different process-routing-role-conferred capability would have no
   principled place to extend this without repeating the same implicit-grant pattern.
3. **`role_from_string/1`'s existing strictness is deliberately not an obstacle here.**
   Its no-`String.to_existing_atom/1`, closed-set contract exists specifically because its
   input is untrusted, attacker-influenceable bearer-token content
   (`Letflow.Oidc.ClaimMapping.resolve_roles/2` → `conn.assigns[:auth_context][:roles]`).
   `tenant_role.name` is a *different*, tenant-admin/process-author-controlled input with
   a different trust boundary — conflating "loosen this function" with "fix the
   conflation" would touch the one function whose current behavior is already correct for
   the untrusted input it actually serves.

### 1.3 Why not (c) some other design — none found that isn't a variant of (a) or (b)

Two variants considered and folded into §1.1 rather than treated as a separate (c):

- **A separate registry table for process-routing roles, `tenant_role` left untouched.**
  Rejected in favor of an in-place `kind` column: `RoleRegistry.resolve_role_in_tx/1`'s
  `(name -> group_id)` lookup and `RoleRegistry.upsert_role/3`'s upsert-on-`name`-conflict
  contract are both keyed on `tenant_role.name` being globally unique (the migration's
  `unique_index(:tenant_role, [:name])`) — splitting into two tables would need two
  separate uniqueness domains and would let the *same literal name* exist once per table,
  reopening a version of the exact ambiguity this fix exists to close (which table's row
  wins when a platform-role literal and a process-routing name collide?). A `kind` column
  on the existing table keeps the one uniqueness domain and answers "which domain is this
  row" with a value, not a second lookup.
- **Runtime heuristic (infer `kind` from whether `name` matches one of the six literals,
  no schema change).** Rejected — this is exactly the implicit, guess-by-string-shape
  status quo AC1 requires this design to replace with something explicit. It also cannot
  reject a typo'd platform-role name at write time the way an explicit, validated `kind`
  can (§2.2).

## 2. Fix mechanism

### 2.1 Migration — `tenant_role.kind`

New migration, `priv/repo/migrations/20260921000001_add_kind_to_tenant_role.exs`
(sequenced after the existing latest, `20260921000001_add_role_claims_synced_at_to_users.exs`
— bump the numeric suffix as needed to keep filenames unique at merge time), applied
inside every tenant schema the same way `20260819000002_create_tenant_role_tenant_scoped.exs`
already does (per-tenant-schema replay, per `Letflow.TenantProvisioning`'s existing
pattern — this migration touches no new mechanism, only a new column on an
already-tenant-scoped table):

- `alter table(:tenant_role)`: add `kind :string, null: false` — a plain string column
  cast through `Ecto.Enum` at the schema layer (matching this codebase's established
  convention: `Letflow.Identity.User.status`/`auth_source`,
  `Letflow.Identity.Tenant.status` all use `Ecto.Enum` over a string column, not a
  Postgres-native enum type).
- **Backfill, in the same migration, for every existing row**: `kind = 'platform_role'`
  where `name` is one of the six literal strings `Authorization.roles/0` maps to string
  form (`Enum.map(Authorization.roles(), &Atom.to_string/1)`); `kind =
  'process_routing_role'` for every other existing row. This is a one-time, deterministic
  reclassification of pre-existing data using the exact same closed-set test
  `role_from_string/1` already encodes — not a new judgement call, a restatement of the
  judgement the codebase already makes today, now persisted instead of re-derived from
  string shape on every read.
- `create index(:tenant_role, [:kind])` — `list_effective_role_names/2`'s rewritten
  query (§2.4) filters on it.

### 2.2 `Letflow.Identity.TenantRole` schema

```
@type kind :: :platform_role | :process_routing_role

schema "tenant_role" do
  field(:name, :string)
  field(:group_id, Ecto.UUID)
  field(:kind, Ecto.Enum, values: [:platform_role, :process_routing_role])

  timestamps(updated_at: false)
end

@type t :: %__MODULE__{kind: kind()}
```

`changeset/2` gains `:kind` in its `cast/3`/`validate_required/3` lists — no new
constraint beyond `Ecto.Enum`'s own cast-time validation (rejects any value outside the
two-member set at the changeset layer, same as `User.status`'s existing precedent).

### 2.3 `RoleRegistry.upsert_role/4` — `kind`-aware, `kind`-validated

Signature widens (call-site-breaking, deliberately — every existing caller must state
which domain it is writing, not fall through a default that could silently mis-tag a
row):

```
@type kind :: :platform_role | :process_routing_role

@type upsert_error ::
        :invalid_role_name
        | :invalid_group_id
        | :group_not_found
        | :name_not_a_recognized_platform_role
        | Ecto.Changeset.t()

@spec upsert_role(
        name :: String.t(),
        kind :: kind(),
        group_id :: Ecto.UUID.t() | String.t(),
        opts :: [prefix: String.t()]
      ) :: {:ok, TenantRole.t()} | {:error, upsert_error()}
```

New validation, ahead of the existing `validate_role_name/1`/`Ecto.UUID.cast/1` checks
(same "validate before any DB round-trip" shape `upsert_role/3` already has): when
`kind == :platform_role`, `name` must be a member of
`Enum.map(Authorization.roles(), &Atom.to_string/1)` — any other value returns
`{:error, :name_not_a_recognized_platform_role}` **before** any `Repo` call, loudly
rejecting a typo'd platform-role grant (e.g. `"PLATFORM_ADMN"`) instead of silently
creating a dead role binding nothing ever resolves — the same "reject loudly rather than
silently narrow" precedent `Letflow.Identity.create_token/3`'s `validate_issuable_roles/1`
already established for a structurally identical closed-set check. `kind ==
:process_routing_role` gets no such literal-set check — that domain is open-ended by
design (any process-definition-chosen string), only `validate_role_name/1`'s existing
format checks (non-empty, length, no control characters) apply.

`do_upsert_role/4`/`insert_or_update_role/4` (private) widen the same way — `kind` is
part of the upserted attrs map and part of `on_conflict: [set: [group_id: ..., kind:
...]]` (an existing row's `kind` can be corrected by a re-`upsert_role/4` call the same
way its `group_id` already can — no new mutation path, the existing upsert-on-conflict
semantics just now cover one more field).

`resolve_role_in_tx/1` is **unchanged** — its `(name -> group_id)` lookup is `kind`-blind
by design (the engine resolving a `HUMAN_TASK` routing name has no reason to care whether
that name is *also* a platform role; it only ever looks up process-routing names in
practice, and nothing about this fix requires it to filter by `kind`).

### 2.4 `Letflow.Identity.list_effective_role_names/2` — filtered to `kind: :platform_role`

The single query gains one `where` clause:

```
@spec list_effective_role_names(user_id :: Ecto.UUID.t(), opts :: opts()) :: [String.t()]
```

(signature unchanged) — query becomes `... join: tr in TenantRole, on: tr.group_id ==
gm.group_id, where: gm.user_id == ^user_id and tr.kind == :platform_role, select: tr.name,
distinct: true`. This is the one and only change needed to stop a process-routing role
name from ever reaching `roles_from_strings/1` via this path — everything downstream
(`Letflow.Plugs.AuthPipeline`, `Authorization.evaluate_access/2`) is untouched, because
the untrusted-input contract they already have (`role_from_string/1` silently drops an
unrecognized string) is now only ever asked to recognize genuine platform-role
candidates.

`sync_role_claims_from_token/3`'s `resolve_group_ids_for_role_names/2` (private,
`lib/letflow/identity.ex`) is **unchanged** — it resolves a token's claimed role names
(always platform-role strings, per its own call site — `Letflow.Oidc.ClaimMapping`'s
contract) to `group_id`s via a bare `tr.name in ^role_names` match, with no `kind`
filter. This is safe unchanged: a token can only ever claim one of the six platform-role
strings in the first place (`ClaimMapping`'s own closed mapping), so this query can never
match a `:process_routing_role`-kind row by construction — adding a `kind` filter here
would be a no-op given today's inputs, not a defect being left open. Flagged as an open
question in §5 for REVIEWER, not silently decided, in case a future OIDC claim shape
changes that assumption.

### 2.5 New: `RoleRegistry.check_platform_role_coverage/2` — the provisioning-time signal (AC2)

```
@type coverage_gap :: %{
        held_process_routing_roles: [String.t()],
        held_platform_roles: [String.t()]
      }

@spec check_platform_role_coverage(user_id :: Ecto.UUID.t(), opts :: [prefix: String.t()]) ::
        :ok | {:error, {:missing_platform_role, coverage_gap()}}
```

Computes, for `user_id`, the same `group_members ⋈ tenant_role` join
`list_effective_role_names/2` uses but **unfiltered by `kind`** (reads both domains),
partitions the result by `kind`, and:

- `held_platform_roles != []` → `:ok` (the user holds at least one platform role,
  regardless of what else they hold — this call does not police *which* platform role,
  only that at least one exists, matching the plain fact that `evaluate_access/2` treats
  any non-empty platform-role set as "not automatically locked out of every route").
- `held_platform_roles == [] and held_process_routing_roles != []` →
  `{:error, {:missing_platform_role, %{held_process_routing_roles: [...], held_platform_roles: []}}}`
  — names the exact gap: "this user's only tenant_role membership(s) are process-routing
  names, and none of them confer any platform permission by themselves" — directly
  answering AC2's "explicit, actionable error... explaining what additional role is
  required" (the caller reading `held_process_routing_roles` sees exactly which routing
  roles are already granted, so "add `TASK_WORKER` in addition to these" is a direct,
  unambiguous next step — this function names the gap; it does not prescribe which of the
  six platform roles closes it, since that is a call the provisioning operator makes based
  on what the user is actually meant to be able to do).
- `held_platform_roles == [] and held_process_routing_roles == []` → `:ok` — a user with
  *no* `tenant_role` membership at all is an ordinary, unprovisioned-for-any-role user,
  not this bug's scenario; this function's job is to catch the specific
  process-routing-only trap, not to police every unrelated all-roles-empty state.

This is a **pure read/check**, not a gate — it does not block `add_group_member/3` or
any other write path from completing (no acceptance criterion asks for an enforced,
blocking precondition, and blocking every `add_group_member/3` call against a
process-routing-kind group would incorrectly forbid the ordinary, legitimate two-step
sequence "bind the routing group first, add the platform-role membership right after" a
provisioning script may reasonably use). It exists to be called **explicitly** —
by a provisioning script immediately after binding a user's group memberships (the
concrete SwiftRoute T-0140 fix, §4), and by the regression test (§3) — matching the
issue's own "surfaced... at provisioning time" framing rather than a runtime
request-path change.

### 2.6 `GET /tasks/inbox` request-path behavior — deliberately unchanged

`Letflow.Plugs.Authorize`, `Authorization.evaluate_access/2`, and the 403 response body
(`Letflow.Api.Response.forbidden("insufficient permissions")`) are **not modified** by
this design. A process-routing-role-only user who was never additionally granted a
platform role still gets `403` on `GET /tasks/inbox` after this fix — the same outcome
as today, but now for the *correct* reason (no platform role held, full stop) rather than
as a side effect of a role-domain conflation bug. Per §1's decision, this is intentional:
the platform's answer to "does a process-routing role alone grant task-API access" is
and remains **no**; what closes AC2 is that the gap is now catchable at provisioning
time (§2.5) instead of only discoverable by a user hitting a 403 in production, as T-0140
did. Widening the 403 body itself to explain "you're missing platform role X" was
considered and rejected: `Letflow.Plugs.Authorize`'s existing `:Deny403` path is
deliberately generic for every caller regardless of *why* they were denied (no route
currently distinguishes "wrong role" from "no role" in its response body), and revealing
role-requirement detail to an unauthenticated-for-that-permission caller is exactly the
kind of information disclosure this module's own INV-2-adjacent minimal-response
discipline avoids elsewhere — changing that discipline for this one policy key only,
without a broader across-the-board decision, would be an inconsistent, undiscussed
widening of this plug's response contract. Flagged for REVIEWER as an explicit
alternative if that reasoning is judged wrong (§5).

## 3. Regression-test design (AC2, AC3)

Four independent tests, spanning schema/registry, context, and router levels — no single
test is asked to prove the whole fix.

**T1 — `RoleRegistry.upsert_role/4` rejects a mistyped `:platform_role` name.**
`upsert_role("PLATFORM_ADMN", :platform_role, group_id, opts)` →
`{:error, :name_not_a_recognized_platform_role}`; the identical call with
`kind: :process_routing_role` succeeds (open-ended domain, no literal-set check) —
proves §2.3's asymmetric validation.

**T2 — `list_effective_role_names/2` excludes a `:process_routing_role`-kind name.**
Provision a user whose only `tenant_role` membership (via group) is
`upsert_role("role-ops-manager", :process_routing_role, group_id, opts)` →
`list_effective_role_names(user_id, opts) == []`. Add a second membership via
`upsert_role("TASK_WORKER", :platform_role, other_group_id, opts)` →
`list_effective_role_names(user_id, opts) == ["TASK_WORKER"]` (the process-routing name
never appears, regardless of how many of it the user holds) — proves §2.4's filter is
the actual mechanism closing the silent-`[]` bug, isolated from any router/plug
machinery.

**T3 (AC2, provable by a test) — `check_platform_role_coverage/2` names the exact gap,
and closes it once the companion grant exists.** Using the same
`role-ops-manager`-only user from T2: `check_platform_role_coverage(user_id, opts) ==
{:error, {:missing_platform_role, %{held_process_routing_roles: ["role-ops-manager"],
held_platform_roles: []}}}`. After adding the `TASK_WORKER` membership:
`check_platform_role_coverage(user_id, opts) == :ok`. This is the direct proof of AC2's
"either succeed, or receive an explicit, actionable... signal" — the signal is this
function's return value, named and structured, not a log line a test would have to
scrape.

**T4 (AC2/AC3, end-to-end) — `GET /tasks/inbox` router-level scenario, both halves.**
New test in `test/letflow/routers/tasks_test.exs` (or wherever this router's existing
inbox tests live — reuse that file's existing tenant/user/group fixture helpers, do not
duplicate them):

- *Process-routing-role-only, no companion platform role* (the exact T-0140/SwiftRoute
  shape — a group bound to `role-ops-manager` via `upsert_role/4` with
  `kind: :process_routing_role`, user added as a member, a `HUMAN_TASK` in a running
  instance routed to that group so a real, assignable task row exists): a bearer token
  for that user against `GET /api/v1/tasks/inbox` → `403`, `problem+json`, matching
  §2.6's stated unchanged behavior. This is the regression guard that the *previous*
  silent-`[]`-then-403 bug and the *current*, intentional
  no-platform-role-held-then-403 behavior are not accidentally distinguished by this
  test's assertions alone — the point of T2/T3 existing separately is that they prove
  *why* it's 403 (no platform role, not a swallowed one), which this router-level test
  alone cannot.
- *Same setup, plus the companion `TASK_WORKER` platform-role membership*: `GET
  /api/v1/tasks/inbox` → `200`, and the task routed to `role-ops-manager`'s group
  appears in the response body — proving AC2's "successfully access... tasks assigned to
  their role/group" branch actually works end-to-end once the design's own remedy (a
  companion platform-role grant) is applied, not merely that the 403 goes away.

**AC3 — SwiftRoute UAT unblock.** Not a new automated test under this design's own
scope (UAT-RUNNER's territory, not CODE-DESIGNER's/ELIXIR-DEV's) — T4's first scenario
*is* the SwiftRoute persona shape reproduced under `mix test`, and §4 below states the
concrete, minimal provisioning-script change (add each SwiftRoute persona's `TASK_WORKER`
membership alongside their existing routing-group membership) that this design's decision
requires before the SwiftRoute UAT scenario can pass. That change is a fixture/tooling
edit, not new `lib/letflow/` code, and is out of this design's own artefact scope — flagged
here so ELIXIR-DEV/whoever owns the T-0140 fixture does not have to rediscover it.

## 4. What this does and does not fix, and the interaction with ISS-0773

- **Fixes:** the structural conflation (§0) that made a process-routing-role-only user's
  effective platform-role set silently `[]`. After this fix, that same user's set is
  still `[]` (§2.6 — deliberately, per §1's decision) but the reason is now transparent
  and the gap is catchable at provisioning time (§2.5) rather than only in production.
- **Does not fix, and does not need to:** ISS-0773 (already fixed, PR #1680, commit
  `9546ef2d`) — that bug was about `sync_role_claims_from_token/3` permanently stamping
  `role_claims_synced_at` even when zero grants were written, locking a
  *legitimately-platform-roled* user (`worker-user`, holding the recognized `TASK_WORKER`
  string) out of their own already-correct role. This design's `kind` filter on
  `list_effective_role_names/2` (§2.4) does not touch `sync_role_claims_from_token/3`'s
  own write path or its `role_claims_synced_at` marker logic at all — the two fixes are
  independent and composable, confirmed by re-reading ISS-0773's own fix (the
  `group_ids != []` conditional stamp, `lib/letflow/identity.ex` lines ~759-781 as read
  for this design) against §2.3/§2.4 above: neither touches the other's code path.
- **Requires a follow-on, out-of-scope-for-this-design change:** any existing
  provisioning script/fixture (T-0140's SwiftRoute persona seeding included) that calls
  `RoleRegistry.upsert_role/3` today must be updated to (a) call the new `upsert_role/4`
  with an explicit `kind`, and (b) for any persona meant to reach task-API routes,
  additionally grant a platform role. Both are mechanical, call-site-level changes
  flagged for ELIXIR-DEV, not new design decisions.

## 5. Open questions (explicit, not silently resolved)

**OQ-1 — `resolve_group_ids_for_role_names/2`'s `kind`-blindness (§2.4).**
**Corrected 2026-09-21 by REVIEWER — the premise below was checked and is wrong.**
This paragraph originally claimed the function was safe to leave unfiltered because "a
token can only ever claim one of the six platform-role strings, per
`Letflow.Oidc.ClaimMapping`'s existing closed mapping." That is false:
`Letflow.Oidc.ClaimMapping.resolve_roles/2` (`lib/letflow/oidc/claim_mapping.ex:166-176`)
does not closed-set-filter anything — it iterates the configured claim paths and passes
whatever string list the IdP token carries straight through unfiltered (mapping non-string
array elements to `""`, but otherwise verbatim). The actual closed-set gate,
`Authorization.role_from_string/1`, sits only on the separate request-time
`AuthPipeline`/`Authorization.roles_from_strings/1` path — it is never applied to
`identity_context.roles` before `sync_role_claims_from_token/3` passes it into
`resolve_group_ids_for_role_names/2` (`lib/letflow/identity.ex:741`), which matches on
`t.name in ^role_names` against the full `tenant_role` table regardless of `kind`.

**Corrected reasoning, and why this is left unchanged in this PR anyway:** an IdP token
that claims an arbitrary string happening to match a `:process_routing_role`-kind
`tenant_role.name` (e.g. `role-ops-manager`) will cause
`sync_role_claims_from_token/3` to write a `group_members` row for that routing group —
group membership the token holder did not legitimately earn via this platform's own
`kind: :platform_role` grant path. The blast radius is bounded, not open: this fix's own
`kind` filter on `list_effective_role_names/2` (§2.4 above) means that
`group_members` row can **never** reach `Authorization.roles_from_strings/1` or confer
any platform permission — `list_effective_role_names/2` only ever reads `kind ==
:platform_role` rows. The exposure is confined to unintended routing-group membership
(HUMAN_TASK task-assignment eligibility for that group), not privilege escalation. This
is also **pre-existing, unchanged behavior**: `resolve_group_ids_for_role_names/2` and
`sync_role_claims_from_token/3` have zero diff hits in this PR (confirmed against
`git diff origin/main...` for `lib/letflow/identity.ex`), and fixing it is out of
ISS-0774's own scope (ISS-0774 is about the platform-role/process-routing-role
conflation in the *read* path feeding `Authorization`, not about hardening the OIDC
claim-to-group-membership write path against an untrusted/misconfigured IdP). Accepted
as a documented known-limitation rather than a blocker for this PR — filed as
**ISS-0775** for a follow-on fix (apply the same `kind: :platform_role`-style
discipline to the write path, or reject unrecognized claimed role strings outright)
tracked separately, not gating TEST-DESIGNER on this PR.

**OQ-2 — Should `check_platform_role_coverage/2` be wired into any existing provisioning
call site automatically, rather than left as an opt-in check a script must remember to
call?** This design deliberately leaves it opt-in (§2.5 — not a gate on
`add_group_member/3`) because no acceptance criterion asks for an enforced precondition
and a hard gate there would forbid a legitimate two-step provisioning sequence. But this
means a *future* T-0140-shaped gap (a new provisioning script that simply never calls
this function) is still possible in principle. Flagged for REVIEWER: is opt-in
sufficient, or should `docs/guides/backend_developer_guide.md` gain a stated convention
("any script that binds a user to a `:process_routing_role`-kind group must call
`check_platform_role_coverage/2` immediately after") — a documentation-level mitigation
this design does not attempt to invent unprompted.

**OQ-3 — `kind` naming.** `:platform_role`/`:process_routing_role` were chosen to read
naturally against this design's own prose and against `Letflow.Api.Authorization`'s
existing `role()` type name. Not cross-checked against any pre-existing vocabulary
elsewhere in the codebase (none was found — `grep -rn "process_routing\|routing_role"
lib/` returns no hits before this design), so there is no established term this risks
colliding with, but naming is inherently a judgement call — flagged in case REVIEWER
prefers different literals (the migration/backfill logic in §2.1 is unaffected by the
literal names chosen, only by there being exactly two of them).

## 6. Files touched by this design

| File | Change |
|---|---|
| `priv/repo/migrations/20260921000001_add_kind_to_tenant_role.exs` (or later timestamp if a same-day collision exists at merge time) | New migration: `kind` column + backfill (§2.1), replayed per tenant schema. |
| `lib/letflow/identity/tenant_role.ex` | `kind` field (`Ecto.Enum`), `changeset/2` widened (§2.2). |
| `lib/letflow/identity/role_registry.ex` | `upsert_role/3` → `upsert_role/4` (new `kind` param, new validation, new error atom); new `check_platform_role_coverage/2` (§2.3, §2.5). `resolve_role_in_tx/1` unchanged. |
| `lib/letflow/identity.ex` | `list_effective_role_names/2` query gains one `where` clause (§2.4). `sync_role_claims_from_token/3`/`resolve_group_ids_for_role_names/2` unchanged (§2.4, OQ-1). |
| `lib/letflow/api/authorization.ex` | **Unchanged.** `role_from_string/1`'s closed set and `roles_from_strings/1`'s drop-unrecognized contract are confirmed correct for their actual (token-claims) input and are not touched by this fix — the conflation this design closes happens upstream of this module, not inside it. |
| `lib/letflow/plugs/authorize.ex` | **Unchanged** (§2.6). |
| Existing `RoleRegistry.upsert_role/3` call sites (provisioning scripts/fixtures, including T-0140's SwiftRoute seeding) | Must migrate to `upsert_role/4` with an explicit `kind`; task-API-reaching personas additionally need a platform-role grant (§4) — out of this design's own file list, flagged for the implementing agent. |

## 7. Acceptance-criteria mapping

| AC | Where satisfied |
|---|---|
| AC1 — explicit decision, not implicit | §1 (decision), §1.2/§1.3 (rejected alternatives named with reasons) |
| AC2 — process-routing-role-only user succeeds or gets an explicit, actionable signal, provable by a test | §2.5 (`check_platform_role_coverage/2`), §2.6 (why request-path stays a 403, deliberately), T3/T4 (§3) |
| AC3 — SwiftRoute UAT scenario unblocked | §3 "AC3" paragraph, §4's flagged provisioning-script follow-on |
| AC4 — `mix letflow.check` passes | Not this design's own artefact to run (CODE-DESIGN-VALIDATOR/ELIXIR-DEV's territory) — nothing in this design introduces a construct (unbounded atom creation, raw SQL interpolation, missing `@spec`) that `mix letflow.check`'s static checks are known to flag; flagged here only as a acknowledgement, not a claim of having run it. |
