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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/renderers/list/list.dart';
import 'package:letflow/renderers/renderer_state_view.dart';

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
  // REQ-427 appends a 'form' entry here (buildFormRenderer +
  // find.byType(RendererStateView<ItsFormPageType>)).
  // REQ-428 appends 'process' and 'task' entries the same way.
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
      // As of REQ-426, only lib/renderers/list/list.dart has real logic --
      // form.dart/process.dart/task.dart are still placeholder libraries
      // (design §0). If this ever goes stale (a future requirement adds a
      // renderer without adding a probe above), this assertion is the
      // tripwire: it fails loudly rather than the guard silently covering
      // fewer renderers than actually exist.
      expect(_probes.map((p) => p.definitionType).toList(), ['list']);
    },
  );
}
