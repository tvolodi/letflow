# Letflow — mobile tier (`apps/mobile/`)

Flutter/Dart client for Letflow. A **generic interpreter of server-delivered
definitions**, on the same principle as `web/` — see
[`docs/mobile/architecture.md`](../../docs/mobile/architecture.md) for the
governing principle, stack, and v1 boundary, and
[`docs/mobile/requirements.md`](../../docs/mobile/requirements.md) for
`MOB-1..8`.

As of `REQ-419` this is the scaffold only: shell app, module layout, static
guards. No auth and no network fetch yet — those land in `REQ-421` (`MOB-2`).

## Run

```
flutter pub get
flutter analyze
flutter test
flutter run -d emulator-5554
```

## API base URL

The platform API base URL is supplied at build/run time via:

```
--dart-define=LETFLOW_API_BASE_URL=<url>
```

This is a **platform** endpoint per environment (dev/staging/prod) — never a
tenant identifier. The app resolves tenant identity separately, via a slug or
deep link (`MOB-2`, `docs/mobile/architecture.md` §1). One tenant-agnostic
build serves every tenant; the API base URL is the only thing that varies per
environment.

## Reaching a local backend from the emulator

Letflow's dev stack (`docker-compose.yml`, `config/dev.exs`) exposes:

- the Letflow API on `localhost:4000`
- Keycloak on `localhost:8082` (the `LETFLOW_KEYCLOAK_PORT` default;
  per-workspace local state — check your own `LETFLOW_KEYCLOAK_PORT` if it
  has been overridden)

Once per emulator boot, before `flutter run`, forward both ports from the
device to the host:

```
adb reverse tcp:4000 tcp:4000
adb reverse tcp:8082 tcp:8082
```

Then run with:

```
flutter run -d emulator-5554 --dart-define=LETFLOW_API_BASE_URL=http://localhost:4000
```

### Why not `10.0.2.2`

The Android emulator's alias for the host loopback, `10.0.2.2`, reaches the
API fine. It does **not** work for the login flow: Keycloak stamps a token's
`iss` (issuer) claim from the host the browser used to authenticate. A login
reached through `10.0.2.2` yields an `iss` of `10.0.2.2`, which the backend's
configured OIDC issuer (`localhost:<port>`, see `config/dev.exs`) rejects —
the token verifies against the wrong issuer and every subsequent authenticated
call fails.

`adb reverse` avoids this because the device reaches **`localhost`** for both
the API and Keycloak, matching the issuer the backend expects. This is why
`10.0.2.2` is not an acceptable substitute for the two `adb reverse` commands
above, even though it appears to work for unauthenticated calls.

## Structure

```
lib/
  main.dart          # entry point only
  app.dart            # ProviderScope root + go_router (the one sanctioned
                       # app/router file)
  bootstrap/           # startup sequence + navigation bootstrap
  auth/                # OIDC Authorization-Code + PKCE (flutter_appauth)
  api/                 # Dio-backed HTTP client
  definitions/         # definition fetch/cache/version-pin
  renderers/
    renderer_registry.dart   # keyed by definition type; unknown type falls
                              # back to an explicit "unsupported definition
                              # type" widget, never a blank screen
    form/  list/  process/  task/
  features/           # one subdirectory per installed module
    module_manifest.json     # declares each feature's depends_on
  design_system/
  i18n/
  shared/
```

## Static guards

`test/guards/` holds three ordinary Dart tests that fail `flutter test` (and
therefore CI) on a violation, not just warn:

- `module_boundary_guard_test.dart` — the core/module import boundary
  (decision `0039` D3): no file outside `lib/features/<id>/` imports from it
  except `lib/bootstrap/navigation_bootstrap.dart`, and a feature only imports
  another feature declared in its `depends_on`.
- `forbidden_dependencies_guard_test.dart` — no script runtime (Lua/JS/WASM),
  no CEL package, no webview package in `pubspec.yaml`/`pubspec.lock`.
- `tenant_identifier_guard_test.dart` — no compiled-in tenant/realm slug
  literal (e.g. `bpm-default`) and no tenant-specific asset.

Each guard's checker is also exercised against an in-test fixture that
violates the rule, to prove the guard actually fires.
