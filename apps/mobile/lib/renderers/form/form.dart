/// Form renderer: interprets `form` definitions, including on-device
/// evaluation of `visible_when`/`computed`/cross-field validation in the
/// `Letflow.Engine.Expr` grammar (`MOB-4`, decision `0020` clause D1a).
///
/// See `lib/letflow/design/req427-form-renderer.md` for the full design this
/// file implements. Builds on REQ-426's `RendererState`/`RendererStateView`
/// framework (`../renderer_state.dart`/`../renderer_state_view.dart`,
/// unchanged) and REQ-294's Dart `Letflow.Engine.Expr` evaluator
/// (`../../expr/expr.dart`, unchanged) -- this file composes both, adding no
/// expression-evaluation logic of its own (D1a's "never extended locally").
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart'
    show PostCapableHttpGateway, buildFileUploadFormData;
import '../../api/api_error.dart'
    show ApiError, ApiFieldError, NetworkUnavailableError, ValidationError;
import '../../bootstrap/navigation_bootstrap.dart' show apiClientProvider;
import '../../definitions/pinned_form_resolver.dart' as pinned_form;
import '../../expr/expr.dart';
import '../renderer_state.dart';
import '../renderer_state_view.dart';

// ── §1.1 `FormFieldKind` — this renderer's closed field-kind enum ─────────

/// The SPA's real 7-type wire union (`text`/`number`/`boolean`/`date`/
/// `datetime`/`select`/`object`/`array`), plus this design's own `file`
/// addition (§1.3/OQ-2) -- 9 wire spellings total (design §1.1/§1.2).
/// `computed`/`hidden` are never members of this enum: they are orthogonal
/// `x-ui` flags any of these 9 kinds may carry (§1.2), never a kind of their
/// own.
enum FormFieldKind {
  text,
  number,
  boolean,
  date,
  datetime,
  select,
  object,
  array,
  file;

  /// Returns `null` -- never throws -- for a `type` string outside the 9
  /// wire spellings resolved below (design §1.2's table, checked in the
  /// exact order given there), so the caller can distinguish "recognized
  /// kind" from "drift" and produce [UnknownFieldType] itself, mirroring
  /// `EntityFieldType.fromWire`'s exact null-on-miss convention (REQ-426
  /// §3.4).
  static FormFieldKind? fromFieldSchema(Map<String, dynamic> fieldSchema) {
    final type = fieldSchema['type'];
    if (type is! String) return null;

    switch (type) {
      case 'boolean':
        return FormFieldKind.boolean;
      case 'select':
        return FormFieldKind.select;
      case 'date':
        return FormFieldKind.date;
      case 'number':
      case 'integer':
        return FormFieldKind.number;
      case 'object':
        return FormFieldKind.object;
      case 'array':
        return FormFieldKind.array;
      case 'file':
        return FormFieldKind.file;
      case 'string':
        final enumValue = fieldSchema['enum'];
        if (enumValue is List && enumValue.isNotEmpty) {
          return FormFieldKind.select;
        }
        final format = fieldSchema['format'];
        if (format == 'date') return FormFieldKind.date;
        if (format == 'date-time') return FormFieldKind.datetime;
        return FormFieldKind.text;
      default:
        // Every other `type` value, including the literal strings
        // `"multi-select"`, `"reference"`, `"hidden"`, `"computed"`, or any
        // other unrecognized token (design §1.2's closing paragraph).
        return null;
    }
  }
}

/// Exported so a widget test can assert on a field's own primary
/// interactive element without knowing this file's internal widget classes
/// (design §6.2).
Key formFieldInputKey(String fieldName) => Key('form-field-$fieldName');

// ── §2.1 `FormFieldDef` ─────────────────────────────────────────────────

@immutable
class CrossFieldValidationDef {
  const CrossFieldValidationDef({required this.expression, required this.message});

  final String expression;
  final String message;
}

@immutable
class FormFieldDef {
  const FormFieldDef({
    required this.name,
    required this.kind,
    required this.title,
    required this.required,
    this.description,
    this.enumValues,
    this.visibleWhenExpr,
    this.computedExpr,
    this.crossFieldValidation,
  });

  final String name;
  final FormFieldKind kind;
  final String title;
  final bool required;
  final String? description;
  final List<String>? enumValues;
  final String? visibleWhenExpr;
  final String? computedExpr;
  final CrossFieldValidationDef? crossFieldValidation;
}

// ── §2.2 `FormSchema.parse` ─────────────────────────────────────────────

sealed class FormParseResult {
  const FormParseResult();
}

final class FormParseOk extends FormParseResult {
  const FormParseOk(this.fields);
  final List<FormFieldDef> fields;
}

final class FormParseUnknownFieldType extends FormParseResult {
  const FormParseUnknownFieldType({required this.fieldName, required this.rawType});
  final String fieldName;
  final String rawType;
}

/// Never throws (design §2.2) -- a malformed `formSchema` (not a map,
/// `properties` not a map, a `properties` entry not itself a map) is read
/// as leniently as `parseFormSchema`'s own defensive casts, defaulting to
/// the same "empty form" [FormParseOk] rather than crashing.
FormParseResult parseFormSchema(Map<String, dynamic>? formSchema) {
  if (formSchema == null) return const FormParseOk([]);
  final properties = formSchema['properties'];
  if (properties is! Map) return const FormParseOk([]);

  final requiredRaw = formSchema['required'];
  final requiredFields = requiredRaw is List
      ? requiredRaw.whereType<String>().toSet()
      : const <String>{};

  final fields = <FormFieldDef>[];
  for (final entry in properties.entries) {
    final name = entry.key.toString();
    final rawFieldSchema = entry.value;
    if (rawFieldSchema is! Map) {
      // Not itself a map -- leniently skipped, matching this function's own
      // "never throws" defensive-cast discipline (no acceptance criterion
      // names a dedicated "malformed single field" state beyond the
      // unknown-type case below).
      continue;
    }
    final fieldSchema = rawFieldSchema.cast<String, dynamic>();

    final kind = FormFieldKind.fromFieldSchema(fieldSchema);
    if (kind == null) {
      final rawTypeValue = fieldSchema['type'];
      final rawType = rawTypeValue is String ? rawTypeValue : '';
      // The WHOLE parse short-circuits here (§1.4/INV-2) -- never a partial
      // `FormParseOk` with this one field dropped.
      return FormParseUnknownFieldType(fieldName: name, rawType: rawType);
    }

    final xUi = fieldSchema['x-ui'];
    final xUiMap = xUi is Map ? xUi.cast<String, dynamic>() : const <String, dynamic>{};

    final enumValue = fieldSchema['enum'];
    final enumValues = enumValue is List
        ? enumValue.map((e) => e.toString()).toList()
        : null;

    CrossFieldValidationDef? crossFieldValidation;
    final cfvRaw = xUiMap['cross_field_validation'];
    if (cfvRaw is Map) {
      final expression = cfvRaw['expression'];
      final message = cfvRaw['message'];
      if (expression is String && message is String) {
        crossFieldValidation = CrossFieldValidationDef(
          expression: expression,
          message: message,
        );
      }
    }

    fields.add(
      FormFieldDef(
        name: name,
        kind: kind,
        title: (fieldSchema['title'] as String?) ?? name,
        required: requiredFields.contains(name),
        description: fieldSchema['description'] as String?,
        enumValues: enumValues,
        visibleWhenExpr: xUiMap['visible_when'] as String?,
        computedExpr: xUiMap['computed'] as String?,
        crossFieldValidation: crossFieldValidation,
      ),
    );
  }
  return FormParseOk(fields);
}

// ── §6.3 `FileUploadOutcome` ────────────────────────────────────────────

sealed class FileUploadOutcome {
  const FileUploadOutcome();
}

final class FileUploadInFlight extends FileUploadOutcome {
  const FileUploadInFlight();
}

final class FileUploadSuccess extends FileUploadOutcome {
  const FileUploadSuccess({required this.attachmentId, required this.fileName});
  final String attachmentId;
  final String fileName;
}

final class FileUploadNetworkUnavailable extends FileUploadOutcome {
  const FileUploadNetworkUnavailable();
}

final class FileUploadOtherFailure extends FileUploadOutcome {
  const FileUploadOtherFailure({required this.cause});
  final Object cause;
}

// ── §5.2 `FormSubmitOutcome` ────────────────────────────────────────────

sealed class FormSubmitOutcome {
  const FormSubmitOutcome();
}

final class SubmitInFlight extends FormSubmitOutcome {
  const SubmitInFlight();
}

/// Deliberately has no field for `complete_result_map/1`'s 5th key
/// (`"variables"`, the instance's full post-merge variable set) -- a
/// structural guarantee (INV-5, design §5.4) that no future caller can read
/// it back as "the corrected field values" and re-derive authority from the
/// client's own just-submitted, not-yet-server-checked data.
final class SubmitSuccess extends FormSubmitOutcome {
  const SubmitSuccess({
    required this.taskId,
    required this.instanceId,
    required this.instanceStatus,
    required this.currentNodes,
    required this.completedAt,
  });

  final String taskId;
  final String instanceId;
  final String instanceStatus;
  final List<dynamic> currentNodes;
  final String completedAt;
}

final class SubmitNetworkUnavailable extends FormSubmitOutcome {
  const SubmitNetworkUnavailable();
}

final class SubmitValidationError extends FormSubmitOutcome {
  const SubmitValidationError({required this.fieldErrors});
  final List<ApiFieldError> fieldErrors;
}

final class SubmitOtherFailure extends FormSubmitOutcome {
  const SubmitOtherFailure({required this.cause});
  final Object cause;
}

// ── §3.1 `FormViewModel` ────────────────────────────────────────────────

@immutable
class FormViewModel {
  const FormViewModel({
    required this.fields,
    required this.values,
    required this.visibility,
    required this.computedValues,
    required this.crossFieldMessages,
    required this.crossFieldUnevaluable,
    required this.fileUploads,
    required this.resolvedComputedDisplayValues,
    required this.submitOutcome,
  });

  final List<FormFieldDef> fields;

  /// Current live form values, top-level keys only. Never mutated in place
  /// -- every change produces a new [FormViewModel] (INV-3).
  final Map<String, Object?> values;

  final Map<String, FieldExpressionOutcome> visibility;
  final Map<String, FieldExpressionOutcome> computedValues;
  final Map<String, String?> crossFieldMessages;
  final Map<String, String> crossFieldUnevaluable;
  final Map<String, FileUploadOutcome> fileUploads;

  /// A `computed` field's successfully-evaluated non-null value (design
  /// §4.3/OQ-4) -- a second, parallel map kept outside
  /// [FieldExpressionOutcome] entirely, since that sealed hierarchy (REQ-294,
  /// unmodified here) has no variant for "evaluated successfully to a value".
  final Map<String, Object?> resolvedComputedDisplayValues;

  final FormSubmitOutcome? submitOutcome;

  FormViewModel copyWith({
    Map<String, Object?>? values,
    Map<String, FieldExpressionOutcome>? visibility,
    Map<String, FieldExpressionOutcome>? computedValues,
    Map<String, String?>? crossFieldMessages,
    Map<String, String>? crossFieldUnevaluable,
    Map<String, FileUploadOutcome>? fileUploads,
    Map<String, Object?>? resolvedComputedDisplayValues,
    FormSubmitOutcome? submitOutcome,
  }) {
    return FormViewModel(
      fields: fields,
      values: values ?? this.values,
      visibility: visibility ?? this.visibility,
      computedValues: computedValues ?? this.computedValues,
      crossFieldMessages: crossFieldMessages ?? this.crossFieldMessages,
      crossFieldUnevaluable: crossFieldUnevaluable ?? this.crossFieldUnevaluable,
      fileUploads: fileUploads ?? this.fileUploads,
      resolvedComputedDisplayValues:
          resolvedComputedDisplayValues ?? this.resolvedComputedDisplayValues,
      submitOutcome: submitOutcome ?? this.submitOutcome,
    );
  }
}

// ── §3.2/§4/§5/§6.3 `FormRendererController` ────────────────────────────

/// Drives the form renderer's own `RendererState<FormViewModel>` (design
/// §3.2). A `ChangeNotifier`, mirroring `ListRendererController`'s own
/// plain-class-behind-a-provider Riverpod style.
class FormRendererController extends ChangeNotifier {
  FormRendererController({
    required this.client,
    required this.pinnedFormResolver,
    required this.manifestCapabilities,
    required this.taskId,
    required this.formId,
    required this.formVersion,
    required this.instanceId,
  });

  final PostCapableHttpGateway client;
  final pinned_form.PinnedFormResolver pinnedFormResolver;
  final List<String> manifestCapabilities;
  final String taskId;
  final String formId;
  final String? formVersion;
  final String instanceId;

  RendererState<FormViewModel> _state = const RendererLoading<FormViewModel>();
  RendererState<FormViewModel> get state => _state;

  void _setState(RendererState<FormViewModel> next) {
    _state = next;
    notifyListeners();
  }

  // ── §3.3 `load()` ──────────────────────────────────────────────────────

  /// Resolves the pinned schema into the first [RendererContent] (design
  /// §3.3). No network call beyond [pinnedFormResolver]'s own -- a cache-hit
  /// resolution requires zero network calls, so this succeeds fully offline
  /// whenever the schema is already cached (AC2's premise).
  Future<void> load() async {
    _setState(const RendererLoading<FormViewModel>());

    final resolution = await pinnedFormResolver.resolve(
      taskId: taskId,
      formId: formId,
      formVersion: formVersion,
    );

    if (resolution is pinned_form.PinnedFormUnavailable) {
      _setState(
        staleVersionState<FormViewModel>(
          PinnedFormUnavailable(reason: resolution.reason),
        ),
      );
      return;
    }

    final formSchema = (resolution as pinned_form.PinnedFormResolved).formSchema;
    final parseResult = parseFormSchema(formSchema);

    if (parseResult is FormParseUnknownFieldType) {
      _setState(
        staleVersionState<FormViewModel>(
          UnknownFieldType(
            fieldName: parseResult.fieldName,
            rawType: parseResult.rawType,
          ),
        ),
      );
      return;
    }

    final fields = (parseResult as FormParseOk).fields;
    final compatibility = evaluatorCompatibility(manifestCapabilities);
    final initial = _recomputeExpressions(
      fields: fields,
      values: const {},
      manifestCompatible: compatibility.compatible,
      fileUploads: const {},
      submitOutcome: null,
    );
    _setState(RendererContent<FormViewModel>(data: initial));
  }

  // ── §4.2 Per-change recomputation ─────────────────────────────────────

  /// Never debounced (design §4.2) -- matches `useFormExpressions`'s own
  /// per-render recomputation semantics.
  FormViewModel _recomputeExpressions({
    required List<FormFieldDef> fields,
    required Map<String, Object?> values,
    required bool manifestCompatible,
    required Map<String, FileUploadOutcome> fileUploads,
    required FormSubmitOutcome? submitOutcome,
  }) {
    final computedOutcomes = <String, FieldExpressionOutcome>{};
    final resolvedComputed = <String, Object?>{};
    final visibilityOutcomes = <String, FieldExpressionOutcome>{};
    final crossFieldMessages = <String, String?>{};
    final crossFieldUnevaluable = <String, String>{};

    if (!manifestCompatible) {
      // §4.1: every field carrying an expression gets StaleVersion without
      // attempting to evaluate it at all.
      const reason =
          'this client cannot evaluate an expression this form requires '
          '(manifest incompatible)';
      for (final field in fields) {
        final computedExpr = field.computedExpr;
        if (computedExpr != null) {
          computedOutcomes[field.name] =
              StaleVersion(expression: computedExpr, reason: reason);
        }
        final visibleWhenExpr = field.visibleWhenExpr;
        if (visibleWhenExpr != null) {
          visibilityOutcomes[field.name] =
              StaleVersion(expression: visibleWhenExpr, reason: reason);
        }
        if (field.crossFieldValidation != null) {
          crossFieldUnevaluable[field.name] = reason;
        }
      }
      return FormViewModel(
        fields: fields,
        values: values,
        visibility: visibilityOutcomes,
        computedValues: computedOutcomes,
        crossFieldMessages: crossFieldMessages,
        crossFieldUnevaluable: crossFieldUnevaluable,
        fileUploads: fileUploads,
        resolvedComputedDisplayValues: resolvedComputed,
        submitOutcome: submitOutcome,
      );
    }

    // Step 1 (§4.2.1): `computed` fields first, declaration order (OQ-5 --
    // no topological sort).
    for (final field in fields) {
      final expr = field.computedExpr;
      if (expr == null) continue;
      final result = evaluateExpression(expr, values);
      if (result is EvaluateOk) {
        final value = result.value;
        computedOutcomes[field.name] = const Blank();
        if (value != null) {
          resolvedComputed[field.name] = value;
        }
      } else {
        computedOutcomes[field.name] =
            StaleVersion(expression: expr, reason: describeFailure(result));
      }
    }

    final extendedValues = {...values, ...resolvedComputed};

    // Step 2 (§4.2.2): `visible_when` fields next, against `extendedValues`.
    for (final field in fields) {
      visibilityOutcomes[field.name] =
          evaluateVisibility(field.visibleWhenExpr, extendedValues);
    }

    // Step 3 (§4.2.3): `cross_field_validation` fields last.
    for (final field in fields) {
      final cfv = field.crossFieldValidation;
      if (cfv == null) continue;
      final result = evaluateExpression(cfv.expression, extendedValues);
      switch (result) {
        case EvaluateOk(:final value) when value == true:
          crossFieldMessages[field.name] = null;
        case EvaluateOk(:final value) when value == false:
          crossFieldMessages[field.name] = cfv.message;
        case EvaluateOk():
          crossFieldUnevaluable[field.name] =
              'expression did not evaluate to a boolean';
        case _:
          crossFieldUnevaluable[field.name] = describeFailure(result);
      }
    }

    return FormViewModel(
      fields: fields,
      values: values,
      visibility: visibilityOutcomes,
      computedValues: computedOutcomes,
      crossFieldMessages: crossFieldMessages,
      crossFieldUnevaluable: crossFieldUnevaluable,
      fileUploads: fileUploads,
      resolvedComputedDisplayValues: resolvedComputed,
      submitOutcome: submitOutcome,
    );
  }

  /// Recomputes visibility/computed/cross-field synchronously against the
  /// updated value set (design §4.2) -- called on every keystroke/selection
  /// change, never debounced.
  void updateFieldValue(String fieldName, Object? value) {
    final current = _state;
    if (current is! RendererContent<FormViewModel>) return;
    final vm = current.data;

    final newValues = {...vm.values, fieldName: value};
    final compatibility = evaluatorCompatibility(manifestCapabilities);
    final updated = _recomputeExpressions(
      fields: vm.fields,
      values: newValues,
      manifestCompatible: compatibility.compatible,
      fileUploads: vm.fileUploads,
      submitOutcome: vm.submitOutcome,
    );
    _setState(RendererContent<FormViewModel>(data: updated));
  }

  // ── §6.3 `pickAndUploadFile` ───────────────────────────────────────────

  Future<void> pickAndUploadFile(
    String fieldName, {
    required String fileName,
    required String contentType,
    required List<int> bytes,
  }) async {
    _setFileUploadOutcome(fieldName, const FileUploadInFlight());

    try {
      final formData = buildFileUploadFormData(
        bytes: bytes,
        fileName: fileName,
        contentType: contentType,
      );
      final response = await client.post(
        '/instances/$instanceId/attachments',
        data: formData,
      );
      final body = response.data as Map<String, dynamic>;
      final attachmentId = body['id'] as String;

      // This is the single point where a `file` field's entry ever appears
      // in `FormViewModel.values` (design §1.3) -- the value is the
      // attachment's id, never raw bytes/metadata.
      final current = _state;
      if (current is! RendererContent<FormViewModel>) return;
      final vm = current.data;
      final newValues = {...vm.values, fieldName: attachmentId};
      _setState(
        RendererContent<FormViewModel>(
          data: vm.copyWith(
            values: newValues,
            fileUploads: {
              ...vm.fileUploads,
              fieldName: FileUploadSuccess(
                attachmentId: attachmentId,
                fileName: fileName,
              ),
            },
          ),
        ),
      );
    } on ApiError catch (e) {
      // `values` untouched on failure -- absent, not blank (design §6.3
      // step 4/5).
      final outcome = e is NetworkUnavailableError
          ? const FileUploadNetworkUnavailable()
          : FileUploadOtherFailure(cause: e);
      _setFileUploadOutcome(fieldName, outcome);
    }
  }

  void _setFileUploadOutcome(String fieldName, FileUploadOutcome outcome) {
    final current = _state;
    if (current is! RendererContent<FormViewModel>) return;
    final vm = current.data;
    _setState(
      RendererContent<FormViewModel>(
        data: vm.copyWith(fileUploads: {...vm.fileUploads, fieldName: outcome}),
      ),
    );
  }

  // ── §5.3 `submit()` ────────────────────────────────────────────────────

  /// Never swaps `state` away from [RendererContent] (design §5.1/INV-6) --
  /// a submit failure tracks its own outcome inside [FormViewModel
  /// .submitOutcome], never by discarding the in-progress view model (which
  /// would discard every typed value, AC4's exact failure this avoids).
  Future<void> submit() async {
    final beforeSubmit = _state;
    if (beforeSubmit is! RendererContent<FormViewModel>) return;
    final vmAtSubmitStart = beforeSubmit.data;

    // §5.3 step 1: both a hidden field's value and a computed field's
    // resolved value are submitted, never dropped -- visibility is never
    // used to filter the submit payload.
    final outputVariables = <String, Object?>{...vmAtSubmitStart.values};
    for (final entry in vmAtSubmitStart.resolvedComputedDisplayValues.entries) {
      outputVariables.putIfAbsent(entry.key, () => entry.value);
    }

    _setSubmitOutcome(const SubmitInFlight());

    try {
      final response = await client.post(
        '/api/v1/tasks/$taskId/complete',
        data: outputVariables,
      );
      final body = response.data as Map<String, dynamic>;
      _setSubmitOutcome(
        SubmitSuccess(
          taskId: body['task_id'] as String,
          instanceId: body['instance_id'] as String,
          instanceStatus: body['instance_status'] as String,
          currentNodes: (body['current_nodes'] as List?) ?? const [],
          completedAt: body['completed_at'] as String,
        ),
      );
    } on ApiError catch (e) {
      final outcome = switch (e) {
        NetworkUnavailableError() => const SubmitNetworkUnavailable(),
        ValidationError(:final fieldErrors) =>
          SubmitValidationError(fieldErrors: fieldErrors),
        _ => SubmitOtherFailure(cause: e),
      };
      _setSubmitOutcome(outcome);
    }
  }

  /// Reads the LATEST state (never the snapshot [submit] captured before its
  /// own `await`) -- `values` may have changed while the request was in
  /// flight, and this must never clobber that (design §5.3 step 6).
  void _setSubmitOutcome(FormSubmitOutcome outcome) {
    final current = _state;
    if (current is! RendererContent<FormViewModel>) return;
    final vm = current.data;
    _setState(
      RendererContent<FormViewModel>(data: vm.copyWith(submitOutcome: outcome)),
    );
  }
}

// ── §6.4.1 `ExpressionUnavailableBannerWidget` ─────────────────────────

/// Exported so a widget test can assert on this banner's key without
/// constructing it directly (design §6.4.1).
Key expressionUnavailableBannerKey(String field, String kind) =>
    Key('expr-unavailable-$field-$kind');

Key crossFieldErrorKey(String field) => Key('cross-field-error-$field');

/// A fourth, distinct visual state from "visible normal input" / "omitted
/// (hidden)" / "visible but shows nothing" -- explicitly names the field and
/// reason an expression could not be evaluated (design §6.4/AC3). [kind] is
/// one of `'visible_when' | 'computed' | 'cross_field_validation'`.
class ExpressionUnavailableBannerWidget extends StatelessWidget {
  const ExpressionUnavailableBannerWidget({
    super.key,
    required this.field,
    required this.kind,
    required this.reason,
  });

  final String field;
  final String kind;
  final String reason;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: expressionUnavailableBannerKey(field, kind),
      padding: const EdgeInsets.all(8),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Text(
        'This app cannot evaluate a condition this form needs '
        '("$field" / $kind): $reason.',
      ),
    );
  }
}

// ── §6.5 Submit UI keys ─────────────────────────────────────────────────

const Key formSubmitButtonKey = Key('form-submit-button');
const Key formSubmitInFlightKey = Key('form-submit-in-flight');
const Key formSubmitSuccessKey = Key('form-submit-success');
const Key formSubmitNetworkUnavailableKey = Key('form-submit-network-unavailable');
const Key formSubmitValidationErrorKey = Key('form-submit-validation-error');
const Key formSubmitOtherFailureKey = Key('form-submit-other-failure');

// ── §6.1/§6.2 Widget layer ──────────────────────────────────────────────

/// The `DefinitionWidgetBuilder` registered for `"form"` (design §6.1).
/// `definition`'s required shape: `task_id` (string), `form_id` (string),
/// `form_version` (string, nullable), `instance_id` (string). Absent or
/// non-string `task_id`/`form_id`/`instance_id` ->
/// `RendererStaleVersion(UnknownFieldType(...))`, the same defensive
/// pattern `buildListRenderer` already uses for its own `entity_type` key.
Widget buildFormRenderer(BuildContext context, Map<String, dynamic> definition) {
  final taskId = definition['task_id'];
  if (taskId is! String) {
    return _staleUnknownDefinitionField('task_id', taskId);
  }
  final formId = definition['form_id'];
  if (formId is! String) {
    return _staleUnknownDefinitionField('form_id', formId);
  }
  final instanceId = definition['instance_id'];
  if (instanceId is! String) {
    return _staleUnknownDefinitionField('instance_id', instanceId);
  }
  final formVersionRaw = definition['form_version'];
  if (formVersionRaw != null && formVersionRaw is! String) {
    return _staleUnknownDefinitionField('form_version', formVersionRaw);
  }
  final formVersion = formVersionRaw as String?;

  return _FormRendererRoot(
    taskId: taskId,
    formId: formId,
    formVersion: formVersion,
    instanceId: instanceId,
  );
}

Widget _staleUnknownDefinitionField(String key, Object? value) {
  return RendererStateView<FormViewModel>(
    state: staleVersionState<FormViewModel>(
      UnknownFieldType(fieldName: key, rawType: '${value.runtimeType}'),
    ),
    contentBuilder: (_, _) => const SizedBox.shrink(),
    onRetryBackpressure: () async {},
  );
}

/// The [FormRendererController]'s provider-family key.
typedef FormRendererParams = ({
  String taskId,
  String formId,
  String? formVersion,
  String instanceId,
});

/// Triggers `load()` exactly once, then forwards
/// `FormRendererController.state` into `RendererStateView<FormViewModel>` --
/// mirrors `_ListRendererRoot`'s identical pattern (REQ-426 design §4).
class _FormRendererRoot extends ConsumerStatefulWidget {
  const _FormRendererRoot({
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
  ConsumerState<_FormRendererRoot> createState() => _FormRendererRootState();
}

class _FormRendererRootState extends ConsumerState<_FormRendererRoot> {
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
    // Deferred to the post-frame callback, mirroring `_ListRendererRootState
    // .didChangeDependencies`'s identical pattern (REQ-426).
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
      // `load()` (the only caller of `RendererBackpressure`-producing error
      // classification -- which this controller's own `load()` never
      // actually performs, since `PinnedFormResolver.resolve` never throws
      // an `ApiError`) is still the only meaningful retry action available.
      onRetryBackpressure: controller.load,
    );
  }
}

/// The form renderer's own body -- one row per top-level schema field, plus
/// the submit button/outcome banner (design §6.2-§6.5).
///
/// Public (not `_`-prefixed) so a widget test can pump it directly against a
/// hand-built [FormRendererController]/[FormViewModel] pair, without going
/// through [buildFormRenderer]'s Riverpod-wired `_FormRendererRoot` (which
/// would otherwise require a full production [ApiClient]/[PinnedFormResolver]
/// stack just to exercise field-rendering behavior) -- the same
/// "controller tested directly, widget tree built by hand" split
/// `ListRendererController`'s own tests already use, extended here with an
/// actual pumped widget tree because AC1-AC5 need `find.byKey` assertions
/// that a controller-only test cannot make.
class FormRendererBody extends StatefulWidget {
  const FormRendererBody({super.key, required this.controller, required this.viewModel});

  final FormRendererController controller;
  final FormViewModel viewModel;

  @override
  State<FormRendererBody> createState() => _FormRendererBodyState();
}

class _FormRendererBodyState extends State<FormRendererBody> {
  final Map<String, TextEditingController> _textControllers = {};

  TextEditingController _textControllerFor(String name, String initialText) {
    final existing = _textControllers[name];
    if (existing != null) return existing;
    final created = TextEditingController(text: initialText);
    _textControllers[name] = created;
    return created;
  }

  @override
  void dispose() {
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.viewModel;
    final rows = <Widget>[];

    // Form-level cross-field-unevaluable banners (design §6.4, placed above
    // the field list).
    for (final fieldName in vm.crossFieldUnevaluable.keys) {
      rows.add(
        ExpressionUnavailableBannerWidget(
          field: fieldName,
          kind: 'cross_field_validation',
          reason: vm.crossFieldUnevaluable[fieldName]!,
        ),
      );
    }

    for (final field in vm.fields) {
      final visibilityOutcome = vm.visibility[field.name];

      if (visibilityOutcome is DefaultHidden) {
        // Omitted from the widget tree entirely -- not merely visually
        // hidden (design §6.4/AC3's `return null` semantics).
        continue;
      }

      if (visibilityOutcome is StaleVersion) {
        rows.add(
          ExpressionUnavailableBannerWidget(
            field: field.name,
            kind: 'visible_when',
            reason: visibilityOutcome.reason,
          ),
        );
        continue;
      }

      rows.add(_buildFieldRow(field, vm));

      final crossFieldMessage = vm.crossFieldMessages[field.name];
      if (crossFieldMessage != null) {
        rows.add(
          Padding(
            key: crossFieldErrorKey(field.name),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              crossFieldMessage,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        );
      }
    }

    return Column(
      key: const Key('form-renderer-body'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [...rows, const SizedBox(height: 16), _buildSubmitSection(vm)],
    );
  }

  Widget _buildFieldRow(FormFieldDef field, FormViewModel vm) {
    // A `computed` field's displayed value is read entirely from
    // `computedValues`/`resolvedComputedDisplayValues`, never pre-seeded
    // into `values` (design §3.3/§4.3) -- this overrides the normal
    // kind-specific editable widget for any field carrying `computed`.
    if (field.computedExpr != null) {
      final computedOutcome = vm.computedValues[field.name];
      if (computedOutcome is StaleVersion) {
        return ExpressionUnavailableBannerWidget(
          field: field.name,
          kind: 'computed',
          reason: computedOutcome.reason,
        );
      }
      final displayValue = vm.resolvedComputedDisplayValues[field.name];
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: TextField(
          key: formFieldInputKey(field.name),
          readOnly: true,
          controller: TextEditingController(text: displayValue?.toString() ?? ''),
          decoration: InputDecoration(labelText: field.title),
        ),
      );
    }

    switch (field.kind) {
      case FormFieldKind.text:
        return _buildTextInput(field, vm, keyboardType: TextInputType.text);
      case FormFieldKind.number:
        return _buildTextInput(
          field,
          vm,
          keyboardType: TextInputType.number,
          isNumber: true,
        );
      case FormFieldKind.boolean:
        return _buildBooleanInput(field, vm);
      case FormFieldKind.date:
        return _buildDateInput(field, vm, withTime: false);
      case FormFieldKind.datetime:
        return _buildDateInput(field, vm, withTime: true);
      case FormFieldKind.select:
        return _buildSelectInput(field, vm);
      case FormFieldKind.file:
        return _buildFileInput(field, vm);
      case FormFieldKind.object:
      case FormFieldKind.array:
        // Recognized but not rendered (design §1.5/OQ-3) -- a fixed,
        // non-editable placeholder row, never submitted.
        return Padding(
          key: formFieldInputKey(field.name),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('${field.title}: this field type is not yet editable on mobile'),
        );
    }
  }

  Widget _buildTextInput(
    FormFieldDef field,
    FormViewModel vm, {
    required TextInputType keyboardType,
    bool isNumber = false,
  }) {
    final current = vm.values[field.name];
    final controller = _textControllerFor(field.name, current?.toString() ?? '');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextField(
        key: formFieldInputKey(field.name),
        controller: controller,
        keyboardType: keyboardType,
        decoration: InputDecoration(labelText: field.title),
        onChanged: (text) {
          if (isNumber) {
            widget.controller.updateFieldValue(field.name, num.tryParse(text));
          } else {
            widget.controller.updateFieldValue(field.name, text);
          }
        },
      ),
    );
  }

  Widget _buildBooleanInput(FormFieldDef field, FormViewModel vm) {
    final current = vm.values[field.name];
    final value = current is bool ? current : false;
    return CheckboxListTile(
      key: formFieldInputKey(field.name),
      title: Text(field.title),
      value: value,
      onChanged: (checked) =>
          widget.controller.updateFieldValue(field.name, checked ?? false),
    );
  }

  Widget _buildDateInput(
    FormFieldDef field,
    FormViewModel vm, {
    required bool withTime,
  }) {
    final current = vm.values[field.name];
    final controller = _textControllerFor(field.name, current?.toString() ?? '');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextField(
        key: formFieldInputKey(field.name),
        controller: controller,
        readOnly: true,
        decoration: InputDecoration(
          labelText: field.title,
          suffixIcon: const Icon(Icons.calendar_today),
        ),
        onTap: () async {
          final now = DateTime.now();
          final pickedDate = await showDatePicker(
            context: context,
            initialDate: now,
            firstDate: DateTime(1900),
            lastDate: DateTime(2100),
          );
          if (pickedDate == null) return;
          var resolved = pickedDate;
          if (withTime) {
            if (!mounted) return;
            final pickedTime = await showTimePicker(
              context: context,
              initialTime: TimeOfDay.now(),
            );
            if (pickedTime != null) {
              resolved = DateTime(
                pickedDate.year,
                pickedDate.month,
                pickedDate.day,
                pickedTime.hour,
                pickedTime.minute,
              );
            }
          }
          final iso = withTime
              ? resolved.toIso8601String()
              : '${resolved.year.toString().padLeft(4, '0')}-'
                  '${resolved.month.toString().padLeft(2, '0')}-'
                  '${resolved.day.toString().padLeft(2, '0')}';
          controller.text = iso;
          widget.controller.updateFieldValue(field.name, iso);
        },
      ),
    );
  }

  Widget _buildSelectInput(FormFieldDef field, FormViewModel vm) {
    final current = vm.values[field.name] as String?;
    final options = field.enumValues ?? const <String>[];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: DropdownButtonFormField<String>(
        key: formFieldInputKey(field.name),
        initialValue: current,
        decoration: InputDecoration(labelText: field.title),
        items: [
          for (final option in options)
            DropdownMenuItem(value: option, child: Text(option)),
        ],
        onChanged: (value) => widget.controller.updateFieldValue(field.name, value),
      ),
    );
  }

  Widget _buildFileInput(FormFieldDef field, FormViewModel vm) {
    final outcome = vm.fileUploads[field.name];
    return Padding(
      key: formFieldInputKey(field.name),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(field.title),
          ElevatedButton(
            key: Key('form-field-${field.name}-pick'),
            // Real file-picking UI is out of this requirement's scope --
            // `decisions/0012-mobile-tier-stack.md`'s closed dependency list
            // carries no file-picker package. Production wiring for a real
            // "Choose file" tap supplies bytes/fileName/contentType through
            // a platform channel at this button's own call site; this
            // widget's contract with [FormRendererController
            // .pickAndUploadFile] does not change based on how those bytes
            // were obtained. Left disabled with no `onPressed` action here
            // since no such platform-channel source is wired in yet; tests
            // call [FormRendererController.pickAndUploadFile] directly.
            onPressed: null,
            child: Text(outcome is FileUploadSuccess ? 'Replace file' : 'Choose file'),
          ),
          switch (outcome) {
            null => const SizedBox.shrink(),
            FileUploadInFlight() =>
              const Text('Uploading…', key: Key('file-upload-in-flight')),
            FileUploadSuccess(:final fileName) =>
              Text(fileName, key: const Key('file-upload-success')),
            FileUploadNetworkUnavailable() => const Text(
              'No network connection',
              key: Key('file-upload-network-unavailable'),
            ),
            FileUploadOtherFailure() => const Text(
              'Upload failed',
              key: Key('file-upload-other-failure'),
            ),
          },
        ],
      ),
    );
  }

  Widget _buildSubmitSection(FormViewModel vm) {
    final submitOutcome = vm.submitOutcome;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton(
          key: formSubmitButtonKey,
          onPressed: submitOutcome is SubmitInFlight
              ? null
              : () => widget.controller.submit(),
          child: const Text('Submit'),
        ),
        switch (submitOutcome) {
          null => const SizedBox.shrink(),
          SubmitInFlight() => const Padding(
            padding: EdgeInsets.all(8),
            child: Center(
              child: CircularProgressIndicator(key: formSubmitInFlightKey),
            ),
          ),
          SubmitSuccess() =>
            const Text('Submitted.', key: formSubmitSuccessKey),
          SubmitNetworkUnavailable() => const Text(
            'No network connection — your answers are still here.',
            key: formSubmitNetworkUnavailableKey,
          ),
          SubmitValidationError(:final fieldErrors) => Column(
            key: formSubmitValidationErrorKey,
            children: [for (final e in fieldErrors) Text(e.message)],
          ),
          SubmitOtherFailure() => const Text(
            'Something went wrong submitting this form.',
            key: formSubmitOtherFailureKey,
          ),
        },
      ],
    );
  }
}

// ── §7 Provider wiring ──────────────────────────────────────────────────

/// One [FormRendererController] per [FormRendererParams], backed by the
/// app's single [ApiClient]/[PinnedFormResolver] (`apiClientProvider`,
/// `pinned_form.pinnedFormResolverProvider`). Kept as a local family
/// provider in this file, mirroring `listRendererControllerProvider`'s own
/// precedent (REQ-426) -- unit tests construct a [FormRendererController]
/// directly with fakes and never touch Riverpod for it.
///
/// `manifestCapabilities` is passed this evaluator's own known-implemented
/// tag set ([kStaticCapabilities]) since no production `manifest.json`
/// fetch/bundle infrastructure exists yet anywhere in `apps/mobile/lib` --
/// there is nothing else to pass here today. A future requirement wiring a
/// real shipped manifest supplies its own capability list instead.
final formRendererControllerProvider =
    ChangeNotifierProvider.family<FormRendererController, FormRendererParams>((
      ref,
      params,
    ) {
      return FormRendererController(
        client: ref.watch(apiClientProvider),
        pinnedFormResolver: ref.watch(pinned_form.pinnedFormResolverProvider),
        manifestCapabilities: kStaticCapabilities.toList(),
        taskId: params.taskId,
        formId: params.formId,
        formVersion: params.formVersion,
        instanceId: params.instanceId,
      );
    });
