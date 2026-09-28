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
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';

import '../api/api_client.dart';
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
}) async {
  final TenantConfig config;
  try {
    config = await fetchTenantConfig(enteredSlug, client: client);
  } catch (_) {
    return const BootstrapFailure(BootstrapFailureReason.networkUnavailable);
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
}

// ── Providers ───────────────────────────────────────────────────────────
//
// Declared here (not app.dart) so `TenantSlugEntryScreen` above and
// `app.dart`'s router can both depend on `bootstrapControllerProvider`
// without a circular import. Real production wiring by default; widget
// tests override `bootstrapControllerProvider` (or a lower-level provider
// it depends on) via `ProviderScope(overrides: [...])` at the test root —
// the standard Riverpod testing idiom, not a second wiring path.

final flutterSecureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage();
});

final tenantTokenStoreProvider = Provider<TenantTokenStore>((ref) {
  return TenantTokenStore(ref.watch(flutterSecureStorageProvider));
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
