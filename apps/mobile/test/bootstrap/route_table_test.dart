// AC3: a module absent from installed_modules has no route at all (not a
// route that then 403s/redirects) — navigating to its path shows the
// not-found screen (REQ-421 design §5.4).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';

void main() {
  final registry = <String, List<RouteBase>>{
    'installed-module': [
      GoRoute(
        path: '/installed',
        builder: (context, state) =>
            const Scaffold(body: Text('installed module content')),
      ),
    ],
    'not-installed-module': [
      GoRoute(
        path: '/not-installed',
        builder: (context, state) =>
            const Scaffold(body: Text('should never be reachable')),
      ),
    ],
  };

  test('buildRouteTable adds a route only for an installed module', () {
    final routes = buildRouteTable(const [
      InstalledModule(moduleId: 'installed-module', version: '1.0.0'),
    ], registry: registry);

    final paths = routes.whereType<GoRoute>().map((r) => r.path).toList();
    expect(paths, contains('/installed'));
    expect(paths, isNot(contains('/not-installed')));
  });

  test('buildRouteTable with no installed modules yields no routes', () {
    expect(buildRouteTable(const [], registry: registry), isEmpty);
  });

  testWidgets(
    'navigating to a path whose module is absent from installed_modules'
    ' shows the not-found screen, never the module\'s own content',
    (tester) async {
      final routes = buildRouteTable(const [
        InstalledModule(moduleId: 'installed-module', version: '1.0.0'),
      ], registry: registry);
      final router = GoRouter(
        initialLocation: '/not-installed',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const Scaffold(body: Text('entry')),
          ),
          ...routes,
        ],
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      expect(find.text('should never be reachable'), findsNothing);
      // go_router's own default "no match" page for an app using
      // MaterialApp is `MaterialErrorScreen` (exported as `ErrorScreen` in
      // some go_router versions) — never this app's own generic content.
      expect(find.text('Page Not Found'), findsWidgets);
    },
  );
}
