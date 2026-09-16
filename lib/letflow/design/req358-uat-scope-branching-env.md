# REQ-358 — Design: UAT scenario `scope`/branching schema, schema-validation mix task,
# and UAT-RUNNER/WF-05 environment-target + branching-evaluation updates

Stage S7 (closing gap identified by REQ-210; trigger condition confirmed fired — see
`context.requirement_text` in this run's handoff, which restates decision 0004's
deferral and why it now applies). Owner: `CODE-DESIGNER`. Status: design only.

This document is shared, load-bearing infrastructure for REQ-359 (BA persona role) and
REQ-361 (PRODUCT-OWNER-equivalent role) — neither of those requirements re-derives the
schema/runner change designed here. **Not in scope here:** no new agent role, no actual
login-routing scenario committed as permanent corpus (a throwaway fixture is designed in
§3 for REQ-358's own validation only — TEST-DESIGNER discards or relocates it), no
visual-regression mechanism (REQ-362).

---

## 0. Premises re-verified against the tree (2026-09-16)

- `test/fixtures/uat/scenarios/meridian/loan-origination-below-threshold.yaml` (read in
  full) is the tenant-scenario shape: top-level `id`, `company_id: meridian`,
  `process_id`, `title`, `version`, `tags`, `description`, `actors` (a map of role-name →
  actor id), `preconditions[]` (`description`, `check`), `steps[]` (`step`, `actor`,
  `action` prose, `via`, `input` map, optional `produces`, optional `sla_context`),
  `expected_outcomes[]` (`id`, `description`, `verification: {method, detail}`, `on_fail:
  {severity, business_impact, suggested_action}`), and `cleanup`. No `scope:` key exists
  anywhere in this file today.
- `test/fixtures/uat/scenarios/platform/definition-promotion-approved.yaml` (read in
  full) already uses **`company_id: platform`** as its scope discriminator, plus a sibling
  `platform_workflow: PW-01` field tenant scenarios don't carry, and an optional
  `pipeline_test:` key naming a Playwright spec (absent or annotated `NOTE (ISS-0527)`
  when the spec doesn't exist yet — UAT-RUNNER records BLOCKED/UNBUILT_FEATURE in that
  case, per `.claude/agents/uat-runner.md`'s existing "Reading the scenario corpus"
  section; this design does not change that convention).
- This confirms `company_id: platform` is **already** today's de facto scope
  discriminator for the 18 platform scenarios, and `company_id: <name>` (a literal R-Co
  company — `meridian`/`swiftroute`/`vortex`) is the de facto discriminator for the 11
  tenant scenarios. §1.2 below designs `scope:` as an explicit, additive field on top of
  this existing convention rather than inventing scope-detection from nothing.
- `docs/agents/` has no existing schema-doc home for the UAT scenario format today
  (confirmed: `ls docs/agents/ | grep -i schema` returns nothing). This design creates
  `docs/agents/uat-scenario-schema.md` as that home, per the handoff's instruction.
- `lib/mix/tasks/letflow.check_requirements_registration.ex` (read in full) is the
  structural precedent for §2: a `Mix.Task` with a pure `scan/1` (content in, report out,
  never raises on malformed content — malformed content becomes `violations` in the
  report), a separate `run/2` `Mix.Task` entry point that reads the file(s), calls the
  pure core, renders a report, and `Mix.raise/1`s iff violations is non-empty. §2 follows
  this same producer/pure-core/raise shape, adapted from one file to a directory walk.
- `mix.exs`'s `letflow.check` alias (read in full, lines 114–154) is a flat list of
  `"letflow.check_*"` task names, fast non-compiling textual/line-oriented checks placed
  before `format --check-formatted` / `compile --warnings-as-errors` / `letflow.check.test`,
  each with an inline comment explaining its placement relative to neighbors. §2.4 below
  follows this convention.
- **REWORK ITERATION 1 correction:** an earlier draft of this section claimed the
  project has no YAML-parsing dependency at all. That is wrong — `mix.exs`'s `deps()`
  already declares `{:yaml_elixir, "~> 2.11", only: :test}`, already used by
  `lib/mix/tasks/letflow.audit_issue_closures.ex` and several test-support/fixture
  modules (grep confirms both). `check_requirements_registration`'s own moduledoc
  explaining why *it* avoids YAML ("adding one for a bug fix would be a library choice
  requiring REVIEWER sign-off") describes that task's own deliberate choice not to
  depend on `yaml_elixir` for a line-oriented text scan — it is not evidence the
  dependency is absent from the project. §2's task **reuses `yaml_elixir`**, already on
  record; see §2.2 and the resolved OQ-1 below (no new REVIEWER library sign-off
  needed).

---

## 1. Schema extension

### 1.1 `scope:` field — shape and semantics

New **optional** top-level key on a scenario file:

```yaml
scope: platform            # or an open tenant-vertical/solution-pack identifier string
```

- Type: non-empty string. Not a closed enum. `"platform"` is the one reserved literal
  value with special meaning (see classification rule below); every other value is an
  open tenant-vertical/solution-pack identifier chosen freely by whoever authors the
  scenario (e.g. `"lending"`, `"logistics"`, or — for a scenario ported from/tied to one
  of the three legacy R-Co companies — the literal company name, which today already
  functions as a de facto vertical identifier for those 11 files; see §1.2 default rule).
- **Classification rule** (adapted verbatim in substance from R-Co's
  uat-scenario-schema-v1.1-addendum.md, per the requirement text): *if a business user of
  a tenant installation would notice the behaviour being tested, the scenario keeps its
  tenant-vertical `scope`; use `scope: platform` only when the actor is the platform
  operator (`role: PLATFORM_ADMIN` or equivalent) or the platform itself (a system actor
  acting outside any tenant's data, e.g. definition promotion, cross-tenant isolation
  checks).* This rule is **not mechanically checkable** — it requires judging what a
  scenario's action actually represents — so §2.2 encodes only the mechanical half
  (presence/non-emptiness/string-type), never "is this the right classification," per the
  task description's explicit instruction not to fake a mechanical check for a semantic
  judgment.

### 1.2 `scope:` / `company_id:` relationship — decided

**Decision: `scope` and `company_id` coexist as two distinct axes, not one superseding
the other**, with a default that derives `scope` from `company_id` when `scope` is
absent, so all 29 existing files parse unchanged:

- `company_id:` stays what it already is: today, for tenant scenarios, the identifier of
  one of the (currently 3, legacy, R-Co-ported) literal companies whose actor ids
  (`actor-meridian-sophie`, etc.) and process definitions the scenario data is
  concretely bound to; for platform scenarios, the literal string `"platform"`. It is not
  redefined or renamed by this design.
- `scope:` is the new, **broader, open classification** the requirement asks for: is this
  scenario's behaviour tenant-visible (and if so, which tenant-vertical/solution-pack) or
  platform-operator-visible. It exists because Letflow's actual tenant model (unlike
  R-Co's fixed SwiftRoute/Vortex/Meridian trio) has no closed set of named companies —
  a real Letflow tenant is created dynamically and belongs to whatever solution pack it
  installed, so a scenario authored against Letflow's own runtime (not a ported R-Co
  fixture) will often have no natural `company_id` at all, only a `scope` value naming
  the vertical/pack it's validating (e.g. `scope: lending` with no `company_id:` key).
- **Default (backward compatibility, REQ-358 AC1):** when `scope:` is absent from a
  scenario file, it is read as:
  - `"platform"` if `company_id: platform` is present, else
  - the literal value of `company_id:` if `company_id:` is present (treating each of the
    3 legacy company names as, today, its own one-member "tenant-vertical" — an accepted
    historical exception documented here, not silently assumed elsewhere), else
  - absent entirely — a scenario with neither `scope:` nor `company_id:` is not
    auto-classified; §2.2's mechanical check flags this as an error (not a silent
    default), because a scenario with no scope information at all is exactly the
    "invisible to classification" case R-Co's addendum rule exists to prevent.
- No existing file needs editing for this design to land: all 11 tenant files carry
  `company_id: <name>`, all 18 platform files carry `company_id: platform`; the default
  rule above classifies every one of the 29 unchanged, so their read `scope` is
  well-defined without adding the key.
- New scenarios (REQ-360's fast-follow, or REQ-359/361's own fixtures) SHOULD write
  `scope:` explicitly rather than relying on the `company_id:` default, since `scope` is
  the field this design actually asks classification questions of; `company_id:` becomes
  optional going forward for scenarios with no natural literal-company binding.

### 1.3 Step-level branching construct

New **optional** key at step-group level: a named list of **branches**, each gated by a
`when:` condition, replacing (for scenarios that need it) a single flat `steps:` /
`expected_outcomes:` list with a `branches:` list of named sub-paths. Backward
compatible: a scenario with no `branches:` key behaves exactly as today (flat
`steps:`/`expected_outcomes:`, unconditional).

Shape:

```yaml
# Instead of (or alongside — see below) top-level `steps:`/`expected_outcomes:`:
branches:
  - name: platform_admin_dashboard
    when:
      fact: role
      op: eq
      value: PLATFORM_ADMIN
    steps:
      - step: 1
        actor: viewer
        action: >
          Signs in as a platform administrator and lands on the post-login screen
        via: gui
    expected_outcomes:
      - id: EO-001
        description: Platform admin dashboard is shown
        verification:
          method: page_state
          detail: "URL/route is the platform-admin dashboard; page shows tenant list"
        on_fail:
          severity: BLOCKER
          business_impact: Platform admins cannot reach their operating console.
          suggested_action: route_to_wf03

  - name: tenant_user_dashboard
    when:
      fact: role
      op: in
      value: [TENANT_ADMIN, TENANT_USER]      # equality+in-list, see operator set below
    steps:
      - step: 1
        actor: viewer
        action: Signs in as a tenant user and lands on the post-login screen
        via: gui
    expected_outcomes:
      - id: EO-001
        description: Tenant workspace dashboard is shown
        verification:
          method: page_state
          detail: "URL/route is the tenant dashboard; page shows this tenant's data only"
        on_fail:
          severity: BLOCKER
          business_impact: Tenant users cannot reach their workspace after login.
          suggested_action: route_to_wf03

  - name: unauthenticated_fallback
    when: else                                 # reserved literal: matches iff every
    steps:                                      # preceding branch's `when` did not match
      - step: 1
        actor: viewer
        action: Attempts to reach the post-login screen without signing in
        via: gui
    expected_outcomes:
      - id: EO-001
        description: The login form is shown instead of any dashboard
        verification:
          method: page_state
          detail: "URL/route is the login form; no dashboard content is present"
        on_fail:
          severity: BLOCKER
          business_impact: Unauthenticated visitors can reach a dashboard.
          suggested_action: route_to_wf03
```

Key/shape rules:

- `branches:` is a **list**, evaluated top-to-bottom. Each entry: `name` (string,
  unique within the file — used only in the UAT report, e.g. `EO-001 (branch:
  platform_admin_dashboard)`), `when` (a condition — see below, or the literal string
  `else`), `steps:` (same shape as today's top-level `steps:`), `expected_outcomes:`
  (same shape as today's top-level `expected_outcomes:`), and optionally `preconditions:`
  (same shape as today's top-level `preconditions:`, scoped to this branch only, if the
  scenario needs branch-specific preconditions — omit to reuse the file's top-level
  `preconditions:` unchanged).
- `when:` condition shape (deliberately narrow — **not** a general expression language,
  per the task description's explicit instruction):
  ```yaml
  when:
    fact: <string>     # a runtime-observable fact name, e.g. "role"
    op: eq | in         # the ONLY two allowed operators
    value: <string>     # for op: eq
    # or
    value: [<string>, ...]   # for op: in
  ```
  Allowed operators: **`eq`** (fact value equals `value` exactly, case-sensitive
  string comparison) and **`in`** (fact value is a member of the `value` list, same
  comparison rule). No boolean composition (`and`/`or`/`not`), no numeric/relational
  operators, no nested conditions. This is sufficient to express the login-routing
  example (§3) and is the entire allowed vocabulary — anything requiring more is an
  explicit signal to escalate to REVIEWER before extending the construct, not to
  quietly grow it.
  - `when: else` (the bare literal string, not a mapping) is reserved and means "matches
    iff no earlier branch in this file's `branches:` list matched." At most one `else`
    branch is allowed per file, and if present it must be the **last** entry (§2.2
    enforces both mechanically).
- **Facts** are named, runtime-observable values UAT-RUNNER is expected to already have
  or be able to obtain mid-run — for this design's initial vocabulary, exactly one fact
  is defined: **`role`**, the authenticated session's role, or the literal string
  `"unauthenticated"` when no session is authenticated (i.e. `when: {fact: role, op: eq,
  value: unauthenticated}` is an equivalent, more explicit spelling of what `when: else`
  is shorthand for in the specific case of "not signed in" — both are legal; §3 uses
  `else` for brevity). Any other `fact:` name is legal syntactically (this design does
  not enumerate a closed fact vocabulary, since UAT-RUNNER is a subagent capable of
  observing other things, e.g. a feature flag or tenant plan tier) but only `role` has a
  procedurally-defined evaluation method — see §3.4's replacement prose. A scenario using
  an undefined fact name must say, in its own `description`, how a human/agent reading it
  would obtain that fact's value; §2.2 cannot and does not check this (semantic, not
  mechanical).
- Backward compatibility: `branches:` and top-level `steps:`/`expected_outcomes:` are
  **mutually exclusive** within one file — a file has one or the other, never both (§2.2
  rejects a file with both, since "which applies first" would be ambiguous and this
  design does not need to answer that question to satisfy REQ-358). All 29 existing files
  use only top-level `steps:`/`expected_outcomes:` and carry no `branches:` key, so they
  are unaffected.

---

## 2. Schema-validation mix task

### 2.1 Module and file

`lib/mix/tasks/letflow.check_uat_scenario_schema.ex`, module
`Mix.Tasks.Letflow.CheckUatScenarioSchema`, following
`Mix.Tasks.Letflow.CheckRequirementsRegistration`'s structural pattern: a thin `run/1`
`Mix.Task` entry point over a pure, hermetically-testable core.

### 2.2 Public function signatures (`@spec`-style; no bodies)

```
@scenario_glob "test/fixtures/uat/scenarios/**/*.yaml"

@type violation :: %{
        file: Path.t(),
        rule: String.t(),        # e.g. "SCHEMA-1", "SCHEMA-2", ... (see rule list below)
        message: String.t()
      }

@type file_result :: %{
        file: Path.t(),
        ok?: boolean(),
        violations: [violation()]
      }

@type report :: %{
        files: [file_result()],
        file_count: non_neg_integer(),
        violations: [violation()]
      }

@impl Mix.Task
@spec run([String.t()]) :: :ok
def run(_args)
# Enumerates @scenario_glob via Path.wildcard/1, calls check_file/1 per path, aggregates
# into a report(), renders it (analogous to check_requirements_registration's always-
# printed report — per-file OK/FAIL line, then a summary), and Mix.raise/1s with every
# violation (file + rule + message) if report.violations != [], :ok otherwise. Exits
# non-zero on a zero-file glob match too (mirrors R5's "a scan that finds nothing is
# never a silent green pass" — an empty scenario corpus is itself a violation, rule
# "SCHEMA-0").

@doc "Checks one scenario file by path. Never raises on a malformed file — a parse or
schema violation becomes a file_result() with ok?: false and a populated violations
list, exactly like check_requirements_registration's scan/1 never raising on malformed
content. Raises only if the path cannot be read at all (I/O error, not a schema error)."
@spec check_file(Path.t()) :: file_result()
def check_file(path)

@doc "Pure core: given already-parsed scenario data (a map, as produced by
`YamlElixir.read_from_file/1`, matching the codebase's existing convention in e.g.
test/support/simulation/scenario_fixture.ex — see §0's REWORK ITERATION 1 correction and
resolved OQ-1: this design reuses the project's existing `yaml_elixir` dependency, not a
new one) and the file's path (for error messages only), returns every
mechanically-checkable violation. Empty list iff the file
satisfies every mechanical rule below. This is the unit hermetic fixture tests target,
mirroring classify_entry/1's role in the precedent module."
@spec check_scenario(Path.t(), map()) :: [violation()]
def check_scenario(path, scenario_data)

@doc "Renders the always-printed report (per-file pass/fail line + summary + violations),
pure like check_requirements_registration's render/1."
@spec render(report()) :: iodata()
def render(report)
```

### 2.3 Mechanical rules `check_scenario/2` enforces (each a distinct `rule` tag)

Only the mechanical half of §1's classification rule — never "is this classification
correct," per the task description.

- **SCHEMA-1** — file parses as valid YAML at all (a parse failure is reported with the
  underlying decoder error message, not swallowed).
- **SCHEMA-2** — top-level `id`, `title`, `version` are present and non-empty strings
  (pre-existing required fields, unchanged by this design — stated here because §2's task
  is to validate the *whole* current shape, not only the new additions, so a malformed
  pre-existing field is still caught).
- **SCHEMA-3** — resolved `scope` (explicit `scope:` key, or the §1.2 default derived
  from `company_id:`) is present and a non-empty string. Fires when neither `scope:` nor
  `company_id:` is present (the "absent entirely" case in §1.2's default rule).
- **SCHEMA-4** — a file carries **either** top-level `steps:`+`expected_outcomes:` **or**
  `branches:`, never both, never neither.
- **SCHEMA-5** — (when `branches:` is present) each branch entry has non-empty `name`
  (unique within the file), a `when` that is either the literal string `"else"` or a map
  with `fact` (non-empty string), `op` (exactly `"eq"` or `"in"`), and `value` (a string
  for `eq`, a non-empty list of strings for `in`); and non-empty `steps:` and
  `expected_outcomes:` lists in the same shape as the pre-existing top-level ones
  (reusing SCHEMA-2-equivalent structural checks per-branch, not re-specified here to
  avoid duplicating the pre-existing step/expected_outcomes shape checks — see Open
  Question OQ-2 on how much of the pre-existing per-step/per-outcome shape this task
  should re-validate vs. leave unchecked as today).
- **SCHEMA-6** — at most one `branches:` entry has `when: else`, and if present it is the
  last entry in the list.

### 2.4 `mix.exs` wiring (diff-shaped instruction, not code)

Insert `"letflow.check_uat_scenario_schema"` into the `"letflow.check"` alias list in
`mix.exs` (currently lines 114–154), immediately after `"letflow.check_issue_refs"` and
before `"format --check-formatted"` — i.e. grouped with the other fast,
non-compiling, pure-textual/structural scans that report in seconds, per the existing
convention documented inline for each neighbor. Concretely:

```diff
         "letflow.check_issue_refs",
+        # REQ-358: validates test/fixtures/uat/scenarios/**/*.yaml against the schema
+        # documented in docs/agents/uat-scenario-schema.md -- placed with the other
+        # fast, non-compiling structural scans (no shared parse target with any
+        # neighbor, so no ordering dependency either direction).
+        "letflow.check_uat_scenario_schema",
         "format --check-formatted",
```

A one-line addition to the inline comment block above the alias (mirroring the existing
per-task rationale comments already there) noting the new task and its placement
rationale, in the same style as the ISS-0613/ISS-0258/2026-09-09 comments already present
at that call site.

### 2.5 Rejection error message shape

Both the always-printed report (`render/1`) and the `Mix.raise/1` message follow
`check_requirements_registration`'s `format_violation/1` precedent exactly:

```
[<rule>] <file>: <message>
```

e.g.:

```
[SCHEMA-3] test/fixtures/uat/scenarios/acme/broken-scope.yaml: neither `scope:` nor
`company_id:` is present -- a scenario with no scope information cannot be classified
[SCHEMA-6] test/fixtures/uat/scenarios/acme/broken-branch.yaml: `when: else` branch
"fallback" is not the last entry in `branches:` (appears before "tenant_user_dashboard")
```

`Mix.raise/1`'s message is `"mix letflow.check_uat_scenario_schema: FAILED -- N
violation(s):\n" <> Enum.map_join(violations, "\n", &format_violation/1)`, matching the
precedent module's `run/1` raise shape verbatim in structure.

---

## 3. The login-routing throwaway fixture (proof the construct is sufficient)

For TEST-DESIGNER's Step 2/3 use — not committed permanent corpus (per the task's NOT IN
THIS REQUIREMENT note; TEST-DESIGNER discards or relocates after using it to exercise
`mix letflow.check_uat_scenario_schema`'s pass/fail paths for REQ-358's own AC2):

```yaml
---
id: throwaway-login-routing-req358-validation
scope: platform
process_id: n/a
title: Post-login landing routes by authenticated role (REQ-358 schema validation fixture)
version: "1.0"
tags: [schema_validation, throwaway]

description: >
  Throwaway fixture proving the branching construct designed in REQ-358 can express:
  a platform admin lands on the platform-admin dashboard, a tenant user lands on the
  tenant dashboard, and an unauthenticated visitor sees the login form -- three distinct
  outcomes from one login-routing action, gated on the authenticated session's role.

actors:
  viewer: actor-any

preconditions:
  - description: The instance is reachable at the configured environment target
    check: instance_reachable

branches:
  - name: platform_admin_dashboard
    when:
      fact: role
      op: eq
      value: PLATFORM_ADMIN
    steps:
      - step: 1
        actor: viewer
        action: Signs in as a platform administrator
        via: gui
    expected_outcomes:
      - id: EO-001
        description: Platform admin dashboard is shown
        verification:
          method: page_state
          detail: "post-login route is the platform-admin dashboard"
        on_fail:
          severity: BLOCKER
          business_impact: Platform admins cannot reach their console after login.
          suggested_action: route_to_wf03

  - name: tenant_user_dashboard
    when:
      fact: role
      op: in
      value: [TENANT_ADMIN, TENANT_USER]
    steps:
      - step: 1
        actor: viewer
        action: Signs in as a tenant user
        via: gui
    expected_outcomes:
      - id: EO-001
        description: Tenant workspace dashboard is shown
        verification:
          method: page_state
          detail: "post-login route is this tenant's dashboard"
        on_fail:
          severity: BLOCKER
          business_impact: Tenant users cannot reach their workspace after login.
          suggested_action: route_to_wf03

  - name: unauthenticated_fallback
    when: else
    steps:
      - step: 1
        actor: viewer
        action: Attempts the post-login route without signing in
        via: gui
    expected_outcomes:
      - id: EO-001
        description: The login form is shown
        verification:
          method: page_state
          detail: "route is the login form, no dashboard content present"
        on_fail:
          severity: BLOCKER
          business_impact: Unauthenticated visitors can reach a dashboard.
          suggested_action: route_to_wf03

cleanup:
  cancel_open_instances: false
  description: No process instance created; no cleanup required.
```

This fixture is `SCHEMA-1..6`-valid under §2.3's rules and exercises all three outcomes
of the login-routing example named in the requirement text with only `eq`/`in`/`else` —
no scripting language needed.

---

## 4. UAT-RUNNER and WF-05 — proposed replacement prose

### 4.1 `.claude/agents/uat-runner.md` — new "Environment target" section

Insert as a new section after "Reading the scenario corpus" and before "Forbidden":

```markdown
## Environment target

Every WF-05 dispatch to UAT-RUNNER carries an explicit environment target in the
handoff's `context` — never assume "whatever instance is reachable":

- `base_url`: the instance's base URL (e.g. `https://qa.bizdala.com`). All real HTTP
  calls and GUI navigation in this run go against this base URL, not a default or
  previously-used one.
- `credential_source`: a named source of seeded login credentials (e.g.
  `ai-dala-infra/scripts/qa-login.sh`) UAT-RUNNER uses to obtain actor credentials for
  the run's scenarios, rather than inventing or hardcoding any. Resolve each scenario's
  `actors:` map entries against this source's seeded users.

If a dispatch is missing either field, do not guess a target — return the handoff
FAILED, naming the missing field, per this project's "no speculation" core directive.
```

### 4.2 `.claude/agents/uat-runner.md` — replacement for "Note on scope"

Replace the entire current "Note on scope" section (quoted in full in this run's
handoff context) with:

```markdown
## Note on scope

R-Co's `BO-*` business-owner personas and `PRODUCT-OWNER` role evaluate UAT results from
a specific tenant's business perspective. As of REQ-361, Letflow has that equivalent
role; until a dispatch names it as this run's downstream reader, your report is read
directly by RELEASE-VALIDATOR, not by a persona layer.
```

(The task description's own citation-discipline instruction — "do not forward-reference
an agent that does not exist yet as though it already does" — is satisfied by "as of
REQ-361" plus "until a dispatch names it," which stays true both before and after
REQ-361 lands: before, no dispatch ever names it, because it doesn't exist; after, a
dispatch may.)

### 4.3 `.claude/agents/uat-runner.md` — new "Evaluating a `when:` branch" section

Insert as a new section immediately after "Reading the scenario corpus":

```markdown
## Evaluating a `when:` branch

A scenario file may carry `branches:` instead of a flat `steps:`/`expected_outcomes:`
list (see `docs/agents/uat-scenario-schema.md`). For such a file:

1. Read the branches top-to-bottom. For each branch (other than one with `when: else`),
   evaluate its condition against the run's actual, currently-observed facts:
   - `fact: role` means the role of the actor **currently authenticated in the browser
     session or API client you are driving for this branch's steps** — observe it for
     real (e.g. the role claim in the session/JWT you just authenticated with via
     `credential_source`, or the role attribute on the account you signed in as), never
     assume it from the actor name alone.
   - `op: eq` matches iff the observed fact equals `value` exactly (string, case
     sensitive).
   - `op: in` matches iff the observed fact equals one entry of the `value` list.
   - If no actor has been authenticated at all for this branch's steps (a step whose
     `actor:` entry is deliberately not signed in), the observed `role` is the literal
     value `unauthenticated`.
2. Run the **first** branch whose condition matches. Run only that one branch's `steps:`
   and check only that one branch's `expected_outcomes:` for this scenario execution —
   do not run every branch.
3. A branch with `when: else` matches iff no earlier branch matched. If no branch matches
   at all (a file authored without an `else` branch, and no earlier condition matched),
   record the scenario BLOCKED with the reason "no branch matched — fact values observed:
   <list>," not a silent skip.
4. Record the verdict against the branch actually run, naming the branch in your report
   (e.g. `EO-001 (branch: tenant_user_dashboard): PASS`), so RELEASE-VALIDATOR can see
   which path was exercised.
```

### 4.4 `docs/agents/workflows/WF-05_uat_run.md` — Step 1 addition

Insert as a new numbered item in "Step 1 — Readiness check" (after the existing item 2,
renumbering item 3 to item 4):

```markdown
3. Confirm this run's dispatch to UAT-RUNNER will carry an explicit environment target:
   `base_url` and `credential_source` (see `.claude/agents/uat-runner.md`'s "Environment
   target" section). Do not dispatch with an implicit/default target.
```

### 4.5 `docs/agents/workflows/WF-05_uat_run.md` — Step 2-3 addition

Insert as a new numbered item in "Step 2-3 — Run and report" (after the existing item 1,
renumbering the rest):

```markdown
2. For a scenario using the `branches:` construct (`docs/agents/uat-scenario-schema.md`),
   evaluate each branch's `when:` condition against this run's actual observed facts and
   run only the first matching branch, per `.claude/agents/uat-runner.md`'s "Evaluating a
   `when:` branch" procedure. Record which branch was run in the report.
```

### 4.6 `docs/agents/workflows/WF-05_uat_run.md` — "Deferred: business-owner personas"
section, trailing-sentence replacement

Replace the section's last sentence —

> Until then, RELEASE-VALIDATOR's own check (WF-04 Step 2) is the closest equivalent
> gate.

— with:

> As of REQ-361, this workflow runs with that persona-equivalent gate once a run's
> dispatch names it as this run's downstream reader; until named, RELEASE-VALIDATOR's own
> check (WF-04 Step 2) remains the closest equivalent gate.

---

## 5. AC1 verification mechanism (for ELIXIR-DEV)

Concrete, not asserted: after implementing §1/§2, run
`mix letflow.check_uat_scenario_schema` against the untouched
`test/fixtures/uat/scenarios/meridian/loan-origination-below-threshold.yaml` (and the
other 28 existing files) and quote its per-file line showing `ok?: true` / an `OK` report
line for that file, with **zero edits made to the file itself** — the file's own
`company_id: meridian` line, unedited, must resolve `scope` via §1.2's default rule and
pass SCHEMA-3 without a `scope:` key ever being added. That run + quoted output is AC1's
evidence, not an assertion that backward compatibility holds.

---

## 6. Open questions

- **OQ-1 — RESOLVED in REWORK ITERATION 1 (was: which YAML-parsing dependency to add).**
  Not a genuine open question: `mix.exs`'s `deps()` (line 64) already declares
  `{:yaml_elixir, "~> 2.11", only: :test}`, already used elsewhere in the codebase
  (`lib/mix/tasks/letflow.audit_issue_closures.ex` and several test-support/fixture
  modules). `check_requirements_registration`'s "adding one for a bug fix would be a
  library choice requiring REVIEWER sign-off" moduledoc comment describes why *that*
  task avoids depending on `yaml_elixir` for its own narrow purpose (a line-oriented
  text scan needs no real parser) — it does not mean the project has no YAML dependency.
  **Decision: §2's `check_file/1` parses each scenario file with
  `YamlElixir.read_from_file/1`, matching the codebase's existing convention (e.g.
  `test/support/simulation/scenario_fixture.ex`) — no new dependency, no new REVIEWER
  library sign-off needed.**
  §2.2's `check_scenario/2` doc above and §0's premise are updated to state this.

  **Scoping sub-question, also resolved:** `yaml_elixir` is currently `only: :test` in
  `deps()`. §2.4 wires the new task into `mix.exs`'s `"letflow.check"` alias, and
  `mix.exs` line 17 already declares `preferred_envs: ["letflow.check": :test]` —
  meaning `mix letflow.check` (and therefore `mix letflow.check_uat_scenario_schema` run
  standalone or via the alias) already executes in the `:test` Mix env. **Conclusion:
  the existing `only: :test` scoping on `yaml_elixir` is already sufficient — it does
  not need widening to `only: [:dev, :test]` or unscoping entirely.** The one case this
  does not cover is a developer invoking `mix letflow.check_uat_scenario_schema` inside
  an explicit `MIX_ENV=dev` (or `=prod`) shell rather than through the alias or its
  `preferred_envs`-driven default — that invocation would `UndefinedFunctionError` on
  `YamlElixir` the same way any other `only: :test` dependency would outside `:test`.
  This is consistent with how the rest of `letflow.check`'s `:test`-scoped tooling
  already behaves and is not a new risk this design introduces, so it is not carried
  forward as a further open question.
- **OQ-2 (per-step/per-outcome structural depth in §2.3).** SCHEMA-5 says branch
  `steps:`/`expected_outcomes:` reuse "the same shape as the pre-existing top-level
  ones" but this design does not fully re-specify field-by-field required-ness for
  `steps[].step`/`.actor`/`.action`/`.via` or `expected_outcomes[].id`/`.description`/
  `.verification`/`.on_fail` for either the pre-existing top-level shape or the new
  branch shape — genuinely unsure whether REQ-358's AC2 wants that full depth validated
  now or only the additive `scope`/`branches` surface (SCHEMA-3 through SCHEMA-6). Left
  to CODE-DESIGN-VALIDATOR/ELIXIR-DEV to decide scope of SCHEMA-2-equivalent checks
  reused inside branches; flagged rather than guessed.
- **OQ-3 (fact vocabulary beyond `role`).** §1.3 defines `role` as the only fact with a
  procedurally-defined evaluation method in §4.3. The requirement text's own example only
  needs `role`, so this design does not invent additional facts (session-authenticated
  tenant plan tier, feature flags, etc.) speculatively. If REQ-359/360/361 need another
  fact, that requirement should extend §4.3's procedure explicitly rather than assume an
  undefined fact name is self-evidently evaluable.
- **OQ-4 (`credential_source` resolution mechanism).** The requirement text names
  `ai-dala-infra/scripts/qa-login.sh` as "the" example, but this design does not know
  whether that script is expected to be invoked by UAT-RUNNER directly (shelling out),
  read as a static seeded-user list, or something else — `ai-dala-infra/` is outside this
  repository, so its actual interface was not read as part of this design pass (not
  listed in `artifacts_in`). §4.1's replacement prose deliberately stays generic
  ("obtain actor credentials from this source") rather than specifying an invocation
  mechanism CODE-DESIGNER cannot verify. Flagged for ELIXIR-DEV/REVIEWER to resolve
  against the actual script when implementing, not guessed here.
- **OQ-5 (branch-level `preconditions:` interaction with top-level `preconditions:`).**
  §1.3 says a branch's own `preconditions:` (if present) is used "instead of" the
  top-level list, but does not define whether it should instead *add to* the top-level
  list. Neither the requirement text nor the login-routing example needs this
  distinction (the §3 fixture has no branch-level preconditions at all), so it is left
  open rather than guessed; TEST-DESIGNER/ELIXIR-DEV should pick the simpler
  "replaces, does not merge" reading unless a concrete scenario needs otherwise, and
  should say so explicitly if they do.
