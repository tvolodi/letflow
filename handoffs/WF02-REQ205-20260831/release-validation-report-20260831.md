# RELEASE-VALIDATOR report — REQ-205 — WF02-REQ205-20260831

Date: 2026-08-31. Branch: `feature/WF02-REQ205-20260831`. Verified independently
from source and real command output; no prior agent's verdict was trusted without
re-derivation.

## AC1 decision — ACCEPT WITH RECORDED CAVEAT (not a clean PASS)

**Verdict: the AC1 gap does NOT block marking REQ-205 done, on condition that a
follow-up task to port real R-Co fixture content is filed and made a hard
prerequisite of REQ-206 (see "Consequence for REQ-206/207/208" below).**

### Is R-Co source genuinely unreachable?

Re-checked independently, not trusting ELIXIR-DEV's search:
- No `/mnt/c` or any Windows-host mount exists in this sandbox (`mount` output
  checked; nothing under `/mnt` but an empty directory).
- `find / -xdev -iname "*swiftroute*" -o -iname "*vortex*" -o -iname "*meridian*"`
  (excluding this repo's own now-existing fixtures) returns nothing.
- This sandbox *does* have outbound network reachability (confirmed: ICMP to
  8.8.8.8 succeeds, a raw TCP connect succeeds) — but that is irrelevant here:
  there is no hostname, IP, or credential anywhere in this repo or its docs for
  reaching the specific Windows machine at `c:\Users\tvolo\dev\ai-dala\R-Co\`.
  Network reachability in the abstract does not translate into a path to an
  unaddressed private filesystem on an unknown host.
- No sibling-session artifact in this repo carries the real fixture bytes.
- Notably, `docs/requirements.yaml`'s own REQ-205 description states the source
  material was "confirmed present in R-Co ... this session" at requirement-drafting
  time — meaning some session, on some host, *did* have R-Co filesystem access when
  REQ-ANALYST wrote this requirement. That access exists somewhere in this
  project's operating environment; it is simply not available from *this* Linux
  implementation sandbox. This makes the gap a **routing problem** (dispatch the
  fixture-porting work to a host that has R-Co access), not a **permanently lost
  data** problem.

Conclusion: ELIXIR-DEV did not give up early — the unreachability is real from this
sandbox, confirmed independently. But it is not evidence R-Co content is
unrecoverable in general.

### Does the rest of the requirement stand on its own?

Yes, independently re-verified (see AC2–AC8 below). `Letflow.Simulation.Seed` and
`Letflow.Simulation.Runner` depend only on the *shape* of the fixture YAML
(`slug`/`display_name`/`hostname`, `people`/`groups` with `actor_id`,
`name`/`version`/`graph`), never on specific R-Co values. Swapping the 12 YAML
files for real R-Co content later is a data-only change — zero code change to
`test/support/simulation/{seed,runner}.ex` — confirmed by reading both modules:
neither hardcodes any of the current synthetic values (`swiftroute`, `Swiftroute
Logistics`, etc.); all values flow in through `Map.fetch!`/`Map.get` on the parsed
YAML map.

### Precedent

Checked for a prior instance in this session of "real content unavailable,
structurally-equivalent synthetic substituted, explicitly disclosed":
none found. REQ-202's design doc records the *same environmental constraint*
(R-Co unreachable) but a **different resolution**: REQ-202's own requirement text
already had the needed facts pre-verified and recorded by REQ-ANALYST at drafting
time, so no fresh file access was needed at implementation time. REQ-205's AC1 is
different in kind — it needs literal byte-for-byte fixture *content* that was never
transcribed into `docs/requirements.yaml`, so no substitute source existed. **This
resolution (self-authored synthetic content, disclosed in every file header, gap
disclosed at every gate) is genuinely novel for this session, not a repeat of an
already-accepted pattern.** I am setting it as the precedent going forward, not
citing one.

### Consequence for REQ-206/207/208

This is the part of the decision most likely to be under-weighted: REQ-206/207/208
run real R-Co *scenario* YAML (a separate corpus, e.g.
`swiftroute-tenant-onboarding-happy.yaml`) that references specific `actor_id`
values (e.g. `actor-swiftroute-lena`) expected to resolve against the org/company
fixtures REQ-205 seeds. If REQ-206 is implemented against REQ-205's current
*synthetic* org fixtures, the real scenario YAML's actor references will not
resolve — REQ-206 cannot be genuinely run against real R-Co scenario content until
REQ-205's 12 fixture files are the *real*, actor-id-matching ones. **This is not
a "nice to have later" cleanup — it is a hard blocking prerequisite for REQ-206 to
do the one thing it exists to do.**

**Recommendation to ORCH (not self-filed — routing an issue is ORCH's job per
`ISSUE_QUEUE.md`):** file a follow-up task, e.g. "Port REQ-205's 12 R-Co
company/org/process fixture files with real content and unchanged actor_id values,
on a host with `c:\Users\tvolo\dev\ai-dala\R-Co\` access" and make it a hard
prerequisite (`depends_on`) of REQ-206 starting. Scope is small and low-risk per
ELIXIR-DEV's own note: only `test/fixtures/simulation/**/*.yaml` changes; zero
`test/support/simulation/{seed,runner}.ex` changes required.

### What DOC-UPDATER should record

- REQ-205 status: `done`, but its acceptance-criteria record must show **AC1:
  PARTIALLY MET** (structure/mechanism/test genuinely met; literal "ported from
  R-Co with actor_id values unchanged" content NOT met — synthetic substitute in
  place, disclosed in every fixture file's header comment) — not a blanket "all 8
  ACs met."
- The run-history event should state the caveat explicitly and reference this
  report, so a later reader of `requirement_status.yaml` sees the gap without
  needing to open this file.
- The follow-up fixture-porting task (once ORCH files it via `letflow-queue`)
  should be cross-referenced from REQ-205's status entry.

## AC2–AC8 — independently re-verified

All read from current source and re-run by me this session; not copied from any
prior agent's report.

**AC2 (Seed calls Letflow's own context modules directly, no HTTP/subprocess) —
MET.** Read `test/support/simulation/seed.ex` in full (371 lines). `seed_company/1`
calls `Letflow.Identity.create_tenant/1` + `Letflow.TenantOnboarding
.provision_and_migrate/1` + `Letflow.Identity.create_onboarding/1`; `seed_users/2`
calls `Letflow.Identity.create_user/2`; `seed_groups/2` calls
`Letflow.Identity.create_group/2` / `add_group_member/3`; `seed_process/3` (arity
widened from the design's `seed_process/1`, documented in the moduledoc as a
recorded deviation, not silent) calls `Letflow.Definitions.create/2` +
`activate/2`. No `HTTPoison`/`Req`/`System.cmd` calls anywhere in the file —
grepped, zero hits. Two other recorded, disclosed deviations checked and found
accurate: `Tenant.t()` has no prefix field (confirmed by reading
`lib/letflow/identity/tenant.ex`'s schema — `id, slug, display_name, status,
idp_realm_id`, no prefix), so `schema_name!/1` derives it via
`TenantProvisioning.schema_name_for_tenant/1`; `get_by_username/2` and
`*_unique_conflict?/1` are `defp` in `Letflow.Identity`, confirmed by reading
`lib/letflow/identity.ex` — Seed correctly substitutes a public
`list_users/2`-plus-client-side-match idiom instead of calling private functions.

**AC3 (double-seed is a no-op, one test per entity kind) — MET.** Ran
`test/letflow/simulation/` + `test/fixtures/simulation/` myself against real
Postgres:

```
Finished in 17.2 seconds (0.3s async, 16.8s sync)
Result: 25 passed
```

`test/letflow/simulation/seed_idempotency_test.exs` has one test per entity kind
(tenant, user, group, definition), each seeding twice and asserting a direct row
count of 1 via `Repo`/`Identity`/`Definitions` queries — not an inference from "no
error raised."

**AC4 (real HTTP dispatch, real instance_state query) — MET.** Read
`test/letflow/simulation/runner_test.exs`'s AC4 test: builds a real `%Scenario{}`,
dispatches `POST /api/v1/instances` through `Letflow.Router.call/2` with a real
API-token bearer header + `x-tenant-slug`, and verifies an `instance_state` outcome
by querying `Letflow.Instances.get_by_id/2` against the live row afterward. Test
passes in the run above.

**AC5 (`via: gui` recorded `DEFERRED_TO_S8`, never silently dropped/executed) —
MET.** Read the AC5 test in the same file — asserts a `gui` step appears in
`step_results` with `outcome: :deferred_to_s8` and is never dispatched as HTTP
(no request recorded for it). Passes.

**AC6 (moduledoc distinguishes from `Letflow.Routers.SimulationTest`/
`simulation_test.zig`) — MET.** Read `Letflow.Simulation.Runner`'s moduledoc
(`test/support/simulation/runner.ex` lines 104–150+) directly. It states plainly:
"This module is explicitly **not** R-Co's `src/api/routes/simulation_test.zig` /
`src/simulation/scenario_runner.zig` mechanism," explains the different input
shape/caller/question each answers, and states "this requirement does not build
that router" — all three required points present, both R-Co paths cited by name.

**AC7 (YAML dependency needs REVIEWER sign-off) — MET.**
`handoffs/WF02-REQ205-20260831/step-02d-reviewer.json`'s
`ac7_dependency_signoff.decision` reads "SIGNED OFF — yaml_elixir ~> 2.11 (only:
:test) approved," with a genuine rationale (pure-Elixir wrapper around `:yamerl`,
no NIF surface, `only: :test` scoping, alternatives considered). Confirmed
independently in `mix.exs` line 64: `{:yaml_elixir, "~> 2.11", only: :test}` —
correctly test-scoped, matches the sign-off's own claim. `mix.lock` pins
`yaml_elixir 2.12.2` / `yamerl 0.10.0`.

**AC8 (mix test / mix compile --warnings-as-errors both pass) — MET, independently
re-run, not copied from TEST-RUNNER's report.**

```
$ mix compile --warnings-as-errors --force
Compiling 180 files (.ex)
Generated letflow app
$ mix format --check-formatted
(no output, exit 0)
$ bash scripts/test_parallel.sh
partition 1: 373 tests, 0 properties, 0 failures, exit 0
partition 2: 393 tests, 0 properties, 0 failures, exit 0
partition 3: 421 tests, 2 properties, 2 failures, exit 2
partition 4: 491 tests, 0 properties, 0 failures, exit 0
partition 5: 345 tests, 2 properties, 0 failures, exit 0
partition 6: 311 tests, 0 properties, 0 failures, exit 0
partition 7: 316 tests, 0 properties, 0 failures, exit 0
partition 8: 331 tests, 2 properties, 0 failures, exit 0
---
combined: 2981 tests, 6 properties, 2 failures (2985/2987 passed)
```

The 2 failures are both in partition 3, both
`Mix.Tasks.Letflow.CheckToolchainTest` ("a mismatched rust pin reports a MISMATCH
row..." / "a matching rust pin reports OK..."), both `** (ErlangError) Erlang
error: :enoent` from `System.cmd("rustc", ["--version"], ...)` — confirmed by
reading the actual failure stack trace myself: `rustc` is not on `PATH` in this
sandbox. Pre-existing, environmental, unrelated to REQ-205 — matches TEST-RUNNER's
own step-04 report exactly, independently reproduced rather than copied.
(Note: a first attempt at this re-run was contaminated by my own mistake — I
started a second concurrent `test_parallel.sh` invocation while the first was
still running in the background after a tool timeout, and the resulting resource
contention on Postgres produced 29 unrelated failures and 2 crashed partitions in
that second, overlapping run. That run's output is discarded; the clean, single,
non-overlapping run quoted above is the one that counts.)

## Audit_event fix — independently re-verified (not just re-read the claim)

Read `test/support/simulation/runner.ex`'s current `verify_outcome/2` `:audit_event`
clause (lines 504–525) directly: it now takes `produces` (not `_produces`) and
calls `resolve_optional_ref/3` for both `resource_id` and `resource_type` before
building the `Audit.list_entries/1` query. `resolve_optional_ref/3` (lines
546–553) returns `{:ok, nil}` only when the key is *absent* from `args` — when
present, it always runs the value through `substitute_templates/2`
(`resolve_ref/3`'s own substitution path), which fails closed
(`{:error, {:unresolved_template, ...}}`) on any `{{produces.X}}` reference that
doesn't resolve against the real `produces` map — confirmed by reading
`resolve_dotted_path/2`'s `:error` branch directly. This is a real fix, not a
partial one: an audit_event outcome with an unresolvable template reference now
fails the outcome rather than silently sending the literal template string (or a
`nil`) to the query. `test/letflow/simulation/runner_template_and_outcomes_test.exs`
exercises this against real Postgres — included in the 25-passed run above.

## Handoff-schema note carried forward from TEST-RUNNER

TEST-RUNNER's step-04 handoff flagged 6 sibling files in this run
(`step-02a-elixir-dev(.json/-rework1)`, `step-02c-security-reviewer`,
`step-02d-reviewer(.json/-recheck1)`, `step-03-test-designer`,
`step-03b-test-design-validator`) as carrying non-schema flat `context`/`notes`
shapes instead of `task`/`result` blocks. Confirmed still present — not a blocker
for this gate (content was independently verifiable regardless of shape) but
re-flagged here for ORCH, since correcting historical handoff files retroactively
is out of scope for RELEASE-VALIDATOR too.

## Summary

| AC | Verdict |
|----|---------|
| AC1 | Accepted with recorded caveat — content NOT ported from real R-Co (synthetic, disclosed), structure/mechanism/test fully met. Follow-up task recommended, should gate REQ-206. |
| AC2 | MET |
| AC3 | MET |
| AC4 | MET |
| AC5 | MET |
| AC6 | MET |
| AC7 | MET |
| AC8 | MET |

**Overall: PASS, with AC1's caveat explicitly recorded for DOC-UPDATER.** Routing
to DOC-UPDATER (Step 6).
