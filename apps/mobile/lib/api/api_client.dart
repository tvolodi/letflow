/// The single `Dio`-construction site for the whole app (REQ-421 design
/// §7). Also houses the tenant-config response models (§2.1) and the
/// unauthenticated `tenant-config` fetch (§2.2).
///
/// **Invariant (AC8):** a repo-wide grep for a `Dio` constructor call must
/// return exactly one hit — the one inside [ApiClient.create] below. No
/// other file in `apps/mobile/lib` constructs a `Dio` instance. (This
/// comment deliberately spells the call differently from the real one so
/// it is not itself a second grep hit.)
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../auth/auth.dart' show TenantTokenStore;

@immutable
class TenantBranding {
  const TenantBranding({
    required this.appName,
    required this.logoUrl,
    required this.primaryColor,
  });

  final String appName;
  final String? logoUrl;
  final String primaryColor;

  factory TenantBranding.fromJson(Map<String, dynamic> json) {
    return TenantBranding(
      appName: _requireString(json, 'app_name'),
      logoUrl: json['logo_url'] as String?,
      primaryColor: _requireString(json, 'primary_color'),
    );
  }
}

/// The mobile `tenant-config` response (`Letflow.Routers.MobileTenantConfig`,
/// REQ-421 design §2.1). `fromJson` is total over the backend's six-key
/// shape and throws [FormatException] on any missing/malformed key — the
/// bootstrap sequence treats a malformed response the same as an
/// unreachable one (no separate "malformed tenant-config" error screen).
@immutable
class TenantConfig {
  const TenantConfig({
    required this.realmUrl,
    required this.clientId,
    required this.locales,
    required this.defaultLocale,
    required this.branding,
    required this.environmentKind,
  });

  final String realmUrl;
  final String clientId;
  final List<String> locales;
  final String defaultLocale;
  final TenantBranding branding;
  final String environmentKind;

  factory TenantConfig.fromJson(Map<String, dynamic> json) {
    final brandingJson = json['branding'];
    if (brandingJson is! Map<String, dynamic>) {
      throw const FormatException(
        'TenantConfig.fromJson: missing or non-object "branding"',
      );
    }
    final localesJson = json['locales'];
    if (localesJson is! List) {
      throw const FormatException(
        'TenantConfig.fromJson: missing or non-array "locales"',
      );
    }
    return TenantConfig(
      realmUrl: _requireString(json, 'realm_url'),
      clientId: _requireString(json, 'client_id'),
      locales: localesJson.map((e) => e as String).toList(),
      defaultLocale: _requireString(json, 'default_locale'),
      branding: TenantBranding.fromJson(brandingJson),
      environmentKind: _requireString(json, 'environment_kind'),
    );
  }
}

String _requireString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('missing or non-string "$key"');
  }
  return value;
}

/// The narrow HTTP surface this requirement's callers need — an interface
/// so tests can supply a fake without touching Dio's transport layer.
/// [ApiClient] is the sole production implementation.
abstract class HttpGateway {
  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  });

  Future<Response<dynamic>> getUnauthenticated(
    String path, {
    Map<String, dynamic>? queryParameters,
  });
}

/// Holds the `realm_url` of whichever tenant's bootstrap most recently
/// completed successfully — the bearer-attach interceptor's source of
/// truth for "the currently active tenant" (REQ-421 design §5.3/§7.2). A
/// plain mutable holder, not a build-time constant, so a second
/// `runTenantBootstrap` call (different tenant, same app instance) can
/// overwrite it with no rebuild.
class ActiveRealmHolder {
  String? currentRealmUrl;
}

class ApiClient implements HttpGateway {
  ApiClient._(this._dio);

  final Dio _dio;

  static const String _apiBaseUrl = String.fromEnvironment(
    'LETFLOW_API_BASE_URL',
  );

  /// The one place a [Dio] instance is constructed in `apps/mobile/lib`
  /// (design §7.1, AC8). `baseUrl` defaults to the build-time `LETFLOW_API_BASE_URL`
  /// define, read once, here — never re-read anywhere else.
  ///
  /// `validateStatus` accepts every HTTP status code so callers (§5.2's
  /// memberships/modules calls, which must distinguish 200/403/other
  /// without a thrown exception) can read `response.statusCode` directly;
  /// a thrown [DioException] from this client therefore only ever
  /// indicates a genuine transport failure (no connectivity, DNS, timeout),
  /// never a non-2xx HTTP response.
  factory ApiClient.create({
    required TenantTokenStore tokenStore,
    required ActiveRealmHolder activeRealm,
    String? baseUrl,
  }) {
    final dio = Dio(
      BaseOptions(baseUrl: baseUrl ?? _apiBaseUrl, validateStatus: (_) => true),
    );
    dio.interceptors.add(_bearerInterceptor(tokenStore, activeRealm));
    return ApiClient._(dio);
  }

  /// Test-only seam: wraps a caller-supplied [Dio] (e.g. one configured
  /// with a fake `HttpClientAdapter`) so tests can exercise the real
  /// [ApiClient] wiring (interceptor, header attach) without constructing a
  /// second one inside this file — the test builds the [Dio] instance
  /// itself, outside `apps/mobile/lib`.
  @visibleForTesting
  factory ApiClient.forTesting(Dio dio) => ApiClient._(dio);

  @override
  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) {
    return _dio.get<dynamic>(path, queryParameters: queryParameters);
  }

  @override
  Future<Response<dynamic>> getUnauthenticated(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) {
    return _dio.get<dynamic>(
      path,
      queryParameters: queryParameters,
      options: Options(extra: const {'skipAuth': true}),
    );
  }
}

/// Bearer-attach interceptor (design §7.2) — attaches nothing beyond that.
/// Refresh-on-401, retry, and typed `ApiError` normalization are REQ-425's
/// (MOB-6) scope, not this one's.
Interceptor _bearerInterceptor(
  TenantTokenStore tokenStore,
  ActiveRealmHolder activeRealm,
) {
  return InterceptorsWrapper(
    onRequest: (options, handler) async {
      if (options.extra['skipAuth'] == true) {
        handler.next(options);
        return;
      }
      final realmUrl = activeRealm.currentRealmUrl;
      if (realmUrl != null) {
        final tokens = await tokenStore.read(realmUrl);
        if (tokens != null) {
          options.headers['Authorization'] = 'Bearer ${tokens.accessToken}';
        }
      }
      handler.next(options);
    },
  );
}

/// Fetches the unauthenticated `tenant-config` for [slug] (design §2.2).
/// Throws (a [DioException] or a [FormatException]) on any transport
/// failure or malformed response — `runTenantBootstrap` catches both and
/// maps them to `BootstrapFailureReason.networkUnavailable`.
Future<TenantConfig> fetchTenantConfig(
  String slug, {
  required HttpGateway client,
}) async {
  final response = await client.getUnauthenticated(
    '/api/mobile/tenant-config',
    queryParameters: {'slug': slug},
  );
  final status = response.statusCode ?? 0;
  if (status < 200 || status >= 300) {
    throw DioException(
      requestOptions: response.requestOptions,
      response: response,
    );
  }
  return TenantConfig.fromJson(response.data as Map<String, dynamic>);
}
