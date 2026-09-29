/// Definitions: fetch, version-pin, and read-through cache of server
/// delivered definitions (`GET /definitions/delta`, `MOB-3`). Built starting
/// REQ-423.
///
/// This is the "no scripting runtime on device" boundary's cache side —
/// `DefinitionSyncService` only ever applies raw server-delivered JSON
/// (`DefinitionCacheEntry.raw`) into local storage. No expression
/// evaluation, no rendering, happens in this file (REQ-294/REQ-426..428's
/// own scope).
///
/// See `lib/letflow/design/req423-mobile-definition-cache-sync.md` for the
/// full design this file implements.
library;

import 'dart:convert' show base64Url, utf8;

import 'package:flutter/foundation.dart' show immutable;

import '../api/api_client.dart' show HttpGateway;

// ── §3. `DefinitionCacheEntry` ─────────────────────────────────────────────

/// The client-assigned `type` stamped onto every item this requirement's
/// sync service ingests (design §3.1) — `/definitions/delta` discloses no
/// `"type"` wire key today; it serves `process_definitions` rows only. If a
/// future backend change adds a real `"type"` key, `DefinitionCacheEntry
/// .fromDeltaItem`'s `type` parameter is the one call site to change (design
/// OQ-2) — every existing cached `'process'` row remains correctly labeled
/// either way.
const String kProcessDefinitionCacheType = 'process';

/// The cache's row shape (design §3). Immutable — a changed row is always a
/// fresh instance, never mutated in place.
@immutable
class DefinitionCacheEntry {
  const DefinitionCacheEntry({
    required this.type,
    required this.id,
    required this.version,
    required this.name,
    required this.status,
    required this.raw,
  });

  final String type;
  final String id;
  final int version;
  final String name;
  final String status;
  final Map<String, dynamic> raw;

  /// The store's primary key. Injective over `(type, id, version)` — no
  /// separator collision is possible for this app's own id/type value
  /// shapes (uuid ids, a fixed small set of type literals), consistent with
  /// the level of rigor `ActiveDefinitionCacheHolder`'s own base64 file-name
  /// derivation uses (design §7.1).
  String get compositeKey => '$type::$id::$version';

  /// Reads a raw `definition_map/1` wire item (design §2) into a
  /// [DefinitionCacheEntry], stamping [type] (caller-supplied — this
  /// endpoint discloses no `"type"` key, §3.1). Throws [FormatException] on
  /// a missing/mistyped required key, mirroring `TenantConfig.fromJson`'s
  /// total-over-the-contract style (`api_client.dart`). The entire [json]
  /// map is retained verbatim as [raw] — this requirement does not itself
  /// interpret `"graph"`/`"description"`/etc.; future renderers read those
  /// from `raw`, not from a second parse of the wire response.
  factory DefinitionCacheEntry.fromDeltaItem(
    Map<String, dynamic> json, {
    required String type,
  }) {
    return DefinitionCacheEntry(
      type: type,
      id: _requireString(json, 'id'),
      version: _requireInt(json, 'version'),
      name: _requireString(json, 'name'),
      status: _requireString(json, 'status'),
      raw: json,
    );
  }

  /// Inverse of [toStoredJson] — reads back exactly what was written. A
  /// store read that cannot reconstruct a valid entry from its own
  /// previously-written record is a repository-implementation bug, not a
  /// data-shape question this constructor defaults around.
  factory DefinitionCacheEntry.fromStoredJson(Map<String, dynamic> json) {
    return DefinitionCacheEntry(
      type: _requireString(json, 'type'),
      id: _requireString(json, 'id'),
      version: _requireInt(json, 'version'),
      name: _requireString(json, 'name'),
      status: _requireString(json, 'status'),
      raw: Map<String, dynamic>.from(json['raw'] as Map),
    );
  }

  /// The on-disk/in-memory record shape — one level of wrapping around the
  /// server's own `raw` map so `type` (client-assigned) and the three
  /// indexed fields survive independent of `raw`'s own future shape
  /// changes.
  Map<String, dynamic> toStoredJson() => {
    'type': type,
    'id': id,
    'version': version,
    'name': name,
    'status': status,
    'raw': raw,
  };
}

String _requireString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('missing or non-string "$key"');
  }
  return value;
}

int _requireInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw FormatException('missing or non-int "$key"');
  }
  return value;
}

// ── §4. `DefinitionCacheRepository` ────────────────────────────────────────

/// Storage interface for cached definitions (design §4). One instance is
/// scoped to exactly one tenant, by construction: there is no `tenantId`
/// parameter on any method here — physical partition (one store per
/// tenant, `ActiveDefinitionCacheHolder`) replaces a filter. A caller that
/// wants tenant B's data must hold tenant B's own repository instance.
abstract class DefinitionCacheRepository {
  /// Upserts every entry by its [DefinitionCacheEntry.compositeKey]. An
  /// existing row at the same key is fully replaced.
  Future<void> putAll(Iterable<DefinitionCacheEntry> entries);

  /// Deletes the row at that exact key, if present. No-op if absent.
  Future<void> removeByKey(String type, String id, int version);

  /// Every currently-cached entry. Ordering is unspecified — a caller that
  /// needs a stable order sorts it itself (`DefinitionHomeController`).
  Future<List<DefinitionCacheEntry>> listAvailable();

  /// Exact-key point lookup.
  Future<DefinitionCacheEntry?> getByKey(String type, String id, int version);

  /// The persisted `next_since` from the most recent successful sync, or
  /// `null` if this tenant has never synced (full-history semantics).
  Future<int?> readCursor();

  /// Overwrites the persisted cursor. The only legitimate caller is
  /// [DefinitionSyncService] — never called with a value derived from
  /// `DateTime.now()` or any client-side clock.
  Future<void> writeCursor(int cursor);

  /// Clears the persisted cursor back to "never synced". Does **not** clear
  /// [listAvailable]'s contents — a full resync re-applies over the
  /// existing cache via [putAll]'s upsert semantics.
  Future<void> resetCursor();

  /// Releases the underlying store handle. Called by the tenant-switch/
  /// logout lifecycle, never mid-request.
  Future<void> close();
}

// ── §5.1 `InMemoryDefinitionCacheRepository` ───────────────────────────────

/// The implementation every test other than the one storage-level test
/// (`test/definitions/sembast_cache_repository_test.dart`) uses. Lives here,
/// not confined to `test/`, because nothing about it is test-specific (no
/// fake clock, no injected failure mode) — it is simply the zero-I/O
/// implementation of the same [DefinitionCacheRepository] contract.
class InMemoryDefinitionCacheRepository implements DefinitionCacheRepository {
  InMemoryDefinitionCacheRepository();

  final Map<String, DefinitionCacheEntry> _entries = {};
  int? _cursor;

  @override
  Future<void> putAll(Iterable<DefinitionCacheEntry> entries) async {
    for (final entry in entries) {
      _entries[entry.compositeKey] = entry;
    }
  }

  @override
  Future<void> removeByKey(String type, String id, int version) async {
    _entries.remove('$type::$id::$version');
  }

  @override
  Future<List<DefinitionCacheEntry>> listAvailable() async {
    return _entries.values.toList();
  }

  @override
  Future<DefinitionCacheEntry?> getByKey(
    String type,
    String id,
    int version,
  ) async {
    return _entries['$type::$id::$version'];
  }

  @override
  Future<int?> readCursor() async => _cursor;

  @override
  Future<void> writeCursor(int cursor) async {
    _cursor = cursor;
  }

  @override
  Future<void> resetCursor() async {
    _cursor = null;
  }

  @override
  Future<void> close() async {
    // No-op: no underlying handle to release.
  }
}

// ── §6. `DefinitionSyncService` ────────────────────────────────────────────

/// The delta-sync algorithm (design §6). At most **two** HTTP calls, ever,
/// per [syncOnce] invocation — never a loop (design §6.4's structural
/// no-retry-loop guarantee, AC4).
class DefinitionSyncService {
  const DefinitionSyncService({required this.repository, required this.client});

  final DefinitionCacheRepository repository;
  final HttpGateway client;

  static const String _path = '/api/v1/definitions/delta';

  /// Runs one sync attempt. Never throws — every failure branch (network
  /// unreachable, non-200/400 status) returns normally, having applied
  /// nothing beyond what a prior successful attempt already applied
  /// (design §6.1/§6.5).
  Future<void> syncOnce() async {
    final cursor = await repository.readCursor();
    Map<String, dynamic> body;
    try {
      body = await _fetch(cursor);
    } catch (_) {
      // Network unreachable (airplane mode, DNS, etc.) — silent return
      // (design §6.1 step 3).
      return;
    }

    final statusHandled = await _applyResponseOrHandle400(body, cursor);
    if (statusHandled) return;
  }

  /// Issues one GET to [_path], throwing on a genuine transport failure.
  /// Returns a synthetic `{'__status': <int>, ...body}` map so the caller
  /// can branch on status without a second exception type.
  Future<Map<String, dynamic>> _fetch(int? sinceCursor) async {
    final response = await client.get(
      _path,
      queryParameters: sinceCursor == null
          ? null
          : {'since': sinceCursor.toString()},
    );
    final status = response.statusCode ?? 0;
    final data = response.data;
    final bodyMap = data is Map<String, dynamic> ? data : <String, dynamic>{};
    return {'__status': status, ...bodyMap};
  }

  /// Applies a 200 response, or handles the 400/reset-then-one-more-call
  /// path (design §6.1 steps 4/5/6). Returns `true` once nothing further
  /// should happen for this [syncOnce] call.
  Future<bool> _applyResponseOrHandle400(
    Map<String, dynamic> body,
    int? originalCursor,
  ) async {
    final status = body['__status'] as int;

    if (status == 200) {
      await _applyDeltaBody(body);
      return true;
    }

    if (status == 400) {
      await repository.resetCursor();
      Map<String, dynamic> resyncBody;
      try {
        resyncBody = await _fetch(null);
      } catch (_) {
        // The one full-history resync attempt itself failed to reach the
        // network — no third attempt (design §6.1 step 5).
        return true;
      }
      final resyncStatus = resyncBody['__status'] as int;
      if (resyncStatus == 200) {
        await _applyDeltaBody(resyncBody);
      }
      // Any other status on the resync attempt: silent return, no further
      // attempt (design §6.1 step 5/6).
      return true;
    }

    // Any other status (5xx, etc.): silent return (design §6.1 step 6).
    return true;
  }

  Future<void> _applyDeltaBody(Map<String, dynamic> body) async {
    final items = (body['items'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    await _applyDeltaItems(items);
    final nextSince = body['next_since'];
    if (nextSince is int) {
      await repository.writeCursor(nextSince);
    }
  }

  /// Applies a 200 response's items (design §6.3). An `"ARCHIVED"` item
  /// (exact uppercase literal) is never `putAll`'d — it is removed from the
  /// cache directly. Every other status (`DRAFT`/`ACTIVE`/`DEPRECATED`) is
  /// `putAll`'d; `DEPRECATED` is kept cached, not removed.
  Future<void> _applyDeltaItems(List<Map<String, dynamic>> items) async {
    final toPut = <DefinitionCacheEntry>[];
    for (final item in items) {
      final entry = DefinitionCacheEntry.fromDeltaItem(
        item,
        type: kProcessDefinitionCacheType,
      );
      if (entry.status == 'ARCHIVED') {
        await repository.removeByKey(entry.type, entry.id, entry.version);
      } else {
        toPut.add(entry);
      }
    }
    if (toPut.isNotEmpty) {
      await repository.putAll(toPut);
    }
  }
}

// ── §7. Tenant-partition lifecycle ─────────────────────────────────────────

/// Deterministic, filesystem-safe, collision-free (base64 is injective)
/// file-name derivation from a tenant's `realmUrl` (design §7.1) — no hash
/// package needed.
String cacheFileNameFor(String realmUrl) {
  final encoded = base64Url.encode(utf8.encode(realmUrl));
  final stripped = encoded.replaceAll('=', '');
  return 'definition_cache_$stripped.db';
}

/// Opens a [DefinitionCacheRepository] for a given `realmUrl` — the
/// production seam [ActiveDefinitionCacheHolder.openFor] takes so the real
/// Sembast-backed opener (which needs `path_provider`, a platform channel)
/// never has to be constructed inside a `flutter test` run that only
/// exercises [InMemoryDefinitionCacheRepository].
typedef DefinitionCacheOpener =
    Future<DefinitionCacheRepository> Function(String realmUrl);

/// Mirrors `ActiveRealmHolder` (design §7.2): holds exactly one open
/// tenant's [DefinitionCacheRepository] at a time, keyed by `realmUrl`, so
/// tenant B's `BootstrapController` never holds a repository pointing at
/// tenant A's file.
class ActiveDefinitionCacheHolder {
  DefinitionCacheRepository? current;
  String? currentRealmUrl;

  /// No-op if [currentRealmUrl] already equals [realmUrl] (re-bootstrapping
  /// the same tenant, e.g. a token-refresh path, must not close and reopen
  /// the same file handle underneath an in-flight read). Otherwise: closes
  /// [current] (if any), opens the new tenant's repository via [opener],
  /// assigns both fields.
  Future<void> openFor(
    String realmUrl, {
    required DefinitionCacheOpener opener,
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
  /// tenant-switch path.
  Future<void> closeAndClear() async {
    final previous = current;
    current = null;
    currentRealmUrl = null;
    if (previous != null) {
      await previous.close();
    }
  }
}

