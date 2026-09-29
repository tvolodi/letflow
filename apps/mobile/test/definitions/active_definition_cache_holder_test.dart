// REQ-423 (MOB-3 part 1) AC5: after switching from tenant A to tenant B, no
// definition cached for A is returned for B (design §7.2's "structural, not
// filtered" tenant-partition guarantee).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/definitions/definitions.dart';
import 'package:letflow/definitions/sembast_cache_repository.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';

const _realmA = 'https://idp.example/realms/acme';
const _realmB = 'https://idp.example/realms/beta';

Map<String, dynamic> _deltaItem(String id) => {
  'id': id,
  'name': 'Def $id',
  'version': 1,
  'description': null,
  'status': 'ACTIVE',
  'graph': <String, dynamic>{},
  'created_by': null,
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
  'archived_at': null,
  'stage': null,
};

void main() {
  test(
    'switching from tenant A to tenant B: B\'s repository never returns'
    ' A\'s cached definitions, and A\'s repository is closed',
    () async {
      final reposByRealm = <String, InMemoryDefinitionCacheRepository>{
        _realmA: InMemoryDefinitionCacheRepository(),
        _realmB: InMemoryDefinitionCacheRepository(),
      };
      final holder = ActiveDefinitionCacheHolder();

      await holder.openFor(
        _realmA,
        opener: (realmUrl) async => reposByRealm[realmUrl]!,
      );
      await holder.current!.putAll([
        DefinitionCacheEntry.fromDeltaItem(
          _deltaItem('a-def'),
          type: kProcessDefinitionCacheType,
        ),
      ]);
      expect((await holder.current!.listAvailable()).map((e) => e.id), ['a-def']);

      // Tenant switch: close A's repository, open B's.
      await holder.openFor(
        _realmB,
        opener: (realmUrl) async => reposByRealm[realmUrl]!,
      );

      expect(holder.currentRealmUrl, _realmB);
      final bEntries = await holder.current!.listAvailable();
      expect(bEntries, isEmpty, reason: 'B starts with none of A\'s data');
      expect(
        bEntries.map((e) => e.id),
        isNot(contains('a-def')),
      );
    },
  );

  test('re-opening the SAME realm is a no-op -- no close/reopen of the live'
      ' handle underneath an in-flight read', () async {
    final repo = InMemoryDefinitionCacheRepository();
    var openCalls = 0;
    final holder = ActiveDefinitionCacheHolder();

    Future<DefinitionCacheRepository> opener(String realmUrl) async {
      openCalls++;
      return repo;
    }

    await holder.openFor(_realmA, opener: opener);
    await holder.openFor(_realmA, opener: opener);

    expect(openCalls, 1);
    expect(holder.current, same(repo));
  });

  test('closeAndClear closes the current repository and nulls both fields', () async {
    final repo = InMemoryDefinitionCacheRepository();
    final holder = ActiveDefinitionCacheHolder();
    await holder.openFor(_realmA, opener: (_) async => repo);

    await holder.closeAndClear();

    expect(holder.current, isNull);
    expect(holder.currentRealmUrl, isNull);
  });

  group('real SembastDefinitionCacheRepository (not the in-memory fake)', () {
    // The gap SECURITY-REVIEWER and REVIEWER both flagged: every test above
    // exercises openFor's close-before-reopen ordering only against
    // InMemoryDefinitionCacheRepository, whose close() is a no-op (design
    // §5.1). That proves the *holder's* bookkeeping (fields reassigned,
    // opener called once) but nothing about whether a REAL on-disk Sembast
    // database handle is actually released before the next tenant's file is
    // opened. This group opens two real, distinct on-disk Sembast files
    // (mirroring design §7.1's one-file-per-realmUrl layout) through the
    // real repository implementation and asserts the release is genuine:
    // the closed handle throws on further use, a fresh direct open of A's
    // own path succeeds with no file-lock/"still open" error, and B's file
    // is a distinct, independently-opened store containing none of A's data.
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'active_cache_holder_sembast_test_',
      );
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    String pathFor(String realmUrl) =>
        '${tempDir.path}/${cacheFileNameFor(realmUrl)}';

    Future<DefinitionCacheRepository> realOpener(String realmUrl) =>
        SembastDefinitionCacheRepository.open(
          pathFor(realmUrl),
          factory: databaseFactoryIo,
        );

    test(
      'tenant switch A -> B against real Sembast files: A\'s on-disk handle'
      ' is genuinely closed (further use throws DatabaseException.closed),'
      ' B is a distinct freshly-opened file with none of A\'s data, and the'
      ' switch itself completes with no file-lock/still-open error',
      () async {
        final holder = ActiveDefinitionCacheHolder();

        await holder.openFor(_realmA, opener: realOpener);
        final repoA = holder.current!; // keep a direct handle to A's repo
        await repoA.putAll([
          DefinitionCacheEntry.fromDeltaItem(
            _deltaItem('a-def'),
            type: kProcessDefinitionCacheType,
          ),
        ]);
        await repoA.writeCursor(11);
        expect((await repoA.listAvailable()).map((e) => e.id), ['a-def']);

        // The switch itself: must complete without throwing (no file-lock
        // or "still open" error) -- if openFor failed to close A's real
        // handle first and the store implementation enforced exclusivity,
        // this await would throw instead of completing normally.
        await holder.openFor(_realmB, opener: realOpener);

        expect(holder.currentRealmUrl, _realmB);
        final repoB = holder.current!;
        expect(repoB, isNot(same(repoA)), reason: 'B is a distinct instance');

        // B is a freshly-opened, independent file: none of A's data.
        expect(await repoB.listAvailable(), isEmpty);
        expect(await repoB.readCursor(), isNull);

        // Genuine file-handle release, not just Dart-side bookkeeping: the
        // OLD repository instance (still held directly, bypassing the
        // holder) now throws when used, because openFor really called
        // Database.close() on it before handing back B's repository.
        await expectLater(
          repoA.listAvailable(),
          throwsA(
            isA<DatabaseException>().having(
              (e) => e.code,
              'code',
              DatabaseException.errDatabaseClosed,
            ),
          ),
        );

        // A's data is genuinely inaccessible through the holder (current
        // tenant is B) yet was durably persisted, not corrupted, by the
        // close -- proven by reopening A's exact on-disk path directly,
        // bypassing the holder entirely. This also proves no lingering
        // file lock: if A's handle had not truly been released, this
        // second, independent open of the same path could itself fail.
        final reopenedA = await SembastDefinitionCacheRepository.open(
          pathFor(_realmA),
          factory: databaseFactoryIo,
        );
        final reopenedAEntries = await reopenedA.listAvailable();
        expect(reopenedAEntries.map((e) => e.id), ['a-def']);
        expect(await reopenedA.readCursor(), 11);
        await reopenedA.close();

        // And B's file, opened independently a second time at its own
        // path, corroborates it is a genuinely separate store on disk --
        // not e.g. the same file A was pointed at.
        final reopenedB = await SembastDefinitionCacheRepository.open(
          pathFor(_realmB),
          factory: databaseFactoryIo,
        );
        expect(await reopenedB.listAvailable(), isEmpty);
        await reopenedB.close();

        await repoB.close();
      },
    );
  });
}
