/// The one sanctioned navigation-bootstrap file: this is the single place
/// outside `lib/features/<id>/` permitted to import from inside a
/// feature's tree, because it is the file that reads the installed-module
/// list (`GET /api/v1/me/modules`) and wires the route table accordingly
/// (`docs/mobile/architecture.md` §6, decision `0039` D3, rule 1). Enforced
/// by `test/guards/module_boundary_guard_test.dart`, which special-cases
/// this exact path.
///
/// Also covers tenant slug/deep-link resolution and the app's startup
/// sequence (unauthenticated `tenant-config` fetch, then login) —
/// `docs/mobile/architecture.md` §1. Built starting REQ-421 (MOB-2).
library;

import 'package:flutter/material.dart';
import 'package:flutter_appauth/flutter_appauth.dart'
    show AuthorizationTokenResponse;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/api_client.dart';
import '../api/transport_policy.dart';
import '../auth/auth.dart';
import 'bootstrap_models.dart';
import 'error_screens.dart';

export 'bootstrap_models.dart';
export 'error_screens.dart';

// ── §1. Deep-link / manual-slug tenant-identity resolution ────────────────

/// The build-time platform host — read once, here, and threaded through as
/// a parameter everywhere else (design §1.3, OQ-1).
const String kPlatformHost = String.fromEnvironment(
  'LETFLOW_PLATFORM_HOST',
  defaultValue: '',
);

/// Extracts the tenant slug from an incoming deep-link/App-Link [uri], or
/// `null` if it does not match the expected `https://<slug>.<platformHost>`
/// shape (design §1.1). Never throws — a malformed/foreign URL is a `null`
/// result, not an exception.
@visibleForTesting
String? parseTenantSlugFromDeepLink(Uri uri, {required String platformHost}) {
  if (uri.scheme != 'https') return null;
  if (platformHost.isEmpty) return null;

  final host = uri.host;
  if (host == platformHost) return null;

  final suffix = '.$platformHost';
  if (!host.endsWith(suffix)) return null;

  final prefix = host.substring(0, host.length - suffix.length);
  if (prefix.isEmpty || prefix.contains('.')) return null;

  return prefix;
}

/// Manual-entry screen (design §1.2) — the widget both a resolved
/// deep-link slug and a typed slug ultimately converge on
/// (`runTenantBootstrap`, taking a plain `String`, is the one function
/// both paths call).
class TenantSlugEntryScreen extends ConsumerStatefulWidget {
  const TenantSlugEntryScreen({super.key});

  @override
  ConsumerState<TenantSlugEntryScreen> createState() =>
      _TenantSlugEntryScreenState();
}

class _TenantSlugEntryScreenState extends ConsumerState<TenantSlugEntryScreen> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final slug = _controller.text.trim();
    if (slug.isEmpty) return;
    ref.read(bootstrapControllerProvider).beginBootstrap(slug);
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(bootstrapControllerProvider);
    final isLoading = controller.state.phase == BootstrapPhase.loading;

    return Scaffold(
      key: const Key('tenant-slug-entry-screen'),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter your organization address'),
              TextField(
                key: const Key('tenant-slug-field'),
                controller: _controller,
                enabled: !isLoading,
                decoration: const InputDecoration(hintText: 'acme'),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                key: const Key('tenant-slug-submit'),
                onPressed: isLoading ? null : _submit,
                // Deliberately not an indeterminate `CircularProgressIndicator`
                // here: its perpetual animation would keep
                // `WidgetTester.pumpAndSettle()` from ever settling in the
                // widget tests that drive this screen through a real
                // bootstrap attempt (AC7).
                child: isLoading
                    ? const Text('Signing in…')
                    : const Text('Continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── §5. Post-auth bootstrap orchestration ──────────────────────────────────

/// Runs the full tenant-bootstrap sequence for [enteredSlug] (design §5.2):
/// fetch tenant-config, authenticate via OIDC, store tokens, check
/// memberships (CANDIDATE 403 skips the check), then list installed
/// modules.
///
/// Returns `null` on user cancellation (the caller returns to the
/// slug-entry screen with no error screen shown — cancellation is not one
/// of the four failure states). Otherwise returns a [BootstrapResult].
Future<BootstrapResult?> runTenantBootstrap(
  String enteredSlug, {
  required HttpGateway client,
  required TenantTokenStore tokenStore,
  required ActiveRealmHolder activeRealm,
  AppAuthAdapter appAuthAdapter = const RealAppAuthAdapter(),
  TransportPolicy? transportPolicy,
}) async {
  final TenantConfig config;
  try {
    config = await fetchTenantConfig(enteredSlug, client: client);
  } catch (_) {
    return const BootstrapFailure(BootstrapFailureReason.networkUnavailable);
  }

  // Transport-policy realm_url check (REQ-422 §4.3, MOB-5, AC5) — the
  // `fetchTenantConfig` request above already went through `ApiClient`'s
  // own transport-policy interceptor; this check is additionally required
  // because `authenticateWithTenant`'s OIDC exchange goes through
  // `flutter_appauth`'s native AppAuth SDK, outside Dio entirely, and that
  // interceptor cannot see or block it.
  final effectivePolicy = transportPolicy ?? transportPolicyFor();
  if (!effectivePolicy.isUrlAllowed(Uri.parse(config.realmUrl))) {
    return const BootstrapFailure(BootstrapFailureReason.oidcFailure);
  }

  AuthorizationTokenResponse? tokenResponse;
  try {
    tokenResponse = await authenticateWithTenant(
      config,
      appAuthAdapter: appAuthAdapter,
    );
  } catch (_) {
    return const BootstrapFailure(BootstrapFailureReason.oidcFailure);
  }
  if (tokenResponse == null) {
    // User cancellation — not a failure state (design §5.2 step 2).
    return null;
  }

  final tokens = TokenSet.fromAuthorizationTokenResponse(tokenResponse);
  try {
    await tokenStore.store(config.realmUrl, tokens);
  } catch (_) {
    return const BootstrapFailure(
      BootstrapFailureReason.secureStorageUnavailable,
    );
  }

  // Set as soon as this tenant's own token is stored — *before* this same
  // tenant's own memberships/modules calls (design §5.2 step 4 requires
  // those calls to carry the just-stored bearer token automatically). This
  // is also what keeps a request made after a later tenant's bootstrap
  // begins from ever attaching an earlier tenant's token (design §5.3):
  // the pointer flips the moment the new tenant's token exists, strictly
  // before that new tenant's own tenant-content requests are issued.
  activeRealm.currentRealmUrl = config.realmUrl;

  try {
    final response = await client.get('/api/v1/me/memberships');
    final status = response.statusCode ?? 0;
    if (status == 200) {
      final data = response.data as Map<String, dynamic>;
      final memberships = (data['memberships'] as List<dynamic>)
          .map((e) => MembershipEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      // First-entry-only check (design §5.2 step 4) — never searches the
      // rest of the list even when a later entry does match.
      if (memberships.isEmpty || memberships.first.tenantSlug != enteredSlug) {
        await tokenStore.delete(config.realmUrl);
        activeRealm.currentRealmUrl = null;
        return const BootstrapFailure(BootstrapFailureReason.tenantNotFound);
      }
    } else if (status == 403) {
      // CANDIDATE: membership check not applicable — proceed to modules.
    } else {
      activeRealm.currentRealmUrl = null;
      return const BootstrapFailure(BootstrapFailureReason.networkUnavailable);
    }
  } catch (_) {
    activeRealm.currentRealmUrl = null;
    return const BootstrapFailure(BootstrapFailureReason.networkUnavailable);
  }

  final List<InstalledModule> installedModules;
  try {
    final response = await client.get('/api/v1/me/modules');
    if ((response.statusCode ?? 0) != 200) {
      activeRealm.currentRealmUrl = null;
      return const BootstrapFailure(BootstrapFailureReason.networkUnavailable);
    }
    final data = response.data as Map<String, dynamic>;
    installedModules = (data['installed_modules'] as List<dynamic>)
        .map((e) => InstalledModule.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    activeRealm.currentRealmUrl = null;
    return const BootstrapFailure(BootstrapFailureReason.networkUnavailable);
  }

  return BootstrapSuccess(installedModules: installedModules);
}

// ── §6. Audience scoping: logout / tenant switch ───────────────────────────
//
// REQ-422 §6.3, MOB-5, AC7 — a tenant switch or logout deletes the previous
// tenant's tokens explicitly, so no residual token for a tenant the user is
// no longer authenticated to survives in secure storage.

/// Deletes the active tenant's tokens and clears [activeRealm]. No-op if
/// nothing is currently active.
Future<void> logout({
  required TenantTokenStore tokenStore,
  required ActiveRealmHolder activeRealm,
}) async {
  final currentRealmUrl = activeRealm.currentRealmUrl;
  if (currentRealmUrl == null) return;
  await tokenStore.delete(currentRealmUrl);
  activeRealm.currentRealmUrl = null;
}

/// Switches the active tenant to [enteredSlug] (REQ-422 §6.3, OQ-5).
///
/// Deletes the *previous* tenant's tokens **before** attempting the new
/// tenant's bootstrap — not after it succeeds — so a token for a tenant the
/// user is initiating a switch away from never survives an in-progress or
/// failed switch attempt. If there is no previous tenant at all (first
/// bootstrap of the app session, not a "switch") or the new tenant resolves
/// to the *same* `realm_url` as the previous one (re-authenticating the
/// same tenant), no delete occurs — deleting first would just force a
/// needless token gap for no isolation benefit.
///
/// This is a thin wrapper: the new tenant's own bootstrap sequence (OIDC
/// exchange, membership/module checks) is still entirely
/// [runTenantBootstrap]'s — this function only adds the pre-delete step,
/// which requires resolving the new tenant's `realm_url` via
/// `fetchTenantConfig` once up front to decide whether a delete is even
/// applicable (a same-tenant re-auth is not a switch). If that lookup
/// itself fails, no delete occurs and the failure is surfaced through the
/// normal `runTenantBootstrap` call below (which repeats the same,
/// idempotent, unauthenticated request).
Future<BootstrapResult?> switchTenant(
  String enteredSlug, {
  required HttpGateway client,
  required TenantTokenStore tokenStore,
  required ActiveRealmHolder activeRealm,
  AppAuthAdapter appAuthAdapter = const RealAppAuthAdapter(),
  TransportPolicy? transportPolicy,
}) async {
  final previousRealmUrl = activeRealm.currentRealmUrl;
  if (previousRealmUrl != null) {
    String? newRealmUrl;
    try {
      newRealmUrl = (await fetchTenantConfig(enteredSlug, client: client)).realmUrl;
    } catch (_) {
      newRealmUrl = null;
    }
    if (newRealmUrl != previousRealmUrl) {
      await tokenStore.delete(previousRealmUrl);
      activeRealm.currentRealmUrl = null;
    }
  }
  return runTenantBootstrap(
    enteredSlug,
    client: client,
    tokenStore: tokenStore,
    activeRealm: activeRealm,
    appAuthAdapter: appAuthAdapter,
    transportPolicy: transportPolicy,
  );
}

// Tear-offs of the two top-level functions above, captured at top-level
// scope (not inside `BootstrapController`) so `BootstrapController`'s own
// identically-named `logout()`/`switchTenant(...)` methods can delegate to
// them without an unqualified call inside those methods resolving back to
// `this.logout`/`this.switchTenant` (Dart resolves a bare call to an
// instance member of the same name before falling back to a top-level
// declaration, which would otherwise recurse infinitely).
final Future<void> Function({
  required TenantTokenStore tokenStore,
  required ActiveRealmHolder activeRealm,
})
_logoutTopLevel = logout;

final Future<BootstrapResult?> Function(
  String enteredSlug, {
  required HttpGateway client,
  required TenantTokenStore tokenStore,
  required ActiveRealmHolder activeRealm,
  AppAuthAdapter appAuthAdapter,
  TransportPolicy? transportPolicy,
})
_switchTenantTopLevel = switchTenant;

// ── §5.4. Route table construction ────────────────────────────────────────

/// Builds the tenant-content route list for the currently
/// [installedModules] (design §5.4). A `moduleId` absent from
/// [installedModules] has no route entry at all — not a route that then
/// denies access. REQ-421 ships zero real feature modules, so this
/// function's real-world output is the empty set unless a test fixture
/// supplies a fake installed module and a fake route-registry entry via
/// [registry].
List<RouteBase> buildRouteTable(
  List<InstalledModule> installedModules, {
  Map<String, List<RouteBase>> registry = const {},
}) {
  final routes = <RouteBase>[];
  for (final module in installedModules) {
    final moduleRoutes = registry[module.moduleId];
    if (moduleRoutes != null) {
      routes.addAll(moduleRoutes);
    }
  }
  return routes;
}

// ── Bootstrap UI state + controller ────────────────────────────────────────

enum BootstrapPhase { unauthenticated, loading, success, failure }

@immutable
class BootstrapUiState {
  const BootstrapUiState({
    required this.phase,
    this.installedModules = const [],
    this.failureReason,
  });

  final BootstrapPhase phase;
  final List<InstalledModule> installedModules;
  final BootstrapFailureReason? failureReason;

  static const unauthenticated = BootstrapUiState(
    phase: BootstrapPhase.unauthenticated,
  );
}

/// Drives the router's `refreshListenable`/`redirect` gating (design §5.4)
/// — no tenant-content route is reachable until this notifier's state
/// reaches [BootstrapPhase.success].
class BootstrapController extends ChangeNotifier {
  BootstrapController({
    required this.client,
    required this.tokenStore,
    required this.activeRealm,
    this.appAuthAdapter = const RealAppAuthAdapter(),
  });

  final HttpGateway client;
  final TenantTokenStore tokenStore;
  final ActiveRealmHolder activeRealm;

  /// Real `flutter_appauth` by default; tests construct their own
  /// [BootstrapController] with a [FakeAppAuthAdapter]-equivalent here so
  /// the UI-driven flow (`TenantSlugEntryScreen`'s submit button) never
  /// reaches a real platform channel in `flutter test`.
  final AppAuthAdapter appAuthAdapter;

  BootstrapUiState _state = BootstrapUiState.unauthenticated;
  BootstrapUiState get state => _state;

  Future<void> beginBootstrap(String slug) async {
    _state = const BootstrapUiState(phase: BootstrapPhase.loading);
    notifyListeners();

    final result = await runTenantBootstrap(
      slug,
      client: client,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: appAuthAdapter,
    );

    if (result == null) {
      // Cancellation: silently back to the entry screen.
      _state = BootstrapUiState.unauthenticated;
    } else {
      _state = switch (result) {
        BootstrapSuccess(:final installedModules) => BootstrapUiState(
          phase: BootstrapPhase.success,
          installedModules: installedModules,
        ),
        BootstrapFailure(:final reason) => BootstrapUiState(
          phase: BootstrapPhase.failure,
          failureReason: reason,
        ),
      };
    }
    notifyListeners();
  }

  /// Returns to the slug-entry screen (used by the tenant-not-found
  /// screen's retry action, and by a generic "start over").
  void resetToEntry() {
    _state = BootstrapUiState.unauthenticated;
    notifyListeners();
  }

  /// Switches the active tenant to [slug] (REQ-422 §6.3) — mirrors
  /// [beginBootstrap] but deletes the previous tenant's tokens first via
  /// the top-level [switchTenant] function (called through the
  /// [_switchTenantTopLevel] tear-off — see that variable's doc comment
  /// for why).
  Future<void> switchTenant(String slug) async {
    _state = const BootstrapUiState(phase: BootstrapPhase.loading);
    notifyListeners();

    final result = await _switchTenantTopLevel(
      slug,
      client: client,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: appAuthAdapter,
    );

    if (result == null) {
      _state = BootstrapUiState.unauthenticated;
    } else {
      _state = switch (result) {
        BootstrapSuccess(:final installedModules) => BootstrapUiState(
          phase: BootstrapPhase.success,
          installedModules: installedModules,
        ),
        BootstrapFailure(:final reason) => BootstrapUiState(
          phase: BootstrapPhase.failure,
          failureReason: reason,
        ),
      };
    }
    notifyListeners();
  }

  /// Logs out the active tenant (REQ-422 §6.3) via the top-level [logout]
  /// function (through the [_logoutTopLevel] tear-off), then resets to the
  /// unauthenticated entry state.
  Future<void> logout() async {
    await _logoutTopLevel(tokenStore: tokenStore, activeRealm: activeRealm);
    _state = BootstrapUiState.unauthenticated;
    notifyListeners();
  }
}

// ── Providers ───────────────────────────────────────────────────────────
//
// Declared here (not app.dart) so `TenantSlugEntryScreen` above and
// `app.dart`'s router can both depend on `bootstrapControllerProvider`
// without a circular import. Real production wiring by default; widget
// tests override `bootstrapControllerProvider` (or a lower-level provider
// it depends on) via `ProviderScope(overrides: [...])` at the test root —
// the standard Riverpod testing idiom, not a second wiring path.

final tenantTokenStoreProvider = Provider<TenantTokenStore>((ref) {
  return TenantTokenStore.production();
});

final activeRealmHolderProvider = Provider<ActiveRealmHolder>((ref) {
  return ActiveRealmHolder();
});

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient.create(
    tokenStore: ref.watch(tenantTokenStoreProvider),
    activeRealm: ref.watch(activeRealmHolderProvider),
  );
});

final bootstrapControllerProvider = ChangeNotifierProvider<BootstrapController>(
  (ref) {
    return BootstrapController(
      client: ref.watch(apiClientProvider),
      tokenStore: ref.watch(tenantTokenStoreProvider),
      activeRealm: ref.watch(activeRealmHolderProvider),
    );
  },
);

/// Renders the dedicated screen for [reason] (design §6) — the single
/// dispatch point; never a generic fallback for one of the four named
/// cases.
Widget buildErrorScreen(
  BootstrapFailureReason reason, {
  VoidCallback? onRetry,
}) {
  return switch (reason) {
    BootstrapFailureReason.tenantNotFound => TenantNotFoundScreen(
      onBackToEntry: onRetry,
    ),
    BootstrapFailureReason.networkUnavailable => NetworkUnavailableScreen(
      onRetry: onRetry,
    ),
    BootstrapFailureReason.oidcFailure => OidcFailureScreen(onRetry: onRetry),
    BootstrapFailureReason.secureStorageUnavailable =>
      SecureStorageUnavailableScreen(onRetry: onRetry),
  };
}
