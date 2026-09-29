# Design: ISS-0895 — swiftroute onboarding-happy vs. sibling scenarios' slug conflict

Status: draft, for CODE-DESIGN-VALIDATOR
Issue: `docs/issues/ISS-0895.yaml`
Related: ISS-0888 (missing master-realm credential; open), ISS-0896 (admin/admin
hard-code — mentioned by ISS-0895 as "the admin/admin hard-code issue"; not
otherwise touched by this design)

## Problem restated

`test/fixtures/uat/scenarios/swiftroute/tenant-onboarding-happy.yaml`'s
precondition #1 requires slug `swiftroute` to be **unregistered**. The three
sibling files in the same directory —
`shipment-ops-timeout-escalation.yaml`, `shipment-attach-delivery-note.yaml`,
`shipment-high-value-happy.yaml` — and cross-tenant probes elsewhere all
hardcode `company_id: swiftroute` and `actor-swiftroute-*` ids that require
the tenant/realm to **already exist**. Confirmed by grep: all three siblings
carry `company_id: swiftroute` and reference already-provisioned
`actor-swiftroute-{tobias,alice,lena,marco}` accounts (per ISS-0888's
`progress_2026_09_29` note, these accounts now exist with realm-qualified
secrets on QA, provisioned by ai-dala-infra run T-0150).

QA now has `swiftroute` permanently registered (T-0150). Tenants are
deactivate-only and `idp_realm_id` is immutable (per Letflow's tenant
lifecycle invariants — no code path unregisters a slug or frees a realm id).
So `tenant-onboarding-happy`'s precondition can **never** become true again
on QA. This is not a transient environment gap that `scripts/uat_preflight.sh`
Step 0 remediation can close by seeding something — it is now structurally
unrunnable on that specific, persistent, shared environment, forever.

### The ported-file constraint

`tenant-onboarding-happy.yaml`'s own header (lines 1–9) states it is "Ported
verbatim from R-Co... byte-identical below this header... Do not edit the
ported content below except to keep it byte-identical to a re-pull of the
same commit." `slug: swiftroute` appears in the ported body at line 12
(`company_id`), line 60 (`input.slug`), line 65/67 (hostname/callback_url
derived from the slug), line 101 (`expected_slug`), line 116 (`realm:
swiftroute` for Alice's login). Editing any of these to a different slug
value violates the file's own documented invariant. **This design does not
edit that file's ported body.**

(Aside, out of scope for this issue: the file's ported body appears to
contain two full copies of the scenario back to back — a `version: "2.0"`
GUI-driven copy at lines 10–221 and a `version: "1.0"` API-driven copy
duplicated at lines 222–411, both under one `---` document marker. This
looks like a merge/port artifact independent of the slug conflict. Flagged
as an open question below; not fixed by this design.)

## What the other three scenarios actually depend on

Grep confirms (not paraphrased):

| file | `company_id` | actor ids referencing swiftroute |
|---|---|---|
| `shipment-ops-timeout-escalation.yaml` | `swiftroute` | `actor-swiftroute-tobias`, `actor-swiftroute-alice` |
| `shipment-attach-delivery-note.yaml` | `swiftroute` | `actor-swiftroute-lena`, `actor-swiftroute-marco` |
| `shipment-high-value-happy.yaml` | `swiftroute` | `actor-swiftroute-lena`, `actor-swiftroute-marco`, `actor-swiftroute-alice` |

All three need the tenant, its realm, and its actor accounts to already
exist — none of them re-onboard or unregister the tenant. There is no way to
satisfy both "swiftroute unregistered" (onboarding scenario) and "swiftroute
registered" (three siblings + cross-tenant probes) on the same persistent
environment at the same time.

## Existing conventions checked (no direct precedent, but a reusable piece exists)

- `grep -rn "env_scoped|skip_on|unrunnable|blocked_on_shared|expected_unrunnable"
  docs/agents/ test/fixtures/uat/` — **no hits**. There is no existing
  sidecar/exclusion-list mechanism for "this scenario is permanently
  unrunnable on environment X."
- `docs/agents/uat-scenario-schema.md` documents `scope:` (REQ-358) and
  `branches:`/`when:` (REQ-358). Neither fits: `scope` classifies *who the
  behavior is visible to* (tenant-vertical vs. platform), not *which
  environment can run it*; `branches:`/`when:` branches on **observed
  runtime facts within a single run** (e.g. `role`), not on a static,
  externally-supplied environment identity, and editing the file to add
  `branches:` would violate the byte-identical constraint anyway.
- `docs/agents/workflows/WF-05_uat_run.md` Step 0 item 4 **already defines**
  the classification this issue needs: a scenario unmet after prep is
  `BLOCKED-by-environment`, one of `ENV_*`, `CREDENTIALS_MISSING`,
  `PRECONDITION_NOT_MET`, `ENV_NOT_SUPPORTED`. `ENV_NOT_SUPPORTED` is already
  used once today (`scripts/uat_preflight.sh` `local_deps` check, for a spec
  that shells out to `docker compose exec psql` — a *structural*, not
  transient, incompatibility with an environment). This is the right
  classification to reuse: `tenant-onboarding-happy` on `qa` is exactly this
  shape — structural, permanent, not preflight-closeable.
- `scripts/uat_preflight.sh`'s per-scenario `tenant` check (`CHECKS = ["spec",
  "local_deps", "feature", "tenant", "realm", "actors"]`, around line 296)
  only checks tenant **existence** (`t.lower() in tenants_found` → OK). For
  `tenant-onboarding-happy` this check would report **OK** today (swiftroute
  exists), because the generic heuristic assumes every scenario wants its
  `company_id` tenant to exist — the opposite of what this one scenario
  needs. So today's Step 0 preflight does **not** catch this gap at all; the
  scenario only fails at UAT-RUNNER execution time against its own `custom`
  precondition check. This is a second, independent finding worth fixing as
  part of this design's mechanism (see below) — otherwise ORCH would keep
  dispatching UAT-RUNNER to discover the same permanent block by hand every
  run.

## Recommendation: option (b) — mark permanently env-scoped/unrunnable on `qa`, do not re-point to a throwaway slug

### Why not (a)

- A throwaway slug (`swiftroute-uat-<run-id>`) needs a master-realm Keycloak
  credential to drive the realm-creation saga. ISS-0888's
  `progress_2026_09_29` note confirms this credential **does not exist yet**
  on QA ("no master-realm admin credential for UAT runs; qa-admin only") —
  option (a) is blocked on an open, unrelated issue before it could even run.
- Tenants are deactivate-only and `idp_realm_id` is immutable — every
  throwaway-slug onboarding run leaves a permanent, undeletable tenant row,
  Postgres schema, and Keycloak realm behind. Run this nightly/per-CI and QA
  accumulates unbounded garbage tenants forever, with no cleanup path ever
  available (this is the same structural constraint that created the
  original problem — reproducing it per-run doesn't fix it, it multiplies
  it).
- Faithfully re-pointing the scenario without editing the ported body would
  require a run-time substitution layer overriding not just `company_id`
  but ~7 more literal-`swiftroute` occurrences across the ported body
  (`input.slug`, `hostname`, `callback_url`, `admin_email` domain,
  `expected_slug`, `realm:` at step 4, `company_workspace`/realm references
  in the duplicated v1.0 copy). A templating layer with that much surface
  area effectively re-authors the scenario through indirection, which
  undermines the point of the byte-identical-port invariant (verifying this
  file still matches R-Co's committed content) without formally violating
  it. That is more machinery, for a worse operational outcome, than (b).

### Why (b)

- Reuses a classification (`ENV_NOT_SUPPORTED`) WF-05 already defines and
  already uses for exactly this shape of problem (structural, not
  preflight-closeable).
- Zero new data growth, zero new credential dependency, zero risk to the
  ported file's byte-identical invariant.
- The scenario keeps working wherever the precondition really can be met —
  a local/ephemeral/reset-per-run environment (e.g. a docker-compose stack
  torn down and rebuilt between runs) still runs it exactly as authored, so
  the onboarding-wizard user journey (`pipeline_test:
  web/tests/e2e/pipelines/onboarding-wizard.pipeline.e2e.spec.ts`) is not
  permanently unvalidated everywhere — only on the one persistent, shared
  environment where it genuinely cannot pass.

## Mechanism

### 1. New sidecar directory (not under `test/fixtures/uat/scenarios/`)

`test/fixtures/uat/scenario-env-limitations/` — a new, NOT ported, NOT
scenario-shaped directory. It is deliberately outside
`test/fixtures/uat/scenarios/`, so it is invisible to both existing globs
that would otherwise try to validate it as a scenario file:
`lib/mix/tasks/letflow.check_uat_scenario_schema.ex`'s
`@scenario_glob "test/fixtures/uat/scenarios/**/*.yaml"` and
`scripts/uat_preflight.sh`'s `glob.glob(os.path.join(scen_dir, "**",
"*.yaml"))`. No exclusion-list change is needed in either tool for this
directory choice alone.

One file per affected scenario, named `<scenario_id>.yaml`:

`test/fixtures/uat/scenario-env-limitations/swiftroute-tenant-onboarding-happy.yaml`:

```yaml
scenario_id: swiftroute-tenant-onboarding-happy
applies_to_environments: [qa]
classification: ENV_NOT_SUPPORTED
reason: >
  Precondition #1 requires slug 'swiftroute' to be unregistered. QA has it
  permanently registered (ai-dala-infra run T-0150) because the sibling
  scenarios in this directory (shipment-ops-timeout-escalation,
  shipment-attach-delivery-note, shipment-high-value-happy) and
  cross-tenant isolation probes require it to already exist. Tenants are
  deactivate-only and idp_realm_id is immutable -- this precondition can
  never become true again on qa. Not closeable by WF-05 Step 0
  remediation (it is not a seeding gap); re-checking will report the same
  GAP every run by design.
recorded_by: ORCH
recorded_at: "2026-09-29"
issue_ref: ISS-0895
review: >
  Revisit only if QA's tenant-lifecycle policy changes (e.g. a
  slug-release/reset path is added), or if a disposable/ephemeral QA lane
  becomes available for onboarding-only scenarios.
```

Field shapes:
- `scenario_id` (string, required): must exactly equal a scenario file's
  `id:` field somewhere under `test/fixtures/uat/scenarios/`.
- `applies_to_environments` (list of string, required, non-empty): exact
  `--environment` slug match(es), e.g. `[qa]`. Not a pattern — an ephemeral
  or local environment simply omits itself from this list and the scenario
  runs there unmodified.
- `classification` (string, required): one of the four codes WF-05 Step 0
  item 4 already enumerates (`ENV_NOT_SUPPORTED`, `PRECONDITION_NOT_MET`,
  `CREDENTIALS_MISSING`, or an `ENV_*` code) — this instance uses
  `ENV_NOT_SUPPORTED` because the block is structural/permanent, not a
  transient missing credential or seed.
- `reason` (string, required): human-readable, goes verbatim into the
  preflight report row.
- `recorded_by`, `recorded_at`, `issue_ref` (strings, required): provenance,
  so a future reader can tell this was a deliberate decision (ISS-0895) and
  not a script bug.
- `review` (string, optional): the condition under which this sidecar should
  be revisited/removed — prevents it silently fossilizing past the point
  it's still true.

### 2. `scripts/uat_preflight.sh` changes

Add a new per-scenario check column: `CHECKS = ["spec", "local_deps",
"feature", "tenant", "realm", "actors", "env_limitation"]` (append
`"env_limitation"`).

Before the existing per-scenario loop's checks run (or after — order doesn't
matter since this is an independent, additive column, not an override of
`tenant`/`realm`), for each scenario `s`:

1. Load all `test/fixtures/uat/scenario-env-limitations/*.yaml` sidecars
   once (same tolerant-YAML/regex reader already used for scenario files —
   PyYAML if present, else the existing regex fallback), keyed by
   `scenario_id`.
2. If `s["id"]` has no matching sidecar: `c["env_limitation"] = ("OK", "no
   known environment limitation", "")`.
3. If it has a match but `a.environment not in
   sidecar["applies_to_environments"]`: same OK result (limitation doesn't
   apply to this environment).
4. If it has a match and `a.environment in
   sidecar["applies_to_environments"]`: `c["env_limitation"] =
   (sidecar["classification"], sidecar["reason"], "environment-structural
   (permanent; issue_ref=%s) -- no prep remediation; re-running preflight
   will report this same GAP by design" % sidecar["issue_ref"])`.

This is additive, not a replacement of the existing `tenant` check (which
stays `OK` for this scenario on `qa`, correctly reporting "swiftroute the
tenant exists" — a true fact — while `env_limitation` separately reports the
real, permanent problem: this scenario specifically needs it to NOT exist).
Keeping both visible in the report is more diagnostic than overriding
`tenant` in place would be.

A `GAP`/`ENV_NOT_SUPPORTED` row for `env_limitation` feeds into the existing
"scenarios with >=1 GAP" aggregate (`scen_dir` loop around line 387) exactly
like any other GAP column already does — no change needed to that
aggregation or to the exit-code logic (`ready = ...`, exit 1 on any GAP).

### 3. `docs/agents/workflows/WF-05_uat_run.md` Step 0 update

Step 0 item 3 (remediation owners) gets a fourth bullet alongside
`letflow-seed` / `ai-dala-infra` / `feature-gap`:

> - environment-structural (permanent): a
>   `test/fixtures/uat/scenario-env-limitations/<scenario_id>.yaml` sidecar
>   says this scenario cannot pass on this `--environment` slug for a
>   structural reason (not a seeding/credential gap). No remediation is
>   attempted. Confirm the sidecar's `applies_to_environments` and `review`
>   condition are still accurate; if so, this GAP is expected and reported
>   every run by design — do not loop trying to close it, and do not
>   re-file it as a new issue (cite the sidecar's `issue_ref` instead).

Step 0 item 4's existing `ENV_NOT_SUPPORTED` bullet needs no wording change
— it already covers this.

### 4. `.claude/agents/uat-runner.md`

Add one sentence to the environment-target / BLOCKED-by-environment section
already present there: a scenario whose preflight report shows
`env_limitation: GAP` must be recorded `BLOCKED` with the sidecar's `reason`
and `issue_ref` verbatim, and UAT-RUNNER must not attempt to execute it
against that environment (mirrors the existing rule "do not run a scenario
the preflight lists as GAP").

### 5. `docs/anti-patterns.md`

Add an entry: "A generic preflight heuristic checked only 'does this
scenario's tenant exist' — for one out of four scenarios sharing a
`company_id` directory, the correct direction was the opposite (must NOT
exist). Don't assume every scenario in a `<company>/` directory wants the
same tenant-existence polarity; an onboarding scenario's precondition can be
the photographic negative of its siblings'." This documents the second,
independent finding (Step 0 not previously catching this gap at all) so a
future scenario author doesn't rediscover it the same way.

## Files touched by this design (for the next agent)

- NEW: `test/fixtures/uat/scenario-env-limitations/swiftroute-tenant-onboarding-happy.yaml`
- MODIFIED: `scripts/uat_preflight.sh` (new `env_limitation` check column +
  sidecar loader)
- MODIFIED: `docs/agents/workflows/WF-05_uat_run.md` (Step 0 item 3, new
  remediation-owner bullet)
- MODIFIED: `.claude/agents/uat-runner.md` (BLOCKED-by-environment section,
  one sentence)
- MODIFIED: `docs/anti-patterns.md` (new entry)
- NOT touched: `test/fixtures/uat/scenarios/swiftroute/tenant-onboarding-happy.yaml`
  (ported body stays byte-identical, per its own header)
- NOT touched: the three sibling scenario files (no conflict on their side —
  they already correctly assume the tenant exists)

## Invariants

- The ported scenario file's byte-identical body is never edited by this
  design.
- `env_limitation` is additive; it never overrides or suppresses the
  `tenant`/`realm`/`actors` columns' own independent findings.
- A sidecar match is environment-scoped (`applies_to_environments`), not
  global — the scenario is not disabled everywhere, only on the named
  persistent/shared environment(s).
- Every sidecar carries `issue_ref` so a recurring GAP row is traceable to a
  known, already-filed decision rather than triggering a fresh issue filing
  each WF-05 run.

## Open questions

1. **Duplicate content inside the ported file itself.** As noted above,
   `tenant-onboarding-happy.yaml`'s body appears to contain two full,
   differently-versioned copies of the scenario (`version: "2.0"` GUI-driven
   at lines 10–221, `version: "1.0"` API-driven duplicated at lines
   222–411) under a single `---` document marker. This design does not
   determine whether that is a porting artifact, an intentional multi-doc
   YAML stream UAT-RUNNER already knows how to read, or a bug — it is
   independent of the slug conflict and out of this issue's scope. Recommend
   filing a separate issue if CODE-DESIGN-VALIDATOR or ELIXIR-DEV confirms
   it's unintentional.
2. **No sidecar staleness check specified.** This design does not add a
   mechanical check (e.g. a `mix letflow.check_uat_scenario_schema` rule)
   confirming every sidecar's `scenario_id` still matches a real scenario
   `id:` in the corpus, or flagging an unused/orphaned sidecar. Left to
   ELIXIR-DEV's judgment whether to add one now or defer — the four-field
   `test/fixtures/uat/scenario-env-limitations/` corpus is small enough
   today that a stale entry would likely surface in review, but this will
   not scale silently if the directory grows.
3. **Where does the onboarding-wizard journey get validated at all, given
   QA is now permanently excluded?** This design assumes a local/ephemeral
   environment run occasionally exercises
   `swiftroute-tenant-onboarding-happy` for real. It does not verify such an
   environment currently exists/is scheduled in the WF-05 rotation — if none
   does, EO-001..EO-004 (onboarding wizard correctness) are validated
   nowhere in practice, which would be worth flagging back to ORCH/BA-swiftroute
   independent of this fix.
4. **Should `applies_to_environments` eventually generalize to a pattern
   (e.g. "any environment tagged `tenant_lifecycle: persistent`") instead of
   an explicit slug list**, once/if more than one persistent shared
   environment exists? No environment-property registry exists today (`
   --environment` is presently just an opaque slug printed in the report),
   so this design keeps the sidecar's allow-list literal and explicit rather
   than inventing that registry speculatively. Revisit if a second
   persistent environment is added.
