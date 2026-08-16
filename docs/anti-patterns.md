# Anti-patterns — Letflow

Known mistakes and their correct alternative, logged as they're found.
Read this before doing anything non-trivial (see `CLAUDE.md`). Empty
sections are expected early on — this grows with the project.

Format per entry: what happened, why it's wrong for this project
specifically, the correct alternative.

<!-- Example shape, remove once the first real entry lands:

## Reporting `mix test` as passing without running it

An agent said "the property test should now cover the new transition"
without actually running `mix test`. This violates the No Speculation
rule in `CLAUDE.md` and defeats the point of the property test, which
exists specifically to catch cases a human wouldn't think to assert by
hand (README §4).

**Correct alternative:** run `mix test`, quote the actual output. If
the environment can't run it (no toolchain, no network for
`mix deps.get`), say that explicitly instead.
-->

## No Elixir/mix toolchain on PATH in this sandbox

Agents repeatedly discover (correctly, per the No Speculation rule)
that there's no local Elixir/mix toolchain, and stop at "can't verify."
There's a working alternative: Docker is available. Run a throwaway
`elixir:1.17-otp-27` container plus an isolated `postgres:16` container
on a private Docker network (`docker network create`, then both
containers `--network` onto it, referencing Postgres by container name
as the DB hostname rather than `localhost`). This sidesteps host port
5462 too, which may already be held by another local Postgres
container — don't touch a container that isn't yours.
Mount the repo read-write into the Elixir container
(`-v //c/...:/app -w /app`), run `mix local.hex --force` /
`mix local.rebar --force` once, then `mix deps.get` / `mix compile` /
`mix ecto.create` / `mix ecto.migrate` / `mix test` as `docker exec`
calls. Tear down both containers and the network afterward. On
Windows/Git Bash, bare `/app`-style paths get mangled by MSYS path
conversion — prefix affected `docker run`/`docker exec` calls with
`MSYS_NO_PATHCONV=1`. If `config/test.exs` hardcodes `localhost:5462`,
temporarily change it to read `System.get_env("LETFLOW_DB_HOST",
"localhost")` / a port env var with the same fallback, run the
verification, then revert the config file back to its committed
contents afterward — don't leave the env-var indirection in a tracked
file for a one-off verification run.

**Correct alternative:** try Docker-based verification before reporting
"can't run it" as final — it worked cleanly for REQ-001 (12/12 tests,
including a StreamData property test, against a real Postgres).

## Overwriting `docs/status/requirement_status.yaml` instead of appending

An agent (ELIXIR-DEV, REQ-003) found the file didn't match its
expectations and rewrote it from scratch with a different header
format and field names (`requirement`/`timestamp_utc` instead of the
established `req`/`at`), silently discarding every prior history entry
(REQ-001, REQ-002). The file's own header comment says "Append one
entry per event. Never rewrite past entries" — this is exactly the
mistake that comment exists to prevent. ORCH caught it by diffing
against what it had just written and restored the lost entries.

**Correct alternative:** always read the existing file in full before
touching it, preserve its established schema even if a different shape
seems cleaner, and append (don't replace). If the file is genuinely
missing, use the header/entry shape already documented in this repo's
other status files or CLAUDE.md, not an invented one.

## Extrapolating handoff timestamps instead of reading the clock (ORCH)

During REQ-023's WF-02 run, ORCH stamped each dispatched handoff's
`created_at`/`started_at` by *estimating* a plausible time from the
run's earlier entries rather than running `date -u` for each one. The
estimates crept steadily ahead of the real clock — by the eleventh
handoff (`step-06-doc-updater.json`) they were ~23 minutes fast. That
made the handoff's `completed_at` (correctly clock-read by
DOC-UPDATER as `18:49:40Z`) *precede* its own `started_at`
(`19:08:00Z`), which is exactly the corruption
`docs/agents/shared/HANDOFF_PROTOCOL.md` §3 forbids and
`core-directives.md`'s "Bookkeeping Is Not Optional" section exists to
prevent.

Why this is worth its own entry even though the fix is one command:
the failure is silent and cumulative. Each individual estimate looked
reasonable next to the previous one, nothing in the file's appearance
revealed the drift, and a mechanical check across all eleven handoffs
found ten of them internally consistent — so the error was invisible
right up until it produced an impossible ordering. It was caught only
because DOC-UPDATER read the real clock, noticed the contradiction with
the `started_at` it had been handed, and *reported it instead of
quietly writing a later `completed_at`* to make the file look tidy.
That is the producer/validator principle working on ORCH's own
bookkeeping, and it only worked because the agent refused to smooth
over an inconsistency it had not caused.

Note this is the same shape as the existing `.ToUniversalTime()`
warning in `core-directives.md` — a timestamp that is wrong in a way
the output string does not reveal. Anything a later reader would use to
reconstruct sequence (handoff stamps, `requirement_status.yaml` events,
`orchestrator.log` lines) has to come from the clock, because nothing
downstream can detect that it didn't.

**Correct alternative:** run the clock command immediately before
writing each timestamp, every time — never derive one from another
entry, never round a previous value forward, and never batch-generate
several stamps from a single reading:

```bash
date -u +"%Y-%m-%dT%H:%M:%SZ"
```
```powershell
(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
```

If a bad timestamp has already been committed, correct it *and* record
that it was a reconstruction rather than a measurement (see
`handoffs/WF02-REQ023-20260816/step-06-doc-updater.json`'s
`orch_timestamp_correction` field for the shape) — a silently corrected
timestamp is indistinguishable from one that was right all along, which
defeats the audit trail the correction is meant to preserve.
