/// AC3 (REQ-428): "a test asserts a 409 on claim renders a state telling
/// the user the task is no longer available and refreshes the inbox, not a
/// crash."
///
/// Proves design §3.2/§3.3: a 409 on `POST /tasks/:id/claim` folds to
/// `TaskClaimNoLongerAvailable` (never routed through `RendererState`, per
/// INV-1/INV-5 -- the task-detail/inbox content already on screen is never
/// discarded for a claim failure), and `TaskInboxController.claim` -- being
/// the same controller that owns `refreshAfterClaimConflict` -- triggers
/// that refresh directly.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_error.dart';
import 'package:letflow/renderers/renderer_state.dart';
import 'package:letflow/renderers/task/task.dart';

import '../../support/fake_post_capable_http_gateway.dart';

const String _taskId = 'task-1';
const String _inboxPath = '/api/v1/tasks/inbox';

Map<String, dynamic> _inboxItemJson() => {
  'id': _taskId,
  'instance_id': 'instance-1',
  'node_id': 'node-1',
  'node_name': 'Review order',
  'status': 'PENDING',
  'assignee_type': null,
  'assignee_ref': null,
  'created_at': '2026-01-01T00:00:00Z',
  'token_id': 'token-1',
  'form_id': 'node-1',
  'form_version': '1',
};

void main() {
  test(
    'AC3: a 409 on claim renders TaskClaimNoLongerAvailable (not a crash)'
    ' and triggers an inbox refresh',
    () async {
      final gateway = FakePostCapableHttpGateway();
      gateway.getResponses[_inboxPath] = ScriptedResponse(
        data: {'items': [_inboxItemJson()], 'next_cursor': null},
      );

      final controller = TaskInboxController(client: gateway);
      await controller.loadFirstPage();
      expect(gateway.getCalls, hasLength(1), reason: 'the initial inbox load');

      gateway.postResponseQueue.add(
        ScriptedResponse(error: const ConflictError()),
      );

      final outcome = await controller.claim(_taskId);

      // The specific state is shown -- not a crash, not swallowed.
      expect(outcome, isA<TaskClaimNoLongerAvailable>());

      // The inbox content is still intact (INV-5: a claim conflict never
      // discards an already-loaded RendererContent).
      expect(controller.state, isA<RendererContent<TaskInboxPage>>());

      // The inbox was refreshed -- a second GET /tasks/inbox call.
      expect(gateway.getCalls, hasLength(2), reason: 'refreshed after the 409');
    },
  );

  test(
    'AC3 (no crash under any other claim ApiError either): a 403 claims'
    ' forbidden, a network failure claims network-unavailable, neither'
    ' throws past claimTask',
    () async {
      final gateway = FakePostCapableHttpGateway();
      final controller = TaskInboxController(client: gateway);

      gateway.postResponseQueue.add(
        ScriptedResponse(error: const ForbiddenError()),
      );
      expect(
        await controller.claim(_taskId),
        isA<TaskClaimForbidden>(),
      );

      gateway.postResponseQueue.add(
        ScriptedResponse(error: const NetworkUnavailableError()),
      );
      expect(
        await controller.claim(_taskId),
        isA<TaskClaimNetworkUnavailable>(),
      );
    },
  );
}
