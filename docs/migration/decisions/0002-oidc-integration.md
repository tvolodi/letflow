# 0002 — OIDC/Keycloak integration: hand-roll vs. library

Status: pending (REQ-011). Owner: ELIXIR-DEV.

## Question

R-Co hand-rolls OIDC in `src/oidc/` (13 files) and `src/identity/` (18
files, including `manager.zig` for JIT provisioning, `jwks_cache.zig`,
`role_registry.zig`, `provider/` for Keycloak specifics). Does Letflow
hand-roll the Elixir equivalent, or adopt a library (e.g. `assent`,
`ueberauth` + an OIDC strategy)?

## Decision

_Not yet recorded — REQ-011 fills this in._

## Reasoning

_Must explicitly state, for at least these R-Co behaviors, whether the
chosen approach covers each out of the box or needs custom code:_

- _JIT user provisioning (`src/identity/manager.zig`)_
- _JWKS caching (`src/identity/jwks_cache.zig`)_
- _multi-realm / multi-tenant Keycloak binding
  (`src/identity/provider/`, `src/oidc/`)_
- _custom role registry (`src/identity/role_registry.zig`)_

_If a library is chosen, name the specific package and version
constraint._
