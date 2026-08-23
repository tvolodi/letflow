# Stage 9 — Mobile tier

Status: not started. Depends on: S4. Requirements: `REQ-123` … `REQ-126`.

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
| `MOB-2` | **Unauthenticated** `tenant-config` returning `{ realm_url, locales, default_locale, branding, environment_kind }` | `Letflow.Routers.TenantConfig` is a stub — routes land in `REQ-078` (`pending`) — **and** `Letflow.Plugs.ApiPipeline` mounts it behind `Letflow.Plugs.AuthPipeline`, so implementing the route is not sufficient. The bootstrap sequence has no token at that point. |
| `MOB-3` | `GET /definitions/delta?since=…` | Implemented (`REQ-125`, 2026-08-23) — `Letflow.Routers.Definitions` delta route, monotonic per-tenant cursor, tenant-isolated. |
| `MOB-3` | `{ form_id, form_version }` on task payloads | Absent — neither identifier appears anywhere in `lib/`. `Letflow.Engine.PinResolver` pins *definition* versions; a pinned **form** version on a task payload is a separate contract. |

The first is the gate for the entire tier — without it the app cannot reach a
login screen. This is why the stage depends on S4, and why
`../mobile/build-order.md` puts gap-closing in phase **M-0** rather than
treating it as preamble. **A mobile-shaped estimate will silently omit M-0**;
it is backend work and it is the majority of the risk.

## Roles

Dart/Flutter sits outside every current agent's competence. `MOBILE-DEV` and its
validating counterpart are registered in
[`../agents/AGENT_SYSTEM.md`](../agents/AGENT_SYSTEM.md) as **dormant** — defined
now so the role is not invented under pressure when the stage starts, and marked
dormant so nothing routes to them before then.

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

(None yet — the stage has not started. The 2026-08-21 migration landed the
specification and this stage file; no mobile code exists.)
