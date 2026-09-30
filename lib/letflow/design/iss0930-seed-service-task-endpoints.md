# WF-03 Fix Design -- ISS-0930 (seeded service-task endpoints fail `request_build_error`)

Run-id: WF03-ISS0930-20261001
Type: seed-data + seed-script + test fix. **No change to `lib/letflow/engine/**`,
`lib/letflow/webhooks/**`, or any security check.** No decision record required (the
engine contract is unchanged; the seed is brought into conformance with it).
Issue: `docs/issues/ISS-0930.yaml` (queue Q-913, GH-2064). Diagnosis:
`handoffs/WF03-ISS0930-20261001/step-01-issue-fixer-diagnose.json`.

## 0. Diagnosis claims verified against code (HANDOFF_PROTOCOL 1.1)

| Claim | Verified at |
|---|---|
| Seeded `attributes.endpoint` is `"POST /kyc/screen"` style; no `method`, no `service_id`, single-brace placeholders | all 5 `test/fixtures/qa/*.json` (node key is `node_type`, not `type`); 25 SERVICE_TASK nodes, see section 3 |
| Engine takes `endpoint` verbatim as `url_template`, method only from separate `"method"` attr, default POST | `service_task.ex` `parse_config_from_node_attributes/1` (~176-222), `parse_method/1` (~234) |
| Only `{{variables.KEY}}` is rendered; `{x}` is sent literally | `engine.ex` `render_service_task_url/2` (regex `\{\{\s*variables\.([a-zA-Z0-9_]+)\s*\}\}`); absent key renders `""` |
| `UrlValidator` requires scheme `https`, a host, and every resolved address public | `url_validator.ex` `check_scheme/1`, `check_host/2`; `URI.parse("POST /x")` has `scheme: nil` -> `{:error, :target_url_not_allowed}` -> `{:request_build_error, ...}`, non-retriable |
| A 2xx JSON-object response is required; its keys are merged into instance variables | `service_task.ex` `classify_failure_kind/1`; `engine.ex` `advance_service_task_dispatch/4` -> `VariableMerge.merge/3` |

All confirmed. Root cause is the seed, not the engine. Note a second-order fact the
diagnosis flagged and this design handles: fixing only the URL *shape* would move the
failure to a host that does not exist; a real reachable public https target is required.

## 1. Decision: what is changed, and what is explicitly NOT

Changed: seed fixtures (endpoint string per SERVICE_TASK node, explicit `method`,
fixture `version`), seed scripts (host parameterisation, version-aware idempotency), one
new ExUnit contract test.

NOT changed (and why):
- `Letflow.Webhooks.UrlValidator` https/SSRF gate -- security invariant INV-9, BLOCKER.
- `Letflow.Engine.ServiceTask` -- no `"METHOD path"` parsing and no engine base-URL
  setting (new feature, would need a decision record + REVIEWER + SECURITY-REVIEWER).
- `test/fixtures/simulation/{meridian,vortex,swiftroute}/process_*.yaml` -- these are NOT
  the generation source. The `test/fixtures/qa/*.json` files are hand-maintained and are
  the literal payload the seed scripts POST (`cat` of the file). The only test that reads
  a YAML/JSON pair (`test/letflow/scripts/seed_swiftroute_definition_test.exs`) compares
  node ids, edge ids, escalation attrs and one CEL condition -- **not endpoints** (verified by
  grep) -- so the YAML can keep its relative `POST /path` notation as narrative spec
  without breaking it. Open question OQ-2 covers whether to also touch it.
- `test/fixtures/uat/process-definition-aliases/*.yaml` -- they map `process_id` to
  `definition_name`; lookups by name (`GET /definitions/active/:name`,
  `Definitions.get_active_by_name/2`) keep working across a version bump (section 5).

## 2. Target host: verified on QA

Procedure: ssh only via the host alias in
`ai-dala-infra/scripts/qa-uat-env.sh` (`ubuntu-16gb-nbg1-1`, the Letflow QA server,
which also hosts container `letflow-qa-app-1`). No credentials were read or printed.

Recorded results, 2026-09-30T22:32Z, real `curl` executed on the QA server:

| Probe | Result |
|---|---|
| `POST https://httpbin.org/post` body `{"a":1}` | `status=200 ct=application/json`, resolved `54.175.207.120` (AWS public), JSON object echo |
| `POST https://httpbin.org/anything/mes/orders/ORD-1/assign` x3 | `status=200 ct=application/json`, 0.43-0.49 s each, three different public AWS IPs; body is a JSON object with keys `args,data,files,form,headers,json,method,origin,url` |
| `GET https://httpbin.org/get` | `status=200 ct=application/json`, JSON object |
| `POST https://postman-echo.com/post` | `status=200 ct=application/json; charset=utf-8`, JSON object (Cloudflare IPv6 `2606:4700:7::21d`) |
| `POST https://echo.free.beeceptor.com` | `status=200 ct=application/json`, JSON object |
| `getent hosts httpbin.org` inside `letflow-qa-app-1` | resolves to 8 public AWS IPv4 addresses (container DNS works; no private/loopback address, so the DNS-rebinding/private-range check passes) |
| `GET https://qa.bizdala.com/health` | 200 `{"status":"ok"}`; `POST` -> 404 problem+json |

Evaluation:
- QA-hosted option (`https://qa.bizdala.com/...`): rejected. No unauthenticated endpoint
  accepts POST and returns 2xx JSON (`/health` is GET-only; POST 404). Its body
  `{"status":"ok"}` would also merge a `status` key into instance variables. Adding such an
  endpoint would be an app change out of scope for a seed defect.
- `postman-echo.com`, `beeceptor`: work, but `postman-echo`'s path-echo semantics are
  fixed (`/post`, `/get` only, no arbitrary path), and beeceptor is rate-limited free tier.
- **Chosen default: `https://httpbin.org/anything`.** Accepts any method and any path
  suffix (so every seeded path can be kept readable in the URL, which makes the dispatch row
  self-describing), returns 200 + JSON object deterministically, public non-private
  addresses.

Collision check for response keys merged into variables (`args,data,files,form,headers,json,method,origin,url`):
grep of the five QA fixtures and the meridian/vortex/swiftroute UAT scenarios finds no
process variable with any of those names (the `method:` hits in scenarios are assertion
kinds, not variables). Accepted as safe; see OQ-1 for residual risk.

Residual risk (recorded, not hidden): a third-party public service is an availability
dependency of UAT. Mitigated by making the base overridable (section 4) so a self-hosted
echo can be substituted with no fixture edit. A non-2xx/unreachable httpbin yields a
retriable `:network`/`:http_non_2xx` failure (retry then ERROR), which is at least a
different, correctly classified failure from `request_build_error`.

## 3. Fixture changes (every SERVICE_TASK node, exhaustive)

Transformation rule, applied uniformly to `graph.nodes[*]` where `node_type == "SERVICE_TASK"`:

1. `attributes.endpoint` := `"https://httpbin.org/anything"` + the original path
   (text after `"POST "`), with every `{name}` rewritten to `{{variables.name}}`.
2. Add `attributes.method` := `"POST"` (the verb that was embedded in the old string;
   all 25 nodes are POST). Valid values are `GET POST PUT PATCH DELETE`.
3. `timeout_ms` (300000) unchanged; no `service_id` (would switch `route_kind` to
   `:catalog_service`, which can never dispatch today).
4. Top-level `version` `"1.0"` -> `"1.1"` in each of the five fixtures (needed by the
   replacement mechanism, section 5). `name` unchanged so scenario/alias lookups by name
   keep resolving.
5. No other node/edge/attribute is touched.

Resulting endpoints, by file (base `B` = `https://httpbin.org/anything`):

`meridian_loan_origination_process_definition.json` (7 nodes)
- credit-memo-timeout, risk-assessment-timeout, kyc-timeout, committee-timeout:
  `B/internal/applications/{{variables.application_id}}/flag`
- kyc-aml-check: `B/kyc/screen`
- create-facility: `B/core-banking/facilities`
- decline-application: `B/crm/applications/{{variables.application_id}}/decline`

`meridian_regulatory_compliance_review_process_definition.json` (6)
- evidence-collection-timeout, risk-evaluation-timeout:
  `B/internal/reviews/{{variables.review_id}}/flag`
- regulatory-auto-escalation: `B/compliance/regulatory-notice`
- cro-sign-off-timeout: `B/internal/reviews/{{variables.review_id}}/escalate`
- archive-review: `B/compliance/reviews/{{variables.review_id}}/archive`
- reopen-review: `B/compliance/reviews/{{variables.review_id}}/reopen`

`vortex_production_order_release_process_definition.json` (3)
- assign-line: `B/mes/orders/{{variables.order_id}}/assign`
- auto-reject-order: `B/mes/orders/{{variables.order_id}}/reject`
- notify-planner: `B/webhooks/notify`

`vortex_supplier_quality_deviation_process_definition.json` (6)
- quarantine-batch: `B/mes/batches/{{variables.batch_ref}}/quarantine`
- release-quarantine: `B/mes/batches/{{variables.batch_ref}}/release`
- default-to-major: `B/internal/deviations/{{variables.deviation_id}}/default-severity`
- supplier-warning: `B/webhooks/supplier-warning`
- supplier-notification: `B/webhooks/supplier-notify`
- close-deviation: `B/quality/deviations/{{variables.deviation_id}}/close`

`swiftroute_process_definition.json` (3; affected identically, same defect, included for
completeness though the ISS-0912 scenarios stop at meridian/vortex)
- release-shipment: `B/internal/shipments/{{variables.shipment_id}}/release`
- auto-reject: `B/internal/shipments/{{variables.shipment_id}}/reject`
- notify-requester: `B/webhooks/notify`

Total 25 nodes (7+6+3+6+3). Behaviour when a placeholder variable is absent at runtime:
renders `""` (double slash in the path); httpbin still returns 200. Not a failure.

## 4. Seed-script design (host parameterisation)

Files: `scripts/seed_meridian_definition.sh`, `scripts/seed_vortex_definition.sh`,
`scripts/seed_swiftroute_definition.sh`; one new shared helper
`scripts/lib/seed_service_task_base.sh` (sourced by all three, resolved relative to
`SCRIPT_DIR`; contains no secrets).

Interface (shell, signatures only):
- Env var `SERVICE_TASK_MOCK_BASE_URL` -- optional. Default `https://httpbin.org/anything`.
  Validation before any network call: must start with `https://`, no trailing `/`
  (a single trailing slash is stripped), no whitespace; else print an `ERROR:` line to
  stderr and `exit 1`. `http://` is refused up front (it would fail the engine SSRF gate
  anyway; fail early and clearly).
- `rewrite_service_task_base <payload-json> -> <payload-json on stdout>` -- when the
  effective base differs from the default literal stored in the fixtures, replaces the
  leading default-base prefix of every SERVICE_TASK node's `attributes.endpoint` with the
  effective base via `jq` (anchored prefix substitution; non-SERVICE_TASK nodes and all
  other fields untouched). When the base equals the default it is an identity
  passthrough. Uses `jq` only (already a stated prerequisite of the scripts).
- Each script pipes the fixture through `rewrite_service_task_base` before the
  `POST /api/v1/definitions` call, and prints `Service-task mock base: <base>` in its
  banner so UAT reports record which host was used.
- Header comment blocks updated: new env var documented; "v1.0" mentions changed to "v1.1";
  the "skips if ACTIVE" sentence replaced by the section 5 rule.

The fixture stays the source of truth with the default base literal baked in (so the
contract test and any direct `POST` of the fixture both work); the env var is only a
seed-time override.

## 5. Replacing an already-ACTIVE definition (QA currently holds v1.0 with bad endpoints)

API facts (read from `lib/letflow/definitions.ex`, `Definitions.activate/2`):
- `create` always yields DRAFT; uniqueness is `(name, version)` (`uq_definition_version`
  -> `{:error, :duplicate_name_version}`, HTTP 409).
- `activate` on a DRAFT atomically deprecates the prior ACTIVE definition **of the same
  name** in the same transaction (at most one ACTIVE per name, `uq_active_definition`).
- An ACTIVE definition's graph is not editable in place; its `(name, version)` cannot be
  reused. Therefore the minimal lifecycle-consistent mechanism is: **create a new version
  of the same name, activate it, let the platform deprecate the old one.** No delete, no
  FORCE flag, no API change.

Mechanism (per `seed_definition` unit in meridian/vortex; once in swiftroute):
1. `GET /definitions?name=<n>&status=active`.
2. Let `fixture_version` = `.version` of the fixture JSON (`jq -r .version`). Let
   `active_version` = `.items[0].version // empty`.
3. Three-way decision on `active_version` vs `fixture_version`, compared **numerically by
   dotted components, not as strings and not by `!=`** (shell helper
   `version_is_older <a> <b>`: true iff `a` sorts strictly before `b` under
   `sort -V`, i.e. `1.9` < `1.10`; `sort -V` ships with GNU coreutils in the scripts' runtime,
   same class of prerequisite as `jq`). The server treats `version` as an opaque string
   (uniqueness `(name, version)` only; no ordering in `Definitions`), so ordering is decided
   client-side by this helper:
   - `active_version` empty (none active) -> proceed to step 4.
   - `active_version == fixture_version` -> skip (idempotent no-op; existing message).
   - `active_version` strictly older than `fixture_version` (e.g. QA's 1.0 vs 1.1) -> proceed
     to step 4.
   - `active_version` strictly NEWER than `fixture_version` (e.g. a hand-promoted 1.2 vs
     fixture 1.1) -> **do not replace**: print
     `WARNING: ACTIVE v<active> is newer than fixture v<fixture>; not downgrading. Bump the fixture version above v<active> to re-seed.`
     to stderr, skip the create/activate calls, and exit 0 (seed is a no-op, never a
     downgrade). Rationale: replacing would deprecate a newer operator-promoted definition
     with an older graph; the script cannot know the newer one is wrong, and a false
     no-op is recoverable (bump fixture) while a silent downgrade is not obviously so.
4. Replace path -> `POST /definitions` with the rewritten payload, then
   `POST /definitions/{id}/activate`. Print, when a prior active existed,
   `Replacing ACTIVE v<old> (id <id>) with v<new>; the platform will deprecate v<old>.`
5. A 409 on create means `(name, fixture_version)` already exists in DRAFT/DEPRECATED/
   ARCHIVED; the script prints that cause (current hint text is updated from "already
   exists as DRAFT" to also name DEPRECATED/ARCHIVED) and exits 1. Recovery is to bump the
   fixture `version`, never to delete. Stated explicitly so nobody reaches for FORCE.

Consequences checked:
- Downgrade guard: the static content block (section 6) also pins the literal
  `not downgrading` and the `version_is_older` helper name in each script.
- Scenario/alias lookups: `definition_name` -> `get_active_by_name` returns the new ACTIVE
  v1.1. Sidecars and `uat_preflight.sh` need no change (preflight compares names, not
  versions; verified by grep).
- Instances already started on v1.0 (the ERROR ones) stay pinned to the deprecated v1.0
  graph; they are not repaired and need not be. Re-run UAT starts fresh instances on v1.1.
- Rollback of the fix is `Definitions` rollback semantics (re-activate v1.0) and is
  unchanged.
- Ordering for QA re-seed after merge/deploy: run the meridian, vortex and swiftroute
  scripts with the tenant admin token (`qa-uat-env.sh token <tenant>-admin-user`, held in a
  shell variable, never printed).

## 6. Regression test design

New file: `test/letflow/scripts/qa_fixture_service_task_endpoints_test.exs`
(module `Letflow.Scripts.QaFixtureServiceTaskEndpointsTest`; `use ExUnit.Case, async: true`;
`@moduletag :unit`; no DB, HTTP or process state; sibling of the existing
`seed_swiftroute_definition_test.exs` and mirrors its fixture-loading style).

Inputs: every file matching `test/fixtures/qa/*.json` (glob at compile/setup time, so a new
fixture is covered automatically); each decoded with `Jason.decode!/1`; nodes taken from
`graph.nodes` where `node_type == "SERVICE_TASK"`.

Exercise path (reuses production code, no reimplementation of the rules): build a
`%Letflow.Definitions.Graph.Node{}` (real struct, `lib/letflow/definitions/graph.ex:156`;
`@enforce_keys [:id, :node_type]`) with `id: <node id>`, `node_type: :SERVICE_TASK` (atom;
the JSON string `"SERVICE_TASK"` is only used to select nodes) and
`attributes: <the node's string-keyed attributes map>` (`label` left nil), and call
`Letflow.Engine.ServiceTask.parse_config_from_node_attributes/1` (it pattern-matches
`%Graph.Node{id:, attributes:}` where `Graph` aliases `Letflow.Definitions.Graph`). Render
the `url_template` by substituting the **exact sample value `"sample1"`** for every
`{{variables.KEY}}` token (same token grammar as `Engine.render_service_task_url/2`:
regex `\{\{\s*variables\.([a-zA-Z0-9_]+)\s*\}\}`; `"sample1"` is URL-safe alphanumeric so
it cannot itself alter scheme/host); call
`Letflow.Webhooks.UrlValidator.validate(rendered_url, resolver)` with an injected stub
resolver (a 1-arity fun over a charlist host returning
`{:ok, [{:inet, {93, 184, 216, 34}, []}]}`, a public documentation-range-safe address,
so the test is hermetic, never touches real DNS).

Assertions, each a separate `test` / describe-per-fixture with the node id in the failure
message (TC ids assigned by TEST-DESIGNER):
1. The fixture set is non-empty and every fixture contains >= 1 SERVICE_TASK node
   (guards against a silently empty glob).
2. Every SERVICE_TASK node has `attributes.endpoint` as a binary, parses via
   `URI.parse/1` with `scheme == "https"` and non-empty `host`.
3. Every node has an explicit `attributes.method` (binary) that is one of
   `["GET","POST","PUT","PATCH","DELETE"]` (case-insensitive), and the parsed
   `Config.method` agrees. Type note: the fixture value is a JSON **string** (`"POST"`),
   whereas parsed `Config.method` is an **atom** (`:POST`; `parse_method/1` does
   `String.upcase |> safe_to_existing_atom` and accepts only `@valid_methods ~w(GET POST PUT
   PATCH DELETE)a`). The test compares them by normalising the fixture side:
   `String.to_existing_atom(String.upcase(fixture_method)) == config.method` (all five atoms
   exist because `ServiceTask` is loaded), never by comparing atom to string directly.
4. `parse_config_from_node_attributes/1` returns `{:ok, %Config{route_kind: :inline_url}}`
   (no `service_id` present -- catalog routing can never dispatch today).
5. After rendering, `UrlValidator.validate(rendered, stub_resolver)` returns `:ok`
   (this is the exact gate that produced `{:request_build_error, :target_url_not_allowed}`).
6. The endpoint template contains no unrendered placeholder: after removing every valid
   `{{variables.KEY}}` token (`KEY` matching `[a-zA-Z0-9_]+`), the remaining string
   contains neither `{` nor `}`.
7. Negative guard (proves the test bites and pins the contract): the literal
   `"POST /kyc/screen"` fails assertion 2/5 logic when fed through the same helper
   (`{:error, :target_url_not_allowed}`), as a unit of the test's own helper.

Second, tiny file-content assertion block in the same module (static, no shell
execution): each of the three seed scripts contains the literal `SERVICE_TASK_MOCK_BASE_URL`
and sources `scripts/lib/seed_service_task_base.sh`, and contains `fixture_version`-style
comparison text (`jq -r .version`), `version_is_older` and `not downgrading` (section 5). This pins the seed/fixture linkage without requiring
live QA (same caveat the existing seed test documents: live-seed ACs are not CI
auto-executable).

Why it FAILS on current `main` fixtures (stated so the validator can check it is a real
regression test): every one of the 25 nodes carries `endpoint` like `"POST /kyc/screen"`;
`URI.parse/1` yields `scheme: nil, host: nil`, so assertions 2 and 5 fail; no node has
`attributes.method`, so assertion 3 fails; every endpoint with a path parameter holds `{application_id}`-style
single braces, so assertion 6 fails; the seed scripts lack the env var/helper, so the
static block fails. After the fix every assertion passes.

Verification commands for the implementer (real output must be quoted, per
core-directives): `mix deps.get` first (worktree has no fetched deps), then
`mix test test/letflow/scripts/qa_fixture_service_task_endpoints_test.exs` and
`mix test test/letflow/scripts/seed_swiftroute_definition_test.exs` (drift guard must
still pass), plus `bash -n` on the four shell files. Live proof (UAT-RUNNER/ORCH, not CI):
re-seed on QA, `GET /api/v1/definitions/{id}` shows version 1.1 and https endpoints, and a
started instance passes `kyc-aml-check` / `assign-line` / `quarantine-batch` without
`service_task_retries_exhausted`.

## 7. File list (owned_modules for ELIXIR-DEV / implementer)

Modify:
- `test/fixtures/qa/meridian_loan_origination_process_definition.json`
- `test/fixtures/qa/meridian_regulatory_compliance_review_process_definition.json`
- `test/fixtures/qa/vortex_production_order_release_process_definition.json`
- `test/fixtures/qa/vortex_supplier_quality_deviation_process_definition.json`
- `test/fixtures/qa/swiftroute_process_definition.json`
- `scripts/seed_meridian_definition.sh`
- `scripts/seed_vortex_definition.sh`
- `scripts/seed_swiftroute_definition.sh`
- `scripts/README.md` (document `SERVICE_TASK_MOCK_BASE_URL` and the version-bump
  re-seed rule, if it lists seed-script env vars)

Create:
- `scripts/lib/seed_service_task_base.sh`
- `test/letflow/scripts/qa_fixture_service_task_endpoints_test.exs`

Not touched: everything under `lib/letflow/` except this design doc, `priv/`, `web/`,
`test/fixtures/simulation/**`, `test/fixtures/uat/**`.
Security review: the change adds no route, no schema, no secret handling and leaves INV-9
intact; SECURITY-REVIEWER gate is not triggered, but the impl must not log
`QA_AUTH_TOKEN` (existing scripts do not) and the base URL validation above is part of
the contract.

## 8. Acceptance-criteria map

| Criterion | Design element |
|---|---|
| Design artefact, no implementation code | this file (signatures/rules only) |
| Working QA host verified by real curl | section 2 table (httpbin `/anything`, 200 + JSON object from QA server, container DNS verified) |
| Replacement of already-ACTIVE definitions | section 5 (new version 1.1, create+activate, platform deprecates prior; 409 rule; name lookups preserved) |
| File list / owned_modules | section 7 |
| Regression test incl. why it fails today | section 6 |
| Every seeded service-task node covered | section 3 (25 nodes across meridian x2, vortex x2, swiftroute) |

## 9. Open questions (explicit; none blocks implementation)

- OQ-1: Response keys `args,data,files,form,headers,json,method,origin,url` from httpbin
  are merged into instance variables. Verified: the service-task merge calls
  `VariableMerge.merge(seed_state.variables, decoded_body, nil)` (`engine.ex`
  `advance_service_task_dispatch/4`, ~line 2944), i.e. with **nil validations**, so tenant
  `variable_schemas` are NOT applied here and cannot reject these keys. Residual risk is only
  semantic: the keys pollute instance variables, and an existing process variable of the same
  name (none found in fixtures/scenarios) would be overwritten by the echo. Default chosen
  anyway; overridable via `SERVICE_TASK_MOCK_BASE_URL`.
- OQ-2: Should the simulation YAML sources also move to absolute endpoints? Designed as NO
  (not generation source; no test compares endpoints). Flag for REVIEWER if they disagree.
- OQ-3: Whether process variables `application_id`, `review_id`, `order_id`, `batch_ref`,
  `deviation_id`, `shipment_id` are actually set by the scenarios' start payloads was not
  verified; absent ones render `""` and do not fail the call.
- OQ-4: Long term, a self-hosted public echo endpoint owned by ai-dala-infra would remove the
  third-party dependency; out of scope here.
