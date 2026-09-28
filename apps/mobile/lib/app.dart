import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'bootstrap/navigation_bootstrap.dart';

/// The one sanctioned "app/router" file (REQ-419 design §3). Defines the
/// top-level app widget and the [GoRouter] instance, gated on
/// `BootstrapController`'s state (REQ-421 design §5.4). The real provider
/// wiring (`ApiClient`, `TenantTokenStore`, `ActiveRealmHolder`,
/// `bootstrapControllerProvider`) lives in `bootstrap/navigation_bootstrap.dart`
/// so both this file's router and that file's own widgets can depend on it
/// without a circular import.
class LetflowApp extends ConsumerWidget {
  const LetflowApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(bootstrapControllerProvider);
    final router = _buildRouter(controller);
    return MaterialApp.router(title: 'Letflow', routerConfig: router);
  }
}

GoRouter _buildRouter(BootstrapController controller) {
  return GoRouter(
    refreshListenable: controller,
    initialLocation: '/',
    redirect: (context, state) {
      final phase = controller.state.phase;
      // No tenant-content route is reachable until bootstrap succeeds
      // (design §5.2/§5.4's ordering invariant).
      if (phase != BootstrapPhase.success && state.matchedLocation != '/') {
        return '/';
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) {
          final uiState = controller.state;
          if (uiState.phase == BootstrapPhase.failure &&
              uiState.failureReason != null) {
            return buildErrorScreen(
              uiState.failureReason!,
              onRetry: controller.resetToEntry,
            );
          }
          return const TenantSlugEntryScreen();
        },
      ),
      // REQ-421 ships zero real feature modules — buildRouteTable's real
      // output is the empty set (design §5.4, OQ-4). A module absent from
      // `installed_modules` has no route entry here, so `GoRouter`'s own
      // default not-found page is shown for it (AC3).
      ...buildRouteTable(controller.state.installedModules),
    ],
  );
}
