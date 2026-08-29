# SECURITY-REVIEWER report — REQ-182 (webhook subscriptions route layer)

**Verdict: PASS**

## Scope test

Diff adds a new API route (`lib/letflow/routers/webhooks.ex`), a new
`endpoint_policy_key/2` clause (`lib/letflow/api/authorization.ex`), and a new
`forward` mount (`lib/letflow/plugs/api_pipeline.ex`). This is a tenant-data
path: a lookup-by-ID handler (PATCH/DELETE `/webhooks/subscriptions/:id`),
response-shaping code for a tenant-scoped entity, and a route reading/writing
tenant-scoped data. In scope.

## INV-1..INV-8 disposition

**INV-1 (tenant data isolation) — APPLIES, PASS.**
- (a) Every `Letflow.Webhooks` function threads `opts[:prefix]` into the
  matching `Repo` call: `list/1` → `Repo.all(query, prefix: prefix)`;
  `update/3` → `fetch_and_lock_subscription/3` (`repo.one(prefix: prefix)`)
  and `apply_status_update/3` (`Repo.update(prefix: prefix)`) inside an
  `Ecto.Multi` transaction; `delete/2` → `get/2` (`Repo.get(prefix: prefix)`)
  then `Repo.delete(subscription, prefix: prefix)`; `create/2` →
  `Repo.insert(prefix: prefix)`. No default/public-schema call anywhere in
  `lib/letflow/webhooks.ex`. The router itself never constructs its own
  prefix — it only ever passes `conn.assigns.scoped_opts` through verbatim.
- (b) No migration is touched by this diff (`git diff main...HEAD --stat`
  confirms zero changes under `priv/repo/migrations/`) — `webhook_subscriptions`
  was created and reviewed under REQ-181.
- (c) `tenant_id` is derived server-side from `opts[:prefix]` via
  `TenantProvisioning.tenant_id_for_schema_name/1` inside `create/2`
  (`lib/letflow/webhooks.ex:82,87`) — `create_attrs()`'s typespec has no
  `:tenant_id` key at all, and the router's `handle_create/1` never places one
  in `attrs`. Caller cannot supply or override it.

**INV-2 (server-side field authorisation) — treated as APPLIES (see note
below), PASS.** The invariants doc's own text still says "None yet — no
multi-tenant API surface exists (S4 not started)," but that is stale in the
same way INV-1's old "not yet applicable" framing was stale before its
2026-08-17 correction: this codebase already has live multi-tenant routes
(`Letflow.Routers.Dlq`, `Tasks`, `Instances`, etc.) and this diff adds another
one. Given the task's explicit instruction to verify response shaping, I
checked it as if live rather than skip it on the doc's outdated wording, and
flag this staleness below for ORCH/doc maintenance. `subscription_json/1`
(`lib/letflow/routers/webhooks.ex:204-218`) is a hand-built map literal over
named `Subscription` struct fields — not a `Jason.Encoder` derivation, not a
post-hoc redaction. Confirmed by direct read: `secret_hash`, `tenant_id`, and
`__meta__` are not present in any of the 10 keys it builds, in `list`,
`update`, or `delete`'s response paths.

**INV-3 (untrusted runtime sandboxing) — NOT APPLICABLE.** No Lua/WASM/S5
code touched.

**INV-4 (secrets by reference only) — APPLIES, PASS.**
- `secret_hash` is never read back out of the `Subscription` struct into any
  response — confirmed absent from `subscription_json/1`'s key list.
- `hmac_secret_once` appears in exactly one place in the entire diff:
  `lib/letflow/routers/webhooks.ex:112`, spliced onto the create-response map
  inside the `{:ok, %{subscription: ..., hmac_secret_once: plaintext}}`
  branch of `handle_create/1`. It is not a `Subscription` struct field (I
  read `lib/letflow/webhooks/subscription.ex`'s schema, confirmed no such
  column/field exists), so it structurally cannot leak via `list`/`update`/
  `delete`'s calls to the same `subscription_json/1` function.
- `grep -n "Logger\|IO.inspect\|secret" lib/letflow/routers/webhooks.ex`
  shows no logging of secret material anywhere in the new router.
- No secret is threaded through a handoff file, config default, or hardcoded
  literal in this diff.

**INV-5 (not-found/forbidden indistinguishability) — treated as APPLIES (same
staleness note as INV-2), PASS.**
- `Letflow.Webhooks.update/3` and `delete/2` both resolve id validity and
  tenant membership through the identical `{:error, :invalid_id}` /
  `{:error, :not_found}` tuples (`cast_subscription_id/1` +
  `fetch_and_lock_subscription/3` for `update/3`; `get/2`'s
  `Ecto.UUID.cast/1` + `Repo.get(prefix: prefix)` for `delete/2`) — a
  malformed UUID and a real UUID belonging to another tenant's schema take
  the same code path and same DB-round-trip shape (one cast, one scoped
  fetch).
- The router (`lib/letflow/routers/webhooks.ex:140-144,165-169`) maps both
  `:not_found` and `:invalid_id` to `Response.not_found/1` — same status
  (404), same call, no differing body. `Response.not_found/1`
  (`lib/letflow/api/response.ex` moduledoc, confirmed) takes no
  detail-bearing argument, so there is no slot for a leaked existence signal.
  I did not find a `not_found/1` definition taking extra args in this diff
  or upstream that could be misused to carry detail.
- Permission checks run in the `AuthorizedRouter`/`Authorize` plug, before
  any handler or `Letflow.Webhooks` call — independent of tenant identity, so
  a same-permission caller from a different tenant reaches the handler and
  gets 404 from id-scoping, never 403. Confirmed by reading the mount order
  in `lib/letflow/plugs/api_pipeline.ex` (`AuthPipeline` → `TenantStatus` →
  `match`/`dispatch`) and `authz_patch`/`authz_delete`'s macro semantics
  (permission gate is declared at the route, evaluated before the handler
  block runs).

**INV-6 (new data-access paths prove scoping) — APPLIES, satisfied by this
report itself** (explicit statement of which invariants apply and how each
is satisfied, per real code read rather than trusted comments).

**INV-7 (no SQL string interpolation) — APPLIES, PASS.** No `Repo.query`/
`Repo.query!` anywhere in the diff; every access goes through `Ecto.Query`
composition (`Ecto.Query.from`/`order_by`/`where`/`lock`) or
`Repo.get`/`Repo.all`/`Repo.insert`/`Repo.update`/`Repo.delete`, all
parameterised by construction. `grep -rn "Repo.query" lib/letflow/webhooks.ex
lib/letflow/routers/webhooks.ex` returns nothing.

**INV-8 (no unhandled crashes on realistic failure paths) — APPLIES, PASS.**
- `lib/letflow/routers/webhooks.ex:95`, `{:ok, subscriptions} =
  Webhooks.list(conn.assigns.scoped_opts)`, is a bare match, but
  `Webhooks.list/1`'s own `@spec` (confirmed by reading
  `lib/letflow/webhooks.ex:136`) has no error branch — it always returns
  `{:ok, [Subscription.t()]}`, so this match cannot fail on any input this
  function can produce. Not a violation.
- Every other external-input path (`object_body/1`, `fetch_target_url/1`,
  `Webhooks.update/3`'s five-variant return, `Webhooks.create/2`'s two-variant
  return, `Webhooks.delete/2`'s three-variant return) is handled through
  `case`/`with` matching every documented tuple shape — confirmed exhaustive
  against each function's real `@spec` (design doc §6 cross-checks this
  independently and I re-verified it against the actual specs in
  `lib/letflow/webhooks.ex`, not just the design doc's claim).

## Note on invariants-doc staleness (not a blocker, flagged for follow-up)

INV-2 and INV-5's "Reference" sections still say "None yet — no multi-tenant
API surface exists (S4 not started)." This is inconsistent with the current
codebase (multiple live multi-tenant routes exist, including this one) and
mirrors the exact staleness pattern INV-1 had before its 2026-08-17
correction (ISS-0026/GH#84). I did not let the stale wording excuse skipping
verification — I verified both against the real diff as if live, per the
task's explicit instructions — but the doc itself should get the same kind
of correcting pass INV-1 received, so a future reviewer with a more literal
reading doesn't skip a live check.

## Known test-file staleness (not a security concern)

`test/letflow/webhooks_test.exs` still asserts "no router file for webhooks
exists anywhere in `lib/letflow/routers`" — a REQ-181-era structural
assertion this requirement intentionally falsifies by adding
`lib/letflow/routers/webhooks.ex`. Same class of issue as REQ-176's AC6 test
breaking on REQ-178 (documented in `docs/anti-patterns.md`). This is expected
test staleness, not a security defect, and does not block this PASS. Flagging
for REVIEWER/next stage to apply the same structural fix
TEST-DESIGN-VALIDATOR applied for REQ-176's AC6 test on REQ-178, before
TEST-RUNNER's full-suite run.

## Files read in full

- `lib/letflow/routers/webhooks.ex`
- `lib/letflow/api/authorization.ex` (relevant clauses: `endpoint_policy_key/2`
  lines 289-307, `required_permission/1` line 425, `role_allows?/2` lines
  450-486)
- `lib/letflow/plugs/api_pipeline.ex`
- `lib/letflow/webhooks.ex` (full context module: `create/2`, `list/1`,
  `update/3`, `delete/2`, `get/2`)
- `lib/letflow/api/response.ex` (excerpt: success/error helper contracts)
- `lib/letflow/design/req182-webhooks-routes.md`
- `handoffs/WF02-REQ182-20260829/step-02c-security-reviewer.json`
