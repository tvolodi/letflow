# Design — ISS-0773 (queue task 771, GH-1677): zero-grant role-claims sync permanently locks users out

Run-id: WF03-ISS0772-20260921
Stage: S4
Owner (design): CODE-DESIGNER. Touches `lib/letflow/identity.ex` only — no new files, no
migration (the column `users.role_claims_synced_at` and its semantics already exist,
added by REQ-378 / `lib/letflow/design/req378-oidc-live-revocation-check.md` §2.2; this
design amends the write-condition on that existing column, nothing else).

**Recreation note (2026-09-21):** this doc's original content was produced and passed
CODE-DESIGN-VALIDATOR under the filename `iss-0772-role-claims-sync-lockout-fix.md`, but
was never committed/pushed from the worktree it was written in and was lost when that
worktree was cleaned up — SECURITY-REVIEWER caught the gap (no inspectable artifact in
git history) before its own gate ran. This is a verbatim reconstruction of the same
content, decisions, and reasoning, renamed to match this issue's real, current filing —
`docs/issues/ISS-0773.yaml` (the id renumbered a second time from ISS-0772 due to another
local-filename collision; `docs/issues/ISS-0772.yaml` is not this issue). ELIXIR-DEV's
implementation on branch `feature/WF03-ISS0772-20260921` (commit `9724fbeb`, PR #1680)
was built from the original, lost copy of this doc — its in-code comments referencing
`ISS-0772`/the old filename are corrected to `ISS-0773`/this filename in the same commit
that adds this file. No design decision changed; only the filename/issue-id label did.

**Mandatory downstream gate:** this change is to `Letflow.Identity`, the tenant-role/
auth-claims-resolution module — same class as every other `lib/letflow/identity.ex`
change in this codebase's history (REQ-378 itself, ISS-0736). **SECURITY-REVIEWER
sign-off against `docs/agents/instructions/security-invariants.md` INV-1..INV-8 is
required before merge**, in addition to REVIEWER. Do not route this around
SECURITY-REVIEWER on the theory that it's "just a logging change" — the write-condition
change to `role_claims_synced_at` is the actual security-relevant surface (§2.2.4 of
REQ-378's design is the permanence invariant this fix must not weaken; §3 below re-checks
that invariant explicitly against this fix).

## 0. Source read — confirmed, not assumed

Read in full for this design: `sync_role_claims_from_token/3` and
`resolve_group_ids_for_role_names/2` (`lib/letflow/identity.ex`, pre-fix lines
702-790), both call sites gating on `role_claims_synced_at == nil`
(`upsert_by_external_identity/4`, `re_select_on_conflict/3`), `Letflow.Identity.TenantRole`
(`lib/letflow/identity/tenant_role.ex`), `Letflow.Oidc.IdentityContext`
(`lib/letflow/oidc/identity_context.ex`), `Letflow.Oidc.ClaimMapping.resolve_roles/2`
(`lib/letflow/oidc/claim_mapping.ex`), `Letflow.Identity.RoleRegistry.upsert_role/3`
and `validate_role_name/1` (`lib/letflow/identity/role_registry.ex`), and REQ-378's own
design doc §2.2-§2.2.4 (`lib/letflow/design/req378-oidc-live-revocation-check.md`).
Confirmed via `grep` that, pre-fix, `role_claims_synced_at` was referenced nowhere else
in `lib/` or `test/` besides `identity.ex` itself, `identity/user.ex` (field
declaration), `identity_migration.ex` (an unrelated historical-schema-freeze comment),
and `test/letflow/plugs/iss0736_oidc_live_revocation_test.exs` (assertions on stamping
behavior — see §4).

## 1. Root cause

**Both a seed-data gap and a claim-mapping gap are live possibilities in this
codebase, and the fix must not assume it is only one of them** — here is the evidence
for each, read directly from source, not inferred:

- **Seed-data gap is real and unguarded against:** `resolve_group_ids_for_role_names/2`
  is a plain `WHERE name IN (...)` query against `tenant_role`. Nothing anywhere in the
  provisioning/deploy path guarantees a `tenant_role` row exists for every role name an
  IdP might claim — `RoleRegistry.upsert_role/3` is called only by whatever seeds/admin
  tooling a given tenant's operator runs, and a brand-new tenant (or a tenant mid-rollout
  of a new role) can trivially have zero `tenant_role` rows, or rows for only some of the
  roles its IdP realm is configured to claim. REQ-378's own design doc (§2.2.2 point 1)
  explicitly sanctions this as *not an error*: "the IdP is free to claim role names this
  tenant hasn't bound to a group yet." So a correctly-configured system can legitimately
  produce zero resolved `group_id`s for a non-empty claimed-role list — this is not
  automatically a bug condition, which is exactly why REQ-378's own test fixture
  (`TokenVerifierDouble`, claims `realm_access.roles: ["VIEWER"]`) deliberately seeds no
  matching `tenant_role` row and treats the resulting `[]` as correct (§2.3 of that
  design).
- **Claim-mapping/naming-convention gap is equally real and unguarded against:**
  `TenantRole.name` has no normalization on write (`RoleRegistry.validate_role_name/1`
  only checks non-empty, `<= 128` codepoints, and no control characters — no case
  folding, no whitespace trimming, no prefix/namespace stripping) and
  `resolve_group_ids_for_role_names/2` does an exact-string `IN` match with no
  normalization on read either. `ClaimMapping.resolve_roles/2` passes claimed role
  strings through completely unchanged from whatever the IdP put in the configured
  claim path (`config.roles_claim_paths`, e.g. Keycloak's `realm_access.roles`). Nothing
  in this codebase enforces that an admin who ran `upsert_role("Tenant Admin", ...)` and
  an IdP realm configured to claim `"tenant-admin"` (or `"TENANT_ADMIN"`, or a
  realm-prefixed `"myrealm:tenant-admin"`) ever produce matching strings. A casing or
  naming-convention drift between "what the IdP's realm role is named" and "what string
  an admin typed into `upsert_role/3`" silently reproduces the identical zero-grant,
  zero-log, marker-still-gets-stamped symptom.

**What would distinguish them, per-tenant, at incident time (state this explicitly for
whoever investigates a future occurrence — not resolved by this fix, which must handle
both):** query `tenant_role` for the affected tenant's schema. Zero rows total -> seed-
data gap (nothing was ever registered for this tenant). Non-zero rows, but no row whose
`name` matches (case-sensitively) any string in the affected user's token's claimed-roles
list -> claim-mapping/naming-convention gap. Both are possible in the same codebase for
different tenants simultaneously (a new tenant mid-provisioning vs. an established tenant
with an IdP-side realm-role rename) — this fix's job is to make either case observable
and non-fatal, not to guess which one it is. (For this specific incident, `ISS-0773.yaml`
`fix_direction` records that the live QA diagnosis subsequently confirmed the seed-data
branch for `bpm-default` — zero `tenant_role` rows, no matching write path ever
successfully called — but this design was written, and must still hold, without that
after-the-fact confirmation.)

## 2. Fix — exact mechanism

### 2.1 Log line on zero-resolution (task item b)

Add a `Logger.warning/1` call inside `sync_role_claims_from_token/3`, immediately after
`resolve_group_ids_for_role_names/2` returns, guarded by: `identity_context.roles` is
non-empty AND the resolved `group_ids` list is empty. (Not merely "`group_ids == []`"
alone — a token that claims zero roles to begin with resolving to zero groups is not a
mapping failure and must not log; guard on both being true together.)

Log content — every field named explicitly, matching this module's existing
`Logger.warning/1` call sites' style (short, single interpolated string, `inspect/1` on
structured values, never a raw exception):

```
"sync_role_claims_from_token/3: zero group_ids resolved for a non-empty claimed-role " <>
  "list -- user will read roles: [] and gain no grants (tenant=#{inspect(prefix)}, " <>
  "user_id=#{user.id}, claimed_roles=#{inspect(identity_context.roles)})"
```

Required fields, all present in the string above: the tenant (the `prefix`/schema
already in scope as the function's own `opts[:prefix]` — this is the per-tenant-schema
identifier this module already uses everywhere else it logs a tenant-scoped operation),
the affected `user.id`, and the full claimed-role-name list from the token
(`identity_context.roles`) — enough for an operator to immediately run the §1
distinguishing query without re-deriving what was claimed from the JWT itself. Do not
log `identity_context.email`/`preferred_username` in this line — not required to
diagnose the mapping gap, and this module's existing logging discipline already
establishes the norm of logging only what's needed for the specific failure, not the
full context struct.

Level: `Logger.warning/1`, not `Logger.error/1` — matches this function's own existing
`Logger.error/1` reservation for genuine transaction failures (the `{:error, step,
reason, _changes}` branch); a zero-resolution outcome is not a crash/exception, it is a
successful, legitimate-per-REQ-378 result that nonetheless deserves operator visibility
because of what it now means for lockout risk (§2.2 below) — `warning` matches that
severity.

### 2.2 Close the lockout — chosen mechanism: only stamp the marker when >=1 grant was written

**Chosen:** `sync_role_claims_from_token/3` stamps `role_claims_synced_at` (via the
existing `Multi.update(:user, ...)` step) **only when `group_ids` is non-empty** — i.e.
only when at least one `group_members` row was (or already existed to be) written for
this user as a result of this call. When `group_ids == []`, the transaction still runs
(step 2's `Multi.run(:memberships, ...)` is a no-op `Enum.each` over an empty list,
exactly as today), but the `Multi.update(:user, ...)` step is skipped entirely and the
function returns the **original, unmodified `user`** struct — marker still `nil`,
identical in shape to today's existing "transaction failed" fallback return.

Concretely, restructure the `Multi` pipeline so `Multi.update(:user, ...)` is
conditional on the resolved `group_ids` rather than unconditional: build the `Multi`
with only the `:memberships` step always present, and add the `:user` update step only
when `group_ids != []` (`Ecto.Multi` supports building a pipeline conditionally before
`Repo.transaction/1` runs it — this is a pipeline-construction change, not a new runtime
branch inside a `Multi.run` callback). When the `:user` step was never added to the
`Multi`, `Repo.transaction/1`'s result has no `:user` key in its `changes` map on
success; the existing `case result do {:ok, %{user: synced_user}} -> synced_user` clause
must gain a second success-shaped clause for this case (`{:ok, %{memberships: _}}` with
no `:user` key -> return the original `user` unchanged) alongside the existing `{:ok,
%{user: synced_user}}` and `{:error, step, reason, _changes}` clauses.

**Why this is safe against retry going forward:** because the marker stays `nil`, the
existing marker-gate at both call sites (`upsert_by_external_identity/4`,
`re_select_on_conflict/3`) re-enters `sync_role_claims_from_token/3` on this same user's
*next* login — the function's own moduledoc already documents this exact self-healing
shape for the transaction-failure case ("because the marker stays nil, the very next
call for this same user retries the sync"); this fix makes the zero-grant case use the
identical mechanism instead of inventing a new one.

**Why this does not reopen REQ-378's revocation-permanence invariant (§2.2.4 of the
REQ-378 design):** that invariant's actual requirement is "once a user has been granted
>=1 `group_members` row via this sync, a later revocation of those grants must not
re-trigger a re-sync from the (possibly stale) token claim." Under this fix, the marker
is stamped if and only if >=1 `group_members` row was actually written on that call — so
a user who *did* get synced with >=1 grant still has the marker permanently stamped
after this fix, identical to today, and revocation (`remove_group_member/3`, which does
not touch `users`) still leaves that marker untouched and non-`nil`. The invariant only
ever applied to users who had a successful non-empty grant in the first place; this fix
changes nothing about that population. The only behavior change is for users who
resolved to *zero* grants, who under this fix are not yet considered "synced" at all —
correctly so, since they received no grants for the marker to be protecting.

**Accepted tradeoff, stated explicitly (this is the judgment call CODE-DESIGN-VALIDATOR
and SECURITY-REVIEWER should sign off on, not silently accept):** a user whose token
*legitimately, permanently* claims a role with no matching `tenant_role` row for this
tenant (§1's seed-data-gap case, e.g. a role this tenant has decided never to map to any
group) will re-attempt this same zero-grant sync — one extra `resolve_group_ids_for_role_names/2`
query plus one no-op `Multi.run` — on every single login, forever, since the marker can
never be stamped for them. This is accepted, not a residual bug, for two reasons: (a) it
is the exact same "uncached per-request DB read is fine" posture REQ-378's own design
already established as the norm for `list_effective_role_names/2`'s live revocation
check (§0 of that design, citing `verify_api_token/2` as precedent) — one extra indexed
`WHERE name IN (...)` query per login is not a meaningfully different cost profile; (b)
the alternative (a separate "sync attempted, don't retry" flag independent of grant
count) was considered and rejected — see §2.3.

### 2.3 Alternative considered and rejected — a separate retry-suppression flag

Considered: add a second column/flag (e.g. `role_claims_sync_attempted_at`, always
stamped regardless of grant count) so a legitimately-zero-role user's repeated
zero-grant retries stop after the first attempt, while a distinct
`role_claims_synced_at` (only stamped on >=1 grant) continues to gate the
revocation-permanence invariant.

**Rejected** for two reasons: (1) it reintroduces exactly the ambiguity REQ-378's design
already named and deliberately avoided (§2.2.4: "a row-count-based trigger... is
indistinguishable between 'never yet synced' and 'synced once, then fully revoked'") —
a two-flag scheme needs its own separate reasoning for why `role_claims_sync_attempted_at`
being non-`nil` can never be mistaken for `role_claims_synced_at`'s permanence guarantee,
adding a second marker whose own invariants must independently be re-verified by
SECURITY-REVIEWER, for a benefit (skipping a cheap indexed query on repeat logins for an
edge-case population) this design does not judge worth that added surface. (2) it needs
a new migration (a second tenant-scoped column) for a problem §2.2's accepted-tradeoff
reasoning already shows is cheap to simply retry. If a future incident shows the retry
cost is not actually negligible (e.g. `resolve_group_ids_for_role_names/2` becomes
measurably hot for a tenant with many permanently-unmapped-role users), that is grounds
to revisit this rejection — not evidence this design should have chosen it now.

## 3. Signature change

```
@spec sync_role_claims_from_token(
        user :: User.t(),
        identity_context :: IdentityContext.t(),
        opts :: opts()
      ) :: User.t()
```

Unchanged — this fix changes only the function body's internal `Multi` construction and
result-matching, not its public contract. Same for `resolve_group_ids_for_role_names/2`
(private, unchanged spec) — this fix does not touch that function's body at all, only
how its caller reacts to an empty result.

## 4. Regression test design

New test(s) in `test/letflow/identity_test.exs`, colocated with (and cross-referencing)
`test/letflow/plugs/iss0736_oidc_live_revocation_test.exs`'s existing
`role_claims_synced_at` coverage since that file already exercises the marker-stamping
contract end-to-end.

**Test 1 — zero-grant sync does not stamp the marker and is retried on next call.**
Setup: a tenant with zero `tenant_role` rows (or `tenant_role` rows whose `name`s do not
match any claimed role). Build an `IdentityContext` whose `roles` is a non-empty list
matching none of them. Call `sync_role_claims_from_token/3`. Assert: (a) the returned
`User.t()`'s `role_claims_synced_at` is `nil` (unchanged from input); (b) zero
`group_members` rows exist for this user afterward (same as before the call — the
no-op-write behavior is unchanged from today); (c) calling
`sync_role_claims_from_token/3` a **second** time for the same user (simulating a second
login before any `tenant_role` row is added) does not raise and again returns
`role_claims_synced_at: nil` — proving the retry-on-nil-marker path actually re-executes
rather than short-circuiting on stale state. This is the test that would have caught
ISS-0773 directly: under the pre-fix behavior, step (a) fails (marker gets stamped
non-nil on the very first call).

**Test 2 — the zero-resolution log line fires with the right content.** Same setup as
Test 1. Assert (via `ExUnit.CaptureLog`) that a `Logger.warning/1` line is emitted
containing: the tenant/prefix value used in the test, the test user's `id`, and every
string from the test's claimed-`roles` list. Assert it does **not** fire when
`identity_context.roles == []` (the "claimed nothing" case, which must stay silent per
§2.1's guard).

**Test 3 — non-empty-grant sync still stamps the marker (no regression on the success
path).** Setup: a `tenant_role` row whose `name` matches one of the claimed roles. Call
`sync_role_claims_from_token/3`. Assert `role_claims_synced_at` is now a non-`nil`
`DateTime`, exactly one `group_members` row was written, and calling the function again
for the same user now short-circuits at the call-site gate (per the existing
`upsert_by_external_identity/4`/`re_select_on_conflict/3` `if is_nil(...)` checks). This
assertion is exercised by `iss0736_oidc_live_revocation_test.exs`'s existing "does NOT
re-sync on a later request" test (line ~297), which must still pass unmodified since
this fix does not change the non-empty-grant path's observable behavior at all.

**Test 4 — a token claiming zero roles at all (`identity_context.roles == []`) is
unaffected.** This is the pre-existing, already-correct "user claims no roles" case
(distinct from Test 1's "claims roles that don't resolve to anything") — assert it
behaves exactly as before this fix: `Multi.run(:memberships, ...)` no-ops (nothing to
resolve), and per §2.1/§2.2 the marker is *also* not stamped (an empty `roles` claim
resolves to `group_ids == []` too, so this collapses into the same §2.2 code path as
Test 1) and no warning log fires (§2.1's guard requires non-empty `identity_context.roles`).
This test is included specifically to pin down that "user has no roles at all" and
"user's roles don't resolve" now share the same non-stamping mechanism but are logically
distinguished by the log guard — the two must not be conflated into one test case, since
§2.1 requires them to produce different logging behavior.

## 5. Open questions

- **None outstanding for implementation.** The one judgment call this design makes
  explicitly (§2.2's accepted-tradeoff, §2.3's rejected alternative) is stated as a
  decision with reasoning, not left as a TBD — ELIXIR-DEV should implement §2.2 as
  specified. If SECURITY-REVIEWER or REVIEWER disagrees with the §2.3 rejection (e.g.
  judges the per-login retry cost unacceptable for some anticipated tenant shape), that
  is a sign-off-time objection to raise against this design, not a gap in it.
- **Not in this design's scope:** actually distinguishing, for the specific incident
  that motivated this issue, whether it was a seed-data or claim-mapping gap for that
  tenant — §1 gives the diagnostic query an operator or ISSUE-FIXER would run; §1's final
  parenthetical notes the live QA diagnosis subsequently confirmed the seed-data branch
  for `bpm-default`, but confirming that against real tenant data is outside a design
  doc's own scope.
