// Static guard (REQ-422 §3.4, MOB-5, AC3): the main manifest disables
// cleartext traffic and app-data backup and references a
// network-security-config that itself forbids cleartext with no exception,
// and the debug-only cleartext exception names exactly `10.0.2.2` and
// `localhost`, nowhere else.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

class ManifestSecurityViolation {
  ManifestSecurityViolation(this.kind);

  final String kind;

  @override
  String toString() => kind;
}

final RegExp _domainConfigCleartextTrue = RegExp(
  r'<domain-config[^>]*cleartextTrafficPermitted="true"[^>]*>([\s\S]*?)</domain-config>',
);
final RegExp _domainTag = RegExp(r'<domain[^>]*>([^<]+)</domain>');
final RegExp _domainIncludeSubdomainsTrue = RegExp(
  r'<domain[^>]*includeSubdomains="true"[^>]*>',
);

/// Checks the three manifest/network-security-config file contents
/// (REQ-422 §3.4). Pure function so the self-test can exercise it without
/// touching the real files.
List<ManifestSecurityViolation> checkAndroidManifestSecurity({
  required String mainManifestXml,
  required String mainNetworkSecurityConfigXml,
  required String debugNetworkSecurityConfigXml,
}) {
  final violations = <ManifestSecurityViolation>[];

  if (!mainManifestXml.contains('android:usesCleartextTraffic="false"')) {
    violations.add(
      ManifestSecurityViolation(
        'main AndroidManifest.xml missing android:usesCleartextTraffic="false"',
      ),
    );
  }
  if (!mainManifestXml.contains('android:allowBackup="false"')) {
    violations.add(
      ManifestSecurityViolation(
        'main AndroidManifest.xml missing android:allowBackup="false"'
        ' (no data-extraction-rules alternative present either)',
      ),
    );
  }
  if (!mainManifestXml.contains(
    'android:networkSecurityConfig="@xml/network_security_config"',
  )) {
    violations.add(
      ManifestSecurityViolation(
        'main AndroidManifest.xml missing android:networkSecurityConfig='
        '"@xml/network_security_config"',
      ),
    );
  }

  final mainHasBaseConfigFalse = RegExp(
    r'<base-config[^>]*cleartextTrafficPermitted="false"',
  ).hasMatch(mainNetworkSecurityConfigXml);
  if (!mainHasBaseConfigFalse) {
    violations.add(
      ManifestSecurityViolation(
        'main network_security_config.xml missing a base-config with'
        ' cleartextTrafficPermitted="false"',
      ),
    );
  }
  if (_domainConfigCleartextTrue.hasMatch(mainNetworkSecurityConfigXml)) {
    violations.add(
      ManifestSecurityViolation(
        'main network_security_config.xml contains a cleartext-permitting'
        ' domain-config — must have none',
      ),
    );
  }

  final debugDomainMatch = _domainConfigCleartextTrue.firstMatch(
    debugNetworkSecurityConfigXml,
  );
  if (debugDomainMatch == null) {
    violations.add(
      ManifestSecurityViolation(
        'debug network_security_config.xml missing a domain-config with'
        ' cleartextTrafficPermitted="true"',
      ),
    );
  } else {
    final domains = _domainTag
        .allMatches(debugDomainMatch.group(1)!)
        .map((m) => m.group(1)!.trim())
        .toList();
    final expected = {'10.0.2.2', 'localhost'};
    if (domains.toSet().length != domains.length ||
        domains.toSet().difference(expected).isNotEmpty ||
        expected.difference(domains.toSet()).isNotEmpty) {
      violations.add(
        ManifestSecurityViolation(
          'debug network_security_config.xml domain-config lists'
          ' $domains, expected exactly {10.0.2.2, localhost}',
        ),
      );
    }
    if (_domainIncludeSubdomainsTrue.hasMatch(debugDomainMatch.group(1)!)) {
      violations.add(
        ManifestSecurityViolation(
          'debug network_security_config.xml domain entry has'
          ' includeSubdomains="true" — must be false',
        ),
      );
    }
  }

  return violations;
}

void main() {
  test(
    'real Android manifest + network-security-config files have zero'
    ' violations',
    () {
      final mainManifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      final mainNsc = File(
        'android/app/src/main/res/xml/network_security_config.xml',
      ).readAsStringSync();
      final debugNsc = File(
        'android/app/src/debug/res/xml/network_security_config.xml',
      ).readAsStringSync();

      final violations = checkAndroidManifestSecurity(
        mainManifestXml: mainManifest,
        mainNetworkSecurityConfigXml: mainNsc,
        debugNetworkSecurityConfigXml: debugNsc,
      );

      expect(
        violations,
        isEmpty,
        reason: violations.map((v) => v.toString()).join('\n'),
      );
    },
  );

  test('self-test: checker fires when usesCleartextTraffic is missing', () {
    final violations = checkAndroidManifestSecurity(
      mainManifestXml: '<application android:allowBackup="false" '
          'android:networkSecurityConfig="@xml/network_security_config">'
          '</application>',
      mainNetworkSecurityConfigXml:
          '<network-security-config><base-config '
          'cleartextTrafficPermitted="false"/></network-security-config>',
      debugNetworkSecurityConfigXml:
          '<network-security-config><domain-config '
          'cleartextTrafficPermitted="true">'
          '<domain includeSubdomains="false">10.0.2.2</domain>'
          '<domain includeSubdomains="false">localhost</domain>'
          '</domain-config></network-security-config>',
    );

    expect(
      violations.any((v) => v.kind.contains('usesCleartextTraffic')),
      isTrue,
    );
  });

  test('self-test: checker fires when the debug config adds a third'
      ' cleartext-permitted domain', () {
    final violations = checkAndroidManifestSecurity(
      mainManifestXml: '<application android:usesCleartextTraffic="false" '
          'android:allowBackup="false" '
          'android:networkSecurityConfig="@xml/network_security_config">'
          '</application>',
      mainNetworkSecurityConfigXml:
          '<network-security-config><base-config '
          'cleartextTrafficPermitted="false"/></network-security-config>',
      debugNetworkSecurityConfigXml:
          '<network-security-config><domain-config '
          'cleartextTrafficPermitted="true">'
          '<domain includeSubdomains="false">10.0.2.2</domain>'
          '<domain includeSubdomains="false">localhost</domain>'
          '<domain includeSubdomains="false">evil.example.com</domain>'
          '</domain-config></network-security-config>',
    );

    expect(
      violations.any((v) => v.kind.contains('expected exactly')),
      isTrue,
    );
  });
}
