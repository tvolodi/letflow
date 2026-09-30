/// REQ-294 §9/§10 — the structural bridge between this requirement's pure
/// evaluator and the already-existing `RendererState`/`StaleVersionReason`
/// hierarchy (`apps/mobile/lib/renderers/renderer_state.dart`) that a future
/// REQ-426/427 form renderer will consume. AC8 names exactly four outcomes
/// -- this file gives them one closed, exhaustively-`switch`able sealed
/// class.
library;

import 'package:flutter/foundation.dart' show immutable;

import 'expr_evaluate.dart';
import 'expr_types.dart';

/// The four structurally distinguishable outcomes AC8 requires. A future
/// form renderer's `switch` over this type is exhaustiveness-checked by the
/// Dart analyzer -- there is no fifth "fell through" case possible without
/// a compile error, and no way to silently collapse [StaleVersion] into one
/// of the other three (each is its own sealed subtype, not a boolean flag
/// on a shared shape).
@immutable
sealed class FieldExpressionOutcome {
  const FieldExpressionOutcome();
}

/// `visible_when` evaluated to `true` (or `visible_when` is absent -- a
/// field with no `visible_when` is always [DefaultVisible], per D1a/MOB-4's
/// own "defaults to shown" convention, the same default REQ-293's own web
/// renderer uses per its design doc §8.2).
@immutable
final class DefaultVisible extends FieldExpressionOutcome {
  const DefaultVisible();
}

/// `visible_when` evaluated to `false`.
@immutable
final class DefaultHidden extends FieldExpressionOutcome {
  const DefaultHidden();
}

/// A `computed` field's expression evaluated successfully to `null` (either
/// the expression's own result was `null`, or the field has no `computed`
/// expression at all). Distinct from [StaleVersion]: a well-formed,
/// evaluable expression producing `null` is not a failure.
@immutable
final class Blank extends FieldExpressionOutcome {
  const Blank();
}

/// AC8's mandatory failure state -- an expression this client could not
/// evaluate at all: a parse failure, an eval error (type mismatch,
/// undefined variable, null-in-arithmetic, division/modulo by zero
/// surfacing as an error rather than a marker, wrong arity), or a `visible_when`
/// that evaluated successfully to a non-boolean value. Never silently
/// mapped to [DefaultVisible]/[DefaultHidden]/[Blank].
@immutable
final class StaleVersion extends FieldExpressionOutcome {
  const StaleVersion({required this.expression, required this.reason});

  final String expression;

  /// Human-readable, matches the shape `renderer_state.dart`'s own
  /// `UnevaluableExpression.reason` field already expects (`String`) -- these
  /// descriptions are written to be passed straight through with no
  /// re-formatting needed by a future REQ-426/427.
  final String reason;
}

/// `visibleWhenExpr == null` -> [DefaultVisible] (no condition authored).
/// Otherwise composes [evaluateExpression] and maps its outcome.
FieldExpressionOutcome evaluateVisibility(String? visibleWhenExpr, Map<String, Object?> variables) {
  if (visibleWhenExpr == null) {
    return const DefaultVisible();
  }

  final result = evaluateExpression(visibleWhenExpr, variables);
  return switch (result) {
    EvaluateOk(:final value) when value == true => const DefaultVisible(),
    EvaluateOk(:final value) when value == false => const DefaultHidden(),
    EvaluateOk() => StaleVersion(
        expression: visibleWhenExpr,
        reason: 'visible_when evaluated to a non-boolean value',
      ),
    _ => StaleVersion(expression: visibleWhenExpr, reason: describeFailure(result)),
  };
}

/// `computedExpr == null` -> [Blank] (no computed expression authored).
FieldExpressionOutcome evaluateComputed(String? computedExpr, Map<String, Object?> variables) {
  if (computedExpr == null) {
    return const Blank();
  }

  final result = evaluateExpression(computedExpr, variables);
  return switch (result) {
    EvaluateOk(:final value) when value == null => const Blank(),
    // A successfully computed non-null value has no dedicated
    // FieldExpressionOutcome variant in this design -- AC8 names exactly 4
    // outcomes (stale-version, default-visible, default-hidden, blank),
    // none of which is "has a value to display." Left to a future
    // REQ-426/427 to extend this sealed hierarchy or wrap this function's
    // result, per design §11 OQ-2 (an explicit, reported open question, not
    // a silently-taken shortcut). Treated as [Blank] here only as the
    // narrowest interpretation that does not invent an unscoped 5th
    // variant; a future requirement may revisit this mapping.
    EvaluateOk() => const Blank(),
    _ => StaleVersion(expression: computedExpr, reason: describeFailure(result)),
  };
}

/// Mirrors `describe_parse_error/1` (`expr.ex` lines 580-588) plus one
/// clause per [EvalErrorReason]/translate-failure shape. Never includes raw
/// user input verbatim in a way that could be mistaken for executable text
/// -- plain descriptive prose only.
String describeFailure(EvaluateExpressionResult result) {
  return switch (result) {
    EvaluateOk() => throw StateError('describeFailure called on a successful result'),
    EvaluateTranslateFailure(:final reason) => switch (reason) {
        TranslateErrorReason.unsupportedCelFeature => 'unsupported CEL feature',
        TranslateErrorReason.translateError => 'malformed condition',
      },
    EvaluateParseFailure(:final failure) => switch (failure.reason) {
        UnexpectedEndOfInput() => 'unexpected end of input',
        UnexpectedToken() => 'unexpected token',
        ExpectedRparen() => 'expected closing parenthesis',
        UnterminatedString() => 'unterminated string literal',
        InvalidNumber() => 'invalid numeric literal',
        InvalidIdentifier() => 'invalid identifier',
        UnexpectedChar() => 'unexpected character',
        TrailingInput() => 'trailing input after expression',
        UnsupportedConstruct() => 'references an unsupported builtin or construct',
      },
    EvaluateEvalFailure(:final error) => switch (error) {
        TypeMismatch() => 'type mismatch',
        UndefinedVariable() => 'undefined variable',
        NullInArithmetic() => 'null value used in arithmetic',
        DivisionByZero() => 'division by zero',
        ModuloByZero() => 'modulo by zero',
        WrongArity() => 'wrong number of arguments',
        UnsupportedAtEval() => 'unsupported construct',
      },
  };
}
