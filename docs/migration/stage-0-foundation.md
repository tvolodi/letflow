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

### 2026-08-15 — REQ-014: cross-decision consistency review of all four S0 decisions

**Verdict: GO for S1.** No contradiction found among
[`decisions/0001-web-framework.md`](decisions/0001-web-framework.md) (Phoenix,
REQ-010), [`decisions/0002-oidc-integration.md`](decisions/0002-oidc-integration.md)
(`ueberauth_oidcc` partial adoption, REQ-011),
[`decisions/0003-ecto-schema-strategy.md`](decisions/0003-ecto-schema-strategy.md)
(Ecto-idiomatic redesign + schema-per-tenant with intra-schema `tenant_id`, REQ-012),
or the REQ-013 check-gate choice (`mix letflow.check`, `mix.exs` `aliases/0` +
`cli/0`). S1 (`docs/migration/stage-1-identity.md`) may begin.

**What was checked, against each other, pairwise:**

1. **0002 (OIDC/tenant resolution) vs. 0003 (schema-per-tenant).** 0002's JIT
   provisioning key is `(tenant_id, external_realm, external_id)` and its binding
   table is keyed on `tenant.idp_realm_id`. Neither assumes a *single shared
   schema with only a `tenant_id` column* — 0002 never asserts a schema
   mechanism at all, it only asserts a key shape. 0003 Decision B's two-layer
   model (schema-per-tenant as the isolation boundary, `tenant_id` retained
   *inside* each tenant's schema as an intra-schema predicate/key component)
   is exactly what 0002's key shape needs: `tenant_id` still exists as a column
   Letflow can put in a composite upsert key, it's just no longer the sole
   isolation mechanism. 0003's own Cross-references section already states
   this compatibility explicitly ("independently corroborates the
   `(tenant_id, external_realm, external_id)` JIT-provisioning key ... both
   consistent with, and unaffected by, this decision's schema-per-tenant
   conclusion"). Confirmed correct on inspection — no contradiction.

2. **0001 (Phoenix) vs. 0002 (`ueberauth_oidcc`).** 0001's Dimension C and
   0002's Reasoning cross-reference each other directly and reach the same
   conclusion from both sides: OIDC library attachment is a `Plug`/supervised
   OTP-worker concern (`Oidcc.ProviderConfiguration.Worker` under
   `Letflow.Application`'s supervisor), not a Phoenix-specific mechanism, so
   it sits identically under Phoenix's pipeline or a hand-rolled Plug chain.
   `assent` (the only other candidate 0001 also names) is likewise
   Plug-based. No constraint in either direction. Confirmed correct — this is
   the one pair both records already checked against each other explicitly;
   review here found nothing that pair missed.

3. **REQ-013 check-gate vs. 0001/0002/0003.** `mix letflow.check` (`format
   --check-formatted` → `compile --warnings-as-errors` → `test`) makes no
   assumption about router (Phoenix vs. Plug/Bandit), OIDC library, or schema
   strategy — it is generic build tooling that runs unchanged regardless of
   what any of the other three decisions choose. Nothing in 0001/0002/0003
   invalidates it; nothing in it constrains them. No contradiction, and none
   plausible given what the gate actually checks.

4. **0003's schema-per-tenant vs. S1's actual scope.**
   `docs/migration/stage-1-identity.md` as currently written only lists
   `docs/migration/decisions/0002-oidc-integration.md` under its own
   "Decisions" section and doesn't yet mention 0003 or schema-per-tenant
   anywhere — expected, since S1 hasn't been expanded into requirements yet
   and its scope note predates REQ-012 landing. This is not a contradiction
   between decisions; it's a forward pointer S1's own CODE-DESIGNER pass
   needs to pick up when `users`/`tenant`/binding tables are designed: those
   tables fall under 0003 Decision B like every other business table
   (schema-per-tenant, `tenant_id` retained intra-schema), not under a
   tenant-column-only model. Recommend S1's stage doc gain an explicit line
   citing 0003 Decision B when it's next expanded, alongside its existing
   0002 citation — noted here as a forward-looking scope item, not a S1-start
   blocker, since nothing currently in stage-1-identity.md asserts or implies
   the wrong model; it simply hasn't asserted a model yet.

**ISS-0006 / ISS-0007 disposition:** both were filed by REVIEWER during
REQ-012's own WF-02 Step 2d as exactly this class of cross-decision-consistency
follow-up. Re-checked here rather than assumed resolved:

- **ISS-0006** (`docs/guides/backend_developer_guide.md` §5 still says
  "Multi-tenancy — not decided yet," should point at 0003) remains open and
  legitimately so — it's a documentation-currency fix with no code or
  decision-record impact, doesn't block S1 starting, and is correctly
  tracked for whoever next touches that guide.
- **ISS-0007** (confirm S2/S3 design artefacts correctly read 0003 Decision B
  as schema-per-tenant, not tenant-column-only, when their own schema work
  starts) remains open and legitimately so, scoped to S2/S3 as filed. Item 4
  above extends the same concern to S1's identity/tenant-binding tables,
  which ISS-0007 as filed does not currently name — worth widening ISS-0007's
  `affected_files` to include `docs/migration/stage-1-identity.md`, or filing
  a sibling issue, when S1 is next expanded; not done here since this task's
  scope is the S0 cross-decision review itself, not issue triage.

**Summary of what was read for this review:** all four decision records in
full (0001, 0002, 0003, and the REQ-013 `mix.exs` `aliases/0`/`cli/0` +
`docs/status/requirement_status.yaml` REQ-013 entry standing in for a formal
decision file), this file's existing structure, `stage-1-identity.md` to
confirm what S1 concretely needs from S0, and ISS-0006/ISS-0007 to confirm
neither represents an unresolved contradiction blocking this verdict.
