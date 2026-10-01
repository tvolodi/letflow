/// AC3 (REQ-427): "a test asserts an expression REQ-294's evaluator rejects
/// puts the form in stale-version and that the affected field is not
/// rendered visible, not silently hidden, and not rendered blank."
///
/// `now()` is used as the always-unevaluable expression throughout: REQ-294's
/// own grammar deliberately excludes `now`/`date_add`/`date_diff`
/// (`apps/mobile/lib/expr/expr_types.dart`'s own doc comment), so
/// `evaluateExpression('now() > 0', ...)` always fails at the
/// translate/parse stage -- never flaky, never a moving-clock dependency.
///
/// This requirement's fourth visual state (the
/// `ExpressionUnavailableBannerWidget`, keyed distinctly from both "omitted"
/// and "visible normal input") is what AC3's three-way distinction actually
/// rests on: the field's normal `formFieldInputKey` widget is absent (not
/// visible) AND the banner IS present (distinguishing this from the
/// `DefaultHidden` "omitted, no banner at all" case) AND, for the computed
/// sub-case, the banner replaces the read-only display entirely rather than
/// showing an empty control (distinguishing this from `Blank`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/definitions/pinned_form_cache.dart';
import 'package:letflow/definitions/pinned_form_resolver.dart';
import 'package:letflow/expr/expr.dart' show kStaticCapabilities;
import 'package:letflow/renderers/form/form.dart';
import 'package:letflow/renderers/renderer_state_view.dart';

import '../../support/fake_post_capable_http_gateway.dart';

const String _taskId = 'task-1';
const String _formId = 'F';
const String _formVersion = '1';
const String _instanceId = 'instance-1';

Future<FormRendererController> _loadedController(
  Map<String, dynamic> formSchema,
) async {
  final repo = InMemoryPinnedFormCacheRepository();
  await repo.putEntry(
    PinnedFormCacheEntry(
      formId: _formId,
      formVersion: _formVersion,
      formSchema: formSchema,
    ),
  );
  final gateway = FakePostCapableHttpGateway();
  final resolver = PinnedFormResolver(repository: repo, client: gateway);
  final controller = FormRendererController(
    client: gateway,
    pinnedFormResolver: resolver,
    manifestCapabilities: kStaticCapabilities.toList(),
    taskId: _taskId,
    formId: _formId,
    formVersion: _formVersion,
    instanceId: _instanceId,
  );
  await controller.load();
  return controller;
}

Widget _harness(FormRendererController controller) {
  return MaterialApp(
    home: Scaffold(
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => RendererStateView<FormViewModel>(
          state: controller.state,
          contentBuilder: (context, data) =>
              FormRendererBody(controller: controller, viewModel: data),
          onRetryBackpressure: () async {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'visible_when the evaluator rejects: the field is not rendered visible'
    ' (no normal input) and not silently hidden (a banner is shown instead)',
    (tester) async {
      final controller = await _loadedController({
        'properties': {
          'gated': {
            'type': 'string',
            'title': 'Gated',
            'x-ui': {'visible_when': 'now() > 0'},
          },
        },
      });
      await tester.pumpWidget(_harness(controller));
      await tester.pump();

      // Not rendered as a normal visible input.
      expect(find.byKey(formFieldInputKey('gated')), findsNothing);
      // Not silently hidden -- a distinct banner is shown, naming the field
      // and the `visible_when` kind.
      expect(
        find.byKey(expressionUnavailableBannerKey('gated', 'visible_when')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'computed the evaluator rejects: not rendered blank -- the banner'
    ' replaces the read-only display entirely',
    (tester) async {
      final controller = await _loadedController({
        'properties': {
          'total': {
            'type': 'number',
            'title': 'Total',
            'x-ui': {'computed': 'now() + 1'},
          },
        },
      });
      await tester.pumpWidget(_harness(controller));
      await tester.pump();

      // Not rendered as the normal read-only computed-display input.
      expect(find.byKey(formFieldInputKey('total')), findsNothing);
      // Not rendered blank (an empty read-only control) -- the unevaluable
      // banner is shown instead.
      expect(
        find.byKey(expressionUnavailableBannerKey('total', 'computed')),
        findsOneWidget,
      );
      expect(find.text(''), findsNothing);
    },
  );

  testWidgets(
    'cross_field_validation the evaluator rejects: a form-level banner is'
    ' shown, never a silently-passing/failing validation result',
    (tester) async {
      final controller = await _loadedController({
        'properties': {
          'a': {
            'type': 'number',
            'title': 'A',
            'x-ui': {
              'cross_field_validation': {
                'expression': 'now() > a',
                'message': 'a must be in the past',
              },
            },
          },
        },
      });
      await tester.pumpWidget(_harness(controller));
      await tester.pump();

      expect(
        find.byKey(expressionUnavailableBannerKey('a', 'cross_field_validation')),
        findsOneWidget,
      );
      // The field itself still renders normally -- cross-field-unevaluable
      // never suppresses the field's own input.
      expect(find.byKey(formFieldInputKey('a')), findsOneWidget);
    },
  );
}
