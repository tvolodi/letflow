// REQ-423 (MOB-3 part 1) AC2/AC3/AC4: DefinitionSyncService.syncOnce()'s
// cursor handling, archived-item removal, and the 400-reset-then-one-more-
// call path (design §6).
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/definitions/definitions.dart';

/// A minimal [HttpGateway] fake that replays a fixed sequence of canned
/// responses (or throws) in call order, and records every request's `path`
/// and `queryParameters` so the exact `since` value sent on each call can
/// be asserted. Distinct from `test/support/fake_http_gateway.dart`'s
/// `FakeHttpGateway` (keyed by path, not call order) because AC2/AC4 need
/// to assert the *sequence* of two calls, not just their individual
/// responses.
class _SequencedGateway implements HttpGateway {
  _SequencedGateway(this._script);

  final List<Object> _script; // int status-with-body-map, or an Object (throws)
  final List<Map<String, dynamic>?> queryLog = [];
  int _i = 0;

  @override
  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    queryLog.add(queryParameters);
    final entry = _script[_i];
    _i++;
    if (entry is _Throws) {
      throw entry.error;
    }
    final scripted = entry as _StatusBody;
    return Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: scripted.status,
      data: scripted.body,
    );
  }

  @override
  Future<Response<dynamic>> getUnauthenticated(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) => throw UnimplementedError('not used by DefinitionSyncService');

  int get callCount => _i;
}

class _StatusBody {
  const _StatusBody(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
}

class _Throws {
  const _Throws(this.error);
  final Object error;
}

Map<String, dynamic> _deltaItem({
  required String id,
  required String name,
  required int version,
  required String status,
}) {
  return {
    'id': id,
    'name': name,
    'version': version,
    'description': null,
    'status': status,
    'graph': <String, dynamic>{},
    'created_by': null,
    'created_at': '2026-01-01T00:00:00Z',
    'updated_at': '2026-01-01T00:00:00Z',
    'archived_at': null,
    'stage': null,
  };
}

void main() {
  group('AC2: cursor sequencing', () {
    test(
      'a second sync sends since == the first response\'s next_since, and'
      ' the persisted cursor is never derived from DateTime.now()',
      () async {
        final repo = InMemoryDefinitionCacheRepository();
        final gateway = _SequencedGateway([
          _StatusBody(200, {
            'items': [
              _deltaItem(id: 'd1', name: 'Def One', version: 1, status: 'ACTIVE'),
            ],
            'next_since': 42,
          }),
          _StatusBody(200, {'items': <Map<String, dynamic>>[], 'next_since': 99}),
        ]);
        final service = DefinitionSyncService(repository: repo, client: gateway);

        await service.syncOnce();
        expect(gateway.queryLog[0], isNull); // never-synced: no `since` at all
        expect(await repo.readCursor(), 42);

        await service.syncOnce();
        expect(gateway.queryLog[1], {'since': '42'});
        // The persisted cursor is the literal `next_since` integer from the
        // wire (99) -- not a value in the neighborhood of
        // `DateTime.now().millisecondsSinceEpoch` (13 digits), which a
        // clock-derived implementation would produce instead.
        expect(await repo.readCursor(), 99);
      },
    );
  });

  group('AC3: archived items', () {
    test(
      'a delta item with status "ARCHIVED" makes that definition unavailable'
      ' from the cache on the next read',
      () async {
        final repo = InMemoryDefinitionCacheRepository();
        await repo.putAll([
          DefinitionCacheEntry.fromDeltaItem(
            _deltaItem(id: 'd1', name: 'Def One', version: 1, status: 'ACTIVE'),
            type: kProcessDefinitionCacheType,
          ),
        ]);
        expect((await repo.listAvailable()).map((e) => e.id), contains('d1'));

        final gateway = _SequencedGateway([
          _StatusBody(200, {
            'items': [
              _deltaItem(id: 'd1', name: 'Def One', version: 1, status: 'ARCHIVED'),
            ],
            'next_since': 7,
          }),
        ]);
        final service = DefinitionSyncService(repository: repo, client: gateway);

        await service.syncOnce();

        final available = await repo.listAvailable();
        expect(available.where((e) => e.id == 'd1'), isEmpty);
      },
    );

    test('a "DEPRECATED" item is kept cached, not removed', () async {
      final repo = InMemoryDefinitionCacheRepository();
      final gateway = _SequencedGateway([
        _StatusBody(200, {
          'items': [
            _deltaItem(id: 'd2', name: 'Def Two', version: 1, status: 'DEPRECATED'),
          ],
          'next_since': 1,
        }),
      ]);
      final service = DefinitionSyncService(repository: repo, client: gateway);

      await service.syncOnce();

      final available = await repo.listAvailable();
      expect(available.where((e) => e.id == 'd2'), hasLength(1));
      expect(available.single.status, 'DEPRECATED');
    });

    test('lowercase "archived" (informal AC prose) is NOT treated as the'
        ' archived case -- only the exact uppercase wire literal is', () async {
      final repo = InMemoryDefinitionCacheRepository();
      final gateway = _SequencedGateway([
        _StatusBody(200, {
          'items': [
            _deltaItem(id: 'd3', name: 'Def Three', version: 1, status: 'archived'),
          ],
          'next_since': 1,
        }),
      ]);
      final service = DefinitionSyncService(repository: repo, client: gateway);

      await service.syncOnce();

      // Design §2: the server always sends uppercase; this asserts the
      // comparison is case-sensitive against that exact contract, not a
      // guess based on the acceptance criterion's informal prose.
      final available = await repo.listAvailable();
      expect(available.where((e) => e.id == 'd3'), hasLength(1));
    });
  });

  group('AC4: 400 resets cursor, exactly one full-history retry', () {
    test(
      'a 400 response resets the cursor and issues exactly one full-history'
      ' request (no since param), not a retry loop',
      () async {
        final repo = InMemoryDefinitionCacheRepository();
        await repo.writeCursor(10);
        final gateway = _SequencedGateway([
          _StatusBody(400, {'error': 'invalid since'}),
          _StatusBody(200, {
            'items': [
              _deltaItem(id: 'd4', name: 'Def Four', version: 1, status: 'ACTIVE'),
            ],
            'next_since': 5,
          }),
        ]);
        final service = DefinitionSyncService(repository: repo, client: gateway);

        await service.syncOnce();

        expect(gateway.callCount, 2, reason: 'exactly two calls, not a loop');
        expect(gateway.queryLog[0], {'since': '10'});
        expect(gateway.queryLog[1], isNull, reason: 'the resync omits since entirely');
        expect(await repo.readCursor(), 5);
        expect((await repo.listAvailable()).map((e) => e.id), contains('d4'));
      },
    );

    test(
      'a 400 followed by the resync itself also failing (thrown) still stops'
      ' at two calls total -- no third attempt',
      () async {
        final repo = InMemoryDefinitionCacheRepository();
        final gateway = _SequencedGateway([
          _StatusBody(400, {'error': 'invalid since'}),
          const _Throws(SocketException('no route to host')),
        ]);
        final service = DefinitionSyncService(repository: repo, client: gateway);

        await service.syncOnce();

        expect(gateway.callCount, 2);
        expect(await repo.readCursor(), isNull, reason: 'reset, never re-set');
      },
    );
  });

  group('airplane mode: no HTTP layer at all', () {
    test(
      'a SocketException on the only call leaves the cache untouched and'
      ' returns normally (never throws)',
      () async {
        final repo = InMemoryDefinitionCacheRepository();
        await repo.putAll([
          DefinitionCacheEntry.fromDeltaItem(
            _deltaItem(id: 'd5', name: 'Def Five', version: 1, status: 'ACTIVE'),
            type: kProcessDefinitionCacheType,
          ),
        ]);
        final gateway = _SequencedGateway([
          const _Throws(SocketException('no route to host')),
        ]);
        final service = DefinitionSyncService(repository: repo, client: gateway);

        await service.syncOnce();

        expect(gateway.callCount, 1);
        expect((await repo.listAvailable()).map((e) => e.id), contains('d5'));
      },
    );
  });
}
