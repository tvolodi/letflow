/// ARB-backed UI-string catalogue + locale-aware date/number formatting
/// (REQ-429 design §2/§3/§4.4).
///
/// ARB files are plain JSON (no Flutter `gen_l10n` codegen — design §3:
/// adding it would mean a new `flutter_localizations` SDK dependency not on
/// `architecture.md` §2's stack table). Loaded at runtime via
/// [AssetBundle.loadString] against the three asset paths registered in
/// `pubspec.yaml`'s `flutter: assets:` list.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:intl/intl.dart';

import 'ui_locale.dart';

/// Looks up translated UI strings loaded from the three ARB files under
/// `lib/i18n/l10n/`. Resolution never throws: an unresolved id/locale
/// falls through to [kEntitiesUiFallbackLocale]'s table, then to the
/// literal message id itself as a last resort (design §3).
class MessageCatalogue {
  const MessageCatalogue(this._byLocale);

  final Map<String, Map<String, String>> _byLocale;

  /// Asset paths of the three ARB files (one per [kEntitiesUiLocales]
  /// entry — AC1d). Registered under `pubspec.yaml`'s `flutter: assets:`.
  static const List<String> arbAssetPaths = [
    'lib/i18n/l10n/app_en.arb',
    'lib/i18n/l10n/app_ru.arb',
    'lib/i18n/l10n/app_kk.arb',
  ];

  /// Loads and parses all three ARB files via [bundle] (defaults to
  /// [rootBundle]). Each file's `@@locale` metadata key names the locale
  /// this file's table is keyed under; every other `@`-prefixed key (ARB
  /// metadata attached to a message id, none used by this catalogue today)
  /// is excluded from the message table, not treated as a message id.
  static Future<MessageCatalogue> loadFromAssets({AssetBundle? bundle}) async {
    final assetBundle = bundle ?? rootBundle;
    final byLocale = <String, Map<String, String>>{};
    for (final path in arbAssetPaths) {
      final raw = await assetBundle.loadString(path);
      final decoded = json.decode(raw) as Map<String, dynamic>;
      final locale = decoded['@@locale'] as String;
      final table = <String, String>{};
      for (final entry in decoded.entries) {
        if (entry.key.startsWith('@')) continue;
        table[entry.key] = entry.value as String;
      }
      byLocale[locale] = table;
    }
    return MessageCatalogue(byLocale);
  }

  /// Resolves [id] for [uiLocale] (defaulting to [resolveUiLocale]'s own
  /// result when omitted): that locale's table, else
  /// [kEntitiesUiFallbackLocale]'s table, else the literal [id] itself.
  /// Never throws.
  String message(String id, {String? uiLocale}) {
    final locale = uiLocale ?? resolveUiLocale();

    final direct = _byLocale[locale]?[id];
    if (direct != null && direct.isNotEmpty) return direct;

    final fallback = _byLocale[kEntitiesUiFallbackLocale]?[id];
    if (fallback != null && fallback.isNotEmpty) return fallback;

    return id;
  }
}

/// The app-wide catalogue instance every widget reads through [tr].
///
/// Starts empty — every [tr] call falls back to returning the raw message
/// id — so a widget pumped in isolation with no app bootstrap never
/// throws. `main()` replaces this with the real loaded catalogue (via
/// [MessageCatalogue.loadFromAssets]) before `runApp`; a widget test that
/// needs real translated text loads its own copy explicitly (see
/// `test/support/load_test_catalogue.dart`) rather than relying on this
/// default.
MessageCatalogue appMessageCatalogue = const MessageCatalogue({});

/// Shorthand every widget calls instead of a hardcoded string literal —
/// `test/guards/text_literal_guard_test.dart` (AC5) enforces that no
/// `Text(...)` call under `lib/` uses a literal instead of this. [uiLocale]
/// is injectable for tests; omitted, it resolves from the device via
/// [resolveUiLocale].
String tr(String id, {String? uiLocale}) =>
    appMessageCatalogue.message(id, uiLocale: uiLocale);

// ── §4.4 date/number formatting, wired to the tier-(a) formatting locale ──
//
// Thin named wrappers, not a new abstraction — every call site passes the
// resolved formatting locale (`resolveFormattingLocale`, in
// `formatting_locale.dart`) explicitly, never relying on `intl`'s ambient
// default locale (design §4.4's call-site discipline).

/// == `intl.DateFormat(pattern, formattingLocale)`.
DateFormat localizedDateFormat(String pattern, String formattingLocale) =>
    DateFormat(pattern, formattingLocale);

/// == `intl.NumberFormat.decimalPattern(formattingLocale)`.
NumberFormat localizedDecimalFormat(String formattingLocale) =>
    NumberFormat.decimalPattern(formattingLocale);

/// == `intl.NumberFormat.currency(locale: formattingLocale, symbol: symbol)`.
/// Included for completeness (design §4.4); AC4 asks only for "a number".
NumberFormat localizedCurrencyFormat(
  String formattingLocale, {
  String? symbol,
}) => NumberFormat.currency(locale: formattingLocale, symbol: symbol);
