# 0012 — Mobile tier: adopt R-Co's Flutter specification, as its own stage

Status: decided (2026-08-21, user-directed). Owner: REQ-ANALYST.

## Question

R-Co specified a mobile tier in `docs/addon-2/` and never built it — its own
baseline table recorded *"Mobile tier: **Absent** — no `apps/mobile`, no mobile
architecture doc. New subsystem. Largest addition."* Letflow's stage list
(S0–S8) had no mobile stage at all, so the specification had nowhere to land.

Three questions, settled together: does Letflow take the mobile tier on at all;
if so does it inherit R-Co's Flutter/Dart stack or re-decide it; and where does
it sit in a dependency chain that currently ends at S8?

## Decision

**Yes, inherit, and as a new stage S9 depending on S4.**

1. **Letflow takes the tier on.** The specification is migrated to
   `docs/mobile/` and is Letflow's, not a reference copy of R-Co's.
2. **The stack is inherited unchanged:** Flutter 3.x · Dart 3 · `go_router` ·
   Riverpod · Dio · `flutter_appauth` (OIDC Auth-Code + PKCE) ·
   `flutter_secure_storage` · a local definition cache (Isar or equivalent) ·
   `intl`. Targets Android API 26+, iOS 15+.
3. **It becomes stage S9 (`mobile-tier`), depending on S4** — not S7, and not a
   fully parallel track.

Requirement IDs are renumbered `BRW-MOB-N` → `MOB-N`. `BRW-` meant "borrowed
from ASCOA-GO", a fact about R-Co's planning process with no meaning here.

## Reasoning

### Why inherit the stack rather than re-decide it

The stack is **backend-agnostic**, which is exactly why it survived the move
from a Zig platform to an Elixir one without a line changing. Nothing in the
choice of Flutter, Riverpod, or Dio depends on what serves the JSON. Re-opening
it would be re-deciding a settled question at the cost of a stage's delay, with
no Elixir-side input that would change the answer.

This is `CLAUDE.md`'s rule applied in the ordinary direction: *"Don't silently
re-decide what a decision record already settled."* R-Co's specification is the
prior art the migration exists to carry over. Where it needs correcting, correct
it explicitly — which is what the dependency change below does.

### Why the tier is not just a responsive breakpoint on `web/`

A fair challenge, since `docs/frontend/frontend-requirements.md` already
requires the Task Inbox to work at 375 px (`FNFR-07`, `TK-UI-10`), and
`docs/frontend/design-system.md` defines a `mobile` breakpoint. So the SPA
already claims a phone story.

It is not sufficient for what `MOB-*` specifies, on three counts the browser
cannot cover:

- **OS-secure token storage** (`MOB-5`): Keychain / EncryptedSharedPreferences.
  A browser has no equivalent, and the SPA's own `FNFR-06` reflects this by
  forbidding token storage in `localStorage`/`sessionStorage` entirely.
- **Offline launch from a local definition cache** (`MOB-3`): rendering cached
  definitions in airplane mode, with version pinning that never silently
  substitutes an active version.
- **Native OIDC via Custom Tabs / `SFSafariViewController`** (`MOB-2`), which the
  requirement mandates precisely *instead of* an embedded webview.

The overlap with the SPA's mobile breakpoint is real but narrow: it covers
"a task worker completes a task on a phone with signal", not "a field worker
opens the app on a train."

### Why S9 depends on S4, correcting R-Co's plan

R-Co's implementation order stated ordering principle #4: *"Mobile is an
independent track. It depends only on existing server contracts, so it runs in
parallel with the entire backend sequence from day one."*

**That reasoning does not transfer, and copying it would be an error.** It was
sound for R-Co because R-Co's backend was shipped — "existing server contracts"
existed to depend on. Letflow's do not. All three of the tier's backend
touch-points were verified against `lib/` on 2026-08-21 and all three are gaps:

| Needed by | Touch-point | State in Letflow |
|---|---|---|
| `MOB-2` | **Unauthenticated** `tenant-config` | `Letflow.Routers.TenantConfig` is a stub (routes land in `REQ-078`, `pending`), *and* it is mounted behind `Letflow.Plugs.AuthPipeline` — so it will require a token the bootstrap sequence does not yet have. |
| `MOB-3` | `GET /definitions/delta?since=…` | Absent. Genuinely new work — R-Co flagged it "may be new" too. |
| `MOB-3` | `{ form_id, form_version }` on task payloads | Absent; neither identifier appears anywhere in `lib/`. The engine pins *definition* versions (`Letflow.Engine.PinResolver`); a pinned **form** version on a task payload is a separate contract. |

The first is blocking: without an unauthenticated tenant-config the app cannot
reach a login screen. Hence S9 depends on S4 (api-surface), where those routes
live. Within S9 there is still useful parallelism — the app shell (`MOB-1`)
renders whatever the server sends and needs the definition *format*, not the
endpoints — but "parallel from day one" is a conclusion whose premise Letflow
does not have.

### Why S9 does not depend on S8

The two clients are independent of each other. They share a contract, not code —
one is TypeScript/React, the other Dart/Flutter. Making the mobile tier wait for
the SPA's cutover would serialise two things that have no build-order
relationship.

The one genuine coupling is `MOB-7` (i18n), which requires reusing "the
platform's web locale policy". That policy does not currently exist in a stated
form — the migrated `web/` does not declare one, and `docs/frontend/` says only
that dates render in browser locale with UTC ISO 8601 on the wire. That is
recorded as prerequisite work in `docs/mobile/requirements.md`, and it is a
frontend question before it is a mobile one. It is a single `SHOULD`
requirement's dependency, not a stage's.

## Consequences

- New stage **S9 `mobile-tier`**, `depends_on: [S4]`, detail file
  `docs/migration/stage-9-mobile.md`. S8 is no longer the last stage, and the
  migration chain no longer ends at cutover.
- `docs/mobile/` holds the tier's architecture, its eight requirements, and its
  build order. Nothing is implemented; `apps/mobile/` does not exist.
- Building the tier will need a `MOBILE-DEV` role and its validating
  counterpart, since Dart/Flutter sits outside every current agent's competence.
  The role is added to the roster now, explicitly dormant, rather than invented
  under time pressure when S9 starts.
- R-Co's other `BRW-*` families (`ENG`, `EFX`, `SAGA`, `SEC`, `OPS`) are **not**
  migrated by this record. They are backend borrows belonging to S3/S6, and
  folding them in here would smuggle unrelated scope through a mobile decision.
  They remain in R-Co's `docs/addon-2/`, unported, and are a known gap.
