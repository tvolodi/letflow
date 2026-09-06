# REQ-205 — S7 scenario-harness foundation: Elixir scenario runner, fixture seeding, API-vs-GUI split

**Requirement:** REQ-205. First requirement of S7 (`docs/migration/stage-7-simulation-uat-parity.md`).
**Stage:** S7
**Owner (design):** CODE-DESIGNER — **Owner (implementation):** ELIXIR-DEV
**Date:** 2026-08-31
**Scope discipline:** this is a test-execution tool. No scenario content (REQ-206/
207/208), no differential corpus (REQ-209), no stage report (REQ-210), no
advance-timer endpoint, no `Letflow.Routers.SimulationTest`. Everything below stays
inside `test/fixtures/simulation/` and `test/support/simulation/` (test-only code —
not `lib/letflow/`, since none of this is production functionality; see §9 for why
this still gets a `lib/letflow/design/` doc under this project's convention).

---

## §0 — Verified source-of-truth facts (not assumed)

- `mix.exs` `deps/0` (read in full this session) has **no YAML-parsing library**,
  direct or transitive — `mix.lock`/`deps()` list is `ecto_sql`, `postgrex`, `plug`,
  `bandit`, `jason`, `telemetry`, `stream_data` (test-only), `ueberauth_oidcc`, `lua`,
  `wasmex`. None parses YAML. §4 below names the dependency to add.
- PROVENANCE (historical, not current decision authority):
  `lib/letflow/router.ex`'s own router-inventory table (read this session, lines
  ~73-83) lists `Letflow.Routers.SimulationTest | simulation_test.zig | S7 (simulation
  harness)` as a **reserved, unbuilt** slot — confirming Decision 3's boundary is
  real, not a hypothetical: that table row is exactly what must NOT be filled by this
  requirement.
- Router modules the requirement cites are real, confirmed by reading
  `lib/letflow/routers/*.ex` directly this session:
  - `Letflow.Routers.Onboarding` — mounted at `/api/v1/onboarding`, `POST /`
    (`handle_create/1`) is the tenant-creation entry point company.yaml seeding uses.
  - `Letflow.Routers.Tenants` — mounted separately, REQ-076 confirms Onboarding's
    `POST /` is the one tenant-provisioning path (not `Tenants`'s own `POST /`,
    which is the direct/internal creation path); Seed uses the same context
    function (`Letflow.Identity.create_tenant/1` plus
    `Letflow.TenantOnboarding.provision_and_migrate/1`), never HTTP, per Decision 1.
  - `Letflow.Routers.Identity` — mounted at `/api/v1/identity`, exposes
    `POST /users`, `POST /groups`, `POST /groups/:id/members` — confirms the
    user/group admin endpoints seed.py hit map onto `Letflow.Identity.create_user/2`,
    `Letflow.Identity.create_group/2`, `Letflow.Identity.add_group_member/3` directly
    (all confirmed present with `@spec`s in `lib/letflow/identity.ex`, read this
    session).
  - `Letflow.Routers.Definitions` — real module; backing context functions
    `Letflow.Definitions.create/2` and `Letflow.Definitions.activate/2` confirmed
    present with `@spec`s in `lib/letflow/definitions.ex`, read this session.
  - `Letflow.Engine.create/2` confirmed present (`lib/letflow/engine.ex`) as the
    context function that starts a process instance — this is the function
    `api`-via steps that launch a new instance ultimately reach (through the real
    HTTP path, not called directly by the Runner — see §3).
- This repo's **existing router-test convention** (confirmed by reading
  `test/letflow/routers/req078_supporting_routes_test.exs`'s moduledoc and body,
  and the sibling `tenants_test.exs`/`identity_test.exs` it cites) is: `import
  Plug.Test`, build a `conn` with `Plug.Test.conn/2`, dispatch it through the real
  `Plug.Router` module (either `Letflow.Router.call/2` for cross-cutting concerns,
  or a sub-router's own `.call/2` with `conn.assigns.auth_context` set by hand) —
  never a mocked handler, always real `Plug.Router` match/dispatch plus a real
  backing context call against real Postgres (`Letflow.DataCase`, `async: false`
  for the tenant-provisioning-heavy suites). This is "the same HTTP client helper
  this repo's existing router tests use" Decision 3 refers to — there is no
  separate socket-level HTTP client module in `test/support/` for *inbound* calls
  (the one HTTP-related test-support module, `test/support/webhook_test_server.ex`,
  is for *outbound* webhook delivery, REQ-183, an unrelated direction). §3 below
  specifies this precisely as the mechanism `Letflow.Simulation.Runner` reuses.
- No prior `lib/letflow/design/*.md` in this session designs a test-support-only
  module under the same `lib/letflow/design/` directory this project uses for
  production designs — `req183-webhook-delivery-dispatch.md` designs production
  code (`Letflow.Webhooks.deliver/3`) and separately documents
  `test/support/webhook_test_server.ex` inline in that file's own text (not a
  separate design doc), and `test/support/webhook_test_server.ex` itself carries
  a full rationale moduledoc in the source file. Convention observed: test-support
  modules get their design folded into the design doc of the requirement that
  needs them (same `lib/letflow/design/` directory, same filename-per-requirement
  pattern — no separate `test/support/design/` directory exists in this repo).
  This doc follows that convention: one design doc,
  `lib/letflow/design/req205-simulation-harness-foundation.md`, covering all of
  `Letflow.Simulation.Seed`, `Letflow.Simulation.Runner`, and the fixture port,
  even though none of it lands under `lib/letflow/`.

---

## §1 — Fixture porting (AC1)

**Target layout** (test-only fixture data, not compiled code):

```
test/fixtures/simulation/swiftroute/company.yaml
test/fixtures/simulation/swiftroute/org_structure.yaml
test/fixtures/simulation/swiftroute/process_*.yaml   (N files, per R-Co's actual count)
test/fixtures/simulation/vortex/company.yaml
test/fixtures/simulation/vortex/org_structure.yaml
test/fixtures/simulation/vortex/process_*.yaml
test/fixtures/simulation/meridian/company.yaml
test/fixtures/simulation/meridian/org_structure.yaml
test/fixtures/simulation/meridian/process_*.yaml
```

Exactly 12 files total across the three directories (per R-Co's
`tests/simulation/companies/{swiftroute,vortex,meridian}/`), ported byte-for-byte
in content — field names, key ordering conventions, and every `actor_id` value
(e.g. `actor-swiftroute-lena`) copied verbatim, no re-keying, no re-formatting. No
transformation step of any kind runs on this data at port time; the only thing
that changes is file location (R-Co's `tests/simulation/companies/` tree ->
Letflow's `test/fixtures/simulation/` tree). This is a **file copy**, not a
generation step — there is no script this design specifies to produce these
files, because none should exist; they are committed static test data, same
status as any other file under `test/fixtures/`.

**Verification (AC1's "diff-style comparison test")**: a test module (e.g.
`test/fixtures/simulation/fixture_parity_test.exs`) that, for each of the 12
ported files, reads the Letflow copy and asserts a fixed list of load-bearing
scalar fields (every `actor_id`, every `slug`/`hostname`, every process `name`/
`key`) match a hardcoded expected value transcribed from the R-Co original at
port time. This test does not require R-Co's source tree to be present at test
run time (CI has no access to `c:\Users\tvolo\dev\ai-dala\R-Co\`) — the expected
values are inlined as literals in the test module itself, established once at
port time by direct comparison against the R-Co original.

---

## §2 — `Letflow.Simulation.Seed` (test-support module)

Location: `test/support/simulation/seed.ex`. Compiled only in `:test`
(`elixirc_paths(:test)` already includes `test/support` — no `mix.exs` change
needed here). One function per `seed.py` responsibility, per Decision 1.

### 2.1 `seed_company/1`

```
@spec seed_company(company_fixture :: map()) ::
        {:ok, %{tenant: Letflow.Identity.Tenant.t(), onboarding: Letflow.Identity.OnboardingRecord.t()}}
        | {:error, term()}
```

- Input: the parsed `company.yaml` map (post-YAML-decode, pre-any-transform —
  same key names as the fixture file: at minimum a hostname/slug and a company
  display name, per R-Co's `company.yaml` shape).
- Calls, in order: `Letflow.Identity.create_tenant/1` (tenant row), then
  `Letflow.TenantOnboarding.provision_and_migrate/1` (schema provisioning +
  migration replay — the identical sequence `Letflow.Routers.Onboarding`'s own
  `POST /` handler uses, per §0's confirmed moduledoc), then
  `Letflow.Identity.create_onboarding/1` (onboarding record). No HTTP call, no
  `Letflow.Routers.Onboarding` invocation of any kind — the context functions
  directly, matching AC2's "no HTTP client" wording exactly.
- **Idempotency mechanism**: before calling `create_tenant/1`, look up the
  tenant by the fixture's slug/hostname via `Letflow.Identity.get_tenant_by_slug/1`
  (already `@spec`'d, confirmed present). If `{:ok, tenant}` is returned, treat
  the company as already seeded: skip `create_tenant/1` and
  `provision_and_migrate/1` entirely (schema provisioning is not safely
  re-runnable — replaying migrations against an already-migrated schema is the
  hazard this avoids) and re-fetch/return the existing onboarding record via
  `Letflow.Identity.get_onboarding_by_hostname/1` (also confirmed present) if one
  exists, otherwise create it (an onboarding row missing under an existing
  tenant is not treated as an error — it is completed, not duplicated). If
  `get_tenant_by_slug/1` returns `{:error, :not_found}`, the full three-call
  sequence above runs. Returns `{:ok, %{tenant: ..., onboarding: ...}}` in both
  the fresh-seed and already-seeded branches — the caller cannot distinguish
  "just created" from "already existed" from the return shape, matching
  seed.py's documented "409 means already exists, left unchanged" contract
  (a no-op is functionally identical to a fresh success from the caller's
  point of view).

### 2.2 `seed_users/2`

```
@spec seed_users(org_structure_fixture :: map(), tenant :: Letflow.Identity.Tenant.t()) ::
        {:ok, [Letflow.Identity.User.t()]} | {:error, term()}
```

- Input: the parsed `org_structure.yaml` map's people list, plus the tenant
  record `seed_company/1` returned (supplies the `opts` prefix — every
  `Letflow.Identity` call in this module takes `opts :: [prefix: String.t()]`
  scoped to the tenant's own Postgres schema, matching every other context
  module's `opts()` convention observed in `lib/letflow/identity.ex`).
- For each person entry, calls `Letflow.Identity.create_user/2` with
  `[prefix: tenant.schema_name]` (or the equivalent field `Tenant.t()` exposes —
  resolved by ELIXIR-DEV against the real `Tenant` schema, not re-derived here).
- **Idempotency mechanism**: before each `create_user/2` call, look up the user
  by the fixture's username/`actor_id`-derived username via
  `Letflow.Identity.get_by_username/2` (confirmed present in
  `lib/letflow/identity.ex`). If found, skip creation and use the existing
  record. If `create_user/2` itself still races and returns the changeset's
  `username_unique_conflict?/1` error (also confirmed present — the same
  detection helper `Letflow.Identity.create_user/2`'s own conflict branch
  already uses), treat that as the equivalent already-exists case (re-fetch via
  `get_by_username/2` rather than propagating the error) — this is the same
  belt-and-suspenders shape as `seed_company/1`'s pre-check, needed because a
  bare pre-check has an unavoidable TOCTOU gap under concurrent test runs.
- Returns `{:ok, [user, ...]}` (fresh or pre-existing, uniformly) in the order
  the fixture lists them, so `seed_groups/2` can resolve member references by
  index/username.

### 2.3 `seed_groups/2`

```
@spec seed_groups(org_structure_fixture :: map(), tenant :: Letflow.Identity.Tenant.t()) ::
        {:ok, [Letflow.Identity.Group.t()]} | {:error, term()}
```

- Input: the same `org_structure.yaml` map's group/team definitions (group name
  plus member `actor_id`/username references), plus `tenant`.
- For each group entry: idempotency mechanism mirrors §2.2 — `list_groups/1`
  (re-read directly this session at `lib/letflow/identity.ex:527-537`) takes
  only `opts :: [prefix: String.t()]`, builds
  `from(g in Group, order_by: [asc: g.name])` with no name/filter clause of
  any kind, and returns `{:ok, %{groups: [...], total: ...}}` — the tenant's
  full, unpaginated group list. There is no server-side by-name lookup to
  call. `seed_groups/2` therefore lists ALL of the tenant's groups via
  `list_groups/1` and matches the fixture's group name **client-side**
  (`Enum.find/2` on `groups` by `name ==`) to decide whether a same-name
  group already exists — this is the settled mechanism, not a pending
  question. If a match is found, skip `create_group/2` for that entry. If
  `create_group/2` still races, its own confirmed
  `duplicate_group_name` conflict branch (seen at
  `lib/letflow/routers/identity.ex:437-438`'s handler, backed by
  `Letflow.Identity.group_name_unique_conflict?/1`) is treated as
  already-exists, re-fetched via the same by-name lookup rather than
  propagated.
- After each group resolves (fresh or existing), calls
  `Letflow.Identity.add_group_member/3` once per member reference resolved
  against `seed_users/2`'s returned list by username. `add_group_member/3`'s
  own idempotency is reused as-is (its `@spec` at `lib/letflow/identity.ex:498`
  already returns a created?-flag-style result per
  `lib/letflow/routers/identity.ex:491`'s `created?` usage — adding an
  already-present member is itself a documented no-op at the context-function
  level, so `seed_groups/2` does not need its own extra pre-check here, only
  for the group row itself).
- Returns `{:ok, [group, ...]}`.

### 2.4 `seed_process/1`

```
@spec seed_process(process_fixture :: map()) ::
        {:ok, Letflow.Definitions.Definition.t()} | {:error, term()}
```

- Input: one parsed `process_*.yaml` map (process definition body plus its
  `name`/`key`).
- **Idempotency mechanism**: before calling `Letflow.Definitions.create/2`,
  look up via `Letflow.Definitions.get_active_by_name/2` (confirmed present,
  `lib/letflow/definitions.ex:575`). If an active definition with that name
  already exists, skip creation and activation entirely and return it as-is —
  re-creating a same-named process definition is exactly the class of
  duplicate seed.py's 409 contract guards against. If not found, calls
  `Letflow.Definitions.create/2` then `Letflow.Definitions.activate/2`
  (confirmed present, `lib/letflow/definitions.ex:726`) to bring it to the
  same active state seed.py's POST-then-activate sequence produces.
- Returns `{:ok, definition}` in both branches.

### 2.5 Idempotency test coverage (AC3)

Four explicit tests, one per entity kind, each seeding the same company twice
in one test run (`Letflow.DataCase`, real Postgres) and asserting: (a) no
`{:error, _}` tuple is returned on the second call for that entity kind, and
(b) the entity count for that kind (tenant count by slug, user count by
username, group count by name, definition count by name) is unchanged between
the first and second seed call — a direct DB row-count assertion, not an
inference from "no error was raised."

---

## §3 — `Letflow.Simulation.Runner` (test-support module)

Location: `test/support/simulation/runner.ex`.

### 3.1 Parsed-scenario struct — `Letflow.Simulation.Scenario`

`Letflow.Simulation.Scenario` is a plain struct (no Ecto schema, no
persistence — this is an in-memory parsed-fixture shape) with the following
fields:

| Field | Type | Meaning |
|---|---|---|
| `id` | `String.t()` | Scenario identifier, from the fixture's own `id` field. |
| `company_id` | `String.t()` | Which of the three seeded companies (swiftroute/vortex/meridian) this scenario runs against. |
| `process_id` | `String.t()` | The process definition name/key this scenario exercises. |
| `actors` | `%{optional(String.t()) => map()}` | Maps a scenario-local actor key (matching the fixture's `actor_id` convention, e.g. `"actor-swiftroute-lena"`) to whatever identity/credential data the api-via steps need to authenticate as that actor (resolved at implementation time against however `Letflow.Identity.create_token/3`-issued tokens get attached to a `Plug.Test` conn's `Authorization` header — same mechanism REQ-076's token work already exposes; not re-derived here since it is settled elsewhere). |
| `preconditions` | `[precondition()]` | List of precondition sub-shapes, see below. Evaluated in list order before any step runs (§3.3 step 1). |
| `steps` | `[step()]` | List of step sub-shapes, see below. Executed in declared order (§3.3 steps 2-3). |
| `expected_outcomes` | `[expected_outcome()]` | List of expected-outcome sub-shapes, see below. Verified after all steps run (§3.3 step 4). |

**`step()` sub-shape** — one entry of `steps`:

| Field | Type | Meaning |
|---|---|---|
| `via` | `:api \| :gui` (required) | Dispatch mechanism — `:api` runs the step through the real HTTP stack (§3.3 step 2), `:gui` is recorded `:deferred_to_s8` and never executed (§3.3 step 3, Decision 2). |
| `action` | `String.t()` (required) | An HTTP method+path descriptor for `via: :api` steps, e.g. `"POST /api/v1/instances"`. |
| `params` | `map()` (optional) | Request body/parameters, subject to `{{produces.X}}` template substitution (§5) before dispatch. |
| `produces` | `String.t()` (optional) | Name under which this step's response body is stored in the accumulated `produces` map, for later steps'/outcomes' template references. |

**`precondition()` sub-shape** — one entry of `preconditions`:

| Field | Type | Meaning |
|---|---|---|
| `check` | `:process_definition_active \| :no_pending_instances \| :custom` (required) | Which of §3.3 step 1's three real-query checks to run. |
| `args` | `map()` (optional) | Check-specific arguments (e.g. the definition name for `:process_definition_active`, the predicate name for `:custom`). |

**`expected_outcome()` sub-shape** — one entry of `expected_outcomes`:

| Field | Type | Meaning |
|---|---|---|
| `verification` | `%{method: :task_assigned \| :instance_state \| :audit_event, args: map()}` (required) | `method` selects one of §6's three real-query verification implementations; `args` supplies that method's check-specific parameters (e.g. an instance reference and expected status for `instance_state`). |

### 3.2 `run/1` and its result shape

```
@spec run(scenario :: Letflow.Simulation.Scenario.t()) ::
        {:ok, Letflow.Simulation.RunReport.t()} | {:error, term()}
```

`Letflow.Simulation.RunReport` is likewise a plain struct (no Ecto schema —
an in-memory run-result shape) with the following fields:

| Field | Type | Meaning |
|---|---|---|
| `scenario_id` | `String.t()` | Echoes the run scenario's `id`. |
| `precondition_results` | `[%{precondition: term(), outcome: :ok \| :error, detail: term()}]` | One entry per evaluated precondition, in list order; empty if a precondition failed and halted the run before steps executed (§3.3 step 1). |
| `step_results` | `[step_result()]` | One entry per step, see below. |
| `outcome_results` | `[outcome_result()]` | One entry per expected outcome, see below. |

**`step_result()` sub-shape** — one entry of `step_results`:

| Field | Type | Meaning |
|---|---|---|
| `step` | `Scenario`'s `step()` shape | The step this result corresponds to, echoed back. |
| `outcome` | `:ok \| :error \| :deferred_to_s8` | `:ok`/`:error` for executed `via: :api` steps; `:deferred_to_s8` for `via: :gui` steps, always (§3.3 step 3). |
| `captured` | `map() \| nil` | This step's `produces` output, if any; `nil` for steps with no `produces` field or steps that errored/deferred. |
| `detail` | `term()` | Free-form diagnostic detail — the response body on error, or the deferral message for `:deferred_to_s8` (§3.3 step 3). |

**`outcome_result()` sub-shape** — one entry of `outcome_results`:

| Field | Type | Meaning |
|---|---|---|
| `expected_outcome` | `Scenario`'s `expected_outcome()` shape | The expected outcome this result corresponds to, echoed back. |
| `outcome` | `:pass \| :fail` | Result of §6's verification method for this outcome. |
| `observed` | `term()` | The actual queried state compared against — never inferred from the absence of a step error (§6). |

### 3.3 Execution algorithm (Decision 3, in order)

1. **Preconditions** — for each `precondition()` in `scenario.preconditions`,
   in list order:
   - `:process_definition_active` — real query via
     `Letflow.Definitions.get_active_by_name/2` (or `get_by_id/2`, per the
     precondition's `args`), asserting `status == :active`. Not a stub: a
     definition that exists but is `:deprecated`/`:archived` fails this check.
   - `:no_pending_instances` — real query via
     `Letflow.Engine.count_instances_by_status/1` (confirmed `@spec`'d,
     `lib/letflow/engine.ex:3554`) scoped to the scenario's `process_id` and
     tenant prefix, asserting the pending/running count is `0`.
   - `:custom` — a scenario-supplied predicate name resolved against a fixed
     registry of named predicate functions this module exposes (no arbitrary
     code execution from YAML content — the registry is closed, predicate
     names not in it fail loudly with `{:error, {:unknown_custom_precondition, name}}`
     rather than silently passing).
   A failed precondition halts the run before any step executes and the
   report's `step_results`/`outcome_results` stay empty — this is a setup
   failure, not a scenario failure, and is reported as such.

2. **API-via steps, in declared order** — for each `step()` where
   `via == :api`:
   - Build a `Plug.Test.conn/2` request for `step.action` (an HTTP
     method+path descriptor, e.g. `"POST /api/v1/instances"`) with
     `step.params` as the body, after **template substitution** (§5) resolves
     every `{{produces.X}}` reference in `step.params` against prior steps'
     `captured` maps.
   - Dispatch it through `Letflow.Router.call/2` against the real, running
     application (the same Bandit-backed `Letflow.Application` supervision
     tree a `mix test` run already starts, not a separately spawned process) —
     this satisfies AC4's "real HTTP through Letflow.Router, not a mocked
     handler" using this repo's own established router-test dispatch
     convention (§0), scoped up from a single sub-router's `.call/2` (as
     `req078_supporting_routes_test.exs` uses for five of its six modules) to
     the top-level `Letflow.Router.call/2` (as that same test file uses for
     its sixth, cross-cutting case) because a scenario step's whole point is
     exercising the full stack including `Letflow.Plugs.AuthPipeline`, not a
     handler in isolation.
   - The response body, if `step.produces` is set, is stored as that step's
     `captured` map for later steps'/outcomes' template references.
   - A non-2xx response is recorded as `outcome: :error` on that step's
     `step_result` — this halts remaining steps in the scenario (a scenario
     is a sequence; a failed step invalidates the rest) but the run itself
     still proceeds to build and return a `RunReport` rather than raising.

3. **GUI-via steps** — for each `step()` where `via == :gui`, in declared
   order interleaved with the api-via steps exactly as the scenario lists
   them (not reordered to "all api then all gui"): recorded immediately as
   `outcome: :deferred_to_s8`, `captured: nil`, `detail: "S8 frontend
   integration not started; see docs/migration/stage-7-simulation-uat-parity.md"`.
   No HTTP call, no Playwright invocation, no attempt to approximate the step
   as an api call — Decision 2 forbids both silent-skip and force-run. If a
   later api-via step's `params` contains a `{{produces.X}}` reference to a
   gui-via step's (nonexistent) `captured` output, template substitution
   fails closed (`{:error, {:unresolved_template, "produces.X"}}`) rather than
   substituting a placeholder — a scenario that structurally depends on a
   deferred step's output cannot produce a real answer, and REQ-206/207/208
   own the finding-level narrative for which scenarios hit this.

4. **Expected outcomes** — for each `expected_outcome()` in
   `scenario.expected_outcomes`, in list order, dispatched by
   `verification.method` to §6's three real-query implementations. Each
   produces an `outcome_result()` with `outcome: :pass | :fail` and the actual
   `observed` state — never inferred from the absence of a step error.

`run/1` returns `{:ok, report}` whenever it completes preconditions-through-
outcomes without an unhandled exception (a scenario with failing steps or
failing outcomes is still `{:ok, report}` — the report's contents carry the
pass/fail information; `{:error, _}` is reserved for the harness itself
malfunctioning, e.g. an unknown custom precondition or an unresolved
template).

---

## §4 — YAML-parsing dependency decision

**Confirmed**: no YAML-parsing library exists in `mix.exs`/`mix.lock`, direct or
transitive (checked this session, §0). One must be added.

**Choice: `{:yaml_elixir, "~> 2.11"}`** — pure-Elixir wrapper (via `:yamerl`) for
YAML 1.1 parsing, actively maintained, no native/NIF compilation (unlike the
`wasmex`/`lua` precedent in `mix.exs`, this adds zero build-toolchain surface —
simpler than either REQ-148 or REQ-165's dependency, not more), and it is the
de facto standard choice for this need in the Elixir ecosystem (used widely for
exactly this "parse a static YAML fixture file" case). Scope: **test-only**
dependency — `{:yaml_elixir, "~> 2.11", only: :test}` in `mix.exs` `deps/0`,
since nothing under `lib/letflow/` (production code) ever parses YAML; this
mirrors `stream_data`'s existing `only: :test` entry, not `wasmex`/`lua`'s
unconditional entries (those are runtime engine dependencies; this is a test
fixture concern only).

**REVIEWER sign-off required** (AC7), following REQ-148/REQ-165's own precedent
of a dedicated "why this dependency" section justified against alternatives
considered and rejected:
- `:yamerl` directly (rejected — lower-level Erlang API, `yaml_elixir` already
  wraps it with a friendlier `read_from_file/1` returning plain maps, no reason
  to hand-roll that wrapping ourselves).
- Hand-writing a minimal YAML subset parser (rejected — R-Co's own fixture
  files use standard YAML constructs; a hand-rolled parser is exactly the kind
  of scope creep this requirement's own boundary section forbids, and this is
  a test-only surface where dependency weight is not a production concern the
  way `wasmex`'s native-build hazard was).

This design does not itself grant sign-off — it flags the addition for
REVIEWER per AC7's explicit requirement, same procedural split REQ-165's
design used (CODE-DESIGNER names and justifies the dependency; REVIEWER signs
off before merge; the sign-off record lives in the PR, not in this file).

---

## §5 — `{{produces.X}}` template substitution

Mechanism: a scenario step's `params` map (post-YAML-decode) is walked
recursively (Enum over map values / list elements); any string value matching
the pattern `{{produces.<name>}}` in its entirety, or containing it as a
substring (both forms supported, since R-Co's YAML fixtures may embed a
produced id inside a larger string, e.g. a URL path), is replaced by looking
up `<name>` in an accumulated `produces` map built from every prior api-via
step's `captured` output keyed by that step's own `produces` field (e.g. step
1 declares `produces: "tenant"` and stores its response body under
`produces["tenant"]`; step 2's `params` containing `"{{produces.tenant.id}}"`
resolves via a dotted-path lookup into that stored map, e.g.
`produces["tenant"]["id"]`). Lookup failure (unknown `produces` key, or a
dotted path that doesn't resolve against the stored map's actual shape) is
`{:error, {:unresolved_template, dotted_path}}`, propagated up through step
execution as a step-level `:error` outcome, never silently substituting `nil`
or the literal template string.

---

## §6 — Expected-outcome verification methods (§3.4, AC4)

All three query real, already-persisted state — none accepts "no error was
raised" as a substitute, matching the forbidden-pattern rule
`.claude/agents/uat-runner.md` states explicitly under "Forbidden": *"Don't
record PASS on the absence of an error; confirm the expected state was
actually reached."* Decision 3 cites this rule by path and this design follows
it identically, not as an analogy.

- **`task_assigned`** — `args` names a task's scenario-local reference (via a
  prior step's `produces` capture, template-resolved same as §5) and an
  expected assignee `actor_id`. Queries real state via
  `Letflow.Engine`'s task-lookup path (the same context function
  `Letflow.Routers.Tasks` uses to read a task, resolved by ELIXIR-DEV against
  its actual name/arity) and asserts the persisted `assignee`/`assigned_to`
  field equals the expected actor's resolved user id — a real row read, not an
  inference from the assignment step having returned 2xx.
- **`instance_state`** — `args` names an instance reference and an expected
  `status` (and optionally a `variables` sub-map to check). Queries real state
  via `Letflow.Engine`'s instance-lookup path against the live Postgres row,
  asserting the persisted status/variables match. This is AC4's required
  minimum-one-outcome method for the minimal one-step scenario test.
- **`audit_event`** — `args` names an expected audit event type and a scoping
  reference (instance/task id). Queries real state via `Letflow.Routers.Audit`'s
  backing context function (real query against the audit log table), asserting
  at least one matching row exists with the expected `event_type` and
  scoping id.

Each method returns `{:pass, observed}` or `{:fail, observed}` where `observed`
is the actual queried value(s), stored verbatim in the `RunReport` so a failed
outcome is diagnosable from the report alone.

---

## §7 — Moduledoc content (AC6)

`Letflow.Simulation.Runner`'s moduledoc must state, verbatim in substance:

1. This module executes REQ-206/207/208's business-scenario YAML corpus
   against a real running Letflow instance (api-via steps) or records
   `DEFERRED_TO_S8` (gui-via steps) — it is a **test-execution harness**, built
   by REQ-205, the correctness gate over S4/S5/S6's combined output.
2. PROVENANCE (historical, not current decision authority):
   This is explicitly **NOT** `simulation_test.zig`/`scenario_runner.zig`'s
   mechanism. Cite both R-Co paths by path:
   `src/api/routes/simulation_test.zig` and `src/simulation/scenario_runner.zig`.
   State the actual distinction confirmed by reading both files: that
   subsystem is a **design-time dry-run tool** validating a candidate process
   *definition* against a schema+event-trace assertion set (`POST
   /simulation/validate`, `POST /simulation/run`, permission-gated
   `simulation:validate`/`simulation:run`) — a different input shape (a
   definition, not a business scenario), a different caller (a definition
   author, not a test harness), and a different question answered ("is this
   definition well-formed" vs. "does the running platform behave correctly
   for this business scenario").
3. `Letflow.Router` reserves a route slot for that subsystem
   (`Letflow.Routers.SimulationTest`, per `lib/letflow/router.ex`'s own
   router-inventory table) — **this requirement does not build that router**,
   does not fill that slot, and nothing in this module's execution path
   touches it.

---

## §8 — Acceptance-criteria-to-design-element map

PROVENANCE (historical, not current decision authority):

| AC | Design element |
|---|---|
| AC1 (12 YAML files ported verbatim, actor_ids unchanged, diff-style test) | §1 — fixture layout + verbatim-copy rule + `fixture_parity_test.exs` |
| AC2 (Seed provisions via context modules directly, no HTTP/Python, verified by querying Identity/Definitions) | §2.1-2.4 (`seed_company/1`, `seed_users/2`, `seed_groups/2`, `seed_process/1`, each naming its real context-function calls) |
| AC3 (double-seed is a no-op per entity kind, one test each) | §2.1-2.4's idempotency mechanisms + §2.5's four explicit tests |
| AC4 (Runner executes a minimal one-step api-via scenario against a real running instance, real HTTP through Letflow.Router, verifies >=1 instance_state outcome by real query) | §3.2-3.3 (`run/1` algorithm step 2, dispatch via `Letflow.Router.call/2`) + §6's `instance_state` method |
| AC5 (a gui step is recorded DEFERRED_TO_S8, never silently skipped, never force-run as api) | §3.3 step 3 |
| AC6 (moduledoc distinguishes this from Letflow.Routers.SimulationTest/simulation_test.zig, cites both R-Co files, states this req doesn't build that router) | §7 |
| AC7 (YAML dep addition flagged for REVIEWER sign-off if added) | §4 |
| AC8 (mix test / mix compile --warnings-as-errors pass, real output quoted) | Implementation-phase obligation (ELIXIR-DEV/TEST-RUNNER) — no design-time element; noted here so it is not missed at handoff |

---

## §9 — Open questions (explicit, not silently resolved)

- **OQ-1**: `Tenant.t()`'s exact field name for the schema/prefix used in
  `opts: [prefix: ...]` calls (§2.2) is not re-derived here — ELIXIR-DEV must
  read `lib/letflow/identity/tenant.ex` (or wherever `Tenant` is defined) to
  confirm the field name before implementing `seed_users/2`/`seed_groups/2`.
- **(resolved, formerly OQ-2)**: `Letflow.Identity.list_groups/1`'s actual
  behavior — confirmed by reading its full body, not just its `@spec`, at
  `lib/letflow/identity.ex:527-537` — takes only `opts :: [prefix: ...]`,
  applies no name filter, and returns the tenant's full unpaginated group
  list. §2.3 states the settled consequence: `seed_groups/2` lists all
  groups and matches the fixture's group name client-side. No open question
  remains here.
- **OQ-2**: the exact HTTP method+path->context-function mapping for
  `Letflow.Engine`'s instance-creation and task-lookup endpoints (needed for
  `step.action` parsing in §3.3 and `task_assigned`/`instance_state` in §6) is
  not enumerated here field-by-field — ELIXIR-DEV resolves each specific
  scenario action against the real router modules as REQ-206/207/208's actual
  scenario content is ported (this requirement only specifies the *mechanism*
  of dispatch, not an exhaustive action table, since no scenario content
  exists yet in this requirement's scope).
- **OQ-3**: whether `yaml_elixir`'s YAML 1.1 parsing round-trips every scalar
  type R-Co's fixture files actually use (e.g. YAML's `on`/`off`/`yes`/`no`
  boolean coercion quirks) without silently mis-typing a field is not verified
  in this session — flagged for ELIXIR-DEV to confirm against the real ported
  fixture content during implementation, not assumed safe here.
