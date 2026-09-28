/// Fake [AppAuthAdapter] test double (REQ-421 design §3.2). Records the
/// [AuthorizationTokenRequest] built for the most recent call, and returns
/// (or throws) a caller-scripted result.
library;

import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:letflow/auth/auth.dart';

class FakeAppAuthAdapter implements AppAuthAdapter {
  FakeAppAuthAdapter({this.response, this.error});

  /// Set to `null` to simulate user cancellation.
  AuthorizationTokenResponse? response;

  /// If set, `authorizeAndExchangeCode` throws this instead.
  Object? error;

  AuthorizationTokenRequest? lastRequest;
  int callCount = 0;

  @override
  Future<AuthorizationTokenResponse?> authorizeAndExchangeCode(
    AuthorizationTokenRequest request,
  ) async {
    callCount += 1;
    lastRequest = request;
    if (error != null) {
      throw error!;
    }
    return response;
  }
}

/// A minimal successful [AuthorizationTokenResponse] fixture.
AuthorizationTokenResponse fakeTokenResponse({
  String accessToken = 'fake-access-token',
  String? refreshToken = 'fake-refresh-token',
  String? idToken = 'fake-id-token',
}) {
  return AuthorizationTokenResponse(
    accessToken,
    refreshToken,
    DateTime.now().add(const Duration(hours: 1)),
    idToken,
    'Bearer',
    const ['openid', 'profile', 'email'],
    const {},
    const {},
  );
}
