# Stage 9 — Mobile tier

Status: in progress. Depends on: S4. Requirements: `REQ-124`..`REQ-127`, `REQ-282`,
`REQ-289`..`REQ-294`, `REQ-385`, `REQ-417`..`REQ-430`.

Created 2026-08-21. See
[`decisions/0012-mobile-tier-stack.md`](decisions/0012-mobile-tier-stack.md) for
why this stage exists, why the stack is inherited unchanged, and why it depends
on S4 rather than running as a parallel track.

## Scope

Build the mobile tier specified in [`../mobile/`](../mobile/): a Flutter app
that is a **generic interpreter of server-delivered definitions**, on the same
principle as the React SPA in `web/`. One tenant-agnostic build serves every
tenant; no per-tenant code or assets are bundled; no tenant logic executes
on-device in v1.

The specification is eight requirements, `MOB-1` … `MOB-8`
([`../mobile/requirements.md`](../mobile/requirements.md)), built in the order
set out in [`../mobile/build-order.md`](../mobile/build-order.md).

## This stage ports nothing

Unlike S1–S8, there is no R-Co source directory to migrate. R-Co's own baseline
recorded the tier as *"Absent — no `apps/mobile`, no mobile architecture doc.
New subsystem. Largest addition."* Confirmed on 2026-08-21: a search of R-Co for
`pubspec.yaml`, `*.dart`, `*.kt`, `*.swift`, `app.json`, and `capacitor.config.*`
found nothing, and `web/package.json` declares no React Native, Expo, Capacitor,
Ionic, or Tauri dependency.

What was migrated is the **specification** — R-Co's `docs/addon-2/` §3 and its
`BRW-MOB-*` requirements, renumbered `MOB-*`. This stage is therefore
greenfield build work against a ported spec, not a port.

## The three backend gaps are this stage's real risk

Verified against `lib/` on 2026-08-21. All three of the tier's backend
touch-points are absent:

| Needed by | Touch-point | State |
|---|---|---|
| `MOB-2` | **Unauthenticated** `tenant-config` returning `{ realm_url, locales, default_locale, branding, environment_kind }` | Closed by `REQ-124`, done 2026-08-22 (`docs/status/requirement_status.v3.yaml` line 463). `Letflow.Routers.TenantConfig` was a stub, mounted behind `Letflow.Plugs.AuthPipeline`; REQ-124 shipped the unauthenticated route and its pipeline placement. |
| `MOB-3` | `GET /definitions/delta?since=…` | Closed by `REQ-125`, done 2026-08-23 (`docs/status/requirement_status.v4.yaml` line 275) — `Letflow.Routers.Definitions` delta route, monotonic per-tenant cursor, tenant-isolated. |
| `MOB-3` | `{ form_id, form_version }` on task payloads | Closed by `REQ-126`, done 2026-08-22 (`docs/status/requirement_status.v3.yaml` line 419). `Letflow.Engine.PinResolver` pins *definition* versions; REQ-126 added the pinned **form** version on task payloads as its own contract. |

The first is the gate for the entire tier — without it the app cannot reach a
login screen. This is why the stage depends on S4, and why
`../mobile/build-order.md` puts gap-closing in phase **M-0** rather than
treating it as preamble. **A mobile-shaped estimate will silently omit M-0**;
it is backend work and it is the majority of the risk.

## Roles

Dart/Flutter sits outside every current agent's competence. `MOBILE-DEV` and its
validating counterpart are registered in
[`../agents/AGENT_SYSTEM.md`](../agents/AGENT_SYSTEM.md) — defined on 2026-08-21 so
the role would not be invented under pressure when the stage starts, and reactivated
by `REQ-417` on 2026-09-27 now that all three backend gaps above are closed.

## Why S9 does not depend on S8

The two clients are independent: they share a contract, not code. Making the
mobile tier wait for the SPA's cutover would serialise two things with no
build-order relationship.

The one real coupling is `MOB-7` (i18n), which must reuse "the platform's web
locale policy" — a policy that does not currently exist in stated form. That is
a single `SHOULD` requirement's prerequisite, recorded in
`../mobile/requirements.md`, and it is a frontend question before it is a mobile
one. It is not a stage dependency.

## Decisions

- [`decisions/0012-mobile-tier-stack.md`](decisions/0012-mobile-tier-stack.md) —
  adopt R-Co's Flutter specification, as its own stage depending on S4. Also
  settles why the tier is not folded into `web/` as a responsive breakpoint.
- **Not yet needed:** anything about offline write conflict resolution.
  `MOB-8` explicitly defers offline writes out of v1, and deciding a conflict
  model for a feature that is out of scope would be designing ahead of the
  requirement.

## REVIEWER sign-off

`REQ-418` (2026-09-27, `WF02-REQ418-20260927`): public PKCE-S256 Keycloak
client `letflow-mobile` added to `priv/keycloak/realms/bpm-default.json`
(custom-scheme redirect only, no wildcards) and its `client_id` exposed as a
sixth key on `GET /api/mobile/tenant-config`. SECURITY-REVIEWER PASSed
(identity-configuration + public-response-shape gate,
`docs/agents/instructions/security-invariants.md`) and REVIEWER PASSed;
RELEASE-VALIDATOR independently re-verified all 8 acceptance criteria,
including the live-Keycloak integration test against a real container. This
is the first real mobile-tier code to land — the stage is no longer
docs-only.

## Phase-gate evidence and deferrals (`REQ-430`, 2026-10-01)

Per [`../mobile/build-order.md`](../mobile/build-order.md)'s "Phasing"
table, each of the three post-M-0 phase gates is demonstrated by real
`flutter test` coverage, cited here by file:

| Phase | Gate | Demonstrated by |
|---|---|---|
| **M-1** | A build authenticates two distinct tenants and stores tokens securely | `apps/mobile/test/auth/authenticate_with_tenant_test.dart`, `apps/mobile/test/auth/tenant_token_store_test.dart`, `apps/mobile/test/auth/audience_scoping_test.dart`, `apps/mobile/test/bootstrap/bootstrap_sequence_test.dart`, `apps/mobile/test/bootstrap/tenant_switch_test.dart`, `apps/mobile/test/guards/token_storage_boundary_guard_test.dart` |
| **M-2** | Airplane-mode launch renders cached definitions; pinned versions never substitute | `apps/mobile/test/definitions/definition_sync_service_test.dart`, `apps/mobile/test/definitions/sembast_cache_repository_test.dart`, `apps/mobile/test/definitions/active_definition_cache_holder_test.dart`, `apps/mobile/test/definitions/pinned_form_resolver_test.dart`, `apps/mobile/test/definitions/sembast_pinned_form_cache_repository_test.dart`, `apps/mobile/test/renderers/task/task_pinned_version_test.dart` |
| **M-3** | All six renderer states demonstrable, including a forced `429` | `apps/mobile/test/renderers/renderer_state_view_ac1_test.dart` (loading/fetch-failure/permission-denied/stale-version/validation-error), `apps/mobile/test/renderers/renderer_state_view_ac2_backpressure_countdown_test.dart` (forced 429), `apps/mobile/test/renderers/form/form_expression_unevaluable_test.dart`, `apps/mobile/test/renderers/task/task_claim_conflict_test.dart`, `apps/mobile/test/guards/v1_scope_boundary_guard_test.dart` (the MOB-8 gate itself) |

### Deferred, with reasons

| Item | Reason deferred |
|---|---|
| iOS build and iOS-runtime checks (`flutter build ios`, device/simulator verification) | This host is Windows; no iOS toolchain (Xcode) is available to build or run an iOS target. All iOS-specific configuration (`ios/Runner/Info.plist` ATS settings, etc.) is reviewed statically (`apps/mobile/test/guards/ios_ats_guard_test.dart`) but never built or run. |
| Interactive OIDC login against a real Keycloak realm (an actual browser-based Authorization-Code+PKCE round trip, not the `fake_app_auth_adapter.dart`-substituted flow `flutter test` exercises) | Requires a live instance and a real human-equivalent browser interaction; out of reach for `flutter test`'s unit/widget harness. Exercised instead by `UAT-RUNNER` against a real running instance, matching the project's stated division between `TEST-RUNNER`'s `flutter test` coverage and `UAT-RUNNER`'s scenario-based live checks. |

`flutter analyze`, `flutter test`, and `flutter build apk --debug` are all
run and their real output recorded by `TEST-RUNNER`/`MOBILE-DEV` at
implementation time (REQ-430 AC5); this section records *which* gates map
to *which* test files, not the run output itself.

Stage REVIEWER sign-off and the stage/requirement status flips remain with
`REVIEWER` and `DOC-UPDATER`, per this stage file's existing convention —
not duplicated here.
