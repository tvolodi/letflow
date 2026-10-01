/// AC4/AC5 (REQ-427):
///
/// AC4: "a test asserts a submit with the network unavailable shows
/// network-unavailable, keeps the typed values in the form, and persists
/// nothing to any store (no write queue)."
///
/// AC5: "a test asserts that when on-device validation passes, submit still
/// sends the request to the server with the user-entered values in the
/// body, and that a 422 returned by the server is rendered as the
/// validation-error state even though the on-device validation passed
/// (server authority, REQ-292; POST /api/v1/tasks/:id/complete returns no
/// field values, so the client never re-derives authority from its own
/// computed values)."
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_error.dart';
import 'package:letflow/definitions/pinned_form_cache.dart';
import 'package:letflow/definitions/pinned_form_resolver.dart';
import 'package:letflow/expr/expr.dart' show kStaticCapabilities;
import 'package:letflow/renderers/form/form.dart';
import 'package:letflow/renderers/renderer_state.dart';
import 'package:letflow/renderers/renderer_state_view.dart';

import '../../support/counting_pinned_form_cache_repository.dart';
import '../../support/fake_post_capable_http_gateway.dart';

const String _taskId = 'task-1';
const String _formId = 'F';
const String _formVersion = '1';
const String _instanceId = 'instance-1';
const String _completePath = '/api/v1/tasks/$_taskId/complete';

Future<({
  FormRendererController controller,
  InMemoryPinnedFormCacheRepository repo,
  CountingPinnedFormCacheRepository countingRepo,
  FakePostCapableHttpGateway gateway,
})>
_loadedController(Map<String, dynamic> formSchema) async {
  final repo = InMemoryPinnedFormCacheRepository();
  await repo.putEntry(
    PinnedFormCacheEntry(
      formId: _formId,
      formVersion: _formVersion,
      formSchema: formSchema,
    ),
  );
  // Wrapped in a counting spy so AC4 can assert *zero* `putEntry` calls
  // happen during a network-unavailable submit -- a pre-seeded
  // `getByKey` returning non-null proves nothing about writes performed
  // during `submit()` itself.
  final countingRepo = CountingPinnedFormCacheRepository(repo);
  final gateway = FakePostCapableHttpGateway();
  final resolver = PinnedFormResolver(repository: countingRepo, client: gateway);
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
  return (
    controller: controller,
    repo: repo,
    countingRepo: countingRepo,
    gateway: gateway,
  );
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
    'AC4: submit with the network unavailable shows network-unavailable,'
    ' keeps typed values in the form, and persists nothing to any store',
    (tester) async {
      final built = await _loadedController({
        'properties': {
          'note': {'type': 'string', 'title': 'Note'},
        },
      });
      final controller = built.controller;
      final gateway = built.gateway;
      final repo = built.repo;
      final countingRepo = built.countingRepo;

      await tester.pumpWidget(_harness(controller));
      await tester.pump();

      await tester.enterText(find.byKey(formFieldInputKey('note')), 'hello');
      await tester.pump();

      gateway.postResponseQueue.add(
        ScriptedResponse(error: const NetworkUnavailableError()),
      );

      // Snapshot immediately before the submit attempt -- `load()` may
      // itself have already resolved/cached the pinned form earlier, and
      // that's not what AC4(c) is about.
      final putCallCountBeforeSubmit = countingRepo.putCallCount;

      await tester.tap(find.byKey(formSubmitButtonKey));
      await tester.pump();

      expect(find.byKey(formSubmitNetworkUnavailableKey), findsOneWidget);

      // The typed value survives the failed submit -- visually and in the
      // controller's own live `values` map.
      expect(find.text('hello'), findsOneWidget);
      final vm = (controller.state as RendererContent<FormViewModel>).data;
      expect(vm.values['note'], 'hello');

      // Nothing new was persisted to the pinned-form cache (the only store
      // this controller has any handle to) -- no write-queue entry exists
      // anywhere for this controller (MOB-8). Real proof: zero `putEntry`
      // calls happened during the submit attempt itself -- not merely that
      // the pre-seeded entry is still present, which would be true whether
      // or not `submit()` wrote anything.
      expect(countingRepo.putCallCount, putCallCountBeforeSubmit);
      final cached = await repo.getByKey(_formId, _formVersion);
      expect(cached, isNotNull);

      expect(gateway.postCalls, hasLength(1), reason: 'exactly one attempted submit');
    },
  );

  testWidgets(
    'AC5: on-device validation passing does not stop the request from'
    ' being sent with the entered values; a 422 still renders as'
    ' validation-error',
    (tester) async {
      final built = await _loadedController({
        'properties': {
          'name': {
            'type': 'string',
            'title': 'Name',
            'x-ui': {
              'cross_field_validation': {
                'expression': 'true',
                'message': 'unreachable -- always passes',
              },
            },
          },
        },
      });
      final controller = built.controller;
      final gateway = built.gateway;

      await tester.pumpWidget(_harness(controller));
      await tester.pump();

      await tester.enterText(find.byKey(formFieldInputKey('name')), 'Alice');
      await tester.pump();

      // On-device cross-field validation passed (no error row rendered).
      expect(find.byKey(crossFieldErrorKey('name')), findsNothing);

      gateway.postResponseQueue.add(
        ScriptedResponse(
          error: const ValidationError(
            fieldErrors: [
              ApiFieldError(
                field: 'name',
                constraint: 'required',
                message: 'name is required',
              ),
            ],
          ),
        ),
      );

      await tester.tap(find.byKey(formSubmitButtonKey));
      await tester.pump();

      // The request was sent regardless of the (passing) on-device check,
      // carrying the user-entered value verbatim.
      expect(gateway.postCalls, hasLength(1));
      expect(gateway.postCalls.single.path, _completePath);
      expect(gateway.postCalls.single.data, {'name': 'Alice'});

      // The server's 422 wins over the client's own passing check.
      expect(find.byKey(formSubmitValidationErrorKey), findsOneWidget);
      expect(find.text('name is required'), findsOneWidget);
    },
  );

  testWidgets(
    'AC5 (success path): a successful complete response carries no field'
    ' values the client could re-derive authority from',
    (tester) async {
      final built = await _loadedController({
        'properties': {
          'name': {'type': 'string', 'title': 'Name'},
        },
      });
      final controller = built.controller;
      final gateway = built.gateway;

      await tester.pumpWidget(_harness(controller));
      await tester.pump();

      await tester.enterText(find.byKey(formFieldInputKey('name')), 'Bob');
      await tester.pump();

      gateway.postResponseQueue.add(
        ScriptedResponse(
          statusCode: 200,
          data: {
            'task_id': _taskId,
            'instance_id': _instanceId,
            'instance_status': 'ACTIVE',
            'current_nodes': ['node-2'],
            // The real server response's "variables" key -- SubmitSuccess
            // has structurally no field for it (INV-5); this test merely
            // proves a response carrying it does not crash or get echoed
            // back into the form.
            'variables': {'name': 'SERVER OVERRIDE'},
            'completed_at': '2026-01-01T00:00:00Z',
          },
        ),
      );

      await tester.tap(find.byKey(formSubmitButtonKey));
      await tester.pump();

      expect(find.byKey(formSubmitSuccessKey), findsOneWidget);
      // The form's own displayed value is never overwritten from the
      // response body's "variables" echo.
      expect(find.text('Bob'), findsOneWidget);
    },
  );
}
