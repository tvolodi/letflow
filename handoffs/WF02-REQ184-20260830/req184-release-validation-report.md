# REQ-184 — RELEASE-VALIDATOR independent re-verification (WF-02 Step 5)

Run date: 2026-08-30
Branch: feature/WF02-REQ184-20260830

## Verdict: PASS

All 6 acceptance criteria genuinely satisfied, independently re-derived from the real
code and a real test run -- not from trusting the upstream chain of PASSes.

## What I independently checked

1. **Read `docs/requirements.yaml`'s REQ-184 entry in full** (all 6
   `acceptance_criteria`), not from memory of the handoff summaries.

2. **AC1 (response allowlist)**: read `lib/letflow/routers/webhooks.ex`'s
   `delivery_json/1` (L304-317) and diffed its 9 emitted keys against
   `web/src/types/api.ts`'s `WebhookDeliveryAttempt` interface (L354-364) directly.
   Exact match, same 9 fields: `delivery_id`, `subscription_id`, `event_type`,
   `status`, `http_status_code`, `attempted_at`, `attempt_count`, `max_attempts`,
   `last_error`. `delivery_json/1` is a hand-built map literal over `%Delivery{}`,
   not a `Jason.Encoder` derivation, so no `tenant_id`/`__meta__`/the row's own `id`
   PK can leak.

3. **AC2 (limit param)**: read `resolve_limit/1` (L241-248) -- parses
   `conn.query_params["limit"]` (query params fetched explicitly via
   `fetch_query_params(conn)` at L224, not read off `conn.params`, confirming the
   moduledoc's own flagged deviation from the design's literal wording is real and
   correctly reasoned), falls back to a default of 20 for anything not a positive
   integer string. Confirmed test coverage in
   `test/letflow/routers/webhooks_test.exs` L462-583: an exact "5 attempts,
   `limit=2` -> exactly 2 items, most-recent-first" test, an omitted-limit-defaults-
   to-20 test, and a parametrized malformed-limit-value test (`"0"`, `"-1"`,
   `"abc"`, etc.) confirming fallback rather than error or an unbounded/zero result.

4. **AC3 (permission gate)**: `authz_get "/subscriptions/:id/deliveries",
   :WebhookSubscriptionsManage` (L132) -- same macro/policy-key path as the other
   three subscription routes, `:WebhookSubscriptionsManage` already resolved by
   `Letflow.Api.Authorization.endpoint_policy_key/2` to `:WebhooksManage`
   pre-REQ-182 (unchanged, confirmed no diff to `lib/letflow/api/authorization.ex`
   -- `git diff main...HEAD -- lib/letflow/api/authorization.ex` is empty).

5. **AC4 (cross-tenant-404, re-verified myself, not proxied through the security
   reviewer's confirmation)**: read `Letflow.Webhooks.list_delivery_attempts/3`
   (`lib/letflow/webhooks.ex` L637-651) -- it calls the same private `get/2`
   (L659-672) that `update/3`/`delete/2` already use. `get/2`'s only tenant input
   is `opts[:prefix]` (schema-per-tenant); a subscription id that exists only in
   another tenant's schema and one that doesn't exist anywhere both resolve to
   `Repo.get(Subscription, id, prefix: prefix)` returning `nil` ->
   `{:error, :not_found}` -- genuinely indistinguishable at the code path, not a
   weaker proxy (e.g. not a separate `tenant_id` filter that could diverge from
   `update/3`'s). The router maps `{:error, :not_found}` and `{:error, :invalid_id}`
   both to `Response.not_found/1` (L231-235), same as PATCH/DELETE. Confirmed real
   cross-tenant test at L585-601 (real subscription id belonging to tenant B,
   accessed as tenant A -> 404) and non-existent/malformed-id tests at L603-625.

6. **AC5 (non-existent id -> 404)**: confirmed by the same `get/2` path and the
   test at L604-613.

7. **AC6 (moduledoc disclosure)**: read `lib/letflow/routers/webhooks.ex`'s
   moduledoc L19-25 -- states explicitly R-Co's `webhooks.zig` "was **not
   inspected**" for this route layer, unreachable Windows path, and that the SPA
   consumer (`web/src/api/dlq.ts`'s `webhooksApi`, `web/src/types/api.ts`) was the
   binding contract instead. Matches AC6's wording requirement.

8. **Re-ran the target tests myself** (not trusting TEST-RUNNER's report):
   `source ~/.asdf/asdf.sh && mix test test/letflow/webhooks_test.exs
   test/letflow/routers/webhooks_test.exs` -> **43 passed, 0 failures**, real
   Postgres-backed tenant-schema fixtures (visible in the debug log: real
   `secrets`/`webhook_subscriptions` inserts, real schema provision/drop).

9. **Confirmed untouched via `git diff main...HEAD --stat`**: no migration file in
   the diff; `lib/letflow/api/authorization.ex` diff is empty; no
   `lib/letflow/webhooks/delivery.ex`/`subscription.ex` schema file in the diff
   (only `lib/letflow/webhooks.ex` and `lib/letflow/routers/webhooks.ex` changed in
   `lib/`); REQ-183's `deliver/3` body unchanged (present in `webhooks.ex` but not
   part of this diff's touched lines beyond the new `list_delivery_attempts/3`
   section appended after it). `test/mix/tasks/letflow_check_toolchain_test.exs` is
   NOT in the diff -- confirms TEST-RUNNER's rustc-absent-failure-is-unrelated
   diagnosis is structurally correct (the failing test file cannot be a regression
   from a branch that never touches it). Independently confirmed the rustc absence
   itself is an environment fact, not re-verified by me a second time via `which
   rustc` since the diff-exclusion argument alone is sufficient to clear this
   branch of responsibility for that failure.

10. **`mix compile --warnings-as-errors`**: clean, zero output, exit success.

11. **`grep -n "Repo\.\|Ecto\.Query\|import Ecto"
    lib/letflow/routers/webhooks.ex`**: zero matches -- INV-RT-1 (no direct
    Repo/Ecto.Query use in a router module) genuinely unviolated.

## Conclusion

No gap found. Routing to DOC-UPDATER to flip REQ-184's status to `done` and append
the status-history event.
