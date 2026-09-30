/// REQ-294 — direct port of `translate_cel_to_expr/1` (`expr.ex` lines
/// 200-304), via `web/src/utils/expr/translateCel.ts` as the direct
/// structural model. Copied constant-for-constant from
/// `@unsupported_call_markers` and `unsupported_cel_feature?/1`, not
/// re-derived.
library;

import 'expr_types.dart';

const List<String> _unsupportedCallMarkers = [
  'has(',
  'matches(',
  'all(',
  'exists_one(',
  'exists(',
  'int(',
  'uint(',
  'double(',
  'string(',
  'bool(',
  'bytes(',
  'duration(',
  'timestamp(',
  'size(',
  'map(',
  'map{',
  'filter(',
];

final RegExp _inOperatorRe = RegExp(r'''(?<![A-Za-z0-9_."'])in(?![A-Za-z0-9_])''');
final RegExp _notRe = RegExp(r'!(?!=)');
final RegExp _doubleQuotedStringRe = RegExp(r'"([^"\\]|\\.)*"');
final RegExp _singleQuotedStringRe = RegExp(r"'([^'\\]|\\.)*'");

String _stripVariablesPrefix(String celCondition) {
  return celCondition.replaceAll('variables.', '');
}

String _rewriteNot(String exprSource) {
  return exprSource.replaceAll(_notRe, 'not ');
}

String _stripStringLiterals(String celCondition) {
  return celCondition
      .replaceAll(_doubleQuotedStringRe, '""')
      .replaceAll(_singleQuotedStringRe, "''");
}

bool _containsInOperator(String celCondition) {
  return _inOperatorRe.hasMatch(_stripStringLiterals(celCondition));
}

bool _containsBareQuestionMark(String celCondition) {
  return _stripStringLiterals(celCondition).contains('?');
}

bool _unsupportedCelFeature(String celCondition) {
  return _unsupportedCallMarkers.any(celCondition.contains) ||
      _containsInOperator(celCondition) ||
      _containsBareQuestionMark(celCondition);
}

/// Translates a CEL-syntax condition string into this module's expr-syntax
/// grammar. Pure string-level rewrite -- never touches `variables`, never
/// parses, never evaluates.
TranslateResult translateCelToExpr(String celCondition) {
  final trimmed = celCondition.trim();

  if (trimmed.isEmpty) {
    return const TranslateErr(TranslateErrorReason.translateError);
  }

  if (_unsupportedCelFeature(celCondition)) {
    return const TranslateErr(TranslateErrorReason.unsupportedCelFeature);
  }

  final exprSource = _rewriteNot(
    _stripVariablesPrefix(celCondition).replaceAll('&&', ' and ').replaceAll('||', ' or '),
  );

  if (exprSource.trim().isEmpty) {
    return const TranslateErr(TranslateErrorReason.translateError);
  }

  return TranslateOk(exprSource);
}
