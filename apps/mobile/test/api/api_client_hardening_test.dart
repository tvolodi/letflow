// REQ-425 (MOB-6) acceptance criteria 1-5: 401 refresh-then-retry with
// concurrent-401 coalescing, refresh-failure token clearing + login routing,
// GET-only 5xx exponential backoff (POST never auto-retried), the
// classifyError -> ApiError mapping (including the module-404 vs.
// plain-404 distinction and Retry-After parsing), and "no raw
// DioException/SocketException escapes lib/api/".
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api.dart';
import 'package:letflow/auth/auth.dart';

import '../support/fake_app_auth_adapter.dart';
import '../support/fake_dio_http_client_adapter.dart';
import '../support/fake_secure_storage_platform.dart';

const _realmUrl = 'https://idp.example/realms/acme';
const _otherRealmUrl = 'https://idp.example/realms/other-tenant';

class _Harness {
  _Harness({
    required this.client,
    required this.fakeAdapter,
    required this.tokenStore,
    required this.activeRealm,
    required this.appAuthAdapter,
    required this.delays,
    required this.loginRouteCallCountGetter,
  });

  final ApiClient client;
  final FakeDioHttpClientAdapter fakeAdapter;
  final TenantTokenStore tokenStore;
  final ActiveRealmHolder activeRealm;
  final FakeAppAuthAdapter appAuthAdapter;
  final List<Duration> delays;
  final int Function() loginRouteCallCountGetter;
}

/// Builds a fresh [ApiClient] wired exactly the way REQ-425 design §2.6
/// specifies: a real [TenantTokenStore] backed by a fresh
/// [FakeSecureStoragePlatform], a real [ActiveRealmHolder], and a
/// [FakeAppAuthAdapter] whose `refresh` call count AC1 inspects directly.
/// Pre-seeds a token set with a refresh token for [_realmUrl] unless
/// [seedTokens] is false.
Future<_Harness> _buildHarness({bool seedTokens = true}) async {
  FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
  final fakeAdapter = FakeDioHttpClientAdapter();
  final dio = Dio(BaseOptions(validateStatus: (_) => true))
    ..httpClientAdapter = fakeAdapter;
  final tokenStore = const TenantTokenStore(FlutterSecureStorage());
  final activeRealm = ActiveRealmHolder()
    ..currentRealmUrl = _realmUrl
    ..clientId = 'acme-client';
  final appAuthAdapter = FakeAppAuthAdapter();
  var loginRouteCallCount = 0;
  final delays = <Duration>[];

  if (seedTokens) {
    await tokenStore.store(
      _realmUrl,
      const TokenSet(
        accessToken: 'initial-access-token',
        refreshToken: 'initial-refresh-token',
        idToken: null,
        accessTokenExpiration: null,
      ),
    );
  }

  final client = ApiClient.forTesting(
    dio,
    tokenStore: tokenStore,
    activeRealm: activeRealm,
    appAuthAdapter: appAuthAdapter,
    routeToLogin: () => loginRouteCallCount += 1,
    delayFn: (d) async {
      delays.add(d);
    },
  );

  return _Harness(
    client: client,
    fakeAdapter: fakeAdapter,
    tokenStore: tokenStore,
    activeRealm: activeRealm,
    appAuthAdapter: appAuthAdapter,
    delays: delays,
    loginRouteCallCountGetter: () => loginRouteCallCount,
  );
}

void main() {
  group('401 refresh-then-retry (AC1)', () {
    test(
      'a 401 then 200 triggers exactly one refresh and exactly one retry',
      () async {
        final h = await _buildHarness();
        var calls = 0;
        h.fakeAdapter.handler = (options) {
          calls += 1;
          return calls == 1 ? (401, {'error': 'expired'}) : (200, {'ok': true});
        };

        final response = await h.client.get('/api/v1/me/modules');

        expect(response.statusCode, 200);
        expect(h.appAuthAdapter.refreshCallCount, 1);
        expect(h.fakeAdapter.requests, hasLength(2));
        // The retry re-reads the refreshed token via the bearer interceptor.
        expect(
          h.fakeAdapter.requests.last.headers['Authorization'],
          'Bearer refreshed-access-token',
        );
      },
    );

    test(
      'two concurrent 401s trigger exactly one refresh total, each request'
      ' still retried once',
      () async {
        final h = await _buildHarness();
        final callsPerPath = <String, int>{};
        h.fakeAdapter.handler = (options) {
          final n = (callsPerPath[options.path] ?? 0) + 1;
          callsPerPath[options.path] = n;
          return n == 1 ? (401, {'error': 'expired'}) : (200, {'ok': true});
        };

        final results = await Future.wait([
          h.client.get('/a'),
          h.client.get('/b'),
        ]);

        expect(results[0].statusCode, 200);
        expect(results[1].statusCode, 200);
        expect(h.appAuthAdapter.refreshCallCount, 1);
        // Each path: one 401 + one retry = 2 requests; two paths = 4 total.
        expect(h.fakeAdapter.requests, hasLength(4));
      },
    );

    test(
      'a second 401 on the retried request itself is terminal: no second'
      ' refresh, no token deletion, no login routing',
      () async {
        final h = await _buildHarness();
        h.fakeAdapter.handler = (options) => (401, {'error': 'still expired'});

        await expectLater(
          h.client.get('/api/v1/me/modules'),
          throwsA(isA<UnauthorizedError>()),
        );

        expect(h.appAuthAdapter.refreshCallCount, 1);
        expect(h.fakeAdapter.requests, hasLength(2));
        expect(await h.tokenStore.read(_realmUrl), isNotNull);
        expect(h.loginRouteCallCountGetter(), 0);
      },
    );

    test(
      'an unauthenticated call (getUnauthenticated) receiving 401 skips the'
      ' refresh flow entirely',
      () async {
        final h = await _buildHarness(seedTokens: false);
        h.fakeAdapter.handler = (options) => (401, {'error': 'nope'});

        await expectLater(
          h.client.getUnauthenticated('/api/mobile/tenant-config'),
          throwsA(isA<UnauthorizedError>()),
        );

        expect(h.appAuthAdapter.refreshCallCount, 0);
        expect(h.fakeAdapter.requests, hasLength(1));
      },
    );
  });

  group('refresh failure (AC2)', () {
    test(
      'refresh failure deletes the tenant\'s tokens from the secure store'
      ' and routes to login',
      () async {
        final h = await _buildHarness();
        h.appAuthAdapter.refreshError = Exception('invalid_grant');
        h.fakeAdapter.handler = (options) => (401, {'error': 'expired'});

        await expectLater(
          h.client.get('/api/v1/me/modules'),
          throwsA(isA<UnauthorizedError>()),
        );

        expect(await h.tokenStore.read(_realmUrl), isNull);
        expect(h.loginRouteCallCountGetter(), 1);
        expect(h.activeRealm.currentRealmUrl, isNull);
        // Only the original request was sent -- no retry after a failed
        // refresh.
        expect(h.fakeAdapter.requests, hasLength(1));
      },
    );

    test(
      'refresh failure when no refresh token is stored also clears tokens'
      ' and routes to login, without ever calling the adapter',
      () async {
        final h = await _buildHarness(seedTokens: false);
        await h.tokenStore.store(
          _realmUrl,
          const TokenSet(
            accessToken: 'access-only',
            refreshToken: null,
            idToken: null,
            accessTokenExpiration: null,
          ),
        );
        h.fakeAdapter.handler = (options) => (401, {'error': 'expired'});

        await expectLater(
          h.client.get('/api/v1/me/modules'),
          throwsA(isA<UnauthorizedError>()),
        );

        expect(h.appAuthAdapter.refreshCallCount, 0);
        expect(await h.tokenStore.read(_realmUrl), isNull);
        expect(h.loginRouteCallCountGetter(), 1);
      },
    );
  });

  group(
    'cross-tenant refresh race (rework 1 -- SECURITY-REVIEWER BLOCKER)',
    () {
      test(
        'a tenant switch racing an in-flight 401 refresh aborts the retry'
        ' instead of resurrecting the old tenant\'s tokens or serving the'
        ' retry as the new tenant',
        () async {
          final h = await _buildHarness();
          h.fakeAdapter.handler = (options) => (401, {'error': 'expired'});
          h.appAuthAdapter.duringRefresh = () {
            // Simulates `switchTenant` flipping the active tenant while the
            // refresh's network call ("await Future.delayed" in the fake) is
            // still suspended -- exactly the race SECURITY-REVIEWER flagged.
            h.activeRealm.currentRealmUrl = _otherRealmUrl;
            h.activeRealm.clientId = 'other-tenant-client';
          };

          await expectLater(
            h.client.get('/api/v1/me/modules'),
            throwsA(isA<UnauthorizedError>()),
          );

          // The refresh's own (soon-to-be-discarded) result must never be
          // written back under the OLD tenant's key -- its tokens are
          // exactly what were seeded, untouched.
          final oldTenantTokens = await h.tokenStore.read(_realmUrl);
          expect(oldTenantTokens?.accessToken, 'initial-access-token');
          expect(oldTenantTokens?.refreshToken, 'initial-refresh-token');
          // Nor does the new tenant acquire any tokens as a side effect of
          // the old tenant's refresh.
          expect(await h.tokenStore.read(_otherRealmUrl), isNull);
          // Exactly one refresh call, and the retry is never sent -- the
          // original request must not be silently re-authenticated and
          // re-served under the new tenant's identity.
          expect(h.appAuthAdapter.refreshCallCount, 1);
          expect(h.fakeAdapter.requests, hasLength(1));
          // Aborting mid-race is not the same as a genuine refresh failure --
          // it must not additionally clear the new tenant's session or route
          // to login (whatever triggered the switch owns that decision).
          expect(h.loginRouteCallCountGetter(), 0);
        },
      );

      test(
        'a logout racing an in-flight 401 refresh does not resurrect the'
        ' just-deleted tenant\'s tokens',
        () async {
          final h = await _buildHarness();
          h.fakeAdapter.handler = (options) => (401, {'error': 'expired'});
          h.appAuthAdapter.duringRefresh = () {
            // Simulates `logout` clearing the active tenant and deleting its
            // tokens while the refresh's network call is still suspended.
            h.activeRealm.currentRealmUrl = null;
            h.activeRealm.clientId = null;
            unawaited(h.tokenStore.delete(_realmUrl));
          };

          await expectLater(
            h.client.get('/api/v1/me/modules'),
            throwsA(isA<UnauthorizedError>()),
          );

          // Still deleted -- the in-flight refresh must not write the
          // logged-out tenant's tokens back into secure storage.
          expect(await h.tokenStore.read(_realmUrl), isNull);
          expect(h.appAuthAdapter.refreshCallCount, 1);
          expect(h.fakeAdapter.requests, hasLength(1));
        },
      );
    },
  );

  group(
    'cross-tenant retry-dispatch race (rework 2 -- SECURITY-REVIEWER'
    ' BLOCKER, post-refresh-success window)',
    () {
      test(
        'a tenant switch landing after refreshOnce() succeeds but before the'
        " retry's own bearer-interceptor pass runs aborts the retry -- it is"
        " never dispatched at all, let alone carrying the new tenant's token",
        () async {
          FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
          final fakeAdapter = FakeDioHttpClientAdapter();
          final dio = Dio(BaseOptions(validateStatus: (_) => true))
            ..httpClientAdapter = fakeAdapter;
          final tokenStore = const TenantTokenStore(FlutterSecureStorage());
          final activeRealm = ActiveRealmHolder()
            ..currentRealmUrl = _realmUrl
            ..clientId = 'acme-client';
          final appAuthAdapter = FakeAppAuthAdapter();
          var loginRouteCallCount = 0;

          await tokenStore.store(
            _realmUrl,
            const TokenSet(
              accessToken: 'initial-access-token',
              refreshToken: 'initial-refresh-token',
              idToken: null,
              accessTokenExpiration: null,
            ),
          );

          // Registered BEFORE `ApiClient.forTesting` adds its own
          // bearer-attach interceptor below -- Dio runs `onRequest`
          // interceptors in registration order, so this one always sees a
          // request FIRST, for every pass through the chain including the
          // retry's. It flips the active tenant the SECOND time it sees a
          // given path -- i.e. on the retry, never on the original,
          // 401'd request -- which lands the switch exactly in the window
          // this regression targets: strictly after
          // `_handleUnauthorized`'s own pre-fetch realm check has already
          // passed (that check runs synchronously, with
          // `_dio.fetch(retriedOptions)` called immediately after it, no
          // `await` in between) but strictly before the bearer interceptor
          // -- registered after this one, so it runs later in the same
          // chain pass -- does its own fresh read of
          // `activeRealm.currentRealmUrl`. This is deliberately NOT
          // `appAuthAdapter.duringRefresh`: that hook only fires while
          // `_doRefresh`'s own network `await` is still suspended, which is
          // the earlier window rework 1 already closed (and which the
          // existing "cross-tenant refresh race" group above already
          // covers) -- this test's window opens only once `refreshOnce()`
          // has already resolved successfully.
          final seenCount = <String, int>{};
          dio.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                final count = (seenCount[options.path] ?? 0) + 1;
                seenCount[options.path] = count;
                if (count == 2) {
                  activeRealm.currentRealmUrl = _otherRealmUrl;
                  activeRealm.clientId = 'other-tenant-client';
                }
                handler.next(options);
              },
            ),
          );

          final client = ApiClient.forTesting(
            dio,
            tokenStore: tokenStore,
            activeRealm: activeRealm,
            appAuthAdapter: appAuthAdapter,
            routeToLogin: () => loginRouteCallCount += 1,
          );

          fakeAdapter.handler = (options) => (401, {'error': 'expired'});

          await expectLater(
            client.get('/api/v1/me/modules'),
            throwsA(isA<UnauthorizedError>()),
          );

          // The refresh itself succeeded (unlike the rework-1 tests above) --
          // this race is entirely at retry-dispatch time, one step later.
          expect(appAuthAdapter.refreshCallCount, 1);
          // The retry is intercepted and rejected by the bearer
          // interceptor's own re-check BEFORE it ever reaches the transport
          // layer -- only the original (401'd) request ever reaches the
          // fake adapter.
          expect(fakeAdapter.requests, hasLength(1));
          // The new tenant acquires no tokens as a side effect of the old
          // tenant's refresh/retry.
          expect(await tokenStore.read(_otherRealmUrl), isNull);
          // Aborting a stale retry is not a fresh auth failure for the NEW
          // tenant -- it must not clear the new tenant's session or
          // re-route it to login (whatever triggered the switch owns that).
          expect(loginRouteCallCount, 0);
        },
      );
    },
  );

  group('5xx backoff for GET only (AC3)', () {
    test(
      'a GET receiving 503 twice then 200 succeeds, with increasing delays'
      ' between attempts',
      () async {
        final h = await _buildHarness();
        var calls = 0;
        h.fakeAdapter.handler = (options) {
          calls += 1;
          return calls <= 2 ? (503, {'error': 'unavailable'}) : (200, {'ok': true});
        };

        final response = await h.client.get('/api/v1/me/modules');

        expect(response.statusCode, 200);
        expect(h.fakeAdapter.requests, hasLength(3));
        expect(h.delays, [
          const Duration(milliseconds: 200),
          const Duration(milliseconds: 400),
        ]);
      },
    );

    test(
      'a GET receiving 503 on every attempt stops after'
      ' kMaxServerRetryAttempts requests and surfaces ServerError',
      () async {
        final h = await _buildHarness();
        h.fakeAdapter.handler = (options) => (503, {'error': 'unavailable'});

        await expectLater(
          h.client.get('/api/v1/me/modules'),
          throwsA(
            isA<ServerError>().having(
              (e) => e.lastStatusCode,
              'lastStatusCode',
              503,
            ),
          ),
        );

        expect(h.fakeAdapter.requests, hasLength(kMaxServerRetryAttempts));
        expect(kMaxServerRetryAttempts, 3);
      },
    );

    test('a POST receiving 503 is not retried', () async {
      final h = await _buildHarness();
      h.fakeAdapter.handler = (options) => (503, {'error': 'unavailable'});

      await expectLater(
        h.client.post('/api/v1/tasks/1/complete', data: {'x': 1}),
        throwsA(isA<ServerError>()),
      );

      expect(h.fakeAdapter.requests, hasLength(1));
      expect(h.delays, isEmpty);
    });
  });

  group('ApiError variant mapping (AC4)', () {
    test('a 404 on /api/v1/modules/exam/x maps to ModuleNotAvailableError'
        ' with moduleId "exam"', () async {
      final h = await _buildHarness();
      h.fakeAdapter.handler = (options) => (404, {'error': 'not found'});

      await expectLater(
        h.client.get('/api/v1/modules/exam/x'),
        throwsA(
          isA<ModuleNotAvailableError>().having(
            (e) => e.moduleId,
            'moduleId',
            'exam',
          ),
        ),
      );
    });

    test('a 404 elsewhere (e.g. /api/v1/me/modules) maps to NotFoundError',
        () async {
      final h = await _buildHarness();
      h.fakeAdapter.handler = (options) => (404, {'error': 'not found'});

      await expectLater(
        h.client.get('/api/v1/me/modules'),
        throwsA(isA<NotFoundError>()),
      );
    });

    test('a 429 with Retry-After: 7 maps to BackpressureError(7)', () async {
      final h = await _buildHarness();
      h.fakeAdapter.handler = (options) => (429, {'error': 'slow down'});
      h.fakeAdapter.headersFor = (options) => {
        'retry-after': ['7'],
      };

      await expectLater(
        h.client.get('/api/v1/me/modules'),
        throwsA(
          isA<BackpressureError>().having(
            (e) => e.retryAfterSeconds,
            'retryAfterSeconds',
            7,
          ),
        ),
      );
    });

    test(
      'a 429 with a missing/malformed Retry-After defaults to 1 second',
      () async {
        final h = await _buildHarness();
        h.fakeAdapter.handler = (options) => (429, {'error': 'slow down'});

        await expectLater(
          h.client.get('/api/v1/me/modules'),
          throwsA(
            isA<BackpressureError>().having(
              (e) => e.retryAfterSeconds,
              'retryAfterSeconds',
              1,
            ),
          ),
        );
      },
    );

    test('a 422 maps to ValidationError with parsed RFC 9457 field errors',
        () async {
      final h = await _buildHarness();
      h.fakeAdapter.handler = (options) => (
        422,
        {
          'errors': [
            {
              'field': 'due_date',
              'constraint': 'future_date',
              'message': 'must be in the future',
              'received': '2020-01-01',
            },
          ],
        },
      );

      await expectLater(
        h.client.post('/api/v1/tasks', data: {}),
        throwsA(
          isA<ValidationError>().having(
            (e) => e.fieldErrors.single.field,
            'fieldErrors.single.field',
            'due_date',
          ),
        ),
      );
    });

    test('a 422 with a malformed body still maps to ValidationError, with an'
        ' empty field-errors list', () async {
      final h = await _buildHarness();
      h.fakeAdapter.handler = (options) => (422, {'unexpected': 'shape'});

      await expectLater(
        h.client.post('/api/v1/tasks', data: {}),
        throwsA(
          isA<ValidationError>().having(
            (e) => e.fieldErrors,
            'fieldErrors',
            isEmpty,
          ),
        ),
      );
    });

    test('a 403 maps to ForbiddenError', () async {
      final h = await _buildHarness();
      h.fakeAdapter.handler = (options) => (403, {'error': 'forbidden'});

      await expectLater(
        h.client.get('/api/v1/me/modules'),
        throwsA(isA<ForbiddenError>()),
      );
    });

    test('a 409 maps to ConflictError', () async {
      final h = await _buildHarness();
      h.fakeAdapter.handler = (options) => (409, {'error': 'conflict'});

      await expectLater(
        h.client.post('/api/v1/tasks', data: {}),
        throwsA(isA<ConflictError>()),
      );
    });

    test('a bare 400 (unmapped 4xx) folds into ServerError as the catch-all'
        ' (design §1.2 OQ-1)', () async {
      final h = await _buildHarness();
      h.fakeAdapter.handler = (options) => (400, {'error': 'bad request'});

      await expectLater(
        h.client.post('/api/v1/tasks', data: {}),
        throwsA(
          isA<ServerError>().having(
            (e) => e.lastStatusCode,
            'lastStatusCode',
            400,
          ),
        ),
      );
    });

    test('classifyError direct unit coverage of every status branch', () {
      final ro = RequestOptions(path: '/api/v1/me/modules');
      expect(
        classifyError(ro, statusCode: null, transportException: 'boom'),
        isA<NetworkUnavailableError>(),
      );
      expect(classifyError(ro, statusCode: 401), isA<UnauthorizedError>());
      expect(classifyError(ro, statusCode: 403), isA<ForbiddenError>());
      expect(classifyError(ro, statusCode: 409), isA<ConflictError>());
      expect(
        classifyError(ro, statusCode: 500),
        isA<ServerError>().having((e) => e.lastStatusCode, 'code', 500),
      );
      final moduleRo = RequestOptions(path: '/api/v1/modules/exam/instances');
      expect(
        classifyError(moduleRo, statusCode: 404),
        isA<ModuleNotAvailableError>().having(
          (e) => e.moduleId,
          'moduleId',
          'exam',
        ),
      );
      // No trailing segment after the id: does NOT count as module-scoped
      // (design §1.3's exact rule).
      final bareModuleRo = RequestOptions(path: '/api/v1/modules/exam');
      expect(classifyError(bareModuleRo, statusCode: 404), isA<NotFoundError>());
    });
  });

  group('no raw transport exception escapes lib/api/ (AC5)', () {
    test('a connection-error DioException maps to NetworkUnavailableError,'
        ' never a raw DioException/SocketException', () async {
      final h = await _buildHarness();
      h.fakeAdapter.handler = (_) => throw DioException(
        requestOptions: RequestOptions(path: '/api/v1/me/modules'),
        type: DioExceptionType.connectionError,
        error: const SocketException('Failed host lookup'),
      );

      try {
        await h.client.get('/api/v1/me/modules');
        fail('expected an ApiError to be thrown');
      } catch (e) {
        expect(e, isA<NetworkUnavailableError>());
        expect(e, isNot(isA<DioException>()));
      }
    });

    test('every ApiError variant is a subtype of ApiError and Exception,'
        ' never a DioException', () {
      const variants = <ApiError>[
        NetworkUnavailableError(),
        UnauthorizedError(),
        ForbiddenError(),
        NotFoundError(),
        ModuleNotAvailableError(moduleId: 'exam'),
        BackpressureError(retryAfterSeconds: 1),
        ValidationError(fieldErrors: []),
        ConflictError(),
        ServerError(),
      ];
      for (final variant in variants) {
        expect(variant, isA<Exception>());
        expect(variant, isNot(isA<DioException>()));
      }
    });
  });
}
