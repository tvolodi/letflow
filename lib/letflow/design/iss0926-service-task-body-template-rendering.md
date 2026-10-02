# Fix Design — ISS-0926 (SERVICE_TASK `body_template` is never rendered)

Issue: `docs/issues/ISS-0926.yaml` (queue Q-926, GH-2106). Diagnosis: ISSUE-FIXER (trusted,
not re-derived here; re-verified against current code per HANDOFF_PROTOCOL 1.1 — section 0).
Related: ISS-0932 (`lib/letflow/design/q915-regulatory-review-21day-timer-path.md` §4, C3,
explicitly deferred this exact gap as a follow-up issue, which is this one).

Type: `lib/` change (renderer generalization, two call-site edits in
`Letflow.Engine`/`Letflow.Engine.ServiceTaskDispatcher`) + fixture/graph-authoring change
(`test/fixtures/qa/meridian_regulatory_compliance_review_process_definition.json`). No new
Ecto schema, no migration, no new public API route, no decision record (the `{{variables.KEY}}`
template contract itself is unchanged — only which `Config` fields get run through it, and only
by adding a new derived key, exactly as `url_template` → `rendered_url` already does).

Design author: CODE-DESIGNER. Not self-reviewed; CODE-DESIGN-VALIDATOR gates this file.

## 0. Diagnosis re-verified against current code

| Claim | Verified at | Result |
|---|---|---|
| `body_template` is parsed into `ServiceTask.Config.t()` | `lib/letflow/engine/service_task.ex:226` (`body_template: Map.get(attrs, "body_template")`) | confirmed |
| `body_template` is copied raw (unrendered) into `config_snapshot_map/3`'s output | `lib/letflow/engine.ex:1117` (`"body_template" => config.body_template` inside `base`) | confirmed |
| `ServiceTaskDispatcher` sends the raw, unrendered value as the HTTP body | `lib/letflow/engine/service_task_dispatcher.ex:719` and `:741` (`rendered_body = row.config_snapshot["body_template"]`, fed into `http_transport(config, rendered_url, rendered_body)`) | confirmed — two call sites inside `do_attempt_dispatch/2`, one per `route_kind` branch |
| `url_template` IS rendered, `body_template` is explicitly out of scope today | `lib/letflow/engine.ex:1138-1147` (comment above `render_service_task_url/2`: "scoped ... to `url_template` only (`body_template` rendering is out of this requirement's own scope, §7 Open Question 2)") | confirmed |
| `render_service_task_url/2` is called at exactly two sites, both with `variables` already in scope | `lib/letflow/engine.ex:973` (`route_kind: :inline_url` branch of `resolve_service_task_arm_attrs/6`) and `:983` (`route_kind: :catalog_service` branch, using `resolved.endpoint_url`) | confirmed |
| `regulatory-auto-escalation` (SERVICE_TASK) has two distinct incoming edges with two distinct meanings | `test/fixtures/qa/meridian_regulatory_compliance_review_process_definition.json:113` (`timeout-risk-evaluation`: `risk-evaluation` → `regulatory-auto-escalation`, unconditioned, the 21-day SLA escalation path) and `:119` (`e10`: `post-remediation-check` → `regulatory-auto-escalation`, `condition: "variables.remediation_status == 'unresolved'"`) | confirmed |
| No edge-level "sets a variable" mechanism exists | `Letflow.Engine.Graph.Edge` carries only `id`/`source`/`target`/`condition` (no attribute map, no "sets"/"assign" key anywhere in `lib/letflow/engine/graph.ex` or `transition.ex`); grep of `lib/` for `"sets"` / edge-level variable assignment: none found | confirmed — a single static `body_template` on a shared node cannot vary correctly by inbound edge without inventing new engine semantics |
| No existing fixture's `body_template` uses `{{}}` placeholders today | grep of `test/fixtures/**/*.json` for `body_template` combined with `{{`: no hits; the only node that currently sets `body_template` at all is none (the meridian definition's SERVICE_TASK nodes set only `endpoint`/`method`/`timeout_ms`) | confirmed — rendering `body_template` for the first time is additive, nothing regresses |
| EO-001's audit check keys on the node id `regulatory-auto-escalation` literally | `test/fixtures/uat/scenarios/meridian/regulatory-compliance-review-bafin.yaml` EO-001 verification: "audit event type 'regulatory-auto-escalation' fired" | confirmed — the SLA-path node's id must not change |

## 1. Scope boundary

In scope:
- Generalize the inline template renderer so it can be applied to `body_template`, not just
  `url_template`, reusing the same `{{variables.KEY}}` regex/value logic (no new syntax, no
  escaping, no nested paths — same minimal contract as today, per the engine.ex:1144-1147
  comment's own framing of what a "future requirement" replacing this function should decide;
  this fix explicitly does NOT widen the template syntax, only which fields get run through it).
- Add `"rendered_body"` as a new derived key in `config_snapshot_map/3`'s output, mirroring the
  existing `"rendered_url"` key. `"body_template"` (raw) stays in the snapshot unchanged, for
  audit/debugging parity with `"url_template"`.
- Switch `ServiceTaskDispatcher`'s two `do_attempt_dispatch/2` branches to read
  `config_snapshot["rendered_body"]` instead of `config_snapshot["body_template"]`.
- Split the `regulatory-auto-escalation` SERVICE_TASK node in the meridian QA fixture into two
  nodes — one per distinct inbound meaning — each carrying its own correct, static
  `body_template`. Pure fixture/graph-authoring change; no new engine capability, no edge-level
  variable mechanism.

Out of scope (explicitly, so ELIXIR-DEV doesn't invent it mid-build):
- Any per-edge variable-assignment mechanism on `Graph.Edge`. ISSUE-FIXER confirmed none exists
  and recommended the node-split instead; this design follows that recommendation.
- Widening `{{variables.KEY}}` syntax (nested paths, filters, escaping, conditionals inside the
  template). Still out of scope, same as the original REQ-215 deferral.
- Any change to `headers` rendering. `headers` is a `%{String.t() => String.t()}` map today and
  nothing in the issue or the scenario requires header interpolation; left untouched. (Open
  question OQ-1 below notes this for the record, not as a silent decision.)
- Any change to `ServiceTask.Config` itself (field set, `@enforce_keys`, parsing). No new field
  is added to the struct — `rendered_body` lives only in the ephemeral `config_snapshot` map
  shape, exactly where `rendered_url` already lives today (it is not a `Config.t()` field
  either).

## 2. Renderer generalization — `Letflow.Engine`

### 2.1 Rename and re-scope the existing private function

`render_service_task_url/2` (private, `lib/letflow/engine.ex:1148-1156`) is renamed to
`render_service_task_template/2`. Its behavior is otherwise unchanged — same regex
(`~r/\{\{\s*variables\.([a-zA-Z0-9_]+)\s*\}\}/`), same `nil`-passthrough clause, same delegation
to `render_service_task_value/1` for per-key value coercion. This is a rename plus doc-comment
update, not a rewrite: the function body (match arms, regex, `Regex.replace/3` call) is
byte-for-byte what exists today under the old name.

```
@spec render_service_task_template(template :: String.t() | nil, variables :: map()) ::
        String.t() | nil
```

- Clause 1: `nil` template → `nil` (unchanged).
- Clause 2: binary template → `Regex.replace/3` over `{{variables.KEY}}`, each match resolved
  via `Map.get(variables, key) |> render_service_task_value()` (unchanged).

`render_service_task_value/1` (the four-clause private helper handling `nil`/binary/
number-or-atom/map-or-list — lines 1158-1165) is unchanged and shared as-is; it already has no
dependency on which field it's rendering for.

Doc comment above the renamed function is updated to drop the "scoped ... to `url_template`
only" sentence and the "`body_template` rendering is out of this requirement's own scope"
sentence (both now false), replacing them with a note that ISS-0926 extended this same function
to `body_template`, and that the function is still the same deliberately-minimal shape flagged
in REQ-215 §7 OQ-2 as not the long-term renderer design — that framing still holds, it now just
covers two fields instead of one.

### 2.2 Call sites — apply the (now-shared) renderer to `body_template`

At each of the two existing call sites inside `resolve_service_task_arm_attrs/6`
(`lib/letflow/engine.ex:967-1001`), alongside the existing `rendered_url` computation, compute a
sibling `rendered_body`:

- Site 1 (`route_kind: :inline_url`, line ~973): after
  `rendered_url = render_service_task_template(config.url_template, variables)`, add
  `rendered_body = render_service_task_template(config.body_template, variables)`.
- Site 2 (`route_kind: :catalog_service`, line ~983): after
  `rendered_url = render_service_task_template(resolved.endpoint_url, variables)`, add
  `rendered_body = render_service_task_template(config.body_template, variables)` (the catalog
  path renders the *endpoint* from the resolved catalog version, but `body_template` is still
  authored on the node itself via `config`, same as today's unrendered behavior — ISSUE-FIXER's
  diagnosis and the current code agree `body_template` is never catalog-sourced).

Both `rendered_body` values are then threaded through to `config_snapshot_map/3`:

- `finish_service_task_arm_attrs/5` and `/6` (`lib/letflow/engine.ex:1068-1089`) gain one new
  parameter, `rendered_body`, inserted after `rendered_url` in the existing positional argument
  list (both the 5-arity inline-url call and the 6-arity catalog call pass it through).
- `config_snapshot_map/3` becomes `config_snapshot_map/4`, taking `rendered_body` as a new
  positional parameter (placed after `rendered_url`, before `catalog_version`, to match the
  existing left-to-right "raw config → derived values → catalog overlay" ordering).

### 2.3 `config_snapshot_map/4`'s new output key

Inside the `base` map literal (`lib/letflow/engine.ex:1112-1122`), add one new key:

```
"rendered_body" => rendered_body
```

placed immediately after the existing `"rendered_url" => rendered_url` line, so the raw/derived
pairing (`"url_template"`/`"rendered_url"`, `"body_template"`/`"rendered_body"`) reads
consistently top-to-bottom. The existing `"body_template" => config.body_template` line is
**not removed** — it stays, for audit/debugging parity with `"url_template"`, which is likewise
kept raw alongside its own rendered counterpart.

The `catalog_version` branch of `config_snapshot_map/4` (the `%{} = resolved ->` clause,
lines 1128-1134) needs no change: it already works by `Map.merge/2` over `base`, so
`"rendered_body"` flows through to catalog-pinned snapshots automatically.

`@spec` update:

```
@spec config_snapshot_map(
        ServiceTask.Config.t(),
        rendered_url :: String.t() | nil,
        rendered_body :: String.t() | nil,
        ServiceCatalog.resolved_service_version() | nil
      ) :: map()
```

### 2.4 No change to `ServiceTask.Config` or `parse_config_from_node_attributes/1`

`body_template` parsing (`lib/letflow/engine/service_task.ex:226`) is unchanged — it still reads
the raw, unrendered template string off the node's attributes. Rendering happens exactly once,
at activation time in `Letflow.Engine`, same lifecycle stage as `url_template` rendering — this
preserves the existing "frozen at activation, replayed verbatim on every dispatch attempt"
invariant that `rendered_url` already relies on (ISS-0917's framing, engine.ex:955-966): a
retried dispatch attempt must resend the identical rendered body it would have sent on attempt
0, not re-evaluate variables that may have changed since.

## 3. `ServiceTaskDispatcher` — switch read site to the rendered key

`lib/letflow/engine/service_task_dispatcher.ex`, inside `do_attempt_dispatch/2`:

- Line ~719 (`route_kind: :inline_url` branch):
  `rendered_body = row.config_snapshot["body_template"]` →
  `rendered_body = row.config_snapshot["rendered_body"]`.
- Line ~741 (`route_kind: :catalog_service` branch, nested inside the `rendered_url when
  is_binary(...)` clause):
  `rendered_body = row.config_snapshot["body_template"]` →
  `rendered_body = row.config_snapshot["rendered_body"]`.

No other line in this module changes. `config_from_snapshot/1` (the function that rebuilds a
`ServiceTask.Config.t()` from the snapshot for retry-limit/method/route-kind purposes,
referenced in the `config_snapshot_map/3` moduledoc comment at engine.ex:1096-1098) is
unaffected — it never reads `body_template` or `rendered_body` itself; only the two
`do_attempt_dispatch/2` branches read the body value directly off `row.config_snapshot`, and
both are covered above.

Variables used for rendering are exactly the hop-chain's in-scope `variables` map at activation
time (same source `render_service_task_template/2` already uses for `url_template`) — no new
variable-resolution path is introduced.

## 4. Fixture change — split `regulatory-auto-escalation` into two nodes

Target: `test/fixtures/qa/meridian_regulatory_compliance_review_process_definition.json`.

### 4.1 Why a split, not a shared `body_template` (confirmed, not re-derived)

The node has two inbound edges with two distinct, mutually exclusive meanings:

- `timeout-risk-evaluation` (`risk-evaluation` → node, unconditioned): fires when the 21-day
  SLA escalation timer trips. The correct BaFin reason is `sla_breach_30_days` (scenario
  `regulatory-compliance-review-bafin.yaml` EO-002).
- `e10` (`post-remediation-check` → node, `condition: "variables.remediation_status ==
  'unresolved'"`): fires when a remediation sub-process concluded unresolved. Sending
  `sla_breach_30_days` on this path would misstate the regulatory reason to BaFin — a wrong
  reason on a regulatory filing is worse than a missing one (same conclusion ISS-0932's design
  doc §4 already reached).

Since `Graph.Edge` carries no "sets a variable" clause (section 0 above), a single static
`body_template` field cannot vary by inbound edge. The fix is graph-authoring, not an engine
feature: two separate SERVICE_TASK nodes, each with its own static `body_template`, each reached
by exactly one of the two edges.

### 4.2 Node 1 (kept, unchanged id) — the SLA-breach path

- Id stays `regulatory-auto-escalation` (**not renamed** — this is load-bearing: EO-001's audit
  check asserts literally on this node id, and ISS-0932 already relies on this id for the timer
  path; renaming it would regress both).
- `node_type` stays `SERVICE_TASK`.
- `attributes.endpoint` stays `https://httpbin.org/anything/compliance/regulatory-notice`.
- `attributes.method` stays `POST`.
- `attributes.timeout_ms` stays `300000`.
- New attribute `attributes.body_template`, a JSON-encoded string, content:
  `{"reason":"sla_breach_30_days","review_id":"{{variables.review_id}}"}`
  (one placeholder, `{{variables.review_id}}`, consistent with the existing
  `{{variables.review_id}}` usage already present elsewhere in this same fixture, e.g.
  `archive-review`'s `endpoint` — so this is the established variable name for this scenario,
  not a new invention).
- Inbound edges: only `timeout-risk-evaluation` now targets this node (unchanged from today).
- Outbound edge: `e5` (`regulatory-auto-escalation` → `end-closed`) stays exactly as-is,
  unchanged id and endpoints.

### 4.3 Node 2 (new) — the remediation-unresolved path

- New node id: `remediation-unresolved-escalation` (distinct from the kept node; descriptive of
  its one trigger condition, matching this fixture's existing naming convention of
  trigger-condition-shaped ids like `evidence-collection-timeout`, `cro-sign-off-timeout`).
- `node_type`: `SERVICE_TASK`.
- `attributes.endpoint`: same BaFin regulatory-notice endpoint as node 1 —
  `https://httpbin.org/anything/compliance/regulatory-notice` (same external system, different
  reason payload; this is the whole point of the split).
- `attributes.method`: `POST`.
- `attributes.timeout_ms`: `300000` (same bound as every other SERVICE_TASK in this fixture).
- `attributes.body_template`: a JSON-encoded string, content:
  `{"reason":"remediation_unresolved","review_id":"{{variables.review_id}}"}` — distinct reason
  string, consistent with the scenario's narrative (a remediation sub-process that concluded
  `remediation_status == 'unresolved'` is a materially different regulatory fact than a 21-day
  SLA breach, and must not be reported as the latter).
- Inbound edge: `e10` is retargeted from `post-remediation-check` → `regulatory-auto-escalation`
  to `post-remediation-check` → `remediation-unresolved-escalation`. `e10`'s own id and
  `condition` (`variables.remediation_status == 'unresolved'`) are unchanged — only its `target`
  changes.
- New outbound edge: id `e18` (next unused edge id in this fixture's sequence — current ids run
  e0–e17), `source: "remediation-unresolved-escalation"`, `target: "end-closed"`, no condition
  (mirrors `e5`'s shape exactly — both escalation paths close the instance the same way).

### 4.4 Everything else in the graph: unchanged

`post-remediation-check` (EXCLUSIVE_GATEWAY) keeps both its outbound edges: `e9` (→
`findings-sign-off`, `remediation_status == 'resolved'`) unchanged, and the retargeted `e10`
(→ `remediation-unresolved-escalation` now instead of `regulatory-auto-escalation`). No other
node, edge, or attribute in the file changes.

### 4.5 Top-level metadata bump

Same convention ISS-0932 used (`"1.1"` → `"1.2"`, confirmed at
`git show b6a4773d -- test/fixtures/qa/meridian_regulatory_compliance_review_process_definition.json`):

| Field | Old | New |
|---|---|---|
| `version` | `"1.2"` | `"1.3"` |
| `description` | current text (ends "...Edge e3 carries the constant condition 'true' on purpose: it always wins on normal task completion but is skipped by the escalation-timer path, which follows the single non-conditioned edge timeout-risk-evaluation.") | append one sentence: "The 21-day SLA-breach path and the remediation-unresolved path file distinct BaFin regulatory-notice reasons (`sla_breach_30_days` on `regulatory-auto-escalation` via `timeout-risk-evaluation`; `remediation_unresolved` on the new node `remediation-unresolved-escalation` via `e10`) — the two inbound meanings of the former shared node are now split into two nodes because edges carry no variable-assignment mechanism." |

`version` is mandatory per `scripts/seed_meridian_definition.sh`'s strictly-newer `sort -V`
replacement rule (same note ISS-0932's design doc §5 recorded) — ELIXIR-DEV must bump it or the
seeded ACTIVE definition will not update.

## 5. Acceptance-criteria mapping

| Acceptance criterion (from the handoff) | Design element that satisfies it |
|---|---|
| EO-002's `sla_breach_30_days` reason is actually delivered in the rendered body on the SLA path | §2 (renderer applied to `body_template` → `rendered_body`), §3 (dispatcher reads `rendered_body`), §4.2 (node 1's `body_template` literally contains `sla_breach_30_days`) |
| The `e10` path delivers its own distinct, correct reason | §4.3 (new node `remediation-unresolved-escalation` with `body_template` containing `remediation_unresolved`), §4.3 (edge `e10` retargeted) |
| No existing SERVICE_TASK usage regresses | §0 (confirmed no existing fixture uses `{{}}` in `body_template` today — purely additive for every other node, which all have `body_template: nil` and therefore `rendered_body: nil`, identical to today's `nil` raw value being sent); §2.3 (raw `"body_template"` key preserved, nothing removed) |
| EO-001's audit-trail check still passes (original node id preserved) | §4.2 (`regulatory-auto-escalation` id kept stable, only its own `body_template` attribute is added) |

## 6. Open questions (not silently resolved)

- **OQ-1 — header interpolation.** `headers` (`%{String.t() => String.t()}`) is not run through
  the renderer by this fix. No current requirement or scenario needs it, but a future
  requirement might (e.g. an `Idempotency-Key` or `Authorization` header templated from
  variables). Left out of scope deliberately; flagging rather than silently deciding it's never
  needed.
- **OQ-2 — JSON-template authoring risk.** `body_template` is a plain string rendered by
  textual substitution, same mechanism as `url_template`. If a rendered variable value itself
  contains a `"` or other JSON-breaking character, `render_service_task_value/1`'s binary clause
  does no escaping (unchanged from today's behavior for URLs). Not a regression introduced by
  this fix — the same risk already exists wherever `url_template` interpolates a variable into a
  URL path segment — but worth CODE-DESIGN-VALIDATOR/REVIEWER noting explicitly since a
  malformed JSON body is a new failure mode this fix newly enables (previously `body_template`
  was never rendered, so it was always syntactically whatever the author typed verbatim). No fix
  proposed here: REQ-215's own framing already marks this renderer as not the long-term shape,
  and real JSON-escaping is exactly the kind of "richer syntax" follow-up that comment already
  anticipates.
- **OQ-3 — `remediation-unresolved-escalation`'s audit-trail visibility.** This fix does not
  write or update any UAT scenario file to assert on the new node's audit trail (e.g. an EO-00N
  for the `e10`/remediation-unresolved path) — the handoff's acceptance criteria only require
  that the new node "delivers its own distinct, correct reason," not that a scenario file assert
  it. If TEST-DESIGNER or a later UAT run wants scenario-level coverage of this second path, that
  scenario does not exist yet and would need to be authored separately.

## 7. SECURITY-REVIEWER applicability

Recommendation: **not required**, but flagging the one consideration that makes this a judgment
call rather than an obvious skip, for CODE-DESIGN-VALIDATOR to weigh:

- No new authentication/authorization path, no new tenant-data-read/write path, no new public
  API route, no migration, no change to how a request is routed or which schema/tenant it
  targets. This is template rendering of a value already fully under the authoring tenant's own
  control (the node's own `body_template` attribute, set when the process definition itself was
  authored) and already being sent as the HTTP body today (unrendered) — the SSRF gate and
  transport layer (`http_transport/3`, mentioned at service_task_dispatcher.ex:735) are
  unchanged; this fix only changes the content of an outbound body, never the URL/destination
  that gate already guards.
- The one reason to flag rather than silently skip: this does change *what external HTTP body
  content gets sent* on every SERVICE_TASK dispatch with a non-nil `body_template` going forward
  (previously the literal unrendered template string; now that string with `{{variables.KEY}}`
  placeholders substituted). The values substituted come from the same `variables` map already
  trusted for URL rendering (no new trust boundary crossed), but CODE-DESIGN-VALIDATOR should
  independently confirm that framing holds before waving SECURITY-REVIEWER off, since "outbound
  webhook body content" is adjacent to data-exfiltration concerns in a multi-tenant system even
  when the rendering mechanism itself is unchanged.
