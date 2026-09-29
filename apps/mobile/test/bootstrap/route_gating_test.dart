// AC3 clause 1: "no tenant content route is reachable before /me/memberships
// and /me/modules have both resolved" -- i.e. before BootstrapController's
// phase reaches BootstrapPhase.success. Unlike route_table_test.dart (which
// covers clause 2: an uninstalled module has no route entry at all), this
// test drives the *real* LetflowApp / _buildRouter wiring in app.dart and
// exercises its actual `redirect` closure -- it does not reimplement that
// closure against a bare GoRouter.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/app.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';
import 'package:letflow/definitions/definitions.dart';

import '../support/fake_app_auth_adapter.dart';

/// An [HttpGateway] whose `getUnauthenticated` call never completes, so a
/// [BootstrapController] that calls `beginBootstrap` against it is pinned in
/// [BootstrapPhase.loading] for the lifetime of the test -- no scripted
/// response is ever needed, and nothing ever resolves it.
class _HangingHttpGateway implements HttpGateway {
  @override
  Future<Response<dynamic>> getUnauthenticated(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) {
    return Completer<Response<dynamic>>().future;
  }

  @override
  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) {
    return Completer<Response<dynamic>>().future;
  }
}

/// Attempts to navigate the real router (reached via `GoRouter.of`, the
/// standard go_router lookup, off a [BuildContext] found in the currently
/// rendered tree) to [path], then pumps once so any redirect the router's
/// `redirect` closure issues has a frame to take effect.
Future<void> _attemptNavigation(WidgetTester tester, String path) async {
  final context = tester.element(
    find.byKey(const Key('tenant-slug-entry-screen')),
  );
  GoRouter.of(context).go(path);
  await tester.pump();
}

void main() {
  testWidgets(
    'BootstrapPhase.unauthenticated: navigating to a non-root path stays'
    ' gated at the entry screen -- the redirect sends it back to /',
    (tester) async {
      final controller = BootstrapController(
        client: _HangingHttpGateway(),
        tokenStore: const TenantTokenStore(FlutterSecureStorage()),
        activeRealm: ActiveRealmHolder(),
        definitionCache: ActiveDefinitionCacheHolder(),
        cacheOpener: (_) async => InMemoryDefinitionCacheRepository(),
        appAuthAdapter: FakeAppAuthAdapter(response: fakeTokenResponse()),
      );
      // Default state, per BootstrapController's field initializer, is
      // BootstrapUiState.unauthenticated -- no submit needed to reach it.
      expect(controller.state.phase, BootstrapPhase.unauthenticated);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bootstrapControllerProvider.overrideWith((ref) => controller),
          ],
          child: const LetflowApp(),
        ),
      );

      await _attemptNavigation(tester, '/some-tenant-content-path');

      // Never go_router's own unmatched-route page: that would mean the
      // redirect never ran at all and the request fell through to route
      // matching instead of being sent back to '/' first.
      expect(find.text('Page Not Found'), findsNothing);
      // Still gated at the entry screen, not any tenant content.
      expect(find.byKey(const Key('tenant-slug-entry-screen')), findsOneWidget);
      expect(controller.state.phase, BootstrapPhase.unauthenticated);
    },
  );

  testWidgets(
    'BootstrapPhase.loading (mid-bootstrap, before /me/memberships and'
    ' /me/modules resolve): navigating to a non-root path is redirected'
    ' back to / rather than rendering anything else',
    (tester) async {
      final controller = BootstrapController(
        client: _HangingHttpGateway(),
        tokenStore: const TenantTokenStore(FlutterSecureStorage()),
        activeRealm: ActiveRealmHolder(),
        definitionCache: ActiveDefinitionCacheHolder(),
        cacheOpener: (_) async => InMemoryDefinitionCacheRepository(),
        appAuthAdapter: FakeAppAuthAdapter(response: fakeTokenResponse()),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bootstrapControllerProvider.overrideWith((ref) => controller),
          ],
          child: const LetflowApp(),
        ),
      );

      // Kick off bootstrap against the hanging gateway and pump exactly
      // once: beginBootstrap sets phase to loading and calls
      // notifyListeners() synchronously, *before* it awaits the (never
      // resolving) tenant-config fetch, so one pump is enough to observe
      // the loading phase and nothing ever advances it further.
      unawaited(controller.beginBootstrap('acme'));
      await tester.pump();
      expect(controller.state.phase, BootstrapPhase.loading);

      await _attemptNavigation(tester, '/some-tenant-content-path');

      expect(find.text('Page Not Found'), findsNothing);
      expect(find.byKey(const Key('tenant-slug-entry-screen')), findsOneWidget);
      // Still stuck in loading -- the hanging gateway never resolves, and
      // the navigation attempt itself must not have changed the phase.
      expect(controller.state.phase, BootstrapPhase.loading);
    },
  );
}
