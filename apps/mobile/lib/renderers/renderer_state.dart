/// `RendererState<T>` — the sealed state every renderer under
/// `lib/renderers/` builds against (`MOB-4`'s six mandatory states, plus a
/// seventh "content" success state). See
/// `lib/letflow/design/req426-mobile-renderer-state-and-list.md` §1 for the
/// full design this file implements.
///
/// This file has no knowledge of any specific renderer's own content type —
/// every renderer supplies its own `T` (the list renderer's `ListPage`, a
/// future form renderer's own view-model, etc.).
library;

import 'dart:async' show Timer;

import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, immutable;

import '../api/api_error.dart';
import '../definitions/pinned_form_resolver.dart' show PinnedFormUnavailableReason;

// ── §1.1 `RendererState<T>` ─────────────────────────────────────────────────

@immutable
sealed class RendererState<T> {
  const RendererState();
}

/// An in-flight fetch with no result yet.
@immutable
final class RendererLoading<T> extends RendererState<T> {
  const RendererLoading();
}

/// Success — the renderer's own body is shown. Not one of the six mandatory
/// states; every renderer needs a seventh "it worked" state to have anything
/// to wrap.
@immutable
final class RendererContent<T> extends RendererState<T> {
  const RendererContent({required this.data});

  final T data;
}

/// AC1's "fetch-failure" state.
@immutable
final class RendererFetchFailure<T> extends RendererState<T> {
  const RendererFetchFailure({this.cause});

  final Object? cause;
}

/// AC1's "permission-denied" state.
@immutable
final class RendererPermissionDenied<T> extends RendererState<T> {
  const RendererPermissionDenied();
}

/// AC1's "stale-version" state.
@immutable
final class RendererStaleVersion<T> extends RendererState<T> {
  const RendererStaleVersion({required this.reason});

  final StaleVersionReason reason;
}

/// AC1's "validation-error" state.
@immutable
final class RendererValidationError<T> extends RendererState<T> {
  const RendererValidationError({required this.fieldErrors});

  final List<ApiFieldError> fieldErrors;
}

/// AC1's "429-backpressure" state.
@immutable
final class RendererBackpressure<T> extends RendererState<T> {
  const RendererBackpressure({required this.retryAfterSeconds});

  final int retryAfterSeconds;
}

// ── §1.3 `StaleVersionReason` — the definition-layer half ──────────────────

/// Populates `RendererState.staleVersion` from causes that never arrive as
/// an HTTP status code — a `RendererRegistry` lookup miss, an unrecognized
/// field type, an unevaluable `Letflow.Engine.Expr` expression, or REQ-424's
/// own pinned-version-unavailable outcome.
@immutable
sealed class StaleVersionReason {
  const StaleVersionReason();
}

/// A `RendererRegistry` lookup miss reachable *inside* a renderer that
/// itself embeds a nested definition of unknown type. Distinct from
/// `renderer_registry.dart`'s own top-level `UnsupportedDefinitionTypeWidget`
/// fallback (REQ-419) — see design §1.3/OQ-3.
@immutable
final class UnknownDefinitionType extends StaleVersionReason {
  const UnknownDefinitionType({required this.definitionType});

  final String definitionType;
}

/// An entity/form field whose `"type"` string is outside the closed set the
/// client knows.
@immutable
final class UnknownFieldType extends StaleVersionReason {
  const UnknownFieldType({required this.fieldName, required this.rawType});

  final String fieldName;
  final String rawType;
}

/// A `Letflow.Engine.Expr`-grammar expression (`computed`/`visible_when`)
/// the on-device evaluator cannot evaluate. Not exercised by the list
/// renderer — reserved for the form renderer (REQ-427).
@immutable
final class UnevaluableExpression extends StaleVersionReason {
  const UnevaluableExpression({required this.expression, required this.reason});

  final String expression;
  final String reason;
}

/// Wraps REQ-424's own `PinnedFormUnavailableReason` enum unchanged. Not
/// exercised by the list renderer — reserved for the task/form renderers
/// (REQ-427/428).
@immutable
final class PinnedFormUnavailable extends StaleVersionReason {
  const PinnedFormUnavailable({required this.reason});

  final PinnedFormUnavailableReason reason;
}

// ── §1.2 `ApiError` → `RendererState` mapping ───────────────────────────────

/// The single function every renderer's error-handling path calls, exhaustive
/// over `ApiError`'s 9 variants (design §1.2). INV-2: a new `ApiError`
/// variant added to `api_error.dart` without updating this mapping is a
/// compile error.
RendererState<T> rendererStateForError<T>(ApiError error) {
  return switch (error) {
    ForbiddenError() => const RendererPermissionDenied(),
    BackpressureError(:final retryAfterSeconds) =>
      RendererBackpressure(retryAfterSeconds: retryAfterSeconds),
    ValidationError(:final fieldErrors) =>
      RendererValidationError(fieldErrors: fieldErrors),
    NetworkUnavailableError() => RendererFetchFailure(cause: error),
    ServerError() => RendererFetchFailure(cause: error),
    ConflictError() => RendererFetchFailure(cause: error),
    NotFoundError() => RendererFetchFailure(cause: error),
    ModuleNotAvailableError() => RendererFetchFailure(cause: error),
    // Should not normally reach this function at all -- ApiClient's own
    // refresh-then-retry flow already routes to login on terminal failure
    // before the exception value ever reaches a renderer's `catch` (OQ-2).
    // Mapped here only so the switch is total.
    UnauthorizedError() => RendererFetchFailure(cause: error),
  };
}

/// Wraps a [StaleVersionReason] into a [RendererStaleVersion] (design §1.3).
RendererState<T> staleVersionState<T>(StaleVersionReason reason) {
  return RendererStaleVersion<T>(reason: reason);
}

// ── §1.4 `BackpressureCountdown` ────────────────────────────────────────────

/// Turns a [RendererBackpressure]'s `retryAfterSeconds` into a ticking
/// countdown and exactly one retry call at zero (design §1.4, INV-4).
class BackpressureCountdown {
  BackpressureCountdown({required int initialSeconds, required this.onZero})
    : _secondsRemaining = ValueNotifier<int>(initialSeconds);

  final Future<void> Function() onZero;

  final ValueNotifier<int> _secondsRemaining;

  /// Exposed as a `ValueListenable<int>` so a widget rebuilds only the
  /// countdown text, not the whole subtree.
  ValueListenable<int> get secondsRemaining => _secondsRemaining;

  Timer? _timer;
  bool _started = false;

  /// Begins the 1-second countdown. Not re-entrant — calling this twice on
  /// the same instance is a programmer error, not defended against (INV-4).
  void start() {
    if (_started) return;
    _started = true;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  Future<void> _onTick() async {
    _secondsRemaining.value -= 1;
    if (_secondsRemaining.value > 0) return;
    // Cancel the timer first so a slow `onZero` can never overlap a second
    // tick (design §1.4).
    _timer?.cancel();
    _timer = null;
    try {
      await onZero();
    } catch (_) {
      // `onZero`'s own exceptions are caught and swallowed here (AC2's "the
      // app does not throw") — a retry that itself fails must re-enter the
      // state framework as a new `RendererState` via the caller's own
      // fetch-wrapping logic, not propagate as an uncaught Future error.
    }
  }

  /// Cancels the timer if still running. Call from `State.dispose()` so
  /// navigating away mid-countdown never leaves a dangling `Timer` calling
  /// `onZero` against an unmounted widget.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _secondsRemaining.dispose();
  }
}
