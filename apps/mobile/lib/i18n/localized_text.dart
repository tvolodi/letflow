/// Tier (c) — the tenant-content `{locale: value}` resolver (REQ-429
/// design §4.3).
///
/// Synthesizes the SPA's `resolveLocalizedText` (`ExamSessionPage.tsx`) and
/// `resolveExamFieldText` (`ExamListPage.tsx`) — the same locale-fallback
/// chain over two different input-type unions (design §0's finding): the
/// map branch below matches both; the plain-string passthrough branch is
/// `resolveExamFieldText`'s alone, included here because AC3(e) requires
/// it.
library;

/// Resolves a tenant-content value for [uiLocale]:
/// - `null` -> `''`.
/// - a `String` -> returned unchanged (passthrough, AC3e).
/// - a `Map` -> `value[uiLocale]` if present and non-empty, else
///   `value['en']` if present and non-empty, else the first non-empty
///   value in map iteration order, else `''`.
/// - any other runtime type -> `value.toString()` (mirrors
///   `resolveExamFieldText`'s final `String(value)` branch; included only
///   so the function is total, not exercised by any AC3 sub-clause).
///
/// Pure. Never throws.
String resolveLocalizedText(Object? value, String uiLocale) {
  if (value == null) return '';
  if (value is String) return value;

  if (value is Map) {
    final byUiLocale = value[uiLocale];
    if (byUiLocale is String && byUiLocale.isNotEmpty) return byUiLocale;

    final byEn = value['en'];
    if (byEn is String && byEn.isNotEmpty) return byEn;

    for (final candidate in value.values) {
      if (candidate is String && candidate.isNotEmpty) return candidate;
    }

    return '';
  }

  return value.toString();
}
