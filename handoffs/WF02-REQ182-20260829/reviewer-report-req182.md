# REVIEWER report — REQ-182 (webhook subscriptions route layer)

Verdict: **PASS**

## 1. Idiomatic Plug/Router usage vs. `lib/letflow/routers/dlq.ex` precedent

`lib/letflow/routers/webhooks.ex` follows `Letflow.Routers.Dlq`'s idiom exactly:
`use Letflow.Api.AuthorizedRouter`, one `authz_get`/`authz_post`/`authz_patch`/
`authz_delete` macro per route with a compile-time-literal policy key, a
trailing `match _ do Response.not_found(conn) end` catch-all, private
`handle_*` functions per route, a hand-built `subscription_json/1` allowlist
(mirroring `dlq_entry_json/1`) rather than a raw `Jason.Encoder` derivation,
and the same `iso8601/1` helper shape. No ad-hoc pattern is invented where an
existing idiom applies — this is a clean structural copy of the established
router shape, appropriately adapted to `Letflow.Webhooks`' own return-tuple
contract (`:invalid_status` folding to 400, `hmac_secret_once` splice on
create only).

## 2. Supervision

No process/supervision changes in this diff — it is a stateless Plug router
mounted via `forward/2` in `Letflow.Plugs.ApiPipeline`, same as every other
router under `lib/letflow/routers/`. No singleton, no unsupervised `spawn`,
no shared mutable state introduced. N/A concern, correctly so.

## 3. Type-safety gaps

None found beyond what already exists upstream in `Letflow.Webhooks` (already
reviewed under REQ-181). The router's own code is a thin, exhaustively
pattern-matched translation layer over that module's `@spec`s — no new class
of runtime-only-detectable invalid state is introduced here.

## 4. Scope creep

Confirmed via `git diff main...HEAD --stat`: the diff touches exactly
`lib/letflow/routers/webhooks.ex` (new), one added clause in
`lib/letflow/api/authorization.ex` (the `PATCH` `endpoint_policy_key` clause,
explicitly in-scope per the design's §4.3 "gap this design found"), one added
`forward` line in `lib/letflow/plugs/api_pipeline.ex`, plus handoff/design
docs. `lib/letflow/webhooks.ex`, `lib/letflow/webhooks/subscription.ex`, and
`lib/letflow/dlq.ex` are untouched. No REQ-176/177/178/181 test files are
touched by ELIXIR-DEV's commits (the one test file I touched myself,
`test/letflow/webhooks_test.exs`, is the disclosed stale-assertion fix, done
under this gate per the same precedent TEST-DESIGN-VALIDATOR set for REQ-176's
AC6 test on REQ-178 — see item 6 below). No abstractions ahead of what REQ-182
needs — no new behaviour/macro, no framework machinery beyond the router
this requirement's own route table calls for. §4.4 of the design (whether to
register `Webhooks` in `authorization_enforcement_test.exs`) was left
unresolved as an explicit open question, consistent with `Dlq` itself not
being registered there either — not scope creep, and not silently decided
either way.

## 5. Decision-record consistency

- `docs/migration/decisions/0003-ecto-schema-strategy.md` Decision B
  (schema-per-tenant): respected — every handler's only tenant input is
  `conn.assigns.scoped_opts`, nothing new introduced here (inherited from
  REQ-181's context module, verified directly in the code).
- `docs/migration/decisions/0013-authorization-role-set.md`: the new PATCH
  `endpoint_policy_key` clause maps to the same `:WebhookSubscriptionsManage`
  → `:WebhooksManage` chain already on record; no new permission atom, no new
  `role_allows?/2` clause — consistent with the existing matrix, not a
  quiet re-decision.
- No framework-choice (Plug vs. Phoenix) question is touched by this diff;
  nothing here conflicts with `0001-web-framework.md`.

## 6. Design-vs-implementation fidelity

Checked `lib/letflow/design/req182-webhooks-routes.md` line-by-line against
the shipped router:

- Route table (§2): all four routes match exactly (mount `/webhooks`, local
  patterns `/subscriptions` and `/subscriptions/:id`, same policy key).
- §3.1–§3.4 result-mapping tables: implemented exactly, including
  `:invalid_id` folding into `Response.not_found/1` for both PATCH and
  DELETE (not a 400), and `:invalid_status` correctly *not* folding into 404.
- §4.3 PATCH-clause fix: present, same file/location the design specifies,
  same policy key, no new permission atom — matches.
- §5 allowlist: `subscription_json/1`'s 10 keys match the design's table
  exactly; `secret_hash`/`hmac_secret_once`/`tenant_id`/`__meta__` never
  emitted except the one documented POST-create splice, verified by reading
  the code directly (not the moduledoc's claim about itself).
- §7 moduledoc requirements: the shipped moduledoc contains all five required
  sections (contract-source disclosure, authorization, cross-tenant-404,
  response allowlist), matching `Dlq`'s own moduledoc structure section for
  section.

No divergence found between design and implementation.

## 7. Disclosed issue: stale `test/letflow/webhooks_test.exs` AC6 assertion

Confirmed the diagnosis SECURITY-REVIEWER flagged: the test
`"no router file for webhooks exists anywhere in lib/letflow/routers"` was a
REQ-181-era structural check whose premise (webhooks has no router) REQ-182
intentionally and correctly falsifies. Same class as REQ-176's AC6 test
breaking on REQ-178 (`docs/anti-patterns.md`).

Fixed in-scope, same way TEST-DESIGN-VALIDATOR fixed REQ-176's AC6 test on
REQ-178 (`test/letflow/dlq_test.exs`'s own AC6 describe block was the
precedent followed verbatim):

- Removed the `"no router file for webhooks exists anywhere..."` test
  entirely (its premise is now false by design, not a bug).
- Kept and retitled the describe block to "Letflow.Webhooks core itself has
  no route or controller-shaped constructs" — the narrower, still-true claim
  that `lib/letflow/webhooks.ex` and `lib/letflow/webhooks/subscription.ex`
  themselves are pure context/schema modules with no `use Plug.Router`, no
  controller `use`, no route macro. Added a `NOTE:` comment explaining the
  history, mirroring `dlq_test.exs`'s own note.
- Updated the module's top-of-file moduledoc note (previously "There is no
  route/controller for `Letflow.Webhooks` yet") to reflect that
  `lib/letflow/routers/webhooks.ex` now exists, while clarifying this test
  file still exercises the context module directly.
- This is a real, still-enforced check (not a no-op) — it will fail if
  someone later adds `use Plug.Router` or a route macro directly inside
  `lib/letflow/webhooks.ex`/`subscription.ex`, which is exactly the invariant
  REQ-181's scope actually required.

Verified with a real run:

```
$ mix test test/letflow/webhooks_test.exs
...
Finished in 9.9 seconds (0.00s async, 9.9s sync)
Result: 13 passed
```

`mix compile --warnings-as-errors` also passes clean with no output.

## Disposition on SECURITY-REVIEWER's judgment question

The stale test needed fixing now, as part of this gate, not deferred to
TEST-DESIGNER/TEST-RUNNER — same precedent as REQ-178/REQ-176: a
known-false assertion left in the suite would otherwise fail
TEST-RUNNER's full run for a reason unrelated to REQ-182's own correctness.
Fixed here; TEST-DESIGNER can build REQ-182's own HTTP-layer coverage on a
green baseline.
