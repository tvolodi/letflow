// AC5 (manifest half): the AndroidManifest intent filter is quoted here,
// showing a host pattern built from the build-time platform host
// (REQ-421 design §1.4), plus this file records App Link verification
// (assetlinks.json) as DEFERRED with its reason, per the acceptance
// criterion's own wording.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AndroidManifest.xml declares a deep-link intent filter with a host'
      ' pattern built from the build-time platformHost placeholder', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    // Quoted verbatim (also reproduced in this test's own doc comment
    // above, per the acceptance criterion's "quoted" requirement):
    //
    //   <intent-filter android:autoVerify="false">
    //       <action android:name="android.intent.action.VIEW" />
    //       <category android:name="android.intent.category.DEFAULT" />
    //       <category android:name="android.intent.category.BROWSABLE" />
    //       <data
    //           android:scheme="https"
    //           android:host="*.${platformHost}" />
    //   </intent-filter>
    expect(manifest, contains('android:autoVerify="false"'));
    expect(manifest, contains('android.intent.action.VIEW'));
    expect(manifest, contains('android.intent.category.BROWSABLE'));
    expect(manifest, contains('android:scheme="https"'));
    expect(manifest, contains(r'android:host="*.${platformHost}"'));
  });

  test('App Link verification (assetlinks.json) is recorded as DEFERRED, with'
      ' its reason, not silently added', () {
    // DEFERRED: verified App Links (`autoVerify="true"`) require
    // `/.well-known/assetlinks.json` served by the platform host. No
    // requirement provisions that file, and serving it is
    // infrastructure outside this requirement's owned_modules
    // (apps/mobile/, apps/mobile/android/) — so the filter above is
    // declared with `autoVerify="false"` and unverified-link behavior
    // (a possible API 31+ disambiguation dialog) is an accepted UX gap,
    // not a functional one: the manual-slug entry path
    // (`TenantSlugEntryScreen`) remains fully available regardless.
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, isNot(contains('android:autoVerify="true"')));

    final assetLinksExists = File(
      'assets/.well-known/assetlinks.json',
    ).existsSync();
    expect(
      assetLinksExists,
      isFalse,
      reason:
          'assetlinks.json is DEFERRED (see this test\'s doc comment) — '
          'it must not exist in this requirement\'s scope',
    );
  });

  test(
    'iOS universal-link entitlement mirrors the Android host pattern, also'
    ' written but DEFERRED (no apple-app-site-association is provisioned)',
    () {
      final entitlements = File(
        'ios/Runner/Runner.entitlements',
      ).readAsStringSync();
      expect(entitlements, contains('com.apple.developer.associated-domains'));
      expect(entitlements, contains('applinks:*.'));

      final aasaExists = File(
        'assets/.well-known/apple-app-site-association',
      ).existsSync();
      expect(aasaExists, isFalse);
    },
  );
}
