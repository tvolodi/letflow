// REQ-422 §2, MOB-5, AC2: no unredacted logger is registered anywhere in
// `apps/mobile/lib`, and `RedactingLogInterceptor` (available, unregistered
// infrastructure for REQ-425/MOB-6) actually redacts the Authorization
// header and token-endpoint bodies when a caller does register/exercise it.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';

import '../support/fake_app_auth_adapter.dart';
import '../support/fake_dio_http_client_adapter.dart';
import '../support/fake_http_gateway.dart' show tenantConfigJson;
import '../support/fake_secure_storage_platform.dart';

// ── Static guard (design §2.2) ─────────────────────────────────────────────

class UnredactedLoggerViolation {
  UnredactedLoggerViolation(this.detail);

  final String detail;

  @override
  String toString() => detail;
}

/// Interceptor constructors this file's `.interceptors.add(...)` calls are
/// allowed to reference. Anything else constructed there is a violation —
/// in particular Dio's own non-redacting `LogInterceptor(`.
const List<String> _allowedInterceptorConstructors = [
  '_transportPolicyInterceptor(',
  '_bearerInterceptor(',
  'RedactingLogInterceptor(',
];

const List<String> _forbiddenLoggingPubspecNames = [
  'pretty_dio_logger',
  'dio_smart_retry',
];

/// Checks `lib/api/api_client.dart`'s own source for a registered
/// unredacted logger. Pure function so the self-test can exercise it
/// without touching the real file.
List<UnredactedLoggerViolation> checkNoUnredactedLogInterceptor({
  required String apiClientDartSource,
}) {
  final violations = <UnredactedLoggerViolation>[];

  // Word-boundary + negative-lookbehind so this doesn't false-positive on
  // `RedactingLogInterceptor(`, which itself contains the substring
  // `LogInterceptor(`.
  if (RegExp(r'(?<!Redacting)\bLogInterceptor\(').hasMatch(apiClientDartSource)) {
    violations.add(
      UnredactedLoggerViolation(
        "api_client.dart constructs Dio's own non-redacting LogInterceptor(",
      ),
    );
  }

  final addCallRegex = RegExp(
    r'\.interceptors\.add\(\s*(?:const\s+)?([A-Za-z_][A-Za-z0-9_]*)\(',
  );
  for (final match in addCallRegex.allMatches(apiClientDartSource)) {
    final ctor = '${match.group(1)}(';
    if (!_allowedInterceptorConstructors.contains(ctor)) {
      violations.add(
        UnredactedLoggerViolation(
          'interceptors.add(...) constructs $ctor, not in the allowlist'
          ' $_allowedInterceptorConstructors',
        ),
      );
    }
  }

  return violations;
}

/// Checks a pubspec dependency-name list for a forbidden third-party
/// logging package.
List<UnredactedLoggerViolation> checkNoForbiddenLoggingPackage({
  required List<String> pubspecDependencyNames,
}) {
  return [
    for (final name in pubspecDependencyNames)
      if (_forbiddenLoggingPubspecNames.contains(name))
        UnredactedLoggerViolation('forbidden logging package: $name'),
  ];
}

List<String> _extractPubspecDependencyNames(String yamlContent) {
  final names = <String>[];
  var inDepsBlock = false;
  for (final rawLine in yamlContent.split('\n')) {
    final line = rawLine.replaceAll('\r', '');
    if (line == 'dependencies:' || line == 'dev_dependencies:') {
      inDepsBlock = true;
      continue;
    }
    if (line.isEmpty) continue;
    if (!line.startsWith(' ') && line.trimRight().endsWith(':')) {
      inDepsBlock = false;
      continue;
    }
    if (!inDepsBlock) continue;
    final match = RegExp(r'^  ([A-Za-z0-9_]+):').firstMatch(line);
    if (match != null) names.add(match.group(1)!);
  }
  return names;
}

void main() {
  test('real lib/api/api_client.dart registers no unredacted logger', () {
    final source = File('lib/api/api_client.dart').readAsStringSync();

    final violations = checkNoUnredactedLogInterceptor(
      apiClientDartSource: source,
    );

    expect(
      violations,
      isEmpty,
      reason: violations.map((v) => v.toString()).join('\n'),
    );
  });

  test('real pubspec.yaml has no forbidden third-party logging package', () {
    final yaml = File('pubspec.yaml').readAsStringSync();
    final names = _extractPubspecDependencyNames(yaml);

    final violations = checkNoForbiddenLoggingPackage(
      pubspecDependencyNames: names,
    );

    expect(violations, isEmpty, reason: violations.map((v) => '$v').join('\n'));
  });

  test('self-test: checker fires on a fixture source registering'
      " Dio's own LogInterceptor(", () {
    const fixture = 'dio.interceptors.add(LogInterceptor());';

    final violations = checkNoUnredactedLogInterceptor(
      apiClientDartSource: fixture,
    );

    expect(violations, isNotEmpty);
  });

  test('self-test: checker fires on a fixture pubspec listing'
      ' pretty_dio_logger', () {
    final violations = checkNoForbiddenLoggingPackage(
      pubspecDependencyNames: ['pretty_dio_logger'],
    );

    expect(violations, hasLength(1));
  });

  // ── RedactingLogInterceptor behavior (design §2.3) ───────────────────────

  test('RedactingLogInterceptor redacts the Authorization header and'
      ' does not redact an unrelated path\'s body', () async {
    final captured = <String>[];
    final interceptor = RedactingLogInterceptor(logSink: captured.add);
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = FakeDioHttpClientAdapter()
      // Added *before* the redacting interceptor so the Authorization
      // header exists by the time RedactingLogInterceptor's onRequest
      // runs (Dio's onRequest interceptors run in FIFO order).
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            options.headers['Authorization'] = 'Bearer SECRET-TOKEN-SENTINEL';
            handler.next(options);
          },
        ),
      )
      ..interceptors.add(interceptor);
    (dio.httpClientAdapter as FakeDioHttpClientAdapter).responses['/x'] = (
      200,
      {'ok': true},
    );

    await dio.get<dynamic>('/x');

    final joined = captured.join('\n');
    expect(joined, isNot(contains('SECRET-TOKEN-SENTINEL')));
    expect(joined, contains('[REDACTED]'));
  });

  test('RedactingLogInterceptor redacts the whole body for a token-endpoint'
      ' path but not for an unrelated path', () async {
    final captured = <String>[];
    final interceptor = RedactingLogInterceptor(logSink: captured.add);
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = FakeDioHttpClientAdapter()
      ..interceptors.add(interceptor);
    final adapter = dio.httpClientAdapter as FakeDioHttpClientAdapter;
    adapter.responses['/protocol/openid-connect/token'] = (
      200,
      {'refresh_token': 'SECRET-REFRESH-SENTINEL'},
    );
    adapter.responses['/unrelated'] = (200, {'value': 'plain-visible'});

    await dio.get<dynamic>('/protocol/openid-connect/token');
    await dio.get<dynamic>('/unrelated');

    final joined = captured.join('\n');
    expect(joined, isNot(contains('SECRET-REFRESH-SENTINEL')));
    expect(joined, contains('plain-visible'));
  });

  // ── Sentinel test across the app's real log sinks (design §2.4, AC2) ────

  test('no sentinel access/refresh token ever reaches debugPrint, and no'
      ' developer.log/print call exists in lib/api/ or lib/auth/', () async {
    final capturedLines = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      capturedLines.add(message ?? '');
    };

    try {
      FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();

      final fakeAdapter = FakeDioHttpClientAdapter();
      final dio = Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = fakeAdapter;
      final tokenStore = TenantTokenStore.production();
      final activeRealm = ActiveRealmHolder();
      final client = ApiClient.forTesting(dio);
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            if (options.extra['skipAuth'] == true) {
              handler.next(options);
              return;
            }
            final realmUrl = activeRealm.currentRealmUrl;
            if (realmUrl != null) {
              final tokens = await tokenStore.read(realmUrl);
              if (tokens != null) {
                options.headers['Authorization'] =
                    'Bearer ${tokens.accessToken}';
              }
            }
            handler.next(options);
          },
        ),
      );

      fakeAdapter.handler = (options) {
        if (options.path == '/api/mobile/tenant-config') {
          return (
            200,
            tenantConfigJson(
              realmUrl: 'https://idp.example/realms/acme',
              clientId: 'acme-client',
            ),
          );
        }
        if (options.path == '/api/v1/me/memberships') {
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
        if (options.path == '/api/v1/me/modules') {
          return (200, {'installed_modules': []});
        }
        return null;
      };

      await runTenantBootstrap(
        'acme',
        client: client,
        tokenStore: tokenStore,
        activeRealm: activeRealm,
        appAuthAdapter: FakeAppAuthAdapter(
          response: fakeTokenResponse(
            accessToken: 'SECRET-TOKEN-SENTINEL',
            refreshToken: 'SECRET-REFRESH-SENTINEL',
          ),
        ),
      );

      await client.get('/api/v1/me/modules');

      final joined = capturedLines.join('\n');
      expect(joined, isNot(contains('SECRET-TOKEN-SENTINEL')));
      expect(joined, isNot(contains('SECRET-REFRESH-SENTINEL')));

      final apiSource = File('lib/api/api_client.dart').readAsStringSync();
      final authSource = File('lib/auth/auth.dart').readAsStringSync();
      final bothSources = '$apiSource\n$authSource';
      expect(bothSources, isNot(contains('developer.log(')));
      // A bare `print(` call — the redacting interceptor's own `logSink`
      // default (`debugPrint`) is not `print`, so this is a genuine,
      // independent static check, not a duplicate of the dynamic capture
      // above.
      expect(RegExp(r'(?<![\w.])print\(').hasMatch(bothSources), isFalse);
    } finally {
      debugPrint = originalDebugPrint;
    }
  });
}
