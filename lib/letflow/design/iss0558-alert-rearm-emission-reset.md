# ISS-0558 — Alert re-arm must reset per-hook emission state

Design for fixing a write-before-deliver idempotency bug in
`Letflow.Obs.Alerts` (REQ-201/OBS-06). No implementation code — signatures,
schema/query shapes, and control-flow description only.

## 0. Scope

Fixes: `lib/letflow/obs/alerts.ex` (`evaluate_trigger/7`'s FIRED→ARMED
branch). No schema/migration change — `alert_hook_emission_state`'s existing
composite key `(hook_id, trigger_key)` (migration
`20260830040002_create_alert_hook_emission_state.exs`) is sufficient for the
fix; only the write pattern against it changes.

## 1. Confirmed bug mechanism (read from the real code, `lib/letflow/obs/alerts.ex`)

**Write-before-deliver** in `check_and_record_emission/4` (lines 458-483):
the function signature is

```
defp check_and_record_emission(hook_id, trigger_key, emitted_key, tenant_schema)
```

it looks up the existing `(hook_id, trigger_key)` row; if
`last_emitted_key == emitted_key` it returns `:already_emitted` and the
caller (`fire_hooks/4`) skips dispatch entirely — `deliver_with_retry/4`
(which does the actual HTTP POST + retry/backoff and is dispatched
fire-and-forget per ISS-0429) is never even started. If the row doesn't
match, it **upserts the row with the new `emitted_key` immediately**, then
returns `:ok` — so `fire_hooks/4` dispatches delivery only *after* the row
already reflects "this key was emitted." Delivery's own exhaustion (all
`retry_policy.max_attempts` attempts fail — `deliver_with_retry/4`'s
`{:error, last_error} when attempt >= policy.max_attempts` clause) only
logs via `Logger.error("alert delivery exhausted", ...)` and returns
`{:error, :exhausted}`; nothing rolls back or clears the emission row on
that path. So after an exhausted delivery, `alert_hook_emission_state`
already holds the key that was never successfully delivered.

**The FIRED→ARMED re-arm branch**, `evaluate_trigger/7` (lines 291-352),
exact current shape:

- State loaded via `load_trigger_state/2`.
- `state.is_armed == false` (i.e. FIRED) and `sample <= threshold` is the
  re-arm branch (lines 324-336): it calls `upsert_trigger_state/2` with
  `is_armed: true`, carrying forward `last_fired_at` and
  `last_correlation_id` from the existing state, `last_sample_value: sample`,
  `updated_at: now`. **It touches only `alert_trigger_state` — it never
  reads or writes `alert_hook_emission_state`.**

**The race**, confirmed exactly as ISS-0558 states: for
`instance_error_stuck`, `build_emitted_key/2` (lines 485-490) derives
`emitted_key = "#{instance_id}:#{md5(error_reason)}"` — a pure function of
`(instance_id, error_reason)`, independent of `sample`/`stuck_minutes`, and
independent of the ARMED/FIRED cycle. So: fire (exhausted, row written) →
recover (re-arm, row untouched) → stick again with the **same
`error_reason`** → identical `emitted_key` → `check_and_record_emission/4`
matches the stale row → `:already_emitted` → `deliver_with_retry/4` is never
even dispatched. Confirmed by reading `evaluate_stuck_instance/4`
(lines 255-280): `trigger_key = "instance_error_stuck:#{inst.instance_id}"`
is fixed per instance, and `payload["error_reason"]` (fed into
`build_emitted_key/2`) is the raw stored `error_reason` string — nothing
in this path varies it across firing cycles.

## 2. Fix mechanism

**What deletes:** all `alert_hook_emission_state` rows whose `trigger_key`
column equals the trigger's own `trigger_key` value (the same value
`evaluate_trigger/7` already carries as its first argument) — see §4 for
why this is scoped by `trigger_key` alone, not narrowed by `hook_id`.

Query shape (Ecto, matching this module's existing `import Ecto.Query`
style): a query against `AlertHookEmissionState` filtered by `where:
trigger_key == ^trigger_key` — an exact-match equality filter on the
`trigger_key` field only, no `hook_id` clause (see §4) — executed with
`prefix: tenant_schema` (every read/write in this module is
tenant-schema-scoped; `AlertHookEmissionState` carries no tenant column of
its own — tenancy is the Postgres search-path prefix, same as
`AlertTriggerState`).

**Where in the control flow:** inside the existing FIRED→ARMED branch of
`evaluate_trigger/7` (the `if sample <= threshold` arm reached only when
`state.is_armed == false`), immediately alongside the existing
`upsert_trigger_state/2` call — not as a separate call made before or after
it, and not delegated to a helper invoked from a different branch.

**Same-transaction requirement (the race-avoidance the issue calls out):**
the delete and the `alert_trigger_state` upsert must commit atomically, or
a poller tick landing between them could observe `is_armed: true` with the
stale emission row still present (or vice versa: emission cleared but
`is_armed` still `false`, in which case a same-cycle fire would already be
suppressed by the ARMED/FIRED gate itself, so the atomicity requirement is
strictly about the first ordering, not both). This codebase's established
idiom for "one DB write must not commit without its own mutation"
(`Letflow.Audit`'s moduledoc, `Letflow.Identity`'s create-with-audit paths)
is `Ecto.Multi` composed inline, run through a single `Repo.transaction/2`
call. The re-arm branch's existing single `upsert_trigger_state/2` call is
replaced with a two-step `Ecto.Multi`:

- Step `:clear_emissions` — `Ecto.Multi.delete_all/3` against the query
  above, opts `prefix: tenant_schema`.
- Step `:trigger_state` — the same insert/`on_conflict: :replace_all`
  operation `upsert_trigger_state/2` already performs, added via
  `Ecto.Multi.insert/3` (or `Ecto.Multi.run/3` wrapping the existing
  `Repo.insert/2` call, whichever keeps `upsert_trigger_state/2`'s existing
  signature reusable from the other two branches that call it unchanged) —
  same `on_conflict:`/`conflict_target:`/`prefix:` options it already uses.

Both run through one `Repo.transaction/2` call. The two branches that do
**not** re-arm (ARMED-still-below, FIRED-still-above) are unaffected and
keep calling `upsert_trigger_state/2` exactly as today — only the
FIRED→ARMED branch's call site changes.

**New/changed private function signature** (replacing the current
`upsert_trigger_state/2` call site inside the re-arm branch only):

```
@spec rearm_and_clear_emissions(attrs :: map(), trigger_key :: String.t(), tenant_schema :: String.t()) ::
        {:ok, term()} | {:error, term(), term(), map()}
```

`attrs` is the same map literal the re-arm branch already builds today
(`%{trigger_key:, is_armed: true, last_sample_value:, last_fired_at:,
last_correlation_id:, updated_at:}`). Return value is whatever
`Repo.transaction/2` returns for the `Ecto.Multi`; the existing re-arm
branch discards `upsert_trigger_state/2`'s return value today (its result
is not pattern-matched), so no caller-visible contract changes are forced
here — ELIXIR-DEV may keep discarding it, but see Open Question OQ-1 below
on whether a transaction failure should now be logged (today's plain
`Repo.insert/2` failure was already silently discarded the same way, so
this is a pre-existing gap the fix does not have to close, only should not
make worse).

## 3. Verified against every other trigger type — not just trusted from the issue text

Read `build_emitted_key/2`'s full clause set (lines 485-504) and each
`evaluate_*` call site that produces its `trigger_key`/`sample`/`threshold`
triple:

| Trigger | `trigger_key` | `emitted_key` derivation | Re-arm reachable via this call path? | Emitted-key stability across a rearm cycle |
|---|---|---|---|---|
| `instance_error_stuck` | `"instance_error_stuck:#{instance_id}"` | `"#{instance_id}:#{md5(error_reason)}"` | Yes — `evaluate_stuck_instance/4` is called every tick for every currently-ERROR-and-stuck instance; `stuck_minutes` naturally drops out of the stuck set (and re-arms, since it's simply absent from `tick_context.stuck_instances` the tick it's no longer stuck — **not** via `sample <= threshold` on this key, since threshold is `stuck_minutes`-based, not depth-based) — **this is the bug's own trigger.** | **Unstable — confirmed broken.** Depends only on `(instance_id, error_reason)`, which is identical across two firing cycles of the same recurring error. |
| `dlq_depth_threshold` | fixed `"dlq_depth_threshold"` | `"depth:#{current_depth}"` | Yes — `evaluate_dlq_depth/4` runs every tick, `sample = depth`. | **Not immune, only usually distinct.** The issue's own claim ("AC-2's `emitted_key` naturally differs on the second crossing") holds in the existing `alerts_test.exs` AC-2 test (`test/letflow/obs/alerts_test.exs:143-169`) only because the test uses a **different** depth on the second crossing (6, then re-arm at 3, then 8) — that is a property of the test's chosen values, not a guarantee `evaluate_trigger/7` enforces. If the queue depth happens to cross back to the **exact same** value on a later crossing (a realistic case: a steady-state depth that oscillates around the threshold, e.g. 105 → drains to 50 → refills to 105 again), `emitted_key` is identical and this same bug would reproduce for `dlq_depth_threshold` too, once its own delivery is ever exhausted between two such crossings. |
| `scheduler_lag_threshold` | fixed `"scheduler_lag_threshold"` | `"lag:#{observed_lag_ms}"` | Yes — `evaluate_scheduler_lag/4` runs every tick with non-nil lag. | **Same non-immunity as `dlq_depth_threshold`** — `observed_lag_ms` repeating an exact prior value across two crossings is less likely than an exact depth repeat but not impossible (e.g. a fixed poll-interval-derived lag ceiling). |
| `webhook_subscription_paused` | `"webhook_subscription_paused:#{subscription_id}"` | `subscription_id` (constant, `build_emitted_key/2`'s last real clause, line 500) | **No** — `evaluate_paused_subscription/3` is only ever called (from `do_run_detection/3`, line 236-238) for subscriptions present in `tick_context.recently_paused_subs`, which `safe_recently_paused_subs/2` populates only for **currently-`:PAUSED`** subscriptions with a recent `paused_at`. `sample` is unconditionally `1` and `threshold` is unconditionally `0` (`evaluate_paused_subscription/3`, line 286) every time this trigger is evaluated at all. The re-arm branch requires `sample <= threshold` (`1 <= 0`, always false) — so `evaluate_trigger/7`'s FIRED→ARMED branch for this `trigger_key` is **structurally unreachable** through this call site: once FIRED, a same-subscription re-pause event lands in the FIRED+"still above"-equivalent branch (lines 337-350: `is_armed: false` again, sample-only update), never the re-arm branch. | N/A — never reaches the branch this fix touches, so the fix is inert for this trigger. This is a **separate, pre-existing behavior** (a subscription that pauses, unpauses, then pauses again never re-fires this alert) — real, but out of ISS-0558's stated scope; flagging per "No Issue Left Local-Only" as a candidate follow-up issue, not fixing here. |

**Conclusion:** the issue's claim that AC-2 (`dlq_depth_threshold`) is
"naturally unaffected" is **not confirmed as a genuine invariant** — it
holds for the specific test data in `alerts_test.exs` but not as a general
property of `build_emitted_key/2`. This is a point in favor of the chosen
fix being scoped generically (§2: reset **all** hook rows for the
trigger's own `trigger_key` on every re-arm, regardless of trigger type)
rather than special-cased to `instance_error_stuck` only — the generic fix
also closes the latent, currently-untriggered exposure in
`dlq_depth_threshold` and `scheduler_lag_threshold`. This is noted as a
design decision, not scope creep: it is the same code change (the re-arm
branch is common to all four trigger types; `evaluate_trigger/7` has no
per-trigger-type branching), not additional code written for a different
trigger.

## 4. "Across all configured hooks" — scoped by `trigger_key` alone, not narrowed by `hook_id`

`alert_hook_emission_state`'s primary key is the pair `(hook_id,
trigger_key)` (migration `20260830040002_create_alert_hook_emission_state.exs`,
`AlertHookEmissionState` schema). A given `trigger_key` can have zero, one,
or many rows — one per hook that has ever had `check_and_record_emission/4`
called for it with that `trigger_key` (i.e. one per currently- or
formerly-configured enabled hook, since `fire_hooks/4` only calls
`check_and_record_emission/4` for hooks with `hook.enabled == true` at
firing time).

**Decision: delete by `trigger_key` match only — no `hook_id` filter.**
Justification:

- The re-arm branch (`evaluate_trigger/7`) already receives `hooks` (the
  full currently-configured hook list, built fresh from
  `Application.get_env/3` on every `run_detection/2` call via
  `build_hooks/1`) as one of its parameters — so an `hook_id in
  Enum.map(hooks, & &1.hook_id)` filter is *available* to write, but it
  would only clear rows for hooks configured **right now**, at re-arm time.
  A hook that was enabled during the firing cycle (and got a stale
  emission row written) but has since been disabled or removed from config
  would keep its stale row forever under that narrower filter — inert
  today, but a latent trap if that hook is re-enabled later without an
  intervening trigger-key change, silently reproducing the exact bug this
  fix exists to close.
- Matching by `trigger_key` alone deletes every row this trigger could
  possibly have written, past or present configuration, which is what
  "the next firing cycle generates a fresh emission" (the issue's own
  fix-direction wording) requires unconditionally.
- No other trigger_key's rows are touched — the query's `where:` clause is
  exact-match on `trigger_key`, not a prefix/pattern match, so
  `instance_error_stuck:<instance-A>` re-arming never touches
  `instance_error_stuck:<instance-B>`'s row, nor any other trigger's rows.
- Row count at stake is small (bounded by configured-hook count, typically
  single digits per tenant schema) — no batching/pagination concern for the
  `delete_all`.

## 5. Test plan

Add to `test/letflow/obs/alerts_test.exs`, following this file's existing
patterns exactly (`Letflow.DataCase`, `WebhookTestServer`,
`put_alert_config/1`, `capture_log/1` + `Process.sleep/1` for the
fire-and-forget dispatch per ISS-0429 — see AC-8's existing test at lines
382-426 for the established idiom of waiting out a detached exhausted
delivery before asserting).

**New `describe` block — regression test for the exact 3-step scenario:**

1. Configure one hook against a `WebhookTestServer` that returns `500` (so
   delivery is guaranteed to exhaust) and a small `max_attempts` (e.g. `2`,
   matching AC-8's pattern) — same `error_reason` used throughout.
2. Drive `Alerts.run_detection/2` with a `stuck_instances` entry whose
   `stuck_minutes` crosses the configured `error_stuck_minutes` threshold
   (mirrors `evaluate_stuck_instance/4`'s call shape) for a fixed
   `instance_id` and `error_reason`. Wrap in `capture_log/1` +
   `Process.sleep/1` (per AC-8's timing rationale) so the detached
   `deliver_with_retry/4` task's exhaustion is observed to complete before
   proceeding.
3. Assert exhaustion happened: log contains `"alert delivery exhausted"`
   (same assertion shape as AC-8), and no request was actually delivered
   successfully (the `WebhookTestServer` always 500s, so this is implied,
   but assert `Dlq.count_entries/1 == 0` too, matching AC-8, to confirm no
   side channel landed the payload).
4. Assert the emission row exists: `Repo.get_by(AlertHookEmissionState,
   [hook_id: ..., trigger_key: "instance_error_stuck:#{instance_id}"],
   prefix: schema_name)` returns a row whose `last_emitted_key` matches
   `"#{instance_id}:#{md5(error_reason)}"` (this is the pre-fix
   reproduction step — this assertion passes both before and after the fix,
   confirming the write-before-deliver mechanism itself is unchanged, only
   the re-arm cleanup is new).
5. Drive `Alerts.run_detection/2` again with the same `instance_id` **absent**
   from `stuck_instances` (i.e. the instance recovered) — but this alone
   does not exercise `evaluate_trigger/7`'s re-arm branch for
   `instance_error_stuck:#{instance_id}`, since `evaluate_stuck_instance/4`
   is only called for instances present in `tick_context.stuck_instances`
   (§3's own finding). The regression test must instead drive recovery
   through a call shape that *does* reach the re-arm branch: pass the same
   `instance_id`/`error_reason` again but with `stuck_minutes` now at or
   below `threshold_minutes` (i.e. still present in `stuck_instances`, but
   no longer over threshold) — `evaluate_stuck_instance/4`'s own
   `effective_threshold = max(threshold_minutes - 1, 0)` and `sample =
   stuck_minutes` means a `stuck_minutes` value `<= effective_threshold`
   reaches the `sample <= threshold` re-arm arm. (This double-checks §1's
   read of `evaluate_stuck_instance/4` against the actual re-arm
   precondition — the test must supply a tick_context entry, not omission,
   to exercise this specific trigger's re-arm path, unlike
   `dlq_depth_threshold`/`scheduler_lag_threshold` where a lower sample
   value naturally passed on every tick already does this.)
6. Assert re-arm happened: `trigger_state!(schema_name,
   "instance_error_stuck:#{instance_id}").is_armed == true` (existing
   helper, same as AC-2's test).
7. **Pre-fix-failing / post-fix-passing assertion:** assert the emission
   row for `(hook_id, "instance_error_stuck:#{instance_id}")` is now
   **absent** (`Repo.get_by/3` returns `nil`) — this is the fix's direct,
   independently-checkable effect.
8. Flip the `WebhookTestServer` to return `200` (or start a second server
   and swap `put_alert_config/1`'s `destination_url`, matching how other
   tests in this file reconfigure between phases), then drive
   `Alerts.run_detection/2` a third time with `stuck_minutes` back above
   threshold and the **same** `error_reason` as step 2 (so `emitted_key` is
   provably identical to the first cycle's).
9. Assert delivery actually happens this time:
   `receive_request/1` receives a POST (the existing helper, per every
   other test in this file) — this is the acceptance assertion the issue
   describes: "the second alert IS delivered this time, unlike before the
   fix." Before the fix, this step would instead time out
   (`refute_receive`/`receive_request`'s own `flunk` on timeout), because
   `check_and_record_emission/4` would still match the stale row from step
   2 and `fire_hooks/4` would skip dispatch without ever calling
   `deliver_with_retry/4`.

**Coverage this test plan does not duplicate:** `dlq_depth_threshold`'s
existing AC-2 test already exercises the "distinct depth on second
crossing" path and does not need this fix to pass (§3) — no new assertion
is added there. A follow-up issue (§3's "Conclusion") — not this fix — is
the right place for a same-depth-repeat regression test on
`dlq_depth_threshold`/`scheduler_lag_threshold`, since reproducing it
requires deliberately choosing a repeating sample value, and this fix
already covers both once merged (verified by the generic, trigger-key-only
scoping in §2/§4, not by a second test per trigger type).

## Open questions

- **OQ-1.** Should a `Repo.transaction/2` failure on the new
  `Ecto.Multi` (e.g. a DB error mid-transaction) be logged explicitly,
  given `evaluate_trigger/7`'s caller (`do_run_detection/3`) already
  ignores every `evaluate_*` call's return value and `run_detection/2`'s
  top-level `rescue` clause is the only safety net? Today's plain
  `Repo.insert/2` call in `upsert_trigger_state/2` has the same
  fire-and-discard shape, so this is a pre-existing gap, not one this fix
  introduces — flagging rather than silently deciding either way.
- **OQ-2.** `Ecto.Multi.insert/3` needs a full changeset or struct, matching
  whatever `upsert_trigger_state/2` already builds via `struct(attrs)`.
  Whether ELIXIR-DEV keeps `upsert_trigger_state/2`'s current
  `%AlertTriggerState{} |> struct(attrs)` shape verbatim inside the `Multi`
  step, or introduces a small changeset function, is an implementation
  choice not decided here — the design only requires that whatever shape
  is used preserves today's exact `on_conflict: :replace_all,
  conflict_target: [:trigger_key]` semantics unchanged.
