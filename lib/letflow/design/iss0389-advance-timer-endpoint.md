# ISS-0389 — `POST /api/v1/instances/:id/advance-timer`

Design for the route ISSUE-FIXER diagnosed as missing
(`handoffs/WF03-ISS0389-20260905/step-01-issue-fixer-diagnosis.json`). The
underlying firing mechanism (`Letflow.Scheduler.fire_timer/2`,
`lib/letflow/scheduler.ex:262`) needs **no change** — it already forces a
`"pending"` timer to fire regardless of `fire_at` vs now. This design covers
only the new route, its request/response contract, a new targeting-resolution
context function, and authz wiring.

## 0. The three open decisions (ISSUE-FIXER's handoff, resolved here)

### Decision 1 — targeting semantics

The route path carries only `instance_id`. `fire_timer/2` takes a specific
`timer_id`, not an instance id, so something must resolve "which timer" for
a given instance before calling it.

**Resolution:** the request body carries an **optional** `timer_id` field.

- `timer_id` present → that exact timer, if pending and belonging to this
  instance, is the target.
- `timer_id` absent → the instance's own **pending** timers are looked up;
  if there is exactly one, it is the target (this is the only shape
  `test/fixtures/simulation/swiftroute/scenarios/shipment-ops-timeout-escalation.yaml`
  step 2 exercises — its `via: api` step has no `params` key at all, so
  `Letflow.Simulation.Runner`'s `dispatch_api_step/4`
  (`test/support/simulation/runner.ex:411-421`) sets `body_params: %{}`; the
  route MUST succeed against a literal empty JSON object body for that
  scenario to move off its documented `:skip` fallback).
- Zero pending timers for the instance (whether because none exist, all are
  already fired/cancelled/failed, or the instance id itself doesn't
  resolve to any tenant-schema row) → **404**, no distinguishing detail
  (matches this router's own established INV-5 "same 404" precedent for
  cross-tenant/absent resources — see moduledoc's "INV-5" section).
- More than one pending timer and no `timer_id` given → **400**, requiring
  the caller to disambiguate by supplying `timer_id`. Chosen over
  "fire the earliest" or "fire all" because both of those are silent,
  surprising behaviors for an operator-facing force-fire action — a
  caller who force-fires the wrong timer among several pending ones has no
  way to know that happened until much later. Explicit disambiguation is
  the only option that can't silently do the wrong thing.
- `timer_id` given but it does not exist, is not `"pending"`, or exists but
  belongs to a **different** instance than the one in the path → **404**,
  same code path as "zero pending timers" (folds together, matching this
  router's own INV-5 discipline: a real-but-wrong-instance timer must not
  be distinguishable from an absent one — see the attachments routes'
  "Two distinct 404 checks" section above in this same file for the
  precedent this mirrors).

### Decision 2 — new authz permission

**Resolution: a genuine new permission, `:InstancesAdvanceTimer`, wired
through the full `endpoint_policy_key/2` + `required_permission/1` +
`role_allows?/2` path** — not the `rebind-pins`/`reconstruct` ad-hoc
route-declared-atom-with-no-`endpoint_policy_key/2`-clause pattern.

That pattern (`lib/letflow/routers/instances.ex`'s own moduledoc, "REQ-131:
no `endpoint_policy_key/2` clause exists for this route") is documented in
that same file as **"explicitly ruled out"** as the general mechanism going
forward — it was a stopgap for two REQ-078/079 routes whose permission
question REQ-131 deferred to a later requirement, and each use required a
named entry on `test/letflow/api/authorization_enforcement_test.exs`'s
`@allowlist` with a stated reason. Advancing a timer is a new, distinct
capability (force-firing a scheduled node ahead of its own schedule) with
no existing "same permission already required" precedent the way
`rebind-pins`/`reconstruct` had `POST /:id/cancel`'s `:InstancesCancel` to
point to — inventing a fresh ad-hoc allowlist entry here would be repeating
exactly the shortcut the moduledoc says is closed, not following it.
Instead this follows the `AttachmentsManage`/`AttachmentsRead` precedent
(REQ-212): a real new permission, fully wired, no allowlist entry needed.

**Naming:** `:InstancesAdvanceTimer` for both the `permission()` and
`endpoint_policy_key()` atom (one name, not two, matching the
`:InstancesStart`/`:InstancesCancel`/`:InstancesRead` 1:1 convention already
used for every other `/instances` policy key — not the `:DlqReadRetryDiscard
-> :DlqOperate` split style, which exists only where one permission legitimately
gates several distinct endpoint shapes; here there is exactly one endpoint).

**Role mapping** (judgment call, flagged for REVIEWER, same discipline as
REQ-212's §6.5 table): `PLATFORM_ADMIN` holds it via the existing
catch-all (`role_allows?(:PLATFORM_ADMIN, _permission), do: true` —
untouched). `PROCESS_OPERATOR` gains it — this is the same role already
holding `:InstancesCancel` and `:AttachmentsManage`, i.e. the
"operates in-flight instances" role, and force-firing a timer is squarely
an in-flight-execution-state mutation of the same class as cancel/rebind.
`PROCESS_DESIGNER`, `TASK_WORKER`, `AGENT_RUNNER` do **not** gain it —
none of the three holds `:InstancesCancel` today either, and there is no
acceptance criterion asking any of them to force-fire timers.

### Decision 3 — production route, not simulation-only

**Resolution: ships as a real, permission-gated, tenant-facing production
route** — not gated to test/simulation contexts.

Reasoning:

- `Letflow.Scheduler.fire_timer/2` is already an ordinary public function
  with no environment guard of any kind (ISSUE-FIXER's finding); adding an
  environment check at the route layer would be inventing a gating
  mechanism this codebase has no precedent for (no other route in
  `lib/letflow/routers/` is conditionally mounted per environment).
- The scenario fixture drives this via `via: :api`
  (`test/support/simulation/runner.ex:124-126`'s own moduledoc: `via: :api`
  steps "dispatch real HTTP" against the real router) — it is written and
  tested as a real product endpoint, not a `Runner`-internal test hook
  (ISSUE-FIXER's grep of `lib/letflow/simulation/` found no test-only "fake
  fire" mechanism to promote instead — there is none; `Letflow.Simulation.Runner`
  itself lives under `test/support/`, not `lib/`, precisely because it is a
  test harness that calls real routes, not a stand-in for one).
- Real operational value exists: an ops manager watching a stuck SLA/escalation
  timer (the exact scenario this issue's own fixture models — a
  driver-incident-report ops-assessment timeout) has a legitimate reason to
  force an escalation now rather than wait out a misconfigured or
  no-longer-relevant delay, the same class of manual override
  `DlqOperate`'s retry/discard actions already represent for stuck DLQ
  entries.
- The new permission (Decision 2) is the actual safety mechanism — restricting
  the *capability* to `PLATFORM_ADMIN`/`PROCESS_OPERATOR` is the correct
  control, not restricting the *route's existence* by environment.

## 1. Route

| Method/path | Delegate | Permission | Success | Error statuses |
|---|---|---|---|---|
| `POST /instances/:id/advance-timer` | `Letflow.Scheduler.resolve_advance_target/3` (new) then `Letflow.Scheduler.fire_timer/2` (existing) | `InstancesAdvanceTimer` | 200 | 400, 404, 422 (`instance_id`/`timer_id` malformed), 500 |

Declared in `lib/letflow/routers/instances.ex` as:

```
authz_post "/:id/advance-timer", :InstancesAdvanceTimer do
  handle_advance_timer(conn, conn.params["id"])
end
```

placed immediately after `authz_post "/:id/reconstruct"` and before
`authz_post "/"` (create) — all are literal path suffixes under `/:id/` or
the bare create path, so ordering among the `POST` block does not collide,
matching this router's own "Route ordering" moduledoc note; it just must
stay above any future bare `authz_post "/:id"`, which does not exist today.

## 2. Request body

Optional JSON object (an absent body / `{}` is valid and is the shape the
swiftroute scenario fixture sends):

```json
{
  "timer_id": "018f4d2a-....-....-....-............"
}
```

| Field | Required | Type | Notes |
|---|---|---|---|
| `timer_id` | no | UUID string | When present, must be a well-formed UUID (422 `unprocessable` if not) or the request is treated identically to `timer_id` absent for the disambiguation logic below. |

No other fields. `reason`/`actor_id`-style audit fields are **not** added —
`fire_timer/2`'s own `append_timer_fired_event/4` already appends a
`TIMER_FIRED` event carrying `timer_id`/`node_id`/`timer_type`/`fired_late`/
`scheduled_fire_at`/`actual_fired_at`; this route adds no second audit
mechanism on top of an already-audited action, and there is no acceptance
criterion asking for a caller-supplied reason string.

## 3. New context function — `Letflow.Scheduler.resolve_advance_target/3`

Added to `lib/letflow/scheduler.ex`, alongside `fire_timer/2`, so the router
never issues a `Repo.*` call itself (INV-RT-1,
`test/letflow/routers/req078_supporting_routes_test.exs`'s `T-19` test —
same boundary REQ-212's attachment routes already had to respect, see that
router's own moduledoc "Byte-retrieval mechanism" section).

```
@spec resolve_advance_target(
        instance_id :: Ecto.UUID.t(),
        timer_id :: Ecto.UUID.t() | nil,
        tenant_schema :: String.t()
      ) :: {:ok, Letflow.Scheduler.Timer.t()}
         | {:error, :no_pending_timer}
         | {:error, :ambiguous_pending_timers}
```

Behavior (spec only — no implementation here):

- Queries `timers` in `tenant_schema` where `status == "pending"`.
- `timer_id == nil`: further filters to `instance_id == ^instance_id`.
  - 0 rows → `{:error, :no_pending_timer}`.
  - 1 row → `{:ok, timer}`.
  - 2+ rows → `{:error, :ambiguous_pending_timers}`.
- `timer_id != nil`: looks up that exact row by `id == ^timer_id`.
  - Not found, OR found but `status != "pending"`, OR found but
    `timer.instance_id != instance_id` → `{:error, :no_pending_timer}` (the
    three collapse to one reason — same-404 discipline, Decision 1).
  - Found, pending, correct instance → `{:ok, timer}`.

The handler then calls `Letflow.Scheduler.fire_timer(timer.id, tenant_schema)`
directly, per ISSUE-FIXER's finding — no change to `fire_timer/2` itself.

## 4. Response shapes

**200**, on `fire_timer/2` returning `{:ok, :fired}`:

```json
{
  "instance_id": "...",
  "timer_id": "...",
  "node_id": "...",
  "timer_status": "fired"
}
```

**200**, on `fire_timer/2` returning `{:ok, :already_final}` (the timer was
concurrently fired/cancelled/failed by something else — e.g. the poller —
between `resolve_advance_target/3`'s read and this call's own lock
acquisition; treated as an idempotent, non-error outcome, not a 409, since
the caller's intent — "make sure this timer isn't still pending" — is
already satisfied):

```json
{
  "instance_id": "...",
  "timer_id": "...",
  "node_id": "...",
  "timer_status": "already_final"
}
```

`node_id` is sourced from the `Timer` struct `resolve_advance_target/3`
already returned (its `fire_at`/`node_id`/etc. fields don't change under
`fire_timer/2`'s own `fire_changeset/2`, which only touches `status`/
`fired_at` — see `lib/letflow/scheduler/timer.ex`'s `fire_changeset/2` doc).
No `fired_at` field is returned — `fire_timer/2`'s own return type is
`{:ok, :fired} | {:ok, :already_final} | {:error, term()}`, carrying no
timestamp; fabricating one at the response layer from "now" would claim a
precision the mechanism doesn't actually give the caller.

**Error mapping:**

| Condition | Status | Body |
|---|---|---|
| `instance_id` not a valid UUID | 422 | `Response.unprocessable(conn, "instance_id is not a valid UUID")` |
| `timer_id` present but not a valid UUID | 422 | `Response.unprocessable(conn, "timer_id is not a valid UUID")` |
| `resolve_advance_target/3` → `{:error, :no_pending_timer}` | 404 | `Response.not_found(conn)` |
| `resolve_advance_target/3` → `{:error, :ambiguous_pending_timers}` | 400 | `Response.bad_request(conn, "instance has more than one pending timer; specify timer_id")` |
| `fire_timer/2` → `{:error, _reason}` | 500 | `Response.internal_error(conn)` — matches this router's own INV-4 no-detail-500 discipline for internal/unexpected failures (`render_cancel/2`, `render_reconstruct/2` etc. all end the same way) |
| request body present but not a JSON object | 400 | `Response.bad_request(conn, "request body must be a JSON object")` — mirrors `object_body/1`'s existing check, reused here |

## 5. Authorization wiring — the four coordinated sites in `lib/letflow/api/authorization.ex`

1. **`@type permission ::`** (~line 71) — add `| :InstancesAdvanceTimer` to
   the closed union.
2. **`@type endpoint_policy_key ::`** (~line 93) — add
   `| :InstancesAdvanceTimer` to that closed union too (same atom name,
   Decision 2's 1:1 convention).
3. **`endpoint_policy_key/2`** (~line 255, next to the existing
   `def endpoint_policy_key("POST", "/instances/:id/cancel"), do: :InstancesCancel`
   clause) — add:
   `def endpoint_policy_key("POST", "/instances/:id/advance-timer"), do: :InstancesAdvanceTimer`
4. **`required_permission/1`** (~line 446, next to
   `def required_permission(:InstancesCancel), do: :InstancesCancel`) — add:
   `def required_permission(:InstancesAdvanceTimer), do: :InstancesAdvanceTimer`
5. **`role_allows?/2`** (~line 503, `:PROCESS_OPERATOR` clause) — add
   `:InstancesAdvanceTimer` to that role's permission list (alongside
   `:InstancesCancel`, `:AttachmentsManage`, etc). No change needed to
   `:PLATFORM_ADMIN` (catch-all `true`), `:PROCESS_DESIGNER`, `:TASK_WORKER`,
   or `:AGENT_RUNNER` (catch-all `false`).

(ISSUE-FIXER's handoff counted sites 1–2 together as "a closed type union
(~line 75/104)" plus sites 3/4/5 as three more — "four coordinated sites"
total; this design spells out all five literal edit points across those
four conceptual sites.)

No `@allowlist` entry is needed in
`test/letflow/api/authorization_enforcement_test.exs` — the route's declared
policy key (`:InstancesAdvanceTimer`) is backed by a real
`endpoint_policy_key/2` clause, so it resolves through the test's normal
"declared key == real key, not `:Unknown`" branch.

## 6. Acceptance criteria (mechanically verifiable)

- **AC1** — `grep -n 'advance-timer' lib/letflow/routers/instances.ex` finds
  the new `authz_post "/:id/advance-timer"` declaration.
- **AC2** — `Letflow.Api.Authorization.permission()` and
  `endpoint_policy_key()` typespecs both include `:InstancesAdvanceTimer`;
  `Authorization.endpoint_policy_key("POST", "/instances/:id/advance-timer")
  == :InstancesAdvanceTimer`; `Authorization.required_permission(:InstancesAdvanceTimer)
  == :InstancesAdvanceTimer`.
- **AC3** — `Authorization.role_allows?(:PROCESS_OPERATOR, :InstancesAdvanceTimer)
  == true`; `Authorization.role_allows?(:TASK_WORKER, :InstancesAdvanceTimer)
  == false`; `Authorization.role_allows?(:AGENT_RUNNER, :InstancesAdvanceTimer)
  == false`; `Authorization.role_allows?(:PLATFORM_ADMIN, :InstancesAdvanceTimer)
  == true`.
- **AC4** — `test/letflow/api/authorization_enforcement_test.exs`'s existing
  walk over `Letflow.Routers.Instances.__authz_routes__/0` passes with no
  new `@allowlist` entry required for `{"POST", "/instances/:id/advance-timer"}`.
- **AC5** — a `POST` with an empty JSON body (`{}`) against an instance with
  exactly one pending timer returns 200 with `"timer_status": "fired"`, and
  a follow-up `GET /instances/:id` shows the instance's token has moved off
  the `TIMER` node (mirrors `shipment-ops-timeout-escalation.yaml` step 2/3 —
  this scenario's step 2 `via: skip` must be converted to `via: api` and its
  disposition changed from `:skip`/`MINOR` to `:pass` once this route ships;
  that fixture/test edit belongs to TEST-DESIGNER, not this design).
- **AC6** — a `POST` against an instance with zero pending timers (no timers
  at all, or all already fired/cancelled/failed) returns 404.
- **AC7** — a `POST` (no `timer_id`) against an instance with two or more
  pending timers returns 400.
- **AC8** — a `POST` with a `timer_id` naming a real pending timer that
  belongs to a *different* instance than the one in the path returns 404
  (not 200, not a cross-instance fire) — the cross-instance guard in
  `resolve_advance_target/3`.
- **AC9** — a `POST` with a syntactically invalid `instance_id` or
  `timer_id` returns 422.
- **AC10** — `test/letflow/simulation/req206_swiftroute_test.exs`'s existing
  `"advance-timer endpoint absent from Letflow.Router and Routers.Instances"`
  test (asserting `refute String.contains?(router_content, "advance-timer")`
  etc., ~line 493-506) is now **stale and must be deleted or inverted** by
  TEST-DESIGNER — it is a self-fulfilling absence check that will fail
  (correctly) the moment this route exists; flagged here so it isn't
  mistaken for a regression.

## 7. Open questions

- **OQ-1** — Whether `InstancesAdvanceTimer` should also gate advancing a
  *recurring* timer (one with `repeat_expression` set,
  `lib/letflow/scheduler/timer.ex`'s recurrence quartet) differently from a
  one-shot timer is left undecided — `fire_timer/2`'s existing
  `maybe_rearm_timer/3` step already re-arms a recurring timer after firing
  with no special-casing needed here, so this design treats both timer
  shapes identically; flagged in case a future requirement wants to
  restrict force-firing recurring timers specifically.
- **OQ-2** — No idempotency-key handling is added for this route (unlike
  `rebind-pins`/`create`/`cancel`, which all read the
  `idempotency-key` header per this router's own established convention).
  Rationale: `fire_timer/2` is already naturally idempotent at the
  `timer_id` level (`{:ok, :already_final}` on a second call), so a
  caller-supplied idempotency key would add no new safety property here —
  flagged rather than silently decided, since it is a divergence from this
  router's own stated convention ("REQ-079 and REQ-080 must adopt this same
  convention rather than inventing a second one" — this route neither
  adopts it nor is REQ-079/080, so it isn't bound by that sentence, but
  REVIEWER should confirm the divergence is acceptable).
