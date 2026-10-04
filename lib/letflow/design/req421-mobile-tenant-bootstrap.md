# Design — REQ-421: MOB-2 tenant bootstrap / OIDC auth flow (`apps/mobile/`)

**Status:** design, pre-implementation. **Stage:** S9 (mobile tier, `docs/mobile/`).
**Gate for:** the entire mobile tier — "after this, a build can log into a tenant."
**SECURITY-REVIEWER is a required, hard gate** (authentication flow, token
handling — `docs/agents/instructions/security-invariants.md`). This must not
proceed to REVIEWER/TEST-DESIGNER until SECURITY-REVIEWER signs off.

No implementation code appears below — `@spec`-style signatures, type/field
shapes, and literal string/JSON fragments that are target *values* (config,
manifest XML, response shapes), not executable Dart/Kotlin bodies. Builds on
REQ-419's scaffold (`lib/letflow/design/req419-mobile-scaffold.md`) and
REQ-418's Keycloak client + sixth `client_id` key
(`lib/letflow/design/req418-mobile-oidc-client.md`). Reuses those two designs'
naming conventions throughout (see §0).

---

## 0. Conventions carried over from REQ-418/419 (not reinvented here)

- **Redirect scheme / app identity:** `com.bizdala.letflow` (Android
  `applicationId`, iOS bundle id, URI scheme) — REQ-419 §0, REQ-418 §1.2.
  `redirectUrl` for `flutter_appauth` is the literal
  `com.bizdala.letflow:/oauth2redirect`, matching the Keycloak client's sole
  `redirectUris` entry exactly.
- **`client_id` resolution:** never a compiled Dart constant — always the
  `client_id` value returned by the tenant-config response (REQ-418 Part 2).
  This design's OIDC call (§3) sources `clientId` from that response, never
  from a literal.
- **File placement:** `lib/auth/` and `lib/api/` already exist as tracked
  placeholder libraries (REQ-419 §3) — `auth.dart` and `api.dart` respectively
  carry doc comments stating "Built starting REQ-421." This design replaces
  those placeholders' bodies; it does not add new top-level directories.
- **`lib/bootstrap/navigation_bootstrap.dart`** is REQ-419's "one sanctioned
  navigation-bootstrap file" (the sole file outside `lib/features/<id>/`
  permitted to import from inside a feature's tree, per architecture.md §6
  D3 rule 1, and the file the module-boundary guard special-cases). Its doc
  comment already states it covers "tenant slug/deep-link resolution and the
  app's startup sequence... Built starting REQ-421" — this design gives that
  file its real body.
- **`lib/app.dart`**'s placeholder `GoRouter` (path `/` →
  `SlugEntryPlaceholderScreen`) is replaced by this design's real route table
  (§5.4) — the "one sanctioned app/router file" convention (REQ-419 §3) is
  unchanged; no second router file is introduced.
- **Response/error shape idiom:** mirrors
  `docs/guides/backend_developer_guide.md` §3.5 — every function's `@spec`
  states its error shape explicitly (`{:ok, T} | {:error, reason}`-style,
  translated to Dart's nearest equivalent, a sealed `Result`-shaped return
  type per function, spelled out below), never an implicit/undocumented
  failure path.
- **Riverpod/go_router/Dio/flutter_appauth/flutter_secure_storage** are the
  only runtime packages in scope (architecture.md §2, REQ-419 §2's
  `pubspec.yaml`) — this design adds no new package. `intl` (i18n) is REQ-429's
  concern, untouched here.

---

## 1. Deep-link / manual-slug tenant-identity resolution

### 1.1 Pure parser function

`apps/mobile/lib/bootstrap/navigation_bootstrap.dart` (or a small pure helper
it imports from the same file — no new directory; kept in the one sanctioned
bootstrap file per §0):

```
@visibleForTesting
String? parseTenantSlugFromDeepLink(Uri uri, {required String platformHost})
```

- **Input:** the incoming `Uri` (from the OS deep-link/App-Link callback) and
  the build-time platform host (§1.3).
- **Output:** `String?` — the slug, or `null` if the URL does not match the
  expected shape. Never throws; a malformed/foreign URL is a `null` result,
  not an exception (matches the requirement's "returning slug-or-null" framing
  and AC5's "rejects a URL on any other host... returning no slug rather than
  guessing").
- **Matching rule:**
  1. `uri.scheme` must be `"https"` — reject (`null`) otherwise (no `http`,
     no custom scheme here; the custom scheme
     `com.bizdala.letflow:/oauth2redirect` is the OIDC redirect only, handled
     separately by `flutter_appauth`, never routed through this parser).
  2. `uri.host` must equal `"<slug>.<platformHost>"` for some non-empty
     `<slug>` — i.e. `uri.host.endsWith('.$platformHost')` **and** the
     remaining prefix (`uri.host` with the `.$platformHost` suffix stripped)
     is non-empty and contains no further `.` (a single subdomain label, not
     a nested one). `uri.host == platformHost` (no subdomain at all) also
     returns `null` — the platform host itself is never a slug.
  3. On a match, the slug is that stripped prefix, returned **without**
     lowercasing or any other normalization performed by this function —
     slug case-sensitivity/normalization is a tenant-config-lookup concern
     (`Letflow.Identity.get_tenant_by_slug/1`, already in production, not
     re-decided here); this parser only extracts the substring.
  4. Path/query are not inspected — the requirement's URL shape is
     `https://<slug>.<platform-host>/...`, and everything after the host is
     irrelevant to slug extraction (an unresolvable app-link path still
     yields a valid slug here; routing to a "not found" screen inside the app
     is a post-login concern, §6).
- **Type note:** `platformHost` is passed in, never read from a global/env
  inside this pure function, so the AC5 unit test can call it directly with a
  fixture host without touching the real build-time define.

### 1.2 Manual-entry path

A widget (part of `lib/bootstrap/navigation_bootstrap.dart`'s screen set, §5)
replacing `app.dart`'s current `SlugEntryPlaceholderScreen`:

```
class TenantSlugEntryScreen extends ConsumerWidget
```

- Presents a text field; on submit, calls the same bootstrap-sequence entry
  point (§5.2) with the typed slug, with no deep-link `Uri` involved — the
  manual path and the deep-link path converge on one function
  (`runTenantBootstrap`, §5.2) that takes a plain `String slug`, not a `Uri`.
  This keeps `parseTenantSlugFromDeepLink` (§1.1) as the *only* place a `Uri`
  is interpreted, and the rest of the bootstrap sequence slug-typed
  throughout.
- No client-side slug format validation beyond "non-empty" — an invalid or
  unknown slug is discovered post-login (§6.2), per the requirement's
  explicit "the app therefore CANNOT detect an unknown slug before login, and
  must not try to."

### 1.3 Build-time platform-host define

**Open question OQ-1 (flagged, not silently resolved):** neither REQ-418 nor
REQ-419's designs fix a name for the build-time platform-host define — only
`LETFLOW_API_BASE_URL` (REQ-419 §7/README) is an established `--dart-define`
name. This design proposes, consistent with that existing naming style:

- **`--dart-define=LETFLOW_PLATFORM_HOST=<platform-host>`** — read in Dart via
  `const String.fromEnvironment('LETFLOW_PLATFORM_HOST', defaultValue: '')`,
  passed as `navigation_bootstrap.dart`'s `platformHost` argument (§1.1) at
  the one call site inside `app.dart`/the router's redirect handler — never
  read a second time elsewhere (single source of truth, matching how
  `LETFLOW_API_BASE_URL` is read once by `api_client.dart`, §7).
- **`android/app/build.gradle.kts`** gains a `manifestPlaceholders["platformHost"]`
  entry sourced the same way REQ-421's own requirement text names
  (`manifestPlaceholders` fed from the same build configuration as the Dio
  base-URL define) — exact Gradle wiring (reading a Flutter
  `--dart-define` value into a Gradle manifest placeholder requires a
  Gradle-side property, e.g. `-Pplatform-host=<value>` passed alongside the
  `--dart-define`, since Gradle and the Dart build-time-environment constants
  are two separate mechanisms) is left to MOBILE-DEV to wire per the
  project's existing `flutter build apk --dart-define=...` invocation
  pattern (README, REQ-419 §7) — **this design does not invent a second,
  redundant define name for the Gradle side**; it names one canonical value
  (`LETFLOW_PLATFORM_HOST`) and requires both the Dart code and the manifest
  placeholder to be fed from it.
- **This name (`LETFLOW_PLATFORM_HOST`) is CODE-DESIGN-VALIDATOR's to confirm**,
  not a decision-record-level choice (same reversibility class as the
  `com.bizdala.letflow` scheme, REQ-418 OQ-1) — cheap to rename until any
  build using it ships.

### 1.4 `AndroidManifest.xml` intent-filter shape

`apps/mobile/android/app/src/main/AndroidManifest.xml`, inside the launcher
`<activity>` element, one additional `<intent-filter>` (alongside, not
replacing, the existing launcher intent-filter):

```xml
<intent-filter android:autoVerify="false">
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data
        android:scheme="https"
        android:host="*.${platformHost}" />
</intent-filter>
```

- **`android:autoVerify="false"`** — deliberate, not an oversight. Verified
  App Links (`autoVerify="true"`) require `/.well-known/assetlinks.json`
  served by the platform host; no requirement provisions that file. Declaring
  the filter with `autoVerify="false"` still lets Android route matching
  `https://*.${platformHost}/...` links to the app (as an unverified link,
  which on API 31+ may show a disambiguation dialog rather than opening the
  app directly — an accepted UX gap, not a functional gap: the manual-slug
  path (§1.2) remains fully available regardless).
- **App Link verification is recorded as DEFERRED**, reason: "no requirement
  provisions `/.well-known/assetlinks.json` on the platform host; adding
  verified status requires that file to exist and be served, which is
  infrastructure this requirement's `owned_modules`
  (`apps/mobile/`, `apps/mobile/android/`) does not include." This is stated
  explicitly per AC5, not left implicit.
- **iOS universal-link entitlement:** per the requirement text, written but
  DEFERRED — no iOS build on this host (matches REQ-419 §9's existing iOS
  deferral pattern). The entitlement file
  (`apps/mobile/ios/Runner/Runner.entitlements`) gains an
  `com.apple.developer.associated-domains` array with
  `applinks:*.${platformHost}` (mirroring the Android host pattern), written
  but not built/verified, exactly as REQ-419 §9 already defers iOS build
  output. No `apple-app-site-association` file is provisioned, for the same
  reason as Android's `assetlinks.json` — flagged, not silently added.
- **`${platformHost}` in the manifest** resolves from the Gradle
  `manifestPlaceholders["platformHost"]` entry (§1.3) — the manifest itself
  never hardcodes a host string; this is the mechanism by which "the slug is
  the only tenant input; nothing tenant-specific is compiled in" (REQ-419's
  dependency guard, §1.1 of this design) stays true for the *platform* host
  too — the platform host is build-config-derived, same category as
  `LETFLOW_API_BASE_URL`, not a tenant slug.

### 1.5 Cross-check against REQ-419's guard tests

The tenant-identifier guard (`req419-mobile-scaffold.md` §6c) scans for
tenant *slugs* (e.g. `bpm-default`) as string literals in `lib/`. The
platform host (§1.3) and the `com.bizdala.letflow` scheme are not tenant
slugs and do not trip that guard. `parseTenantSlugFromDeepLink` (§1.1) itself
contains no tenant-specific string literal — it takes `platformHost` as a
parameter — so it introduces nothing for that guard to flag.

---

## 2. Tenant-config client (`lib/api/api_client.dart` + a bootstrap-side caller)

### 2.1 Response data class

```
@immutable
class TenantConfig {
  const TenantConfig({
    required this.realmUrl,
    required this.clientId,
    required this.locales,
    required this.defaultLocale,
    required this.branding,
    required this.environmentKind,
  });

  final String realmUrl;
  final String clientId;
  final List<String> locales;
  final String defaultLocale;
  final TenantBranding branding;
  final String environmentKind;

  factory TenantConfig.fromJson(Map<String, dynamic> json)
}

@immutable
class TenantBranding {
  const TenantBranding({
    required this.appName,
    required this.logoUrl,
    required this.primaryColor,
  });

  final String appName;
  final String? logoUrl;
  final String primaryColor;

  factory TenantBranding.fromJson(Map<String, dynamic> json)
}
```

- Field names/types map 1:1 to `Letflow.Routers.MobileTenantConfig.mobile_config_map/2`'s
  six-key response (`realm_url`, `locales`, `default_locale`, `branding`,
  `environment_kind`, `client_id` — `lib/letflow/routers/mobile_tenant_config.ex:262-271`).
  `branding` is a flat `{app_name, logo_url, primary_color}` map on the wire
  (that module's moduledoc, "brand_colors is stored nested... this endpoint's
  disclosed branding shape stays FLAT") — `TenantBranding.fromJson` reads
  exactly those three flat keys, no nested `brand_colors` lookup.
- `TenantConfig.fromJson` is total over the six-key shape: every key is
  `required` in the backend's response (the endpoint never omits one — its
  own never-error rule), so `fromJson` throws a `FormatException`
  (caught upstream by the bootstrap sequence, §5, and mapped to the
  network-unavailable error screen, §6.4, since a malformed/short response
  from the configured API base is treated the same as an unreachable one —
  there is no separate "malformed tenant-config" error screen; only the four
  named in the requirement exist) if any key is absent or the wrong shape.
  No partial/optional field is silently defaulted client-side — the backend
  is the sole source of defaults (its own `@default_*` fallbacks); the client
  never re-implements them.

### 2.2 Client function

```
@spec Future<TenantConfig> fetchTenantConfig(String slug)
```

- Backed by the single shared `Dio` instance from `lib/api/api_client.dart`
  (§7) — **but** this specific call attaches **no** `Authorization` header,
  even though the shared `Dio` instance normally attaches a bearer token
  (§7.2) when one is present in the token store. Mechanism: `api_client.dart`
  exposes a second, narrower entry point alongside the bearer-attaching one:

  ```
  @spec Future<Response<dynamic>> ApiClient.getUnauthenticated(String path, {Map<String, dynamic>? queryParameters})
  ```

  which issues the request through the same `Dio` instance (§7's single-Dio
  rule is about *construction*, not about every call attaching a header) but
  via a request option that suppresses the bearer-attach interceptor for that
  one call (Dio's per-request `Options.extra` flag, e.g.
  `Options(extra: {'skipAuth': true})`, read by the interceptor added in §7.2
  before it decides whether to attach `Authorization`). `fetchTenantConfig`
  is the only caller of `ApiClient.getUnauthenticated` in this requirement's
  scope.
- Request: `GET {LETFLOW_API_BASE_URL}/api/mobile/tenant-config?slug=<slug>`
  — `LETFLOW_API_BASE_URL` read once, inside `api_client.dart` (§7.1), never
  re-read here.
- Success: any 2xx (the backend's own never-error rule means this call
  practically always returns 200 with a body) decodes via
  `TenantConfig.fromJson` and returns it.
- Failure: a `DioException` (no connectivity, DNS failure, timeout, non-2xx
  — the last of which the backend design states should not occur, but the
  client does not assume server behavior it cannot verify at the transport
  layer) or a `FormatException` from `fromJson` both propagate as a thrown
  exception from `fetchTenantConfig` — the bootstrap sequence (§5) catches
  both and routes to network-unavailable (§6.4). `fetchTenantConfig` itself
  performs no retry (REQ-425's concern per §7's scope note).

---

## 3. OIDC flow via `flutter_appauth`

### 3.1 Call shape

```
@spec Future<AuthorizationTokenResponse?> authenticateWithTenant(TenantConfig config)
```

Implemented in `lib/auth/auth.dart`, calling
`FlutterAppAuth().authorizeAndExchangeCode(AuthorizationTokenRequest(...))`
with:

| Parameter | Value | Source |
|---|---|---|
| `clientId` | `config.clientId` | tenant-config response (§2.1) — **never** a compiled Dart constant, per §0 |
| `issuer` | `config.realmUrl` | tenant-config response (§2.1) |
| `redirectUrl` | `'com.bizdala.letflow:/oauth2redirect'` | literal, fixed (§0) — matches the Keycloak client's sole registered `redirectUris` entry (REQ-418 §1.1) |
| `scopes` | `['openid', 'profile', 'email']` (platform default scope set — no tenant-specific scope; open question OQ-2 below if a future requirement needs more) | literal |
| PKCE | S256, `flutter_appauth`'s default behavior for `authorizeAndExchangeCode` — no explicit code-verifier/challenge construction in this app's code (the package generates and validates it internally) | package default |
| Android transport | Custom Tabs via the `appAuthRedirectScheme` Gradle manifest placeholder (`android/app/build.gradle.kts`'s `manifestPlaceholders["appAuthRedirectScheme"] = "com.bizdala.letflow"`) — **no webview** anywhere, matching REQ-419's forbidden-dependency guard (§6b of that design) which already rejects `webview_flutter`/`flutter_inappwebview` | `flutter_appauth`'s own Android integration contract |

- **Return type:** `AuthorizationTokenResponse?` — `null` (not an exception)
  on user cancellation (the package's own convention: a user backing out of
  the Custom Tab returns `null` from `authorizeAndExchangeCode`, distinct from
  a thrown `FlutterAppAuthUserCancelException`/`PlatformException` for an
  actual OIDC-protocol failure). `authenticateWithTenant`'s own `@spec`
  therefore returns `null` on cancellation and lets a `PlatformException`
  from the package **propagate** — the caller (§5.2) is responsible for
  catching it and routing to the OIDC-failure screen (§6.3); this function
  does not itself catch and swallow it, so a genuine OIDC error is never
  silently converted into the same `null` cancellation returns.

### 3.2 Fake adapter seam (for the widget/unit tests)

```
abstract class AppAuthAdapter {
  Future<AuthorizationTokenResponse?> authorizeAndExchangeCode(
    AuthorizationTokenRequest request,
  );
}
```

`authenticateWithTenant` takes an `AppAuthAdapter` (defaulting to a thin
production wrapper around `FlutterAppAuth()`) as an injectable dependency —
this is the seam the LIVE LOGIN caveat's "fake AppAuth adapter" (requirement
text) plugs into for the full-sequence widget/unit tests. No test-only code
ships inside `lib/auth/auth.dart` itself beyond the interface + production
implementation; the fake implementation lives under `apps/mobile/test/`
(TEST-DESIGNER's scope, not this design's).

---

## 4. The one token-store class (`lib/auth/`)

### 4.1 Class shape

```
class TenantTokenStore {
  const TenantTokenStore(FlutterSecureStorage storage);

  Future<void> store(String realmUrl, TokenSet tokens);
  Future<TokenSet?> read(String realmUrl);
  Future<void> delete(String realmUrl);
}

@immutable
class TokenSet {
  const TokenSet({
    required this.accessToken,
    required this.refreshToken,
    required this.idToken,
    required this.accessTokenExpiration,
  });

  final String accessToken;
  final String? refreshToken;
  final String? idToken;
  final DateTime? accessTokenExpiration;
}
```

- **Keying: `realmUrl`, not the entered slug.** Per the requirement text
  ("keyed by tenant (realm_url) so tenant A's tokens are never presented to
  tenant B") — the secure-storage key for a given tenant's token set is a
  value derived from `TenantConfig.realmUrl` (e.g. the realm URL string
  itself, used as — or hashed into — the `flutter_secure_storage` key), never
  the slug the user typed. This matters because a slug is user-entered and
  unverified pre-login (§1.2), while `realm_url` is the value the backend
  actually authenticated against; keying on the verified value, not the
  claimed one, is what makes "tenant B's API calls never carry tenant A's
  access token" (AC2) hold even under a slug that resolves to platform
  defaults (`bpm-default`'s `realm_url`) for an unrecognized slug (REQ-124's
  anti-enumeration behavior, §2 above) — two different unresolvable slugs
  both fall back to the *same* default `realm_url` and therefore, correctly,
  the same storage key and the same (absent) tenant — they are not
  distinguishable tenants at the token-storage layer either, consistent with
  the backend never having distinguished them in the first place.
- **This is the ONLY storage path for tokens in REQ-421's scope.** No other
  class, no shared-preferences fallback, no in-memory-only cache used for
  persistence across app restarts. `lib/auth/auth.dart` exposes
  `TenantTokenStore` as its sole persistence surface; every other component
  in this design that needs to read/write tokens goes through an instance of
  this class (typically obtained via a Riverpod provider,
  `tenantTokenStoreProvider`, constructed once at app startup).
- **REQ-422 seam, explicitly left open, not designed here:** this design
  does not add key-rotation, biometric-gate, or tamper-detection logic to
  `TenantTokenStore`. The three public methods above (`store`/`read`/
  `delete`) are the seam REQ-422 "hardens and guards this" (REQ-421's own
  requirements.yaml text) wraps or extends; this design does not guess at
  REQ-422's own shape beyond stating that seam exists.
  **Correction (ISS-0882, post-REQ-422):** REQ-422 (now built, PR #1973)
  hardened token storage/logging/transport/cleartext/audience-scoping/
  masking only — its actual requirement text and acceptance criteria never
  included key rotation, biometric gating, or tamper detection. Those three
  items remain entirely undesigned and unbuilt anywhere in the mobile tier
  — including `docs/mobile/architecture.md` §7 ("Security hardening before
  corporate-tier deployment"), which records only certificate pinning and
  root/jailbreak detection as required-before-corporate-tier-and-not-in-v1;
  key rotation, biometric gating, and tamper detection are not listed there
  either. If any of the three is still wanted, it needs its own new
  requirement with real acceptance criteria — do not infer coverage from
  this note or from REQ-422.
- **Secure-storage failure:** `store`/`read`/`delete` each let a
  `PlatformException` from `flutter_secure_storage` (e.g. Keystore/Keychain
  unavailable) propagate rather than swallow it — the caller (§5, §6.5) is
  responsible for catching it and routing to the
  secure-storage-unavailable screen.

---

## 5. Post-auth bootstrap sequence

### 5.1 Membership/module response types

```
@immutable
class MembershipEntry {
  const MembershipEntry({
    required this.tenantId,
    required this.tenantSlug,
    required this.tenantDisplayName,
    required this.displayLabel,
  });

  final String tenantId;
  final String tenantSlug;
  final String tenantDisplayName;
  final String? displayLabel;

  factory MembershipEntry.fromJson(Map<String, dynamic> json)
}

@immutable
class InstalledModule {
  const InstalledModule({required this.moduleId, required this.version});

  final String moduleId;
  final String version;

  factory InstalledModule.fromJson(Map<String, dynamic> json)
}
```

Field names map to `Letflow.Routers.Me`'s `home_tenant_json/1`/
`membership_json/1` (`lib/letflow/routers/me.ex:126-144`, four keys:
`tenant_id`, `tenant_slug`, `tenant_display_name`, `display_label`) and
`installed_module_json/1` (`lib/letflow/routers/me.ex:159-162`, two keys:
`module_id`, `version`).

### 5.2 Bootstrap orchestration function

```
@spec Future<BootstrapResult> runTenantBootstrap(String enteredSlug)

sealed class BootstrapResult {}
class BootstrapSuccess extends BootstrapResult {
  const BootstrapSuccess({required this.installedModules});
  final List<InstalledModule> installedModules;
}
class BootstrapFailure extends BootstrapResult {
  const BootstrapFailure(this.reason);
  final BootstrapFailureReason reason;
}

enum BootstrapFailureReason {
  tenantNotFound,
  networkUnavailable,
  oidcFailure,
  secureStorageUnavailable,
}
```

`runTenantBootstrap`, in `lib/bootstrap/navigation_bootstrap.dart`, is the
single function both the manual-entry screen (§1.2) and a resolved deep-link
slug (§1.1) call. Steps, in order:

1. **`fetchTenantConfig(enteredSlug)`** (§2.2). A thrown exception here →
   `BootstrapFailure(networkUnavailable)`.
2. **`authenticateWithTenant(config)`** (§3.1). `null` return (user
   cancellation) → the bootstrap sequence **stops silently**, returning the
   user to the slug-entry screen with no error screen shown (cancellation is
   not a failure state — none of the four dedicated error screens is
   "user cancelled"). A thrown `PlatformException`/OIDC-protocol error →
   `BootstrapFailure(oidcFailure)`.
3. **`tokenStore.store(config.realmUrl, tokens)`** (§4.1), tokens built from
   the `AuthorizationTokenResponse`. A thrown `PlatformException` →
   `BootstrapFailure(secureStorageUnavailable)` — no partial write; the
   store call is a single write attempt, not attempted-then-rolled-back
   (nothing was written yet to roll back on this exact failure path, since
   the exception is thrown by the write itself).
4. **`GET /api/v1/me/memberships`** via the shared `ApiClient` (§7, bearer
   attached automatically from the just-stored token). Two outcomes:
   - **200:** decode `memberships: [MembershipEntry, ...]`. Per the
     requirement's rule: **the first entry** is the tenant the token itself
     serves (`me.ex` moduledoc, "Response shape" — "always includes the
     caller's own current tenant... prepended"). If
     `memberships.first.tenantSlug != enteredSlug` (exact string comparison,
     no normalization applied here beyond what §1.1/§1.2 already didn't
     apply) → **tenant-not-found**, regardless of whether any later entry's
     `tenantSlug` matches — this check only ever inspects `memberships[0]`,
     never searches the list. On this path: call
     `tokenStore.delete(config.realmUrl)` (delete the just-stored tokens)
     **before** returning `BootstrapFailure(tenantNotFound)` — the delete is
     unconditional and happens before the failure result is returned, not
     merely "eventually" on screen dismissal.
   - **403:** per the requirement text and `me.ex`'s own documented
     "`:MembershipsRead` — CANDIDATE deliberately excluded" behavior — this
     is treated as "membership check not applicable for this role," **not**
     as a failure. Skip the membership-slug check entirely and proceed
     directly to step 5. (Any other non-200/non-403 status — e.g. a 5xx —
     is treated as `BootstrapFailure(networkUnavailable)`, the same bucket as
     a transport-level failure, since the app cannot distinguish "backend
     down" from "backend erroring" at this layer and neither has a dedicated
     screen of its own.)
5. **`GET /api/v1/me/modules`** via the shared `ApiClient`. A 200 decodes
   `installed_modules: [InstalledModule, ...]`. Any non-200 here (there is no
   documented CANDIDATE-style exclusion for this route — `me.ex`'s moduledoc
   states `:MyModulesRead` is "granted to every role, including `CANDIDATE`
   and `AGENT_RUNNER`") is `BootstrapFailure(networkUnavailable)` — module
   listing has no partial/degraded path.
6. On success of both required calls (memberships-check-passed-or-skipped,
   then modules): `BootstrapSuccess(installedModules: [...])`.

**Ordering invariant:** no tenant-content route is registered until
`runTenantBootstrap` resolves with `BootstrapSuccess` — §5.4 states the exact
mechanism (route-table construction gated on this result), satisfying AC3's
"no tenant content route is reachable before /me/memberships and /me/modules
have both resolved."

### 5.3 Two-tenant / no-rebuild requirement (AC2)

Nothing in §5.1–5.2 reads any build-time tenant constant. `config.clientId`,
`config.realmUrl`, the entered slug, and the token-store key are all
per-invocation values threaded through `runTenantBootstrap`'s parameters and
return values — no module-level mutable singleton holds "the current
tenant." A second call to `runTenantBootstrap` with a different slug (in the
same running app instance, e.g. after a logout-and-different-tenant-login)
re-fetches its own `TenantConfig`, re-authenticates, and stores tokens under
its own `realm_url` key without disturbing a previous tenant's stored
tokens — this is exactly what `TenantTokenStore`'s per-`realm_url` keying
(§4.1) is for. The `ApiClient`'s bearer-attach interceptor (§7.2) reads
"the currently active tenant's token" from whichever `TenantTokenStore` key
the active app session is scoped to (a Riverpod-held current-realm-url
value, set at the end of a successful `runTenantBootstrap`) — it is never
possible for a stale interceptor state to attach tenant A's token to a
request made after tenant B's bootstrap has completed, because the
active-realm pointer is overwritten as the last step of `BootstrapSuccess`
construction, before any tenant-content request is issued (§5.2 step 6 order).

### 5.4 Route table construction

`app.dart`'s `GoRouter` (REQ-419's "one sanctioned app/router file", §0) is
rebuilt (via a Riverpod-driven redirect/refreshable router, e.g.
`GoRouter(refreshListenable: ..., redirect: ...)`) once `BootstrapSuccess` is
available:

```
@spec List<RouteBase> buildRouteTable(List<InstalledModule> installedModules)
```

- For each `InstalledModule` whose `moduleId` matches a module this build
  ships code for (a static compiled-in registry — this design does not
  invent that registry; it is whichever module-registration mechanism the
  first real `features/<id>/` module introduces, per architecture.md §6 "Per-
  module feature folders" — REQ-421 ships **zero** real modules, so this
  function's real-world output in this requirement's own tests is the empty
  set unless a test fixture supplies a fake installed module), add that
  module's route(s) to the table.
- A `moduleId` **absent** from `installedModules` has **no route entry at
  all** — not a route that then 403s or redirects; the path simply is not
  registered, so `GoRouter`'s own no-match handling shows its not-found page
  (AC3: "navigating to its path shows the not-found screen"). This directly
  implements architecture.md §6's "a module's absence is not information to
  leak" for navigation.
- Before `BootstrapSuccess`, the router's `redirect` callback sends every
  path to the slug-entry screen (§1.2) or, mid-flow, a loading screen — no
  tenant-content path is reachable, satisfying AC3's ordering requirement
  together with §5.2's ordering invariant.

---

## 6. Four dedicated error screens

Each is a distinct, separately keyed widget under
`lib/bootstrap/navigation_bootstrap.dart` (or a small sibling file in the
same directory — no new top-level directory), each taking the information
needed to let the user retry, and each reachable **only** via
`BootstrapResult`/a caught exception from §5 — never a generic error widget
substituting for one of these four.

| Screen | Widget | Key | Triggered by |
|---|---|---|---|
| Tenant not found | `TenantNotFoundScreen` | `Key('tenant-not-found-screen')` | §5.2 step 4's `memberships.first.tenantSlug != enteredSlug` branch — `BootstrapFailure(tenantNotFound)` |
| Network unavailable | `NetworkUnavailableScreen` | `Key('network-unavailable-screen')` | A `SocketException`/`DioException` (connection-level) surfacing from `fetchTenantConfig` (§2.2), or a non-200/403 response from `/me/memberships`/`/me/modules` (§5.2 steps 4/5) — `BootstrapFailure(networkUnavailable)` |
| OIDC failure | `OidcFailureScreen` | `Key('oidc-failure-screen')` | A thrown exception from `authenticateWithTenant` (§3.1), excluding the `null`-cancellation case, which is not an error state — `BootstrapFailure(oidcFailure)` |
| Secure storage unavailable | `SecureStorageUnavailableScreen` | `Key('secure-storage-unavailable-screen')` | A thrown `PlatformException` from `TenantTokenStore.store`/`.read` (§4.1) — `BootstrapFailure(secureStorageUnavailable)` |

- Each screen widget takes an optional retry callback (re-invoking
  `runTenantBootstrap` with the same slug, or returning to the slug-entry
  screen for tenant-not-found, since a not-found result means the slug
  itself was wrong) — exact retry-button copy/behavior is a UI-polish detail
  left to MOBILE-DEV, not gated by any acceptance criterion here.
- `BootstrapResult` (§5.2) is the single dispatch point: the router's
  redirect/error-display logic pattern-matches on `BootstrapFailureReason`
  and renders exactly one of the four widgets above — never a generic
  "Something went wrong" fallback for one of these four named cases (a truly
  unmapped exception type, if one somehow occurred, is out of this
  requirement's four-screen scope and not designed here — none of the
  requirement's SEQUENCE steps produce a fifth failure category).

---

## 7. `lib/api/api_client.dart` — the single `Dio`-construction site

### 7.1 Construction

```
class ApiClient {
  ApiClient._(this._dio);

  factory ApiClient.create({required TenantTokenStore tokenStore})

  final Dio _dio;
}
```

- **Exactly one `Dio(...)` constructor call in `apps/mobile/lib/`, inside
  `ApiClient.create` (or an equivalent single private factory/initializer in
  this file) — this is what AC (`git grep -n 'Dio(' -- apps/mobile/lib`
  returns exactly one hit) requires.** No other file in this requirement's
  scope (`auth.dart`, `navigation_bootstrap.dart`, `app.dart`) constructs its
  own `Dio` — `fetchTenantConfig` (§2.2) and the memberships/modules calls
  (§5.2) all go through a shared `ApiClient` instance (held by a Riverpod
  provider, `apiClientProvider`, constructed once at app startup and injected
  wherever needed).
- Base URL: `const String.fromEnvironment('LETFLOW_API_BASE_URL')` — read
  once, here, matching REQ-419 §7 README's documented `--dart-define` (§0).

### 7.2 Interceptor — bearer attach only

```
@spec void _attachBearerInterceptor(Dio dio, TenantTokenStore tokenStore, ActiveRealmHolder activeRealm)
```

- One `Interceptor` (`onRequest`) added to the single `Dio` instance:
  - If the outgoing request's `Options.extra['skipAuth'] == true` (§2.2's
    unauthenticated-call escape hatch), the interceptor does nothing and
    calls `handler.next(options)` unmodified — **no** `Authorization` header
    is added, which is what AC1's "the tenant-config request carries no
    Authorization header" requires.
  - Otherwise, read the current token via
    `tokenStore.read(activeRealm.currentRealmUrl)` (§5.3's active-realm
    pointer) and, if present, set
    `options.headers['Authorization'] = 'Bearer ${tokens.accessToken}'`
    before calling `handler.next(options)`. If no token is present (no
    tenant has completed bootstrap yet), the request proceeds with no
    `Authorization` header rather than throwing — callers that require
    auth (memberships/modules, §5.2) are only ever invoked after a
    successful token store (§5.2 step 3), so this "no token" branch is not
    expected to be exercised by this requirement's own call sites, but is
    specified rather than left undefined.
- **Explicitly out of REQ-421's scope, per the requirement text and MOB-6's
  own separate requirement:** silent refresh-on-401, retry-after-refresh,
  exponential backoff on 5xx, and typed-`ApiError` normalization are **not**
  designed or implemented here — `api_client.dart` in this requirement
  attaches a bearer token and nothing else. REQ-425 (MOB-6) is the owner of
  that behavior; this design leaves the interceptor chain open for REQ-425
  to add a second interceptor (refresh/retry) without changing the
  single-`Dio`-construction invariant this section establishes.
- **`ApiClient`'s public request methods** used by this requirement's own
  callers:
  ```
  @spec Future<Response<dynamic>> get(String path, {Map<String, dynamic>? queryParameters})
  @spec Future<Response<dynamic>> getUnauthenticated(String path, {Map<String, dynamic>? queryParameters})
  ```
  Both delegate to the same underlying `_dio.get(...)`; `getUnauthenticated`
  is the one that sets `Options(extra: {'skipAuth': true})` (§2.2). No
  `post`/`put`/`delete` method is designed here — REQ-421's own call sites
  are all `GET` (`tenant-config`, `/me/memberships`, `/me/modules`); a later
  requirement adds write methods to this same class without touching its
  single-construction invariant.

---

## 8. `docs/mobile/*.md` dated-note additions (additive only)

### 8.1 `docs/mobile/requirements.md`, MOB-2's first acceptance bullet

Current text (line 63-64):

> - `GET /tenant-config` returns `{ realm_url, locales, default_locale,
>   branding, environment_kind }` **without a bearer token**.

Append immediately after that bullet (same list, new line, original bullet
text unchanged):

> - **Added 2026-09-28 (`REQ-418`).** The response gained a sixth key,
>   `client_id`, alongside the original five — `{ realm_url, locales,
>   default_locale, branding, environment_kind, client_id }`. `REQ-421`'s
>   mobile app consumes this `client_id` as the OIDC `clientId` parameter
>   (never a compiled constant) — see
>   `lib/letflow/design/req418-mobile-oidc-client.md` §2 and
>   `lib/letflow/design/req421-mobile-tenant-bootstrap.md` §3.1.

### 8.2 `docs/mobile/architecture.md`, §3 row 1

Current row 1 (line 69):

> | 1 | An **unauthenticated** `tenant-config` endpoint returning `{ realm_url,
>   locales, default_locale, branding, environment_kind }`, for slug-based
>   bootstrap before any token exists. | `Letflow.Routers.TenantConfig`
>   exists but is a **stub**... |

Append a new sentence to that row's second (State) cell, after its existing
text, or a new line immediately below the table (whichever keeps the table
well-formed — MOBILE-DEV's implementation choice; content is fixed):

> **Added 2026-09-28 (`REQ-418`).** The response now returns six keys, not
> five: `client_id` was added as a sixth, platform-global value so the
> mobile app's OIDC client id is never compiled into the app binary. See
> `lib/letflow/design/req418-mobile-oidc-client.md` §2.3 for the full
> disclosure rationale.

Both notes are additive edits (new lines only); `git diff` on both files
must show only insertions in this section, per the requirement text's "keep
the original text" instruction and this requirement's AC6.

---

## 9. Cross-module dependencies

| Package/module | Role in this design |
|---|---|
| `flutter_appauth` | §3 — `authorizeAndExchangeCode`, PKCE S256 default, Custom Tabs transport |
| `flutter_secure_storage` | §4 — backs `TenantTokenStore` |
| `dio` | §7 — the single `ApiClient`-internal `Dio` instance |
| `go_router` | §5.4 — route table, redirect-gated on `BootstrapResult` (REQ-419 §2 already pins this as the routing package — confirmed, not guessed) |
| `flutter_riverpod` | Providers: `tenantTokenStoreProvider`, `apiClientProvider`, an active-realm holder, and the bootstrap-result state driving the router's `refreshListenable` (REQ-419 §2 already pins this as the state package) |
| `Letflow.Routers.MobileTenantConfig` (backend) | §2 — six-key response contract consumed as-is |
| `Letflow.Routers.Me` (backend) | §5 — `/me/memberships`, `/me/modules` contracts consumed as-is |
| `lib/bootstrap/navigation_bootstrap.dart` (this app) | Houses §1 (parsing), §5 (orchestration), §6 (error screens) — the one sanctioned cross-feature-boundary file (REQ-419 §0/architecture.md §6) |
| `lib/auth/auth.dart` (this app) | Houses §3 (OIDC call) and §4 (token store) |
| `lib/api/api_client.dart` (this app, new file) | Houses §7 (single `Dio`) |
| `lib/app.dart` (this app) | §5.4 — router wiring only; no business logic added here beyond what REQ-419 already placed |

No new package is added beyond REQ-419's `pubspec.yaml` (§2 of that design).
No change to `apps/mobile/lib/features/`, `renderers/`, `definitions/`,
`design_system/`, `i18n/`, or `shared/` — all out of this requirement's
`owned_modules`.

---

## 10. Invariants

- **One token-storage path (requirement text, §4).** `TenantTokenStore` is
  the only class in `lib/auth/` (or anywhere else) that calls into
  `flutter_secure_storage`. No plain-preferences fallback exists.
- **One `Dio` construction site (AC, §7.1).** `git grep -n 'Dio(' --
  apps/mobile/lib` must return exactly one hit.
- **`client_id` never compiled in (§0, §3.1).** No Dart string literal named
  `letflow-mobile` (or any client id) appears as an OIDC `clientId` value
  anywhere in `lib/` — always sourced from `TenantConfig.clientId`.
- **Tenant-not-found is a post-login check only (§5.2 step 4).** No
  code path attempts to distinguish an unknown slug from a known one before
  `authenticateWithTenant` succeeds — consistent with the backend's
  anti-enumeration never-error rule (§2, `mobile_tenant_config.ex` moduledoc).
- **First-entry-only membership check (§5.2 step 4).** The tenant-not-found
  decision reads `memberships[0]` only, never searches for a match anywhere
  else in the list, even when a later entry does match.
- **Module-absence is invisible, not gated (§5.4).** A module missing from
  `installed_modules` has no route registered, not a route that then denies
  access.
- **No route before both `/me/memberships` (or its 403 skip) and
  `/me/modules` resolve (§5.2, §5.4).**

---

## 11. Acceptance-criteria resolution map

| # | Acceptance criterion (paraphrased) | Resolved by |
|---|---|---|
| 1 | tenant-config request has no `Authorization` header; auth request uses `issuer`/`clientId` from that response, fixed `redirectUrl`, PKCE S256 | §2.2 (`getUnauthenticated`/`skipAuth`), §3.1, §7.2 |
| 2 | Two distinct slugs/realm_urls in one app instance, no rebuild, tokens stored under own tenant key, no cross-tenant token leakage | §4.1 (realm_url keying), §5.3, §7.2 (active-realm pointer) |
| 3 | No tenant-content route before memberships+modules resolve; module absent from `installed_modules` has no route | §5.2 (ordering), §5.4 (route table construction) |
| 4 | First-membership-entry mismatch (even with a later match) → tenant-not-found + tokens deleted; CANDIDATE 403 → proceed to `/me/modules` | §5.2 step 4 |
| 5 | Deep-link parser extracts slug from matching host, rejects other hosts (no slug, not a guess); AndroidManifest intent filter quoted with build-time host pattern; App Link verification recorded DEFERRED with reason | §1.1, §1.4 |
| 6 | `docs/mobile/requirements.md`/`architecture.md` carry additive dated `client_id` notes, original text intact | §8 |
| 7 | Four widget-test-forced failures each show their own dedicated screen (by key), not a generic error/crash | §6 (per-`BootstrapFailureReason` screen dispatch, keys listed) |
| 8 | Exactly one `Dio(` construction site, in `lib/api/api_client.dart` | §7.1 |
| 9 | Every AC maps to a concrete design element, no TBD/deferral language, no implementation code bodies | This table; §§1–9 above contain signatures/shapes only, no method bodies |

---

## 12. Open questions

- **OQ-1 (platform-host build-time define name, §1.3).** This design
  proposes `LETFLOW_PLATFORM_HOST` as the `--dart-define` name, fed into both
  the Dart-side parser (§1.1) and the Android Gradle manifest placeholder
  (§1.4), on the same reversible-until-shipped footing as REQ-418's
  `com.bizdala.letflow` scheme choice (that design's OQ-1). Not fixed by any
  prior REQ-418/419 artefact — confirmed absent by search before flagging.
  CODE-DESIGN-VALIDATOR/REVIEWER should confirm or rename before
  implementation.
- **OQ-2 (OIDC scope set, §3.1).** `['openid', 'profile', 'email']` is this
  design's proposed default scope request — no requirement text or prior
  design fixes an exact scope list for the mobile client. If a later
  requirement needs additional scopes (e.g. an offline-access/refresh-token
  scope beyond what `standardFlowEnabled` already implies), that is an
  additive change to this one call site, not a redesign.
- **OQ-3 (iOS universal-link file, §1.4).** The associated-domains
  entitlement is written per this design, but — like REQ-419 §9's iOS build
  deferral — cannot be verified on this (Windows) host. No
  `apple-app-site-association` file is provisioned by this requirement
  (parallel to Android's `assetlinks.json` gap) — flagged as DEFERRED, same
  reasoning as Android's verified-App-Links gap.
- **OQ-4 (compiled-in module registry mechanism, §5.4).** `buildRouteTable`
  assumes some static mapping from `moduleId` to that module's registered
  `RouteBase`s exists once the first real `features/<id>/` module ships.
  REQ-421 itself ships zero real feature modules, so this design specifies
  the *shape* of that mapping's consumption (filter by `installed_modules`)
  without inventing the registration mechanism itself — left for whichever
  requirement adds the first real module (per architecture.md §6, "Per-
  module feature folders").
- **OQ-5 (Gradle-side platform-host plumbing, §1.3).** This design fixes the
  Dart-side define name and the manifest-placeholder *key* name
  (`platformHost`) but leaves the exact Gradle property/invocation
  MOBILE-DEV uses to feed that placeholder from the same build configuration
  as `LETFLOW_API_BASE_URL` unspecified — this is a build-tooling detail, not
  an app-behavior decision, and does not affect any acceptance criterion
  above (all of which are exercised via `flutter test`'s fixture-driven
  checks, not a real Gradle build on this host).
