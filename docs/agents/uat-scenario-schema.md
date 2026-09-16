# UAT scenario schema

Canonical documented home for the shape of a UAT scenario file under
`test/fixtures/uat/scenarios/**/*.yaml`. Mechanically enforced (the mechanical
half only — see below) by `mix letflow.check_uat_scenario_schema`
(`lib/mix/tasks/letflow.check_uat_scenario_schema.ex`), wired into
`mix letflow.check`.

This document covers the two REQ-358 additions — `scope:` and the
`branches:`/`when:` step-level branching construct — plus the pre-existing
required top-level fields the mix task also checks. It does not re-derive the
full pre-existing per-step/per-expected-outcome shape field by field; see
`.claude/agents/uat-runner.md`'s "Reading the scenario corpus" section and the
worked examples in `test/fixtures/uat/scenarios/` for that.

## Pre-existing required top-level fields (unchanged)

`id`, `title`, `version` must each be present and a non-empty string. These
predate REQ-358; the mix task validates them alongside the new fields because
it validates the whole current shape, not only the additive surface.

## `scope:`

New **optional** top-level key on a scenario file:

```yaml
scope: platform            # or an open tenant-vertical/solution-pack identifier string
```

- Type: non-empty string. Not a closed enum. `"platform"` is the one reserved
  literal value with special meaning (see the classification rule below);
  every other value is an open tenant-vertical/solution-pack identifier
  chosen freely by whoever authors the scenario (e.g. `"lending"`,
  `"logistics"`, or — for a scenario ported from/tied to one of the three
  legacy R-Co companies — the literal company name, which today already
  functions as a de facto vertical identifier for those 11 files).

**Classification rule** (adapted verbatim in substance from R-Co's
`uat-scenario-schema-v1.1-addendum.md`): *if a business user of a tenant
installation would notice the behaviour being tested, the scenario keeps its
tenant-vertical `scope`; use `scope: platform` only when the actor is the
platform operator (`role: PLATFORM_ADMIN` or equivalent) or the platform
itself (a system actor acting outside any tenant's data, e.g. definition
promotion, cross-tenant isolation checks).*

This rule is **not mechanically checkable** — it requires judging what a
scenario's action actually represents. `mix letflow.check_uat_scenario_schema`
enforces only the mechanical half: is a `scope` value *resolvable* at all
(presence/non-emptiness/string-type — rule `SCHEMA-3`), never whether the
value chosen is the *correct* classification.

### `scope:` / `company_id:` relationship

`scope` and `company_id` coexist as two distinct axes, not one superseding
the other, with a default that derives `scope` from `company_id` when `scope`
is absent:

- `company_id:` stays what it already is: for tenant scenarios, the
  identifier of one of the (currently 3, legacy, R-Co-ported) literal
  companies whose actor ids and process definitions the scenario data is
  concretely bound to; for platform scenarios, the literal string
  `"platform"`.
- `scope:` is the new, broader, open classification: is this scenario's
  behaviour tenant-visible (and if so, which tenant-vertical/solution-pack)
  or platform-operator-visible. It exists because a real Letflow tenant is
  created dynamically and belongs to whatever solution pack it installed —
  a scenario authored against Letflow's own runtime (not a ported R-Co
  fixture) will often have no natural `company_id` at all, only a `scope`
  value naming the vertical/pack it's validating (e.g. `scope: lending` with
  no `company_id:` key).
- **Default (backward compatibility):** when `scope:` is absent from a
  scenario file, it is read as:
  1. `"platform"` if `company_id: platform` is present, else
  2. the literal value of `company_id:` if `company_id:` is present (each of
     the 3 legacy company names is treated, today, as its own one-member
     "tenant-vertical" — an accepted historical exception), else
  3. absent entirely — a scenario with neither `scope:` nor `company_id:` is
     not auto-classified; `SCHEMA-3` flags this as an error, because a
     scenario with no scope information at all is exactly the
     "invisible to classification" case the addendum rule exists to prevent.
- No existing file needs editing for this schema to apply: all 11 tenant
  files carry `company_id: <name>`, all 18 platform files carry
  `company_id: platform`; the default rule above classifies every one of the
  29 unchanged.
- New scenarios should write `scope:` explicitly rather than relying on the
  `company_id:` default, since `scope` is the field classification questions
  are actually asked of; `company_id:` becomes optional going forward for
  scenarios with no natural literal-company binding.

### Worked example — explicit `scope`, no `company_id`

```yaml
id: lending-fast-track-approval
scope: lending
title: Fast-track approval for a pre-qualified lending applicant
version: "1.0"
# ...
```

### Worked example — default derivation (today's 29 files, unchanged)

```yaml
id: meridian-loan-origination-below-threshold
company_id: meridian
# no scope: key -- resolves to scope: "meridian" via the default rule
title: Small loan (€50k) approved at L2 without committee
version: "1.0"
# ...
```

## Step-level branching (`branches:` / `when:`)

New **optional** key at step-group level: a named list of **branches**, each
gated by a `when:` condition, replacing (for scenarios that need it) a single
flat `steps:`/`expected_outcomes:` list with a `branches:` list of named
sub-paths. Backward compatible: a scenario with no `branches:` key behaves
exactly as before REQ-358 (flat `steps:`/`expected_outcomes:`, unconditional).

A file carries **either** top-level `steps:`+`expected_outcomes:` **or**
`branches:`, never both, never neither (rule `SCHEMA-4`).

### Shape

```yaml
branches:
  - name: platform_admin_dashboard          # string, unique within the file
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
      value: [TENANT_ADMIN, TENANT_USER]      # eq/in are the only allowed operators
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

The complete worked example above (all three branches together, exercising
`eq`, `in`, and `else`) is committed as a throwaway validation fixture at
`test/fixtures/uat/scenarios/_throwaway/login-routing-example.yaml` — see that
file's header comment for its scope and lifecycle.

### Key/shape rules

- `branches:` is a **list**, evaluated top-to-bottom. Each entry: `name`
  (string, unique within the file — used only in the UAT report, e.g.
  `EO-001 (branch: platform_admin_dashboard)`), `when` (a condition — see
  below, or the literal string `else`), `steps:` (same shape as today's
  top-level `steps:`), `expected_outcomes:` (same shape as today's top-level
  `expected_outcomes:`), and optionally `preconditions:` (same shape as
  today's top-level `preconditions:`, scoped to this branch only — omit to
  reuse the file's top-level `preconditions:` unchanged; a branch's own
  `preconditions:`, if present, *replaces* the top-level list rather than
  merging with it).
- `when:` condition shape (deliberately narrow — **not** a general expression
  language):
  ```yaml
  when:
    fact: <string>     # a runtime-observable fact name, e.g. "role"
    op: eq | in         # the ONLY two allowed operators
    value: <string>     # for op: eq
    # or
    value: [<string>, ...]   # for op: in
  ```
  Allowed operators: **`eq`** (fact value equals `value` exactly,
  case-sensitive string comparison) and **`in`** (fact value is a member of
  the `value` list, same comparison rule). No boolean composition
  (`and`/`or`/`not`), no numeric/relational operators, no nested conditions.
  This is the entire allowed vocabulary — anything requiring more is an
  explicit signal to escalate to `REVIEWER` before extending the construct,
  not to quietly grow it.
  - `when: else` (the bare literal string, not a mapping) is reserved and
    means "matches iff no earlier branch in this file's `branches:` list
    matched." At most one `else` branch is allowed per file, and if present
    it must be the **last** entry (`SCHEMA-6` enforces both mechanically).
- **Facts** are named, runtime-observable values UAT-RUNNER is expected to
  already have or be able to obtain mid-run. Exactly one fact has a
  procedurally-defined evaluation method today: **`role`** — the
  authenticated session's role, or the literal string `"unauthenticated"`
  when no session is authenticated (i.e. `when: {fact: role, op: eq, value:
  unauthenticated}` is an equivalent, more explicit spelling of what `when:
  else` is shorthand for in the specific case of "not signed in" — both are
  legal). See `.claude/agents/uat-runner.md`'s "Evaluating a `when:` branch"
  section for the runtime evaluation procedure. Any other `fact:` name is
  legal syntactically (this schema does not enumerate a closed fact
  vocabulary) but only `role` has a defined evaluation method — a scenario
  using an undefined fact name must say, in its own `description`, how a
  human/agent reading it would obtain that fact's value; the mechanical check
  cannot and does not check this (semantic, not mechanical).

## Mechanical rules enforced by `mix letflow.check_uat_scenario_schema`

Each a distinct `rule` tag in that task's output — see the module's own
`@moduledoc` for the authoritative list (`SCHEMA-0` through `SCHEMA-6`). In
summary: the corpus is non-empty; each file parses as YAML; `id`/`title`/
`version` are present; a resolved `scope` exists; a file uses exactly one of
`steps:`+`expected_outcomes:` / `branches:`; each branch has a valid `name`/
`when`/`steps:`/`expected_outcomes:` shape; and at most one `when: else`
branch exists, last in the list. The task never checks the *semantic*
correctness of a `scope` classification or a `fact` choice — see the
classification-rule note above.
