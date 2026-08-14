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
and the R-Co source paths each stage ports. Only Stage 0
(foundation-and-scaffolding) is broken into requirements today — later
stages are expanded into requirements as the stage before them lands.
Check `docs/requirements.yaml` for the next `pending` requirement
before starting unscoped work, same as always.

## What's here today

The earliest working slice (still the actual runnable code — the
migration builds on top of it, doesn't replace it): a minimal slice of
a BPM engine, one workflow, four states, plus a second
parallel-approval state machine.

```
draft --submit--> submitted --approve--> approved (terminal)
  ^                   |
  |                 reject
  +----resubmit-------+ (rejected)
```

- `Letflow.ProcessInstance` — one `:gen_statem` process per running
  workflow instance.
- `Letflow.InstanceSupervisor` — a `DynamicSupervisor` that owns one
  instance process per running workflow.
- `Letflow.Events.TransitionEvent` / migrations — every transition is
  logged to Postgres via Ecto, mirroring R-Co's migration discipline.
- `Letflow.Router` — three HTTP endpoints (Plug + Bandit, no Phoenix
  yet — see `docs/migration/decisions/0001-web-framework.md`) to drive
  it end to end.

## Running it

```
docker compose up -d
mix deps.get
mix ecto.setup
mix run --no-halt
```

```
curl -s -X POST localhost:4000/instances | tee /tmp/inst.json
# {"id": "..."}

curl -s -X POST localhost:4000/instances/<id>/actions \
  -H 'content-type: application/json' -d '{"action": "submit"}'

curl -s localhost:4000/instances/<id>
# {"state": "submitted", "history": [...]}
```

```
mix test
```

To also capture compile/test timing, run the suite via the timing
script instead — it appends one row to `docs/eval/dev-loop-timings.csv`
per run:

```
sh scripts/timed_test.sh
```

This is a plain shell script, not a `mix` task, on purpose — see the
comment at the top of `scripts/timed_test.sh` for why a `mix`-prefixed
command structurally can't time this project's own compile step.

Postgres runs on port 5462, not 5432 — R-Co's own docker-compose
already uses 5432 (dev) and 5433 (test), so this can run alongside it
without colliding.

## Notes

- Elixir 1.14 / OTP 25 via apt was used to scaffold this — use whatever
  current version you have locally (1.17+ recommended) once you pull
  this down; nothing here depends on 1.14 specifically.
- `mix deps.get` needs network access to hex.pm, which this sandbox
  doesn't have — dependencies are declared in `mix.exs` but not
  fetched. Run it locally.
