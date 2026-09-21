# ISS-0775 — `resolve_group_ids_for_role_names/2`'s write path is not scoped by `tenant_role.kind`

CODE-DESIGNER design for MINOR `docs/issues/ISS-0775.yaml` (GH-1684, Q-773, queue task
773). Fix target: `Letflow.Identity.resolve_group_ids_for_role_names/2` (private,
`lib/letflow/identity.ex:816-829`), called only from
`Letflow.Identity.sync_role_claims_from_token/3` (`lib/letflow/identity.ex:739-808`).

Explicitly **not** in scope: `Letflow.Oidc.ClaimMapping.resolve_roles/2` (unchanged —
its "pass whatever the token claims straight through" contract is correct for its own
zero-I/O, pure-mapping role, confirmed again below in §1.4); `list_effective_role_names/2`
(unchanged — already `kind`-filtered by ISS-0774); `RoleRegistry.upsert_role/4`
(unchanged — this fix touches a read/match query, not role-binding provisioning).

## 0. Root cause (already diagnosed by the issue; restated briefly)

`resolve_group_ids_for_role_names/2` matches every string in a token's claimed
`identity_context.roles` against `tenant_role.name` with no `kind` predicate:

```
query =
  from(t in TenantRole,
    where: t.name in ^role_names,
    select: t.group_id,
    distinct: true
  )
```

`tenant_role` now (post-ISS-0774) holds two structurally unrelated domains
distinguished only by `kind` (`:platform_role` | `:process_routing_role`, see
`lib/letflow/design/iss-0774-role-domain-authorization.md` §0). Because
`Letflow.Oidc.ClaimMapping.resolve_roles/2` (`lib/letflow/oidc/claim_mapping.ex:154-179`)
does not closed-set-filter the claimed strings it returns — confirmed again here: it
walks `config.roles_claim_paths`, returns the first path that resolves to a list,
verbatim (non-string elements become `""`, nothing is dropped or validated against
`Authorization.role_from_string/1`) — an IdP token can claim *any* string. If that
string happens to match an existing `tenant_role.name` of either `kind`, this query
resolves it to a `group_id`, and `sync_role_claims_from_token/3` writes a
`group_members` row for it, unconditionally.

**Practical effect** (per the issue, re-confirmed by source read): a token claiming a
string matching a `:process_routing_role`-kind row grants HUMAN_TASK task-assignment
group membership the holder never earned through this platform's own provisioning path.
Bounded blast radius, not open — `list_effective_role_names/2`'s own `kind ==
:platform_role` filter means this stray membership can never itself reach
`Authorization.roles_from_strings/1` or confer a platform permission.

## 1. The decision (real, not deferred to the issue's own framing)

**Chosen: restrict `resolve_group_ids_for_role_names/2`'s write path to
`kind == :platform_role` rows only — the mirror image of the issue's own candidate
(b), not candidate (b) itself.** This is candidate **(a)** from the issue's
`fix_direction` list, made concrete, over the issue's own tentative preference for
(b). §1.1 gives the mechanism; §1.2/§1.3 explain why (b) and (c) are rejected — including
why (b), despite being the issue's own suggested "more targeted fix," is actually the
wrong direction once checked against `sync_role_claims_from_token/3`'s own designed
purpose, not a defensible alternative left aside on style grounds alone.

### 1.1 Mechanism, in one sentence

Add one predicate to `resolve_group_ids_for_role_names/2`'s existing `where` clause —
`and t.kind == :platform_role` — so a claimed string can only ever resolve to a
`group_id` when it matches a `:platform_role`-kind `tenant_role` row; a claimed string
that happens to collide with a `:process_routing_role`-kind row's `name` now resolves to
nothing for that name, identical in shape to today's existing "no matching row at all"
case (not an error, not logged differently — §2 covers this precisely).

### 1.2 Why not (b) — restrict the write path to `:process_routing_role` rows instead

**Rejected — this is not a narrower version of the current bug, it inverts which
domain the write path exists to serve, and breaks `sync_role_claims_from_token/3`'s own
stated purpose.** Re-reading `lib/letflow/design/req378-oidc-live-revocation-check.md`
§2.2 (the design that introduced this exact function) settles what `resolve_group_ids_
for_role_names/2`'s write path is *for*:

> "One-time sync of a JWT's claimed role names into `group_members`, closing the
> JIT-provisioning gap `list_effective_role_names/2` alone cannot close... a user with
> zero rows there... reads `roles: []` from `list_effective_role_names/2` regardless of
> what their token claims."

`list_effective_role_names/2` is — both before and after ISS-0774 — the **one and only**
function whose output ever reaches `Authorization.roles_from_strings/1` (its own moduledoc,
`lib/letflow/identity.ex:686-692`), and since ISS-0774 it reads **only** `kind ==
:platform_role` rows. The entire reason `sync_role_claims_from_token/3` exists is to
populate `group_members` so that a *platform* role claimed in an OIDC token becomes
visible to that read path — i.e., `resolve_group_ids_for_role_names/2`'s intended,
load-bearing domain is `:platform_role`, not `:process_routing_role`. Restricting it to
`:process_routing_role`-kind rows only, as (b) proposes, would:

1. **Sever REQ-378's entire designed mechanism.** No OIDC-claimed platform role would
   ever again resolve to a `group_id`, so `group_members` would never gain a
   `:platform_role`-kind row from this path again — every OIDC user's
   `list_effective_role_names/2` output would permanently read as if they held no
   platform role at all, regardless of what their IdP legitimately grants. This is not a
   narrowing of an edge case; it is a regression of the exact feature REQ-378 shipped
   (built and hardened across two reworks — `req378-oidc-live-revocation-check.md`'s own
   REWORK 1/REWORK 2 notes — specifically to close this gap).
2. **The "legitimate IdP-federated routing-role claim" use case the issue speculates
   might justify (b) has no support anywhere in this codebase.** Searched
   `lib/letflow/design/*.md`, `docs/`, and the SwiftRoute fixtures
   (`test/fixtures/simulation/swiftroute/*.yaml`) for any design, requirement, or
   provisioning-tooling reference to an OIDC token claiming a process-routing role name
   — none exists. Every process-routing binding in this codebase (`role-ops-manager`,
   `role-ceo`, `role-accountant`, …) is provisioned exclusively through
   `RoleRegistry.upsert_role/4` (`kind: :process_routing_role`) followed by an explicit
   `add_group_member/3` call from provisioning tooling — never from a token claim. (b)
   would trade a real, designed, currently-working feature for a hypothetical one with
   zero evidence it is wanted, let alone specified.
3. **The task's own "must not break legitimate process-routing-role claim-driven group
   membership" framing has no referent to protect.** Since no such legitimate flow
   exists today, (a) — the chosen direction — vacuously satisfies that constraint by
   construction: it changes nothing about how `:process_routing_role`-kind group
   membership is provisioned (still exclusively via `RoleRegistry.upsert_role/4` +
   `add_group_member/3`, unchanged by this fix), and (b) would have broken the one
   `:platform_role`-kind flow that genuinely does exist and is genuinely load-bearing.

If a future requirement wants IdP-federated process-routing-role assignment, that is a
new, deliberately-scoped feature requiring its own design (explicit acceptance
criteria, its own security review of the widened trust boundary) — not something this
MINOR hardening fix should introduce as a side effect of "the other" kind filter.

### 1.3 Why not (c) — validate against `Authorization.role_from_string/1`'s closed set OR an existing `:process_routing_role`-kind name, reject+log otherwise

**Rejected — this does not actually close the vulnerability the issue describes, and
adds complexity beyond what closes it.** Unpacking the proposed validation: a claimed
string passes if it is (i) one of `Authorization.role_from_string/1`'s six platform-role
literals, **or** (ii) an existing `:process_routing_role`-kind `tenant_role.name`. Case
(i) is exactly the platform-role-literal string set — nothing in (c) then stops that
now-validated string from resolving against `resolve_group_ids_for_role_names/2`'s
still-unfiltered-by-`kind` query, which can still match **either** kind of row sharing
that literal name (a `:process_routing_role`-kind row could coincidentally be named
`"TASK_WORKER"` — `RoleRegistry.upsert_role/4`'s open-ended `:process_routing_role`
namespace does not forbid picking a name that collides with a platform-role literal).
So (c), as specified, still permits exactly the cross-kind write ISS-0775 is about,
unless paired with the same `kind`-scoped query (a) already provides — at which point
(c)'s extra closed-set-membership pre-check is redundant work on top of the actual fix,
not an alternative to it. The one thing (c) adds beyond (a) — a logged rejection for a
claimed string that matches *no* `tenant_role` row of either kind at all — already exists
today: `sync_role_claims_from_token/3`'s own "zero group_ids resolved for a non-empty
claimed-role list" warning (`lib/letflow/identity.ex:743-749`, ISS-0773) covers that case
generically, with no per-string logging needed. (c) is folded into (a) rather than kept
as a distinct decision.

### 1.4 `Letflow.Oidc.ClaimMapping.resolve_roles/2` — confirmed out of scope, not silently left unchanged

Not modified. Its moduledoc states a "zero I/O, pure mapping" contract with no
`Letflow.Repo`/`Authorization` coupling — folding a `tenant_role`-kind-aware or
closed-set check into it would violate that documented boundary and would also be the
wrong layer: it has no way to know which `tenant_role.kind` a name might collide with
(that's a DB-backed fact, unavailable to a pure function), and `Authorization`'s own
moduledoc already states its closed-set strictness is deliberately reserved for the
*request-time* `roles_from_strings/1` path, not the claim-mapping stage. Confirmed
correct as-is; this design does not touch it.

## 2. Fix mechanism (types/specs only — no implementation code)

### 2.1 `resolve_group_ids_for_role_names/2` — one added predicate

Signature is **unchanged**:

```
@spec resolve_group_ids_for_role_names(role_names :: [String.t()], opts :: opts()) ::
        [Ecto.UUID.t()]
```

Query behavior changes to: select `t.group_id`, distinct, from `TenantRole` `t` where
`t.name in ^role_names` **and** `t.kind == :platform_role` — the identical shape of
predicate `list_effective_role_names/2`'s own `where` clause already uses
(`gm.user_id == ^user_id and tr.kind == :platform_role`,
`lib/letflow/identity.ex:702`), applied here to the analogous "any claimed name must be
a platform-role-kind binding to count" rule for the write side. A claimed name matching
zero rows (no row at all, or a row that exists but is `:process_routing_role`-kind)
resolves to nothing for that name — same "not an error, name just doesn't map to
anything today" contract this function's own comment already documents
(`lib/letflow/identity.ex:815`, "A claimed role name with no matching tenant_role row
resolves to nothing for that name — not an error"), now covering one more reason a name
can fail to map.

### 2.2 `sync_role_claims_from_token/3` — unchanged

No signature or body change. Its existing "zero group_ids resolved for a non-empty
claimed-role list" warning (`lib/letflow/identity.ex:743-749`) continues to fire
whenever **every** claimed name fails to resolve — which now additionally covers "every
claimed name matched only `:process_routing_role`-kind rows" alongside its existing
"matched nothing at all" case. No new warning variant is introduced: this fix does not
need to distinguish, in the log line, *why* a name failed to resolve (wrong kind vs. no
row at all) — both are "this claim granted nothing," the same outcome the existing
warning already reports on, and inventing a second log message that reveals which
`tenant_role.kind` a colliding name belongs to would leak provisioning-shape
information into logs for no acceptance-criterion-driven reason.

### 2.3 `list_effective_role_names/2`, `RoleRegistry.upsert_role/4`, `RoleRegistry.resolve_role_in_tx/1` — unchanged

None of these three are touched. `list_effective_role_names/2` already carries the
`kind == :platform_role` filter this fix's write-path predicate now mirrors (ISS-0774);
`upsert_role/4` is a provisioning-time write, not a match/read path, and is not part of
this bug's call graph; `resolve_role_in_tx/1` is the engine's own `HUMAN_TASK`
routing-name lookup, deliberately `kind`-blind by ISS-0774's own design (§2.3 of that
design doc) and structurally unrelated to the OIDC claim-sync path this fix scopes.

## 3. Regression-test design

Extends `test/letflow/identity_test.exs`'s existing `describe "sync_role_claims_from_token/3
(ISS-0773)"` block (or a new sibling `describe "sync_role_claims_from_token/3 — kind-scoped
write path (ISS-0775)"` block immediately after it — TEST-DESIGNER's call, either
placement satisfies this design) — reuses that block's own `bind_role_to_group!/2` and
`group_member_rows/2` helpers (already present, `lib/letflow/identity_test.exs:1189-1213`),
widening `bind_role_to_group!/2`'s existing implicit `kind: :platform_role` insert into
an explicit `kind` parameter (call-site-breaking, deliberately, same rationale
`RoleRegistry.upsert_role/4` itself used) so both kinds can be exercised without a
second near-duplicate helper.

**T1 — a claimed name matching a `:platform_role`-kind row still writes `group_members`
(no regression).** Provision an OIDC user; bind `"TASK_WORKER"` to a fresh group via
`bind_role_to_group!("TASK_WORKER", :platform_role, schema_name)`; call
`sync_role_claims_from_token(user, identity_context(%{roles: ["TASK_WORKER"]}),
prefix: schema_name)`. Assert: `group_member_rows(user.id, schema_name)` contains exactly
one row whose `group_id` matches the bound group's `id`, and the returned user's
`role_claims_synced_at` is a non-nil `%DateTime{}`. This is the direct proof §2.1's added
predicate does not regress REQ-378's own legitimate flow (§1.2's point 1) — the whole
reason (b) was rejected.

**T2 — a claimed name matching a `:process_routing_role`-kind row writes nothing (the
actual fix).** Same shape as T1, but bind `"role-ops-manager"` via
`bind_role_to_group!("role-ops-manager", :process_routing_role, schema_name)`; call
`sync_role_claims_from_token(user, identity_context(%{roles: ["role-ops-manager"]}),
prefix: schema_name)`. Assert: `group_member_rows(user.id, schema_name) == []`, and the
returned user's `role_claims_synced_at` stays `nil` (mirrors the existing
ISS-0773-covered "zero group_ids resolved" outcome — §2.2's unchanged marker-gating
logic is what keeps this non-stamping, already covered by that describe block's own
sibling test, re-asserted here for this specific input shape rather than assumed).
Additionally assert (via `ExUnit.CaptureLog.capture_log/1`, mirroring the existing
"logs a warning on zero-resolution" test at `lib/letflow/identity_test.exs:1255`) that
the existing zero-resolution warning fires, naming `"role-ops-manager"` in the
claimed-roles list — proving the claim was seen and deliberately not granted, not
silently dropped before reaching this function at all.

**T3 — one token claiming both a `:platform_role`-kind name and a
`:process_routing_role`-kind name writes only the platform-kind membership.** Bind both
`"TASK_WORKER"` (`:platform_role`) and `"role-ops-manager"` (`:process_routing_role`) to
two distinct fresh groups; call `sync_role_claims_from_token(user,
identity_context(%{roles: ["TASK_WORKER", "role-ops-manager"]}), prefix: schema_name)`.
Assert: `group_member_rows(user.id, schema_name)` contains exactly one row, whose
`group_id` matches the `"TASK_WORKER"` group's `id` — not the `"role-ops-manager"`
group's. This is the single test that most directly matches the issue's own regression
requirement ("a token claiming a role-name string that matches an existing `tenant_role`
of each kind") in one claim list, proving the `kind` predicate discriminates correctly
when both are present simultaneously rather than only when tested in isolation (T1/T2
each test one kind alone; T3 is the one test that can't pass by accident of test
ordering or a filter that happens to match "the only tenant_role row present").

Each of T1-T3 must additionally assert `list_effective_role_names(user.id, prefix:
schema_name)` afterward, to close the loop end-to-end: T1/T3 → `["TASK_WORKER"]`; T2 →
`[]`. This ties the write-path fix back to the read-path guarantee ISS-0774 already
established, in the same test run, rather than trusting the two fixes compose without
re-checking.

## 4. What this does and does not fix

- **Fixes:** the exact vulnerability ISS-0775 describes — an IdP token claiming a string
  that happens to match a `:process_routing_role`-kind `tenant_role.name` can no longer
  cause `sync_role_claims_from_token/3` to write a `group_members` row for that routing
  group.
- **Does not change:** `list_effective_role_names/2`'s output for any user (its own
  `kind` filter, ISS-0774, is unaffected — this fix only narrows what `group_members`
  rows can be written in the first place, not how they're read back).
- **Does not introduce:** any new provisioning path, log message shape, or public
  function. The change is a single `where`-clause predicate inside an existing private
  function.
- **Leaves genuinely open (flagged, not silently resolved) — OQ-1: should an
  OIDC-claimed process-routing-role assignment become a real, designed feature later?**
  This design's §1.2 point 2 found no evidence it is wanted today, but if a future
  requirement wants it, it needs its own acceptance criteria and its own security review
  of the trust boundary being widened (an IdP becoming a source of HUMAN_TASK routing
  eligibility is a materially different claim than "an IdP asserts a platform role
  this tenant already provisioned for that literal string") — not something to infer
  from this fix's absence of a `:process_routing_role` write path.

## 5. Files touched by this design

| File | Change |
|---|---|
| `lib/letflow/identity.ex` | `resolve_group_ids_for_role_names/2`'s query gains one `where` predicate (§2.1). `sync_role_claims_from_token/3` unchanged (§2.2). |
| `lib/letflow/oidc/claim_mapping.ex` | **Unchanged** (§1.4) — listed in the issue's `affected_files` but this design finds no change needed there. |
| `test/letflow/identity_test.exs` | New/extended `describe` coverage (§3, T1-T3); `bind_role_to_group!/2` helper widens to take an explicit `kind` parameter. |

## 6. Acceptance-criteria mapping (derived, per this task's own framing — the issue carries no separate AC list)

| Derived AC | Where satisfied |
|---|---|
| A real, explicit decision among (a)/(b)/(c)/(d), with rationale and rejected alternatives | §1 (decision), §1.2 ((b) rejected, including why the issue's own framing for it doesn't hold up), §1.3 ((c) rejected), §1.4 (`ClaimMapping` confirmed out of scope) |
| Fix must not break legitimate process-routing-role claim-driven group membership | §1.2 point 3 (no such flow exists today, so nothing is broken); §3 T1/T3 prove the one genuinely legitimate flow (`:platform_role`-kind OIDC sync, REQ-378) is unaffected |
| Regression test: a token claiming a role-name string matching an existing `tenant_role` of EACH kind, confirming actual `group_members` writes/non-writes | §3 T1 (platform-kind: writes), T2 (routing-kind: does not write), T3 (both in one claim list: only platform-kind writes) |
| `mix letflow.check` must pass | Not this design's own artefact to run (CODE-DESIGN-VALIDATOR/ELIXIR-DEV's territory) — this design introduces no construct (unbounded atom creation, raw SQL, missing `@spec`) the check is known to flag; acknowledged, not claimed as run. |
