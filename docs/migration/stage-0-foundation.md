# Stage 0 — Foundation & scaffolding

Status: active. Requirements: REQ-010, REQ-011, REQ-012, REQ-013,
REQ-014 (`docs/requirements.yaml`).

## Scope

Nothing else in the migration can be sized correctly until this stage
answers three questions:

1. Does Letflow adopt Phoenix, or continue on plain Plug/Bandit
   (`lib/letflow/router.ex` today handles 3 routes; R-Co's
   `src/api/routes/` has 22 modules plus `src/api/middleware/`'s 6
   modules — auth, rate_limit, quota_enforcement, tenant_status,
   trace, validate)? → REQ-010,
   `decisions/0001-web-framework.md`.
2. Does Letflow hand-roll OIDC/Keycloak integration (matching R-Co's
   `src/oidc/`, 13 files, and `src/identity/`, 18 files — JIT user
   provisioning, JWKS caching, multi-realm/tenant binding, role
   registry) or adopt a library? → REQ-011,
   `decisions/0002-oidc-integration.md`.
3. Does the Ecto schema layer port R-Co's 143 migrations
   (`migrations/` in R-Co) 1:1, or redesign idiomatically — and how is
   multi-tenancy represented at the schema level? R-Co's own tenant
   design is documented in its `src/design/adp-01-tenant-column-event-store.md`
   through `adp-04b-tenant-realm-binding.md` — read those before
   deciding whether Letflow adopts or diverges. → REQ-012,
   `decisions/0003-ecto-schema-strategy.md`.

A fourth, smaller decision: a single-command check gate — build with
warnings as errors, formatting check, and the test suite, all behind
one command. → REQ-013.

## Decisions

- [`decisions/0001-web-framework.md`](decisions/0001-web-framework.md) — pending (REQ-010)
- [`decisions/0002-oidc-integration.md`](decisions/0002-oidc-integration.md) — pending (REQ-011)
- [`decisions/0003-ecto-schema-strategy.md`](decisions/0003-ecto-schema-strategy.md) — pending (REQ-012)
- Check-gate choice (Mix alias vs. standalone script) — recorded
  directly in REQ-013's completion note in
  `docs/status/requirement_status.yaml`, not a separate decision file;
  it's a smaller, more mechanical choice than the other three, but
  still needs the one-line justification the acceptance criteria asks
  for (a prior requirement found that a custom Mix task under lib/
  forces a full project recompile just to be discovered, which broke
  compile-timing capture elsewhere in this repo — decide here whether
  that same problem applies to a check gate).

## Why these three and not others

Everything downstream reads one of these. S1 (identity) can't be
scoped without 0002. S4 (API surface) can't be scoped without 0001.
S2/S3 (event store, definitions, instance engine) can't be scoped
without 0003's tenant-modeling call. Other R-Co subsystems (Lua/WASM
scripting, scheduler, secrets) have their own build-vs-bind questions,
but those are deferred to S5/S6 — they don't block anything before
them the way these three do.

## REVIEWER sign-off

(No entries yet — REQ-014 adds the first once REQ-010..013 are done.
Append dated entries here, don't overwrite.)
