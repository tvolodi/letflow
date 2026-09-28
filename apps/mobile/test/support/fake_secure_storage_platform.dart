/// In-memory `FlutterSecureStoragePlatform` fake (REQ-421). Real
/// `flutter_secure_storage` calls into a native Keystore/Keychain over a
/// platform channel, which `flutter test`'s host process cannot provide —
/// this substitutes `FlutterSecureStoragePlatform.instance` with a plain
/// in-memory map so `TenantTokenStore` tests exercise the real class
/// end-to-end (JSON encode/decode, per-`realmUrl` keying) without a real
/// secure enclave.
library;

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';

class FakeSecureStoragePlatform extends FlutterSecureStoragePlatform {
  final Map<String, String> _values = {};

  /// When set, the next `write`/`read`/`delete` call throws this instead
  /// (simulates Keystore/Keychain unavailable) — reset after one throw.
  Object? throwOnNextCall;

  void _maybeThrow() {
    final error = throwOnNextCall;
    if (error != null) {
      throwOnNextCall = null;
      throw error;
    }
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    _maybeThrow();
    _values[key] = value;
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    _maybeThrow();
    return _values[key];
  }

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async {
    return _values.containsKey(key);
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    _maybeThrow();
    _values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async {
    return Map<String, String>.from(_values);
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    _values.clear();
  }
}
