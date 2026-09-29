// Static guard (REQ-422 §5.2, MOB-5, AC6): `Info.plist` must not declare
// `NSAppTransportSecurity` -> `NSAllowsArbitraryLoads` -> true. Absent
// entirely (today's real state) passes; present-and-false also passes.
//
// iOS runtime ATS behaviour is DEFERRED — this host is Windows, no iOS
// build/simulator is available; only this static Info.plist check is
// verified, matching REQ-419 §9's/REQ-421 OQ-3's existing iOS-deferral
// pattern.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

class InfoPlistAtsViolation {
  InfoPlistAtsViolation(this.detail);

  final String detail;

  @override
  String toString() => detail;
}

/// Checks [infoPlistXml] for an `NSAppTransportSecurity` dict whose
/// `NSAllowsArbitraryLoads` is `true`. Pure function so the self-test can
/// exercise it without touching the real file.
List<InfoPlistAtsViolation> checkInfoPlistAts({required String infoPlistXml}) {
  final atsKeyIndex = infoPlistXml.indexOf('<key>NSAppTransportSecurity</key>');
  if (atsKeyIndex == -1) return const [];

  final dictStart = infoPlistXml.indexOf('<dict>', atsKeyIndex);
  if (dictStart == -1) return const [];
  final dictEnd = infoPlistXml.indexOf('</dict>', dictStart);
  if (dictEnd == -1) return const [];
  final dictBody = infoPlistXml.substring(dictStart, dictEnd);

  final arbitraryLoadsKeyIndex = dictBody.indexOf(
    '<key>NSAllowsArbitraryLoads</key>',
  );
  if (arbitraryLoadsKeyIndex == -1) return const [];

  final afterKey = dictBody
      .substring(arbitraryLoadsKeyIndex + '<key>NSAllowsArbitraryLoads</key>'.length)
      .trimLeft();
  if (afterKey.startsWith('<true/>')) {
    return [
      InfoPlistAtsViolation(
        'Info.plist declares NSAppTransportSecurity ->'
        ' NSAllowsArbitraryLoads -> true',
      ),
    ];
  }
  return const [];
}

void main() {
  test('real Info.plist has no NSAllowsArbitraryLoads=true exception', () {
    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();

    final violations = checkInfoPlistAts(infoPlistXml: infoPlist);

    expect(
      violations,
      isEmpty,
      reason: violations.map((v) => v.toString()).join('\n'),
    );
  });

  test('self-test: checker fires on a fixture with'
      ' NSAllowsArbitraryLoads=true', () {
    const fixture = '<key>NSAppTransportSecurity</key><dict>'
        '<key>NSAllowsArbitraryLoads</key><true/></dict>';

    final violations = checkInfoPlistAts(infoPlistXml: fixture);

    expect(violations, hasLength(1));
  });

  test('self-test: checker passes on a fixture with'
      ' NSAllowsArbitraryLoads=false', () {
    const fixture = '<key>NSAppTransportSecurity</key><dict>'
        '<key>NSAllowsArbitraryLoads</key><false/></dict>';

    final violations = checkInfoPlistAts(infoPlistXml: fixture);

    expect(violations, isEmpty);
  });
}
