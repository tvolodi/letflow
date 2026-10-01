/// AC1 (REQ-427): "one widget test per field type in the SPA's field
/// registry (at minimum the eleven MOB-4 names) renders a schema containing
/// that field and asserts the corresponding input widget by key, and a test
/// asserts an unknown field type yields the stale-version state."
///
/// Each MOB-4 name is exercised against the design's own §1 reconciliation
/// (`lib/letflow/design/req427-form-renderer.md`):
///   - text/number/boolean/date/datetime/select/file: real `FormFieldKind`s,
///     each with a dedicated, keyed widget.
///   - computed/hidden: not `FormFieldKind`s at all -- orthogonal `x-ui`
///     flags any kind may carry (§1.2/§1.3) -- exercised as a `computed`
///     read-only display and a `visible_when`-driven DOM omission,
///     respectively.
///   - multi-select/reference: no wire encoding exists anywhere on the
///     platform (§1 point 5/OQ-1) -- exercised via the SAME unknown-type
///     stale-version case a genuinely-unrecognized type string gets, not a
///     dedicated working widget.
///
/// Drives a hand-built `FormRendererController` directly (never through
/// `buildFormRenderer`'s Riverpod-wired root, which would require a full
/// production `ApiClient`/`PinnedFormResolver` stack) -- mirrors
/// `ListRendererController`'s own test precedent, pumped through
/// `RendererStateView`/`FormRendererBody` so `find.byKey` assertions are
/// real.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/definitions/pinned_form_cache.dart';
import 'package:letflow/definitions/pinned_form_resolver.dart';
import 'package:letflow/expr/expr.dart' show kStaticCapabilities;
import 'package:letflow/renderers/form/form.dart';
import 'package:letflow/renderers/renderer_state.dart';
import 'package:letflow/renderers/renderer_state_view.dart';

import '../../support/fake_post_capable_http_gateway.dart';

const String _taskId = 'task-1';
const String _formId = 'F';
const String _formVersion = '1';
const String _instanceId = 'instance-1';

/// Builds a [FormRendererController] whose pinned schema is already cached
/// under `(formId, formVersion)` -- `load()` therefore makes zero network
/// calls, mirroring `PinnedFormResolver`'s own documented cache-hit contract.
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

/// The exact production composition (`RendererStateView` wrapping
/// `FormRendererBody`), rebuilt on every `controller` notification.
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
  testWidgets('text field renders a keyed text input', (tester) async {
    final controller = await _loadedController({
      'properties': {
        'notes': {'type': 'string', 'title': 'Notes'},
      },
    });
    await tester.pumpWidget(_harness(controller));
    await tester.pump();

    expect(find.byKey(formFieldInputKey('notes')), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(formFieldInputKey('notes'))),
      isA<TextField>(),
    );
  });

  testWidgets('number field renders a keyed numeric text input', (tester) async {
    final controller = await _loadedController({
      'properties': {
        'quantity': {'type': 'number', 'title': 'Quantity'},
      },
    });
    await tester.pumpWidget(_harness(controller));
    await tester.pump();

    final finder = find.byKey(formFieldInputKey('quantity'));
    expect(finder, findsOneWidget);
    expect(
      tester.widget<TextField>(finder).keyboardType,
      TextInputType.number,
    );
  });

  testWidgets('boolean field renders a keyed checkbox', (tester) async {
    final controller = await _loadedController({
      'properties': {
        'agree': {'type': 'boolean', 'title': 'Agree'},
      },
    });
    await tester.pumpWidget(_harness(controller));
    await tester.pump();

    expect(find.byKey(formFieldInputKey('agree')), findsOneWidget);
    expect(
      tester.widget<CheckboxListTile>(find.byKey(formFieldInputKey('agree'))),
      isA<CheckboxListTile>(),
    );
  });

  testWidgets('date field renders a keyed date-picker-backed text input', (
    tester,
  ) async {
    final controller = await _loadedController({
      'properties': {
        'due': {'type': 'date', 'title': 'Due date'},
      },
    });
    await tester.pumpWidget(_harness(controller));
    await tester.pump();

    final finder = find.byKey(formFieldInputKey('due'));
    expect(finder, findsOneWidget);
    expect(tester.widget<TextField>(finder).readOnly, isTrue);
  });

  testWidgets(
    'datetime field (string + format date-time) renders a keyed'
    ' date+time-picker-backed text input',
    (tester) async {
      final controller = await _loadedController({
        'properties': {
          'startsAt': {
            'type': 'string',
            'format': 'date-time',
            'title': 'Starts at',
          },
        },
      });
      await tester.pumpWidget(_harness(controller));
      await tester.pump();

      final finder = find.byKey(formFieldInputKey('startsAt'));
      expect(finder, findsOneWidget);
      expect(tester.widget<TextField>(finder).readOnly, isTrue);
    },
  );

  testWidgets('select field renders a keyed dropdown', (tester) async {
    final controller = await _loadedController({
      'properties': {
        'status': {
          'type': 'select',
          'title': 'Status',
          'enum': ['open', 'closed'],
        },
      },
    });
    await tester.pumpWidget(_harness(controller));
    await tester.pump();

    expect(find.byKey(formFieldInputKey('status')), findsOneWidget);
    expect(
      tester.widget<DropdownButtonFormField<String>>(
        find.byKey(formFieldInputKey('status')),
      ),
      isA<DropdownButtonFormField<String>>(),
    );
  });

  testWidgets(
    'string + non-empty enum (the SPA\'s second select spelling) also'
    ' renders a keyed dropdown',
    (tester) async {
      final controller = await _loadedController({
        'properties': {
          'priority': {
            'type': 'string',
            'title': 'Priority',
            'enum': ['low', 'high'],
          },
        },
      });
      await tester.pumpWidget(_harness(controller));
      await tester.pump();

      expect(find.byKey(formFieldInputKey('priority')), findsOneWidget);
    },
  );

  testWidgets('file field renders a keyed upload control', (tester) async {
    final controller = await _loadedController({
      'properties': {
        'attachment': {'type': 'file', 'title': 'Attachment'},
      },
    });
    await tester.pumpWidget(_harness(controller));
    await tester.pump();

    expect(find.byKey(formFieldInputKey('attachment')), findsOneWidget);
    expect(find.byKey(const Key('form-field-attachment-pick')), findsOneWidget);
  });

  testWidgets(
    'computed field (an orthogonal x-ui flag, not a FormFieldKind) renders'
    ' a keyed read-only display',
    (tester) async {
      final controller = await _loadedController({
        'properties': {
          'total': {
            'type': 'number',
            'title': 'Total',
            'x-ui': {'computed': '2'},
          },
        },
      });
      await tester.pumpWidget(_harness(controller));
      await tester.pump();

      final finder = find.byKey(formFieldInputKey('total'));
      expect(finder, findsOneWidget);
      final textField = tester.widget<TextField>(finder);
      expect(textField.readOnly, isTrue);
      expect(textField.controller?.text, '2');
    },
  );

  testWidgets(
    'hidden field (visible_when evaluating to false -- an orthogonal x-ui'
    ' flag, not a FormFieldKind) is omitted from the widget tree entirely',
    (tester) async {
      final controller = await _loadedController({
        'properties': {
          'secret': {
            'type': 'string',
            'title': 'Secret',
            'x-ui': {'visible_when': 'false'},
          },
        },
      });
      await tester.pumpWidget(_harness(controller));
      await tester.pump();

      // Omitted entirely -- not merely a disabled/invisible widget still in
      // the tree (design §6.4's `return null` semantics).
      expect(find.byKey(formFieldInputKey('secret')), findsNothing);
    },
  );

  testWidgets(
    'multi-select has no wire encoding anywhere on the platform (design'
    ' §1 point 5/OQ-1) -- exercised via the unknown-type stale-version case',
    (tester) async {
      final controller = await _loadedController({
        'properties': {
          'tags': {'type': 'multi-select', 'title': 'Tags'},
        },
      });
      await tester.pumpWidget(_harness(controller));
      await tester.pump();

      expect(find.byKey(rendererStaleVersionKey), findsOneWidget);
      expect(controller.state, isA<RendererStaleVersion<FormViewModel>>());
    },
  );

  testWidgets(
    'reference has no wire encoding anywhere on the platform (design §1'
    ' point 5/OQ-1) -- exercised via the unknown-type stale-version case',
    (tester) async {
      final controller = await _loadedController({
        'properties': {
          'owner': {'type': 'reference', 'title': 'Owner'},
        },
      });
      await tester.pumpWidget(_harness(controller));
      await tester.pump();

      expect(find.byKey(rendererStaleVersionKey), findsOneWidget);
    },
  );

  testWidgets(
    'a genuinely-unrecognized, future field type string yields the'
    ' stale-version state for the WHOLE form (not a per-field skip)',
    (tester) async {
      final controller = await _loadedController({
        'properties': {
          'known': {'type': 'string', 'title': 'Known'},
          'mystery': {'type': 'widget-from-the-future', 'title': 'Mystery'},
        },
      });
      await tester.pumpWidget(_harness(controller));
      await tester.pump();

      expect(find.byKey(rendererStaleVersionKey), findsOneWidget);
      final state = controller.state;
      expect(state, isA<RendererStaleVersion<FormViewModel>>());
      final reason = (state as RendererStaleVersion<FormViewModel>).reason;
      expect(reason, isA<UnknownFieldType>());
      expect((reason as UnknownFieldType).fieldName, 'mystery');
      expect(reason.rawType, 'widget-from-the-future');
      // Not a partial render of the known field either.
      expect(find.byKey(formFieldInputKey('known')), findsNothing);
    },
  );
}
