/// List renderer: interprets `list` definitions — reads the entity
/// definition (`GET /api/v1/entities/definitions/active/:name`) and queries
/// records via `POST /api/v1/entities/query` with filters and keyset
/// pagination on `next_cursor`. See
/// `lib/letflow/design/req426-mobile-renderer-state-and-list.md` §3 for the
/// full design this file implements.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart' show PostCapableHttpGateway;
import '../../api/api_error.dart' show ApiError;
import '../../bootstrap/navigation_bootstrap.dart' show apiClientProvider;
import '../renderer_state.dart';
import '../renderer_state_view.dart';

// ── §3.4 `EntityFieldDef` — the client-side field-definition shape ────────

/// The nine closed field-type strings `entities.ex`'s `@field_type_strings`
/// emits (design §3.3). Dart reserves `enum` as a keyword — the wire value
/// `"enum"` maps to the Dart identifier `enum_`.
enum EntityFieldType {
  string,
  integer,
  decimal,
  boolean,
  date,
  datetime,
  enum_,
  json,
  localizedText;

  /// Returns `null` — never throws — for an unrecognized string, so the
  /// caller can distinguish "recognized type" from "drift" and produce
  /// [UnknownFieldType] itself.
  static EntityFieldType? fromWire(String raw) {
    return switch (raw) {
      'string' => EntityFieldType.string,
      'integer' => EntityFieldType.integer,
      'decimal' => EntityFieldType.decimal,
      'boolean' => EntityFieldType.boolean,
      'date' => EntityFieldType.date,
      'datetime' => EntityFieldType.datetime,
      'enum' => EntityFieldType.enum_,
      'json' => EntityFieldType.json,
      'localized_text' => EntityFieldType.localizedText,
      _ => null,
    };
  }
}

@immutable
class EntityFieldDef {
  const EntityFieldDef({
    required this.name,
    required this.type,
    required this.rawType,
    required this.queried,
  });

  final String name;

  /// `null` means "drift" — a wire type string outside the nine known
  /// values. [rawType] is always kept even when this is `null`, so
  /// [UnknownFieldType]'s `rawType` field has something to report.
  final EntityFieldType? type;
  final String rawType;

  /// Only `queried == true` fields are offered in the filter UI, mirroring
  /// `EntityFilterBuilder.tsx`'s own `fields.filter((f) => f.queried ===
  /// true)`. Defaults `false` if absent.
  final bool queried;

  factory EntityFieldDef.fromJson(Map<String, dynamic> json) {
    final rawType = json['type'] as String? ?? '';
    return EntityFieldDef(
      name: json['name'] as String? ?? '',
      type: EntityFieldType.fromWire(rawType),
      rawType: rawType,
      queried: json['queried'] as bool? ?? false,
    );
  }
}

// ── §3.3 `FilterClause`/`SortClause` — the backend's own closed op set ─────

/// The backend's own closed 12-value operator set
/// (`Letflow.Entities.Query.Types.parse_filter_op/1`) — deliberately NOT the
/// same set `EntityFilterBuilder.tsx`'s `ALL_OPS` uses (design §3.3/OQ-6).
enum FilterOp {
  eq,
  neq,
  gt,
  gte,
  lt,
  lte,
  in_,
  notIn,
  contains,
  startsWith,
  isNull,
  isNotNull;

  /// Maps back to the exact backend wire string.
  String get wireValue {
    return switch (this) {
      FilterOp.eq => 'eq',
      FilterOp.neq => 'neq',
      FilterOp.gt => 'gt',
      FilterOp.gte => 'gte',
      FilterOp.lt => 'lt',
      FilterOp.lte => 'lte',
      FilterOp.in_ => 'in',
      FilterOp.notIn => 'not_in',
      FilterOp.contains => 'contains',
      FilterOp.startsWith => 'starts_with',
      FilterOp.isNull => 'is_null',
      FilterOp.isNotNull => 'is_not_null',
    };
  }

  /// `value` is only ever meaningful for an operator that takes one —
  /// `is_null`/`is_not_null` take none, mirroring the server's own
  /// `Map.has_key?` arity check.
  bool get takesValue => this != FilterOp.isNull && this != FilterOp.isNotNull;
}

@immutable
class FilterClause {
  const FilterClause({required this.field, required this.op, this.value});

  final String field;
  final FilterOp op;
  final Object? value;

  Map<String, dynamic> toJson() {
    return {
      'field': field,
      'op': op.wireValue,
      if (op.takesValue) 'value': value,
    };
  }
}

enum SortDir {
  asc,
  desc;

  String get wireValue => this == SortDir.asc ? 'asc' : 'desc';
}

@immutable
class SortClause {
  const SortClause({required this.field, required this.dir});

  final String field;
  final SortDir dir;

  Map<String, dynamic> toJson() => {'field': field, 'dir': dir.wireValue};
}

// ── §3.5 `ListPage` — the list renderer's own `RendererState<T>` payload ──

@immutable
class ListPage {
  const ListPage({
    required this.fields,
    required this.records,
    required this.nextCursor,
  });

  final List<EntityFieldDef> fields;
  final List<Map<String, dynamic>> records;
  final String? nextCursor;
}

/// Which operation most recently transitioned the controller into
/// `RendererBackpressure`, so `retryLastOperation` can re-issue the exact
/// same request rather than a fresh Search's (possibly-changed) params.
enum _LastOperation { firstPage, nextPage }

// ── §3.5 `ListRendererController` ──────────────────────────────────────────

/// Drives the list renderer's own `RendererState<ListPage>` (design §3.5).
/// A `ChangeNotifier`, mirroring `DefinitionHomeController`'s own plain-
/// class-behind-a-provider Riverpod style.
class ListRendererController extends ChangeNotifier {
  ListRendererController({required this.client, required this.entityType});

  final PostCapableHttpGateway client;
  final String entityType;

  static const String _definitionsPathPrefix =
      '/api/v1/entities/definitions/active/';
  static const String _queryPath = '/api/v1/entities/query';

  RendererState<ListPage> _state = const RendererLoading<ListPage>();
  RendererState<ListPage> get state => _state;

  List<FilterClause> _committedFilters = const [];
  List<SortClause> _committedSort = const [];
  _LastOperation? _lastOperation;

  /// The exact `(fields, cursor, existingRecords)` the most recent
  /// `loadNextPage` call issued Call 2 with — captured separately from
  /// `_state` because a failed next-page attempt overwrites `_state` with
  /// the error/backpressure state itself, so the pre-failure content is not
  /// otherwise recoverable for `retryLastOperation` to reuse.
  ({
    List<EntityFieldDef> fields,
    String? cursor,
    List<Map<String, dynamic>> existingRecords,
  })?
  _lastNextPageArgs;

  /// Guards AC3's exactness ("exactly one next-page request ... per
  /// scroll-to-end") — INV-5: never a second in-flight request for the same
  /// controller instance.
  bool _requestInFlight = false;

  void _setState(RendererState<ListPage> next) {
    _state = next;
    notifyListeners();
  }

  /// Sets `state` to [RendererLoading] immediately, then: Call 1, then (on
  /// success) Call 2 with `cursor: null`, clearing any previously
  /// accumulated records (design §3.5).
  Future<void> loadFirstPage({
    required List<FilterClause> filters,
    required List<SortClause> sort,
  }) async {
    if (_requestInFlight) return;
    _requestInFlight = true;
    _lastOperation = _LastOperation.firstPage;
    _committedFilters = filters;
    _committedSort = sort;
    _setState(const RendererLoading<ListPage>());

    try {
      final fields = await _fetchFields();
      if (fields == null) return; // Already set to a terminal state below.
      await _fetchPage(fields: fields, cursor: null, existingRecords: const []);
    } finally {
      _requestInFlight = false;
    }
  }

  /// A no-op (never issues a request) if `state` is not currently
  /// `RendererContent` or if that content's `nextCursor` is `null` (AC3's
  /// stop condition) — enforced here, not just at the UI/scroll-listener
  /// level.
  Future<void> loadNextPage() async {
    if (_requestInFlight) return;
    final current = _state;
    if (current is! RendererContent<ListPage>) return;
    final page = current.data;
    if (page.nextCursor == null) return;

    _requestInFlight = true;
    _lastOperation = _LastOperation.nextPage;
    _lastNextPageArgs = (
      fields: page.fields,
      cursor: page.nextCursor,
      existingRecords: page.records,
    );
    try {
      await _fetchPage(
        fields: page.fields,
        cursor: page.nextCursor,
        existingRecords: page.records,
      );
    } finally {
      _requestInFlight = false;
    }
  }

  /// Re-issues whichever of `loadFirstPage`/`loadNextPage` most recently
  /// produced the `RendererBackpressure` state, with the exact same
  /// arguments — never a fresh Search's params (design §3.5).
  Future<void> retryLastOperation() async {
    switch (_lastOperation) {
      case _LastOperation.firstPage:
        await loadFirstPage(filters: _committedFilters, sort: _committedSort);
      case _LastOperation.nextPage:
        final args = _lastNextPageArgs;
        if (args == null || _requestInFlight) return;
        _requestInFlight = true;
        try {
          await _fetchPage(
            fields: args.fields,
            cursor: args.cursor,
            existingRecords: args.existingRecords,
          );
        } finally {
          _requestInFlight = false;
        }
      case null:
        return;
    }
  }

  /// Call 1 — `GET /api/v1/entities/definitions/active/:name`. Returns the
  /// parsed field list on success, or `null` after already setting `_state`
  /// to the mapped terminal state (fetch-failure/permission-denied/etc., or
  /// stale-version on an unknown field type — short-circuits before Call 2
  /// is ever issued).
  Future<List<EntityFieldDef>?> _fetchFields() async {
    final Map<String, dynamic> body;
    try {
      final response = await client.get('$_definitionsPathPrefix$entityType');
      body = response.data as Map<String, dynamic>;
    } on ApiError catch (e) {
      _setState(rendererStateForError<ListPage>(e));
      return null;
    }

    final definition = body['definition'] as Map<String, dynamic>? ?? const {};
    final rawFields = (definition['fields'] as List? ?? const [])
        .cast<Map<String, dynamic>>();

    final fields = <EntityFieldDef>[];
    for (final rawField in rawFields) {
      final field = EntityFieldDef.fromJson(rawField);
      if (field.type == null) {
        // The WHOLE list renderer renders `RendererStaleVersion`, not just
        // that one field silently dropped (design §3.3, "fails loudly").
        _setState(
          staleVersionState<ListPage>(
            UnknownFieldType(fieldName: field.name, rawType: field.rawType),
          ),
        );
        return null;
      }
      fields.add(field);
    }
    return fields;
  }

  /// Call 2 — `POST /api/v1/entities/query`, issued only after Call 1
  /// succeeds. Appends the new page's records to [existingRecords] and sets
  /// `_state` to the resulting `RendererContent`, or to the mapped error
  /// state on failure.
  Future<void> _fetchPage({
    required List<EntityFieldDef> fields,
    required String? cursor,
    required List<Map<String, dynamic>> existingRecords,
  }) async {
    final Map<String, dynamic> body;
    try {
      final response = await client.post(
        _queryPath,
        data: {
          'entity_type': entityType,
          'filters': _committedFilters.map((f) => f.toJson()).toList(),
          'sort': _committedSort.map((s) => s.toJson()).toList(),
          'cursor': ?cursor,
        },
      );
      body = response.data as Map<String, dynamic>;
    } on ApiError catch (e) {
      _setState(rendererStateForError<ListPage>(e));
      return;
    }

    final items = (body['items'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final nextCursor = body['next_cursor'] as String?;

    _setState(
      RendererContent<ListPage>(
        data: ListPage(
          fields: fields,
          records: [...existingRecords, ...items],
          nextCursor: nextCursor,
        ),
      ),
    );
  }
}

// ── §3.1/§3.2 `buildListRenderer` — the registered `"list"` builder ───────

/// Reads `definition["entity_type"]` — the `"list"` definition's own
/// required shape is exactly `{"entity_type": "<string>"}` (design §3.2).
/// Renders `RendererStaleVersion` if absent or non-string, treated the same
/// as any other definition-shape drift.
Widget buildListRenderer(BuildContext context, Map<String, dynamic> definition) {
  final entityType = definition['entity_type'];
  if (entityType is! String) {
    return RendererStateView<ListPage>(
      state: staleVersionState<ListPage>(
        UnknownFieldType(fieldName: 'entity_type', rawType: '${entityType.runtimeType}'),
      ),
      contentBuilder: (_, _) => const SizedBox.shrink(),
      onRetryBackpressure: () async {},
    );
  }

  return _ListRendererRoot(entityType: entityType);
}

/// Triggers the first page load exactly once, then forwards
/// `ListRendererController.state` into `RendererStateView<ListPage>` —
/// `RendererStateView` is the outermost widget this returns (design §4);
/// `ref.watch` on a `ChangeNotifierProvider` rebuilds this on every
/// `notifyListeners()` call, so no separate `AnimatedBuilder`/listener is
/// needed.
class _ListRendererRoot extends ConsumerStatefulWidget {
  const _ListRendererRoot({required this.entityType});

  final String entityType;

  @override
  ConsumerState<_ListRendererRoot> createState() => _ListRendererRootState();
}

class _ListRendererRootState extends ConsumerState<_ListRendererRoot> {
  bool _startedLoad = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_startedLoad) return;
    _startedLoad = true;
    final controller = ref.read(listRendererControllerProvider(widget.entityType));
    // Fire-and-forget — `loadFirstPage` itself sets `RendererLoading`
    // synchronously before its first `await`, so the very first `build`
    // below already observes that state.
    controller.loadFirstPage(filters: const [], sort: const []);
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(
      listRendererControllerProvider(widget.entityType),
    );
    return RendererStateView<ListPage>(
      state: controller.state,
      contentBuilder: (context, data) =>
          _ListRendererBody(controller: controller, page: data),
      onRetryBackpressure: controller.retryLastOperation,
    );
  }
}

/// The list renderer's own body — a scrollable list of records, triggering
/// `loadNextPage` on scroll-to-end (AC3).
class _ListRendererBody extends StatefulWidget {
  const _ListRendererBody({required this.controller, required this.page});

  final ListRendererController controller;
  final ListPage page;

  @override
  State<_ListRendererBody> createState() => _ListRendererBodyState();
}

class _ListRendererBodyState extends State<_ListRendererBody> {
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
      widget.controller.loadNextPage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final records = widget.page.records;
    return ListView.builder(
      key: const Key('list-renderer-records'),
      controller: _scrollController,
      itemCount: records.length,
      itemBuilder: (context, index) {
        final record = records[index];
        final recordId = record['record_id'] as String? ?? '$index';
        return ListTile(
          key: Key('list-renderer-record-$recordId'),
          title: Text(recordId),
        );
      },
    );
  }
}

// ── §6 Provider wiring — `listRendererControllerProvider` ──────────────────

/// One [ListRendererController] per `entityType`, backed by the app's single
/// [HttpGateway] (`apiClientProvider`, `navigation_bootstrap.dart`). Kept as
/// a local family provider in this file rather than `navigation_bootstrap
/// .dart` because this requirement introduces no new screen/route — a
/// future requirement wiring the list renderer into a real route reads this
/// same provider. Unit tests are not expected to go through this provider at
/// all — mirroring `PinnedFormResolver`/`DefinitionSyncService`'s own test
/// precedent, a test constructs a [ListRendererController] directly with a
/// fake [HttpGateway] and never touches Riverpod for it.
final listRendererControllerProvider =
    ChangeNotifierProvider.family<ListRendererController, String>((
      ref,
      entityType,
    ) {
      return ListRendererController(
        client: ref.watch(apiClientProvider),
        entityType: entityType,
      );
    });
