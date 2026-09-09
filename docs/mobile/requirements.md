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
tenant-authored **script** on-device — no Lua, JS or WASM runtime.

**Amended 2026-09-09** by `../migration/decisions/0020-frontend-architecture.md`
clause **D1a**. This requirement previously said "no tenant-authored formula or
script logic on-device in v1 — all evaluation server-side". Declarative field
logic in the `Letflow.Engine.Expr` grammar (`visible_when`, `computed`,
cross-field validation) is now **in scope on-device**, because `MOB-3` requires
airplane-mode launch and an offline device has no server to evaluate against.
A general scripting runtime remains out — see `MOB-4` for the full statement.

**Acceptance criteria**

- A single build artifact authenticates against and renders for at least two
  distinct tenants without a rebuild.
- Static inspection of the bundle finds no tenant identifiers and **no script
  runtime** (Lua/JS/WASM) compiled in. An evaluator for the platform's own
  `Letflow.Engine.Expr` grammar IS expected in the bundle (`REQ-294`) and is not
  a violation — it is a closed, total, effect-free grammar, not a script runtime.
- Every `computed` and `visible_when` result the client produces is
  **re-evaluated server-side on submit**, and the server's value wins —
  verifiable from a request log. The client's evaluation carries no authority;
  it exists so a cached form stays usable offline.

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

**What evaluates `computed` (added 2026-09-08).** This requirement listed
`computed` among the mandatory field types without saying what evaluates it, and
that silence was load-bearing: the first draft of
[`../migration/decisions/0020-frontend-architecture.md`](../migration/decisions/0020-frontend-architecture.md)
rejected all client-side expression evaluation, which would have made this
criterion unimplementable. That record's clause **D1a** resolves it in this
requirement's favour and supplies the missing half:

- `computed` fields, `visible_when` conditions and cross-field validation are
  expressed in the **`Letflow.Engine.Expr` grammar** — the pure CEL-subset
  evaluator already used for gateway conditions. Not a new language, and not a
  general scripting runtime, which D1a still rejects for every client.
- The client evaluates them for **interactivity only, with no authority**. The
  server re-evaluates on submit and its answer wins. A computed value arriving
  from a client is never trusted.
- All implementations — Elixir, TypeScript, Dart — must pass one
  **language-neutral conformance corpus** exported from `Letflow.Engine.Expr`'s
  own tests. Three hand-written evaluators with no shared corpus drift, and the
  drift surfaces as a wrong number on a customer's form.
- An expression this client cannot evaluate is a **`stale-version`** case — one
  of the six states above. It fails loudly; it never silently skips the field or
  guesses a value.

This is what makes offline form population work: a cached form stays fillable
with no server reachable. It does **not** make it submittable offline — MOB-8's
exclusion of offline writes is unchanged, because a write queue needs a conflict
model that D1a does not supply.

---

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
reuse them rather than assuming a set. That verification is **done** —
`REQ-127` (2026-08-22, `FRONTEND-DEV`) read `web/src/` directly and recorded
the finding in `docs/frontend/frontend-requirements.md`'s "Locale policy"
section: **there is no locale policy today.** No i18n library is installed,
no supported locale set or fallback chain exists, all 25 date-formatting call
sites use the bare unparameterised `Intl` default (one inconsistently
hardcodes `'en-US'`), and no `{locale: value}`-shaped tenant-content map
exists anywhere in `web/src/types/`. ~315 hardcoded English JSX strings would
need externalizing to adopt one.

This requirement therefore has nothing to "match" yet — `MOB-7`'s locale set
and fallback chain cannot be defined by reference to a web policy that
doesn't exist. Either the web platform adopts a real locale policy first (see
the concrete adoption cost in `docs/frontend/frontend-requirements.md`), or
this mobile requirement defines its own locale set/fallback chain
independently and accepts that it will not match the web tier, since the web
tier currently has none to match.

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
