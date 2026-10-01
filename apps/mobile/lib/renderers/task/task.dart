/// Task renderer: interprets `task` definitions carrying version-pinned
/// `{ form_id, form_version }` payloads (`REQ-126`) — task inbox, claim,
/// and complete (`MOB-4` part 3). Built starting REQ-428.
///
/// See `lib/letflow/design/req428-task-and-instance-renderer.md` for the
/// full design this file implements. Builds on REQ-426's
/// `RendererState`/`RendererStateView` framework (unchanged) and REQ-427's
/// `FormRendererController` (unchanged, composed by `TaskDetailScreen`
/// below) — completing a task is always `FormRendererController.submit()`,
/// never a second submission mechanism (design INV-2).
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../../i18n/i18n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart' show PostCapableHttpGateway;
import '../../api/api_error.dart'
    show ApiError, ConflictError, ForbiddenError, NetworkUnavailableError;
import '../../bootstrap/navigation_bootstrap.dart' show apiClientProvider;
import '../form/form.dart';
import '../renderer_state.dart';
import '../renderer_state_view.dart';

// ── §2.1.1 `TaskStatus` ─────────────────────────────────────────────────

/// `task_status_string/1`'s own three-value range (`tasks.ex`, design §0).
enum TaskStatus {
  pending,
  completed,
  cancelled;

  /// Returns `null` -- never throws -- for a status string outside the
  /// three known values, so the caller can fold that drift into the
  /// whole-page `RendererStaleVersion` the design's §2.1.1 requires.
  static TaskStatus? fromWire(String raw) {
    return switch (raw) {
      'PENDING' => TaskStatus.pending,
      'COMPLETED' => TaskStatus.completed,
      'CANCELLED' => TaskStatus.cancelled,
      _ => null,
    };
  }
}

// ── §2.1 `TaskInboxItem` ─────────────────────────────────────────────────

@immutable
class TaskInboxItem {
  const TaskInboxItem({
    required this.id,
    required this.instanceId,
    required this.nodeId,
    required this.nodeName,
    required this.status,
    required this.assigneeType,
    required this.assigneeRef,
    required this.createdAt,
    required this.tokenId,
    required this.formId,
    required this.formVersion,
  });

  final String id;
  final String instanceId;
  final String nodeId;
  final String nodeName;
  final TaskStatus status;
  final String? assigneeType;
  final String? assigneeRef;
  final DateTime createdAt;
  final String? tokenId;
  final String? formId;
  final String? formVersion;

  /// Assumes [json]'s `id`/`instance_id`/`status` have already been
  /// validated by the caller ([TaskInboxController._fetchPage]) -- this
  /// factory is NOT responsible for defending against those three (design
  /// §2.1). Every other key is read defensively, mirroring
  /// `EntityFieldDef.fromJson`'s own style.
  factory TaskInboxItem.fromJson(Map<String, dynamic> json) {
    return TaskInboxItem(
      id: json['id'] as String,
      instanceId: json['instance_id'] as String,
      nodeId: json['node_id'] as String? ?? '',
      nodeName: json['node_name'] as String? ?? '',
      status: TaskStatus.fromWire(json['status'] as String)!,
      assigneeType: json['assignee_type'] as String?,
      assigneeRef: json['assignee_ref'] as String?,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      tokenId: json['token_id'] as String?,
      formId: json['form_id'] as String?,
      formVersion: json['form_version'] as String?,
    );
  }
}

// ── §2.2 `TaskInboxPage` ───────────────────────────────────────────────

@immutable
class TaskInboxPage {
  const TaskInboxPage({required this.items, required this.nextCursor});

  final List<TaskInboxItem> items;
  final String? nextCursor;
}

/// Which operation most recently transitioned the controller into
/// `RendererBackpressure`, mirroring `ListRendererController`'s own
/// `_LastOperation` idiom (design §2.3).
enum _TaskInboxLastOperation { firstPage, nextPage }

// ── §2.3 `TaskInboxController` ────────────────────────────────────────

class TaskInboxController extends ChangeNotifier {
  TaskInboxController({required this.client});

  /// Typed as [PostCapableHttpGateway], not the bare `HttpGateway` design
  /// §2.3 comments as "GET-only -- inbox never POSTs" -- `claim` (§2.4)
  /// delegates to the same [claimTask] function `TaskDetailController`
  /// uses, which needs POST capability. [ApiClient] (the sole production
  /// implementation) already implements `PostCapableHttpGateway`, so this
  /// is a client-side interface-typing correction, not a behavior change:
  /// the inbox fetch itself still issues only `GET` calls.
  final PostCapableHttpGateway client;

  static const String _inboxPath = '/api/v1/tasks/inbox';

  RendererState<TaskInboxPage> _state = const RendererLoading<TaskInboxPage>();
  RendererState<TaskInboxPage> get state => _state;

  _TaskInboxLastOperation? _lastOperation;
  String? _lastNextPageCursor;
  List<TaskInboxItem> _lastExistingItems = const [];

  bool _requestInFlight = false;

  void _setState(RendererState<TaskInboxPage> next) {
    _state = next;
    notifyListeners();
  }

  Future<void> loadFirstPage() async {
    if (_requestInFlight) return;
    _requestInFlight = true;
    _lastOperation = _TaskInboxLastOperation.firstPage;
    _setState(const RendererLoading<TaskInboxPage>());
    try {
      await _fetchPage(cursor: null, existingItems: const []);
    } finally {
      _requestInFlight = false;
    }
  }

  /// Same `nextCursor`-null stop rule as `ListRendererController
  /// .loadNextPage` (design §2.3).
  Future<void> loadNextPage() async {
    if (_requestInFlight) return;
    final current = _state;
    if (current is! RendererContent<TaskInboxPage>) return;
    final page = current.data;
    if (page.nextCursor == null) return;

    _requestInFlight = true;
    _lastOperation = _TaskInboxLastOperation.nextPage;
    _lastNextPageCursor = page.nextCursor;
    _lastExistingItems = page.items;
    try {
      await _fetchPage(cursor: page.nextCursor, existingItems: page.items);
    } finally {
      _requestInFlight = false;
    }
  }

  Future<void> retryLastOperation() async {
    switch (_lastOperation) {
      case _TaskInboxLastOperation.firstPage:
        await loadFirstPage();
      case _TaskInboxLastOperation.nextPage:
        if (_requestInFlight) return;
        _requestInFlight = true;
        try {
          await _fetchPage(
            cursor: _lastNextPageCursor,
            existingItems: _lastExistingItems,
          );
        } finally {
          _requestInFlight = false;
        }
      case null:
        return;
    }
  }

  /// `loadFirstPage()` under a distinct name -- no new mechanism (design
  /// §2.3) -- called by the caller of [claim] exactly when its outcome is
  /// [TaskClaimNoLongerAvailable] (design §3.3, AC3's "inbox refresh"
  /// half).
  Future<void> refreshAfterClaimConflict() => loadFirstPage();

  Future<void> _fetchPage({
    required String? cursor,
    required List<TaskInboxItem> existingItems,
  }) async {
    final Map<String, dynamic> body;
    try {
      final response = await client.get(
        _inboxPath,
        queryParameters: {'cursor': ?cursor},
      );
      body = response.data as Map<String, dynamic>;
    } on ApiError catch (e) {
      _setState(rendererStateForError<TaskInboxPage>(e));
      return;
    }

    final rawItems = (body['items'] as List? ?? const [])
        .cast<Map<String, dynamic>>();

    final items = <TaskInboxItem>[];
    for (final raw in rawItems) {
      final idVal = raw['id'];
      if (idVal is! String) {
        _setState(
          staleVersionState<TaskInboxPage>(
            UnknownFieldType(fieldName: 'id', rawType: '${idVal.runtimeType}'),
          ),
        );
        return;
      }
      final instanceIdVal = raw['instance_id'];
      if (instanceIdVal is! String) {
        _setState(
          staleVersionState<TaskInboxPage>(
            UnknownFieldType(
              fieldName: 'instance_id',
              rawType: '${instanceIdVal.runtimeType}',
            ),
          ),
        );
        return;
      }
      final statusVal = raw['status'];
      final status = statusVal is String ? TaskStatus.fromWire(statusVal) : null;
      if (status == null) {
        _setState(
          staleVersionState<TaskInboxPage>(
            UnknownFieldType(
              fieldName: 'status',
              rawType: statusVal is String ? statusVal : '${statusVal.runtimeType}',
            ),
          ),
        );
        return;
      }
      items.add(TaskInboxItem.fromJson(raw));
    }

    _setState(
      RendererContent<TaskInboxPage>(
        data: TaskInboxPage(
          items: [...existingItems, ...items],
          nextCursor: body['next_cursor'] as String?,
        ),
      ),
    );
  }

  /// Delegates to [claimTask] (§3.2/§3.3) -- shared with
  /// `TaskDetailController.claim`, not a second implementation. On
  /// [TaskClaimNoLongerAvailable], this controller IS the inbox's own
  /// controller, so it refreshes itself directly -- the "direct, same
  /// controller" half of design §3.3's AC3 mapping.
  Future<TaskClaimOutcome> claim(String taskId) async {
    final outcome = await claimTask(client, taskId);
    if (outcome is TaskClaimNoLongerAvailable) {
      // Awaited (not fire-and-forget) so a caller observing this Future's
      // completion also observes the refresh having happened -- AC3's
      // "triggers an inbox refresh" is a deterministic effect of this
      // call, not a race the caller has to separately wait out.
      await refreshAfterClaimConflict();
    }
    return outcome;
  }
}

// ── §3.1 `TaskDetail` ─────────────────────────────────────────────────

@immutable
class TaskDetail {
  const TaskDetail({
    required this.id,
    required this.instanceId,
    required this.nodeId,
    required this.nodeName,
    required this.status,
    required this.assigneeType,
    required this.assigneeRef,
    required this.createdAt,
    required this.tokenId,
    required this.formId,
    required this.formVersion,
    required this.correlationKey,
    required this.updatedAt,
    required this.formSchema,
  });

  final String id;
  final String instanceId;
  final String nodeId;
  final String nodeName;
  final TaskStatus status;
  final String? assigneeType;
  final String? assigneeRef;
  final DateTime createdAt;
  final String? tokenId;
  final String? formId;
  final String? formVersion;
  final String? correlationKey;
  final DateTime updatedAt;
  final Map<String, dynamic>? formSchema;

  /// Assumes [json]'s `id`/`instance_id`/`status` have already been
  /// validated by the caller ([TaskDetailController.load],
  /// [claimTask]) -- mirrors [TaskInboxItem.fromJson]'s same convention.
  factory TaskDetail.fromJson(Map<String, dynamic> json) {
    return TaskDetail(
      id: json['id'] as String,
      instanceId: json['instance_id'] as String,
      nodeId: json['node_id'] as String? ?? '',
      nodeName: json['node_name'] as String? ?? '',
      status: TaskStatus.fromWire(json['status'] as String)!,
      assigneeType: json['assignee_type'] as String?,
      assigneeRef: json['assignee_ref'] as String?,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      tokenId: json['token_id'] as String?,
      formId: json['form_id'] as String?,
      formVersion: json['form_version'] as String?,
      correlationKey: json['correlation_key'] as String?,
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      formSchema: json['form_schema'] as Map<String, dynamic>?,
    );
  }
}

// ── §3.2 `TaskClaimOutcome` ────────────────────────────────────────────

sealed class TaskClaimOutcome {
  const TaskClaimOutcome();
}

final class TaskClaimSuccess extends TaskClaimOutcome {
  const TaskClaimSuccess({required this.detail});
  final TaskDetail detail;
}

/// 409 -- `handle_claim_result`'s five distinct conflict clauses (design
/// §0) all collapse to this ONE outcome (AC3): the task is no longer
/// available to claim, full stop.
final class TaskClaimNoLongerAvailable extends TaskClaimOutcome {
  const TaskClaimNoLongerAvailable();
}

final class TaskClaimForbidden extends TaskClaimOutcome {
  const TaskClaimForbidden();
}

final class TaskClaimNetworkUnavailable extends TaskClaimOutcome {
  const TaskClaimNetworkUnavailable();
}

final class TaskClaimOtherFailure extends TaskClaimOutcome {
  const TaskClaimOtherFailure({required this.cause});
  final Object cause;
}

/// Shared by `TaskInboxController.claim` and `TaskDetailController.claim`
/// -- a bare top-level function so there is exactly one claim
/// implementation (design §3.2). `POST /api/v1/tasks/:id/claim`, empty
/// body -- `handle_claim` reads only `auth_context.user_id`, no request
/// body field (design §0).
Future<TaskClaimOutcome> claimTask(
  PostCapableHttpGateway client,
  String taskId,
) async {
  try {
    final response = await client.post('/api/v1/tasks/$taskId/claim');
    final body = response.data as Map<String, dynamic>;
    return TaskClaimSuccess(detail: TaskDetail.fromJson(body));
  } on ApiError catch (e) {
    return switch (e) {
      ConflictError() => const TaskClaimNoLongerAvailable(),
      ForbiddenError() => const TaskClaimForbidden(),
      NetworkUnavailableError() => const TaskClaimNetworkUnavailable(),
      _ => TaskClaimOtherFailure(cause: e),
    };
  }
}

// ── §3.4 `TaskDetailController` ───────────────────────────────────────

class TaskDetailController extends ChangeNotifier {
  TaskDetailController({required this.client, required this.taskId});

  final PostCapableHttpGateway client;
  final String taskId;

  RendererState<TaskDetail> _state = const RendererLoading<TaskDetail>();
  RendererState<TaskDetail> get state => _state;

  TaskClaimOutcome? _lastClaimOutcome;
  TaskClaimOutcome? get lastClaimOutcome => _lastClaimOutcome;

  void _setState(RendererState<TaskDetail> next) {
    _state = next;
    notifyListeners();
  }

  /// §3.4.1: `GET /api/v1/tasks/:id`.
  Future<void> load() async {
    _setState(const RendererLoading<TaskDetail>());

    final Map<String, dynamic> body;
    try {
      final response = await client.get('/api/v1/tasks/$taskId');
      body = response.data as Map<String, dynamic>;
    } on ApiError catch (e) {
      _setState(rendererStateForError<TaskDetail>(e));
      return;
    }

    final statusVal = body['status'];
    final status = statusVal is String ? TaskStatus.fromWire(statusVal) : null;
    if (status == null) {
      _setState(
        staleVersionState<TaskDetail>(
          UnknownFieldType(
            fieldName: 'status',
            rawType: statusVal is String ? statusVal : '${statusVal.runtimeType}',
          ),
        ),
      );
      return;
    }

    _setState(RendererContent<TaskDetail>(data: TaskDetail.fromJson(body)));
  }

  /// §3.3/§3.4: calls [claimTask], stores the result in [lastClaimOutcome],
  /// and on [TaskClaimSuccess] also re-sets `state` to the claim response's
  /// own `TaskDetail` -- no second `GET /tasks/:id` needed (design §3.4).
  Future<TaskClaimOutcome> claim() async {
    final outcome = await claimTask(client, taskId);
    _lastClaimOutcome = outcome;
    if (outcome is TaskClaimSuccess) {
      _state = RendererContent<TaskDetail>(data: outcome.detail);
    }
    notifyListeners();
    return outcome;
  }
}

// ── §6 Widget layer ──────────────────────────────────────────────────

const Key taskClaimButtonKey = Key('task-claim-button');
const Key taskClaimNoLongerAvailableKey = Key('task-claim-no-longer-available');
const Key taskClaimForbiddenKey = Key('task-claim-forbidden');
const Key taskClaimNetworkUnavailableKey = Key('task-claim-network-unavailable');
const Key taskClaimOtherFailureKey = Key('task-claim-other-failure');

Key taskInboxItemKey(String id) => Key('task-inbox-item-$id');
Key taskInboxClaimKey(String id) => Key('task-inbox-claim-$id');

/// The `"task"` definition's required shape: `{"task_id": "<string>"}`
/// (design §6.1) -- the task-detail screen's own entry point.
Widget buildTaskRenderer(BuildContext context, Map<String, dynamic> definition) {
  final taskId = definition['task_id'];
  if (taskId is! String) {
    return RendererStateView<TaskDetail>(
      state: staleVersionState<TaskDetail>(
        UnknownFieldType(fieldName: 'task_id', rawType: '${taskId.runtimeType}'),
      ),
      contentBuilder: (_, _) => const SizedBox.shrink(),
      onRetryBackpressure: () async {},
    );
  }
  return TaskDetailScreen(taskId: taskId);
}

/// Composes [TaskDetailController] (task metadata + claim) and
/// [FormRendererController] (REQ-427, unmodified) -- two independent
/// `RendererStateView`s stacked vertically (design §6.2).
class TaskDetailScreen extends ConsumerStatefulWidget {
  const TaskDetailScreen({
    super.key,
    required this.taskId,
    this.onClaimConflict,
  });

  final String taskId;

  /// Called when this screen's own `claim()` returns
  /// [TaskClaimNoLongerAvailable] -- the screen-composition layer's hook
  /// for calling the inbox's `refreshAfterClaimConflict()` (design §3.3's
  /// "left to the future screen-wiring code" clause, OQ-2). `null` is a
  /// valid, supported value: a task-detail screen opened outside the inbox
  /// (e.g. a deep link) has no inbox controller to refresh.
  final void Function()? onClaimConflict;

  @override
  ConsumerState<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends ConsumerState<TaskDetailScreen> {
  bool _startedLoad = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_startedLoad) return;
    _startedLoad = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = ref.read(taskDetailControllerProvider(widget.taskId));
      unawaited(controller.load());
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(taskDetailControllerProvider(widget.taskId));
    return RendererStateView<TaskDetail>(
      state: controller.state,
      contentBuilder: (context, data) => _TaskDetailBody(
        controller: controller,
        detail: data,
        onClaimConflict: widget.onClaimConflict,
      ),
      onRetryBackpressure: controller.load,
    );
  }
}

class _TaskDetailBody extends StatefulWidget {
  const _TaskDetailBody({
    required this.controller,
    required this.detail,
    required this.onClaimConflict,
  });

  final TaskDetailController controller;
  final TaskDetail detail;
  final void Function()? onClaimConflict;

  @override
  State<_TaskDetailBody> createState() => _TaskDetailBodyState();
}

class _TaskDetailBodyState extends State<_TaskDetailBody> {
  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    final formId = detail.formId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(detail.nodeName),
        Text(detail.status.name),
        if (detail.status == TaskStatus.pending)
          ElevatedButton(
            key: taskClaimButtonKey,
            onPressed: () async {
              final outcome = await widget.controller.claim();
              if (outcome is TaskClaimNoLongerAvailable) {
                widget.onClaimConflict?.call();
              }
            },
            child: Text(tr('task.claim.action')),
          ),
        _ClaimOutcomeBanner(outcome: widget.controller.lastClaimOutcome),
        if (formId != null)
          FormRendererBridge(
            taskId: detail.id,
            formId: formId,
            formVersion: detail.formVersion,
            instanceId: detail.instanceId,
          ),
      ],
    );
  }
}

class _ClaimOutcomeBanner extends StatelessWidget {
  const _ClaimOutcomeBanner({required this.outcome});

  final TaskClaimOutcome? outcome;

  @override
  Widget build(BuildContext context) {
    return switch (outcome) {
      null => const SizedBox.shrink(),
      TaskClaimSuccess() => const SizedBox.shrink(),
      TaskClaimNoLongerAvailable() => Text(
        tr('task.claim.noLongerAvailable'),
        key: taskClaimNoLongerAvailableKey,
      ),
      TaskClaimForbidden() => Text(
        tr('task.claim.forbidden'),
        key: taskClaimForbiddenKey,
      ),
      TaskClaimNetworkUnavailable() => Text(
        tr('task.claim.networkUnavailable'),
        key: taskClaimNetworkUnavailableKey,
      ),
      TaskClaimOtherFailure() => Text(
        tr('task.claim.otherFailure'),
        key: taskClaimOtherFailureKey,
      ),
    };
  }
}

/// Bridges the task-detail screen's own `taskId`/`formId`/`formVersion`/
/// `instanceId` into a [FormRendererController] (design §3.5/§3.6) --
/// `formId`/`formVersion` are passed through UNCHANGED from [TaskDetail],
/// never re-derived from any "active version" lookup (INV-4).
class FormRendererBridge extends ConsumerStatefulWidget {
  const FormRendererBridge({
    super.key,
    required this.taskId,
    required this.formId,
    required this.formVersion,
    required this.instanceId,
  });

  final String taskId;
  final String formId;
  final String? formVersion;
  final String instanceId;

  @override
  ConsumerState<FormRendererBridge> createState() => _FormRendererBridgeState();
}

class _FormRendererBridgeState extends ConsumerState<FormRendererBridge> {
  bool _startedLoad = false;

  FormRendererParams get _params => (
    taskId: widget.taskId,
    formId: widget.formId,
    formVersion: widget.formVersion,
    instanceId: widget.instanceId,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_startedLoad) return;
    _startedLoad = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = ref.read(formRendererControllerProvider(_params));
      unawaited(controller.load());
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(formRendererControllerProvider(_params));
    return RendererStateView<FormViewModel>(
      state: controller.state,
      contentBuilder: (context, data) =>
          FormRendererBody(controller: controller, viewModel: data),
      onRetryBackpressure: controller.load,
    );
  }
}

/// The task inbox -- needs no definition payload (design §6.1), so it is
/// never registered through [RendererRegistry]; a future navigation route
/// (OQ-2) constructs this widget directly.
class TaskInboxScreen extends ConsumerStatefulWidget {
  const TaskInboxScreen({super.key});

  @override
  ConsumerState<TaskInboxScreen> createState() => _TaskInboxScreenState();
}

class _TaskInboxScreenState extends ConsumerState<TaskInboxScreen> {
  bool _startedLoad = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_startedLoad) return;
    _startedLoad = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = ref.read(taskInboxControllerProvider);
      unawaited(controller.loadFirstPage());
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(taskInboxControllerProvider);
    return RendererStateView<TaskInboxPage>(
      state: controller.state,
      contentBuilder: (context, data) =>
          _TaskInboxBody(controller: controller, page: data),
      onRetryBackpressure: controller.retryLastOperation,
    );
  }
}

class _TaskInboxBody extends StatefulWidget {
  const _TaskInboxBody({required this.controller, required this.page});

  final TaskInboxController controller;
  final TaskInboxPage page;

  @override
  State<_TaskInboxBody> createState() => _TaskInboxBodyState();
}

class _TaskInboxBodyState extends State<_TaskInboxBody> {
  final Map<String, TaskClaimOutcome?> _rowOutcomes = {};

  @override
  Widget build(BuildContext context) {
    final items = widget.page.items;
    return ListView.builder(
      key: const Key('task-inbox-items'),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return ListTile(
          key: taskInboxItemKey(item.id),
          title: Text(item.nodeName),
          trailing: ElevatedButton(
            key: taskInboxClaimKey(item.id),
            onPressed: () async {
              final outcome = await widget.controller.claim(item.id);
              setState(() => _rowOutcomes[item.id] = outcome);
            },
            child: Text(tr('task.claim.action')),
          ),
          subtitle: _ClaimOutcomeBanner(outcome: _rowOutcomes[item.id]),
        );
      },
    );
  }
}

// ── §6/§7 Provider wiring ────────────────────────────────────────────

final taskInboxControllerProvider = ChangeNotifierProvider<TaskInboxController>((
  ref,
) {
  return TaskInboxController(client: ref.watch(apiClientProvider));
});

final taskDetailControllerProvider =
    ChangeNotifierProvider.family<TaskDetailController, String>((ref, taskId) {
      return TaskDetailController(
        client: ref.watch(apiClientProvider),
        taskId: taskId,
      );
    });
