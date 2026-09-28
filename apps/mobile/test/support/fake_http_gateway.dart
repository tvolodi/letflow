/// Fake [HttpGateway] test double (REQ-421). Records every call made
/// through it and returns a caller-scripted [Response] (or throws a
/// caller-scripted exception) per path, so bootstrap-sequence tests never
/// need to touch Dio's real transport layer.
library;

import 'package:dio/dio.dart';
import 'package:letflow/api/api_client.dart';

class RecordedCall {
  RecordedCall({
    required this.method,
    required this.path,
    required this.queryParameters,
  });

  final String method; // 'get' | 'getUnauthenticated'
  final String path;
  final Map<String, dynamic>? queryParameters;
}

class ScriptedResponse {
  ScriptedResponse({this.statusCode = 200, this.data, this.error});

  final int statusCode;
  final dynamic data;

  /// If set, the call throws this instead of returning a response.
  final Object? error;
}

class FakeHttpGateway implements HttpGateway {
  FakeHttpGateway();

  final List<RecordedCall> calls = [];

  /// `path -> ScriptedResponse` for authenticated `get` calls.
  final Map<String, ScriptedResponse> getResponses = {};

  /// `path -> ScriptedResponse` for `getUnauthenticated` calls.
  final Map<String, ScriptedResponse> unauthenticatedResponses = {};

  /// `slug -> ScriptedResponse` for `getUnauthenticated` calls whose
  /// `queryParameters['slug']` matters (the tenant-config endpoint) — takes
  /// precedence over [unauthenticatedResponses] when the incoming call
  /// carries a `slug` query parameter present in this map. Lets one
  /// [FakeHttpGateway] instance serve two distinct slugs with two distinct
  /// tenant-config bodies across a single running app instance (AC2).
  final Map<String, ScriptedResponse> unauthenticatedResponsesBySlug = {};

  Response<dynamic> _respond(String path, ScriptedResponse scripted) {
    if (scripted.error != null) {
      throw scripted.error!;
    }
    return Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: scripted.statusCode,
      data: scripted.data,
    );
  }

  @override
  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    calls.add(
      RecordedCall(method: 'get', path: path, queryParameters: queryParameters),
    );
    final scripted = getResponses[path];
    if (scripted == null) {
      throw StateError('FakeHttpGateway: no scripted response for GET $path');
    }
    return _respond(path, scripted);
  }

  @override
  Future<Response<dynamic>> getUnauthenticated(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    calls.add(
      RecordedCall(
        method: 'getUnauthenticated',
        path: path,
        queryParameters: queryParameters,
      ),
    );
    final slug = queryParameters?['slug'] as String?;
    final scripted =
        (slug != null ? unauthenticatedResponsesBySlug[slug] : null) ??
        unauthenticatedResponses[path];
    if (scripted == null) {
      throw StateError(
        'FakeHttpGateway: no scripted response for unauthenticated GET $path',
      );
    }
    return _respond(path, scripted);
  }
}

/// Builds a canned 6-key tenant-config JSON body (`Letflow.Routers.
/// MobileTenantConfig`'s response shape) for [realmUrl]/[clientId].
Map<String, dynamic> tenantConfigJson({
  required String realmUrl,
  required String clientId,
}) {
  return {
    'realm_url': realmUrl,
    'client_id': clientId,
    'locales': ['en'],
    'default_locale': 'en',
    'branding': {
      'app_name': 'Letflow',
      'logo_url': null,
      'primary_color': '#000000',
    },
    'environment_kind': 'test',
  };
}
