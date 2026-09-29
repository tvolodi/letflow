/// AC2: "the backpressure test advances a fake clock and asserts the
/// countdown shows 3, 2, 1 and then exactly one retry request is issued --
/// and the app does not throw" (REQ-426). Builds on the AC1 1f setup
/// (design §8's own note that AC2 "may build on 1f's setup") --
/// `tester.pump(const Duration(seconds: 1))` drives `flutter_test`'s fake
/// clock, which intercepts the real `Timer.periodic` inside
/// `BackpressureCountdown` (design §1.4), so no injected clock/delay seam is
/// needed here (unlike `ApiClient`'s own retry backoff, REQ-425).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_error.dart' show BackpressureError;
import 'package:letflow/renderers/list/list.dart';
import 'package:letflow/renderers/renderer_state_view.dart';

import '../support/fake_post_capable_http_gateway.dart';

const String _entityType = 'widgets';
const String _definitionsPath =
    '/api/v1/entities/definitions/active/$_entityType';
const String _queryPath = '/api/v1/entities/query';

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
    'AC2: countdown text reads 3, 2, 1, then the automatic zero-retry '
    'issues exactly one further POST request, with no thrown exception',
    (tester) async {
      final gateway = FakePostCapableHttpGateway()
        ..getResponses[_definitionsPath] = ScriptedResponse(
          data: {
            'definition': {'fields': <Map<String, dynamic>>[]},
          },
        )
        // First POST (Call 2 of loadFirstPage): throttled.
        ..postResponseQueue.add(
          ScriptedResponse(
            error: const BackpressureError(retryAfterSeconds: 3),
          ),
        )
        // Second POST -- the ONE automatic retry `retryLastOperation` (the
        // countdown's `onZero`) issues at zero: succeeds.
        ..postResponseQueue.add(
          ScriptedResponse(data: {'items': <dynamic>[], 'next_cursor': null}),
        );
      final controller = ListRendererController(
        client: gateway,
        entityType: _entityType,
      );

      await tester.pumpWidget(_harness(controller));
      await controller.loadFirstPage(filters: const [], sort: const []);
      await tester.pump();

      // Initial: the countdown text reads the starting value immediately,
      // before any tick (design §1.4's exact tick semantics -- never a
      // pre-decrement "4").
      expect(find.byKey(rendererBackpressureKey), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(gateway.postCalls, hasLength(1));

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('2'), findsOneWidget);
      expect(gateway.postCalls, hasLength(1));

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('1'), findsOneWidget);
      expect(gateway.postCalls, hasLength(1));

      // Third tick: reaches zero. `BackpressureCountdown` cancels its own
      // timer BEFORE calling `onZero` (INV-4), then calls
      // `onRetryBackpressure` (`retryLastOperation`) exactly once.
      await tester.pump(const Duration(seconds: 1));
      // Flushes the awaited retry POST call's microtasks and the resulting
      // `notifyListeners` rebuild.
      await tester.pump();

      expect(
        gateway.postCalls,
        hasLength(2),
        reason: 'exactly one retry request -- not zero, not more than one',
      );
      expect(gateway.postCalls[1].path, _queryPath);
      expect(
        tester.takeException(),
        isNull,
        reason: "onZero's own exceptions must be caught internally and "
            'never left uncaught (design §1.4/AC2)',
      );
      // The controller moved on to `RendererContent` -- the backpressure
      // widget (and its countdown) is gone, not stuck re-showing itself.
      expect(find.byKey(rendererBackpressureKey), findsNothing);
    },
  );
}
