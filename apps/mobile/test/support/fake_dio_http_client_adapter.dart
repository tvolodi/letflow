/// Fake `HttpClientAdapter` (Dio's own transport-layer seam) — used by the
/// one test (REQ-421 AC1) that must prove, at the real `Dio`/interceptor
/// level, that the tenant-config request carries no `Authorization`
/// header. Records every request's headers and path, and returns a
/// caller-scripted JSON body.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

class RecordedRequest {
  RecordedRequest({required this.path, required this.headers});

  final String path;
  final Map<String, dynamic> headers;
}

class FakeDioHttpClientAdapter implements HttpClientAdapter {
  final List<RecordedRequest> requests = [];

  /// `path -> (statusCode, jsonBody)`.
  final Map<String, (int, Map<String, dynamic>)> responses = {};

  /// Overrides [responses] when non-null — lets a test script a response
  /// that also depends on the request's query parameters (e.g. a
  /// tenant-config lookup keyed by `slug`), or a response that varies
  /// across successive calls to the same path (REQ-425 — e.g. 401-then-200,
  /// 503-then-503-then-200).
  (int, Map<String, dynamic>)? Function(RequestOptions options)? handler;

  /// Additional response headers for the next `fetch` call (REQ-425 —
  /// e.g. `Retry-After`). Merged on top of the default `content-type`
  /// header; does not persist across calls unless the test re-sets it.
  Map<String, List<String>> Function(RequestOptions options)? headersFor;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(
      RecordedRequest(path: options.path, headers: Map.of(options.headers)),
    );
    final scripted = handler?.call(options) ?? responses[options.path];
    final extraHeaders = headersFor?.call(options) ?? const {};
    if (scripted == null) {
      return ResponseBody.fromString(
        jsonEncode({'error': 'no scripted response for ${options.path}'}),
        404,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
          ...extraHeaders,
        },
      );
    }
    final (statusCode, body) = scripted;
    return ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        ...extraHeaders,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
