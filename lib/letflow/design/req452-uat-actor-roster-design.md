# REQ-452 -- Design: UAT actor roster, `expect_refusal` step key, rules SCHEMA-7..12

Stage S7. Owner of the build: ELIXIR-DEV. Status: design only (no implementation code).
Depends on REQ-445 (`docs/roles.md`). Run: `WF02-REQ452-20261006`.

Extends `lib/mix/tasks/letflow.check_uat_scenario_schema.ex` (REQ-358, rules SCHEMA-0..6; the
series ends at SCHEMA-6, so the new rules continue at SCHEMA-7). Scenario files are NOT edited:
29 of the 32 files under `test/fixtures/uat/scenarios/` carry a `Ported verbatim` header and must
stay byte-identical (the 3 without it: `bilimbaga/candidate-timed-exam-autograde.yaml`,
`platform/platform-login-routing-by-role.yaml`, `_throwaway/login-routing-example.yaml`). All
role information therefore lives in a separate roster file.

---

## 0. Premises verified in the worktree

- Corpus: 32 YAML files. Resolved scope = `scope:` if a non-empty string, else `company_id:`
  (SCHEMA-3 rule). Resolved scopes present today: `bilimbaga`, `meridian`, `platform`,
  `swiftroute`, `vortex` (five). `platform` comes from `company_id: platform` (18 files plus the
  two non-ported platform-scope files).
- Actors appear in a top-level `actors:` map (`alias: actor-id`, e.g. `tenant_admin:
  actor-swiftroute-alice`). Steps reference the alias (`actor: viewer`). Only `actors:` values are
  ids. No branch-level `actors:` exists.
- Login actors in the corpus today (by `grep -o 'actor-[a-z0-9-]*'`, excluding `actor-system-*`
  and `actor-any`): `actor-platform-admin`; `actor-bilimbaga-candidate`; meridian: ben, claudia,
  eva, julia, lars, marcus, miriam, sophie, thomas; swiftroute: alice, lena, marco, tobias;
  vortex: anna, felix, karl, nina, sabine, stefan (the ELIXIR-DEV step must re-derive this list by
  running the task's own extractor; this list is a cross-check, not the source).
  Note some ids (e.g. `actor-vortex-dirk` in `scripts/seed_vortex_persona_actors.sh`) appear in
  seed scripts but not in scenarios; they are NOT roster entries unless a scenario uses them.
- `actor-platform-admin` is used in 12 `platform/` scenarios (scope platform: fine) and in
  `swiftroute/tenant-onboarding-happy.yaml` (scope swiftroute: needs a `platform_actor_allowed`
  entry, reason "tenant onboarding").
- `Letflow.Api.Authorization.roles/0` returns atoms (`:PLATFORM_ADMIN` ...). Today six; after
  REQ-447/448 eight. The check must convert atoms to strings at check time and never hard-code.
- Seed evidence for the roster (ELIXIR-DEV reads these; nothing guessed):
  `scripts/seed_meridian_persona_actors.sh`, `seed_swiftroute_persona_actors.sh`,
  `seed_vortex_persona_actors.sh` (persona `"actor-x|role-y"` lines give `routing_roles`; header
  comments say persona accounts get TASK_WORKER implicitly; QA_AUTH_TOKEN is "a PLATFORM_ADMIN
  user in the <tenant> tenant" -- the legacy case of the open question), `scripts/uat_preflight.sh`
  (username matching), `priv/keycloak/realms/bpm-default.json` (the only realm file), and
  `scripts/seed_vortex_entities.sh`, `seed_*_definition.sh`.
- The task is slotted in the `letflow.check` alias BEFORE `compile`, but the new rule (b) needs
  `Letflow.Api.Authorization` loaded. See decision D1.

---

## 1. Roster file: `test/fixtures/uat/actors.yaml`

Outside `scenarios/**`, so the scenario glob does not pick it up. Top-level keys (all strings):

```yaml
actors:                                  # required, non-empty map; key = login actor id
  actor-platform-admin:
    tenant: platform                     # tenant slug, or literal "platform"
    builtin_roles: [PLATFORM_ADMIN]      # non-empty list of strings
    routing_roles: []                    # optional list of strings (process-routing role names)
    note: "free text"                    # optional string
  actor-swiftroute-alice:
    tenant: swiftroute
    builtin_roles: [PLATFORM_ADMIN]      # real current seed; see legacy_platform_admin
    routing_roles: [role-dispatcher]
    note: "..."
unresolved:                              # optional map; key = login actor id
  actor-vortex-felix:
    searched:                            # required non-empty list of strings: what was searched
      - "scripts/seed_vortex_persona_actors.sh: no builtin role line"
      - "priv/keycloak/realms/bpm-default.json: no such user"
platform_actor_allowed:                  # optional map; key = scenario top-level `id`
  swiftroute-tenant-onboarding-happy: "tenant onboarding is performed by the platform operator"
refusal_coverage_exempt: [bilimbaga, meridian, platform, swiftroute, vortex]   # optional list of scope strings
legacy_platform_admin:                   # optional map; key = actor id (open-question default)
  actor-swiftroute-alice:
    since: "2026-10-06"                  # ISO date the exemption was recorded
    reason: "no TENANT_ADMIN until REQ-447; REQ-454 empties this map"
    removed_by: REQ-454
```

Rules for the shape (violations are SCHEMA-12):
- `actors` missing, not a map, or empty.
- an actor entry: `tenant` not a non-empty string; `builtin_roles` not a non-empty list of
  non-empty strings; `routing_roles` present but not a list of non-empty strings; `note` present
  but not a string.
- an id appearing under both `actors` and `unresolved`; an `unresolved` entry with empty/missing
  `searched`.
- `platform_actor_allowed` value that is not a non-empty (after trim) string.
- `refusal_coverage_exempt` not a list of non-empty strings.
- a `legacy_platform_admin` entry: `since` not a valid ISO date (`Date.from_iso8601`), `reason`
  empty, `removed_by` missing; or its actor id is not in `actors`, does not hold PLATFORM_ADMIN, or
  has `tenant: platform` (a stale or pointless exemption). No clock-based expiry (keeps the check
  deterministic; REQ-454 is the removal mechanism).
- roster file missing, unreadable, unparseable, or not a map: one SCHEMA-12 violation whose `file`
  is the roster path; the task does not then run the cross-file rules (they would all be noise).

The "frozen initial exempt list" is NOT in the roster (a roster cannot police itself). Initial
content of `refusal_coverage_exempt`: every scope having at least one scenario and no step with
`expect_refusal: true` on the day of landing. Because no scenario can contain the new key today
(ported files are immutable; the two non-ported platform/bilimbaga files get none in this
requirement), that is all five scopes: `bilimbaga`, `meridian`, `platform`, `swiftroute`,
`vortex`.

---

## 2. Step key `expect_refusal`

Optional boolean on a step map, in flat `steps:` and in `branches[].steps`. `true` means the
named actor attempts the described action and the scenario passes only if the product refuses.
Prose in `action:` stays business language. Only the literal boolean `true` counts for rule (e);
a present value that is not a boolean is SCHEMA-12 (message: `step N: expect_refusal must be a
boolean`). Absent is valid and means false. UAT-RUNNER interpretation text is documented in the
schema doc (D6); no runner code change.

---

## 3. Module surface (additions to `Mix.Tasks.Letflow.CheckUatScenarioSchema`)

Existing public functions `run/1`, `check_file/1`, `check_scenario/2`, `render/1` keep their
names, arities and return types (existing tests must pass unchanged). `check_scenario/2` gains the
file-local SCHEMA-12 check for `expect_refusal` only. `file_result()` is NOT changed.

New module attributes (not public): `@roster_path "test/fixtures/uat/actors.yaml"`.

New types:
- `role_name :: String.t()`
- `actor_entry :: %{tenant: String.t(), builtin_roles: [role_name()], routing_roles: [String.t()], note: String.t() | nil}`
- `roster :: %{actors: %{String.t() => actor_entry()}, unresolved: %{String.t() => [String.t()]}, platform_actor_allowed: %{String.t() => String.t()}, refusal_coverage_exempt: [String.t()], legacy_platform_admin: %{String.t() => %{since: Date.t(), reason: String.t(), removed_by: String.t()}}}`
- `scenario :: {Path.t(), map()}` (path plus parsed data)
- `actor_stats :: %{login_actors: non_neg_integer(), in_roster: non_neg_integer(), unresolved: non_neg_integer(), missing: non_neg_integer()}`
- `report` gains an OPTIONAL key `actor_stats: actor_stats()`; `render/1` must tolerate its absence
  (existing report fixtures in tests lack it).

New public functions (all pure unless noted; `@spec`):

- `@spec known_role_names() :: [role_name()]` -- `Letflow.Api.Authorization.roles/0` atoms mapped
  with `Atom.to_string/1`. The only function touching `Authorization`; called by `run/1` and by
  tests that prove "follows roles/0" (D2). Everything else takes the list as a parameter.
- `@spec login_actor?(term()) :: boolean()` -- true iff a binary starting with `"actor-"`, not
  starting with `"actor-system-"`, and not exactly `"actor-any"`.
- `@spec login_actor_ids(map()) :: [String.t()]` -- sorted unique ids from the values of the
  top-level `actors:` map plus any step `actor:` value (flat and branch steps) that satisfies
  `login_actor?/1`. Non-map `actors:` yields only the step-derived ids (shape errors are other
  rules' business; never raises).
- `@spec resolve_scope(map()) :: String.t() | nil` -- `scope` if non-empty binary, else
  `company_id` if non-empty binary, else `nil` (same precedence SCHEMA-3 uses; extract and reuse
  it so the two cannot drift).
- `@spec has_refusal_step?(map()) :: boolean()` -- true iff any step in top-level `steps:` or in
  any `branches[].steps` has `"expect_refusal" => true`. Tolerates malformed shapes (false).
- `@spec read_roster(Path.t()) :: {:ok, roster()} | {:error, [violation()]}` -- parses and
  validates the shape per section 1; error list is SCHEMA-12 violations with `file` = roster path.
  Never raises on content; unreadable path (I/O) handled like parse failure (one SCHEMA-12), because
  a missing roster must be a clean violation, not a crash.
- `@spec check_roster(Path.t(), roster(), [role_name()]) :: [violation()]` -- rules SCHEMA-8 and
  SCHEMA-9 (roster-only, no scenarios needed).
- `@spec check_corpus([scenario()], Path.t(), roster(), [role_name()]) :: {[violation()], actor_stats()}`
  -- rules SCHEMA-7, SCHEMA-10, SCHEMA-11 (need scenarios + roster); returns the actor counts
  for the printout.
- `@spec check_paths([Path.t()], Path.t(), [role_name()]) :: report()` -- orchestrates: per-file
  `check_file/1` (existing), reads each parseable file once more for data (or reuses a shared
  private loader; double parse is acceptable, corpus is 32 small files), `read_roster/1`, then
  `check_roster/3` + `check_corpus/4` when the roster read succeeded; assembles the `report()`
  including the SCHEMA-0 empty-corpus case. Only files that parse as maps are fed to
  `check_corpus/4`. Pure of `Mix`; `run/1` and the live-corpus test both call it.
- `run/1` change: after D1 loading, `check_paths(paths, @roster_path, known_role_names())`,
  render, raise exactly as today (format `"[#{rule}] #{file}: #{message}"` unchanged).

---

## 4. Rules, tags and exact message formats

`violation` shape unchanged (`file`, `rule`, `message`); the printed line is
`[<RULE>] <file>: <message>`. Every message below names the rule (via the printed tag), the file
(the `file` field) and the actor or scope (inside the message). Sorting: violations are emitted
sorted by `{rule, file, message}` for deterministic output. One violation per distinct
(file, actor) / (actor, role) / scope; no duplicates when an actor appears twice in a file.

| Tag | AC rule | `file` field | Message |
|---|---|---|---|
| SCHEMA-7 | (a) | scenario path | `login actor "<actor>" has no entry in <roster path> under actors: or unresolved:` |
| SCHEMA-8 | (b) | roster path | `actor "<actor>" lists builtin_roles value "<role>" which is not in Authorization.roles/0 (<comma-separated known roles>)` |
| SCHEMA-9 | (c) | roster path | `actor "<actor>" has tenant "<tenant>" (not platform) but holds PLATFORM_ADMIN and is not listed under legacy_platform_admin` |
| SCHEMA-10 | (d) | scenario path | `platform actor "<actor>" appears in scenario "<scenario id>" whose resolved scope is "<scope>"; allowed only in scope platform or when the scenario id is listed in platform_actor_allowed with a non-empty reason` |
| SCHEMA-11 | (e) | first scenario path (sorted) of the scope | `resolved scope "<scope>" has <n> scenario(s) and none has a step with expect_refusal: true; add one or list "<scope>" under refusal_coverage_exempt` |
| SCHEMA-12 | structure | roster path, or scenario path for the step-key case | roster shape errors per section 1 (message names the actor/key), or `step <n>: expect_refusal must be a boolean` |

Semantics:
- (a): an id is covered if it is a key of `actors` or of `unresolved`. SCHEMA-7 never fires for
  `unresolved` ids; unresolved ids are exempt from (b)-(d) (no data).
- (b): for each actor and each `builtin_roles` entry compared as strings to `known_role_names/0`.
  Case-sensitive. Reads roles at check time, so REQ-447/448 need no edit here.
- (c): `tenant != "platform"` and `"PLATFORM_ADMIN" in builtin_roles` and actor not a key of
  `legacy_platform_admin`. A tenant-slug comparison is string equality; no tenant lookup.
- (d): for each scenario with a resolved scope S (skip if `nil`, SCHEMA-3 covers it) and each login
  actor in it that has a roster entry with `tenant == "platform"`: violation if `S != "platform"`
  and the scenario top-level `id` is not a key of `platform_actor_allowed` with non-empty reason.
  (An empty reason in the map is itself SCHEMA-12, so (d) fires again too; acceptable, both are
  real.)
- (e): group scenarios by `resolve_scope/1` (skip `nil`). For each scope with >= 1 scenario, fire
  unless some scenario in it satisfies `has_refusal_step?/1` or the scope is in
  `refusal_coverage_exempt`.

Interplay with the existing SCHEMA-4: nothing changes there; `expect_refusal` is inside steps.

---

## 5. Counts printed by the task

`render/1` adds, between the per-file lines and the summary line, when `actor_stats` is present:

`Actor roster: <roster path> -- <login_actors> login actor(s) in corpus: <in_roster> in roster, <unresolved> unresolved, <missing> missing`

`login_actors` = distinct login ids across all scenarios; `in_roster` = those that are keys of
`actors`; `unresolved` = those keys of `unresolved`; `missing` = the rest (each also a SCHEMA-7).
Always printed on a normal run (pass or fail) so AC1 ("the task prints the count of each") is
visible in `mix letflow.check` output. When the roster failed to load, the line reads
`Actor roster: <path> -- not loaded (see SCHEMA-12)`.

---

## 6. Test design (for TEST-DESIGNER; listed so every AC maps)

File: `test/mix/tasks/letflow_check_uat_scenario_schema_test.exs` (extend; existing tests untouched).
All new rule tests are hermetic: in-memory scenario maps and roster maps, `check_corpus/4`,
`check_roster/3`, passing an explicit role list such as `["PLATFORM_ADMIN","TASK_WORKER"]`.
Each builds ONE corpus that violates ONLY the rule under test and asserts: the violation rules
list equals exactly `[<that tag>]`, the `file` equals the expected path, and the message contains
the actor id (a-d) or the scope (e).

| AC | Test |
|---|---|
| (a) | T-SCHEMA-7: scenario names `actor-x-bob`, roster lacks it and `unresolved` lacks it; plus a negative: id listed only under `unresolved` passes |
| (b) | T-SCHEMA-8: roster role `"TENANT_BOSS"` not in the passed list; plus a test that calls `known_role_names/0` and asserts it equals `roles/0` atom strings (follows REQ-447/448) |
| (c) | T-SCHEMA-9: `tenant: acme` holding PLATFORM_ADMIN; negative: same actor listed under `legacy_platform_admin` passes; negative: `tenant: platform` passes |
| (d) | T-SCHEMA-10: platform actor in a scope-`acme` scenario; negative: scenario id in `platform_actor_allowed` with reason passes; negative: same actor in a scope-`platform` scenario passes |
| (e) | T-SCHEMA-11: scope with one scenario, no refusal, not exempt; negatives: with an `expect_refusal: true` step (flat and inside a branch) and when exempt |
| frozen list | T-EXEMPT-FROZEN: module attribute `@initial_refusal_exempt ~w(bilimbaga meridian platform swiftroute vortex)` in the test file; reads the real `actors.yaml` via `read_roster/1`; asserts `MapSet.subset?(roster exempt, frozen)` and, in a second test, that a fabricated exempt list containing an extra scope (`"newscope"`) makes the same assertion helper report a non-empty difference (proves the guard bites) |
| live corpus | T-LIVE-ROSTER: `check_paths(Path.wildcard(corpus glob), "test/fixtures/uat/actors.yaml", known_role_names())` returns zero violations; asserts `actor_stats.missing == 0` and `login_actors == in_roster + unresolved` |
| shape | T-SCHEMA-12 cases: missing roster file, empty `actors`, bad `since`, non-boolean `expect_refusal` |
| render | T-RENDER-COUNTS: `render/1` of a report with `actor_stats` contains the "Actor roster:" line with the three counts; render without the key still works |
| verbatim AC | not a unit test: release gate quotes `git diff --stat origin/main -- test/fixtures/uat/scenarios` (must print nothing); ELIXIR-DEV and RELEASE-VALIDATOR run it |

Compile/format/`mix letflow.check` acceptance is run, not designed.

---

## 7. Design decisions

- **D1 (loading `Authorization` before compile):** the alias slot is before `compile`. `run/1`
  calls `Mix.Task.run("compile")` first (the later `compile --warnings-as-errors` re-emits manifest
  warnings, per the measurement noted in `mix.exs`). Alternative considered and rejected for now:
  moving the alias entry after `compile --warnings-as-errors`; it would invalidate the alias-order
  assertion recorded in `test/specs/REQ-405.md`. See open question Q2.
- **D2:** role names are a runtime parameter of the pure functions; only `known_role_names/0` reads
  `Authorization`. No role list is duplicated anywhere in the task, roster, or docs.
- **D3:** roster is keyed by actor id; one roster for the whole corpus (not per tenant) so rule (a)
  is a single map lookup and a cross-tenant id collision is impossible.
- **D4:** `unresolved` carries a `searched` list so a reader can re-run the search; an actor under
  `unresolved` is a recorded gap, not a pass for rules (b)-(d).
- **D5:** SCHEMA-12 is an addition beyond the five required rules: without it a missing or
  malformed roster would crash the task or silently weaken (a)-(e). It is the integrity rule for
  the new input files, not a new product rule.
- **D6:** `docs/agents/uat-scenario-schema.md` gets three new sections plus an update to its
  "Mechanical rules" summary (`SCHEMA-0` through `SCHEMA-12`) and a one-line note in "How the
  preflight reads a scenario" that the roster is the source of an actor's built-in role (the
  preflight script itself is unchanged). Each of rules (a)-(e) gets one correct and one rejected
  YAML example (rejected examples show the exact printed line from section 4). The roster section
  and the `expect_refusal` section each get a correct and a rejected example too.

## 8. Acceptance-criteria mapping

| AC | Where satisfied |
|---|---|
| roster exists, task passes, counts printed | sections 1, 5; T-LIVE-ROSTER |
| one unit test per rule (a)-(e) naming tag, file, actor/scope | sections 4, 6 |
| no ported file modified | section 0 premise, section 6 verbatim row (roster is separate) |
| schema doc documents roster, expect_refusal, (a)-(e) with examples | D6 |
| exempt list subset of frozen list, test fails on added scope | section 1 (initial content), T-EXEMPT-FROZEN |
| compile/format/test/check pass | run by ELIXIR-DEV; no design element |

## 9. Files to be touched

New:
- `test/fixtures/uat/actors.yaml`

Modified:
- `lib/mix/tasks/letflow.check_uat_scenario_schema.ex` (moduledoc rules list SCHEMA-7..12, new types and functions, `run/1`, `render/1`, `check_scenario/2` SCHEMA-12 step key, shared scope helper)
- `test/mix/tasks/letflow_check_uat_scenario_schema_test.exs` (new describes per section 6)
- `docs/agents/uat-scenario-schema.md` (D6)

Not touched: any file under `test/fixtures/uat/scenarios/`; `mix.exs` (alias slot unchanged under D1);
`scripts/uat_preflight.sh`; `docs/roles.md`.
Orchestration-owned, not ELIXIR-DEV: `docs/requirements.yaml` status flip and run-history event.

## 10. Open questions (not resolved by guessing)

- **Q1 (from the requirement, default applied):** tenant actors seeded as PLATFORM_ADMIN are
  recorded with their real current role and listed under dated `legacy_platform_admin`; REQ-454
  empties it. No test freezes the size of this map (not required). If REQ-454 should be enforced by
  a frozen cap like the refusal list, that is a new requirement.
- **Q2:** D1 forces a compile inside a "fast, non-compiling" check. Accept, or relocate the alias
  entry after `compile --warnings-as-errors` and update the REQ-405 alias-order assertion? Default
  in this design: accept D1.
- **Q3:** whether any currently-unresolvable actor ends up under `unresolved` is a fact for
  ELIXIR-DEV to establish from the seeds and realm; nothing here presumes it. If ids such as
  `actor-vortex-felix` have no recoverable role, they go under `unresolved` with the searches
  recorded.
- **Q4:** `refusal_coverage_exempt` initially lists all five scopes because nothing can carry
  `expect_refusal: true` yet. Adding refusal steps to the two non-ported scenarios (bilimbaga,
  platform login routing) so two scopes can leave the list is out of scope for REQ-452 (follow-up
  for BA authors).
- **Q5:** a `refusal_coverage_exempt` entry naming a scope with zero scenarios is left unchecked
  (harmless, and the frozen-list test already bounds it). Say so if a stale-entry rule is wanted.
