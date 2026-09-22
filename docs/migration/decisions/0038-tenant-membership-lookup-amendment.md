# 0038 — Amendment: narrow, admin-only exception to 0006 §3.3's cross-tenant-lookup foreclosure, for switcher membership listing only

Status: decided (2026-09-22, `CODE-DESIGNER`, REQ-384), pending `REVIEWER` and
`SECURITY-REVIEWER` sign-off (sections below left as explicit PENDING
placeholders — not filled in by `CODE-DESIGNER`).
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

PENDING.

## SECURITY-REVIEWER sign-off

PENDING — in particular, independently re-derive point 1 above (that
`GET /me/memberships` cannot be used to enumerate or discover another
human's accounts) against INV-1/INV-2/INV-6, the same three invariants
REQ-384's design §3 AC5 row already names.
