# SECURITY-REVIEWER findings — REQ-200 (timeline actor display names/descriptions, WF02-REQ200-20260830)

**Verdict: PASS.** No BLOCKER found. Routing to REVIEWER (step-02d).

## Scope test

`git diff main...HEAD --stat` confirms scope is exactly: `lib/letflow/instances.ex`,
`lib/letflow/routers/instances.ex`, `test/letflow/routers/instances_test.exs`, the
design doc, plus handoff/registry/status-index bookkeeping. No file under `web/`. No
migration. `lib/letflow/api/authorization.ex` not touched. This is a tenant-data path:
response-shaping code for a tenant-scoped entity (instance timeline items) plus a new
lookup-by-actor-id query — reviewed substantively, not waved through.

## Independent verification performed (not trusting ELIXIR-DEV's report)

1. `mix compile` — ran directly, no output, clean.
2. `mix format --check-formatted` — ran directly, no output, clean.
3. `mix test test/letflow/routers/instances_test.exs` — ran directly: `Result: 40
   passed`. Matches the report.
4. `mix letflow.lint_handoffs` — ran directly: `OK -- 0 new violations across 1520
   handoff files (25 pre-existing grandfathered, traced to ISS-0190)`. Matches the
   report.
5. Read the full `git diff main...HEAD -- lib/letflow/instances.ex
   lib/letflow/routers/instances.ex` end to end myself, not the design doc's paraphrase.
6. `grep -n "Repo.query" lib/letflow/instances.ex lib/letflow/routers/instances.ex` and
   the INV-4 secret-literal heuristic grep against both files — zero hits on both.

## Point-by-point findings (per the dispatching agent's specific asks)

### 2. The flagged cross-tenant risk in `fetch_display_names_by_actor_id/2` — traced concretely

`Letflow.Identity.User`'s schema module (`lib/letflow/identity/user.ex`) moduledoc and
`docs/migration/decisions/0006-identity-tables-schema-per-tenant.md` §D1 confirm `users`
is a **per-tenant-schema table** (shipped, not provisional) — it has no `tenant_id`
column at all (dropped per Decision 0006 D2, since the Postgres schema itself already
identifies the tenant; retaining it would have been redundant). So the relevant question
isn't "does a `tenant_id` predicate filter correctly" but "is the query issued against
the correct Postgres schema."

Read `fetch_display_names_by_actor_id/2`'s real code (not the design doc's paraphrase):

```elixir
defp fetch_display_names_by_actor_id(actor_ids, prefix) do
  query = from(u in User, where: u.id in ^actor_ids, select: {u.id, u.display_name})
  query |> Repo.all(prefix: prefix)
  |> Enum.reduce(%{}, fn {id, display_name}, acc -> ... end)
end
```

`prefix` here is the exact same value threaded through every other query in
`timeline/3` — it is `timeline/3`'s own `opts[:prefix]` argument, i.e. the caller's own
tenant schema resolved upstream in the plug pipeline (`conn.assigns.scoped_opts`,
unchanged by this diff). It is not re-derived, not read from any request parameter, and
not read from the events themselves.

Concrete trace of why an `actor_id` cannot cross a tenant boundary here even under an
adversarial assumption:

- The `page` list this function's `actor_ids` are drawn from comes from `timeline/3`'s
  own event query (`where([e], e.instance_id == ^id)`, itself `Repo.all(query, prefix:
  prefix)` against the *same* `prefix`) — unchanged by this diff. `ensure_instance_exists/2`
  (also unchanged, REQ-072) already guarantees `id` names an instance inside that same
  tenant's schema, or the request 404s before this code runs at all.
- Even setting aside "where did the actor_id come from" and considering only "what can
  `Repo.all(query, prefix: prefix)` return": `prefix` fixes which Postgres schema
  `FROM users` resolves against. A UUID value that happens to equal another tenant's
  user id is irrelevant — that other tenant's row physically lives in a *different*
  Postgres schema (`tenant_<other>`.`users`, not `tenant_<this>`.`users`), which this
  query never touches. The isolation is structural (schema selection via `:prefix`), not
  incidental on actor_ids "happening" to be well-behaved.
- So both halves hold: (a) in practice, actor_ids on an instance's own event stream only
  ever originate from that tenant's own actors (users created via that tenant's own
  `Letflow.Identity` calls, which write into that tenant's own schema) or the platform
  sentinel; and (b) even in the hypothetical case of an accidental UUID collision with
  another tenant's user id, the query is schema-scoped and cannot resolve that other
  tenant's row regardless.

**No new prefix-scoping violation. No bare unscoped `Repo.all/1` — every query in this
diff passes `prefix:` explicitly, matching every other query in `Letflow.Instances`.**

### 3. Actor-fallback chain — `token_description`/`actor_label` cannot carry attacker content today, and are rendered as text even if they could

`grep -rn "token_description\|actor_label" lib/letflow/` (excluding tests) returns only
the two read sites inside `resolve_actor_display_name/3` itself — **no writer anywhere
in the codebase currently sets either metadata key**. Per the design doc's own §1 table
(verified independently by reading it), every real event writer sets `actor_id`
directly; these two fallback branches exist for parity with R-Co's `resolveActorDisplayName`
and for forward-compatibility, but are dead in practice today. There is therefore no
live path today by which either key carries tenant/attacker-controlled content.

Independent of that: even if a future writer populated `event.metadata` from
tenant-controlled input, the consumer is the SPA. Read
`web/src/components/instances/TimelineFeedItem.tsx` directly — `entry.actor_display_name`
is passed as a prop to `ActorAvatar` and through `getTimelineActorDisplayName`, and
`entry.description` is rendered as `{entry.description}` inside JSX. Neither is a
`dangerouslySetInnerHTML` sink; React escapes JSX text-content interpolation by
construction. No injection vector today, and the render path wouldn't be one even if
these fields carried adversarial strings.

### 4. `render_description/3` — no cross-instance/cross-tenant data in any sentence

Read all 7 typed clauses plus the fallback. Every placeholder is one of: `actor` (from
§2's resolution, itself scoped as per point 2), or a `payload` key read via
`Map.get(payload, ...)` where `payload` is `event.payload` for *this specific event*,
already scoped to this instance/tenant by the unchanged upstream query
(`instance_id == ^id`, `prefix: prefix`). `SUB_PROCESS_COMPLETED`'s
`child_instance_id` is the literal id already stored in this event's own payload by the
existing writer (`sub_process.ex:1203`, unchanged) — it is emitted as an opaque id
string in the sentence, not used to trigger any further lookup/query in this diff. No
clause issues a query, joins another table, or reads any field outside `event`/`payload`
that isn't already tenant-scoped by the row itself having been returned from the
existing tenant-scoped query.

### 5. Generic fallback for Lua-emitted `event_type` strings — not an injection vector

`"Event #{event_type} by #{actor}"` interpolates `event_type` (a tenant's own
Lua-script-chosen string, per the design doc §1's note on `do_emit_event/3`'s
open-ended `event_type`) directly into the description. Confirmed this reasoning
explicitly:

- It's Elixir string interpolation into a `String.t()` field of a JSON response body —
  not SQL, not a shell command, not an HTML template with an unescaped sink. There is no
  second interpretation layer this string is fed into anywhere in this diff.
- The JSON response is consumed by the SPA exactly as in point 3 — rendered as JSX text
  content, auto-escaped by React, never `dangerouslySetInnerHTML`.
- The content is the *authoring tenant's own* data (their own script's own chosen event
  name), rendered back only to that same tenant's own timeline view (gated by the
  unchanged `:InstancesRead` authz check and `ensure_instance_exists/2`'s tenant scoping)
  — there's no cross-tenant exposure even in principle, only a tenant potentially
  choosing to render odd text into their own UI, which is not a security boundary this
  invariant set protects.

**Confirmed: no injection vector, and the risk if any is confined to the authoring
tenant's own view of their own data.**

## INV-1..INV-8 gate check

- **INV-1 (tenant data isolation)** — APPLIES (live, S1/S2 done). New query
  (`fetch_display_names_by_actor_id/2`) added against `Letflow.Identity.User`, a
  per-tenant-schema table (Decision 0006 D1). (a) Confirmed scoped via
  `Repo.all(query, prefix: prefix)` — no bare unscoped `Repo.all/1`. (b) No migration in
  this diff; `users`' existing migration already places it correctly per-tenant-schema,
  untouched here. (c) `users` carries no `tenant_id` column at all (dropped per 0006 D2)
  so (c)'s caller-supplied-vs-derived concern doesn't arise for this table. **PASS** —
  see point 2 above for the full trace.
- **INV-2 (server-side field authorisation)** — NOT-APPLICABLE. Still pre-S4 per the
  invariants doc's own stated gating; no multi-tenant API surface concept beyond what's
  already live is being introduced by this change's field additions (they're plain
  server-computed strings added to an already-authorized response, not a new
  visibility/authorization dimension).
- **INV-3 (untrusted runtime sandboxing)** — NOT-APPLICABLE. S5 not started; this diff
  reads already-recorded Lua-emitted event data, it does not touch the Lua sandbox
  itself.
- **INV-4 (secrets by reference only)** — APPLIES (live) but no secret-resolution code
  touched. Both prescribed greps run against the diffed files: zero hits.
- **INV-5 (not-found/forbidden indistinguishability)** — NOT-APPLICABLE per the
  invariants doc's own stated gating (S4 not started), though as extra diligence:
  confirmed by reading the diff that `ensure_instance_exists/2` and the 404 mapping
  (`render_page_result/3`) are byte-for-byte untouched — REQ-072's cross-tenant 404
  behavior has zero risk of regression from this diff.
- **INV-6 (new data-access paths prove their scoping)** — APPLIES as the meta-invariant
  this handoff discharges. This report is the explicit statement of which invariants
  apply and why, per INV-6's own requirement, for the one genuinely new data-access path
  in this diff (`fetch_display_names_by_actor_id/2`).
- **INV-7 (no SQL string interpolation)** — APPLIES (live), satisfied. The new query is
  pure `Ecto.Query` composition (`from/2`, `where`, `select`) passed to `Repo.all/2` —
  no `Repo.query`/`Ecto.Adapters.SQL.query` anywhere in this diff (grep confirms zero
  hits in both changed files).
- **INV-8 (no unhandled crashes on realistic failure paths)** — APPLIES (live),
  satisfied. `resolve_actor_display_name/3` is a total function over all four
  input-combination branches (`cond` with a final `true ->` catch-all, never raises).
  `render_description/3`'s trailing catch-all clause (`%Event{event_type: event_type}`)
  matches any string, so an unrecognised/open-ended Lua-emitted `event_type` cannot hit
  a `FunctionClauseError` (this is exactly AC5's structural requirement, verified
  present in the actual code, not just the design doc's claim that it exists). No new
  bare `{:ok, x} =` pattern was introduced by this diff.

## Overall verdict: PASS

No BLOCKER on any applicable invariant. Substantive review of points 2-5 (cross-tenant
actor lookup trace, fallback-chain content sourcing, per-event-type description scoping,
generic-fallback injection risk) found no defect. Routing to REVIEWER per WF-02 Step 2d.
