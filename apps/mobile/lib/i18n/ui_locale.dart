/// Tier (b) — the UI-string-locale resolver (REQ-429 design §4.2).
///
/// Mirrors `web/src/i18n/entitiesMessages.ts`'s `ENTITIES_UI_LOCALES` /
/// `ENTITIES_UI_FALLBACK_LOCALE` / `resolveUiLocale` exactly: this is the
/// locale family that governs **translated UI strings** (the ARB message
/// catalogue in `catalogue.dart`) — a separate, narrower set from tier
/// (a)'s formatting-locale family in `formatting_locale.dart`, deliberately
/// not unified with it (same reasoning the SPA source records).
library;

import 'formatting_locale.dart' show deviceLocaleTags;

/// == `ENTITIES_UI_LOCALES` (`web/src/i18n/entitiesMessages.ts`). Any change
/// here must be made in lockstep with that file — `ui_locale_test.dart`
/// asserts the two stay equal by parsing the `.ts` source directly (AC1b).
const List<String> kEntitiesUiLocales = ['en', 'ru', 'kk'];

/// == `ENTITIES_UI_FALLBACK_LOCALE`. `'en'` (AC1c).
const String kEntitiesUiFallbackLocale = 'en';

bool _isEntitiesUiLocale(String value) => kEntitiesUiLocales.contains(value);

/// Pure resolver mirroring `resolveUiLocale`'s base-tag rule exactly
/// (design §4.2): for each of [candidates] (defaulting to
/// [deviceLocaleTags] when omitted), its base tag (substring before the
/// first `-`, lowercased) — the first base tag that is a member of
/// [kEntitiesUiLocales] wins; else [kEntitiesUiFallbackLocale].
///
/// Never throws. `['ru-RU'] -> 'ru'`; `['de-DE'] -> 'en'` (since `'de'` is
/// not a member of [kEntitiesUiLocales]).
String resolveUiLocale([List<String>? candidates]) {
  final sources = candidates ?? deviceLocaleTags();
  for (final raw in sources) {
    final dashIndex = raw.indexOf('-');
    final base = (dashIndex == -1 ? raw : raw.substring(0, dashIndex))
        .toLowerCase();
    if (_isEntitiesUiLocale(base)) return base;
  }
  return kEntitiesUiFallbackLocale;
}
