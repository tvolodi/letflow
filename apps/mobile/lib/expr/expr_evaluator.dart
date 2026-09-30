/// REQ-294 — direct port of `eval/2` (`expr.ex` lines 1114-1468) and its
/// private helpers (`apply_arith`/`apply_int_arith`/`apply_float_arith`/
/// `apply_neg`/`apply_ordering`/`apply_builtin`/`resolve_var`/
/// `check_arity`), via `web/src/utils/expr/evaluator.ts` as the direct
/// structural model.
///
/// Every function here is a pure function of its typed arguments alone --
/// no `dart:io`, no `package:dio`, no platform channel, no `async`/`Future`
/// anywhere in this file (design §8's purity argument, AC9).
library;

import 'dart:convert' show utf8;

import 'expr_types.dart';

EvalOutcome _ok(ExprValue value) => EvalOk(value);
EvalOutcome _err(EvalErrorReason error) => EvalErr(error);

/// Evaluates `ast` against `variables`, resolving `VarNode` paths via
/// successive string-keyed map lookups. An undefined variable (missing key
/// at any step of the path) is an eval error, not a nil-propagating case;
/// `and`/`or`/`not`/ordering-comparison operands that are not the required
/// type are also eval errors.
EvalOutcome evalAst(ExprAst ast, Map<String, Object?> variables) {
  switch (ast) {
    case LitNode(:final value):
      return _ok(value);

    case VarNode(:final path):
      return _resolveVar(path, variables, path);

    case NotNode(:final sub):
      final v = evalAst(sub, variables);
      if (v is EvalErr) return v;
      final value = (v as EvalOk).value;
      if (value is! bool) {
        return _err(TypeMismatch('not', [value]));
      }
      return _ok(!value);

    case AndNode(:final left, :final right):
      final lv = evalAst(left, variables);
      if (lv is EvalErr) return lv;
      final rv = evalAst(right, variables);
      if (rv is EvalErr) return rv;
      final lval = (lv as EvalOk).value;
      final rval = (rv as EvalOk).value;
      if (lval is! bool || rval is! bool) {
        return _err(TypeMismatch('and', [lval, rval]));
      }
      return _ok(lval && rval);

    case OrNode(:final left, :final right):
      final lv = evalAst(left, variables);
      if (lv is EvalErr) return lv;
      final rv = evalAst(right, variables);
      if (rv is EvalErr) return rv;
      final lval = (lv as EvalOk).value;
      final rval = (rv as EvalOk).value;
      if (lval is! bool || rval is! bool) {
        return _err(TypeMismatch('or', [lval, rval]));
      }
      return _ok(lval || rval);

    case CmpNode(:final op, :final left, :final right):
      return _evalCmp(op, left, right, variables);

    case ArithNode(:final op, :final left, :final right):
      return _evalArith(op, left, right, variables);

    case NegNode(:final sub):
      final v = evalAst(sub, variables);
      if (v is EvalErr) return v;
      return _applyNeg((v as EvalOk).value);

    case CallNode(:final name, :final args):
      return _evalCall(name, args, variables);
  }
}

EvalOutcome _evalCmp(CmpOp op, ExprAst leftNode, ExprAst rightNode, Map<String, Object?> variables) {
  final lv = evalAst(leftNode, variables);
  if (lv is EvalErr) return lv;
  final rv = evalAst(rightNode, variables);
  if (rv is EvalErr) return rv;
  final lval = (lv as EvalOk).value;
  final rval = (rv as EvalOk).value;

  if (op == CmpOp.eq || op == CmpOp.neq) {
    // REQ-197 §4.6 parity: real IEEE 754 NaN self-inequality -- checked
    // before the generic equality fallback, which would otherwise treat
    // two `InfinityMarker.nan` values as equal (Dart `enum ==` is ordinary
    // identity equality, design §4.3.1).
    if (lval == InfinityMarker.nan || rval == InfinityMarker.nan) {
      return _ok(op == CmpOp.neq);
    }
    return _ok(op == CmpOp.eq ? lval == rval : lval != rval);
  }

  // lt/lte/gt/gte
  if (lval == null || rval == null) {
    // §4.5 asymmetry vs. arithmetic -- null propagates, not an error.
    return _ok(null);
  }
  if (lval == InfinityMarker.nan || rval == InfinityMarker.nan) {
    return _ok(false);
  }
  final lok = lval is num || lval == InfinityMarker.infinity || lval == InfinityMarker.negInfinity;
  final rok = rval is num || rval == InfinityMarker.infinity || rval == InfinityMarker.negInfinity;
  if (lok && rok) {
    return _ok(_applyOrdering(op, lval, rval));
  }
  return _err(TypeMismatch(op.name, [lval, rval]));
}

bool _applyOrdering(CmpOp op, Object? l, Object? r) {
  if (l == InfinityMarker.infinity ||
      l == InfinityMarker.negInfinity ||
      r == InfinityMarker.infinity ||
      r == InfinityMarker.negInfinity) {
    if (l == r) return op == CmpOp.lte || op == CmpOp.gte;
    if (l == InfinityMarker.infinity) return op == CmpOp.gt || op == CmpOp.gte;
    if (l == InfinityMarker.negInfinity) return op == CmpOp.lt || op == CmpOp.lte;
    if (r == InfinityMarker.infinity) return op == CmpOp.lt || op == CmpOp.lte;
    return op == CmpOp.gt || op == CmpOp.gte; // r == negInfinity
  }
  final ln = l as num;
  final rn = r as num;
  switch (op) {
    case CmpOp.lt:
      return ln < rn;
    case CmpOp.lte:
      return ln <= rn;
    case CmpOp.gt:
      return ln > rn;
    case CmpOp.gte:
      return ln >= rn;
    case CmpOp.eq:
    case CmpOp.neq:
      throw StateError('unreachable: eq/neq handled by _evalCmp before ordering');
  }
}

EvalOutcome _evalArith(ArithOp op, ExprAst leftNode, ExprAst rightNode, Map<String, Object?> variables) {
  final lv = evalAst(leftNode, variables);
  if (lv is EvalErr) return lv;
  final rv = evalAst(rightNode, variables);
  if (rv is EvalErr) return rv;
  final lval = (lv as EvalOk).value;
  final rval = (rv as EvalOk).value;

  // §4.2 clause order: null check first, before any type/promotion logic
  // (asymmetric with ordering comparison, which propagates null instead).
  if (lval == null || rval == null) {
    return _err(NullInArithmetic(op.name));
  }

  if (lval is! num || rval is! num) {
    return _err(TypeMismatch(op.name, [lval, rval]));
  }

  // Design §4.4: dispatch on the *runtime type* of the evaluated operand
  // values (`lv is int && rv is int` -> integer path; otherwise -> float
  // path, promoting via `.toDouble()`), exactly mirroring `expr.ex`'s own
  // `is_integer(lv) and is_integer(rv)` dispatch (`apply_arith/3`, line
  // 1373). Dart's `num` genuinely distinguishes `int`/`double` at runtime,
  // unlike JS -- this is strictly more faithful than REQ-293's TS port
  // needed to settle for (design §4.4).
  if (lval is int && rval is int) {
    return _applyIntArith(op, lval, rval);
  }
  return _applyFloatArith(op, lval.toDouble(), rval.toDouble());
}

EvalOutcome _applyIntArith(ArithOp op, int l, int r) {
  switch (op) {
    case ArithOp.add:
      return _ok(l + r);
    case ArithOp.sub:
      return _ok(l - r);
    case ArithOp.mul:
      return _ok(l * r);
    case ArithOp.div:
      if (r == 0) return _err(const DivisionByZero());
      // Truncating integer division, matching Elixir's `div/2` (truncates
      // toward zero), not Dart's `~/` for negative operands divergence --
      // `~/` on Dart ints also truncates toward zero, matching `div/2`.
      return _ok(l ~/ r);
    case ArithOp.mod:
      if (r == 0) return _err(const ModuloByZero());
      // Elixir's `rem/2` takes the sign of the dividend, matching Dart's
      // `%` operator's remainder-with-dividend-sign behaviour... actually
      // Dart's `%` always returns a non-negative result (Euclidean
      // modulo), which diverges from Elixir's `rem/2` for
      // mixed-sign operands. `remainder()` matches `rem/2` exactly.
      return _ok(l.remainder(r));
  }
}

/// Float division-by-zero: never Dart's native `double.infinity`/
/// `double.nan` -- checks `r == 0.0` first (mirroring `expr.ex`'s own
/// clause order) and returns the `InfinityMarker` enum value directly, by
/// explicit sign comparison of `l`, per the exact 3-row table at `expr.ex`
/// lines 1408-1410 (design §4.3).
EvalOutcome _applyFloatArith(ArithOp op, double l, double r) {
  switch (op) {
    case ArithOp.add:
      return _ok(l + r);
    case ArithOp.sub:
      return _ok(l - r);
    case ArithOp.mul:
      return _ok(l * r);
    case ArithOp.div:
      if (r == 0.0) {
        if (l == 0.0) return _ok(InfinityMarker.nan);
        if (l > 0.0) return _ok(InfinityMarker.infinity);
        return _ok(InfinityMarker.negInfinity);
      }
      return _ok(l / r);
    case ArithOp.mod:
      // Float modulo is never attempted, zero divisor or not -- ported
      // literally from `apply_float_arith(:mod, l, r)`, `expr.ex` line
      // 1413-1415.
      return _err(const ModuloByZero());
  }
}

EvalOutcome _applyNeg(ExprValue v) {
  if (v == null) return _err(const NullInArithmetic('neg'));
  if (v == InfinityMarker.infinity) return _ok(InfinityMarker.negInfinity);
  if (v == InfinityMarker.negInfinity) return _ok(InfinityMarker.infinity);
  if (v == InfinityMarker.nan) return _ok(InfinityMarker.nan);
  if (v is num) return _ok(-v);
  return _err(TypeMismatch('neg', [v]));
}

EvalOutcome _resolveVar(List<String> path, Object? current, List<String> fullPath) {
  var value = current;
  for (final key in path) {
    if (value is Map<String, Object?> && value.containsKey(key)) {
      value = value[key];
    } else {
      return _err(UndefinedVariable(fullPath));
    }
  }
  return _ok(value);
}

EvalOutcome _evalCall(BuiltinName name, List<ExprAst> argNodes, Map<String, Object?> variables) {
  final values = <ExprValue>[];
  for (final argNode in argNodes) {
    final v = evalAst(argNode, variables);
    if (v is EvalErr) return v;
    values.add((v as EvalOk).value);
  }

  final arityError = _checkArity(name, values.length);
  if (arityError != null) return arityError;

  return _applyBuiltin(name, values);
}

({bool exactly, int n}) _requiredArity(BuiltinName name) {
  switch (name) {
    case BuiltinName.length:
    case BuiltinName.lower:
    case BuiltinName.upper:
    case BuiltinName.trim:
      return (exactly: true, n: 1);
    case BuiltinName.contains:
    case BuiltinName.startsWith:
    case BuiltinName.endsWith:
      return (exactly: true, n: 2);
    case BuiltinName.coalesce:
      return (exactly: false, n: 1);
  }
}

EvalErr? _checkArity(BuiltinName name, int got) {
  final requirement = _requiredArity(name);
  final ok = requirement.exactly ? got == requirement.n : got >= requirement.n;
  if (ok) return null;
  return EvalErr(WrongArity(name, got));
}

// ── §4.1 ASCII-only lower/upper ─────────────────────────────────────────
//
// Dart's `String.toLowerCase()`/`toUpperCase()` are Unicode-aware --
// same divergence risk `expr.ex`'s moduledoc names for Elixir's own
// `String.downcase/1`/`upcase/1` defaults. Neither may be called directly.
// A fixed, module-scope map over ASCII code points (0x41-0x5A / 0x61-0x7A),
// applied per Unicode *rune* (code point, not UTF-16 code unit) via
// `String.runes`, so a precomposed accented character like `É` (U+00C9, a
// single rune outside the ASCII range) is visited once and left
// byte-for-byte unchanged -- never split, never mapped (design §4.1).

String _asciiLower(String s) {
  return String.fromCharCodes(
    s.runes.map((r) => (r >= 0x41 && r <= 0x5A) ? r + 0x20 : r),
  );
}

String _asciiUpper(String s) {
  return String.fromCharCodes(
    s.runes.map((r) => (r >= 0x61 && r <= 0x7A) ? r - 0x20 : r),
  );
}

// ── §4.2 Exact-4-ASCII-char trim ────────────────────────────────────────
//
// Strips only space (U+0020), tab (U+0009), line feed (U+000A), and
// carriage return (U+000D) -- `kAsciiWhitespaceCodeUnits` -- never Dart's
// `String.trim()`, which strips a broader Unicode-whitespace set (e.g.
// U+00A0 NBSP, U+2003 EM SPACE). Walked at rune boundaries so a >0xFFFF
// character adjacent to a boundary is never split (design §4.2).

String _asciiTrim(String s) {
  final runes = s.runes.toList();
  var start = 0;
  var end = runes.length;
  while (start < end && kAsciiWhitespaceCodeUnits.contains(runes[start])) {
    start += 1;
  }
  while (end > start && kAsciiWhitespaceCodeUnits.contains(runes[end - 1])) {
    end -= 1;
  }
  return String.fromCharCodes(runes.sublist(start, end));
}

EvalOutcome _stringPredicate(
  String name,
  ExprValue a,
  ExprValue b,
  bool Function(String, String) fn,
) {
  if (a == null || b == null) return _ok(null);
  if (a is String && b is String) return _ok(fn(a, b));
  return _err(TypeMismatch(name, [a, b]));
}

/// REQ-198 dispatch, mirroring `apply_builtin/2` (`expr.ex` lines
/// 1275-1314). `switch` over the closed 8-member `BuiltinName` enum -- there
/// is no `case` for `now`/`date_add`/`date_diff` because there is no such
/// enum member to match; adding one is a structural, multi-file, visibly
/// diffed change (design §5.1), never a runtime-mutable dispatch table.
EvalOutcome _applyBuiltin(BuiltinName name, List<ExprValue> values) {
  switch (name) {
    case BuiltinName.length:
      final s = values[0];
      if (s == null) return _ok(null);
      if (s is String) return _ok(utf8.encode(s).length);
      return _err(TypeMismatch('length', [s]));

    case BuiltinName.lower:
      final s = values[0];
      if (s == null) return _ok(null);
      if (s is String) return _ok(_asciiLower(s));
      return _err(TypeMismatch('lower', [s]));

    case BuiltinName.upper:
      final s = values[0];
      if (s == null) return _ok(null);
      if (s is String) return _ok(_asciiUpper(s));
      return _err(TypeMismatch('upper', [s]));

    case BuiltinName.trim:
      final s = values[0];
      if (s == null) return _ok(null);
      if (s is String) return _ok(_asciiTrim(s));
      return _err(TypeMismatch('trim', [s]));

    case BuiltinName.contains:
      return _stringPredicate('contains', values[0], values[1], (a, b) => a.contains(b));

    case BuiltinName.startsWith:
      return _stringPredicate('startsWith', values[0], values[1], (a, b) => a.startsWith(b));

    case BuiltinName.endsWith:
      return _stringPredicate('endsWith', values[0], values[1], (a, b) => a.endsWith(b));

    case BuiltinName.coalesce:
      for (final v in values) {
        if (v != null) return _ok(v);
      }
      return _ok(null);
  }
}
