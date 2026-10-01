/// REQ-294 — mirrors `web/src/utils/expr/capability.ts` one-for-one, which
/// itself implements REQ-290's client contract
/// (`lib/letflow/design/req290-corpus-drift-guard.md` §7/§13.1-13.2). A
/// set-membership check on the tag vocabulary, not a semver comparison --
/// `corpus_schema_version` is surfaced for diagnostics only, never parsed
/// as a version number here.
library;

import 'package:flutter/foundation.dart' show immutable;

import 'expr_types.dart';

/// This evaluator's own statically-known implemented-tag set, hand-
/// maintained, one entry per `grammar_constructs` tag this module actually
/// implements -- the 30 tags in `priv/expr_conformance/manifest.json`
/// today, enumerated literally (design §10.1: "hardcoded but fails loudly
/// on staleness" -- a drift from `manifest.json`'s real content can only
/// ever cause an incompatibility to be, correctly, reported, never a
/// silent pass).
const Set<String> kStaticCapabilities = {
  'arith:add',
  'arith:div',
  'arith:mod',
  'arith:mul',
  'arith:neg',
  'arith:sub',
  'bool:and',
  'bool:not',
  'bool:or',
  'builtin:coalesce',
  'builtin:contains',
  'builtin:endsWith',
  'builtin:length',
  'builtin:lower',
  'builtin:startsWith',
  'builtin:trim',
  'builtin:upper',
  'cmp:eq',
  'cmp:gt',
  'cmp:gte',
  'cmp:lt',
  'cmp:lte',
  'cmp:neq',
  'lit:boolean',
  'lit:float',
  'lit:integer',
  'lit:null',
  'lit:string',
  'var:dotted',
  'var:simple',
};

@immutable
class ManifestCompatibility {
  const ManifestCompatibility({required this.compatible, required this.unsupported});

  final bool compatible;

  /// `manifest.capabilities - kStaticCapabilities`, empty iff `compatible`.
  final List<String> unsupported;
}

/// Coarse, proactive, at load/startup (design §10.1 point 1).
ManifestCompatibility checkManifestCompatibility(List<String> manifestCapabilities) {
  final unsupported = manifestCapabilities.where((tag) => !kStaticCapabilities.contains(tag)).toList();
  return ManifestCompatibility(compatible: unsupported.isEmpty, unsupported: unsupported);
}

const Map<CmpOp, String> _cmpTag = {
  CmpOp.eq: 'cmp:eq',
  CmpOp.neq: 'cmp:neq',
  CmpOp.lt: 'cmp:lt',
  CmpOp.lte: 'cmp:lte',
  CmpOp.gt: 'cmp:gt',
  CmpOp.gte: 'cmp:gte',
};

const Map<ArithOp, String> _arithTag = {
  ArithOp.add: 'arith:add',
  ArithOp.sub: 'arith:sub',
  ArithOp.mul: 'arith:mul',
  ArithOp.div: 'arith:div',
  ArithOp.mod: 'arith:mod',
};

const Map<BuiltinName, String> _builtinTag = {
  BuiltinName.length: 'builtin:length',
  BuiltinName.lower: 'builtin:lower',
  BuiltinName.upper: 'builtin:upper',
  BuiltinName.trim: 'builtin:trim',
  BuiltinName.contains: 'builtin:contains',
  BuiltinName.startsWith: 'builtin:startsWith',
  BuiltinName.endsWith: 'builtin:endsWith',
  BuiltinName.coalesce: 'builtin:coalesce',
};

String _tagForLit(ExprValue value) {
  if (value == null) return 'lit:null';
  if (value is bool) return 'lit:boolean';
  if (value is String) return 'lit:string';
  if (value is int) return 'lit:integer';
  if (value is double) return 'lit:float';
  return 'lit:string';
}

/// Fine, reactive, per parsed AST, defence in depth (design §10.1 point 2).
/// Walks `ast` and returns every `grammar_constructs`-shaped tag it
/// actually uses that is NOT in [kStaticCapabilities].
List<String> checkAstCapabilities(ExprAst ast) {
  final found = <String>{};

  void visit(ExprAst node) {
    switch (node) {
      case LitNode(:final value):
        found.add(_tagForLit(value));
      case VarNode(:final path):
        found.add(path.length > 1 ? 'var:dotted' : 'var:simple');
      case NotNode(:final sub):
        found.add('bool:not');
        visit(sub);
      case AndNode(:final left, :final right):
        found.add('bool:and');
        visit(left);
        visit(right);
      case OrNode(:final left, :final right):
        found.add('bool:or');
        visit(left);
        visit(right);
      case CmpNode(:final op, :final left, :final right):
        found.add(_cmpTag[op] ?? 'cmp:${op.name}');
        visit(left);
        visit(right);
      case ArithNode(:final op, :final left, :final right):
        found.add(_arithTag[op] ?? 'arith:${op.name}');
        visit(left);
        visit(right);
      case NegNode(:final sub):
        found.add('arith:neg');
        visit(sub);
      case CallNode(:final name, :final args):
        found.add(_builtinTag[name] ?? 'builtin:${name.name}');
        for (final arg in args) {
          visit(arg);
        }
    }
  }

  visit(ast);

  return found.where((tag) => !kStaticCapabilities.contains(tag)).toList();
}

/// Composed startup check a future form-load sequence calls once per cached
/// `manifest.json` fetch/bundle.
ManifestCompatibility evaluatorCompatibility(List<String> manifestCapabilities) {
  return checkManifestCompatibility(manifestCapabilities);
}
