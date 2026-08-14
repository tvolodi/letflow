# Stage 1 — Identity & multi-tenancy

Status: not started. Depends on: S0. Requirements: none expanded yet.

## Scope

Port `src/identity/` (18 files) and `src/oidc/` (13 files): Keycloak
OIDC login, JIT user provisioning, tenant resolution/binding, role
registry. Everything downstream is tenant-scoped, so this must be a
real implementation before S2 starts, not a stub.

Key R-Co files to read before expanding this stage into requirements:

- `src/identity/manager.zig` — JIT provisioning
- `src/identity/jwks_cache.zig`
- `src/identity/role_registry.zig`
- `src/identity/provider/` — Keycloak-specific adapter
- `src/oidc/` (13 files) — OIDC protocol handling
- `src/api/middleware/auth.zig`, `tenant_status.zig` — how identity
  plugs into the request pipeline today

## Decisions

Inherits `docs/migration/decisions/0002-oidc-integration.md` from S0.
Add a stage-specific decision file here only if S1 surfaces a genuinely
new choice 0002 didn't cover.

## REVIEWER sign-off

(None yet — this stage hasn't started.)
