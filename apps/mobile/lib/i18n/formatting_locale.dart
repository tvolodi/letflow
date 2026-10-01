/// Tier (a) — the formatting-locale resolver (REQ-429 design §4.1).
///
/// Mirrors `web/src/i18n/sessionLocale.ts`'s `PLATFORM_SUPPORTED_LOCALES` /
/// `FALLBACK_LOCALE` / `resolveSessionLocale` exactly: this is the locale
/// family that governs **date/number formatting only** (never UI-string
/// translation — see `ui_locale.dart` for that, separate tier).
library;

import 'dart:ui' as ui;

/// == `PLATFORM_SUPPORTED_LOCALES` (`web/src/i18n/sessionLocale.ts`). Any
/// change here must be made in lockstep with that file — `formatting_locale_
/// test.dart` asserts the two stay equal by parsing the `.ts` source
/// directly (AC1a), so a drift here fails that test, not silently.
const List<String> kPlatformSupportedLocales = [
  'en',
  'en-US',
  'en-GB',
  'es',
  'es-ES',
  'fr',
  'fr-FR',
  'de',
  'de-DE',
  'pt-BR',
];

/// == `FALLBACK_LOCALE`. Deliberately `'en'`, not `'en-US'` (AC1c).
const String kFormattingFallbackLocale = 'en';

bool _isSupportedFormattingLocale(String? value) =>
    value != null && kPlatformSupportedLocales.contains(value);

/// Reads the device's own reported locale preference, most-preferred
/// first, as BCP-47 tags (mirrors `sessionLocale.ts`'s
/// `readBrowserLocales()`). Shared by `resolveFormattingLocale` (this
/// file) and `resolveUiLocale` (`ui_locale.dart`) — one device-locale
/// reading function, not two (design §4.2 note). Never throws; an empty
/// `PlatformDispatcher.instance.locales` yields an empty list.
List<String> deviceLocaleTags() {
  final locales = ui.PlatformDispatcher.instance.locales;
  return [for (final locale in locales) locale.toLanguageTag()];
}

/// Pure resolver mirroring `resolveSessionLocale` exactly (design §4.1):
/// 1. [tenantDefaultLocale] if it is a member of [kPlatformSupportedLocales].
/// 2. The first of [deviceLocales] (defaulting to [deviceLocaleTags] when
///    omitted) that is a member.
/// 3. [kFormattingFallbackLocale].
///
/// Never throws.
String resolveFormattingLocale({
  String? tenantDefaultLocale,
  List<String>? deviceLocales,
}) {
  if (_isSupportedFormattingLocale(tenantDefaultLocale)) {
    return tenantDefaultLocale!;
  }

  final candidates = deviceLocales ?? deviceLocaleTags();
  for (final candidate in candidates) {
    if (_isSupportedFormattingLocale(candidate)) {
      return candidate;
    }
  }

  return kFormattingFallbackLocale;
}

/// Holds the active tenant's `default_locale` (`TenantConfig.defaultLocale`,
/// REQ-421) across the session — tier (a)'s "tenant default" role (design
/// §1), set by `lib/bootstrap/navigation_bootstrap.dart`'s
/// `runTenantBootstrap`/`switchTenant` alongside `ActiveRealmHolder`. A
/// plain mutable holder, not a build-time constant, mirroring
/// `ActiveRealmHolder`'s own shape (`lib/api/api_client.dart`) so a second
/// bootstrap (different tenant, same app instance) overwrites it with no
/// rebuild.
class ActiveTenantLocaleHolder {
  String? defaultLocale;
}

