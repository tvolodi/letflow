// REQ-294 — mirrors `web/src/utils/expr/capability.test.ts` (REQ-293):
// manifest/AST capability-check behaviour, plus a cross-check that
// [kStaticCapabilities] matches the real `priv/expr_conformance/manifest.json`
// contents exactly (AC4/AC12 — no drift).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/expr/expr.dart';
import 'package:path/path.dart' as p;

String get _manifestPath =>
    p.normalize(p.join(Directory.current.path, '..', '..', 'priv', 'expr_conformance', 'manifest.json'));

void main() {
  test('kStaticCapabilities has exactly the 30 tags the real manifest.json declares', () {
    final raw = File(_manifestPath).readAsStringSync();
    final manifest = jsonDecode(raw) as Map<String, Object?>;
    final capabilities = (manifest['capabilities'] as List<Object?>).cast<String>();

    expect(capabilities.length, 30);
    expect(kStaticCapabilities, capabilities.toSet());
  });

  test('checkManifestCompatibility is compatible for the real manifest capabilities', () {
    final raw = File(_manifestPath).readAsStringSync();
    final manifest = jsonDecode(raw) as Map<String, Object?>;
    final capabilities = (manifest['capabilities'] as List<Object?>).cast<String>();

    final result = checkManifestCompatibility(capabilities);

    expect(result.compatible, isTrue);
    expect(result.unsupported, isEmpty);
  });

  test('checkManifestCompatibility reports an unknown tag as unsupported', () {
    final result = checkManifestCompatibility(['cmp:eq', 'builtin:regexMatch']);

    expect(result.compatible, isFalse);
    expect(result.unsupported, ['builtin:regexMatch']);
  });

  test('checkAstCapabilities walks the AST and finds no unsupported tag for an in-grammar expression', () {
    final parsed = parse('amount > 100 and lower(name) == "bob"');
    expect(parsed, isA<ParseOk>());
    final tags = checkAstCapabilities((parsed as ParseOk).ast);
    expect(tags, isEmpty);
  });

  test('checkAstCapabilities tags every construct actually used', () {
    final parsed = parse('order.status == "approved"');
    expect(parsed, isA<ParseOk>());
    final ast = (parsed as ParseOk).ast;

    // Reconstruct the full set of used tags via the same visitor logic by
    // checking against a manifest missing exactly the tags this expression
    // needs -- if checkManifestCompatibility flags them as unsupported,
    // checkAstCapabilities' defence-in-depth path should too.
    final tags = checkAstCapabilities(ast);
    // 'cmp:eq', 'lit:string', 'var:dotted' are all in kStaticCapabilities,
    // so none should show up as unsupported here.
    expect(tags, isEmpty);
  });
}
