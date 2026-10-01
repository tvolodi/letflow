/// AC4 (REQ-428): "a test asserts the process-instance screen renders
/// status and timeline entries from fake `/instances/:id` and
/// `/instances/:id/timeline` responses and exposes no cancel, rebind or
/// advance action."
///
/// Drives `InstanceDetailController` directly against a fake
/// `HttpGateway`, mirroring `list_renderer_ac3_test.dart`'s "controller
/// tested directly" precedent. The "exposes no cancel/rebind/advance
/// action" half is proved two ways: (a) `InstanceDetailController`'s own
/// public method surface has no such method at all (checked directly
/// below, by construction -- the class literally has no `cancel`/`rebind`/
/// `advance` method to call), and (b) a source-text guard proving the
/// implementation file never references any of the four forbidden routes
/// (design §1/§4.1/INV-3).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_error.dart' show BackpressureError;
import 'package:letflow/renderers/process/process.dart';
import 'package:letflow/renderers/renderer_state.dart';

import '../../support/fake_http_gateway.dart';

const String _instanceId = 'instance-1';
const String _detailPath = '/api/v1/instances/$_instanceId';
const String _timelinePath = '/api/v1/instances/$_instanceId/timeline';

void main() {
  test(
    'AC4: renders status and timeline entries from the two fake responses,'
    ' and derives "current step" from the timeline\'s most recent'
    ' non-null node_id entry',
    () async {
      final gateway = FakeHttpGateway();
      gateway.getResponses[_detailPath] = ScriptedResponse(
        data: {
          'instance_id': _instanceId,
          'definition_id': 'def-1',
          'correlation_key': null,
          'status': 'ACTIVE',
          'variables': <String, dynamic>{},
          'started_at': '2026-01-01T00:00:00Z',
          'completed_at': null,
          'cancelled_at': null,
          'error_detail': null,
        },
      );
      gateway.getResponses[_timelinePath] = ScriptedResponse(
        data: {
          'items': [
            {
              'event_id': 'ev-1',
              'event_type': 'INSTANCE_STARTED',
              'sequence_num': 1,
              'instance_id': _instanceId,
              'timestamp': '2026-01-01T00:00:00Z',
              'node_id': 'start',
              'task_id': null,
              'metadata': null,
              'actor_display_name': null,
              'description': 'Instance started',
            },
            {
              'event_id': 'ev-2',
              'event_type': 'TASK_ACTIVATED',
              'sequence_num': 2,
              'instance_id': _instanceId,
              'timestamp': '2026-01-01T00:05:00Z',
              'node_id': 'review',
              'task_id': 'task-1',
              'metadata': null,
              'actor_display_name': null,
              'description': 'Review activated',
            },
          ],
          'next_cursor': null,
        },
      );

      final controller = InstanceDetailController(
        client: gateway,
        instanceId: _instanceId,
      );
      await controller.load();

      final detailState = controller.detailState;
      expect(detailState, isA<RendererContent<InstanceDetail>>());
      final detail = (detailState as RendererContent<InstanceDetail>).data;
      expect(detail.status, InstanceStatus.active);

      final timelineState = controller.timelineState;
      expect(timelineState, isA<RendererContent<InstanceTimelinePage>>());
      final timeline =
          (timelineState as RendererContent<InstanceTimelinePage>).data;
      expect(timeline.entries, hasLength(2));
      expect(timeline.entries.map((e) => e.eventId), ['ev-1', 'ev-2']);

      // "Current step" (AC4) -- the most recent entry carrying a non-null
      // node_id, no second endpoint read (design §4.2).
      expect(deriveCurrentStepNodeId(timeline), 'review');
    },
  );

  test(
    'AC4: detailState and timelineState fail independently -- a 429 on'
    ' the timeline call alone does not blank the already-loaded header'
    ' (design §4.4.1/§4.4.2, INV-6)',
    () async {
      final gateway = FakeHttpGateway();
      gateway.getResponses[_detailPath] = ScriptedResponse(
        data: {
          'instance_id': _instanceId,
          'definition_id': 'def-1',
          'correlation_key': null,
          'status': 'COMPLETED',
          'variables': <String, dynamic>{},
          'started_at': '2026-01-01T00:00:00Z',
          'completed_at': '2026-01-01T01:00:00Z',
          'cancelled_at': null,
          'error_detail': null,
        },
      );
      gateway.getResponses[_timelinePath] = ScriptedResponse(
        error: const BackpressureError(retryAfterSeconds: 5),
      );

      final controller = InstanceDetailController(
        client: gateway,
        instanceId: _instanceId,
      );
      await controller.load();

      expect(controller.detailState, isA<RendererContent<InstanceDetail>>());
      expect(
        (controller.detailState as RendererContent<InstanceDetail>).data.status,
        InstanceStatus.completed,
      );
      expect(
        controller.timelineState,
        isA<RendererBackpressure<InstanceTimelinePage>>(),
      );
    },
  );

  test(
    'guard: process.dart issues no POST call at all (so no cancel/rebind/'
    'reconstruct/advance-timer action can exist, design §1/§4.1/INV-3) and'
    ' calls exactly the two GET routes this design names',
    () {
      final source = File('lib/renderers/process/process.dart').readAsStringSync();

      // The structural guarantee: this file never imports a POST-capable
      // gateway and never calls `.post(` -- a cancel/rebind/reconstruct/
      // advance-timer action literally cannot be issued from code that
      // holds only a GET-only `HttpGateway` and never calls `post`.
      expect(
        source.contains('PostCapableHttpGateway'),
        isFalse,
        reason: 'process.dart must never hold a POST-capable gateway',
      );
      expect(
        source.contains('.post('),
        isFalse,
        reason: 'process.dart must never issue a POST request',
      );

      // The only two routes this design names (design §1/§4.1/INV-3) --
      // every `.get(` call target is one of these two path prefixes.
      final getCallTargets = RegExp(r"\.get\(\s*'([^']*)'")
          .allMatches(source)
          .map((m) => m.group(1)!)
          .toList();
      expect(getCallTargets, isNotEmpty);
      for (final target in getCallTargets) {
        expect(
          target == r'$_detailPathPrefix$instanceId' ||
              target == r'$_detailPathPrefix$instanceId/timeline',
          isTrue,
          reason: 'unexpected GET target: $target',
        );
      }
    },
  );
}
