# Design — REQ-425: MOB-6 mobile API client hardening (`apps/mobile/lib/api/`)

**Status:** design, pre-implementation. **Stage:** S9 (mobile tier, `docs/mobile/`).
**SECURITY-REVIEWER is a required, hard gate** — refresh-token handling and token
clearing are explicitly named in this requirement's routing text
(`context.requirement_text`), and MOB-6 falls under the mobile counterpart of
`docs/agents/instructions/security-invariants.md`'s "anything resolving a ... token"
clause per `WF-02_requirement_implementation.md` Step 2c. This design must not proceed
past CODE-DESIGN-VALIDATOR into implementation without that understanding carried
forward.

No implementation code appears below — `@spec`-style signatures, type/field shapes,
enum/class shapes, and literal values (constant names, formulas, regexes) only. This
requirement is built **before** MOB-4 (REQ-426..428) per the S9 build order — the
renderers' six mandatory states (`docs/mobile/requirements.md` MOB-4) consume the
`ApiError` type this design defines, but this design does not depend on MOB-4's
renderer code; it only needs to produce a type shape MOB-4 can later classify against.

Builds on REQ-419 (`lib/letflow/design/req419-mobile-scaffold.md`), REQ-421
(`lib/letflow/design/req421-mobile-tenant-bootstrap.md`), and REQ-422
(`lib/letflow/design/req422-mobile-security-hardening.md`) — it **hardens**
`apps/mobile/lib/api/api_client.dart`, `api.dart`, and `transport_policy.dart` as they
exist today (read in full before writing this design; contents restated where load-
bearing below), it does not redesign the client from scratch.

**No DB/backend change.** `owned_modules` are `apps/mobile/lib/api/` and
`apps/mobile/test/guards/` only. No Ecto schema, migration, or `lib/letflow/` router is
touched by this requirement. Where this design cites backend response shapes (§1.2,
§1.3), it is reading already-shipped backend code (`lib/letflow/api/error.ex`,
`lib/letflow/plugs/admission.ex`, `lib/letflow/plugs/public_read_rate_limit.ex`) to
determine the exact wire shape the mobile client must parse — not proposing a backend
change.

---

## 0. Current state (read before design, not guessed)

`apps/mobile/lib/api/api_client.dart` today:

- `ApiClient implements HttpGateway` — the sole `Dio` construction site
  (`ApiClient.create`, AC8 from REQ-421/422), wrapping `_dio` privately.
- `HttpGateway` — abstract interface with exactly two methods: `get` and
  `getUnauthenticated`. **No `post`/`put`/`patch`/`delete` methods exist yet.**
- Two interceptors registered, in order: `_transportPolicyInterceptor` (REQ-422 §4.2,
  rejects a disallowed URL before any socket opens), then `_bearerInterceptor`
  (REQ-421 §7.2, extended by REQ-422 §6.2 with the `_tokenMatchesActiveRealm` audience
  check).
- `Dio`'s `BaseOptions(validateStatus: (_) => true)` — every HTTP status code is
  accepted as a normal `Response`, never a thrown `DioException`; a thrown
  `DioException` from this client today only ever means a genuine transport failure
  (no connectivity, DNS, timeout, or `TransportPolicyRejectedException`).
- `RedactingLogInterceptor` — designed and present (REQ-422 §2.3) but **not
  registered** by `ApiClient.create`. REQ-422's own header note (line 259) explicitly
  names REQ-425 as the requirement expected to adopt it "when it has an actual need to
  log Dio traffic for debugging retry/backoff behavior." This design registers it —
  see §6.
- `ApiClient.forTesting(Dio dio)` — the `@visibleForTesting` seam every existing test
  in `apps/mobile/test/api/api_client_test.dart` uses; this design preserves it
  unchanged in shape (tests keep constructing a real `Dio` over a fake
  `HttpClientAdapter` and wrapping it).
- `TenantTokenStore`/`TokenSet`/`issuerOf` live in `apps/mobile/lib/auth/auth.dart`
  (REQ-421/422) — this design's refresh coordinator calls into that existing store; it
  does not add a second token-storage path (would violate the token-storage-boundary
  guard, `apps/mobile/test/guards/token_storage_boundary_guard_test.dart`).
- No refresh-token flow exists anywhere in `lib/api/` or `lib/auth/` today —
  `authenticateWithTenant` (REQ-421 §3.1) only performs the initial authorization-code
  exchange; nothing in the tree today calls a `flutter_appauth` token-refresh API. This
  is genuinely new surface, not a hardening of an existing refresh path.
- No named backoff/retry mechanism exists in `lib/api/` today.
- No `ApiError` type exists in `lib/api/` today.
- `apps/mobile/test/guards/` today has two guards, both following the same
  three-part idiom (pure checker over in-memory maps/strings + a `test()` against the
  real tree + a `test()` self-test against a deliberately-violating fixture):
  `forbidden_dependencies_guard_test.dart` (pubspec dependency names) and
  `token_storage_boundary_guard_test.dart` (per-file source-text regex checks over
  `{relativePath: content}`). This design's new guard (§4) follows the same idiom,
  modeled specifically on `token_storage_boundary_guard_test.dart`'s shape (source-text
  regex over an in-memory file map), since the single-client guard's job — "no file
  outside `lib/api/` imports a raw HTTP package" — is structurally identical to
  "no file outside `lib/auth/auth.dart` imports `flutter_secure_storage`."
- `web/tests/guards/forbidlist.ts`'s `raw-fetch-outside-client` pattern
  (`/\bfetch\(|\baxios\(/`, `appliesTo: 'source'`, `allowedPaths: ['web/src/api/client.ts']`)
  is architecturally the same rule this design's guard enforces on the Dart side — a
  central `GuardPattern` registry with a name/regex/allowedPaths/rationale shape. The
  Dart guard does not need a shared-registry abstraction (no second consuming guard
  file exists in `apps/mobile/test/guards/` today that would justify one; the two
  existing guards each own their own checker), so this design keeps the existing
  per-file idiom rather than introducing a `forbidlist.ts`-equivalent registry file —
  flagged as **OQ-6** below for REVIEWER to confirm that choice is still right once a
  third guard exists.

---

## 1. The sealed `ApiError` type

### 1.1 Variant list and shape

New file: `apps/mobile/lib/api/api_error.dart`, re-exported from `api.dart` alongside
`api_client.dart` (matching the existing `export 'api_client.dart';` pattern —
`api.dart` gains a second `export 'api_error.dart';` line).

```
@immutable
sealed class ApiError implements Exception {
  const ApiError();
}

@immutable
class NetworkUnavailableError extends ApiError {
  const NetworkUnavailableError({this.cause});
  final Object? cause; // the underlying DioException/SocketException, for logging only
}

@immutable
class UnauthorizedError extends ApiError {
  const UnauthorizedError();
}

@immutable
class ForbiddenError extends ApiError {
  const ForbiddenError();
}

@immutable
class NotFoundError extends ApiError {
  const NotFoundError();
}

@immutable
class ModuleNotAvailableError extends ApiError {
  const ModuleNotAvailableError({required this.moduleId});
  final String moduleId; // the <id> segment of /api/v1/modules/<id>/...
}

@immutable
class BackpressureError extends ApiError {
  const BackpressureError({required this.retryAfterSeconds});
  final int retryAfterSeconds; // parsed from the Retry-After response header
}

@immutable
class ValidationError extends ApiError {
  const ValidationError({required this.fieldErrors});
  final List<ApiFieldError> fieldErrors; // RFC 9457 "errors" array, see §1.3
}

@immutable
class ApiFieldError {
  const ApiFieldError({
    required this.field,
    required this.constraint,
    required this.message,
    this.received,
  });
  final String field;
  final String constraint;
  final String message;
  final Object? received;
}

@immutable
class ConflictError extends ApiError {
  const ConflictError();
}

@immutable
class ServerError extends ApiError {
  const ServerError({this.lastStatusCode});
  final int? lastStatusCode; // the final 5xx status after retries were exhausted
}
```

`ApiError` is a Dart 3 `sealed class` — every call site pattern-matching on it (a
`switch` expression/statement over the nine subtypes) is exhaustiveness-checked by the
analyzer at compile time, which is the mechanism that makes "every one of the six
MOB-4 renderer states classifies this requirement's `ApiError`" a compile-time-enforced
property rather than a convention MOB-4 could silently drift from.

### 1.2 Status-code / exception → variant mapping rule (exact)

A single mapping function performs this classification. Its result is what every
`ApiClient` public method (§5) returns/throws instead of a raw `Response`/`DioException`.

```
@spec ApiError classifyError(
  RequestOptions requestOptions, {
  int? statusCode,
  Object? transportException, // a caught DioException (non-response type) or
                               // SocketException, when statusCode is null
  String? retryAfterHeader,   // the raw "Retry-After" response header value, if present
  Object? responseBody,       // decoded JSON body, if any (for the 422 branch)
})
```

Mapping, evaluated in this order (first match wins):

1. `statusCode == null` (a `DioException` whose `type` is
   `connectionError`/`connectionTimeout`/`sendTimeout`/`receiveTimeout`/`unknown` with
   no `response`, or a `SocketException` caught at the client boundary) →
   `NetworkUnavailableError(cause: transportException)`.
2. `statusCode == 401` → `UnauthorizedError()`.
3. `statusCode == 403` → `ForbiddenError()`.
4. `statusCode == 404` **and** `_isModulePath(requestOptions.path)` (see below) →
   `ModuleNotAvailableError(moduleId: _extractModuleId(requestOptions.path))`.
5. `statusCode == 404` (module-path check false) → `NotFoundError()`.
6. `statusCode == 429` → `BackpressureError(retryAfterSeconds: _parseRetryAfter(retryAfterHeader))`.
7. `statusCode == 422` → `ValidationError(fieldErrors: _parseFieldErrors(responseBody))`.
8. `statusCode == 409` → `ConflictError()`.
9. `statusCode != null && statusCode >= 500 && statusCode <= 599` →
   `ServerError(lastStatusCode: statusCode)`.
10. Any other `statusCode` (a 2xx reaching this function, or an unmapped 3xx/4xx not
    covered above, e.g. 400) → this is **not** a normal outcome for this function
    (2xx responses never reach `classifyError` — see §5's flow); a 3xx/4xx code with no
    explicit variant above (400, 405, 410, ...) maps to `ServerError(lastStatusCode:
    statusCode)` as the catch-all "something failed and none of our named categories
    fit" bucket, rather than silently succeeding or throwing an unclassified exception.
    **OQ-1**, flagged explicitly: is a bare 400 (bad-request-shaped, not validation)
    common enough on this backend's actual routes to deserve its own variant, or is
    folding it into `ServerError` acceptable? Not decided here — no BUILDS/AC text
    names 400 explicitly, and `Letflow.Api.Error.bad_request/1` is a real backend
    constructor (`lib/letflow/api/error.ex`), so a 400 is reachable in principle.
    MOBILE-DEV/REVIEWER should confirm the catch-all is acceptable or split it out.

### 1.3 Module-path matching rule (exact)

```
@spec bool _isModulePath(String path)
@spec String _extractModuleId(String path)
```

- Regex: `^/api/v1/modules/([^/]+)/` applied to `requestOptions.path` (the request's
  path component, matching `docs/mobile/architecture.md` §6's literal
  `/api/v1/modules/<id>/…` base path — note the trailing slash after `<id>` in the
  architecture doc, meaning a bare `/api/v1/modules/<id>` with no trailing segment is
  **not** a module-scoped call under this rule; every real module route always has at
  least one path segment after the id, e.g. `/api/v1/modules/exam/instances`).
- `_isModulePath(path)` is `path` matching that regex (case-sensitive — the backend's
  actual mount path is lowercase per `architecture.md` §6's confirmed
  `api_pipeline.ex:166` grep).
- `_extractModuleId(path)` returns capture group 1 (the `<id>` segment) — only called
  when `_isModulePath` is already `true`, so it never needs a null/failure branch of
  its own.
- Worked examples (from the acceptance criteria, exact): `404` on
  `/api/v1/modules/exam/x` → `_isModulePath` true, `_extractModuleId` returns
  `'exam'` → `ModuleNotAvailableError(moduleId: 'exam')`. `404` on, e.g.,
  `/api/v1/me/modules` or `/api/mobile/tenant-config` → `_isModulePath` false →
  `NotFoundError()`.
- `requestOptions.path` is used, not `requestOptions.uri` — Dio's `path` is the
  request path as given to `get`/`post`/etc (relative to `baseUrl`, no query string),
  which is what the regex above is written against; if a caller ever passes an
  absolute URL as `path`, `Uri.parse(path).path` extraction would be needed first —
  this design assumes (per every existing call site in `api_client.dart` today) that
  `path` is always a bare path string like `/api/v1/me/modules`, never a full URL.

### 1.4 `Retry-After` parsing (exact)

```
@spec int _parseRetryAfter(String? headerValue)
```

- `Letflow.Plugs.Admission`/`Letflow.Api.Response.rate_limited/2` (backend,
  `lib/letflow/api/response.ex`/`lib/letflow/plugs/admission.ex`) set `Retry-After` as
  a plain decimal integer string of seconds (e.g. `"1"`, `"7"`) — never an HTTP-date
  form. This function therefore only implements the delta-seconds branch of RFC 7231
  §7.1.3, not the HTTP-date branch: `int.tryParse(headerValue ?? '')`. If parsing
  fails (header absent, non-numeric, or negative) → default to `1` (matching
  `Letflow.Admission`'s own documented default retry-after-seconds config value,
  `lib/letflow/plugs/admission.ex`'s moduledoc, "default 1") rather than `0` or
  `null`, since a `BackpressureError` with a nonsensical zero/negative wait is worse
  for a caller than a conservative 1-second default.
- Acceptance criterion's exact case: `'Retry-After: 7'` → `BackpressureError(retryAfterSeconds: 7)`.

### 1.5 RFC 9457 field-error parsing (exact)

```
@spec List<ApiFieldError> _parseFieldErrors(Object? responseBody)
```

- Backend shape confirmed by reading `lib/letflow/api/error.ex`'s `serialise/1`: a 422
  problem-details JSON body has an `"errors"` top-level key holding a JSON array, each
  element shaped `{"field": String, "constraint": String, "message": String,
  "received": <any, nullable>}` (`Letflow.Api.Validation.FieldError`'s
  `@derive Jason.Encoder` struct, `lib/letflow/api/validation.ex`).
- `_parseFieldErrors` expects `responseBody` to be a `Map<String, dynamic>` whose
  `'errors'` key is a `List`; maps each element (expected `Map<String, dynamic>`) to
  an `ApiFieldError(field: e['field'] as String, constraint: e['constraint'] as
  String, message: e['message'] as String, received: e['received'])`.
- **Malformed-body fallback (explicit, not guessed):** if `responseBody` is not a map,
  has no `'errors'` key, or `'errors'` is not a list, `_parseFieldErrors` returns an
  empty `[]` rather than throwing — a `ValidationError(fieldErrors: [])` is still a
  correctly-classified `ApiError` (the caller knows it was a 422), just with no
  field-level detail to show; this matches `classifyError`'s overall contract that no
  raw exception ever escapes `lib/api/` (§5's AC).

---

## 2. The 401-refresh-then-retry state machine

### 2.1 What mediates "concurrent 401s share one in-flight refresh"

A single coordinator object, held as a private field on `ApiClient` (one instance per
`ApiClient`, matching the "single client" invariant this whole requirement hardens):

```
class _RefreshCoordinator {
  _RefreshCoordinator({
    required TenantTokenStore tokenStore,
    required ActiveRealmHolder activeRealm,
    required AppAuthAdapter appAuthAdapter,
  });

  /// Non-null while a refresh triggered by some 401 is in flight. Every
  /// caller that observes a 401 while this is non-null awaits THIS Future
  /// instead of starting a second refresh call.
  Future<bool>? _inFlightRefresh;

  /// Returns true iff the refresh succeeded (new tokens stored) and the
  /// caller should retry its original request; false iff refresh failed
  /// (tokens already cleared and login routing already triggered by the
  /// time this returns).
  Future<bool> refreshOnce();
}
```

- `refreshOnce()`'s body: if `_inFlightRefresh` is non-null, `return
  await _inFlightRefresh!` (join the existing attempt — this is what makes two
  concurrent 401s share one refresh: the second caller never calls the token-refresh
  endpoint itself). If null, it assigns `_inFlightRefresh = _doRefresh()` (the actual
  work, described in §2.2), awaits it, then — in a `finally` — resets
  `_inFlightRefresh = null` (so a **later**, temporally-separate 401 after this one
  resolves starts a fresh refresh attempt; the coordinator dedupes only truly
  concurrent 401s, not every 401 for the rest of the session, which is what "exactly
  one silent refresh via flutter_appauth's token refresh, then exactly one retry"
  means per-401-episode, not per-app-lifetime).
- This is a plain `Future`-caching pattern (no new package) — the standard Dart idiom
  for "coalesce concurrent async callers," consistent with this codebase's existing
  no-extra-dependency posture (REQ-422 §0's rule, restated here as still binding: no
  new pubspec dependency for this mechanism).

### 2.2 Exact sequence

Implemented as a Dio `onError` interceptor (added to `ApiClient.create`'s interceptor
chain, after the transport-policy and bearer-attach interceptors — order matters here
because the retry re-enters the same chain including the bearer-attach interceptor,
which must re-read the now-refreshed token):

1. A request is attempted (`_dio.fetch`/`get`/etc, via the existing interceptor chain
   — transport-policy, then bearer-attach, which attaches whatever token
   `TenantTokenStore` currently holds for the active realm).
2. Response arrives with `statusCode == 401` (via `validateStatus: (_) => true`, so
   this is an `onResponse`-observed status, not a thrown `DioException` — see §2.5 for
   why the retry logic is therefore implemented as response inspection in the request
   pipeline, not a Dio `onError` handler).
3. Client calls `await _refreshCoordinator.refreshOnce()`.
   - Inside `_doRefresh()`: reads the current `TokenSet` for
     `activeRealm.currentRealmUrl` from `tokenStore` (if no realm/tokens are present at
     all, treat as refresh failure immediately — go to step 5). Calls
     `appAuthAdapter`'s token-refresh method (exact method/type — **OQ-2**, see §2.6)
     with the stored `refreshToken`. On success: builds a new `TokenSet` from the
     response, `await tokenStore.store(realmUrl, newTokens)`, returns `true`. On any
     failure (thrown exception from the adapter, or a response carrying no usable
     access token): proceeds to step 5 and returns `false`.
4. **On refresh success (`true`):** the original request is retried **exactly once** —
   re-issued through the same `_dio` instance (so the bearer-attach interceptor
   re-reads the just-stored, now-fresh token). This retried request's response is
   returned to the original caller as if it were the first attempt's response (i.e.
   `classifyError`/success-mapping runs against the *retry's* outcome, not the
   original 401).
5. **On refresh failure (`false`):** `await tokenStore.delete(activeRealm.currentRealmUrl)`
   (REQ-422 §6.3's existing `TenantTokenStore.delete` — no new deletion path), then
   `activeRealm.currentRealmUrl = null`, then routes to login — see §2.4 for the exact
   routing mechanism. The original request's caller receives `UnauthorizedError()`
   (never a raw 401 `Response`, never a thrown `DioException`) — the login routing and
   the returned `ApiError` are two independent, both-required effects of the same
   failure, matching the acceptance criterion's two separate assertions (tokens
   deleted AND router at login route).
6. **A SECOND 401 on the retried request itself — terminal behavior, stated
   explicitly (this is the loop-prevention rule CODE-DESIGN-VALIDATOR checks for):**
   the retry in step 4 is marked, at the call-site level, as "already-retried" (a
   boolean carried on the request's `Options.extra`, e.g.
   `extra: {'_letflowRetriedAfter401': true}`, set only on the re-issued request, never
   on a fresh caller-initiated request). If **that** retried request's response is
   *also* a 401, the interceptor's 401-handling branch checks this flag first: when
   set, it does **not** call `refreshOnce()` again — it immediately returns
   `UnauthorizedError()` to the caller, with **no token deletion and no forced login
   routing** on this path specifically (deletion/routing already happened, or didn't
   need to, on whichever call actually ran `_doRefresh()`; a second 401 immediately
   after a *successful* refresh is a distinct, rarer case — the refreshed token itself
   being rejected — and this design's terminal rule is: surface `UnauthorizedError()`
   to the caller and stop, do not cascade into a second refresh attempt, ever, for
   this one request). This is a strict "retry budget of one 401-triggered refresh
   attempt per original request," matching the acceptance criterion's "exactly one
   refresh call and exactly one retry" wording taken as a hard ceiling, not merely a
   typical case.
7. A 401 on a request that already carries no `Authorization` header at all (e.g. an
   unauthenticated call, `extra['skipAuth'] == true`) skips the whole refresh/retry
   flow entirely and maps straight to `UnauthorizedError()` — there is no token to
   refresh usefully in that path (this mirrors `_bearerInterceptor`'s own existing
   `skipAuth` short-circuit, REQ-421 §7.2).

### 2.3 Concurrent-401 coalescing — exact test-observable behavior

Two concurrent calls (`Future.wait([client.get('/a'), client.get('/b')])` in a test)
that both receive 401 on their first attempt: both call
`_refreshCoordinator.refreshOnce()`; whichever calls first becomes the "owner" that
actually invokes `_doRefresh()` (one call to the fake AppAuth adapter's refresh
method, total); the second caller's `refreshOnce()` call returns the same `Future`
already in flight (`_inFlightRefresh`) and therefore performs **zero** additional
refresh calls. Both callers then each retry their own original request exactly once
(`/a` once, `/b` once) once the shared refresh resolves — the acceptance criterion's
"one refresh total" is about the refresh call count, not the retry count (each
caller still needs its own retry, since they were different requests to begin with).

### 2.4 Login routing mechanism

```
@spec typedef void Function() LoginRouter;
```

`ApiClient.create` gains a required `LoginRouter routeToLogin` parameter (a simple
callback, not a `go_router`-specific type, so `lib/api/` does not need to import the
app's routing package — matching the module-boundary spirit of `docs/mobile/architecture.md`
§6's core/module split, though `lib/api/` and `lib/bootstrap/`/the router setup are
both "core," not module-owned, so this is a plain dependency-injection seam, not a
`depends_on` boundary crossing). The production call site (wherever `ApiClient.create`
is constructed today, in the app's composition root / provider setup) supplies a
closure that calls `go_router`'s navigation to the login/tenant-entry route — **exact
route name/path is an implementation detail of the app's existing router setup, not
specified here** (this design does not have visibility into whether a named
`'/login'` route already exists — **OQ-3**, flagged for MOBILE-DEV to resolve against
the actual `go_router` configuration).

### 2.5 Why response-inspection, not `onError`

Because `BaseOptions(validateStatus: (_) => true)` (REQ-421 §7.1, unchanged by this
design) means a 401 arrives as a normal `Response` through `onResponse`/the method's
return value, never as a thrown `DioException` through `onError`. This design
therefore implements the refresh/retry/backoff logic as **wrapping logic inside each
public `ApiClient` method** (§5), inspecting the returned `Response.statusCode`
directly, rather than as a Dio interceptor's `onError` hook — an `onError` interceptor
would never fire for a 401/403/404/429/422/409/5xx under the current `validateStatus`
policy. (The transport-policy and bearer-attach interceptors remain `onRequest`
interceptors, unaffected by this distinction — they run regardless of the eventual
response status.)

---

## 3. 5xx backoff for GET only

### 3.1 Named constant

```
const int kMaxServerRetryAttempts = 3; // lib/api/api_client.dart (or api_error.dart)
```

Total attempts for a GET against a persistent 5xx is `kMaxServerRetryAttempts` — i.e.
the original attempt plus up to `kMaxServerRetryAttempts - 1` retries, OR
`kMaxServerRetryAttempts` counts the original attempt as attempt 1 (exact convention
below). **Exact convention, stated explicitly so the "exact number of requests sent"
acceptance criterion is unambiguous:** `kMaxServerRetryAttempts = 3` means the client
sends **at most 3 HTTP requests total** for one logical GET call before giving up and
surfacing `ServerError`. A GET that returns 503 on attempts 1 and 2 and 200 on attempt
3 succeeds (3 requests sent, matching the acceptance criterion's "503 twice then 200
succeeds"). A GET that returns 503 on every attempt sends exactly 3 requests total and
then surfaces `ServerError(lastStatusCode: 503)` (the acceptance criterion's "stops
after the maximum attempt count ... asserts the exact number of requests sent" —
that number is `3`, `kMaxServerRetryAttempts`'s value, not `kMaxServerRetryAttempts - 1`
or `+1`).

### 3.2 Backoff delay formula (deterministic, testable under a fake clock)

```
@spec Duration backoffDelayFor(int attemptNumber); // attemptNumber: 1-based index of
                                                     // the attempt that just failed
```

- Formula: `kBaseServerRetryDelay * pow(2, attemptNumber - 1)`, capped at
  `kMaxServerRetryDelay`.
- Constants: `const Duration kBaseServerRetryDelay = Duration(milliseconds: 200);`
  `const Duration kMaxServerRetryDelay = Duration(seconds: 5);`
- Concretely: after attempt 1 fails (503), wait `200ms * 2^0 = 200ms` before attempt 2;
  after attempt 2 fails, wait `200ms * 2^1 = 400ms` before attempt 3; a hypothetical
  attempt 3 failing would wait `800ms` before a 4th attempt, but
  `kMaxServerRetryAttempts = 3` means there is no 4th attempt — the delay formula is
  specified generally (for testability/documentation) even though only two delays
  (after attempts 1 and 2) are ever actually awaited under the current constant.
- "Increasing delays between attempts" (the acceptance criterion's exact wording) is
  satisfied by this formula's monotonically-increasing `2^(attemptNumber-1)` term.
- **Testability under a fake clock:** `ApiClient.create`/the retry loop accepts an
  injectable delay function: `Future<void> Function(Duration) delayFn = Future.delayed`
  (default parameter, matching this codebase's existing pattern of threading a real
  default while letting tests inject a fake — e.g. `transportPolicyFor`'s `isRelease`
  parameter, REQ-422 §4.1). A test supplies a fake `delayFn` that records the
  requested `Duration`s and resolves immediately (no real wall-clock wait), which is
  how the test asserts "increasing delays between attempts" without a real multi-second
  test run — this satisfies WF-02 Step 3's "no test depends on wall-clock time"
  acceptance criterion.

### 3.3 Retry eligibility rule (exact)

- Only `HttpGateway.get`/`getUnauthenticated` (GET) invoke this backoff loop.
- Any method added for POST/PUT/PATCH/DELETE (§5.2) performs **zero** automatic
  retries on a 5xx — a single attempt, and a 5xx response maps straight to
  `ServerError(lastStatusCode: statusCode)` with no delay/backoff logic invoked at
  all. This is the exact "no duplicate task completion" rule from the requirement
  text: idempotency is not inferred per-request; it is a hardcoded property of the
  HTTP method, matching REST's own idempotency guarantee (GET is defined idempotent;
  POST is not, and PUT/PATCH/DELETE are idempotent in principle but this requirement's
  text explicitly says "GET only," so this design does not extend auto-retry to
  PUT/DELETE even though they are technically idempotent — **OQ-4**, flagged: should a
  future requirement extend 5xx auto-retry to PUT/DELETE now that the mechanism
	exists? Not decided here; the requirement text says "GET only," so this design
  implements exactly that and no more).
- A 401 mid-retry-loop (a GET's 2nd attempt returns 401 instead of another 5xx) exits
  the backoff loop immediately and hands off to §2's refresh/retry flow instead — the
  two mechanisms are not nested (a request is never simultaneously "in a 401-retry"
  and "in a 5xx-backoff-retry"; whichever status is observed on a given attempt
  determines which single mechanism handles it next, and the 401 flow's own retry, if
  it succeeds, does not itself get wrapped in a fresh 5xx-backoff budget — a 5xx on
  the 401-flow's retry maps straight to `ServerError`, no further backoff attempts,
  since the 5xx-backoff budget in this design is scoped to the original GET's own
  attempt loop, not compounded with the 401 retry rule; **OQ-5**, flagged: is
  "no backoff after the 401-retry-then-5xx case" acceptable, or should the 401 retry's
  own 5xx also get the full 3-attempt GET backoff treatment? Not decided here — the
  acceptance criteria describe the two mechanisms independently and never describe
  their interaction, so this design picks the simpler, non-compounding behavior and
  flags it for REVIEWER confirmation).

---

## 4. Static single-client guard

### 4.1 What it scans, what it flags

New file: `apps/mobile/test/guards/single_api_client_guard_test.dart`, following the
exact three-part idiom of `token_storage_boundary_guard_test.dart` (§0, chosen over
`forbidden_dependencies_guard_test.dart`'s shape because this guard's job — per-file
source-text regex over an in-memory `{relativePath: content}` map — is structurally
identical to the token-storage guard's, not to the pubspec-dependency-name guard's).

```
class SingleApiClientViolation {
  SingleApiClientViolation(this.file, this.kind);
  final String file;
  final String kind;
}

@spec List<SingleApiClientViolation> checkSingleApiClientBoundary({
  required Map<String, String> libFiles, // {relativePath: content}, relativePath
                                          // starting 'lib/'
})
```

- Scans every file under `lib/` (matching `token_storage_boundary_guard_test.dart`'s
  `_readRealLibFiles` helper — this design reuses the same tree-walking approach, not
  a new one).
- Flags any file whose content matches one of three regexes, **except** files whose
  path starts with `lib/api/` (the sanctioned location):
  1. `import\s+['"]package:dio/[^'"]+['"]` — a `package:dio` import.
  2. `import\s+['"]package:http/[^'"]+['"]` — a `package:http` import (the
     `http` pub package, distinct from `dart:io`'s `HttpClient`).
  3. `\bHttpClient\s*\(` — a `dart:io` `HttpClient` construction (matched together
     with a same-file `import\s+['"]dart:io['"]` check, mirroring
     `token_storage_boundary_guard_test.dart`'s existing two-condition
     `dart:io`+`File(` pattern for its own violation kind 3 — a bare `dart:io` import
     alone is not itself a violation, since `dart:io` is used elsewhere for benign
     reasons, e.g. `Platform.isX`; the violation is specifically constructing an
     `HttpClient` from it).
- "Outside `lib/api/`" is exactly `!path.startsWith('lib/api/')` — string-prefix
  compare on the normalized forward-slash relative path, matching
  `token_storage_boundary_guard_test.dart`'s `sanctionedSecureStorageFile` compare
  idiom (there, an exact-file compare; here, a directory-prefix compare, since the
  sanctioned surface is a whole directory, `lib/api/`, not one file — `api_client.dart`
  is the one file that actually constructs `Dio`, but `api_error.dart` and any other
  file under `lib/api/` are equally allowed to reference Dio-adjacent types like
  `DioException` for classification purposes, per §1).
- One violation per (file, matched-pattern) pair — a file could in principle trigger
  more than one kind (e.g. both a `package:dio` and a `package:http` import), each
  reported separately, matching `checkTokenStorageBoundary`'s existing per-condition
  violation-emission style.

### 4.2 Self-test fixture

```
test('self-test: checker fires on a fixture under lib/features/ importing package:dio', () {
  final violations = checkSingleApiClientBoundary(
    libFiles: {
      'lib/features/exam/leaky_client.dart':
          "import 'package:dio/dio.dart';\n",
    },
  );
  expect(violations, hasLength(1));
  expect(violations.single.file, 'lib/features/exam/leaky_client.dart');
});
```

Modeled directly on `token_storage_boundary_guard_test.dart`'s own self-test shape
(lines 109–120 of that file) — same fixture-map argument, same single-violation
assertion style. Two further self-tests, for parity with the guard's other two
patterns: a `package:http` import under `lib/features/` fires; an `HttpClient(`
construction alongside a `dart:io` import under `lib/renderers/` fires. A fourth
self-test asserts the **negative** case: a fixture under `lib/api/leaky.dart`
importing `package:dio` fires **zero** violations (the sanctioned directory), mirroring
`token_storage_boundary_guard_test.dart`'s own "the sanctioned file itself fires zero
violations" self-test (lines 159–169).

### 4.3 Real-tree test

`test('real lib/ tree has zero single-api-client-boundary violations', ...)` — reads
the real `apps/mobile/lib/` tree via the same `_readRealLibFiles`-style helper and
asserts `checkSingleApiClientBoundary` returns `[]`. This is the guard's actual gate
against regressions; the self-test (§4.2) only proves the checker function itself is
capable of firing.

---

## 5. Function signatures — every new/changed public function in `lib/api/`

### 5.1 `ApiClient` — changed/added methods

```
class ApiClient implements HttpGateway {
  factory ApiClient.create({
    required TenantTokenStore tokenStore,
    required ActiveRealmHolder activeRealm,
    required AppAuthAdapter appAuthAdapter,   // NEW — for §2's refresh coordinator
    required LoginRouter routeToLogin,         // NEW — for §2.4
    String? baseUrl,
    TransportPolicy? transportPolicy,
    Future<void> Function(Duration) delayFn = Future.delayed, // NEW — for §3.2
    bool registerRedactingLog = true,          // NEW — see §6
  });

  @visibleForTesting
  factory ApiClient.forTesting(
    Dio dio, {
    required AppAuthAdapter appAuthAdapter,
    required LoginRouter routeToLogin,
    Future<void> Function(Duration) delayFn = Future.delayed,
  });

  /// Throws [ApiError] (never [DioException]/[SocketException]) on any
  /// non-2xx outcome, after this design's full refresh/retry/backoff
  /// handling has already run. Returns the decoded response on 2xx.
  @override
  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  });

  @override
  Future<Response<dynamic>> getUnauthenticated(
    String path, {
    Map<String, dynamic>? queryParameters,
  });

  /// NEW. No 5xx auto-retry (§3.3). Still subject to the 401 refresh/retry
  /// flow (§2) like every authenticated call. Throws [ApiError].
  Future<Response<dynamic>> post(String path, {Object? data});

  /// NEW, same shape as [post]. Not required by any BUILDS item's literal
  /// text but named here since HttpGateway currently has zero write methods
  /// and MOB-4's task/list renderers (a later requirement) will need one —
  /// OQ-7: should PUT/PATCH/DELETE be added now (symmetrical scaffolding)
  /// or left to whichever later requirement first needs them? Not decided
  /// here; only `post` is added since REQ-425's own acceptance criteria
  /// explicitly test a POST's non-retry behavior (criterion 3), which
  /// requires `post` to exist to be tested at all.
  Future<Response<dynamic>> post(String path, {Object? data});
}
```

- **Throwing convention, stated explicitly (AC "no DioException/SocketException
  escapes"):** every public method above is `async` and its body is wrapped so that
  any caught `DioException`/`SocketException`/other transport exception, and any
  non-2xx `Response.statusCode`, is passed through `classifyError` (§1.2) and
  **thrown as the resulting `ApiError`** (not returned as an `{:error, ApiError}`-style
  tuple — Dart idiom for a client boundary like this is a thrown typed exception, and
  `sealed class ApiError implements Exception` (§1.1) makes `try { ... } on ApiError
  catch (e) { switch (e) { ... } }` at call sites exhaustive-checkable). A 2xx response
  returns normally (the `Response<dynamic>`, unchanged shape from today — this design
  does not change what a successful call returns, only what an unsuccessful one
  produces).
- `HttpGateway`'s interface itself is **not** widened with a `post` method in this
  design (the abstract interface stays `get`/`getUnauthenticated`-only, since
  `HttpGateway` exists specifically as "the narrow HTTP surface this requirement's
  callers need," per its own doc comment, and no caller of `HttpGateway` — as opposed
  to `ApiClient` directly — needs `post` yet); `post` is added directly on the
  concrete `ApiClient` class. **OQ-8**, flagged: should `post` instead be added to
  `HttpGateway` for symmetry/testability-via-interface? Left to MOBILE-DEV/REVIEWER —
  no existing test seam requires it on the interface today.

### 5.2 Refresh coordinator — `AppAuthAdapter` extension

```
abstract class AppAuthAdapter {
  Future<AuthorizationTokenResponse?> authorizeAndExchangeCode(
    AuthorizationTokenRequest request,
  );

  /// NEW. Performs an OIDC refresh_token grant. Returns the new
  /// AuthorizationTokenResponse (or its token-refresh-response equivalent
  /// -- see OQ-2, exact flutter_appauth type/method TBD) on success. Throws
  /// on any failure (network, invalid_grant, expired refresh token, etc.)
  /// -- the caller (_RefreshCoordinator._doRefresh) catches every exception
  /// type uniformly and treats it as refresh failure, since this design
  /// does not need to distinguish *why* a refresh failed (network vs.
  /// revoked token both lead to the same "clear tokens, route to login"
  /// outcome).
  Future<AuthorizationTokenResponse?> refresh(TokenRequest request);
}
```

`RealAppAuthAdapter` (in `lib/auth/auth.dart`, unchanged file ownership — this
interface lives alongside the existing `AppAuthAdapter`/`authorizeAndExchangeCode`, not
duplicated in `lib/api/`) gains the corresponding `refresh` implementation, delegating
to `flutter_appauth`'s real refresh call. A test-only `FakeAppAuthAdapter`
(`apps/mobile/test/support/fake_app_auth_adapter.dart`, already exists per REQ-422 §2.4's
reference to it) gains a controllable `refresh` stub for the new tests this
requirement needs (§2.3's concurrency test, the refresh-failure test).

### 5.3 `ApiError` / mapping functions

Already fully specified in §1 (`classifyError`, `_isModulePath`, `_extractModuleId`,
`_parseRetryAfter`, `_parseFieldErrors`) and §3 (`backoffDelayFor`).

### 5.4 Guard entry point

Already fully specified in §4 (`checkSingleApiClientBoundary`).

---

## 6. Redacting log interceptor — registration decision (closing REQ-422's OQ-1)

REQ-422 §2.3 built `RedactingLogInterceptor` but deliberately left it unregistered,
naming this requirement (REQ-425/MOB-6) as the one with "an actual need to log
Dio traffic for debugging retry/backoff behavior" (REQ-422's own header note, restated
in §0 above). This design **registers** it: `ApiClient.create` gains a
`bool registerRedactingLog = true` parameter (§5.1); when `true`, `dio.interceptors.add(const RedactingLogInterceptor())`
is added last in the interceptor chain (after transport-policy, bearer-attach, and the
401/backoff wrapping logic — which is implemented as method-body logic per §2.5, not
as an interceptor, so there is no ordering interaction between it and
`RedactingLogInterceptor`). Tests that don't want log noise pass `registerRedactingLog:
false` (or simply don't assert on `debugPrint` output). This closes REQ-422's OQ-1
explicitly rather than leaving it open a second requirement in a row.

---

## 7. Cross-module dependencies

| Package/module | Role in this design |
|---|---|
| `dio` | `ApiClient`'s transport; `DioException`/`Response` inspected by `classifyError` |
| `flutter_appauth` | `AppAuthAdapter.refresh` (§5.2) — the actual refresh_token grant call |
| `lib/auth/auth.dart` (this app) | `TenantTokenStore`/`TokenSet`/`ActiveRealmHolder`/`AppAuthAdapter`/`RealAppAuthAdapter` — this design extends `AppAuthAdapter`'s interface there, not in `lib/api/` |
| `lib/api/api_client.dart` (this app) | Houses `ApiClient`, `_RefreshCoordinator`, the 401/backoff wrapping logic, `RedactingLogInterceptor` registration |
| `lib/api/api_error.dart` (this app, **new file**) | Houses `ApiError` and its 9 variants, `ApiFieldError`, `classifyError` and its helpers |
| `lib/api/transport_policy.dart` (this app) | Unchanged — interceptor ordering preserved (§2.2) |
| `lib/api/api.dart` (this app) | Gains `export 'api_error.dart';` |
| `test/guards/single_api_client_guard_test.dart` (this app, **new file**) | §4 |
| `test/support/fake_app_auth_adapter.dart` (this app) | Gains a controllable `refresh` stub |
| `Letflow.Api.Error`/`Letflow.Api.Response` (backend, `lib/letflow/api/`) | Unchanged — this design only reads their already-shipped wire shapes (RFC 9457 `errors` array, `Retry-After` header) to write the mobile-side parser; no backend change |
| `Letflow.Plugs.Admission`/`Letflow.Plugs.PublicReadRateLimit` (backend) | Unchanged — source of the 429 responses §1.4 parses |

No new pubspec dependency — the refresh coordinator, backoff loop, and `ApiError` type
are all pure-Dart/`dio`-only constructs.

---

## 8. Invariants

- **Single Dio construction site preserved.** This design adds no second `Dio(...)`
  call — `ApiClient.create` remains the only one (REQ-421 §7.1's invariant, AC8,
  unaffected by this requirement).
- **No raw transport exception ever escapes `lib/api/`.** Every public `ApiClient`
  method's failure surface is `ApiError`, exclusively (§5.1).
- **Exactly one refresh-then-retry cycle per original request, ever, even under a
  second 401 on the retried request itself (§2.2 step 6).** No unbounded/looping
  refresh is possible under any response sequence.
- **Concurrent 401s never trigger more than one refresh call (§2.1/§2.3).**
- **A GET's 5xx backoff never exceeds `kMaxServerRetryAttempts` total HTTP requests
  (§3.1), and no write method (`post`, and any future PUT/PATCH/DELETE) is ever
  auto-retried on 5xx (§3.3).**
- **A 404 on a `/api/v1/modules/<id>/…` path is always distinguished from every other
  404 (§1.3)** — this is the one mapping rule with a real security/UX consequence
  named explicitly in `docs/mobile/architecture.md` §6 (module absence must not read
  as generic not-found).
- **Refresh failure always both clears the tenant's stored tokens AND routes to login
  — never one without the other (§2.2 step 5).**
- **No second `flutter_secure_storage`/token-storage path is introduced** — the
  refresh coordinator calls the existing `TenantTokenStore` only (§2.2), preserving
  `token_storage_boundary_guard_test.dart`'s existing invariant unchanged.
- **The single-client guard (§4) never flags any file under `lib/api/` itself** —
  proven by its own negative self-test case (§4.2).

---

## 9. Acceptance-criteria resolution map

| # | Acceptance criterion (paraphrased) | Resolved by |
|---|---|---|
| 1 | 401-once-then-200 → exactly one refresh + one retry; two concurrent 401s → one refresh total | §2.1 (`_RefreshCoordinator`), §2.2 (sequence), §2.3 (concurrency behavior) |
| 2 | Refresh failure → tokens deleted from secure store + router at login route | §2.2 step 5, §2.4 (routing mechanism) |
| 3 | GET: 503×2 then 200 succeeds with increasing delays (fake clock); GET: 503 always → stops at named max-attempts constant, exact request count asserted, surfaces `ServerError`; POST: 503 not retried | §3.1 (`kMaxServerRetryAttempts`), §3.2 (formula + injectable `delayFn`), §3.3 (POST non-retry rule) |
| 4 | Per-`ApiError`-variant mapping test, including 404-on-module-path vs. 404-elsewhere, and 429+`Retry-After: 7` → `backpressure(7)` | §1.1 (variant list), §1.2 (mapping rule), §1.3 (module-path regex, worked examples), §1.4 (`Retry-After` parsing, exact case) |
| 5 | No `DioException`/`SocketException` escapes `lib/api/`; public API returns/throws only `ApiError` | §5.1 (throwing convention on every public method) |
| 6 | Single-client guard fails on a `lib/features/` fixture importing `package:dio`; passes on the real tree | §4.1 (checker + patterns), §4.2 (self-test fixture), §4.3 (real-tree test) |
| 7 | `flutter analyze && flutter test` pass, real output quoted; SECURITY-REVIEWER signs off | Standard gate (Step 2b-mobile procedure) + this design's SECURITY-REVIEWER-required header (§ preamble) |

---

## 10. Open questions

- **OQ-1 (§1.2, mapping fallback).** A bare 400 (and any other unmapped 3xx/4xx) folds
  into `ServerError` as a catch-all. Is that acceptable, or does it deserve its own
  `ApiError` variant (e.g. `BadRequestError`)? Not decided here — no BUILDS/AC text
  names 400 explicitly.
- **OQ-2 (§5.2, the biggest open item).** The exact `flutter_appauth` (pinned
  `^12.1.0`, per `lib/auth/auth.dart`'s existing package-version notes) API shape for
  a **refresh** call is not established anywhere in the existing codebase — REQ-421/422
  only ever call `authorizeAndExchangeCode` (the initial code exchange), never a
  refresh grant. This design states the *coordinator's* contract
  (`AppAuthAdapter.refresh(TokenRequest) -> Future<AuthorizationTokenResponse?>`) but
  does **not** assert that `flutter_appauth: ^12.1.0` actually exposes a method with
  that exact name/signature — MOBILE-DEV must check the pinned package's real API
  (likely `FlutterAppAuth().token(TokenRequest(...))` with `grantType:
  'refresh_token'`, per that package's general shape in other versions, but this is
  not verified against the actual pinned version here, per this design's "don't invent
  a fictitious method name" instruction) and adjust `RealAppAuthAdapter.refresh`'s
  exact call accordingly; the `_RefreshCoordinator`/`AppAuthAdapter` interface shapes
  in §2.1/§5.2 are stable regardless of that adjustment (they only depend on "some
  method takes stored refresh-token material and returns new token material or
  throws"), so this is an implementation-detail gap, not a design-shape gap — but
  it is exactly the kind of unstated assumption this design must flag rather than
  guess at.
- **OQ-3 (§2.4).** The exact login/tenant-entry route name/path for `LoginRouter`'s
  production closure is not specified — depends on the app's actual `go_router`
  configuration, which this design did not need to read in full to specify the
  refresh/retry mechanism itself.
- **OQ-4 (§3.3).** Should 5xx auto-retry ever extend to PUT/DELETE (technically
  idempotent) in a later requirement, given the mechanism will already exist? Not
  decided — this design implements "GET only" per the requirement text's literal
  wording.
- **OQ-5 (§3.3).** Whether a 5xx observed on the 401-flow's own retry (as opposed to
  the original request) should get its own fresh backoff budget, or fail immediately
  as this design specifies (no compounding). Flagged for REVIEWER since the
  acceptance criteria describe the two mechanisms independently and never their
  interaction.
- **OQ-6 (§0).** Whether the Dart guard suite needs a `forbidlist.ts`-style shared
  `GuardPattern` registry once a third guard exists (this requirement adds the third
  guard file, `single_api_client_guard_test.dart`, alongside the two from REQ-419/422)
  — this design keeps the current per-file idiom since no consuming code today would
  benefit from a shared registry, but flags the question for when a fourth guard is
  added.
- **OQ-7 (§5.1).** Whether PUT/PATCH/DELETE should be added to `ApiClient` now
  (symmetrical scaffolding) or left to whichever later requirement first needs one.
  This design adds only `post`, since it is the only write method this requirement's
  own acceptance criteria (criterion 3's POST-not-retried case) require to exist.
- **OQ-8 (§5.1).** Whether `post` belongs on the `HttpGateway` abstract interface
  (for test-seam symmetry) or only on the concrete `ApiClient` class, as this design
  currently specifies.
