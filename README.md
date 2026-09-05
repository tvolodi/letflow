# Letflow

Letflow is an Elixir/OTP multi-tenant BPM platform. The name plays on
the double meaning of "let it flow" — a workflow engine, and one meant
to run itself via AI agents rather than needing a human to drive each
step. Letflow began as a full, staged migration of a predecessor
system, [R-Co](../R-Co) (Robotized Company); that migration is now
essentially complete (see "Migration status" below), and R-Co's design
and source now serve as historical provenance for why Letflow behaves
the way it does, not as the reason to keep building it that way.

> The project directory on disk is still `ro-co` (a live session had
> it open and couldn't rename it); the code, mix app, and modules are
> all `Letflow` / `:letflow`. Rename the folder to `letflow` when
> convenient — nothing inside depends on the directory name.

## Migration status

The R-Co migration that originally shaped this project is effectively
complete — the large majority of `docs/requirements.yaml`'s
requirements are `status: done`, with only a small pending tail and a
handful formally cancelled. `docs/migration/` is retained as the
historical build record: it explains why Letflow's stages (S0–S9) and
much of its design look the way they do, including the R-Co source
paths each stage ported from, but it is documentation of how Letflow
was built, not live instructions for how it should be shaped from
here. `docs/requirements.yaml`'s `stages:` list and
`docs/migration/README.md` have the full breakdown. This section
intentionally doesn't restate a snapshot count here, since that's
exactly the kind of number that goes stale (see `ISS-0022`) — check
`docs/requirements.yaml` for the next `pending` requirement before
starting unscoped work, same as always.

## The frontend and the mobile tier

As of 2026-08-21 this repository also holds **`web/`** — Letflow's React
18 + TypeScript + Vite SPA, migrated out of R-Co along with its
specification (`docs/frontend/`). Letflow owns it; it is no longer
"R-Co's frontend that we point at our API." See
[`web/README.md`](web/README.md) for how to run it, what was and wasn't
carried over, and the drift it arrived with, and
`docs/migration/decisions/0011-frontend-ownership.md` for why. It
type-checks, lints, and passes 178 unit + 47 guard tests on its own; it
does **not** yet work end-to-end against Letflow, because the API
surface it needs (S4) is still being built. That integration is S8.
`npm run check` (run from `web/`) is the frontend's counterpart to
`mix letflow.check` below — type-check, lint, test, and guards in that
order, fail-fast (REQ-115); see `web/README.md`'s script table. Not yet
wired into CI (no `.github/workflows/` exists in this repository yet —
that's REQ-138).

The same migration brought over the **mobile tier specification**
(`docs/mobile/`) as stage S9 — a Flutter app that is a generic
interpreter of server-delivered definitions, on the same principle as
the SPA. Nothing is built: the tier was specified in R-Co and never
implemented, and all three of the backend endpoints it needs are
verified gaps in Letflow today.

## What's here today

The original pilot slice (`Letflow.ProcessInstance`, a hand-rolled
4-state `:gen_statem` workflow, plus a second parallel-approval state
machine) was retired as of REQ-046 — superseded by the real,
definition-driven instance engine landing across Stage 3
(`Letflow.Engine.create/2`; see `docs/migration/stage-3-instance-engine.md`).
`Letflow.Router` (Plug + Bandit, no Phoenix — see
`docs/migration/decisions/0001-web-framework.md`) serves `GET /health`,
the unauthenticated `GET /api/tenant-config` (REQ-078, web-SPA
login-bootstrap) and `GET /api/mobile/tenant-config` (REQ-124, the
MOB-2 mobile-tier bootstrap gate — see `docs/mobile/build-order.md`
phase M-0), plus `Letflow.Plugs.Cors` (REQ-118) mounted ahead of all of
them; see `Letflow.Router`'s own moduledoc for the full route table.
The real tenant-scoped instance-management HTTP API is deferred to S4
(api-surface) and will be built against `Letflow.Engine.create/2`, not
a revival of the old pilot contract's three routes. `Letflow.InstanceSupervisor`
is retained, with `start_instance/1` removed, reserved for REQ-056/057.

Check `docs/requirements.yaml` for the current per-requirement status
of the Stage 3 engine build-out.

## Running it

```
docker compose up -d
mix deps.get
LETFLOW_DEV_DB_CONFIRMED=1 mix ecto.setup
LETFLOW_DEV_DB_CONFIRMED=1 mix run --no-halt
```

`LETFLOW_DEV_DB_CONFIRMED=1` is required for anything that connects to
`letflow_dev` — see `Letflow.Repo.init/2`. Unlike the test database
(isolated per workspace via `MIX_TEST_PARTITION`), `letflow_dev` is a
single database shared across every concurrent workspace/host in this
project's multi-workspace setup; the confirmation requirement exists so a
bare/accidental `mix ecto.migrate` or `mix run` from one workspace can't
silently write to state another workspace is relying on. For
throwaway/scratch verification (provisioning a tenant, checking a
migration by hand), use the already-isolated test database instead:
`MIX_ENV=test MIX_TEST_PARTITION=<N> mix ecto.migrate` /
`MIX_ENV=test MIX_TEST_PARTITION=<N> mix run -e '...'`.

```
LETFLOW_DEV_DB_CONFIRMED=1 mix letflow.seed
```

Provisions the `bpm-default` tenant (slug and `idp_realm_id` both
`bpm-default`) that authenticated requests bearing a
`bpm-default`-realm token resolve against
(`Letflow.Identity.resolve_tenant_by_realm/1`, used by `AuthPipeline`'s
tenant-resolution step). Required once per fresh `letflow_dev`
database (a fresh `docker compose up -d` volume, or after a `mix
ecto.reset`); safe to re-run.

```
curl -s localhost:4000/health
# {"status": "ok"}
```

This is the only working HTTP endpoint today — see "What's here today"
above. Any other path currently 404s, as an RFC 9457 problem document
(`Content-Type: application/problem+json`) rather than an ad-hoc error
body; the real instance-management API lands in S4.

```
curl -s -i localhost:4000/nope
# HTTP/1.1 404 Not Found
# content-type: application/problem+json
# {"type":"https://bpm.example.com/problems/not-found","title":"Not Found",
#  "status":404,"detail":"the requested resource was not found","trace_id":""}
```

Every error body in the application goes through the one
`Letflow.Api.Error`/`Letflow.Api.Response` contract (REQ-066); the
`type` base URI is configurable via `config :letflow, :problems_base_uri`.

```
mix test
```

`mix test`/`scripts/test_parallel.sh` exclude one deliberately-tagged suite by default:
`test/letflow/integration/keycloak_auth_pipeline_test.exs` (`@moduletag :keycloak`)
drives a genuine token from the running Keycloak through `Letflow.Plugs.AuthPipeline`
end to end (REQ-134) and needs `docker compose up -d keycloak` first. Run it
deliberately with:

```
mix test --include keycloak test/letflow/integration/keycloak_auth_pipeline_test.exs
```

To run format-check + compile-with-warnings-as-errors + test as a
single fail-fast gate (equivalent to R-Co's `zig build check`):

```
mix letflow.check
```

`mix letflow.check` runs clean end-to-end as of 2026-08-17 (ISS-0012). Two
prior caveats recorded here no longer apply: the formatting failure
(`ISS-0008`) was resolved 2026-08-15, and a since-fixed test-isolation flake
in `test/letflow/plugs/tenant_status_test.exs` (`ISS-0011`, a global
`:telemetry.attach` racing other concurrently running `async: true` tests)
could occasionally fail an unrelated run — both are `status: resolved`, and
running the full suite four times in a row while verifying this note showed
zero flakes.

To also capture compile/test timing, run the suite via the timing
script instead — it appends one row to `docs/eval/dev-loop-timings.csv`
per run:

```
sh scripts/timed_test.sh
```

This is a plain shell script, not a `mix` task, on purpose — see the
comment at the top of `scripts/timed_test.sh` for why a `mix`-prefixed
command structurally can't time this project's own compile step.

To run the suite across parallel OS processes instead (Elixir's native
`mix test --partitions N`, one `Repo` pool per process — much faster
than the single-process `mix test` above on multi-core hosts):

```
sh scripts/test_parallel.sh
```

`N` defaults to `nproc` (override with `TEST_PARALLEL_N`). If the
`nproc`-derived `N` exceeds this host's Postgres/CPU capacity, every
partition can crash outright during `ecto.create`/`ecto.migrate`
before any test result is produced (ISS-0219) — if that happens, set
`TEST_PARALLEL_N` explicitly to a smaller value (`4` is known-good on
at least one dev host) rather than assuming a code regression. The
script
pre-compiles `MIX_ENV=test` exactly once before launching any
partition, then aggregates each partition's own reported pass/fail
counts into one combined total and exits non-zero if any partition
failed. This is now the full-suite mechanism `TEST-RUNNER` and
`RELEASE-VALIDATOR` invoke in their own workflow steps (REQ-114),
replacing the plain `mix test` full-suite invocations they used
before.

Postgres runs on port 5462 by default, not 5432 — R-Co's own
docker-compose already uses 5432 (dev) and 5433 (test), so this can run
alongside it without colliding.

That default is per-workspace, not fixed. This repo is routinely checked
out into more than one workspace at a time (`letflow`, `letflow-2`, plus
git worktrees), each running its own `docker compose up`; a hardcoded
host port makes the second one fail to bind (or, worse, silently come up
with no port mapping at all — see `docs/anti-patterns.md`). To give a
workspace its own PostgreSQL instance, create an untracked `.env` at the
project root:

```
LETFLOW_DB_PORT=5472
```

Both `docker-compose.yml` (host-port mapping) and `config/dev.exs` /
`config/test.exs` (via `config/db_port.exs`) read that one file, so the
container and Ecto can't drift apart. An environment variable of the same
name takes precedence over `.env`; with neither set, the port is 5462 and
behaviour is unchanged. `.env` is gitignored on purpose — the port is
local state of a checkout, not of the project.

## Notes

- Elixir 1.20.3 / OTP 29 is the pinned toolchain for this repo (see
  `docs/migration/decisions/0005-pin-formatting-toolchain.md`) — install
  it via `asdf install` after `asdf plugin add elixir` /
  `asdf plugin add erlang` if you don't already have those plugins; the
  root `.tool-versions` file selects the exact version automatically on
  `cd` into this repo. `mix.exs`'s `elixir: "~> 1.18"` requirement is a
  compile-time backstop only, and it is deliberately **wider** than the
  pin: `~> 1.18` means `>= 1.18.0 and < 2.0.0`, so it admits 1.19, 1.20
  and 1.21. That width is the point — an off-pin host is *warned, never
  blocked*: it still compiles, still runs the full gate, and still gets
  an exit code that reflects the code rather than the toolchain.
  Narrowing this line is not a consistency cleanup and needs REVIEWER
  sign-off. Because the requirement can't catch formatter drift on its
  own, `mix letflow.check` now runs `letflow.check_toolchain` as its
  first step, which warns on stderr when the running Elixir/OTP differs
  from `.tool-versions`. That warning is advisory: it never changes an
  exit code. Running `mix format` (and `mix letflow.check`) under the
  `.tool-versions`-selected toolchain is what actually keeps formatting
  deterministic across hosts.
- `mix deps.get` needs network access to hex.pm, which this sandbox
  doesn't have — dependencies are declared in `mix.exs` but not
  fetched. Run it locally.
