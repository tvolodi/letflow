/// REQ-294 — port of `do_tokenize_positioned/4` (`expr.ex` lines 590-786),
/// via `web/src/utils/expr/tokenizer.ts`'s own port as the direct structural
/// model. Always position-tracking (line/column) -- this port has no
/// non-positioned variant, matching REQ-293's own design choice.
library;

import 'package:flutter/foundation.dart' show immutable;

import 'expr_types.dart';

enum TokenKind {
  lparen,
  rparen,
  comma,
  cmpOp,
  arithOp,
  and,
  or,
  not,
  lit,
  // `var` is a reserved word in Dart -- named `variable` here, the
  // `VarNode`/`{:var, path}` AST-level name is unaffected.
  variable,
  builtinCall,
}

@immutable
class Token {
  const Token({
    required this.kind,
    this.value,
    this.numericKind,
    required this.text,
    required this.line,
    required this.column,
  });

  final TokenKind kind;

  /// One of: `CmpOp`, `ArithOp`, `ExprValue`, `BuiltinName`, `List<String>`,
  /// or `null` (Dart has no closed union types; callers narrow by `kind`).
  final Object? value;
  final NumericKind? numericKind;
  final String text;
  final int line;
  final int column;
}

@immutable
sealed class TokenizeResult {
  const TokenizeResult();
}

@immutable
final class TokenizeOk extends TokenizeResult {
  const TokenizeOk(this.tokens, this.eofLine, this.eofColumn);
  final List<Token> tokens;
  final int eofLine;
  final int eofColumn;
}

@immutable
final class TokenizeErr extends TokenizeResult {
  const TokenizeErr(this.failure);
  final ParseFailure failure;
}

final RegExp _numberRe = RegExp(r'^-?\d+(\.\d+)?');
final RegExp _identRe = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*');

({int line, int column}) _advancePos(int line, int column, String text) {
  var l = line;
  var c = column;
  for (final unit in text.codeUnits) {
    if (unit == 0x0A) {
      l += 1;
      c = 1;
    } else {
      c += 1;
    }
  }
  return (line: l, column: c);
}

/// Mirrors `identifier_token_kv/1` (`expr.ex` lines 749-765) -- a fixed,
/// exhaustive `switch` over string literals dispatching to either one of
/// the 8 `BuiltinName` values or falling through to the catch-all
/// `variable` clause. Never a `Map<String, BuiltinName>` built from
/// external/config data (design §5.1's "grep-verified, not runtime-mutable"
/// property).
(TokenKind, Object?) _identifierToken(String ident) {
  switch (ident) {
    case 'and':
      return (TokenKind.and, null);
    case 'or':
      return (TokenKind.or, null);
    case 'not':
      return (TokenKind.not, null);
    case 'true':
      return (TokenKind.lit, true);
    case 'false':
      return (TokenKind.lit, false);
    case 'null':
      return (TokenKind.lit, null);
    case 'length':
      return (TokenKind.builtinCall, BuiltinName.length);
    case 'lower':
      return (TokenKind.builtinCall, BuiltinName.lower);
    case 'upper':
      return (TokenKind.builtinCall, BuiltinName.upper);
    case 'trim':
      return (TokenKind.builtinCall, BuiltinName.trim);
    case 'contains':
      return (TokenKind.builtinCall, BuiltinName.contains);
    case 'startsWith':
      return (TokenKind.builtinCall, BuiltinName.startsWith);
    case 'endsWith':
      return (TokenKind.builtinCall, BuiltinName.endsWith);
    case 'coalesce':
      return (TokenKind.builtinCall, BuiltinName.coalesce);
    default:
      return (TokenKind.variable, ident.split('.'));
  }
}

/// Scans a string literal body up to its closing, un-escaped `quote`
/// character. A backslash immediately followed by `quote` is consumed as
/// one escaped-quote unit; any other backslash sequence passes through
/// unchanged (mirrors `scan_string_literal/3`, `expr.ex` lines 455-466).
({bool ok, String content, int nextIndex}) _scanStringLiteral(
  String source,
  int start,
  String quote,
) {
  final buffer = StringBuffer();
  var i = start;
  while (i < source.length) {
    final c = source[i];
    if (c == quote) {
      return (ok: true, content: buffer.toString(), nextIndex: i + 1);
    }
    if (c == '\\' && i + 1 < source.length && source[i + 1] == quote) {
      buffer.write(quote);
      i += 2;
      continue;
    }
    buffer.write(c);
    i += 1;
  }
  return (ok: false, content: '', nextIndex: i);
}

/// Tokenizes an expr-syntax string (as produced by `translateCelToExpr`).
TokenizeResult tokenize(String source) {
  final tokens = <Token>[];
  var line = 1;
  var column = 1;
  var i = 0;

  while (i < source.length) {
    final c = source[i];

    if (kAsciiWhitespaceCodeUnits.contains(c.codeUnitAt(0))) {
      final pos = _advancePos(line, column, c);
      line = pos.line;
      column = pos.column;
      i += 1;
      continue;
    }

    if (c == '(') {
      tokens.add(Token(kind: TokenKind.lparen, text: '(', line: line, column: column));
      column += 1;
      i += 1;
      continue;
    }
    if (c == ')') {
      tokens.add(Token(kind: TokenKind.rparen, text: ')', line: line, column: column));
      column += 1;
      i += 1;
      continue;
    }
    if (c == ',') {
      tokens.add(Token(kind: TokenKind.comma, text: ',', line: line, column: column));
      column += 1;
      i += 1;
      continue;
    }

    final two = i + 2 <= source.length ? source.substring(i, i + 2) : '';
    if (two == '==') {
      tokens.add(Token(kind: TokenKind.cmpOp, value: CmpOp.eq, text: '==', line: line, column: column));
      column += 2;
      i += 2;
      continue;
    }
    if (two == '!=') {
      tokens.add(Token(kind: TokenKind.cmpOp, value: CmpOp.neq, text: '!=', line: line, column: column));
      column += 2;
      i += 2;
      continue;
    }
    if (two == '<=') {
      tokens.add(Token(kind: TokenKind.cmpOp, value: CmpOp.lte, text: '<=', line: line, column: column));
      column += 2;
      i += 2;
      continue;
    }
    if (two == '>=') {
      tokens.add(Token(kind: TokenKind.cmpOp, value: CmpOp.gte, text: '>=', line: line, column: column));
      column += 2;
      i += 2;
      continue;
    }
    if (c == '<') {
      tokens.add(Token(kind: TokenKind.cmpOp, value: CmpOp.lt, text: '<', line: line, column: column));
      column += 1;
      i += 1;
      continue;
    }
    if (c == '>') {
      tokens.add(Token(kind: TokenKind.cmpOp, value: CmpOp.gt, text: '>', line: line, column: column));
      column += 1;
      i += 1;
      continue;
    }
    if (c == '+') {
      tokens.add(Token(kind: TokenKind.arithOp, value: ArithOp.add, text: '+', line: line, column: column));
      column += 1;
      i += 1;
      continue;
    }
    if (c == '-') {
      tokens.add(Token(kind: TokenKind.arithOp, value: ArithOp.sub, text: '-', line: line, column: column));
      column += 1;
      i += 1;
      continue;
    }
    if (c == '*') {
      tokens.add(Token(kind: TokenKind.arithOp, value: ArithOp.mul, text: '*', line: line, column: column));
      column += 1;
      i += 1;
      continue;
    }
    if (c == '/') {
      tokens.add(Token(kind: TokenKind.arithOp, value: ArithOp.div, text: '/', line: line, column: column));
      column += 1;
      i += 1;
      continue;
    }
    if (c == '%') {
      tokens.add(Token(kind: TokenKind.arithOp, value: ArithOp.mod, text: '%', line: line, column: column));
      column += 1;
      i += 1;
      continue;
    }

    if (c == '"' || c == "'") {
      final startLine = line;
      final startColumn = column;
      final scanned = _scanStringLiteral(source, i + 1, c);
      if (!scanned.ok) {
        final rest = source.substring(i + 1);
        return TokenizeErr(
          ParseFailure(
            line: startLine,
            column: startColumn,
            tokenText: rest,
            reason: UnterminatedString(rest),
          ),
        );
      }
      final consumed = source.substring(i, scanned.nextIndex);
      tokens.add(Token(
        kind: TokenKind.lit,
        value: scanned.content,
        text: consumed,
        line: startLine,
        column: startColumn,
      ));
      final pos = _advancePos(startLine, startColumn, consumed);
      line = pos.line;
      column = pos.column;
      i = scanned.nextIndex;
      continue;
    }

    final codeUnit = c.codeUnitAt(0);
    if (codeUnit >= 0x30 && codeUnit <= 0x39) {
      final rest = source.substring(i);
      final match = _numberRe.firstMatch(rest);
      if (match == null) {
        return TokenizeErr(
          ParseFailure(line: line, column: column, tokenText: rest, reason: InvalidNumber(rest)),
        );
      }
      final text = match.group(0)!;
      final isFloat = text.contains('.');
      final num value = isFloat ? double.parse(text) : int.parse(text);
      tokens.add(Token(
        kind: TokenKind.lit,
        value: value,
        numericKind: isFloat ? NumericKind.floatKind : NumericKind.intKind,
        text: text,
        line: line,
        column: column,
      ));
      final pos = _advancePos(line, column, text);
      line = pos.line;
      column = pos.column;
      i += text.length;
      continue;
    }

    final isAlpha = (codeUnit >= 0x61 && codeUnit <= 0x7A) ||
        (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
        codeUnit == 0x5F;
    if (isAlpha) {
      final rest = source.substring(i);
      final match = _identRe.firstMatch(rest);
      if (match == null) {
        return TokenizeErr(
          ParseFailure(line: line, column: column, tokenText: rest, reason: InvalidIdentifier(rest)),
        );
      }
      final text = match.group(0)!;
      final (kind, value) = _identifierToken(text);
      tokens.add(Token(kind: kind, value: value, text: text, line: line, column: column));
      final pos = _advancePos(line, column, text);
      line = pos.line;
      column = pos.column;
      i += text.length;
      continue;
    }

    return TokenizeErr(
      ParseFailure(line: line, column: column, tokenText: c, reason: UnexpectedChar(c)),
    );
  }

  return TokenizeOk(tokens, line, column);
}
