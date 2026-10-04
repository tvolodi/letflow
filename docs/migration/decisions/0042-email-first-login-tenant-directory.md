# 0042 — Email-first login: a platform tenant-login directory and a credential-free, email-keyed discovery route

Status: decided

Date: 2026-10-04. Drafted by `CODE-DESIGNER` (REQ-434). Owner: `ORCH`. Gates:
`CODE-DESIGN-VALIDATOR` PASS, `SECURITY-REVIEWER` RATIFIED and `REVIEWER` RATIFIED (see
"Sign-off" at the end; verdicts dated 2026-10-04). The disclosure-mode default (Mode B) was
ratified by `SECURITY-REVIEWER` and `REVIEWER` on the conditions recorded there; the product
questions carried forward in "Open questions this record does not answer" remain for the user.

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
4. **Rate limiting is a precondition of the mount** (0028 §6): **per-IP first, then global,
   consumed only for IP-admitted requests**, checked by the first plug that does work in the
   route's own chain, before the body is read, plus a per-email-key bucket that the endpoint
   consults after computing the key. Refused requests never consume the global bucket, so one
   source cannot drain it (design §12.2). IPv6 sources are aggregated to their /64. The buckets are
   namespaced and independent of `/api/public`'s, and state is bounded by two caps (design §12.3).
   The IP is the **resolved client IP** (Decision 9), not blindly `conn.remote_ip`.
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
8. **Enablement preconditions (binding).** The SPA flag `VITE_EMAIL_FIRST_LOGIN` may be set to
   `true` in any environment other than local dev only when all hold, each recorded in the
   enabling change: (a) the trusted-proxy client-IP requirement (Decision 9) is done, configured
   and UAT-verified; (b) **OQ-3 is answered** (named controller, lawful basis, retention), (c) the
   multi-tenant dead end is resolved (OQ-9), (d) realm "Login with email" is verified (OQ-8).
   The backend additionally refuses to boot with the mount enabled in `:prod` and no trusted-proxy
   list (design §12.6).
9. **Trusted-proxy client IP is a dependency, not an open question.** In the real topology
   (Cloudflare -> nginx -> published container port -> Bandit, `deploy/nginx/letflow-test.conf`,
   `deploy/docker-compose.test.yml`) `conn.remote_ip` is the proxy hop and nothing in the tree
   resolves the visitor address. A new requirement (REQ-CIP, id to be assigned) adds
   `Letflow.Plugs.ClientIp`: it honours exactly one `X-Real-IP` header only when the TCP peer is in
   a deployment-configured CIDR list (`LETFLOW_TRUSTED_PROXIES`, empty by default), never
   `X-Forwarded-For`, and nginx is configured with realip so `$remote_addr` is the visitor. It is
   a `depends_on` of REQ-436 and REQ-437 (design §12.6, §15.0, §0.3 D11). This supersedes OQ-5.

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
8. **The limiter is a precondition, not a follow-on** (0028 point 6): the first plug that does
   work in the route's own chain, keyed on the **resolved client IP** (`Letflow.Plugs.ClientIp`:
   `conn.remote_ip`, replaced by `X-Real-IP` only when the TCP peer is in the configured trusted
   proxy list; never `X-Forwarded-For`; Decision 9), checked before the body is read, so the `429`
   is input-independent. **Order is per-IP first; the global bucket is consumed only by
   IP-admitted requests**, so a refused request never drains it. The per-email refusal returns the
   identical `429`.
9. **No raw email, email key, request body or IP address in logs, telemetry labels, audit
   records or error messages** (INV-4). Failures log fixed strings only. This **includes
   Ecto's `:debug` query log**, which prints bound parameters: every `Repo` call on a directory
   table, or carrying a normalised email or `email_key` as a bound value (lookup, upsert, the
   other-active-user check, removal, advisory lock, backfill), passes `log: false`, proven by a
   `capture_log(level: :debug)` test and a grep guard (design §3.9). Outcome counters carry only
   fixed-atom labels (design §12.7).
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
14. **Any future user-deletion path must call the directory removal.** There is no
    `Identity.delete_user` today (design §0.1), so a deletion needs no hook now; but any
    requirement that adds a path deleting a `users` row (hard delete, GDPR erasure, tenant-user
    purge, an admin or Mix task) must, in the same transaction, invoke
    `Letflow.LoginDirectory.remove_entry_if_unreferenced/3` for the deleted user's email, with a
    test proving no entry survives. A deletion path that bypasses it leaves a ghost routing entry
    for a person who no longer exists, which is an erasure failure. Tenant-row deletion is covered
    by the FK cascade; a deletion that removes only user rows is not.

## Accepted bounded inference

Stated rather than claimed away, in the manner of `0028...md:124-138` and
`lib/letflow/routers/tenant_config.ex:53-56`. The statement is for the **ratified
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
code change, if abuse is observed. **The kill switch is observable (C-1):** non-identifying
outcome counters (`:tenant`, `:accepted`, `:rate_limited_ip|global|email`, fixed-atom labels, no
email/key/IP/slug; design §12.7) let an operator see a rise in single-match disclosures or in
refusals and trigger the switch. **The per-IP bound this inference rests on holds only with the
trusted-proxy client IP (Decision 9);** without it every visitor shares one bucket, which is why
it is a `depends_on` and an enablement precondition (Decision 8), not a note.

**Accepted residuals (stated, not claimed away).**

1. **Targeted per-email lockout (C-2).** Anyone who knows a victim's address can keep that
   address's per-email bucket exhausted (about one request per minute, from any IPs), so the
   victim's email-first attempt gets a `429`. The response is identical for known and unknown
   addresses, so nothing is disclosed. Accepted because dropping the per-address bucket removes
   the email-bombing control (RQ-6). Bounded by: effect limited to that address on the email-first
   path; the SPA's 429 state, and the page in every state, offers the **organisation-code route**
   (`?realm=`, rank 1 of the precedence, which bypasses discovery); the `:rate_limited_email`
   counter makes sustained targeting visible.
2. **New-IP refusal at the IP-key cap.** A flood from more than `max_ip_keys` distinct /64
   networks within about 50 seconds causes previously unseen sources to be refused (fail closed,
   the global bucket not consumed); existing sources are unaffected. A flood of that size can
   already drain the global bucket at its refill rate, so this adds no new capability.
3. **Distributed flood at the global rate** (unchanged from the original inference): refused
   requests no longer drain the global bucket (D-1 fix), but a flood of many distinct sources can
   still consume admitted tokens and 429 legitimate users until it stops.

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
cannot 429 the other (design §12). This is the "mount-point-agnostic successor" option of
REQ-434 item 4, not reuse: shared are the token-bucket algorithm, `conn.remote_ip` keying and
the `Response.rate_limited` halt convention; new are the table, key namespace, lossless eviction,
key cap and atomic check-and-write (design §0.3 D10, §12.1). The existing
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

- REQ-CIP (trusted-proxy client IP, new, id to be assigned), REQ-435 (data layer and
  population), REQ-436 (limiter; depends on REQ-CIP), REQ-437 (endpoint, notifier port;
  depends on REQ-CIP) and REQ-438 (SPA) are scheduled by the design's §15 work packages.
  `docs/requirements.yaml` is amended by `ORCH`/`REQ-ANALYST` (design §0.3 D11). `SECURITY-REVIEWER`
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
- **OQ-3. Legal basis and human owner of the directory's personal data. BLOCKING PRECONDITION
  for enabling the flag outside local dev (C-5, Decision 8).** The directory is a cross-tenant
  index of personal data held outside any tenant schema (keyed HMACs of email addresses are
  still personal data while the pepper exists). The lawful basis, the retention period and a
  named human or organisational controller are not decidable inside this pipeline and are **not
  answered by this record**. **Owner:** the project owner (a human); `ORCH` escalates and, once
  answered, records the answer here and in the enabling change. **Until then** the flag stays off
  in QA/production builds; the backend mount is disabled by default in `:prod` (design §12.6),
  so building and merging the code is not blocked, enabling it is. What the design supplies
  toward the answer: no plaintext, same-transaction removal on deactivation, FK cascade on tenant
  deletion, a documented rebuild/erasure procedure (design §2.4), and Standing prohibition 14.
- **OQ-4. Mail adapter selection and credential ownership** (Swoosh/Bamboo/SMTP or an
  external transactional provider; INV-4 secret). Separate decision and requirement.
- **OQ-5. Client IP behind a reverse proxy. RESOLVED by Decision 9 (rework 2)** as a new
  requirement REQ-CIP, a `depends_on` of REQ-436/437. Verified: no client-IP handling exists in
  the tree (only `PublicReadRateLimit` reads `conn.remote_ip`); the real topology is Cloudflare
  -> nginx (sets `X-Real-IP $remote_addr`, no realip directive, so `$remote_addr` is the
  Cloudflare edge) -> published container port -> Bandit. Still open inside it: that Cloudflare
  supplies `CF-Connecting-IP` and its ranges (external knowledge), the container-side peer
  address, and QA's nginx vhost (outside this repository); the implementer and UAT verify them
  and `ORCH` must register REQ-CIP in `docs/requirements.yaml` and amend both `depends_on`
  lists. 0028's `/api/public` keeps the same limitation (not changed here).
- **OQ-6. Pepper provisioning and rotation.** Who provisions `LETFLOW_LOGIN_DIRECTORY_PEPPER`
  in QA and production (the `ai-dala-infra` secrets inventory is outside this repository),
  and whether a dual-pepper rotation window is wanted instead of the rebuild procedure.
- **OQ-7. Whether 0028's "exactly one unauthenticated read surface" sentence needs a one-line
  cross-reference to this record**, and whether the `0006` §7 item 3 wording
  ("reopenable only by superseding this record") required supersession rather than the
  0038-style amendment used here. **Answered by `REVIEWER` (2026-10-04):** yes, a one-line cross-reference is needed and was added to
  0028 with this record (it states the mount is separate and not a second read surface); the
  amend-by-reference form (not supersession) was accepted for `0006` §7 item 3.
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
- **OQ-12. Pre-existing defects in the `/api/public` limiter.** `PublicReadRateLimit.Bucket`'s
  `{:ip, ip}` keys have no eviction, and `PublicReadRateLimit.call/2` consumes the global bucket
  before the per-IP bucket (the same ordering defect fixed here for the new mount, D-1;
  `public_read_rate_limit.ex:36-52`). Not introduced or fixed here; flagged so both can be filed.
- **OQ-13. Plaintext emails still reach debug logs outside the directory.** The tenant `users`
  insert/update queries bind the plaintext email and Ecto logs them at `:debug` regardless of
  this feature, and PostgreSQL's own `log_statement` settings are deployment configuration
  outside this repository. This record fixes only the directory's queries (Standing prohibition
  9, `log: false`); `ORCH` to file the broader item and add a deployment check.

## Sign-off

Verdicts recorded by the gate agents on 2026-10-04 (history of failed rounds kept inline).

- **CODE-DESIGN-VALIDATOR:** `PASS` (2026-10-04, round 4). The round 3 defect is fixed, verified against `router.ex:111-137` (static unconditional `forward/2` mounts, so a function plug `enabled_gate/2` as the first plug of `Letflow.Routers.LoginDiscovery` is the buildable place) and `Letflow.Api.Response.not_found/1`. The gate runs before `ClientIp` and the limiter, the `:disabled` counter is always emitted with only the `outcome` key, and design 5.1, 12.6, 12.7 and 15.3 (mount-switch test) agree; no limiter, `Repo` or `ClientIp` work and nothing leaks. The 17 table is fixed, no implementation code is present, REQ-434 acceptance criteria still hold, and the diff scope is the two files. History: round 3 `FAIL` (disabled-mount gate unspecified, 17 table break); round 2 `PASS`; round 1 failed. Round 4 supersedes round 3.
- **(superseded) CODE-DESIGN-VALIDATOR round 3:** `FAIL` (2026-10-04, after rework 2). Citations for the new D-1/D-2/D-3 claims verified against code (public_read_rate_limit.ex:36-52, letflow-test.conf:23-24, router.ex mounts, `log: false` at sandbox_pool.ex:964 and tenant_provisioning.ex:386); no implementation code; REQ-CIP is described as a dependency to be registered; diff scope is the two files. One defect: the disabled-mount `404` gate (design 5.1, 12.6, D12) names no plug or module, no position relative to `ClientIp`, and its counter is "optional" (12.7), so it is not buildable unambiguously. Cosmetic: the 17 table is split by a blank line before Q16. Prior history: round 2 `PASS`; round 1 failed (guard compared the tagged tuple from `schema_name_for_tenant/1` to a string; JIT transaction ignored the username-conflict recovery; the rate-limit mount departed from requirement item 4 without a discrepancy row), fixed in round 2 (design 3.2 `{:ok, ^prefix}` guard, 3.5 savepoint-mode insert, 0.3 D10). Round 3 supersedes the round 2 `PASS`.
- **(superseded) CODE-DESIGN-VALIDATOR round 2:** `PASS` (2026-10-04). Round 1 failed (guard compared the tagged tuple from `schema_name_for_tenant/1` to a string; JIT transaction ignored the username-conflict recovery; the rate-limit mount departed from requirement item 4 without a discrepancy row). Round 2 verified against code: design 3.2 now matches `{:ok, ^prefix}` per `tenant_provisioning.ex:212-219` with `:invalid_tenant_id` and `:tenant_prefix_mismatch` outcomes; 3.5 specifies a savepoint-mode insert so `get_by_username/2` and `re_select_on_conflict/3` (`identity.ex:1811-1846`) run in a live transaction, with a required username-race test in 15.1; 0.3 D10 records the successor-module reading of item 4. All REQ-434 acceptance criteria re-checked with no regression; no implementation code present (signatures, type shapes, prose only).
- **SECURITY-REVIEWER:** `RATIFIED` / `PASS` (2026-10-04, re-run after rework 2). Mode B `:redirect_single` default ratified. D-1 discharged (design 12.2: per-IP consumed first, global only for IP-admitted requests, /64 aggregation, two separately derived key caps, ordering test asserts global tokens untouched). D-2 discharged (12.6/15.0/0042 Decisions 8-9: `ClientIp` honours a single `X-Real-IP` only from a peer in a deployment CIDR list, never `X-Forwarded-For`, every parse/arity failure falls back to `remote_ip` = stricter shared bucket, never a spoofable one; `:prod` boot raises when the mount is enabled with an empty list; mount default-off in prod, Dockerfile builds `MIX_ENV=prod`; REQ-CIP is a depends_on of REQ-436/437). Unverified U3 (Cloudflare header/ranges) and U4 (container peer address) are bounded by an explicit UAT precondition and by fail-stricter defaults, not assumed. D-3 discharged (3.9: `log: false` on every directory Repo call, grep guard plus `capture_log(level: :debug)` test, telemetry still fires). C-1 (12.7 counters), C-2 (12.8 plus SPA 429 `?realm=` control, 11.5), C-3 (prohibition 14), C-4 (13 closure-form start_child plus raise test), C-5 (11.3 and prohibition 8, OQ-3 gate) discharged. INV-1/2/4/5/7/8/9 PASS in design, INV-3 N/A. Non-blocking advice for REQ-CIP: reject or loudly warn on a `/0` trusted CIDR in `:prod`. History: earlier same-day verdict was FAIL (D-1..D-3, C-1..C-5), superseded by this record.
- **REVIEWER:** `RATIFIED` (2026-10-04). Evidence: branch diff vs origin/main touches only
  this file and `lib/letflow/design/req434-...md` (2 files). Quotes of 0006 §3.3/§7.3, 0038
  "remains foreclosed" and 0035 lines 15-17/39-42 match the source text; amendments are
  minimal, amend-by-reference (0038 form), and keep the 0038 four-condition exception, 0006 D1
  and R5 untouched; 0002, 0012, 0016, 0022 and 0040 are not contradicted (0040's deferred
  authenticated limiter is explicitly not discharged). Limiter design is idiomatic OTP: a
  supervised GenServer owning the ETS table (Infrastructure child, count tests updated),
  lossless idle-row sweep, bounded key cap with a boot-time invariant, CAS consume, and a
  dedicated `Task.Supervisor` for notifier sends (no bare spawn). Scope stays within
  REQ-434..438; no behaviours or macros ahead of need. Open questions RQ-1..RQ-7 each carry a
  stated default or are carried forward as OQ-1..OQ-12. The design now addresses the
  CODE-DESIGN-VALIDATOR defects (`{:ok, prefix}` guard, savepoint-mode insert, D10 row).
  Ratified: the Mode B default (conditional on `SECURITY-REVIEWER` concurrence, which owns the
  risk appetite), amendment-not-supersession for 0006 §7.3 (OQ-7), and in-transaction JIT
  directory write (OQ-10). 0028 cross-reference: YES, add one line to 0028's "exactly one
  unauthenticated read surface" sentence noting that `POST /api/login-discovery` (0042) is a
  separate, credential-free, non-resource lookup mount; ORCH/DOC-UPDATER to apply, not edited
  here. Non-blocking: `Status: decided` header precedes gate completion; update the line 5-8
  gate-pending text once SECURITY-REVIEWER signs.
