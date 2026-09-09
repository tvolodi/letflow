# REQ-285 design — Adopt an i18n layer in `web/`

Library choice: `docs/migration/decisions/0021-web-i18n-library.md` (react-intl,
rejecting i18next/react-i18next). Read that record first — this doc does not repeat its
reasoning, only its conclusion (react-intl, imperative `createIntl()` API, no
`IntlProvider`/React-context wiring in this requirement's scope).

Depends on: REQ-127 (finding, `docs/frontend/frontend-requirements.md`'s Locale policy
section), REQ-280 (`Letflow.Identity.TenantSettings`'s `locales`/`default_locale` keys
and their shape validation in `Letflow.Identity.Tenant`).

Scope fence (from REQ-285's own text, restated so this design doesn't drift from it):
adopt the library, define the supported locale set and fallback chain, wire a
session-locale concept, convert the `.toLocale*()` call sites. **Not in scope:**
translating UI strings, a locale-switcher UI, React-context (`IntlProvider`/`useIntl`)
wiring for JSX text.

---

## a. Re-verified call-site counts (re-run 2026-09-09, not inherited from 2026-08-22)

Commands re-run exactly as REQ-127 specified:

```
grep -rn "react-intl\|i18next\|formatjs" web/package.json web/src/
```
Zero hits — confirmed still absent. (Note: this design *adds* `react-intl`; the grep
above was run against the pre-change tree.)

```
grep -rn "toLocaleDateString\|toLocaleTimeString\|toLocaleString" web/src/
```
**25 grep-matched lines**, one of which (`TaskInboxPage.tsx:223`) contains two calls —
so **26 actual `.toLocale*()` invocations across 19 files** (REQ-127's record said 25
call sites / 27 grep-matched lines / 20 files on 2026-08-22 — the count has drifted
down by one call site and one file since; the surviving hardcode moved location, see
below). Full file:line list, 26 invocations:

| # | File:line | Method |
|---|---|---|
| 1 | `src/pages/admin/TokensPage.tsx:49` | `toLocaleDateString()` |
| 2 | `src/pages/admin/UsersPage.tsx:91` | `toLocaleDateString('en-US')` — **the hardcode** |
| 3 | `src/pages/dlq/WebhooksPage.tsx:285` | `toLocaleString()` |
| 4 | `src/pages/instances/InstanceBoardPage.tsx:23` | `toLocaleString()` |
| 5 | `src/pages/instances/InstanceBoardPage.tsx:28` | `toLocaleTimeString()` |
| 6 | `src/pages/tasks/TaskInboxPage.tsx:223` | `toLocaleDateString()` |
| 7 | `src/pages/tasks/TaskInboxPage.tsx:223` | `toLocaleTimeString()` (2nd call, same line) |
| 8 | `src/pages/tasks/TaskInboxPage.tsx:318` | `toLocaleString()` |
| 9 | `src/components/instances/TimelineFeedItem.tsx:18` | `toLocaleString()` |
| 10 | `src/pages/admin/HealthDashboardPage.tsx:46` | `toLocaleTimeString()` |
| 11 | `src/pages/admin/AuditLogPage.tsx:186` | `toLocaleString()` |
| 12 | `src/pages/instances/timelineUtils.ts:55` | `toLocaleDateString()` |
| 13 | `src/pages/admin/modules/ProcessModulesPage.tsx:65` | `toLocaleDateString()` |
| 14 | `src/pages/admin/modules/ProcessModulesPage.tsx:116` | `toLocaleString()` |
| 15 | `src/pages/admin/modules/ProcessModulesPage.tsx:118` | `toLocaleString()` |
| 16 | `src/components/instances/EventHistoryPanel.tsx:202` | `toLocaleString()` |
| 17 | `src/pages/dlq/DlqPage.tsx:111` | `toLocaleString()` |
| 18 | `src/pages/instances/InstanceDetailPage.tsx:46` | `toLocaleString()` |
| 19 | `src/pages/instances/InstanceDetailPage.tsx:51` | `toLocaleTimeString()` |
| 20 | `src/components/webhooks/WebhookSubscriptionDetailPanel.tsx:31` | `toLocaleString()` |
| 21 | `src/pages/admin/tenants/TenantsPage.tsx:143` | `toLocaleDateString()` |
| 22 | `src/pages/definitions/DefinitionListPage.tsx:276` | `toLocaleDateString()` |
| 23 | `src/pages/definitions/DefinitionListPage.tsx:313` | `toLocaleDateString()` |
| 24 | `src/components/definitions/DraftBanner.tsx:46` | `toLocaleTimeString()` |
| 25 | `src/components/webhooks/WebhookDeliveryAttemptsTable.tsx:11` | `toLocaleString()` |
| 26 | `src/components/promotions/PromotionReviewStateMachine.tsx:62` | `toLocaleString()` |

**The hardcoded `'en-US'` site, before and after:**
- Before: `web/src/pages/admin/UsersPage.tsx:91` —
  `{ id: 'created', header: 'Created', accessor: (u) => new Date(u.created_at).toLocaleDateString('en-US') }`.
  (REQ-127's 2026-08-22 record cited this same defect at `src/pages/admin/UsersPage.tsx:352`
  in a codebase that also then had a separate `src/pages/admin/users/UsersPage.tsx:142`;
  only one `UsersPage.tsx` exists today — `web/src/pages/admin/UsersPage.tsx`, no
  `web/src/pages/admin/users/` directory — so the file was consolidated and the
  hardcode's line number moved between 2026-08-22 and now.)
- After (per §d's migration plan below): the accessor calls the new
  `formatDate(u.created_at)` helper (§c/§d), which resolves the session locale via
  `resolveSessionLocale`/`getSessionLocale()` instead of the literal `'en-US'` — the
  literal string `'en-US'` no longer appears anywhere in this call.

**19 distinct files** contain at least one call site (not 20 — see the UsersPage
consolidation note above).

---

## b. Supported locale set and fallback chain

### Supported locale set

`PLATFORM_SUPPORTED_LOCALES` — a new, explicit, finite constant (module:
`web/src/i18n/sessionLocale.ts`). Type: `readonly string[]`. This set governs
**date/time formatting locale only** — it is decoupled from UI string translation
(which stays English-only per §e; see decision 0021's "what this decision does not
settle"). Value: 10 curated BCP-47 tags chosen to cover the language families already
implied by `Letflow.Identity.Tenant`'s `@locale_regex`
(`~r/^[a-z]{2,3}(-[A-Z]{2})?$/`, `lib/letflow/identity/tenant.ex:283`) without trying to
enumerate every shape-valid string that regex would accept:
`en`, `en-US`, `en-GB`, `es`, `es-ES`, `fr`, `fr-FR`, `de`, `de-DE`, `pt-BR`.

Rationale for a curated finite set rather than "whatever `Intl.DateTimeFormat` accepts":
`Intl.DateTimeFormat` silently accepts and formats almost any well-formed BCP-47 tag
(falling back internally to its own default for tags it doesn't fully recognize), which
makes "unsupported locale" untestable as a distinct case if "supported" just means
"syntactically well-formed." A finite, named set makes AC3's three required test cases
(a supported locale, an unsupported locale falling back, no preference at all)
concretely constructible: e.g. `es-ES` is a member (case 1), a fabricated tag like
`xx-XX` or an unlisted real one like `ja` is not a member and exercises the fallback
path (case 2), and an empty/absent preference list exercises the terminal hardcoded
fallback (case 3).

`FALLBACK_LOCALE` — a new constant, value `"en"`. This is the terminal fallback used
when neither a tenant default nor any browser-preferred locale is a member of
`PLATFORM_SUPPORTED_LOCALES`. `FALLBACK_LOCALE` MUST itself be a member of
`PLATFORM_SUPPORTED_LOCALES` (an invariant, stated so a future edit to either constant
doesn't silently break it) — chosen as bare `"en"` rather than `"en-US"` specifically
*because* `"en-US"` was the defect this requirement is removing (AC5): the terminal
fallback must not reintroduce the same US-region-specific bias as a hardcoded value
elsewhere in the app.

### Fallback chain — precedence order

1. **Tenant `default_locale`** (when supplied — see §c for why this is not wired to any
   real data source today) — wins if its value is a member of `PLATFORM_SUPPORTED_LOCALES`.
2. **Browser preference** (`navigator.languages`, falling back to `navigator.language`
   when `navigator.languages` is unavailable) — the first entry, in the browser's own
   preference order, that is a member of `PLATFORM_SUPPORTED_LOCALES`.
3. **`FALLBACK_LOCALE`** (`"en"`) — used when neither of the above yields a member.

Reasoning for this order: a tenant's own configured default is the most specific signal
available (it is what that tenant's admin explicitly chose, per REQ-280's
`Tenant.settings_changeset/2` validation) and should win over an individual visitor's
browser setting when both are known — the same precedence direction REQ-280's own
`default_locale must be one of the supplied locales` validation implies (tenant-level
configuration is the authority `default_locale` exists to express). Browser preference
is the correct middle tier because it is a real, per-visitor signal that should not be
discarded just because a tenant configured *a* default — a tenant default is a
reasonable baseline, not evidence the platform should override every visitor's own
language setting when their preference is otherwise unknown to the tenant. It only
actually wins today, in practice, because tier 1 currently never fires (see §c) — but
the precedence is specified independent of that fact so it does not need to change when
tier 1 becomes real.

### Fallback chain — testable cases (at least 3, per AC3)

1. **Supported locale case.** Browser preference `["es-ES", "en"]`, no tenant default
   supplied → resolves to `"es-ES"` (first browser-preferred member of
   `PLATFORM_SUPPORTED_LOCALES`).
2. **Unsupported locale falling back.** Browser preference `["xx-XX", "ja"]` (neither a
   member of `PLATFORM_SUPPORTED_LOCALES`), no tenant default supplied → resolves to
   `FALLBACK_LOCALE` (`"en"`).
3. **No locale preference at all.** Browser preference is an empty list (or
   `navigator.languages`/`navigator.language` both unavailable, e.g. a test/SSR
   environment), no tenant default supplied → resolves to `FALLBACK_LOCALE` (`"en"`).
4. **(AC6's specific case) Tenant default wins over browser preference.** Tenant
   default `"fr-FR"` supplied and a member of `PLATFORM_SUPPORTED_LOCALES`, browser
   preference `["de-DE"]` → resolves to `"fr-FR"`, not `"de-DE"`.
5. **(AC6's specific case) Browser preference used when no tenant default.** Tenant
   default absent/`null`, browser preference `["de-DE"]` → resolves to `"de-DE"`.

---

## c. Session-locale concept

### Source of truth

A single resolved locale string, computed **once per session** (at SPA bootstrap, not
re-derived on every render or on every route change) by `resolveSessionLocale` and held
in a new Zustand store, `useSessionLocaleStore` (module: `web/src/i18n/sessionLocale.ts`
— same directory/convention as the library choice's own module, and the same pattern
`web/src/stores/definitionDraftStore.ts` already establishes for this codebase's
Zustand usage). "Session" here means "for the lifetime of this browser tab's SPA
session" — there is no locale-switcher UI in this requirement's scope (not asked for by
any REQ-285 acceptance criterion), so the resolved value does not need to be reactive
after bootstrap for anything currently in scope; the store shape below still exposes a
setter so a future requirement (a locale switcher, or real tenant-default wiring — see
below) does not require a shape change to consume.

**Store shape** (`web/src/i18n/sessionLocale.ts`):
- State field `locale: string` — always a member of `PLATFORM_SUPPORTED_LOCALES`
  (invariant maintained by construction: every code path that writes it goes through
  `resolveSessionLocale`, which never returns a non-member value).
- Action `setTenantDefaultLocale(tenantDefaultLocale: string | null): void` — re-runs
  `resolveSessionLocale` with the new tenant default and the browser preference
  captured at store creation, and writes the result to `locale`. Exists for forward
  compatibility (see below); no current call site invokes it with a non-null argument.

**Pure resolver function** (exported separately from the store so it is unit-testable
without a Zustand/React harness):
- `resolveSessionLocale(input: { tenantDefaultLocale?: string | null; browserLocales?: readonly string[] }): string`
- Input defaults: `browserLocales` defaults to reading `navigator.languages` (or
  `[navigator.language]` if `navigator.languages` is unavailable, or `[]` if neither
  exists — e.g. in a test environment) when omitted; `tenantDefaultLocale` defaults to
  `null`/absent.
- Output: always a member of `PLATFORM_SUPPORTED_LOCALES`, per the precedence in §b.
- Error shape: none — this function has no failure mode; every input, including
  malformed or empty locale strings, either matches a member of
  `PLATFORM_SUPPORTED_LOCALES` or falls through to `FALLBACK_LOCALE`.

**Non-hook accessor** for use from plain module-scope functions (see §d — most call
sites are not inside a component body):
- `getSessionLocale(): string` — reads `useSessionLocaleStore.getState().locale`
  directly (Zustand's non-hook `getState()`, not the `useSessionLocaleStore()` hook),
  usable from any module scope, not just component bodies.

### Addressing the tenant-`default_locale`-supply gap (investigated, not assumed)

**Finding: there is currently no path by which the web SPA can learn a tenant's
`default_locale`.** Traced explicitly:

- `GET /api/tenant-config` (`lib/letflow/routers/tenant_config.ex`, REQ-281, `done`) is
  the only pre-authentication config endpoint the web SPA calls
  (`web/src/auth/tenantConfig.ts:43`). REQ-281 added a `branding` key to that
  **backend** response shape (`lib/letflow/routers/tenant_config.ex`) only — the
  **frontend** `TenantConfig` interface at `web/src/auth/tenantConfig.ts:10` still
  declares exactly `{ oidc_authority: string; client_id: string }`, confirmed by
  `grep -n "branding" web/src/auth/tenantConfig.ts` returning zero hits. Consuming the
  new backend key on the frontend (extending this interface, reading the field) is
  REQ-283's still-pending scope, not something REQ-281 did — and no `locale` field of
  any kind exists in either the backend response or this frontend interface today. Its
  own moduledoc states explicitly,
  as a security constraint, that it "must **never** return a tenant id, slug, display
  name, status, user count, **locale/language configuration**, or any other tenant
  attribute" beyond its closed three-key allowlist (`oidc_authority`, `client_id`,
  `branding`). This is a deliberate exclusion, not an oversight — re-verified directly
  against the module source, not inherited from a description of it.
- `GET /api/mobile/tenant-config` (`lib/letflow/routers/mobile_tenant_config.ex`,
  REQ-282, `done`) **does** serve `locales` and `default_locale` — but only to the
  mobile tier (`docs/mobile/`), which the web SPA never calls.
- REQ-283 (`pending`, owner `FRONTEND-DEV`) — the only other requirement touching
  `GET /api/tenant-config`'s consumption in `web/` — is scoped exclusively to applying
  the `branding` key as CSS custom-property overrides ("theming half of step 6").
  Read in full: it does not mention `locale`/`default_locale` anywhere, and its own
  acceptance criteria are all about CSS custom properties and image sources. It does
  **not** supply this gap.
- No other requirement in `docs/requirements.yaml` was found (searched for
  `default_locale` and `tenant-config` together) that adds a locale field to any web-
  reachable endpoint.

**Conclusion, stated explicitly rather than assumed:** this is a genuine, currently
unfilled gap, not a wiring detail this design can silently complete. REQ-285's own text
anticipates exactly this ("the session locale must resolve sensibly ... even when no
tenant default is available, which is also what makes the fallback chain testable") —
this design follows that instruction literally: `resolveSessionLocale` and
`useSessionLocaleStore` are built and fully testable today using only
`browserLocales` and a directly-supplied `tenantDefaultLocale` test double (AC6's test
does not require any real endpoint — it calls `resolveSessionLocale`/
`setTenantDefaultLocale` with a fabricated tenant-default value). At SPA bootstrap,
`useSessionLocaleStore` is initialized with `tenantDefaultLocale: null` (no real value
exists to pass), so tier 1 of the fallback chain never fires in production today — the
app runs entirely on tiers 2–3 until a future requirement wires tier 1 to real data.

**Open question, flagged rather than resolved:** a future requirement is needed to
extend `GET /api/tenant-config`'s response with a `default_locale`/`locales` field (the
same shape of change REQ-281 already made once for `branding`) and to call
`setTenantDefaultLocale` from `web/src/auth/tenantConfig.ts` once that field exists.
That is a **security-relevant response-shaping change** to a pre-authentication
endpoint (same class of change as REQ-281 itself — the endpoint's moduledoc explicitly
calls out that adding a fourth top-level key is "a security change, not a feature"), so
it belongs in its own SECURITY-REVIEWER-gated requirement, not folded into this one.
This design does not invent an id for that future requirement (no such id is registered
in `docs/requirements.yaml` at time of writing) — it is named here as an explicit,
unresolved dependency for whoever files it next, per this project's "no TBD" rule: the
gap itself, and exactly what must change (`tenant_config.ex`'s allowlist,
`TenantConfig` interface, `useSessionLocaleStore`'s bootstrap call), is stated
concretely rather than left implicit.

---

## d. Migration plan for every `.toLocale*()` call site

**New non-hook formatting helpers** (module: `web/src/i18n/format.ts`), built on
react-intl's imperative API per decision 0021:

- `getIntl(): IntlShape` — returns a memoized `react-intl` `IntlShape` built via
  `createIntl({ locale: getSessionLocale(), defaultLocale: FALLBACK_LOCALE, messages: {} })`
  and `createIntlCache()`. `messages: {}` is deliberate and matches §e: no translation
  catalogue exists yet, and none of this requirement's usage calls `formatMessage`.
  Memoized once per resolved session locale (the session locale does not change after
  bootstrap in this requirement's scope — see §c — so this is effectively a
  session-lifetime singleton, not re-created per call).
- `formatDate(value: Date | string | number, options?: Intl.DateTimeFormatOptions): string`
  — thin wrapper over `getIntl().formatDate(value, options)`.
- `formatTime(value: Date | string | number, options?: Intl.DateTimeFormatOptions): string`
  — thin wrapper over `getIntl().formatTime(value, options)`.
- `formatDateTime(value: Date | string | number, options?: Intl.DateTimeFormatOptions): string`
  — combines date and time (react-intl's `IntlShape` does not ship a single combined
  method the way `Date.prototype.toLocaleString()` does; this wrapper composes
  `formatDate`/`formatTime` with a locale-appropriate separator, or passes both date and
  time component options to a single `getIntl().formatDate(value, { ...dateOpts,
  ...timeOpts })` call — either is an implementation choice for ELIXIR-DEV/FRONTEND-DEV,
  not fixed here; the signature and behavioural contract — "renders both date and time
  components, locale-aware" — is what's fixed).

These three wrappers are plain functions, not hooks — callable uniformly from module-
scope helper functions and from inside component bodies/JSX alike, which is the
concrete reason decision 0021 chose react-intl's imperative API (most call sites below
are module-scope helpers, not JSX-inline expressions, and cannot use a hook-based API
like `useIntl()` without restructuring their call signatures — out of this
requirement's scope).

**Every one of the 26 call sites converts — none stays bare.** 26 converted + 0 staying
bare = 26, matching the re-derived total from §a (AC4's required arithmetic). No call
site has a legitimate reason to stay locale-naive: all 26 render a date/time value
directly to a user-facing UI surface (a table cell, a detail panel, a banner, a
timeline entry) — there is no internal-logging or non-UI call site among them that
would justify leaving it bare.

| # | File:line | Old call | New call |
|---|---|---|---|
| 1 | `TokensPage.tsx:49` | `parsed.toLocaleDateString()` | `formatDate(parsed)` |
| 2 | `UsersPage.tsx:91` | `new Date(u.created_at).toLocaleDateString('en-US')` | `formatDate(u.created_at)` |
| 3 | `WebhooksPage.tsx:285` | `new Date(w.created_at).toLocaleString()` | `formatDateTime(w.created_at)` |
| 4 | `InstanceBoardPage.tsx:23` | `new Date(value).toLocaleString()` | `formatDateTime(value)` |
| 5 | `InstanceBoardPage.tsx:28` | `new Date(value).toLocaleTimeString()` | `formatTime(value)` |
| 6 | `TaskInboxPage.tsx:223` (date) | `new Date(task.created_at).toLocaleDateString()` | `formatDate(task.created_at)` |
| 7 | `TaskInboxPage.tsx:223` (time) | `new Date(task.created_at).toLocaleTimeString()` | `formatTime(task.created_at)` |
| 8 | `TaskInboxPage.tsx:318` | `new Date(task.created_at).toLocaleString()` | `formatDateTime(task.created_at)` |
| 9 | `TimelineFeedItem.tsx:18` | `new Date(entry.timestamp).toLocaleString()` | `formatDateTime(entry.timestamp)` |
| 10 | `HealthDashboardPage.tsx:46` | `new Date(dataUpdatedAt).toLocaleTimeString()` | `formatTime(dataUpdatedAt)` |
| 11 | `AuditLogPage.tsx:186` | `new Date(e.occurred_at).toLocaleString()` | `formatDateTime(e.occurred_at)` |
| 12 | `timelineUtils.ts:55` | `ts.toLocaleDateString()` | `formatDate(ts)` |
| 13 | `ProcessModulesPage.tsx:65` | `new Date(s.granted_at).toLocaleDateString()` | `formatDate(s.granted_at)` |
| 14 | `ProcessModulesPage.tsx:116` | `new Date(entry.created_at).toLocaleString()` | `formatDateTime(entry.created_at)` |
| 15 | `ProcessModulesPage.tsx:118` | `new Date(entry.updated_at).toLocaleString()` | `formatDateTime(entry.updated_at)` |
| 16 | `EventHistoryPanel.tsx:202` | `new Date(event.created_at).toLocaleString()` | `formatDateTime(event.created_at)` |
| 17 | `DlqPage.tsx:111` | `new Date(value).toLocaleString()` | `formatDateTime(value)` |
| 18 | `InstanceDetailPage.tsx:46` | `new Date(value).toLocaleString()` | `formatDateTime(value)` |
| 19 | `InstanceDetailPage.tsx:51` | `new Date(value).toLocaleTimeString()` | `formatTime(value)` |
| 20 | `WebhookSubscriptionDetailPanel.tsx:31` | `parsed.toLocaleString()` | `formatDateTime(parsed)` |
| 21 | `TenantsPage.tsx:143` | `new Date(row.created_at).toLocaleDateString()` | `formatDate(row.created_at)` |
| 22 | `DefinitionListPage.tsx:276` | `new Date(def.updated_at).toLocaleDateString()` | `formatDate(def.updated_at)` |
| 23 | `DefinitionListPage.tsx:313` | `new Date(v.updated_at).toLocaleDateString()` | `formatDate(v.updated_at)` |
| 24 | `DraftBanner.tsx:46` | `new Date(draft.savedAt).toLocaleTimeString()` | `formatTime(draft.savedAt)` |
| 25 | `WebhookDeliveryAttemptsTable.tsx:11` | `parsed.toLocaleString()` | `formatDateTime(parsed)` |
| 26 | `PromotionReviewStateMachine.tsx:62` | `new Date(iso).toLocaleString()` | `formatDateTime(iso)` |

Existing `Intl.DateTimeFormat`-option arguments already present at any of these sites
(none currently pass explicit `options` — all 26 are zero-argument or locale-argument-
only calls per §a) are preserved unchanged; the new calls simply omit the `options`
parameter where the old call passed none.

---

## e. Where the English-only-by-design statement goes (AC7)

`docs/frontend/frontend-requirements.md`'s existing "Locale policy (`REQ-127`,
2026-08-22)" section (lines 65–158) is the policy document — REQ-285 updates it in
place (retitled to reflect REQ-285's adoption, e.g. "Locale policy (`REQ-127`/`REQ-285`,
2026-08-22/2026-09-09)") rather than creating a new file, since that section is already
the named authority REQ-285's own description points at ("implement against it rather
than re-deriving the survey"). The update:

1. Keeps REQ-127's original finding intact as a dated historical record (what was true
   on 2026-08-22).
2. Adds a new subsection documenting what REQ-285 actually adopted: the library
   (react-intl, citing decision 0021), `PLATFORM_SUPPORTED_LOCALES`, the fallback-chain
   precedence and its three-tier reasoning (§b/§c above), and the tenant-default-supply
   gap (§c) stated as an explicit, currently-open dependency.
3. Contains the required explicit statement, placed at the top of that new subsection
   so it cannot be missed: **"This adoption ships an English-only string catalogue by
   design. Locale-aware date/time formatting and a real fallback chain are live as of
   REQ-285; translating the application's UI strings into any language other than
   English is explicitly out of REQ-285's scope and is a separate, later requirement.
   An English-only catalogue at this point is the intended state, not an unfinished
   implementation."** This satisfies AC7's requirement that a reader not mistake an
   English-only catalogue for incomplete work.

---

## Cross-module dependencies

- `web/src/i18n/sessionLocale.ts` depends on nothing new outside `zustand` (already a
  dependency) and the browser `navigator` global (guarded for absence, per §c).
- `web/src/i18n/format.ts` depends on `react-intl` (new dependency, decision 0021) and
  `web/src/i18n/sessionLocale.ts` (for `getSessionLocale()`).
- `web/src/auth/tenantConfig.ts` gains no change in this requirement (the gap in §c is
  explicitly not resolved here) but is the named future call site for
  `setTenantDefaultLocale` once a future requirement extends `GET /api/tenant-config`.
- All 19 files listed in §a's table import `formatDate`/`formatTime`/`formatDateTime`
  from `web/src/i18n/format.ts` in place of calling `.toLocale*()` directly.

## Invariants

- `useSessionLocaleStore`'s `locale` field is always a member of
  `PLATFORM_SUPPORTED_LOCALES` (never an arbitrary string) — maintained because every
  write path goes through `resolveSessionLocale`.
- `FALLBACK_LOCALE` is always itself a member of `PLATFORM_SUPPORTED_LOCALES`.
- No call site in `web/src/` calls `.toLocaleDateString()`, `.toLocaleTimeString()`, or
  `.toLocaleString()` directly after this requirement lands (a grep for those three
  method names returning zero hits is the mechanical check TEST-DESIGNER/REVIEWER can
  run for AC4).
- The literal string `'en-US'` does not appear as a locale argument anywhere in
  `web/src/` after this requirement lands (AC5's mechanical check).

## Open questions (stated, not silently resolved)

1. **Tenant `default_locale` supply to the web SPA** (§c) — no requirement currently
   extends `GET /api/tenant-config` with a locale field; this design's
   `setTenantDefaultLocale` exists and is tested in isolation, but is not called by any
   production code path today. A future requirement must add that field (a
   security-relevant change to a pre-auth endpoint, per REQ-281's own precedent) and
   wire the call.
2. **`formatDateTime`'s exact composition** (date+time separator, whether it reuses a
   single `Intl.DateTimeFormat` call with combined options vs. concatenating
   `formatDate`+`formatTime` outputs) is left to the implementing turn — the
   behavioural contract (locale-aware, renders both components) is fixed, the exact
   composition is not, since no acceptance criterion depends on the precise separator
   or spacing.
3. **Whether `PLATFORM_SUPPORTED_LOCALES`'s specific 10-entry membership is the right
   long-term set** is not settled here — it is a concrete, testable starting set
   sufficient for this requirement's fallback-chain tests; expanding it later (e.g. to
   match whatever locales a real tenant actually configures via REQ-280's `locales`
   key) is a natural follow-up but not required by any REQ-285 acceptance criterion.
