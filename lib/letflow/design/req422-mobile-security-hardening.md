# Design — REQ-422: MOB-5 on-device security hardening (`apps/mobile/`)

**Status:** design, pre-implementation. **Stage:** S9 (mobile tier, `docs/mobile/`).
**SECURITY-REVIEWER is a required, hard gate** — every clause of the requirement
text is security content (token storage, transport, logging, audience scoping).
This must not proceed to REVIEWER/TEST-DESIGNER until SECURITY-REVIEWER signs
off, and the mobile counterpart of `docs/agents/instructions/security-invariants.md`
(MOB-5, `docs/mobile/requirements.md`) is the checklist it gates against.

No implementation code appears below — `@spec`-style signatures, type/field
shapes, and literal string/XML/JSON fragments that are target *values* (manifest
XML, network-security-config XML, doc text), not executable Dart/Kotlin bodies.
Builds on REQ-419 (`lib/letflow/design/req419-mobile-scaffold.md`), REQ-420
(`lib/letflow/design/req420-ci-mobile-gate.md`), and REQ-421
(`lib/letflow/design/req421-mobile-tenant-bootstrap.md`) — it **hardens**
`lib/auth/auth.dart`, `lib/api/api_client.dart`, and
`lib/bootstrap/navigation_bootstrap.dart` as those three files exist today
(read in full before writing this design), it does not redesign MOB-2's
bootstrap sequence from scratch. REQ-421 §4.1 explicitly named this seam:
*"REQ-422 hardens/guards this same class (key rotation, biometric gate, tamper
detection) — not designed or implemented here."* Key rotation and biometric
gating are **not** in REQ-422's requirement text (BUILDS items 1–7) and are
**not** designed here either — flagged as OQ-6.

**No DB/backend change.** This requirement's `owned_modules` are `apps/mobile/`
only (`android/`, `ios/`, `lib/`, `test/`, `docs/mobile/architecture.md`). No
Ecto schema, migration, or `lib/letflow/` router is touched.

---

## 0. Conventions carried over from REQ-419/420/421 (not reinvented here)

- **File placement, single-construction-site rules.** `lib/auth/auth.dart`
  remains the *only* file that imports `flutter_secure_storage`; `lib/api/api_client.dart`
  remains the *only* file that constructs a `Dio` instance (REQ-421 §7.1's
  invariant, unchanged). This design's AC1 requirement — "the only file under
  `lib` that imports `flutter_secure_storage` is the `lib/auth/` token store" —
  is *new* text on top of an *existing* violation this design must close (see
  §1.1).
- **Guard-test idiom** (REQ-419 §6a–6c, confirmed by reading
  `test/guards/module_boundary_guard_test.dart`,
  `test/guards/forbidden_dependencies_guard_test.dart`,
  `test/guards/tenant_identifier_guard_test.dart`): every guard is a **pure,
  exported checker function** operating on in-memory strings/maps (so a
  self-test can drive it with a fixture without touching the real tree), plus
  one `test()` that runs the checker against the real files on disk, plus one
  `test()` ("self-test") that feeds the checker a deliberately violating
  fixture and asserts it fires. Every new guard test in this design follows
  that exact three-part shape — TEST-DESIGNER/MOBILE-DEV write the test code;
  this design specifies each checker's signature and the violation(s) it must
  detect.
- **Riverpod/go_router/Dio/flutter_appauth/flutter_secure_storage** remain the
  only runtime packages (architecture.md §2). This design adds **zero** new
  pubspec dependencies — the JWT-payload decode needed for audience scoping
  (§6) is implemented as a pure `dart:convert`-only function (base64url +
  `jsonDecode`), not a new `jwt_decode`/`dart_jsonwebtoken` package, both to
  avoid growing the dependency surface and because no signature verification
  is needed client-side (the server already verified the token; this is a
  same-device "does this token belong to the tenant I'm about to call"
  sanity check, not a trust boundary).
- **Response/error shape idiom** (REQ-421 §0): every function below states its
  error/failure shape explicitly.

---

## 1. Token storage hardening (BUILDS item 1, AC1)

### 1.1 Closing the existing import-boundary gap

**Finding (read before design, not guessed):** `apps/mobile/lib/bootstrap/navigation_bootstrap.dart`
currently contains:

```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
...
final flutterSecureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage();
});
```

This is a **second** `flutter_secure_storage` import site outside
`lib/auth/`, which AC1's guard would fail against on day one if left
unchanged. This design **relocates** that construction into `lib/auth/auth.dart`
and removes the import (and the bare `FlutterSecureStorage()` construction)
from `navigation_bootstrap.dart` entirely.

### 1.2 Hardened production constructor

`lib/auth/auth.dart` gains a second constructor on `TenantTokenStore`,
alongside the existing test-injectable one (`const TenantTokenStore(this._storage)`,
**unchanged** — test fixtures across `test/auth/`, `test/bootstrap/`, and
`test/support/fake_secure_storage_platform.dart` already depend on
constructing a `TenantTokenStore` over an injected storage, and must keep
doing so):

```
@spec factory TenantTokenStore.production()
```

- Internally constructs exactly one `FlutterSecureStorage` instance with:
  - `aOptions: AndroidOptions(encryptedSharedPreferences: true)`
  - `iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device)`

  passed as the constructor's `aOptions`/`iOptions` defaults (the
  `flutter_secure_storage` plugin API accepts these as instance-level
  defaults applied to every `read`/`write`/`delete` call made through that
  instance — not per-call flags this design would have to thread through
  every call site) — then wraps it in `TenantTokenStore(...)` (the existing
  private-storage-holding constructor).
- `encryptedSharedPreferences: true` (Android) and
  `KeychainAccessibility.first_unlock_this_device` (iOS, **no** `synchronizable`
  flag set — the plugin's iCloud-sync option defaults to `false`/unset, which
  this design relies on rather than re-specifies, since `IOSOptions` has no
  `synchronizable: true` passed anywhere) together satisfy BUILDS item 1's
  exact wording: encrypted-shared-preferences Android storage, and an iOS
  keychain item that unlocks only after the device's first unlock post-boot
  and is **never** included in an iCloud Keychain backup/sync.
- `navigation_bootstrap.dart`'s `tenantTokenStoreProvider` (Riverpod) changes
  from `TenantTokenStore(ref.watch(flutterSecureStorageProvider))` to
  `TenantTokenStore.production()` directly — `flutterSecureStorageProvider`
  and its `flutter_secure_storage` import are deleted from that file. No
  other production call site constructs `TenantTokenStore` any other way.

### 1.3 Guard test — import boundary + no plaintext-persistence path

```
List<TokenStorageBoundaryViolation> checkTokenStorageBoundary({
  required Map<String, String> libFiles, // {relativePath: content}
})
```

Detects, over the real `lib/` tree (paths starting `lib/`):

1. Any file whose content contains
   `import 'package:flutter_secure_storage/...'` (or the `package:letflow/...`
   equivalent form) **other than** `lib/auth/auth.dart` — one violation per
   extra file.
2. Any file under `lib/auth/` or `lib/api/` whose content contains
   `import 'package:shared_preferences/...'` — violation.
3. Any file under `lib/auth/` or `lib/api/` whose content contains
   `import 'dart:io'` **and** a `File(` construction (both conditions —
   `dart:io` alone is used elsewhere for benign reasons such as `Platform.isX`
   checks; the violation is specifically a `File(...)` persistence call
   alongside a `dart:io` import) — violation.

Self-test fixture (per §0's guard idiom): a fake
`{'lib/api/leaky.dart': "import 'dart:io';\nfinal f = File('x');\n"}` and a
fake `{'lib/renderers/form/x.dart': "import 'package:flutter_secure_storage/flutter_secure_storage.dart';\n"}`
must each fire exactly the corresponding violation kind; a fake
`{'lib/auth/auth.dart': "import 'package:flutter_secure_storage/flutter_secure_storage.dart';\n"}`
must fire **zero** violations (the one sanctioned file).

Test file: `apps/mobile/test/guards/token_storage_boundary_guard_test.dart`.

---

## 2. Redacting log interceptor (BUILDS item 2, AC2)

### 2.1 Current state (read before design)

`lib/api/api_client.dart`'s `ApiClient.create` registers exactly one
`Interceptor` — the bearer-attach interceptor (REQ-421 §7.2). **No**
`LogInterceptor`, and no third-party HTTP-logging package, is registered
anywhere in `apps/mobile/lib` today. BUILDS item 2 is disjunctive ("either
absent or replaced by a redacting one") — the "absent" branch is already
true. This design's job is to (a) keep it true with a guard, and (b) supply a
reusable redacting interceptor for REQ-425 (MOB-6, silent refresh/retry) to
adopt, since MOB-6 will be the first requirement with a real motive to log
Dio traffic for debugging retry/backoff behavior — leaving that requirement to
invent its own unredacted logger later is exactly the hazard this item
exists to close ahead of time.

### 2.2 Static guard — no unredacted logger registered

```
List<UnredactedLoggerViolation> checkNoUnredactedLogInterceptor({
  required String apiClientDartSource,
})
```

Fails if `lib/api/api_client.dart`'s source contains `LogInterceptor(`
(Dio's own built-in logger, which is not redacting) **or** a construction of
any interceptor class whose name does not appear in an explicit allowlist
(`_bearerInterceptor`, `RedactingLogInterceptor` — §2.3). A third-party
logging package import (`pretty_dio_logger`, `dio_smart_retry`'s logging
mixin, etc.) anywhere in `pubspec.yaml` is a second, independent violation,
checked the same way `forbidden_dependencies_guard_test.dart` already checks
substrings — this design adds `'logger'`, `'pretty_dio_logger'` are **not**
added to that guard's forbidden-substring list (too broad — `logger` would
false-positive on unrelated words); instead this new checker greps
`pubspec.yaml`'s dependency names for an explicit denylist:
`['pretty_dio_logger', 'dio_smart_retry']` (dio_smart_retry ships its own
non-redacting log callback) — exact-match only, extendable later.

### 2.3 Reusable redacting interceptor (available now, registered by MOB-6)

```
@immutable
class RedactingLogInterceptor extends Interceptor {
  const RedactingLogInterceptor({this.logSink = defaultLogSink});

  final void Function(String) logSink; // injectable for tests

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler);

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler);

  @override
  void onError(DioException err, ErrorInterceptorHandler handler);
}
```

- **Redaction rule (BUILDS item 2, exact):** before any request/response is
  passed to `logSink`, this interceptor:
  1. Replaces the value of an `Authorization` header (any case) with the
     literal string `'[REDACTED]'` — never logs the scheme+token.
  2. Replaces the entire request/response **body** with `'[REDACTED]'`
     whenever the request path (per `RequestOptions.path`, compared
     case-insensitively against a fixed suffix list:
     `['/protocol/openid-connect/token', '/oauth2/token']` — Keycloak's and a
     generic OIDC token endpoint's conventional paths) matches — i.e. the
     token/refresh endpoint's body is never logged even in outline form,
     because a refresh token or access token can appear in either the
     request (`grant_type=refresh_token&refresh_token=...`) or response body.
  3. For every other path, headers other than `Authorization` and the body
     are logged unredacted (this interceptor is a diagnostic tool, not a
     silence-everything switch — only the two secret-bearing surfaces are
     masked).
- Lives in `lib/api/api_client.dart` (no new file — keeps the "one file for
  the Dio surface" convention from REQ-421 §0).
- **Not registered by this requirement.** `ApiClient.create` in REQ-422's
  scope adds no call to `dio.interceptors.add(const RedactingLogInterceptor())` —
  it exists as available infrastructure, per §2.1's rationale. See OQ-1.

### 2.4 Behavioral (black-box) test — the sentinel test (AC2 exact)

Not a guard over source text; a real, driven request. Design of the test's
*shape* (TEST-DESIGNER writes the code):

1. Install a fake `debugPrint` (via `debugPrint = (String? msg, {int? wrapWidth}) => capturedLines.add(msg ?? '')`),
   a fake `dart:developer` `log()` sink (`log()` itself cannot be swapped, but
   `dart:developer`'s `log` writes to the VM service log stream — the test
   instead asserts no code path in `lib/api/` or `lib/auth/` calls
   `developer.log` at all, via a source-grep companion check, since
   intercepting the VM log stream from a `flutter_test` host is not a stable
   seam) — three capture points total: `debugPrint` override (dynamic), a
   source-level grep for `developer.log`/`print(` calls in `lib/api/` and
   `lib/auth/` (static — matches the guard idiom instead of a runtime hook,
   since `print`/`developer.log` have no injectable sink), and
   `RedactingLogInterceptor.logSink` itself if the test chooses to register
   one against a fake `Dio` to exercise §2.3 directly (defense-in-depth, not
   required for AC2's letter, which only requires "every log sink the app
   uses" — an app that uses zero sinks trivially satisfies "asserts neither
   sentinel appears" over the empty set, but the static grep is what makes
   that claim checkable rather than assumed).
2. Drive a full request: construct `ApiClient.forTesting(fakeDio)` (existing
   test seam, REQ-421 §7.1) with `fakeDio`'s `HttpClientAdapter` returning a
   canned response, store a `TokenSet` via `TenantTokenStore` (test-injected
   fake storage) whose `accessToken == 'SECRET-TOKEN-SENTINEL'`, set
   `ActiveRealmHolder.currentRealmUrl`, then call `apiClient.get('/some/path')`.
3. Separately, drive the OIDC exchange path: a `FakeAppAuthAdapter` (existing
   fixture, `test/support/fake_app_auth_adapter.dart`) returning an
   `AuthorizationTokenResponse` whose `refreshToken == 'SECRET-REFRESH-SENTINEL'`,
   through `runTenantBootstrap`.
4. Assert: `capturedLines` (the `debugPrint` capture) contains neither
   sentinel string, **and** the static grep of `lib/api/`+`lib/auth/` source
   for `developer.log(`/bare `print(` calls returns zero hits (so there is no
   sink this dynamic capture could have missed).

Test file: `apps/mobile/test/security/token_redaction_test.dart` (new
directory, `test/security/`, since this is neither a guard-over-source-text
nor a feature/bootstrap test — TEST-DESIGN-VALIDATOR confirms the placement).

---

## 3. Android manifest + network-security-config (BUILDS item 3, AC3, AC4)

### 3.1 Main manifest changes

`apps/mobile/android/app/src/main/AndroidManifest.xml`'s `<application>`
element (currently `android:label`, `android:name`, `android:icon` only)
gains three attributes:

```xml
<application
    android:label="letflow"
    android:name="${applicationName}"
    android:icon="@mipmap/ic_launcher"
    android:usesCleartextTraffic="false"
    android:networkSecurityConfig="@xml/network_security_config"
    android:allowBackup="false">
```

- `android:usesCleartextTraffic="false"` — belt-and-suspenders alongside the
  network-security-config's own `base-config` (Android honours the more
  restrictive of the two; setting both is explicit rather than relying on
  one mechanism alone, matching AC3's literal wording).
- `android:allowBackup="false"` — chosen over a data-extraction-rules XML
  (the requirement's parenthetical alternative) because `allowBackup="false"`
  is a one-line, unambiguous, Android-version-independent statement that
  covers both Auto Backup (API ≤30) and the newer Data Extraction Rules
  mechanism (API 31+ falls back to the legacy `allowBackup` flag when no
  `android:dataExtractionRules` is declared) — simpler than authoring and
  maintaining a separate extraction-rules XML that must independently stay in
  sync with whatever key prefix `flutter_secure_storage` uses internally.
  Flagged as OQ-2 for REVIEWER: acceptable, or does a corporate-tier future
  need selective backup of *non*-secret app data, at which point a
  data-extraction-rules file replacing this flag is the better mechanism?
  Deferred, not decided here, since v1 has no non-secret data worth backing
  up yet (MOB-3's offline cache is explicitly re-fetchable, not a backup
  concern).

### 3.2 `res/xml/network_security_config.xml` (main source set — new file)

```xml
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="false">
        <trust-anchors>
            <certificates src="system" />
        </trust-anchors>
    </base-config>
</network-security-config>
```

Path: `apps/mobile/android/app/src/main/res/xml/network_security_config.xml`.
No `domain-config` in the main (release-shipping) source set — the
`base-config` alone forbids cleartext for every domain, with no exception.
`<certificates src="system">` is the Android default trust store, stated
explicitly rather than left to the platform default so the file is legible
on its own (no behavior change from Android's built-in default — certificate
pinning, which *would* change this, is explicitly `[S]`/deferred, §8).

### 3.3 `res/xml/network_security_config.xml` (debug source set — new file, DEV-ONLY)

Path: `apps/mobile/android/app/src/debug/res/xml/network_security_config.xml`.
Android's resource-merging for `res/xml/<name>.xml` **replaces** the main
file with the debug one for a debug build (it does not merge the two files'
contents) — so the debug file must **restate** the `base-config`, not only
add the exception:

```xml
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">10.0.2.2</domain>
        <domain includeSubdomains="false">localhost</domain>
    </domain-config>
    <base-config cleartextTrafficPermitted="false">
        <trust-anchors>
            <certificates src="system" />
        </trust-anchors>
    </base-config>
</network-security-config>
```

- Exactly two `<domain>` entries, `10.0.2.2` (Android emulator's host-loopback
  alias) and `localhost`, both `includeSubdomains="false"` — no wildcard, no
  third domain.
- This file is **never** part of a release build — Gradle's source-set
  precedence (`debug` overlays `main` only for `assembleDebug`/`bundleDebug`
  variants) means `assembleRelease`/`bundleRelease` never sees this file; the
  release APK's merged manifest resolves `@xml/network_security_config`
  against the `main` file only (§3.2). AC4's `aapt dump xmltree` check is
  exactly the verification that this is true in the actual built artifact,
  not merely in source.
- **No change needed** to `android/app/src/debug/AndroidManifest.xml` (its
  current sole content is the `INTERNET` permission) — the `networkSecurityConfig`
  *reference* is declared once, in the main manifest (§3.1), and Android
  resolves `@xml/network_security_config` to whichever resource file wins for
  the build variant; the debug manifest does not need its own
  `android:networkSecurityConfig` attribute.

### 3.4 Guard test — manifest + network-security-config shape (AC3)

```
List<ManifestSecurityViolation> checkAndroidManifestSecurity({
  required String mainManifestXml,
  required String mainNetworkSecurityConfigXml,
  required String debugNetworkSecurityConfigXml,
})
```

Asserts (each a separate violation kind on failure, mirroring
`test/android/android_manifest_test.dart`'s existing quoting style):

1. `mainManifestXml` contains `android:usesCleartextTraffic="false"`.
2. `mainManifestXml` contains `android:allowBackup="false"` (or, as an
   alternative satisfying branch, references a data-extraction-rules XML that
   itself excludes the secure-storage key prefix — this design ships the
   `allowBackup="false"` branch, §3.1, so the checker's primary assertion is
   that flag; the alternative branch is specified so the checker doesn't
   spuriously fail if a later requirement switches mechanisms).
3. `mainManifestXml` contains `android:networkSecurityConfig="@xml/network_security_config"`.
4. `mainNetworkSecurityConfigXml` contains a `base-config` with
   `cleartextTrafficPermitted="false"` and **no** `domain-config` element
   anywhere permitting cleartext.
5. `debugNetworkSecurityConfigXml` contains a `domain-config` with
   `cleartextTrafficPermitted="true"` whose only `<domain>` entries are
   `10.0.2.2` and `localhost` (fails if a third domain, a wildcard, or
   `includeSubdomains="true"` appears).
6. Any cleartext-permitting `domain-config` found in *any* file **other
   than** the debug-source-set file is a violation (guards against a future
   edit accidentally moving the exception into `main`).

Self-test fixture: a fake main manifest missing `usesCleartextTraffic`, and a
fake debug network-security-config listing three domains (adds
`'evil.example.com'`) — each must fire its corresponding violation.

Test file: `apps/mobile/test/guards/android_manifest_security_guard_test.dart`.

### 3.5 Release-APK verification procedure (AC4 — not a guard test; a build+inspect step MOBILE-DEV/TEST-RUNNER runs and quotes)

Not Dart code — a command sequence this design specifies so Step 2b-mobile's
"quote real output" obligation has an exact target to quote:

```bash
cd apps/mobile
flutter build apk --release          # debug-signed acceptable per AC4
aapt dump xmltree build/app/outputs/flutter-apk/app-release.apk AndroidManifest.xml \
  | grep -A2 usesCleartextTraffic
aapt dump xmltree build/app/outputs/flutter-apk/app-release.apk AndroidManifest.xml \
  | grep networkSecurityConfig
# Decompile/extract the merged network_security_config resource actually
# packaged (apkanalyzer or `unzip -p ... res/xml/network_security_config.xml`
# run through `aapt2 xmlflatten`/`abx` as needed on this host) and confirm it
# is the §3.2 (main) content, not §3.3 (debug) — i.e. contains no
# `domain-config` element at all.
```

If `aapt`/`apkanalyzer` is unavailable on this host (no Android SDK
build-tools on PATH), that is reported explicitly per "No Speculation" — not
assumed to pass.

---

## 4. App-level transport policy (BUILDS item 3b, AC5)

### 4.1 `TransportPolicy` (new: `lib/api/transport_policy.dart`)

A new file (not folded into `api_client.dart`, since it is consumed by both
`lib/api/` and `lib/bootstrap/`, and a single-file-per-concern split matches
how `lib/auth/`/`lib/api/` are already separated by concern rather than by
"everything Dio-related in one file"):

```
abstract class TransportPolicy {
  bool isUrlAllowed(Uri url);
}

@immutable
class ReleaseTransportPolicy implements TransportPolicy {
  const ReleaseTransportPolicy();
  @override
  bool isUrlAllowed(Uri url); // true iff url.scheme == 'https'
}

@immutable
class DebugTransportPolicy implements TransportPolicy {
  const DebugTransportPolicy();
  @override
  bool isUrlAllowed(Uri url);
  // true iff url.scheme == 'https', OR
  // (url.scheme == 'http' AND url.host is exactly '10.0.2.2' or 'localhost',
  //  case-insensitive host compare, no port restriction — a dev backend may
  //  run on any local port).
}

@spec TransportPolicy transportPolicyFor({bool isRelease = kReleaseMode})
// isRelease sourced from package:flutter/foundation.dart's kReleaseMode by
// default, threaded as a parameter (not read a second time internally) so
// tests can force either branch without a real release build.
```

`class TransportPolicyRejectedException implements Exception` — thrown/used
to signal a rejection uniformly across both call sites below; carries the
rejected `Uri` and `isRelease` flag for a clear error message. Not a
`DioException` subtype itself (§4.2 wraps it into one at the Dio call site;
the bootstrap call site (§4.3) uses it directly).

### 4.2 `ApiClient` enforcement — "before any socket is opened"

`lib/api/api_client.dart`'s `ApiClient.create` gains a second interceptor,
added **before** the existing bearer-attach interceptor (order matters only
in that a rejected request never reaches the bearer-attach step either, which
is immaterial to correctness but keeps the reject path cheapest):

```
@spec Interceptor _transportPolicyInterceptor(TransportPolicy policy)
```

- `onRequest`: computes the absolute request `Uri` (`options.uri` — Dio
  resolves `baseUrl` + `path` into this before the adapter runs). If
  `!policy.isUrlAllowed(uri)`, calls
  `handler.reject(DioException(requestOptions: options, error: TransportPolicyRejectedException(uri, ...), type: DioExceptionType.unknown))` —
  **never** calls `handler.next(options)` on the rejected path. `handler.reject`
  short-circuits before Dio's `HttpClientAdapter.fetch` is invoked, which is
  what makes "the fake HTTP layer records zero calls" (AC5) true: the fake
  adapter installed in a test is never reached for a rejected URL.
- `ApiClient.create` gains a parameter:
  `TransportPolicy? transportPolicy` (defaults to `transportPolicyFor()` — real
  `kReleaseMode`-derived policy in production; tests inject
  `const DebugTransportPolicy()`/`const ReleaseTransportPolicy()` directly).

### 4.3 Bootstrap enforcement — realm_url scheme check

`lib/bootstrap/navigation_bootstrap.dart`'s `runTenantBootstrap` gains a
check immediately after `fetchTenantConfig` succeeds and **before**
`authenticateWithTenant` is called (the OIDC call is what would otherwise
open a connection to `config.realmUrl` over whatever scheme it declares):

```
@spec Future<BootstrapResult?> runTenantBootstrap(
  String enteredSlug, {
  required HttpGateway client,
  required TenantTokenStore tokenStore,
  required ActiveRealmHolder activeRealm,
  AppAuthAdapter appAuthAdapter = const RealAppAuthAdapter(),
  TransportPolicy transportPolicy = ..., // defaults to transportPolicyFor()
})
```

- After `fetchTenantConfig` returns `config`: if
  `!transportPolicy.isUrlAllowed(Uri.parse(config.realmUrl))`, return
  **`BootstrapFailure(BootstrapFailureReason.oidcFailure)`** without calling
  `authenticateWithTenant` at all.
- **Decision, stated explicitly, not silently made (OQ-3):** this design
  reuses the existing `oidcFailure` bucket rather than adding a fifth
  `BootstrapFailureReason`/fifth error screen. Rationale: MOB-2's requirement
  text and acceptance criteria fix "four dedicated error screens," and this
  rejection is, from the user's perspective, "we refused to authenticate you
  against this server" — the same category as a genuine OIDC-protocol
  failure, even though the underlying cause (insecure scheme) is different
  and worth distinguishing in logs/telemetry, not necessarily in UI. An
  alternative (a fifth `insecureRealmRejectedScreen`) is equally defensible;
  CODE-DESIGN-VALIDATOR/REVIEWER should confirm this choice rather than treat
  it as obviously settled.
- `fetchTenantConfig`/`ApiClient`'s own transport-policy interceptor (§4.2)
  already covers the tenant-config request itself (it goes through the
  shared `Dio`/`ApiClient`); this §4.3 check is additionally required because
  `authenticateWithTenant`'s OIDC exchange goes through `flutter_appauth`'s
  native AppAuth SDK, **outside** Dio entirely — §4.2's interceptor cannot
  see or block that call.

### 4.4 dart:io / Android cleartext-policy interaction — recorded finding, not a design guess

The requirement text asks the completion report to record "whether the
pinned Flutter version's `dart:io` honours the Android cleartext policy, with
the evidence." This design does **not** assert an answer (that would be
speculation this agent cannot verify from a design pass alone) — it specifies
what MOBILE-DEV must do to answer it during implementation:

1. Check the pinned Flutter version (`3.41.7`, `pubspec.yaml`'s
   `environment.flutter`) and Dart SDK (`>=3.11.0 <3.12.0`) release notes /
   the Flutter engine's `dart:io` HTTP-client source
   (`flutter/engine`'s `io/` bindings) for whether outgoing `HttpClient`
   sockets consult `android.security.net.config` at the OS level.
2. If a real Android build/emulator is available on the implementation host,
   the empirical test is: with the debug network-security-config (§3.3)
   installed and `usesCleartextTraffic="false"` set, attempt an `http://`
   request via `Dio`'s default `dart:io`-backed adapter to a plain-HTTP local
   server and observe whether the OS-level policy alone blocks it (if it
   does, §4's app-level check is defense-in-depth; if it does not — the
   documented Flutter/dart:io gap this item's own preamble anticipates — §4's
   check is load-bearing, not merely redundant).
3. Record the answer and the exact evidence (a doc link, a release-note
   quote, or the empirical test's real output) in the Step 2b-mobile
   completion report, per the requirement text's explicit instruction — this
   is a reporting obligation, not a design element with a checkable
   acceptance criterion of its own, so it is not added to §12's AC table.

### 4.5 Guard/behavioral test shape (AC5)

```
List<Object> checkTransportPolicyDecisions({
  required TransportPolicy releasePolicy,
  required TransportPolicy debugPolicy,
})
```
— a pure table-driven check (release: only `https://x` allowed; debug: `https://x`,
`http://10.0.2.2:*`, `http://localhost:*` allowed, `http://evil.example.com`
rejected under both policies) plus a `flutter_test` using
`ApiClient.forTesting` over a fake `HttpClientAdapter` that records every
`fetch` call, asserting zero calls recorded when the interceptor rejects, and
a `runTenantBootstrap` test with a fake `HttpGateway` returning a
`TenantConfig` whose `realmUrl` is `http://evil.example.com`, asserting
`BootstrapFailure(oidcFailure)` with the injected `FakeAppAuthAdapter` never
invoked (the adapter fixture can assert its own call count is zero).

Test file: `apps/mobile/test/security/transport_policy_test.dart`.

---

## 5. iOS `Info.plist` static guard (BUILDS item 4, AC6)

### 5.1 Current state

`apps/mobile/ios/Runner/Info.plist` (read in full, §"reading" above) contains
**no** `NSAppTransportSecurity` key at all — the "absent" branch of AC6 is
already true; iOS's own default (ATS enabled, no arbitrary loads) governs.
**No file change is required** for this item; only the guard.

### 5.2 Guard test

```
List<InfoPlistAtsViolation> checkInfoPlistAts({required String infoPlistXml})
```

- Parses for a `<key>NSAppTransportSecurity</key>` entry. If absent →
  zero violations (passes). If present, parses the following `<dict>` for a
  `<key>NSAllowsArbitraryLoads</key>` immediately followed by `<true/>` →
  violation; followed by `<false/>` or absent-within-that-dict → passes.
- Self-test fixture: a fake plist fragment containing
  `<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>`
  must fire; the real file (no such key) must not.

Test file: `apps/mobile/test/guards/ios_ats_guard_test.dart`. The completion
report states explicitly: **iOS runtime ATS behaviour is DEFERRED — this
host is Windows, no iOS build/simulator is available; only the static
`Info.plist` check above is verified**, matching REQ-419 §9's/REQ-421 OQ-3's
existing iOS-deferral pattern.

---

## 6. Audience scoping (BUILDS item 5, AC7)

### 6.1 JWT-payload issuer extraction (pure, no new package)

`lib/auth/auth.dart` gains:

```
@spec Map<String, dynamic>? decodeJwtPayload(String jwt)
```

- Splits `jwt` on `.`; if it does not have exactly 3 segments, returns `null`
  (never throws — a malformed/opaque token, e.g. a non-JWT access token some
  IdPs issue, is a `null` result, not a crash).
- Base64url-decodes the middle segment (with `=` padding added as needed —
  `dart:convert`'s `base64Url.normalize`/manual padding, no new package),
  UTF-8 decodes, then `jsonDecode`s it. Any decode failure at any step →
  `null` (caught internally, never propagated as an exception).

```
@spec String? issuerOf(TokenSet tokens)
```

- Returns `decodeJwtPayload(tokens.idToken ?? tokens.accessToken)?['iss'] as String?`
  — prefers `idToken` (the standard OIDC audience/issuer-bearing token) and
  falls back to `accessToken` only if no ID token was stored (some OIDC
  configurations omit it) — `null` if neither decodes to a string `iss`
  claim.

### 6.2 Bearer-interceptor audience check (extends REQ-421 §7.2)

`_bearerInterceptor` (in `lib/api/api_client.dart`) gains one additional
check between "read the token for `activeRealm.currentRealmUrl`" and
"attach it":

```
@spec bool _tokenMatchesActiveRealm(TokenSet tokens, String activeRealmUrl)
// true iff issuerOf(tokens) == activeRealmUrl (exact string compare) OR
// issuerOf(tokens) == null (fail-open only for a token whose iss cannot be
// determined at all — see rationale below; NOT fail-open for a determinable
// mismatch).
```

- If `_tokenMatchesActiveRealm` is `false` (a determinable, mismatched
  issuer), the interceptor does **not** attach the token — the request
  proceeds with no `Authorization` header (same "no token present" branch
  REQ-421 §7.2 already specifies for the no-stored-token case), rather than
  throwing, so a mismatched-audience request fails as an ordinary
  unauthenticated request (401 from the server) instead of crashing the
  caller.
- **Rationale for the `null`-issuer fail-open branch, not silently chosen
  (OQ-4):** since `TenantTokenStore` already keys storage by `realm_url`
  (REQ-421 §4.1) and the active-realm pointer is only ever set to a
  `realm_url` a successful bootstrap just verified (REQ-421 §5.3), a
  determinable mismatch should be structurally unreachable in this
  requirement's own code paths — this check exists as **defense-in-depth**
  against a future code path reading the wrong store key, not as the primary
  mechanism (the primary mechanism is, and remains, per-`realm_url` storage
  keying). Failing open when `iss` cannot be determined avoids breaking every
  request for an IdP/token shape this design didn't anticipate; REVIEWER
  should confirm this tradeoff (fail-open-on-unknown vs. fail-closed-always)
  is acceptable given the primary mechanism already prevents the leak.

### 6.3 Tenant-switch and logout — explicit token deletion

`lib/bootstrap/navigation_bootstrap.dart` gains:

```
@spec Future<void> logout({
  required TenantTokenStore tokenStore,
  required ActiveRealmHolder activeRealm,
})
```

- If `activeRealm.currentRealmUrl` is non-null: `tokenStore.delete(currentRealmUrl)`,
  then set `activeRealm.currentRealmUrl = null`. If already `null`, no-op.
- Called from wherever the app's "log out" UI action lives (no such screen
  exists yet in this requirement's scope — REQ-422 adds the function; wiring
  a visible logout button is MOBILE-DEV's implementation choice, not gated by
  an acceptance criterion here, since none of BUILDS items 1–7 requires a
  logout *screen*).

```
@spec Future<BootstrapResult?> switchTenant(
  String enteredSlug, {
  required HttpGateway client,
  required TenantTokenStore tokenStore,
  required ActiveRealmHolder activeRealm,
  AppAuthAdapter appAuthAdapter = const RealAppAuthAdapter(),
  TransportPolicy transportPolicy = ...,
})
```

- **Decision, stated explicitly (OQ-5):** deletes the *previous* tenant's
  tokens (`tokenStore.delete(previousRealmUrl)`, where `previousRealmUrl =
  activeRealm.currentRealmUrl` captured **before** any new-tenant call is
  made) **immediately**, before calling `runTenantBootstrap(enteredSlug, ...)`
  for the new tenant — not after the new bootstrap succeeds. Rationale: MOB-5's
  text ("on tenant switch... the previous tenant's tokens are deleted") reads
  as an unconditional consequence of *initiating* a switch, and leaving the
  old tenant's token live during a switch attempt that might fail is itself
  the residual-token-exposure risk this item exists to close — the user can
  always re-authenticate against the old tenant if the new one fails. The
  alternative (delete-old-only-on-new-success) trades a moment of
  no-tenant-authenticated risk for a moment of two-tenants-authenticated
  risk; this design picks the former. REVIEWER/SECURITY-REVIEWER should
  confirm.
- If `previousRealmUrl` is `null` (first bootstrap of the app session, not a
  "switch" at all) or equals the new tenant's eventual `config.realmUrl`
  (re-authenticating the *same* tenant), no delete occurs before the new
  bootstrap runs (a same-tenant re-auth is not a "switch," and deleting first
  would just force a needless token gap for no isolation benefit).
- Delegates the rest of the sequence to the existing `runTenantBootstrap`
  (§4.3's transport-policy check included) unchanged — `switchTenant` is a
  thin wrapper adding the pre-delete step, not a second copy of the
  bootstrap sequence.
- `BootstrapController` (Riverpod `ChangeNotifier`, REQ-421) gains a
  `switchTenant(String slug)` method mirroring its existing `beginBootstrap`,
  calling the new top-level `switchTenant` function instead of
  `runTenantBootstrap` directly, and a `logout()` method calling the new
  top-level `logout` function and resetting `_state` to
  `BootstrapUiState.unauthenticated`.

### 6.4 Guard/behavioral test shape (AC7)

1. Unit test on `decodeJwtPayload`/`issuerOf`: a hand-built base64url JWT
   fixture with `{"iss": "https://tenant-a.example/realm"}`, asserting the
   round-trip; a malformed-JWT fixture asserting `null`, not a thrown
   exception.
2. `switchTenant` test: seed the token store with tenant A's tokens under
   `realmUrl = 'https://a.example'`, set `activeRealm.currentRealmUrl = 'https://a.example'`,
   call `switchTenant('b', ...)` with a fake `HttpGateway` resolving tenant
   B's config/memberships/modules and a `FakeAppAuthAdapter` for B; assert
   `tokenStore.read('https://a.example')` is `null` afterward, and that a
   subsequent `ApiClient.get(...)` call (through the real bearer interceptor,
   fake `Dio` adapter recording headers) attaches only tenant B's token, with
   an `iss` claim equal to B's realm — never A's.
3. `logout` test: symmetric, asserting the active realm's token is deleted
   and `activeRealm.currentRealmUrl` becomes `null`.
4. Bearer-interceptor mismatch test: store a token whose `iss` is
   `'https://a.example'` under key `'https://b.example'` (a deliberately
   corrupted fixture, since production code never does this — this is the
   "defense-in-depth actually fires" self-test per §6.2's OQ-4), set
   `activeRealm.currentRealmUrl = 'https://b.example'`, issue a request, and
   assert no `Authorization` header is attached.

Test files: `apps/mobile/test/auth/audience_scoping_test.dart` (items 1, 4),
`apps/mobile/test/bootstrap/tenant_switch_test.dart` (items 2, 3).

---

## 7. Masked-text widget (BUILDS item 6, AC8)

### 7.1 State machine

`apps/mobile/lib/design_system/masked_text.dart` (new file; the placeholder
`design_system.dart` gains an `export 'masked_text.dart';` line, matching the
`api.dart` re-export pattern REQ-421 §0 already established):

```
enum MaskRevealPhase { masked, revealed, locked }

class MaskRevealController extends ChangeNotifier {
  MaskRevealController();

  MaskRevealPhase get phase; // starts at .masked
  bool get canReveal;        // true iff phase == .masked

  void reveal(); // .masked -> .revealed. No-op (does not throw, does not
                  // notify) if phase is already .revealed or .locked.
  void hide();    // .revealed -> .locked. No-op if phase is .masked or
                  // already .locked.
}
```

- **Exactly one reveal, ever, per controller instance.** `masked` →
  (`reveal()`) → `revealed` → (`hide()`) → `locked`, and `locked` has no
  transition back to `revealed` — calling `reveal()` from `locked` is a
  documented no-op, not an exception (a UI double-tap racing the
  hide-transition must not crash the widget).
- A fresh `MaskRevealController()` per masked value is the expected usage —
  this is a one-time-reveal *instance*, not a reusable toggle; a screen
  showing N secrets (API keys, webhook signing keys — INV-4 material)
  constructs N controllers.

### 7.2 Widget

```
class MaskedRevealText extends StatelessWidget {
  const MaskedRevealText({
    super.key,
    required this.value,
    required this.controller,
    this.maskCharacter = '•',
    this.style,
  });

  final String value;
  final MaskRevealController controller;
  final String maskCharacter;
  final TextStyle? style;
}
```

- Rebuilds on `controller` notifications (`AnimatedBuilder`/`ListenableBuilder`
  keyed to `controller`).
- Displays `maskCharacter * value.length` when `phase != .revealed`;
  displays `value` verbatim when `phase == .revealed`.
- Renders a trailing icon button: an "eye" icon enabled (`onPressed: controller.reveal`)
  only when `controller.canReveal` is `true`; once `phase` is `.revealed`, the
  icon becomes a "hide" affordance calling `controller.hide()`; once `phase`
  is `.locked`, the icon is either removed or rendered disabled (implementation
  choice, not gated by an acceptance criterion — the *value* being
  unrevealable is what AC8 checks, not the icon's exact visual state).
- Both `value` (the real secret) and `controller` are passed in **plaintext**
  by the caller — this widget only controls *display*; it is not itself a
  secret-fetching or secret-storage component (INV-4's "never serialised into
  any payload" governs how the caller obtained `value`, not this widget).

### 7.3 Guard/behavioral test shape (AC8)

A `flutter_test` widget test: pump `MaskedRevealText(value: 'sk_live_ABC123', controller: controller)`;
assert the rendered text contains no substring of `'sk_live_ABC123'` and does
contain the mask character repeated `value.length` times; tap the reveal
affordance; assert the real value is now rendered; tap the (now) hide
affordance; assert masked again; attempt to reveal a second time (call
`controller.reveal()` directly, since the icon may no longer be present) and
assert the displayed text is still masked, not the real value.

Test file: `apps/mobile/test/design_system/masked_reveal_text_test.dart`.

---

## 8. `docs/mobile/architecture.md` corporate-tier hardening section (BUILDS item 7, AC9)

Append a new numbered section (this file's existing sections run 1–6, per
the "read before design" pass) — exact text, additive only (no existing text
changed), placed after current §6 ("Application modules (decision 0039)"):

```markdown
## 7. Security hardening before corporate-tier deployment

**Status: documented now, not implemented in v1 (REQ-422).**

Two hardening measures are **required before any corporate-tier deployment**
of the mobile tier, and are **not implemented in v1**:

- **Certificate pinning.** v1 trusts the platform's system certificate store
  (`android/app/src/main/res/xml/network_security_config.xml`'s
  `<certificates src="system">`, `docs/mobile/architecture.md` — this
  section). A corporate-tier deployment, where the client may run on a
  managed device inside a network with a corporate TLS-inspecting proxy or
  where the threat model includes a compromised system trust store, needs
  pinning the platform's own certificate/public key so a MITM proxy with an
  installed root CA cannot intercept API traffic.
- **Root/jailbreak detection.** v1 performs no device-integrity check. A
  corporate-tier deployment needs a check (e.g. `flutter_jailbreak_detection`
  or an equivalent) gating access to tenant-scoped data on an
  un-rooted/un-jailbroken device, since OS-secure storage's guarantees
  (Keystore/Keychain hardware-backing) are weakened or bypassable on a rooted
  device.

Both are `[S]`-priority per `docs/mobile/requirements.md` MOB-5 — required
before corporate-tier, not before v1. Tracked here so the gap is a recorded
decision, not a silent omission discovered later.
```

MOBILE-DEV inserts this verbatim (or with only formatting adjustments to fit
the file's existing heading/table conventions) — the content, not the exact
Markdown table/heading styling, is what AC9 checks.

---

## 9. Guard-test inventory (new files this design specifies)

| Test file | Covers |
|---|---|
| `test/guards/token_storage_boundary_guard_test.dart` | AC1 |
| `test/security/token_redaction_test.dart` | AC2 |
| `test/guards/android_manifest_security_guard_test.dart` | AC3 |
| *(AC4 is a build+inspect procedure, §3.5 — not a Dart test)* | AC4 |
| `test/security/transport_policy_test.dart` | AC5 |
| `test/guards/ios_ats_guard_test.dart` | AC6 |
| `test/auth/audience_scoping_test.dart`, `test/bootstrap/tenant_switch_test.dart` | AC7 |
| `test/design_system/masked_reveal_text_test.dart` | AC8 |
| *(AC9 is a docs check — a plain string-contains test over `docs/mobile/architecture.md`, or reviewed manually by SECURITY-REVIEWER/RELEASE-VALIDATOR; TEST-DESIGNER decides which, not gated by app behavior)* | AC9 |
| Existing `flutter analyze && flutter test` (AC10) | AC10 — no new file, the standard gate |

Every new guard test above follows §0's three-part idiom (pure checker + real-file test + self-test fixture).

---

## 10. Cross-module dependencies

| Package/module | Role in this design |
|---|---|
| `flutter_secure_storage` | §1 — `TenantTokenStore.production()`'s hardened `AndroidOptions`/`IOSOptions` |
| `flutter_appauth` | §4.3 — the call §4.3's transport check gates before it runs |
| `dio` | §2, §4.2 — interceptor chain: transport-policy (new) → bearer-attach (existing) |
| `flutter_riverpod` | §6.3 — `BootstrapController.switchTenant`/`.logout` methods |
| `dart:convert` | §6.1 — JWT-payload base64url + JSON decode, no new package |
| `lib/auth/auth.dart` (this app) | Houses §1.2 (hardened constructor), §6.1 (issuer decode), §6.3 (logout/switchTenant orchestration alongside `navigation_bootstrap.dart`, see below) |
| `lib/api/api_client.dart` (this app) | Houses §2.3 (redacting interceptor, unregistered), §4.1–4.2 (transport policy + interceptor), §6.2 (audience check in bearer interceptor) |
| `lib/api/transport_policy.dart` (this app, **new file**) | §4.1 |
| `lib/bootstrap/navigation_bootstrap.dart` (this app) | Houses §1.1 (provider fix — removes its `flutter_secure_storage` import), §4.3 (`runTenantBootstrap` transport check), §6.3 (`logout`/`switchTenant` top-level functions + `BootstrapController` methods) |
| `lib/design_system/masked_text.dart` (this app, **new file**) | §7 |
| `docs/mobile/architecture.md` | §8 — new §7, additive |
| `Letflow.Routers.MobileTenantConfig` / `Letflow.Routers.Me` (backend) | Unchanged — this requirement adds no new backend call, only hardens existing ones |

No new pubspec dependency (§0).

---

## 11. Invariants

- **One `flutter_secure_storage` import site (§1.1/§1.3).** `lib/auth/auth.dart`
  only, enforced by a guard, closing an existing gap in `navigation_bootstrap.dart`.
- **One `Dio` construction site** — unchanged from REQ-421 §7.1; this design
  adds interceptors, not a second construction.
- **Transport-policy rejection never opens a socket (§4.2, §4.3).** Enforced
  by `handler.reject` running strictly before `HttpClientAdapter.fetch` for
  `ApiClient` calls, and by the realm_url check running strictly before
  `authenticateWithTenant` for the OIDC path.
- **A rejected/mismatched-audience token is never attached (§6.2)** — the
  request proceeds unauthenticated rather than throwing or attaching a
  wrong-tenant token.
- **Exactly one reveal per `MaskRevealController` instance, ever (§7.1).**
- **The debug-only cleartext exception names exactly `10.0.2.2` and
  `localhost`, and exists only in `android/app/src/debug/` (§3.3/§3.4 item 6)** —
  never present in a release-built manifest/network-security-config (§3.5
  verifies this against the actual built APK, not just source).

---

## 12. Acceptance-criteria resolution map

| # | Acceptance criterion (paraphrased) | Resolved by |
|---|---|---|
| 1 | Guard: only `lib/auth/` imports `flutter_secure_storage`; no shared_preferences/`dart:io File` in `lib/auth/`/`lib/api/`; self-test on violating fixture | §1.1 (closes existing gap), §1.3 |
| 2 | Sentinel-token/refresh-token test across every log sink; no unredacted logger | §2.2 (static guard), §2.3 (reusable redactor, unregistered), §2.4 (behavioral test) |
| 3 | Manifest/network-security-config: `usesCleartextTraffic=false`, base-config `cleartextTrafficPermitted=false`, `allowBackup=false`; debug-only cleartext exception naming only `10.0.2.2`/`localhost` | §3.1, §3.2, §3.3, §3.4 |
| 4 | Real `flutter build apk --release` + `aapt dump xmltree` quoted showing cleartext false and no cleartext domain-config | §3.5 |
| 5 | API client/bootstrap reject `http://` before any connection (release); debug allows `http://` for `10.0.2.2`/`localhost` only; `https://` allowed | §4.1–4.3, §4.5 |
| 6 | `Info.plist` guard: `NSAllowsArbitraryLoads` absent/false; iOS runtime deferred (Windows host) stated in report | §5 |
| 7 | Tenant switch/logout deletes previous tenant's tokens; request for tenant B never carries a token whose `iss` is A's realm | §6.1–6.4 |
| 8 | Masked-by-default, one-time reveal, cannot reveal twice — widget test | §7 |
| 9 | `docs/mobile/architecture.md` corporate-tier hardening section, cert pinning + root/jailbreak detection named as required-before-corporate-tier, not v1 | §8 |
| 10 | `flutter analyze && flutter test` pass, real output quoted; SECURITY-REVIEWER sign-off | Standard gate (Step 2b-mobile procedure) + this design's SECURITY-REVIEWER-required header |

---

## 13. Open questions

- **OQ-1 (§2.3).** `RedactingLogInterceptor` is designed but deliberately
  **not registered** in this requirement's scope (BUILDS item 2's "absent"
  branch). Should REQ-422 register it now, in debug builds only, for
  developer convenience — or leave it fully unregistered until REQ-425
  (MOB-6) has an actual need to log retry/backoff behavior? Not decided here;
  either is compliant with the requirement text as written.
- **OQ-2 (§3.1).** `allowBackup="false"` chosen over a data-extraction-rules
  XML. Revisit if a corporate-tier deployment later needs selective backup of
  non-secret app data.
- **OQ-3 (§4.3).** Realm_url-scheme-rejected bootstrap failures reuse the
  existing `BootstrapFailureReason.oidcFailure` bucket rather than adding a
  fifth reason/screen. CODE-DESIGN-VALIDATOR/REVIEWER should confirm this
  reuse rather than a new dedicated reason.
- **OQ-4 (§6.2).** The bearer-interceptor's audience check fails **open**
  (attaches nothing, but does not block the whole request) when a token's
  `iss` cannot be determined at all (a `null` decode), and fails **closed**
  only on a *determinable* mismatch. REVIEWER/SECURITY-REVIEWER should
  confirm this tradeoff, since the primary isolation mechanism remains
  per-`realm_url` storage keying (REQ-421 §4.1) and this check is
  defense-in-depth on top of it, not the sole mechanism.
- **OQ-5 (§6.3).** `switchTenant` deletes the previous tenant's tokens
  **before** attempting the new tenant's bootstrap (not after success).
  REVIEWER/SECURITY-REVIEWER should confirm this ordering choice.
- **OQ-6 (header note).** Key rotation, biometric gating, and tamper
  detection — named in REQ-421 §4.1 as things "REQ-422 hardens/guards" —
  are **not** present in REQ-422's actual requirement text (BUILDS items
  1–7) and are **not** designed here. If a later requirement still expects
  them under the REQ-422 label, that expectation is stale relative to the
  requirement text this design was actually handed; flagged rather than
  guessed at.
- **OQ-7 (§4.4).** The `dart:io`/Android-cleartext-policy interaction is a
  factual question this design cannot answer without empirical
  verification or a primary-source citation — left as an explicit
  implementation-time task with a stated method, not guessed at here.
