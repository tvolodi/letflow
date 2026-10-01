# REQ-429 design — MOB-7 mobile internationalisation

Owner of implementation: MOBILE-DEV (`apps/mobile/lib/**`, `apps/mobile/test/**`,
`docs/mobile/requirements.md`). This document is design only — no `.dart` code, no
authored ARB file contents. Produced by CODE-DESIGNER, WF02-REQ429-20261001.

## 0. Source-of-truth verification (done at design time, 2026-10-01)

Re-read both SPA files in full. No drift since the 2026-09-27 REQ-VALIDATOR
correction that split this requirement into two tiers:

- `web/src/i18n/sessionLocale.ts`: `PLATFORM_SUPPORTED_LOCALES` is exactly
  `['en','en-US','en-GB','es','es-ES','fr','fr-FR','de','de-DE','pt-BR']` (10 entries),
  `FALLBACK_LOCALE = 'en'`. `resolveSessionLocale({tenantDefaultLocale, browserLocales})`:
  (1) if `tenantDefaultLocale` is a member of the set, return it; (2) else return the
  first of `browserLocales` that is a member; (3) else return `FALLBACK_LOCALE`. Matches
  the requirement text verbatim.
- `web/src/i18n/entitiesMessages.ts`: `ENTITIES_UI_LOCALES = ['en','ru','kk']`,
  `ENTITIES_UI_FALLBACK_LOCALE = 'en'`. `resolveUiLocale(candidates?)`: for each candidate
  (default source `navigator.languages`/`navigator.language`), take the substring before
  the first `-`, lowercase it; return the first whose base tag is a member of
  `ENTITIES_UI_LOCALES`; else return the fallback. Matches the requirement text verbatim
  (`['ru-RU'] -> 'ru'`, `['de-DE'] -> 'en'` both check out against this logic).
- Tier (c): `ExamSessionPage.tsx`'s `resolveLocalizedText(value, uiLocale)` — chain is
  `value[uiLocale]` (if truthy) -> `value['en']` (if truthy) -> first truthy value in
  `Object.values(value)` -> `''`. Its parameter type is `LocalizedText | null | undefined`
  where `LocalizedText = Record<string, string>` (`exam.types.ts:36`) — **it has no
  plain-string branch**; a bare string is never a legal `LocalizedText` value in this
  module's own type. `ExamListPage.tsx`'s sibling `resolveExamFieldText(value: unknown,
  uiLocale)` runs the *same* chain but first checks `typeof value === 'string'` and
  returns it unchanged — that is where the "plain string passes through" behaviour
  actually lives.

**Finding, not silently resolved:** AC3 names `resolveLocalizedText` as the function to
match but also requires "a plain-string value passing through unchanged" (sub-clause
3e), a behaviour that function doesn't have — only its sibling `resolveExamFieldText`
does. The two SPA functions are the same chain over two different input-type unions. The
Dart tier-(c) resolver below is designed to accept the *union* input (mirroring
`resolveExamFieldText`'s `unknown`/dynamic parameter), so it satisfies both: it
implements `resolveLocalizedText`'s map-chain behaviour over AC3(a-d) and
`resolveExamFieldText`'s string-passthrough over AC3(e). This is the correct synthesis
of the two cited behaviours, not a new third behaviour, so it is recorded as a finding
rather than an open question requiring a decision from someone else.

No SPA unit test file exists for `resolveUiLocale` (`web/tests/unit/` has
`sessionLocale.test.ts` and `format.test.ts` only — confirmed by grep). AC2(b)'s "the two
named examples" (`['ru-RU'] -> 'ru'`, `['de-DE'] -> 'en'`) are therefore the only
SPA-sourced expected values available for that table; TEST-DESIGNER should derive any
additional cases directly from `resolveUiLocale`'s source logic (reproduced above), not
invent independent ones. AC2(a)'s instruction to source expected values "from the SPA's
own tests where they exist" is fully satisfiable for the formatting-locale resolver:
`web/tests/unit/sessionLocale.test.ts` TC-1..TC-5 plus the inline "unsupported tenant
default" case cover exactly the three named scenarios (unsupported tenant default,
unsupported device list, no SPA case for `'pt-BR'` exact match specifically — that one
case's expected value is derived directly from `PLATFORM_SUPPORTED_LOCALES` membership,
not copied from an SPA test, since no SPA test exercises `'pt-BR'` by name).

## 1. Existing mobile groundwork (surveyed, not to be duplicated)

- `apps/mobile/lib/i18n/i18n.dart` is a placeholder barrel (REQ-419 scaffold) — "Built
  starting REQ-429." This requirement is what fills it in.
- `apps/mobile/pubspec.yaml` already depends on `intl: ^0.20.3`. **No
  `flutter_localizations` SDK dependency exists today, and this design does not add
  one** — see §3 for why.
- `apps/mobile/lib/api/api_client.dart`'s `TenantConfig` class already carries
  `locales: List<String>` and `defaultLocale: String` (REQ-421, from `GET
  /api/mobile/tenant-config`) — this is tenant content's `locales`/`default_locale`,
  playing tier (a)'s "tenant default" role exactly as the requirement describes. No new
  wire contract is needed; the resolver just consumes fields that already exist on an
  object already threaded through bootstrap.
- `docs/mobile/architecture.md` §2's stack table lists `i18n -> intl` only. Adding
  `flutter_localizations` would be a new table entry and a new pubspec dependency line;
  this design avoids that (§3).
- Existing guard-test convention (`apps/mobile/test/guards/forbidden_dependencies_guard_test.dart`,
  `module_boundary_guard_test.dart`): a pure, regex/text-based checker function + a
  `main()` that (1) runs it against the real tree and (2) runs a `self-test:` case with
  an injected fixture proving the checker actually fires. AC5's guard follows this same
  shape.
- No `lib/features/` import-boundary issue: `lib/i18n/` sits beside `lib/design_system/`
  and `lib/shared/` as core/shared code, not inside `lib/features/<id>/`, so
  `module_boundary_guard_test.dart`'s rules don't apply to it and no `module_manifest.json`
  entry is needed.

## 2. File layout (new files, under `apps/mobile/lib/i18n/` and `apps/mobile/lib/i18n/l10n/`)

```
apps/mobile/lib/i18n/
  i18n.dart                 # barrel: export formatting_locale.dart, ui_locale.dart,
                             #         localized_text.dart, catalogue.dart
  formatting_locale.dart     # tier (a): kPlatformSupportedLocales, kFormattingFallbackLocale,
                             #           resolveFormattingLocale(), deviceLocaleTags()
  ui_locale.dart              # tier (b): kEntitiesUiLocales, kEntitiesUiFallbackLocale,
                             #           resolveUiLocale()
  localized_text.dart         # tier (c): resolveLocalizedText()
  catalogue.dart              # ARB loader + message lookup (MessageCatalogue), date/number
                             #   formatting helpers wired to the tier-(a) locale
  l10n/
    app_en.arb               # one ARB file per ENTITIES_UI_LOCALES entry (AC1d)
    app_ru.arb
    app_kk.arb
apps/mobile/test/i18n/
  formatting_locale_test.dart       # AC1(a), AC1(c, fallback-a half), AC2(a)
  ui_locale_test.dart               # AC1(b), AC1(c, fallback-b half), AC1(d), AC2(b)
  localized_text_test.dart          # AC3(a-e)
  catalogue_formatting_test.dart    # AC4(a-b)
apps/mobile/test/guards/
  text_literal_guard_test.dart      # AC5(a-b)
```

Rationale for `catalogue.dart` as a separate file from `ui_locale.dart`: `ui_locale.dart`
is a pure resolver with zero I/O (testable with no `rootBundle`/asset harness, same shape
as `formatting_locale.dart`/`localized_text.dart`); ARB loading is `Future`-based asset
I/O. Keeping them apart means `ui_locale_test.dart` stays a plain synchronous
`flutter_test` file with no `TestWidgetsFlutterBinding.ensureInitialized()` ceremony,
consistent with how `expr_evaluate.dart`/`expr_evaluator.dart` are split from their
tokenizer/parser in `lib/expr/`.

## 3. ARB wiring decision: hand-rolled loader, not Flutter's `gen-l10n` codegen

Flutter's built-in ARB tool (`flutter gen_l10n`) requires adding `flutter_localizations:
sdk: flutter` to `pubspec.yaml`'s dependencies, `generate: true` under the `flutter:`
section, and (optionally) an `l10n.yaml`, plus a build-time codegen step producing
`AppLocalizations` classes. This is a bigger toolchain change than this requirement's
scope (architecture.md §2's stack table states `i18n -> intl` only; REQ-419 §2's "no
runtime dependency beyond this list" constraint, reproduced in `pubspec.yaml`'s own
comment) and would require a REVIEWER sign-off to add a stack entry not already on
record, per CLAUDE.md's "don't silently re-decide what a decision record already
settled."

**Design decision:** ARB files are plain JSON (ARB *is* JSON with an `@@locale` metadata
key — using the `.arb` extension and ARB's `@`-prefixed metadata-entry convention does
not require Flutter's codegen tool to consume it). `catalogue.dart` loads each file at
runtime via `rootBundle.loadString('packages/letflow/i18n/l10n/app_<locale>.arb')` (exact
asset path depends on whether these are registered as Flutter assets in `pubspec.yaml`'s
`flutter: assets:` list — MOBILE-DEV must add that list entry; this design specifies the
files' logical location, `assets:` registration is an implementation mechanic, not an
open design question) or, more simply, as plain Dart `rootBundle.loadString('assets/i18n/...')`
if MOBILE-DEV instead copies the three files into `assets/i18n/` for asset-bundle
registration simplicity — **MOBILE-DEV's choice between `lib/i18n/l10n/` (co-located, via
`assets:` pointing inside `lib/`) and `assets/i18n/`* (conventional assets directory) is
left open below as OQ-1**, since it is a packaging mechanic that does not change any
function signature or test behaviour. `json.decode` gives a `Map<String, dynamic>` of
message-id -> string, with the `@@locale` key filtered out before use. `MessageCatalogue`
wraps the three loaded maps keyed by `EntitiesUiLocale` and exposes lookup with the same
locale-fallback semantics `entitiesMessages.ts`'s consumers get from `react-intl`
(missing id or missing locale resolves through `kEntitiesUiFallbackLocale`'s map, then the
literal id itself as a last resort so a lookup never throws).

ARB key/value shape mirrors `entitiesMessages.ts`'s id scheme for anything this
requirement's own widgets need (navigation chrome, generic form/validation strings,
error messages already present as hardcoded literals today) — MOBILE-DEV enumerates the
actual ids by sweeping `apps/mobile/lib` for literal `Text(...)`/string-typed
user-visible content once the guard (§5) identifies every site; this design does not
pre-enumerate the id list because that enumeration is exactly the guard's job to surface,
not something to hand-author speculatively up front (doing so risks the id list silently
drifting from what the guard actually finds).

## 4. Public signatures

### 4.1 Tier (a) — formatting-locale resolver (`formatting_locale.dart`)

```
const List<String> kPlatformSupportedLocales;   // == PLATFORM_SUPPORTED_LOCALES, 10 entries
const String kFormattingFallbackLocale;          // 'en'

List<String> deviceLocaleTags();
  // input: none (reads dart:ui PlatformDispatcher.instance.locales, mapping each
  //        ui.Locale via .toLanguageTag(); empty list if that list is empty)
  // output: List<String> of BCP-47 tags, in the platform's own preference order
  //         (mirrors sessionLocale.ts's readBrowserLocales())

String resolveFormattingLocale({
  String? tenantDefaultLocale,
  List<String>? deviceLocales,   // null -> deviceLocaleTags()
});
  // output: a member of kPlatformSupportedLocales, chosen by:
  //   1. tenantDefaultLocale if it is a member
  //   2. first of deviceLocales that is a member
  //   3. kFormattingFallbackLocale
  // Pure given explicit deviceLocales (injectable for tests, mirrors
  // ResolveSessionLocaleInput). Never throws.
```

### 4.2 Tier (b) — UI-string locale resolver (`ui_locale.dart`)

```
const List<String> kEntitiesUiLocales;           // == ENTITIES_UI_LOCALES: ['en','ru','kk']
const String kEntitiesUiFallbackLocale;          // 'en'

String resolveUiLocale([List<String>? candidates]);
  // input: candidates, defaulting to deviceLocaleTags() when omitted/null
  // output: for each candidate, in order, its base tag (substring before the
  //         first '-', lowercased); the first base tag that is a member of
  //         kEntitiesUiLocales; else kEntitiesUiFallbackLocale.
  // Pure. Never throws. Matches resolveUiLocale's base-tag rule exactly
  // (['ru-RU'] -> 'ru'; ['de-DE'] -> 'en', since 'de' is not a member).
```

Note `deviceLocaleTags()` is shared between tiers (a) and (b) — one device-locale
reading function, not two — since both SPA resolvers likewise read
`navigator.languages`/`navigator.language` independently but with identical logic; the
Dart design deliberately shares the one function rather than duplicating it, which is a
legitimate implementation simplification (it changes no observable input/output
contract of either resolver).

### 4.3 Tier (c) — tenant-content `{locale: value}` resolver (`localized_text.dart`)

```
String resolveLocalizedText(Object? value, String uiLocale);
  // input: value is one of:
  //   - null                          -> output ''
  //   - a String                      -> output value unchanged (passthrough, AC3e)
  //   - a Map<String, dynamic/String> -> chain:
  //       1. value[uiLocale] if present and non-empty -> that value
  //       2. else value['en'] if present and non-empty -> that value
  //       3. else the first non-empty value in value.values (map iteration order,
  //          mirroring Object.values()'s insertion-order guarantee) -> that value
  //       4. else ''
  //   - any other runtime type -> output value.toString() (mirrors
  //     resolveExamFieldText's `return String(value)` final branch; not exercised
  //     by any AC3 sub-clause, included only so the function is total)
  // Pure. Never throws.
```

This is the synthesis described in §0's finding: AC3(a-d) exercise the map branch
(identical chain to `resolveLocalizedText`/`resolveExamFieldText`, which agree on it),
AC3(e) exercises the string branch (present in `resolveExamFieldText`, absent from
`resolveLocalizedText`, included here because AC3 explicitly requires it).

### 4.4 Date/number formatting wired to the tier-(a) locale (`catalogue.dart`)

```
DateFormat localizedDateFormat(String pattern, String formattingLocale);
  // == intl.DateFormat(pattern, formattingLocale) -- a thin named wrapper, not a
  // new abstraction, so every call site passes the resolved tier-(a) locale
  // explicitly rather than relying on intl's ambient default locale (the same
  // "never call the bare/default-locale formatter" discipline REQ-285 enforced
  // on the SPA's Intl.* call sites).

NumberFormat localizedDecimalFormat(String formattingLocale);
  // == intl.NumberFormat.decimalPattern(formattingLocale)

NumberFormat localizedCurrencyFormat(String formattingLocale, {String? symbol});
  // == intl.NumberFormat.currency(locale: formattingLocale, symbol: symbol)
  // (included for completeness; only decimal formatting is exercised by AC4,
  // which asks for "a number", not specifically currency -- TEST-DESIGNER may
  // use localizedDecimalFormat alone to satisfy AC4(b))
```

Call-site discipline: every widget that formats a date or number MUST obtain the
formatting locale from `resolveFormattingLocale(...)` (via whatever Riverpod provider
MOBILE-DEV wires it through — e.g. a `Provider<String> formattingLocaleProvider`
computed once per session from the active `TenantConfig.defaultLocale`/`.locales` and
`deviceLocaleTags()`, the same "resolved once per session" shape as the SPA's
`useSessionLocaleStore`) and pass it explicitly to `localizedDateFormat`/
`localizedDecimalFormat` — never constructing a bare `DateFormat`/`NumberFormat` with no
locale argument (that would silently take the device's ambient default, defeating tier
(a) entirely). This call-site discipline is a design invariant for MOBILE-DEV to follow;
it is not itself one of the 7 ACs' sub-clauses but underlies AC4 being meaningfully
testable at all (if call sites don't thread the resolved locale through, AC4's two
test cases would only be proving `intl`'s own behaviour, not this requirement's wiring).

## 5. Guard test design (AC5)

**What it scans:** every `.dart` file under `apps/mobile/lib` (recursive), reading raw
text (no `analyzer` dependency — same `dart:io` + `RegExp` approach as
`module_boundary_guard_test.dart`/`forbidden_dependencies_guard_test.dart`).

**What counts as a violation:** a `Text(` constructor call (the widget, not
`TextField`/`TextFormField`/`TextStyle`/`TextSpan`/`TextButton` etc. — match the literal
token `Text(` preceded by a non-identifier character, to avoid matching those
longer-named widgets) whose first positional argument is a quoted string literal (single
or double quotes, matched via regex, not full parsing — consistent with this test
suite's existing text-scan convention) containing at least one letter character (so a
purely-symbolic literal like `Text('—')` or `Text('')` is not flagged — see allowlist
below for the precise exclusion this is meant to generalize).

**Allowlist (non-violations even though they match the raw pattern):**
- A `Text(` call whose string argument is empty or contains no letter character (a
  bullet/separator glyph, not user-visible language content).
- A `Text(` call inside a file path matching `apps/mobile/test/**` (test fixtures/golden
  widgets are not shipped UI).
- A `Text(` call whose argument is not a literal at all (an interpolated string
  `Text('$x')`, a variable, or a function call like `Text(catalogue.get('id'))`) — these
  are definitionally not hardcoded literals and the regex's own literal-match
  requirement already excludes them structurally; listed here for clarity, not as an
  extra exclusion rule to implement.
- A fixed, explicit allowlist of **file:line** entries for any genuinely-technical,
  non-user-visible string the sweep turns up that isn't a real violation (e.g. a debug
  marker) — MOBILE-DEV populates this list only if the real-tree run (AC5b) finds such a
  case; this design does not pre-populate it since no current `Text(` literal has been
  surveyed string-by-string by this design pass (that enumeration is the implementing
  turn's job, same reasoning as §3's id-list point).

**Self-test (AC5a, non-vacuousness):** a fixture Dart source string (an in-memory
string, not a file on disk) containing a widget tree with one `Text('Hardcoded literal')`
call, run through the same checker function used against the real tree. The test asserts
the checker returns exactly one violation for that fixture, and separately asserts a
fixture using `Text(someCatalogueLookup('id'))` (an interpolation/variable case) and a
fixture using `Text('—')` (empty/no-letter case) each return zero violations — proving
the checker both fires on a real violation and does not fire on the three allowlisted
shapes. This mirrors `forbidden_dependencies_guard_test.dart`'s
`'self-test: checker fires on a pubspec containing webview_flutter'` pattern exactly.

**Real-tree pass (AC5b):** the same checker run against the actual
`apps/mobile/lib` tree today must return zero violations. This requirement's own BUILDS
item ("no hardcoded literals in widgets") is therefore enforced going forward by this
test, not just asserted once — MOBILE-DEV's job in Step 2b-mobile is to externalize every
literal the guard finds (via the catalogue from §3) until the real-tree run is clean,
*then* commit the guard. If the guard is written and committed finding violations still
present, that is a build failure, not a passing AC5(b) — the guard must be genuinely
green against the shipped tree, not merely present.

## 6. AC sub-clause -> design-element mapping

| Sub-clause | Design element |
|---|---|
| 1a: mobile formatting-locale list == PLATFORM_SUPPORTED_LOCALES, parsed from the .ts file at test time | `formatting_locale_test.dart` reads `web/src/i18n/sessionLocale.ts` as text, regex-extracts the `PLATFORM_SUPPORTED_LOCALES` array literal, and asserts it equals `kPlatformSupportedLocales` (§4.1) |
| 1b: mobile UI-string locale list == ENTITIES_UI_LOCALES, parsed from entitiesMessages.ts | `ui_locale_test.dart` reads `web/src/i18n/entitiesMessages.ts` as text, regex-extracts the `ENTITIES_UI_LOCALES` array literal, and asserts it equals `kEntitiesUiLocales` (§4.2) |
| 1c: both fallbacks assert to 'en' | Assertions on `kFormattingFallbackLocale == 'en'` (in `formatting_locale_test.dart`) and `kEntitiesUiFallbackLocale == 'en'` (in `ui_locale_test.dart`) |
| 1d: ARB file count == ENTITIES_UI_LOCALES.length, one per entry | `ui_locale_test.dart` (or a dedicated case in it) lists `apps/mobile/lib/i18n/l10n/*.arb` (or wherever OQ-1 resolves them to) and asserts the set of `@@locale` values inside them equals `kEntitiesUiLocales` exactly, no more no less — §2's three files (`app_en.arb`, `app_ru.arb`, `app_kk.arb`) |
| 2a: >=6 table cases for formatting-locale resolver vs resolveSessionLocale, incl. unsupported tenant default / unsupported device list / 'pt-BR' exact match, sourced from SPA tests where they exist | `formatting_locale_test.dart`'s table, built from `web/tests/unit/sessionLocale.test.ts`'s TC-1..TC-5 plus the inline "unsupported tenant default" case plus a `pt-BR` exact-match case (source noted in §0 as derived from the locale-set definition, not an SPA test, since none exercises it) — >= 6 rows total against `resolveFormattingLocale` (§4.1) |
| 2b: separate table for UI-locale resolver vs resolveUiLocale's base-tag rule, with the two named examples | `ui_locale_test.dart`'s table against `resolveUiLocale` (§4.2), including `['ru-RU'] -> 'ru'` and `['de-DE'] -> 'en'` |
| 3a: UI-locale-key hit resolves to that value | `localized_text_test.dart` case against `resolveLocalizedText` (§4.3), map branch step 1 |
| 3b: fallback to 'en' key when UI-locale key absent | same, map branch step 2 |
| 3c: fallback to first non-empty value when neither UI-locale nor 'en' present | same, map branch step 3 |
| 3d: fallback to '' when map empty/all blank | same, map branch step 4 |
| 3e: plain-string value passes through unchanged | same, string branch (§4.3, synthesized from `resolveExamFieldText` per §0's finding) |
| 4a: date formatting differs between de-DE and en-US | `catalogue_formatting_test.dart`, `localizedDateFormat(pattern, 'de-DE')` vs `localizedDateFormat(pattern, 'en-US')` on a fixed `DateTime`, asserting the formatted strings differ (§4.4) |
| 4b: number formatting differs between de-DE and en-US | same file, `localizedDecimalFormat('de-DE')` vs `localizedDecimalFormat('en-US')` on a fixed number (e.g. a decimal-separator difference: `1234.5` -> `"1.234,5"` vs `"1,234.5"`), asserting they differ (§4.4) |
| 5a: guard's self-test fires on an injected literal | `text_literal_guard_test.dart`'s self-test fixture (§5) |
| 5b: guard passes on the real tree | `text_literal_guard_test.dart`'s real-tree case (§5) — contingent on MOBILE-DEV having externalized every literal the guard finds first |
| 6a: references REQ-285 | §7 target text below |
| 6b: references sessionLocale.ts | §7 target text below |
| 6c: references entitiesMessages.ts | §7 target text below |
| 6d: states the two-tier split explicitly | §7 target text below |
| 6e: 2026-08-22 finding text preserved as dated history | §7 target text below (original paragraph kept verbatim, not deleted) |
| 7: `flutter analyze && flutter test` pass, real output quoted | Not a design-time element — MOBILE-DEV runs it in Step 2b-mobile/TEST-RUNNER runs it in Step 3; this design's job is to make every other AC concretely testable so that run has something real to pass against |

Every one of the 7 ACs' listed sub-clauses maps to a concrete design element above. None
were silently dropped.

## 7. `docs/mobile/requirements.md` MOB-7 rewrite target (AC6) — for MOBILE-DEV, not executed by this design

Replace the current "**Letflow note.**" paragraph and the paragraph after it (the
"This requirement therefore has nothing to 'match' yet..." paragraph, lines ~264-281 as
read at design time) with text that:

1. Keeps the existing "**Letflow note.**" paragraph's content about `REQ-127`
   (2026-08-22) **verbatim, unchanged, as dated history** (AC6e) — do not delete or
   reword the "there is no locale policy today" finding; it remains true *as of that
   date*, which is the point of preserving it.
2. Immediately after it, adds a new dated paragraph (e.g. "**Update (REQ-285,
   2026-09-09 design; REQ-429, 2026-10-01 mobile match).**") stating:
   - That `REQ-285` (cite `lib/letflow/design/req285-i18n-layer-adoption.md` and
     `docs/migration/decisions/0021-web-i18n-library.md`) adopted a real web locale
     policy, closing the gap the 2026-08-22 finding recorded (AC6a).
   - That the policy has **two tiers**, named explicitly (AC6d):
     (a) a **formatting-locale** tier — `PLATFORM_SUPPORTED_LOCALES`/`FALLBACK_LOCALE`
     in `web/src/i18n/sessionLocale.ts` (AC6b), governing date/number formatting only;
     (b) a **UI-string-locale** tier — `ENTITIES_UI_LOCALES`/`ENTITIES_UI_FALLBACK_LOCALE`
     in `web/src/i18n/entitiesMessages.ts` (AC6c), governing translated UI strings, with
     its own independent resolver and base-tag matching rule.
   - That `REQ-429` is the mobile implementation matching both tiers (plus tenant
     `{locale: value}` content resolution), replacing this requirement's old
     "defines its own locale set independently" framing — the mobile tier now matches
     the web tier's locale sets/fallbacks/resolution order exactly, with
     `TenantConfig.locales`/`.defaultLocale` playing the role of the SPA's tenant
     default and the device's reported locales playing the role of the browser's.
3. Removes (does not merely leave stale) the sentence "Either the web platform adopts a
   real locale policy first..., or this mobile requirement defines its own locale
   set/fallback chain independently and accepts that it will not match the web tier" —
   that branch is now resolved (the web platform did adopt one, and mobile does match
   it), so stating it as still-open would misstate the current state. This removal is
   the cost of AC6e's "preserve the 2026-08-22 finding" instruction co-existing with "the
   note must now be accurate" — only the *forward-looking conditional* sentence is
   removed; the *backward-looking finding* (the whole 2026-08-22 paragraph) stays.

## 8. Open questions (not silently resolved)

- **OQ-1 (packaging mechanic, §3):** whether the three ARB files live under
  `apps/mobile/lib/i18n/l10n/` (co-located with the Dart source that loads them, needing
  an `assets:` entry that points inside `lib/`) or under a conventional
  `apps/mobile/assets/i18n/` directory. Either satisfies every AC literally (AC1d only
  requires "ARB files present under `apps/mobile/`"); MOBILE-DEV picks whichever reads
  more naturally against this repo's existing asset-registration style (no prior asset
  directory exists in `apps/mobile/` to copy a convention from — checked, none found).
- **OQ-2 (id enumeration, §3):** the exact set of message ids the ARB catalogue carries
  is not pre-enumerated by this design; it falls out of MOBILE-DEV's literal-string sweep
  while satisfying AC5(b). Flagged so MOBILE-DEV does not expect a ready-made id list and
  TEST-DESIGNER does not expect a fixed id set to test against by name (only the
  mechanism — lookup/fallback — is this requirement's test surface, not any particular
  id's presence, except incidentally during the real-tree guard pass).
- **OQ-3 (device-locale source on simulators/CI):** `deviceLocaleTags()`'s production
  implementation reads `PlatformDispatcher.instance.locales`, which `flutter test`'s
  headless binding reports as a fixed default (`en-US` in current Flutter test
  bindings) rather than a real device's list — this is fine for `resolveFormattingLocale`/
  `resolveUiLocale`'s *own* unit tests (§4.1/4.2 take `deviceLocales`/`candidates`
  explicitly as injectable parameters precisely so production-vs-test device-locale
  behaviour never has to be reconciled), but is noted here so TEST-DESIGNER does not
  attempt to assert anything about the *default* (no-argument) call path's behaviour
  under `flutter test` — only the explicit-input table cases (AC2) are this
  requirement's test surface for these two resolvers.
