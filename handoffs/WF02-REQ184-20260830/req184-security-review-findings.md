# REQ-184 SECURITY-REVIEWER findings (WF-02 Step 2c)

**Verdict: PASS**

**Diff scope confirmed** (`git diff main...HEAD --name-only`): only
`lib/letflow/webhooks.ex`, `lib/letflow/routers/webhooks.ex`, two test files
(`test/letflow/webhooks_test.exs`, `test/letflow/routers/webhooks_test.exs`),
the design doc, three handoff files, `handoffs/registry.json`, and
`docs/status/requirement_status.{index,v7}.yaml`. No `authorization.ex`
change, no migration, no schema change.

## INV-1 (tenant data isolation) — APPLIES, PASS

`list_delivery_attempts/3` (`lib/letflow/webhooks.ex:637-651`) queries
`Delivery` filtered by `subscription_id`, executed via
`Repo.all(query, prefix: prefix)` — schema-per-tenant scoping (Decision B),
same idiom as `list/1`. Confirmed live: the actual test run's debug log shows
the generated SQL hitting `"tenant_<uuid>"."webhook_delivery_attempts"`, not
`public`. `tenant_id` on `Delivery` is written only by `deliver/3` (REQ-183,
unchanged here), derived from `subscription.tenant_id`, never caller-supplied
in this diff's code path (this route never writes).

## INV-2 (server-side field allowlist) — APPLIES, PASS

Verified `delivery_json/1` (`lib/letflow/routers/webhooks.ex:304-317`) against
the full `Letflow.Webhooks.Delivery` schema
(`lib/letflow/webhooks/delivery.ex:26-38`). Schema has 11 fields: `id`
(primary key), `tenant_id`, `delivery_id`, `subscription_id`, `event_type`,
`status`, `http_status_code`, `attempted_at`, `attempt_count`, `max_attempts`,
`last_error`. `delivery_json/1` emits exactly 9: `delivery_id`,
`subscription_id`, `event_type`, `status`, `http_status_code`,
`attempted_at`, `attempt_count`, `max_attempts`, `last_error` — a hand-built
map literal, never `Jason.Encoder` derivation. `tenant_id` and the row's own
primary key `id` (distinct from `delivery_id`) are both absent, confirmed by
inspection of the map literal. No signing/retry-internal fields exist on this
schema to leak (no raw request/response body, no HMAC key material — those
live in `Letflow.Secrets`/the dispatch closure, never persisted on
`Delivery`).

## INV-3 (sandboxing) — NOT-APPLICABLE (S5 not started)

## INV-4 (secrets by reference only) — APPLIES, PASS

```
grep -rn "System.get_env" config/ lib/ --include=*.ex --include=*.exs   # unaffected by this diff
grep -rniE "(password|secret|client_secret|token)\s*(=|:)\s*\"[^\"]{8,}" lib/letflow/webhooks.ex lib/letflow/routers/webhooks.ex
```
Zero hits in the changed files. This diff touches no secret-resolution code
(`deliver/3`'s HMAC signing is untouched, REQ-183 territory) — the new read
path never resolves or emits `secret_ref`/`secret_key_id`/plaintext.

## INV-5 (not-found/forbidden indistinguishability) — APPLIES (route-layer
lookup-by-ID against tenant-scoped data), PASS

Read `list_delivery_attempts/3`'s use of the private `get/2` helper
(`lib/letflow/webhooks.ex:657-672`): `Ecto.UUID.cast/1` first
(`{:error, :invalid_id}`, no DB round-trip for a malformed id), then
`Repo.get(Subscription, id, prefix: prefix)` — a subscription that exists
only in a foreign tenant's Postgres schema and one that doesn't exist
anywhere are both simply invisible to this query and both yield `nil` →
`{:error, :not_found}`. This is genuinely tenant-scoped (by schema prefix,
not merely `subscription_id` alone) — a real subscription id belonging to
tenant B queried under tenant A's `prefix` cannot resolve, because Postgres
itself has no such row in tenant A's schema. `handle_deliveries/2`
(`lib/letflow/routers/webhooks.ex:223-237`) folds both `{:error, :not_found}`
and `{:error, :invalid_id}` to `Response.not_found/1` — no `400` branch, no
`403` branch for this case.

Read the AC4 test itself (`test/letflow/routers/webhooks_test.exs:525-541`):
it provisions **two real, distinct tenant schemas**
(`TenantFixture.provisioned_tenant!/1` — real Postgres schema provisioning,
not a stub), creates a real subscription in tenant B, inserts a real delivery
attempt row for it, then probes from tenant A (with `PLATFORM_ADMIN`, so
authorization is not the reason for the 404) using tenant B's real
subscription id, and asserts `404`. This is the genuine cross-tenant scenario,
not a weaker proxy (e.g. not merely "nonexistent id returns 404" — that is
covered separately by the distinct AC5 tests at lines 543-566, which check
"never existed" and "malformed" as two more cases). Ran this test for real (it
is part of the 39/39 passing run below) — confirmed passing.

Also confirmed the ordering/short-circuit property INV-5 cares about: step 1
(`get/2`, subscription existence) runs and fails **before** step 2 (the
`Delivery` query) ever executes — a foreign-tenant id never reaches the
delivery-attempts query at all, so the AC4 test's "regardless of whether that
subscription has delivery attempts" holds structurally (the delivery-row
insert for tenant B is irrelevant to the result — it never gets queried).

## INV-6 (new data-access paths prove their scoping) — APPLIES, PASS (this document)

## INV-7 (no SQL string interpolation) — APPLIES, PASS

```
grep -rn "Repo.query" lib/ priv/repo/migrations/ --include=*.ex --include=*.exs
```
No hits at all in the repo (this diff adds none). All query construction is
via `Ecto.Query` macros (`where/3`, `order_by/3`, `limit/2`), parameterized by
construction.

## INV-8 (no unhandled crashes on realistic failure paths) — APPLIES, PASS

```
grep -n "^\s*{:ok, .*} = " lib/letflow/webhooks.ex lib/letflow/routers/webhooks.ex
```
One hit, `lib/letflow/routers/webhooks.ex:143` (`handle_list/1`'s
`{:ok, subscriptions} = Webhooks.list(...)`) — confirmed via
`git diff main...HEAD -- lib/letflow/routers/webhooks.ex` that this line is
**pre-existing** (REQ-182), not touched by this diff; `list/1`'s own spec
returns only `{:ok, _}` unconditionally, so it is not a realistic-failure
crash risk and is out of this review's scope. The new code in this diff
(`handle_deliveries/2`, `resolve_limit/1`, `list_delivery_attempts/3`) uses a
`case`/`with` on every external-input-touching call and has no bare
`{:ok, _} =` match on a call that can fail on tenant-controlled input.

`resolve_limit/1` (`lib/letflow/routers/webhooks.ex:241-248`) specifically:
takes `conn.query_params["limit"]` (`nil` or `String.t()`), pattern-matches
`is_binary(raw)` first — a non-string is impossible from Plug's query-string
parsing regardless, and the second clause (`resolve_limit(_other)`) defaults
safely even so. For a binary, `Integer.parse/1` is used (never `String.to_integer/1`,
which would raise on non-numeric input) — `{value, ""}` requires the *entire*
string to parse as an integer with `value > 0`, otherwise falls back to the
default `20`. Confirmed this handles: non-numeric (`Integer.parse` returns
`:error` → falls to `_other` → default), negative (`value > 0` guard fails →
default), zero (same), trailing garbage e.g. `"5abc"` (`{5, "abc"}`, `""` guard
fails → default), and a very large numeric string (parses fine as an
arbitrary-precision Elixir integer — no overflow risk — and is then used
directly as `Ecto.Query.limit/2`'s bound, i.e. a large but syntactically valid
integer is passed straight to Postgres's `LIMIT` clause). This is a bounded
resource-exhaustion consideration, not a crash risk: an absurdly large
`?limit=99999999999` does not crash the process (it is a plain, valid
`LIMIT` value Postgres itself will cap at the actual row count for this one
subscription — no unbounded fan-out, no join, no cross-tenant scan, and the
result set size is capped by the number of delivery-attempt rows that
subscription actually has). No `400`/rejection of an oversized limit exists,
but no acceptance criterion or existing codebase idiom (see `dlq.ex`,
`tasks.ex`) requires one either, and the query itself cannot be induced to
scan more than one subscription's own row set — flagging as a stylistic
inconsistency worth REVIEWER's awareness (an upper clamp, e.g. `min(limit,
500)`, would be a defensive improvement) but not a BLOCKER: it is not itself
an injection surface (parsed to a native integer, never interpolated into SQL
text) and not a crash surface (`Integer.parse/1` never raises).

## Real verification run (not trusted from ELIXIR-DEV's report)

```
mix compile --warnings-as-errors   # exit 0, no output
mix format --check-formatted       # exit 0
grep -n "Repo\.\|Ecto.Query" lib/letflow/routers/webhooks.ex   # zero matches (INV-RT-1)
MIX_ENV=test mix test test/letflow/webhooks_test.exs test/letflow/routers/webhooks_test.exs
# Result: 39 passed, 0 failed
mix letflow.lint_handoffs
# letflow.lint_handoffs: OK -- 0 new violations across 1508 handoff files
```

Also confirmed via the real test run's SQL debug log that the delivery query
executes as
`... FROM "tenant_<uuid>"."webhook_delivery_attempts" AS w0 WHERE
(w0."subscription_id" = $1) ORDER BY w0."attempted_at" DESC,
w0."attempt_count" DESC LIMIT $2` — schema-qualified, parameterized,
database-level `LIMIT`, matching the design exactly.

## Carried forward for REVIEWER

1. **`fetch_query_params/1` fix.** ELIXIR-DEV found and fixed a real bug: the
   design's own text (§4) assumed `conn.params["limit"]` was already
   populated by Plug's query-string parsing, but this router's pipeline
   (`Letflow.Api.AuthorizedRouter`, `use Plug.Router`) never calls
   `fetch_query_params/1`, so `conn.params["limit"]` was always `nil`. Fixed
   by calling `fetch_query_params(conn)` and reading
   `conn.query_params["limit"]`, matching the established idiom in
   `dlq.ex`/`tasks.ex`/`definitions.ex`. Documented in the router's moduledoc.
   No security concern — this is a correctness fix that makes the feature's
   `limit` parameter actually functional; REVIEWER should confirm it's a
   faithful, non-scope-creeping fix (idiom-consistency judgment, REVIEWER's
   territory, not SECURITY-REVIEWER's).
2. **Ordering choice (design's own OQ-2).** `[desc: attempted_at, desc:
   attempt_count]` is the design's own undictated choice (no AC requires a
   specific order) — flagged for REVIEWER per the design's own request, no
   security implication.
3. **Stylistic note (not a BLOCKER, see INV-8 above):** `resolve_limit/1` has
   no upper clamp on a caller-supplied `limit`. Not a security defect (no
   injection, no crash, no cross-tenant reach) but worth REVIEWER's
   awareness as a possible idiom-consistency/defensive-programming
   improvement.

## Summary

All eight invariants assessed. INV-3 NOT-APPLICABLE (S5 not started). INV-1,
INV-2, INV-4, INV-5, INV-6, INV-7, INV-8 APPLY and PASS. No BLOCKER found.
Routing to REVIEWER (WF-02 Step 2d).
