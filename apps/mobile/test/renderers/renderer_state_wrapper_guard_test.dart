/// AC4: "a guard or test asserts every renderer under
/// lib/renderers/{form,list,process,task}/ that exists at this point is
/// wrapped by the shared state wrapper (e.g. by type check in a widget test
/// for each)" (REQ-426).
///
/// `form/`, `process/`, `task/` are still placeholder libraries as of
/// REQ-426 (design §0/§4 item 2 -- REQ-427/428's scope) -- `_probes` below
/// is the explicit registry the design's own §4 item 2 asks TEST-DESIGNER
/// to maintain, so this file iterates the actual non-placeholder renderer
/// entries rather than hardcoding "there are 4 renderers." When REQ-427
/// builds the form renderer, or REQ-428 builds process/task, each adds one
/// more entry to `_probes` (its own `buildXRenderer` + a
/// `find.byType(RendererStateView<ItsOwnPageType>)` finder) -- this test's
/// body and its `for` loop need no other change to extend coverage to it
/// (INV-3's structural check: "no renderer ever calls ApiClient/HttpGateway
/// and inspects the thrown ApiError itself" is exactly what "wrapped by
/// RendererStateView at the root" verifies mechanically).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/definitions/pinned_form_cache.dart';
import 'package:letflow/definitions/pinned_form_resolver.dart';
import 'package:letflow/expr/expr.dart' show kStaticCapabilities;
import 'package:letflow/renderers/form/form.dart';
import 'package:letflow/renderers/list/list.dart';
import 'package:letflow/renderers/process/process.dart';
import 'package:letflow/renderers/renderer_state_view.dart';
import 'package:letflow/renderers/task/task.dart';

import '../support/fake_post_capable_http_gateway.dart';

typedef _RendererProbe = ({
  String definitionType,
  Widget Function(BuildContext, Map<String, dynamic>) builder,
  Map<String, dynamic> definition,
  Finder Function() findStateView,
});

/// One entry per non-placeholder renderer that exists today. See this
/// file's own doc comment above for how a future requirement extends this
/// list rather than rewriting the test.
final List<_RendererProbe> _probes = [
  (
    definitionType: 'list',
    builder: buildListRenderer,
    definition: const {'entity_type': 'widgets'},
    findStateView: () => find.byType(RendererStateView<ListPage>),
  ),
  (
    definitionType: 'form',
    builder: buildFormRenderer,
    definition: const {
      'task_id': 'task-1',
      'form_id': 'F',
      'form_version': '1',
      'instance_id': 'instance-1',
    },
    findStateView: () => find.byType(RendererStateView<FormViewModel>),
  ),
  (
    definitionType: 'task',
    builder: buildTaskRenderer,
    definition: const {'task_id': 'task-1'},
    findStateView: () => find.byType(RendererStateView<TaskDetail>),
  ),
  (
    definitionType: 'process',
    builder: buildProcessRenderer,
    definition: const {'instance_id': 'instance-1'},
    findStateView: () => find.byType(RendererStateView<InstanceDetail>),
  ),
];

void main() {
  for (final probe in _probes) {
    testWidgets(
      "AC4: the '${probe.definitionType}' renderer's root widget is "
      'wrapped by RendererStateView, never a raw FutureBuilder/Consumer '
      'bypassing it',
      (tester) async {
        // Loading forever is enough -- AC4 is about widget STRUCTURE (which
        // widget sits at the root), not about a real fetch completing.
        // RendererStateView renders something (the loading branch) for
        // every one of its seven states, so this holds regardless of
        // fetch outcome.
        final gateway = FakePostCapableHttpGateway()
          ..getResponses['/api/v1/entities/definitions/active/widgets'] =
              ScriptedResponse.hang()
          ..getResponses['/api/v1/tasks/task-1'] = ScriptedResponse.hang()
          ..getResponses['/api/v1/instances/instance-1'] = ScriptedResponse.hang()
          ..getResponses['/api/v1/instances/instance-1/timeline'] =
              ScriptedResponse.hang();

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              listRendererControllerProvider.overrideWith(
                (ref, entityType) => ListRendererController(
                  client: gateway,
                  entityType: entityType,
                ),
              ),
              formRendererControllerProvider.overrideWith(
                (ref, params) => FormRendererController(
                  client: gateway,
                  pinnedFormResolver: PinnedFormResolver(
                    repository: InMemoryPinnedFormCacheRepository(),
                    client: gateway,
                  ),
                  manifestCapabilities: kStaticCapabilities.toList(),
                  taskId: params.taskId,
                  formId: params.formId,
                  formVersion: params.formVersion,
                  instanceId: params.instanceId,
                ),
              ),
              taskDetailControllerProvider.overrideWith(
                (ref, taskId) =>
                    TaskDetailController(client: gateway, taskId: taskId),
              ),
              instanceDetailControllerProvider.overrideWith(
                (ref, instanceId) => InstanceDetailController(
                  client: gateway,
                  instanceId: instanceId,
                ),
              ),
            ],
            child: MaterialApp(
              home: Builder(
                builder: (context) => probe.builder(context, probe.definition),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(
          probe.findStateView(),
          findsOneWidget,
          reason:
              "${probe.definitionType}'s own top-level entry-point widget "
              'must return exactly one RendererStateView instance as the '
              'outermost widget of its build (design §4, INV-3)',
        );
      },
    );
  }

  test(
    'AC4 sanity: the probe list actually covers every non-placeholder '
    'renderer directory today',
    () {
      // This does NOT compare two hardcoded literals against each other --
      // it reads the real files on disk under lib/renderers/{form,process,
      // task}/ and fails loudly if any of them has grown past the
      // placeholder shape without a corresponding probe being added above.
      //
      // Mechanism: every placeholder library (form.dart/process.dart/
      // task.dart, as of REQ-426) shares the literal marker string below in
      // its doc comment, verbatim -- see each file for the sentence this
      // was copied from. A file is "still a placeholder" iff it still
      // contains that marker. This is deliberately NOT a line-count or
      // byte-size check (fragile -- a reformat or an added comment would
      // trip it for no reason); the marker is the one thing a placeholder
      // file and a real-logic file cannot both plausibly contain, because
      // the sentence explicitly asserts "no logic yet."
      //
      // For REQ-427/REQ-428 authors: when you replace one of these
      // placeholder files with real renderer logic, delete this marker
      // sentence as part of that change (it stops being true). Doing so is
      // exactly what turns this assertion red -- which is the point: it
      // forces you to also add that renderer's entry to `_probes` above
      // before this test (and thus `flutter test`) goes green again.
      const placeholderMarker = 'it carries no logic yet';
      const placeholderFiles = {
        'form': 'lib/renderers/form/form.dart',
        'process': 'lib/renderers/process/process.dart',
        'task': 'lib/renderers/task/task.dart',
      };

      final probedTypes = _probes.map((p) => p.definitionType).toSet();

      for (final entry in placeholderFiles.entries) {
        final definitionType = entry.key;
        final file = File(entry.value);
        expect(
          file.existsSync(),
          isTrue,
          reason:
              '${entry.value} is expected to exist (as either the '
              'placeholder or the real renderer) -- if it moved/was '
              'renamed, update placeholderFiles above alongside it.',
        );

        final stillPlaceholder = file
            .readAsStringSync()
            .contains(placeholderMarker);

        if (!stillPlaceholder) {
          expect(
            probedTypes.contains(definitionType),
            isTrue,
            reason:
                "${entry.value} no longer contains the placeholder marker "
                "'$placeholderMarker' -- it has gained real renderer "
                'logic, but no matching probe for definitionType '
                "'$definitionType' was added to `_probes` above. Add one "
                '(its buildXRenderer + a '
                'find.byType(RendererStateView<ItsOwnPageType>) finder) so '
                "AC4's widget-structure check above actually covers it.",
          );
        }
      }
    },
  );
}
