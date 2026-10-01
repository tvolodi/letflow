/// i18n: locale-aware strings via `intl`, driven by the tenant-config
/// `locales`/`default_locale` fields. Built by REQ-429 (MOB-7) — see
/// `lib/letflow/design/req429-mobile-i18n.md`.
///
/// Two independent tiers (never unified — the SPA this mirrors keeps them
/// separate for the same reason):
///   (a) formatting locale (`formatting_locale.dart`) — date/number
///       formatting only.
///   (b) UI-string locale (`ui_locale.dart`) — the ARB message catalogue
///       (`catalogue.dart`).
/// Plus tier (c), tenant `{locale: value}` content resolution
/// (`localized_text.dart`), which is independent of both.
library;

export 'catalogue.dart';
export 'formatting_locale.dart';
export 'localized_text.dart';
export 'ui_locale.dart';
