# REQ-430 (MOB-8) — v1 scope boundary guard + S9 close-out

Design only — no implementation code. Signatures/@spec-shapes, exact doc-edit
content, and open questions. Builds on the established guard pattern in
`apps/mobile/test/guards/forbidden_dependencies_guard_test.dart` (pubspec
scan) and `apps/mobile/test/guards/token_storage_boundary_guard_test.dart`
(lib/-tree scan).

---

## 1. Static guard: `apps/mobile/test/guards/v1_scope_boundary_guard_test.dart`

New file, same shape as the two precedents: pure-function checkers, a
real-tree test per checker, self-test fixtures per checker. Picked up
automatically by `flutter test` (it globs `test/**/*_test.dart`) — no new
runner wiring needed, exactly as every sibling guard file already works.

### 1.1 Checker A — forbidden push/background-task dependency

Scans the same two sources as `forbidden_dependencies_guard_test.dart`:
`pubspec.yaml`'s `dependencies:`/`dev_dependencies:` blocks and
`pubspec.lock`'s `packages:` block, via functions equivalent to the existing
`extractPubspecYamlDependencyNames` / `extractPubspecLockPackageNames` (this
design reuses those two functions rather than duplicating their logic —
either by importing them from the forbidden-dependencies guard file, or, if
Dart test files can't cheaply share private helpers across files without a
refactor, by MOBILE-DEV copying the same two functions verbatim into the new
file under the same names, matching the established duplication precedent
already present between guard files that each define their own `_relativeTo`
helper. Which approach to take is left to MOBILE-DEV — see Open Question
OQ-1).

**Forbidden list, with reasoning for each inclusion/exclusion:**

```dart
/// Package names forbidden by exact (case-insensitive) match: push/
/// messaging SDKs and background-task schedulers. MOB-8 forbids "push-based
/// cache invalidation" and implicitly anything that would let the device
/// receive a background wake/message or run code while not foregrounded,
/// since that is the on-ramp to both push invalidation and a write-queue
/// flush scheduler.
const List<String> _forbiddenExact = [
  // Push / messaging
  'firebase_messaging',       // the canonical "push" SDK named in MOB-8's text
  'onesignal_flutter',        // a common third-party push SDK -- "or equivalent"
  'flutter_fcm',
  // Background task / scheduling
  'workmanager',              // named explicitly in REQ-430's task text
  'android_alarm_manager_plus',
  'background_fetch',
  'flutter_background_service',
];

/// Substrings forbidden anywhere in a package name (case-insensitive),
/// catching adjacent/platform-interface packages the same way the
/// forbidden-dependencies guard already does for 'lua'/'wasm'/'cel'.
const List<String> _forbiddenSubstrings = [
  'workmanager',        // catches workmanager_android, workmanager_platform_interface, etc.
  'alarm_manager',
  'background_fetch',
  'onesignal',
  'firebase_messaging',
];
```

**Deliberately NOT forbidden, with reasoning (so MOBILE-DEV does not
second-guess this later):**

- `firebase_core` — a bare Firebase initializer package with no push
  behavior of its own. Forbidding it would also block an unrelated future
  use (e.g. Crashlytics) that has nothing to do with MOB-8's scope. Only
  `firebase_messaging` (the messaging *module*) is forbidden.
- `flutter_local_notifications` — this schedules/display *local*
  notifications already decided on-device; it has no server-push channel
  and cannot deliver a cache-invalidation signal. It is a UI-affordance
  package, not a push-invalidation on-ramp. Not forbidden.
- `connectivity_plus` / similar network-state-observer packages — reading
  network state is not a write queue or push channel. Not forbidden.

**Function signatures** (reusing the existing checker's shape, extended
with the new forbidden list — this can literally be the *same*
`checkForbiddenDependencies` function from the precedent file with a second,
disjoint forbidden-list pair, OR a new sibling function; MOBILE-DEV's
choice, see OQ-1):

```
checkV1ScopeDependencies(List<String> packageNames)
  -> List<ScopeDependencyViolation>

class ScopeDependencyViolation {
  final String packageName;
  final String reason;   // e.g. "push/messaging package forbidden by MOB-8"
                          //   or "background-task package forbidden by MOB-8"
}
```

### 1.2 Checker B — persisted outgoing-request shape (write-queue detector)

This is a **static, textual heuristic over `.dart` source**, not an AST or
type-level check — same honesty standard as
`token_storage_boundary_guard_test.dart`'s own doc comment, which states its
own blind spots plainly. State the contract precisely:

**What it detects (the "shape" of a write-queue entry):** a sembast-style
persistence call —

```
<StoreRefExpr>.record(<anyExpr>).put(<dbExpr>, <valueExpr>)
```

— where `<valueExpr>`, read as *source text* (not evaluated), is a map/object
literal or a `.toStoredJson()`/`.toJson()`-style call whose **literal key set,
found within the same statement or the enclosing `{ ... }` block the `.put(`
call sits in**, contains **at least two of** the following key-name tokens
(as string-literal map keys, e.g. `'method':`, `"url":`, or a positional
named-constructor-arg spelled `method:`/`url:`/`body:`/`request:`):

- `method` (or `httpMethod`)
- `url` (or `uri`, `path` when co-occurring with `method`)
- `body` (or `payload`)
- `request` (a single field literally named `request` already counts as 2
  of its own, since it names the whole outgoing-request shape directly)

**Precise detection heuristic (regex-based, for MOBILE-DEV to implement
without further judgement calls):**

1. Find every call-site in a `.dart` file matching
   `RegExp(r'\.record\([^)]*\)\.put\(')` (mirrors `StoreRef<...>.record(...).put(...)`
   used by both existing sembast repositories, `sembast_cache_repository.dart`
   and `sembast_pinned_form_cache_repository.dart`).
2. Take a bounded window of source text around that call-site: the smallest
   enclosing `{ ... }` block (or, if that is impractical to compute with
   regex alone, a fixed window of the preceding 400 characters plus the
   statement itself — MOBILE-DEV's implementation choice, document whichever
   is chosen in the file's doc comment).
3. Within that window, count how many of the key-name tokens above appear
   as a quoted-string map key (`'method'\s*:` / `"method"\s*:`, etc.) or as
   a named-argument token (`method:` not preceded by `.` — to avoid matching
   unrelated member accesses).
4. If **2 or more distinct** key-name tokens from the list are found in the
   window, flag a violation: `OutgoingRequestPersistenceViolation(file, lineOfPutCall, matchedKeys)`.

**Function signature:**

```
checkNoPersistedOutgoingRequests({required Map<String, String> libFiles})
  -> List<OutgoingRequestPersistenceViolation>

class OutgoingRequestPersistenceViolation {
  final String file;
  final int approxLine;
  final List<String> matchedKeys;  // e.g. ['method', 'url']
}
```

Wired into `main()` the same way as the precedent: a real-tree test reading
every `.dart` file under `lib/` into `Map<String,String>` (reuse
`_readRealLibFiles`/`_relativeTo` helpers from
`token_storage_boundary_guard_test.dart`, duplicated into the new file per
the same precedent already set between existing guard files) and asserting
`checkNoPersistedOutgoingRequests(libFiles: files)` is empty.

**Explicit, documented false-negative boundary (required doc comment,
matching the honesty standard of the precedent files):**

- Does **not** catch a write-queue built from a *renamed* field (e.g.
  `verb`/`endpoint`/`data` instead of `method`/`url`/`body`) — a determined
  rewrite can rename around the heuristic. This is a lint-level static gate,
  not a type system; MOB-8's real backstop is architectural (no conflict
  model exists server-side to resolve a replayed write), not this guard.
- Does **not** catch a write-queue assembled across multiple statements
  (e.g. building a `Map` field-by-field across several lines outside the
  bounded window, then passing a single pre-built variable into `.put()`)
  if the key literals fall outside the scanned window.
- Does **not** evaluate semantics — a map legitimately named `method`/`url`
  for an unrelated reason (e.g. caching a *definition's* own `method` field,
  if the server's definition JSON ever used that name) would be a **false
  positive**. None of the current definition/cache schemas use these key
  names (verified: `sembast_cache_repository.dart` and
  `sembast_pinned_form_cache_repository.dart`'s stored shapes are definition/
  pinned-form envelopes, not request envelopes), so this is not expected to
  fire today, but MOBILE-DEV should re-check this assumption if a future
  definition schema legitimately uses `method`/`url`/`body` as field names.
- Only scans `.dart` files under `apps/mobile/lib/` (not `test/`, not
  generated code) — matching the existing guards' scope.

### 1.3 Required self-test fixtures (AC1)

All four as literal in-memory fixtures, mirroring the precedent files'
`self-test:` named tests:

(a) **pubspec with `firebase_messaging`** → `checkV1ScopeDependencies` on
    `extractPubspecYamlDependencyNames('dependencies:\n  firebase_messaging: ^15.0.0\n')`
    returns exactly one violation naming `firebase_messaging`.

(b) **pubspec with `workmanager`** → same shape, fixture
    `'dependencies:\n  workmanager: ^0.5.2\n'`, one violation naming
    `workmanager`.

(c) **Dart file writing a request method/url/body map to a store** →
    `checkNoPersistedOutgoingRequests` on a fixture such as:
    ```dart
    // fixture content (as a string, not a real file):
    await _store.record(id).put(db, {
      'method': 'POST',
      'url': '/api/v1/instances/42/submit',
      'body': formValues,
    });
    ```
    must return exactly one violation.

(d) **the real tree** → both checkers return `isEmpty` against the actual
    `pubspec.yaml`/`pubspec.lock` and actual `apps/mobile/lib/` tree.

Each of (a)/(b)/(c) is a `test('self-test: ...', () { ... })` block; (d) is
the lead `test('real ... has zero violations', ...)` block, matching the
precedent files' ordering convention (real-tree test first, self-tests
after).

### 1.4 File path and wiring

- New file: `apps/mobile/test/guards/v1_scope_boundary_guard_test.dart`.
- No `pubspec.yaml` change needed for the guard itself (uses only `dart:io`
  and `flutter_test`, both already available to every other guard file).
- Picked up by the existing `flutter test` invocation automatically — same
  mechanism as all 7 existing files under `apps/mobile/test/guards/`.

---

## 2. `docs/mobile/architecture.md` §4 — exact replacement text

Replace the current §4 body (from `## 4. v1 boundary` through the end of the
"The distinction is not arbitrary..." paragraph, i.e. lines 92–120 of the
file as read for this design) with the following. This keeps the existing
D1a clarification paragraph (still accurate — verified against
`docs/migration/decisions/0020-frontend-architecture.md` D1a and MOB-4's own
"What evaluates `computed`" section, both unchanged by REQ-430) and adds the
scope table plus delivering-REQ column:

```markdown
## 4. v1 boundary

v1 is **online-first with a read-through definition cache.**

### Scope table (added 2026-10-01, `REQ-430`)

| Requirement | Scope | Delivered by |
|---|---|---|
| `MOB-1` — generic definition-interpreter shell | done | `REQ-419` (scaffold), `REQ-294` (Dart `Letflow.Engine.Expr` evaluator) |
| `MOB-2` — tenant bootstrap | done | `REQ-418` (OIDC `client_id` disclosure), `REQ-421` (bootstrap sequence), `REQ-282` (per-tenant branding) |
| `MOB-3` — offline definition cache, delta sync, version pinning | done | `REQ-423` (cache + delta sync), `REQ-424` (pinned form version resolution) |
| `MOB-4` — generic renderers, six mandatory states | done | `REQ-426` (state framework + list renderer), `REQ-427` (form renderer), `REQ-428` (task + process-instance renderer) |
| `MOB-5` — on-device security | done | `REQ-422` |
| `MOB-6` — API client | done | `REQ-425` |
| `MOB-7` — i18n | done | `REQ-429` |
| `MOB-8` — v1 scope boundary (this section's own gate) | done | `REQ-430` |

`REQ-385` confirmed no code change was needed for a related backend question
under `REQ-126`'s frozen-at-creation architecture — noted here as context,
not as a delivering REQ for any MOB-N row. `REQ-417` (`MOBILE-DEV` role
reactivation) and `REQ-420` (CI mobile gate) are infrastructure/process
requirements, not MOB-N deliverables, and are intentionally absent from the
table above.

### Explicitly out of v1 (deferred, not forgotten)

- **Offline writes** — no optimistic write queue. This is the important one:
  offline writes require a conflict model the platform does not have and
  does not currently need. **Guarded statically by `REQ-430`'s**
  `apps/mobile/test/guards/v1_scope_boundary_guard_test.dart`, which fails
  the build if a `.dart` file under `lib/` persists a store write shaped
  like an outgoing HTTP request (method/url/body).
- **Push-based cache invalidation.** **Guarded statically by the same
  `REQ-430` guard**, which fails the build on a push/messaging dependency
  (`firebase_messaging` or equivalent) in `pubspec.yaml`/`pubspec.lock`.
- **An on-device form builder.** No dependency or code-shape signature
  exists to statically guard against a feature with no implementation
  surface to scan; this exclusion is enforced by requirement scope
  (MOB-1..MOB-8 define the entire build surface; a form builder is not
  among them) rather than a static check.

Keeping these out is what makes the tier *additive*. Each of them, added,
would pull a new subsystem into the backend rather than a new screen into
the app.

**Offline *form population* is in; offline *submission* is out
(2026-09-08).** The line above is easy to misread as "nothing works offline
but reading," so state it precisely. Under
[`../migration/decisions/0020-frontend-architecture.md`](../migration/decisions/0020-frontend-architecture.md)
clause **D1a**, a cached form is **fillable** with no server reachable: its
`computed` fields recompute, its `visible_when` conditions resolve, and its
cross-field validation runs, all evaluated on-device in the
`Letflow.Engine.Expr` grammar (MOB-4). What stays out of v1 is the **write
queue** — the user still cannot submit until connectivity returns.

The distinction is not arbitrary. Evaluating a pure expression against
local data needs no conflict model; queueing a write does. D1a supplies the
first and deliberately not the second, so this section's exclusion of
offline writes stands unchanged.
```

This table is verified accurate against this design session's own greps of
`docs/requirements.yaml` (REQ-417..REQ-430 all present, titles consistent
with the mapping ORCH supplied) — no amendment to the D1a paragraph is
needed; it was re-read in full and remains an accurate statement of what
D1a actually changed.

---

## 3. `docs/migration/stage-9-mobile.md` — new section content

Append a new section after the existing "REVIEWER sign-off" section (the
current last section, ending "...the stage is no longer docs-only."). Exact
content:

```markdown
## Phase-gate evidence and deferrals (`REQ-430`, 2026-10-01)

Per [`../mobile/build-order.md`](../mobile/build-order.md)'s "Phasing"
table, each of the three post-M-0 phase gates is demonstrated by real
`flutter test` coverage, cited here by file:

| Phase | Gate | Demonstrated by |
|---|---|---|
| **M-1** | A build authenticates two distinct tenants and stores tokens securely | `apps/mobile/test/auth/authenticate_with_tenant_test.dart`, `apps/mobile/test/auth/tenant_token_store_test.dart`, `apps/mobile/test/auth/audience_scoping_test.dart`, `apps/mobile/test/bootstrap/bootstrap_sequence_test.dart`, `apps/mobile/test/bootstrap/tenant_switch_test.dart`, `apps/mobile/test/guards/token_storage_boundary_guard_test.dart` |
| **M-2** | Airplane-mode launch renders cached definitions; pinned versions never substitute | `apps/mobile/test/definitions/definition_sync_service_test.dart`, `apps/mobile/test/definitions/sembast_cache_repository_test.dart`, `apps/mobile/test/definitions/active_definition_cache_holder_test.dart`, `apps/mobile/test/definitions/pinned_form_resolver_test.dart`, `apps/mobile/test/definitions/sembast_pinned_form_cache_repository_test.dart`, `apps/mobile/test/renderers/task/task_pinned_version_test.dart` |
| **M-3** | All six renderer states demonstrable, including a forced `429` | `apps/mobile/test/renderers/renderer_state_view_ac1_test.dart` (loading/fetch-failure/permission-denied/stale-version/validation-error), `apps/mobile/test/renderers/renderer_state_view_ac2_backpressure_countdown_test.dart` (forced 429), `apps/mobile/test/renderers/form/form_expression_unevaluable_test.dart`, `apps/mobile/test/renderers/task/task_claim_conflict_test.dart`, `apps/mobile/test/guards/v1_scope_boundary_guard_test.dart` (the MOB-8 gate itself) |

### Deferred, with reasons

| Item | Reason deferred |
|---|---|
| iOS build and iOS-runtime checks (`flutter build ios`, device/simulator verification) | This host is Windows; no iOS toolchain (Xcode) is available to build or run an iOS target. All iOS-specific configuration (`ios/Runner/Info.plist` ATS settings, etc.) is reviewed statically (`apps/mobile/test/guards/ios_ats_guard_test.dart`) but never built or run. |
| Interactive OIDC login against a real Keycloak realm (an actual browser-based Authorization-Code+PKCE round trip, not the `fake_app_auth_adapter.dart`-substituted flow `flutter test` exercises) | Requires a live instance and a real human-equivalent browser interaction; out of reach for `flutter test`'s unit/widget harness. Exercised instead by `UAT-RUNNER` against a real running instance, matching the project's stated division between `TEST-RUNNER`'s `flutter test` coverage and `UAT-RUNNER`'s scenario-based live checks. |

`flutter analyze`, `flutter test`, and `flutter build apk --debug` are all
run and their real output recorded by `TEST-RUNNER`/`MOBILE-DEV` at
implementation time (REQ-430 AC5); this section records *which* gates map
to *which* test files, not the run output itself.

Stage REVIEWER sign-off and the stage/requirement status flips remain with
`REVIEWER` and `DOC-UPDATER`, per this stage file's existing convention —
not duplicated here.
```

The test-file lists above were taken from the actual
`apps/mobile/test/` directory listing (`find apps/mobile/test -type f`,
run during this design session) — every filename cited exists in the tree
today. MOBILE-DEV should re-verify the list is still current at
implementation time in case files were renamed/added between this design
and the build step, and should add `v1_scope_boundary_guard_test.dart`'s
actual self-test names once written if finer citation is wanted (the file
itself did not exist yet at design time).

---

## 4. Open questions

- **OQ-1 (code-sharing mechanism for Checker A's pubspec-parsing
  helpers).** `extractPubspecYamlDependencyNames` /
  `extractPubspecLockPackageNames` already exist, verbatim, in
  `forbidden_dependencies_guard_test.dart`. This design does not resolve
  whether MOBILE-DEV should (a) import and reuse those two top-level
  functions from the new guard file, or (b) duplicate them into the new
  file (matching the precedent that `_relativeTo`/`_readRealLibFiles`-style
  helpers are already duplicated, not shared, between
  `token_storage_boundary_guard_test.dart` and other tree-scanning guards).
  Both are valid under the existing pattern; left to MOBILE-DEV's
  implementation-time judgement rather than decided here, since it has no
  behavioral effect on any acceptance criterion.
- **OQ-2 (Checker B's "enclosing block" window computation).** The design
  states two options — a true smallest-enclosing-`{...}`-block scan, or a
  fixed-size character window before the `.put(` call-site — and leaves the
  choice to MOBILE-DEV, documented in the shipped file's own doc comment
  (matching this project's standard of each guard stating its own
  heuristic precisely, in-file). A true block-scan is more precise but
  harder to implement correctly with regex alone over arbitrarily nested
  braces (string literals/comments containing `{`/`}` can desync a naive
  counter); a fixed window is simpler but has a sharper, better-understood
  false-negative edge. Neither choice affects AC1's three required-fail
  fixtures, since fixture (c) places the forbidden keys immediately inside
  the `.put(` call's own map literal.
- **OQ-3 (forbidden-package list completeness).** The push/background-task
  package lists in §1.1 are reasoned but not exhaustive — the push/
  background-task SDK ecosystem is larger than the six packages named
  (e.g. OneSignal has several platform-interface sub-packages, and other
  background schedulers exist). The substring list is deliberately broader
  than the exact list to catch *named-after* variants, but a push SDK with
  an unrelated-sounding package name would not be caught by either list.
  This is accepted as the same class of limitation the existing
  `forbidden_dependencies_guard_test.dart` already lives with for its own
  list (script-runtime/webview packages), not a new gap introduced by this
  design.
- **OQ-4 (whether `path`/`path_provider` in the forbidden-substring space
  could ever collide).** None of the forbidden substrings in §1.1 overlap
  with any package currently in `pubspec.yaml` (`dio`, `flutter_appauth`,
  `flutter_riverpod`, `flutter_secure_storage`, `go_router`, `intl`,
  `path`, `path_provider`, `sembast`) — verified by inspection. No action
  needed, flagged only so a future dependency addition is checked against
  both forbidden lists before being added.
