# Letflow

Letflow is the Elixir/OTP rewrite target for
[R-Co](../R-Co) (Robotized Company), a multi-tenant BPM platform.
Letflow is a **full, staged migration** of R-Co to Elixir. The name
plays on the double meaning of "let it flow" — a workflow engine, and
one meant to run itself via AI agents rather than needing a human to
drive each step.

> The project directory on disk is still `ro-co` (a live session had
> it open and couldn't rename it); the code, mix app, and modules are
> all `Letflow` / `:letflow`. Rename the folder to `letflow` when
> convenient — nothing inside depends on the directory name.

## Migration status

The migration is staged (S0–S8); see `docs/requirements.yaml`'s
`stages:` list and `docs/migration/README.md` for the full breakdown
and the R-Co source paths each stage ports. As of 2026-08-17: Stage 0
(foundation-and-scaffolding) and Stage 1 (identity/multi-tenancy) are
both fully expanded into requirements **and done** — S1's stage gate
was formally cleared 2026-08-16. Stage 2 (event store + definitions)
is expanded into requirements and in progress. Later stages are
expanded as the stage before them lands. `docs/requirements.yaml` and
`docs/migration/README.md`'s "Requirement expansion" section are the
live source of truth for exact per-requirement status — this section
intentionally doesn't restate a snapshot count here, since that's
exactly the kind of number that goes stale (see `ISS-0022`). Check
`docs/requirements.yaml` for the next `pending` requirement before
starting unscoped work, same as always.

## What's here today

The original pilot slice (`Letflow.ProcessInstance`, a hand-rolled
4-state `:gen_statem` workflow, plus a second parallel-approval state
machine) was retired as of REQ-046 — superseded by the real,
definition-driven instance engine landing across Stage 3
(`Letflow.Engine.create/2`; see `docs/migration/stage-3-instance-engine.md`).
`Letflow.Router` now serves only `GET /health` (Plug + Bandit, no
Phoenix — see `docs/migration/decisions/0001-web-framework.md`); the
real tenant-scoped instance-management HTTP API is deferred to S4
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
curl -s localhost:4000/health
# {"status": "ok"}
```

This is the only working HTTP endpoint today — see "What's here today"
above. Any other path currently 404s; the real instance-management API
lands in S4.

```
mix test
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

- Elixir 1.18.3 / OTP 27 is the pinned toolchain for this repo (see
  `docs/migration/decisions/0005-pin-formatting-toolchain.md`) — install
  it via `asdf install` after `asdf plugin add elixir` /
  `asdf plugin add erlang` if you don't already have those plugins; the
  root `.tool-versions` file selects the exact version automatically on
  `cd` into this repo. `mix.exs`'s `elixir: "~> 1.18"` requirement is a
  compile-time backstop only — it accepts any 1.18.x patch, so it will
  not itself catch formatter drift; running `mix format` (and
  `mix letflow.check`) under the `.tool-versions`-selected toolchain is
  what actually keeps formatting deterministic across hosts.
- `mix deps.get` needs network access to hex.pm, which this sandbox
  doesn't have — dependencies are declared in `mix.exs` but not
  fetched. Run it locally.
