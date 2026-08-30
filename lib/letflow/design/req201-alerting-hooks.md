# REQ-201 — Alerting hooks: threshold detection with edge-triggered firing and retry/backoff delivery (OBS-06)

**Status:** design (Step 1, WF-02, run WF02-REQ201-20260830)
**Depends on (already shipped):** REQ-061 (ERROR instances), REQ-176
(`dlq_entries`), REQ-183 (`Letflow.Webhooks.deliver/3`, auto-pause),
REQ-186/188 (`Letflow.Scheduler.Poller`'s tick cadence), REQ-190
(`Letflow.Secrets.resolve/2`), REQ-193 (`Letflow.Obs.Logger`).

---

## 0. Moduledoc-mandated statements (must appear verbatim-in-substance in `Letflow.Obs.Alerts` moduledoc)

### 0.1 Alerting hooks vs. webhook subscriptions — required distinction

Alerting hooks (this module) and webhook subscriptions (REQ-181/183) are
**two distinct mechanisms that must never be merged**, even though both POST
JSON to a configured URL with retry/backoff. The distinctions are load-bearing:

| Property | Alerting hooks (REQ-201) | Webhook subscriptions (REQ-181/183) |
|---|---|---|
| Audience | Platform operator diagnostics | Tenant-facing event delivery |
| Configuration | Application config — no API, no route | Tenant API (`POST /webhooks/subscriptions`) |
| Triggers | Fixed set of four: `instance_error_stuck`, `dlq_depth_threshold`, `scheduler_lag_threshold`, `webhook_subscription_paused` | Any domain event type |
| Signing | None (optional `auth_secret_ref` via REQ-190) | HMAC-SHA256 `X-Letflow-Signature` mandatory |
| Auto-pause | No — hooks are platform-configured, not tenant-owned | Yes — `consecutive_failures >= 5` → PAUSED |
| Delivery failure terminal action | Log via REQ-193 and drop | Land in `dlq_entries` (`entry_type: "webhook"`) |
| DLQ landing | **Never** — exhausted alert delivery DOES NOT write a `dlq_entries` row | Yes |

The no-DLQ property for exhausted alert delivery is explicit in OBS-06 and must be
stated in the moduledoc. Any future change that makes alerting delivery land in the DLQ
requires a new requirement and REVIEWER sign-off.

### 0.2 No route or controller

Alert hooks are configured through application config (`config :letflow, :alert_hooks,
[...]`), not through an API. No route file, no controller, and no Plug module is added
or modified by this requirement. R-Co has no alerts route; the SPA has no alerting
client (`web/src/api/` has no alerts entry; `web/src/types/api.ts` has no alert type).
This is a platform-operator-only facility.

### 0.3 No new periodic process

Detection runs on REQ-186's existing `Letflow.Scheduler.Poller` tick cadence. No new
child is added to `Letflow.Application`'s supervision tree. This matches the pattern
REQ-188 and REQ-199 follow.

---

## 1. Configuration struct shapes

These are Ecto-less plain structs (keyword list or struct, loaded from application
config at call time; no DB persistence of config).

### 1.1 `Letflow.Obs.Alerts.RetryPolicy`

```
@type t :: %__MODULE__{
  max_attempts:    pos_integer(),       # default 3
  base_backoff_ms: pos_integer(),       # default 1_000
  max_backoff_ms:  pos_integer(),       # default 30_000
  multiplier:      float()              # default 2.0
}
```

### 1.2 `Letflow.Obs.Alerts.AlertHookConfig`

```
@type t :: %__MODULE__{
  hook_id:         String.t(),          # opaque operator-chosen identifier
  enabled:         boolean(),
  destination_url: String.t(),          # absolute HTTPS URL
  timeout_ms:      pos_integer(),
  auth_secret_ref: String.t() | nil,    # REQ-190 secret reference — see §1.4
  retry_policy:    RetryPolicy.t()
}
```

### 1.3 `Letflow.Obs.Alerts.AlertThresholds`

```
@type t :: %__MODULE__{
  error_stuck_minutes:    pos_integer(),   # instance_error_stuck trigger
  dlq_depth_threshold:    pos_integer(),   # dlq_depth_threshold trigger
  scheduler_lag_ms:       pos_integer()    # scheduler_lag_threshold trigger
}
```

### 1.4 `auth_secret_ref` resolution — REQ-190 contract

`auth_secret_ref` is a **secret reference string** (format defined by
`Letflow.Secrets`, namespace `"alert_hook"`). It is NEVER stored inline as a
credential value in application config or in either state table. At delivery
time the HTTP sender calls `Letflow.Secrets.resolve/2` immediately before
constructing the request, passing `(hook.auth_secret_ref, namespace: "alert_hook")`.
The resolved value is used as a Bearer token in the `Authorization` header and
is NOT retained in any log, state row, or struct field. If the hook has no
`auth_secret_ref` (`nil`), no `Authorization` header is sent.

Open question OQ-1: namespace string for alert hook secrets — `"alert_hook"` is
proposed here but must be confirmed against `Letflow.Secrets`'s own namespace
validation when ELIXIR-DEV reads that module.

---

## 2. Application config pattern

Following `config :letflow, :scheduler, [...]` (REQ-186's precedent):

```elixir
config :letflow, :alert_hooks,
  enabled: true,
  thresholds: [
    error_stuck_minutes: 10,
    dlq_depth_threshold: 100,
    scheduler_lag_ms: 15_000
  ],
  hooks: [
    [
      hook_id: "ops-primary",
      enabled: true,
      destination_url: "https://alerts.example.com/letflow",
      timeout_ms: 5_000,
      auth_secret_ref: nil,
      retry_policy: [
        max_attempts: 3,
        base_backoff_ms: 1_000,
        max_backoff_ms: 30_000,
        multiplier: 2.0
      ]
    ]
  ]
```

Config is read fresh on every detection cycle (via `Application.get_env/2`) so a
runtime override (e.g. `Application.put_env/3` in tests) takes effect on the next tick.

---

## 3. DB migration specs

### 3.1 Table placement decision — PER-TENANT SCHEMA

**Decision: both tables are created in the per-tenant schema, using the same
`if prefix() do` guard pattern as every other S6 tenant-scoped migration
(e.g. `20260830010001_create_webhook_delivery_attempts.exs`). Both tables are
registered in `Letflow.TenantProvisioning.tenant_scoped_migrations/0`.**

**Reasoning against R-Co's global placement:**

R-Co places these tables in the global `public` schema (`migrations/022_obs06_alerting_state.sql`
header: "scope: public … global-registry table"). R-Co's design justification is that
its alerting thresholds are platform-wide: one global DLQ depth counter, one
platform-wide lag figure. Letflow's monitored subjects are structurally different:

- `dlq_entries` is per-tenant (tenant-scoped table, `prefix`-keyed, Decision 0003
  Decision B). A "DLQ depth" figure for alerting purposes is necessarily per-tenant.
- `instance_projections` (ERROR instances) is per-tenant. Per-instance stuck-duration
  is per-tenant.
- `webhook_subscriptions` auto-pause is per-tenant.

The only candidate for a global figure is `scheduler_lag_ms`, which measures the
platform-wide poll interval in the single `Letflow.Scheduler.Poller` process. However,
that one global figure does not warrant diverging from Decision 0003 Decision B —
it can be passed through the per-tenant detection loop without difficulty, or measured
once per tick before the per-tenant loop begins (see §6 for the scheduler integration).

Placing these tables globally would require diverging from Decision 0003 Decision B
and would require REVIEWER sign-off, per that decision record's own stated rule.
No such grounded R-Co-equivalent reason exists for Letflow. Per-tenant is correct
and requires no exception.

**Consequence for trigger_key:** within a per-tenant schema, the tenant identity is
already provided by the schema itself (the `prefix`), so `trigger_key` values do NOT
need to embed `tenant_id`. The format is `"trigger_name:{subject_id}"` or just
`"trigger_name"` for tenant-aggregate triggers (see §4 for instance_error_stuck).

### 3.2 `alert_trigger_state`

Migration name example: `20260830020001_create_alert_trigger_state.exs`

```
table :alert_trigger_state  (per-tenant schema, if prefix() do guard)

  trigger_key         :string,        primary_key: true, null: false
  is_armed            :boolean,       null: false,  default: true
  last_sample_value   :bigint,        null: false,  default: 0
  last_fired_at       :utc_datetime_usec,  null: true
  last_correlation_id :string,        null: true
  updated_at          :utc_datetime_usec,  null: false
```

No `id` column — `trigger_key` is the primary key (string). No `timestamps/1` macro;
`updated_at` is managed explicitly (set on upsert, no `inserted_at`).

No additional indexes beyond the primary key — lookups are always by `trigger_key`.

### 3.3 `alert_hook_emission_state`

Migration name example: `20260830020002_create_alert_hook_emission_state.exs`

```
table :alert_hook_emission_state  (per-tenant schema, if prefix() do guard)

  hook_id          :string,  null: false
  trigger_key      :string,  null: false
  last_emitted_key :string,  null: false
  updated_at       :utc_datetime_usec,  null: false

  primary_key: false
  composite PK: (hook_id, trigger_key)
```

No `id` column. Composite primary key via `create table(..., primary_key: false)` +
`add :hook_id, :string, primary_key: true` / `add :trigger_key, :string, primary_key:
true`. No `timestamps/1`; `updated_at` managed explicitly.

`last_emitted_key` is a string that uniquely identifies the last event/subject that
caused this hook to fire for this trigger — for deduplication across the Poller's own
retry logic. Format per trigger type:

| Trigger | last_emitted_key format |
|---|---|
| `instance_error_stuck:{instance_id}` | `"{instance_id}:{error_reason_hash}"` |
| `dlq_depth_threshold` | `"depth:{last_sample_value}"` |
| `scheduler_lag_threshold` | `"lag:{observed_lag_ms}"` |
| `webhook_subscription_paused` | `"{subscription_id}"` |

---

## 4. Per-instance trigger_key format

**For `instance_error_stuck`:** `"instance_error_stuck:{instance_id}"`

Within a per-tenant schema, `instance_id` is a UUID that is unique within that
tenant's schema. No `tenant_id` prefix is needed because the schema itself provides
tenant isolation. This format means:
- Two instances stuck simultaneously get two distinct `trigger_key` rows.
- One row per instance, never an aggregate row covering multiple instances.
- OBS-06's first edge case (two stuck instances → two separate deliveries, one per instance)
  is satisfied structurally: each instance_id maps to a distinct `trigger_key` row with
  its own `is_armed` state.

**For tenant-aggregate triggers** (DLQ depth, scheduler lag, subscription paused):
- `"dlq_depth_threshold"` — one row per tenant schema (DLQ depth is a per-tenant count)
- `"scheduler_lag_threshold"` — one row per tenant schema (lag is platform-global but
  the row lives in each tenant schema; all tenant schemas receive the same sample value
  passed in the tick context)
- `"webhook_subscription_paused:{subscription_id}"` — one row per subscription that
  has triggered an alert (not aggregate; a subscription pausing fires one delivery, and
  a second pausing of the same subscription after a re-enable fires another — edge
  case handled naturally by the is_armed state machine per subscription_id)

---

## 5. Edge-triggered firing algorithm (state machine)

The `alert_trigger_state` table exists for one purpose: making firing edge-triggered
(fires once on crossing, not on every sample while above threshold). The algorithm is a
two-state machine:

### States

- **ARMED** (`is_armed = true`): ready to fire if threshold is crossed.
- **FIRED** (`is_armed = false`): threshold was crossed; will not fire again until sample
  falls back below threshold and then crosses again.

### Transitions

```
ARMED + (sample > threshold):
  → fire delivery for this trigger_key
  → set is_armed = false
  → set last_fired_at = now()
  → set last_sample_value = sample
  → upsert row (INSERT ... ON CONFLICT DO UPDATE)

ARMED + (sample ≤ threshold):
  → no action (threshold not reached)
  → optionally update last_sample_value for observability

FIRED + (sample ≤ threshold):
  → re-arm: set is_armed = true
  → set last_sample_value = sample
  → upsert row

FIRED + (sample > threshold):
  → do NOT fire (already fired for this crossing; wait for re-arm)
  → update last_sample_value = sample (for observability)
```

### Initial state

On first detection for a trigger_key that has no row yet, the row is created with
`is_armed = true` (the table default). The first above-threshold sample thus fires.

### Re-arm edge case (OBS-06's explicit edge case)

If depth crosses threshold → fires (ARMED→FIRED). Depth falls below threshold → re-arms
(FIRED→ARMED). Depth crosses threshold again → fires a second time (ARMED→FIRED). This
is correct behavior and is tested by AC-2 as a distinct test.

### Upsert mechanism

All state transitions use `Repo.insert/2` with `on_conflict: :replace_all, conflict_target: [:trigger_key]`
(or `[:hook_id, :trigger_key]` for emission state), with `prefix: tenant_schema`. This
is an Ecto `Repo.insert/2` call with the conflict opts — NOT a raw SQL upsert — matching
the codebase's existing idiom.

---

## 6. `Letflow.Obs.Alerts` — public API

### 6.1 Primary entry point

```elixir
@spec run_detection(
  tenant_schema  :: String.t(),
  tick_context   :: tick_context()
) :: :ok
```

Called once per tenant schema per tick by `Letflow.Scheduler.Poller`. Never
raises — errors are caught internally and logged via `Letflow.Obs.Logger`. Config
(hooks and thresholds) is read from `Application.get_env(:letflow, :alert_hooks)`
inside this function, so it is always fresh.

`tick_context` type:

```elixir
@type tick_context :: %{
  dlq_count:               non_neg_integer(),
  observed_lag_ms:         non_neg_integer() | nil,
  stuck_instances:         [stuck_instance()],
  recently_paused_subs:    [paused_subscription()]
}

@type stuck_instance :: %{
  instance_id:  Ecto.UUID.t(),
  error_reason: String.t(),
  stuck_minutes: non_neg_integer()
}

@type paused_subscription :: %{
  subscription_id: Ecto.UUID.t()
}
```

`observed_lag_ms` is `nil` when the Poller has no prior tick timestamp recorded (first
tick after startup); no `scheduler_lag_threshold` alarm is fired in that case.

### 6.2 Internal functions (not public API, signatures for design completeness)

```elixir
# Evaluates one trigger type for one tenant schema.
@spec evaluate_trigger(
  trigger_key :: String.t(),
  sample      :: non_neg_integer(),
  threshold   :: non_neg_integer(),
  hooks       :: [AlertHookConfig.t()],
  tenant_schema :: String.t()
) :: :ok

# Reads or initialises the trigger state row for the given key.
@spec load_trigger_state(
  trigger_key   :: String.t(),
  tenant_schema :: String.t()
) :: {:ok, AlertTriggerState.t()} | {:error, term()}

# Upserts trigger state after a transition.
@spec upsert_trigger_state(
  attrs         :: map(),
  tenant_schema :: String.t()
) :: {:ok, AlertTriggerState.t()} | {:error, term()}

# Initiates delivery for all enabled hooks.
@spec fire_hooks(
  hooks         :: [AlertHookConfig.t()],
  trigger_key   :: String.t(),
  payload       :: map(),
  tenant_schema :: String.t()
) :: :ok

# Delivers one POST with retry/backoff; logs on exhaustion.
@spec deliver_with_retry(
  hook     :: AlertHookConfig.t(),
  payload  :: map(),
  attempt  :: non_neg_integer()
) :: :ok | {:error, :exhausted}
```

### 6.3 Ecto schema modules

```elixir
Letflow.Obs.AlertTriggerState    # backs alert_trigger_state table
Letflow.Obs.AlertHookEmissionState  # backs alert_hook_emission_state table
```

---

## 7. Delivery POST body shapes

All bodies are JSON (via `Jason.encode!/1`). Common envelope fields:

```
trigger:    String.t()   -- trigger name, e.g. "instance_error_stuck"
fired_at:   String.t()   -- ISO 8601 UTC, e.g. "2026-08-30T17:00:00.000000Z"
```

### 7.1 `instance_error_stuck`

```json
{
  "trigger":     "instance_error_stuck",
  "fired_at":    "2026-08-30T17:00:00.000000Z",
  "instance_id": "<UUID>",
  "error_reason": "<string>",
  "stuck_duration_minutes": 12
}
```

AC-7 requires field-by-field assertion on `instance_id`, `error_reason`, and
`stuck_duration_minutes`.

### 7.2 `dlq_depth_threshold`

```json
{
  "trigger":      "dlq_depth_threshold",
  "fired_at":     "2026-08-30T17:00:00.000000Z",
  "current_depth": 142,
  "threshold":    100
}
```

### 7.3 `scheduler_lag_threshold`

```json
{
  "trigger":          "scheduler_lag_threshold",
  "fired_at":         "2026-08-30T17:00:00.000000Z",
  "observed_lag_ms":  16200,
  "threshold_ms":     15000
}
```

### 7.4 `webhook_subscription_paused`

```json
{
  "trigger":         "webhook_subscription_paused",
  "fired_at":        "2026-08-30T17:00:00.000000Z",
  "subscription_id": "<UUID>"
}
```

---

## 8. Retry/backoff algorithm

Exponential backoff with a cap:

```
delay(attempt) = min(base_backoff_ms × multiplier^attempt, max_backoff_ms)
```

Where `attempt` is 0-indexed (0 = first retry, after attempt 1 fails).

With defaults (base=1000, multiplier=2.0, max=30000, max_attempts=3):
- Attempt 1: deliver
- Attempt 2: wait 1000ms, deliver
- Attempt 3: wait 2000ms, deliver
- Attempt 4 (max_attempts=3 means 3 total deliveries, 2 retries): wait 4000ms, deliver
  — or with max_attempts=3: 3 attempts, delays after attempts 1 and 2 are 1000ms and
  2000ms.

After the final failed attempt: `Letflow.Obs.Logger` receives one error-level log
entry with `component: "alert_delivery"`, `hook_id`, `trigger_key`, `attempt_count`,
`last_error`. **No `dlq_entries` row is written** (OBS-06 explicit; see §0.1's table).

Backoff is implemented via `Process.sleep/1` inline in the delivery loop — no separate
process or Task.Supervisor is introduced, matching the requirement's "no new periodic
process" constraint.

---

## 9. Scheduler integration

### 9.1 Where detection is plugged in

`Letflow.Scheduler.Poller.handle_info(:tick, state)` is the integration point. After
the existing calls to `Scheduler.poll_and_fire/1` and `maybe_refresh_active_instances/1`,
a new call `maybe_run_alert_detection/2` is added, following the exact pattern of
`maybe_run_retention_sweep/2` (REQ-188):

```
handle_info(:tick, state) ->
  schemas = fetch_tenant_schemas()
  Enum.each(schemas, &Scheduler.poll_and_fire/1)       # existing
  maybe_refresh_active_instances(schemas)               # existing (REQ-194)
  maybe_run_retention_sweep(schemas, state)             # existing (REQ-188)
  maybe_run_alert_detection(schemas, observed_lag_ms)   # NEW (REQ-201)
  schedule_next_tick()
```

### 9.2 `maybe_run_alert_detection/2` — what it does

```elixir
# Called once per tick if :alert_hooks is configured and enabled.
defp maybe_run_alert_detection(schemas, observed_lag_ms)
```

For each schema in `schemas`, queries:
1. DLQ count: `Letflow.Dlq.count_entries/1` (or equivalent aggregate query with `prefix: schema`)
2. Stuck instances: queries `instance_projections` for `status = "ERROR"` records
   where `updated_at <= now() - configured error_stuck_minutes`, `prefix: schema`
3. Recently-paused subscriptions: queries `webhook_subscriptions` for rows whose
   `paused_at` is within the last tick interval, `prefix: schema`

Then calls `Letflow.Obs.Alerts.run_detection/2` with the tenant schema and the assembled `tick_context`.

### 9.3 Observed lag measurement

`observed_lag_ms` is computed from `state.last_tick_started_at` (a new field added to
Poller's state map alongside `last_retention_run_at`). At the start of `handle_info/2`,
`now = DateTime.utc_now()` is captured; lag = `DateTime.diff(now, state.last_tick_started_at, :millisecond)`.
On the first tick `last_tick_started_at` is `nil` → `observed_lag_ms = nil` → no lag alarm.

**Poller state shape addition (REQ-201):**

```elixir
@type state :: %{
  last_retention_run_at: DateTime.t() | nil,   # existing (REQ-188)
  last_tick_started_at:  DateTime.t() | nil     # new (REQ-201)
}
```

`init/1` initializes `last_tick_started_at: nil`. At the start of each `handle_info(:tick)`,
`state` is updated: `%{state | last_tick_started_at: DateTime.utc_now()}` — but this
is the implementation detail; the design constraint is that the lag figure MUST come
from a real elapsed wall-clock interval between two ticks, not from a synthetic value
or a direct call to the detector (AC-5).

---

## 10. AC-to-design mapping

| AC | Design element satisfying it |
|---|---|
| AC-1: DLQ-depth hook fires exactly once when depth crosses threshold; does not re-fire while depth stays above | §5 edge-triggered state machine: ARMED→FIRED on crossing; subsequent samples while FIRED+above-threshold do not trigger. Tested across ≥3 evaluation cycles by driving the Poller tick directly. |
| AC-2: after depth falls below and rises above again, hook fires a second time | §5 FIRED→ARMED re-arm transition when sample ≤ threshold; then ARMED→FIRED again on next crossing. Distinct test from AC-1. |
| AC-3: two instances simultaneously stuck in ERROR produce two separate deliveries | §4 per-instance trigger_key `"instance_error_stuck:{instance_id}"`: two instance_ids → two distinct rows → two independent state machines → two deliveries. |
| AC-4: instance in ERROR for less than configured minutes produces no alert; same instance produces one once threshold is passed | §5 initial ARMED state + §6 `stuck_instance.stuck_minutes < threshold` → sample ≤ threshold → no fire. Once `stuck_minutes >= threshold` → sample > threshold → fire. |
| AC-5: scheduler-lag hook fires when observed poll interval exceeds threshold, driven by a real delayed cycle | §9.3 `observed_lag_ms` derived from `state.last_tick_started_at` wall-clock delta. Test delays an actual tick (not a direct detector call) to produce the lag. |
| AC-6: webhook subscription transitioning to PAUSED by REQ-183's auto-pause produces exactly one alert delivery | §4 trigger_key `"webhook_subscription_paused:{subscription_id}"` per subscription. Edge-triggered: fires once when subscription transitions to PAUSED; re-arms only if the subscription is re-enabled and pauses again. |
| AC-7: alert POST body for stuck-instance trigger contains instance_id, error_reason, and duration | §7.1 POST body shape includes `instance_id`, `error_reason`, `stuck_duration_minutes`. Test asserts each field by name on captured request body. |
| AC-8: failing delivery is retried up to max_attempts with increasing backoff; final failure logs exactly one error through REQ-193's logger and NO dlq_entries row is created | §8 retry/backoff algorithm. §0.1 no-DLQ property. Test asserts log entry via `ExUnit.CaptureLog` and queries `dlq_entries` for absence. |
| AC-9: hook with auth_secret_ref resolves credential through REQ-190's resolve/2; no credential stored inline | §1.4 auth_secret_ref resolution contract. `Letflow.Secrets.resolve/2` called at delivery time; no credential in config, in state tables, or in any returned struct. |
| AC-10: table placement stated in migration with reason; if global, divergence from 0003 Decision B flagged for REVIEWER | §3.1 placement decision: PER-TENANT, with explicit reasoning against R-Co's global placement and Decision 0003 Decision B. Migration file header must restate this reasoning in the same style as `20260830010001_create_webhook_delivery_attempts.exs`. |
| AC-11: detection runs on REQ-186's existing scheduler, not a new periodic child; confirmed by git diff of application.ex | §9.1 integration point is `Letflow.Scheduler.Poller.handle_info(:tick, state)`. No new child added to `Letflow.Application`. Test confirms `application.ex` is not modified (git diff --stat scoped to REQ-201 commits). |
| AC-12: moduledoc states how alerting hooks differ from REQ-181/183 webhook subscriptions | §0.1 required distinction table. Must appear verbatim-in-substance in `Letflow.Obs.Alerts` moduledoc. |
| AC-13: no route or controller file added or modified | §0.2 no-route statement. Confirmed by `git diff --stat` scoped to this requirement's commits. |
| AC-14: mix test and mix compile --warnings-as-errors pass with real output quoted | ELIXIR-DEV obligation: run both commands after implementation and quote actual terminal output in the handoff. |

---

## 11. Open questions

**OQ-1: `auth_secret_ref` namespace string.** This design proposes `"alert_hook"` as
the namespace passed to `Letflow.Secrets.resolve/2`. ELIXIR-DEV must verify this is a
valid namespace per `Letflow.Secrets`'s own namespace validation (read `letflow/secrets.ex`
before implementing). If the namespace format differs, adjust without changing the
design's intent (secret reference, resolved at delivery time, never stored inline).

**OQ-2: `Letflow.Dlq.count_entries/1` API.** The design assumes a function that returns
the total count of `dlq_entries` rows for a given tenant schema. ELIXIR-DEV must verify
this function exists (or add a private query) before implementing `maybe_run_alert_detection/2`.
If only a list query exists, a `count(*)` variant must be added; this is a read-only
aggregate and does not require a new requirement.

**OQ-3: "recently paused subscriptions" query window.** The design uses "paused within
the last tick interval" as the query window. The exact clause should be
`paused_at >= last_tick_started_at` (using the Poller's own recorded tick start). If
`last_tick_started_at` is nil on the first tick, skip the paused-subscription check.
ELIXIR-DEV must confirm `webhook_subscriptions.paused_at` is available on the schema
struct (it is, per REQ-183).

**OQ-4: `Letflow.Obs.Alerts` placement in the supervision tree.** This module has no
process of its own (pure function called from the Poller). No `application.ex` change.
This is a statement of non-change for clarity, not an unresolved question — included
here because AC-11 explicitly asserts it.
