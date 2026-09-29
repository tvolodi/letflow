// REQ-422 §6.1/§6.2, MOB-5, AC7: JWT-payload `iss` decode round-trips over a
// hand-built fixture and never throws on a malformed token, and the
// bearer-interceptor's audience check fails closed on a determinable
// mismatch (attaches nothing) while failing open only when the `iss` claim
// cannot be determined at all.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/auth/auth.dart';

import '../support/fake_app_auth_adapter.dart';
import '../support/fake_dio_http_client_adapter.dart';
import '../support/fake_secure_storage_platform.dart';

/// Hand-builds a (signature-less, since none is verified client-side) JWT
/// string whose payload is [claims].
String _fakeJwt(Map<String, dynamic> claims) {
  String encodeSegment(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final header = encodeSegment({'alg': 'none', 'typ': 'JWT'});
  final payload = encodeSegment(claims);
  return '$header.$payload.';
}

void main() {
  group('decodeJwtPayload / issuerOf', () {
    test('round-trips a hand-built JWT fixture\'s iss claim', () {
      final jwt = _fakeJwt({'iss': 'https://tenant-a.example/realm'});

      final payload = decodeJwtPayload(jwt);

      expect(payload, isNotNull);
      expect(payload!['iss'], 'https://tenant-a.example/realm');
    });

    test('issuerOf prefers idToken over accessToken', () {
      final tokens = TokenSet(
        accessToken: _fakeJwt({'iss': 'https://from-access.example'}),
        refreshToken: null,
        idToken: _fakeJwt({'iss': 'https://from-id.example'}),
        accessTokenExpiration: null,
      );

      expect(issuerOf(tokens), 'https://from-id.example');
    });

    test('issuerOf falls back to accessToken when idToken is null', () {
      final tokens = TokenSet(
        accessToken: _fakeJwt({'iss': 'https://from-access.example'}),
        refreshToken: null,
        idToken: null,
        accessTokenExpiration: null,
      );

      expect(issuerOf(tokens), 'https://from-access.example');
    });

    test('a malformed (non-JWT) token decodes to null, never throws', () {
      expect(decodeJwtPayload('not-a-jwt-at-all'), isNull);
      expect(decodeJwtPayload('a.b'), isNull);
      expect(decodeJwtPayload('a.!!!not-base64!!!.c'), isNull);

      final tokens = TokenSet(
        accessToken: 'opaque-non-jwt-access-token',
        refreshToken: null,
        idToken: null,
        accessTokenExpiration: null,
      );
      expect(() => issuerOf(tokens), returnsNormally);
      expect(issuerOf(tokens), isNull);
    });
  });

  group('bearer-interceptor audience check', () {
    late FakeDioHttpClientAdapter fakeAdapter;
    late TenantTokenStore tokenStore;
    late ActiveRealmHolder activeRealm;

    setUp(() {
      FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
      fakeAdapter = FakeDioHttpClientAdapter();
      tokenStore = const TenantTokenStore(FlutterSecureStorage());
      activeRealm = ActiveRealmHolder();
    });

    test('a token whose iss is a DIFFERENT tenant\'s realm than the active'
        ' one is never attached — request proceeds unauthenticated', () async {
      // Deliberately corrupted fixture (production code never stores a
      // token under the wrong realm key) — this is the
      // "defense-in-depth actually fires" self-test per design §6.2's
      // OQ-4.
      final mismatchedToken = TokenSet(
        accessToken: 'plain-access-token',
        refreshToken: null,
        idToken: _fakeJwt({'iss': 'https://a.example'}),
        accessTokenExpiration: null,
      );
      await tokenStore.store('https://b.example', mismatchedToken);
      activeRealm.currentRealmUrl = 'https://b.example';

      // Real ApiClient.create wraps its own internal Dio; swap the fake
      // adapter into that same Dio via the interceptor test seam is not
      // exposed, so exercise this at the ApiClient.forTesting level
      // instead, replicating ApiClient.create's interceptor chain.
      final dio = Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = fakeAdapter;
      final testClient = ApiClient.forTesting(
        dio,
        tokenStore: tokenStore,
        activeRealm: activeRealm,
        appAuthAdapter: FakeAppAuthAdapter(),
        routeToLogin: () {},
      );
      fakeAdapter.responses['/api/v1/me/modules'] = (
        200,
        {'installed_modules': []},
      );

      await testClient.get('/api/v1/me/modules');

      expect(
        fakeAdapter.requests.single.headers.containsKey('Authorization'),
        isFalse,
      );
    });

    test('a token whose iss matches the active realm IS attached', () async {
      final matchingToken = TokenSet(
        accessToken: 'plain-access-token',
        refreshToken: null,
        idToken: _fakeJwt({'iss': 'https://a.example'}),
        accessTokenExpiration: null,
      );
      await tokenStore.store('https://a.example', matchingToken);
      activeRealm.currentRealmUrl = 'https://a.example';

      final dio = Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = fakeAdapter;
      final testClient = ApiClient.forTesting(
        dio,
        tokenStore: tokenStore,
        activeRealm: activeRealm,
        appAuthAdapter: FakeAppAuthAdapter(),
        routeToLogin: () {},
      );
      fakeAdapter.responses['/api/v1/me/modules'] = (
        200,
        {'installed_modules': []},
      );

      await testClient.get('/api/v1/me/modules');

      expect(
        fakeAdapter.requests.single.headers['Authorization'],
        'Bearer plain-access-token',
      );
    });

    test('a token whose iss cannot be determined (opaque, non-JWT) fails'
        ' open -- still attached', () async {
      final opaqueToken = TokenSet(
        accessToken: 'opaque-access-token',
        refreshToken: null,
        idToken: null,
        accessTokenExpiration: null,
      );
      await tokenStore.store('https://a.example', opaqueToken);
      activeRealm.currentRealmUrl = 'https://a.example';

      final dio = Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = fakeAdapter;
      final testClient = ApiClient.forTesting(
        dio,
        tokenStore: tokenStore,
        activeRealm: activeRealm,
        appAuthAdapter: FakeAppAuthAdapter(),
        routeToLogin: () {},
      );
      fakeAdapter.responses['/api/v1/me/modules'] = (
        200,
        {'installed_modules': []},
      );

      await testClient.get('/api/v1/me/modules');

      expect(
        fakeAdapter.requests.single.headers['Authorization'],
        'Bearer opaque-access-token',
      );
    });
  });
}

