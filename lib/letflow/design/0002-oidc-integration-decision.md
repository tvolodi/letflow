# Design: REQ-011 — decision-record research (0002-oidc-integration.md)

**Requirement:** REQ-011 (`docs/requirements.yaml`)
**Target artefact ELIXIR-DEV writes into:** `docs/migration/decisions/0002-oidc-integration.md`
  (Decision + Reasoning sections only — the Question section already exists, do not
  rewrite it)

## What kind of "design" this is

REQ-011 produces a decision record, not application code. There is no Ecto schema,
`gen_statem` shape, or DB migration in scope. This document is the structured research
ELIXIR-DEV needs so that writing the Decision/Reasoning sections is transcription
against a settled comparison, not open-ended research done under a content-writing
task — matching the precedent set by
`lib/letflow/design/0001-web-framework-decision.md` for REQ-010. CODE-DESIGN-VALIDATOR
should treat "every acceptance criterion maps to a concrete design element" as: every
acceptance criterion below has a resolved (not "TBD") answer in this document.

## 1. Ground truth on R-Co's actual `src/identity/` and `src/oidc/` contents (verified this session)

PROVENANCE (historical, not current decision authority):
The skeleton's Question section (and REQ-011's `description`) describe `src/identity/`
as "18 files, including `manager.zig` for JIT provisioning, `jwks_cache.zig`,
`role_registry.zig`, `provider/` for Keycloak specifics" — implying a flat directory of
18 files. **That is not the actual shape.** Verified directly via `ls`/`find` against
`C:\Users\tvolo\dev\ai-dala\R-Co\src\identity\` and `...\src\oidc\` this session (not
inferred, not trusted from any prior written source, following the same discipline
0001's design used when it caught the route-count error):

### 1.1 `src/identity/` — 18 files total, but nested, not flat

PROVENANCE (historical, not current decision authority):
Top level (4 files):
```
onboarding.zig   registry.zig   role_registry.zig   service.zig
```
plus a `provider/` subdirectory containing 14 more `.zig` files:
```
src/identity/provider/
├── bootstrap.zig
├── errors.zig
├── idp_test_root.zig
├── interface.zig
├── manager.zig            ← JIT-adjacent orchestration (see §2.1 — thinner than the name implies)
├── mod.zig
├── test_oidc02_keycloak_adapter.zig
├── types.zig
├── adapters/
│   ├── keycloak/
│   │   ├── config.zig
│   │   ├── provider.zig   ← the actual Keycloak-specific adapter (HTTP transport, admin token caching)
│   │   └── urls.zig
│   └── stub/
│       └── provider.zig   ← non-Keycloak stub implementation of the same interface
└── oidc/
    ├── jwks_cache.zig      ← the actual JWKS cache (see §2.2)
    └── standards_verifier.zig
```
PROVENANCE (historical, not current decision authority):
4 (top-level) + 14 (nested) = **18 files**, confirmed by `find src/identity/ -name
"*.zig" | wc -l` → `18`. The requirement's stated count (18) is correct; what's wrong
is the implied flat structure — `manager.zig` lives at
`src/identity/provider/manager.zig`, not `src/identity/manager.zig`, and
`jwks_cache.zig` lives at `src/identity/provider/oidc/jwks_cache.zig`, not
`src/identity/jwks_cache.zig`. `role_registry.zig` is the one file that *is* flat,
directly under `src/identity/`, exactly as the skeleton says.

### 1.2 `src/oidc/` — 13 files, flat, count confirmed correct

PROVENANCE (historical, not current decision authority):
```
agent_lifecycle.zig      claim_mapping.zig       coexistence_auth.zig
identity_stability.zig   jit_provisioning.zig     migration_helper.zig
realm_deletion.zig       realm_provisioning.zig   realm_seed.zig
realm_tenant_binding.zig tenant_claim_source.zig  test_token_helper.zig
verification_benchmark.zig
```
PROVENANCE (historical, not current decision authority):
13 files, confirmed by `find src/oidc/ -name "*.zig" | wc -l` → `13`, matching both the
skeleton and REQ-011's `description`. **`jit_provisioning.zig` is here, in `src/oidc/`,
not in `src/identity/`** — the requirement's framing ("JIT user provisioning
(`src/identity/manager.zig`)") points at the wrong file for where the actual JIT logic
lives; `identity/provider/manager.zig` is a thin delegation shim (see §2.1), while
`src/oidc/jit_provisioning.zig` is the real orchestration layer.

PROVENANCE (historical, not current decision authority):
**Resolution ELIXIR-DEV must apply, not re-derive:** when the Reasoning section cites
"JIT user provisioning," cite **`src/oidc/jit_provisioning.zig`** (the orchestration
logic) together with **`src/identity/registry.zig`'s `createOrGetJitOidcUser`**
(the actual idempotent insert, called by the orchestrator) as the behavior, not
`src/identity/manager.zig` alone — `manager.zig`'s `provisionUser` is a one-line
delegation to whatever `IdentityProvider` is configured (see §2.1), it does not itself
implement JIT semantics. This satisfies acceptance criterion 2 ("names at least 2 real
R-Co identity behaviors... by filename") more precisely than the skeleton's own
Question section does. Do not silently correct the skeleton's Question section text
itself (out of this requirement's file scope, same boundary 0001's design drew for the
route-count discrepancy) — file it as an issue instead (see §6).

## 2. What the key R-Co source files actually do (read from source, not from memory of typical OIDC implementations)

### 2.1 `src/identity/provider/manager.zig` — thin delegation, NOT the JIT logic itself

Read in full (170 lines). `Manager` is a struct holding an optional `provider:
?interface.IdentityProvider`, an `auth_mode` (`local_only | dual_accept | oidc_only`),
and expected audience/issuer. Every public method (`verifyBearerToken`,
`provisionUser`, `provisionRealm`, `grantRoles`, `provisionClient`,
`upsertFederation`, `deleteFederation`, `listAuditEvents`, `createProtocolMapper`,
`toggleRealm`, `deleteRealm`, `updateClient`, `checkRealmExists`, ...) is a one-line
forward call to `self.provider.<method>(...)`, returning `error.NotImplemented` if no
provider is configured. The one piece of real logic in this file is
`looksLikeJwt/1` + `isJwtSegmentLexicallyDecodable/1` — a lexical (non-cryptographic)
pre-check used by `shouldVerifyExternalToken/1` to decide whether an incoming bearer
token even looks like a JWT before attempting OIDC verification (used to support
`dual_accept` mode: local password auth and OIDC bearer tokens both accepted on the
same endpoint). `verifyBearerTokenWithIssuer/2` is the multi-realm fallback entry
point noted in its own doc-comment (`ISS-UAT-V6-002`): after a caller has resolved
which tenant realm a token's issuer claims to belong to (via a DB lookup elsewhere),
this re-verifies the token's signature against that specific tenant's issuer URL.

**Implication for the Decision:** `manager.zig` is a provider-abstraction facade, not
where JIT provisioning is implemented. The Reasoning section should cite it (if at
all) as "the multi-provider dispatch point, including the multi-realm
issuer-re-verification fallback (`verifyBearerTokenWithIssuer`)" rather than as "JIT
provisioning" — see §1.2's resolution for which file to cite for JIT specifically.

PROVENANCE (historical, not current decision authority):
### 2.2 `src/identity/provider/oidc/jwks_cache.zig` — the actual JWKS cache

Read in full (141 lines). `JwksCache` is an in-memory (not persisted, not
distributed) `std.StringHashMap(JwksCacheEntry)` keyed by JWKS URI string, explicitly
documented as **not thread-safe** ("callers must hold an external mutex if the
Adapter is accessed concurrently" — a single-threaded-per-instance assumption, notable
because Elixir/BEAM's concurrency model is the opposite default). Behavior:
- `lookupKid(uri, kid, now)` returns `true`/`false` if a valid (non-stale) cache entry
  exists and the kid is/isn't present, or `null` if the entry is absent or stale
  (`now - fetched_at >= ttl_seconds`) — `null` signals "caller must fetch and call
  `store()`."
- `store(uri, jwks_body, now)` parses the raw JWKS JSON, extracts each key's `kid`,
  replaces any existing entry for that URI.
- `isRateLimited(now)` / `markRefreshed(now)` implement a **global** (not per-URI)
  minimum-refresh-interval rate limiter across all JWKS fetches, guarding against
  refetch storms if many unknown `kid`s arrive in a burst.
- No key-material caching beyond `kid` strings — the actual public key fetch/parse for
  verification happens elsewhere (`standards_verifier.zig`, not read in full here);
  this file only tracks "is this kid known" to decide whether a refetch is warranted.

**Implication for the Decision:** this is a hand-built, single-process, TTL + global
rate-limited JWKS `kid` presence cache with explicit non-thread-safety documented in
its own comment — a design that predates/ignores BEAM concurrency primitives entirely
(it would need `Agent`/`ETS`/`:persistent_term` wrapping to be safe under Elixir's
default concurrent-request model, not a direct port).

PROVENANCE (historical, not current decision authority):
### 2.3 `src/identity/role_registry.zig` — per-tenant custom role registry (IDN-05)

Read in full (280 lines), doc-comment header cites design artefact
`src/design/idn05-role-registry.md`. `TenantRoleStore` wraps a `tenant_role` SQL table
(columns: `id`, `name`, `group_id`, `created_at`) with `listRoles/1` and
`upsertRole/3` (parameterized SQL throughout — `$1`/`$2` positional params, explicit
"no SQL string interpolation" comments matching Letflow's own INV-7 rule). A
module-level function `resolveRoleInTx(conn, name)` resolves a role name to a group
UUID **inside an already-open DB transaction**, called from `applyTransition` in
`src/engine/instance.zig` (S3 territory, not S1) — errors are swallowed to `null`
("unbound") rather than propagated, so a role-lookup failure never blocks a task
transition. **This module has no direct call-site cross-reference to any file in
`src/oidc/`** (verified: `grep -rn "role_registry" src/oidc/*.zig` → no matches) — it
is a standalone, tenant-scoped custom role/group mapping used by the workflow engine
at transition time, not part of the OIDC token-verification or claim-mapping pipeline
itself. Whatever role information an OIDC claim carries (see §2.5) is a separate
concept from this registry; nothing read in this session shows the two being
reconciled automatically.

**Implication for the Decision:** "custom role registry" (REQ-011's acceptance
criterion language) names a workflow-engine-facing per-tenant role→group table with
transactional resolution semantics tied into `applyTransition`, not an OIDC-claim role
mapper. A library integration would need a **separate**, hand-written
`TenantRoleStore`-equivalent regardless of OIDC library choice — this is Letflow/S3
domain logic with a SQL-transaction coupling no third-party OIDC library would (or
should) provide.

PROVENANCE (historical, not current decision authority):
### 2.4 `src/identity/provider/adapters/keycloak/provider.zig` — the actual Keycloak adapter

Read the first 80 lines (of a 65KB+ file, per the earlier `ls -la`, i.e. this is one of
the largest files in the whole subtree). Confirms: an `HttpTransport` abstraction
(caller-injected `sendFn`), a `SecretResolver` abstraction (caller-injected, for
Keycloak client-secret retrieval — i.e. secrets are not read directly from env/file by
this module, consistent with S6's `src/secrets` being a separate subsystem), a `Clock`
abstraction (caller-injected, for testability), and a `CachedAdminToken` struct
(admin API token caching — separate from the JWKS cache in §2.2; this caches
Keycloak's **admin REST API** bearer token used for realm/user/client provisioning
calls, not end-user JWTs). Imports `../../oidc/jwks_cache.zig` and
`../../oidc/standards_verifier.zig` directly, confirming the JWKS cache from §2.2 is
consumed here as part of the Keycloak-specific adapter, not the provider-agnostic
`interface.zig`.

**Implication for the Decision:** the Keycloak adapter is substantial (65KB+,
largest file examined this session) and couples together HTTP transport, admin-token
caching, JWKS caching, and standards-based ID-token verification behind
caller-injected abstractions (transport/secrets/clock) for testability — a
non-trivial amount of hand-rolled infrastructure regardless of which OIDC library
Letflow picks for the token-verification piece, because none of this admin-API
provisioning surface (realm/client/user management via Keycloak's Admin REST API) is
something either candidate library provides (see §3).

PROVENANCE (historical, not current decision authority):
### 2.5 `src/oidc/jit_provisioning.zig` — the actual JIT provisioning orchestration

Read the first 120 lines (of a larger file). Doc-comment header: "OIDC-09 — JIT user
provisioning orchestration... bridges the OIDC-08 claim-mapping output
(`IdentityContext`) and the ADP-04a identity service (`createOrGetJitOidcUser`) so
that every successfully verified OIDC bearer token results in a local user record
before the request proceeds to route handling." Stated invariants (verbatim from
source):
1. Idempotent — `createOrGetJitOidcUser` guarantees exactly one local user record per
   `(tenant_id, external_realm, external_id)`.
2. Provisioning failure is a **hard failure** — "the auth pipeline MUST NOT proceed."
3. JIT config is **per-realm, not per-tenant** ("avoids a dependency on the
   tenant-resolution layer").

Defines `JitProvisioningConfig` (per-realm: `enabled`, `default_status`,
`default_roles` — role slugs assigned to newly-provisioned users, falling back to
VIEWER if empty) and three error sets (`JitProvisioningError`,
`JitConfigError`, `SyncError` for OIDC-10 attribute-sync, stubbed). Actual row
creation is `src/identity/registry.zig`'s `createOrGetJitOidcUser/4` (read in full,
lines 843-912): does a `SELECT` on `(tenant_id, external_realm, external_id)` first
(idempotency check), then an `INSERT ... ON CONFLICT (external_realm, external_id) ...
DO NOTHING RETURNING ...` with a re-select fallback if the conflict branch fired
concurrently (race-safe upsert-or-fetch pattern), hardcoding
`password_hash = '__OIDC_ONLY__'` and `auth_source = 'oidc'` so OIDC-provisioned users
are structurally distinguished from password-auth users at the schema level.

**Implication for the Decision:** this is real, non-trivial, tenant-aware business
logic — idempotent upsert with a specific conflict-resolution race-safety pattern, a
per-realm (not per-tenant) configuration axis, hard-fail-closed semantics on the auth
path, and a schema-level marker distinguishing OIDC-created users. No general-purpose
OIDC/OAuth library (§3) provides this — every candidate requires the same amount of
hand-written provisioning logic on top, because "what happens to local application
state after token verification succeeds" is inherently an application concern, not a
protocol concern.

PROVENANCE (historical, not current decision authority):
### 2.6 `src/oidc/claim_mapping.zig` and `src/oidc/realm_tenant_binding.zig` — supporting facts

Briefly read for completeness (not exhaustively, since neither is separately named in
REQ-011's acceptance criteria, but both inform the multi-realm dimension):
- `claim_mapping.zig` (OIDC-08): a **pure, zero-I/O** function
  (`mapVerifiedClaims` — invariant #1 in its own doc-comment) that maps verified OIDC
  claims to a provider-agnostic `IdentityContext`, with per-realm configurable claim
  paths (`tenant_id_claim`, `roles_claim_paths`, `email_claim`,
  `preferred_username_claim`) and documented defaulting rules for missing optional
  claims (invariant #3: missing → `""`/`&.{}`/`null` per field, never an error).
- `realm_tenant_binding.zig` (OIDC-12): enforces a **one-to-one** mapping between BPM
  tenants and IdP realms via a `tenant.idp_realm_id` column, with a documented default
  binding (`idp_realm_id = 'bpm-default'`) and the invariant that realm ID is
  immutable after tenant creation.

**Implication for the Decision:** "multi-realm/multi-tenant Keycloak" in R-Co is not
just "point different requests at different Keycloak realms" — it is a specific,
enforced 1:1 tenant↔realm binding stored in Postgres, plus a configurable
(per-realm) claim-to-identity mapping layer that is explicitly pure/synchronous. Any
OIDC library integration still needs this binding table and mapping layer built
independently; a library's "multi-tenant support" (per-request dynamic
issuer/discovery-URL configuration, see §3) addresses only the *token verification*
half of this, not the *tenant↔realm binding enforcement* half.

## 3. The two candidate libraries — real, cited capabilities

Per Core Directives' "No Speculation," the facts below are what was found via current
Hex/HexDocs documentation lookups this session, not assumed from typical OIDC-library
shapes. Cite the source pages named below in the Decision's Reasoning section rather
than asserting these as general knowledge.

### 3.1 `assent` (`pow-auth/assent` on GitHub, package `assent` on Hex.pm)

- **Current published version: 0.3.1** (0.3.0 released 2025-01-06 per its own
  CHANGELOG; 0.3.1 is the latest as of this session's lookup). A version constraint of
  `{:assent, "~> 0.3"}` is what a Decision naming this library must state, per
  acceptance criterion 3.
- `Assent.Strategy.OIDC` is built on `Assent.Strategy.OAuth2` with OIDC additions
  (`Assent.Strategy.OAuth2.Base`/`OAuth.Base`/`OIDC.Base` macros for building a
  provider-specific strategy module).
- **What it provides out of the box** (from `assent.hexdocs.pm/Assent.Strategy.OIDC.html`):
  authorization-URL generation (auto-adds `openid` scope), authorization-code token
  exchange, ID-token validation per OpenID Connect Core 1.0, **JWKS fetching** ("the
  appropriate public key will be fetched from the `jwks_uri`"), nonce generation/
  management, and `fetch_userinfo/2` for the userinfo endpoint.
- **What it explicitly does not provide** (confirmed by absence in the same
  documentation pass): no JWKS **caching** (each verification appears to fetch fresh
  per the documented flow — no cache/TTL/refresh mechanism is documented), no user
  provisioning (`assent` returns claims only; persisting a local user record is
  entirely the calling application's job — this matches Letflow's need for
  §2.5's `createOrGetJitOidcUser`-equivalent regardless), and no multi-tenant/
  multi-realm routing (the calling application is responsible for selecting/
  configuring which realm's strategy config to use per request — Assent has no
  concept of "realm").

### 3.2 `ueberauth` + an OIDC strategy — two live options exist, not one

The skeleton names "`ueberauth` + an OIDC strategy" as a single candidate, but two
materially different strategy packages exist and the Decision must pick between them,
not treat "ueberauth" as one undifferentiated option:

PROVENANCE (historical, not current decision authority):
**3.2a `ueberauth_oidcc`** (built on the Erlang `oidcc` library, `erlef/oidcc`):
- Current version **0.4.2** (last published 2025-07-02, per Hex.pm). Erlang Ecosystem
  Foundation-maintained (`erlef` org), same foundation that stewards Elixir/OTP
  tooling broadly.
- Multi-realm support is real and documented: "an OIDC Issuer... can be shared by
  multiple `Ueberauth.Strategy.Oidcc` providers," with config examples defining
  multiple issuers in a list — i.e. multiple realms/discovery-URLs configured
  declaratively in one app, closer to what R-Co's per-realm binding (§2.6) needs than
  Assent's single-strategy-per-provider model.
- The underlying `oidcc` library (`Oidcc.ProviderConfiguration.Worker`, current
  version **3.7.2**/3.8.0 per HexDocs) runs a **supervised worker process per
  provider configuration** that: fetches provider metadata + JWKS on first use,
  caches JWKS in an ETS table for fast lookup, sets a refresh timer based on the
  JWKS's own expiry metadata (`jwks_expired` message triggers automatic refresh), and
  exposes an explicit `refresh_jwks/1` for manual invalidation plus
  fetch-on-unknown-`kid` fallback. **This is a real, automatic, ETS-backed JWKS cache
  with expiry-driven refresh** — materially more capable than Assent's fetch-per-call
  model and closer in spirit to R-Co's own `jwks_cache.zig` (§2.2), but
  process-supervised (OTP-idiomatic) rather than a bare mutex-guarded hashmap.
- Still provides **no user provisioning** — same as Assent, claims-out /
  persistence-is-the-app's-job.
- Version constraint: `{:ueberauth_oidcc, "~> 0.4"}` (which pulls in `{:oidcc, "~>
  3.7"}` transitively).

**3.2b `ueberauth_keycloak_strategy`** (`Rukenshia/ueberauth_keycloak`, current
version **0.4.0** per Hex.pm):
- Keycloak-specific rather than generic-OIDC. Realm is configured via the
  `authorize_url`/`token_url`/`userinfo_url` pattern (`/realms/<realm>/protocol/
  openid-connect/...`), meaning multi-realm support here means "configure N separate
  strategy blocks, one per realm's URLs" rather than `ueberauth_oidcc`'s shared-issuer
  list — a materially weaker multi-realm story than 3.2a, and no independent
  confirmation was found this session that it does JWKS caching at all (its README
  focuses on the authorize/token/userinfo URL pattern, not token verification
  internals) — flagged as unresolved rather than assumed, see §6.

### 3.3 Summary table of out-of-box coverage vs. R-Co's actual behaviors (§2)

PROVENANCE (historical, not current decision authority):
| R-Co behavior (file) | `assent` 0.3.1 | `ueberauth_oidcc` 0.4.2 (+ `oidcc` ~3.7) |
|---|---|---|
| JIT user provisioning (`src/oidc/jit_provisioning.zig` + `registry.zig`'s `createOrGetJitOidcUser`) | Not provided — claims-out only | Not provided — claims-out only |
| JWKS caching (`src/identity/provider/oidc/jwks_cache.zig`) | Not provided — fetches per verification (no documented cache) | Provided — ETS-backed, expiry-driven auto-refresh via `Oidcc.ProviderConfiguration.Worker` |
| Multi-realm/multi-tenant Keycloak binding (`src/oidc/realm_tenant_binding.zig`, `src/identity/provider/adapters/keycloak/`) | Not provided — one strategy config per provider, no realm concept | Partially — multiple issuers/realms declaratively configurable, but the tenant↔realm *binding table* (§2.6, one-to-one enforcement) is still hand-written either way |
| Custom role registry (`src/identity/role_registry.zig`) | Not provided | Not provided — both require the same hand-written `TenantRoleStore`-equivalent (§2.3) |
| Keycloak Admin REST API provisioning (realm/client/user mgmt, `adapters/keycloak/provider.zig`) | Not provided | Not provided — neither library manages Keycloak's Admin API; that surface (§2.4) is hand-rolled either way |

Every row above is either "not provided by either" or "materially better under
`ueberauth_oidcc`" — no row favors `assent` or `ueberauth_keycloak_strategy` over
`ueberauth_oidcc`. This asymmetry is what the Decision section needs to state
explicitly per acceptance criterion 1 (an explicit decision, not a pros/cons list).

## 4. Cross-reference to `docs/migration/decisions/0001-web-framework.md` (done)

0001 (Phoenix at S4) already addresses OIDC/library fit under its own "Dimension C,"
concluding the choice is **orthogonal** to Phoenix vs. Plug/Bandit because "both
`ueberauth` and `assent`... are Plug-based, not Phoenix-specific — each attaches to a
request pipeline as a `Plug`... Nothing about 0001's Decision... depends on, or is
contradicted by, whatever 0002 eventually decides."

This design's research **agrees with 0001's orthogonality finding and finds nothing
0001 missed**: nothing in §2's ground-truth read of R-Co's actual identity/OIDC
behavior, nor §3's library research, surfaces a Phoenix-specific integration
requirement for either candidate. `ueberauth_oidcc`'s core mechanism is a supervised
worker process (`Oidcc.ProviderConfiguration.Worker`) started under the host
application's own supervision tree — a plain OTP concern, not a Phoenix-vs-Plug/Bandit
one; it would sit under `Letflow.Application`'s supervisor either way. `assent` has no
process/supervision component at all (its OIDC strategy is a stateless function-call
API). The Reasoning section for 0002 should state this cross-reference explicitly
(something to the effect of: "see `docs/migration/decisions/0001-web-framework.md`
Dimension C — that decision already found OIDC library choice orthogonal to the
Phoenix/Plug decision, and this decision confirms nothing found during 0002's own
research contradicts that: both `assent`'s function-call API and `ueberauth_oidcc`'s
supervised-worker API attach identically under either router choice").

One thing 0001 did **not** need to consider, that IS relevant here: if `ueberauth_oidcc`
is chosen, `Oidcc.ProviderConfiguration.Worker` needs a supervised child spec
somewhere in `Letflow.Application`'s tree (`lib/letflow/application.ex`) — this is a
detail 0001 had no reason to touch (it doesn't add any process) but 0002's eventual
S1 *execution* (not this decision record) will need to account for. Flagging this as
an open item for S1 execution, not something this decision record or its design needs
to resolve now (see §6).

## 5. What NOT to do (scope boundary ELIXIR-DEV must respect)

PROVENANCE (historical, not current decision authority):
- REQ-011 and this design produce a **decision record only**. No actual OIDC
  integration code, no `mix.exs` dependency addition (even if the Decision favors
  `ueberauth_oidcc`), no new file under `lib/letflow/` beyond what already exists.
  Adding `{:ueberauth_oidcc, "~> 0.4"}` (or `{:assent, "~> 0.3"}`) to `mix.exs` is S1
  execution work (`docs/migration/stage-1-identity.md`), not S0 decision-recording —
  same boundary 0001's design drew for the Phoenix dependency.
- No changes to `lib/letflow/router.ex`, `lib/letflow/application.ex`, or any existing
  `.ex` file.
- The only file ELIXIR-DEV should modify for REQ-011 is
  `docs/migration/decisions/0002-oidc-integration.md` (Decision + Reasoning sections),
  consistent with the skeleton file already in place. This design document is the only
  new file this step produces
  (`lib/letflow/design/0002-oidc-integration-decision.md`).
- Do not silently correct the skeleton's Question section (its "`src/identity/
  manager.zig`'s JIT provisioning" framing, per §1.2, points at the wrong file) or
  REQ-011's `description` field as a side effect of this work — register it as an
  issue instead (§6) so ORCH/DOC-UPDATER can decide whether to fix it in this run or a
  follow-up, matching how 0001's design handled its own route-count discrepancy.

## 6. Acceptance-criteria traceability

PROVENANCE (historical, not current decision authority):
| REQ-011 acceptance criterion | Concrete design element addressing it |
|---|---|
| "`docs/migration/decisions/0002-oidc-integration.md` exists with an explicit decision, not just a pros/cons list" | §3.3's summary table shows no row favoring `assent` or `ueberauth_keycloak_strategy` over `ueberauth_oidcc` — the Reasoning section must conclude with a single stated winner (library or hand-roll) rather than leaving the comparison open; this design does not pre-pick the winner (ELIXIR-DEV's call per `owner: ELIXIR-DEV`) but gives it a decisive, asymmetric comparison to conclude from |
| "decision names at least 2 real R-Co identity behaviors (from `src/identity/` or `src/oidc/`, by filename) and states whether the chosen approach covers each" | §2.1–§2.6 name and describe, from source: `src/oidc/jit_provisioning.zig` + `identity/registry.zig`'s `createOrGetJitOidcUser` (JIT), `identity/provider/oidc/jwks_cache.zig` (JWKS caching), `identity/role_registry.zig` (custom role registry), `oidc/realm_tenant_binding.zig` (tenant↔realm binding), `identity/provider/adapters/keycloak/provider.zig` (Keycloak adapter) — §3.3's table states library coverage for each explicitly |
| "if a library is chosen, decision names the specific library and version constraint" | §3.1 gives `{:assent, "~> 0.3"}`; §3.2a gives `{:ueberauth_oidcc, "~> 0.4"}` (pulling `{:oidcc, "~> 3.7"}`); §3.2b gives `ueberauth_keycloak_strategy` at 0.4.0 — whichever the Decision names, the exact constraint is already resolved here, not left for ELIXIR-DEV to look up mid-write |

## 7. Open questions / discrepancies to register, not silently resolve

PROVENANCE (historical, not current decision authority):
1. **Skeleton's Question section misattributes JIT provisioning's filename.** The
   existing `docs/migration/decisions/0002-oidc-integration.md` skeleton (and
   REQ-011's own `description` in `docs/requirements.yaml`) says JIT provisioning is
   `src/identity/manager.zig`. Ground truth (§1.2, §2.1, §2.5): the file at that path
   is `src/identity/provider/manager.zig`, a thin multi-provider delegation facade
   with no JIT-specific logic; the actual JIT orchestration is
   `src/oidc/jit_provisioning.zig`, backed by `src/identity/registry.zig`'s
   `createOrGetJitOidcUser`. This design resolves it for the purpose of writing
   0002's Reasoning section (cite `src/oidc/jit_provisioning.zig` +
   `registry.zig`'s `createOrGetJitOidcUser`, not `identity/manager.zig` — see §1.2)
   but does **not** edit the skeleton's Question section or REQ-011's `description`,
   since that's outside this design step's file scope. Recommend filing a
   `docs/issues/ISS-NNNN.yaml` entry (per core-directives.md's "No Issue Left
   Local-Only") so the misattribution gets corrected in its own right — same pattern
   0001's design used for its route-count issue (tracked as `ISS-0001.yaml`, so this
   should be a new, distinct issue number).
2. **`ueberauth_keycloak_strategy`'s JWKS-caching behavior is unconfirmed.** §3.2b
   notes no documentation was found this session confirming or denying whether this
   package caches JWKS. If the eventual Decision considers this package as a serious
   third option (rather than dismissing it in favor of `ueberauth_oidcc`'s
   stronger, confirmed multi-realm + JWKS-caching story), that gap should be closed
   with a direct source read before asserting a capability either way — do not assume
   parity with `ueberauth_oidcc` absent confirmation.
3. **Supervision placement for `ueberauth_oidcc`'s `Oidcc.ProviderConfiguration.Worker`
   is a real S1 execution detail, not resolved here.** §4 flags that if
   `ueberauth_oidcc` is the chosen library, `lib/letflow/application.ex`'s supervision
   tree will need a child spec for this worker (likely one per configured realm/issuer,
   given R-Co's per-realm JIT config from §2.5's invariant #3). This decision record
   only needs to name the library/version (acceptance criterion 3); the supervision
   wiring itself is S1 (`docs/migration/stage-1-identity.md`) execution work, out of
   this requirement's scope — flagging so it isn't lost before S1 starts.
4. **Final Decision (library vs. hand-roll, and which library) is intentionally not
   pre-decided here.** This design specifies the dimensions, the ground truth, and an
   asymmetric comparison (§3.3) strongly suggestive of one direction, but it does not
   assert the winner as settled fact — that synthesis is ELIXIR-DEV's to record as
   `docs/migration/decisions/0002-oidc-integration.md`'s actual Decision section
   content, per REQ-011's stated `owner: ELIXIR-DEV`. CODE-DESIGN-VALIDATOR should not
   fail this design for not naming a winner outright — the design's job is to make
   sure the Decision, once written, is fully reasoned against real, source-verified
   facts, not to pre-empt ELIXIR-DEV's documented ownership of the call.
