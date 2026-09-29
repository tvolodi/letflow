// REQ-424 (MOB-3 part 2) design §4.3: the one storage-level test proving
// SembastPinnedFormCacheRepository actually persists across a close/reopen
// cycle, including the null-vs-absent "form_schema" round-trip (design §3.1)
// -- the property that distinguishes it from InMemoryPinnedFormCacheRepository
// (which every other test in this requirement uses).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/definitions/pinned_form_cache.dart';
import 'package:letflow/definitions/sembast_pinned_form_cache_repository.dart';
import 'package:sembast/sembast_io.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sembast_pinned_form_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test(
    'two entries -- one with a non-null formSchema, one with formSchema'
    ' explicitly null -- both survive a close/reopen round-trip at the'
    ' same path with the null-ness preserved exactly',
    () async {
      final path = '${tempDir.path}/pinned_forms.db';

      final repo1 = await SembastPinnedFormCacheRepository.open(
        path,
        factory: databaseFactoryIo,
      );
      await repo1.putEntry(
        const PinnedFormCacheEntry(
          formId: 'F1',
          formVersion: '1',
          formSchema: {'title': 'Form One v1'},
        ),
      );
      await repo1.putEntry(
        const PinnedFormCacheEntry(
          formId: 'F2',
          formVersion: '3',
          formSchema: null,
        ),
      );
      await repo1.close();

      final repo2 = await SembastPinnedFormCacheRepository.open(
        path,
        factory: databaseFactoryIo,
      );

      final entry1 = await repo2.getByKey('F1', '1');
      expect(entry1, isNotNull);
      expect(entry1!.formId, 'F1');
      expect(entry1.formVersion, '1');
      expect(entry1.formSchema, {'title': 'Form One v1'});

      final entry2 = await repo2.getByKey('F2', '3');
      expect(entry2, isNotNull);
      expect(entry2!.formId, 'F2');
      expect(entry2.formVersion, '3');
      // The round-trip's central assertion: a present-but-null formSchema
      // reads back as null, not as an absent record and not as `{}`.
      expect(entry2.formSchema, isNull);

      // A different (formId, formVersion) key that was never written is a
      // genuine miss -- not confused with a present-but-null row.
      expect(await repo2.getByKey('F1', '2'), isNull);

      await repo2.close();
    },
  );

  test('putEntry upserts -- a second write at the same key fully replaces'
      ' the first', () async {
    final path = '${tempDir.path}/pinned_forms2.db';
    final repo = await SembastPinnedFormCacheRepository.open(
      path,
      factory: databaseFactoryIo,
    );

    await repo.putEntry(
      const PinnedFormCacheEntry(
        formId: 'F',
        formVersion: '1',
        formSchema: {'title': 'first'},
      ),
    );
    await repo.putEntry(
      const PinnedFormCacheEntry(
        formId: 'F',
        formVersion: '1',
        formSchema: {'title': 'second'},
      ),
    );

    final entry = await repo.getByKey('F', '1');
    expect(entry!.formSchema, {'title': 'second'});

    await repo.close();
  });
}
