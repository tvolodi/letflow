// REQ-423 (MOB-3 part 1) design §5.3: the one storage-level test proving
// SembastDefinitionCacheRepository actually persists across a close/reopen
// cycle -- the one property that distinguishes it from
// InMemoryDefinitionCacheRepository (which every other test in this
// requirement uses, per REQ-423's own "used by the tests" wording).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/definitions/definitions.dart';
import 'package:letflow/definitions/sembast_cache_repository.dart';
import 'package:sembast/sembast_io.dart';

Map<String, dynamic> _deltaItem() => {
  'id': 'd1',
  'name': 'Onboarding',
  'version': 2,
  'description': null,
  'status': 'ACTIVE',
  'graph': <String, dynamic>{'nodes': []},
  'created_by': null,
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
  'archived_at': null,
  'stage': null,
};

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sembast_cache_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test(
    'an entry survives a close/reopen round-trip at the same path',
    () async {
      final path = '${tempDir.path}/definitions.db';

      final repo1 = await SembastDefinitionCacheRepository.open(
        path,
        factory: databaseFactoryIo,
      );
      await repo1.putAll([
        DefinitionCacheEntry.fromDeltaItem(
          _deltaItem(),
          type: kProcessDefinitionCacheType,
        ),
      ]);
      await repo1.writeCursor(17);
      await repo1.close();

      final repo2 = await SembastDefinitionCacheRepository.open(
        path,
        factory: databaseFactoryIo,
      );
      final entries = await repo2.listAvailable();
      expect(entries, hasLength(1));
      expect(entries.single.id, 'd1');
      expect(entries.single.name, 'Onboarding');
      expect(entries.single.version, 2);
      expect(entries.single.status, 'ACTIVE');
      expect(entries.single.type, kProcessDefinitionCacheType);
      expect(entries.single.raw['graph'], {'nodes': []});
      expect(await repo2.readCursor(), 17);

      final byKey = await repo2.getByKey(kProcessDefinitionCacheType, 'd1', 2);
      expect(byKey, isNotNull);
      expect(byKey!.id, 'd1');

      await repo2.close();
    },
  );

  test('removeByKey and resetCursor persist across close/reopen too', () async {
    final path = '${tempDir.path}/definitions2.db';

    final repo1 = await SembastDefinitionCacheRepository.open(
      path,
      factory: databaseFactoryIo,
    );
    await repo1.putAll([
      DefinitionCacheEntry.fromDeltaItem(
        _deltaItem(),
        type: kProcessDefinitionCacheType,
      ),
    ]);
    await repo1.writeCursor(5);
    await repo1.removeByKey(kProcessDefinitionCacheType, 'd1', 2);
    await repo1.resetCursor();
    await repo1.close();

    final repo2 = await SembastDefinitionCacheRepository.open(
      path,
      factory: databaseFactoryIo,
    );
    expect(await repo2.listAvailable(), isEmpty);
    expect(await repo2.readCursor(), isNull);
    await repo2.close();
  });
}
