// REQ-423 (MOB-3 part 1) AC1: airplane-mode launch. A pre-populated cache
// and an HTTP layer that throws SocketException on every call still lists
// every cached definition (by type, id, version), with no loading-indicator
// widget shown at any pumped frame (design §8.1/§8.3's "eagerly-loaded
// controller, never a FutureBuilder" discipline).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/definitions/definitions.dart';
import 'package:letflow/definitions/tenant_home_screen.dart';

import '../support/fake_http_gateway.dart';
import '../support/load_test_catalogue.dart';

Map<String, dynamic> _deltaItem({
  required String id,
  required String name,
  required int version,
}) {
  return {
    'id': id,
    'name': name,
    'version': version,
    'description': null,
    'status': 'ACTIVE',
    'graph': <String, dynamic>{},
    'created_by': null,
    'created_at': '2026-01-01T00:00:00Z',
    'updated_at': '2026-01-01T00:00:00Z',
    'archived_at': null,
    'stage': null,
  };
}

void _expectNoLoadingIndicatorAnywhere() {
  expect(find.byType(CircularProgressIndicator), findsNothing);
  expect(find.byType(LinearProgressIndicator), findsNothing);
  expect(find.byType(RefreshProgressIndicator), findsNothing);
}

void main() {
  setUpAll(loadTestMessageCatalogue);

  testWidgets(
    'airplane mode: pre-populated cache renders immediately, SocketException'
    ' on every sync call, and no loading indicator appears at any frame',
    (tester) async {
      final repo = InMemoryDefinitionCacheRepository();
      await repo.putAll([
        DefinitionCacheEntry.fromDeltaItem(
          _deltaItem(id: 'd1', name: 'Onboarding', version: 3),
          type: kProcessDefinitionCacheType,
        ),
        DefinitionCacheEntry.fromDeltaItem(
          _deltaItem(id: 'd2', name: 'Expense Approval', version: 1),
          type: kProcessDefinitionCacheType,
        ),
      ]);

      final gateway = FakeHttpGateway()
        ..getResponses['/api/v1/definitions/delta'] = ScriptedResponse(
          error: const SocketException('no route to host'),
        );
      final syncService = DefinitionSyncService(
        repository: repo,
        client: gateway,
      );
      final controller = DefinitionHomeController(
        repository: repo,
        syncService: syncService,
      );
      // Design §8.2/§8.3: loaded and awaited BEFORE the screen is pumped --
      // never inside the screen's own build/initState.
      await controller.loadFromCache();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            definitionHomeControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(home: TenantHomeScreen()),
        ),
      );

      // First frame: cached entries already visible, no spinner.
      expect(find.text('Onboarding'), findsOneWidget);
      expect(find.text('Expense Approval'), findsOneWidget);
      expect(find.textContaining('process · v3'), findsOneWidget);
      expect(find.textContaining('process · v1'), findsOneWidget);
      _expectNoLoadingIndicatorAnywhere();

      // The post-first-frame background sync fires and throws
      // SocketException on every call -- still no spinner at any pumped
      // frame while that resolves.
      await tester.pump();
      _expectNoLoadingIndicatorAnywhere();
      await tester.pumpAndSettle();
      _expectNoLoadingIndicatorAnywhere();

      // The cache the screen already rendered from is untouched by the
      // failed background sync.
      expect(find.text('Onboarding'), findsOneWidget);
      expect(find.text('Expense Approval'), findsOneWidget);
      expect(gateway.calls, hasLength(1));
    },
  );

  testWidgets('an empty cache renders "No definitions yet", never a spinner'
      ' or a blank container', (tester) async {
    final repo = InMemoryDefinitionCacheRepository();
    final gateway = FakeHttpGateway()
      ..getResponses['/api/v1/definitions/delta'] = ScriptedResponse(
        error: const SocketException('no route to host'),
      );
    final syncService = DefinitionSyncService(repository: repo, client: gateway);
    final controller = DefinitionHomeController(
      repository: repo,
      syncService: syncService,
    );
    await controller.loadFromCache();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          definitionHomeControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: TenantHomeScreen()),
      ),
    );

    expect(find.byKey(const Key('tenant-home-empty')), findsOneWidget);
    expect(find.text('No definitions yet'), findsOneWidget);
    _expectNoLoadingIndicatorAnywhere();

    await tester.pumpAndSettle();
    _expectNoLoadingIndicatorAnywhere();
  });
}
