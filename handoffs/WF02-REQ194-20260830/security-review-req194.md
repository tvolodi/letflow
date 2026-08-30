# SECURITY-REVIEWER report — REQ-194 (Prometheus Metrics Subsystem)

**Verdict: PASS**

Run: WF02-REQ194-20260830, Step 2c. Diff reviewed: `git diff main...HEAD` (26 files,
+2417/-247). Design read in full: `lib/letflow/design/req194-prometheus-metrics.md`.

## Scope test

Applies: this diff adds a new global HTTP route (`GET /metrics`), touches
tenant-scoped read paths (`Letflow.Engine.count_instances_by_status/1` inside
`poller.ex`, `Letflow.Definitions.get_by_id/2` inside `engine.ex`), and adds a new
direct `mix.exs` dependency. Hard gate applies.

## INV-1..INV-8 disposition

- **INV-1 (tenant data isolation) — APPLIES, PASS.** The only tenant-scoped reads
  touched are `Letflow.Engine.count_instances_by_status(prefix: schema_name)`
  (`poller.ex`, pre-existing function, called per-schema, correctly `:prefix`-scoped)
  and `Letflow.Definitions.get_by_id(definition_id, prefix: prefix)` (`engine.ex`,
  pre-existing function). Neither is a new schema/migration. Both results are reduced
  to non-identifying values (a count folded into a platform sum; a `status` atom)
  before ever leaving the tenant-scoped read — no tenant_id/definition_id/instance_id
  crosses into the global metrics registry at any point. Confirmed by reading
  `lib/letflow/metrics/registry.ex` end to end (see below) — this is the load-bearing
  check for this whole review.
- **INV-2 (server-side field auth)** — NOT-APPLICABLE (S4 not started; also no
  tenant-scoped API response shaping here — this is a global, non-tenant metrics body).
- **INV-3 (sandboxing)** — NOT-APPLICABLE (S5 not started; no scripting/plugin surface
  touched).
- **INV-4 (secrets by reference)** — APPLIES, PASS. No secret material anywhere in
  this diff. `grep -rniE "(password|secret|client_secret|token)\s*(=|:)\s*\"[^\"]{8,}"`
  over the changed files: no hits. No connection strings, no config values touched.
- **INV-5 (not-found/forbidden indistinguishability)** — NOT-APPLICABLE (S4 not
  started; no lookup-by-ID endpoint added — `/metrics` takes no ID parameter).
- **INV-6 (new data-access paths prove scoping)** — APPLIES, PASS. This report is that
  proof: `GET /metrics` is a new data-access path: it is *deliberately* not
  tenant-scoped, and its safety argument (the label-allowlist invariant) is verified
  below rather than assumed.
- **INV-7 (no SQL string interpolation)** — APPLIES, PASS.
  `grep -rn "Repo.query" lib/letflow/metrics lib/letflow/plugs/http_metrics.ex
  lib/letflow/routers/metrics_exposition.ex lib/letflow/scheduler/poller.ex
  lib/letflow/engine.ex lib/letflow/event_store.ex` → zero hits. Family 4's SQL-keyword
  parsing (`query_type_from_sql/1` in `registry.ex`) reads text Ecto already produced,
  does string inspection only (`String.trim_leading/1`, `String.split/2`,
  `String.upcase/1`), never builds or executes SQL, and the raw SQL text itself is
  discarded immediately (mapped to one of 5 fixed enum values, never stored or
  exposed).
- **INV-8 (no unhandled crashes on realistic failure paths)** — APPLIES, PASS. See
  items 3 and 4 below for the two new failure-isolation call sites
  (`emit_task_completed_telemetry/2`, `fetch_tenant_schemas/0` +
  `count_active_for_schema/1`). `grep -n "^\s*{:ok, .*} = "` over all new metrics/plug
  modules: zero hits. `:telemetry.span/3` in `event_store.ex` re-raises/returns the
  wrapped function's own result unchanged — no new failure mode introduced there.

## Item 1 — new direct dependency `{:telemetry, "~> 1.4"}`

Confirmed: `git diff main...HEAD -- mix.lock` is empty. `mix.exs` diff is +12/-0
(entirely a comment plus the one dependency line). This is a promotion of an
already-resolved transitive dependency (pulled in today via bandit/db_connection/
ecto/ecto_sql/plug at the same v1.4.2), not a new fetch, new transitive tree, or new
license surface (Apache-2.0, already accepted transitively).

**SECURITY-REVIEWER sign-off: GRANTED.** No new attack surface — `:telemetry` is a
pub/sub primitive with no I/O, no network, no file access; first-party code now calls
it directly instead of relying on an implicit transitive presence, which is a
hygiene improvement, not a risk increase. Recorded per REQ-194 AC3's own
no-size-exception requirement. REVIEWER (Step 2d) still owes its own sign-off on this
line per the same AC3 — carried forward below, not treated as satisfied by this
review alone.

## Item 2 — label-allowlist invariant (the load-bearing check)

Read every `handle_*`/`dispatch` clause in `lib/letflow/metrics/registry.ex` in full,
line by line, not summarized:

- `handle_task_completed/3` (family 2, `letflow_task_completions_total`): guarded by
  `when status in [:draft, :active, :deprecated, :archived]` — pattern-matches
  `%{definition_status: status}` and rejects (falls through to the catch-all `:ok`
  no-op clause) anything else. The ONLY label extracted is
  `%{definition_status: Atom.to_string(status)}`. There is no code path in this
  function that can read `definition_id`, `tenant_id`, or any other metadata key —
  the function signature only ever destructures `definition_status` out of `metadata`.
  Confirmed this matches the design's explicit restatement decision (never
  `definition_id`, never a definition name).
- `handle_event_append_stop/3` (family 3): `observe_histogram(:event_append_duration_seconds,
  %{}, duration)` — empty label map, hard-coded. No metadata is read at all beyond
  `measurements.duration`.
- `handle_repo_query/3` (family 4): the only metadata key ever read is `:query` (raw
  SQL text), and it is passed through `query_type_from_sql/1`, which reduces it to one
  of five fixed strings (`select|insert|update|delete|other`) — the raw SQL string
  itself is never stored as a label value or anywhere else. No `:source`/`:repo`/other
  metadata keys (which Ecto's telemetry event does carry, per the design's own §0
  evidence) are ever read by this handler.
- `handle_http_request/3` (families 5/6): reads exactly three metadata keys —
  `:method`, `:route_template`, `:status` — via `Map.fetch!/2` (so a missing key raises
  rather than silently emitting something else; acceptable since this module's own
  only caller, `Letflow.Plugs.HttpMetrics`, always supplies all three). `route_template`
  is never the raw request path (verified in item 3 below). No other metadata key is
  read.
- Family 1 (`set_active_instances/1`, `mark_active_instances_refresh_failed/0`): takes
  a bare `count :: non_neg_integer()` argument, no metadata/labels at all — cannot
  carry an identifier by construction.
- `snapshot/0`, `incr_counter/3`, `observe_histogram/3`, `get_row/2`: pure read/ETS
  plumbing over the label maps already built by the `handle_*` functions above — they
  do not introduce any new key extraction from raw event data.

**Conclusion: the label-allowlist invariant holds.** No metric family, anywhere in
this module, can ever emit a `tenant_id`, `instance_id`, `definition_id`, `task_id`,
or `actor_id` value as a label. Every label-producing function names its allowed keys
literally in its own function head/pattern match — this is a structural property of
the code, not a runtime promise.

`lib/letflow/plugs/http_metrics.ex`'s route-template labeling: `resolve_route_template/1`
either returns `Plug.Router.match_path(conn)` (a compile-time route template, e.g.
`"/api/v1/instances/:id"` — never a resolved path segment) or the literal constant
`"unmatched"`. Confirmed no code path in this module can pass a raw request path
through to the label — `conn.path_info`/`conn.request_path` are never read anywhere in
this file.

## Item 3 — `conn.private[:plug_route]` correction and the `"unmatched"` fallback

Verified ELIXIR-DEV's correction against the real `deps/plug/lib/plug/router.ex`
source directly:

- Line 663-664: `extract_path({:_, _, var}) when is_atom(var), do: "/*_path"` —
  confirms a bare `match _` catch-all clause's path is rewritten to the literal string
  `"/*_path"` at compile time, not left unset.
- Line 520: `Plug.Conn.put_private(conn, :plug_route, {append_match_path(conn, path), fun})`
  inside `__route__/4`'s expansion — confirms this happens for EVERY match clause,
  including the rewritten catch-all, so `:plug_route` is always set once any `match`
  clause (explicit or catch-all) has fired.
- Lines 523-527: `append_match_path/2` prepends the base path when nested inside a
  `forward`, so a catch-all inside a forwarded sub-router composes to e.g.
  `"/api/v1/*_path"`, not a bare fragment.
- Line 325-326: `match_path/1` does `Map.fetch!(conn.private, :plug_route)` — this
  would raise `KeyError` only if `:plug_route` were genuinely absent, which per the
  above is unreachable through `Letflow.Router`'s own structure (every router in this
  tree, including `Letflow.Routers.MetricsExposition` and `Letflow.Plugs.ApiPipeline`'s
  sub-routers, ends in a `match _` catch-all).

ELIXIR-DEV's correction is accurate: `:plug_route` is always set, `match_path/1` never
raises on this router tree, and the literal value on an unmatched request is
`"/*_path"` (or a forward-composed variant), not an unset private key.

**Does `"unmatched"` ever combine with something identifying?** No.
`resolve_route_template/1` in `http_metrics.ex` checks
`String.ends_with?(template, "/*_path")` and replaces the ENTIRE template with the bare
literal `"unmatched"` — it does not concatenate, prefix, or otherwise retain any part
of the composed path (e.g. it does not keep `"/api/v1/"` and append `"unmatched"` to
it, which would still leak the matched-prefix depth but not raw values; it collapses
to one single flat string regardless of forward-nesting depth). Verified by reading
the function body directly (`lib/letflow/plugs/http_metrics.ex:89-96`) — there is no
string concatenation involving `"unmatched"` anywhere in this file. Cardinality is
bounded at exactly one value for every unmatched request, platform-wide, with no
per-request or per-tenant variation possible.

## Item 4 — Poller's DB-unavailable deviation from design §6

Design §6 literal wording: "the timer poll-and-fire loop for that tick still proceeds
normally" even when `tenant_schemas()` raises. The shipped code
(`fetch_tenant_schemas/0` catching the raise, then skipping BOTH the poll-and-fire
loop and the active-instances refresh for that tick on failure, calling
`mark_active_instances_refresh_failed/0`) does not match that literal wording.

**Assessment: safe, reasonable, and correctly reasoned — not a regression, not scope
creep.** The design's own literal wording is actually incoherent on the failure path:
the poll-and-fire loop's own input IS `tenant_schemas()`'s result (`schemas`) — there
is no defined list to iterate "normally" over if the very call that produces that list
raised. ELIXIR-DEV's version is a strict improvement in crash-avoidance over a literal
reading (which would require inventing some fallback list, itself a worse choice —
either an empty list, silently skipping all tenants' ticks anyway with no visibility,
or a stale cached list, silently polling against possibly-deprovisioned schemas) while
preserving the design's actual stated intent: the Poller GenServer itself never
crashes (verified: `fetch_tenant_schemas/0` wraps the raise in a `rescue`, returns
`:error`, and `handle_info/2`'s `case` handles both branches without re-raising —
confirmed no `raise`/unhandled pattern match remains on this path), and the next tick
is still scheduled normally (`schedule_next_tick()` runs unconditionally after the
`case`, outside it). `count_active_for_schema/1`'s per-schema isolation
(`case ... rescue _ -> 0`) additionally cannot crash the Poller on a single corrupted
tenant schema. This does not need to go back to CODE-DESIGNER — it is a correct,
narrowly-scoped adaptation of an internally-inconsistent literal design sentence, and
is transparently flagged as a deviation in both the module moduledoc and this
requirement's handoff chain (not silently diverged).

## Items 5-7 — standard checks

- **Item 5 (file list):** `git diff main...HEAD --stat` matches the expected set
  exactly: new `lib/letflow/metrics/{registry,exposition}.ex`,
  `lib/letflow/plugs/http_metrics.ex`, `lib/letflow/routers/metrics_exposition.ex`;
  deleted `lib/letflow/routers/metrics.ex`; modified `router.ex`, `api_pipeline.ex`,
  `application.ex`, `engine.ex`, `event_store.ex`, `scheduler/poller.ex`, `mix.exs`;
  plus the six new/modified test files and handoff/status bookkeeping. No unexpected
  files.
- **Item 6 (auth omission is deliberate, and the only unauthenticated route change):**
  confirmed via `lib/letflow/router.ex` — `GET /metrics` is forwarded at the same tier
  as the pre-existing `/health` and `/api/tenant-config`, explicitly before the
  `/api/v1` forward, with no auth plug in its pipeline (`Letflow.Routers.MetricsExposition`
  uses bare `Plug.Router`, no `AuthorizedRouter`). This is the deliberate Axis 2/3
  design decision (design §1), not an omission — restated in three separate
  moduledocs (`router.ex`, `metrics_exposition.ex`, `registry.ex`). `git diff
  main...HEAD -- lib/letflow/router.ex lib/letflow/plugs/api_pipeline.ex` shows the
  only routing change besides the new `/metrics` mount is the REMOVAL of the old
  per-tenant authenticated `/api/v1/metrics` forward — no other route's auth posture
  changed.
- **Item 7 (DB-unavailable response never leaks internals):** `Letflow.Metrics.Exposition.render/0`
  never calls `Letflow.Repo` and never touches the DB-unavailable code path at all — it
  only reads `Registry.snapshot/0` (pure ETS). On a DB outage, families 2-6 are
  unaffected (they never touched the DB) and family 1's gauge simply keeps its
  last-known value (`mark_active_instances_refresh_failed/0` is a documented no-op —
  writes nothing, changes nothing). There is no error object, connection string, or
  exception message anywhere in the exposition path that could reach the HTTP
  response — `render/0` has no `try/rescue`/`case ... {:error, reason}` branch that
  formats an error into the body at all, by construction.

## Items carried forward to REVIEWER (Step 2d)

1. **Dependency sign-off:** `{:telemetry, "~> 1.4"}` in `mix.exs` — SECURITY-REVIEWER
   has granted its own sign-off above (promotion of an already-resolved transitive
   dependency, zero new risk surface). REVIEWER must record its own sign-off on this
   same line per REQ-194's AC3 (which draws no size-based exception) before merge.
2. **Label-allowlist invariant:** independently re-verify if REVIEWER wishes — this
   review's full line-by-line walk of every `handle_*` function in
   `lib/letflow/metrics/registry.ex` is recorded above for that purpose.
3. **`conn.private[:plug_route]` correction:** confirmed accurate against
   `deps/plug/lib/plug/router.ex` real source (see item 3) — REVIEWER may want to spot
   check the same lines for their own OTP/idiom review.
4. **Poller DB-unavailable deviation from design §6's literal wording:** assessed safe
   and reasonable by SECURITY-REVIEWER (see item 4) — REVIEWER should form its own view
   on whether this deviation needs a design-doc amendment for future-reader clarity
   (a documentation/process question, not a safety one).
