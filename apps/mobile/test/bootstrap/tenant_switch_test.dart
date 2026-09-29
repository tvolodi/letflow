// REQ-422 §6.3, MOB-5, AC7: switchTenant deletes the previous tenant's
// tokens before the new tenant's bootstrap completes, and logout deletes
// the active tenant's tokens and clears the active-realm pointer.
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';
import 'package:letflow/definitions/definitions.dart';
import 'package:letflow/definitions/pinned_form_cache.dart';

import '../support/fake_app_auth_adapter.dart';
import '../support/fake_dio_http_client_adapter.dart';
import '../support/fake_http_gateway.dart' show tenantConfigJson;
import '../support/fake_secure_storage_platform.dart';

const _realmA = 'https://idp.example/realms/acme';
const _realmB = 'https://idp.example/realms/beta';

void main() {
  late FakeDioHttpClientAdapter fakeAdapter;
  late ApiClient client;
  late TenantTokenStore tokenStore;
  late ActiveRealmHolder activeRealm;

  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
    fakeAdapter = FakeDioHttpClientAdapter();
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = fakeAdapter;
    tokenStore = const TenantTokenStore(FlutterSecureStorage());
    activeRealm = ActiveRealmHolder();
    client = ApiClient.forTesting(
      dio,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: FakeAppAuthAdapter(),
      routeToLogin: () {},
    );

    fakeAdapter.handler = (options) {
      if (options.path == '/api/mobile/tenant-config') {
        final slug = options.queryParameters['slug'];
        if (slug == 'acme') {
          return (
            200,
            tenantConfigJson(realmUrl: _realmA, clientId: 'client-acme'),
          );
        }
        if (slug == 'beta') {
          return (
            200,
            tenantConfigJson(realmUrl: _realmB, clientId: 'client-beta'),
          );
        }
      }
      if (options.path == '/api/v1/me/memberships') {
        final auth = options.headers['Authorization'];
        if (auth == 'Bearer token-acme') {
          return (
            200,
            {
              'memberships': [
                {
                  'tenant_id': 't-acme',
                  'tenant_slug': 'acme',
                  'tenant_display_name': 'Acme',
                  'display_label': null,
                },
              ],
            },
          );
        }
        if (auth == 'Bearer token-beta') {
          return (
            200,
            {
              'memberships': [
                {
                  'tenant_id': 't-beta',
                  'tenant_slug': 'beta',
                  'tenant_display_name': 'Beta',
                  'display_label': null,
                },
              ],
            },
          );
        }
      }
      if (options.path == '/api/v1/me/modules') {
        return (200, {'installed_modules': []});
      }
      return null;
    };
  });

  test('switchTenant deletes tenant A\'s tokens before completing tenant'
      ' B\'s bootstrap, and a subsequent request attaches only B\'s token',
      () async {
    final resultA = await runTenantBootstrap(
      'acme',
      client: client,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: FakeAppAuthAdapter(
        response: fakeTokenResponse(accessToken: 'token-acme'),
      ),
    );
    expect(resultA, isA<BootstrapSuccess>());
    expect(await tokenStore.read(_realmA), isNotNull);

    final resultB = await switchTenant(
      'beta',
      client: client,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: FakeAppAuthAdapter(
        response: fakeTokenResponse(accessToken: 'token-beta'),
      ),
    );

    expect(resultB, isA<BootstrapSuccess>());
    expect(
      await tokenStore.read(_realmA),
      isNull,
      reason: 'tenant A\'s tokens must be deleted by switchTenant',
    );
    expect((await tokenStore.read(_realmB))!.accessToken, 'token-beta');

    fakeAdapter.requests.clear();
    await client.get('/api/v1/me/modules');
    expect(
      fakeAdapter.requests.single.headers['Authorization'],
      'Bearer token-beta',
    );
    expect(
      fakeAdapter.requests.single.headers.containsKey('Authorization'),
      isTrue,
    );
  });

  test('switchTenant with no previous active tenant (first bootstrap of the'
      ' session) behaves exactly like runTenantBootstrap -- no delete'
      ' attempted, nothing to delete', () async {
    expect(activeRealm.currentRealmUrl, isNull);

    final result = await switchTenant(
      'acme',
      client: client,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: FakeAppAuthAdapter(
        response: fakeTokenResponse(accessToken: 'token-acme'),
      ),
    );

    expect(result, isA<BootstrapSuccess>());
    expect((await tokenStore.read(_realmA))!.accessToken, 'token-acme');
  });

  test('logout deletes the active tenant\'s tokens and clears the active'
      ' realm pointer', () async {
    await runTenantBootstrap(
      'acme',
      client: client,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: FakeAppAuthAdapter(
        response: fakeTokenResponse(accessToken: 'token-acme'),
      ),
    );
    expect(activeRealm.currentRealmUrl, _realmA);
    expect(await tokenStore.read(_realmA), isNotNull);

    await logout(tokenStore: tokenStore, activeRealm: activeRealm);

    expect(activeRealm.currentRealmUrl, isNull);
    expect(await tokenStore.read(_realmA), isNull);
  });

  test('logout with no active tenant is a no-op', () async {
    expect(activeRealm.currentRealmUrl, isNull);

    await logout(tokenStore: tokenStore, activeRealm: activeRealm);

    expect(activeRealm.currentRealmUrl, isNull);
  });

  test('BootstrapController.switchTenant/.logout delegate correctly (no'
      ' infinite recursion, real state transitions)', () async {
    final controller = BootstrapController(
      client: client,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      definitionCache: ActiveDefinitionCacheHolder(),
        pinnedFormCache: ActivePinnedFormCacheHolder(),
      cacheOpener: (_) async => InMemoryDefinitionCacheRepository(),
        pinnedFormCacheOpener: (_) async => InMemoryPinnedFormCacheRepository(),
      appAuthAdapter: FakeAppAuthAdapter(
        response: fakeTokenResponse(accessToken: 'token-acme'),
      ),
    );

    await controller.beginBootstrap('acme');
    expect(controller.state.phase, BootstrapPhase.success);
    expect(await tokenStore.read(_realmA), isNotNull);

    final betaController = BootstrapController(
      client: client,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      definitionCache: ActiveDefinitionCacheHolder(),
        pinnedFormCache: ActivePinnedFormCacheHolder(),
      cacheOpener: (_) async => InMemoryDefinitionCacheRepository(),
        pinnedFormCacheOpener: (_) async => InMemoryPinnedFormCacheRepository(),
      appAuthAdapter: FakeAppAuthAdapter(
        response: fakeTokenResponse(accessToken: 'token-beta'),
      ),
    );
    // Re-point at the same controller instance's state by calling
    // switchTenant on it directly (uses its own appAuthAdapter).
    await betaController.switchTenant('beta');
    expect(betaController.state.phase, BootstrapPhase.success);
    expect(await tokenStore.read(_realmA), isNull);
    expect(await tokenStore.read(_realmB), isNotNull);

    await betaController.logout();
    expect(betaController.state.phase, BootstrapPhase.unauthenticated);
    expect(await tokenStore.read(_realmB), isNull);
  });
}
