# WF-03 Fix Design -- ISS-0926 / Q-926 (SERVICE_TASK `body_template` is not rendered by the engine)

Run-id: WF03-Q926-20261001
Type: lib change (MINOR, `ELIXIR-DEV`) plus fixture split (JSON + YAML parity) plus tests.
No migration, no supervision files, no new dependency.
Issue: `docs/issues/ISS-0926.yaml` (queue Q-926, GH-2106). Diagnosis:
`handoffs/WF03-Q926-20261001/step-01-issue-fixer-diagnose.json`.
Rework iteration 1 (2026-10-01): addresses CODE-DESIGN-VALIDATOR issues 1-7 (Jason option,
sub-process dispatch gap 3.6, concrete T14, typespec, reason-class function, placeholder scan,
duplicate mutant).
Design author: CODE-DESIGNER. Not self-reviewed; CODE-DESIGN-VALIDATOR gates this file.
Tenant-data path (instance variables flow into an outbound HTTP body): SECURITY-REVIEWER
gate applies (INV-2, INV-8).

## 0. Claims re-verified against code (HANDOFF_PROTOCOL 1.1)

Every line number below was read at HEAD `c6bd4b62`.

| Diagnosis claim | Verified at | Result |
|---|---|---|
| `body_template` parsed verbatim, no rendering | `service_task.ex:226` `body_template: Map.get(attrs, "body_template")` | Confirmed. URL comes from attribute `"endpoint"` (`:205`), body from `"body_template"` |
| Raw template frozen in snapshot | `engine.ex:1117` `"body_template" => config.body_template` inside `config_snapshot_map/3` (`:1111-1122`) | Confirmed. No `rendered_body` key exists |
| Dispatcher sends the raw template | `service_task_dispatcher.ex:719` (inline) and `:741` (catalog): `rendered_body = row.config_snapshot["body_template"]` | Confirmed. Correction to the issue text: the body IS sent, but unrendered; `{{variables.X}}` goes out literally |
| Only `variables`-in-scope site is activation | `engine.ex:967-995` `resolve_service_task_arm_attrs/6`; `finish_service_task_arm_attrs/6` at `:1068-1092` | Confirmed. Dispatcher poller has no instance variables |
| URL renderer is flat-key, no escaping | `engine.ex:1152-1165` (`render_service_task_url/2`, `render_service_task_value/1`) | Confirmed |
| Content-type injected iff template non-nil | `service_task_dispatcher.ex` `headers_from/1` (`if body_template do`) | Confirmed. Uses `config.body_template`, not the snapshot's rendered body |
| `config_snapshot` is a plain map column | `priv/repo/migrations/20260902010001_create_service_task_dispatches.exs:80` `add :config_snapshot, :map, null: false`; schema `field(:config_snapshot, :map)` (`service_task_dispatcher.ex:151`) | Confirmed. Adding a key needs no migration |
| Snapshot is read only by the engine and the dispatcher | `grep config_snapshot lib` returns only `engine.ex` and `service_task_dispatcher.ex`; no router/serializer | Confirmed. No API echoes it; the dispatcher has no `Logger` call |
| Outbound body is never audited | `append_service_task_completed_event/4` (`engine.ex:3446`) records `dispatch_id`, `node_id`, `decoded_body` (the RESPONSE) only | Confirmed. See section 3.5 for the consequence for EO-002 |

## 1. Rendering

### 1.1 Where, and what is frozen

Body rendering happens at activation, in the same place and from the same `variables` map as
`rendered_url` (`finish_service_task_arm_attrs`, called from `resolve_service_task_arm_attrs`
at `engine.ex:967-995`), and the result is frozen in the snapshot as
`config_snapshot["rendered_body"]`. Rendering at dispatch time is rejected: the dispatcher has
no access to instance variables, and dispatcher design section 5.6 ("re-renders nothing, ever")
makes the snapshot the single frozen source for every retry attempt.

Rules:

1. The render step runs once per activated SERVICE_TASK, after the URL has been rendered and
   passed `ServiceTask.validate_rendered_url/1`. Precedence: an empty-URL error wins over a
   body error (the existing `{:empty_url_error, node_id}` branch is taken first).
2. `rendered_body` is `nil` when `config.body_template` is `nil` (key still written, value
   `nil`). It is a `String.t()` otherwise. The key is therefore ALWAYS present on rows created
   after this change; its absence identifies a legacy row (section 1.5).
3. `"body_template"` (the raw template) stays in the snapshot unchanged. Reasons:
   `config_from_snapshot/1` (`service_task_dispatcher.ex:800`) rebuilds `Config.t()` from it,
   and `headers_from/1` keys the `content-type: application/json` header off its presence.
   Since rule 2 guarantees `rendered_body` is non-nil exactly when `body_template` is non-nil,
   `headers_from/1` needs no change.
4. The dispatcher sends `rendered_body`, never the raw template (section 1.4).
5. Retries resend the identical frozen `rendered_body`; no re-render, so a retry cannot see
   changed variables.

### 1.2 Placeholder syntax

Exactly the URL renderer's syntax, same regex semantics: `{{variables.KEY}}` with optional
inner whitespace, `KEY` matching `[a-zA-Z0-9_]+`, flat key only (no nested paths, no
filters, no defaults). Any other `{{ ... }}` text is NOT a placeholder and is left literal
(parity with the URL renderer; it is simply body text).

The URL renderer is NOT changed in behaviour. Its function, regex and `render_service_task_value/1`
stay exactly as they are (it keeps `nil -> ""` and unescaped substitution, correct for a URL
that is validated by `UrlValidator` at dispatch). Only its doc comment (`engine.ex:1138-1147`)
is updated to say body rendering now lives in `Letflow.Engine.ServiceTask.render_body_template/2`.
The body renderer is a separate pure function in `ServiceTask`; it does not share the URL
renderer's value stringifier because the escaping and missing-variable rules differ.

### 1.3 Missing and nil variable behaviour

| Variable state | Result | Rationale |
|---|---|---|
| Key absent from `variables` | `{:error, {:missing_variable, key}}` | The body goes to an external party (the fixture's BaFin notice). A silently empty `review_id` on an irreversible regulatory filing is worse than an activation failure the operator can see. The URL renderer's lenient `""` is kept for URLs only because `validate_rendered_url/1` guards the all-empty case |
| Key present, value `nil` (JSON null) | substitutes the empty string | An explicit null is data, not absence |
| Key present, any other value | stringified per section 2.2 | |

Accepted trade-off, recorded: on the timer-fire and other non-hop sites (section 1.6) a
`:missing_variable` rolls the whole attempt back, so a definition whose instances omit the
referenced variable would have its escalation timer retried until exhausted instead of firing.
That is the existing, documented scope boundary for every activation error on those sites
(`prepare_service_task_dispatch_abort_on_empty_url/6`), not widened here. The shipped fixture
references only `review_id`, which the scenario supplies at instance start (scenario step 1
input; `regulatory_review_timer_path_test.exs:79` supplies it too).

### 1.4 Dispatcher change

Both dispatch branches replace `rendered_body = row.config_snapshot["body_template"]`
(`service_task_dispatcher.ex:719` inline, `:741` catalog) with a call to one new private
helper that resolves the body to send:

```
@spec resolve_dispatch_body(ServiceTaskDispatch.t()) ::
        {:ok, rendered_body :: String.t() | nil} | {:error, :unrenderable_legacy_body}
defp resolve_dispatch_body(row)
```

Behaviour (full table in 1.5). On `{:error, :unrenderable_legacy_body}` the branch does NOT call
`http_transport/3`; it calls `handle_failure(row, tenant_schema, config.retry_limit,
:request_build_error)` exactly as the existing malformed-snapshot and missing-`rendered_url`
branches do (`:request_build_error` is non-retriable, `is_retriable_failure/1`
`service_task.ex:442`, so the row gives up immediately and the instance goes to ERROR through
the existing give-up path). No new `failure_kind`.

### 1.5 Legacy snapshots (rows created before this change)

Rows with `status = "pending"` may exist whose snapshot has no `"rendered_body"` key.
The helper keys off key presence (`Map.fetch`), not nil-ness:

| Snapshot | Action | Why |
|---|---|---|
| `"rendered_body"` key present (value `nil` or string) | use it as is | New-format row |
| key absent, `"body_template"` is `nil` | `{:ok, nil}` | Identical to today; no body |
| key absent, template present, `ServiceTask.body_has_placeholders?/1` is `false` | `{:ok, template}` | A static template needs no rendering; byte-identical to today's behaviour, backward compatible |
| key absent, template present, has a `{{variables.KEY}}` placeholder | `{:error, :unrenderable_legacy_body}` (fail closed) | The variables are gone from the dispatcher's reach, so it cannot render, and today's behaviour (sending literal `{{variables.X}}` to the third party) is the defect being fixed. Failing closed is safe: no outbound request is made |

No row in any shipped fixture or test carries a templated body (grep of `test/fixtures` and the
Meridian/Vortex QA JSON found no `body_template`), so the fail-closed population is expected to
be empty. No data backfill and no migration.

### 1.6 Catalog path (ISS-0917) and all activation sites

`body_template` is a NODE attribute on both route kinds. The catalog supplies `endpoint_url`
and `timeout_ms` only; it supplies none of `method`, `body_template`, `headers`, `retry_limit`
(`iss0917-catalog-service-task-pinned-dispatch.md` line 258 table, row "unchanged (node
attributes; the catalog supplies none of these)"). Therefore a catalog node's template comes from
the same node attribute as an inline node's, and BOTH paths are covered by one render step:
`finish_service_task_arm_attrs` is called by both the `:inline_url` clause (`engine.ex:975`) and
the `:catalog_service` clause (`engine.ex:985`), and `config_snapshot_map` is shared. The catalog
clause renders the body only after `resolve_catalog_version` succeeded (a catalog resolution
error still wins and short-circuits before any body render). There is no catalog limit to state:
nothing is deferred.

Signature changes (all private, `engine.ex`):

```
@spec finish_service_task_arm_attrs(
        ServiceTask.Config.t(), node_id :: String.t(), instance_id :: Ecto.UUID.t(),
        rendered_url :: String.t() | nil, variables :: map(), now :: DateTime.t(),
        ServiceCatalog.resolved_service_version() | nil
      ) :: {:ok, map()}
         | {:empty_url_error, node_id :: String.t()}
         | {:body_render_error, node_id :: String.t(), ServiceTask.body_render_reason()}

@spec config_snapshot_map(
        ServiceTask.Config.t(), rendered_url :: String.t() | nil,
        rendered_body :: String.t() | nil, ServiceCatalog.resolved_service_version() | nil
      ) :: map()
```

(`variables` is inserted before `now`; the optional `catalog_version \\ nil` default stays last.
The two callers at `:975` and `:985` pass `variables`.) `config_snapshot_map` gains the
`"rendered_body" => rendered_body` entry beside `"rendered_url"`; the catalog audit keys are
unchanged. The `@spec` of `resolve_service_task_arm_attrs/6` return widens by
`{:body_render_error, node_id, reason}`.

### 1.7 Error propagation (mirrors the catalog-unresolved plumbing 1:1)

A new tagged tuple `{:body_render_error, node_id, reason, variables}` leaves
`prepare_service_task_dispatch/6` (extend its `@spec` at `engine.ex:860-874`, the `reduce_while`
at `:915-936`, and the final `case` at `:939-944`) and is folded at each existing site exactly
where `{:catalog_resolution_error, ...}` is folded. `reason` in that tuple is the ATOM CLASS, not
the full reason. The reduction is done by the public pure function
`ServiceTask.body_render_reason_class/1` (section 2.6), called in exactly one place:
`Engine.prepare_service_task_dispatch/6`, at the point where it converts the
`{:body_render_error, node_id, full_reason}` it received from `resolve_service_task_arm_attrs`
(which carries the FULL `ServiceTask.body_render_reason()`, including `{:missing_variable, key}`)
into the 4-tuple above. Everything downstream of that point (create fold, completion fold,
timer fold, `build_body_render_error_attrs/1`, tests I-6/I-7/I-8) sees only the class atom.
The engine-side `catalog_resolution_reason` typep gets a
sibling `body_render_reason` (alias of `ServiceTask.body_render_reason()`).

| Site (anchor) | Folds to |
|---|---|
| `create/2`: `prepare_service_task_dispatch_for_create` (`engine.ex:619-623`) | `{:error, {:activation_failed, {:service_task_body_render_failed, node_id, reason_class}}}`; nothing persisted (same as the empty-URL and catalog-unresolved create failures) |
| completion hop: `prepare_service_task_dispatch_for_completion` (`:3861-3884`) and the `{:error, {:catalog_resolution_error, error_args}}` clause (`:3771`) | new sibling `{:error, {:body_render_error, error_args}}` clause that maps to `{:ok, {:execution_error, error_args}}`; `error_args` from `ServiceTask.build_body_render_error_attrs/1`, `error_type: :service_task_body_render_failed` (the `error_type` union in `execution_error.ex` is open, `:99-107`), instance goes to ERROR with no `service_task_dispatches` row |
| timer-fire, escalation-timer-fire, service-outcome advance: `prepare_service_task_dispatch_abort_on_empty_url` (`:3096-3100`; call sites `:2682`, `:2904`, `:3323`) | `{:error, {:service_task_body_render_failed_not_supported_for_timer_fire, node_id, reason_class}}`; rolls back the attempt, same documented scope boundary as the empty-URL and catalog clauses. Not widened |

The completion-hop ERROR is already surfaced to HTTP callers as 409 with only the `error_type`
atom in `detail` (`req085-task-routes-write.md:555`, "Uniform for every `error_type`"), so no
router change is needed and the new `error_type` leaks nothing.

## 2. Escaping and injection (SECURITY)

### 2.1 Decision: option A, per-value JSON-string escaping, no concrete flaw found

Adopt diagnosis option A. Re-examined for a concrete flaw; none blocks it:

- Structure injection is impossible: every substituted value is rendered as the inside of a JSON
  string (quote, backslash, control characters escaped), so a value cannot close the string,
  add keys, or add array elements.
- Key-position placeholders (`{"{{variables.k}}": 1}`) can only change the key's text, never the
  structure. Accepted and pinned by a test (T-R14); it can create a duplicate key if an author
  deliberately builds one, which is an authoring concern, not an injection.
- Typed values (numbers, booleans, objects) become strings; a receiver needing a JSON number
  cannot get one. Accepted limitation of option A, stated in the author-facing docs; option B/C
  are the upgrade path and are out of scope here.
- Options B (typed whole-token) and C (decode, substitute leaves, re-encode) are rejected for
  this change: new authoring conventions and larger blast radius for a MINOR fix. Option D (raw
  substitution like the URL renderer) is rejected as an injection hole.

### 2.2 Value stringification (before escaping)

Per looked-up value, `ServiceTask` private `stringify_value/1` returns `{:ok, String.t()}` or a
typed error. No raising: `Jason.encode!/1` must NOT be used (INV-8); use the tuple-returning
`Jason.encode/2`.

| Value | String form |
|---|---|
| binary (valid UTF-8) | as is |
| binary (invalid UTF-8) | `{:error, :invalid_utf8}` |
| integer | decimal digits (`Integer.to_string/1`) |
| float | `Float.to_string/1` shortest round-trip form |
| `true` / `false` | `"true"` / `"false"` |
| `nil` | `""` |
| any other atom | `Atom.to_string/1` (jsonb never yields one; defensive) |
| map or list | compact JSON text via `Jason.encode/1`; the resulting TEXT is then escaped like any string, so it lands as one JSON string value (nested structure is flattened to a string, never spliced) |
| anything else (tuple, pid, struct without encoder) or encode failure | `{:error, :unsupported_value_type}` |

### 2.3 JSON string escaping

Chosen option (exactly one): `Jason.encode(string, escape: :javascript_safe)`, then remove
exactly the first and last byte of the result (the surrounding `"` characters). Not
`:json`, not `:html_safe`, not `:unicode_safe`.

Verified against the pinned dependency: `mix.lock` pins `jason` 1.4.5; the option list is
documented at `deps/jason/lib/jason.ex:105-113` and `:javascript_safe` is wired to
`escape_javascript/1` at `deps/jason/lib/encode.ex:58`. The byte table is built at
`encode.ex:283-302`: the `:javascript_safe` path escapes the same single-byte set as `:json`
(`ranges` = U+0000..U+001F plus the seven characters backspace, tab, newline, form feed, carriage return, double quote and backslash; `/` and `<` are
only in the separate `html_ranges` list used by `:html_safe`) and additionally the two
codepoints U+2028 and U+2029 (`surogate_escapes`, `encode.ex:285`, applied in
`escape_javascript/4` from `:374`). Exact guarantees, and nothing beyond them:

- `"` becomes backslash + `"` (two characters), and a backslash becomes two backslashes.
- Control characters U+0000 through U+001F: the five U+0008, U+0009, U+000A, U+000C, U+000D
  become `\b`, `\t`, `\n`, `\f`, `\r`; every other one becomes `\u00XX` with UPPERCASE hex
  (format `~4.16.0B`, `encode.ex:292`), for example NUL is `\u0000`, U+001F is `\u001F`.
- U+2028 becomes the six ASCII characters backslash, `u`, `2`, `0`, `2`, `8` (written `\u2028` in prose; the test must assert the six-character form, never the raw codepoint); U+2029 likewise with `2029`.
- `/` is NOT escaped (it stays `/`). No expectation anywhere may contain backslash followed by `/`.
- `<`, `>`, `&` are NOT escaped.
- DEL (U+007F) is NOT escaped (the byte table covers 0x00..0x7F and DEL is a pass-through).
- All other non-ASCII text (emoji, Cyrillic, CJK, and so on) is emitted as UTF-8 unchanged.
- An invalid UTF-8 byte makes `Jason.encode/2` return `{:error, %Jason.EncodeError{}}`
  (`error({:invalid_byte, ...})` in `escape_javascript/4`). Section 2.2 rejects invalid UTF-8
  with `String.valid?/1` before this step, so this is not reachable from `stringify_value/1`;
  if it ever occurs it must map to `{:error, :invalid_utf8}` (never raise).

Every guarantee above has its own test row in 6.1 (T-R6, T-R7a to T-R7e).

The escaped text replaces the placeholder in place. Template text outside placeholders is copied
verbatim (it is author-controlled and trusted).

### 2.4 Placeholder position: must be inside a quoted JSON string; otherwise REJECT

Decision: a placeholder located outside a JSON string literal is rejected at activation with
`{:error, :placeholder_outside_string}`; it is NOT left literal and NOT substituted.
Justification: leaving it literal would send an invalid body (`{"a": {{variables.x}}}`) to a
third party, and substituting it unquoted is exactly the injection the per-value escaping
cannot protect. A typed activation failure is visible and fail-closed, consistent with the
empty-URL and catalog-unresolved errors.

Detection (specified as an algorithm, no code). The scan runs over the ORIGINAL template text
(never over partly substituted text), once, left to right, by a character loop (not by
regex), and it is the only place that decides position. Placeholders themselves are
recognised by the section 1.2 regex, `Regex.scan/3` with `return: :index`, run over the same
original template, giving a list of `{start_byte, length}` spans; the scan and the span list
are joined by byte offset: for every span, `in_string` is evaluated as of the first byte of
that span.

State: `in_string` (starts false) and `escaped` (starts false). For each character of the
original template, in order:

1. Inside a string and `escaped` is true: clear `escaped`; nothing else.
2. Inside a string and the character is a backslash: set `escaped`.
3. Inside a string and the character is `"`: set `in_string` false (string closed).
4. Outside a string and the character is `"`: set `in_string` true.
5. A backslash OUTSIDE a string is ignored (no `escaped` flag; it is not valid JSON there and
   the section 2.5 decode check will reject the template).
6. Any other character: no state change.

Because a placeholder (`{{`, `variables.`, key, `}}`) contains no `"` and no backslash, the
state cannot change while inside a span, so evaluating `in_string` at the span's first byte
is exact. A placeholder in a span with `in_string` false returns
`{:error, :placeholder_outside_string}` (the FIRST such span in template order wins; this
whole-template check runs before any substitution and before any variable is looked up).
All spans inside strings are then substituted per 2.2/2.3. Nested JSON needs no extra state:
braces and brackets never affect quote state. A template whose quotes never close is not
caught here; it is caught by the 2.5 decode check (`:rendered_body_not_json`). Complexity is
linear in template size; the loop is iterative.

### 2.5 Decodability and size

After substitution, when (and only when) the template contained at least one placeholder:

1. `Jason.decode/1` of the rendered text must return `{:ok, _}`, else
   `{:error, :rendered_body_not_json}`. Content-type is hardcoded to `application/json`
   (`@http_content_type`, `service_task_dispatcher.ex:100`), so every body is JSON by contract;
   this catches a malformed template or an unbalanced quote that the scan alone cannot.
2. `byte_size(rendered) <= @max_rendered_body_bytes` (module attribute in `ServiceTask`,
   value `65_536`), else `{:error, :rendered_body_too_large}`. 64 KiB bounds snapshot jsonb
   growth and the outbound request; a notice body is small.

A template with ZERO placeholders is returned verbatim with no decode check and no size check:
byte-identical to today's behaviour, so no existing definition gains a new failure mode.
(Note: a pre-existing static non-JSON template therefore still goes out with the JSON
content-type, exactly as today; out of scope.)

### 2.6 Typed, non-leaking errors

```
@type body_render_reason ::
        :placeholder_outside_string
        | {:missing_variable, key :: String.t()}
        | :invalid_utf8
        | :unsupported_value_type
        | :rendered_body_not_json
        | :rendered_body_too_large

@type body_render_reason_class ::
        :placeholder_outside_string
        | :missing_variable
        | :invalid_utf8
        | :unsupported_value_type
        | :rendered_body_not_json
        | :rendered_body_too_large

@spec body_render_reason_class(body_render_reason()) :: body_render_reason_class()
```

`ServiceTask.body_render_reason_class/1` is public and pure: identity for the five bare atoms,
`{:missing_variable, _key}` becomes `:missing_variable`. Sole caller: section 1.7
(`Engine.prepare_service_task_dispatch/6`). `body_render_error_context.reason` is typed
`body_render_reason_class()`.

The six fixed `reason` sentences (one per class, returned by `build_body_render_error_attrs/1`;
no interpolation of any kind):

| Class | `reason` sentence |
|---|---|
| `:placeholder_outside_string` | `service task body template could not be rendered: placeholder outside a JSON string` |
| `:missing_variable` | `service task body template could not be rendered: referenced variable is not set` |
| `:invalid_utf8` | `service task body template could not be rendered: variable value is not valid UTF-8` |
| `:unsupported_value_type` | `service task body template could not be rendered: variable value type is not supported` |
| `:rendered_body_not_json` | `service task body template could not be rendered: result is not valid JSON` |
| `:rendered_body_too_large` | `service task body template could not be rendered: result exceeds the size limit` |

`{:missing_variable, key}` carries only the author-written template key name (not a value).
Nothing in any error ever contains a variable value or any part of a rendered body.
`build_body_render_error_attrs/1` persists ONLY the atom class in `details: %{reason: class}`
(`:missing_variable` drops the key), and `reason` text is a fixed sentence per class
(for example "service task body template could not be rendered: placeholder outside a JSON
string"), never an interpolation. `variables` in the attrs map is the existing field that every
sibling builder already passes (`build_empty_url_error_attrs/1`), unchanged policy.

### 2.7 Secrets, PII and logging

- No `Logger`, `IO.inspect` or telemetry call may receive the template-with-values, the rendered
  body, or a variable value, in `ServiceTask`, `Engine` or the dispatcher (INV-2/INV-8; iss0917
  design ~line 649 already forbids it). The dispatcher has no `Logger` use today; keep it so.
- `rendered_body` IS stored in `config_snapshot` (decision). It cannot be dropped: the
  dispatcher has no variables and the retry contract requires a frozen body. PII consideration:
  the snapshot already holds `rendered_url`, which embeds variables (for example `review_id`),
  lives in the tenant's own schema table `service_task_dispatches`, and is read only by the
  engine and the dispatcher (section 0; no router or serializer reads it). The new key widens
  that exposure by the body's content, within the same tenant-isolated table. Mitigations are
  the size cap (2.5), the no-logging rule above, and authoring guidance that templates reference
  only the variables the external call genuinely needs. Whether `service_task_dispatches` rows are
  retention-purged is not specified in the code read here; recorded as open question OQ-1
  (non-blocking, no behaviour depends on it).
- `rendered_body` must never be added to any API response or audit payload. The existing
  `SERVICE_TASK_COMPLETED` event records the RESPONSE body only and is unchanged.

## 3. Fixture

### 3.1 Instance variables that really exist

Instance start input for this process (scenario step 1): `review_id`, `review_type`,
`portfolio_ref`, `review_period`, `initiator_actor_id`. `review_id` is already relied on by four
other nodes of this fixture (`evidence-collection-timeout`, `cro-sign-off-timeout`,
`archive-review`, `reopen-review` endpoints) and by `regulatory_review_timer_path_test.exs:79`.
It is present in the instance variables on BOTH inbound GRAPH paths (timer path and the
remediation path, since the remediation sub-process merge only adds variables to the parent's
seed variables). Whether a SERVICE_TASK reached via the remediation path is actually dispatched
is a separate, pre-existing question answered "no" in section 3.6. Neither `remediation_status` nor any reason variable exists on
the timer path, and there is no set-variable node type (`graph.ex` node types: START, END,
HUMAN_TASK, SERVICE_TASK, EXCLUSIVE_GATEWAY, PARALLEL_GATEWAY, TIMER, SUB_PROCESS), so the reason
must be a literal per node; hence the split.

### 3.2 The split (no engine node-type change)

`test/fixtures/qa/meridian_regulatory_compliance_review_process_definition.json`:

1. `version`: `"1.2"` to `"1.3"` (the seed script only replaces an ACTIVE definition when the
   fixture version is strictly newer, `scripts/seed_meridian_definition.sh` header; a 409 on
   create means (name, version) exists, so a bump is mandatory).
2. Node `regulatory-auto-escalation` (id KEPT, timer path; EO-001 names this node): add attribute
   `body_template` with the JSON text `{"reason":"sla_breach_30_days","review_id":"{{variables.review_id}}"}`
   (in the JSON file this is one escaped string). `endpoint`, `method`, `timeout_ms` unchanged.
   Inbound edges: `timeout-risk-evaluation` ONLY.
3. NEW node `regulatory-remediation-escalation`, `node_type` `SERVICE_TASK`, attributes:
   `endpoint` the same `https://httpbin.org/anything/compliance/regulatory-notice`, `method`
   `POST`, `timeout_ms` `300000`, `body_template`
   `{"reason":"remediation_unresolved","review_id":"{{variables.review_id}}"}`. Same endpoint on
   purpose: it is the same regulatory notice API, only the reason differs. The wording
   `remediation_unresolved` follows the edge's own condition `variables.remediation_status ==
   'unresolved'`; the BA scenario defines no wording for this path (it only covers the 21-day
   path), recorded as OQ-2 for BA confirmation (non-blocking: it is a string constant).
4. Edge `e10`: `target` changes from `regulatory-auto-escalation` to
   `regulatory-remediation-escalation`; `source` and `condition` unchanged.
5. NEW edge `e18`: `source` `regulatory-remediation-escalation`, `target` `end-closed`, no
   condition (`e18` is unused: existing ids are `e0` to `e17`). `e5` unchanged
   (`regulatory-auto-escalation` to `end-closed`).
6. Fixture `description` text: replace the sentence implying one shared node; state that the
   21-day path and the unresolved-remediation path file separate notices with distinct reasons.
   T2 only forbids the phrase "timer boundary event", so keep that phrase out.

Graph validation: the new node has an `endpoint` (CHK-10), a default `timeout_ms` is valid
(CHK-11), has one inbound and one outbound edge, is reachable from `start` via
`post-remediation-check`, and reaches the END node `end-closed`. The e10 edge keeps its
`variables.remediation_status == 'unresolved'` condition on an `EXCLUSIVE_GATEWAY` source
(`post-remediation-check`), so the gateway edge-condition checks are unaffected. No node-type
change. `end-closed` gains a third inbound edge, which END nodes allow (it already has `e5` and
`e16`). Verified by the existing T3 (`validate_graph`, `validate_node_attributes`,
`validate_edge_conditions` all clean), which the implementer must run.

Scope of the split, stated plainly: it is a graph-level and fixture-level correctness
measure. It guarantees that no static `sla_breach_30_days` reason is ever attached to a node
reachable from `e10`. It does NOT make the e10 notice get sent: see 3.6.

### 3.3 Files that reference the fixture shape and what each needs

| File | Reference | Change needed |
|---|---|---|
| `test/fixtures/qa/meridian_regulatory_compliance_review_process_definition.json` | the artifact | per 3.2 |
| `test/fixtures/simulation/meridian/process_policy_binding.yaml` | nodes (~line 33-75) and edges (~92-113); its own `version: "1.0"` field is a separate version | add node `regulatory-remediation-escalation` (endpoint `POST /compliance/regulatory-notice`, `timeout_ms: 300000`, matching the file's existing endpoint style), add edge `e18`, retarget `e10`. T12 compares node-id and edge-id sets and the `e3`/`timeout-risk-evaluation`/`risk-evaluation` attributes; the YAML does not carry `body_template` today, and T12 does not compare it, so do not add it (its endpoint strings are descriptive, not rendered) |
| `test/letflow/scripts/regulatory_review_timer_path_fixture_test.exs` | `check_t1` (`:119`, version `"1.2"`), `check_t8` (`:174-185`, inbound `["e10", "timeout-risk-evaluation"]`, no `body_template`), test titles `:239`/`:267`, M9 (`:371-376`), `check_t9` | T1: expect `"1.3"` and retitle. T8: rewrite to the new contract (section 6.3). M9: the mutant "literal body_template added turns T8 red" no longer holds; replace with the new mutants in 6.3. T9 (`token_node(... :escalation_timer_fired ...)` lands on `regulatory-auto-escalation`) stays valid unchanged. T12 passes once the YAML matches. Header text "T1-T12 / M1-M10" counts update |
| `test/letflow/engine/regulatory_review_timer_path_test.exs` | `:66` loads `doc["version"]` (dynamic, no literal), `:79` supplies `review_id` (required: without it the new strict missing-variable rule would fail activation), `:156-180` node ids on the timer path | No literal change needed for the version. The E1 service-task stub path now activates with a rendered body; verify it still reaches COMPLETED. Add the assertion in 6.2 that the dispatch row's `rendered_body` equals the expected literal for the timer path |
| `test/specs/ISS-0932.md` | prose spec of T8/M9 and "1.2" | amend to the 1.3 contract (DOC-UPDATER/TEST-DESIGNER) |
| `scripts/seed_meridian_definition.sh` | header line 6 `v1.2` | change to `v1.3` |
| `test/fixtures/uat/process-definition-aliases/proc-meridian-regulatory-compliance-review.yaml` | maps the scenario process id to the fixture path and definition name | no change (no version or node ids in it) |
| `test/scripts/persona_actor_seed_drift_test.exs` | `:20` lists the fixture path to compare `role-*` names | no change (the new node is not a HUMAN_TASK; no new role) |
| `test/letflow/scripts/qa_fixture_service_task_endpoints_test.exs` | iterates every SERVICE_TASK node: https scheme, host, `UrlValidator`, placeholder syntax of `endpoint` | no code change; the new node must satisfy it (it does: same URL as the existing node). It never counts nodes (`grep` found no count assertion) |
| `lib/letflow/design/q915-regulatory-review-21day-timer-path.md` section 4 (and `iss0930-seed-service-task-endpoints.md` lines 110-113 endpoint list) | records "do NOT add body_template" and the 6-node list | add a superseding note pointing to this design (DOC-UPDATER) |
| `docs/issues/ISS-0926.yaml` | description says "body_template is not sent" | correct to "sent raw, unrendered" and set status on completion (DOC-UPDATER) |
| `test/fixtures/uat/scenarios/meridian/regulatory-compliance-review-bafin.yaml` | ported byte-identical scenario, EO-001/EO-002/EO-003 | do NOT edit (header forbids it); EO-001 (node name `regulatory-auto-escalation`) and EO-003 (`end-closed`) stay valid because the timer-path node id and terminal are unchanged. See 3.5 for EO-002 |
| `test/fixtures/simulation/meridian/scenarios/regulatory-compliance-review-bafin.yaml`, `test/letflow/simulation/req208_meridian_test.exs`, `req208-meridian-scenario-execution.md` | mention `regulatory-auto-escalation` only as a kept-unreached node of a simplified in-test graph | no change (`@simple_regulatory_review_graph` is a separate in-test graph, not this fixture) |
| `docs/requirements.yaml` | matched the grep for the fixture name | no change |
| Operations: QA re-seed | the live QA deployment | needs a re-seed of v1.3 (ops step, same as the ISS-0932 v1.2 note) |

### 3.4 Remaining scenario consistency

UAT scenario steps 1-3 reference only `risk-evaluation` (advance-timer node) and instance
inputs, not the changed node ids. `scripts/` seeds read the fixture file generically through
`scripts/lib/seed_service_task_base.sh` (no per-node-id logic found for this definition).

### 3.5 What EO-002 can observe, and whether this fix satisfies it

EO-002: verification method `audit_event`, detail "audit event for POST /compliance/regulatory-notice
with payload containing reason 'sla_breach_30_days' for review sim-meridian-review-001".

What exists after this fix:

- The engine records NO event of the outbound request: not the method, path, or request body.
  The only SERVICE_TASK event is `SERVICE_TASK_COMPLETED` with payload
  `{dispatch_id, node_id, decoded_body}` where `decoded_body` is the RESPONSE
  (`engine.ex:3446-3470`).
- The Meridian QA endpoints are `https://httpbin.org/anything/...`, which echoes the request:
  its JSON response contains `"json": {...parsed request body...}` (the dispatcher sends
  `content-type: application/json` whenever a template exists) and `"data"` (raw body string).
  So after the fix, `SERVICE_TASK_COMPLETED.payload.decoded_body.json.reason` equals
  `"sla_breach_30_days"` for the timer path, and the same data is merged into the instance
  variables by the existing variable merge. This is an observable, assertable trace, but it
  depends on the echo behaviour of the QA endpoint, not on an engine guarantee.
- The frozen `config_snapshot["rendered_body"]` of the dispatch row also holds the exact bytes
  sent (DB-observable, not an API/audit event).

Conclusion: the fix makes the reason value present and observable, but it cannot make EO-002
satisfiable AS WRITTEN ("audit event for POST /compliance/regulatory-notice"), because no audit
event for an outbound call exists. Residual gap, with follow-up recommendations (do NOT expand
this fix to build outbound-request auditing):

1. ORCH files a new issue: "Engine does not audit outbound SERVICE_TASK requests (method, host/path,
   body digest); UAT EO-002 `audit_event` verification cannot be literal". Any future outbound
   audit must record a body digest or a redacted/size-bounded body, never raw variable-derived
   text beyond what INV-2 allows; that design is its own work.
2. BA-MERIDIAN (owner of the scenario's sign-off) may amend EO-002's verification detail to read
   `SERVICE_TASK_COMPLETED` for node `regulatory-auto-escalation` and assert
   `decoded_body.json.reason`. Until then UAT-RUNNER should expect EO-002 to stay open or be
   judged on that event. The ported scenario file itself must not be edited here.

### 3.6 Known pre-existing gap, OUT OF SCOPE: no SERVICE_TASK dispatch after sub-process completion

Verified by reading `lib/letflow/engine/sub_process.ex`: after a child sub-process completes,
`build_completion_multi_from_merge` (`:867-912`) calls `Engine.advance_until_stable/4`
(`:877`) and matches `{:ok, final_instance_state, _more_pending}` at `:894`: the
pending-event list is bound to `_more_pending` and discarded, and only `final_instance_state`
is passed to `build_completion_write_steps/12` (`:949`). A grep of `sub_process.ex` for
`prepare_service_task_dispatch` / `service_task_dispatch` finds nothing. The engine's only
callers of `prepare_service_task_dispatch/6` are the create fold (`engine.ex:605`), the
timer/outcome wrapper (`:3082`) and the task-completion hop (`:3847`); none runs for the
sub-process completion hop. Consequence: a token that reaches a SERVICE_TASK through
`remediation-subprocess` -> `post-remediation-check` -> `e10` ->
`regulatory-remediation-escalation` is moved onto that node but NO `service_task_dispatches`
row is created, so no request (and no notice) is sent today, with or without this fix. The
same pre-existing defect applies to any SERVICE_TASK placed after a SUB_PROCESS in any
definition; it is not specific to the Meridian fixture.

Decision: this is a separate defect, NOT fixed or worked around by ISS-0926, and this design
does not pretend to fix it. Follow-up for ORCH to file as a new issue: "SubProcess completion
hop discards pending events from advance_until_stable, so SERVICE_TASK (and any other
pending-event consumer) reached after a sub-process completes is never dispatched".
Consequences for this design:

- No claim anywhere in this design, its tests or its fixture notes says the remediation-path
  notice is delivered. The e10 fixture work (3.2 items 3-5) is graph-routing and fixture
  shape only.
- The T14 test (6.3) asserts graph routing only and is labelled so.
- The body-rendering fix itself (sections 1, 2) is fully exercised on the paths that DO
  dispatch: create, task-completion hop, and timer/outcome advance (the 21-day timer path
  through `regulatory-auto-escalation`, which is what EO-001/EO-002 observe).
- When the follow-up issue is fixed, the already-split node will start dispatching with its own
  `remediation_unresolved` reason and needs no further fixture change.

## 4. Public surface

No migration (`config_snapshot` is an existing `:map` column; a new string key is schemaless,
evidence in section 0). No supervision-tree or child-spec change. No router, OpenAPI, or
frontend change. Classification: MINOR (new internal capability, additive snapshot key, new
internal error types, no behaviour change for templates without placeholders).

New / changed functions:

| Module | Function | Visibility | Spec |
|---|---|---|---|
| `Letflow.Engine.ServiceTask` | `render_body_template/2` | public, pure, no DB/Logger/clock | `@spec render_body_template(template :: String.t() \| nil, variables :: map()) :: {:ok, String.t() \| nil} \| {:error, body_render_reason()}` |
| `Letflow.Engine.ServiceTask` | `body_has_placeholders?/1` | public, pure | `@spec body_has_placeholders?(template :: String.t() \| nil) :: boolean()` (same regex as 1.2) |
| `Letflow.Engine.ServiceTask` | `body_render_reason_class/1` | public, pure | `@spec body_render_reason_class(body_render_reason()) :: body_render_reason_class()` (section 2.6; sole caller `Engine.prepare_service_task_dispatch/6`) |
| `Letflow.Engine.ServiceTask` | `build_body_render_error_attrs/1` | public, pure | `@spec build_body_render_error_attrs(body_render_error_context()) :: Letflow.Engine.standalone_error_attrs()` |
| `Letflow.Engine.ServiceTask` | `stringify_value/1`, `escape_json_string/1`, placeholder-position scan (2.4) | private `defp` | return `{:ok, String.t()} \| {:error, body_render_reason()}` (scan returns `:ok` or `{:error, :placeholder_outside_string}`) |
| `Letflow.Engine.ServiceTask` | `@type body_render_reason`, `@type body_render_reason_class`, `@type body_render_error_context` (`instance_id`, `node_id`, `actor_id`, `idempotency_key`, `variables`, `reason`; same shape as `catalog_unresolved_context`) | types | section 2.6 |
| `Letflow.Engine.ServiceTask` | `@max_rendered_body_bytes 65_536` | module attribute | not configurable |
| `Letflow.Engine` | `finish_service_task_arm_attrs/7` (was /6) | private | section 1.6 |
| `Letflow.Engine` | `config_snapshot_map/4` (was /3) | private | section 1.6 |
| `Letflow.Engine` | `resolve_service_task_arm_attrs/6`, `prepare_service_task_dispatch/6`, `prepare_service_task_dispatch_for_create/6`, `prepare_service_task_dispatch_for_completion/8`, `prepare_service_task_dispatch_abort_on_empty_url/6` | private | return types widened by the `body_render_error` outcome (section 1.7); a new private `build_service_task_body_render_error/6` thin wrapper beside `build_service_task_catalog_unresolved_error/6` |
| `Letflow.Engine.ServiceTaskDispatcher` | `resolve_dispatch_body/1` | private | section 1.4 |
| `Letflow.Engine.ServiceTaskDispatcher` | `do_attempt_dispatch/2` | private, edited at the two `rendered_body =` lines | no spec change |
| `Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch` | `@type config_snapshot` | type | NO type change. The existing type (`service_task_dispatcher.ex:163-165`, `%{required(String.t()) => String.t() \| non_neg_integer() \| map() \| nil}`) already admits a `"rendered_body"` key with a `String.t() \| nil` value |

`transport_fun` type and `http_transport/3` signatures are unchanged (they already take
`rendered_body :: String.t() | nil`).

Downstream doc edits (for ELIXIR-DEV / DOC-UPDATER, not done here): `service_task_dispatcher.md:299`
snapshot type, `service_task.md:421` ("rendering is out of scope"), `engine.ex:1138-1147` comment,
`req215-service-task-engine-wiring.md` OQ2 resolved pointer.

## 5. Decision-record consistency

`grep -il` over `docs/migration/decisions/` for SERVICE_TASK, SSRF, secrets, templating: 0022,
0027, 0029, 0030 mention SERVICE_TASK/SSRF and 0016 covers secret storage; none settles body
rendering or escaping. 0019 (typed business-object templates) is unrelated to HTTP body
templating. Confirmed: only design docs touched it, all as deferrals
(`req215-service-task-engine-wiring.md` Open Question 2 at lines 1063-1070,
`service_task.md:421`, `q915-regulatory-review-21day-timer-path.md` section 4). Nothing is
re-decided: 0027's SSRF/catalog install policy is untouched, the SSRF gate (`UrlValidator` at
dispatch) is unchanged, and no secret is read or written (INV-4 intact; catalog
`required_auth != :NONE` still fails closed). No framework or library choice changes (Jason is
already a dependency). **No new decision record is warranted**: this is a module-local rendering
contract resolving a design-doc open question, recorded in this design with REVIEWER and
SECURITY-REVIEWER sign-off in the WF-03 chain. If REVIEWER disagrees about the 64 KiB cap or the
strict missing-variable rule, they are plain constants/branches to adjust, not architectural.

## 6. Test plan (for TEST-DESIGNER)

Existing stub technique: dispatcher tests run `ServiceTaskDispatcher.attempt_dispatch/2` against
a real local listener `WebhookTestServer` (`test/support/webhook_test_server.ex`) with
`Application.put_env(:letflow, :service_task_ssrf_validation_enabled, false)` and
`on_exit` cleanup (`service_task_dispatcher_test.exs:310-337`); the server messages the test
process `{:webhook_test_server_request, %{headers:, body:, method:, path:}}`, so the literal
request body bytes are assertable. Wiring tests build a definition with `Definitions.create/2`
and `Definitions.activate/2` and read the dispatch row.

### 6.1 Unit, pure, `async: true`, NO DB (add to `test/letflow/engine/service_task_test.exs`)

All through `ServiceTask.render_body_template/2`:

| ID | Case | Expected |
|---|---|---|
| T-R1 | `nil` template | `{:ok, nil}` |
| T-R2 | static template, no placeholder (even non-JSON text) | `{:ok, template}` verbatim |
| T-R3 | `{"r":"{{variables.reason}}"}` with plain string | `{:ok, ~s({"r":"..."})}`; result decodes |
| T-R4 | value contains `"`; and the injection `x","admin":true` | placeholder text escaped; decoded map has exactly the intended keys, `"admin"` absent |
| T-R5 | value contains backslash and a trailing backslash | `\\`, decodes back to the original value |
| T-R6 | value contains newline, tab, CR, backspace, form feed, NUL and U+001F | raw output contains the two-character short forms for newline, tab, CR, backspace, form feed, and the six-character uppercase-hex forms for NUL (`\u0000`) and U+001F (`\u001F`); no raw control byte remains; decodes back to the original value |
| T-R7a | value contains U+2028 and U+2029 | raw output contains the six ASCII characters `\u2028` and `\u2029`, and neither raw codepoint; decodes back identically |
| T-R7b | value contains `/` (for example `a/b`) | raw output contains `a/b` unchanged; it contains no backslash immediately before the slash (`:javascript_safe` does NOT escape `/`); decodes back identically |
| T-R7c | value contains DEL (U+007F) | raw output contains the DEL byte unchanged; decodes back identically |
| T-R7d | value contains `<`, `>`, `&` | raw output contains them unchanged |
| T-R7e | value contains emoji and non-Latin text (Cyrillic, CJK) | raw output contains the same UTF-8 bytes unchanged; decodes back identically |
| T-R8 | map and list values | rendered as one string whose content is the compact JSON text; decoded result has a string, not a nested object |
| T-R9 | integer, float, `true`, `false` | `"42"`, `"1.5"`, `"true"`, `"false"` inside the string |
| T-R10 | `nil` value with key present; and key absent | empty string inside the quotes; `{:error, {:missing_variable, "k"}}` |
| T-R11 | placeholder outside quotes: `{"a": {{variables.x}}}`, and bare at top level | `{:error, :placeholder_outside_string}`; value never consulted (use a value that would raise if stringified) |
| T-R12 | escaped quote before placeholder: `"a\"{{variables.x}}"` (placeholder still inside the string) | substituted; and `"a\\"` followed by a placeholder outside the string closes properly and is rejected |
| T-R13 | oversize: a value that pushes the rendered size past 65_536 bytes; and exactly at the limit | `{:error, :rendered_body_too_large}`; at-limit passes |
| T-R14 | key-position placeholder `{"{{variables.k}}":1}` with value `a","b":"c` | stays one key, decoded map has one key whose text is the original value |
| T-R15 | malformed template with a placeholder (unbalanced quote) | `{:error, :rendered_body_not_json}` |
| T-R16 | invalid UTF-8 binary value; unsupported term (tuple) | `{:error, :invalid_utf8}`; `{:error, :unsupported_value_type}`; never raises |
| T-R17 | `body_has_placeholders?/1`: nil, static, `{{variables.x}}`, `{{ variables.x }}`, `{{other}}` | false, false, true, true, false |
| T-R18 | error terms never contain the variable value (assert on `inspect/1` of every error for a secret-looking value) | no substring match |
| T-R19 | `build_body_render_error_attrs/1` for each of the six classes | `error_type: :service_task_body_render_failed`, `details == %{reason: class}`, and `reason` equals the exact sentence in the 2.6 table; no value in `reason` text |
| T-R20 | `body_render_reason_class/1` | each bare atom maps to itself; `{:missing_variable, "k"}` maps to `:missing_variable` |
| T-R21 | placeholder scan edge cases: backslash outside a string before a placeholder; a template with two placeholders, first inside and second outside a string; nested JSON (`{"a":{"b":["{{variables.x}}"]}}`) | backslash outside string ignored by the scan (the 2.5 decode check decides); the second placeholder yields `:placeholder_outside_string` with NO value lookup for the first (use a value that raises if stringified); nested placeholder is inside a string and substitutes |

### 6.2 Integration (need Postgres; may be unrunnable on the shared dev machine, so state it)

DB-backed: all below. Add to `test/letflow/engine/service_task_wiring_test.exs` and
`service_task_dispatcher_test.exs`.

| ID | Case | Expected |
|---|---|---|
| I-1 (REGRESSION, fails pre-fix) | `create/2` with an inline SERVICE_TASK `body_template` `{"reason":"x","id":"{{variables.review_id}}"}` and `initial_variables` containing `review_id` | the inserted dispatch row's `config_snapshot["rendered_body"]` equals the rendered JSON; pre-fix the key is absent and `body_template` holds the raw text |
| I-2 | dispatcher with the snapshot from I-1 against `WebhookTestServer` (SSRF gate disabled) | the server receives the RENDERED body bytes and `content-type: application/json`; never the `{{variables...` text. Fails pre-fix |
| I-3 | catalog SERVICE_TASK node with a `body_template` (reuse the `engine_catalog_service_task_test.exs` harness) | `rendered_body` rendered in the snapshot; dispatcher sends it |
| I-4 | injection end to end: variable value `x","admin":true` | server-received body decodes to exactly the template's keys |
| I-5 | `body_template: nil` | `rendered_body` key present and `nil`; server receives an empty body; no content-type |
| I-6 | `{:missing_variable}` on `create/2` | `{:error, {:activation_failed, {:service_task_body_render_failed, node_id, :missing_variable}}}`, zero projection/event rows |
| I-7 | `{:missing_variable}` on a completion hop | instance ERROR, `error_type` `service_task_body_render_failed`, no dispatch row, `details.reason == :missing_variable`, no variable value in the persisted error |
| I-8 | non-hop site (timer-fire or service-outcome advance, at minimum one) | typed `{:error, {:service_task_body_render_failed_not_supported_for_timer_fire, node_id, class}}`, no raise, no row |
| I-9 | legacy snapshot, no `rendered_body` key, `body_template` static | server receives the static template (backward compatible) |
| I-10 | legacy snapshot, no `rendered_body` key, `body_template` with a placeholder | zero requests reach the server; row gives up with `request_build_error`. Mutant: dispatching the raw template turns this red |
| I-11 | retry resends the identical frozen body | two attempts (first refused/5xx class per existing helpers), identical body |
| I-12 | update `engine_catalog_service_task_test.exs:307` `@inline_keys` to include `rendered_body` |  existing key-set assertions stay green |
| I-13 | existing nil-body tests: `service_task_dispatcher_test.exs:88`, `service_task_wiring_test.exs:625` | unchanged and green (they only use `nil`) |

### 6.3 Fixture tests (pure, no DB; `regulatory_review_timer_path_fixture_test.exs`)

- T1 version `"1.3"`.
- T8 (rewritten): `regulatory-auto-escalation` inbound exactly `["timeout-risk-evaluation"]`, outbound `[{"e5","end-closed"}]`, `body_template` decodes to a map whose `reason` is `"sla_breach_30_days"` and whose `review_id` is the placeholder `{{variables.review_id}}`; `regulatory-remediation-escalation` exists, is SERVICE_TASK, inbound exactly `["e10"]`, outbound `[{"e18","end-closed"}]`, template reason `"remediation_unresolved"`, same endpoint URL as the timer-path node.
- New T13: both templates pass `ServiceTask.render_body_template/2` with `%{"review_id" => "r-1"}` and decode to the expected maps (proves the shipped templates are renderable, quotes balanced, placeholders inside strings).
- T9 unchanged (timer fire lands on `regulatory-auto-escalation`). New T14 (GRAPH-ROUTING / FIXTURE-SHAPE ONLY; it does NOT prove the remediation notice is dispatched, which it is not today, see 3.6). Pure, no DB, uses only `Transition.transition/3` and the already-imported `InstanceState` / `Token` structs. The existing `token_node/3` cannot be reused because it hard-codes start node `"risk-evaluation"` and a token without `waiting_child_instance_id`; add ONE new private helper to the test module:

  `@spec remediation_exit_nodes(doc :: map(), variables :: map()) :: {:ok, after_subprocess :: [String.t()], after_gateway :: [String.t()]} | {:error, term()}`

  Specification of the helper (no body here): build an `InstanceState` with `instance_id: "inst-q926"`, `status: :active`, `variables: variables`, `pending_task_nodes: []`, and exactly one token `%Token{node_id: "remediation-subprocess", token_id: "tok-1", waiting_child_instance_id: "child-1"}` (the `waiting_child_instance_id` MUST be non-nil, otherwise `dispatch_sub_process_completion/4` returns `{:token_not_waiting_on_child, ...}`, `transition.ex:623`). Step 1: `Transition.transition(graph!(doc), state, {:sub_process_completed, "tok-1"})` must return `{:ok, s1, _}`; `after_subprocess` is the list of `node_id`s of `s1.tokens`. Step 2: `Transition.transition(graph!(doc), s1, {:advance_token, "tok-1"})` (a token parked on an EXCLUSIVE_GATEWAY is moved off it by `:advance_token`, the same event the engine's `advance_until_stable` uses) must return `{:ok, s2, _}`; `after_gateway` is the list of `node_id`s of `s2.tokens`. Any non-`{:ok, ...}` result is returned as `{:error, result}`.

  Assertions: with `variables = %{"remediation_status" => "unresolved", "review_id" => "r-1"}` the result is `{:ok, ["post-remediation-check"], ["regulatory-remediation-escalation"]}`; with `remediation_status == "resolved"` it is `{:ok, ["post-remediation-check"], ["findings-sign-off"]}` (guards that the `e9` branch is untouched). Expected values are read-only facts of the fixture graph: `e8` goes from `remediation-subprocess` to `post-remediation-check`, `e10` carries `variables.remediation_status == 'unresolved'`, `e9` carries `== 'resolved'`. If ELIXIR-DEV or TEST-DESIGNER finds step 2 does not land as stated (for example a token id change), the sole fallback allowed is to read the token id from `s1.tokens` instead of hard-coding `"tok-1"`, not to weaken the assertion.
- T3 (validation clean), T7, T12 (JSON/YAML parity: node ids, edge ids) must pass with the new node and edge in BOTH files.
- Replace M9 with: M9a "body_template removed from `regulatory-auto-escalation` -> T8 red"; M9b "reason on the remediation node changed to `sla_breach_30_days` -> T8 red" (the exact defect: a wrong reason on a regulatory filing); M9c "e10 retargeted back to `regulatory-auto-escalation` -> T8, T14 red". The existing mutant M10 (`test ... "M10 JSON new but YAML reverted to the old shape -> T12 red"`) is RETAINED and adapted to the new node and edge ids; no duplicate mutant is added.
- Engine E1 (DB, existing): add an assertion that the dispatch row for the timer path has `config_snapshot["rendered_body"]` decoding to `reason == "sla_breach_30_days"` and `review_id == "sim-q915-001"`.

### 6.4 Regression test that fails pre-fix

I-1 and I-2 (and T-R3, which cannot compile-fail but fails because `render_body_template/2`
does not exist; the pure fixture-contract test T8 also fails pre-fix since the template and
node are absent). Mutation checks TEST-DESIGNER should perform on a throwaway worktree (never a
shared tree, per the project's recorded mutation-testing hazard; commit first): (a) drop the
per-value escaping (T-R4, I-4 red); (b) skip the outside-string check (T-R11 red); (c) dispatcher
reads `body_template` again (I-2 red); (d) legacy fallback sends the raw templated body (I-10
red); (e) lenient missing variable (T-R10, I-6 red).

### 6.5 Which tests need the DB

Pure and runnable without Postgres: all of 6.1, all of 6.3 except the E1 addition.
Need Postgres: 6.2 in full and the E1 addition. On this shared machine, Postgres was
unreachable during diagnosis; TEST-RUNNER must say explicitly if the DB tests could not run and
not claim them green.

## 7. Acceptance-criteria map

| Handoff criterion | Where satisfied |
|---|---|
| Design doc exists at the required path | this file |
| Rendering location, frozen snapshot, dispatcher change, catalog path, legacy rows | 1.1, 1.4, 1.5, 1.6 |
| Injection and escaping rules concrete and testable | section 2, tests T-R1 to T-R21 (T-R6, T-R7a to T-R7e pin each Jason guarantee), I-4 |
| Fixture split with version bump and full list of affected files and tests | 3.2, 3.3, 6.3 (T14 graph-routing only) |
| Remediation-path dispatch gap stated and scoped out | 3.6 |
| EO-002 observability gap stated with follow-up recommendation | 3.5 |
| `@spec`s and visibility listed, no implementation code | section 4 |
| Decision-record consistency | section 5 |
| Test plan and `owned_modules` | section 6, section 8 |

## 8. owned_modules for this run

ELIXIR-DEV: `lib/letflow/engine/service_task.ex`, `lib/letflow/engine.ex`,
`lib/letflow/engine/service_task_dispatcher.ex`,
`test/fixtures/qa/meridian_regulatory_compliance_review_process_definition.json`,
`test/fixtures/simulation/meridian/process_policy_binding.yaml`,
`scripts/seed_meridian_definition.sh` (header only).

TEST-DESIGNER: `test/letflow/engine/service_task_test.exs`,
`test/letflow/engine/service_task_wiring_test.exs`,
`test/letflow/engine/service_task_dispatcher_test.exs`,
`test/letflow/engine_catalog_service_task_test.exs`,
`test/letflow/scripts/regulatory_review_timer_path_fixture_test.exs`,
`test/letflow/engine/regulatory_review_timer_path_test.exs`, `test/specs/ISS-0926.md` (new).

DOC-UPDATER: `docs/issues/ISS-0926.yaml`, `lib/letflow/design/service_task_dispatcher.md`,
`lib/letflow/design/service_task.md`, `lib/letflow/design/q915-regulatory-review-21day-timer-path.md`
(superseding note), `lib/letflow/design/iss0930-seed-service-task-endpoints.md` (endpoint list),
`test/specs/ISS-0932.md`.

No migration files, no `application.ex`/supervisor files, no router, no `web/`.

## 9. Open questions (non-blocking; none gates the build)

- OQ-1: Is `service_task_dispatches` retention-purged? `rendered_body` (like `rendered_url`)
  persists in the tenant schema for as long as the row does. No behaviour in this design depends
  on the answer; if rows are kept indefinitely, a retention policy is a separate issue.
- OQ-2: BA-MERIDIAN to confirm the wording `remediation_unresolved` for the second notice
  reason (the ported scenario defines only `sla_breach_30_days`). It is a string constant in the
  fixture and in tests T8/T13.
- OQ-3: A graph-time check (CHK in `validate_node_attributes/1`) that flags a placeholder outside
  a JSON string at definition-create time would shift this failure left. Deliberately NOT in this
  change (scope); recommended as a follow-up issue so authors learn at publish time instead of at
  activation.
