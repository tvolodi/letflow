/// The pinned-form cache's row shape and storage interface (`MOB-3` part 2,
/// REQ-424 design §3/§4.1) — a **new, dedicated** store, not a reuse of
/// `DefinitionCacheEntry`/`DefinitionCacheRepository` (REQ-423). See
/// `lib/letflow/design/req424-mobile-pinned-form-version-resolution.md` §5.2
/// for why: `form_version` is a `String`
/// (`instance_definition_snapshots.definition_ver`), not the `int` REQ-423's
/// cache uses, and the natural key here is two-part `(formId, formVersion)`,
/// not REQ-423's three-part `(type, id, version)`. This file adds new types
/// alongside `definitions.dart` — it changes zero characters of that file.
library;

import 'dart:convert' show base64Url, utf8;

import 'package:flutter/foundation.dart' show immutable;

// ── §3.1 `PinnedFormCacheEntry` ────────────────────────────────────────────

/// The pinned-form cache's row shape (design §3.1). Immutable — a changed
/// row is always a fresh instance, never mutated in place.
@immutable
class PinnedFormCacheEntry {
  const PinnedFormCacheEntry({
    required this.formId,
    required this.formVersion,
    required this.formSchema,
  });

  /// == the task's `form_id` (== `task.node_id`).
  final String formId;

  /// == the task's `form_version`. Never `null` here — [PinnedFormResolver]
  /// short-circuits before a `null` `form_version` ever reaches this type
  /// (design §5.1 step 1).
  final String formVersion;

  /// The frozen `"form_schema"` value, verbatim. `null` is a legitimate
  /// stored value (design §2) — the task's own node genuinely carries no
  /// `form_schema` attribute; that is a resolved, cacheable result, not a
  /// miss.
  final Map<String, dynamic>? formSchema;

  /// The store's primary key. Two-part — not three-part like
  /// `DefinitionCacheEntry.compositeKey` — because this cache carries no
  /// `type` dimension (design §5.2).
  String get compositeKey => '$formId::$formVersion';

  /// Inverse of [toStoredJson]. Throws [FormatException] on a missing/
  /// mistyped required key, mirroring `DefinitionCacheEntry.fromStoredJson`'s
  /// total-over-the-contract style. `"form_schema"` is read as
  /// `json['form_schema'] as Map<String, dynamic>?` — present-but-null is
  /// read as null, never defaulted to `{}` or treated as a missing key.
  factory PinnedFormCacheEntry.fromStoredJson(Map<String, dynamic> json) {
    return PinnedFormCacheEntry(
      formId: _requireString(json, 'form_id'),
      formVersion: _requireString(json, 'form_version'),
      formSchema: json['form_schema'] as Map<String, dynamic>?,
    );
  }

  /// The on-disk/in-memory record shape. `"form_schema"` is always written,
  /// even when [formSchema] is `null`, so [fromStoredJson]'s read-back is
  /// never ambiguous between "stored as null" and "key never written".
  Map<String, dynamic> toStoredJson() => {
    'form_id': formId,
    'form_version': formVersion,
    'form_schema': formSchema,
  };
}

String _requireString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('missing or non-string "$key"');
  }
  return value;
}

// ── §3.2 `PinnedFormCacheRepository` ───────────────────────────────────────

/// Storage interface for the pinned-form cache (design §3.2). Deliberately
/// minimal — exactly the two operations `PinnedFormResolver` needs, no more:
/// no `listAvailable`, no `removeByKey`, no cursor, no `putAll` batch — none
/// of REQ-423's delta-sync/archival concepts have a counterpart here (design
/// §5.2). One repository instance is scoped to exactly one tenant, by the
/// same "physical partition, not a filter parameter" construction
/// `DefinitionCacheRepository` uses.
abstract class PinnedFormCacheRepository {
  /// Exact-key point lookup. `null` means "no cache entry for this exact
  /// (formId, formVersion) pair" (a miss) — distinct from a present entry
  /// whose own `formSchema` field happens to be `null`.
  Future<PinnedFormCacheEntry?> getByKey(String formId, String formVersion);

  /// Upserts by [PinnedFormCacheEntry.compositeKey]. An existing row at the
  /// same key is fully replaced. Singular, not batch, because this cache is
  /// populated one entry at a time, on demand — never as a batch delta
  /// apply.
  Future<void> putEntry(PinnedFormCacheEntry entry);

  /// Releases the underlying store handle. Called by the tenant-switch/
  /// logout lifecycle, never mid-request.
  Future<void> close();
}

// ── §4.1 `InMemoryPinnedFormCacheRepository` ───────────────────────────────

/// The implementation every resolver-behavior test (AC1-AC4) uses. Lives
/// here, not confined to `test/`, because nothing about it is test-specific
/// — it is simply the zero-I/O implementation of the same
/// [PinnedFormCacheRepository] contract, mirroring
/// `InMemoryDefinitionCacheRepository`'s own precedent exactly.
class InMemoryPinnedFormCacheRepository implements PinnedFormCacheRepository {
  InMemoryPinnedFormCacheRepository();

  final Map<String, PinnedFormCacheEntry> _entries = {};

  @override
  Future<PinnedFormCacheEntry?> getByKey(
    String formId,
    String formVersion,
  ) async {
    return _entries['$formId::$formVersion'];
  }

  @override
  Future<void> putEntry(PinnedFormCacheEntry entry) async {
    _entries[entry.compositeKey] = entry;
  }

  @override
  Future<void> close() async {
    // No-op: no underlying handle to release.
  }
}

// ── §6.1 Tenant-partition lifecycle ────────────────────────────────────────

/// Deterministic, filesystem-safe, collision-free file-name derivation from
/// a tenant's `realmUrl` (design §6.1) — identical derivation to
/// `cacheFileNameFor` (`definitions.dart`), a different fixed prefix so it
/// is a distinct file from REQ-423's own `definition_cache_<...>.db`
/// (design §5.2).
String pinnedFormCacheFileNameFor(String realmUrl) {
  final encoded = base64Url.encode(utf8.encode(realmUrl));
  final stripped = encoded.replaceAll('=', '');
  return 'pinned_form_cache_$stripped.db';
}

/// Opens a [PinnedFormCacheRepository] for a given `realmUrl` — the
/// production seam [ActivePinnedFormCacheHolder.openFor] takes, mirroring
/// `DefinitionCacheOpener`'s own precedent exactly, so the real Sembast-
/// backed opener (which needs `path_provider`, a platform channel) never
/// has to be constructed inside a `flutter test` run that only exercises
/// [InMemoryPinnedFormCacheRepository].
typedef PinnedFormCacheOpener =
    Future<PinnedFormCacheRepository> Function(String realmUrl);

/// Mirrors `ActiveDefinitionCacheHolder` (design §6.1): holds exactly one
/// open tenant's [PinnedFormCacheRepository] at a time, keyed by `realmUrl`,
/// so tenant B's `BootstrapController` never holds a repository pointing at
/// tenant A's file. A second, independent holder from
/// `ActiveDefinitionCacheHolder` — not a reuse (design §5.2).
class ActivePinnedFormCacheHolder {
  PinnedFormCacheRepository? current;
  String? currentRealmUrl;

  /// No-op if [currentRealmUrl] already equals [realmUrl]. Otherwise: closes
  /// [current] (if any), opens the new tenant's repository via [opener],
  /// assigns both fields. Identical contract to
  /// `ActiveDefinitionCacheHolder.openFor`.
  Future<void> openFor(
    String realmUrl, {
    required PinnedFormCacheOpener opener,
  }) async {
    if (currentRealmUrl == realmUrl && current != null) return;
    final previous = current;
    if (previous != null) {
      await previous.close();
    }
    current = await opener(realmUrl);
    currentRealmUrl = realmUrl;
  }

  /// Closes [current] (if any) and nulls both fields — the logout/
  /// tenant-switch path. Identical contract to
  /// `ActiveDefinitionCacheHolder.closeAndClear`.
  Future<void> closeAndClear() async {
    final previous = current;
    current = null;
    currentRealmUrl = null;
    if (previous != null) {
      await previous.close();
    }
  }
}
