/// AC1: "six widget tests, one per state ... assert the state's dedicated
/// widget by key" (REQ-426). Each sub-case forces a DIFFERENT
/// `RendererState` variant through `ListRendererController`'s real fetch
/// path against a fake `PostCapableHttpGateway` and asserts the exhaustive
/// `switch` in `RendererStateView.build` (design
/// `req426-mobile-renderer-state-and-list.md` §2.2/§8) actually renders
/// that state's own `Key` -- proving the mapping end-to-end, not just that
/// the sealed type compiles. Per-case forcing mechanism matches design
/// §8's own AC1 resolution map exactly.
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_error.dart';
import 'package:letflow/renderers/list/list.dart';
import 'package:letflow/renderers/renderer_state_view.dart';

import '../support/fake_post_capable_http_gateway.dart';

const String _entityType = 'widgets';
const String _definitionsPath =
    '/api/v1/entities/definitions/active/$_entityType';

Widget _harness(ListRendererController controller) {
  return MaterialApp(
    home: ListenableBuilder(
      listenable: controller,
      builder: (context, _) => RendererStateView<ListPage>(
        state: controller.state,
        contentBuilder: (context, data) =>
            const Text('content', key: Key('content-body')),
        onRetryBackpressure: controller.retryLastOperation,
      ),
    ),
  );
}

void main() {
  testWidgets(
    '1a: loading, forced via an uncompleted future, shows rendererLoadingKey',
    (tester) async {
      final gateway = FakePostCapableHttpGateway()
        ..getResponses[_definitionsPath] = ScriptedResponse.hang();
      final controller = ListRendererController(
        client: gateway,
        entityType: _entityType,
      );

      await tester.pumpWidget(_harness(controller));
      // The GET call never resolves (an uncompleted Future) -- `state`
      // stays `RendererLoading` for the rest of this test. Fire-and-forget
      // is deliberate: nothing ever completes this Future.
      unawaited(controller.loadFirstPage(filters: const [], sort: const []));
      await tester.pump();

      expect(find.byKey(rendererLoadingKey), findsOneWidget);
    },
  );

  testWidgets(
    '1b: fetch-failure, forced via a network ApiError, shows '
    'rendererFetchFailureKey',
    (tester) async {
      final gateway = FakePostCapableHttpGateway()
        ..getResponses[_definitionsPath] = ScriptedResponse(
          error: const NetworkUnavailableError(),
        );
      final controller = ListRendererController(
        client: gateway,
        entityType: _entityType,
      );

      await tester.pumpWidget(_harness(controller));
      await controller.loadFirstPage(filters: const [], sort: const []);
      await tester.pump();

      expect(find.byKey(rendererFetchFailureKey), findsOneWidget);
    },
  );

  testWidgets(
    '1c: permission-denied, forced via a 403 (ForbiddenError), shows '
    'rendererPermissionDeniedKey',
    (tester) async {
      final gateway = FakePostCapableHttpGateway()
        ..getResponses[_definitionsPath] = ScriptedResponse(
          error: const ForbiddenError(),
        );
      final controller = ListRendererController(
        client: gateway,
        entityType: _entityType,
      );

      await tester.pumpWidget(_harness(controller));
      await controller.loadFirstPage(filters: const [], sort: const []);
      await tester.pump();

      expect(find.byKey(rendererPermissionDeniedKey), findsOneWidget);
    },
  );

  testWidgets(
    '1d: stale-version, forced via an unknown definition-layer field type, '
    'shows rendererStaleVersionKey',
    (tester) async {
      final gateway = FakePostCapableHttpGateway()
        ..getResponses[_definitionsPath] = ScriptedResponse(
          data: {
            'definition': {
              'fields': [
                {'name': 'amount', 'type': 'money', 'queried': true},
              ],
            },
          },
        );
      final controller = ListRendererController(
        client: gateway,
        entityType: _entityType,
      );

      await tester.pumpWidget(_harness(controller));
      await controller.loadFirstPage(filters: const [], sort: const []);
      await tester.pump();

      expect(find.byKey(rendererStaleVersionKey), findsOneWidget);
      // "fails loudly" (design §3.3): the whole renderer goes stale-version,
      // and Call 2 must never be issued once Call 1's field interpretation
      // already short-circuited.
      expect(gateway.postCalls, isEmpty);
    },
  );

  testWidgets(
    '1e: validation-error, forced via a 422 with field errors, shows '
    'rendererValidationErrorKey',
    (tester) async {
      final gateway = FakePostCapableHttpGateway()
        ..getResponses[_definitionsPath] = ScriptedResponse(
          error: const ValidationError(
            fieldErrors: [
              ApiFieldError(
                field: 'entity_type',
                constraint: 'unknown',
                message: 'unknown entity type',
              ),
            ],
          ),
        );
      final controller = ListRendererController(
        client: gateway,
        entityType: _entityType,
      );

      await tester.pumpWidget(_harness(controller));
      await controller.loadFirstPage(filters: const [], sort: const []);
      await tester.pump();

      expect(find.byKey(rendererValidationErrorKey), findsOneWidget);
      expect(find.text('unknown entity type'), findsOneWidget);
    },
  );

  testWidgets(
    '1f: backpressure, forced via a 429 with Retry-After 3, shows '
    'rendererBackpressureKey',
    (tester) async {
      final gateway = FakePostCapableHttpGateway()
        ..getResponses[_definitionsPath] = ScriptedResponse(
          data: {
            'definition': {'fields': <Map<String, dynamic>>[]},
          },
        )
        ..postResponseQueue.add(
          ScriptedResponse(
            error: const BackpressureError(retryAfterSeconds: 3),
          ),
        );
      final controller = ListRendererController(
        client: gateway,
        entityType: _entityType,
      );

      await tester.pumpWidget(_harness(controller));
      await controller.loadFirstPage(filters: const [], sort: const []);
      await tester.pump();

      expect(find.byKey(rendererBackpressureKey), findsOneWidget);
    },
  );
}
