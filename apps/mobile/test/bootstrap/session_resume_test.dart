// REQ-423 design §7.3: BootstrapController.attemptSessionResume() reaches
// BootstrapPhase.resumedOffline from secure storage alone, with zero HTTP
// calls, and falls back to unauthenticated when there is nothing to resume.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';
import 'package:letflow/definitions/definitions.dart';
import 'package:letflow/definitions/pinned_form_cache.dart';

import '../support/fake_app_auth_adapter.dart';
import '../support/fake_http_gateway.dart' show FakeHttpGateway;
import '../support/fake_secure_storage_platform.dart';

const _realmA = 'https://idp.example/realms/acme';

void main() {
  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
  });

  test(
    'no last-active-tenant pointer: attemptSessionResume leaves state at'
    ' unauthenticated, with zero HTTP calls',
    () async {
      final gateway = FakeHttpGateway();
      final controller = BootstrapController(
        client: gateway,
        tokenStore: const TenantTokenStore(FlutterSecureStorage()),
        activeRealm: ActiveRealmHolder(),
        definitionCache: ActiveDefinitionCacheHolder(),
        cacheOpener: (_) async => InMemoryDefinitionCacheRepository(),
        pinnedFormCache: ActivePinnedFormCacheHolder(),
        pinnedFormCacheOpener: (_) async => InMemoryPinnedFormCacheRepository(),
        appAuthAdapter: FakeAppAuthAdapter(response: fakeTokenResponse()),
      );

      await controller.attemptSessionResume();

      expect(controller.state.phase, BootstrapPhase.unauthenticated);
      expect(gateway.calls, isEmpty);
    },
  );

  test(
    'a previously-stored session: attemptSessionResume reaches'
    ' resumedOffline (never success) with zero HTTP calls, and opens the'
    ' definition-cache partition for that realm',
    () async {
      final gateway = FakeHttpGateway();
      final tokenStore = const TenantTokenStore(FlutterSecureStorage());
      final activeRealm = ActiveRealmHolder();
      final definitionCache = ActiveDefinitionCacheHolder();
      final cacheRepo = InMemoryDefinitionCacheRepository();
      final pinnedFormCache = ActivePinnedFormCacheHolder();
      final pinnedFormCacheRepo = InMemoryPinnedFormCacheRepository();

      // Simulate a prior successful bootstrap having written both the
      // token and the last-active-tenant pointer (design §7.2/§7.3 -- the
      // same point `activeRealm.currentRealmUrl` itself is set).
      await tokenStore.store(
        _realmA,
        TokenSet(
          accessToken: 'stored-access-token',
          refreshToken: 'stored-refresh-token',
          idToken: null,
          accessTokenExpiration: null,
        ),
      );
      await writeLastActiveTenant(
        tokenStore,
        const LastActiveTenantPointer(realmUrl: _realmA, slug: 'acme'),
      );

      final controller = BootstrapController(
        client: gateway,
        tokenStore: tokenStore,
        activeRealm: activeRealm,
        definitionCache: definitionCache,
        cacheOpener: (_) async => cacheRepo,
        pinnedFormCache: pinnedFormCache,
        pinnedFormCacheOpener: (_) async => pinnedFormCacheRepo,
        appAuthAdapter: FakeAppAuthAdapter(response: fakeTokenResponse()),
      );

      await controller.attemptSessionResume();

      expect(controller.state.phase, BootstrapPhase.resumedOffline);
      expect(controller.state.phase, isNot(BootstrapPhase.success));
      expect(activeRealm.currentRealmUrl, _realmA);
      expect(definitionCache.current, same(cacheRepo));
      expect(definitionCache.currentRealmUrl, _realmA);
      expect(pinnedFormCache.current, same(pinnedFormCacheRepo));
      expect(pinnedFormCache.currentRealmUrl, _realmA);
      expect(gateway.calls, isEmpty, reason: 'resume reads secure storage only');
    },
  );

  test(
    'a pointer with no matching stored tokens (e.g. a prior logout raced'
    ' with an unclean pointer clear) falls back to unauthenticated',
    () async {
      final gateway = FakeHttpGateway();
      final tokenStore = const TenantTokenStore(FlutterSecureStorage());
      await writeLastActiveTenant(
        tokenStore,
        const LastActiveTenantPointer(realmUrl: _realmA, slug: 'acme'),
      );
      // No token stored for _realmA.

      final controller = BootstrapController(
        client: gateway,
        tokenStore: tokenStore,
        activeRealm: ActiveRealmHolder(),
        definitionCache: ActiveDefinitionCacheHolder(),
        cacheOpener: (_) async => InMemoryDefinitionCacheRepository(),
        pinnedFormCache: ActivePinnedFormCacheHolder(),
        pinnedFormCacheOpener: (_) async => InMemoryPinnedFormCacheRepository(),
        appAuthAdapter: FakeAppAuthAdapter(response: fakeTokenResponse()),
      );

      await controller.attemptSessionResume();

      expect(controller.state.phase, BootstrapPhase.unauthenticated);
      expect(gateway.calls, isEmpty);
    },
  );

  test('logout clears the last-active-tenant pointer -- a later'
      ' attemptSessionResume on the same device falls back to'
      ' unauthenticated', () async {
    final gateway = FakeHttpGateway();
    final tokenStore = const TenantTokenStore(FlutterSecureStorage());
    final activeRealm = ActiveRealmHolder()..currentRealmUrl = _realmA;
    await tokenStore.store(
      _realmA,
      const TokenSet(
        accessToken: 'tok',
        refreshToken: null,
        idToken: null,
        accessTokenExpiration: null,
      ),
    );
    await writeLastActiveTenant(
      tokenStore,
      const LastActiveTenantPointer(realmUrl: _realmA, slug: 'acme'),
    );

    await logout(tokenStore: tokenStore, activeRealm: activeRealm);

    expect(await readLastActiveTenant(tokenStore), isNull);

    final controller = BootstrapController(
      client: gateway,
      tokenStore: tokenStore,
      activeRealm: ActiveRealmHolder(),
      definitionCache: ActiveDefinitionCacheHolder(),
      cacheOpener: (_) async => InMemoryDefinitionCacheRepository(),
      pinnedFormCache: ActivePinnedFormCacheHolder(),
      pinnedFormCacheOpener: (_) async => InMemoryPinnedFormCacheRepository(),
      appAuthAdapter: FakeAppAuthAdapter(response: fakeTokenResponse()),
    );
    await controller.attemptSessionResume();
    expect(controller.state.phase, BootstrapPhase.unauthenticated);
  });
}
