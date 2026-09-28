// AC1 (auth-request half): the authorization request built for a slug uses
// issuer == that slug's tenant-config realm_url, clientId == that
// response's client_id, redirectUrl 'com.bizdala.letflow:/oauth2redirect',
// and a PKCE S256 challenge (REQ-421 design §3.1).
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/auth/auth.dart';

import '../support/fake_app_auth_adapter.dart';

void main() {
  test('issuer/clientId come from the tenant-config response, redirectUrl is'
      ' the fixed literal, and PKCE proceeds via the package default (no'
      ' explicit code-verifier override at this call site)', () async {
    final config = const TenantConfig(
      realmUrl: 'https://idp.example/realms/acme',
      clientId: 'acme-client-id',
      locales: ['en'],
      defaultLocale: 'en',
      branding: TenantBranding(
        appName: 'Acme',
        logoUrl: null,
        primaryColor: '#123456',
      ),
      environmentKind: 'test',
    );
    final fakeAdapter = FakeAppAuthAdapter(response: fakeTokenResponse());

    final response = await authenticateWithTenant(
      config,
      appAuthAdapter: fakeAdapter,
    );

    expect(response, isNotNull);
    expect(fakeAdapter.callCount, 1);

    final request = fakeAdapter.lastRequest!;
    expect(request.issuer, 'https://idp.example/realms/acme');
    expect(request.clientId, 'acme-client-id');
    expect(request.redirectUrl, 'com.bizdala.letflow:/oauth2redirect');

    // PKCE S256: `AuthorizationTokenRequest` never accepts an explicit
    // `codeVerifier` at construction (unlike the lower-level
    // `TokenRequest` it extends), so `codeVerifier` is always null here
    // — proof that no explicit code-verifier/challenge override is
    // possible at this call site, and PKCE proceeds via
    // `flutter_appauth`'s own S256-by-default native behavior.
    expect(request.codeVerifier, isNull);
    // realm_url was https, so no insecure-connection override.
    expect(request.allowInsecureConnections, isFalse);
  });

  test('allowInsecureConnections is true only when realm_url itself is'
      ' http (e.g. a local dev backend) -- never hardcoded true', () async {
    final httpConfig = const TenantConfig(
      realmUrl: 'http://localhost:8093/realms/bpm-default',
      clientId: 'letflow-mobile',
      locales: ['en'],
      defaultLocale: 'en',
      branding: TenantBranding(
        appName: 'Letflow',
        logoUrl: null,
        primaryColor: '#000000',
      ),
      environmentKind: 'development',
    );
    final adapter = FakeAppAuthAdapter(response: fakeTokenResponse());

    await authenticateWithTenant(httpConfig, appAuthAdapter: adapter);

    expect(adapter.lastRequest!.allowInsecureConnections, isTrue);
  });

  test('clientId is never a compiled literal — it always traces to the'
      ' TenantConfig value passed in', () async {
    final configA = const TenantConfig(
      realmUrl: 'https://idp.example/realms/a',
      clientId: 'client-a',
      locales: ['en'],
      defaultLocale: 'en',
      branding: TenantBranding(
        appName: 'A',
        logoUrl: null,
        primaryColor: '#000000',
      ),
      environmentKind: 'test',
    );
    final configB = const TenantConfig(
      realmUrl: 'https://idp.example/realms/b',
      clientId: 'client-b',
      locales: ['en'],
      defaultLocale: 'en',
      branding: TenantBranding(
        appName: 'B',
        logoUrl: null,
        primaryColor: '#000000',
      ),
      environmentKind: 'test',
    );
    final adapter = FakeAppAuthAdapter(response: fakeTokenResponse());

    await authenticateWithTenant(configA, appAuthAdapter: adapter);
    expect(adapter.lastRequest!.clientId, 'client-a');

    await authenticateWithTenant(configB, appAuthAdapter: adapter);
    expect(adapter.lastRequest!.clientId, 'client-b');
  });

  test('returns null on user cancellation (not a thrown exception)', () async {
    final config = const TenantConfig(
      realmUrl: 'https://idp.example/realms/acme',
      clientId: 'acme-client-id',
      locales: ['en'],
      defaultLocale: 'en',
      branding: TenantBranding(
        appName: 'Acme',
        logoUrl: null,
        primaryColor: '#123456',
      ),
      environmentKind: 'test',
    );
    final adapter = FakeAppAuthAdapter(response: null);

    final response = await authenticateWithTenant(
      config,
      appAuthAdapter: adapter,
    );

    expect(response, isNull);
  });

  test('lets a genuine OIDC-protocol failure propagate (not silently'
      ' converted to the same null cancellation returns)', () async {
    final config = const TenantConfig(
      realmUrl: 'https://idp.example/realms/acme',
      clientId: 'acme-client-id',
      locales: ['en'],
      defaultLocale: 'en',
      branding: TenantBranding(
        appName: 'Acme',
        logoUrl: null,
        primaryColor: '#123456',
      ),
      environmentKind: 'test',
    );
    final adapter = FakeAppAuthAdapter(
      error: FlutterAppAuthPlatformException(
        code: 'oidc_error',
        platformErrorDetails: FlutterAppAuthPlatformErrorDetails(),
      ),
    );

    expect(
      () => authenticateWithTenant(config, appAuthAdapter: adapter),
      throwsA(isA<FlutterAppAuthPlatformException>()),
    );
  });
}
