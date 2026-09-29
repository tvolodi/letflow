// AC1 (no-Authorization-header half) and AC8 (single Dio(...) construction
// site). REQ-421 design §2.2/§7.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/auth/auth.dart';

import '../support/fake_app_auth_adapter.dart';
import '../support/fake_dio_http_client_adapter.dart';
import '../support/fake_http_gateway.dart' show tenantConfigJson;
import '../support/fake_secure_storage_platform.dart';

void main() {
  late FakeDioHttpClientAdapter fakeAdapter;
  late ApiClient client;
  late TenantTokenStore tokenStore;
  late ActiveRealmHolder activeRealm;
  late FakeAppAuthAdapter appAuthAdapter;
  late int loginRouteCallCount;

  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
    fakeAdapter = FakeDioHttpClientAdapter();
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = fakeAdapter;
    tokenStore = const TenantTokenStore(FlutterSecureStorage());
    activeRealm = ActiveRealmHolder();
    appAuthAdapter = FakeAppAuthAdapter();
    loginRouteCallCount = 0;
    // `ApiClient.forTesting` auto-attaches the same bearer-attach
    // interceptor `ApiClient.create` does (REQ-425 design §2.6), so this
    // test file no longer needs to re-apply its own copy.
    client = ApiClient.forTesting(
      dio,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: appAuthAdapter,
      routeToLogin: () => loginRouteCallCount += 1,
    );
  });

  test(
    'the tenant-config request (getUnauthenticated) carries no'
    ' Authorization header, even when a token exists for the active realm',
    () async {
      await tokenStore.store(
        'https://idp.example/realms/acme',
        TokenSet(
          accessToken: 'should-never-be-sent',
          refreshToken: null,
          idToken: null,
          accessTokenExpiration: null,
        ),
      );
      activeRealm.currentRealmUrl = 'https://idp.example/realms/acme';
      fakeAdapter.responses['/api/mobile/tenant-config'] = (
        200,
        tenantConfigJson(
          realmUrl: 'https://idp.example/realms/acme',
          clientId: 'acme-client',
        ),
      );

      await fetchTenantConfig('acme', client: client);

      expect(fakeAdapter.requests, hasLength(1));
      expect(
        fakeAdapter.requests.single.headers.containsKey('Authorization'),
        isFalse,
      );
    },
  );

  test('an authenticated get() DOES attach the bearer token for the active'
      ' realm', () async {
    await tokenStore.store(
      'https://idp.example/realms/acme',
      TokenSet(
        accessToken: 'the-access-token',
        refreshToken: null,
        idToken: null,
        accessTokenExpiration: null,
      ),
    );
    activeRealm.currentRealmUrl = 'https://idp.example/realms/acme';
    fakeAdapter.responses['/api/v1/me/modules'] = (
      200,
      {'installed_modules': []},
    );

    await client.get('/api/v1/me/modules');

    expect(
      fakeAdapter.requests.single.headers['Authorization'],
      'Bearer the-access-token',
    );
  });

  test('a GET issued with no active realm carries no Authorization header'
      ' (not a thrown error)', () async {
    fakeAdapter.responses['/api/v1/me/modules'] = (
      200,
      {'installed_modules': []},
    );

    await client.get('/api/v1/me/modules');

    expect(
      fakeAdapter.requests.single.headers.containsKey('Authorization'),
      isFalse,
    );
  });

  test('exactly one Dio(...) construction site in apps/mobile/lib, in'
      ' lib/api/api_client.dart', () async {
    // `--untracked` so this assertion holds identically whether or not
    // these exact files have been committed yet (git grep otherwise only
    // searches tracked content).
    final result = await Process.run('git', [
      'grep',
      '-n',
      '--untracked',
      'Dio(',
      '--',
      'lib',
    ]);
    expect(
      result.exitCode,
      0,
      reason:
          'git grep found no hits at all — expected exactly one:\n'
          '${result.stdout}\n${result.stderr}',
    );
    final lines = (result.stdout as String)
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    expect(
      lines,
      hasLength(1),
      reason: 'expected exactly one `Dio(` hit, found:\n${lines.join('\n')}',
    );
    expect(lines.single, contains('lib/api/api_client.dart'));
  });
}
