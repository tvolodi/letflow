# 0042 — Email-first login: a platform tenant-login directory and a credential-free, email-keyed discovery route

Status: decided

Date: 2026-10-04. Drafted by `CODE-DESIGNER` (REQ-434). Owner: `ORCH`. Gates:
`CODE-DESIGN-VALIDATOR`, `SECURITY-REVIEWER` and `REVIEWER` are all still `PENDING` (see
"Sign-off" at the end) -- the disclosure-mode default in particular is a recommendation
that requires ratification by `REVIEWER` and `SECURITY-REVIEWER`, not a settled fact.

Amends (by reference, not by supersession, following the form 0038 used):
`0006-identity-tables-schema-per-tenant.md` §3.3 and §7 item 3;
`0038-tenant-membership-lookup-amendment.md` "What remains foreclosed, unchanged";
`0035-frontend-login-delegated-to-keycloak.md`'s "no in-app login surface / no `/login`
route" observation. Does **not** amend `0028` (standing prohibitions re-stated and
obeyed below) or `0040` (scope differs, see "Accepted bounded inference").

Full mechanism: `lib/letflow/design/req434-email-first-login-directory.md` ("the design").
This record carries the decision, the amendments and the prohibitions that bind future
requirements; the design carries the specification, the citations and the per-requirement
work packages. The split is chosen for the reason 0028 states for its own: the
prohibitions must be read to the end by every future requirement touching this route.

## Context

Letflow is realm-per-tenant: one Keycloak host, N realms, `tenants.idp_realm_id` is a
strict 1:1 binding (0002 addendum, `0002-oidc-integration.md:190-193`; 0006 R5,
`0006-identity-tables-schema-per-tenant.md:132-157`), and accounts are separate per realm
(0006 D1). After login the tenant is resolved from the token's realm
(`Letflow.Identity.resolve_tenant_by_realm/1`, `lib/letflow/identity.ex:150`). *Before*
login, the SPA has to decide which realm to send the browser to, and today it can only
use a stored slug, a `?realm=` parameter, or fall back to `bpm-default`
(`web/src/auth/tenantConfig.ts:40-51`, `:53-67`; `lib/letflow/routers/tenant_config.ex:230-249`).
A user of any other tenant who arrives without `?realm=` is sent to the wrong realm
(ISS-0727, cited by REQ-438). The user-approved feature is an email-first screen: the SPA
asks for an email, a platform-level directory maps the normalised email to the tenants
where it has an account, one match goes straight to that tenant's Keycloak realm with
`login_hint`, and several or none get a neutral outcome.

The feature cannot be built without first deciding it is allowed. Reading the existing
records found four real conflicts and one adjacent point:

1. **0006 §3.3 / §7 item 3, as narrowed by 0038.** 0038's "What remains foreclosed" names
   "a self-service 'find my account(s) by email' flow reachable by an unauthenticated ...
   caller" and "a cross-tenant lookup keyed on anything the caller supplies at request
   time". This feature is exactly that flow. It cannot be inferred from 0038; it needs its
   own record, which 0038 itself calls for (`0038...md:86-89`: "still requires its own
   decision-record work").
2. **0035.** 0035 records that the SPA has "no in-app login surface ... no `/login` route".
   The email-first page is a new SPA page. It collects an email address and never a
   credential, so 0035's core decision stands, but its observation does not.
3. **0028.** 0028 says Letflow has "exactly one unauthenticated read surface, `/api/public`,
   and a resource is reached on it by an opaque capability handle"
   (`0028...md:44-45`) and forbids a caller-supplied tenant hint, a collection or search
   route, any 401/403, and an `AuthPipeline` allowlist (`0028...md:86-110`). The discovery
   lookup is keyed by a caller-supplied email, so it must not live under `/api/public`.
4. **0040.** 0040 concerns *authenticated* routes and defers a general per-actor limiter
   to S4 (`0040...md:25-52`, citing the deferred `Letflow.Plugs.RateLimit` row at
   `lib/letflow/plugs/api_pipeline.ex:59`). It does not cover this route; 0028 §6
   (`0028...md:81-84`) is the closer precedent.

Checked and found not in conflict: **0002** (the token-verification path and
`ProviderRegistry` are untouched; the realm still comes from the verified token), **0022**
(BilimBaga's users are the motivating case; no per-vertical code is introduced, and
`0022...md`'s bucket rule 1 is respected -- nothing here names exams), **0012** (mobile
stack; see the mobile NOTE in the design §14), **0016** (the pepper is a secret held by
reference, `0016...md:95-119`), and **0038 point 4** (the realm-resolution chain is
unchanged).

## Decision

1. **A global, pointer-only directory.** One public-schema table,
   `tenant_login_directory`, maps `(email_key, tenant_id)`. `email_key` is a keyed
   HMAC-SHA256 of the normalised email (pepper held by environment-variable reference,
   INV-4), not plaintext. It carries no password, role, session, user id or profile field.
   It is separate from `tenant_memberships` (REQ-384), shares only the normalisation
   function `TenantMembership.normalize_subject_key/1`, and is never read by
   `AuthPipeline` or any authorisation decision.
2. **A credential-free discovery route on its own mount.**
   `POST /api/login-discovery`, forwarded from `Letflow.Router` ahead of the `/api/v1`
   forward, backed by its own router module and its own limiter. The email travels in the
   JSON body, never in a query string.
3. **Two disclosure modes, selected by application config.** `:uniform_plus_email`
   (Mode A: every request gets the same neutral response; the tenant list reaches the user
   only by email) and `:redirect_single` (Mode B: exactly one active-tenant match returns
   `{slug, display_name}`; several matches or none return the same neutral response, and
   the list for several is emailed). **Recommended default: Mode B**, switchable to Mode A
   by config. This is a **recommendation requiring `REVIEWER` and `SECURITY-REVIEWER`
   ratification**, because Mode B discloses "this email has an account in tenant Y" to an
   unauthenticated caller for single matches, bounded only by rate limiting. A third
   option, an unauthenticated tenant picker (`picker_unauth`), is **not built** (see
   "Alternatives rejected").
4. **Rate limiting is a precondition of the mount** (0028 §6): per-IP and global buckets
   checked by the first plug in the route's own chain, before the body is read, plus a
   per-email-key bucket that the endpoint consults after computing the key. The buckets are
   namespaced and independent of `/api/public`'s, and per-email state is bounded.
5. **The directory is populated inside the Identity context's own transactions**, never
   from router handlers: `create_user/2`, `provision_oidc_user/4`, `update_user_profile/3`
   and `update_user_status/3`. The `tenant_id` comes from
   `conn.assigns.auth_context.tenant_id` through a new required `:tenant_id` opt, never
   from a request parameter. An idempotent backfill reads each tenant schema's
   `users.email` through the derived `:prefix`.
6. **After login nothing changes.** Tenant resolution is the token's realm ->
   `resolve_tenant_by_realm/1`. `?realm=`, the stored slug, host lookup and the
   `bpm-default` fallback remain; the in-app switcher (REQ-384) is untouched. SPA
   precedence (decided here, to be ratified): explicit `?realm=` > stored slug >
   email-first screen (when the flag is on) > default-realm fallback.
7. **Scope fence.** No SSO across realms, no Keycloak identity-provider brokering
   (`kc_idp_hint` is deliberately unused), no Keycloak Admin client, no migration to
   Keycloak Organizations, no mail adapter (a port with a non-delivering default adapter
   ships; the real adapter is a separate decision), no per-vertical code.

## Amends

Each amendment is stated as: the quoted text, what changes, what remains unchanged.

### 0006 §3.3 ("What D1 forecloses") and §7 item 3

Quoted, `0006...md:212-221`:

> Per-tenant `users` permanently rules out any cross-tenant user lookup that does not
> start from a realm — e.g. a future "find my account by email across all tenants" login
> flow, or a single human identity spanning multiple tenants without a per-tenant row.
> R-Co's adp-04 already commits to single-tenant-per-user-row, and nothing in Letflow's
> roadmap requires otherwise, so this record accepts the foreclosure. Flagged explicitly
> so a future requirement needing multi-tenant users knows it must reopen this record
> rather than discovering the constraint by surprise.

Quoted, `0006...md:296-297` (§7 item 3):

> **Multi-tenant human identity** — foreclosed by §3.3, reopenable only by superseding
> this record.

*What changes.* The first example in §3.3, a login flow that finds accounts by email
across tenants, is permitted in exactly one bounded form: the directory lookup defined
here, whose output is a **tenant slug to route a browser to**, from which the ordinary
realm-start resolution then proceeds. It is still a cross-tenant lookup keyed on a
caller-supplied email; this record does not argue otherwise (the same candour as 0038's
"Why this record exists"). It is accepted only while every Standing prohibition below
holds, and only with the bounded inference stated below.

*What remains unchanged.* The second half of §3.3 and all of §7 item 3: no single human
identity spanning tenants, no shared or global `users` row, no mechanism by which one row
stands for more than one tenant. The directory is a routing index of where an email may
log in, never an identity record: no password, role, session, user id or profile field.
D1 (per-tenant `users`), D2, D3 and R5's realm<->tenant bijection are untouched; accounts
stay separate per realm. This record follows 0038's amend-by-reference form rather than
superseding 0006, because what §7 item 3 names (multi-tenant human identity) is not
created; whether the *lookup capability* also required supersession is the same question
0038's `REVIEWER` already answered in favour of amendment, and is flagged again in
"Open questions this record does not answer" (OQ-7).

### 0038 "What remains foreclosed, unchanged"

Quoted, `0038...md:91-103` (first and third bullets, the two this record touches):

> - A self-service "find my account(s) by email" flow reachable by an unauthenticated or
>   arbitrarily-authenticated caller.
> - A cross-tenant lookup keyed on anything the *caller* supplies at request time (as
>   opposed to derived from their own already-authenticated identity).

Also quoted, `0038...md:86-89`:

> A future requirement proposing self-service cross-tenant lookup, a caller-suppliable
> email parameter, or any mechanism that lets one `users` row stand in for more than one
> tenant is **still foreclosed** and still requires its own decision-record work — this
> record does not reopen §3.3 generally.

*What changes.* This record **is** that "own decision-record work", for one mechanism. The
first and third bullets no longer foreclose the directory lookup, and only it.

*What remains unchanged.* 0038's four-condition exception for `tenant_memberships` stays
exactly as written and is not widened: that table stays admin-write-only, non-self-service,
resolved from the authenticated caller's own identity, with no read path in `AuthPipeline`
(point 4, the realm-resolution chain). The second bullet ("any mechanism letting a single
`users` row serve more than one tenant schema, or letting `AuthPipeline`'s realm->tenant
resolution consult anything other than `tenants.idp_realm_id`") and the fourth
(no automatic or JIT-created `tenant_memberships` rows) remain foreclosed verbatim. The
directory is **not** `tenant_memberships`, is populated automatically by design (which is
precisely why it must not be merged into that table, see "Alternatives rejected"), and
`GET /api/v1/me/memberships` (REQ-384) is untouched.

### 0035 "no in-app login surface / no `/login` route"

Quoted, `0035...md:15-17`:

> ISSUE-FIXER's diagnosis confirmed exhaustively that no in-app login surface exists
> anywhere in `web/src`: no `LoginPage`/`LoginForm` component, no `/login` route in
> `web/src/router.tsx`.

Quoted, `0035...md:39-42` (the core decision):

> **Keycloak-hosted-only login is the correct, working, intended production architecture.**
> The SPA delegates login entirely to Keycloak's own hosted UI via a full-page redirect
> (`ProtectedRoute.tsx`'s `signinRedirect`). No in-app token-paste login screen exists, and
> none is planned.

*What changes.* The observation that the SPA has no login surface and no `/login` route is
amended to permit **one credential-free discovery route** (recommended path `/login`,
registered outside `ProtectedRoute`) whose page collects an email address and then
redirects to Keycloak.

*What remains unchanged.* The core decision stands in full: credentials are entered only on
Keycloak's hosted UI. The new page has no password field, no token field and never
receives a credential; the typed email goes to Keycloak only as `login_hint`. SH-01 and
OIDC-F-01 remain superseded (a token-paste screen is still not planned). The dead
`AuthContext.login(token)` scaffold (`0035...md:55-62`) remains dead and out of scope.

## Standing prohibitions

These bind every future requirement that touches the discovery route, the directory, or
the email-first page. Each is a structural property to be enforced by a test, not a policy
promise.

1. **`AuthPipeline` keeps its no-allowlist property**, permanently (0028). No public-path
   allowlist, bypass or `skip` option is added to it or to `ApiPipeline` for this feature.
   The route is public by being mounted on `Letflow.Router` ahead of the `/api/v1`
   forward, as `/api/tenant-config` is (`lib/letflow/router.ex:111`).
2. **`/api/public` stays handle-addressed, with no email and no tenant hint** (0028
   "Standing prohibitions", first bullet). The discovery lookup is never mounted under
   `/api/public`, never registered as a `Letflow.PublicRead` kind, and does not reuse
   `public_read_handles`.
3. **The lookup is a separate mount**: `forward("/api/login-discovery", to:
   Letflow.Routers.LoginDiscovery)`, declared before `forward("/api/v1", ...)`, with its
   own router, its own limiter table and its own tests.
4. **Closed response allowlist.** The response never contains `idp_realm_id`, `tenant_id`,
   an authority URL, a user id, a role, a count of accounts, a tenant status or any tenant
   field beyond **`slug` and `display_name`**. Response maps are hand-built with literal
   keys, never derived from an Ecto struct (INV-2; 0028's projection rule). The lookup
   function returns plain maps containing only those two fields, so the other fields are
   unrepresentable past the query. The SPA derives the authority from the existing
   `GET /api/tenant-config?realm=<slug>`.
5. **No bulk, list, search or paginated variant.** One email per request, `POST` only,
   email in the JSON body only, no array form, no cursor, no `GET`, no query-string email.
6. **No 401 and no 403 on the route**, producible by no input. The only statuses the route
   emits are `200`, `202`, `429` and the standard route-level `404`. A deactivated tenant or
   user is indistinguishable from an unknown email (no "exists but unavailable" disclosure;
   `Letflow.Plugs.TenantStatus`'s 403 is correct behind auth and wrong here, 0028).
7. **One database round trip before any response decision**, for matched, unmatched,
   inactive and malformed input alike; no early return ahead of that query (a malformed
   email is normalised to a fixed sentinel key), and no second query to improve a message
   (0028 point 4 and its "no second lookup" prohibition).
8. **The limiter is a precondition, not a follow-on** (0028 point 6): the first plug in the
   route's own chain, keyed on `conn.remote_ip` (never a forwarded header absent
   trusted-proxy configuration), checked before the body is read, so the `429` is
   input-independent. The per-email refusal returns the identical `429`.
9. **No raw email, email key, request body or IP address in logs, telemetry labels, audit
   records or error messages** (INV-4). Failures log fixed strings only.
10. **The directory is never consulted by an authenticated path.** It answers "where might
    this email log in", never "who is this request from" (0038 point 4, carried over).
11. **Adding a field to either success response shape, adding a third disclosure mode, or
    returning tenant names for the multi-match case is a security change, not a feature**:
    it needs `SECURITY-REVIEWER` sign-off against INV-2 and INV-5 in the requirement that
    adds it, and an amendment to this record.
12. **The notifier's egress is bounded**: a fixed message template carrying no text derived
    from the request other than the recipient address, at most one send per address per
    configured minimum interval, and no URL derived from tenant-controlled text (INV-9).
13. **The directory lands with its writers and its reader** (0028's REQ-056 rule): REQ-435
    ships the table together with every writer and the backfill; REQ-437 is the reader.

## Accepted bounded inference

Stated rather than claimed away, in the manner of `0028...md:124-138` and
`lib/letflow/routers/tenant_config.ex:53-56`. The statement is for the **recommended
default, Mode B**; Mode A's differences are noted at the end.

**What an unauthenticated caller CAN learn in Mode B** (each is bounded by the limiter):

1. **For an email address the caller supplies: whether it has an account in exactly one
   active, OIDC-bound tenant, and if so that tenant's `slug` and `display_name`.** This is
   the disclosure the feature exists to make, and it is the disclosure that requires
   ratification: anyone who knows or guesses an address can learn which one organisation it
   belongs to (for example that a named person is a user of tenant Y). It is the same class
   of information `GET /api/tenant-config` already gives for a guessed slug (a non-default
   realm and branding), and the same information the legitimate user sees on their own
   login page; the new element is that the *key* is a personal email rather than an
   organisation slug.
2. **By exclusion, that a neutral response means "not exactly one active tenant"**: the
   address is unknown, multi-tenant, only in an inactive or migrating tenant, only in a
   tenant without a bound realm, malformed, or the lookup failed. Nothing finer.
3. **That the platform is rate-limited** (a `429`), which discloses nothing about any
   address because the refusal is input-independent for the IP and global buckets and
   byte-identical for the per-email bucket.
4. **Which of a tenant's `slug`/`display_name` exist**, for active tenants that contain the
   probed address. Slugs and display names are low-sensitivity and already derivable from
   `/api/tenant-config`.

**What is explicitly NOT learnable:**

- Whether an address with accounts in **two or more** tenants is multi-tenant versus
  unknown (both return the byte-identical neutral response), and which tenants those are.
- Whether an address exists only in an **inactive** tenant, a **migrating** tenant, or a
  tenant whose realm binding is null (treated as unknown, decided in the single query).
- Whether a **user was deactivated** (the entry is removed; indistinguishable from
  unknown).
- Any tenant `id`, `idp_realm_id`, authority URL, tenant status, user id, role, display
  name of the user, count of accounts, or any field of any tenant schema.
- Any list of tenants, addresses or users: there is no list, search, bulk or paginated
  route, and no more than one address per request.
- Accounts that exist only in Keycloak and have never been seen by Letflow (the directory
  does not contain them; documented limitation).
- Anything through timing beyond the structural bound: the operation sequence (one HMAC,
  one limiter consult per bucket, exactly one database query, exactly one notifier-task
  submission) is identical for every input class; the wall-clock check is a sanity bound
  only.

**Mode A (`:uniform_plus_email`)** removes inference 1: every input class receives the same
neutral response, byte for byte, and the list reaches only the mailbox owner. Its costs are
UX and a dependency Letflow lacks (no mailer exists; `mix.exs` and `lib/` contain no mail
library, per the requirement's own grep). Until a mail adapter exists Mode A makes login
impossible for every email-first user, which is why it is not the recommended default.

**Mitigations, in order of strength:** the closed allowlist and single-match-only
disclosure; no bulk route; the per-IP, global and per-email buckets (a botnet can still
probe at the global rate, which is why the global bucket is deliberately tight and
configurable); uniform neutral outcomes for everything except the single-match case; no
second query and no early return; the notifier running off the request path; a per-address
minimum send interval; and the ability to switch to Mode A by configuration alone, without a
code change, if abuse is observed.

**Relationship to 0040.** 0040 states the position for *authenticated* list routes: there
is no per-actor rate limit and concurrency bounding (`Letflow.Plugs.Admission`) is the
operative protection, with `Letflow.Plugs.RateLimit` deferred to S4 (`0040...md:25-52`).
That reasoning does not transfer: this route is unauthenticated, and `Admission` is mounted
only inside `ApiPipeline` (`lib/letflow/plugs/api_pipeline.ex:88`, `:135`), which this route
never enters. 0040 neither authorises nor forbids this route's limiter. This record
**does not discharge 0040's deferred authenticated limiter** and does not touch
`ApiPipeline`; it states only that a future per-actor limiter, if it lands
mount-point-agnostic, may be reused here, as 0028 says of its own limiter
(`0028...md:147-149`).

**Governing limiter precedent: 0028 §6** (`0028...md:81-84`): rate limiting is a precondition
of mounting an unauthenticated route, enforced as the first plug inside the route's own
router, keyed on `conn.remote_ip`, before any resolution work. The new mount follows it and
uses its own limiter module, namespaced keys and its own ETS table, so a flood of one mount
cannot 429 the other (design §12). The existing
`Letflow.Plugs.PublicReadRateLimit.Bucket` is deliberately not modified: it has one table,
`:global | {:ip, ip}` keys, a check-then-write race and no eviction
(`lib/letflow/plugs/public_read_rate_limit/bucket.ex:31-33`, `:58-78`).

## Alternatives rejected

1. **"Always redirect an unknown email to `bpm-default`."** Rejected. It makes unknown
   emails look like default-tenant users and any non-default tenant's user look different:
   a prober learns "this email belongs to some non-default tenant" by *contrast*, for every
   non-default tenant, in every mode, with no way to switch it off. It is strictly more
   informative than Mode B's single-match disclosure and gives the unknown-email user the
   wrong realm (the ISS-0727 defect). Today's fallback to `bpm-default` for *no information
   at all* is retained only as rank 4 of the SPA precedence, where nothing was typed.
2. **`picker_unauth` (option C): return tenant names to the caller for any typed email.**
   Rejected as a production default and **not built**: it would disclose every tenant
   membership of any address to an unauthenticated caller and violates the spirit of INV-5.
   The requirement's phrase "only behind an explicit dev-only flag" is *not* adopted: the
   mode set is exactly the two values REQ-437 specifies, no response field can carry tenant
   names for the multi-match case, and a dev-only picker would need its own amendment to this
   record and a `SECURITY-REVIEWER` pass (Standing prohibition 11).
3. **Keycloak Organizations instead of a custom directory.** Not adopted *for this
   requirement set*, and not rejected as a long-term direction. Facts: `docker-compose.yml:26`
   runs `quay.io/keycloak/keycloak:26.2`, and the `ai-dala-infra` landscape documents record
   QA on 26.2 (`landscape/services.md:177`, `landscape/hosts/ubuntu-16gb-nbg1-1.md:217`);
   that Organizations is available from Keycloak 26.0 and must still be enabled and verified
   per deployment is external knowledge this design could not verify from the repo. Adopting
   it would mean migrating off realm-per-tenant, which touches 0002 and 0006 R5 (token realm
   -> tenant resolution, JIT provisioning, per-realm audience/issuer verification,
   `ProviderRegistry`) and ends the separate-accounts-per-realm model. A future ADR must
   choose; the directory is built so it can be retired (the SPA depends only on the
   discovery response contract). Carried as OQ-2.
4. **Extending or unifying `tenant_memberships`.** Rejected. Memberships are admin-linked
   switch targets created only by `PLATFORM_ADMIN` action (0038 point 2); the directory is
   system-populated for every active user. Unifying would make 0038's conditions 1 and 2
   false for the table. Different write authority, lifecycle (a membership persists, a
   directory entry vanishes on deactivation), key form (plaintext vs HMAC) and erasure
   obligations. One shared normalisation function, two tables.
5. **Mounting under `/api/public`.** Prohibited by 0028 (caller-supplied tenant hint).
6. **`GET` with the email in the query string.** Rejected: it would be written to access
   logs and proxies.
7. **Plaintext email key** (as `tenant_memberships.subject_key` is). Rejected for the
   directory because the lookup only needs equality on an address the caller just typed and
   delivery uses that typed address, so a stored plaintext index would be a cross-tenant
   email list outside every tenant's erasure reach for no functional gain. Trade-off in
   design §2.
8. **Deriving `tenant_id` from the `:prefix` opt** (reverse
   `TenantProvisioning.tenant_id_for_schema_name/1`) instead of a new `:tenant_id` opt.
   Rejected, with the rationale **corrected from the requirement's wording**: that reverse
   derivation is pure and performs no query (`lib/letflow/tenant_provisioning.ex:221-262`),
   so "an extra query" is not the reason. The reasons are that 0006 D2 deliberately retired
   prefix-derived tenant identity from write paths, and that prefix-derived identity cannot
   disagree with the prefix, so it can never *detect* a mismatch (0006 R2). The chosen
   design takes `tenant_id` explicitly from the authenticated context and asserts it equals
   the prefix's derivation, failing closed on a mismatch (design §3).
9. **Host-based tenant resolution ranked above the email-first screen.** Rejected: Letflow
   has no host->tenant binding by design (`lib/letflow/routers/tenant_config.ex:90-125`,
   REQ-076), so a host lookup never identifies a tenant.
10. **Keycloak Admin REST API as the backfill source now.** Deferred to a separate
    requirement: Letflow has no Admin client and would need per-realm admin credentials, a
    new INV-4 secret surface.
11. **Keycloak identity-provider brokering (`kc_idp_hint`).** Not applicable: no realm
    brokers an IdP today; `kc_idp_hint` is deliberately unused.

## Answers to REQ-434's open questions

| # | Question | Answer in this record |
|---|---|---|
| RQ-1 | Multi-tenant disclosure mode | Default **Mode B `:redirect_single`**, switchable to Mode A by config; option C not built. **Recommendation pending `REVIEWER` and `SECURITY-REVIEWER` ratification.** |
| RQ-2 | Backfill source | (1) each tenant schema's `users.email` via the derived prefix, now; (2) Keycloak Admin API as a separate future requirement. Consequence documented: an account that exists only in Keycloak and has never logged in is invisible to the directory (falls to `?realm=`/host/default fallbacks). The backfill iterates **all registered tenants**, not only active ones (design §4), so reactivation needs no re-run. |
| RQ-3 | Inactive tenant / user | An `:inactive` or `:migrating` tenant, or one with a null/empty `idp_realm_id`, contributes **no match** (decided in the single query via the join). A deactivated user's entry is removed in the same transaction, subject to the other-active-user rule. |
| RQ-4 | GDPR / PII retention | Keyed HMAC, not plaintext; same-transaction removal on deactivation and email change; FK `ON DELETE CASCADE` on tenant deletion; no row survives its source user except via the documented backfill race (design §4); no plaintext email in logs, audit or telemetry; erasure and pepper-rotation procedures in design §2. Proposed policy owner: `ORCH` (decision owner, as in 0028 and 0038). The human or legal controller is carried as OQ-3. |
| RQ-5 | Single-tenant / dev deployments | SPA build flag `VITE_EMAIL_FIRST_LOGIN`; absent or not `true` means off, i.e. today's behaviour exactly. Multi-tenant deployments set it to `true` in their build environment. E2E logins that pre-restore a session (`tryRestoreE2eSession`) never reach `ProtectedRoute`'s redirect branch and are unaffected either way. |
| RQ-6 | Per-email throttle / email-bombing | Per-email request bucket (REQ-436) **and** a per-address send bucket with a fixed minimum interval; fixed message template; send attempts bounded in concurrency. |
| RQ-7 | Keycloak Organizations | Not adopted now; directory built retire-able; future ADR (OQ-2). |

## Consequences

- REQ-435 (data layer and population), REQ-436 (limiter), REQ-437 (endpoint, notifier
  port) and REQ-438 (SPA) are scheduled by the design's §15 work packages. `SECURITY-REVIEWER`
  is a mandatory gate on this record and on REQ-435, REQ-436 and REQ-437.
- A new required deployment secret appears (`LETFLOW_LOGIN_DIRECTORY_PEPPER`); a deployment
  without it fails at boot (design §2). Provisioning it in each environment is an
  infrastructure action outside this repository (OQ-6).
- Until a real mail adapter exists, every path that depends on email delivery degrades to the
  neutral response; in Mode B a multi-tenant user reaches a neutral outcome that sends
  nothing (OQ-9).

## Open questions this record does not answer

- **OQ-1. Ratification of the disclosure default.** Whether Mode B is acceptable as the
  default, or Mode A (or Mode B gated by a deployment flag) is required, is for `REVIEWER`
  and `SECURITY-REVIEWER`. This record states the recommendation and the bounded inference;
  it does not decide the risk appetite.
- **OQ-2. Directory versus Keycloak Organizations.** A future ADR chooses; this record only
  guarantees the directory is retire-able.
- **OQ-3. Legal basis and human owner of the directory's personal data.** The directory is a
  cross-tenant index of personal data held outside any tenant schema. The lawful basis, the
  retention period and a named human or organisational controller are not decidable inside
  this pipeline.
- **OQ-4. Mail adapter selection and credential ownership** (Swoosh/Bamboo/SMTP or an
  external transactional provider; INV-4 secret). Separate decision and requirement.
- **OQ-5. Client IP behind a reverse proxy.** There is no trusted-proxy configuration in the
  tree (`grep` of `lib/letflow/plugs/` and `config/` finds none), so behind nginx
  `conn.remote_ip` may be the proxy address and the per-IP bucket would collapse into the
  global one. 0028 carries the same limitation; an owning requirement for trusted-proxy
  handling is not part of this record.
- **OQ-6. Pepper provisioning and rotation.** Who provisions `LETFLOW_LOGIN_DIRECTORY_PEPPER`
  in QA and production (the `ai-dala-infra` secrets inventory is outside this repository),
  and whether a dual-pepper rotation window is wanted instead of the rebuild procedure.
- **OQ-7. Whether 0028's "exactly one unauthenticated read surface" sentence needs a one-line
  cross-reference to this record**, and whether the `0006` §7 item 3 wording
  ("reopenable only by superseding this record") required supersession rather than the
  0038-style amendment used here. Left to `REVIEWER`; this record edits neither.
- **OQ-8. Realm "Login with email" precondition.** `login_hint` pre-fills the username field
  only; realms whose users log in by username need Keycloak's "Login with email" enabled
  for a typed email to work. `priv/keycloak/realms/bpm-default.json` does not set
  `loginWithEmailAllowed` (zero occurrences), and Keycloak's default was not verified from
  the repository. UAT must check each realm (`bpm-default`, `bilimbaga` on QA).
- **OQ-9. The multi-tenant dead end while no mailer exists.** Whether to ship a mail adapter
  before enabling the flag in a multi-tenant deployment, or to add a manual
  organisation-code entry on the email-first page, or both.
- **OQ-10. JIT directory-write failure policy.** The design makes the directory write part of
  the JIT user-insert transaction (a directory fault fails the first login, fail-closed on
  index integrity) rather than best-effort after commit (a fault leaves a hole until the next
  backfill). `REVIEWER` to confirm the trade-off.
- **OQ-11. Shared email strings across different humans.** As in 0038 OQ-1: the directory
  maps an email *string* to tenants, not an identity. Two humans sharing an address in two
  tenants are indistinguishable to it, which is harmless for routing.
- **OQ-12. Pre-existing unbounded growth in `PublicReadRateLimit.Bucket`.** Its `{:ip, ip}`
  keys have no eviction. Not introduced or fixed here; flagged so it can be filed.

## Sign-off

Placeholders only. No verdict below has been given; none may be inferred from this file's
`Status: decided` line.

- **CODE-DESIGN-VALIDATOR:** `PENDING`
- **SECURITY-REVIEWER:** `PENDING` (mandatory gate on this record and on REQ-435/436/437;
  must assess INV-1, INV-2, INV-4, INV-5, INV-6, INV-7, INV-8, INV-9 and confirm INV-3 does
  not apply; must ratify or reject the Mode B default)
- **REVIEWER:** `PENDING` (decision-record consistency: the three amendments, the 0028
  cross-reference question, the 0006 supersession-versus-amendment question, and the
  disclosure-mode default)
