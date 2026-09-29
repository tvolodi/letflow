// REQ-424 (MOB-3 part 2) AC1-AC4: PinnedFormResolver.resolve's five-step
// contract (design §5.1) -- exact-key cache hit, cache-miss fetch, offline
// fetch failure, and the null-form_version short-circuit. Every test here
// uses InMemoryPinnedFormCacheRepository (design §4.1's "what every test in
// this requirement's own acceptance criteria uses").
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/definitions/pinned_form_cache.dart';
import 'package:letflow/definitions/pinned_form_resolver.dart';

/// A minimal [HttpGateway] fake recording every `get` call's path, and
/// either replaying a canned [Response] or throwing [errorToThrow].
/// [getUnauthenticated] is never used by [PinnedFormResolver].
class _FakeGateway implements HttpGateway {
  _FakeGateway({this.response, this.errorToThrow});

  Response<dynamic>? response;
  Object? errorToThrow;
  final List<String> calls = [];

  @override
  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    calls.add(path);
    if (errorToThrow != null) {
      throw errorToThrow!;
    }
    return response!;
  }

  @override
  Future<Response<dynamic>> getUnauthenticated(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) => throw UnimplementedError('not used by PinnedFormResolver');
}

Response<dynamic> _taskDetailResponse({
  required int status,
  Map<String, dynamic>? formSchema,
  bool includeFormSchemaKey = true,
}) {
  final body = <String, dynamic>{
    'id': 'task-1',
    'form_id': 'F',
    'form_version': '1',
    if (includeFormSchemaKey) 'form_schema': formSchema,
  };
  return Response<dynamic>(
    requestOptions: RequestOptions(path: '/api/v1/tasks/task-1'),
    statusCode: status,
    data: body,
  );
}

void main() {
  group('AC1: exact-key cache hit -- zero network calls', () {
    test(
      'F cached at versions 1 and 2, task pinned to version 1 -- resolver'
      ' returns version 1\'s schema, never touches the network',
      () async {
        final repo = InMemoryPinnedFormCacheRepository();
        await repo.putEntry(
          const PinnedFormCacheEntry(
            formId: 'F',
            formVersion: '1',
            formSchema: {'title': 'v1 schema'},
          ),
        );
        await repo.putEntry(
          const PinnedFormCacheEntry(
            formId: 'F',
            formVersion: '2',
            formSchema: {'title': 'v2 schema'},
          ),
        );
        final gateway = _FakeGateway();
        final resolver = PinnedFormResolver(repository: repo, client: gateway);

        final result = await resolver.resolve(
          taskId: 'task-1',
          formId: 'F',
          formVersion: '1',
        );

        expect(result, isA<PinnedFormResolved>());
        expect(
          (result as PinnedFormResolved).formSchema,
          {'title': 'v1 schema'},
        );
        expect(gateway.calls, isEmpty, reason: 'cache hit makes zero network calls');
      },
    );
  });

  group('AC2: cache miss -- exactly one fetch, never version 2\'s schema', () {
    test(
      'version 2 cached, task pinned to version 1 -- resolver fetches'
      ' GET /api/v1/tasks/:id and returns the fetched schema, never'
      ' version 2\'s',
      () async {
        final repo = InMemoryPinnedFormCacheRepository();
        await repo.putEntry(
          const PinnedFormCacheEntry(
            formId: 'F',
            formVersion: '2',
            formSchema: {'title': 'v2 schema'},
          ),
        );
        final gateway = _FakeGateway(
          response: _taskDetailResponse(
            status: 200,
            formSchema: {'title': 'v1 fetched schema'},
          ),
        );
        final resolver = PinnedFormResolver(repository: repo, client: gateway);

        final result = await resolver.resolve(
          taskId: 'task-1',
          formId: 'F',
          formVersion: '1',
        );

        expect(gateway.calls, ['/api/v1/tasks/task-1']);
        expect(result, isA<PinnedFormResolved>());
        expect(
          (result as PinnedFormResolved).formSchema,
          {'title': 'v1 fetched schema'},
        );

        // The fetched schema is now cached under the (formId, '1') key --
        // and version 2's own row is untouched.
        final cached1 = await repo.getByKey('F', '1');
        expect(cached1?.formSchema, {'title': 'v1 fetched schema'});
        final cached2 = await repo.getByKey('F', '2');
        expect(cached2?.formSchema, {'title': 'v2 schema'});
      },
    );

    test(
      'a successful fetch whose "form_schema" is null caches null as a'
      ' legitimate, resolved value -- not a miss',
      () async {
        final repo = InMemoryPinnedFormCacheRepository();
        final gateway = _FakeGateway(
          response: _taskDetailResponse(status: 200, formSchema: null),
        );
        final resolver = PinnedFormResolver(repository: repo, client: gateway);

        final result = await resolver.resolve(
          taskId: 'task-1',
          formId: 'F',
          formVersion: '1',
        );

        expect(result, isA<PinnedFormResolved>());
        expect((result as PinnedFormResolved).formSchema, isNull);
        final cached = await repo.getByKey('F', '1');
        expect(cached, isNotNull);
        expect(cached!.formSchema, isNull);
      },
    );
  });

  group('AC3: offline on a miss -- pinned-version-unavailable, version 2'
      ' untouched', () {
    test(
      'version 2 cached, task pinned to version 1, network unavailable --'
      ' result is pinned-version-unavailable, version 2\'s schema is not'
      ' returned, and nothing new is cached',
      () async {
        final repo = InMemoryPinnedFormCacheRepository();
        await repo.putEntry(
          const PinnedFormCacheEntry(
            formId: 'F',
            formVersion: '2',
            formSchema: {'title': 'v2 schema'},
          ),
        );
        final gateway = _FakeGateway(errorToThrow: Exception('no route to host'));
        final resolver = PinnedFormResolver(repository: repo, client: gateway);

        final result = await resolver.resolve(
          taskId: 'task-1',
          formId: 'F',
          formVersion: '1',
        );

        expect(result, isA<PinnedFormUnavailable>());
        expect(
          (result as PinnedFormUnavailable).reason,
          PinnedFormUnavailableReason.fetchFailed,
        );
        expect(gateway.calls, ['/api/v1/tasks/task-1']);
        expect(await repo.getByKey('F', '1'), isNull, reason: 'nothing cached');
        final cached2 = await repo.getByKey('F', '2');
        expect(cached2?.formSchema, {'title': 'v2 schema'});
      },
    );

    test('a non-200 response (e.g. 404) is also pinned-version-unavailable,'
        ' nothing cached', () async {
      final repo = InMemoryPinnedFormCacheRepository();
      final gateway = _FakeGateway(response: _taskDetailResponse(status: 404));
      final resolver = PinnedFormResolver(repository: repo, client: gateway);

      final result = await resolver.resolve(
        taskId: 'task-1',
        formId: 'F',
        formVersion: '1',
      );

      expect(result, isA<PinnedFormUnavailable>());
      expect(
        (result as PinnedFormUnavailable).reason,
        PinnedFormUnavailableReason.fetchFailed,
      );
      expect(await repo.getByKey('F', '1'), isNull);
    });
  });

  group('AC4: form_version null -- pinned-version-unavailable, no I/O', () {
    test(
      'a task with form_version null yields pinned-version-unavailable'
      ' (versionMissing), with zero cache reads and zero network calls',
      () async {
        final repo = InMemoryPinnedFormCacheRepository();
        final gateway = _FakeGateway();
        final resolver = PinnedFormResolver(repository: repo, client: gateway);

        final result = await resolver.resolve(
          taskId: 'task-1',
          formId: 'F',
          formVersion: null,
        );

        expect(result, isA<PinnedFormUnavailable>());
        expect(
          (result as PinnedFormUnavailable).reason,
          PinnedFormUnavailableReason.versionMissing,
        );
        expect(gateway.calls, isEmpty);
      },
    );
  });
}
