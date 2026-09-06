PROVENANCE (historical, not current decision authority):

# Design: REQ-056 — Service task configuration, retry classification and dispatch contract (`service_task.zig`, EXT-01)

**Requirement:** REQ-056 (`docs/requirements.yaml`, stage S3, `depends_on: [REQ-061, REQ-049, REQ-029, REQ-031]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ056-20260819`, WF-02 Step 1
**This document produces:** module/function signatures, data-structure shapes, the
injectable-transport/catalog contracts, the failure-classification/backoff/retry algorithm
(as tables and pseudocode, not code), and the required moduledoc text — **no implementation
code**. No function bodies, no `.ex` files.

---

## 0. Sources read for this design

**Letflow project docs:**
- `docs/agents/instructions/core-directives.md`, `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1.
- `docs/guides/backend_developer_guide.md` §3.1 (naming), §3.5 (error shapes), §3.6 (SQL — not
  applicable, this module is pure).
- `docs/migration/stage-3-instance-engine.md` — confirms REQ-056's own scope boundary
  paragraph ("the real outbound HTTP transport for SERVICE_TASK dispatch (REQ-056 leaves it
  injectable)") and that `src/dlq/` (OBS-05) and `service_catalog`/PLC-01 are both out of
  scope for this stage, matching this requirement's own SCOPE BOUNDARY paragraph verbatim.
- `docs/anti-patterns.md` — no entry directly applicable to this module's own construction.

**Letflow shipped code, read directly:**
- `lib/letflow/engine/execution_error.ex` (full file) — `ExecutionError.error_type()` already
  includes `:service_task_retries_exhausted` as one of its five named atoms (line 65), and
  `ExecutionError.error_args()`/`affected()` shapes (lines 62-91) are the exact contract this
  design's give-up path must produce.
- `lib/letflow/engine.ex` lines 1839-1972 — `Letflow.Engine.set_instance_error/2` (REQ-061,
  already shipped): `standalone_error_attrs()` (lines 1850-1859), `set_error_opts()`,
  `set_error_result()`, `set_error_error()` (lines 1861-1879). Confirmed this is **the**
  standalone entry point for a caller with no open `Ecto.Multi` of its own — its own comment
  (line 1846) says exactly that: *"set_instance_error/2 is for a caller with no other Multi of
  its own open (design doc §4's own future REQ-056/057/062 callers)"* — this design is one of
  the callers that comment names directly.
- `lib/letflow/engine.ex` lines 1060-1108 — `merge_output_variables/5`, confirming the
  established pattern for routing a REQ-049 (`VariableMerge`) rejection into an
  `ExecutionError.error_args()` tuple rather than raising or writing a bespoke ERROR
  transition — this design's own give-up path follows the same shape.
- `lib/letflow/engine/variable_merge.ex` (full file) — `merge/3`'s `@spec`, `merge_event()`,
  `variable_validations()` — the function REQ-049's own merge is invoked through once a 2xx
  JSON-object body is decoded (AC5).
- `lib/letflow/definitions/service_scope_validator.ex` + its design doc
  `lib/letflow/design/req031-service-scope-validator.md` (both full) — REQ-031's
  struct-of-functions injectable-lookup pattern (`Lookup` nested module,
  `@enforce_keys`/`defstruct`, `build/1` returning a closure) is the direct precedent this
  design reuses for both the transport and catalog-lookup injection points (§3.4-3.5 below),
  per this requirement's own text: *"exactly as REQ-031 did for its own missing
  ServiceCatalog/PluginRegistry gap."*
- `lib/letflow/definitions/graph.ex` — `Graph.Node.t()` (`@enforce_keys [:id, :node_type]`,
  `attributes: map() | nil`, line 79-80); CHK-10 `check_service_task_endpoint/1` (line
  693-706) already requires a SERVICE_TASK node's `"endpoint"` attribute non-blank
  **unconditionally**, and CHK-11 `check_service_task_timeout/1` (line 708+) already requires
  `"timeout_ms"`, when present, to be an integer in `[1, 300_000]` (REQ-029). Neither
  `"service_id"` nor a `"route_kind"`/`"url_template"` key is read anywhere in `graph.ex`
  (grep confirmed no match) — see §9 OQ-1 for the naming reconciliation this forces.
- `lib/letflow/event_store.ex` lines 100-260 — `idempotency_key` is required, non-nil,
  `<= 255` chars, and enforced unique **per tenant schema** via a DB constraint
  (`conflict_target: :idempotency_key`) with duplicate-detection returning the original event
  — confirms `build_idempotency_key/N`'s job is to produce a value stable across redeliveries
  of the *same* attempt and distinct across *different* attempts (§3.6).

PROVENANCE (historical, not current decision authority):
**R-Co source of truth:** the R-Co tree at `c:\Users\tvolo\dev\ai-dala\R-Co` is reachable, but
this design was not built by reading `service_task.zig` directly — it is a reasoned
reconstruction from the requirement text's own description/acceptance criteria and the
shipped-Letflow precedents above (the same "not verified against a second, independent read
of R-Co" posture `Letflow.Engine.ExecutionError`'s own moduledoc states for its EE-10 port,
§12 OQ-1 of its design doc). Every place this matters for a concrete design choice is flagged
as an explicit open question in §9, not silently guessed; two of those (OQ-1, OQ-5) are filed
as their own tracked issues rather than left as a bare caveat (see §9).

---

## 1. Scope boundary

**In scope:** one new module, `Letflow.Engine.ServiceTask` (§2), implementing EXT-01's pure
config-parsing, URL/failure classification, backoff, and retry-decision logic, plus the glue
that hands a give-up decision to REQ-061's already-shipped `Letflow.Engine.set_instance_error/2`.
Every function is pure (no `Letflow.Repo`, no HTTP call, no clock read inside the classification/
backoff/decision functions themselves) — the actual outbound HTTP transport and the
`service_catalog` lookup are both **injectable function values** the caller supplies, per this
requirement's own SCOPE BOUNDARY paragraph (quoted verbatim in §7's required moduledoc text).

**Explicitly NOT built here (AC7):**

PROVENANCE (historical, not current decision authority):

| Not built here | Real dependency | Belongs to |
|---|---|---|
| The actual outbound HTTP client/transport that executes a dispatch | R-Co's `executeHttpRequest()` (`src/engine/service_task.zig`) | Deferred — this module defines the `transport_fun()` contract (§3.4) a future concrete adapter implements; no HTTP library dependency is added to `mix.exs` by this requirement. |
| A dead-letter queue that an exhausted-retry outcome lands in for operator retry/discard | OBS-05 (`src/dlq/`) | **S6** (operational cross-cutting) — not yet ported. This module's only contribution is handing the exhausted-retry outcome to `Letflow.Engine.set_instance_error/2` (§6), which is REQ-061's already-shipped path into `instance_projections.status = :error` — the same durable record OBS-05's future dead-letter listing will query. No partial DLQ (no retry-queue table, no discard endpoint, no background sweep) is introduced here. |
| A real, DB-backed service registry resolving `service_id` -> URL template for `route_kind: :catalog_service` | `service_catalog` (`src/repository/service_catalog.zig`) | **S6** — the same gap REQ-031's moduledoc already flagged for its own `ServiceCatalog` dependency. This module defines the `catalog_lookup_fun()` contract (§3.5) only. |
| Any HTTP/Plug route layer, any dispatch-loop orchestration process (a `gen_statem`/`Task` that actually sleeps for backoff and calls the transport in a loop) | S4 (routes) / a future requirement | Not in scope — `docs/migration/stage-3-instance-engine.md`'s own scope boundary places HTTP routes at S4. This design's `compute_service_task_backoff_ms/3` is deliberately a pure, no-sleep function (AC4) so a future orchestration caller can unit-test its own retry loop's *decisions* without any real waiting; the loop itself is not this requirement's job. |

**DB schema:** none. This module reads an already-in-memory `Graph.Node.t()` (REQ-028/029) and
returns plain structs/tuples — no new `Ecto.Schema`, no migration.

---

## 2. Module and file layout

| Module | File | Kind |
|---|---|---|
| `Letflow.Engine.ServiceTask` | `lib/letflow/engine/service_task.ex` | **New.** Public functions per §4. |
| `Letflow.Engine.ServiceTask.Config` | same file, nested | **New.** Plain struct — parsed SERVICE_TASK dispatch configuration (§3.1). |

Follows the existing `lib/letflow/engine/*.ex` convention (`execution_error.ex`,
`variable_merge.ex`, `task_activation.ex` — one file per EE-\*/EXT-\* behavioral seam, nested
plain structs for a module's own data shapes, mirroring `ServiceScopeValidator`'s
`Lookup`/`Violation` nesting).

---

## 3. Types

### 3.1 `Config` — parsed SERVICE_TASK dispatch configuration

```
defmodule Letflow.Engine.ServiceTask.Config do
  @enforce_keys [:node_id, :route_kind, :method, :timeout_ms, :retry_limit]
  defstruct [
    :node_id,
    :route_kind,
    :url_template,
    :service_id,
    :method,
    :body_template,
    headers: %{},
    timeout_ms: 30_000,
    retry_limit: 3,
    warnings: []
  ]

  @type route_kind :: :inline_url | :catalog_service
  @type http_method :: :GET | :POST | :PUT | :PATCH | :DELETE
  @type warning :: :both_url_and_service_id_provided_url_ignored

  @type t :: %__MODULE__{
    node_id: String.t(),
    route_kind: route_kind(),
    url_template: String.t() | nil,
    service_id: String.t() | nil,
    method: http_method(),
    body_template: String.t() | nil,
    headers: %{optional(String.t()) => String.t()},
    timeout_ms: pos_integer(),
    retry_limit: non_neg_integer(),
    warnings: [warning()]
  }
end
```

- `url_template` is `nil` only when `route_kind == :catalog_service` **and** no URL attribute
  was present at all. When both a URL and `service_id` are present, `url_template` still
  carries the parsed (now-ignored) value for audit/warning detail — dispatch itself must use
  `service_id` via the catalog lookup (§3.5), never `url_template`, whenever
  `route_kind == :catalog_service` (AC1).
- `warnings` is an open list (one atom defined today, `both_url_and_service_id_provided_url_ignored`)
  — a warning, never an error, per AC1's own wording ("a warning, not an error"). Distinguishing
  it from a hard parse failure: `parse_config_from_node_attributes/1` still returns `{:ok,
  config}` when this warning fires, never `{:error, _}`.

### 3.2 Failure kinds

```
@type failure_kind ::
  :timeout
  | :network
  | :http_non_2xx
  | :http_redirect_3xx
  | :rate_limited_429
  | :invalid_2xx_body
  | :request_build_error
```

Closed, 7-member union — matches the requirement text's own enumeration verbatim. No open
`atom()` tail (unlike `ExecutionError.error_type()`) because this set is EXT-01's own fixed
outcome taxonomy, not an extensible cross-module sink.

### 3.3 Raw transport outcome — the input `classify_failure_kind/1` consumes

```
@type raw_outcome ::
  :timeout
  | {:network, reason :: term()}
  | {:request_build_error, reason :: term()}
  | {:http, status :: pos_integer(), body :: String.t() | nil}
```

The shape a `transport_fun()` implementation (§3.4) is expected to return, or that a caller
constructs from whatever a concrete HTTP client raises/returns. `{:http, status, body}` covers
every HTTP-transport-level response (2xx through 5xx) — `body` is the raw response body text
(or `nil` for an empty body), not yet JSON-decoded; decoding happens inside
`classify_failure_kind/1` only for the 2xx case (§4).

### 3.4 Injectable HTTP transport contract

```
@type transport_fun ::
  (Config.t(), rendered_url :: String.t(), rendered_body :: String.t() | nil -> raw_outcome())
```

Not a `@behaviour` — a plain 3-arity function value, matching REQ-031's `Lookup`
struct-of-functions rationale (§0): a caller/test supplies a different transport per call
without `Application.put_env/3` cross-test coupling, and this module needs exactly one
function (unlike REQ-031's two), so a bare function value is simpler than a one-field struct
wrapper. **No concrete implementation of this type exists in this codebase yet** — a future
adapter (HTTP client library choice deferred) supplies it.

### 3.5 Injectable service-catalog lookup contract

```
@type catalog_lookup_fun ::
  (service_id :: String.t(), tenant_id :: Ecto.UUID.t() -> {:ok, url_template :: String.t()} | {:error, :not_registered})
```

Resolves `route_kind: :catalog_service`'s `service_id` to a real URL template. **No concrete
implementation exists in this codebase yet** — belongs to a future S6 `service_catalog`
adapter (§1, §7). This module's own functions never call this type — it is a documented
contract only, for a future dispatch-orchestration caller to invoke before rendering a URL
from `service_id`'s resolved template.

### 3.6 Retry/backoff/idempotency primitives

```
@type attempt_index :: non_neg_integer()   # 0 = first attempt, never retried yet
@type retry_decision :: :retry | :give_up
```

---

## 4. Function signatures

```
@spec parse_config_from_node_attributes(node :: Letflow.Definitions.Graph.Node.t()) ::
  {:ok, Config.t()} | {:error, config_parse_error()}

@type config_parse_error ::
  :missing_node_id
  | :missing_url_and_service_id
  | {:invalid_method, term()}
  | {:invalid_timeout_ms, term()}
  | {:invalid_retry_limit, term()}
```

Builds a `Config.t()` from a SERVICE_TASK `Graph.Node.t()`'s `id` and `attributes` (string-keyed
map, per `graph.ex`'s own convention — §0). Pure, no I/O. Field derivation (§5's table) —
`timeout_ms` defaults to `30_000` and `retry_limit` defaults to `3` when the node omits them
(AC1); both, when present, are read but **not re-validated** against REQ-029's `[1, 300_000]`
range here — REQ-029's CHK-11 already gates this at graph-validation time before a definition
can activate (this function's own job is parsing, not re-deriving an already-enforced
invariant; §9 OQ-2 notes the one case where this matters).

```
@spec validate_rendered_url(rendered_url :: String.t() | nil) :: :ok | {:error, :empty_rendered_url}
```

Pure. Trims `rendered_url` (mirrors `graph.ex`'s own blank-string convention, §0) and rejects
`nil` or an all-whitespace/empty result (AC6). Called by a future activation-time caller
**after** template rendering (URL-template variable substitution is not this module's job —
out of scope, §1) and **before** any dispatch attempt.

```
@spec build_empty_url_error_attrs(empty_url_context()) ::
  Letflow.Engine.standalone_error_attrs()

@type empty_url_context :: %{
  required(:instance_id) => Ecto.UUID.t(),
  required(:node_id) => String.t(),
  required(:actor_id) => Ecto.UUID.t() | nil,
  required(:idempotency_key) => String.t(),
  required(:variables) => map(),
  optional(:details) => map()
}
```

Pure. AC6's concrete routing element, built the same way `build_service_task_give_up_error_attrs/1`
(§4 above) builds AC8's — the design does not leave "how does an empty rendered URL reach the
ERROR path" as an open question. `error_type: :service_task_url_rendered_empty` — a new,
concrete member of `ExecutionError.error_type()`'s already-open union (its trailing `atom()`,
§0, makes adding this legal without changing `execution_error.ex` itself); `affected: {:node,
node_id}`; `reason` a fixed string ("service task URL template rendered to an empty string");
`variables`/`details` passed through from the caller unchanged. See §6 for the routing
statement this function's existence backs.

```
@spec classify_failure_kind(raw_outcome()) :: {:success, decoded_body :: map()} | failure_kind()
```

Pure. Maps a `raw_outcome()` to either `{:success, decoded_body}` (a 2xx response whose body
decodes as a JSON *object*, AC5) or one of the 7 `failure_kind()` atoms (§5's classification
table — this is where the 2xx/JSON-object-vs-not decision and the 3xx/429/other-non-2xx
decisions all live, since EXT-01 draws all of them from the same raw HTTP outcome). Never
raises on a JSON-decode failure — a body that fails to decode, or decodes to a non-map (array,
string, number, bool, null), classifies as `:invalid_2xx_body` (AC5), never crashes.

```
@spec is_retriable_failure(failure_kind()) :: boolean()
```

Pure, total function over the closed `failure_kind()` union (§5's table, "Retriable?" column).

```
@spec compute_service_task_backoff_ms(
  attempt_index :: attempt_index(),
  base_ms :: pos_integer(),
  cap_ms :: pos_integer()
) :: non_neg_integer()
```

Pure, deterministic: `min(base_ms * 2^attempt_index, cap_ms)` (§5.2). No jitter (§9 OQ-4). No
sleep, no clock read — AC4's "verified across at least 4 successive attempt indices without
any sleeping" is satisfied by this function's own purity: calling it 4+ times with successive
`attempt_index` values and asserting on the returned integers requires no `Process.sleep/1`
anywhere in a test.

```
@spec decide_failure(
  kind :: failure_kind(),
  attempt_index :: attempt_index(),
  retry_limit :: non_neg_integer()
) :: retry_decision()
```

Pure. `:give_up` immediately if `is_retriable_failure(kind)` is `false` (regardless of
`attempt_index`/`retry_limit`); otherwise `:retry` while `attempt_index < retry_limit`, else
`:give_up` — this is the exact boundary AC3 requires tested at below/equal/above `retry_limit`
(§5.3).

```
@spec build_idempotency_key(
  instance_id :: Ecto.UUID.t(),
  node_id :: String.t(),
  token_id :: Ecto.UUID.t() | String.t(),
  attempt_index :: attempt_index()
) :: String.t()
```

Pure, deterministic: `"service_task:" <> instance_id <> ":" <> node_id <> ":" <> token_id <>
":" <> Integer.to_string(attempt_index)` (§5.4). Two calls with identical arguments produce the
identical key — a redelivery of the *same* attempt collides against `EventStore`'s unique
`idempotency_key` constraint (§0) and is therefore not a duplicate side effect (the
`build_idempotency_key/N` requirement's own stated purpose); two different `attempt_index`
values produce distinct keys, so a genuine retry is not blocked by the same constraint.

```
@spec build_service_task_give_up_error_attrs(service_task_give_up_context()) ::
  Letflow.Engine.standalone_error_attrs()

@type service_task_give_up_context :: %{
  required(:instance_id) => Ecto.UUID.t(),
  required(:node_id) => String.t(),
  required(:actor_id) => Ecto.UUID.t() | nil,
  required(:idempotency_key) => String.t(),
  required(:variables) => map(),
  required(:last_failure_kind) => failure_kind(),
  required(:attempt_index) => attempt_index(),
  required(:retry_limit) => non_neg_integer()
}
```

Pure. **The single routing target for every `decide_failure/3` `:give_up` outcome, regardless
of cause** (renamed and generalized in rework iteration 2 — CODE-DESIGN-VALIDATOR's AC5 FAIL:
the design originally named this function `build_retries_exhausted_error_attrs/1`, whose
name/type implied multi-attempt exhaustion specifically, leaving `:invalid_2xx_body`'s
immediate, first-attempt give-up unrouted, AC5(b)'s own gap. A `:give_up` verdict from
`decide_failure/3` has exactly one meaning downstream — "this dispatch attempt is over,
transition the instance to ERROR" — whether the cause was a non-retriable kind on attempt 0
(`:http_redirect_3xx`, `:invalid_2xx_body`, `:request_build_error`) or a retriable kind whose
`attempt_index` reached `retry_limit` (`:timeout`, `:network`, `:rate_limited_429`); one
function, one shape, no cause-specific branching needed by a caller — a second, near-duplicate
function was considered and rejected for exactly this reason.)

Builds the exact map shape `Letflow.Engine.set_instance_error/2` (REQ-061, already shipped)
requires as its own `attrs` argument (§0): `error_type: :service_task_retries_exhausted` in
every case (already a named member of `ExecutionError.error_type()`, no change needed there —
its own moduledoc, §0, states this one atom maps 1:1 onto REQ-056's entire calling path, not
onto "retry-exhaustion" specifically, so reusing it for every REQ-056-sourced give-up is the
design already on record, not a new choice), `affected: {:node, node_id}`, a `reason` string
that names `last_failure_kind` and states whether the cause was "not retriable" (when
`is_retriable_failure(last_failure_kind) == false`) or "retries exhausted after `retry_limit`
attempts" (when it is) — so the human-readable text still distinguishes the two causes even
though the machine-matchable `error_type` atom does not — `variables` passed through unchanged,
`details: %{last_failure_kind:, attempt_index:, retry_limit:}`. **This module never calls
`ExecutionError.append_multi/3` directly and never writes its own `instance_projections`
update** — a future dispatch-orchestration caller (not built here, §1) is expected to call
`Letflow.Engine.set_instance_error/2` with this function's return value directly, exactly the
calling shape `engine.ex`'s own comment names this requirement for (§0). This is the concrete
design element AC5(b) and AC8 both require "confirmed by inspection" — the inspection target is
this function's `@spec` return type matching `Letflow.Engine.standalone_error_attrs()`
field-for-field, its being the *only* function this module offers for a `:give_up` outcome
(§6), and its moduledoc/§6 stating the routing explicitly.

---

## 5. Algorithms

### 5.1 `parse_config_from_node_attributes/1` — field derivation table

All attribute reads are string-keyed (`Map.get(attributes, "url_template")`, not atom keys —
matches `graph.ex`'s own convention, §0). `attributes` may be `nil` (a node with no attributes
at all) — treated identically to an empty map.

PROVENANCE (historical, not current decision authority):

| Config field | Source attribute key(s) | Default | Notes |
|---|---|---|---|
| `node_id` | `node.id` | — (required) | `{:error, :missing_node_id}` if `node.id` is `nil`/blank (defensive; `Graph.Node.t()`'s own `@enforce_keys` already makes this unreachable in practice — kept as a total-function guard, §9 OQ-2 style reasoning). |
| `service_id` | `"service_id"` | `nil` | Non-empty-string gate (mirrors `ServiceScopeValidator.ref_id/2`, §0) — a missing key, `nil`, non-string, or `""` value is treated as "not provided." |
| `url_template` | `"endpoint"` (see §9 OQ-1, verified 2026-08-20, GH#331 — optional when `service_id` is provided) | `nil` | Same non-empty-string gate. |
| `route_kind` | *derived*, not read directly | — | `:catalog_service` if `service_id` provided (§ above); else `:inline_url` if `url_template` provided; else `{:error, :missing_url_and_service_id}` — neither present is a hard parse failure, not a defaulted/silent case. |
| `warnings` | *derived* | `[]` | `[:both_url_and_service_id_provided_url_ignored]` iff both `service_id` and `url_template` are non-blank (AC1) — `route_kind` still resolves to `:catalog_service` in this case (service_id wins, URL ignored per the requirement text's own wording). |
| `method` | `"method"` | `:POST` (matches R-Co `service_task.zig`'s own unconditional `.POST` default when `"method"` is absent — §9 OQ-5, verified 2026-08-20, GH#330) | Must parse (case-insensitively) to one of `GET/POST/PUT/PATCH/DELETE`; anything else -> `{:error, {:invalid_method, value}}`. |
| `headers` | `"headers"` | `%{}` | Must be a string-keyed map if present; anything else -> treated as `%{}` (defensive, non-fatal — headers are not validated further, no requirement names a header-shape error case). |
| `timeout_ms` | `"timeout_ms"` | `30_000` (AC1) | Read as-is if an integer; non-integer present value -> `{:error, {:invalid_timeout_ms, value}}`. Not re-checked against `[1, 300_000]` (§9 OQ-2). |
| `retry_limit` | `"retry_limit"` | `3` (AC1) | Must be a non-negative integer if present; else `{:error, {:invalid_retry_limit, value}}`. No requirement states an upper bound — none enforced here. |
| `body_template` | `"body_template"` | `nil` | Passed through as-is (rendering is out of scope, §1). |

### 5.2 `classify_failure_kind/1` — classification table

| `raw_outcome()` input | Result | `failure_kind()` |
|---|---|---|
| `:timeout` | failure | `:timeout` |
| `{:network, _reason}` | failure | `:network` |
| `{:request_build_error, _reason}` | failure | `:request_build_error` |
| `{:http, status, body}`, `status in 200..299`, `body` decodes as a JSON **object** | `{:success, decoded_map}` | — |
| `{:http, status, body}`, `status in 200..299`, `body` fails to decode, or decodes to a JSON array/string/number/bool/null | failure | `:invalid_2xx_body` (AC5) |
| `{:http, 429, _body}` | failure | `:rate_limited_429` (checked **before** the generic non-2xx case below — AC2) |
| `{:http, status, _body}`, `status in 300..399` | failure | `:http_redirect_3xx` — **never followed as a redirect** (AC2); this module performs no follow-up HTTP call regardless, since it makes none itself (§1) |
| `{:http, status, _body}`, any other value (1xx, 4xx other than 429, 5xx) | failure | `:http_non_2xx` |

### 5.3 `is_retriable_failure/1` / `decide_failure/3` — retriability table

| `failure_kind()` | Retriable? | Rationale |
|---|---|---|
| `:timeout` | `true` | Transient — the canonical retriable case. |
| `:network` | `true` | Transient (connection refused/reset/DNS, etc.). |
| `:rate_limited_429` | `true` | AC2's explicit edge case — "a failure that DOES retry." |
| `:http_redirect_3xx` | `false` | AC2's explicit edge case — "never followed automatically," and never retried either (retrying an unfollowed redirect would just repeat the same 3xx). |
| `:http_non_2xx` | `false` | Default, conservative reading — a generic 4xx/5xx is treated as non-transient (§9 OQ-6: R-Co source unreachable to confirm whether some 5xx subset is meant to retry; not silently assumed). |
| `:invalid_2xx_body` | `false` | A body-shape/contract problem, not a transient transport failure — retrying would reproduce the same body. |
| `:request_build_error` | `false` | Deterministic given the same config/variables — retrying without a config change cannot succeed. |

`decide_failure(kind, attempt_index, retry_limit)`:
1. `is_retriable_failure(kind) == false` -> `:give_up` (attempt/limit irrelevant).
2. `attempt_index < retry_limit` -> `:retry`.
3. Otherwise (`attempt_index >= retry_limit`) -> `:give_up`.

AC3's below/equal/above boundary: for `retry_limit = N`, `attempt_index = N - 1` ->
`:retry` (below); `attempt_index = N` -> `:give_up` (equal); `attempt_index = N + 1` -> `:give_up`
(above) — all three exercised against a retriable kind (else step 1 shortcuts every case to
`:give_up` regardless of the boundary, which is itself a separate, also-required test per §11).

### 5.4 `build_idempotency_key/4`

`"service_task:" <> instance_id <> ":" <> node_id <> ":" <> to_string(token_id) <> ":" <>
Integer.to_string(attempt_index)`. Deterministic string concatenation only — no hashing, no
clock, no randomness (mirrors `VariableMerge`'s own determinism contract, §0).

---

## 6. ERROR-path routing — closes REQ-061's own AC8 obligation, AC6's empty-URL case, and AC5(b)'s invalid-2xx-body case

Two distinct SERVICE_TASK failure *entry points* route into REQ-061's ERROR path, and **both**
route through the exact same standalone entry point, `Letflow.Engine.set_instance_error/2` —
neither one is a separate ERROR transition written by this module:

1. **Every `decide_failure/3` `:give_up` verdict (AC8's exhausted-retries case, AND AC5(b)'s
   invalid-2xx-body case).** `decide_failure/3` returns `:give_up` for two structurally
   different reasons (§5.3): a *retriable* kind (`:timeout`, `:network`, `:rate_limited_429`)
   whose `attempt_index` reached `retry_limit` — the "exhausted retry" case AC8 names — **or**
   a kind that `is_retriable_failure/1` says is not retriable at all
   (`:http_redirect_3xx`, `:invalid_2xx_body`, `:request_build_error`), which gives up on
   attempt 0 regardless of `retry_limit` — the case that covers AC5(b)'s "2xx JSON array/bare
   string does not merge and routes to REQ-061's ERROR path." Both reasons produce the exact
   same `retry_decision()` value (`:give_up`) and route through the exact same function —
   rework iteration 2 generalized what was previously a retry-exhaustion-only-named function
   into this single sink specifically so a caller never has to branch on *why* `:give_up` was
   returned before routing it (§4's full rationale). This module's contribution stops at
   `build_service_task_give_up_error_attrs/1` (§4) producing the exact
   `Letflow.Engine.standalone_error_attrs()` shape — the future dispatch-orchestration caller
   (not built by this requirement, §1) is required to invoke:

   ```
   Letflow.Engine.set_instance_error(
     ServiceTask.build_service_task_give_up_error_attrs(context),
     prefix: schema_name
   )
   ```

   This is the one call site every `:give_up` verdict reaches — a 2xx JSON-array/bare-string
   body (AC5(b)) is classified `:invalid_2xx_body` by `classify_failure_kind/1` (§5.2 row 4),
   found non-retriable by `is_retriable_failure/1` (§5.3), and `decide_failure/3` returns
   `:give_up` on the very first evaluation (§5.3 step 1) — there is no separate "body shape
   rejected" code path anywhere in this module; it is the same `:give_up` verdict AC8's
   exhausted-retry case produces, built into the same `standalone_error_attrs()` shape, handed
   to the same `set_instance_error/2` call.

2. **Empty rendered URL (AC6).** `validate_rendered_url/1` returning `{:error,
   :empty_rendered_url}` at activation time is the "URL template rendering to an empty string"
   case AC6 names — structurally separate from `decide_failure/3`'s domain, since it fires
   *before* any dispatch attempt exists to classify (§4). This module's contribution stops at
   `build_empty_url_error_attrs/1` (§4) producing the same `Letflow.Engine.standalone_error_attrs()`
   shape — the future activation-time caller is required to invoke it exactly the same way:

   ```
   Letflow.Engine.set_instance_error(
     ServiceTask.build_empty_url_error_attrs(context),
     prefix: schema_name
   )
   ```

Neither entry point calls `Ecto.Multi`/`Repo.update` against `instance_projections` directly,
and neither calls `Letflow.Engine.ExecutionError.append_multi/3` directly (that path is
reserved for a caller that already has its own open `Multi` — REQ-061's own comment, §0 —
which neither a standalone service-task dispatch loop nor an activation-time URL check has).
This is the concrete, inspectable design element AC5(b), AC6, and AC8 all require: no
alternate ERROR-transition code path exists anywhere in this module's own signatures, and
every give-up/rejection-shaped output this module produces is typed exactly as REQ-061's
already-shipped standalone entry point's own input type.

---

## 7. Required moduledoc text (AC7)

Per AC7 ("the moduledoc states explicitly that the HTTP transport and the service_catalog
lookup are injectable interfaces, names OBS-05's DLQ (S6) as the unbuilt destination for
exhausted retries, and confirms no partial DLQ was built here"). ELIXIR-DEV may add
surrounding prose but must not omit the substance of these statements (CODE-DESIGN-VALIDATOR
and REVIEWER can check them literally against the module built):

```
## Scope boundary — injectable transport and catalog lookup, no DLQ built here

The actual outbound HTTP transport is INJECTABLE (`transport_fun/0`, a function value the
caller supplies) -- this module wires no concrete HTTP client. The `service_catalog` lookup
`route_kind: :catalog_service` needs to resolve a `service_id` to a URL template is also
INJECTABLE (`catalog_lookup_fun/0`) -- no concrete, DB-backed catalog exists in this codebase
yet (the same gap `Letflow.Definitions.ServiceScopeValidator`'s own moduledoc names for its
own `ServiceCatalog` dependency).

Every `decide_failure/3` `:give_up` outcome (whether from exhausted retries or an immediately
non-retriable failure) is handed to `Letflow.Engine.set_instance_error/2` (REQ-061) via
`build_service_task_give_up_error_attrs/1` -- it does NOT land in a dead-letter queue here.
R-Co's OBS-05 dead-letter API (`src/dlq/`) is
the eventual operator-facing retry/discard surface for an instance parked in `ERROR`, and it
belongs to stage S6 (operational cross-cutting) -- NOT YET BUILT. No partial DLQ (no
retry-queue table, no discard endpoint, no background sweep of `ERROR`-status instances) is
introduced by this module. `instance_projections.status == :error` plus its `error_detail`
column, already written by `set_instance_error/2`, is the durable record OBS-05's future
dead-letter listing will query -- no additional table is needed for S6 to find every
`ERROR`-halted service-task instance once it exists.
```

---

## 8. Invariants

| id | Invariant | Enforced where |
|---|---|---|
| INV-ST-1 | `parse_config_from_node_attributes/1`, `validate_rendered_url/1`, `classify_failure_kind/1`, `is_retriable_failure/1`, `compute_service_task_backoff_ms/3`, `decide_failure/3`, `build_idempotency_key/4`, `build_service_task_give_up_error_attrs/1`, `build_empty_url_error_attrs/1` are all pure — no `Letflow.Repo`, no `Logger.*`, no HTTP/file call, no clock read except where a caller supplies a value explicitly (none of these functions read a clock internally). | Whole module — mirrors `VariableMerge`'s/`ServiceScopeValidator`'s own "Purity" sections (§0) |
| INV-ST-2 | A 3xx response is never followed automatically and is always classified as a failure, never a success. | §5.2 row 6; §5.3 (`http_redirect_3xx` non-retriable) |
| INV-ST-3 | A 429 response is always classified as `:rate_limited_429` and is always retriable (subject to `retry_limit`). | §5.2 row 5; §5.3 |
| INV-ST-4 | A 2xx response merges into instance variables only when its body decodes as a JSON object; any other 2xx body shape (array, bare string/number/bool/null, or undecodable) is `:invalid_2xx_body`, never merged. | §5.2 rows 3-4 |
| INV-ST-5 | `both_url_and_service_id_provided_url_ignored` is a warning, never an `{:error, _}` return from `parse_config_from_node_attributes/1`. | §3.1, §5.1 |
| INV-ST-6 | `compute_service_task_backoff_ms/3`'s result never exceeds `cap_ms`, and is non-decreasing in `attempt_index` for fixed `base_ms`/`cap_ms`. | §4, §5.2 |
| INV-ST-7 | `decide_failure/3` returns `:give_up` for a non-retriable kind regardless of `attempt_index`/`retry_limit`. | §5.3 step 1 |
| INV-ST-8 | This module never opens an `Ecto.Multi`, never calls `Letflow.Engine.ExecutionError.append_multi/3`, and never updates `instance_projections` itself — every ERROR-transition side effect (both the exhausted-retry case and the empty-rendered-URL case) is delegated to `Letflow.Engine.set_instance_error/2`. | §6 |

---

## 9. Open questions — not silently resolved

PROVENANCE (historical, not current decision authority):
**OQ-1 (MINOR, RESOLVED 2026-08-20, GH#331):** Verified against R-Co source
(`R-Co/src/engine/service_task.zig`, `parseConfigFromNodeAttributes`, lines 84-100): R-Co
treats `"url"`/`"endpoint"` as fully **optional** whenever `"service_id"` is present —
`resolveCatalogEndpoint/3` derives the real URL from the service catalog entry, and
`InvalidConfig` is returned only when **neither** `service_id` **nor** `url`/`endpoint` is
supplied (line ~102). No placeholder `"endpoint"` value is expected or required from a
definition author using `service_id`-only dispatch. This module's own already-shipped
`parse_config_from_node_attributes/1` (`lib/letflow/engine/service_task.ex:191-199`) already
matches R-Co exactly here (`{nil, nil} -> {:error, :missing_url_and_service_id}`, any other
combination succeeds) — so no change was needed in this module.

The still-open problem this verification surfaced is upstream of this module: REQ-029's
already-shipped CHK-10 (`graph.ex`) requires `"endpoint"` unconditionally at graph-validation
time, regardless of `service_id`, contradicting both R-Co and this module's own parse function
— a definition using `route_kind: :catalog_service` (service-id-only, no URL) can never pass
graph validation today and so can never reach `parse_config_from_node_attributes/1` in
production. That is a defect in CHK-10 itself, outside this design's own file scope — filed
separately as ISS-0104/GH#334 rather than fixed here (see `ISSUE_QUEUE.md`'s
incidentally-discovered-defect protocol) so it gets its own reviewed change to `graph.ex` and
its test suite.

**OQ-2 (MINOR):** `parse_config_from_node_attributes/1` does not re-validate `timeout_ms`
against REQ-029's `[1, 300_000]` range (§5.1) — it trusts CHK-11 already ran at graph-validation
time. If this function is ever called against a node that bypassed graph validation (e.g. a
hand-built test fixture, or a future code path that parses config before activation), an
out-of-range `timeout_ms` would pass through uncaught. Flagged, not defended against, since
adding a second range check here would duplicate CHK-11's own already-shipped rule rather than
reuse it, and this requirement's acceptance criteria do not ask for a second enforcement point.

**OQ-3 — RESOLVED (rework iteration 1, CODE-DESIGN-VALIDATOR FAIL on AC6):** originally left
`validate_rendered_url/1`'s ERROR-path routing as a deferred question. Now resolved
concretely: `error_type: :service_task_url_rendered_empty` (a new, legal member of
`ExecutionError.error_type()`'s already-open union, §0) plus `build_empty_url_error_attrs/1`
(§4), routed through `Letflow.Engine.set_instance_error/2` exactly like AC8's exhausted-retry
case — see §6 for the full routing statement and INV-ST-8.

**OQ-4 (MINOR):** `compute_service_task_backoff_ms/3` is deliberately jitter-free (§4) — pure
exponential-with-cap only. Real-world retry storms typically add jitter; whether EXT-01's real
R-Co behavior includes it is unconfirmed (source unreachable, §0). Not added speculatively —
flagged for a future requirement/rework if this proves to matter operationally (this
requirement's own AC4 only asks for deterministic, no-sleep exponential growth with a cap,
which this design satisfies without jitter).

PROVENANCE (historical, not current decision authority):
**OQ-5 (MINOR, RESOLVED 2026-08-20, GH#330):** `method`'s default (`:POST`, §5.1) when a
SERVICE_TASK node's `"method"` attribute is absent has been confirmed against R-Co source
(`R-Co/src/engine/service_task.zig`, the `method` parse block: `break :blk .POST;` when
`obj.get("method")` is absent) — R-Co defaults to `.POST` unconditionally, matching this
design's own choice. No change needed.

**OQ-6 (MINOR):** `:http_non_2xx`'s retriability (§5.3, defaulted to `false`) covers every
status outside `2xx/3xx/429` — including generic `5xx` server errors, which some retry
policies treat as transient. The requirement text calls out only 3xx (never retry) and 429
(always retry) explicitly; it is silent on the rest of the 4xx/5xx space. This design's
conservative default (never retry) is stated explicitly here rather than picked silently —
flagged for REVIEWER in case R-Co's real behavior special-cases 5xx.

---

## 10. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Definitions.Graph`/`.Node` (REQ-028/029) | this design -> REQ-028/029 | Reads `Graph.Node.t()`'s `id`/`attributes` fields only. Zero code added to `graph.ex`. |
| `Letflow.Engine.ExecutionError.error_type()`/`error_args()`/`affected()` (REQ-061) | this design -> REQ-061 | `build_service_task_give_up_error_attrs/1` and `build_empty_url_error_attrs/1`'s return types are both built to match `Letflow.Engine.standalone_error_attrs()` field-for-field — the former reuses the already-shipped `:service_task_retries_exhausted` atom for every `:give_up` cause (exhausted retries AND immediate non-retriable failure), the latter introduces `:service_task_url_rendered_empty` as a new (legal, since the union is open) member. Zero code added to `execution_error.ex`. |
| `Letflow.Engine.set_instance_error/2` (REQ-061) | REQ-061 -> this design (this design is a documented, not-yet-wired caller) | The routing target §6 names for both the exhausted-retry and empty-rendered-URL cases — no call site exists inside this module itself; a future dispatch-orchestration/activation-time requirement is expected to make the actual call. |
| `Letflow.Engine.VariableMerge.merge/3` (REQ-049) | REQ-049 -> this design (documented, not-yet-wired caller) | `classify_failure_kind/1`'s `{:success, decoded_map}` result is the input a future caller passes as `incoming_variables` to `VariableMerge.merge/3` (AC5) — this module does not call `merge/3` itself, since merging also needs `current_variables`/`variable_validations` this module has no access to. |
| A future `transport_fun()` implementation | future -> this design | Supplies a real HTTP client call. Not built here (§1, §3.4, §7). |
| A future `catalog_lookup_fun()` implementation (S6 `service_catalog`) | future S6 -> this design | Supplies a real DB-backed service registry lookup. Not built here (§1, §3.5, §7). |
| A future OBS-05 dead-letter queue (S6) | future S6 -> `instance_projections` (via REQ-061) | Reads the `status == :error` record this module's give-up path causes `set_instance_error/2` to write. Not built here (§1, §6, §7). |

---

## 11. Acceptance-criteria traceability

| REQ-056 acceptance criterion | Concrete design element |
|---|---|
| 1. `parse_config_from_node_attributes` defaults `timeout_ms` to 30000 and `retry_limit` to 3 when omitted, records `BothUrlAndServiceIdProvidedUrlIgnored` as a warning (not error) when both `url`/`service_id` present | §3.1 defaults; §5.1 table rows `timeout_ms`/`retry_limit`/`warnings`; INV-ST-5 |
| 2. HTTP 3xx classified as failure, never followed; HTTP 429 classified as retriable failure — two explicit tests | §5.2 rows 5-6; §5.3 table (`http_redirect_3xx: false`, `rate_limited_429: true`); INV-ST-2, INV-ST-3 |
| 3. Each of the 7 failure kinds has an explicit test mapping condition -> kind; `is_retriable_failure`/`decide_failure` tested at attempt_index below/equal/above retry_limit | §5.2 (full 7-row table); §5.3's `decide_failure/3` three-step algorithm and its worked boundary example |
| 4. `compute_service_task_backoff_ms` grows exponentially, clamped at cap, verified across ≥4 successive attempt indices without sleeping | §4 spec (`min(base_ms * 2^attempt_index, cap_ms)`); INV-ST-6; §5.2/§5.3 purity note ("no sleep, no clock read") |
| 5. 2xx JSON-object body merges via REQ-049's merge; 2xx JSON array/bare string does not merge, routes to REQ-061 ERROR — two explicit tests | (a) §5.2 row 3 (`{:success, decoded_map}`) + §10's `VariableMerge.merge/3` cross-reference; (b) §5.2 row 4 (`:invalid_2xx_body`) -> §5.3 (non-retriable) -> `decide_failure/3` step 1 gives up on attempt 0 -> `build_service_task_give_up_error_attrs/1` (§4) -> §6 case 1's routing statement, explicitly naming AC5(b) -> `Letflow.Engine.set_instance_error/2`; INV-ST-4, INV-ST-8 |
| 6. URL template rendering to empty string rejected at activation, routes to ERROR path rather than dispatching | `validate_rendered_url/1` (§4); `build_empty_url_error_attrs/1` (§4, `:service_task_url_rendered_empty`); §6 case 2's routing statement; INV-ST-8 |
| 7. Moduledoc states HTTP transport and service_catalog lookup are injectable, names OBS-05's DLQ (S6) as unbuilt destination, confirms no partial DLQ built | §7 (required verbatim moduledoc text) |
| 8. Exhausted-retry outcome (`decide_failure` -> give-up) demonstrated routing into `set_instance_error` rather than its own ERROR transition, confirmed by inspection and by test | §4 `build_service_task_give_up_error_attrs/1`; §6 case 1 (full routing section, also covers AC5(b) as the same `:give_up` sink); INV-ST-8; §10's `set_instance_error/2` cross-reference |
