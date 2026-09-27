import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// The one sanctioned "app/router" file (REQ-419 design §3). Defines the
/// top-level app widget and the [GoRouter] instance.
///
/// This requirement (REQ-419, MOB-1 scaffold) ships a single placeholder
/// route only — no auth, no fetch. The real bootstrap sequence (tenant
/// slug resolution, `tenant-config` call, login) is REQ-421's scope
/// (MOB-2).
class LetflowApp extends StatelessWidget {
  const LetflowApp({super.key});

  static final GoRouter _router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const SlugEntryPlaceholderScreen(),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Letflow',
      routerConfig: _router,
    );
  }
}

/// Placeholder for the tenant slug-entry screen. Manual text-entry shape
/// per REQ-419's design (§3, open question 1) — a real bootstrap flow
/// (slug resolution, `tenant-config` fetch, login) is built in REQ-421.
class SlugEntryPlaceholderScreen extends StatelessWidget {
  const SlugEntryPlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text('Letflow — tenant entry (placeholder)'),
      ),
    );
  }
}
