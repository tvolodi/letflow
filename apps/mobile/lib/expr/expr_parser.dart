/// REQ-294 — direct structural port of `parse_or_p`/`parse_and_p`/
/// `parse_not_p`/`parse_cmp_p`/`parse_additive_p`/`parse_multiplicative_p`/
/// `parse_unary_p`/`parse_primary_p`/`parse_call_args_p`/
/// `parse_call_args_rest_p` (`expr.ex` lines 792-961), via
/// `web/src/utils/expr/parser.ts` as the direct structural model. Same
/// 8-level precedence chain (lowest -> highest: or, and, not, comparison,
/// +/-, * / %, unary -, primary), same left-associative folding, same
/// right-recursive not/unary -.
library;

import 'expr_tokenizer.dart';
import 'expr_types.dart';

typedef _EofPos = ({int line, int column});

sealed class _PResult<T> {
  const _PResult();
}

final class _POk<T> extends _PResult<T> {
  const _POk(this.value, this.rest);
  final T value;
  final List<Token> rest;
}

final class _PErr<T> extends _PResult<T> {
  const _PErr(this.failure);
  final ParseFailure failure;
}

ParseFailure _failAt(ParseErrorReason reason, Token tok) {
  return ParseFailure(line: tok.line, column: tok.column, tokenText: tok.text, reason: reason);
}

ParseFailure _failEof(ParseErrorReason reason, _EofPos eofPos) {
  return ParseFailure(line: eofPos.line, column: eofPos.column, tokenText: '', reason: reason);
}

_PResult<ExprAst> _parseOr(List<Token> tokens, _EofPos eofPos) {
  final left = _parseAnd(tokens, eofPos);
  if (left is _PErr<ExprAst>) return left;
  final ok = left as _POk<ExprAst>;
  return _parseOrRest(ok.value, ok.rest, eofPos);
}

_PResult<ExprAst> _parseOrRest(ExprAst left, List<Token> tokens, _EofPos eofPos) {
  if (tokens.isNotEmpty && tokens.first.kind == TokenKind.or) {
    final right = _parseAnd(tokens.sublist(1), eofPos);
    if (right is _PErr<ExprAst>) return right;
    final ok = right as _POk<ExprAst>;
    return _parseOrRest(OrNode(left, ok.value), ok.rest, eofPos);
  }
  return _POk(left, tokens);
}

_PResult<ExprAst> _parseAnd(List<Token> tokens, _EofPos eofPos) {
  final left = _parseNot(tokens, eofPos);
  if (left is _PErr<ExprAst>) return left;
  final ok = left as _POk<ExprAst>;
  return _parseAndRest(ok.value, ok.rest, eofPos);
}

_PResult<ExprAst> _parseAndRest(ExprAst left, List<Token> tokens, _EofPos eofPos) {
  if (tokens.isNotEmpty && tokens.first.kind == TokenKind.and) {
    final right = _parseNot(tokens.sublist(1), eofPos);
    if (right is _PErr<ExprAst>) return right;
    final ok = right as _POk<ExprAst>;
    return _parseAndRest(AndNode(left, ok.value), ok.rest, eofPos);
  }
  return _POk(left, tokens);
}

_PResult<ExprAst> _parseNot(List<Token> tokens, _EofPos eofPos) {
  if (tokens.isNotEmpty && tokens.first.kind == TokenKind.not) {
    final sub = _parseNot(tokens.sublist(1), eofPos);
    if (sub is _PErr<ExprAst>) return sub;
    final ok = sub as _POk<ExprAst>;
    return _POk(NotNode(ok.value), ok.rest);
  }
  return _parseCmp(tokens, eofPos);
}

_PResult<ExprAst> _parseCmp(List<Token> tokens, _EofPos eofPos) {
  final left = _parseAdditive(tokens, eofPos);
  if (left is _PErr<ExprAst>) return left;
  final lok = left as _POk<ExprAst>;
  if (lok.rest.isNotEmpty && lok.rest.first.kind == TokenKind.cmpOp) {
    final op = lok.rest.first.value as CmpOp;
    final right = _parseAdditive(lok.rest.sublist(1), eofPos);
    if (right is _PErr<ExprAst>) return right;
    final rok = right as _POk<ExprAst>;
    return _POk(CmpNode(op, lok.value, rok.value), rok.rest);
  }
  return lok;
}

_PResult<ExprAst> _parseAdditive(List<Token> tokens, _EofPos eofPos) {
  final left = _parseMultiplicative(tokens, eofPos);
  if (left is _PErr<ExprAst>) return left;
  final ok = left as _POk<ExprAst>;
  return _parseAdditiveRest(ok.value, ok.rest, eofPos);
}

_PResult<ExprAst> _parseAdditiveRest(ExprAst left, List<Token> tokens, _EofPos eofPos) {
  if (tokens.isNotEmpty &&
      tokens.first.kind == TokenKind.arithOp &&
      (tokens.first.value == ArithOp.add || tokens.first.value == ArithOp.sub)) {
    final op = tokens.first.value as ArithOp;
    final right = _parseMultiplicative(tokens.sublist(1), eofPos);
    if (right is _PErr<ExprAst>) return right;
    final ok = right as _POk<ExprAst>;
    return _parseAdditiveRest(ArithNode(op, left, ok.value), ok.rest, eofPos);
  }
  return _POk(left, tokens);
}

_PResult<ExprAst> _parseMultiplicative(List<Token> tokens, _EofPos eofPos) {
  final left = _parseUnary(tokens, eofPos);
  if (left is _PErr<ExprAst>) return left;
  final ok = left as _POk<ExprAst>;
  return _parseMultiplicativeRest(ok.value, ok.rest, eofPos);
}

_PResult<ExprAst> _parseMultiplicativeRest(ExprAst left, List<Token> tokens, _EofPos eofPos) {
  if (tokens.isNotEmpty &&
      tokens.first.kind == TokenKind.arithOp &&
      (tokens.first.value == ArithOp.mul ||
          tokens.first.value == ArithOp.div ||
          tokens.first.value == ArithOp.mod)) {
    final op = tokens.first.value as ArithOp;
    final right = _parseUnary(tokens.sublist(1), eofPos);
    if (right is _PErr<ExprAst>) return right;
    final ok = right as _POk<ExprAst>;
    return _parseMultiplicativeRest(ArithNode(op, left, ok.value), ok.rest, eofPos);
  }
  return _POk(left, tokens);
}

_PResult<ExprAst> _parseUnary(List<Token> tokens, _EofPos eofPos) {
  if (tokens.isNotEmpty && tokens.first.kind == TokenKind.arithOp && tokens.first.value == ArithOp.sub) {
    final sub = _parseUnary(tokens.sublist(1), eofPos);
    if (sub is _PErr<ExprAst>) return sub;
    final ok = sub as _POk<ExprAst>;
    return _POk(NegNode(ok.value), ok.rest);
  }
  return _parsePrimary(tokens, eofPos);
}

_PResult<ExprAst> _parsePrimary(List<Token> tokens, _EofPos eofPos) {
  if (tokens.isEmpty) {
    return _PErr(_failEof(const UnexpectedEndOfInput(), eofPos));
  }
  final head = tokens.first;

  if (head.kind == TokenKind.builtinCall && tokens.length > 1 && tokens[1].kind == TokenKind.lparen) {
    final args = _parseCallArgs(tokens.sublist(2), eofPos);
    if (args is _PErr<List<ExprAst>>) return _PErr((args).failure);
    final ok = args as _POk<List<ExprAst>>;
    return _POk(CallNode(head.value as BuiltinName, ok.value), ok.rest);
  }

  if (head.kind == TokenKind.lparen) {
    final inner = _parseOr(tokens.sublist(1), eofPos);
    if (inner is _PErr<ExprAst>) return inner;
    final iok = inner as _POk<ExprAst>;
    if (iok.rest.isNotEmpty && iok.rest.first.kind == TokenKind.rparen) {
      return _POk(iok.value, iok.rest.sublist(1));
    }
    if (iok.rest.isNotEmpty) {
      return _PErr(_failAt(const ExpectedRparen(), iok.rest.first));
    }
    return _PErr(_failEof(const ExpectedRparen(), eofPos));
  }

  if (head.kind == TokenKind.lit) {
    return _POk(LitNode(head.value, numericKind: head.numericKind), tokens.sublist(1));
  }

  if (head.kind == TokenKind.variable) {
    return _POk(VarNode(head.value as List<String>), tokens.sublist(1));
  }

  return _PErr(_failAt(UnexpectedToken(head.text), head));
}

_PResult<List<ExprAst>> _parseCallArgs(List<Token> tokens, _EofPos eofPos) {
  if (tokens.isNotEmpty && tokens.first.kind == TokenKind.rparen) {
    return _POk(const <ExprAst>[], tokens.sublist(1));
  }
  final first = _parseOr(tokens, eofPos);
  if (first is _PErr<ExprAst>) return _PErr((first).failure);
  final ok = first as _POk<ExprAst>;
  return _parseCallArgsRest([ok.value], ok.rest, eofPos);
}

_PResult<List<ExprAst>> _parseCallArgsRest(List<ExprAst> acc, List<Token> tokens, _EofPos eofPos) {
  if (tokens.isNotEmpty && tokens.first.kind == TokenKind.comma) {
    final next = _parseOr(tokens.sublist(1), eofPos);
    if (next is _PErr<ExprAst>) return _PErr((next).failure);
    final ok = next as _POk<ExprAst>;
    return _parseCallArgsRest([...acc, ok.value], ok.rest, eofPos);
  }
  if (tokens.isNotEmpty && tokens.first.kind == TokenKind.rparen) {
    return _POk(acc, tokens.sublist(1));
  }
  if (tokens.isNotEmpty) {
    return _PErr(_failAt(const ExpectedRparen(), tokens.first));
  }
  return _PErr(_failEof(const ExpectedRparen(), eofPos));
}

/// Parses an expr-syntax string (as produced by `translateCelToExpr`) into
/// this module's `ExprAst`.
ParseResult parse(String source) {
  final tokenized = tokenize(source);
  if (tokenized is TokenizeErr) {
    return ParseErr(tokenized.failure);
  }
  final ok = tokenized as TokenizeOk;
  final eofPos = (line: ok.eofLine, column: ok.eofColumn);

  final result = _parseOr(ok.tokens, eofPos);
  if (result is _PErr<ExprAst>) {
    return ParseErr((result).failure);
  }
  final pok = result as _POk<ExprAst>;

  if (pok.rest.isNotEmpty) {
    final tok = pok.rest.first;
    return ParseErr(
      ParseFailure(line: tok.line, column: tok.column, tokenText: tok.text, reason: const TrailingInput()),
    );
  }

  return ParseOk(pok.value);
}
