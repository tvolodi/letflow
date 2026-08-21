# Mobile tier — architecture

**Status:** specification only; nothing built. See [`README.md`](README.md) for
provenance and [`../migration/stage-9-mobile.md`](../migration/stage-9-mobile.md)
for where this sits in the migration plan.

---

## 1. Governing principle

The mobile app is a **generic interpreter of server-delivered definitions** —
identical in principle to the React SPA in `web/`.

- One **tenant-agnostic build** serves every tenant.
- The app ships **renderers** that operate over JSON definitions fetched at
  runtime.
- **No per-tenant code or assets are bundled.**
- In v1 the app executes **no tenant logic on-device**. All formula and script
  evaluation stays server-side, exactly as the SPA does.

This reuse of principle is what makes the tier cheap: it consumes the *same*
server contracts the SPA already exposes — definition fetch, form/list/process/
task APIs, batched formula evaluation, version-pinned task payloads.

## 2. Placement and stack

```
apps/mobile/                 # new top-level app, peer to web/
  lib/
    bootstrap/   auth/   api/   definitions/
    renderers/   form/ list/ process/ task/
    features/    design_system/   i18n/   shared/
```

Stack — backend-agnostic, which is why it transferred unchanged from a Zig
platform to an Elixir one:

| Concern | Choice |
|---|---|
| Framework / language | Flutter 3.x · Dart 3 |
| Routing | `go_router` |
| State | `Riverpod` |
| HTTP | `Dio` |
| Auth | `flutter_appauth` — OIDC Authorization-Code + PKCE |
| Token storage | `flutter_secure_storage` (Keychain / EncryptedSharedPreferences) |
| Local cache | Isar, or equivalent local store |
| i18n | `intl` |

Platform targets: **Android API 26+**, **iOS 15+**.

The stack choice is recorded as
[`../migration/decisions/0012-mobile-tier-stack.md`](../migration/decisions/0012-mobile-tier-stack.md),
which also covers why the tier is not folded into `web/` as a responsive
breakpoint.

## 3. What the tier needs from Letflow's backend

Three touch-points, and **only** three — everything else is client-side.
R-Co's version of this section carried them as *"verify against the backend."*
Verified against Letflow on **2026-08-21**, all three are gaps:

| # | Needed | State in Letflow (verified 2026-08-21) |
|---|---|---|
| 1 | An **unauthenticated** `tenant-config` endpoint returning `{ realm_url, locales, default_locale, branding, environment_kind }`, for slug-based bootstrap before any token exists. | `Letflow.Routers.TenantConfig` exists but is a **stub** — its routes land in `REQ-078` (`pending`). More importantly it is mounted by `Letflow.Plugs.ApiPipeline` *behind* `Letflow.Plugs.AuthPipeline`, so even once implemented it will require a token the bootstrap sequence does not have yet. **Both an implementation gap and a pipeline-placement gap.** |
| 2 | A **definition delta-sync** endpoint, `GET /definitions/delta?since=…`, so a device can warm an offline cache and refresh incrementally. | Absent. No `delta` route exists under `Letflow.Routers.Definitions`. Was flagged as *"may be new"* in R-Co too — it is genuinely new work, not a port. |
| 3 | **Version-pinned task payloads** carrying `{ form_id, form_version }`. | Absent — `form_id` and `form_version` appear nowhere in `lib/`. Version pinning exists in the engine for *definitions* (`Letflow.Engine.PinResolver`), but task payloads carrying a pinned **form** version is a separate contract the task API does not yet emit. |

Gap 1 is the blocking one: without an unauthenticated tenant-config, the app
cannot reach the point of showing a login screen. Gaps 2 and 3 block `MOB-3`
(cache/delta/pinning) but not the shell.

These three are why S9 depends on S4 rather than running as a fully independent
track. R-Co could treat mobile as parallel-from-day-one because its backend was
already shipped; Letflow's is not.

## 4. v1 boundary

v1 is **online-first with a read-through definition cache.**

Explicitly **out** of v1, and recorded as deferred rather than forgotten:

- Offline **writes** — no optimistic write queue. This is the important one:
  offline writes require a conflict model the platform does not have and does
  not currently need.
- Push-based cache invalidation.
- An on-device form builder.

Keeping these out is what makes the tier *additive*. Each of them, added, would
pull a new subsystem into the backend rather than a new screen into the app.

## 5. Relationship to `web/`

The SPA and the mobile app are **two clients of one contract**, not two
codebases with a shared core. They share no code — one is TypeScript/React, the
other Dart/Flutter — and that is accepted deliberately. What they share is the
definition format and the API, and that sharing is enforced by both consuming
the same endpoints rather than by a common library.

Practically: when a definition-format change lands, it must be applied to both
renderers. There is no compiler that will catch a miss. The mitigation is that
the format is server-delivered and versioned, so a stale client fails loudly on
an unknown field rather than silently mis-rendering — `MOB-4`'s six mandatory
renderer states exist for exactly this reason.
