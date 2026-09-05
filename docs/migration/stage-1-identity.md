# Stage 1 — Identity & multi-tenancy

Status: in progress — all S1 requirements done, stage gate pending. Depends on:
S0. Requirements: REQ-015, REQ-016, REQ-017, REQ-018, REQ-019, REQ-020, REQ-021
(all done).

## Scope

Port `src/identity/` (18 files) and `src/oidc/` (13 files): Keycloak
OIDC login, JIT user provisioning, tenant resolution/binding, role
registry. Everything downstream is tenant-scoped, so this must be a
real implementation before S2 starts, not a stub.

Key R-Co files to read before expanding this stage into requirements:

PROVENANCE (historical, not current decision authority):
- `src/oidc/jit_provisioning.zig` (orchestration) + `src/identity/registry.zig`'s
  `createOrGetJitOidcUser` (the actual upsert) — JIT provisioning
PROVENANCE (historical, not current decision authority):
- `src/identity/provider/oidc/jwks_cache.zig`
PROVENANCE (historical, not current decision authority):
- `src/identity/role_registry.zig`
PROVENANCE (historical, not current decision authority):
- `src/identity/provider/` — Keycloak-specific adapter (nested `adapters/`, `oidc/`
  subdirs; 18 `.zig` files total under `src/identity/`)
- `src/oidc/` (13 files) — OIDC protocol handling
PROVENANCE (historical, not current decision authority):
- `src/api/middleware/auth.zig`, `tenant_status.zig` — how identity
  plugs into the request pipeline today

## Decisions

Inherits `docs/migration/decisions/0002-oidc-integration.md` from S0 (OIDC library
choice: `ueberauth_oidcc`) and `docs/migration/decisions/0003-ecto-schema-strategy.md`
Decision B from S0 (schema-per-tenant via Ecto `:prefix`/dynamic-repo, `tenant_id`
retained intra-schema) — S1's own `users`/tenant/tenant-binding tables fall under
Decision B like every other business table, not a tenant-column-only model (flagged by
REVIEWER during REQ-014's cross-decision review, `docs/issues/ISS-0007.yaml`). Add a
stage-specific decision file here only if S1 surfaces a genuinely new choice neither
0002 nor 0003 covered.

## REVIEWER sign-off

### 2026-08-16 — WF-04 stage-gate release validation (RELEASE-VALIDATOR)

**Verdict: PASS — S1 stage gate cleared.** Independently re-verified all 7
requirements (REQ-015 through REQ-021) against the actual current code and
tests in `lib/letflow/identity/`, `lib/letflow/oidc/`, `lib/letflow/plugs/`,
`priv/repo/migrations/20260816000001..000004`, and their corresponding
`test/letflow/**` files — not against `docs/status/requirement_status.yaml`'s
history narration. Full detail in
`docs/status/S1-release-2026-08-16.yaml`; summary below.

**Per-requirement verdicts** (evidence re-derived from source, not copied
from prior handoffs):

PROVENANCE (historical, not current decision authority):
- **REQ-015** (Ecto schema/migrations) — met. `20260816000001_create_tenants.exs`
  through `..000004_create_users.exs` all apply cleanly (confirmed indirectly:
  `mix test`'s `ecto.migrate --quiet` step succeeded). `tenants`/`users`/`groups`/
  `tenant_role` schema modules exist with moduledocs citing adp-04/04a/04b (and,
  for `tenant_role`, `src/identity/role_registry.zig` — the correct source per
  REQ-015's own description, which names `role_registry.zig`, not an adp-0x doc,
  for that one table's shape; the acceptance criterion's generic "adp-04/04a/04b"
  phrasing doesn't literally cover this, but the requirement's own description
  does — not a defect). Users' partial unique index on
  `(external_realm, external_id) WHERE external_id IS NOT NULL` confirmed
  verbatim in the migration. No DB CHECK constraint for
  auth_source-vs-external-fields consistency; both migration and schema
  moduledoc state this is an application-level invariant. Migration moduledoc
  explicitly states schema-per-tenant provisioning is deferred, not built,
  targeting Ecto's single default schema for now.
- **REQ-016** (ueberauth_oidcc + supervised worker) — met. `mix.exs` lists
  `{:ueberauth_oidcc, "~> 0.4"}`; `mix.lock` shows it resolved (0.4.2, pulling
  in `oidcc` 3.8.0). `lib/letflow/application.ex` supervises
  `Oidcc.ProviderConfiguration.Worker` with `issuer`/`name` read from
  `Application.fetch_env!(:letflow, :oidc)`, never a hardcoded literal.
  `mix compile --warnings-as-errors` re-run clean (exit 0). Independently
  re-ran `mix test`: the app boots and stays up against the placeholder
  `.invalid` issuer, logging `Metadata load failed ... Retrying in ...ms`
  without crashing or restart-looping — `backoff_type: :random` confirmed in
  `application.ex`. `test/letflow/application_test.exs` asserts the worker is
  alive, supervised as a real child, and config-sourced; this test passed in
  my own run.
PROVENANCE (historical, not current decision authority):
- **REQ-017** (pure claim-mapping) — met. `lib/letflow/oidc/claim_mapping.ex`
  inspected line by line: `map_verified_claims/3`, `resolve_claim_path/2`,
  `resolve_optional_string_claim/3`, `resolve_roles/2` — no `Repo`, `HTTP`,
  `File`, or `Application.get_env`/`fetch_env!` call anywhere in the module.
  Defaulting rules match Key Invariant 3 exactly (email→"",
  preferred_username→subject, roles→[], display_name→nil, tenant_id→nil);
  `subject in [nil, ""]` is the sole `{:error, :sub_claim_missing}` path.
  Moduledoc cites `src/oidc/claim_mapping.zig`.
PROVENANCE (historical, not current decision authority):
- **REQ-018** (JIT provisioning) — met. `lib/letflow/identity.ex`'s
  `provision_oidc_user/3` implements select-first →
  `Repo.insert(on_conflict: :nothing, conflict_target: {:unsafe_fragment, ...})`
  → re-select-on-conflict, matching the race-safe upsert-or-fetch pattern (not
  `Ecto.Multi`, not insert-then-rescue). `password_hash` fixed to
  `"__OIDC_ONLY__"` and `auth_source: :oidc` set unconditionally in
  `User.jit_changeset/2`, never caller-overridable (`IdentityContext` has no
  such fields to override with). `test/letflow/identity_test.exs`'s genuine
  two-`Task` concurrent-race test (barrier-synchronized, sandbox
  connection-allowed) passed in my own re-run, resolving to exactly one row
  and no unhandled exception. Moduledoc cites both
  `src/oidc/jit_provisioning.zig` and `registry.zig`'s `createOrGetJitOidcUser`.
- **REQ-019** (tenant↔realm binding) — met.
  `resolve_tenant_by_realm/1`/`resolve_realm_by_tenant/1`/`verify_realm_ownership/2`
  confirmed against `Letflow.Identity.Tenant`. One-to-one invariant enforced by
  a real unique partial index (`tenants_idp_realm_id_partial_index`), not just
  changeset validation. `idp_realm_id` immutability confirmed structurally:
  `update_changeset/2`'s `cast/3` field list omits `:idp_realm_id` entirely
  (verified by reading the schema file directly) — no rotation function exists,
  stated explicitly in the moduledoc. Default tenant pinning to
  `idp_realm_id = "bpm-default"` enforced via `validate_default_tenant_pinning/1`.
  `verify_realm_ownership/2` re-queries the DB rather than trusting a
  caller-supplied realm, correctly rejecting a mismatched
  `(tenant_id, external_realm)` pair.
- **REQ-020** (role registry) — met. `lib/letflow/identity/role_registry.ex`'s
  `list_roles/0` returns `[]` on empty and sorts by `name` (real `ORDER BY`,
  confirmed by reading the query). `upsert_role/2` checks `Repo.get(Group, ...)`
  inside a transaction before writing, rolling back
  `{:error, :group_not_found}` on a dangling reference; a second call with a
  different `group_id` updates via `on_conflict: [set: [group_id: ...]]`
  rather than duplicating. `resolve_role_in_tx/1` wraps its lookup in `rescue
  _ -> nil`, confirmed by both the unbound-name case and a genuine
  `Ecto.Query.CastError`-forcing test. Moduledoc confirms (and the module's
  own `alias` list confirms by absence) no coupling to any `Letflow.Oidc.*`
  module or `Letflow.Identity`'s OIDC-pipeline functions.
- **REQ-021** (Plug pipeline wiring) — met.
  `lib/letflow/plugs/auth_pipeline.ex`'s `call/2` is a single `with` chain in
  the exact order the requirement specifies (extract token → verify → extract
  realm → resolve tenant → guard realm ownership → map claims → JIT provision
  → attach auth context); a missing/malformed bearer token fails at the first
  `with` clause, before any of the later steps run — confirmed both by reading
  the chain and by the passing "none of the above rejected requests write any
  user row anywhere" test. `lib/letflow/plugs/tenant_status.ex`'s write-method
  guard (`POST`/`PUT`/`PATCH`/`DELETE`) returns 503 + `Retry-After: 30` for a
  `:migrating` tenant and passes `GET`/`HEAD` through with zero DB query
  (confirmed by the telemetry-handler test asserting no `[:letflow, :repo,
  :query]` event fires for GET) — all of these tests passed in my own re-run.
  Both moduledocs state this supersedes the never-built REQ-103 plug and name
  all 3 of `Letflow.Router`'s existing routes as not currently mounted behind
  either plug.

**Decision-record cross-check** — no contradiction found:
`docs/migration/decisions/0002-oidc-integration.md` (ueberauth_oidcc,
`~> 0.4`) matches `mix.exs`/`application.ex` exactly; 0002's "likely one per
configured realm/issuer" language is a forward-looking hint the decision
itself doesn't mandate for S1, and REQ-016's own description explicitly
narrows scope to exactly one realm/issuer for this batch (no real Keycloak/
realm-provisioning exists yet) — not a deviation.
`docs/migration/decisions/0003-ecto-schema-strategy.md` Decision B
(schema-per-tenant via Ecto `:prefix`/dynamic-repo, `tenant_id` retained
intra-schema) is correctly read by this file's own "Decisions" section above.
REQ-015's actual migrations target Ecto's single default schema and say so
explicitly in their header comments — this is a documented deferral 0003
itself anticipates ("a `tenant_schemas`-equivalent registry and a
provisioning path... are needed at S2/S3 execution time"), not a silent
divergence from Decision B.

**`docs/issues/ISS-0007.yaml` disposition:** was open as of this stage gate
(S1-scoped concern satisfied — confirmed above — but the issue's close
condition was tied to the first S2/S3 design artefact citing Decision B,
which hadn't happened yet). Closed 2026-08-16 once REQ-022 (S2's first
schema-design requirement) landed and its design artefact
(`lib/letflow/design/req022-tenant-schema-provisioning.md`) was independently
confirmed to cite and implement Decision B during REQ-022's own WF-02 gates —
see `docs/issues/ISS-0007.yaml`'s resolution note. Not a blocker for this
(already-cleared) S1 stage gate either way.

**Independent full-suite re-run:** `mix test` (this validator's own
invocation, HEAD `1b1ab1f`, plus the untracked
`test/reports/report-2026-08-16-WF04.yaml`) — **132 passed (4 properties, 128
tests), 0 failures**, exit code 0, run three times with consistent results.
`mix compile --warnings-as-errors` and `mix format --check-formatted` both
exit 0.

---

## What S1 deferred, and where it is now tracked (added 2026-08-22)

S1 delivered the identity **logic** and narrowed scope deliberately: token
verification, claim mapping, JIT provisioning, tenant↔realm binding, and
`Letflow.Plugs.AuthPipeline`, all against exactly one configured realm/issuer,
with "no real Keycloak/realm-provisioning exists yet" recorded above as a scope
narrowing rather than a deviation. That was correct and this section does not
reopen the stage.

It does close a dead end. The deferral had no forward pointer, and a gap
analysis on 2026-08-22 found what that cost:

- `docker-compose.yml` declares exactly one service, `postgres`. There is no
  identity provider in this system.
- `config/dev.exs` **and** `config/prod.exs` both carry
  `issuer: "https://placeholder-keycloak.invalid/realms/bpm-default"`.
- `application.ex` starts `Oidcc.ProviderConfiguration.Worker` against that
  issuer unconditionally with `backoff_type: :random`, so a running node retries
  a non-existent host indefinitely and `TokenVerifier.Oidcc` can never verify a
  token.
- `config/test.exs` uses `Letflow.Oidc.TokenVerifierDouble`, so the full suite
  passes with no provider running. **No test in this repository has ever
  exercised a real token** — which is why none of the above surfaced as a
  failure for months.
- Nothing creates a realm. `tenants.idp_realm_id` can point at a realm that has
  never existed, and nothing notices until a login fails.

Tracked as `REQ-128` (Keycloak in the dev stack, real issuer, five-role realm)
through `REQ-135` (per-tenant realm provisioning design), filed under **S4** —
S4's goal is an API surface that serves an authenticated, authorized request,
and these are its preconditions. See also
[`decisions/0013-authorization-role-set.md`](decisions/0013-authorization-role-set.md),
which settles a role-set drift between the authorization matrix, R-Co's realm
fixture, and the SPA's nav gating.
