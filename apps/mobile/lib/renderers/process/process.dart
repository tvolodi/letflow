/// Process renderer: a READ-ONLY view of a process instance -- status,
/// current step, timeline (`MOB-4`). Built starting REQ-428.
///
/// See `lib/letflow/design/req428-task-and-instance-renderer.md` §4 for the
/// full design this file implements. **No cancel/rebind/advance-timer
/// action anywhere in this file** -- `Letflow.Routers.Instances` exposes
/// `POST /:id/cancel`, `POST /:id/rebind-pins`, `POST /:id/reconstruct`, and
/// `POST /:id/advance-timer`; none of the four is called, referenced, or
/// exposed by any type or method below (design §1/§4.1, INV-3). This file
/// calls exactly two routes: `GET /instances/:id` and
/// `GET /instances/:id/timeline`.
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart' show HttpGateway;
import '../../api/api_error.dart' show ApiError;
import '../../bootstrap/navigation_bootstrap.dart' show apiClientProvider;
import '../renderer_state.dart';
import '../renderer_state_view.dart';

// ── §4.2.1 `InstanceStatus` ──────────────────────────────────────────

/// `status_string/1`'s own four-value range (`instances.ex`, design §0).
enum InstanceStatus {
  active,
  completed,
  cancelled,
  error;

  static InstanceStatus? fromWire(String raw) {
    return switch (raw) {
      'ACTIVE' => InstanceStatus.active,
      'COMPLETED' => InstanceStatus.completed,
      'CANCELLED' => InstanceStatus.cancelled,
      'ERROR' => InstanceStatus.error,
      _ => null,
    };
  }
}

// ── §4.2 `InstanceDetail` ────────────────────────────────────────────

@immutable
class InstanceDetail {
  const InstanceDetail({
    required this.instanceId,
    required this.definitionId,
    required this.correlationKey,
    required this.status,
    required this.variables,
    required this.startedAt,
    required this.completedAt,
    required this.cancelledAt,
    required this.errorDetail,
  });

  final String instanceId;
  final String definitionId;
  final String? correlationKey;
  final InstanceStatus status;
  final Map<String, dynamic> variables;
  final DateTime startedAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final Object? errorDetail;

  /// Assumes `status` has already been validated by the caller
  /// ([InstanceDetailController._loadDetail]) -- mirrors
  /// `TaskDetail.fromJson`'s own convention.
  factory InstanceDetail.fromJson(Map<String, dynamic> json) {
    return InstanceDetail(
      instanceId: json['instance_id'] as String,
      definitionId: json['definition_id'] as String? ?? '',
      correlationKey: json['correlation_key'] as String?,
      status: InstanceStatus.fromWire(json['status'] as String)!,
      variables: (json['variables'] as Map<String, dynamic>?) ?? const {},
      startedAt: DateTime.tryParse(json['started_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      completedAt: json['completed_at'] is String
          ? DateTime.tryParse(json['completed_at'] as String)
          : null,
      cancelledAt: json['cancelled_at'] is String
          ? DateTime.tryParse(json['cancelled_at'] as String)
          : null,
      errorDetail: json['error_detail'],
    );
  }
}

// ── §4.3 `TimelineEntry` / `InstanceTimelinePage` ────────────────────

@immutable
class TimelineEntry {
  const TimelineEntry({
    required this.eventId,
    required this.eventType,
    required this.sequenceNum,
    required this.instanceId,
    required this.timestamp,
    required this.nodeId,
    required this.taskId,
    required this.metadata,
    required this.actorDisplayName,
    required this.description,
  });

  final String eventId;
  final String eventType;
  final int sequenceNum;
  final String instanceId;
  final DateTime timestamp;
  final String? nodeId;
  final String? taskId;
  final Map<String, dynamic>? metadata;
  final String? actorDisplayName;
  final String? description;

  factory TimelineEntry.fromJson(Map<String, dynamic> json) {
    return TimelineEntry(
      eventId: json['event_id'] as String? ?? '',
      eventType: json['event_type'] as String? ?? '',
      sequenceNum: json['sequence_num'] as int? ?? 0,
      instanceId: json['instance_id'] as String? ?? '',
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      nodeId: json['node_id'] as String?,
      taskId: json['task_id'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
      actorDisplayName: json['actor_display_name'] as String?,
      description: json['description'] as String?,
    );
  }
}

@immutable
class InstanceTimelinePage {
  const InstanceTimelinePage({required this.entries, required this.nextCursor});

  final List<TimelineEntry> entries;
  final String? nextCursor;
}

// ── §4.4 `InstanceDetailController` ──────────────────────────────────

class InstanceDetailController extends ChangeNotifier {
  InstanceDetailController({required this.client, required this.instanceId});

  /// GET-only -- this whole controller never POSTs (design §4.1/INV-3).
  final HttpGateway client;
  final String instanceId;

  static const String _detailPathPrefix = '/api/v1/instances/';

  RendererState<InstanceDetail> _detailState =
      const RendererLoading<InstanceDetail>();
  RendererState<InstanceDetail> get detailState => _detailState;

  RendererState<InstanceTimelinePage> _timelineState =
      const RendererLoading<InstanceTimelinePage>();
  RendererState<InstanceTimelinePage> get timelineState => _timelineState;

  bool _detailRequestInFlight = false;
  bool _timelineRequestInFlight = false;

  void _setDetailState(RendererState<InstanceDetail> next) {
    _detailState = next;
    notifyListeners();
  }

  void _setTimelineState(RendererState<InstanceTimelinePage> next) {
    _timelineState = next;
    notifyListeners();
  }

  /// §4.4.3: issues both `GET /instances/:id` and
  /// `GET /instances/:id/timeline` concurrently -- no ordering dependency
  /// between the two (design §4.4.3 step 2); each resolves into its own,
  /// independent `RendererState` (§4.4.1/§4.4.2, INV-6).
  Future<void> load() async {
    _setDetailState(const RendererLoading<InstanceDetail>());
    _setTimelineState(const RendererLoading<InstanceTimelinePage>());
    await Future.wait([_loadDetail(), _loadTimelinePage(cursor: null, existing: const [])]);
  }

  Future<void> _loadDetail() async {
    if (_detailRequestInFlight) return;
    _detailRequestInFlight = true;
    try {
      final Map<String, dynamic> body;
      try {
        final response = await client.get('$_detailPathPrefix$instanceId');
        body = response.data as Map<String, dynamic>;
      } on ApiError catch (e) {
        _setDetailState(rendererStateForError<InstanceDetail>(e));
        return;
      }

      final statusVal = body['status'];
      final status = statusVal is String ? InstanceStatus.fromWire(statusVal) : null;
      if (status == null) {
        _setDetailState(
          staleVersionState<InstanceDetail>(
            UnknownFieldType(
              fieldName: 'status',
              rawType: statusVal is String ? statusVal : '${statusVal.runtimeType}',
            ),
          ),
        );
        return;
      }

      _setDetailState(RendererContent<InstanceDetail>(data: InstanceDetail.fromJson(body)));
    } finally {
      _detailRequestInFlight = false;
    }
  }

  Future<void> _loadTimelinePage({
    required String? cursor,
    required List<TimelineEntry> existing,
  }) async {
    if (_timelineRequestInFlight) return;
    _timelineRequestInFlight = true;
    try {
      final Map<String, dynamic> body;
      try {
        final response = await client.get(
          '$_detailPathPrefix$instanceId/timeline',
          queryParameters: {'cursor': ?cursor},
        );
        body = response.data as Map<String, dynamic>;
      } on ApiError catch (e) {
        _setTimelineState(rendererStateForError<InstanceTimelinePage>(e));
        return;
      }

      final rawItems = (body['items'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      final entries = <TimelineEntry>[];
      for (final raw in rawItems) {
        final eventTypeVal = raw['event_type'];
        if (eventTypeVal != null && eventTypeVal is! String) {
          _setTimelineState(
            staleVersionState<InstanceTimelinePage>(
              UnknownFieldType(
                fieldName: 'event_type',
                rawType: '${eventTypeVal.runtimeType}',
              ),
            ),
          );
          return;
        }
        entries.add(TimelineEntry.fromJson(raw));
      }

      _setTimelineState(
        RendererContent<InstanceTimelinePage>(
          data: InstanceTimelinePage(
            entries: [...existing, ...entries],
            nextCursor: body['next_cursor'] as String?,
          ),
        ),
      );
    } finally {
      _timelineRequestInFlight = false;
    }
  }

  /// Mirrors `ListRendererController.loadNextPage()`'s no-op-unless-
  /// `RendererContent`-with-non-null-`nextCursor` guard, applied to
  /// [timelineState] alone -- never touches [detailState] (design §4.4.3).
  Future<void> loadMoreTimeline() async {
    final current = _timelineState;
    if (current is! RendererContent<InstanceTimelinePage>) return;
    final page = current.data;
    if (page.nextCursor == null) return;
    await _loadTimelinePage(cursor: page.nextCursor, existing: page.entries);
  }

  Future<void> retryTimelineBackpressure() =>
      _loadTimelinePage(cursor: null, existing: const []);

  Future<void> retryDetailBackpressure() => _loadDetail();
}

// ── §4.2's "current step" derivation (view concern, §6.3) ────────────

/// Derives "current step" (AC4) as the most recent timeline entry
/// carrying a non-null `node_id` -- no second endpoint is read (design
/// §4.2). Returns `null` when no such entry exists yet.
String? deriveCurrentStepNodeId(InstanceTimelinePage page) {
  for (final entry in page.entries.reversed) {
    if (entry.nodeId != null) return entry.nodeId;
  }
  return null;
}

// ── §6 Widget layer ──────────────────────────────────────────────────

const Key instanceStatusKey = Key('instance-status');
const Key instanceCurrentStepKey = Key('instance-current-step');

Key timelineEntryKey(String eventId) => Key('timeline-entry-$eventId');

/// The `"process"` definition's required shape: `{"instance_id": "<string>"}`
/// (design §6.1).
Widget buildProcessRenderer(BuildContext context, Map<String, dynamic> definition) {
  final instanceId = definition['instance_id'];
  if (instanceId is! String) {
    return RendererStateView<InstanceDetail>(
      state: staleVersionState<InstanceDetail>(
        UnknownFieldType(fieldName: 'instance_id', rawType: '${instanceId.runtimeType}'),
      ),
      contentBuilder: (_, _) => const SizedBox.shrink(),
      onRetryBackpressure: () async {},
    );
  }
  return ProcessInstanceScreen(instanceId: instanceId);
}

/// Read-only -- NO button, menu item, or gesture anywhere in this widget
/// calls `cancel`/`rebind-pins`/`reconstruct`/`advance-timer` (design §1/
/// §4.1/§6.3).
class ProcessInstanceScreen extends ConsumerStatefulWidget {
  const ProcessInstanceScreen({super.key, required this.instanceId});

  final String instanceId;

  @override
  ConsumerState<ProcessInstanceScreen> createState() => _ProcessInstanceScreenState();
}

class _ProcessInstanceScreenState extends ConsumerState<ProcessInstanceScreen> {
  bool _startedLoad = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_startedLoad) return;
    _startedLoad = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = ref.read(instanceDetailControllerProvider(widget.instanceId));
      unawaited(controller.load());
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(instanceDetailControllerProvider(widget.instanceId));
    return RendererStateView<InstanceDetail>(
      state: controller.detailState,
      contentBuilder: (context, detail) =>
          _ProcessInstanceBody(controller: controller, detail: detail),
      onRetryBackpressure: controller.retryDetailBackpressure,
    );
  }
}

class _ProcessInstanceBody extends StatelessWidget {
  const _ProcessInstanceBody({required this.controller, required this.detail});

  final InstanceDetailController controller;
  final InstanceDetail detail;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(detail.status.name, key: instanceStatusKey),
        AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            return RendererStateView<InstanceTimelinePage>(
              state: controller.timelineState,
              contentBuilder: (context, timeline) {
                final currentStepNodeId =
                    detail.status == InstanceStatus.active
                        ? deriveCurrentStepNodeId(timeline)
                        : null;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (detail.status == InstanceStatus.active)
                      Text(
                        currentStepNodeId ?? '',
                        key: instanceCurrentStepKey,
                      ),
                    Expanded(
                      child: _TimelineList(
                        controller: controller,
                        timeline: timeline,
                      ),
                    ),
                  ],
                );
              },
              onRetryBackpressure: controller.retryTimelineBackpressure,
            );
          },
        ),
      ],
    );
  }
}

class _TimelineList extends StatefulWidget {
  const _TimelineList({required this.controller, required this.timeline});

  final InstanceDetailController controller;
  final InstanceTimelinePage timeline;

  @override
  State<_TimelineList> createState() => _TimelineListState();
}

class _TimelineListState extends State<_TimelineList> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      widget.controller.loadMoreTimeline();
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.timeline.entries;
    return ListView.builder(
      key: const Key('timeline-entries'),
      controller: _scrollController,
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return ListTile(
          key: timelineEntryKey(entry.eventId),
          title: Text(entry.eventType),
          subtitle: Text(entry.description ?? ''),
        );
      },
    );
  }
}

// ── §7 Provider wiring ────────────────────────────────────────────────

final instanceDetailControllerProvider =
    ChangeNotifierProvider.family<InstanceDetailController, String>((
      ref,
      instanceId,
    ) {
      return InstanceDetailController(
        client: ref.watch(apiClientProvider),
        instanceId: instanceId,
      );
    });
