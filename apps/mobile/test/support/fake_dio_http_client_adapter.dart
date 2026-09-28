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
  /// tenant-config lookup keyed by `slug`).
  (int, Map<String, dynamic>)? Function(RequestOptions options)? handler;

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
    if (scripted == null) {
      return ResponseBody.fromString(
        jsonEncode({'error': 'no scripted response for ${options.path}'}),
        404,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    final (statusCode, body) = scripted;
    return ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
