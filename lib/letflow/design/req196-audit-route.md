# REQ-196 — Serve GET /api/v1/audit from the audit_entries store

Design for `docs/requirements.yaml` REQ-196 (queue task 369, GH#715). The route half of
the audit split, atop REQ-195's just-merged `audit_entries` store
(`lib/letflow/audit.ex`, `lib/letflow/audit/entry.ex`,
`lib/letflow/design/req195-audit-entry-storage.md`). Deliberately small: repoint
`lib/letflow/routers/audit.ex`'s handler from `Letflow.EventStore.read_global/1` onto
REQ-195's store, preserving the response envelope and the `:AuditRead` permission.

## 0. Traceability matrix (AC → design element)

| AC | Design element |
|---|---|
| AC1 (real non-null before_state/after_state) | §2 field mapping (§2.1), §1 new query function reads real columns |
| AC2 (resource_type varies, not constant "instance") | §2.1 mapping — `resource_type` now the stored column, not a literal |
| AC3 (resource_type filter actually filters) | §3 |
| AC4 (response envelope still matches RawAuditPage/RawAuditEntry field-for-field) | §2, §2.2 |
| AC5 (still requires :AuditRead, no authorization.ex change) | §6 |
| AC6 (tenant isolation) | §7 |
| AC7 (moduledoc no longer claims always-null/constant resource_type) | §5 |
| AC8 (no file under web/ touched) | §9 non-goals |
| AC9 (`mix test`/`mix compile --warnings-as-errors` pass) | ELIXIR-DEV/TEST-RUNNER execution gate, not a design element |

## 1. New read function: `Letflow.Audit.list_entries/1`

**Decision: a new query function is needed in `Letflow.Audit`, not a direct
`Entry`/`Repo` query inline in the router.** `Letflow.Routers.Audit`'s own moduledoc
already documents (§"Ordering guarantee") that this module performs **no `Repo` call of
any kind** — INV-RT-1, stated identically at `lib/letflow/routers/admin_services.ex:64`
and enforced project-wide ("no `Repo.` call anywhere under `lib/letflow/routers/`").
`Letflow.Audit` today (REQ-195) exposes only `append_multi/4`, `insert_entry/3`, and
`verify_chain/2` — none is a filtered/paginated list. This is the same shape REQ-192
resolved for `Letflow.ServiceCatalog` by adding `list_all/1` alongside the existing
`list_for_tenant/2` (`lib/letflow/service_catalog.ex:369-387`,
`lib/letflow/design/req192-service-catalog-routes.md` §5): "a hard conflict between
[a 'no context-module change' note] and INV-RT-1" is resolved by adding the read-only
query function, not by bending INV-RT-1. REQ-196's own scope note ("no change to
REQ-195's schema or capture logic") permits this exactly as REQ-192's did — schema and
capture logic are untouched; only a new read path is added.

### 1.1 Input shape

```
@type list_params :: %{
        required(:page_size)     => pos_integer(),
        optional(:cursor)        => {DateTime.t(), Ecto.UUID.t()} | nil,
        optional(:from)          => DateTime.t() | nil,
        optional(:to)            => DateTime.t() | nil,
        optional(:actor_id)      => Ecto.UUID.t() | nil,
        optional(:resource_id)   => String.t() | nil,
        optional(:resource_type) => String.t() | nil
      }
```

`cursor` is pre-decoded by the router (§4 of `routers/audit.ex`'s existing pattern:
decoding is a router-owned concern, same division of labor `ServiceCatalog.list_all/1`
uses with its own `decode_list_all_cursor/1` — except here, per this section, the
*decode* step itself is better placed in the router because the router already owns
the `"A:"` cursor-prefix constant and `parse_cursor_param/1`/`global_seq_from_cursor/1`
private functions from the EventStore-backed implementation; §1.3 below states exactly
what carries over unchanged). `list_entries/1` therefore accepts an **already-decoded**
`{timestamp, id}` seek pair, not a raw cursor string — mirroring `EventStore.read_global/1`'s
own division of labor, where the router decodes the opaque cursor into a page-name term
before calling the store.

There is no `pipeline_run_id` or `payload` param in this shape: `pipeline_run_id` stays
a router-level 422 rejection exactly as today (§1.3), and `payload` is removed (§4) —
neither reaches the new query function.

### 1.2 Output shape

```
@spec list_entries(list_params()) ::
        {:ok, %{items: [Entry.t()], has_more: boolean()}}
        | {:error, :invalid_actor_id | :invalid_resource_id}
```

Mirrors `EventStore.read_global/1`'s `{events, has_more}` result shape (renamed
`items`/`Entry.t()` to match REQ-195's schema) so `routers/audit.ex`'s existing
`render_page/2` two-clause dispatch (`{:ok, %{...}}` / `{:error, reason}`) needs only its
field names updated, not its control-flow shape. `has_more` is computed the same
`page_size + 1`-fetch/drop-the-extra-row idiom `ServiceCatalog.list_all/1` and
`EventStore.read_global/1` both already use — query `limit: page_size + 1`, and if
`length(rows) > page_size`, `has_more = true` and the extra row is dropped before
returning `items`.

The two `{:error, ...}` atoms exist only if `actor_id`/`resource_id` validation
(e.g. malformed UUID cast for `actor_id`) needs to surface a typed error, matching
`EventStore.read_global/1`'s own `:invalid_actor_id`/`:invalid_instance_id` — since
`Entry.actor_id` is `:binary_id`, an `Ecto.Query` equality filter with a non-UUID string
value raises an `Ecto.Query.CastError` rather than returning an error tuple; `list_entries/1`
must catch that ahead of the query (`Ecto.UUID.cast/1` check on a non-nil `actor_id`
before building the query) and turn it into `{:error, :invalid_actor_id}`, matching
`render_page/2`'s existing `:invalid_actor_id`/`:invalid_instance_id` clause verbatim (no
router-side change to that clause needed beyond the atom name, if it differs —
recommend keeping `:invalid_actor_id`/`:invalid_resource_id` so the existing `render_page/2`
`when reason in [...]` guard only needs its atom list updated, not its shape). `resource_id`
is `:string` on `Entry` (§1.2 of REQ-195's design), so no cast-error risk exists for
it — `list_entries/1`'s `:invalid_resource_id` clause is included for interface symmetry
but may be dead code in practice; ELIXIR-DEV should confirm and, if genuinely
unreachable, may omit it from the `@spec`'s error union (an open question, §8 OQ-1).

### 1.3 Query construction

Base query: `Letflow.Audit.Entry`, with the following predicates applied, each only
when its corresponding filter value is non-nil (an absent filter contributes no
predicate at all, not a predicate that always matches):

| Filter | Predicate applied when present |
|---|---|
| `from` | `timestamp >= from` |
| `to` | `timestamp <= to` |
| `actor_id` | `actor_id == actor_id` (equality) |
| `resource_id` | `resource_id == resource_id` (equality) |
| `resource_type` | `resource_type == resource_type` (equality) |
| `cursor` (`{cursor_ts, cursor_id}` seek pair, §1.1) | keyset-pagination predicate: `timestamp < cursor_ts`, OR (`timestamp == cursor_ts` AND `id < cursor_id`) — standard `(timestamp, id)` composite-keyset seek in the descending direction matching the ordering below |

Ordering: `timestamp` descending, `id` descending (the tiebreak). Row limit:
`page_size + 1` (the has-more probe, §1.2). Executed via the tenant-scoped `prefix`
option (§7), identically to how every other tenant-scoped query in this codebase
passes `prefix:` to its `Repo` call.

`order by timestamp desc, id desc` matches REQ-195's own index #1
(`(timestamp desc, id desc)`, `lib/letflow/design/req195-audit-entry-storage.md` §1.3) —
the same tiebreak convention `Letflow.Definitions.list_paginated/2`/
`Letflow.Identity.list_users/2` already use, so the query is index-backed with no new
index required. The `resource_type`+`resource_id`-filtered path is additionally backed
by index #3 (`(resource_type, resource_id, timestamp desc, id desc)`), and the
`actor_id`-filtered path by index #2 (`(actor_id, timestamp desc, id desc)`) — both
already created by REQ-195's migration; **no new migration is needed for this
requirement.**

`prefix` comes from `conn.assigns.scoped_opts` exactly as `routers/audit.ex` passes it
to `EventStore.read_global/1` today (`opts` keyword list carries `prefix: ...`) — `list_entries/1`
accepts it the same way `insert_entry/3` accepts `prefix` today (an explicit argument,
not read from process/application config), so tenant scoping is structural, not
optional (§7).

## 2. Response-envelope mapping

### 2.1 Column → RawAuditEntry field mapping

| `audit_entries` column (`Letflow.Audit.Entry`) | `RawAuditEntry` field (`web/src/api/audit.ts`) | Notes |
|---|---|---|
| `id` | `audit_id` | Same rename `routers/audit.ex`'s existing `audit_item/1` already performs for `event.event_id` → `"audit_id"` (REQ-195's own design doc, §1.1 "Naming note," anticipates exactly this route-layer rename). |
| `actor_id` | `actor_id` | Direct; `nil` passes through as JSON `null` — `RawAuditEntry.actor_id` is already optional/nullable in the SPA type. |
| `action` | `action` | Direct, no rename (was `event.event_type` before; now the `action` column itself, e.g. `"definition.activate"`). |
| `resource_type` | `resource_type` | Direct — **no longer a hardcoded literal** (§3). |
| `resource_id` | `resource_id` | Direct — was `event.instance_id` before; now the `resource_id` column, a `:string`, not necessarily a UUID (REQ-195 §1.2). |
| `timestamp` | `timestamp` | `DateTime.to_iso8601/1` over `Entry.timestamp` (`:utc_datetime_usec`) — same `iso8601/1` private helper `routers/audit.ex` already has, unchanged. |
| `before_state` | `before_state` | Direct — was always `nil`; now the real stored `:map`/`jsonb` value, passed through as-is (already JSON-representable, REQ-195 §3.2's "plain map of scalar/string/nested-map values" invariant). |
| `after_state` | `after_state` | Direct, same as `before_state`. |

This is a straightforward 1:1 mapping — every `RawAuditEntry` field maps to exactly one
`Entry` column, with only the `id` → `audit_id` rename carried over from the existing
implementation. No `RawAuditEntry` field is left unfilled, and no `Entry` column needs
computation/derivation the way `event.metadata["pipeline_run_id"]` did before.

**Fields removed from the response, both confirmed absent from `RawAuditEntry`
(`web/src/api/audit.ts:26-35`) and from `AuditLogPage.tsx`'s rendering (it reads only
`id`, `occurred_at`, `actor_id`/`actor_display_name`, `action`, `resource_type`,
`resource_id`, `before_state`, `after_state`, `ip_address` — the last two are populated
client-side by `mapAuditEntry`, `ip_address` always `null`, never from the wire):**

* `pipeline_run_id` — REQ-195's `Entry` schema has no such column at all (it was
  `event.metadata["pipeline_run_id"]`, an event-store-specific concept). Dropped
  entirely; no equivalent exists to carry forward. `RawAuditEntry` never declared it,
  so the SPA is unaffected.
* `payload` — see §4.

### 2.2 Envelope shape unchanged

```
%{
  "items"       => [envelope_map(), ...],  # unchanged key, unchanged array shape
  "next_cursor" => String.t() | nil,       # unchanged: opaque cursor, same "A:" prefix,
                                            # same encode_cursor/1 call, minted over the
                                            # last item's (timestamp, id) instead of
                                            # (mint_time_us, global_seq) -- §1.3's seek
                                            # pair, not a new cursor scheme
  "count"       => non_neg_integer()       # unchanged: length(items), still not a total
}
```

`page_body/2`'s existing structure in `routers/audit.ex` is unchanged; only
`next_cursor/2`'s internal encoding of the seek pair (`global_seq` → `{timestamp, id}`)
and `audit_item/1`'s field-by-field mapping (§2.1) change. The `"A:"` cursor prefix,
`Pagination.encode_cursor/1`/`decode_cursor/3`, and the 400-on-invalid-cursor
convention are all unchanged (§1.1 already establishes the router still owns cursor
encode/decode).

## 3. `resource_type` filter — real behavior

**Before:** `unsupported_resource_type?/1` treated any value other than `nil`/`""`/`"instance"`
as unsupported, returning a truthful-but-static empty page with no query issued
(`routers/audit.ex:154,211-214`) — a no-op filter dressed as a real one, because every
row in `events` was `"instance"`.

**After:** `unsupported_resource_type?/1` and its empty-page short-circuit are **deleted
entirely**. `resource_type` becomes a normal optional equality filter passed straight
into `list_entries/1`'s `list_params()` (§1.1), applied as `WHERE resource_type = $1`
when present, unfiltered when absent/empty (§1.3's `is_nil(^resource_type) or ...`
clause) — backed by REQ-195's index #3. AC2's requirement ("a response containing at
least two different resource_type values") and AC3's requirement ("filtering to one
resource kind returns only entries of that kind, and omitting it returns all kinds")
are both satisfied directly: REQ-195's covered operations already write at least
`"definition"`, `"instance"`, `"task"`, `"user"`, `"group"`, `"api_token"` rows
(`lib/letflow/design/req195-audit-entry-storage.md` §3.2's per-operation table), so a
test seeding two different operations and asserting the filtered/unfiltered behavior
has real data to exercise.

## 4. The `payload` field — removed

**Decision: remove `payload` from the response entirely.**

Verification, not assumption, per the requirement's own instruction to assert rather
than assume:

* `web/src/api/audit.ts`'s `RawAuditEntry` interface (lines 26-35) declares exactly
  eight fields — `audit_id`, `actor_id`, `action`, `resource_type`, `resource_id`,
  `timestamp`, `before_state`, `after_state` — no `payload` field. Confirmed by reading
  the file directly this session (§ project instructions: "Read the real code first").
* `mapAuditEntry/1` (`audit.ts:43-55`) reads only those eight fields off `raw`; a ninth
  `payload` key present on the wire response is simply never accessed — TypeScript's
  structural typing means an extra JSON key is silently ignored at runtime, not a type
  error, so `payload`'s current presence has never been anything but dead weight to the
  SPA.
* `AuditLogPage.tsx` renders only the `AuditEntry` fields `mapAuditEntry/1` already
  produces (`occurred_at`, `actor_id`/`actor_display_name`, `action`, `resource_type`,
  `resource_id`, `before_state`/`after_state` via `JsonDiffView`, `ip_address`) — no
  reference to `payload` anywhere in the component.
* `grep -rn "\.payload" web/src/` (ELIXIR-DEV should re-run this exact check at
  implementation time as its own verification step, since this design predates the
  actual diff) is expected to show no read of an audit-response `payload` field
  anywhere under `web/`, consistent with the above.

**Why removal is correct, not merely safe:** `routers/audit.ex`'s own moduledoc states
`payload` existed specifically because "[w]ithout it the response carried no information
about *what* changed" — a gap that existed only because `before_state`/`after_state`
were always `null`. REQ-195's store supplies real `before_state`/`after_state` on every
row (AC1), which is strictly more structured information about "what changed" than the
event's raw `payload` blob ever was. Carrying `payload` forward would mean serializing
`Entry`'s `before_state`/`after_state` maps *and* some redundant payload-shaped value
with no defined source column (REQ-195's `Entry` schema has no `payload` field at
all — inventing one would mean re-deriving it from `after_state`, a pure duplicate).
Removing it is therefore not just "safe because the SPA doesn't read it" but "correct
because it is no longer meaningful once `after_state` is real."

## 5. Moduledoc rewrite

`lib/letflow/routers/audit.ex`'s moduledoc must be rewritten to remove every claim this
requirement falsifies, matching REQ-195's own `Letflow.Audit` moduledoc's convention of
stating what the shipped code actually does rather than cross-referencing a design doc
alone (REQ-195 design §5.4/§7's "the shipped module must say it" rule applies here too,
even though this AC (AC7) is phrased as "no longer states," not "must state X" —
ELIXIR-DEV should still positively describe the new source, not just delete the old
claims and leave a gap). Specifically, remove:

* The whole **"Served from the event store, not an audit-entry table"** section
  (lines 14-37 of the current file) — the premise ("Letflow has no such table") is now
  false.
* The **"Filter disposition"** table's `resource_type` row's "not supported" framing
  (§3 above) — replaced with a row stating it is a real, index-backed equality filter.
* `pipeline_run_id`'s row can stay conceptually (still 422-rejected, §1.1) but must be
  re-anchored to the fact that `audit_entries` has no such column at all, rather than
  "nothing writes `metadata["pipeline_run_id"]` yet" (an `events`-table-specific
  framing that no longer applies).

And state, in its place:

* `GET /audit` now reads from `Letflow.Audit.list_entries/1` (REQ-196), backed by
  REQ-195's `audit_entries` table — link to
  `lib/letflow/design/req195-audit-entry-storage.md` and this file for the schema and
  hashing details, matching how other REQ-19x moduledocs cross-reference their design
  docs.
* `resource_type`, `before_state`, `after_state` all now carry real, per-row values —
  the exact inverse statement of the caveats being removed, so a future reader diffing
  moduledoc history sees the change was deliberate, not a silent drop.
* The three deliberate cursor-status divergences (§"Two deliberate cursor divergences...")
  and the ordering-guarantee/INV-1 sections are **unchanged in substance** — they
  describe router-owned behavior this requirement doesn't touch — but ELIXIR-DEV should
  confirm they still read correctly given `EventStore` is no longer named in the
  "no `Repo` call" sentence (replace `EventStore.read_global/1` with
  `Letflow.Audit.list_entries/1` wherever the moduledoc names the delegate).

## 6. Authorization — unchanged (AC5)

`Letflow.Api.Authorization.endpoint_policy_key("GET", "/audit")` already returns
`:AuditRead` (`lib/letflow/api/authorization.ex:282`, confirmed unchanged this session);
`:AuditRead`'s role mapping (`PLATFORM_ADMIN`/`PROCESS_OPERATOR` hold it,
`PROCESS_DESIGNER`/`TASK_WORKER`/`AGENT_RUNNER` do not) is REQ-069's existing matrix,
also unchanged. `routers/audit.ex`'s `authz_get "/", :AuditRead do ... end` declaration
is untouched by this requirement — no edit to `lib/letflow/api/authorization.ex` is in
scope, and AC5's `git diff` check should show zero lines changed in that file.

## 7. Tenant scoping — inherited automatically (AC6)

Identical mechanism to REQ-195's own tenant-scoped queries and to `routers/audit.ex`'s
existing `EventStore.read_global/1` call: `Entry` is a per-schema table (Decision
0003-B, physical per-tenant-schema isolation), and `list_entries/1` is called with
`prefix: conn.assigns.scoped_opts`'s prefix, resolved solely from
`conn.assigns[:auth_context][:tenant_id]` — the same "only tenant input" invariant
`routers/audit.ex`'s own moduledoc states under "INV-1 — the sharpest case in
REQ-078" (unchanged section, §5 above). `Repo.all(query, prefix: prefix)` targets
Postgres's `search_path`-equivalent schema-qualification at the connection level;
there is no query parameter, header, or body field through which another tenant's
`audit_entries` rows could be selected, because `prefix` is never derived from anything
in the request other than the already-authenticated `auth_context`. No new test
infrastructure is needed beyond what REQ-195 already established for asserting
`Entry` rows are schema-isolated (REQ-195 AC4) — this requirement's AC6 exercises the
same isolation through the route instead of through `Letflow.Audit` directly.

## 8. Open questions

* **OQ-1 — is `:invalid_resource_id` reachable?** §1.2 notes `resource_id` is a plain
  `:string` column with no cast-error risk analogous to `actor_id`'s UUID cast, so a
  `resource_id`-triggered `{:error, :invalid_resource_id}` may be unreachable dead code.
  ELIXIR-DEV should confirm during implementation and drop the clause from both the
  `@spec` and `render_page/2`'s guard if genuinely unreachable, rather than keeping an
  error path nothing can hit.
* **OQ-2 — cursor decode ownership.** §1.1 places cursor *decoding* in the router
  (matching the existing `parse_cursor_param/1`/`global_seq_from_cursor/1` shape) rather
  than in `Letflow.Audit`, unlike `ServiceCatalog.list_all/1`'s self-contained
  `decode_list_all_cursor/1`. This design chose router-side decoding because
  `routers/audit.ex` already owns the `"A:"` prefix constant and the existing private
  parse functions need only their inner-payload interpretation changed (`global_seq`
  integer → `{timestamp, id}` pair), not relocated. ELIXIR-DEV may instead follow
  `ServiceCatalog`'s convention and move decode into `Letflow.Audit` if that reads more
  consistently with REQ-195's own module conventions — either placement satisfies every
  AC; this is a style choice, not a correctness one, left open deliberately rather than
  mandated.

## 9. Non-goals (explicit)

* **No change to REQ-195's schema or capture logic.** `lib/letflow/audit/entry.ex`'s
  columns, `Letflow.Audit.append_multi/4`/`insert_entry/3`/`verify_chain/2`, and the
  hash-chain mechanics are untouched — this requirement adds one new read-only function
  (§1) alongside them.
* **No change to `lib/letflow/api/authorization.ex`.** §6.
* **No change to any file under `web/`.** §2's mapping is designed specifically so
  `RawAuditPage`/`RawAuditEntry`/`AuditLogPage.tsx` require zero edits — confirmed by
  reading both files directly this session (§4's verification applies to the whole
  response shape, not just `payload`).
* **No new routes.** `GET /audit` is the only endpoint this requirement touches; no
  new path, method, or sub-router is added.
* **No new migration.** REQ-195's three indexes (§1.3) already back every filter shape
  this route needs; §1.3 confirms no new index is required.
