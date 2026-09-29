/// `PinnedFormResolver` — `MOB-3` part 2 (REQ-424 design §5): given a
/// task's `(formId, formVersion)`, resolves exactly that pinned version's
/// `form_schema`, never the "active"/"latest" version of `formId`. The
/// failure this exists to prevent is silent substitution of the active
/// version for a pinned one.
///
/// See `lib/letflow/design/req424-mobile-pinned-form-version-resolution.md`
/// §5 for the full contract this file implements.
library;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart' show HttpGateway;
import '../bootstrap/navigation_bootstrap.dart' show apiClientProvider;
import 'pinned_form_cache.dart';

// ── §5.0 `PinnedFormResolution` ────────────────────────────────────────────

/// The exhaustive result of resolving a task's pinned `{form_id,
/// form_version}`. A future form renderer (REQ-426..428) switches on this
/// type's two variants — never on a raw schema-or-null — so "unavailable"
/// is never confusable with "resolved to an empty/null schema" at the call
/// site.
sealed class PinnedFormResolution {
  const PinnedFormResolution();
}

/// The pinned version's schema was found (cache hit or successful fetch).
/// [formSchema] may itself be `null` — that is a resolved result, not an
/// unavailable one: the task's node genuinely carries no `form_schema`, and
/// the renderer's normal (non-stale-version) path is responsible for
/// however it displays "no schema", not this resolver.
final class PinnedFormResolved extends PinnedFormResolution {
  const PinnedFormResolved({required this.formSchema});
  final Map<String, dynamic>? formSchema;
}

/// The pinned version could not be resolved. Renders as `MOB-4`'s
/// `stale-version` state (REQ-426..428's own build surface).
final class PinnedFormUnavailable extends PinnedFormResolution {
  const PinnedFormUnavailable({required this.reason});
  final PinnedFormUnavailableReason reason;
}

enum PinnedFormUnavailableReason {
  /// The task's own `form_version` was `null` (§5.1 step 1) — structurally
  /// cannot be looked up or cached.
  versionMissing,

  /// A cache miss and the follow-up `GET /tasks/:id` threw — either a
  /// network-transport failure or an `ApiError` (REQ-425's taxonomy; see
  /// `lib/api/api_error.dart`) for a non-2xx response. Not split further
  /// here — resolved (was design §9 OQ-D, deferred pending REQ-425, which
  /// has since landed): `ApiClient.get` normalizes every non-2xx outcome to
  /// a thrown `ApiError` before it reaches this resolver, so both causes
  /// land in the same `catch` below and are reported identically.
  fetchFailed,
}

// ── §5.1 `PinnedFormResolver` ───────────────────────────────────────────────

/// Contract, in order — no step below is retried or looped:
/// 1. `formVersion == null` → [PinnedFormUnavailable] (`versionMissing`),
///    before any I/O.
/// 2. Cache hit on the exact `(formId, formVersion)` key → return
///    immediately, zero network calls.
/// 3. Cache miss → exactly one `GET /api/v1/tasks/:id`. Never a "latest
///    version"/"active version" lookup.
/// 4. Fetch throws (network failure or a thrown `ApiError` for any non-2xx
///    response) → [PinnedFormUnavailable] (`fetchFailed`), nothing cached.
/// 5. Fetch succeeds (200) → cache the fetched `form_schema` under the
///    exact `(formId, formVersion)` key, return [PinnedFormResolved].
@immutable
class PinnedFormResolver {
  const PinnedFormResolver({required this.repository, required this.client});

  final PinnedFormCacheRepository repository;
  final HttpGateway client;

  /// Takes [taskId]/[formId]/[formVersion] as plain primitives supplied by
  /// the caller (a future task/form renderer) — not a `Task` domain object,
  /// which does not exist in `apps/mobile/lib/` yet.
  Future<PinnedFormResolution> resolve({
    required String taskId,
    required String formId,
    required String? formVersion,
  }) async {
    // Step 1 (AC4): a null form_version has no valid two-part cache key to
    // look up or store under — short-circuit before touching either the
    // repository or the network.
    if (formVersion == null) {
      return const PinnedFormUnavailable(
        reason: PinnedFormUnavailableReason.versionMissing,
      );
    }

    // Step 2 (AC1): exact-key lookup only — never by formId alone, so a
    // different cached version of the same formId is never consulted.
    final cached = await repository.getByKey(formId, formVersion);
    if (cached != null) {
      return PinnedFormResolved(formSchema: cached.formSchema);
    }

    // Step 3: cache miss — exactly one fetch, of this task's own detail.
    // Never a "latest"/"active version" lookup for formId (AC5).
    final dynamic response;
    try {
      response = await client.get('/api/v1/tasks/$taskId');
    } catch (_) {
      // AC3/Step 4: a thrown network failure or a thrown `ApiError` (any
      // non-2xx response, per REQ-425's `ApiClient.get` contract) both land
      // here — nothing cached, the previously-cached different version (if
      // any) is never returned.
      return const PinnedFormUnavailable(
        reason: PinnedFormUnavailableReason.fetchFailed,
      );
    }

    // Step 5 (AC2): a present `null` "form_schema" is a valid value, read
    // as-is, never defaulted. Cached under the caller-supplied
    // (formId, formVersion) key — the pinned key this resolver was asked
    // to resolve, not whatever the response body happens to echo.
    final data = response.data as Map<String, dynamic>;
    final fetchedSchema = data['form_schema'] as Map<String, dynamic>?;
    await repository.putEntry(
      PinnedFormCacheEntry(
        formId: formId,
        formVersion: formVersion,
        formSchema: fetchedSchema,
      ),
    );
    return PinnedFormResolved(formSchema: fetchedSchema);
  }
}

// ── §7. Provider wiring ─────────────────────────────────────────────────────

final pinnedFormCacheHolderProvider = Provider<ActivePinnedFormCacheHolder>((
  ref,
) {
  return ActivePinnedFormCacheHolder();
});

/// Only ever read once [pinnedFormCacheHolderProvider]'s `.current` is
/// non-null (i.e. after `openFor` has run) — every real call site
/// (post-bootstrap-success, post-resume) satisfies this by construction,
/// mirroring `definitionSyncServiceProvider`'s own precedent, including its
/// "a null read here is a wiring bug, not silently defended against" stance.
final pinnedFormResolverProvider = Provider<PinnedFormResolver>((ref) {
  final repo = ref.watch(pinnedFormCacheHolderProvider).current;
  if (repo == null) {
    throw StateError(
      'pinnedFormResolverProvider read before ActivePinnedFormCacheHolder'
      '.openFor has run — this is a wiring bug, not a case this provider '
      'silently falls back for.',
    );
  }
  return PinnedFormResolver(repository: repo, client: ref.watch(apiClientProvider));
});
