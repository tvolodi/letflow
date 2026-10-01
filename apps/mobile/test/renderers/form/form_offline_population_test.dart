/// AC2 (REQ-427): "a test renders a cached schema with a visible_when and a
/// computed field, with the network unavailable, changes an input, and
/// asserts the dependent field's visibility and the computed value update
/// (offline form population, D1a)."
///
/// Uses a gateway that throws `NetworkUnavailableError` on every call, so
/// this test also proves the whole load -> render -> edit -> re-evaluate
/// path makes zero network calls end to end -- the structural basis for
/// D1a's "offline-fillable from a cached schema" guarantee.
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/api/api_error.dart';
import 'package:letflow/definitions/pinned_form_cache.dart';
import 'package:letflow/definitions/pinned_form_resolver.dart';
import 'package:letflow/expr/expr.dart' show kStaticCapabilities;
import 'package:letflow/renderers/form/form.dart';
import 'package:letflow/renderers/renderer_state.dart';
import 'package:letflow/renderers/renderer_state_view.dart';

const String _taskId = 'task-1';
const String _formId = 'F';
const String _formVersion = '1';
const String _instanceId = 'instance-1';

/// Throws [NetworkUnavailableError] on every call -- simulates "the network
/// is unavailable" rather than merely "nothing was scripted", and records
/// every attempted call so the test can assert none was ever made.
class _AlwaysNetworkUnavailableGateway implements PostCapableHttpGateway {
  final List<String> calls = [];

  @override
  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    calls.add('GET $path');
    throw const NetworkUnavailableError();
  }

  @override
  Future<Response<dynamic>> getUnauthenticated(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    calls.add('GET(unauth) $path');
    throw const NetworkUnavailableError();
  }

  @override
  Future<Response<dynamic>> post(String path, {Object? data}) async {
    calls.add('POST $path');
    throw const NetworkUnavailableError();
  }
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
    'offline: a cached schema with visible_when + computed loads and'
    ' re-evaluates on every input change, with zero network calls',
    (tester) async {
      final formSchema = {
        'properties': {
          'qty': {'type': 'number', 'title': 'Quantity'},
          'detail': {
            'type': 'string',
            'title': 'Detail',
            'x-ui': {'visible_when': 'qty > 3'},
          },
          'double': {
            'type': 'number',
            'title': 'Double',
            'x-ui': {'computed': 'qty * 2'},
          },
        },
      };

      final repo = InMemoryPinnedFormCacheRepository();
      await repo.putEntry(
        PinnedFormCacheEntry(
          formId: _formId,
          formVersion: _formVersion,
          formSchema: formSchema,
        ),
      );
      final gateway = _AlwaysNetworkUnavailableGateway();
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
      expect(controller.state, isA<RendererContent<FormViewModel>>());
      expect(gateway.calls, isEmpty, reason: 'a cache hit makes zero network calls');

      await tester.pumpWidget(_harness(controller));
      await tester.pump();

      // Seed `qty` once first (the evaluator treats a missing variable as
      // an eval error, not a nil-propagating default -- `expr_evaluator
      // .dart`'s own documented "undefined variable, not nil-propagating"
      // rule, mirroring the server-side grammar exactly), then assert the
      // pre-change state: 1 > 3 is false, 1 * 2 == 2.
      controller.updateFieldValue('qty', 1);
      await tester.pump();

      expect(
        find.byKey(formFieldInputKey('detail')),
        findsNothing,
        reason: 'detail is DefaultHidden while qty <= 3',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(formFieldInputKey('double')))
            .controller
            ?.text,
        '2',
      );

      // Change the input that both expressions depend on.
      controller.updateFieldValue('qty', 5);
      await tester.pump();

      // The dependent field's visibility updates: 5 > 3 is true.
      expect(
        find.byKey(formFieldInputKey('detail')),
        findsOneWidget,
        reason: 'detail becomes DefaultVisible once qty > 3',
      );
      // The computed value updates: 5 * 2 == 10.
      expect(
        tester
            .widget<TextField>(find.byKey(formFieldInputKey('double')))
            .controller
            ?.text,
        '10',
      );

      // The entire load -> render -> edit -> re-evaluate path made zero
      // network calls (D1a's offline-fillable guarantee).
      expect(gateway.calls, isEmpty);
    },
  );
}
