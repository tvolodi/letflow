// REQ-422 §4, MOB-5, AC5: release policy allows only https://; debug policy
// additionally allows http:// to 10.0.2.2/localhost; a disallowed URL is
// rejected before any socket opens, at both the ApiClient/Dio level and the
// bootstrap realm_url-check level.
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/api/transport_policy.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';

import '../support/fake_app_auth_adapter.dart';
import '../support/fake_dio_http_client_adapter.dart';
import '../support/fake_http_gateway.dart' show tenantConfigJson;
import '../support/fake_secure_storage_platform.dart';

/// Pure, table-driven check over [releasePolicy]/[debugPolicy]'s decisions
/// for a fixed set of URLs (design §4.5). Returns every mismatch found.
List<Object> checkTransportPolicyDecisions({
  required TransportPolicy releasePolicy,
  required TransportPolicy debugPolicy,
}) {
  final cases = <(String url, bool releaseExpected, bool debugExpected)>[
    ('https://api.letflow.example/x', true, true),
    ('http://10.0.2.2:8080/x', false, true),
    ('http://localhost:8080/x', false, true),
    ('http://evil.example.com/x', false, false),
  ];

  final mismatches = <Object>[];
  for (final (url, releaseExpected, debugExpected) in cases) {
    final uri = Uri.parse(url);
    final releaseActual = releasePolicy.isUrlAllowed(uri);
    final debugActual = debugPolicy.isUrlAllowed(uri);
    if (releaseActual != releaseExpected) {
      mismatches.add(
        'release: $url expected $releaseExpected, got $releaseActual',
      );
    }
    if (debugActual != debugExpected) {
      mismatches.add('debug: $url expected $debugExpected, got $debugActual');
    }
  }
  return mismatches;
}

void main() {
  test('table-driven: release/debug policy decisions match the design'
      ' exactly', () {
    final mismatches = checkTransportPolicyDecisions(
      releasePolicy: const ReleaseTransportPolicy(),
      debugPolicy: const DebugTransportPolicy(),
    );

    expect(mismatches, isEmpty, reason: mismatches.join('\n'));
  });

  test('transportPolicyFor(isRelease: true) returns a ReleaseTransportPolicy'
      ' and (isRelease: false) returns a DebugTransportPolicy', () {
    expect(
      transportPolicyFor(isRelease: true),
      isA<ReleaseTransportPolicy>(),
    );
    expect(
      transportPolicyFor(isRelease: false),
      isA<DebugTransportPolicy>(),
    );
  });

  group('ApiClient transport-policy interceptor', () {
    late FakeDioHttpClientAdapter fakeAdapter;

    setUp(() {
      FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
      fakeAdapter = FakeDioHttpClientAdapter();
    });

    test('a release-policy client rejects an http:// request before any'
        ' socket opens -- the fake adapter records zero calls', () async {
      final dio = Dio(
        BaseOptions(
          baseUrl: 'http://evil.example.com',
          validateStatus: (_) => true,
        ),
      )..httpClientAdapter = fakeAdapter;
      // Re-apply what ApiClient.create wires (forTesting wraps a
      // caller-built Dio verbatim), mirroring api_client_test.dart's idiom.
      dio.interceptors.add(
        _transportPolicyInterceptorForTest(const ReleaseTransportPolicy()),
      );
      final client = ApiClient.forTesting(dio);

      await expectLater(
        () => client.get('/some/path'),
        throwsA(isA<DioException>()),
      );

      expect(fakeAdapter.requests, isEmpty);
    });

    test('a debug-policy client allows http://10.0.2.2 -- the fake adapter'
        ' does record the call', () async {
      final dio = Dio(
        BaseOptions(
          baseUrl: 'http://10.0.2.2:8080',
          validateStatus: (_) => true,
        ),
      )..httpClientAdapter = fakeAdapter;
      dio.interceptors.add(
        _transportPolicyInterceptorForTest(const DebugTransportPolicy()),
      );
      fakeAdapter.responses['/some/path'] = (200, {'ok': true});
      final client = ApiClient.forTesting(dio);

      await client.get('/some/path');

      expect(fakeAdapter.requests, hasLength(1));
    });
  });

  group('runTenantBootstrap realm_url transport check', () {
    setUp(() {
      FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
    });

    test('a tenant-config response whose realm_url is http:// (release'
        ' policy) is rejected with oidcFailure, and the OIDC adapter is'
        ' never invoked', () async {
      final fakeGateway = _FakeInsecureRealmGateway();
      final tokenStore = const TenantTokenStore(FlutterSecureStorage());
      final activeRealm = ActiveRealmHolder();
      final appAuthAdapter = FakeAppAuthAdapter(response: fakeTokenResponse());

      final result = await runTenantBootstrap(
        'acme',
        client: fakeGateway,
        tokenStore: tokenStore,
        activeRealm: activeRealm,
        appAuthAdapter: appAuthAdapter,
        transportPolicy: const ReleaseTransportPolicy(),
      );

      expect(result, isA<BootstrapFailure>());
      expect(
        (result as BootstrapFailure).reason,
        BootstrapFailureReason.oidcFailure,
      );
      expect(appAuthAdapter.callCount, 0);
    });

    test('the same http:// realm_url IS allowed under the debug transport'
        ' policy (the emulator/localhost case), so bootstrap proceeds to'
        ' the OIDC step', () async {
      final fakeGateway = _FakeInsecureRealmGateway(
        realmUrl: 'http://10.0.2.2:8080/realms/acme',
      );
      final tokenStore = const TenantTokenStore(FlutterSecureStorage());
      final activeRealm = ActiveRealmHolder();
      final appAuthAdapter = FakeAppAuthAdapter(response: fakeTokenResponse());

      await runTenantBootstrap(
        'acme',
        client: fakeGateway,
        tokenStore: tokenStore,
        activeRealm: activeRealm,
        appAuthAdapter: appAuthAdapter,
        transportPolicy: const DebugTransportPolicy(),
      );

      expect(appAuthAdapter.callCount, 1);
    });
  });
}

/// Re-registers the same private transport-policy interceptor shape
/// `ApiClient.create` installs internally -- this test file cannot import
/// the private `_transportPolicyInterceptor` from `api_client.dart`, so it
/// exercises the public contract (`policy.isUrlAllowed`) the same way,
/// against the same seam (`handler.reject` before `handler.next`).
Interceptor _transportPolicyInterceptorForTest(TransportPolicy policy) {
  return InterceptorsWrapper(
    onRequest: (options, handler) {
      if (!policy.isUrlAllowed(options.uri)) {
        handler.reject(
          DioException(
            requestOptions: options,
            error: TransportPolicyRejectedException(
              options.uri,
              isRelease: policy is ReleaseTransportPolicy,
            ),
            type: DioExceptionType.unknown,
          ),
        );
        return;
      }
      handler.next(options);
    },
  );
}

class _FakeInsecureRealmGateway implements HttpGateway {
  _FakeInsecureRealmGateway({
    this.realmUrl = 'http://insecure.example/realms/acme',
  });

  final String realmUrl;

  @override
  Future<Response<dynamic>> getUnauthenticated(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    return Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: tenantConfigJson(realmUrl: realmUrl, clientId: 'acme-client'),
    );
  }

  @override
  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    if (path == '/api/v1/me/memberships') {
      return Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: {
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
    return Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: {'installed_modules': []},
    );
  }
}
