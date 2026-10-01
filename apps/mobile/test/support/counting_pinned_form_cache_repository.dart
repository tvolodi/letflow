/// A thin spy wrapper around [PinnedFormCacheRepository] that counts
/// [putEntry] calls, for tests that need to prove a code path performs
/// *zero* writes (REQ-427 AC4(c): "persists nothing to any store (no write
/// queue)"). Kept test-local rather than added to
/// `InMemoryPinnedFormCacheRepository` itself (`lib/definitions/
/// pinned_form_cache.dart`) -- that class is production code shared by every
/// resolver-behavior test (AC1-AC4), and a call counter is test-only
/// instrumentation with no production use, matching this directory's own
/// convention of recording calls on dedicated fakes (see
/// `fake_post_capable_http_gateway.dart`'s `RecordedPostCall`/`postCalls`)
/// rather than on the production doubles they wrap.
library;

import 'package:letflow/definitions/pinned_form_cache.dart';

class CountingPinnedFormCacheRepository implements PinnedFormCacheRepository {
  CountingPinnedFormCacheRepository(this._delegate);

  final PinnedFormCacheRepository _delegate;

  /// Incremented on every [putEntry] call -- a direct proof of "zero
  /// writes" (a before/after count or contents comparison on the delegate
  /// would only prove "net zero", which a write-then-delete pair could
  /// still pass).
  int putCallCount = 0;

  @override
  Future<PinnedFormCacheEntry?> getByKey(String formId, String formVersion) {
    return _delegate.getByKey(formId, formVersion);
  }

  @override
  Future<void> putEntry(PinnedFormCacheEntry entry) {
    putCallCount++;
    return _delegate.putEntry(entry);
  }

  @override
  Future<void> close() => _delegate.close();
}
