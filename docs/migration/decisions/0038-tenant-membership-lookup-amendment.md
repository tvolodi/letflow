# 0038 — Amendment: narrow, admin-only exception to 0006 §3.3's cross-tenant-lookup foreclosure, for switcher membership listing only

Status: decided and ratified (2026-09-22). Drafted by `CODE-DESIGNER`
(REQ-384); both required gates now signed off — `SECURITY-REVIEWER`
RATIFIED (commit `2edf7ca6`) and `REVIEWER` RATIFIED (below).
Owner: `ORCH` (this record amends decision `0006` §3.3/§7 item 3 by reference;
implementation is scheduled by REQ-384's own design,
`lib/letflow/design/req384-tenant-switcher-cache-isolation.md`, not by this
record).

Amends: `0006-identity-tables-schema-per-tenant.md` §3.3 ("What D1
forecloses") and §7 item 3 ("Multi-tenant human identity — foreclosed by
§3.3, reopenable only by superseding this record").

## Why this record exists

REQ-384 (in-app tenant switcher) needs a way to answer "which other tenants
can this human act as" without a full re-authentication per tenant. The only
candidate mechanism available in this codebase — `Letflow.Identity`, having
no existing membership concept, per
`lib/letflow/design/req384-tenant-switcher-cache-isolation.md` §0 — is a new
table keyed on a cross-tenant identity string (normalized email), looked up
independent of which realm authenticated the current request.

`CODE-DESIGN-VALIDATOR` correctly flagged that this is not a clean miss of
0006 §3.3's foreclosure. §3.3's own text forecloses two things together, via
"e.g.": *"a future 'find my account by email across all tenants' login flow,
or a single human identity spanning multiple tenants without a per-tenant
row."* REQ-384's `GET /api/v1/me/memberships` (design §2.2), querying
`tenant_memberships` by `subject_key` (normalized email) across every
tenant, is a literal instance of the first example — a cross-tenant lookup
keyed by email, not by realm. The earlier draft of the design's §0 argued
this was compatible with 0006 by analogy to D3's global-table precedent;
that argument addressed *where the table lives* (public schema, real FK) but
not *what capability the lookup delivers* (exactly the foreclosed
capability), and does not survive a re-read of §3.3's actual text. This
record does not repeat that argument.

## What this record does

**Amends 0006 §3.3/§7 item 3 with one narrow, explicitly-bounded exception**,
read alongside that text rather than replacing it: a cross-tenant,
email-keyed lookup is permitted **if and only if every one of the following
holds**, all of which are structural properties of REQ-384's design, not
policy promises:

1. **The lookup is never self-service.** No request handler accepts a
   caller-supplied email and returns matching accounts (the shape §3.3
   explicitly names as foreclosed — "find my account by email"). REQ-384's
   `GET /me/memberships` (design §2.2 step 1) derives the lookup key from the
   **already-authenticated caller's own** user row in the **current request's
   own tenant schema** — never from a request parameter, never from another
   user's data. A caller cannot use this endpoint to discover any account but
   their own currently-authenticated one plus whatever the `tenant_memberships`
   table already links to that same email, and only that table's rows,
   populated only by step 2 below, are ever returned.
2. **The link is admin-granted, not automatic or self-registering.** The
   `tenant_memberships` row that makes two per-tenant accounts
   cross-referenceable is created only by explicit `PLATFORM_ADMIN` action
   (design §1.1), the same trust tier as `Letflow.Routers.Tenants`' existing
   six tenant-administration functions. Nothing in JIT provisioning,
   claim-mapping, or self-service signup ever writes this table. No human can
   grant themselves cross-tenant visibility by knowing another account's
   email; an administrator must have deliberately linked the two rows first.
3. **No shared or global `users` row is created.** Each tenant a human can
   switch to still requires its own independently-provisioned, per-tenant-
   schema `users` row — exactly D1's per-schema shape, untouched. This
   satisfies the second half of §3.3's own foreclosure text literally: "a
   single human identity spanning multiple tenants **without a per-tenant
   row**" is precisely what does *not* happen here — every tenant reachable
   through the switcher has its own per-tenant row, reached via that tenant's
   own realm and its own JIT provisioning, exactly as D1 requires today.
   `tenant_memberships` never becomes an identity record itself — it has no
   password, role, or session fields; it is purely an admin-authored pointer
   between two otherwise-unrelated per-tenant rows.
4. **The realm-resolution chain (0006 R5) is unchanged.** Which tenant a
   given *request* is authenticated against still resolves exclusively via
   `AuthPipeline`'s realm→tenant chain (0006 R5), never via
   `tenant_memberships`. The membership table only ever answers "what could
   this human switch to," never "who is this request from" — that answer
   stays exactly where 0006 put it.

**This is the entire exception.** It authorizes exactly the mechanism REQ-384
§1–§2 specifies (a `PLATFORM_ADMIN`-only-writable, per-tenant-row-preserving,
non-self-service, realm-resolution-uninvolved link table) and nothing wider.
A future requirement proposing self-service cross-tenant lookup, a
caller-suppliable email parameter, or any mechanism that lets one `users` row
stand in for more than one tenant is **still foreclosed** and still requires
its own decision-record work — this record does not reopen §3.3 generally.

## What remains foreclosed, unchanged

- A self-service "find my account(s) by email" flow reachable by an
  unauthenticated or arbitrarily-authenticated caller.
- Any mechanism letting a single `users` row serve more than one tenant
  schema, or letting `AuthPipeline`'s realm→tenant resolution consult
  anything other than `tenants.idp_realm_id`.
- A cross-tenant lookup keyed on anything the *caller* supplies at request
  time (as opposed to derived from their own already-authenticated identity).
- Automatic/JIT-created `tenant_memberships` rows — that table stays
  admin-write-only per point 2 above; a future requirement widening it (e.g.
  self-service membership requests subject to admin approval) needs its own
  decision-record treatment, not an inference from this one.

## Known residual risk, carried forward rather than re-litigated here

REQ-384's own design §10 OQ-1 already names the risk this amendment's point 1
does not eliminate: two unrelated humans who happen to share an email string
across two tenants' independently-provisioned `users` rows would be
switchable as "the same identity" if a `PLATFORM_ADMIN` ever linked them.
This amendment does not weaken or strengthen that risk — it is unchanged by
whether the lookup mechanism is 0006-compliant, since it is about
`subject_key`'s choice of value (email), not about who can query it. OQ-1
remains the correct place for `REVIEWER` to adjudicate whether that
tradeoff is acceptable for REQ-384's scope; this record only settles the
narrower question of whether the *lookup mechanism itself* reopens 0006.

## REVIEWER sign-off

**RATIFIED** (2026-09-22, `REVIEWER`, REQ-384/queue-task-744). Independent
judgment from a decision-record-consistency/architectural-integrity
standpoint, distinct from SECURITY-REVIEWER's INV-1..8 remit above — the
question here is whether this amendment quietly erodes 0006's broader intent,
not whether the mechanism is safe.

Read 0006 in full and this record's four conditions against it:

1. **The amendment is scoped to exactly the gap it names, not wider.** 0006
   §3.3 forecloses two things via one "e.g.": a caller-suppliable
   cross-tenant email lookup, and a single `users` row spanning tenants
   without a per-tenant row. This record only reopens the first, and even
   that only for the narrow, structurally-bounded shape point 1 describes
   (derived exclusively from the caller's own already-authenticated
   identity, never a request parameter). The second foreclosure — no shared
   `users` row — is not merely left alone, it is restated as a condition
   (point 3) and is satisfied by construction: `tenant_memberships` carries
   no password/role/session field, every tenant a human reaches still gets
   its own independently-provisioned per-schema `users` row via its own
   realm's JIT provisioning. D1 (0006's actual per-schema `users` shape) is
   untouched by this record or by the shipped code.
2. **R5's bijection is not reopened.** 0006's central technical result — that
   realm→tenant resolution is a verified 1:1 bijection and is the sole
   mechanism that decides which tenant a *request* is authenticated against
   — is condition 4, restated rather than assumed, and is true of the
   shipped code: `tenant_memberships` has no read path in `AuthPipeline`, and
   `me.ex`'s handler runs strictly after normal tenant resolution. A
   membership row answers "what could this human switch to," never "who is
   this request from." 0006 §3's entire load-bearing argument (R5's
   bijection backing the `users_external_identity_partial_index` relocation)
   stays exactly as true after this amendment as before it.
3. **D3's tier is used correctly, and the record is honest about not
   over-claiming it.** `tenant_memberships` is public-schema, real-FK-to-
   `tenants`, same tier as `tenant_schemas`/`solution_pack_installs` — a
   correct application of D3's precedent for *where the table lives*. The
   record explicitly declines to let that fact alone carry the argument (see
   "Why this record exists," which retracts the earlier draft's D3-by-
   analogy reasoning) and instead argues the capability question on its own
   terms. That is the right call — D3 justifies schema placement, not lookup
   semantics, and conflating the two is exactly the mistake
   CODE-DESIGN-VALIDATOR caught in the earlier draft.
4. **The admin-write-only gate is a real, not cosmetic, boundary.** Point 2's
   claim — that nothing in JIT/claim-mapping ever writes this table — holds
   both as a design constraint (§1.1: "nothing in the JIT-provisioning or
   claim-mapping pipeline writes it") and, independently verified against
   the shipped diff, as a structural fact: `auth_pipeline.ex` does not
   appear in this diff at all, and `TenantMembership` exposes only
   `create_changeset/2`, mirroring `GroupMember`'s existing insert-or-delete
   convention rather than inventing a new one. No write route ships with
   REQ-384 (OQ-2, correctly deferred rather than silently built).
5. **Scope of the exception matches Letflow's own stated remit for decision
   amendments.** This is a narrow, four-condition carve-out written as an
   amendment to 0006 rather than a silent divergence or a fresh, competing
   decision record — the correct move per this project's "don't silently
   re-decide what a decision record already settled" rule
   (`CLAUDE.md`). §3.3's foreclosure list and §7 item 3 are both updated by
   reference, not deleted or reinterpreted, and the "what remains foreclosed"
   section preserves everything this amendment does not touch (self-service
   lookup, caller-suppliable keys, JIT-created memberships, any relaxation
   of realm→tenant resolution).

**Conclusion: 0038 is a sound, narrowly-scoped amendment.** It resolves the
one specific gap between REQ-384's requirement and 0006's text without
loosening any of 0006's structural guarantees (per-schema `users`, R5's
bijection, admin-only trust tier for platform-wide tables). OQ-1's residual
risk (two humans sharing an email string across tenants could be linked by an
admin) is a policy/product-scope question for REQ-384's own acceptance, not a
0006-consistency defect, and the record correctly declines to resolve it
here rather than smuggling a policy judgment into a decision-record
amendment.

## SECURITY-REVIEWER sign-off

**RATIFIED** (2026-09-22, `SECURITY-REVIEWER`, commit `2edf7ca6`). Re-derived
all four conditions directly against the shipped code, not the design doc's
claims about it:

1. **Non-self-service, caller's-own-identity-only.** `lib/letflow/routers/me.ex`'s
   `handle_list_memberships/1` derives `user_id`/`home_tenant_id` exclusively
   from `conn.assigns.auth_context` (populated by `AuthPipeline` from the
   verified JWT) and `prefix` from `conn.assigns.scoped_opts`. The route
   accepts no query parameter, body, or path segment of any kind — there is
   no code path by which a caller can supply an email or another identity to
   look up. `Identity.get_user/2` is called with the caller's own
   `user_id`/`prefix`, never a caller-supplied value. Confirmed by reading
   the full handler; grepped for any `conn.params`/`conn.query_params` use in
   `me.ex` — none exists.
2. **Admin-write-only, no JIT/claim-mapping writes.** `grep -rn
   "tenant_memberships\|TenantMembership" lib/` shows exactly three files:
   the migration, the schema module (`create_changeset/2` only, no
   `update_changeset/2`, matching `GroupMember`'s insert-or-delete-only
   shape), and `identity.ex`'s `list_memberships_for_subject/1` (a read,
   `Repo.all`, no insert/update/delete). No router other than `me.ex` (a
   `GET`-only route) references it. `lib/letflow/plugs/auth_pipeline.ex` and
   `lib/letflow/identity.ex`'s JIT-provisioning functions
   (`provision_oidc_user/4`, `verify_realm_ownership/2`) are **not present in
   this diff at all** (confirmed via `git diff --stat`) — the claim-mapping
   pipeline is untouched, not merely claimed-untouched. No write path ships
   with this branch, matching the migration header's own statement.
3. **No shared `users` row.** `TenantMembership`'s schema
   (`lib/letflow/identity/tenant_membership.ex`) has no password, role, or
   session field — `id`, `subject_key`, `tenant_id` (FK), `display_label`,
   timestamps only. It is a pointer table, not an identity table. Decision
   0006 D1 (per-tenant-schema `users`) is unmodified by this diff.
4. **Realm→tenant resolution (0006 R5) untouched.** `auth_pipeline.ex` does
   not appear in the diff; `me.ex`'s handler runs after normal
   `AuthPipeline`/`TenantStatus` resolution (mounted via
   `forward("/me", to: Letflow.Routers.Me)` in `api_pipeline.ex`, alongside
   every other tenant-scoped sub-router, not specially exempted). Nothing in
   `tenant_memberships` or its query path participates in resolving which
   tenant a request is authenticated against.

All four conditions hold as **structural** properties of the shipped code,
not policy promises. INV-1 (business-data isolation: this table carries no
business data, only tenant metadata), INV-2 (field selection is server-side
— `me.ex`'s `home_tenant_json/1`/`membership_json/1` explicitly allowlist
four fields, `idp_realm_id` never touched), and INV-6 (this record plus
REQ-384's design constitute the required scoping proof) are satisfied. This
amendment authorizes exactly the narrow mechanism described and nothing
wider — the "what remains foreclosed" list above stays intact.

Full review detail (CANDIDATE-exclusion precedent check, frontend
cache-isolation mechanism review, INV-1..9 pass/fail table) recorded in this
run's SECURITY-REVIEWER handoff for REQ-384/queue-task-744.
