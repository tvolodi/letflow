/// Fake [PostCapableHttpGateway] test double for REQ-426's renderer-state
/// and list-renderer tests. Distinct from `fake_http_gateway.dart`'s
/// [FakeHttpGateway] class because that one implements only [HttpGateway]
/// (no `post`) -- extending it would require every existing
/// `implements HttpGateway` call site to gain a `post` override it doesn't
/// need (see `api_client.dart`'s own doc comment on why
/// `PostCapableHttpGateway` is kept as a separate, narrower interface).
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:letflow/api/api_client.dart';

class RecordedPostCall {
  RecordedPostCall({required this.path, required this.data});

  final String path;
  final Object? data;
}

/// A canned outcome for one `get`/`post` call: either a response (optionally
/// non-2xx `statusCode`, though every REQ-426 test scripts errors as a
/// thrown [ApiError] directly, matching how the real [ApiClient] surfaces
/// them to callers -- see `api_client.dart`'s throwing convention), a thrown
/// [error], or (via [ScriptedResponse.hang]) a [Future] that never
/// completes.
class ScriptedResponse {
  ScriptedResponse({this.statusCode = 200, this.data, this.error})
    : hang = false;

  const ScriptedResponse._hang()
    : statusCode = 200,
      data = null,
      error = null,
      hang = true;

  /// Never resolves -- forces the caller's own `RendererLoading` state to
  /// persist for the whole test (AC1's "loading via an uncompleted future").
  factory ScriptedResponse.hang() => const ScriptedResponse._hang();

  final int statusCode;
  final dynamic data;

  /// If set, the call throws this instead of returning a response.
  final Object? error;

  final bool hang;
}

class FakePostCapableHttpGateway implements PostCapableHttpGateway {
  final List<String> getCalls = [];
  final List<RecordedPostCall> postCalls = [];

  /// `path -> ScriptedResponse` for `get` calls (Call 1 --
  /// `GET /api/v1/entities/definitions/active/:name`).
  final Map<String, ScriptedResponse> getResponses = {};

  /// Sequential responses for `post` calls (Call 2 --
  /// `POST /api/v1/entities/query`) -- one entry consumed per call, in
  /// order, so a pagination/retry test can script a distinct response per
  /// page/attempt.
  final List<ScriptedResponse> postResponseQueue = [];

  @override
  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    getCalls.add(path);
    final scripted = getResponses[path];
    if (scripted == null) {
      throw StateError(
        'FakePostCapableHttpGateway: no scripted GET response for $path',
      );
    }
    if (scripted.hang) {
      // Deliberately never completes.
      return Completer<Response<dynamic>>().future;
    }
    if (scripted.error != null) throw scripted.error!;
    return Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: scripted.statusCode,
      data: scripted.data,
    );
  }

  @override
  Future<Response<dynamic>> getUnauthenticated(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) {
    throw UnimplementedError(
      'FakePostCapableHttpGateway does not script getUnauthenticated -- not '
      'needed by any REQ-426 renderer test.',
    );
  }

  @override
  Future<Response<dynamic>> post(String path, {Object? data}) async {
    postCalls.add(RecordedPostCall(path: path, data: data));
    if (postResponseQueue.isEmpty) {
      throw StateError(
        'FakePostCapableHttpGateway: no scripted POST response for $path',
      );
    }
    final scripted = postResponseQueue.removeAt(0);
    if (scripted.hang) {
      return Completer<Response<dynamic>>().future;
    }
    if (scripted.error != null) throw scripted.error!;
    return Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: scripted.statusCode,
      data: scripted.data,
    );
  }
}
