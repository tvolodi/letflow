/// Auth: OIDC Authorization-Code + PKCE via `flutter_appauth`, with tokens
/// stored exclusively in OS-secure storage (`flutter_secure_storage`) —
/// `docs/mobile/architecture.md` §2, `MOB-5`'s security invariant. Built
/// starting REQ-421 (MOB-2).
///
/// This is the ONLY storage path for tokens anywhere in the app —
/// [TenantTokenStore] is the sole class that calls into
/// `flutter_secure_storage`. No plain-preferences fallback exists.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/api_client.dart' show TenantConfig;

/// Matches the Keycloak client's sole registered `redirectUris` entry
/// (REQ-418 §1.1) — literal, fixed, never derived from tenant config.
const String kOidcRedirectUrl = 'com.bizdala.letflow:/oauth2redirect';

/// Platform-default scope set (design §3.1, OQ-2) — no tenant-specific
/// scope.
const List<String> kOidcScopes = ['openid', 'profile', 'email'];

@immutable
class TokenSet {
  const TokenSet({
    required this.accessToken,
    required this.refreshToken,
    required this.idToken,
    required this.accessTokenExpiration,
  });

  final String accessToken;
  final String? refreshToken;
  final String? idToken;
  final DateTime? accessTokenExpiration;

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'id_token': idToken,
    'access_token_expiration': accessTokenExpiration?.toIso8601String(),
  };

  factory TokenSet.fromJson(Map<String, dynamic> json) {
    final expirationRaw = json['access_token_expiration'] as String?;
    return TokenSet(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      idToken: json['id_token'] as String?,
      accessTokenExpiration: expirationRaw == null
          ? null
          : DateTime.parse(expirationRaw),
    );
  }

  factory TokenSet.fromAuthorizationTokenResponse(
    AuthorizationTokenResponse response,
  ) {
    final accessToken = response.accessToken;
    if (accessToken == null) {
      throw StateError(
        'AuthorizationTokenResponse carried no accessToken on a '
        'non-cancelled, non-throwing result',
      );
    }
    return TokenSet(
      accessToken: accessToken,
      refreshToken: response.refreshToken,
      idToken: response.idToken,
      accessTokenExpiration: response.accessTokenExpirationDateTime,
    );
  }
}

/// The one token-store class (REQ-421 design §4). Keyed by `realmUrl`, not
/// the entered slug — the secure-storage key is derived from the
/// backend-verified `realm_url`, never the user-claimed slug, which is
/// what keeps tenant B's calls from ever carrying tenant A's token even
/// when two different unresolvable slugs both fall back to the same
/// default realm (REQ-124's anti-enumeration behavior).
///
/// REQ-422 hardens/guards this same class (key rotation, biometric gate,
/// tamper detection) — not designed or implemented here.
class TenantTokenStore {
  const TenantTokenStore(this._storage);

  final FlutterSecureStorage _storage;

  static String _keyFor(String realmUrl) => 'letflow.tenant_tokens.$realmUrl';

  /// A thrown [PlatformException] from the underlying secure storage
  /// (Keystore/Keychain unavailable) propagates — the caller is
  /// responsible for catching it and routing to
  /// `SecureStorageUnavailableScreen`.
  Future<void> store(String realmUrl, TokenSet tokens) {
    return _storage.write(
      key: _keyFor(realmUrl),
      value: jsonEncode(tokens.toJson()),
    );
  }

  Future<TokenSet?> read(String realmUrl) async {
    final raw = await _storage.read(key: _keyFor(realmUrl));
    if (raw == null) return null;
    return TokenSet.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> delete(String realmUrl) {
    return _storage.delete(key: _keyFor(realmUrl));
  }
}

/// Fake-adapter seam for `flutter_appauth` (REQ-421 design §3.2) — the
/// widget/unit tests plug a fake implementation in here instead of driving
/// a real Custom Tab / native AppAuth SDK.
abstract class AppAuthAdapter {
  Future<AuthorizationTokenResponse?> authorizeAndExchangeCode(
    AuthorizationTokenRequest request,
  );
}

/// Production wrapper around the real `flutter_appauth` plugin.
///
/// **Package-version note:** the design (§3.1) describes
/// `authorizeAndExchangeCode` returning `null` on user cancellation. The
/// pinned `flutter_appauth: ^12.1.0` (`pubspec.yaml`) instead *throws*
/// `FlutterAppAuthUserCancelledException` on cancellation — its
/// `authorizeAndExchangeCode` returns a non-nullable
/// `Future<AuthorizationTokenResponse>`. This adapter absorbs exactly that
/// one exception type and returns `null`, so [AppAuthAdapter]'s
/// null-on-cancel contract (and therefore `authenticateWithTenant`'s own)
/// holds regardless of which mechanism this exact dependency version uses
/// to signal it. Every other exception (a genuine OIDC-protocol failure)
/// propagates unmodified.
class RealAppAuthAdapter implements AppAuthAdapter {
  const RealAppAuthAdapter();

  @override
  Future<AuthorizationTokenResponse?> authorizeAndExchangeCode(
    AuthorizationTokenRequest request,
  ) async {
    try {
      return await const FlutterAppAuth().authorizeAndExchangeCode(request);
    } on FlutterAppAuthUserCancelledException {
      return null;
    }
  }
}

/// Runs the OIDC Authorization-Code + PKCE flow for [config] (design §3.1).
/// `clientId`/`issuer` are sourced from [config] — **never** a compiled
/// Dart constant. PKCE is S256, `flutter_appauth`'s own default behavior
/// for `AuthorizationTokenRequest` (no explicit code-verifier/challenge
/// construction here — the package generates and validates it internally;
/// `AuthorizationTokenRequest`'s constructor does not even accept a
/// `codeVerifier` parameter, unlike the lower-level `TokenRequest` it
/// extends, which is this app's proof that no explicit PKCE override is
/// possible at this call site).
///
/// Returns `null` on user cancellation. Lets any other exception from
/// [appAuthAdapter] (a genuine OIDC-protocol failure) propagate — the
/// caller (`runTenantBootstrap`) is responsible for catching it and
/// routing to `OidcFailureScreen`.
///
/// **`allowInsecureConnections`:** derived from `config.realmUrl`'s own
/// scheme, never hardcoded — the native AppAuth SDK (Android) refuses a
/// plain-`http` issuer/discovery connection unless this flag is set
/// (`only https connections are permitted`, `DefaultConnectionBuilder`).
/// Setting it based on the disclosed `realm_url`'s own scheme grants no
/// *new* trust: the client already only ever connects to whatever URL the
/// tenant-config response specified, over whatever scheme that response
/// specified. A real deployment's `realm_url` is always `https://`, so
/// this is `false` in production; only a local/dev backend that discloses
/// an `http://` realm (e.g. a local Keycloak with no TLS in front of it)
/// makes this `true`.
Future<AuthorizationTokenResponse?> authenticateWithTenant(
  TenantConfig config, {
  AppAuthAdapter appAuthAdapter = const RealAppAuthAdapter(),
}) {
  final allowInsecureConnections =
      Uri.tryParse(config.realmUrl)?.scheme != 'https';
  final request = AuthorizationTokenRequest(
    config.clientId,
    kOidcRedirectUrl,
    issuer: config.realmUrl,
    scopes: kOidcScopes,
    allowInsecureConnections: allowInsecureConnections,
  );
  return appAuthAdapter.authorizeAndExchangeCode(request);
}
