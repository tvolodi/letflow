# Stage 11 — Modular platform (platform / module / solution / tenant configuration)

Status: P1–P3 requirements done. Requirements REQ-400 through REQ-416 filed and all
`done`. P3 close-out end-to-end proof: `test/letflow/modules/bilimbaga_solution_e2e_test.exs`
(REQ-416) installs the bilimbaga solution into a fresh tenant via the real HTTP route and
verifies the full exam-tenant path end-to-end (solution install → module listing → entity
definition/restriction verification → exam seeding → candidate session flow → TASK_WORKER
answer-key redaction → 404-for-uninstalled-tenant). Depends on: S10. Created 2026-09-24.

See [`decisions/0039-platform-module-solution-layering.md`](decisions/0039-platform-module-solution-layering.md)
for why this stage exists and for decisions D1–D8, which every requirement in this
stage is gated against. Like S9 and S10, this stage ports no R-Co source.

## Scope

Introduce the **application module** layer between the platform core and a
tenant, make a **solution** a manifest of modules, and move BilimBaga's exam
domain out of the platform into the first module, `exam`. No new business
module (HR, WMS, ERP, project management, …) is built in this stage (0039 D8).

For the end-to-end module contract this stage produced — layout, the
`Letflow.Modules.Module` behaviour, permissions/role_grants/route_policies,
router mounting and the 404 gate, pack location and `on_install/2`,
registration, `tenant_modules` backfills, settings, solution manifests, the
frontend registry, and the boundary checks — see
[`../guides/adding-an-application-module.md`](../guides/adding-an-application-module.md),
the guide a future module's implementer should build from rather than
reverse-engineering `exam`.

## Phases

| Phase | Goal | Done when |
|---|---|---|
| **P1 — Module mechanism** | `Letflow.Modules.Module` behaviour, `Letflow.Modules.Catalog`, the `tenant_modules` table + install/list context (`Letflow.Modules.Installs`) and HTTP routes gated by the new `:ModulesManage` permission (0039 D5), Catalog-sourced module permissions and `role_grants` in `Letflow.Api.Authorization` (0039 D4), the `404`-for-uninstalled gate on `/api/v1/modules/<id>/…`, installed modules on `GET /me`, `mix letflow.check_boundaries` in CI, the ESLint boundary rule, and `web/src/modules/registry.ts`, which builds routes and nav from the installed list. Proven with a test-only fixture module, **before** any exam code moves. | All P1 requirements `done`; boundary check green in CI; a fixture module installs, grants its permissions and is 404-gated for a tenant without it, per 0039 D4/D5, in tests. No uninstall (0039 D5). | ✅ Done — REQ-400 through REQ-407. |
| **P2 — Extract `exam`** | Move `lib/letflow/exam/` → `lib/letflow/modules/exam/`, `Letflow.Routers.ExamSessions` → the module's `router/0` (URL becomes `/api/v1/modules/exam/…`), the six exam permission atoms and `CANDIDATE`'s grants → the module's `permissions`/`role_grants`, a migration backfilling a `tenant_modules` `exam` row for every tenant with a bilimbaga `solution_pack_installs` row, every live `/exam-sessions` caller listed in 0039 "Consequences" updated, `Letflow.Packs.Bilimbaga` → the module's `on_install/2`, `priv/packs/bilimbaga/` → `priv/modules/exam/`, `web/src/pages/exam/` + the `/exam` and `/admin/bilimbaga` nav items → `web/src/modules/exam/`. | All three measurements in 0039 "Consequences" hold; full backend suite and the S10 Playwright specs green. | ✅ Done — REQ-408 through REQ-414. |
| **P3 — Solutions** | `priv/solutions/<id>.json` format, solution install (modules in dependency order + default settings), `priv/solutions/bilimbaga.json`, module `settings_schema` validation on settings writes (0039 D7). | Installing the `bilimbaga` solution into a fresh tenant yields a working exam tenant, verified end-to-end. | ✅ Done — REQ-415 (Solutions install context) + REQ-416 (E2E proof in `test/letflow/modules/bilimbaga_solution_e2e_test.exs`). |

Sizing rule unchanged: each requirement is one agent turn; a WF-02 run covers at
most 4 requirements (`ORCHESTRATOR.md`).

## Hard constraints for every S11 requirement

1. **No behaviour change for BilimBaga users** other than the URL prefix move in
   P2. Every existing exam test keeps passing, moved alongside its code.
2. **INV-1 applies to every new write path** (`tenant_modules`, install,
   settings) — tenant scope comes from the authenticated connection's `prefix`,
   never from a caller-supplied id. `SECURITY-REVIEWER` gates P1's install routes
   and P3's settings writes.
3. **No new hex or npm dependency** for the boundary checks (0039 D3).
4. **The pack section set stays closed** (0026/0027/0029). A requirement that
   needs a new pack section is out of scope for S11 and needs its own decision.

## Open items — recorded, not expanded

- **Module uninstall.** Needs a decision on what happens to the module's
  definitions and tenant data; S11 builds install and list only (0039 D5).

- **`CANDIDATE` role.** An exam-specific role in the platform role set (0013).
  Moving it into the exam module needs its own design; not in P1–P3.
- **Tenant extension points / client Lua scripts.** Blocked on 0029 §1's
  scripted-rule registry. Needs its own decision once that exists.
- **Shared `org` foundation module.** Extracted only when a second module needs
  organisation/department/employee concepts (0039 D8).
- **Per-module versions and upgrades across tenants.** P1 records a module's
  version at install; upgrading an installed module reuses the existing pack
  update path. A dedicated module-upgrade flow is filed only if P3 shows a need.

## Module inventory (health metric, per 0022 rule 3 applied per module)

| Module | Backend lines (`lib/letflow/modules/<id>/`) | Measured |
|---|---|---|
| `exam` | 3,530 lines (`lib/letflow/modules/exam/`) | 2026-09-26 |

## REVIEWER sign-off

See 0039's sign-off section; this stage file has no separate sign-off.
