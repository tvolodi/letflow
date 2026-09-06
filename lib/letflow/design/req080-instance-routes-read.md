# REQ-080 design — Instance routes 2/2 (read path)

PROVENANCE (historical, not current decision authority):
Ports the read half of `src/api/routes/instances.zig`: `handleGetById`
(L422), `handleList` (L586), `handleHistory` (L839), `handleTimeline`
(L1067), `handleGetPins` (L1265). Sibling to REQ-079 (write path, shipped
PR #565) — both own `lib/letflow/routers/instances.ex`.

## New context module: `Letflow.Instances`

No context module backed instance reads before this requirement (unlike
`Letflow.Tasks`/`Letflow.Definitions`). This requirement adds
`lib/letflow/instances.ex`, mirroring `Letflow.Tasks`'s established shape
(`get_task/2`, `list_tasks/2` — see that module for the cursor-pagination
idiom this requirement reuses verbatim, not reinvents):

- `get_by_id/2` — direct `InstanceProjection` read by `instance_id`,
  prefix-scoped. `{:error, :not_found}` on absent-or-cross-tenant, same
  single code path (INV-5), matching `Letflow.Tasks.get_task/2`'s own
  established convention.
PROVENANCE (historical, not current decision authority):
- `list/2` — cursor-paginated `InstanceProjection` query. Filters: `status`,
  `definition_id`, `correlation_key`, `started_after`/`started_before`
  (date range) — **wider than R-Co's own `handleList`**, which filters only
  `status`/`definition_id` (`instances.zig:167-176`). This requirement's own
  acceptance criteria explicitly require `correlation_key` and date-range
  filtering ("any filter parameter (status, definition id, correlation key,
  date range)"), so this is a considered Letflow addition over R-Co, the
  same precedent REQ-079's `definition_name` create-param addition already
  set — not scope creep, the requirement text itself demands it. Cursor key:
  `(started_at, instance_id)` descending, same shape as
  `Letflow.Tasks.list_tasks/2`'s `(inserted_at, id)` key.
- `history/2` — cursor-paginated `Letflow.EventStore.Event` query scoped to
  one `instance_id`. Filters: `event_type`, `from`/`to` (on `created_at`).
  Existence check first (`instance_exists?/2` against `InstanceProjection`)
  so a cross-tenant/nonexistent id 404s before any `events` query runs —
  same INV-5 shape as `get_by_id/2`. Cursor key: `sequence_number` alone
  (unique per instance by construction, REQ-025) — simpler than `list/2`'s
  compound key since no tie-break is needed.

  PROVENANCE (historical, not current decision authority):
  **Deliberate non-port: `pipeline_run_id` filter (`instances.zig`
  `HistoryParams.pipeline_run_id`, ADP-06).** No ADP-06 pipeline-run
  correlation concept exists anywhere in Letflow yet (`grep -rn
  "pipeline_run_id" lib/` — zero hits outside this file). Porting a filter
  parameter with no backing column to filter on would be dead code advertising
  a capability that doesn't work. Omitted; a future ADP-06 port is this
  filter's proper home, not this requirement's to invent early.

- `timeline/2` — same underlying `Event` query/pagination as `history/2`,
  **lighter response projection**: `event_type`, `sequence_number`,
  `created_at`, `event_id`, `instance_id`, `metadata`, plus `node_id`/
  `task_id` extracted from `payload` where present (`payload["node_id"]`/
  `payload["task_id"]`, both already-established per-event-type payload keys
  — no new extraction logic, a plain `Map.get/2`).

  PROVENANCE (historical, not current decision authority):
  **Deliberate non-port: `actor_display_name`/`description` synthesis**
  (`instances.zig` handleTimeline body, ~L1067-1160). R-Co's timeline
  handler resolves `actor_id` to a human display name and synthesizes a
  free-text description per event type — a UI-presentation layer with no
  Letflow backing (no actor-name-lookup module, no per-event-type
  description-template registry). This requirement's acceptance criteria
  require pagination-completeness and cross-tenant/permission coverage for
  all five endpoints; none names `actor_display_name`/`description`
  specifically. Building that presentation layer from scratch is a
  separate, UI-facing requirement's scope, not this one's — flagged here so
  a later reader building it doesn't read this omission as an oversight.
  `timeline/2` returns the raw per-event data a future presentation layer
  would derive those two fields from.

- No `get_pins/2` wrapper: `Letflow.Engine.PinResolver.reconstruct_effective_pins/2`
  (already shipped, REQ-078) already does exactly this — instance's
  effective pin set from its own event stream, `{:error, :instance_not_found}`
  on absent-or-cross-tenant. The router's `handle_get_pins/2` calls it
  directly; a wrapper here would be a pass-through with nothing to add.

## Router (`lib/letflow/routers/instances.ex`)

Five new `get` routes, thin handlers, all delegating to `Letflow.Instances`
or `PinResolver` — same shape as REQ-079's write handlers and
`Letflow.Routers.Tasks`'s existing read handlers. `GET`/`POST` are
independent `Plug.Router` dispatch tables (per REQ-079's own moduledoc), so
no route-ordering interaction with the existing `POST` routes.

Route table:

| Handler       | Method/path                    | Delegate                                                | Permission      |
|---------------|---------------------------------|----------------------------------------------------------|------------------|
| get_by_id     | `GET /instances/:id`            | `Letflow.Instances.get_by_id/2`                           | `InstancesRead` |
| list          | `GET /instances`                | `Letflow.Instances.list/2`                                | `InstancesRead` |
| history       | `GET /instances/:id/history`    | `Letflow.Instances.history/2`                             | `InstancesRead` |
| timeline      | `GET /instances/:id/timeline`   | `Letflow.Instances.timeline/2`                            | `InstancesRead` |
| get_pins      | `GET /instances/:id/pins`       | `Letflow.Engine.PinResolver.reconstruct_effective_pins/2` | `InstancesRead` |

Authorization: same temporary direct-`Authorization.evaluate_access/2`-call
pattern REQ-079/`Letflow.Routers.Tasks` already use (REQ-131 not yet
mandatory-plugged). One permission (`InstancesRead`) gates all five, per
this requirement's own AC6 ("a caller without InstancesRead receives 403 on
every one of the five endpoints") — matching `Letflow.Api.Authorization`'s
existing `:InstancesRead` policy key (confirm it exists; if not, add the
`endpoint_policy_key/2` clauses the same way REQ-079 added its three).

**Route-match ordering.** `get "/:id"` (get_by_id) must be declared
**after** `get "/:id/history"`, `get "/:id/timeline"`, `get "/:id/pins"` in
this module — otherwise `Plug.Router`'s first-match-wins semantics would
have `/:id` swallow `/:id/history` etc. with `id = "history"` etc., the same
class of hazard `Letflow.Routers.Tasks`'s `/inbox`-before-`/:id` note
already documents (this module now needs the router-generated `/:id`
literal-suffix precedence check `Letflow.Routers.Instances`'s own moduledoc
already states for its `POST` table — `GET`'s table needs the identical
discipline, independently, since the two tables don't interact).

## Response shapes (INV-2 allowlists)

`get_by_id`: `{instance_id, definition_id, correlation_key, status,
variables, started_at, completed_at, cancelled_at, error_detail}` — the
`InstanceProjection` row's own fields, `status` via `Atom.to_string`-style
uppercase mapping (reuse `status_string/1` already defined in this router by
REQ-079, exposed as a shared private helper — do not duplicate it).

PROVENANCE (historical, not current decision authority):
`list`/`history`/`timeline`: the standard `Letflow.Api.Pagination.Page`
envelope (`items`, `next_cursor`, `count`) — `list`'s items are the same
shape as `get_by_id` minus `variables`/`error_detail` (list rows omit large
JSON blobs, matching R-Co's own lighter list-row shape,
`instances.zig:730-ish`). `history`'s items: `{event_id, event_type,
sequence_number, created_at, payload}` (the raw event, all fields the
caller can read from `Letflow.EventStore.Event` directly — no field
omitted, since a history endpoint's whole purpose is exposing raw event
data). `timeline`'s items: the lighter projection stated above.

`get_pins`: `{instance_id, pins: [...]}\}` — `pins` is
`PinResolver.effective_pin()` list, mapped the same element-shape
`render_rebind/2`'s `changed_entry_map/1` already establishes for pin
entries (`kind`, `ref`, `version`, `source`) — reuse that mapping function
if its shape fits, or a sibling one if `effective_pin()`'s fields differ
enough to need one (verify field names against `pin_resolver.ex` directly
before assuming reuse works unchanged).

## Security (INV-1, INV-5, INV-7)

- **INV-1 (tenant isolation).** Every query in `Letflow.Instances` takes
  `prefix` from `opts` (caller-supplied, sourced from
  `Letflow.Api.Context.scoped_repo_opts/1` in the router, same as every
  other REQ-07x/08x context module) and every `Repo` call passes
  `prefix: prefix` explicitly — no query omits it. `list/2`'s filter test
  seeds two tenants with matching filter values and asserts each tenant's
  list contains only its own rows (AC4).
- **INV-5 (cross-tenant is the same 404).** `get_by_id/2`,
  `history/2`, `timeline/2` all route absent-and-cross-tenant through one
  code path each (`{:error, :not_found}` / `{:error, :instance_not_found}`),
  never a distinguishing branch. `get_pins` inherits this from
  `PinResolver.reconstruct_effective_pins/2`, already built this way.
  AC3 needs four explicit tests, one per endpoint (`list` has no per-id
  concept, so it is not one of the four — `list`'s own tenant-isolation
  coverage is AC4, a different acceptance criterion).
- **INV-7 (no raw SQL, no interpolation).** Every filter composes via
  `Ecto.Query` macros with pinned (`^`) values — `filter_by_status/2` etc.
  mirror `Letflow.Tasks`'s own private filter helpers exactly (`where:
  t.status == ^status`, never a `fragment/1` string-building path). AC5's
  SQL-metacharacter test seeds a filter value containing `'; DROP TABLE
  events; --`-shaped input and asserts it is treated as an inert literal
  (matches zero rows, all tenant tables still present afterward) — plus a
  `grep -rn "fragment(" lib/letflow/instances.ex lib/letflow/routers/instances.ex`
  confirming zero raw-fragment usage (AC5's own literal "confirmed by grep"
  wording).

## Pagination correctness (AC2)

`list/history/timeline` each get a dedicated test seeding N rows (N >
2×page_size, e.g. 5 rows at page_size 2) and walking every page via
`next_cursor` until `next_cursor == nil`, asserting the concatenated pages
equal the full seeded set with no duplicate and no gap — the same
methodology `Letflow.Tasks`'s own list_tasks pagination tests already use
(reuse that test's structure, don't invent a new one).

## Open question resolved: `RESTORED_ORPHAN` status (R-Co 5th status)

PROVENANCE (historical, not current decision authority):
R-Co's `InstanceProjection.status` enum has five values
(`instances.zig:459`: `ACTIVE`/`COMPLETED`/`CANCELLED`/`ERROR`/
`RESTORED_ORPHAN`). Letflow's `Letflow.EventStore.InstanceProjection.status`
`Ecto.Enum` has four (`active`/`completed`/`cancelled`/`error` —
`instance_projection.ex:125-128`, already shipped, REQ-023/043, unrelated
to this requirement). `RESTORED_ORPHAN` is not this requirement's to add —
it is an already-closed 4-vs-5 divergence in an earlier-shipped schema, out
of scope here. `list`'s `status` filter validates against Letflow's
existing four-value set only (`Ecto.Enum.values/2`-backed, not a hand-copied
literal list), matching the schema it actually queries.

## Follow-up filed, not fixed here: `list/2`'s cursor-expiry basis

`list/2`'s cursor (`build_list_next_cursor/1`) reuses `Letflow.Tasks.list_tasks/2`'s
exact pattern verbatim: the cursor's expiry-checked timestamp slot is the
LAST ROW'S OWN `started_at`, not the wall-clock instant the cursor was
minted. For a list of instances all started more than 24h ago (the
`cursor_expiry_us` window), every page-2+ request would return
`{:error, :expired}` immediately, even though the cursor was minted seconds
ago -- conflating "how old is this row" with "how long has this cursor been
outstanding". `history/2`/`timeline/2` (new cursor prefixes, no existing
precedent to match) use `System.system_time(:microsecond)` as the timestamp
slot instead, the semantically-correct basis. `list/2` matches
`list_tasks/2` for consistency within this requirement rather than
unilaterally diverging from an already-shipped, already-reviewed sibling
pattern -- flagged for REVIEWER, and a follow-up issue filed against both
`list_tasks/2` and `list/2` together rather than silently fixed piecemeal
here.
