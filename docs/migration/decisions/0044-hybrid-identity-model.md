# 0044 -- Identity model: realm-per-tenant (O1), central realm with organisations (O2), or a two-tier hybrid (O3)

Status: PHASE 1 RATIFIED by the user (repo owner) on 2026-10-05; all later phases DEFERRED.
Phase 1 means REQ-435..444 as planned, directory + email-first login, realm-per-tenant (O1).
The shared tier / O3 beyond Phase 1, e-mail-domain routing, brokered company IdP and any O2
move are NOT decided: they are deferred until a real tenant needs them (trigger: an actual
customer requirement), at which point the Keycloak spikes S-1..S-18 are run and the remaining
questions are answered. See "Ratification record (2026-10-05)" below. Until a later phase is
ratified, nothing in sections 2.2/2.3 (beyond Phase 1) is a decision and no ratified record is
changed by it. The legal controller question (0042 OQ-3 / 0043 D-D) remains OPEN and still gates
enabling the feature flag outside dev.

Date: 2026-10-05. Drafted by `CODE-DESIGNER` (ADHOC-20261005-001, step 01). Owner: `ORCH`.

Amends / supersedes: nothing yet. If ratified, the "Consistency with existing decision records"
section (section 6) lists exactly which quoted passages of 0002, 0006, 0038, 0042 and 0043 would be amended or
superseded, and by which phase. This record never edits those files itself.

Decision requested of the user: (1) ratify or reject the RECOMMENDATION (O3, phased, with
Phase 1 = O1 as already planned), and (2) answer, or accept the stated defaults for, the
numbered questions in "Remaining questions for the user".

Conventions used below. A citation `path:N` or `path:N-M` was verified by reading that file in
the drafting worktree (branch `docs/ADR-hybrid-identity`, based on `origin/main`) on
2026-10-05. A statement about Keycloak that goes beyond the version pinned in the repository
is NOT asserted anywhere in this record; it appears only as a numbered spike question marked
UNVERIFIED. No web lookup of Keycloak documentation was performed for this draft, so no
statement here is "doc-claimed" either. "Step" means one requirement-sized unit of work, i.e.
one agent turn, in the sense of `docs/requirements.yaml`'s sizing rule.

---

## 1. Context

### 1.1 Today's model, with citations

- **One Keycloak host, one realm per tenant.** `docker-compose.yml:26` pins
  `quay.io/keycloak/keycloak:26.2` and `docker-compose.yml:27` starts it with `start-dev
  --import-realm`; `priv/keycloak/realms/bpm-default.json:3` is the single realm fixture in the
  repository. QA runs the same image (`ai-dala-infra/landscape/services.md:177`) with realms
  `bpm-default`, `bilimbaga`, `swiftroute`, `meridian`, `vortex` plus `master`
  (`ai-dala-infra/landscape/hosts/ubuntu-16gb-nbg1-1.md:203`).
- **`tenants.idp_realm_id` is a strict partial 1:1 binding.** Unique partial index
  `tenants_idp_realm_id_partial_index` (`priv/repo/migrations/20260816000001_create_tenants.exs:38`),
  a single scalar column (`lib/letflow/identity/tenant.ex:71`), immutable after creation
  (`tenant.ex:42-55`, `0006-identity-tables-schema-per-tenant.md:132-157`, "R5").
- **After login the tenant comes from the token's realm.** `Letflow.Plugs.AuthPipeline`
  runs verify token -> `extract_realm` -> `resolve_tenant` -> `guard_realm_ownership` ->
  `map_claims` -> `provision_user` -> `verify_local_account_state`
  (`lib/letflow/plugs/auth_pipeline.ex:124-133`); `resolve_tenant_by_realm/1` is a
  `Repo.get_by(Tenant, idp_realm_id: ...)` (`lib/letflow/identity.ex:150-151`). That call would
  raise on two matching rows; it is safe today only because the unique index forbids them.
- **Trust source for token verification is the `tenants` table, re-resolved on every call.**
  `0002-oidc-integration.md:168-175`; `lib/letflow/oidc/provider_registry.ex:21-27`.
  `config :letflow, :oidc, :client_id` is one value for all realms
  (`lib/letflow/oidc/token_verifier/oidcc.ex:147-156`), and each realm fixture carries a
  `letflow-web` client with an audience mapper (`bpm-default.json:22,48`).
- **Accounts are per tenant, in the tenant's own Postgres schema.** 0006 D1
  (`0006...md:30-33`). Authorisation is local data: effective roles are read per request from
  the tenant schema's group membership (`auth_pipeline.ex:343-361`,
  `lib/letflow/identity.ex:724`), and token role claims are only synced at JIT time
  (`identity.ex:763-768`). Claim mapping and JIT behaviour are configured per realm
  (`lib/letflow/oidc/claim_mapping_config.ex:53-75`,
  `lib/letflow/oidc/jit_provisioning_config.ex:4-11`).
- **Pre-login tenant selection is weak.** The SPA reads a stored slug first, then `?realm=`,
  else asks `GET /api/tenant-config?host=` which always answers the default realm because no
  host->tenant binding exists (`web/src/auth/tenantConfig.ts:29-47,49-62`;
  `lib/letflow/routers/tenant_config.ex:218-249`). `ProtectedRoute` immediately calls
  `signinRedirect` (`web/src/auth/ProtectedRoute.tsx:9-22`), so a user of a non-default tenant
  with no `?realm=` lands on the wrong realm (ISS-0727, cited in 0042 Context).
- **Cross-tenant people are handled by an admin-linked switcher.** `tenant_memberships`
  (`priv/repo/migrations/20260922000011_create_tenant_memberships.exs:28,34`) and
  `GET /api/v1/me/memberships` (0038; `lib/letflow/routers/me.ex`). Switching to another
  realm needs a silent-login that the code itself says only works "if tenant realms share SSO
  via a federated upstream IdP" (`web/src/auth/tenantOidcRegistry.ts:34-36`); otherwise the
  user is asked to sign in again.
- **The current plan is the email-first directory (O1).** Decision 0042 (ratified) and 0043 (BA-decided by delegation; REVIEWER and SECURITY-REVIEWER gates still owed)
  (BA decisions D-A..D-H), requirements REQ-434..REQ-444. State in `docs/requirements.yaml`
  today: REQ-434, REQ-436, REQ-439 `done`; REQ-435, 437, 438, 440, 441, 442, 443, 444
  `pending`. In the tree: `lib/letflow/plugs/client_ip.ex` and
  `lib/letflow/plugs/login_discovery_rate_limit.ex` (+ `login_discovery_rate_limit/`) exist;
  there is no `tenant_login_directory` migration and no `Letflow.Routers.LoginDiscovery`
  (`router.ex:111-135` mounts `/api/tenant-config`, `/api/mobile/tenant-config`, `/api/public`
  and `/api/v1` only). Open PR #2201 (`feat/REQ-435-login-directory`, state OPEN, merge state
  CLEAN, title "MERGE HELD: pepper provisioning", last updated 2026-10-04) implements the whole
  former REQ-435 including the write hooks, on a single pepper.

### 1.2 The problem being solved

1. **Pre-login tenant discovery** for people who do not know their realm (O1's original
   motivation, 0042 Context).
2. **People in several tenants.** Today each tenant is a separate account in a separate
   realm; the switcher helps only after an admin links accounts and re-authenticates on
   switch.
3. **Enterprise SSO.** A customer who wants its own corporate IdP (SAML/OIDC) has no
   designed path; 0042 Decision 7 fences brokering out of the email-first series.
4. **Operational weight of one realm per tenant.** A new realm has to be hand-provisioned by
   someone with Keycloak admin access (`docs/anti-patterns.md:3008-3016`; the QA lesson list
   at `ai-dala-infra/shared/app-registry.md:250`), and Letflow has no Keycloak Admin client
   (0042 Alternative 10).
5. **Mobile.** The Flutter tier resolves a tenant by deep-link subdomain or manual slug and
   then does OIDC against that tenant's realm (`docs/mobile/requirements.md:55-72`,
   `0012-mobile-tier-stack.md:23`).

### 1.3 What the user agreed

The user agreed to EXPLORE a hybrid, in their words "for the complex case a complex solution,
for the simple case a simple one". This record therefore compares three options and
recommends a path; it does not pre-empt the spikes that decide whether the simple tier is
technically feasible on Keycloak 26.2.

### 1.4 Scope of this record

In scope: the identity architecture options, the effect on ratified decisions and on
REQ-434..444, a phased plan, PR #2201, and the questions only the user can answer. Out of
scope: any implementation, any edit of `docs/requirements.yaml` (ORCH adds the hold marker),
any edit of the ratified records, any Keycloak configuration.

---

## 2. The three options

Common vocabulary. "Dedicated" = a tenant has its own Keycloak realm (today's model). "Shared"
= a tenant's users authenticate in a platform-wide central realm and belong to the tenant as
organisation members. "Selector" = whatever tells the server which tenant a request is for
when the realm alone cannot.

### 2.1 O1 -- Realm per tenant + platform directory + email-first login (REQ-434..444 as planned)

**Description.** Keep realm-per-tenant, R5, per-tenant `users` (0006 D1) and the realm->tenant
chain exactly as they are. Add a public-schema pointer table `tenant_login_directory`
(`email_key` = keyed HMAC of the normalised email, `tenant_id`, `key_id`), an unauthenticated
`POST /api/login-discovery` with a rate limiter and two disclosure modes, an email-first SPA
page, a notifier port with an SMTP adapter, and an enablement gate (0042, 0043).

**Login, step by step.**
1. SPA starts unauthenticated; rank order is `?realm=`, stored slug, email-first page (flag
   on), default-realm fallback (0042 Decision 6; design section 11.1).
2. User types an email; SPA POSTs it to `/api/login-discovery`.
3. Server normalises, computes the HMAC (pepper by reference), runs ONE query joining the
   directory to `tenants` (active, realm bound), and answers per disclosure rule: exactly one
   disclosed match -> 200 `{slug, display_name}`; everything else -> the same 202 neutral body,
   with the tenant list e-mailed off the request path.
4. SPA stores the slug, fetches `GET /api/tenant-config?realm=<slug>`, calls `signinRedirect`
   with `login_hint`.
5. Keycloak hosted login for that tenant's realm; token comes back; `AuthPipeline` resolves the
   tenant from the realm as today.

**User in several tenants.** Mode B: several matches -> neutral 202 and an e-mailed list (REQ-441
adapter required, otherwise the multi-tenant user hits a dead end that the organisation-code
control only softens: 0042 OQ-9). Post-login: admin-linked `tenant_memberships` switcher.
Each tenant remains a separate account and, on switching to another realm, a separate login.

**Enumeration / privacy posture.** Bounded and already analysed in depth (0042 "Accepted
bounded inference"): single-match disclosure of `slug` and `display_name` in Mode B, none in
Mode A or in a per-tenant uniform tenant (0043 D-A); per-IP, global and per-email limiter;
HMAC key instead of plaintext; legal basis still OPEN (0042 OQ-3, 0043 D-D).

**Security-invariant impact.** INV-1: directory outside tenant schemas, backfill reads tenant
schemas through the derived prefix only. INV-2: closed response allowlist. INV-3: not
applicable. INV-4: pepper and SMTP credentials by environment reference; no raw email in logs
(`log: false`). INV-5: first email-keyed instance; equivalence classes defined in design
section 10. INV-6: each new path proves scoping (0042 design). INV-7: no interpolated SQL in
backfill. INV-8: notifier/mail/DB failure returns the neutral response. INV-9: no
tenant-controlled outbound URL is requested by Letflow in Phase 1, and the notifier carries
no tenant-derived URL (0042 Standing prohibition 12) (INV-9 text:
`security-invariants.md:332-382`).

**Migration from today.** None for users. Tables and code are additive; the feature is off
outside dev until OQ-3 is answered (0043 D-D, REQ-444).

**Cost in steps.** 8 pending requirements (REQ-435, 437, 438, 440, 441, 442, 443, 444; REQ-440
may close by verification of PR #2201), plus roughly 2 follow-on steps (UAT check that each
realm has "Login with email" enabled, 0042 OQ-8; realm-config checklist) = about 10 steps.
Three requirements are already done (REQ-434, 436, 439).

**Operational cost.** Unchanged shape: N realms for N dedicated tenants (QA: 5 plus `master`),
one `letflow-web` client, role set and two protocol mappers per realm (`bpm-default.json:20-110`
shows the per-realm pattern), per-realm backups and manual provisioning. New: a pepper per
environment with rotation runbook (REQ-443), SMTP relay and credentials, the QA/prod nginx
realip change (REQ-439). Realm count vs Keycloak memory: UNVERIFIED (spike S-12); the QA host
is a CX43 with 8 vCPU and about 15 GiB RAM and no swap
(`hosts/ubuntu-16gb-nbg1-1.md:31-32`), and no Keycloak memory limit is recorded in this
repository or in the landscape documents read.

**Tenant-admin autonomy.** Full inside the realm if the platform operator hands a realm admin
to the tenant, none by default; Letflow itself exposes no realm administration.

**Enterprise SSO per tenant.** Intended, subject to spikes S-8..S-10 (UNVERIFIED): a corporate
IdP brokered inside that tenant's realm. Not designed: 0042 Alternative 11 states no realm
brokers an IdP today, and whether Keycloak 26.2 supports it as needed is not verified here.

**Data separation.** Maximal: separate Keycloak account store per tenant (a realm) AND
separate Postgres schema per tenant (0006 D1). A realm-level compromise or misconfiguration
affects one tenant.

**Mobile impact.** None. Slug entry or deep link -> `GET /api/mobile/tenant-config` -> OIDC
against that realm (`docs/mobile/requirements.md:55-72`). A later requirement could adopt the
unauthenticated discovery endpoint in place of manual slug entry (design section 14).

### 2.2 O2 -- GitHub/Google model: one central login realm, tenants as organisations

**Description.** One central realm holds every human's single account. A tenant is an
"organisation" a person is a member of. Two realisations exist and BOTH are spike questions,
neither is asserted: (a) Keycloak Organizations inside one realm of the pinned 26.2 (spike
S-1..S-7); (b) a Letflow-owned central identity service in front of Keycloak (not costed in
detail; strictly more build). Tenants are chosen after login (a picker) or by URL
(path or subdomain). To keep INV-1 intact this record assumes O2 would KEEP a per-tenant
`users` row in each tenant schema as the authorisation record (see below), because replacing
0006 D1 with a central `users` table would touch every table that references a user.

**Login, step by step (assumed realisation (a)).**
1. SPA goes to the central realm login (or to `/t/<slug>` / `<slug>.host` which carries the
   selector).
2. Single Keycloak login; token issued by the central realm; `iss` realm is the same for all
   tenants.
3. Server cannot derive the tenant from the realm any more. It needs a selector (see "What
   the caller cannot choose" below) validated against local membership data.
4. If no selector, SPA shows a picker built from the caller's own memberships (authenticated,
   so no enumeration problem).

**User in several tenants.** Assumed native (UNVERIFIED, spike S-2): one account, N memberships; switching is a selector
change with the same token, no re-login. This replaces the admin-linked `tenant_memberships`
(0038) with authoritative memberships.

**Enumeration / privacy posture.** Best of the three for discovery: there is no pre-login
"which tenant is this email in" question for shared users, hence no directory and no oracle.
What remains: the login page's own behaviour (Keycloak's, spike S-6) and any email-domain
routing to an enterprise IdP, which reveals "this domain has SSO" (domain-level, not
person-level).

**Security-invariant impact.**
- INV-1: scoping must now be derived from authenticated identity plus a membership check, not
  from the realm. New scoping proof required (INV-6). The tenant schema prefix still comes
  only from a validated tenant id.
- INV-2: unchanged mechanics; but token-carried role names are realm-wide, so they cannot be
  per tenant; Letflow already ignores them for live authorisation (it reads local groups per
  request, `auth_pipeline.ex:343-361`) but still syncs them at JIT (`identity.ex:763-768`);
  the sync must be disabled for shared realms.
- INV-3: not applicable.
- INV-4: a new Keycloak Admin client (tenant/org/user provisioning) is a new standing secret
  with realm-wide power; today none exists in `lib/` (0042 Alternative 10).
- INV-5: a caller-chosen selector for a tenant they do not belong to must be byte-identical to
  a non-existent tenant, with comparable DB round trips (INV-5 text:
  `security-invariants.md:176-206`). New equivalence class, new tests.
- INV-6: mandatory for the selector path.
- INV-7, INV-8: unchanged discipline; the new lookup is normal Ecto.
- INV-9: tenant-admin-supplied IdP metadata URLs (enterprise SSO) are fetched by Keycloak, not
  by Letflow, so INV-9 as written (Letflow outbound requests) does not bind that fetch; if a
  future Letflow admin client forwards tenant-supplied URLs to Keycloak, Letflow becomes a
  confused deputy and INV-9-style validation is needed there (risk R-6).

**What the caller can NOT choose (the authorisation core).** The tenant id and schema prefix
are never taken from a request value. The server accepts a selector (a header or path
segment carrying a tenant slug) only as a hint that can narrow, never widen: it resolves
the slug to a tenant, then requires an ACTIVE `users` row in that tenant's schema for the
token's `(shared realm, sub)` pair. Roles come from that tenant's local groups, never from
token claims. An organisation claim (spike S-3) is only a cross-check, never the authority;
the mismatch rule is stated once in 2.3.5 item 5. JIT creation of a `users` row on selector alone MUST NOT
exist: with it, any holder of a shared-realm account could name any shared tenant's slug and
be provisioned into it. Rows are created only by invitation acceptance (an admin creates invitations, not rows)
(see O3 section 2.3.4).

**Migration from today.** Heavy and partly irreversible. Existing users live in N realms.
Moving them needs either per-user password reset or a realm-to-realm import that carries
credentials (spike S-13); either way each user's `sub` changes, so every existing `users` row
keyed `(external_realm, external_id)` (0006 section 3.2) would no longer match on next login
and JIT (if allowed) would create a second row, orphaning task assignments and history. A
re-link tool (match by email, rewrite `external_realm`/`external_id`) is required, and email
is not unique per tenant (`users.email` has no unique index, 0042 design section 3.6), so
the match can be ambiguous. Realm-per-tenant tenants also lose any realm-local policy.

**Cost in steps.** Roughly 25 to 35: spikes (4), ADR/design (3), trust-source and
AuthPipeline change (3), selector plug and membership authorisation (4), per-tenant claim and
JIT configuration (2), Keycloak Admin client (3), organisation lifecycle on tenant create
(3), SPA tenant picker, URL scheme and flags (4), user migration tooling and runbook (3),
mobile (2), tenant-admin UI for invitations (2). This is an estimate with wide error bars; it
cannot be tightened before the spikes.

**Operational cost.** One realm, one client, one set of mappers, one backup unit, one set of
realm-level settings (password policy, MFA, brute-force protection) for ALL shared tenants.
Realm count and per-organisation memory cost: UNVERIFIED (S-12). A single realm outage or
misconfiguration affects every tenant at once (blast radius up).

**Tenant-admin autonomy.** Low: realm-level policy is platform-wide. Whether a tenant admin
can manage ONLY their organisation's members through Keycloak's admin API and permission model:
UNVERIFIED (S-5). Alternative: tenant admins never touch Keycloak and use Letflow-side
invitations only.

**Enterprise SSO per tenant.** Depends entirely on whether an organisation can be linked to an
external IdP and routed by email domain (S-4, S-8, S-9). If it works it is simple; if not, O2
cannot serve enterprise SSO at all and would have to keep realm-per-tenant for those tenants
(i.e. become O3).

**Data separation.** Weaker at the identity layer: all accounts in one realm. Business data
separation (Postgres schema per tenant, 0006 D1) is unchanged IF per-tenant `users` rows are
kept; if a central `users` table were chosen instead, 0006 D1 would be superseded for users,
groups and `tenant_role` and the FK graph would need rework. This record assumes the former.

**Mobile impact.** Medium. `flutter_appauth` Auth-Code + PKCE (`0012...md:23`) is unchanged,
but `docs/mobile/requirements.md:208-211` ("The token audience MUST be scoped to the tenant
realm") cannot hold for shared tenants (the audience is one client for all shared tenants,
`oidcc.ex:147-156`); the tenant selector must be carried by the app on every API call; the
tenant-config response (`requirements.md:63-72`) would need a shared-tier variant. Needs a
mobile requirement revision before any mobile work on shared tenants.

### 2.3 O3 -- Hybrid with tiers: 'shared' and 'dedicated', one entry point

**Description.** Each tenant declares an auth mode. `dedicated` (default, today's model): own
realm, optionally a brokered company IdP/SAML inside that realm (intended, subject to spikes
S-8..S-10, UNVERIFIED). `shared` (simple tenants,
e.g. candidate-facing): users live in ONE central realm and belong to the tenant as
organisation members. One entry point routes a person to the right place by (in order)
invitation, explicit URL/slug, stored slug, e-mail directory, e-mail domain, default. The O1
directory is the router.

#### 2.3.1 Login, step by step

1. Entry: `/login` (the credential-free discovery page, already authorised by 0042 for the
   email-first screen). An invitation link or a `?realm=`/subdomain skips straight to step 4.
2. E-mail typed -> `POST /api/login-discovery` (contract unchanged in Phases 1-3: 200 `{slug,
   display_name}` or neutral 202; per-tenant disclosure per 0043 D-A).
3. Directory lookup is unchanged in Phases 1-3: it returns tenants, with no knowledge of
   tier. (Phase 4 domain routing changes the query, see 2.3.2 item 3.)
4. SPA calls `GET /api/tenant-config?realm=<slug>` (already pre-authentication and already a
   bounded inference). For a `dedicated` tenant it returns that tenant's realm authority (as
   today). For a `shared` tenant it would return the central realm's authority and the tenant
   slug to send as selector. The tier therefore reaches the browser through tenant-config, NOT
   through a new field in the discovery response, so 0042 Standing prohibition 4 and 11 (closed
   discovery allowlist) are not touched.
5. `signinRedirect` with `login_hint`; hosted Keycloak login (0035 intact).
6. Server: `AuthPipeline` verifies the token against a trusted realm; if the realm is a
   `dedicated` tenant's realm the chain is unchanged; if it is the shared realm the tenant is
   chosen by selector + local membership (section 2.3.5).

#### 2.3.2 How the O1 directory is reused as the ROUTER

What survives unchanged: the table and its data (email_key, tenant_id, key_id), the pepper,
dual-read rotation, the population hooks (a `shared` tenant still has a per-tenant `users`
row, created by invitation acceptance rather than JIT; the same hook and removal rule
apply to that new invitation writer, added by a new requirement, since REQ-440's four
function hooks do not cover it), the lookup query and its closed
response, the disclosure modes and per-tenant flag, the limiter, `ClientIp`, the notifier
port and SMTP adapter, the enablement gate and the SPA discovery page.

What changes:
1. `tenants` gains an `auth_mode` column (`dedicated` default, `shared`), read in the existing
   single join; no extra query. The discovery response does not change (see 2.3.1 step 4).
2. `GET /api/tenant-config?realm=<slug>` learns to answer for a shared tenant (central
   authority + selector). `resolve_realm` (`tenant_config.ex:230-239`) currently requires a
   non-null `idp_realm_id` to win; shared tenants have `idp_realm_id` NULL, so this function
   needs a second branch.
3. A new routing source (Phase 4 only) for people who are NOT in the directory yet (invited
   but never logged in; enterprise SSO users who have never been JIT-provisioned): a
   `tenant_login_domains` table (verified e-mail domain -> tenant). It also closes the
   Keycloak-only-account gap of 0043 D-E. It is NOT a "second lookup on the miss path": that
   would break 0042 Standing prohibition 7 (one database round trip, no second query) and
   create a timing signal between "known" and "unknown at a routed domain". Phase 4 MUST
   take one of two forms: (a) ONE joined query (directory plus domain table) with constant
   work on every path, whose domain-routed results are answered ONLY through the existing
   mode and per-tenant uniform rules, i.e. never a 200 in Mode A or for a uniform tenant, so
   a routed domain behaves like a directory match for that tenant and nothing new is
   disclosed to uniform tenants; or (b) give nothing tenant-specific at the discovery step
   and route by domain elsewhere (Keycloak-side, S-4). Either way this AMENDS 0042 Standing
   prohibitions 6, 7 and 11 (6.5) and needs SECURITY-REVIEWER sign-off in its own
   requirement. Residual oracle, named: in form (a) with a disclosing tenant, any local part
   at a routed domain yields the 200 `{slug, display_name}` whether or not that mailbox
   exists, so the endpoint reveals "this domain is routed to tenant X" (domain-level), and a
   routed vs unrouted domain differ in 200 vs 202. A person-level inference remains: if the
   mailbox is ALSO in another tenant it becomes a multi-match and gets the 202, so 200 vs 202
   at a routed domain tells a prober that mailbox is single-tenant. Further, for uniform
   tenants a list could be e-mailed to nonexistent mailboxes at the routed domain (a
   sending side effect, bounded by the per-address send bucket). The joined query must
   DEDUPE by tenant so a person present in both the directory and the domain table counts as
   one match.
4. An invitation entry (`/invite`, token in the URL fragment, 2.3.8 item 4) as a second credential-free route resolved
   by an opaque token; it carries tenant and tier, so no e-mail lookup is needed. 0028's
   handle model is only a LOOSE analogy (0028 governs unauthenticated reads; an invitation
   token is a bearer capability that MUTATES membership). Its constraints are in 2.3.8.
5. The in-app switcher (0038) keeps working for dedicated-to-dedicated hops; shared-to-shared
   hops become a selector change with the same token (no re-login).

#### 2.3.3 A person with accounts in both tiers

Alice is a member of tenant A (shared, central realm account `a@x`) and of tenant B
(dedicated, realm-B account `a@x`). She has two Keycloak accounts and two authentications; this
record does NOT unify them (cross-realm SSO or a single identity spanning realms stays out of
scope, 0042 Decision 7 and 0042 design item (k)).
- Discovery by `a@x`: two directory rows (A, B) -> multi-match -> neutral 202 plus an e-mailed
  list (Mode B), or 202 plus list in Mode A/uniform. The e-mail contains both tenants' slugs
  and display names as plain text (REQ-441 message contract). Single-match behaviour for a
  person with one tenant is unchanged.
- Post-login: the memberships switcher lists both only if a `PLATFORM_ADMIN` linked them
  (0038). Switching A->B is a re-login at realm B; B->A with a live central session can be
  silent only if the shared realm's SSO session exists (spike S-6).
- Failure mode to design against: the same e-mail in two tiers is ordinary, so nothing may
  assume e-mail uniqueness across tiers (0042 OQ-11, 0038 OQ-1).

#### 2.3.4 What the central realm's identity means for 0006 D1, R5, 0038

- **0006 D1 (per-tenant users): kept.** A shared tenant still has its own `users` row per
  member in its own schema; the central realm identity is authentication only. This is the
  shape 0038 describes ("every tenant reachable ... has its own per-tenant row",
  `0038...md:65-75`). 0038 condition 3 speaks of rows created via each tenant's own realm
  and JIT, whereas shared rows are created by invitation in a common realm: 0038 forbids
  nothing here but did not allow it either.
- **0006 R5 (realm<->tenant bijection): kept for dedicated tenants, narrowed for shared ones.**
  Shared tenants carry `idp_realm_id` NULL, so `tenants_idp_realm_id_partial_index` and
  `Tenant.update_changeset/2` are untouched. What changes is R5's parenthetical "nullable only
  when OIDC is off" (`0006...md:150-152`) and the sentence that `AuthPipeline` resolves the
  tenant from the realm (`0006...md:152-157`): for the shared realm the tenant is resolved by
  selector + membership. A new platform-level binding is required for the shared realm
  itself (a table such as `shared_identity_realms`, so the trust source stays a database
  row that can be revoked immediately, in the spirit of `0002...md:168-175`). Two rules bind
  it: (i) **disjointness** -- no realm may be both a `shared_identity_realms` row and some
  tenant's `tenants.idp_realm_id` (the unique index on `tenants` alone cannot prevent it);
  enforced in `Tenant.create_changeset`, in shared-realm creation, and by a DB trigger or at
  minimum a boot assertion; otherwise every shared-realm token would authenticate into that
  dedicated tenant through the unchanged chain (`auth_pipeline.ex:126-133`); (ii) **realm
  kind decided once**: the dedicated-vs-shared decision is made a single time, BEFORE
  `resolve_tenant`, from the revocable database row, and the two branches never share state
  (a shared-realm token can never satisfy a dedicated tenant's chain; see S-11).
- **0006 section 3.2 argument weakens.** Its safety claim, that two tenant schemas can never
  hold the same `(external_realm, external_id)` because R5 forbids a realm bound to two
  tenants (`0006...md:188-195`), is false BY DESIGN for the shared realm: one `sub` legitimately
  appears in several tenant schemas. The replacement guarantee is "a row exists in schema T
  only if an accepted invitation created it" (an admin creates invitations, never rows
  directly). This is a DOWNGRADE: the guarantee
  replaced was a database constraint (`tenants_idp_realm_id_partial_index`,
  `0006...md:138-141`); the replacement is an application invariant. It therefore must be made
  structural: (a) exactly ONE dedicated writer creates shared-realm `users` rows (invitation
  acceptance), a function distinct from `provision_oidc_user/4` (`identity.ex:127`, the JIT
  insert), which must not be reused for it; (b) every other `users` writer
  (`provision_oidc_user/4`, `create_user/2`, `update_user_profile/3`) refuses an
  `external_realm` that is a shared realm, with a typed error; (c) a DB backstop where
  feasible (a trigger or CHECK against `shared_identity_realms`, or an invitation reference
  NOT NULL on shared rows); if none is feasible, Phase 2 must say so explicitly. The Phase 5
  re-link tool (moving an existing tenant) is a SEPARATE writer: explicitly user-authorised,
  bound to `sub` (the old and new `(realm, sub)` pair supplied by a verified mapping), and it
  must never match users by e-mail (`users.email` is not unique, 0042 design section 3.6). JIT is thus
  off for the shared realm by construction (2.3.5 item 4a), not by configuration. 0006
  section 8 itself names this claim as the one SECURITY-REVIEWER must re-derive
  (`0006...md:304-306`); it must be re-derived again in Phase 2.
- **0006 section 3.3 / 7.3 (multi-tenant human identity): this is the real supersession.**
  0038 and 0042 each amended only the lookup half and left "no single human identity spanning
  multiple tenants" untouched (`0042...md:160-165`). A shared-tier account IS one
  authentication identity spanning tenants (with per-tenant rows). Ratification of the shared
  tier therefore requires superseding 0006 section 7 item 3 ("reopenable only by superseding
  this record", `0006...md:296-297`) and 0042's "What remains unchanged" paragraph, for the
  shared tier only.
- **0038.** `tenant_memberships` stays what it is (admin-linked cross-tenant switch targets).
  Shared-tier membership is NOT stored there: 0038 forbids automatic or JIT-created rows in
  that table (`0038...md:100-103`). The authoritative shared-tier membership is the per-tenant
  `users` row plus its invitation record. 0038 point 4 ("realm-resolution chain unchanged",
  `0038...md:76-81`) is amended for the shared realm.

#### 2.3.5 How tenant_id and roles stay derived in a shared realm (INV-1 style)

Summary of the rule O3 would adopt (also the O2 rule):
1. Identity: the verified token's `(iss realm, sub)`.
2. Tenant: the selector slug (header or path segment) resolved server-side to a tenant id.
   The caller can only choose among slugs; the prefix is derived by
   `TenantProvisioning.schema_name_for_tenant/1` from the resolved id, never supplied.
3. Authorisation to be in that tenant: an ACTIVE `users` row with that `(external_realm,
   external_id)` in that tenant's schema. **Ordering is fixed: slug -> membership ->
   status.** Membership is decided first; tenant status (`:inactive`/`:migrating`, today's
   `TenantStatus` 403) is evaluated only for a caller who IS a member. If status were checked
   first, a non-member would see 403 for an inactive tenant and 404 for a non-existent one,
   an existence oracle. A member seeing their own inactive tenant is acceptable; it must not
   reveal other tenants.
   - **Collapsed response.** Unknown slug, non-member and not-invited produce ONE status and
     ONE body, byte-identical (INV-5, `security-invariants.md:199-204`). Today's pipeline
     emits distinguishable bodies (401 "token realm does not match tenant", 403 "JIT
     provisioning disabled for this realm", 403 account inactive,
     `auth_pipeline.ex:152-191`); the selector path must not reuse those for these cases.
   - **Uniform cost.** A non-existent slug costs zero tenant-schema queries while a real
     tenant costs a `users` lookup, so parity needs a deliberate DECOY query: for an unknown
     slug the server runs the same-shaped lookup against a fixed decoy target, so the
     number of database round trips is the same on every path. The decoy is a REAL
     tenant-schema `users` lookup, using the same index and cost, against a fixed, existing
     tenant schema (never a no-op, a sleep or a cached answer). Phase 2 tests assert equal
     round trips and equal bytes.
4. Roles: `list_effective_role_names` from that tenant's local groups
   (`auth_pipeline.ex:353-361`). Token role claims are ignored for shared realms.
   - **4a. The shared-realm branch is STRUCTURAL.** It is selected by the
     `shared_identity_realms` row, and that branch never calls `provision_oidc_user/4` or
     `sync_role_claims_from_token/3` (`identity.ex:763-768`; also run at `identity.ex:1752-1756,
     1805, 1865-1867`, including for existing rows with a nil marker, where realm-wide shared
     roles in the token could otherwise be copied into every tenant where the user has a row).
   - **4b. Unconfigured realm becomes DENY.** Today the fallback FAILS OPEN:
     `JitProvisioningConfig.for_realm/1` returns `default/1` for any realm absent from
     `config :letflow, :oidc_jit_provisioning`, and `default/1` is `enabled: true,
     default_status: :active, default_roles: []`
     (`lib/letflow/oidc/jit_provisioning_config.ex:43-59,72-80`); `ClaimMappingConfig.for_realm/1`
     has the same absent-realm fallback (`claim_mapping_config.ex:53-75`). A shared realm
     missing from those maps, or mistyped, would be JIT-on. The fallback for an unconfigured
     realm must become a typed deny. **Ordering matters:** the dedicated realms rely on the
     fail-open default today. `config/prod.exs:32-38`, `config/dev.exs:137-143` and
     `config/test.exs:171-176` list only `"bpm-default"` (test.exs adds test realms), while QA
     also serves `bilimbaga`, `swiftroute`, `meridian`, `vortex`
     (`hosts/ubuntu-16gb-nbg1-1.md:203`), which JIT through the default. So Phase 2 must FIRST
     add an explicit entry for every existing dedicated realm, with a boot-time check that
     every `tenants.idp_realm_id` has one, and only THEN flip the fallback to deny; the
     acceptable alternative is to scope the deny to shared realms only (the realm-kind row
     of 2.3.4) and leave the dedicated fallback unchanged. **Phase 2 acceptance property, with
     a test:** a shared realm absent from every config map still cannot create a `users` row.
5. Cannot be chosen by the caller: tenant id, schema prefix, roles, status, `users` row id,
   and anything about a tenant they have no row in.
   - **Organisation claim rule (stated once, used by 2.2 and here).** A token claim naming
     organisations, if Keycloak provides one (S-3), is a cross-check, never the authority.
     A claim listing all of a user's memberships can legitimately differ from the selector,
     so a mismatch is not by itself a refusal: the request is refused only when the claim
     is present as a per-organisation token (S-3 "scoped to ONE organisation") and names a
     different organisation than the selector. Authority remains the local `users` row.
6. Revocation bound. Letflow-side deactivation is immediate per request (`users.status` read
   live, `auth_pipeline.ex:353-363`). ASSUMED, UNVERIFIED (S-17, S-14): a Keycloak-side
   disable, or a changed `sub`, does not revoke already-issued access tokens, so the bound
   would be the access-token lifetime (value also UNVERIFIED, recorded by the Phase 0 spike). Central account deletion leaves
   local rows keyed to a dead `sub`; Phase 3 therefore requires an **offboarding
   procedure** that fans central disable/deletion out to the local `users` rows (set
   inactive, then purge per policy) and records it in the per-tenant audit trail. Any purge
   that deletes `users` rows is bound by 0042 Standing prohibition 14: it calls
   `remove_entry_if_unreferenced/3` in the same transaction, with a test.

#### 2.3.6 REQ-434..REQ-444 under O3 (stay / modify / obsolete)

| REQ | Status today | O3 verdict | Reason in one line |
|---|---|---|---|
| REQ-434 | done | stay (decision 0042 and design remain the router's basis) | The directory design is tier-agnostic; 0044 only adds a later amendment to 0042 Decision 7's scope fence. |
| REQ-435 | pending (PR #2201) | stay | Table, key id, pepper, dual-read, backfill are exactly what the router needs; nothing in it knows a tier. |
| REQ-436 | done | stay, reused | The limiter already guards the discovery mount; domain routing and invitations reuse it as the first plug. |
| REQ-437 | pending | stay for Phase 1; modify later | Endpoint contract unchanged in Phase 1; a domain-fallback branch is added by a new requirement in Phase 4, not by editing this one. |
| REQ-438 | pending | stay for Phase 1; modify later | The page is unchanged for dedicated tenants; Phase 3 adds shared-tenant handling (tenant-config answer + selector) as a new requirement. |
| REQ-439 | done | stay | `ClientIp` is mount-agnostic and serves every new public mount. |
| REQ-440 | pending (in PR #2201) | stay | Same hook/removal rule, applied to the new invitation writer by a new requirement; REQ-440's own four hooks stay as specified. |
| REQ-441 | pending | stay, more valuable | The mail adapter is the delivery channel for invitations and tenant lists. |
| REQ-442 | pending | stay | Per-tenant uniform disclosure is exactly what candidate-facing shared tenants want. |
| REQ-443 | pending | stay | Pepper rotation tooling is tier-independent. |
| REQ-444 | pending | stay; extend gate later | The enablement gate (OQ-3 marker, delivering adapter, pepper) covers every route using the directory; Phase 4 adds domain routing to its scope. |

Under O1 every row is `stay`. Under O2 REQ-435, 437, 438, 440, 442, 443, 444 become obsolete,
REQ-436 and 439 survive as generic public-mount machinery, REQ-441 survives for invitations,
REQ-434 is a sunk, partly moot decision (see section 3).

#### 2.3.7 O3 per-dimension comparison, tier by tier

Same dimensions as 2.1 and 2.2. "Dedicated" = O1 unchanged; "shared" = the O2-like tier.
Where dedicated is identical to O1 this says so and refers to 2.1. Multi-tenant people: see
2.3.3. Description and login: 2.3 and 2.3.1.

**Enumeration / privacy posture.** Dedicated: as O1 (2.1). Shared: no pre-login discovery for
a person who arrives by invitation or URL; if they arrive by e-mail the same directory
lookup applies, with the same disclosure rules and per-tenant uniform flag (REQ-442), which
is recommended on for candidate-facing shared tenants. New inference only in Phase 4: the
domain table, even under the single-query constraint of 2.3.2 item 3, reveals "this domain
routes to tenant X" for disclosing tenants (domain-level residual oracle, R-7). The hosted
login page's own e-mail behaviour in the shared realm is UNVERIFIED (S-6).

**INV-1..INV-8 impact (O3).**
- INV-1: dedicated as O1; shared adds a selector whose scoping must be proven (2.3.5); prefix
  still derived from a server-resolved tenant id.
- INV-2: dedicated as O1; shared adds a tenant-config shared branch that must stay a
  hand-built allowlist; roles never from token claims.
- INV-3: not applicable (both tiers).
- INV-4: dedicated as O1 (pepper, SMTP); shared adds the Keycloak Admin client credential
  (Phase 3) with realm-scoped power.
- INV-5: dedicated as O1; shared adds the "no membership equals no such tenant" class with
  equal round trips.
- INV-6: each Phase 2-4 path (selector, `shared_identity_realms`, invitation route, domain
  routing) needs its own scoping proof.
- INV-7: unchanged (parameterised Ecto in all new tables).
- INV-8: unknown selector, missing organisation claim or a Keycloak outage must return typed
  errors, not raise (both tiers).
INV-9 as in 6.7.

**Migration path from today.** None for any existing tenant: all stay dedicated, the
`auth_mode` default preserves behaviour, and no user moves in Phases 0-4. A tenant reaches
the shared tier only by a new greenfield tenant (Phase 3) or an explicit per-tenant migration
(Phase 5, not cleanly reversible, R-5).

**Cost in requirement-sized steps.** Summed from 4.2: spike 3-4, Phase 1 (dedicated + router)
about 8, Phase 2 about 7, Phase 3 about 6, Phase 4 about 5 = about 29-30 in total, of which 8
are the already-planned O1 work and about 18 (Phases 2-4) are gated on the spikes and on the
user's answer to question 1. Phase 5 is extra, per tenant. The matrix in section 3 uses these
numbers. Estimate, wide error bars.

**Operational cost.** Dedicated: as O1 (N realms, per-realm provisioning and backup). Shared:
one additional realm (the shared realm), one client and mapper set, one backup unit, plus the
shared realm's trust row. Total realms = dedicated tenants + 1. Memory cost per realm or
organisation: UNVERIFIED (S-12). Added blast radius: the shared realm only (R-4).

**Tenant-admin autonomy.** Dedicated: as O1. Shared: low; realm policy is platform-wide, and
admin delegation per organisation is UNVERIFIED (S-5). Default: tenant admins invite and
deactivate members through Letflow only (question 2).

**Enterprise SSO per tenant.** Dedicated: intended via a brokered corporate IdP in that
tenant's realm, subject to spikes S-8..S-10 (UNVERIFIED). Shared: not offered; a tenant that
needs corporate SSO is dedicated. Organisation-level IdP linking (S-4) is a possible later
alternative, UNVERIFIED.

**Data separation.** Dedicated: as O1 (strongest). Shared: identity store is shared across
shared tenants; business data still schema-per-tenant with per-tenant `users` rows (2.3.4),
so INV-1 holds. Isolation between the two tiers is complete (different realms).

**Mobile tier impact.** Dedicated: none (as O1). Shared: the app sends the tenant selector on
every call, tenant-config needs a shared variant, and MOB-5's "token audience MUST be scoped to
the tenant realm" (`docs/mobile/requirements.md:208-211`) must be revised for shared tenants
first (R-11). No mobile change in Phases 0-2.

#### 2.3.8 Invitation security (constraints Phase 2/3 must carry)

An invitation is the ONLY way a shared-tier `users` row is created, so it is a bearer
capability that mutates membership. Constraints:
1. **Bound to the authenticated identity at acceptance, not to an e-mail string.** Acceptance
   requires an authenticated session of the shared realm; the row is keyed to that token's
   `(shared realm, sub)`. Binding by e-mail would be account linking by e-mail.
2. **Verified e-mail.** The token's `email_verified` must be true and the address must equal
   the invited address. Without this, with self-registration enabled in the shared realm an
   attacker could register `victim@x` unverified and accept the invitation addressed to it.
   (Whether self-registration can be disabled, and how `email_verified` behaves: UNVERIFIED,
   spike S-18; S-15 covers only "Login with email".)
3. **Token lifecycle.** High-entropy random token (at least 128 bits), short fixed expiry,
   single use, stored only as a hash (comparison of hashes), revocable by the inviting tenant
   admin; acceptance is idempotent for the same `sub` only.
4. **Leak handling.** The token travels in the URL FRAGMENT (`/invite#<token>`, never sent to
   the server or to access logs) and is then sent only in a POST body; it is never in a path
   or query string. The SPA immediately replaces the URL, sends
   `Referrer-Policy: no-referrer`, and logs only a fixed string (INV-4 spirit; 0042 prohibition 9
   style, no token in logs or telemetry).
5. **Rate limiting.** First-plug limiter as for the discovery mount (0028 s6 style, reusing
   the mount-agnostic machinery), plus a per-token attempt cap.
6. **INV-5 / INV-6.** An unknown, expired, used or revoked token returns one collapsed
   response; the route carries its own scoping proof and SECURITY-REVIEWER gate. It touches
   exactly one tenant schema, derived from the token's server-side record, never from a
   request parameter.
7. **Single writer.** Acceptance is the dedicated shared-realm writer of 2.3.4 (a); it writes
   the directory row in the same transaction through the REQ-440 hook.

#### 2.3.9 Additional Phase 2/3 scope (security hardening, one line each)

- **Mutable e-mail in the central realm.** ASSUMED RISK, UNVERIFIED (S-18): Keycloak
  profile e-mail edits and first-broker-login linking by e-mail may allow an account to be
  transferred to an attacker; invitations, domain routing and
  the directory all key on e-mail. Phase 2 requires locked/verified e-mail change and no
  automatic linking by e-mail; membership authority is `(realm, sub)` only.
- **Break-glass admin of the shared realm (question 5).** Needs an audit trail and
  credential custody by reference only (INV-4); no shared password in a repository, chat or
  handoff.
- **Per-tenant audit trail.** Membership grants/removals and shared-realm logins are
  recorded in the tenant's own audit log, so auditors need not read the central realm.
- **Cross-tenant SSO session and logout scope.** ASSUMED, UNVERIFIED (S-14, S-6): one
  shared-realm SSO session spans all the user's shared tenants; logout semantics become a
  requirement of the pilot.
- **Mobile refresh token.** ASSUMED, UNVERIFIED (S-14, S-17): one shared-realm refresh token
  is valid for every shared tenant of the user (unlike per-realm tokens); the MOB-5 revision must address secure storage and
  per-tenant binding before any mobile shared-tier work.
- **The directory is never the shared-tier membership source** (0042 Standing prohibition
  10): membership is the per-tenant `users` row plus its invitation record; the directory
  only routes.

---

## 3. Decision matrix

Scale: ++ clearly best, + good, 0 neutral, - weak, -- poor. Qualitative; none of it was
measured.

| Criterion | O1 realm-per-tenant + directory | O2 central realm + organisations | O3 hybrid | One-line justification |
|---|---|---|---|---|
| Pre-login discovery risk | 0 | ++ | 0 | O1/O3 carry a bounded single-match inference (0042); O2 has no per-person discovery for shared users. |
| Multi-tenant people | - | ++ (assumed, UNVERIFIED: S-2) | + (shared tier only, same assumption) | O1 keeps separate accounts; O2's native multi-membership is assumed, not verified; O3 inherits it within the shared tier only. |
| Simple/candidate tenants | - | ++ | ++ | Per-tenant realm provisioning is manual (`anti-patterns.md:3008-3016`); shared tier removes it. |
| Complex/enterprise tenants | + | 0 | ++ | Realm-per-tenant isolates policy and IdP; O2 depends on unverified org-IdP features (S-4, S-8, S-9). |
| Tenant-admin autonomy | + | - | + | Realm policy is per-tenant in O1/O3-dedicated; platform-wide in O2/O3-shared. |
| Data separation (identity layer) | ++ | - | + | Realm per tenant is the strongest identity separation; shared realm is one store. |
| Business-data isolation (INV-1) | ++ | + | + | Unchanged schema-per-tenant; O2/O3-shared add a membership-checked selector that must be proven. |
| Build cost | + (about 10 steps, 3 done) | -- (about 25-35) | 0 (about 29-30 in total: 8 Phase 1 = O1, 3-4 spike, 18 gated shared/SSO) | Costs from 2.3.7 and 4.2; O3 pays O1 then adds the gated 18 only if spikes pass. |
| Operational cost today (tens of tenants) | 0 | + | 0 | Realm count/memory unknown (S-12); O2 consolidates but concentrates blast radius. |
| Blast radius of one IdP mistake | + | -- | + | One shared realm affects every shared tenant at once. |
| Migration risk from today | ++ (none) | -- (user `sub` changes, re-link) | + (none until a tenant opts in) | O3 never migrates existing tenants unless the user chooses. |
| Reversibility | ++ | - | + | O3 phases 0-2 are reversible; moving a tenant to shared is not. |
| Fit with ratified decisions | ++ | -- (supersedes 0006 7.3, R5, 0002 addendum) | 0 (same, but only for the shared tier, later) | O1 follows 0042 (ratified) and 0043 (BA-decided, gates owed); O2/O3 reopen identity decisions. |
| Mobile impact | ++ | - | 0 | O2 breaks MOB-5's "audience scoped to the tenant realm" (`requirements.md:208-211`) for everyone; O3 only for shared tenants. |
| Dependence on unverified Keycloak features | ++ (none new) | -- (central) | 0 (only for the shared/SSO phases) | Every O2/O3 organisation claim is a spike question. |

---

## 4. Recommendation

**Proceed with Phase 1, which is identical under O1 and O3 (the email-first work as planned
in 0042/0043); nothing beyond it is committed. O3 is the recommended direction for
anything further: Phase 0 (the spike) and Phases 2 and later (the shared tier) start only
on a question 1 answer that wants the shared tier (Phase 4 also needs question 9), and then
on spike results.**

Rationale.
1. O1 is not wasted under any outcome. The directory, limiter, client-IP resolution, mail
   adapter, pepper handling and discovery page are required by O3 as the router, and are
   independent of whether the shared tier ever ships. The only option that discards them
   is O2.
2. The decisive unknowns are facts about Keycloak 26.2 that this repository cannot answer
   (can an organisation be a member of several organisations, scoped in a token, linked to an
   external IdP, administered by a non-platform admin; what does it cost in memory). A
   decision that depends on them before they are measured would be speculation. O3
   postpones that bet to Phase 2 while still delivering the O1 value now.
3. O2 as a wholesale replacement has the worst risk profile: it supersedes the most
   ratified identity decisions at once (0006 D1-adjacent, R5, 7.3; 0002 addendum), changes
   every user's `sub` for existing tenants (orphaning `users` rows unless re-linked), and
   concentrates blast radius in one realm, in exchange for benefits (fewer realms, native
   multi-tenant people) whose size is unknown at tens of tenants.
4. The user's own framing, "for the complex case a complex solution, for the simple case a
   simple one", is exactly the tier split; but the simple tier is only simple if the spikes
   show Keycloak organisations behave as hoped. If they do not, O3 collapses to O1 at no
   loss.
5. Honest counter-argument: if the product will never have more than a few dozen hand-
   provisioned tenants, and enterprise SSO demand is zero, then O1 alone is the right
   endpoint and building the shared tier would be over-engineering. That is why question 1
   gates Phase 2.

### 4.1 Risks and mitigations

| # | Risk | Mitigation |
|---|---|---|
| R-1 | Selector enables cross-tenant access if membership checking is wrong (the most serious new risk of O2/O3-shared). | JIT off for the shared realm; selector accepted only with an active local `users` row; INV-5 equivalence tests; SECURITY-REVIEWER re-derives 0006 section 3.2's claim; pilot with one greenfield tenant. |
| R-2 | Spikes show Organizations cannot do what is needed (multi-membership token scoping, IdP linking, admin delegation). | Phase 2 is not started; O3 degrades to O1; nothing built is lost. |
| R-3 | Tier complexity leaks into every layer (tenant-config, AuthPipeline, claim mapping, SPA, mobile). | Keep the tier decision in two places only: `tenants.auth_mode` and tenant-config; discovery response unchanged; every shared-tier code path behind one flag until the pilot passes. |
| R-4 | Single shared realm outage or misconfiguration hits every shared tenant. | Shared tier limited to low-criticality tenants first; realm export/restore runbook before the pilot; separate realm for the shared tier, never `master` or a dedicated tenant's realm. |
| R-5 | User migration (if a tenant is ever moved to shared) orphans history because `sub` changes. | Never migrate in Phases 1-4; migration only on explicit user decision with a re-link tool and rehearsal on a QA copy; question 3 default is "Bilimbaga stays dedicated". |
| R-6 | A future Letflow Keycloak Admin client forwards tenant-supplied IdP URLs (SSRF through Keycloak). | Treat as INV-9-style validation at the admin client; SECURITY-REVIEWER gate; platform operator, not tenant admin, configures IdPs in Phase 4. |
| R-7 | Domain-based routing is abused (claiming someone else's domain) or leaks which domains are SSO tenants. | Platform-operator-verified domains only (DNS proof), one joined constant-work query answered only through the mode/uniform rules (never a 200 in Mode A or a uniform tenant), same limiter; first release has no self-service domain claim (question 6). The domain-level and person-level (single-tenant mailbox) oracles for disclosing tenants, the possible mail to nonexistent mailboxes for uniform tenants, and the required dedupe by tenant are named in 2.3.2 item 3; accepted residuals. |
| R-8 | The e-mail path is inert until a mail adapter exists, so multi-tenant people dead-end (0042 OQ-9). | REQ-441 stays a prerequisite of enabling outside dev (REQ-444); organisation-code control remains. |
| R-9 | Per-tenant claim/JIT configuration (currently keyed by realm in config) does not scale to shared tenants. | Move to per-tenant records in Phase 2; static config remains for dedicated realms. |
| R-10 | Holding REQ-437..444 stalls the email-first work for no benefit if the user ratifies. | Hold is temporary; under the recommendation all of them are `stay`, so the cost is elapsed time only. |
| R-11 | Mobile spec says audience is tenant-realm-scoped; shared tier contradicts it. | Shared-tier mobile work needs a revision of MOB-5 first (flagged in section 6). |
| R-12 | PII (HMAC of e-mail) accumulates before the legal basis (OQ-3) is confirmed. | Gate unchanged (REQ-444); flag off outside dev; no pepper provisioned in QA/prod until the user decides. |

### 4.2 Phased migration plan (each phase leaves `main` shippable)

| Phase | Content | Steps (rough) | Reversible? |
|---|---|---|---|
| 0 | **Spike (no product code).** Throwaway Keycloak 26.2 container, answer spike questions S-1..S-18 below, record results in a spike report and an addendum to this record. Decision gate: ratify Phase 2 or stop at O1. | 3-4 (REQ-ANALYST requirement + executing agent per question group) | Fully (docs and a throwaway container). |
| 1 | **O1 as planned = dedicated tier + router.** REQ-435 (with 0043 D-C delta on PR #2201), REQ-440 (closed by verification of the merged PR), REQ-442, REQ-437, REQ-438, REQ-441, REQ-443, REQ-444. Off outside dev until OQ-3 answered. | about 8 | Yes: flag off, reversible migrations, no user data moved. |
| 2 | **Shared-tier foundations, dark.** New ADR 0045 (supersedes 0006 7.3 for shared; amends 0002 addendum, R5, 0038 point 4). `tenants.auth_mode` (default `dedicated`), `shared_identity_realms` trust source in `ProviderRegistry`/`AuthPipeline`, selector plug + membership authorisation, per-tenant claim/JIT config, tenant-config shared branch. No tenant uses it. Acceptance properties: structural shared-realm branch and deny-by-default config fallback with the absent-realm test (2.3.5 4a-4b); single writer, refusal elsewhere, DB backstop or explicit statement (2.3.4); realm disjointness and realm-kind-decided-once; slug -> membership -> status with decoy query and collapsed response (2.3.5 item 3); full-issuer check (S-11); invitation constraints (2.3.8); hardening lines of 2.3.9. | about 7 | Yes until a tenant is set to shared (column default keeps all behaviour). |
| 3 | **Pilot.** One greenfield shared tenant (not Bilimbaga by default). Keycloak Admin client or manual provisioning runbook (INV-4), invitations (uses REQ-441), SPA handling (shared answer in tenant-config), mobile MOB-5 revision. | about 6 | Pilot tenant can be deleted/deactivated (new tenant only). |
| 4 | **Domain routing and enterprise SSO for dedicated realms.** `tenant_login_domains`, brokered corporate IdP in a dedicated realm, domain routing as one joined constant-work query under the mode/uniform rules, or not at discovery (2.3.2 item 3), extended enablement gate. | about 5 | Yes (new tables; per-realm IdP config). |
| 5 | **Optional: migrate existing simple tenants** to shared (user decision per tenant, re-link tool, rehearsal). | per tenant, 3-4 | NOT cleanly reversible (user `sub` changes). Only on explicit user instruction. |

Mobile adoption of discovery is a separate, later requirement in any phase (design section 14).

### 4.3 Open PR #2201 under each option

PR #2201 (`feat/REQ-435-login-directory`) implements the whole former REQ-435 including the
population hooks, on a single pepper; merge is held on pepper provisioning. Its boot checks
fail closed until a pepper exists (0043 D-C, 0043 External dependencies), so merging it
before provisioning would break boot in any environment that has the mount enabled.

| Option | Disposition | Why |
|---|---|---|
| O1 | MERGE after the 0043 D-C delta (key id + dual-read in REQ-435, rotation tooling in REQ-443, per 0043 flagged conflict 3) and pepper provisioning; close REQ-440 by RELEASE-VALIDATOR verification of the merged code. | It is the planned implementation; D-C is BA-decided with REVIEWER/SECURITY-REVIEWER gates still owed (0043 conflicts 1-3). |
| O2 | CLOSE (keep the branch for reference). | The directory has no reader in a design with no pre-login discovery for shared users; merging it would add a PII-bearing table with no use. |
| O3 (recommended) | No new hold added by 0044; the existing pepper-provisioning hold governs. Recommendation: do not merge before ratification, then MERGE with the D-C delta (key id + dual-read, rotation tooling in REQ-443), scope UNCHANGED (do not widen it with tier concepts). | The directory is the router; the table, hooks and key id are tier-agnostic, so waiting costs only time and widening the PR would couple Phase 1 to unverified Phase 2 assumptions. Narrowing (dropping the hooks) is rejected because 0042 Standing prohibition 13 ("directory lands with its writers") and 0043 D-F already accept the split only if REQ-435 and REQ-440 land back to back. |

---

## 5. Keycloak facts and spike questions

### 5.1 Facts cited from the repository

- Image and version: `quay.io/keycloak/keycloak:26.2` (`docker-compose.yml:26`); QA runs the
  same (`ai-dala-infra/landscape/services.md:177`;
  `ai-dala-infra/shared/app-registry.md:239`). Local compose uses `start-dev --import-realm`
  (`docker-compose.yml:27`).
- Realms on QA: `bpm-default`, `bilimbaga`, `swiftroute`, `meridian`, `vortex`, `master`
  (`hosts/ubuntu-16gb-nbg1-1.md:203`). One Keycloak container serves all realms behind one
  nginx vhost (`app-registry.md:246`).
- Realm fixture facts: six realm roles, `letflow-web` and `letflow-mobile` clients, a realm
  role mapper and an audience mapper per client (`bpm-default.json:11-17,22,32-60,62,77-100`);
  no `loginWithEmailAllowed` key (0042 OQ-8).
- Host: CX43, 8 vCPU, about 15 GiB RAM, no swap (`hosts/ubuntu-16gb-nbg1-1.md:31-32`). No
  Keycloak memory limit or JVM setting is recorded in this repository's deploy files or in the
  landscape documents read for this draft; the QA Keycloak compose file lives outside this
  repository (`/opt/apps/letflow-qa-keycloak/deploy/docker-compose.qa.yml`,
  `services.md:169`).
- Users must carry `email`, `firstName` and `lastName` or password grant fails with
  `invalid_grant` (a QA lesson, `app-registry.md:250`).

Nothing else about Keycloak is stated in this record as fact.

### 5.2 Spike questions (must be verified before ratification of Phase 2)

Each is UNVERIFIED. They are phrased to be answerable on a throwaway 26.2 container using
`docker-compose.yml`'s image, with results written into an addendum to this record.

1. **S-1 (availability).** UNVERIFIED. Is the Organizations feature available in
   `quay.io/keycloak/keycloak:26.2`, and is it enabled by default, by a feature flag, or by a
   realm setting? How is it enabled in `start-dev --import-realm` and in the production
   `start` mode QA uses (the exact QA command line is not in this repository)?
2. **S-2 (multi-membership).** UNVERIFIED. Can one user be a member of several organisations in
   one realm? What restrictions apply (managed vs unmanaged members, e-mail domain constraints,
   username uniqueness)?
3. **S-3 (token surface).** UNVERIFIED. How does membership surface in tokens: which claim,
   which mapper, which scope? Can an access token be scoped to ONE organisation at
   authorisation time (a per-organisation token), or does it list all? What does the token
   contain for a user in zero organisations? Does the SPA's single `letflow-web` client and
   audience mapper (`bpm-default.json:22,48`) work unchanged?
4. **S-4 (IdP linking and domain routing).** UNVERIFIED. Can an organisation be linked to an
   external IdP (SAML or OIDC), and does Keycloak route by e-mail domain at login (identity-
   first behaviour) without a prior discovery call? How are domains registered and is
   ownership verified by Keycloak or not?
5. **S-5 (admin delegation).** UNVERIFIED. Can organisations and their members be created and
   managed through the Admin REST API? What permission model exists, i.e. can a
   tenant admin be limited to ONE organisation's members without realm-wide rights? What
   credentials would a Letflow Admin client need, and can they be scoped to organisation
   management only (INV-4 surface)?
6. **S-6 (login and account console).** UNVERIFIED. How does the hosted login page behave for a
   user in several organisations (is there an organisation chooser)? Does it disclose whether
   an e-mail exists (compare to the brute-force and user-enumeration settings)? How does the
   account console show organisations? Does an SSO session in the shared realm allow
   `signinSilent` into a different client or realm (`web/src/auth/tenantOidcRegistry.ts:34-36`
   says it only works with a federated upstream)?
7. **S-7 (limits).** UNVERIFIED. Are there documented or practical limits on organisations per
   realm and members per organisation? What is the behaviour with thousands of organisations?
8. **S-8 (brokering in a dedicated realm).** UNVERIFIED. For a dedicated realm that brokers a
   corporate IdP: how are users first-login-linked, which attributes become the `email`
   claim Letflow's claim mapping expects (`claim_mapping_config.ex:89-97`), and how is
   `kc_idp_hint` or the equivalent used (0042 deliberately unused it)?
9. **S-9 (SAML).** UNVERIFIED. Does the pinned version support SAML brokering in a realm
   without extra configuration, and how are signing certificates rotated?
10. **S-10 (IdP URL handling).** UNVERIFIED. Who fetches an IdP's metadata URL (Keycloak server
    side), and does Keycloak restrict private-range targets? (Relevant to INV-9 and R-6.)
11. **S-11 (issuer and audience vs `ProviderRegistry`).** UNVERIFIED. What is the `iss` of a
    token issued by an organisation-aware login in the shared realm (still
    `<base>/realms/<shared>`)? Confirm `extract_realm` (`auth_pipeline.ex:269-281`) and
    `Oidcc.Token.validate_jwt` with one `client_id` (`oidcc.ex:147-156`) validate it; confirm
    the audience mapper emits the audience Letflow expects for the shared client.
    Narrowness (Phase 2 acceptance): the FULL issuer (base URL plus realm) is checked, not
    only the realm slug that `extract_realm` keeps from `iss`; and a token from the shared
    realm's client cannot satisfy a dedicated tenant's chain (one `client_id` is used for
    all realms today, so the realm-kind decision of 2.3.4 must come first).
12. **S-12 (memory and realm count).** UNVERIFIED. Measure resident memory of the Keycloak
    container at 1, 6 and 50 realms, and with 10 and 1000 organisations in one realm, on the
    QA host class (CX43); record the current QA Keycloak memory and JVM settings.
13. **S-13 (user migration).** UNVERIFIED. Can users move between realms with credentials
    intact (partial export/import, credential hash portability), or only with password reset?
    What happens to `sub` on import? (Determines R-5 and the Phase 5 cost.)
14. **S-14 (refresh and logout).** UNVERIFIED. How do refresh-token lifetime, session and
    logout behave across several organisations in one session? Does the SPA's logout
    (`AuthProvider.logout`, which clears the stored realm) end the right sessions?
15. **S-15 ("Login with email").** UNVERIFIED. Is "Login with email" a realm-level setting that
    applies to the shared realm, what is its default in 26.2 (0042 OQ-8 notes the fixture
    does not set it), and how does it interact with organisation membership resolution by
    e-mail?
16. **S-16 (theming and branding).** UNVERIFIED. Can the login page show per-organisation
    branding in the shared realm, or is the theme realm-wide (tenant branding today is served
    by `GET /api/tenant-config`, not by Keycloak)?
17. **S-17 (access-token lifetime and revocation).** UNVERIFIED. What is the default and the
    configurable access-token lifetime in 26.2, and does a Keycloak-side user disable, `sub`
    change or deletion revoke already-issued access tokens before expiry, or only block
    refresh? (Defines the revocation bound of 2.3.5 item 6; complements S-14.)
18. **S-18 (self-registration, e-mail verification, e-mail edit, broker linking).**
    UNVERIFIED. In the shared realm: can self-registration be disabled; how is `email_verified`
    set and can an unverified address be registered and then used; can a user edit their e-mail
    in the account console without re-verification; does first-broker-login link accounts by
    e-mail automatically? (Underpins 2.3.8 items 1-2 and 2.3.9.)

---

## 6. Consistency with existing decision records (0042 ratified; 0043 BA-decided, gates owed)

Legend: CONSISTENT = the recommendation neither changes nor contradicts it; AMENDS = a quoted
passage changes in a stated phase; SUPERSEDES = a decision is replaced. "Today" means Phase 1
(= O1), which is fully consistent with every record below by construction (it IS decisions
0042/0043).

### 6.1 Decision 0002 (OIDC integration)

- Library choice (`ueberauth_oidcc`/`oidcc`, `0002...md:18-21`): CONSISTENT in all phases;
  token verification code is unchanged.
- **AMENDS (Phase 2).** Quoted, `0002...md:168-171`: "the `tenants` table (`idp_realm_id`,
  REQ-015/REQ-019) is the sole source of truth for which OIDC issuers are trusted -- never a
  static config list, never 'accept any issuer.'" The shared realm adds one more trusted
  issuer that is not a tenant row. Proposed shape: a revocable database row
  (`shared_identity_realms`) consulted by the same trust gate, so "database is the trust
  source and revocation is immediate" is preserved; "tenants table is the SOLE source" is the
  text that changes.
- Quoted, `0002...md:190-195`: "One shared Keycloak host, N realms ... a bare realm slug, not
  a full issuer URL". CONSISTENT: the shared realm is one more realm on the same host.

### 6.2 Decision 0006 (identity tables per tenant)

- D1 (`0006...md:30-33`), D2, D3: CONSISTENT (per-tenant `users` kept in the shared tier).
- R5 (`0006...md:132-157`): AMENDS (Phase 2), narrowed to dedicated tenants as described in
  section 2.3.4. The quoted claim "realm<->tenant is a strict partial bijection (nullable only
  when OIDC is off)" (`0006...md:150-152`) gains a second legitimate NULL case (shared tier).
- Section 3.2 (`0006...md:181-210`): its argument "R5 makes the collision unreachable"
  (`0006...md:188-195`) is false for the shared realm, and its replacement is a DOWNGRADE from a
  database constraint to an application invariant (2.3.4: single writer, refusal elsewhere,
  DB backstop or an explicit statement none is feasible). NOT silently reused; needs the
  independent SECURITY-REVIEWER re-derivation 0006 section 8 already asks for
  (`0006...md:304-306`).
- Section 3.3 (`0006...md:212-221`) and section 7 item 3 (`0006...md:296-297`, quoted:
  "Multi-tenant human identity -- foreclosed by section 3.3, reopenable only by superseding
  this record."): SUPERSEDED for the shared tier only (Phase 2 ADR), exactly because 0042
  deliberately left it standing (`0042...md:160-165`).

### 6.3 Decision 0035 (login delegated to Keycloak)

- Core decision, quoted `0035...md:39-42`: "Keycloak-hosted-only login is the correct, working,
  intended production architecture." CONSISTENT in all phases: credentials are entered only on
  Keycloak's hosted UI, including in the shared realm.
- Observation "no `/login` route" (`0035...md:15-17`): already amended by 0042
  (`0042...md:201-225`). The invitation landing route (`/invite`, token in the fragment, Phase 3) is a second
  credential-free route and would extend that same amendment (it collects no credential).

### 6.4 Decision 0038 (tenant membership lookup)

- Conditions 1-3 for `tenant_memberships` (`0038...md:47-75`): CONSISTENT; the table is not
  used for shared-tier membership, specifically because of the forbidden JIT-created rows
  (`0038...md:100-103`).
- **AMENDS (Phase 2).** Quoted point 4, `0038...md:76-81`: "The realm-resolution chain (0006 R5)
  is unchanged. Which tenant a given request is authenticated against still resolves
  exclusively via AuthPipeline's realm->tenant chain." For the shared realm the tenant is
  resolved by selector + local membership.
- **AMENDS (Phase 2).** "What remains foreclosed" bullet 2, quoted `0038...md:95-97`: "Any
  mechanism letting a single `users` row serve more than one tenant schema, or letting
  `AuthPipeline`'s realm->tenant resolution consult anything other than
  `tenants.idp_realm_id`." The second half is contradicted for the shared realm; the first
  half ("a single `users` row serving more than one tenant") stays true because shared
  tenants keep per-tenant rows.
- "What remains foreclosed" (`0038...md:91-103`), other bullets: still honoured for
  `tenant_memberships`; the unauthenticated-lookup bullet is already amended by 0042.
- 0012 note: see 6.8.

### 6.5 Decision 0042 (email-first directory)

- **AMENDS (Phase 2, shared realm).** 0042's reaffirmation (`0042...md:193-196`) that 0038's
  second foreclosed bullet remains foreclosed verbatim: "any mechanism letting a single
  `users` row serve more than one tenant schema, or letting `AuthPipeline`'s realm->tenant
  resolution consult anything other than `tenants.idp_realm_id`". The shared-realm branch
  consults `shared_identity_realms` plus selector plus membership, so the second half is
  amended for the shared realm (see 6.4); the first half ("single `users` row serving more
  than one tenant") stays true.
- **AMENDS (Phase 3).** Standing prohibition 12 (fixed template with no request-derived text
  other than the recipient, no URL from tenant text): an invitation mail needs a new template
  and a link, so Phase 3 amends it, with a SECURITY-REVIEWER gate; not claimed consistent.
  Prohibition 14 (any path deleting/purging `users` rows calls
  `remove_entry_if_unreferenced/3` in the same transaction) binds the offboarding purge of
  2.3.5 item 6.
- Decisions 1-6 and Standing prohibitions 1-5, 8-10, 13, 14: CONSISTENT in Phases 1-3. The
  tier reaches the browser through tenant-config, not through the discovery response, so
  prohibitions 4 and 11 (closed allowlist; no new field without SECURITY-REVIEWER) are not
  touched by the router reuse in those phases.
- **AMENDS (Phase 4, domain routing).** Standing prohibition 6 (no input-differentiated
  status), 7 (one database round trip, no second query, quoted in 2.3.2 item 3) and 11 (a
  new disclosure source needs SECURITY-REVIEWER and an amendment). Domain routing may only be
  built as one joined constant-work query answered through the existing mode and per-tenant
  uniform rules (never a 200 in Mode A or a uniform tenant), or not at the discovery step at
  all. The residual domain-level oracle is named in 2.3.2 item 3 and R-7.
- **AMENDS (Phase 2+).** Decision 7, quoted `0042...md:111-114`: "No SSO across realms, no
  Keycloak identity-provider brokering (`kc_idp_hint` is deliberately unused), no Keycloak Admin
  client, no migration to Keycloak Organizations". Phase 2-4 introduce organisations, an
  Admin client and brokering inside dedicated realms; cross-realm SSO remains out of scope.
- "What remains unchanged", quoted `0042...md:160-163`: "no single human identity spanning
  tenants, no shared or global `users` row". SUPERSEDED for the shared tier (see 6.2); the
  "no shared or global `users` row" half stays true (rows remain per tenant).
- Alternative 3 (`0042...md:417-427`, "A future ADR must choose") and OQ-2: this record IS
  that ADR (proposed).
- OQ-3 (lawful basis, `0042...md:494-504`): UNCHANGED and still the one hard blocker for
  enabling outside dev.

### 6.6 Decision 0043 (BA decisions)

- 0043 status: BA-decided by delegation (`0043...md:3-5`); D-D is PROPOSED and the
  REVIEWER/SECURITY-REVIEWER gates are still owed. Only 0042 is gate-ratified. 0043's ten
  "Conflicts flagged for REVIEWER" (`0043...md:286-343`) remain OPEN and are NOT settled by
  0044; Phase 1 (= O1) inherits them.
- D-A..D-F, D-H: not contradicted by 0044 (stay). D-C key id and dual-read (REQ-435) and the
  rotation tooling (REQ-443) are what PR #2201 must absorb (0043 flagged conflict 3).
- **AMENDS (Phase 3), D-B.** Quoted `0043...md:112-114`: "Nothing here builds those and the
  port is not widened for them" (invitations). Phase 3 uses the mail adapter for invitations,
  which needs its own template and link; see 6.5 (prohibition 12) and the SECURITY-REVIEWER
  gate.
- D-G, quoted `0043...md:229-233`: "DEFERRED; decide via an ADR when the tenant count grows. The
  directory is the abstraction that survives a later move". CONSISTENT: this record is that
  ADR and recommends deferring the build decision to the Phase 0 spike.
- Known limitation D-E (Keycloak-only accounts, `0043...md:187-192`): Phase 4 domain routing
  is a candidate fix; not required.
- D-D (OQ-3 gate) unchanged.

### 6.7 Security invariants

| Invariant | Phase 1 (O1) | Shared tier (O2 / O3 Phase 2+) |
|---|---|---|
| INV-1 data isolation (`security-invariants.md:46-75`) | CONSISTENT: directory outside tenant schemas, backfill via derived prefix. | Prefix still derived from a server-resolved tenant id; new selector path must prove scoping (INV-6). |
| INV-2 server-side fields (`:79-114`) | CONSISTENT: hand-built closed allowlist. | Tenant-config shared-branch response stays a hand-built allowlist; role names never from token. |
| INV-3 sandboxing (`:118-140`) | Not applicable. | Not applicable. |
| INV-4 secrets by reference (`:144-172`) | Pepper and SMTP credentials by reference. | New Keycloak Admin client credentials (realm-scoped power) are a new standing secret. |
| INV-5 indistinguishability (`:176-206`) | First e-mail-keyed instance; classes in 0042 design section 10. | New class: selector for a tenant with no membership must equal non-existent tenant; same round trips. |
| INV-6 new paths prove scoping (`:210-227`) | Each requirement carries a SECURITY-REVIEWER gate. | Selector, `shared_identity_realms`, invitation route, domain routing each need one. |
| INV-7 no SQL interpolation (`:231-250`) | Backfill uses prefix derivation. | Unchanged discipline. |
| INV-8 no crash on realistic failure (`:254-290`) | Notifier/DB failure -> neutral 202. | Unknown selector, missing org claim, Keycloak outage must return typed errors, not raise. |
| INV-9 outbound URLs (`:332-382`) | No tenant-controlled outbound URL. | Letflow-originated IdP URL forwarding (future Admin client) needs validation (R-6). |

### 6.8 Decision 0012 (mobile tier stack)

CONSISTENT. The stack (`flutter_appauth`, OIDC Auth-Code + PKCE through Custom Tabs /
`SFSafariViewController`, `0012-mobile-tier-stack.md:23,63`) is unchanged in Phases 0-2 and
for dedicated tenants. For shared tenants (Phase 3+) the tenant-realm audience wording of
MOB-5 in `docs/mobile/requirements.md:208-211` is revised first (R-11, question 10); that is
a change to the mobile spec, not to 0012.

---

## 7. Remaining questions for the user

Each question carries the default this record would adopt if unanswered, and why.

1. **How many tenants, and are small/self-service tenants expected?** Default: tens of
   hand-provisioned tenants, no self-service sign-up, so build Phase 1 only and do NOT start
   Phase 2. Why: the shared tier's value grows with tenant count; at the current QA scale (6
   realms) O1's operational cost is tolerable.
2. **Tenant-admin autonomy for the shared tier.** Can tenant admins invite and deactivate their
   own members, set MFA or branding? Default: invite/deactivate members through Letflow only;
   no Keycloak access, no realm-level settings. Why: realm policy in a shared realm is
   platform-wide, and S-5 is unverified.
3. **Does Bilimbaga move to the shared tier?** Default: no; it stays dedicated and is set to
   uniform disclosure (0043 D-A). Why: candidate PII and exam context favour maximum identity
   separation, and migration changes every `sub` (R-5).
4. **Legal controller and lawful basis (0042 OQ-3, 0043 D-D).** Still OPEN and BLOCKING for
   enabling outside dev. Default: the gate stays; the SPA flag and the mount stay off outside
   dev; no pepper is provisioned in QA/prod. Why: the directory is cross-tenant personal data;
   a BA proposal is not legal confirmation.
5. **Who owns the central realm?** Default: the platform operator (the `ai-dala-infra`
   process), with `PLATFORM_ADMIN` humans and a break-glass admin; tenant admins have no
   Keycloak admin rights. Why: it is a cross-tenant trust root and an INV-4 secret holder.
6. **Domain claim and verification for e-mail-domain routing.** Default: platform-operator-
   verified domains (DNS TXT proof, manual approval), one tenant per domain, no self-service
   claim in the first release. Why: unverified domain claims let one tenant capture another
   organisation's users (R-7).
7. **Hosting and memory limits.** Default: before any realm-consolidation decision, record the
   current QA Keycloak resident memory and JVM settings and run spike S-12; no change to the
   host until measured. Why: nothing about realm/organisation memory is verified.
8. **Person in both tiers.** Default: two separate accounts, neutral 202 plus e-mailed list,
   no unification. Why: cross-realm identity is out of scope (0042 Decision 7) and a
   unification promise cannot be kept without SSO federation.
9. **Is there a named customer needing corporate SSO (SAML/OIDC)?** Default: none, so Phase 4
   is not scheduled. Why: it is the most Keycloak-dependent phase (S-4, S-8, S-9, S-10).
10. **Mobile adoption.** Default: the mobile tier keeps slug/deep-link bootstrap; adoption of
    discovery and any shared-tier support are separate later requirements, and MOB-5's tenant-
    realm audience wording is revised first (`requirements.md:208-211`). Why: mobile is
    unaffected in Phases 0-1.
11. **Do you ratify releasing the Phase 1 work now?** Default: yes. After ratification the hold
    on REQ-437..444 is lifted and PR #2201 proceeds as in 4.3. Why: Phase 1 is the planned
    work of 0042 (ratified) and 0043 (BA-decided, gates owed) and is identical under O1 and O3.
12. **Per-tenant "Login with email" (0042 OQ-8).** Default: UAT verifies every dedicated realm
    (and later the shared realm) before the SPA flag is enabled anywhere. Why: `login_hint`
    pre-fills the username field only.
13. **Where shared-tier profile data lives.** Default: per-tenant `users` row; the central
    realm holds credentials and e-mail only. Why: keeps 0006 D1 and every foreign key to
    users intact.
14. **Token roles in the shared realm.** Default: ignored; roles come only from local tenant
    groups. Why: realm roles are realm-wide and cannot be per tenant; the code already
    authorises from local groups (`auth_pipeline.ex:353-361`).

---

## 8. Requirement impact

| REQ | Status today | Verdict (recommended, O3) | Reason |
|---|---|---|---|
| REQ-434 | done | stay | Design and 0042 are the router's basis; no edit. |
| REQ-435 | pending (PR #2201 open, merge held) | stay (no new hold from 0044; the existing pepper hold governs; do not merge before ratification) | Tier-agnostic data layer; needs the D-C delta (key id + dual-read here, rotation tooling in REQ-443); do not widen. |
| REQ-436 | done | stay | Limiter reused for every public mount. |
| REQ-437 | pending | stay (hold until ratified) | Contract unchanged in Phase 1; domain fallback is a later new requirement. |
| REQ-438 | pending | stay (hold until ratified) | Page unchanged for dedicated; shared handling is a later new requirement. |
| REQ-439 | done | stay | `ClientIp` mount-agnostic. |
| REQ-440 | pending (covered by PR #2201) | stay (hold until ratified) | Same hook/removal rule, applied to the new invitation writer by a new requirement. |
| REQ-441 | pending | stay (hold until ratified) | Delivery channel for lists and invitations. |
| REQ-442 | pending | stay (hold until ratified) | Per-tenant uniform disclosure suits candidate-facing shared tenants. |
| REQ-443 | pending | stay (hold until ratified) | Rotation tooling independent of tier. |
| REQ-444 | pending | stay (hold until ratified); scope extended later | Gate covers all directory-backed routes. |

For comparison (not recommended): O1 = all `stay`, no hold needed. O2 = REQ-435, 437, 438, 440,
442, 443, 444 obsolete; REQ-436, 439, 441 survive as generic machinery; REQ-434 sunk.

### Hold note

UPDATE 2026-10-05: Phase 1 was ratified and the `hold:` markers described below have been
removed (see "Ratification record" in section 9). The text below is retained as history.

REQ-437, REQ-438, REQ-440, REQ-441, REQ-442, REQ-443 and REQ-444 (the pending requirements
numbered 437 and above) carry a temporary hold marker in `docs/requirements.yaml`, added by
`ORCH` and not by this record, pending the user's ratification of this record. The marker's
purpose is to stop new build work from starting on assumptions that O2 or an amended O3 could
invalidate while the decision is open. It is not a statement that the work is wrong: under the
recommendation every one of those requirements is `stay`, so ratification releases the hold
unchanged and the only cost of the hold is elapsed time. REQ-435 carries NO hold marker in
`docs/requirements.yaml`; it is held only by the pre-existing pepper-provisioning hold on PR
#2201 / queue task Q-944 (see 4.3), which is independent of this record; 0044 adds no new
hold on it. `hold:` is an advisory text key in `docs/requirements.yaml` that tooling ignores;
letflow-queue task state is not changed by this record, so a worker that claims a held id is
expected to read the marker and release the claim. `ORCH` removes the markers on
ratification (or when the user rejects O3 in favour of O1, in which case the same).

---

## 9. Sign-off

Verdicts below are copied by `ORCH` from the gate agents' own handoff results
(`handoffs/ADHOC-20261005-001/step-01b-*.json`, `step-02-*.json`, `step-03-*.json`); the
record's author claims none. A gate PASS is a verdict on soundness and honesty of this
proposal, not a choice among O1, O2 and O3, which is the user's. History: the record needed
four rework rounds (validator FAIL on O3 coverage; security FAIL on 6 MAJOR; validator FAIL
on tags; reviewer FAIL on 3 MAJOR), each applied as text and re-gated; `ORCH` ran the fourth
round past the nominal `max_rework` of 3 because each failure was new and narrowing, not a
repeat (stated in the PR body).

- **CODE-DESIGN-VALIDATOR:** `PASS` (2026-10-05, after rework 3; the later line-10 cross-reference
  fix of rework 4 was applied by `ORCH` as a one-phrase mechanical edit, not re-gated).
- **SECURITY-REVIEWER:** `RATIFIED` / `PASS` (2026-10-05, after rework 3; 0 BLOCKER, 0 MAJOR,
  1 ADVICE A-1: new dedicated realms need their JIT entry before the tenant row is bound). Not
  re-run on rework 4, which only changed consistency wording (6.x, 4.3, hold note). Specific asks as gated: (a) the selector + membership rule and the
  INV-5 equivalence class of section 2.3.5 (ordering slug -> membership -> status, decoy
  query, collapsed response); (b) the downgrade of 0006 section 3.2's guarantee from a DB
  constraint to an application invariant (`0006...md:188-195`, `:304-306`) and the single-
  writer / refuse-shared-realm / backstop requirements of 2.3.4; (c) the structural shared-
  realm branch and deny-by-default config fallback (2.3.5 items 4a-4b); (d) disjointness of
  `shared_identity_realms` and `tenants.idp_realm_id` and realm-kind-decided-once (2.3.4);
  (e) the domain-routing amendment of 0042 prohibitions 6, 7, 11 and its residual oracle
  (2.3.2 item 3, 6.5, R-7); (f) the invitation-security constraints (2.3.8) and the Phase 2/3
  hardening scope (2.3.9).
- **REVIEWER:** `RATIFIED` / `PASS` (2026-10-05, after rework 4; RV-1..RV-8 resolved; two MINOR
  notes: line-14 vs section 4 emphasis, and `hold:` handling by queue tooling unverified).
  Specific asks as gated: (a) the supersession scope for 0006 section 7.3 and
  0042's "what remains unchanged" paragraph; (b) the amendment of 0002's "sole source" sentence
  and 0038 point 4; (c) whether the Phase 1 = O1 framing leaves 0042 intact and does not pretend to settle 0043's open conflicts 1-10
  (it should); (d) the O3 treatment of PR #2201 and the hold note.
- **User ratification:** Phase 1 RATIFIED on 2026-10-05 (see below); later phases deferred. Not
  a gate agent; the user alone converts Status from PROPOSED to decided.

### Ratification record (2026-10-05)

The user (repo owner) decided in the session on 2026-10-05, quote: "My concern is that we can
resolve complex authorization path in future. But I prefer to make simple cases now and complex
later when they will come actually. So, I am for the first phase to execute now and other - as
soon as they will be really needed".

- **Ratified now (Phase 1):** REQ-435..444 as planned: platform directory, email-first login,
  realm-per-tenant (O1). Under the recommendation every one of these is `stay` (section 8), so
  the temporary hold on REQ-437, 438, 440-444 is lifted and the `hold:` markers are removed
  from `docs/requirements.yaml`. Work is still subject to each requirement's `depends_on`
  (REQ-440 before 437; 441 and 442 before 437; 443/444 as in the yaml). PR #2201 proceeds as in
  4.3, still gated by the pepper-provisioning hold.
- **Deferred, not decided:** the shared tier / O3 beyond Phase 1, domain routing, brokered
  company IdP and any O2 move. Trigger to revisit: an actual customer requirement. At that time
  run spikes S-1..S-18 (section 5.2) and answer the remaining questions.
- **Section 7 questions:** the defaults for the Phase-1-relevant questions are ACCEPTED as
  written: Q1 (tens of hand-provisioned tenants, no self-service, build Phase 1 only), Q3
  (Bilimbaga stays in its dedicated realm, uniform disclosure per 0043 D-A), Q5 (central realm
  owner: not applicable until a shared tier exists), Q11 (release Phase 1 now). Q4 (legal
  controller, 0042 OQ-3) stays OPEN and still gates enabling the feature flag outside dev. All
  other questions (Q2, Q6-Q10, Q12-Q14) are DEFERRED, not answered; their stated defaults are
  not adopted by this ratification.
