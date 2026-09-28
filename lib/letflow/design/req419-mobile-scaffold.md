# Design — REQ-419: MOB-1 scaffold (`apps/mobile/`)

Status: design only. No implementation code below — signatures, file paths,
formats, and detection logic descriptions only. Implements build-order M1
(`docs/mobile/build-order.md`), placement/stack per `docs/mobile/architecture.md`
§2, stack settled by `docs/migration/decisions/0012-mobile-tier-stack.md` (not
re-decided here). Creates `apps/mobile/`; nothing here authenticates or fetches
(REQ-421 / MOB-2).

## 0. Redirect scheme / app identity (confirms REQ-418 linkage)

`priv/keycloak/realms/bpm-default.json`'s `letflow-mobile` client (added by
REQ-418) registers `redirectUris: ["com.bizdala.letflow:/oauth2redirect"]`
exactly (`docs/requirements.yaml` REQ-418 description, PART 1). Android
`applicationId` and iOS bundle id MUST therefore both be `com.bizdala.letflow`
— the reverse-DNS prefix of that custom scheme. This is what `flutter create
--org com.bizdala --project-name letflow` produces by Flutter's own
convention (org + project name → `com.bizdala.letflow`), so no extra rename
step is needed after scaffolding, only verification (AC3).

## 1. `flutter create` invocation and platform identifiers

```
flutter create --org com.bizdala --project-name letflow \
  --platforms android,ios apps/mobile
```

Run from the repo root so the project lands at `apps/mobile/` (peer to `web/`,
per architecture.md §2's tree). Resulting identifiers:

- Android `applicationId`: `com.bizdala.letflow`
- iOS bundle id (`PRODUCT_BUNDLE_IDENTIFIER`): `com.bizdala.letflow`

**Android minSdk 26** — location: `apps/mobile/android/app/build.gradle.kts`
(current `flutter create` emits Kotlin DSL by default; if the installed
Flutter version instead emits Groovy `build.gradle`, the same setting lives at
the equivalent `android { defaultConfig { minSdk = 26 } }` block, key name
`minSdk` in Kotlin DSL / `minSdkVersion` in Groovy). Do not lower
`flutter.minSdkVersion`'s default from the template; set the literal `26`.

**iOS deployment target 15.0** — two locations, both must agree:
- `apps/mobile/ios/Podfile`: `platform :ios, '15.0'` (template default is
  lower; must be edited).
- `apps/mobile/ios/Runner.xcodeproj/project.pbxproj`:
  `IPHONEOS_DEPLOYMENT_TARGET = 15.0;` in each of the three build
  configurations (`Debug`, `Release`, `Profile`) under both the `Runner`
  target and the project-level `Runner.xcodeproj` settings — `flutter create`
  emits one value per configuration block; all instances must read `15.0`.

**iOS build itself is DEFERRED.** The build host is Windows; Xcode does not
run on Windows, so `pod install` / `flutter build ios` cannot be executed or
verified in this environment. The files above are generated and their
settings edited to the correct values, but no iOS build output is produced or
claimed. This is recorded as an explicit open constraint (see §9), not
silently dropped — matches AC7's requirement that the report state this.

## 2. `pubspec.yaml` shape

```yaml
environment:
  sdk: ">=3.11.0 <3.12.0"     # Dart 3.11 line
  flutter: "3.41.7"           # exact constraint; REQ-420's CI reads this line

dependencies:
  flutter:
    sdk: flutter
  go_router: <version resolved by `flutter pub get` at build time>
  flutter_riverpod: <version resolved by `flutter pub get` at build time>
  dio: <version resolved by `flutter pub get` at build time>
  flutter_appauth: <version resolved by `flutter pub get` at build time>
  flutter_secure_storage: <version resolved by `flutter pub get` at build time>
  intl: <version resolved by `flutter pub get` at build time>

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: <version>
```

No other runtime dependency. `dev_dependencies` may add ordinary test-only
packages (e.g. `flutter_lints`) but MUST NOT add anything that itself
resembles a forbidden runtime capability (no webview/script/CEL package even
as a dev dependency) — the forbidden-dependency guard (§6b) scans the whole
`pubspec.yaml`/`pubspec.lock`, not just the `dependencies:` block, so this is
enforced, not just stated. **Open question:** whether the three static guard
tests need any additional dev-only package (e.g. `path` for path
manipulation) — the design in §6 uses `dart:io` and `dart:convert` only,
avoiding a new dependency; if implementation finds this insufficient, use of
any additional package must stay in `dev_dependencies` and must not trip the
guard's own list-scan (self-referential edge case: the guard scans
`pubspec.yaml` for forbidden names; a dev-only test-support package is fine as
long as it isn't itself on the forbidden list).

The local cache store (Isar or equivalent, per architecture.md §2) is
explicitly **not** added here — that is REQ-423's choice (MOB-3).

## 3. `lib/` directory tree

Exactly per architecture.md §2, plus the entry point and one app/router file:

```
apps/mobile/lib/
  main.dart                  # entry point only
  app.dart                   # ProviderScope root + go_router setup (the one
                              # "app/router" file — see below)
  bootstrap/
    .gitkeep or first real file (tracked; git does not track empty dirs)
  auth/
  api/
  definitions/
  renderers/
    renderer_registry.dart   # public interface, see §4
    form/
    list/
    process/
    task/
  features/
    module_manifest.json     # depends_on manifest, see §6a
  design_system/
  i18n/
  shared/
```

Each directory that has no other content yet in this requirement gets a
placeholder file so it is tracked by git (AC5 depends on `git ls-files`
finding a tracked file per directory — an empty directory is invisible to
git). Placeholder content is a minimal library file with a doc comment
stating the directory's purpose (from architecture.md §2) and nothing else —
still design-only in spirit, since REQ-419 doesn't populate these
subsystems' logic (that's later REQs: auth→REQ-421, api→REQ-421/425,
definitions/renderers→REQ-426..428, features→first module REQ, design_system/
i18n→REQ-429, shared→as needed).

**`main.dart`** — entry point only: calls `runApp` wrapping the app widget
from `app.dart` in a `ProviderScope` (Riverpod root). No route table, no
business logic.

**`app.dart`** — the one sanctioned "app/router" file (satisfies AC5's "main.dart
and at most one app/router .dart file"): defines the top-level app widget
(`MaterialApp.router` or equivalent) and constructs the `GoRouter` instance
with a single placeholder route:

- path `/`  (or `/:slug` — open question below) → a placeholder
  "slug entry" screen widget (no auth, no fetch — MOB-2's actual bootstrap
  sequence is REQ-421).

**Open question:** whether the placeholder route is a bare `/` (a slug-entry
*form* screen the user types into) or a `/: slug` path parameter route (deep
link shape, per MOB-2's "resolve tenant identity from a deep-link subdomain or
manual slug entry"). REQ-419 only needs *a* placeholder; REQ-421 will replace
it with the real bootstrap flow. Recommend `/` with a manual text-entry
placeholder widget, since deep-link URL scheme registration is bootstrap
behavior (REQ-421's scope), not scaffold behavior — flagged for
CODE-DESIGN-VALIDATOR / REQ-421's designer to confirm rather than silently
deciding it forecloses REQ-421's design.

## 4. Renderer registry — public interface

`apps/mobile/lib/renderers/renderer_registry.dart`:

- `typedef DefinitionWidgetBuilder = Widget Function(BuildContext context, Map<String, dynamic> definition);`
- `class RendererRegistry`:
  - Backed by an internal `Map<String, DefinitionWidgetBuilder>` keyed by
    definition-type string (e.g. `"form"`, `"list"`, `"process"`, `"task"` —
    the four renderer kinds named in architecture.md's tree; exact key
    strings are an open question for whichever REQ registers the first real
    renderer — REQ-419 ships the registry with zero entries registered).
  - `void register(String definitionType, DefinitionWidgetBuilder builder)` —
    adds/overwrites an entry.
  - `Widget build(BuildContext context, String definitionType, Map<String, dynamic> definition)`
    — looks up `definitionType`; if absent, returns the fallback widget
    (below) instead of the registered builder's output.
- Fallback widget: a small stateless widget, e.g.
  `UnsupportedDefinitionTypeWidget`, constructed with the unknown
  `definitionType` string, that renders:
  - a `Key` the widget test can find: `const Key('unsupported-definition-type')`
  - visible text containing the literal substring `"Unsupported definition type"`
    (exact copy open to wording, but must contain that substring so a test can
    match by `find.textContaining('Unsupported definition type')` or by key).
  - Never an empty `Container()` or `SizedBox.shrink()` — this is MOB-4's
    stale-version principle applied from day one (AC6).

REQ-419 registers no real renderers (form/list/process/task renderers don't
exist yet — REQ-426..428). The registry ships with an empty map and the
fallback path is the only path exercised by this requirement's widget test:
call `registry.build(context, 'not-a-real-type', {})` and assert the fallback
key/text appears.

## 5. `analysis_options.yaml`

```yaml
include: package:flutter_lints/flutter.yaml

linter:
  rules:
    # project-specific additions/overrides, if any — none required by
    # REQ-419; base flutter_lints ruleset is the floor.
```

Must be strict enough that `flutter analyze` reports `No issues found!`
against the scaffold as generated (AC1) — i.e. the placeholder files added in
§3 must be lint-clean under `flutter_lints`, not merely present.

## 6. Three static guards (`apps/mobile/test/guards/`)

Ordinary Dart test files under `flutter test`'s discovery path, each
structured as: a pure, unit-testable **checker function** (so the self-test
can invoke it against a fixture without touching the real tree), plus one
`test()` that runs the checker against the real `apps/mobile/lib/` /
`pubspec.yaml` / `pubspec.lock` and asserts zero violations, plus one
self-test `test()` that runs the same checker against an in-test fixture
known to violate the rule and asserts the checker reports at least one
violation (AC4).

### (a) `apps/mobile/test/guards/module_boundary_guard_test.dart`

- Manifest format: `apps/mobile/lib/features/module_manifest.json` —
  ```json
  { "features": { "<feature-id>": { "depends_on": ["<other-feature-id>"] } } }
  ```
  A feature with no dependencies declares `"depends_on": []`. Every
  subdirectory of `lib/features/` MUST have an entry; the checker treats a
  feature directory missing from the manifest as itself a violation (fails
  closed, not open).
- Detection mechanism: walk `lib/` with `dart:io`'s `Directory.list(recursive: true)`
  filtering `.dart` files; for each file, read its content and extract
  `import '...'`/`import "..."` lines via a line-oriented regex (no
  `analyzer` package dependency — plain text scan is sufficient because
  Dart import statements are single-line, quoted string literals). For each
  import whose resolved path (relative or `package:letflow_mobile/...`)
  points inside `lib/features/<id>/`:
  - Rule 1 violation: the importing file's own path is **not** inside
    `lib/features/<id>/` and is **not** the one sanctioned navigation-bootstrap
    file (path fixed at `lib/bootstrap/navigation_bootstrap.dart` — the file
    that reads `installed_modules` and wires routes, per architecture.md §6
    rule 1; this file's own path is a constant the checker special-cases).
  - Rule 2 violation: the importing file **is** inside
    `lib/features/<a>/` where `a != id`, and `id` is not present in
    `manifest.features[a].depends_on`.
- Self-test fixture: an in-test temporary directory (`Directory.systemTemp.createTempSync`)
  containing two fake feature dirs `features/a/` and `features/b/` and a
  fixture manifest with `a.depends_on == []`; a file
  `features/a/thing.dart` containing `import '../b/other.dart';`. Running
  the checker over this fixture (not over the real `lib/`) must report
  exactly one Rule 2 violation. Asserted with `expect(violations, isNotEmpty)`
  (or an exact count).

### (b) `apps/mobile/test/guards/forbidden_dependencies_guard_test.dart`

- Detection mechanism: read `pubspec.yaml` and `pubspec.lock` as raw text
  (`dart:io` `File.readAsStringSync`); for `pubspec.lock`, package names are
  the top-level (2-space-indented) keys under `packages:` — extract via a
  line regex `^  ([A-Za-z0-9_]+):\s*$`; for `pubspec.yaml`, extract dependency
  keys the same way under the `dependencies:` and `dev_dependencies:` blocks.
  No YAML-parsing package dependency needed — the format is regular enough
  for line-based extraction, and using one avoids adding a package that the
  guard itself would then have to special-case.
- Forbidden set (exact-name match unless noted "substring"):
  `flutter_js`, `webview_flutter`, `flutter_inappwebview`, plus
  substring checks (case-insensitive) for `lua` and `wasm` in any package
  name, plus any package name containing `cel` (REQ-294's CEL-package
  prohibition) — substring checks are deliberately broader than exact-name
  to catch adjacent packages (`webview_flutter_android`, `flutter_inappwebview_platform_interface`,
  a hypothetical `cel_dart`, etc.).
- Self-test fixture: an in-memory string standing in for `pubspec.yaml`
  content: `"dependencies:\n  webview_flutter: ^3.0.0\n"`. Running the
  checker's package-name-extraction + forbidden-set-match over this string
  (not over the real `pubspec.yaml`) must report a violation naming
  `webview_flutter`.

### (c) `apps/mobile/test/guards/tenant_identifier_guard_test.dart`

- Tenant-slug source list: parse every `priv/keycloak/realms/*.json` file's
  `"realm"` field (top-level key in each Keycloak realm export — confirms
  `bpm-default` is present, per `priv/keycloak/realms/bpm-default.json`) plus
  any additional slugs enumerated in `test/support/` fixtures (backend
  ExUnit fixtures — read as plain text/JSON the same way); union into a
  forbidden-literal set, with `'bpm-default'` guaranteed present as the floor
  (the requirement's explicit minimum).
- Detection mechanism: walk `lib/` (`dart:io`, same recursive listing as
  guard (a)) reading `.dart` file contents; extract single- and
  double-quoted string literals via a regex covering non-escaped quote runs
  (`'([^'\\]*)'` and `"([^"\\]*)"`); compare each extracted literal
  case-sensitively against the forbidden-slug set. Separately, list
  `apps/mobile/assets/` (if present) and flag any file whose name or path
  contains a forbidden slug substring.
- Self-test fixture: an in-test string
  `"const tenantSlug = 'bpm-default';"` fed to the same literal-extraction +
  match function (not the real `lib/` tree) — must report a violation
  naming `bpm-default`.

Each guard file's real-tree test and self-test are two separate `test()`
blocks in the same file, both counted in `flutter test`'s output (AC2 —
"lists the three guard test files and their self-tests").

## 7. `apps/mobile/README.md`

Required sections/content (verbatim in substance, wording open):

- **Run:**
  ```
  flutter pub get
  flutter analyze
  flutter test
  flutter run -d emulator-5554
  ```
- **API base URL:** supplied at build/run time via
  `--dart-define=LETFLOW_API_BASE_URL=<url>` — state explicitly this is a
  **platform** endpoint per environment (dev/staging/prod), never a tenant
  identifier; the app resolves tenant identity separately (slug/deep-link,
  MOB-2).
- **Reaching a local backend from the emulator** — two `adb reverse`
  commands, run once per emulator boot, before `flutter run`:
  ```
  adb reverse tcp:<api-port> tcp:<api-port>
  adb reverse tcp:<keycloak-port> tcp:<keycloak-port>
  ```
  (placeholders for whatever ports `docker compose` exposes locally for the
  Letflow API and Keycloak respectively — README should show the actual dev
  ports currently in `docker-compose.yml`/`config/dev.exs` rather than
  literal `<api-port>` in the shipped file; open question for the
  implementer to fill from the current dev config rather than guess a
  number here).
- **Why not `10.0.2.2`:** state explicitly that `10.0.2.2` (the Android
  emulator's alias for the host loopback) reaches the API, but **Keycloak
  stamps a token's `iss` (issuer) claim from the host the browser used to
  authenticate** — a login flow reached through `10.0.2.2` yields an `iss`
  of `10.0.2.2`, which the backend's configured OIDC issuer (`localhost`)
  rejects. `adb reverse` avoids this because the device reaches
  **`localhost`** for both the API and Keycloak, matching the issuer the
  backend expects.

## 8. `docs/mobile/README.md` update

Current line 3 (the "Nothing is built" line):

> **Nothing is built.** This directory is a specification for a subsystem
> that does not exist yet, in this repository or in R-Co. It was migrated on
> 2026-08-21 so that the mobile tier has a home, a stage, and a dependency
> chain in Letflow's own plan rather than living as an appendix in a Zig
> repo that is being retired.

Replacement (same paragraph, first sentence changed, rest of the historical
provenance sentence kept since it's still true — the directory *was*
migrated as a spec before anything was built):

> **The scaffold exists as of REQ-419** (`apps/mobile/` — shell, static
> guards, no auth or fetch yet). This directory was originally a
> specification for a subsystem that did not exist yet, in this repository
> or in R-Co; it was migrated on 2026-08-21 so that the mobile tier has a
> home, a stage, and a dependency chain in Letflow's own plan rather than
> living as an appendix in a Zig repo that is being retired.

The line further down (§ "Status", currently: "`apps/mobile/` itself still
does not exist; that is `REQ-419`'s job, part of the `REQ-417..430` build
queue.") is now also stale once REQ-419 lands; DOC-UPDATER's normal
status-flip pass (not this design) should reconcile it — flagged here so it
isn't missed, but out of this requirement's owned-files scope
(`docs/mobile/README.md` is explicitly in `owned_modules`, so REQ-419's own
change should fix both sentences in the same commit rather than leave a
second stale claim next to the one it just fixed).

## 9. iOS — explicit open constraint

`ios/Podfile` MUST declare `platform :ios, '15.0'` (§1). Building
(`pod install`, `flutter build ios`, any Xcode invocation) is **deferred**:
the build host for this requirement is Windows, which cannot run Xcode. The
completion report must state this deferral explicitly rather than omit iOS
results — this is recorded, not dropped, matching REQ-419's own text ("iOS:
files are generated and configured; building them is DEFERRED").

## Acceptance-criteria map

| AC | Design element |
|---|---|
| `flutter analyze` clean | §3 placeholder files + §5 lint config |
| `flutter test` lists 3 guard files + self-tests | §6, two `test()` blocks per guard file |
| `flutter build apk --debug` + minSdk/applicationId grep | §1 |
| each guard self-test fails on violating fixture | §6a/b/c self-test fixtures |
| `git ls-files` directory set | §3 tree + placeholder-file requirement |
| widget test on renderer fallback | §4 |
| `Podfile` platform line + iOS deferred statement | §9 |
| `git diff --name-only` scope | `owned_modules`: `apps/mobile/`, `docs/mobile/README.md` only — no other file touched |

## Open questions (not resolved here — flag to CODE-DESIGN-VALIDATOR / next REQ's designer)

1. Placeholder route shape (`/` manual entry vs `/:slug` deep link) — §3.
2. Exact dev-port values for the `adb reverse` commands in the README — §7
   (implementer should read current `docker-compose.yml`/`config/dev.exs`
   rather than invent a number).
3. Whether `flutter create`'s default-generated `test/widget_test.dart`
   (the stock counter-app smoke test) must be deleted or rewritten — it will
   not compile against the new `app.dart`/`main.dart` shape from §3, so it
   cannot be left as-is; deleting it in favor of the guard tests plus a new
   renderer-fallback widget test (§4) is the straightforward resolution, but
   is called out since REQ-419's text doesn't mention it explicitly.
