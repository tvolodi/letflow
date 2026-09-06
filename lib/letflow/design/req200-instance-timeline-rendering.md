# REQ-200 design — Instance timeline rendering (actor display names and descriptions)

Closes the gap between REQ-080's already-shipped `GET
/api/v1/instances/:id/timeline` and the already-shipped SPA consumer
(`web/src/types/api.ts`'s `TimelineEntry`, rendered by
`web/src/components/instances/TimelineFeedItem.tsx`). Scope is limited to
what one timeline item *contains*; the route, its auth, its pagination and
its 404 behaviour are unchanged (see §5).

PROVENANCE (historical, not current decision authority):
Ports R-Co's `src/obs/timeline.zig` `resolveActorDisplayName` (L287-317)
and `renderDescription` (L320+), reshaped for Letflow's per-page N+1
avoidance requirement (R-Co does one `queryRow` per entry; this design
batches).

## 1. Real event types this codebase can append to an instance's `events` row

Verified by reading every `EventStore.append/2` call site with a literal
`event_type:` (excluding `EventStore.append_platform_event/2` call sites,
whose rows land in a separate platform-events stream, never carry an
`instance_id` that matches an instance in `instance_projections`, and are
therefore never returned by `Letflow.Instances.timeline/3`'s
`where([e], e.instance_id == ^id)` query — `DEFINITION_PROMOTED`,
`DEFINITION_VERSION_ROLLED_BACK` and `PROMOTION_ASSERTION_TEARDOWN_FAILED`
are excluded on this basis, confirmed via
`lib/letflow/event_store/platform_events.ex` and their call sites in
`lib/letflow/definitions/promotion.ex` and `lib/letflow/definitions.ex`).

The instance-scoped set, with the payload keys each writer actually sets
(all payloads are JSON-encoded maps; `payload` on the `Event` schema is
`:map`, decoded already by the time `Instances` handles it):

| `event_type` | Writer | Payload keys relevant to rendering | `actor_id` |
|---|---|---|---|
| `INSTANCE_STARTED` | `Letflow.Engine.create/2` (engine.ex:1250); also `Letflow.Engine.SubProcess` for a child instance (sub_process.ex:630) | none needed beyond actor | caller-supplied (`Map.get(attrs, :actor_id)`), may be `nil` |
| `TASK_COMPLETED` | `Letflow.Engine.complete_task/3` (engine.ex:2632) | `task_id`, `node_id` | the completing user/token |
| `INSTANCE_CANCELLED` | `Letflow.Engine.cancel_instance/3` (engine.ex:3015) | none needed beyond actor | the cancelling user/token |
| `INSTANCE_PINS_REBOUND` | `Letflow.Engine.PinRebind.rebind_pins/3` (pin_rebind.ex:469) | `reason` | the rebinding user/token |
| `SUB_PROCESS_COMPLETED` | `Letflow.Engine.SubProcess` (sub_process.ex:1203), appended on the **parent** instance | `child_instance_id` | the actor that completed the child's terminal task |
| `EXECUTION_ERROR` | `Letflow.Engine.ExecutionError.append_execution_error_event/2` (execution_error.ex:302) | `error_type`, `reason` | `error_args.actor_id` (may be the platform sentinel for system-detected errors) |
| `TIMER_FIRED` | `Letflow.Scheduler` (scheduler.ex:307) | `timer_id`, `node_id`, `timer_type` | always `Letflow.EventStore.platform_actor_id/0`, the sentinel `"00000000-0000-0000-0000-000000000002"` — **never a row in `users`**, so this is the codebase's own naturally-occurring instance of AC3's "actor id refers to a user row that no longer exists" edge case |

Additionally: `Letflow.Engine.Lua.Platform.do_emit_event/3` (lua/platform.ex,
the `emit_event(event_type, payload, idempotency_key)` script hook) lets a
tenant's own workflow script append an event under **any** `event_type`
string the script author chooses, gated only by that tenant's
`event_type_registry` (`Letflow.EventStore.Registry.validate_payload/3`).
This means the set of `event_type` values reaching `timeline_item/1` is
**not closed** to the seven above — it is open-ended per tenant. This is
exactly why AC5 (generic fallback) is not an edge case to shrug off but a
structural requirement: any renderer keyed on a fixed case list must have a
`_ -> generic` clause, never a `raise`/`FunctionClauseError` default.

Note there is no `HUMAN_TASK_*` event type anywhere in this list — grepped
for it; the only hits are module/variable names in `task_activation.ex`,
never an `event_type:` literal. `TASK_COMPLETED` is the only task-lifecycle
event actually appended.

## 2. Actor display name resolution — `resolve_actor_display_name/3`

New private function in `lib/letflow/instances.ex`:

```
@spec resolve_actor_display_name(
        actor_id :: Ecto.UUID.t() | nil,
        metadata :: map(),
        display_names_by_id :: %{optional(Ecto.UUID.t()) => String.t()}
      ) :: String.t()
```

Total function — every input combination returns a non-nil, non-blank
`String.t()`. Order, exactly as R-Co's `resolveActorDisplayName` (L287-317)
and the requirement's own §1:

1. If `actor_id` is not `nil` **and** `display_names_by_id` has a
   non-blank entry for it (populated by the batch lookup in §4 — a user row
   whose own `display_name` is `nil`/blank does not count as a hit here),
   return that entry.
2. Else if `metadata["token_description"]` is a non-blank string, return
   it.
3. Else if `metadata["actor_label"]` is a non-blank string, return it.
4. Else return the literal `"system"`.

"Non-blank" means: not `nil`, and (after `String.trim/1`) not the empty
string — mirrors `getTimelineActorDisplayName`'s own
`(actorDisplayName ?? '').trim()` blank check in
`web/src/pages/instances/timelineUtils.ts`, so a value this function would
already treat as absent server-side is never forwarded as if it were
present.

`display_names_by_id` deliberately holds **only** users found by the batch
query (§4) — an `actor_id` present in the map is a resolved hit for step 1;
an `actor_id` absent from the map (never queried because it was `nil`, or
queried and not found because the user row was deleted) falls through to
step 2, satisfying AC3 (deleted-user actor still falls through, never
errors, never returns `nil`) without `resolve_actor_display_name/3` itself
needing to distinguish "no such id" from "id not looked up" — both are
simply "absent from the map."

`metadata` is `event.metadata` (the `Event` schema's `:map` field,
default `%{}}` — already always a map, never `nil`, so no extra `nil`
guard is needed on that argument itself, only on its two keys).

## 3. Description rendering — `render_description/3`

New private function:

```
@spec render_description(
        event :: Letflow.EventStore.Event.t(),
        actor_display_name :: String.t(),
        payload :: map()
      ) :: String.t()
```

Dispatches on `event.event_type` (a `case`/multi-clause match), one clause
per real event type from §1, plus a mandatory trailing fallback clause
matching any other string (AC5). `payload` is passed separately from
`event` only so each clause can pattern-match the specific keys it needs
without repeating `event.payload` accesses; `actor_display_name` is always
the value already resolved by §2 for this event, so this function never
touches `actor_id` or `metadata` itself — it is pure string composition
given already-resolved inputs.

Per-type renderings (`{actor}` = `actor_display_name`, all other
placeholders read from `payload`):

| `event_type` | Rendered description |
|---|---|
| `INSTANCE_STARTED` | `"Instance started by {actor}"` |
| `TASK_COMPLETED` | `"Task {node_id} completed by {actor}"` — see note below on `node_id` vs. the requirement text's illustrative `{node_label}` |
| `INSTANCE_CANCELLED` | `"Instance cancelled by {actor}"` |
| `INSTANCE_PINS_REBOUND` | `"Instance pins rebound by {actor}"` |
| `SUB_PROCESS_COMPLETED` | `"Sub-process {child_instance_id} completed by {actor}"` |
| `EXECUTION_ERROR` | `"Execution error ({error_type}) reported by {actor}"` — `error_type` read from `payload["error_type"]`; falls back to the literal `"unknown"` if absent (defensive only — every real writer sets it, per §1's table) |
| `TIMER_FIRED` | `"Timer {timer_id} fired"` — deliberately does NOT append "by {actor}": the actor is always the platform sentinel (§1), so naming it would read as `"Timer ... fired by system"` on every single row, adding no information; `{actor}` is still computed (feeds `actor_display_name` in the response item) but only description text omits it for this one type |
| any other value (open-ended per §1's Lua note) | `"Event {event_type} by {actor}"` — the mandatory AC5 fallback. Non-empty, always includes the resolved actor, never raises on an unrecognised `event_type` |

**Open question flagged, not silently resolved:** the requirement's own
description text (SCOPE point 2) illustrates `"Task {node_label} completed
by {actor}"`, but no `node_label` field exists anywhere in this codebase —
not in the `TASK_COMPLETED` payload (`task_id`, `node_id`,
`output_variables`, `merged_variable_events`, `activated_nodes` — see
engine.ex's `append_task_completed_event/5`), not on any schema this
design's reading touched. `node_id` is a UUID/id-shaped value, not a
human label, so `"Task {node_id} completed by {actor}"` will render a raw
id, not a friendly name. This design uses `node_id` as the closest
available substitute rather than inventing a `node_label` lookup this
requirement never scoped (no node-definition-lookup dependency is listed
in `depends_on`, and adding one would be scope creep past OBS-04). If a
future requirement adds a node-label resolution path, `TASK_COMPLETED`'s
clause is the one to revisit.

## 4. N+1 avoidance — batched actor lookup

New private function, called once per `timeline/3` invocation (i.e. once
per page), never once per event:

```
@spec fetch_display_names_by_actor_id(
        actor_ids :: [Ecto.UUID.t()],
        prefix :: String.t()
      ) :: %{optional(Ecto.UUID.t()) => String.t()}
```

Design of `timeline/3`'s body, in the order the batching must happen (this
replaces the current single `Enum.map(page, &timeline_item/1)` line —
`lib/letflow/instances.ex` L181):

1. Run the existing query exactly as today (unchanged: same `where`,
   `filter_by_seq_cursor/2`, `order_by`, `limit`, `split_seq_page/3`) to
   get `page` (the list of `Event.t()` for this response, size ≤
   `page_size`).
2. **Pre-pass:** `Enum.map(page, & &1.actor_id) |> Enum.reject(&is_nil/1)
   |> Enum.uniq/1` — the distinct, non-nil actor ids on this page. Zero
   events with a non-nil `actor_id` yields an empty list here.
2a. If that list is empty, skip step 3 entirely (no lookup query issued at
   all) and use `%{}}` as the map in step 4 — satisfies AC7's "at most one
   lookup per distinct actor" trivially (zero is at most one) without an
   unnecessary round-trip.
3. **One query:** `Letflow.Identity.User` filtered by `where([u], u.id in
   ^distinct_actor_ids)`, `select: {u.id, u.display_name}`, `prefix:
   prefix` (the same `prefix` `timeline/3` already threads through
   everywhere else — `users` is a per-tenant-schema table per Decision
   0006 D1, so this lookup must pass `prefix` exactly like every other
   query in this module, never a bare unscoped `Repo.all/1`). Reduced to a
   map keyed by id, omitting any row whose `display_name` is `nil`/blank
   (kept out of the map rather than mapped to a blank string, so §2 step 1
   correctly treats it as a miss and falls through).
4. `Enum.map(page, &timeline_item(&1, display_names_by_id))` — the
   per-item render, now taking the pre-built map instead of doing its own
   lookup.

This bounds the query count for a page to **exactly one** `SELECT ... FROM
users WHERE id IN (...)` regardless of `page_size`, or **zero** if no event
on the page carries a non-nil `actor_id` — satisfying AC7 ("at most one
lookup per DISTINCT actor... issues a bounded number of user-lookup
queries rather than one per event") without depending on Ecto/Postgres
query-plan behaviour: the boundedness is structural (one `Repo.all/2` call
site, called once per `timeline/3` invocation), not incidental.

## 5. `timeline_item/2`'s new shape and field naming decision

**Decision: rename, don't duplicate.** `created_at` → `timestamp` and
`sequence_number` → `sequence_num` are renamed outright in the timeline
response, not emitted alongside the old names.

Justification: `timeline_item/1` (soon `/2`) and `timeline_item_map/1`
(`lib/letflow/routers/instances.ex` L654) are confirmed (grep across
`lib/letflow`) to be the **only** producers/consumers of a timeline item's
map shape anywhere in the codebase — `history_item_map/1` (routers/
instances.ex, the sibling `/:id/history` handler) is a separate function
serving a separate route and is untouched by this requirement; it keeps
`created_at`/`sequence_number` as-is, since REQ-080's `/history` endpoint
is not part of OBS-04's scope and its own SPA consumer (if any) was not
cited by this requirement. Nothing else in `lib/` pattern-matches or reads
`item.created_at`/`item.sequence_number` from a `timeline/3` result, and
`web/` — the only external consumer — already expects `timestamp`/
`sequence_num` and nothing else (`TimelineEntry` in `web/src/types/api.ts`
has no `created_at` or `sequence_number` member at all). Emitting both old
and new names would mean shipping two fields the SPA never reads and no
other consumer needs, purely to preserve a compatibility contract nothing
depends on — that is dead surface, not safety. Renaming outright is the
smaller, equally-safe change.

Updated `timeline_item/2` (replaces the current `timeline_item/1`,
`lib/letflow/instances.ex` L185-196):

```
@spec timeline_item(
        event :: Letflow.EventStore.Event.t(),
        display_names_by_id :: %{optional(Ecto.UUID.t()) => String.t()}
      ) :: map()
```

Returned map's keys (internal, atom-keyed — `timeline_item_map/1` in the
router still does the atom→string JSON-shaping pass, unchanged in kind
from today):

- `event_id` — unchanged
- `event_type` — unchanged
- `sequence_num` — **renamed** from `sequence_number`; same value
  (`event.sequence_number`)
- `instance_id` — unchanged
- `timestamp` — **renamed** from `created_at`; same value
  (`event.created_at`)
- `node_id` — unchanged (`Map.get(event.payload, "node_id")`)
- `task_id` — unchanged (`Map.get(event.payload, "task_id")`)
- `metadata` — unchanged
- `actor_display_name` — **new**, from §2
- `description` — **new**, from §3

`lib/letflow/routers/instances.ex`'s `timeline_item_map/1` (L654-664)
changes in lockstep: its output keys become `"sequence_num"` (was
`"sequence_number"`) and `"timestamp"` (was `"created_at"`, still passed
through `DateTime.to_iso8601/1`), plus two new passthrough keys
`"actor_display_name"` and `"description"` (both already-formatted
strings, no further transform needed at the router layer). This is a
JSON-shaping change only — the map-building shape is a straight one-to-one
mirror of `timeline_item/2`'s new keys, same idiom already used for every
other field in that function.

## 6. Route, pagination, auth, 404, cross-tenant — confirmed unchanged

- **Route path:** `authz_get "/:id/timeline", :InstancesRead do
  handle_timeline(conn, conn.params["id"]) end` —
  `lib/letflow/routers/instances.ex` L196-198 — this design makes no edit
  to the router's route-macro lines, only to `timeline_item_map/1`'s body
  (§5) and (not needed, see below) `handle_timeline/2`'s body is also
  unchanged: it still calls `Instances.timeline(id, params, opts) |>
  render_page_result(conn, &timeline_item_map/1)` verbatim (L641), just
  with `timeline_item_map/1`'s internals changed.
- **Auth:** `authz_get` is the macro that gates on the permission atom
  argument — `:InstancesRead`, same as today, not touched.
- **Pagination:** `Pagination.parse_page_size_param/1`,
  `Pagination.validate_page_size/1`, the `@timeline_cursor_prefix "IT:"`
  keyset cursor, `filter_by_seq_cursor/2`, `order_by([e], asc:
  e.sequence_number)`, `split_seq_page/3` — none of these functions or
  call sites change. `timeline/3`'s query-building code (L166-180) is
  untouched; only the line building the response items (L181, today
  `Enum.map(page, &timeline_item/1)`) changes, per §4.
- **404:** `ensure_instance_exists/2` (L200-207, unchanged) still runs
  before the query and still returns `{:error, :not_found}` on a missing
  or cross-tenant instance id, which `render_page_result/3`
  (routers/instances.ex) still maps to `Response.not_found/1` — no change
  to either function.
- **REQ-072 cross-tenant behaviour:** enforced by `opts`'s `prefix` being
  the caller's own tenant schema (bound upstream of `handle_timeline/2`,
  in `conn.assigns.scoped_opts` — unchanged plug/pipeline) and by
  `ensure_instance_exists/2` querying `InstanceProjection` scoped to that
  same `prefix` — an instance id belonging to another tenant's schema is
  simply absent from this tenant's `instance_projections` table, so it
  404s exactly as before. This design adds no new query that could leak a
  bypass: the new `fetch_display_names_by_actor_id/2` query (§4) is itself
  `prefix`-scoped to the same tenant schema, querying that tenant's own
  `users` table — it cannot resolve or leak another tenant's user rows,
  since `users` is itself a per-tenant-schema table (Decision 0006 D1) and
  the query never receives any other tenant's prefix.

Net: five files worth of behaviour (route, auth, ordering, pagination,
404/cross-tenant) are provably unchanged because the only edited functions
are `Letflow.Instances.timeline/3`'s response-item-building tail (§4/§5)
and `timeline_item_map/1`/(new helper) in the router — every other line
either module has today stays as-is.

## 7. Confirmed no-touch surfaces

- **`lib/letflow/api/authorization.ex`:** not read, not edited by this
  design. The permission gate is `:InstancesRead`, already registered and
  already enforced by `authz_get`'s existing macro expansion — this
  requirement adds no new permission and changes no existing one.
- **`web/`:** not edited by this design. `TimelineFeedItem.tsx` and
  `timelineUtils.ts` already read `entry.actor_display_name`,
  `entry.description`, `entry.timestamp` and `entry.sequence_num` (per the
  requirement's own citations, confirmed by reading both files directly:
  `TimelineFeedItem.tsx` L15-48, `timelineUtils.ts`'s
  `getTimelineActorDisplayName`/`getTimelineSecondaryContext`); `§5`'s
  renamed/new fields are exactly what those already-shipped call sites
  expect, so no SPA file needs any change for this response shape to
  render correctly.

## Open questions (explicit, not silently resolved)

1. **`node_id` vs. `node_label` in `TASK_COMPLETED`'s description (§3).**
   No node-label lookup exists in this codebase reachable from this
   requirement's scope; the rendered sentence names the raw `node_id`.
   Revisit if/when a node-definition label lookup becomes available.
2. **`EXECUTION_ERROR`'s description omits the specific `affected`
   entities** (task/node ids the error affected, present in the payload
   under `affected`) — only `error_type` is named, to keep the sentence a
   single short human-readable line per the requirement's own framing
   ("a short human-readable sentence"). If a future requirement wants
   affected-entity detail in the sentence itself, that payload key is
   already available to a later clause.
3. **`TIMER_FIRED` names no actor in its sentence** (§3) even though
   `actor_display_name` is still populated (as `"system"`) in the item —
   a deliberate choice to avoid a content-free "by system" suffix on every
   such row; flagged in case a reviewer prefers uniformity over brevity
   here.
