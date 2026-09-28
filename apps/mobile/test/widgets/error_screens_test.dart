// AC7: four widget tests, each forcing one of the four dedicated failure
// screens through the real bootstrap flow (submit slug -> failure ->
// screen), asserted by Key -- never a generic error widget or a crash
// (REQ-421 design §6).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/app.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';

import '../support/fake_app_auth_adapter.dart';
import '../support/fake_http_gateway.dart';
import '../support/fake_secure_storage_platform.dart';

Future<void> _enterSlugAndSubmit(WidgetTester tester, String slug) async {
  await tester.enterText(find.byKey(const Key('tenant-slug-field')), slug);
  await tester.tap(find.byKey(const Key('tenant-slug-submit')));
  // One pump for the loading state, then settle for the async bootstrap.
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
  });

  testWidgets('tenant-not-found: shows TenantNotFoundScreen by key', (
    tester,
  ) async {
    final gateway = FakeHttpGateway()
      ..unauthenticatedResponsesBySlug['nope'] = ScriptedResponse(
        data: tenantConfigJson(
          realmUrl: 'https://idp.example/realms/acme',
          clientId: 'client-acme',
        ),
      )
      ..getResponses['/api/v1/me/memberships'] = ScriptedResponse(
        data: {
          'memberships': [
            {
              'tenant_id': 't-x',
              'tenant_slug': 'a-different-tenant',
              'tenant_display_name': 'X',
              'display_label': null,
            },
          ],
        },
      );
    final controller = BootstrapController(
      client: gateway,
      tokenStore: const TenantTokenStore(FlutterSecureStorage()),
      activeRealm: ActiveRealmHolder(),
      appAuthAdapter: FakeAppAuthAdapter(response: fakeTokenResponse()),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bootstrapControllerProvider.overrideWith((ref) => controller),
        ],
        child: const LetflowApp(),
      ),
    );

    await _enterSlugAndSubmit(tester, 'nope');

    expect(find.byKey(tenantNotFoundScreenKey), findsOneWidget);
    expect(find.byKey(networkUnavailableScreenKey), findsNothing);
    expect(find.byKey(oidcFailureScreenKey), findsNothing);
    expect(find.byKey(secureStorageUnavailableScreenKey), findsNothing);
  });

  testWidgets('SocketException from the tenant-config fetch: shows'
      ' NetworkUnavailableScreen by key', (tester) async {
    final gateway = FakeHttpGateway()
      ..unauthenticatedResponsesBySlug['down'] = ScriptedResponse(
        error: const SocketException('no route to host'),
      );
    final controller = BootstrapController(
      client: gateway,
      tokenStore: const TenantTokenStore(FlutterSecureStorage()),
      activeRealm: ActiveRealmHolder(),
      appAuthAdapter: FakeAppAuthAdapter(response: fakeTokenResponse()),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bootstrapControllerProvider.overrideWith((ref) => controller),
        ],
        child: const LetflowApp(),
      ),
    );

    await _enterSlugAndSubmit(tester, 'down');

    expect(find.byKey(networkUnavailableScreenKey), findsOneWidget);
    expect(find.byKey(tenantNotFoundScreenKey), findsNothing);
    expect(find.byKey(oidcFailureScreenKey), findsNothing);
    expect(find.byKey(secureStorageUnavailableScreenKey), findsNothing);
  });

  testWidgets(
    'an AppAuth (OIDC-protocol) error: shows OidcFailureScreen by key',
    (tester) async {
      final gateway = FakeHttpGateway()
        ..unauthenticatedResponsesBySlug['acme'] = ScriptedResponse(
          data: tenantConfigJson(
            realmUrl: 'https://idp.example/realms/acme',
            clientId: 'client-acme',
          ),
        );
      final controller = BootstrapController(
        client: gateway,
        tokenStore: const TenantTokenStore(FlutterSecureStorage()),
        activeRealm: ActiveRealmHolder(),
        appAuthAdapter: FakeAppAuthAdapter(
          error: FlutterAppAuthPlatformException(
            code: 'oidc_error',
            platformErrorDetails: FlutterAppAuthPlatformErrorDetails(),
          ),
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bootstrapControllerProvider.overrideWith((ref) => controller),
          ],
          child: const LetflowApp(),
        ),
      );

      await _enterSlugAndSubmit(tester, 'acme');

      expect(find.byKey(oidcFailureScreenKey), findsOneWidget);
      expect(find.byKey(tenantNotFoundScreenKey), findsNothing);
      expect(find.byKey(networkUnavailableScreenKey), findsNothing);
      expect(find.byKey(secureStorageUnavailableScreenKey), findsNothing);
    },
  );

  testWidgets('a secure-storage exception on token store: shows'
      ' SecureStorageUnavailableScreen by key', (tester) async {
    final gateway = FakeHttpGateway()
      ..unauthenticatedResponsesBySlug['acme'] = ScriptedResponse(
        data: tenantConfigJson(
          realmUrl: 'https://idp.example/realms/acme',
          clientId: 'client-acme',
        ),
      );
    final fakeStoragePlatform = FakeSecureStoragePlatform()
      ..throwOnNextCall = PlatformException(code: 'keystore_error');
    FlutterSecureStoragePlatform.instance = fakeStoragePlatform;
    final controller = BootstrapController(
      client: gateway,
      tokenStore: const TenantTokenStore(FlutterSecureStorage()),
      activeRealm: ActiveRealmHolder(),
      appAuthAdapter: FakeAppAuthAdapter(response: fakeTokenResponse()),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bootstrapControllerProvider.overrideWith((ref) => controller),
        ],
        child: const LetflowApp(),
      ),
    );

    await _enterSlugAndSubmit(tester, 'acme');

    expect(find.byKey(secureStorageUnavailableScreenKey), findsOneWidget);
    expect(find.byKey(tenantNotFoundScreenKey), findsNothing);
    expect(find.byKey(networkUnavailableScreenKey), findsNothing);
    expect(find.byKey(oidcFailureScreenKey), findsNothing);
  });
}
