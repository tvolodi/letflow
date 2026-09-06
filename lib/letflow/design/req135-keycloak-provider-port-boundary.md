# REQ-135: Survey of R-Co's Keycloak provider adapter — port boundary finding

**Requirement:** REQ-135 (`docs/requirements.yaml`)
**Kind of artefact:** finding, not a design. No provisioning-flow design and no
implementation code appear here — that is REQ-137's scope. This document answers
one question only: of R-Co's `src/identity/provider/` (14 files), which files' content
survives the port to Letflow, and which are already covered by facilities Letflow has.

## 1. Line-count measurement (AC2)

Command run against `c:\Users\tvolo\dev\ai-dala\R-Co`:

PROVENANCE (historical, not current decision authority):
```
find src/identity/provider/ -type f -name "*.zig" -exec wc -l {} +
```

Output:

PROVENANCE (historical, not current decision authority):
```
   107 src/identity/provider/adapters/keycloak/config.zig
  1626 src/identity/provider/adapters/keycloak/provider.zig
    99 src/identity/provider/adapters/keycloak/urls.zig
   141 src/identity/provider/adapters/stub/provider.zig
   573 src/identity/provider/bootstrap.zig
    27 src/identity/provider/errors.zig
    31 src/identity/provider/idp_test_root.zig
    98 src/identity/provider/interface.zig
   169 src/identity/provider/manager.zig
     8 src/identity/provider/mod.zig
   140 src/identity/provider/oidc/jwks_cache.zig
   179 src/identity/provider/oidc/standards_verifier.zig
   714 src/identity/provider/test_oidc02_keycloak_adapter.zig
   281 src/identity/provider/types.zig
  4193 total
```

**Total: 4,193 lines — matches the 4,193 this requirement was drafted against. No
drift.** The row line counts below sum to 4,193 (see §3 tally).

## 2. Per-file table (AC1, AC3)

PROVENANCE (historical, not current decision authority):
| # | File | Lines | Verdict | Reason |
|---|---|---|---|---|
| 1 | `adapters/keycloak/config.zig` | 107 | **PORT** | Keycloak admin-API client config (base URL, admin realm, admin client credentials, timeouts, JWKS TTL) — none of this is provided by `oidcc`/`ueberauth_oidcc`, which only configure token-verification issuers, not Keycloak's Admin REST API. Needed by REQ-137's admin client. |
| 2 | `adapters/keycloak/provider.zig` | 1,626 | **PORT** | The actual Keycloak Admin REST API client (HTTP transport, admin-token caching, realm/user/client/federation/audit-event provisioning calls). This is the single largest file and the concrete gap this requirement's parent problem names: nothing in Letflow or `oidcc` creates a Keycloak realm. Confirmed via `lib/letflow/design/0002-oidc-integration-decision.md`'s coverage table: "Keycloak Admin REST API provisioning... Not provided [by either candidate library]; that surface is hand-rolled either way." |
| 3 | `adapters/keycloak/urls.zig` | 99 | **PORT** | Admin REST API URL builders (`/admin/realms`, `/admin/realms/:id`, `/admin/realms/:id/users/:id`, etc.) — a direct helper of `provider.zig` (#2); has no independent existence, ports alongside it. |
| 4 | `adapters/stub/provider.zig` | 141 | DROP | A configurable fake implementing the same `IdentityProvider` interface for testing without a real Keycloak. Superseded by two Letflow facilities: `test/support/token_verifier_double.ex` already covers the token-VERIFICATION half of this pattern (the seam `Letflow.Oidc.TokenVerifier` dispatches through), and REQ-128 (shipped) gives the test suite a real Keycloak instance for the admin-provisioning half, reducing the need for a hand-rolled fake there. REQ-137 will write a fresh Elixir test double for its own admin-client behaviour if one proves necessary — not port this file. |
| 5 | `bootstrap.zig` | 573 | DROP | Runtime provider construction driven by env vars (`BPM_IDP_PROVIDER_TYPE`, `BPM_IDP_BASE_URL`, etc.), read at process start. Superseded by REQ-016's already-made decision (`lib/letflow/design/req016-oidc-dependency-supervision.md` §"Decision: use `config/dev.exs`, not `config/runtime.exs`") to source OIDC config from compile-time `Application` config files, not runtime env-var bootstrap. |
| 6 | `errors.zig` | 27 | DROP | A Zig `error{}` set (`InvalidToken`, `TokenExpired`, `RealmNotFound`, ...). Elixir has no error-union type to port this onto; the idiomatic equivalent is `{:error, reason}` tuples with atom reasons chosen per call site as REQ-137 needs them, not a single upfront ported enum. |
| 7 | `idp_test_root.zig` | 31 | DROP | A Zig test-aggregator file (`test { _ = @import(...) }` pattern required by `zig build test` to discover nested test files). ExUnit auto-discovers `*_test.exs` files with no barrel/root file needed — this file's entire purpose does not exist in the target toolchain. |
| 8 | `interface.zig` | 98 | **PORT** | Defines the admin-operation surface as a vtable: `provisionRealm`, `checkRealmExists`, `provisionUser`, `grantRoles`, `provisionClient`, `upsertFederation`, `deleteFederation`, `listAuditEvents`, `createProtocolMapper`, `toggleRealm`, `deleteRealm`, `updateClient`, plus the already-covered `verifyToken`/`lookupUser`. This is exactly the missing capability the parent problem names (nothing creates a realm) — ports as an Elixir `@behaviour` (see §4), not the fn-pointer-struct shape verbatim. |
| 9 | `manager.zig` | 169 | DROP | A provider-dispatch facade plus an `AuthMode` enum (`local_only`/`dual_accept`/`oidc_only`) for accepting both local password auth and OIDC bearer tokens on the same endpoint. Letflow is OIDC-only (`docs/migration/decisions/0002-oidc-integration.md`'s own decision; confirmed by grep — `lib/letflow/plugs/auth_pipeline.ex` has no password/local-auth branch), so the dual-mode concept has no target. The single-dispatch-point concern this file also serves is already covered by `Letflow.Oidc.TokenVerifier` (a `@behaviour` with exactly one real implementation configured via `Application.get_env(:letflow, :oidc)[:token_verifier]`, per its own moduledoc). |
| 10 | `mod.zig` | 8 | DROP | A Zig module re-export barrel (`pub const errors = @import(...)`, etc.). Elixir's module namespacing (`Letflow.Oidc.*`, `Letflow.Identity.*`) needs no equivalent aggregator file. |
| 11 | `oidc/jwks_cache.zig` | 140 | DROP | A hand-built, explicitly-documented-as-not-thread-safe, single-process JWKS `kid` presence cache with TTL and a global refresh rate limiter. Superseded by `oidcc`'s `Oidcc.ProviderConfiguration.Worker`: a supervised, OTP-idiomatic, ETS-backed JWKS cache with automatic expiry-driven refresh and fetch-on-unknown-`kid` fallback — cited and compared directly in `lib/letflow/design/0002-oidc-integration-decision.md`, which is materially more capable than this file's bare-mutex-guarded hashmap design. |
| 12 | `oidc/standards_verifier.zig` | 179 | DROP | Discovery-document and JWKS resolution abstractions feeding standards-based ID-token verification. Superseded by `Oidcc.Token.validate_jwt/3`, already wired through `lib/letflow/oidc/token_verifier/oidcc.ex`. |
| 13 | `test_oidc02_keycloak_adapter.zig` | 714 | DROP | Zig integration tests for the Keycloak adapter. Test content does not port 1:1 across language/framework boundaries (ExUnit fixtures, `Letflow.DataCase`/`Sandbox` conventions, and REQ-128's real Keycloak instance are all shaped differently from this file's Zig test harness). REQ-137's own TEST-DESIGNER step writes fresh ExUnit coverage for whatever admin-client surface it implements; this file may inform *which scenarios* to cover but is not itself a porting target. |
| 14 | `types.zig` | 281 | **PORT** | Input/output shapes for the admin operations: `ProvisionRealmInput/Result`, `ProvisionUserInput/Result`, `GrantRolesInput/Result`, `ProvisionClientInput/Result`, `UpsertFederationInput`, `ListAuditEventsInput`, `AuditEvent(Page)`, `CheckRealmExistsInput`, etc. Two of the twenty-six structs (`VerifyTokenInput`, `VerifiedPrincipal`) duplicate what `oidcc`'s claims map already provides and do not need porting individually, but the file as a whole is dominated (24 of 26 structs) by the same missing admin-provisioning surface as `interface.zig` (#8) and `provider.zig` (#2), and ports alongside them as the corresponding Elixir struct/typespec definitions. |

## 3. Tally (AC1, AC2)

| Verdict | Files | R-Co lines |
|---|---|---|
| PORT | 5 (#1, #2, #3, #8, #14) | 107 + 1,626 + 99 + 98 + 281 = **2,211** |
| DROP | 9 (#4, #5, #6, #7, #9, #10, #11, #12, #13) | 141 + 573 + 27 + 31 + 169 + 8 + 140 + 179 + 714 = **1,982** |
| **Total** | **14** | **4,193** ✓ matches §1's measured total |

## 4. Expected total ported size (AC4)

**Single estimate: ~1,200 lines of Elixir**, not a range.

PROVENANCE (historical, not current decision authority):
Reasoning: the five PORT files sum to 2,211 R-Co (Zig) lines, but a straight line-for-line
port is not the right unit of comparison — Zig's admin-client code carries structural
overhead Elixir does not: explicit `allocator: std.mem.Allocator` parameters and
`errdefer`/`deinit` pairs on every struct (types.zig, config.zig), a hand-rolled
fn-pointer vtable for what Elixir expresses as a five-line `@behaviour` declaration
(interface.zig), and manual `std.fmt.allocPrint`/buffer-management for what an HTTP
client library (`Req`, already a Letflow dependency per other REQ-0XX route
implementations) and `Jason` handle in far fewer lines (provider.zig, urls.zig). Applying
the same shrinkage this session has consistently observed porting other R-Co modules
(Zig's manual-memory-management and vtable boilerplate typically costs 40-60% more
lines than the equivalent idiomatic Elixir) to each PORT file individually:

PROVENANCE (historical, not current decision authority):
- `interface.zig` (98) → an Elixir `@behaviour` with ~13 `@callback` declarations: ~70 lines
PROVENANCE (historical, not current decision authority):
- `types.zig` (281) → plain structs/typespecs, no allocator/deinit ceremony: ~170 lines
PROVENANCE (historical, not current decision authority):
- `config.zig` (107) → a config struct sourced from `Application.get_env` (REQ-016's
  established pattern), no manual `clone`/`dupeTrimmedUrl`: ~60 lines
PROVENANCE (historical, not current decision authority):
- `urls.zig` (99) → one-line string-interpolation functions, no `allocPrint`/allocator
  threading: ~40 lines
PROVENANCE (historical, not current decision authority):
- `provider.zig` (1,626) → the substantive admin-HTTP-client logic does not shrink as
  dramatically (the ~13 admin operations' request/response handling is genuine work
  regardless of language), but `Req`+`Jason` eliminate the hand-rolled HTTP transport
  and JSON parsing this file currently does manually: ~860 lines

Sum: 70 + 170 + 60 + 40 + 860 = **1,200 lines**, stated here as REQ-137's starting
estimate — REQ-137's own design may revise it once it scopes exactly which of the
~13 admin operations ship in its first cut versus a later requirement.

## 5. Interface/adapter split decision (AC5)

PROVENANCE (historical, not current decision authority):
**Decision: preserve the split, but as an Elixir `@behaviour` + implementation module
pair — the same shape Letflow already uses for token verification — not as R-Co's
fn-pointer/vtable struct (`interface.zig`'s literal shape).**

Reasoning: Letflow already has exactly this pattern, live and shipped, for the
token-verification half of identity: `Letflow.Oidc.TokenVerifier` (a `@behaviour` with
one `@callback`), `Letflow.Oidc.TokenVerifier.Oidcc` (the real `oidcc`-backed
implementation, `@behaviour Letflow.Oidc.TokenVerifier`), and
`test/support/token_verifier_double.ex` (the test double, configured in
`config/test.exs`). REQ-137's new admin-provisioning surface (realm/user/client
management) is the same *shape* of problem — one real caller-facing operation set,
one Keycloak-backed implementation, and a need for tests that do not require a live
Keycloak for every unit test — so the same precedent applies directly: a new
`Letflow.Identity.ProviderAdmin`-style `@behaviour` (name is REQ-137's to pick),
one `oidcc`/Keycloak-Admin-REST-backed implementation module, and a test double
following `token_verifier_double.ex`'s existing pattern.

PROVENANCE (historical, not current decision authority):
This holds even though REQ-128 now gives the test suite a *real* Keycloak instance
to run against (which materially reduces, but does not eliminate, the case for a stub
— see row #4's DROP reasoning): a behaviour seam still keeps fast unit tests fast
(most admin-client callers do not need to exercise real HTTP against Keycloak to test
their own logic), and keeps the abstraction available if Letflow ever needs a second
IdP backend, matching the reasoning `docs/migration/decisions/0002-oidc-integration.md`
already established for the token-verification seam. What does NOT carry over is
`interface.zig`'s specific mechanism (`ctx: *anyopaque` plus a struct of function
pointers) — that is a Zig idiom for runtime polymorphism without a language-level
interface construct; Elixir's `@behaviour`/`@callback` is the direct, idiomatic
equivalent and is what ports, not the vtable shape itself.

## 6. Explicit scope boundary

This document contains no design of the realm-creation/provisioning flow itself (no
`gen_statem`/context-module shape, no supervision tree placement, no migration, no
HTTP route) and no implementation code. Those belong to REQ-137, which this
requirement's own description states explicitly: "REQ-137 owns both, and folding them
in here is what made the original single requirement unsizable." The
`@behaviour` name proposed in §5 (`Letflow.Identity.ProviderAdmin`) is illustrative,
not a design decision — REQ-137's own CODE-DESIGNER step names it for real.
