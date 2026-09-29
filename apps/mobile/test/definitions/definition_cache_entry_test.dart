// REQ-423 (MOB-3 part 1): DefinitionCacheEntry's wire/stored round-trips and
// compositeKey shape.
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/definitions/definitions.dart';

Map<String, dynamic> _deltaItem() => {
  'id': 'd1',
  'name': 'Onboarding',
  'version': 2,
  'description': 'desc',
  'status': 'ACTIVE',
  'graph': <String, dynamic>{'nodes': []},
  'created_by': 'alice',
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-02T00:00:00Z',
  'archived_at': null,
  'stage': null,
};

void main() {
  test('fromDeltaItem reads the required fields and retains the full raw map', () {
    final entry = DefinitionCacheEntry.fromDeltaItem(
      _deltaItem(),
      type: kProcessDefinitionCacheType,
    );

    expect(entry.type, 'process');
    expect(entry.id, 'd1');
    expect(entry.name, 'Onboarding');
    expect(entry.version, 2);
    expect(entry.status, 'ACTIVE');
    expect(entry.raw['description'], 'desc');
    expect(entry.raw['graph'], {'nodes': []});
    expect(entry.compositeKey, 'process::d1::2');
  });

  test('fromDeltaItem throws FormatException on a missing required key', () {
    final json = _deltaItem()..remove('version');
    expect(
      () => DefinitionCacheEntry.fromDeltaItem(
        json,
        type: kProcessDefinitionCacheType,
      ),
      throwsFormatException,
    );
  });

  test('toStoredJson / fromStoredJson round-trips exactly', () {
    final original = DefinitionCacheEntry.fromDeltaItem(
      _deltaItem(),
      type: kProcessDefinitionCacheType,
    );

    final restored = DefinitionCacheEntry.fromStoredJson(
      original.toStoredJson(),
    );

    expect(restored.type, original.type);
    expect(restored.id, original.id);
    expect(restored.version, original.version);
    expect(restored.name, original.name);
    expect(restored.status, original.status);
    expect(restored.raw, original.raw);
    expect(restored.compositeKey, original.compositeKey);
  });

  group('InMemoryDefinitionCacheRepository', () {
    test('putAll upserts by compositeKey; getByKey/listAvailable/removeByKey', () async {
      final repo = InMemoryDefinitionCacheRepository();
      final entry = DefinitionCacheEntry.fromDeltaItem(
        _deltaItem(),
        type: kProcessDefinitionCacheType,
      );

      await repo.putAll([entry]);
      expect(await repo.getByKey('process', 'd1', 2), isNotNull);
      expect(await repo.listAvailable(), hasLength(1));

      // Upsert at the same compositeKey fully replaces.
      final updated = DefinitionCacheEntry.fromDeltaItem(
        {..._deltaItem(), 'name': 'Renamed'},
        type: kProcessDefinitionCacheType,
      );
      await repo.putAll([updated]);
      final list = await repo.listAvailable();
      expect(list, hasLength(1));
      expect(list.single.name, 'Renamed');

      await repo.removeByKey('process', 'd1', 2);
      expect(await repo.listAvailable(), isEmpty);
      expect(await repo.getByKey('process', 'd1', 2), isNull);
    });

    test('cursor: null until written, resetCursor clears it back to null', () async {
      final repo = InMemoryDefinitionCacheRepository();
      expect(await repo.readCursor(), isNull);

      await repo.writeCursor(11);
      expect(await repo.readCursor(), 11);

      await repo.resetCursor();
      expect(await repo.readCursor(), isNull);
    });
  });
}
