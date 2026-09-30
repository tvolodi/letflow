/// REQ-294 — barrel export for the Dart port of `Letflow.Engine.Expr`'s
/// pure CEL-subset grammar (`lib/letflow/engine/expr.ex`). A Flutter form
/// renderer imports this file, not the individual pipeline-stage files
/// under `lib/expr/`.
///
/// D1a (`docs/migration/decisions/0020-frontend-architecture.md`): in
/// scope on-device are `visible_when`, `computed` fields, and cross-field
/// validation, expressed only in this grammar -- never a general scripting
/// runtime. The client has no authority: the server re-evaluates on submit
/// and wins (`Letflow.Engine.FormExpressionReevaluation`, REQ-292),
/// unchanged and untouched by this module.
library;

export 'expr_capability.dart';
export 'expr_evaluate.dart';
export 'expr_evaluator.dart' show evalAst;
export 'expr_field_outcome.dart';
export 'expr_parser.dart' show parse;
export 'expr_tokenizer.dart' show Token, TokenKind, TokenizeErr, TokenizeOk, TokenizeResult, tokenize;
export 'expr_translate_cel.dart' show translateCelToExpr;
export 'expr_types.dart';
