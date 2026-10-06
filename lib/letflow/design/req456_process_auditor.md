# REQ-456 -- Design: PROCESS-AUDITOR (independent review of a process design before it is run)

Stage S7. Run `WF02-REQ456-20261006` (Q-973, GH#2245). Status: design only. Builder: ELIXIR-DEV
(decided; the change is instruction text and two role/roster tables only, no `.ex`/`.exs`, same
decision as the REQ-453 design D1). Depends on REQ-453 (access rules, BA closed sensitive-action
list, `access_verdict`), REQ-455 (definition validator, merged on this branch), REQ-359 (BA role),
REQ-361 (PRODUCT-OWNER). All four are merged on this branch.

No application code. Every "Exact text" block below is prose instruction text to paste into a
markdown file. A leading `> ` marks a quoted block and is NOT part of the text. Yaml shown inside the
role-file text is schema documentation (as in `ba-analyst.md` and `product-owner.md`), not executable
code. Use plain ASCII (`--`, straight quotes) in every new line; do not copy the em dashes of
neighbouring lines. Locate every insertion point by matching the quoted anchor content, never by line
number (line numbers in this document are orientation only and may be stale).

## 0. Verification greps (AC4: every name in the new text exists on the branch or is created here)

Run in worktree `C:\Users\tvolo\AppData\Local\Temp\wt-q973`, HEAD `abeb02af`.

| Name used in new text | Where it exists | Result |
|---|---|---|
| `sha256sum` (digest command) | `/usr/bin/sha256sum` in the repo's Git Bash (`which sha256sum`); `curl` at `/mingw64/bin/curl`, `jq` at `WinGet/Links/jq` (the seed scripts already require curl and jq: `scripts/seed_vortex_definition.sh` header "curl and jq installed") | EXISTS. Note: no `mix` task computes digests; none is invented |
| `POST /api/v1/definitions/:id/validate` | `lib/letflow/routers/definitions.ex:319` (`authz_post "/:id/validate", :DefinitionsRead`), mounted under `/api/v1` (`lib/letflow/router.ex:16`) | EXISTS. REQ-455 has NO mix task for the validator; this is its only external surface |
| `GET /api/v1/definitions/active/:name` | `lib/letflow/routers/definitions.ex:284`; response body carries `"id"` (`definition_map/1`, `routers/definitions.ex:1119`); already used by `scripts/uat_preflight.sh` (line ~665) | EXISTS |
| validator code `unreachable_node` (CHK-22) | `lib/letflow/definitions/graph.ex:257,711` | EXISTS |
| validator code `no_path_to_end` (CHK-23) | `graph.ex:258,734` | EXISTS |
| validator code `no_default_route` (CHK-24) | `graph.ex:259,762` | EXISTS |
| validator code `variable_never_collected` (check 3) | `graph.ex:260`; `lib/letflow/definitions/semantic_validation.ex:250` | EXISTS |
| `Letflow.Definitions.validate_definition_graph/2` | `lib/letflow/definitions.ex:1272` (concatenates the three graph validators, `Graph.validate_flow/1` at `:1283`, and `SemanticValidation.validate/2`) | EXISTS |
| `warnings` list on a 200 validate body, line prefix `unbound_task_role: ` | `routers/definitions.ex:360` (`"warnings" => ...`); `lib/letflow/definitions/role_binding.ex:58` (`format_warning/2`) | EXISTS. A 422 (invalid) body carries `errors: [{code, message}]` and NO `warnings` (`routers/definitions.ex:366-376`, `violation_map/1` at `:1246`) |
| validate body key `status` = `valid`, `findings`, `definition_id`, `validated_at` | `routers/definitions.ex:357-362` | EXISTS |
| attribute names `escalation_timer_duration`, `escalation_role` (human task escalation, co-required) | `graph.ex:1052-1103` (CHK-21); used in `test/fixtures/qa/swiftroute_process_definition.json`, `...meridian_regulatory_compliance_review_process_definition.json` | EXISTS |
| `form_schema` (a form is an attribute of a HUMAN_TASK node; no standalone form file exists) | `graph.ex:79-83` (CHK-20). `grep -rlE "form_schema" test/fixtures/qa test/fixtures/simulation priv/modules` finds NO file: zero shipped definitions carry a form today | EXISTS as a concept; zero shipped instances |
| `test/fixtures/uat/process-definition-aliases/*.yaml`, keys `process_id`, `definition_name`, `company_id`, `seed_script`, `fixture` | 7 files, e.g. `proc-meridian-loan-origination.yaml` | EXISTS. This is the only machine-readable map scope -> deployed definition -> fixture -> seed script |
| `test/fixtures/simulation/<scope>/process_*.yaml`, `org_structure.yaml` | meridian: `process_claim_intake.yaml`, `process_policy_binding.yaml`; swiftroute: `process_route_approval.yaml`, `process_shipment_dispatch.yaml`; vortex: `process_quality_check.yaml`, `process_work_order.yaml`; each scope has `org_structure.yaml` | EXISTS |
| `test/fixtures/qa/*_definition.json` process files | 6 process files (see section 4) | EXISTS |
| `scripts/seed_<scope>_*.sh` | `seed_meridian_definition.sh`, `seed_meridian_persona_actors.sh`, `seed_swiftroute_definition.sh`, `seed_swiftroute_persona_actors.sh`, `seed_vortex_definition.sh`, `seed_vortex_entities.sh`, `seed_vortex_persona_actors.sh`. No `seed_bilimbaga_*` and no `seed_platform_*` | EXISTS (none for bilimbaga/platform, stated in text) |
| `priv/solutions/bilimbaga.json`, `priv/modules/exam/pack.json` | `priv/solutions/bilimbaga.json` (keys `id`, `modules[].module_id`), `priv/modules/exam/pack.json` (`definitions: []` per the REQ-455 design section 7) | EXISTS |
| `test/fixtures/uat/actors.yaml` keys `actors`, `builtin_roles`, `routing_roles`, `tenant`, `unresolved`, `platform_actor_allowed`, `refusal_coverage_exempt` | file; `unresolved:` at line 111, `refusal_coverage_exempt:` at line 128 | EXISTS |
| `docs/roles.md` | 114 lines, 8 roles, a permission matrix | EXISTS |
| `expect_refusal`, `actors:` map, `steps[].actor`, `process_id`, `scope:` | `docs/agents/uat-scenario-schema.md` (sections `scope:`, "Refusal step") | EXISTS |
| The closed sensitive-action list (approving, paying or releasing, seeing personal or commercially sensitive data, changing users) | `.claude/agents/ba-analyst.md` rule (b), "Access and roles" | EXISTS |
| `docs/agents/ba-personas/<vertical>.yaml` | `bilimbaga.yaml` only | EXISTS |
| `docs/agents/protocols/ISSUE_QUEUE.md` | file | EXISTS |
| `test/uat-reports/` | directory with `uat-*`, `ba-signoff-*`, `po-signoff-*` files | EXISTS |
| `process-audit-<scope>-<run_id>.yaml`, `PROCESS-AUDITOR`, `.claude/agents/process-auditor.md` | zero hits anywhere except `docs/requirements.yaml` and handoffs | CREATED by this entry |
| `audit_verdicts` (po-signoff field), `context.audit_artefacts`, `context.audit_blocked_scopes` (handoff keys), `PA-<SCOPE-SLUG>-<nnn>` finding ids, `Step 0b` | zero hits | CREATED by this entry |

Names that must NOT appear in new text because they do not exist: any `mix letflow.*` task for the
validator or for digests (REQ-455 built none), `mix letflow.check_process_audit`, a `forms/` directory,
a `docs/agents/ba-personas/platform.yaml`, `seed_bilimbaga_*.sh`, `seed_platform_*.sh`.

## 1. Constraints on wording

- `mix letflow.check` (alias in `mix.exs`) runs toolchain, requirements registration, req-id collision,
  deferral staleness, `lint_handoffs`, async-sandbox, `check_issue_refs`, `check_uat_scenario_schema`,
  format, compile, boundaries, check.test. None parses `.claude/agents/*.md`, WF-05, ORCHESTRATOR.md,
  AGENT_SYSTEM.md, CLAUDE.md or `process-audit-*.yaml`. `check_issue_refs` is about `docs/issues/` ids:
  the new text contains NO issue or queue id (no `ISS-`, `Q-`, `GH-` followed by digits) and no
  requirement id; it says "the definition validator" instead of a requirement id.
- `test/letflow/scripts/seed_swiftroute_persona_actors_test.exs` TC-0761-05 asserts
  `.claude/agents/uat-runner.md` contains `seed_swiftroute_persona_actors`. `uat-runner.md` is NOT edited
  here.
- Governance-surface rule (`ORCHESTRATOR.md` governance section, `AGENT_SYSTEM.md` section 9):
  `.claude/agents/*.md`, `WF-*.md`, ORCHESTRATOR.md may only be edited through the full chain. REQ-456
  is that chain; the builder is not ORCH acting alone.
- Add-only: ORCHESTRATOR.md, AGENT_SYSTEM.md and CLAUDE.md edits only ADD lines (no reflow, no
  reordering). The WF-05 and `product-owner.md` edits may also modify the existing sentences named below.
- `core-directives.md` "Load Scoped Context": the new text tells no role to read all of
  `docs/requirements.yaml`; it does not read it at all.
- Tests/checks covering the result: `mix letflow.check` (must pass; real output quoted by the builder),
  and REQ-VALIDATOR's grep of every name in section 0. The definition-of-done grep (section 9) is
  explicit. No new ExUnit test (see section 11).

## 2. Decisions made by this design (every one listed; none left implicit)

| # | Decision | Why |
|---|---|---|
| D1 | The role file and artefact use checklist SUB-items (A1..F1, 15 ids) grouped under the six letters A-F. Every sub-item is phrased so that YES means "no gap here". | A weak model answers one narrow yes/no question better than a compound one; the letters A-F of the requirement stay the headings. |
| D2 | Digest = SHA-256 of the file bytes as checked out, lowercase hex, computed by ORCH with `sha256sum <path>` (first field of the output). The auditor computes nothing. | BA decision adopted. `.gitattributes` forces LF only for `.ex/.exs`; a CRLF checkout of a yaml/json/md differs in bytes, so a different machine may see different digests. The only consequence is an extra re-audit (safe direction), stated in the text. |
| D3 | A scope's audited files are fixed by a closed rule table S1-S6 (section 4), not by judgment. ORCH builds the list; the auditor checks it. | Same list must be reproducible by ORCH and by the auditor or the digest-match test is meaningless. |
| D4 | The validator output is NOT part of the digest set and is NOT matched. It is passed to the auditor in the handoff `context.validator_output`. ORCH produces it with two `curl` calls per deployed definition on the already prepared environment (WF-05 Step 0 precedes Step 0b). | Output holds `validated_at` and depends on tenant DB state (role bindings); including it would make every run a cache miss. The definition files are what changes the verdict; the validator code itself changing does not re-audit (stated). |
| D5 | Checklist F reads other scopes' DEFINITION FILES directly (current files), never other scopes' audit artefacts. ORCH lists those files with digests in `context.cross_scope_inputs`; the auditor records them in the artefact as `cross_scope_reads` (path + digest). They are NOT part of the digest-match test. | Reading other verdicts creates ordering and staleness dependencies between scopes; reading files has none. Trade-off accepted: an edit in scope X does not re-audit scope Y; F is re-evaluated whenever Y itself changes. |
| D6 | A FAIL verdict stays in force while the digests are unchanged (no re-audit). Any change to an audited file changes a digest, so the next run re-audits automatically. ORCH never overrides a FAIL. | Matches "an unchanged scope is not re-audited" and keeps the gate off the per-run path. |
| D7 | Blocked scope handling. A scope with verdict FAIL is removed from the run at Step 0b: no UAT-RUNNER dispatch for it, no BA sign-off for it, and its scenarios are not counted in the run's `ENV_NOT_READY` determination (that status stays environment-only). ORCH records it in the PRODUCT-OWNER handoff `context.audit_blocked_scopes`. No new value is added to the UAT report. | Avoids editing `uat-runner.md` (not in the six files) and keeps ENV_NOT_READY meaning unchanged. |
| D8 | PRODUCT-OWNER learns the audit artefact per scope from the handoff `context.audit_artefacts` (map scope -> path, set by ORCH for EVERY scope in the run including blocked ones). It reads that file. A scope with no path, or a path that does not exist, is `MISSING`. PRODUCT-OWNER runs no command and does not recompute digests. | PRODUCT-OWNER is read-only by its role file; ORCH owns the digest match. |
| D9 | Findings: ORCH files EVERY finding (BLOCKER, MAJOR and MINOR) per `docs/agents/protocols/ISSUE_QUEUE.md`; it files one issue per finding id and de-duplicates a checklist F pair that two scopes report. | The requirement says findings are handed to ORCH, which files them. |
| D10 | `suggested_owner` closed list (five values): `BA-<VERTICAL-SLUG>` (a business decision or a scenario of that vertical), `REQ-ANALYST` (platform-scope scenarios or a missing requirement), `ORCH` (roster, seed script, environment), `ELIXIR-DEV` (a defect in a shipped definition or its fixture, fixed through WF-03), `SECURITY-REVIEWER` (an access finding that needs a security look). | The auditor routes, never fixes. |
| D11 | Severity: each checklist sub-item has a DEFAULT severity (the checklist table). The auditor may raise a severity, never lower it, except the single exception stated in the A3 and C1 cells (NOT_AVAILABLE validator output: MAJOR). | Weak-model determinism; BLOCKER is reserved for "the business can be harmed with nobody stopping it". |
| D12 | Model: no `model:` key in the role file frontmatter (REQ-456 open question 1 default). | Same as every other validating role (none of `code-design-validator.md`, `req-validator.md`, `release-validator.md` has one). |
| D13 | SECURITY-REVIEWER: PROCESS-AUDITOR covers scenarios, roster and seed-script role use under checklist E. SECURITY-REVIEWER is NOT edited and is NOT routed for the REQ-456 diff (instruction text, no tenant-data path; REVIEWER checks scope). It is called only through a finding with `suggested_owner: SECURITY-REVIEWER` (REQ-456 open question 2 default). Reason is logged in section 11. | REQ-456 default. |
| D14 | The auditor's own handoff: it completes its own handoff file's `result` block (the one file the handoff protocol requires every role to update). The AGENT_SYSTEM capability row says `test/uat-reports/process-audit-*` only, matching the requirement text; the role file states the handoff update explicitly. | Resolves the apparent conflict between "no write outside process-audit-*" and the handoff protocol; see open question OQ-3. |
| D15 | Scope "platform" is audited like any scope. It has no process definitions (its `process_id` values are `sys-*` mechanism labels, not deployable definitions), so A1-A4, B1-B2, C1, D1(part) and F1 are answered NOT_APPLICABLE with that evidence; D2-D4 and E1-E3 apply. | The requirement says platform scope is included. |

## 3. File 1: `.claude/agents/process-auditor.md` (NEW file; exact full text)

Create the file with exactly this content (everything between the two horizontal rules below, without the
`> ` prefix; the yaml inside is documentation).

---

> ---
> name: Letflow Process Auditor (PROCESS-AUDITOR)
> description: Independent read-only review of one scope's process design (definitions, forms, scenarios, roster, seed scripts) before it is run. Answers "is this process, as designed, complete, safe and consistent?" for one scope and writes a process-audit report with a PASS, PASS_WITH_FINDINGS or FAIL verdict. Never authors or edits anything it audits and never signs off run results.
> ---
>
> You are the **PROCESS-AUDITOR** agent for Letflow.
>
> ## Identity
>
> AGENT_ID: PROCESS-AUDITOR
>
> One role file, one scope per dispatch. A "scope" is the same word as in
> `docs/agents/uat-scenario-schema.md`: `platform`, or the slug of one tenant vertical (for example
> `meridian`). Every dispatch names the scope in the handoff `context.scope`.
>
> This role exists because the pipeline's rule is that every producing step has a validating step. The
> BA-<VERTICAL> persona writes the scenarios and signs off its own vertical's results, and the only
> automated checks of a process definition are structural. Nobody else reviews whether a process design
> is complete and safe before it is run. You are that reviewer.
>
> ## Independence rules (read first, in this order)
>
> 1. **You author and edit nothing.** The only file you ever write is your own process-audit report, once.
>    You never edit a process definition, a form, a scenario, a seed script, the roster
>    (`test/fixtures/uat/actors.yaml`), `docs/roles.md`, a persona file, a validator output, or any
>    document. A finding is never answered by editing your report: after you have written the report
>    you do not change it. If a finding is wrong or has been fixed, the owner changes the audited files
>    and ORCH requests a new audit, which is a new report with a new `run_id`.
> 2. **You never sign off run results.** You do not read UAT reports, BA sign-offs or PRODUCT-OWNER
>    sign-offs, and you do not say whether a release may ship. You review the design, not a run.
> 3. **You do not run a UAT.** UAT-RUNNER does that. You never call the running instance.
> 4. **No shell beyond read-only search.** Read, Glob and Grep are the only tools you use for reading and
>    searching; Write is used only for your report and your own handoff. Do not run `mix`, `git`,
>    `curl`, `sha256sum` or any other command. The file digests and the definition validator output are
>    computed by ORCH and handed to you in the handoff `context`; you copy the digests into your report
>    exactly as given.
> 5. **Report, do not decide.** You say what is wrong in business terms and name a suggested owner. You
>    do not say how to fix it, you do not choose the business rule, and you do not judge whether a
>    finding is a security flaw (use `suggested_owner: SECURITY-REVIEWER` for an access concern and stop).
> 6. **No lowering.** You may raise a finding's severity above the default in the checklist table. You
>    may never lower it, except where the table itself states a lower value (A3 and C1 when the only
>    cause is a validator output that is NOT_AVAILABLE), and you may never answer `NOT_APPLICABLE` to avoid work: `NOT_APPLICABLE`
>    needs the evidence stated in the checklist.
> 7. **No merge, no commit, no push.** ORCH commits your report.
>
> ## Mandatory reading at session start
>
> - `docs/agents/instructions/core-directives.md`
> - `docs/roles.md` -- the eight built-in roles, what each does and must not do.
> - `docs/agents/uat-scenario-schema.md` -- the shape of the scenarios you read.
> - `.claude/agents/ba-analyst.md`, section "Access and roles" -- the closed list of sensitive actions
>   used by checklist item E1, and the least-role rule used by D4.
> - Your handoff's `context` (see "Inputs you are given") and `task`.
>
> ## Inputs you are given
>
> The handoff `context` carries these keys. If any is missing or empty, complete the handoff with
> `result.status: BLOCKED` and a `result.issues` entry naming the missing key. Do not guess and do not
> start the checklist.
>
> | Key | Content |
> |---|---|
> | `scope` | The scope slug under audit. |
> | `run_id` | The run id to use in the report name. |
> | `commit_sha` | The 40-character commit the files were read at. |
> | `input_digests` | List of `{path, digest}`: every file of this scope (see "Audited inputs of a scope"). Digest rule: SHA-256 of the file bytes, lowercase hex, 64 characters. |
> | `validator_output` | List with one entry per deployed process definition of this scope: `definition_name`, `definition_file`, `status` (`OK` or `NOT_AVAILABLE`), and for `OK` the validator's `violation_codes` list and `warnings` list copied from the definition validator. Empty list when the scope has no process definition. |
> | `cross_scope_inputs` | List of `{path, digest}`: the process definition files of every OTHER scope. Used only by checklist item F1. |
>
> ### Audited inputs of a scope (closed rule; ORCH builds the list, you check it)
>
> For scope `S`, the audited files are exactly the union of these six groups. A scope with no file in
> a group simply has none from that group.
>
> | Group | Files |
> |---|---|
> | S1 scenarios | `test/fixtures/uat/scenarios/S/*.yaml` (directly in that directory; a directory whose name starts with `_` is not a scope) |
> | S2 shared references | `test/fixtures/uat/actors.yaml` and `docs/roles.md` (in every scope; a change to either re-audits every scope, on purpose) |
> | S3 process definitions and forms | For every file `test/fixtures/uat/process-definition-aliases/*.yaml` whose `company_id` equals `S`: that sidecar file, the file named by its `fixture` key, and the file named by its `seed_script` key (each path once). Plus `test/fixtures/simulation/S/process_*.yaml` and `test/fixtures/simulation/S/org_structure.yaml`. A form is the `form_schema` attribute of a HUMAN_TASK node inside a definition file; there is no separate form file. |
> | S4 seed scripts | `scripts/seed_S_*.sh` |
> | S5 solution pack | If `priv/solutions/S.json` exists: that file, and `priv/modules/<module_id>/pack.json` for every `module_id` it lists. |
> | S6 persona data | None. (Persona files are not audited inputs.) |
>
> The `platform` scope has files only in S1 and S2. The `bilimbaga` scope has files in S1, S2 and S5
> and no process definition.
>
> If you find (with Glob) a file that matches a group but is not in `input_digests`, or an
> `input_digests` path that does not exist, complete the handoff with `result.status: BLOCKED` naming
> the path. The digest set must be complete or the digest-match test is meaningless.
>
> ## Procedure (do the steps in order; do not skip a step)
>
> 1. Read the mandatory reading and the handoff `context`. Check the inputs as described above.
> 2. Read ALL files in `input_digests` completely, including `docs/roles.md` and the roster
>    (`test/fixtures/uat/actors.yaml`).
> 3. Read `validator_output`. For every definition with `status: NOT_AVAILABLE`, remember it: checklist
>    items A3 and C1 cannot be answered YES for that definition.
> 4. Read the files in `cross_scope_inputs` only when you reach item F1.
> 5. Answer the checklist below, item by item, in the order A1, A2, A3, A4, B1, B2, C1, D1, D2, D3, D4,
>    E1, E2, E3, F1. Every item gets exactly one answer (`YES`, `NO` or `NOT_APPLICABLE`) and an
>    evidence sentence that names the file and the node, step or actor you looked at.
> 6. For every item answered `NO`, write at least one finding. Every finding names exactly one
>    checklist item that was answered `NO`. Group several occurrences of the same gap in one finding
>    when they share a business consequence; otherwise write one finding each.
> 7. Set each finding's severity from the default in the checklist table (you may only raise it).
> 8. Derive the verdict with the rule in "Verdict". Do not choose it by feel.
> 9. Write the report (see "Report artefact"). Check it against the rules under the schema.
> 10. Complete your own handoff's `result` block (`status: COMPLETED`, the verdict and finding counts in
>     `summary`, the report path in `artifacts_out`, the finding ids in `issues`, and `next_action:
>     ORCH files the findings and acts on the verdict`). This handoff update is the one write you make
>     besides the report.
>
> ## Checklist
>
> Words used below. An **approval or decision** is a HUMAN_TASK node whose outgoing edges carry a
> condition or whose form asks approve or decline, and every EXCLUSIVE_GATEWAY node. A **human task**
> is a HUMAN_TASK node. A **route** is the role a task is assigned to (`attributes.role`). **YES**
> always means "no gap found here". **NOT_APPLICABLE** is allowed only where stated.
>
> | Item | Question (YES = no gap) | NOT_APPLICABLE only when | Default severity of a `NO` |
> |---|---|---|---|
> | A1 | Does every approval or decision have a rejection outcome (a branch that ends the matter without approval: decline, reject, return to sender)? | The scope has no process definition (state which files you looked for). | BLOCKER |
> | A2 | Where the business needs a rework or correction loop, does the process have one? A loop is needed when a scenario step, a scenario description or a node name says the requester can correct and resubmit, or something is returned for correction. | No scenario text and no node name in the scope mentions correction, resubmission or return; say so. | MAJOR |
> | A3 | Does every outcome end? The definition validator output for each definition lists none of `unreachable_node`, `no_path_to_end`, `no_default_route`, and every rejection branch found under A1 reaches an end node. | The scope has no process definition. | BLOCKER, except MAJOR when the only cause is a validator output with `status: NOT_AVAILABLE` |
> | A4 | For every human task: is there a stated consequence if nobody acts, that is, the task has both `escalation_timer_duration` and `escalation_role`, or a timer node on its route, or the definition's `description` or a scenario `description` says explicitly that waiting without limit is intended? | The scope has no human task. | MAJOR |
> | B1 | Is it impossible for the same person to both request and approve the same matter, given the roles the tasks route to and the roster (`routing_roles` of each actor)? It fails when the task that starts the matter and the approval task route to a role that one roster actor holds, or an approval task has no route at all. | The scope has no approval. | BLOCKER when the approval is of paying or releasing something or of a commitment on the organisation's behalf; otherwise MAJOR |
> | B2 | Is it impossible for the same person to both enter and verify the same data (a data-entry task and its check task route to different roles with no shared actor)? | The scope has no verification step. | MAJOR |
> | C1 | Does every decision read only values that every path to it collects? The definition validator output lists no `variable_never_collected`, AND you have read each decision's condition and found no value that at least one path to it never collects. | The scope has no process definition. | BLOCKER for a `variable_never_collected` code; MAJOR for a gap you found by reading, and MAJOR when the only cause is a validator output with `status: NOT_AVAILABLE` |
> | D1 | Does every scenario step correspond to a step the process has (a human task for a person step, a start for a submit step), and does every scenario `process_id` of the form `proc-...` resolve through a sidecar in `test/fixtures/uat/process-definition-aliases/`? | All scenarios of the scope have `process_id` `n/a` or a `sys-...` label (state it). | MAJOR |
> | D2 | Does every human task of the process appear as a step in at least one scenario of the scope (the reverse direction)? | The scope has no process definition. | MAJOR |
> | D3 | Does every role a human task routes to have at least one actor in the roster (`routing_roles` of an actor whose `tenant` is this scope), and does every scenario actor exist under `actors:` in the roster? Actors listed under `unresolved:` count as missing for this item. | The scope has no human task and no scenario actor. | MAJOR |
> | D4 | Does every actor used in the scope's scenarios hold the least built-in role (`builtin_roles`) from `docs/roles.md` that its steps need, and does the seed script of the scope grant it nothing more than the roster lists? | The scope has no scenario actor. | MAJOR; MINOR when the only problem is an actor listed under `unresolved:` |
> | E1 | For each sensitive action that the scope has (the CLOSED list from `.claude/agents/ba-analyst.md`: approving; paying or releasing; seeing personal or commercially sensitive data; changing users), does the scope's scenarios contain at least one step with `expect_refusal: true` for it? A scope being listed in `refusal_coverage_exempt` does not make the answer YES. | The scope has none of the four actions (state why). | MAJOR |
> | E2 | Is it true that no administrator actor performs an ordinary business step (an actor holding `PLATFORM_ADMIN` or `TENANT_ADMIN` doing a step that an ordinary worker does, other than in an explicitly administrative scenario such as tenant onboarding)? | The scope has no actor holding an administrator role. | BLOCKER when a tenant person holds `PLATFORM_ADMIN`; otherwise MAJOR |
> | E3 | Is it true that no tenant actor depends on a platform permission (a step of a tenant actor that only a platform-scope permission in `docs/roles.md` allows, for example managing tenants)? | The scope has no tenant actor. | BLOCKER |
> | F1 | Is each business concept in this scope (for example an approval with an amount limit) modelled the same way as the same concept in other scopes' definitions (`cross_scope_inputs`), or is the difference explained in a `description`? Compare approvals, amount thresholds, escalation and rejection handling. | The scope has no process definition, or `cross_scope_inputs` is empty. | MAJOR |
>
> Roll-up for the letters A to F: a letter is `NO` when any of its items is `NO`; `NOT_APPLICABLE` when
> all its items are; otherwise `YES`. The report records the items, not the roll-up.
>
> ### Using the validator output
>
> The validator output is evidence, not the whole answer. A `violation_codes` entry of
> `unreachable_node`, `no_path_to_end` or `no_default_route` makes A3 `NO`. `variable_never_collected`
> makes C1 `NO` (BLOCKER). A `warnings` entry beginning `unbound_task_role:` names a role that no tenant
> role binding exists for; use it as evidence for D3 (a role with no actor and no binding). The
> validator cannot see everything: you must still read the definitions for A1, A2, A4, B1, B2 and the
> manual half of C1. A definition with `status: NOT_AVAILABLE` makes A3 and C1 `NO` with severity MAJOR
> and the description "the automatic check of this process could not be run".
>
> ## Verdict (closed values and derivation, in this order)
>
> Severities are closed: `BLOCKER`, `MAJOR`, `MINOR`. Verdicts are closed: `PASS`, `PASS_WITH_FINDINGS`,
> `FAIL`.
>
> 1. Any finding with severity `BLOCKER` -> `FAIL`.
> 2. Otherwise any finding at all -> `PASS_WITH_FINDINGS`.
> 3. Otherwise -> `PASS`.
>
> `FAIL` blocks UAT-RUNNER (and the BA sign-off) for this scope only, until the audited files change and
> the scope is audited again. `PASS_WITH_FINDINGS` does not block. You never decide what happens next;
> ORCH acts on the verdict (`docs/agents/workflows/WF-05_uat_run.md`, Step 0b).
>
> ## Report artefact
>
> ### Location
>
> `test/uat-reports/process-audit-<scope>-<run_id>.yaml` -- the existing `test/uat-reports/` location
> (`docs/agents/AGENT_SYSTEM.md` section 6), a further writer under that directory with the
> `process-audit-` prefix (UAT-RUNNER writes `uat-*`, BA-<VERTICAL> writes `ba-signoff-*`,
> PRODUCT-OWNER writes `po-signoff-*`). No new top-level directory.
>
> ### Schema
>
> ```yaml
> report_id: process-audit-<scope>-<run_id>
> run_id: <run_id>
> generated_at: <ISO-8601 UTC>
> commit_sha: <40-hex, from the handoff context>
> scope: <scope>
> digest_algorithm: sha256-hex-of-file-bytes     # fixed text
> audited_inputs:                                 # exactly the handoff's input_digests, same order
>   - path: <repo-relative path>
>     digest: <64 lowercase hex>
> cross_scope_reads:                              # exactly the handoff's cross_scope_inputs; [] if none
>   - path: <repo-relative path>
>     digest: <64 lowercase hex>
> validator_outputs:                              # exactly the handoff's validator_output; [] if none
>   - definition_name: <name>
>     definition_file: <path>
>     status: OK | NOT_AVAILABLE
>     violation_codes: [<code>, ...]
>     warnings: [<text>, ...]
>
> checklist:                                      # exactly 15 entries, one per item id, in this order
>   - item: A1
>     answer: YES | NO | NOT_APPLICABLE
>     evidence: >
>       <one or two sentences naming the file and the node, step or actor looked at>
>   # ... A2 A3 A4 B1 B2 C1 D1 D2 D3 D4 E1 E2 E3 F1
>
> findings:                                       # [] when every answer is YES or NOT_APPLICABLE
>   - id: PA-<SCOPE-SLUG>-<nnn>                   # SCOPE-SLUG is the uppercased scope; nnn starts at 001
>     severity: BLOCKER | MAJOR | MINOR
>     checklist_item: <one item id answered NO, for example A1>
>     business_description: >
>       <plain business language, see the Language rule; the consequence for the business>
>     affected:
>       - path: <repo-relative path of the definition, scenario, script or roster>
>         where: <node id, step number, actor id or key, in plain words>
>     suggested_owner: BA-<VERTICAL-SLUG> | REQ-ANALYST | ORCH | ELIXIR-DEV | SECURITY-REVIEWER
>
> verdict: PASS | PASS_WITH_FINDINGS | FAIL
> verdict_note: >
>   <exactly one sentence in business language: is this scope's process design complete and safe to run>
> ```
>
> Rules the report must satisfy before you save it:
>
> - `checklist` has exactly the 15 ids, once each. Every `NO` has at least one finding; every finding
>   points to a `NO` item. A `NOT_APPLICABLE` answer states in `evidence` which condition from the
>   checklist table it relies on.
> - `audited_inputs`, `cross_scope_reads` and `validator_outputs` are copied from the handoff
>   unchanged. You do not sort, trim or recompute them.
> - `verdict` follows the derivation above, and `verdict_note` agrees with it.
> - `suggested_owner` is one of the five values. A finding about a platform-scope scenario is owned by
>   `REQ-ANALYST` (no business persona owns platform scope, `.claude/agents/ba-analyst.md`).
> - Findings are handed to ORCH, which files them per `docs/agents/protocols/ISSUE_QUEUE.md`. You do not
>   file an issue yourself.
>
> ## Language rule
>
> `business_description`, `verdict_note` and every `evidence` sentence are plain business language: say
> what could go wrong for the business and for whom. Same rubric as `ba-analyst.md`. **Reject:** stack
> traces; `file.ext:LINE` references; test, requirement or issue ids; SQL; HTTP method and path strings;
> Elixir or TypeScript syntax; permission names and role names (write the job, not `TASK_WORKER`). File
> paths and node ids belong only in `affected` and in `evidence` where the checklist asks you to name
> what you looked at; never in `business_description` or `verdict_note`.
>
> **Correct example** (checklist A1, business description):
>
> > "A credit manager can approve a large loan, but if the committee does not agree there is no way
> > to decline it: the application just stays open, so the applicant is never told no."
>
> **Forbidden example:**
>
> > "Gateway authority-routing has no edge with is_default true; no_default_route in validate output
> > for definition 8c1f, see graph.ex:762."
>
> **Correct example** (checklist B1):
>
> > "The dispatcher who submits a shipment request is also one of the people the approval task goes to,
> > so one person could approve their own shipment."
>
> **Forbidden example:**
>
> > "actor-swiftroute-lena holds role-ops-manager and TASK_WORKER so requester == approver."
>
> ## Forbidden
>
> - Editing, creating or deleting any file other than your own report and your own handoff (rule 1).
> - Editing your report after it is written, or "answering" a finding by changing the report.
> - Running any command (rule 4), calling the running instance, running a UAT, computing a digest.
> - Reading UAT reports, BA sign-offs or PRODUCT-OWNER sign-offs, or signing off run results (rule 2).
> - Choosing the fix, the business rule or the owner's wording; deciding that an access finding is a
>   defect or is acceptable.
> - Lowering a severity below the checklist default, or answering `NOT_APPLICABLE` without the stated
>   condition.
> - Writing a verdict other than `PASS`, `PASS_WITH_FINDINGS`, `FAIL`, an answer other than `YES`, `NO`,
>   `NOT_APPLICABLE`, a severity other than `BLOCKER`, `MAJOR`, `MINOR`, or an owner outside the closed
>   list.
> - Technical or implementation language in any prose field (see "Language rule").
> - Reading all of `docs/requirements.yaml`.
>
> ## Rework policy
>
> `max_rework: 1`. If ORCH finds your report malformed (a rule under the schema is broken), it
> dispatches you once more for the same scope; the second report replaces the first only because the
> first was never accepted. A finding you disagree with is not a rework trigger. After the second
> malformed report ORCH treats the scope as `MISSING` an audit and escalates per
> `docs/agents/ORCHESTRATOR.md` section 5.

---

Notes for the builder on file 1:
- Replace each nested `>` quote inside the Language-rule examples with the file's own quoting (the
  doubled `> >` above is only an artefact of quoting this document). The final file uses a single
  `> ` quote line for the example sentences, as `ba-analyst.md` does.
- The yaml code fence inside the schema section is real (a fenced block in the file).
- Do not add a `model:` or `tools:` frontmatter key (decision D12).

## 4. Scope-to-files mapping actually on the branch (what ORCH's S1-S6 rule yields today)

This table is evidence for the rule in file 1 and the digest list ORCH will compute. It is not pasted
into any file.

| Scope | S1 scenarios | S3 definitions and forms | S4 seed scripts | S5 pack | Process definitions deployed (validator runs) |
|---|---|---|---|---|---|
| `meridian` | `test/fixtures/uat/scenarios/meridian/*.yaml` (3) | sidecars `proc-meridian-loan-origination.yaml`, `proc-meridian-regulatory-compliance-review.yaml`; fixtures `test/fixtures/qa/meridian_loan_origination_process_definition.json`, `test/fixtures/qa/meridian_regulatory_compliance_review_process_definition.json`; `test/fixtures/simulation/meridian/process_claim_intake.yaml`, `process_policy_binding.yaml`, `org_structure.yaml` | `scripts/seed_meridian_definition.sh`, `scripts/seed_meridian_persona_actors.sh` | none | "Loan Origination", the regulatory review definition (names from each sidecar's `definition_name`) |
| `swiftroute` | 4 files | sidecar `proc-swiftroute-shipment-approval.yaml`; `test/fixtures/qa/swiftroute_process_definition.json`; simulation `process_route_approval.yaml`, `process_shipment_dispatch.yaml`, `org_structure.yaml` | `scripts/seed_swiftroute_definition.sh`, `scripts/seed_swiftroute_persona_actors.sh` | none | the shipment approval definition |
| `vortex` | 4 files | sidecars `proc-vortex-production-order-release.yaml`, `proc-vortex-8d-corrective-action.yaml`, `proc-vortex-supplier-quality-deviation.yaml`, `proc-vortex-quality-deviation.yaml`; fixtures `vortex_production_order_release_process_definition.json`, `vortex_8d_corrective_action_definition.json`, `vortex_supplier_quality_deviation_process_definition.json`; simulation `process_quality_check.yaml`, `process_work_order.yaml`, `org_structure.yaml` (the two supplier-quality sidecars name the same fixture: listed once) | `scripts/seed_vortex_definition.sh`, `scripts/seed_vortex_entities.sh`, `scripts/seed_vortex_persona_actors.sh` | none | 3 definitions (the 8D one is a child of the supplier quality deviation) |
| `bilimbaga` | `test/fixtures/uat/scenarios/bilimbaga/*.yaml` (1) | none | none | `priv/solutions/bilimbaga.json`, `priv/modules/exam/pack.json` | none (`definitions: []`) |
| `platform` | `test/fixtures/uat/scenarios/platform/*.yaml` (19) | none (`process_id` values are `sys-*` labels, or `n/a`) | none | none | none |

All five scopes also include S2 (`test/fixtures/uat/actors.yaml`, `docs/roles.md`). The directory
`test/fixtures/uat/scenarios/_throwaway/` is not a scope.

`cross_scope_inputs` for scope S = the S3 definition fixtures (`test/fixtures/qa/*_process_definition.json`
and `*_definition.json` named by sidecars, plus `test/fixtures/simulation/<other>/process_*.yaml`) of every
other scope that has any.

## 5. File 2: `docs/agents/workflows/WF-05_uat_run.md`

Four edits. Anchors are content, not line numbers.

### 5.1 Overview diagram

Insert the block below between the STEP 0 box and the STEP 1 box: immediately after the `           ▼`
line that follows the STEP 0 box, and before the `┌───────────────────────┐` line that opens the
`STEP 1: READINESS` box. Then add one more `           ▼` line after the new block. (The new block
uses plain ASCII for the new text; the box characters match the neighbours.)

> ┌───────────────────────┐
> │  STEP 0b: PROCESS     │ ← ORCH digests each scope's files; PROCESS-AUDITOR reviews the
> │  AUDIT (per scope)    │   scope's process design unless an unchanged audit exists. A FAIL
> └──────────┬─────────────┘   blocks that scope's UAT only, never the other scopes.
>            ▼

(Result: STEP 0 box, `▼`, STEP 0b box, `▼`, STEP 1 box -- exactly one arrow between each pair of boxes.
The existing `▼` line after the STEP 0 box stays where it is; the new box follows it, then the new `▼`.)

### 5.2 New section, inserted immediately BEFORE the heading `## Step 1 — Readiness check`

Heading text exactly `## Step 0b — Process audit (gate per scope)` (an em dash is acceptable here to match
the neighbouring headings; keep the words `Step 0b`). Exact text:

> ## Step 0b — Process audit (gate per scope)
>
> **Agent:** `ORCH` dispatches `PROCESS-AUDITOR` once per scope. Runs after Step 0 (the environment is
> prepared, so the deployed definitions can be reached) and before Step 1. Role and checklist:
> `.claude/agents/process-auditor.md`.
>
> **DIGEST-RULE.** ORCH dispatches PROCESS-AUDITOR for a scope unless an audit artefact exists whose
> input digests match the current files. An unchanged scope is not re-audited: ORCH cites the existing
> artefact by path instead. A `FAIL` verdict blocks UAT-RUNNER for that scope only. The `platform` scope
> is included and follows the same rule. This keeps the gate off the per-run path when nothing changed.
>
> ```
> 1. List the scopes of this run: the scope of every scenario in the corpus under test (a directory under
>    test/fixtures/uat/scenarios/ whose name does not start with `_`), `platform` included.
> 2. For each scope, build its file list with the closed rule in `.claude/agents/process-auditor.md`
>    ("Audited inputs of a scope", groups S1-S5). The list is built by the rule, not by judgment.
> 3. Compute the digest of each file with the command (Git Bash, run from the repo root):
>      sha256sum <path>
>    The digest is the first field of the output: 64 lowercase hex characters, the SHA-256 of the file
>    bytes as checked out. Keep the path and the digest together. (A checkout whose line endings differ
>    produces a different digest: the only effect is one extra audit, which is the safe direction.)
> 4. Look for an existing artefact: every file test/uat-reports/process-audit-<scope>-*.yaml. It MATCHES
>    when its `audited_inputs` have exactly the same set of paths as step 2 and every digest is equal to
>    the one from step 3. If one or more match, take the one with the latest `generated_at`: do NOT
>    dispatch PROCESS-AUDITOR for this scope; go to step 8 with that artefact's path and verdict. (The
>    validator output and the other scopes' files are not part of the match.)
> 5. Otherwise produce the definition validator output for each deployed process definition of the scope.
>    For each `test/fixtures/uat/process-definition-aliases/*.yaml` whose `company_id` is the scope, take
>    its `definition_name` (once per name). Get a bearer token for any roster actor of this scope from
>    the credential source with the `qa-uat-env` token protocol of `scripts/uat_preflight.sh`
>    (`fetch_credential`, line ~311: it runs `<credential_source> token <actor_id>` and takes the first
>    stdout line that `parse_token_line`, line ~297, accepts: `Token: <jwt>` or a bare JWT; any built-in
>    role in `docs/roles.md` that can read definitions suffices). Then run, literally:
>      curl -s -H "Authorization: Bearer <token>" <base_url>/api/v1/definitions/active/<url-encoded name>
>      curl -s -X POST -H "Authorization: Bearer <token>" <base_url>/api/v1/definitions/<id>/validate
>    `<id>` is the top-level `id` field of the JSON body of the first call. From the second answer keep:
>    for a 200 body its `warnings` list and `violation_codes: []`; for a 422 body the `code` of every
>    entry of `errors` as `violation_codes` (a 422 body has no `warnings`). If a call cannot be made
>    (definition not deployed, no token), record `status: NOT_AVAILABLE` for that definition; never
>    invent output. Never write the token into any file or handoff. A scope with no process definition
>    has an empty `validator_output`.
> 6. Also compute the digests of the process definition files of every OTHER scope (the S3 group of each
>    other scope): this is `cross_scope_inputs`, used only by checklist item F1.
> 7. Dispatch PROCESS-AUDITOR with `context`: `scope`, `run_id`, `commit_sha` (current `HEAD`),
>    `input_digests`, `validator_output`, `cross_scope_inputs`. Commit its report
>    (`test/uat-reports/process-audit-<scope>-<run_id>.yaml`) with the handoff. If the report breaks the
>    schema rules in the role file, re-dispatch once; a second failure leaves the scope with no audit
>    (verdict MISSING in step 8).
> 8. Act on the verdict of the matched or new artefact:
>    - `PASS` or `PASS_WITH_FINDINGS`: the scope proceeds to Step 1.
>    - `FAIL`: the scope is BLOCKED for this run. Do not dispatch UAT-RUNNER for its scenarios and do not
>      dispatch its BA-<VERTICAL> sign-off. Other scopes proceed. The scope's scenarios are not counted in
>      the run's `ENV_NOT_READY` determination (that status stays environment-only). The scope stays
>      blocked on every later run until an audited file changes (its digests then differ and step 4 no
>      longer matches); ORCH never overrides a FAIL.
>    - no artefact (step 7 failed twice): treat as `MISSING`; the scope is blocked as for `FAIL`.
> 9. File every finding of a NEW artefact per docs/agents/protocols/ISSUE_QUEUE.md (one issue per finding
>    id; one issue for a cross-scope pair reported by two scopes). A finding's `suggested_owner` tells
>    where it goes (BA-<VERTICAL> or REQ-ANALYST for business decisions, ELIXIR-DEV through WF-03 for a
>    definition defect, ORCH for roster or seed scripts, SECURITY-REVIEWER for an access concern). Do not
>    file a cited (matched) artefact's findings again.
> 10. Record in the handoff to UAT-RUNNER and PRODUCT-OWNER `context.audit_artefacts`: a map scope -> path
>    of the artefact used (new or cited) for EVERY scope of step 1, blocked ones included; and in the
>    PRODUCT-OWNER handoff `context.audit_blocked_scopes`: the list of scopes blocked in step 8.
> ```

### 5.3 Step 1 readiness list

In the fenced block under `## Step 1 — Readiness check`, insert after item `4.` ("Confirm Step 0
completed and its preflight report path is available for the handoff.") and before item `5.`:

> 4a. Confirm Step 0b completed for every scope of this run: each scope has an audit artefact path and a
>     verdict. Remove every scope whose verdict is FAIL or MISSING from this dispatch. If no scope is
>     left, do not dispatch UAT-RUNNER; log BLOCKED, name the blocked scopes.

### 5.4 Step 4 (PRODUCT-OWNER) -- keep the heading `## Step 4 -- PRODUCT-OWNER release recommendation` unchanged

(a) In the fenced numbered list, item 1 gains a clause: after "...and test/uat-reports/uat-<date>-<run_id>.yaml."
append: " Also read the audit artefact of every scope named in your handoff `context.audit_artefacts`."

(b) Insert after item `3a.` (the access gate item, ends "...with the same no-override rule.") and before item `4.`:

> 3b. Apply the audit gate: read the audit verdict of every scope in `context.audit_artefacts`. The
>     recommendation is NOT `APPROVED` if any scope has no PASS or PASS_WITH_FINDINGS audit (its verdict is
>     FAIL, or the artefact is missing). A scope without a PASS or PASS_WITH_FINDINGS audit is not
>     APPROVED. This applies to `platform` and to a scope blocked at Step 0b, which has no UAT result.

(c) At the very end of the closing paragraph (the one that starts "FAIL (BLOCKED) -> route per each
issue's `suggested_action`" and ends "(`max_rework: 1`)."), append this sentence; change nothing else in it:

> A scope blocked by its process audit is routed by the findings ORCH already filed at Step 0b (not by a new issue from PRODUCT-OWNER's side); once the audited files change, the next run re-audits the scope at Step 0b.

## 6. File 3: `docs/agents/AGENT_SYSTEM.md` (add three lines)

### 6.1 Roster table, section 3: new row immediately AFTER the `PRODUCT-OWNER` row

> | `PROCESS-AUDITOR` | Process Auditor (independent design reviewer, per scope) | Reads one scope's process definitions and forms, scenarios, roster (`test/fixtures/uat/actors.yaml`), seed scripts and `docs/roles.md`, plus the definition validator output ORCH hands it, answers a closed checklist A-F (missing business paths, separation of duties, data on some paths only, consistency inside the scope, access, consistency across scopes) and writes a process-audit report with verdict PASS, PASS_WITH_FINDINGS or FAIL. Authors and edits nothing it audits; never signs off run results (`.claude/agents/process-auditor.md`). A FAIL blocks UAT-RUNNER for that scope only (`docs/agents/workflows/WF-05_uat_run.md`, Step 0b) | `test/uat-reports/` (`process-audit-` prefix only), `handoffs/` |

### 6.2 Capability matrix, section 3.1: new row immediately AFTER the `PRODUCT-OWNER` row

> | `PROCESS-AUDITOR` | ✓ | `test/uat-reports/process-audit-*` only (no merge) | ✗ (read-only search only) | ✗ |

(The `✓` and `✗` are the characters already used by the neighbouring rows.)

### 6.3 Artifact locations, section 6: new row immediately AFTER the `PO sign-off reports` row

> | Process audit reports | `test/uat-reports/` (`process-audit-` prefix) | `PROCESS-AUDITOR` | `.yaml` |

No other edit to AGENT_SYSTEM.md. The sentence under section 3.1 about `handoffs` in the Writes column is
left as is; D14 records how the auditor's own handoff update relates to the capability row.

## 7. File 4: `docs/agents/ORCHESTRATOR.md` (add two lines, no existing line changes)

### 7.1 Section 3 decision tree: new physical line

Insert as a new line immediately BEFORE the line that begins `├─ A BA sign-off or PRODUCT-OWNER issue has
suggested_action route_to_security_review?` (that line was added by the access-rules requirement), i.e.
after the last `│` continuation line of the WF-05 branch. Exact characters of the single physical line:

> ├─ A WF-05 run is being prepared (Step 0 done, Step 1 not yet)?  └─► Gate: WF-05 Step 0b -- per scope, ORCH computes the file digests and dispatches PROCESS-AUDITOR unless an audit artefact with matching digests exists (an unchanged scope is not re-audited); a FAIL verdict blocks UAT-RUNNER and the BA sign-off for that scope only, never ORCH-overridable; file every finding per docs/agents/protocols/ISSUE_QUEUE.md; PRODUCT-OWNER does not APPROVE a scope without a PASS or PASS_WITH_FINDINGS audit.

### 7.2 Section 8 stage-gate list: one new line after item 4's paragraph

Insert immediately after the last line of item 4 (the line ending "...so ORCH prepares the environment and
re-runs.") and before item `5.`:

> 4a. In the same WF-05 run, every scope has a PASS or PASS_WITH_FINDINGS audit (`PROCESS-AUDITOR`,
>     `docs/agents/workflows/WF-05_uat_run.md` Step 0b); a scope with a FAIL or missing audit is not
>     APPROVED, so the stage does not advance on it. Does not apply when no WF-05 run was in scope.

No other edit to ORCHESTRATOR.md. (No change to section 2's workflow table, no change to section 10.)

## 8. File 5: `CLAUDE.md` (add one row) and File 6: `.claude/agents/product-owner.md`

### 8.1 `CLAUDE.md` roster table: new row immediately AFTER the `PRODUCT-OWNER` row (the last row of the table)

> | `PROCESS-AUDITOR` | Read-only independent review of one scope's process design (definitions, forms, scenarios, roster, seed scripts) before it is run; a FAIL verdict blocks UAT for that scope only — never edits what it audits, never signs off run results | [`.claude/agents/process-auditor.md`](.claude/agents/process-auditor.md) |

(An em dash is acceptable here to match the file's style; the substring `PROCESS-AUDITOR` is required.)

### 8.2 `.claude/agents/product-owner.md` edits (locate each by content)

(a) Mandatory reading: append one bullet after the `.claude/agents/release-validator.md` bullet:

> - `.claude/agents/process-auditor.md` -- the process-audit report this role reads for each scope
>   (verdict values, closed `suggested_owner` list); this role never runs or re-dispatches the audit.

(b) In `## What you do`, after the end of `### 3a. Access gate` (after its last bullet, "Plain-language rule: ...") and before `### 4. Arbitration`, insert a new subsection:

> ### 3b. Audit gate
>
> Read the audit verdict of every scope listed in your handoff `context.audit_artefacts` (a map from
> scope to the path of its process-audit report; ORCH lists EVERY scope of the run there, including a
> scope blocked at WF-05 Step 0b and including `platform`). For each scope:
>
> - Open the file at that path and read its `verdict` (`PASS`, `PASS_WITH_FINDINGS` or `FAIL`) and
>   `verdict_note`. Set `audit_verdicts[<scope>]` to that verdict.
> - If the scope has no entry in the map, or the file does not exist, set `audit_verdicts[<scope>]` to
>   `MISSING`.
> - A scope without a PASS or PASS_WITH_FINDINGS audit is not APPROVED: if any scope is `FAIL` or
>   `MISSING`, `release_recommendation` MUST be `BLOCKED`. This cannot be overridden with
>   `blocker_overrides`.
> - A scope listed in your handoff `context.audit_blocked_scopes` has no UAT result and no BA sign-off;
>   that is expected, and it is not a "missing BA sign-off" BLOCKER under step 1. Its block comes from
>   this gate only.
> - `PASS_WITH_FINDINGS` does not block. Say in `release_rationale`, in plain language, that the process
>   design of that scope was reviewed with open observations (the findings are already filed by ORCH).
> - For each scope with `FAIL` or `MISSING`, add one `issues` entry: `severity: BLOCKER`,
>   `suggested_action: none` (the findings were filed by ORCH at Step 0b), `description` in plain
>   language naming the scope by its business name.
> - Do not read the findings in detail to re-judge them, do not re-dispatch the audit, and do not try to
>   verify digests (you run no command; ORCH owns the digest match).
> - Plain-language rule: copy `verdict_note` into `release_rationale` only as plain prose. Correct: "One
>   area's process design was reviewed before testing and has a gap that could leave a loan application
>   open forever, so its release is blocked until the design is corrected." Forbidden: "audit_verdicts:
>   meridian FAIL, PA-MERIDIAN-001 A1."

(c) Schema block (locate by `report_id: po-signoff-`): insert after the `access_verdicts:` block (the two lines
`access_verdicts:` and `  <vertical-slug>: PASS | FAIL | NOT_COVERED`) and before `criteria_coverage:`:

> audit_verdicts:                       # one entry per scope in context.audit_artefacts, platform included
>   <scope>: PASS | PASS_WITH_FINDINGS | FAIL | MISSING

(d) `release_recommendation` derivation list: insert as a new item between the access item (`3.`) and the
coverage item (`4.`), labelled `3a.` so nothing is renumbered:

> 3a. Any `audit_verdicts[...]` == `FAIL` or == `MISSING` -> `BLOCKED` (a scope without a PASS or
>     PASS_WITH_FINDINGS audit is not APPROVED).

(e) `## Forbidden`: append one bullet at the end of the list:

> - Approving a release (`release_recommendation: APPROVED`) when any scope of the run has an audit
>   verdict of `FAIL` or `MISSING` -- a scope without a PASS or PASS_WITH_FINDINGS audit is not APPROVED
>
> and one more:
>
> - Re-judging, re-dispatching or recomputing a process audit (route nothing about it; ORCH already filed
>   its findings)

(f) Step 1 of `## What you do` ("Read-only relationship to BA sign-offs"): append one sentence at the end
of its last paragraph: " A scope that appears only in `context.audit_blocked_scopes` has no BA sign-off by
design (see step 3b)."

(g) Sign-off `### Location` paragraph (the one saying this role is a third writer): no edit.

No change to the front-matter description, the Relationship section or the Rework policy.

## 9. Acceptance-criteria mapping and definition of done

| AC | Element |
|---|---|
| AC1 `.claude/agents/process-auditor.md` with independence rules, numbered procedure, checklist A-F with three answer values, verdict values, artefact schema | section 3: "Independence rules" (7 numbered, the first is "author and edit nothing; findings are not answered by editing the report"), "Procedure" (10 numbered steps), "Checklist" (A1..F1 under letters A-F; `YES`/`NO`/`NOT_APPLICABLE`), "Verdict" (`PASS`/`PASS_WITH_FINDINGS`/`FAIL`), "Report artefact" (schema with `run_id`, `generated_at`, `commit_sha`, `scope`, `audited_inputs` with `digest_algorithm`, `checklist`, `findings` with `id`, `severity`, `checklist_item`, `business_description`, `affected`, `suggested_owner`, `verdict`) |
| AC2 AGENT_SYSTEM roster + capability rows, ORCHESTRATOR.md and CLAUDE.md list PROCESS-AUDITOR; capability row grants no write outside `test/uat-reports/process-audit-*` | sections 6.1, 6.2 (capability row text `test/uat-reports/process-audit-* only (no merge)`), 6.3, 7.1, 7.2, 8.1 |
| AC3 WF-05 audit step with the digest rule and the FAIL-blocks-that-scope rule; product-owner.md reads the audit verdict | section 5.2 (DIGEST-RULE paragraph, steps 4 and 8), 5.1, 5.3, 5.4; section 8.2 (b), (c), (d), (e) with the exact sentence "a scope without a PASS or PASS_WITH_FINDINGS audit is not APPROVED" |
| AC4 every named path, field and mix task exists or is created here | section 0 (greps with evidence; no mix task is named anywhere in the new text) |
| AC5 `mix letflow.check` passes with real output | section 1; run by the builder and by TEST-RUNNER, real output quoted |

Definition of done additions (decided here; the builder runs them and quotes the output):

1. `grep -c "PROCESS-AUDITOR"` over each of the six files returns at least 1:
   `.claude/agents/process-auditor.md`, `docs/agents/workflows/WF-05_uat_run.md`,
   `docs/agents/AGENT_SYSTEM.md`, `docs/agents/ORCHESTRATOR.md`, `CLAUDE.md`, `.claude/agents/product-owner.md`.
2. `grep -n "not APPROVED" .claude/agents/product-owner.md` shows the sentence "a scope without a PASS or
   PASS_WITH_FINDINGS audit is not APPROVED" (case as written).
3. `grep -n "process-audit-" docs/agents/AGENT_SYSTEM.md` shows three hits (roster, capability, artifact rows)
   and the capability row contains no `handoffs` and no other path.
4. `grep -n "DIGEST-RULE\|not re-audited" docs/agents/workflows/WF-05_uat_run.md` shows the rule.
5. `grep -rn "mix letflow" .claude/agents/process-auditor.md docs/agents/workflows/WF-05_uat_run.md` shows no
   hit introduced by this entry (no invented task).
6. `mix letflow.check` (the full alias) exits 0, real output quoted.

## 10. Walkthrough check against the current corpus (so the text is usable, not only correct)

- `meridian` today: three scenario files, two sidecars, 5 + 1 definition-adjacent files, 2 seed scripts, the
  shared roster and roles. The digest set has about 17 files. First run: no artefact -> dispatch. The REQ-455
  validator would report no CHK-24 violations for the fixed fixtures, so A3 is YES; A1 depends on whether each
  approval gateway has a decline branch (the BA-confirmed defaults now route toward decline or more scrutiny).
- `platform`: 19 scenarios, no definitions -> A1-A4, B1-B2, C1, F1 are `NOT_APPLICABLE`; E1 is `NO` while no
  scenario has `expect_refusal: true` (`refusal_coverage_exempt` lists `platform`); that yields a MAJOR finding,
  verdict `PASS_WITH_FINDINGS`, so UAT is not blocked. (Stated deliberately: the first audits will not FAIL on
  missing refusal steps alone.)
- `bilimbaga`: 1 scenario, no definition, one unresolved actor in the roster: A-C `NOT_APPLICABLE`, D3 `NO`
  (the actor is under `unresolved:`), D4 `NO` MINOR, E1 `NO` MAJOR -> `PASS_WITH_FINDINGS`.

## 11. Gates and workflow routing for this requirement

- SECURITY-REVIEWER: NOT applicable to the REQ-456 diff. Log reason: instruction text and role/roster rows
  only; no route, migration, secret, response shape or tenant-data path is touched. Access concerns that
  the AUDITOR finds at run time reach SECURITY-REVIEWER only via a finding owned by `SECURITY-REVIEWER`.
- TEST-DESIGNER: NOT applicable (no new ExUnit). The acceptance criteria demand only `mix letflow.check` and
  the greps in section 9. No `check` task exists for these files, and none is built (a mechanical check of
  `process-audit-*.yaml` is future work; flag to REVIEWER before building).
- REVIEWER: applies (scope creep, consistency with the REQ-453 decisions: closed sensitive-action list, the
  `access_verdict` gate; consistency with decision record 0004 humanless pipeline).
- RELEASE-VALIDATOR / DOC-UPDATER: normal WF-02 tail. DOC-UPDATER also notes in `docs/requirements.yaml`
  history only.
- Overlap check for the builder: no other open run edits the six files; the REQ-453 edits to
  `ORCHESTRATOR.md` (the `route_to_security_review` line) and to `product-owner.md` (3a, access) are already
  merged and are the neighbours of the new lines.

## 12. Open questions (each has the default this design builds; none is left blank)

- **OQ-1. Shared references in every scope's digest set (decision D3, group S2).** A change to
  `test/fixtures/uat/actors.yaml` or `docs/roles.md` changes every scope's digests, so a roster edit
  re-audits all five scopes. Default built: yes, include them (the audit judges the roster against the
  scenarios, so a roster change really can invalidate every scope). Alternative: digest only the actor
  entries used by the scope (needs a parser, not available to ORCH as a one-line command).
- **OQ-2. Severity calibration (decision D11).** BLOCKER is reserved for: no rejection outcome, a dead
  end, requester-equals-approver on a payment or commitment, a decision reading a never-collected value,
  a tenant person holding `PLATFORM_ADMIN`, a tenant actor needing a platform permission. A missing refusal
  step is MAJOR, so the five scopes that are all in `refusal_coverage_exempt` today get
  `PASS_WITH_FINDINGS`, not `FAIL`. Default built: as stated. Alternative: make E1 BLOCKER once a scope
  leaves `refusal_coverage_exempt`.
- **OQ-3. The auditor's own handoff write vs the capability row (decision D14).** The requirement says the
  capability row grants no write outside `test/uat-reports/process-audit-*`; every role also completes its own
  handoff file. Default built: the capability row says exactly `test/uat-reports/process-audit-* only (no
  merge)` and the role file states that the auditor completes its own handoff (rule: it is the one write
  besides the report). Alternative: add `, own handoff` to the capability row (the roster row already says
  `handoffs/`).

Settled by the requirement's own defaults, not open: model (no override), SECURITY-REVIEWER scope (D13).
Settled by the BA decisions adopted unchanged: `Step 0b` naming, `audit_verdicts` field name, ORCH runs the
digest command and the validator and hands the outputs to the auditor, digest algorithm and command.

## 13. Rework 1 (CODE-DESIGN-VALIDATOR FAIL) -- applied

1. A3/C1 table cells and independence rule 6 now state the NOT_AVAILABLE exception (MAJOR); D11 updated.
2. Rule 4 reworded (Read/Glob/Grep for reading; Write only for report and own handoff); procedure step 2 reads ALL input_digests files.
3. WF-05 Step 0b step 5 gives the two literal curl commands; token protocol cited as `fetch_credential` (scripts/uat_preflight.sh ~311, runs `<credential_source> token <actor_id>`) with `parse_token_line` (~297).
