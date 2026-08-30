# REQ-184 TEST-DESIGNER gap analysis (WF-02 Step 3)

Cross-checked all 6 acceptance criteria in `docs/requirements.yaml`'s REQ-184 entry
against ELIXIR-DEV's existing test coverage in `test/letflow/webhooks_test.exs`
(context-level) and `test/letflow/routers/webhooks_test.exs` (HTTP-level), both read
in full. Verdict per AC below.

## AC1 — response shape, 9-field allowlist, exact field values

**Already complete, no gap.** `routers/webhooks_test.exs`'s `describe "REQ-184 AC1: ..."`
(lines 394–459 pre-edit) has two tests against real seeded rows:

- `Map.keys(item) |> Enum.sort() == Enum.sort([9 field names])` — an exact-set
  check, not superset/subset.
- Every field individually asserted against a concrete value from the seeded
  `Delivery` row (`delivery.delivery_id`, `"instance.completed"`, `"FAILED"`, `503`,
  `2`, `4`, `"HTTP 503: unavailable"`) plus `is_binary(item["attempted_at"])` for the
  one field whose exact string isn't practical to assert byte-for-byte (ISO8601
  timestamp). A second test covers the `SUCCESS`/`last_error: nil` path.

This satisfies the task's specific ask ("asserted on a real seeded row with concrete
values, not just keys present"). No new test needed.

## AC2 — limit enforcement, ordering-correctness of the subset

**Two genuine gaps found and filled.**

1. The exact-limit-cutoff test (`"more delivery attempts than the requested limit
   returns exactly limit items"`) seeded 5 attempts at strictly decreasing
   `attempted_at` values and asserted `length(items) == 2` under `?limit=2` — this
   confirms the *count* but not *which* 2 survived or their order. Given the
   REVIEWER-signed-off `[desc: attempted_at, desc: attempt_count]` ordering (design
   §4/OQ-2), the missing assertion is a real gap: a regression that limited to the
   *oldest* 2 rows instead of the newest 2, or returned the right 2 rows in the
   wrong order, would have passed the pre-existing test. Fixed by capturing the
   inserted `Delivery` structs and asserting
   `Enum.map(items, & &1["delivery_id"]) == [most_recent.delivery_id, second_most_recent.delivery_id]`.

   Note: `test/letflow/webhooks_test.exs`'s context-level test (`"returns exactly
   limit rows, most-recent (and highest attempt_count on tie) first"`) already
   verifies the *query's* ordering including the attempt_count tie-break, at the
   `Letflow.Webhooks.list_delivery_attempts/3` level directly. The HTTP-level gap
   fixed here is a different (thinner) risk: that `handle_deliveries/2`'s
   `Enum.map(deliveries, &delivery_json/1)` or the JSON encoding step reorders an
   already-correctly-ordered list on its way out — a real, if narrow, gap distinct
   from the context-level test's query-correctness proof.

2. `resolve_limit/1` (`lib/letflow/routers/webhooks.ex:241-248`) has three
   meaningfully distinct branches:
   - `is_binary(raw)`, `Integer.parse/1` succeeds with no leftover, value > 0 →
     the parsed value.
   - `is_binary(raw)`, any other outcome (non-numeric, non-positive, or leftover
     characters after the parsed integer, e.g. `"5abc"`) → default `20`.
   - not a binary at all (`nil`, i.e. the param was absent) → default `20`.

   Before this pass, only the third branch (via "omitted limit defaults to 20") and
   the first branch's single valid-positive-integer path (via the exact-count test)
   had coverage. The second branch — the actual fallback logic SECURITY-REVIEWER's
   finding is about — had **zero** test coverage: no test exercised `?limit=abc`,
   `?limit=0`, `?limit=-1`, or a partial-parse value like `?limit=5abc`. This is a
   real, several-branch function with no acceptance criterion directly demanding
   this behavior (design's own OQ-1) but a genuine correctness question a
   plausible alternate implementation (e.g. accepting `"5abc"` as `5`, or crashing
   on `Integer.parse!/1`) would get wrong without any test catching it. Filled with
   four parameterized tests (`describe "REQ-184 AC2: ..."`, the `for {slug,
   raw_limit} <- [...]` block), each asserting a 200 response and all 3 seeded rows
   surviving (proving fallback to 20, not to a 0- or 1-row limit, and not an error
   response).

## AC3 — 403 without WebhooksManage

**Already complete, no gap.** `routers/webhooks_test.exs`'s `describe "REQ-184 AC3: ..."`
uses `TASK_WORKER`. Verified directly against `lib/letflow/api/authorization.ex:482-483`:
`role_allows?(:TASK_WORKER, permission), do: permission in [:DefinitionsRead,
:InstancesRead, :TasksRead, :TasksComplete]` — `:WebhooksManage` is absent from this
list, and `:WebhookSubscriptionsManage` maps to `:WebhooksManage`
(`authorization.ex:425`). `TASK_WORKER` is one of the five real roles in `@roles`
(`authorization.ex:109`), not an invented/fake permission. No gap.

## AC4 — cross-tenant real id → 404 regardless of attempts

**Already complete, no gap — including the "permission alone doesn't bypass tenant
scoping" companion case.** REVIEWER already confirmed the existing test
(`describe "REQ-184 AC4: ..."`) uses two real distinct tenant schemas
(`TenantFixture.provisioned_tenant!/1` for both `tenant_a` and `tenant_b`). Reading
the test itself confirms the caller's role is `PLATFORM_ADMIN` — a role that *does*
hold `WebhooksManage` (the `PLATFORM_ADMIN` catch-all in `role_allows?/2`) — naming
tenant B's real subscription id (which has a real delivery attempt seeded against
it) from tenant A's auth context, and still getting 404. This **is** the exact
"caller with proper WebhooksManage from tenant A still can't see tenant B's data"
case asked about in the Step 3 task — it was not a separate missing case, because
the existing AC4 test's caller was never a permission-lacking one (that's AC3's
independent test). No new test needed.

## AC5 — non-existent id → 404, distinct from AC4

**Already complete, no gap — both the valid-UUID-but-absent case and the
malformed-non-UUID case are covered.** `describe "REQ-184 AC5: ..."` has two tests:
one with `Ecto.UUID.generate()` (well-formed, never persisted), one with the literal
string `"not-a-uuid"` (syntactically invalid). Read `Letflow.Webhooks`'s private
`get/2` (reused verbatim by `list_delivery_attempts/3` per the design) — it returns
`{:error, :invalid_id}` for a value that fails UUID parsing before any DB round-trip,
and `{:error, :not_found}` for a well-formed-but-absent id; the router
(`handle_deliveries/2`) folds both to `Response.not_found/1`. Both branches are
exercised by ELIXIR-DEV's existing two tests, and neither test crashes or produces a
non-404 status. No gap.

## AC6 — moduledoc disclosure

**Confirmed satisfied by direct read of the source — a doc-content check, not a
runtime test, per the task's own framing.** `lib/letflow/routers/webhooks.ex:17-25`'s
"## Contract source" section states verbatim: "R-Co's `webhooks.zig` was **not
inspected** while drafting this route layer (REQ-182) or the deliveries route added
on top of it (REQ-184) — R-Co is at a Windows path unreachable from this sandbox,
verified absent, not assumed covered. The binding contract instead is the
already-shipped SPA consumer: `web/src/api/dlq.ts`'s `webhooksApi` object (including
`getDeliveries/2`) and `web/src/types/api.ts`'s `WebhookSubscription` and
`WebhookDeliveryAttempt` types." This is the exact disclosure AC6 requires, and it is
additionally covered by REQ-182's pre-existing runtime test in
`routers/webhooks_test.exs` (`describe "moduledoc states R-Co's webhooks.zig was not
inspected ..."`, using `Code.fetch_docs/1`), which asserts on `"webhooks.zig"`,
`"not inspected"`, `"web/src/api/dlq.ts"`, and `"web/src/types/api.ts"` all being
present in the compiled moduledoc — the same moduledoc REQ-184's route lives in. No
new test forced; none was needed.

## Summary of changes made this pass

Both edits are in `test/letflow/routers/webhooks_test.exs`, `describe "REQ-184 AC2: ..."`:

1. Enhanced the existing exact-limit-cutoff test to assert delivery-id ordering of
   the surviving subset, not just its count.
2. Added four new parameterized tests for `resolve_limit/1`'s fallback branches
   (`?limit=abc`, `?limit=0`, `?limit=-1`, `?limit=5abc`), each asserting a 200
   response with all 3 seeded rows surviving (proof of fallback to the default of
   20).

Also added `test/specs/REQ-184.md` (did not previously exist), documenting every
acceptance criterion's test-case mapping and rationale across both test files, per
this project's `test_developer_guide.md` convention (see `test/specs/REQ-182.md` for
the established format this mirrors).

No existing passing test was duplicated, weakened, or removed. TEST-RUNNER has not
yet run the enhanced/added tests — that is TEST-DESIGN-VALIDATOR's and then
TEST-RUNNER's job per WF-02.
