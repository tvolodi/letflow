# 0002 — OIDC/Keycloak integration: hand-roll vs. library

Status: decided (REQ-011). Owner: ELIXIR-DEV.

## Question

PROVENANCE (historical, not current decision authority):
R-Co hand-rolls OIDC in `src/oidc/` (13 files, including
`jit_provisioning.zig` for JIT provisioning orchestration) and
`src/identity/` (18 files, including `registry.zig`'s
`createOrGetJitOidcUser` for the actual JIT upsert,
`provider/oidc/jwks_cache.zig`, `role_registry.zig`, `provider/` for
Keycloak specifics). Does Letflow hand-roll the Elixir equivalent, or
adopt a library (e.g. `assent`, `ueberauth` + an OIDC strategy)?

## Decision

Letflow adopts **`ueberauth_oidcc` (`{:ueberauth_oidcc, "~> 0.4"}`, pulling in
`{:oidcc, "~> 3.7"}` transitively)** for the token-verification/JWKS-caching layer of
OIDC integration, rather than hand-rolling that layer or adopting `assent (~> 0.3)` or
`ueberauth_keycloak_strategy (0.4.0)`.

This is a **partial**-library decision, not "library replaces R-Co's `src/oidc/` and
`src/identity/` wholesale": `ueberauth_oidcc` (and every other candidate evaluated)
covers only token verification and JWKS caching. JIT user provisioning, the
tenant↔realm binding table, the custom role registry, and Keycloak Admin REST API
provisioning are hand-rolled regardless of library choice, because none of the
candidates provide them — see Reasoning below. Adding the actual `mix.exs` dependency,
and any supervision-tree wiring it needs, is S1 execution work
(`docs/migration/stage-1-identity.md`), not part of this decision record — no
`mix.exs` change is made here.

## Reasoning

PROVENANCE (historical, not current decision authority):
**Note on source accuracy:** the Question section originally (pre-existing, not edited
as part of REQ-011 itself) attributed JIT provisioning to `src/identity/manager.zig`.
Verified directly against R-Co's source: that attribution was wrong. The file at
`src/identity/manager.zig` does not exist — the actual path is
`src/identity/provider/manager.zig`, and it is a thin multi-provider delegation facade
(every public method one-line-forwards to a configured `IdentityProvider`; the only
non-trivial logic in it is a lexical JWT-shape pre-check used to decide whether
`dual_accept` mode should attempt OIDC verification at all). It does not implement JIT
semantics. The real JIT orchestration lives in **`src/oidc/jit_provisioning.zig`**,
backed by **`src/identity/registry.zig`'s `createOrGetJitOidcUser`** function. This
Reasoning cites those two correctly-attributed files below, not `manager.zig`. The
skeleton's misattribution was filed separately as `docs/issues/ISS-0002.yaml` rather
than corrected in place as part of REQ-011 itself (out of that requirement's file
scope — see `lib/letflow/design/0002-oidc-integration-decision.md` §5, §7.1); it has
since been fixed in the Question section above, in the same pass that resolved
ISS-0002.

For each R-Co behavior below: does `ueberauth_oidcc` cover it out of the box, or does
Letflow still need custom code?

PROVENANCE (historical, not current decision authority):
- **JIT user provisioning** (`src/oidc/jit_provisioning.zig`, backed by
  `src/identity/registry.zig`'s `createOrGetJitOidcUser`) — **not covered, custom code
  required.** R-Co's implementation is real, tenant-aware business logic: an idempotent
  upsert keyed on `(tenant_id, external_realm, external_id)` via `INSERT ... ON
  CONFLICT ... DO NOTHING RETURNING ...` with a re-select fallback for concurrent
  conflicts, a hardcoded `password_hash = '__OIDC_ONLY__'` / `auth_source = 'oidc'`
  schema-level marker, per-realm (not per-tenant) JIT config, and hard-fail-closed
  semantics ("the auth pipeline MUST NOT proceed" on provisioning failure).
  `ueberauth_oidcc` — like every candidate evaluated, including `assent` — returns
  verified claims only; persisting a local user record is entirely the calling
  application's responsibility under every option considered. Letflow must hand-write
  a `createOrGetJitOidcUser`-equivalent regardless of library choice, so this dimension
  does not favor any candidate over hand-rolling; it favors none of them.

PROVENANCE (historical, not current decision authority):
- **JWKS caching** (`src/identity/provider/oidc/jwks_cache.zig`) — **covered out of
  the box.** R-Co's cache is a hand-built, single-process, TTL + globally
  rate-limited `std.StringHashMap` keyed by JWKS URI, explicitly documented as **not
  thread-safe** ("callers must hold an external mutex") — a design that assumes
  single-threaded access and does not map cleanly onto BEAM's default concurrent-request
  model. `ueberauth_oidcc`'s underlying `oidcc` (`~> 3.7`) library runs a **supervised
  worker process per provider configuration**
  (`Oidcc.ProviderConfiguration.Worker`) that fetches provider metadata and JWKS on
  first use, caches JWKS in an ETS table, sets a refresh timer from the JWKS's own
  expiry metadata, and exposes both automatic expiry-driven refresh and an explicit
  `refresh_jwks/1` for manual invalidation plus fetch-on-unknown-`kid` fallback. This
  is process-supervised (OTP-idiomatic) rather than mutex-guarded, and is a strictly
  more capable, safer-under-concurrency equivalent of R-Co's hand-built cache. `assent
  (~> 0.3)` provides no comparable caching — its documented flow fetches JWKS fresh
  per verification, with no cache/TTL/refresh mechanism.

PROVENANCE (historical, not current decision authority):
- **Multi-realm / multi-tenant Keycloak binding** (`src/oidc/realm_tenant_binding.zig`,
  `src/identity/provider/adapters/keycloak/`) — **partially covered; the binding
  enforcement itself is custom code regardless.** R-Co enforces a specific, persisted
  one-to-one mapping between BPM tenants and IdP realms (a `tenant.idp_realm_id`
  column, immutable after tenant creation, defaulting to `'bpm-default'`), plus a
  separate, pure/synchronous per-realm claim-mapping layer
  (`src/oidc/claim_mapping.zig`) with configurable claim paths. `ueberauth_oidcc`
  supports multiple issuers/realms declaratively — "an OIDC Issuer... can be shared by
  multiple `Ueberauth.Strategy.Oidcc` providers," with config examples defining
  several issuers in one app — which is a materially better starting shape for
  multi-realm than `assent`'s single-strategy-per-provider model (no realm concept at
  all) or `ueberauth_keycloak_strategy`'s per-realm URL-block duplication. But the
  *token-verification* half (which library configuration applies to a given request)
  is distinct from the *tenant↔realm binding table* half (the persisted, enforced 1:1
  mapping and its immutability invariant) — no candidate provides the latter. Letflow
  still hand-writes the binding table and its enforcement under any library choice;
  `ueberauth_oidcc` only makes the former half easier.

PROVENANCE (historical, not current decision authority):
- **Custom role registry** (`src/identity/role_registry.zig`) — **not covered, custom
  code required, and not really an OIDC-library concern at all.** `TenantRoleStore`
  wraps a per-tenant `tenant_role` SQL table with transactional resolution
  (`resolveRoleInTx`, called from the S3 workflow engine's `applyTransition`, errors
  swallowed to "unbound" rather than propagated) — a workflow-engine-facing
  role→group mapping with no call-site coupling to `src/oidc/` at all (confirmed: no
  `role_registry` references found under `src/oidc/`). This is Letflow/S3 domain
  logic with a SQL-transaction coupling that no general-purpose OIDC/OAuth library
  provides or should provide. Identical hand-written effort under every candidate.

**Why `ueberauth_oidcc` over the alternatives:** across the four behaviors above, no
row favors `assent` or `ueberauth_keycloak_strategy` over `ueberauth_oidcc` — every
row is either "hand-written regardless of library" or "materially better under
`ueberauth_oidcc`" (JWKS caching, multi-realm token-verification config). `assent
(~> 0.3)` would mean re-implementing JWKS caching by hand on top of a library that
already lacks one, gaining nothing over hand-rolling that specific piece.
`ueberauth_keycloak_strategy (0.4.0)` has a weaker multi-realm story (per-realm URL
duplication vs. `ueberauth_oidcc`'s shared-issuer-list config) and its JWKS-caching
behavior is unconfirmed from available documentation as of this session (flagged, not
assumed — see `docs/issues/ISS-0002.yaml`), so it is not chosen as a serious
alternative absent that confirmation. `ueberauth_oidcc` is EEF-maintained (`erlef`
org, the same foundation stewarding Elixir/OTP tooling broadly), which also weighs in
its favor for long-term maintenance versus a single-maintainer Keycloak-specific
strategy.

**Cross-reference to `docs/migration/decisions/0001-web-framework.md`:** that decision
(Phoenix at S4) already found OIDC library choice orthogonal to Phoenix vs. Plug/Bandit
under its Dimension C, since both `ueberauth` and `assent` attach as a `Plug`, not a
Phoenix-specific mechanism. Nothing found during this decision's research contradicts
that: `ueberauth_oidcc`'s core mechanism is a supervised worker process
(`Oidcc.ProviderConfiguration.Worker`) started under the host application's own
supervision tree — a plain OTP concern — and would sit under `Letflow.Application`'s
supervisor identically regardless of which router/framework decision 0001 made.
`assent` has no process/supervision component at all. This decision does not
contradict or require revisiting 0001.

PROVENANCE (historical, not current decision authority):
**Deferred to S1 execution, not this decision record:** if/when `ueberauth_oidcc` is
wired in, `Oidcc.ProviderConfiguration.Worker` needs a supervised child spec in
`lib/letflow/application.ex` (likely one per configured realm/issuer, given the
per-realm JIT config invariant in `src/oidc/jit_provisioning.zig`). No `mix.exs`
dependency and no `application.ex` change are made as part of this decision record —
see `docs/migration/stage-1-identity.md` for where that work belongs.
