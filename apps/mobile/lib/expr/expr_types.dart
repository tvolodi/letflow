/// REQ-294 — Dart port of `Letflow.Engine.Expr`'s type surface
/// (`lib/letflow/engine/expr.ex`).
///
/// Direct structural counterpart of `expr.ex`'s `ast()`, `value()`, and
/// `eval/2`'s `{:ok, value()} | {:error, {:eval_error, reason}}` return
/// shape, and of `web/src/utils/expr/types.ts` (REQ-293's TypeScript port) --
/// same node set, same closed operator/builtin enums, same 3-member
/// infinity marker. No node kind exists here that `expr.ex` does not have
/// (D1a constraint: no local extension of the grammar).
///
/// See `lib/letflow/design/req294-dart-expr-evaluator.md` §3.
library;

import 'package:flutter/foundation.dart' show immutable;

/// Mirrors `expr.ex`'s `infinity_marker()`. Never Dart's native
/// `double.infinity`/`double.nan` -- a branded, closed, 3-member type so it
/// cannot be confused with a real IEEE 754 double at any call site
/// (design §4.3).
enum InfinityMarker { infinity, negInfinity, nan }

/// Mirrors `expr.ex`'s `value()`. Dart's `num` already subsumes `int`/
/// `double` distinctly (design §4.4) -- no separate "numeric provenance"
/// flag is needed on values themselves, unlike REQ-293's TypeScript port.
/// Effectively: `num | String | bool | null | InfinityMarker`. Dart has no
/// closed union types, so call sites narrow via `is`/switch patterns on
/// these 5 permitted runtime shapes.
typedef ExprValue = Object?;

/// The 6 comparison operators this subset's grammar supports (`cmp_op()`).
enum CmpOp { eq, neq, lt, lte, gt, gte }

/// The 5 binary arithmetic operators (`arith_op()`). Unary negation is a
/// separate `ExprAst` variant (`NegNode`), not a 6th member here.
enum ArithOp { add, sub, mul, div, mod }

/// Every name the closed lex-time whitelist recognizes as a builtin-function
/// call. Exactly 8 -- structurally the only names `applyBuiltin` can
/// dispatch to. `now`, `date_add`, `date_diff` are deliberately absent
/// (`expr.ex` moduledoc, "`now()` / `date_add()` / `date_diff()` are
/// deliberately not added") -- not a gap, a permanent decision (design §5).
enum BuiltinName {
  length,
  lower,
  upper,
  trim,
  contains,
  startsWith,
  endsWith,
  coalesce,
}

/// Numeric-literal provenance -- present only when a `LitNode`'s `value` is
/// a `num` literal from the tokenizer. Diagnostic/self-documentation only
/// (does `"3"` vs `"3.0"` parse to `int` vs `double`); never consulted by
/// `applyArith`'s dispatch logic, which dispatches on the *runtime type* of
/// the already-evaluated operand values instead (design §4.4).
enum NumericKind { intKind, floatKind }

/// Mirrors `expr.ex`'s `ast()` -- 9 tagged variants, sealed so a `switch`
/// over `ExprAst` is exhaustiveness-checked by the Dart analyzer.
@immutable
sealed class ExprAst {
  const ExprAst();
}

@immutable
final class LitNode extends ExprAst {
  const LitNode(this.value, {this.numericKind});
  final ExprValue value;
  final NumericKind? numericKind;
}

@immutable
final class VarNode extends ExprAst {
  const VarNode(this.path);

  /// Non-empty. The leading `variables.` token has already been stripped
  /// by `translateCelToExpr`.
  final List<String> path;
}

@immutable
final class NotNode extends ExprAst {
  const NotNode(this.sub);
  final ExprAst sub;
}

@immutable
final class AndNode extends ExprAst {
  const AndNode(this.left, this.right);
  final ExprAst left;
  final ExprAst right;
}

@immutable
final class OrNode extends ExprAst {
  const OrNode(this.left, this.right);
  final ExprAst left;
  final ExprAst right;
}

@immutable
final class CmpNode extends ExprAst {
  const CmpNode(this.op, this.left, this.right);
  final CmpOp op;
  final ExprAst left;
  final ExprAst right;
}

@immutable
final class ArithNode extends ExprAst {
  const ArithNode(this.op, this.left, this.right);
  final ArithOp op;
  final ExprAst left;
  final ExprAst right;
}

@immutable
final class NegNode extends ExprAst {
  const NegNode(this.sub);
  final ExprAst sub;
}

@immutable
final class CallNode extends ExprAst {
  const CallNode(this.name, this.args);
  final BuiltinName name;
  final List<ExprAst> args;
}

/// Mirrors `expr.ex`'s `parse_error_reason()` (8 shapes) plus this port's
/// own addition for a syntactically-valid-but-unrecognized construct
/// (design §5.4/§5.5), mirroring REQ-293's TS `unsupported_construct`
/// addition one-for-one.
@immutable
sealed class ParseErrorReason {
  const ParseErrorReason();
}

@immutable
final class InvalidNumber extends ParseErrorReason {
  const InvalidNumber(this.text);
  final String text;
}

@immutable
final class InvalidIdentifier extends ParseErrorReason {
  const InvalidIdentifier(this.text);
  final String text;
}

@immutable
final class UnexpectedChar extends ParseErrorReason {
  const UnexpectedChar(this.char);
  final String char;
}

@immutable
final class UnterminatedString extends ParseErrorReason {
  const UnterminatedString(this.text);
  final String text;
}

@immutable
final class ExpectedRparen extends ParseErrorReason {
  const ExpectedRparen();
}

@immutable
final class UnexpectedEndOfInput extends ParseErrorReason {
  const UnexpectedEndOfInput();
}

@immutable
final class UnexpectedToken extends ParseErrorReason {
  const UnexpectedToken(this.text);
  final String text;
}

@immutable
final class TrailingInput extends ParseErrorReason {
  const TrailingInput();
}

/// This port's own addition (not in `expr.ex`, same class as REQ-293's TS
/// addition), declared for structural parity with the design doc's type
/// shape (§3) but not currently constructed anywhere in this port.
///
/// FINDING (reported, not silently reconciled): the design doc (§5.2/§5.3)
/// claims referencing an impure builtin like `now()`/`date_add(x, 1)` is
/// rejected with this variant (`UnexpectedToken`, in the design's own
/// wording). Empirically re-verified against `expr.ex` itself
/// (`mix run --no-start`, `Letflow.Engine.Expr.parse/1`) this is incorrect:
/// a bare unrecognized identifier parses successfully as `{:var, [...]}`,
/// and the trailing `(...)` is reported via the *existing* `TrailingInput`
/// variant, never `UnexpectedToken` and never this port's own addition
/// either. See `apps/mobile/test/expr/expr_impure_builtin_rejection_test.dart`
/// for the full verification transcript. Retained here only because the
/// design's type table (§3) names it; a future requirement may remove it
/// if it is confirmed permanently unreachable.
@immutable
final class UnsupportedConstruct extends ParseErrorReason {
  const UnsupportedConstruct(this.tag);
  final String tag;
}

@immutable
final class ParseFailure {
  const ParseFailure({
    required this.line,
    required this.column,
    required this.tokenText,
    required this.reason,
  });
  final int line;
  final int column;
  final String tokenText;
  final ParseErrorReason reason;
}

@immutable
sealed class ParseResult {
  const ParseResult();
}

@immutable
final class ParseOk extends ParseResult {
  const ParseOk(this.ast);
  final ExprAst ast;
}

@immutable
final class ParseErr extends ParseResult {
  const ParseErr(this.failure);
  final ParseFailure failure;
}

/// Mirrors `expr.ex`'s `{:eval_error, reason}` shapes.
@immutable
sealed class EvalErrorReason {
  const EvalErrorReason();
}

@immutable
final class TypeMismatch extends EvalErrorReason {
  const TypeMismatch(this.op, this.operands);
  final String op;
  final List<ExprValue> operands;
}

@immutable
final class UndefinedVariable extends EvalErrorReason {
  const UndefinedVariable(this.path);
  final List<String> path;
}

@immutable
final class NullInArithmetic extends EvalErrorReason {
  const NullInArithmetic(this.op);
  final String op;
}

@immutable
final class DivisionByZero extends EvalErrorReason {
  const DivisionByZero();
}

@immutable
final class ModuloByZero extends EvalErrorReason {
  const ModuloByZero();
}

@immutable
final class WrongArity extends EvalErrorReason {
  const WrongArity(this.name, this.got);
  final BuiltinName name;
  final int got;
}

/// This port's own addition, defence-in-depth only (parallel to REQ-293's
/// `unsupported_at_eval`) -- should be unreachable in practice because
/// `parse()` already rejects unsupported constructs before `eval()` ever
/// sees an `ExprAst` (design §5.4), kept only so `eval()`'s own switch is
/// exhaustive.
@immutable
final class UnsupportedAtEval extends EvalErrorReason {
  const UnsupportedAtEval();
}

@immutable
sealed class EvalOutcome {
  const EvalOutcome();
}

@immutable
final class EvalOk extends EvalOutcome {
  const EvalOk(this.value);
  final ExprValue value;
}

@immutable
final class EvalErr extends EvalOutcome {
  const EvalErr(this.error);
  final EvalErrorReason error;
}

enum TranslateErrorReason { unsupportedCelFeature, translateError }

@immutable
sealed class TranslateResult {
  const TranslateResult();
}

@immutable
final class TranslateOk extends TranslateResult {
  const TranslateOk(this.exprSource);
  final String exprSource;
}

@immutable
final class TranslateErr extends TranslateResult {
  const TranslateErr(this.reason);
  final TranslateErrorReason reason;
}

/// The 4-ASCII-char whitespace set shared by the tokenizer and `trim` --
/// one constant so the two can never drift relative to each other (design
/// §4.2), same discipline as REQ-293's `ASCII_WHITESPACE`. Space (U+0020),
/// tab (U+0009), line feed (U+000A), carriage return (U+000D) -- exactly
/// the 4 code points `do_tokenize/2`'s own whitespace guard treats as
/// whitespace (`expr.ex` lines 345-347), never Dart's broader Unicode
/// whitespace default.
const Set<int> kAsciiWhitespaceCodeUnits = {0x20, 0x09, 0x0A, 0x0D};
