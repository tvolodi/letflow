# `docs/mobile/` — mobile tier specification

**Nothing is built.** This directory is a specification for a subsystem that
does not exist yet, in this repository or in R-Co. It was migrated on
2026-08-21 so that the mobile tier has a home, a stage, and a dependency chain
in Letflow's own plan rather than living as an appendix in a Zig repo that is
being retired.

| File | What it is |
|---|---|
| [`architecture.md`](architecture.md) | The tier's governing principle, stack, placement, and v1 boundary |
| [`requirements.md`](requirements.md) | `MOB-1..8` — the eight functional requirements, with acceptance criteria |
| [`build-order.md`](build-order.md) | The order the eight are built in, and what each depends on |

## Provenance

Migrated from R-Co's `docs/addon-2/`, which specified the tier as a borrow from
a peer platform (ASCOA-GO) but never implemented it:

| Letflow file | R-Co origin |
|---|---|
| `architecture.md` | `docs/addon-2/01-architecture-addition.md` §3 |
| `requirements.md` | `docs/addon-2/02-functional-requirements.md`, area `MOB` (`BRW-MOB-1..8`) |
| `build-order.md` | `docs/addon-2/03-implementation-order.md` §2 "Track M" |

R-Co's own baseline table recorded the tier as **"Absent — no `apps/mobile`, no
mobile architecture doc. New subsystem. Largest addition."** That was still true
on 2026-08-21: a search of R-Co for `pubspec.yaml`, `*.dart`, `*.kt`, `*.swift`,
`app.json`, and `capacitor.config.*` returned nothing, and `web/package.json`
declares no React Native, Expo, Capacitor, Ionic, or Tauri dependency.

Requirement IDs were renumbered `BRW-MOB-N` → `MOB-N`. The `BRW-` prefix meant
"borrowed from ASCOA-GO" — a provenance fact about R-Co's planning process that
carries no meaning in Letflow. The numbering is otherwise unchanged, so
`MOB-3` is `BRW-MOB-3`. The rest of R-Co's `BRW-*` families (`ENG`, `EFX`,
`SAGA`, `SEC`, `OPS`) are **not** migrated here: they are backend work that
belongs to S3/S6, not to the mobile tier.

## Status

Covered by **S9 (mobile-tier)** in
[`../migration/stage-9-mobile.md`](../migration/stage-9-mobile.md). S9 depends
on S4, because three of the eight requirements need API endpoints that Letflow
does not serve yet — see that stage file for the verified gap list. Nothing
here is expanded into `REQ-NNN` implementation requirements beyond the spec-port
itself; that expansion happens when S4 lands.

## The one thing to understand before reading further

The mobile app is **a generic interpreter of server-delivered definitions**, on
exactly the same principle as the React SPA in `web/`. One tenant-agnostic build
serves every tenant. It ships renderers that operate over JSON definitions
fetched at runtime, and it bundles no per-tenant code or assets. In v1 it
executes **no tenant logic on-device** — every formula and script evaluates
server-side, identically to the SPA.

That single constraint is what makes the tier affordable: it consumes the same
server contracts the SPA already needs, so it adds one client, not one platform.
A change that puts tenant logic on the device is not a shortcut, it is a
different product.
