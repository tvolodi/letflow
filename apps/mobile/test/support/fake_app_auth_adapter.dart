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

  /// Controllable `refresh` stub (REQ-425 design §5.2/§2.6). Set
  /// [refreshResponse] for a scripted success, or [refreshError] to make
  /// `refresh` throw (simulating a failed refresh — network, `invalid_grant`,
  /// expired refresh token). [refreshCallCount] is what AC1's "exactly one
  /// refresh call" assertion inspects.
  TokenResponse? refreshResponse;
  Object? refreshError;
  TokenRequest? lastRefreshRequest;
  int refreshCallCount = 0;

  /// Test hook (rework of REQ-425 §2, cross-tenant refresh race regression
  /// test): invoked synchronously right as `refresh` is called, BEFORE the
  /// simulated network delay below -- i.e. "while the refresh call is in
  /// flight" from the coordinator's point of view. A test sets this to
  /// mutate an [ActiveRealmHolder] (switchTenant/logout) partway through a
  /// refresh, to assert `_RefreshCoordinator` re-checks the active tenant
  /// after this `await` resumes rather than blindly persisting/retrying
  /// under the realm captured before it.
  void Function()? duringRefresh;

  @override
  Future<TokenResponse> refresh(TokenRequest request) async {
    refreshCallCount += 1;
    lastRefreshRequest = request;
    duringRefresh?.call();
    // A real refresh_token grant is a genuine network round-trip -- it never
    // resolves on the very next microtask. Scheduling on the timer queue
    // here (even a nominal zero-duration one) lets every other
    // microtask-only chain already in flight (e.g. a second concurrent
    // request's own 401 detection and `refreshOnce()` call) run to
    // completion first, which is what makes AC1's "two concurrent 401s
    // share one in-flight refresh" test deterministic rather than a race
    // between this fake's own speed and the second request's.
    await Future.delayed(Duration.zero);
    if (refreshError != null) {
      throw refreshError!;
    }
    return refreshResponse ?? fakeTokenRefreshResponse();
  }
}

/// A minimal successful [TokenResponse] fixture for `refresh` (REQ-425).
TokenResponse fakeTokenRefreshResponse({
  String accessToken = 'refreshed-access-token',
  String? refreshToken = 'refreshed-refresh-token',
  String? idToken = 'refreshed-id-token',
}) {
  return TokenResponse(
    accessToken,
    refreshToken,
    DateTime.now().add(const Duration(hours: 1)),
    idToken,
    'Bearer',
    const ['openid', 'profile', 'email'],
    const {},
  );
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
