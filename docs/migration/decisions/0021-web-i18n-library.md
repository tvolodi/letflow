# 0021 — Web i18n library: react-intl over i18next/react-i18next

Status: decided (2026-09-09). Owner: CODE-DESIGNER, WF02-REQ285-20260909, per REQ-285's
own text: "A library choice is a `docs/migration/decisions/` matter under CLAUDE.md's
'Don't silently re-decide what a decision record already settled' rule — record 0020
does not settle it, so either it is settled in a new decision record before
implementation, or the implementing turn records the choice and its rationale in one
and gets REVIEWER sign-off." This record settles it before implementation.

## Question

`docs/frontend/frontend-requirements.md`'s "Locale policy (`REQ-127`, 2026-08-22)"
section named `react-intl` and `i18next` (with `react-i18next`) as the only two
candidates surveyed, but deliberately did not choose between them — that was
REQ-127's finding half, not its decision half. REQ-285 (`lib/letflow/design/req285-
i18n-layer-adoption.md`) is the requirement that adopts a real i18n layer: a library, a
supported locale set, a fallback chain, a session-locale concept, and locale-aware
conversion of every bare `.toLocale*()` call site. It needs one library, chosen with
real criteria, before that design can specify concrete module signatures.

## Candidates

- **react-intl** (FormatJS project, OpenJS Foundation): React-bound i18n with ICU
  MessageFormat, `IntlProvider`/`useIntl()` for component use, and an imperative
  `createIntl()`/`createIntlCache()` API for non-component code.
- **i18next + react-i18next**: a framework-agnostic i18n core (`i18next`) plus a thin
  React binding (`react-i18next`), with its own interpolation/pluralization syntax by
  default and a large plugin ecosystem (`i18next-browser-languagedetector`,
  `i18next-http-backend`, `i18next-icu`).

## Criteria and findings

**1. What this requirement actually needs to call, concretely.** This mattered more
than any other criterion once the call sites were inspected (see the design doc's §a).
Of the 26 `.toLocale*()` call sites being converted, most are **not** inline inside a
component's JSX render — they are plain, module-scope helper functions defined
*before* the component that uses them (e.g. `TokensPage.tsx:46`'s `formatDate`,
`InstanceDetailPage.tsx:44`'s `formatDateTime`, `WebhookSubscriptionDetailPanel.tsx:27`'s
`formatTimestamp`, all of `timelineUtils.ts`). A hook-only API (`useIntl()`,
`react-i18next`'s `useTranslation()`) cannot be called from a plain function — it would
require refactoring every one of those helpers to take a `locale`/`intl` parameter
threaded down from the calling component, which is a larger, more invasive change than
this requirement's scope fence allows ("adopt the library... convert the call sites" —
not "restructure every helper's call signature"). **react-intl ships a non-hook
imperative API for exactly this** — `createIntl({ locale, defaultLocale, messages })`
returns an `IntlShape` whose `.formatDate`/`.formatTime` methods work identically
whether called from a component or a bare module function. i18next's core `t()`
function is similarly callable outside components (it's a plain export), but i18next
has no equivalent *date formatting* method of its own — formatting dates is not
i18next's job, it delegates to the caller building their own `Intl.DateTimeFormat`,
which means adopting i18next would not actually touch this requirement's real
deliverable (the 26 call sites) at all, only translation strings, which are explicitly
**out of scope** here (`REQ-285`: "Translating the app's UI strings into a second
language is NOT in scope"). Choosing i18next now would mean shipping a dependency with
zero load-bearing call sites until a future, separate translation requirement lands —
the same "partial subsystem with no current producer/consumer" shape this project's own
decision records already reject elsewhere (`docs/migration/decisions/0020-frontend-
architecture.md`'s D1 host-binding discussion; REQ-078's `sandbox_access.zig`
non-port). react-intl does not have this problem: its `createIntl().formatDate/
formatTime` is exactly the mechanism REQ-285 needs today.

**2. ICU MessageFormat support (relevant to future pluralization/translation work).**
react-intl/FormatJS uses ICU MessageFormat natively — no plugin. i18next uses its own
interpolation syntax (`{{var}}`) by default; ICU pluralization requires the separate
`i18next-icu` plugin (itself a wrapper around FormatJS's `intl-messageformat`, the same
library react-intl already depends on directly). Choosing react-intl now means the
ICU-based message catalogue a later translation requirement will author is already the
library's native format — no format migration when that requirement lands.

**3. Bundle size.** Neither library is heavy in absolute terms, but the comparison that
matters here is "cost of what we'd actually be shipping." react-intl's runtime cost is
dominated by `intl-messageformat` and its own polyfill-only-if-needed formatting layer
on top of the browser's native `Intl` object — every browser this SPA targets already
has `Intl.DateTimeFormat`, so react-intl adds a thin wrapper, not a polyfill, in
practice. i18next core is comparably small, but a working fallback-chain-and-detection
setup in the i18next ecosystem conventionally also pulls in
`i18next-browser-languagedetector` — a dependency this requirement does not need, since
REQ-285's own fallback-chain logic (tenant default → browser preference → hardcoded
default, with the tenant-default half not yet wired to any endpoint — see the design
doc §c) has to be hand-written regardless of library, as it is Letflow-specific data no
off-the-shelf detector plugin knows about. Given neither library's own fallback tooling
gets used, this stops being a real bundle-size differentiator either way, but it is one
fewer dependency to justify with react-intl.

**4. TypeScript support.** Both ship first-party `.d.ts` and are commonly used from
TypeScript. react-intl's `IntlShape`, `IntlProvider` props, and `createIntl`'s options
are all directly typed with no code-generation step. i18next's strongest type safety
(type-checked translation keys) requires a generated `resources` type from actual
translation JSON files — moot here since no translation catalogue exists yet
(`AC7`: English-only, translation is a separate future requirement). Roughly even for
what this requirement actually uses; a mild edge to react-intl for needing no
generation step to get useful types today.

**5. React 18 compatibility.** Both are React-18-compatible in their current major
versions (react-intl v6.x, react-i18next v13+). Not a differentiator.

**6. Community/maintenance status.** Both are actively maintained, high-download
packages (react-intl under the OpenJS Foundation's FormatJS umbrella; i18next
independently maintained with a large plugin ecosystem). Not a differentiator on its
own; noted so a future reader does not think this was overlooked.

**7. Ease of the specific fallback-chain behaviour REQ-285 needs.** This criterion, on
its own, would favour i18next: `fallbackLng` plus `i18next-browser-languagedetector`
implement a browser-preference-then-hardcoded-default cascade out of the box. But
REQ-285's actual fallback chain has three tiers, not two, and the tenant-default tier is
Letflow-specific data no plugin can supply (see the design doc's §c — there is currently
no endpoint that serves a tenant's `default_locale` to the web SPA at all). The chain
has to be a small, independently-testable Letflow function (`resolveSessionLocale`)
regardless of which library is chosen, consuming whatever the function resolves to as a
plain `locale` string. Once that is true, neither library's own cascade machinery is
actually exercised, so this criterion does not carry the weight it would in a project
that only needed a two-tier browser/default cascade.

## Decision: **react-intl**

Criterion 1 is dispositive: it is the only criterion tied to what this requirement's
acceptance criteria actually exercise today (26 real call sites converting to
locale-aware formatting), and only react-intl's imperative `createIntl()` API reaches
all of them — including the module-scope helper functions — without restructuring their
call signatures. Criteria 2–5 are consistent with react-intl or neutral; criterion 6 is
a wash; criterion 7 favours i18next in the abstract but doesn't survive contact with
this requirement's actual fallback-chain shape (see above). No criterion here reaches a
different conclusion than criterion 1 already does.

## What this decision does not settle

- **The React-context wiring (`IntlProvider`/`useIntl`/`FormattedMessage`) for UI-string
  translation.** Out of scope for REQ-285 by its own text; deferred to whichever future
  requirement actually externalizes the ~315 hardcoded JSX strings the REQ-127 finding
  counted. This record only settles the *library*, so that future requirement does not
  have to re-litigate it.
- **Which locales are in the SPA's supported set, or the exact fallback-chain
  precedence.** Both are REQ-285 design content — see `lib/letflow/design/req285-i18n-
  layer-adoption.md`, not this record.
- **How/whether a tenant's `default_locale` ever reaches the web SPA.** Investigated as
  part of REQ-285's design and found to be a genuine, currently-unfilled gap (`GET
  /api/tenant-config`, REQ-281, deliberately excludes locale data per its own
  moduledoc; only `GET /api/mobile/tenant-config`, REQ-282, serves it, to the mobile
  tier). This record does not propose or authorize a wire-up — see the design doc §c
  for the open question, flagged rather than silently resolved.

## Package added

`react-intl` (dependency, not devDependency — it runs in the shipped bundle) is added
to `web/package.json`. `react-i18next`/`i18next` are **not** added, per the decision
above.
