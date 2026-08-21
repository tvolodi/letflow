# Mobile tier — functional requirements

**`MOB-1` … `MOB-8`.** Migrated from R-Co's `BRW-MOB-*` (see
[`README.md`](README.md) for the renumbering rationale). Nothing here is
implemented.

**Priority notation** matches `docs/frontend/frontend-requirements.md`:
**MUST** — no v1 without it. **SHOULD** — strongly recommended, defer only with a
documented reason. `[S]` marks a hardening item required before a corporate-tier
deployment, not before v1.

Where R-Co's text said **VERIFY** against its own backend, this document records
the result of verifying against **Letflow's** backend on 2026-08-21 instead. See
[`architecture.md`](architecture.md) §3 for the evidence behind each.

---

## MOB-1 — Generic definition-interpreter mobile app

**Priority:** MUST · **Depends on:** existing definition contracts

The platform MUST provide a mobile application (`apps/mobile/`) that is a
generic interpreter of server-delivered definitions. It MUST ship a single
tenant-agnostic build with no per-tenant code or assets, and MUST execute no
tenant-authored formula or script logic on-device in v1 — all evaluation
server-side, identical to the SPA.

**Acceptance criteria**

- A single build artifact authenticates against and renders for at least two
  distinct tenants without a rebuild.
- Static inspection of the bundle finds no tenant identifiers, no formula
  evaluator, and no script runtime compiled in.
- All computed-field and visibility evaluation traffic resolves to the server
  formula endpoint — verifiable from a request log, not from code reading.

---

## MOB-2 — Tenant bootstrap sequence

**Priority:** MUST · **Depends on:** MOB-1, and an unauthenticated tenant-config
endpoint (**gap** — see below)

The app MUST resolve tenant identity from a deep-link subdomain or manual slug
entry, fetch an unauthenticated tenant configuration, authenticate via OIDC
Authorization-Code + PKCE through the platform browser, store tokens in
OS-secure storage, and load the user profile and permissions before showing any
tenant content.

**Acceptance criteria**

- `GET /tenant-config` returns `{ realm_url, locales, default_locale, branding,
  environment_kind }` **without a bearer token**.
- OIDC runs in Custom Tabs (Android) / `SFSafariViewController` (iOS) — **never**
  an embedded webview.
- Dedicated error screens exist for each of: tenant-not-found,
  network-unavailable, OIDC-failure, secure-storage-unavailable.

**Letflow gap (verified 2026-08-21).** `Letflow.Routers.TenantConfig` is a stub
whose routes land in `REQ-078` (`pending`), and `Letflow.Plugs.ApiPipeline`
mounts it behind `Letflow.Plugs.AuthPipeline`. An unauthenticated tenant-config
therefore needs both the route *and* a pipeline placement that does not demand a
token. This is the tier's single blocking dependency.

---

## MOB-3 — Offline definition cache, delta sync, version pinning

**Priority:** MUST · **Depends on:** MOB-2, and two backend gaps

The app MUST cache definitions locally keyed by `(type, id, version)`, render
from cache on launch without a definition spinner, and refresh via background
delta sync. A pinned interaction — a task payload carrying
`{ form_id, form_version }` — MUST render the exact pinned version and MUST NOT
silently fall back to the active version.

**Acceptance criteria**

- `GET /definitions/delta?since=<ts>` returns only changed definitions.
- Airplane-mode launch renders previously cached definitions.
- A pinned form whose version is missing from the cache triggers a server fetch.
  It **never** substitutes the active version — substituting silently is the
  failure this requirement exists to prevent.

**Letflow gaps (verified 2026-08-21).** Neither touch-point exists: there is no
`delta` route under `Letflow.Routers.Definitions`, and `form_id` / `form_version`
appear nowhere in `lib/`. The engine pins *definition* versions
(`Letflow.Engine.PinResolver`); emitting a pinned **form** version on a task
payload is a separate contract.

---

## MOB-4 — Generic renderers with six mandatory states

**Priority:** MUST · **Depends on:** MOB-3, and the form/list/task APIs

The app MUST provide form, list, process-instance, and task-inbox renderers
driven by the same server definition format as the SPA. Every renderer MUST
handle all six states: **loading, fetch-failure, permission-denied,
stale-version, validation-error, 429-backpressure.**

**Acceptance criteria**

- The form renderer supports every platform field type: text, number, boolean,
  date, datetime, select, multi-select, reference, file, computed, hidden.
- The list renderer supports filtering and keyset pagination.
- The task renderer supports inbox, claim, and complete against the task API.
- A forced `429` produces a retry-after countdown, not a crash.

The six states are not a UI-polish item. They are the mechanism by which a
client that has drifted from the server's definition format fails **loudly**
instead of mis-rendering — see [`architecture.md`](architecture.md) §5.

---

## MOB-5 — On-device security

**Priority:** MUST · **Depends on:** MOB-2

Tokens MUST be stored only in OS-secure storage (Keychain /
EncryptedSharedPreferences), never in plain preferences and never in logs. The
token audience MUST be scoped to the tenant realm. Cleartext traffic MUST be
disabled. Secret values MUST be masked by default, with one-time reveal on
creation.

**Acceptance criteria**

- Static check: no token value reaches a log sink; no plaintext-preferences API
  is used for tokens.
- Android `network-security-config` and iOS ATS both forbid cleartext.
- `[S]` Certificate pinning and root/jailbreak detection are **documented as
  required before any corporate-tier deployment** — documented in v1, not
  necessarily implemented in v1.

This requirement is the mobile counterpart of
`docs/agents/instructions/security-invariants.md`. A change touching token
storage, audience scoping, or transport security is a security-gated change.

---

## MOB-6 — API client with auth, refresh, retry, typed errors

**Priority:** SHOULD · **Depends on:** MOB-2

All network access SHOULD go through a **single** API client that attaches the
bearer token, performs a silent refresh on `401` and then retries the original
request, applies exponential backoff on `5xx`, and normalises every error to a
typed `ApiError` before it reaches UI state.

**Acceptance criteria**

- A `401` mid-session triggers exactly one silent refresh plus one retry.
- On refresh failure, tokens are cleared and the user is routed to login.
- No raw transport exception reaches a widget.

This mirrors the SPA's `raw-fetch-outside-client` guard (`web/tests/guards/`),
which enforces the same single-client rule statically. The mobile tier should
acquire an equivalent static check rather than relying on review.

---

## MOB-7 — Internationalisation

**Priority:** SHOULD · **Depends on:** MOB-4

All user-visible strings SHOULD come from localisation resources — no hardcoded
strings. The locale set and fallback chain MUST match the platform's web locale
policy.

**Acceptance criteria**

- Tenant content resolves from the session locale using the same
  `{locale: value}` map the SPA uses.
- Date and number formatting follow the session locale.

**Letflow note.** R-Co's text said to verify the SPA's configured locales and
reuse them rather than assuming a set. That verification has **not** been done
against the migrated `web/`: it declares `intl`-style locale handling nowhere
obvious, and `docs/frontend/` states only that dates render in the browser
locale with UTC ISO 8601 on the wire. Establishing the platform's locale policy
is prerequisite work for this requirement, and it is a **frontend** question
before it is a mobile one.

---

## MOB-8 — v1 scope boundary

**Priority:** MUST · **Depends on:** MOB-4

v1 MUST be online-first with a read-through definition cache. Offline writes,
push-based cache invalidation, and an on-device form builder MUST be out of v1
scope and recorded as deferred.

**Acceptance criteria**

- No optimistic offline write queue exists in v1.
- The scope table in [`architecture.md`](architecture.md) §4 matches the shipped
  feature set.

A requirement whose content is "do not build these three things" looks odd until
you have watched an offline cache grow an offline write queue one reasonable
commit at a time. It is a gate, and it belongs in the acceptance criteria of the
requirement that ships the cache.
