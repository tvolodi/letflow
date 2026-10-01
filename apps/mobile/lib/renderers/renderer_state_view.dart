/// `RendererStateView<T>` — the shared, reusable widget every renderer under
/// `lib/renderers/` wraps its own content in (design
/// `req426-mobile-renderer-state-and-list.md` §2). Presentational only: it
/// holds no fetch logic of its own, and knows nothing about `ApiError` or
/// any specific renderer.
library;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import 'renderer_state.dart';

// ── §2.2 Widget keys — exported so a widget test can assert on them without
// knowing this file's internal widget classes ───────────────────────────────

const Key rendererLoadingKey = Key('renderer-loading');
const Key rendererContentKey = Key('renderer-content');
const Key rendererFetchFailureKey = Key('renderer-fetch-failure');
const Key rendererPermissionDeniedKey = Key('renderer-permission-denied');
const Key rendererStaleVersionKey = Key('renderer-stale-version');
const Key rendererValidationErrorKey = Key('renderer-validation-error');
const Key rendererBackpressureKey = Key('renderer-backpressure');

/// Keys the countdown number `Text` specifically (distinct from
/// [rendererBackpressureKey], which keys the container) — AC2 needs to
/// assert the number's text content changing across three frames.
const Key backpressureCountdownTextKey = Key('backpressure-countdown-text');

// ── §2.1 `RendererStateView<T>` ─────────────────────────────────────────────

class RendererStateView<T> extends StatefulWidget {
  const RendererStateView({
    super.key,
    required this.state,
    required this.contentBuilder,
    required this.onRetryBackpressure,
  });

  /// The current [RendererState], supplied by the caller's own
  /// controller/provider — this widget holds no fetch logic itself, only
  /// presentation per state.
  final RendererState<T> state;

  /// Builds the renderer's real body for [RendererContent.data].
  final Widget Function(BuildContext, T) contentBuilder;

  /// Invoked by the internal [BackpressureCountdown] when its timer reaches
  /// zero. The caller is responsible for this performing exactly one
  /// re-fetch and producing a new [RendererState] (which flows back into
  /// this widget via a rebuild with a new `state` value).
  final Future<void> Function() onRetryBackpressure;

  @override
  State<RendererStateView<T>> createState() => _RendererStateViewState<T>();
}

class _RendererStateViewState<T> extends State<RendererStateView<T>> {
  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return switch (state) {
      RendererLoading<T>() => const Center(
        key: rendererLoadingKey,
        child: CircularProgressIndicator(),
      ),
      RendererContent<T>(:final data) => KeyedSubtree(
        key: rendererContentKey,
        child: widget.contentBuilder(context, data),
      ),
      RendererFetchFailure<T>() => Center(
        key: rendererFetchFailureKey,
        child: Text(tr('renderer.state.fetchFailure')),
      ),
      RendererPermissionDenied<T>() => Center(
        key: rendererPermissionDeniedKey,
        child: Text(tr('renderer.state.permissionDenied')),
      ),
      RendererStaleVersion<T>(:final reason) => Center(
        key: rendererStaleVersionKey,
        child: Text(
          '${tr('renderer.state.staleVersion')}'
          '${kDebugMode ? ' (${reason.runtimeType})' : ''}',
        ),
      ),
      RendererValidationError<T>(:final fieldErrors) => Center(
        key: rendererValidationErrorKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final fieldError in fieldErrors) Text(fieldError.message),
          ],
        ),
      ),
      RendererBackpressure<T>(:final retryAfterSeconds) => Center(
        key: rendererBackpressureKey,
        child: _BackpressureCountdownWidget(
          key: ValueKey(retryAfterSeconds),
          retryAfterSeconds: retryAfterSeconds,
          onZero: widget.onRetryBackpressure,
        ),
      ),
    };
  }
}

// ── §2.3 `BackpressureCountdownWidget` ──────────────────────────────────────

class _BackpressureCountdownWidget extends StatefulWidget {
  const _BackpressureCountdownWidget({
    super.key,
    required this.retryAfterSeconds,
    required this.onZero,
  });

  final int retryAfterSeconds;
  final Future<void> Function() onZero;

  @override
  State<_BackpressureCountdownWidget> createState() =>
      _BackpressureCountdownWidgetState();
}

class _BackpressureCountdownWidgetState
    extends State<_BackpressureCountdownWidget> {
  late final BackpressureCountdown _countdown;

  @override
  void initState() {
    super.initState();
    _countdown = BackpressureCountdown(
      initialSeconds: widget.retryAfterSeconds,
      onZero: widget.onZero,
    );
    _countdown.start();
  }

  @override
  void dispose() {
    _countdown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _countdown.secondsRemaining,
      builder: (context, secondsRemaining, _) {
        return Text(
          '$secondsRemaining',
          key: backpressureCountdownTextKey,
        );
      },
    );
  }
}
