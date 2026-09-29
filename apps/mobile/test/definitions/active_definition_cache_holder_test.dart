// REQ-423 (MOB-3 part 1) AC5: after switching from tenant A to tenant B, no
// definition cached for A is returned for B (design §7.2's "structural, not
// filtered" tenant-partition guarantee).
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/definitions/definitions.dart';

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
}
