/// Transport policy: whether a given [Uri] may be connected to at all
/// (REQ-422 §4, MOB-5, BUILDS item 3b, AC5). Enforced at two call sites —
/// [ApiClient]'s Dio interceptor chain (`lib/api/api_client.dart`) and
/// `runTenantBootstrap`'s `realm_url` scheme check
/// (`lib/bootstrap/navigation_bootstrap.dart`) — since `flutter_appauth`'s
/// native AppAuth SDK call goes outside Dio entirely and needs its own
/// check.
///
/// A release build permits only `https://`. A debug build additionally
/// permits plain `http://` to the Android emulator's host-loopback alias
/// (`10.0.2.2`) and `localhost`, for a local dev backend.
library;

import 'package:flutter/foundation.dart';

/// Whether a given [Uri] may be connected to under the active build's
/// transport policy.
abstract class TransportPolicy {
  bool isUrlAllowed(Uri url);
}

@immutable
class ReleaseTransportPolicy implements TransportPolicy {
  const ReleaseTransportPolicy();

  @override
  bool isUrlAllowed(Uri url) => url.scheme == 'https';
}

@immutable
class DebugTransportPolicy implements TransportPolicy {
  const DebugTransportPolicy();

  @override
  bool isUrlAllowed(Uri url) {
    if (url.scheme == 'https') return true;
    if (url.scheme != 'http') return false;
    final host = url.host.toLowerCase();
    return host == '10.0.2.2' || host == 'localhost';
  }
}

/// Returns the [TransportPolicy] the active build should enforce.
/// [isRelease] defaults to `kReleaseMode` but is threaded as a parameter
/// (not read a second time internally) so tests can force either branch
/// without a real release build.
TransportPolicy transportPolicyFor({bool isRelease = kReleaseMode}) {
  return isRelease ? const ReleaseTransportPolicy() : const DebugTransportPolicy();
}

/// Thrown/used to signal a transport-policy rejection uniformly across
/// both call sites (the Dio interceptor and the bootstrap realm_url
/// check). Not a `DioException` subtype itself — the Dio call site wraps
/// it into one.
class TransportPolicyRejectedException implements Exception {
  TransportPolicyRejectedException(this.url, {required this.isRelease});

  final Uri url;
  final bool isRelease;

  @override
  String toString() =>
      'TransportPolicyRejectedException: $url is not permitted under the '
      '${isRelease ? 'release' : 'debug'} transport policy';
}
