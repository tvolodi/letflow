/// AC3: "a test asserts the list renderer sends the filter in the POST
/// /api/v1/entities/query body and, on scrolling to the end, requests the
/// next page with the previous response's next_cursor, stopping when
/// next_cursor is null" (REQ-426). Three independently exercised
/// sub-assertions, each its own `test()` so a regression in one cannot hide
/// behind a pass in another (design §8's AC3 mapping;
/// `docs/anti-patterns.md` ISS-0880's "decompose every 'and'-joined
/// acceptance criterion" lesson).
///
/// Drives `ListRendererController` directly against a fake
/// `PostCapableHttpGateway` -- no widget tree needed, since AC3 is entirely
/// about the controller's own request-construction/pagination logic
/// (§3.5), not presentation.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/renderers/list/list.dart';

import '../../support/fake_post_capable_http_gateway.dart';

const String _entityType = 'orders';
const String _definitionsPath =
    '/api/v1/entities/definitions/active/$_entityType';
const String _queryPath = '/api/v1/entities/query';

FakePostCapableHttpGateway _gatewayWithOneQueriedField() {
  return FakePostCapableHttpGateway()
    ..getResponses[_definitionsPath] = ScriptedResponse(
      data: {
        'definition': {
          'fields': [
            {'name': 'status', 'type': 'string', 'queried': true},
          ],
        },
      },
    );
}

void main() {
  test(
    'AC3a: loadFirstPage sends the constructed filter clauses exactly in '
    'the POST body',
    () async {
      final gateway = _gatewayWithOneQueriedField()
        ..postResponseQueue.add(
          ScriptedResponse(
            data: {'items': <dynamic>[], 'next_cursor': 'cursor-1'},
          ),
        );
      final controller = ListRendererController(
        client: gateway,
        entityType: _entityType,
      );
      final filters = [
        const FilterClause(field: 'status', op: FilterOp.eq, value: 'open'),
      ];

      await controller.loadFirstPage(filters: filters, sort: const []);

      expect(gateway.postCalls, hasLength(1));
      expect(gateway.postCalls.single.path, _queryPath);
      final body = gateway.postCalls.single.data as Map<String, dynamic>;
      expect(body['entity_type'], _entityType);
      expect(body['filters'], [
        {'field': 'status', 'op': 'eq', 'value': 'open'},
      ]);
    },
  );

  test(
    'AC3b: loadNextPage sends cursor equal to the PREVIOUS response\'s '
    'next_cursor exactly',
    () async {
      final gateway = _gatewayWithOneQueriedField()
        ..postResponseQueue.add(
          ScriptedResponse(
            data: {'items': <dynamic>[], 'next_cursor': 'cursor-1'},
          ),
        )
        ..postResponseQueue.add(
          ScriptedResponse(
            data: {'items': <dynamic>[], 'next_cursor': 'cursor-2'},
          ),
        );
      final controller = ListRendererController(
        client: gateway,
        entityType: _entityType,
      );

      await controller.loadFirstPage(filters: const [], sort: const []);
      expect(gateway.postCalls, hasLength(1));

      await controller.loadNextPage();

      expect(gateway.postCalls, hasLength(2));
      final secondBody = gateway.postCalls[1].data as Map<String, dynamic>;
      expect(
        secondBody['cursor'],
        'cursor-1',
        reason: "must equal the first response's own next_cursor verbatim",
      );
    },
  );

  test(
    'AC3c: loadNextPage issues no further HTTP request once next_cursor is '
    'null -- it becomes a no-op',
    () async {
      final gateway = _gatewayWithOneQueriedField()
        ..postResponseQueue.add(
          ScriptedResponse(data: {'items': <dynamic>[], 'next_cursor': null}),
        );
      final controller = ListRendererController(
        client: gateway,
        entityType: _entityType,
      );

      await controller.loadFirstPage(filters: const [], sort: const []);
      expect(gateway.postCalls, hasLength(1));

      await controller.loadNextPage();
      // Calling it a second time is also still a no-op -- not just "the
      // first call after null happened to be skipped."
      await controller.loadNextPage();

      expect(
        gateway.postCalls,
        hasLength(1),
        reason: 'no further /entities/query request once next_cursor is '
            'null',
      );
    },
  );
}
