/// AC1 (REQ-428): "a test lists the inbox from a fake
/// `GET /api/v1/tasks/inbox`, claims a task (asserting
/// `POST /api/v1/tasks/:id/claim`), opens it, and completes it (asserting
/// `POST /api/v1/tasks/:id/complete` with the form values in the body)."
///
/// Drives `TaskInboxController`/`TaskDetailController`/
/// `FormRendererController` directly against a fake `PostCapableHttpGateway`
/// -- no widget tree needed, mirroring `list_renderer_ac3_test.dart`'s own
/// "controller tested directly" precedent (REQ-426).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/definitions/pinned_form_cache.dart';
import 'package:letflow/definitions/pinned_form_resolver.dart';
import 'package:letflow/expr/expr.dart' show kStaticCapabilities;
import 'package:letflow/renderers/form/form.dart';
import 'package:letflow/renderers/renderer_state.dart';
import 'package:letflow/renderers/task/task.dart';

import '../../support/fake_post_capable_http_gateway.dart';

const String _taskId = 'task-1';
const String _instanceId = 'instance-1';
const String _formId = 'node-1';
const String _formVersion = '1';
const String _inboxPath = '/api/v1/tasks/inbox';
const String _detailPath = '/api/v1/tasks/$_taskId';
const String _claimPath = '/api/v1/tasks/$_taskId/claim';
const String _completePath = '/api/v1/tasks/$_taskId/complete';

Map<String, dynamic> _taskListItemJson({required String status}) => {
  'id': _taskId,
  'instance_id': _instanceId,
  'node_id': _formId,
  'node_name': 'Review order',
  'status': status,
  'assignee_type': null,
  'assignee_ref': null,
  'created_at': '2026-01-01T00:00:00Z',
  'token_id': 'token-1',
  'form_id': _formId,
  'form_version': _formVersion,
};

Map<String, dynamic> _taskDetailJson({required String status}) => {
  ..._taskListItemJson(status: status),
  'correlation_key': null,
  'updated_at': '2026-01-01T00:00:00Z',
  'form_schema': {
    'properties': {
      'note': {'type': 'string', 'title': 'Note'},
    },
  },
};

void main() {
  test(
    'AC1: list inbox, claim a task, open it, and complete it',
    () async {
      final gateway = FakePostCapableHttpGateway();

      // ── 1. List the inbox ─────────────────────────────────────────
      gateway.getResponses[_inboxPath] = ScriptedResponse(
        data: {
          'items': [_taskListItemJson(status: 'PENDING')],
          'next_cursor': null,
        },
      );
      final inboxController = TaskInboxController(client: gateway);
      await inboxController.loadFirstPage();

      final inboxState = inboxController.state;
      expect(inboxState, isA<RendererContent<TaskInboxPage>>());
      final inboxPage = (inboxState as RendererContent<TaskInboxPage>).data;
      expect(inboxPage.items, hasLength(1));
      expect(inboxPage.items.single.id, _taskId);

      // ── 2. Claim the task from the inbox ─────────────────────────
      gateway.postResponseQueue.add(
        ScriptedResponse(data: _taskDetailJson(status: 'PENDING')),
      );
      final claimOutcome = await inboxController.claim(_taskId);
      expect(claimOutcome, isA<TaskClaimSuccess>());
      expect(gateway.postCalls, hasLength(1));
      expect(gateway.postCalls.single.path, _claimPath);

      // ── 3. Open it ────────────────────────────────────────────────
      gateway.getResponses[_detailPath] = ScriptedResponse(
        data: _taskDetailJson(status: 'PENDING'),
      );
      final detailController = TaskDetailController(
        client: gateway,
        taskId: _taskId,
      );
      await detailController.load();

      final detailState = detailController.state;
      expect(detailState, isA<RendererContent<TaskDetail>>());
      final detail = (detailState as RendererContent<TaskDetail>).data;
      expect(detail.formId, _formId);
      expect(detail.formVersion, _formVersion);

      // ── 4. Complete it, via FormRendererController.submit() ─────
      // (design §3.5: a thin composition over REQ-427's own controller,
      // never a second submission mechanism).
      final repo = InMemoryPinnedFormCacheRepository();
      final resolver = PinnedFormResolver(repository: repo, client: gateway);
      final formController = FormRendererController(
        client: gateway,
        pinnedFormResolver: resolver,
        manifestCapabilities: kStaticCapabilities.toList(),
        taskId: detail.id,
        formId: detail.formId!,
        formVersion: detail.formVersion,
        instanceId: detail.instanceId,
      );
      await formController.load();
      formController.updateFieldValue('note', 'looks good');

      gateway.postResponseQueue.add(
        ScriptedResponse(
          data: {
            'task_id': _taskId,
            'instance_id': _instanceId,
            'instance_status': 'ACTIVE',
            'current_nodes': <dynamic>['node-2'],
            'variables': <String, dynamic>{},
            'completed_at': '2026-01-01T01:00:00Z',
          },
        ),
      );
      await formController.submit();

      expect(gateway.postCalls, hasLength(2));
      final completeCall = gateway.postCalls.last;
      expect(completeCall.path, _completePath);
      expect(completeCall.data, {'note': 'looks good'});

      final submitOutcome =
          (formController.state as RendererContent<FormViewModel>)
              .data
              .submitOutcome;
      expect(submitOutcome, isA<SubmitSuccess>());
    },
  );
}
