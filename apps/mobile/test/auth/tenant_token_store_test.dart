// Supports AC2/AC7: TenantTokenStore is keyed by realmUrl (not slug), and a
// PlatformException from the underlying secure storage propagates rather
// than being swallowed (REQ-421 design §4).
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/auth/auth.dart';

import '../support/fake_secure_storage_platform.dart';

void main() {
  late FakeSecureStoragePlatform fakePlatform;
  late TenantTokenStore store;

  setUp(() {
    fakePlatform = FakeSecureStoragePlatform();
    FlutterSecureStoragePlatform.instance = fakePlatform;
    store = const TenantTokenStore(FlutterSecureStorage());
  });

  final tokensA = TokenSet(
    accessToken: 'access-a',
    refreshToken: 'refresh-a',
    idToken: 'id-a',
    accessTokenExpiration: DateTime(2030),
  );
  final tokensB = TokenSet(
    accessToken: 'access-b',
    refreshToken: 'refresh-b',
    idToken: 'id-b',
    accessTokenExpiration: DateTime(2030),
  );

  test('stores and reads tokens independently per realmUrl', () async {
    await store.store('https://idp.example/realms/a', tokensA);
    await store.store('https://idp.example/realms/b', tokensB);

    final readA = await store.read('https://idp.example/realms/a');
    final readB = await store.read('https://idp.example/realms/b');

    expect(readA!.accessToken, 'access-a');
    expect(readB!.accessToken, 'access-b');
  });

  test('deleting one realm\'s tokens never affects another\'s', () async {
    await store.store('https://idp.example/realms/a', tokensA);
    await store.store('https://idp.example/realms/b', tokensB);

    await store.delete('https://idp.example/realms/a');

    expect(await store.read('https://idp.example/realms/a'), isNull);
    expect(
      (await store.read('https://idp.example/realms/b'))!.accessToken,
      'access-b',
    );
  });

  test('read returns null for a realm nothing was ever stored under', () async {
    expect(await store.read('https://idp.example/realms/never-used'), isNull);
  });

  test('a PlatformException from secure storage propagates on store()', () {
    fakePlatform.throwOnNextCall = PlatformException(code: 'keystore_error');

    expect(
      () => store.store('https://idp.example/realms/a', tokensA),
      throwsA(isA<PlatformException>()),
    );
  });
}
