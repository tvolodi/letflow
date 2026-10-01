/// AC2 (REQ-428): "a test asserts opening a task pinned to form_version 1
/// while version 2 is cached renders version 1's fields (through REQ-424's
/// resolver), not version 2's."
///
/// Proves design §3.6/INV-4: `TaskDetail.formId`/`formVersion` flow
/// UNCHANGED into `FormRendererController`'s constructor and then into
/// `PinnedFormResolver.resolve` -- never substituted by any "active
/// version" lookup.
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

void main() {
  test(
    'AC2: a task pinned to form_version 1 renders version 1\'s fields, not'
    ' version 2\'s, even though version 2 is also cached',
    () async {
      final repo = InMemoryPinnedFormCacheRepository();
      // Version 1 carries field "v1_only_field"; version 2 carries a
      // DIFFERENT field "v2_only_field" -- the two schemas are
      // deliberately disjoint so rendering the wrong one is unambiguous.
      await repo.putEntry(
        PinnedFormCacheEntry(
          formId: _formId,
          formVersion: '1',
          formSchema: {
            'properties': {
              'v1_only_field': {'type': 'string', 'title': 'V1 field'},
            },
          },
        ),
      );
      await repo.putEntry(
        PinnedFormCacheEntry(
          formId: _formId,
          formVersion: '2',
          formSchema: {
            'properties': {
              'v2_only_field': {'type': 'string', 'title': 'V2 field'},
            },
          },
        ),
      );

      final gateway = FakePostCapableHttpGateway();
      final resolver = PinnedFormResolver(repository: repo, client: gateway);

      // The task this requirement's scope is about: GET /tasks/:id's own
      // `form_version` says "1" -- `TaskDetail.fromJson` reads it verbatim
      // (design §3.1), never "the active/latest version" of `_formId`.
      const detailJson = {
        'id': _taskId,
        'instance_id': _instanceId,
        'node_id': _formId,
        'node_name': 'Review order',
        'status': 'PENDING',
        'assignee_type': null,
        'assignee_ref': null,
        'created_at': '2026-01-01T00:00:00Z',
        'token_id': 'token-1',
        'form_id': _formId,
        'form_version': '1',
        'correlation_key': null,
        'updated_at': '2026-01-01T00:00:00Z',
        'form_schema': null,
      };
      final detail = TaskDetail.fromJson(detailJson);
      expect(detail.formVersion, '1');

      // §3.6's exact data flow: TaskDetail.formId/formVersion -> the form
      // controller's constructor, unchanged.
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

      // Zero network calls -- a cache hit on the exact (formId,
      // formVersion) key requires no fetch at all (REQ-424 §5.1 step 2).
      expect(gateway.getCalls, isEmpty);

      final vm =
          (formController.state as RendererContent<FormViewModel>).data;
      final fieldNames = vm.fields.map((f) => f.name).toList();
      expect(fieldNames, ['v1_only_field']);
      expect(fieldNames, isNot(contains('v2_only_field')));
    },
  );
}
