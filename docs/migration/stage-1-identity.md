# Stage 1 — Identity & multi-tenancy

Status: in progress. Depends on: S0. Requirements: REQ-015, REQ-016, REQ-017,
REQ-018, REQ-019 (done); REQ-020 through REQ-021 (`docs/requirements.yaml`) pending.

## Scope

Port `src/identity/` (18 files) and `src/oidc/` (13 files): Keycloak
OIDC login, JIT user provisioning, tenant resolution/binding, role
registry. Everything downstream is tenant-scoped, so this must be a
real implementation before S2 starts, not a stub.

Key R-Co files to read before expanding this stage into requirements:

- `src/oidc/jit_provisioning.zig` (orchestration) + `src/identity/registry.zig`'s
  `createOrGetJitOidcUser` (the actual upsert) — JIT provisioning
- `src/identity/provider/oidc/jwks_cache.zig`
- `src/identity/role_registry.zig`
- `src/identity/provider/` — Keycloak-specific adapter (nested `adapters/`, `oidc/`
  subdirs; 18 `.zig` files total under `src/identity/`)
- `src/oidc/` (13 files) — OIDC protocol handling
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

(None yet — this stage hasn't started.)
