# ISS-0733 Fix Design — Promotion Audit Write Path + Platform-Events Read Path

Run-id: WF03-ISS0733-20260921
Type: backend design (two independent gaps under EO-004's single acceptance criterion).
Design only — no `.ex` function bodies. Signatures, `@spec`s, and data shapes only.

## 0. Inputs this design builds on (not re-derived)

- `docs/issues/ISS-0733.yaml` — EO-004 (`test/fixtures/uat/scenarios/platform/definition-promotion-approved.yaml`):
  "The change history for this process shows the proposal, the approval with the
  approver's name, and the release, in that order with timestamps."
- `handoffs/WF03-ISS0733-20260921/step-01-issue-fixer-diagnosis.json`'s `result.summary`
  (ISSUE-FIXER, PASS): the event-append itself is NOT silently failing —
  `PlatformEvents.append_definition_promoted/2` is a real adapter, verified end-to-end by
  a real test run, and a real `DEFINITION_PROMOTED` row does land in the target tenant's
  own `events` table (scoped by `target_prefix`, `instance_id = platform_instance_id()`).
  The two real bugs are both **read/write-surface gaps**, not append failures:
  - **GAP A**: `lib/letflow/definitions/promotion.ex` calls `Letflow.Audit` nowhere, so
    `GET /api/v1/audit` structurally can never show a promotion release.
  - **GAP B**: `GET /api/v1/instances/:platform_instance_id/timeline` 404s
    unconditionally for every caller, always, because `platform_instance_id/0` is
    deliberately never inserted into `instance_projections`
    (`lib/letflow/event_store.ex:871-879`) and `Instances.timeline/3`'s
    `ensure_instance_exists/2` (`lib/letflow/instances.ex:330-338`) requires a real
    `instance_projections` row.

This design closes both gaps. **Scope note, stated explicitly rather than silently
assumed:** the handoff's own task text scopes GAP A to `promote_definition/3`'s write
path only (the "release" leg of EO-004). `PromotionReviewStore`'s submit/approve/reject
functions (the "proposal"/"approval" legs) call `Letflow.Audit` nowhere either — grepped,
confirmed no caller in `lib/letflow/definitions/promotion_review_store.ex` — but designing
audit entries for those is **out of scope for this artefact** and is called out as an open
question in §4, not silently folded in.

## 1. GAP A — write path: does the audit-entry write join `promote_definition/3`'s
pre-commit transaction, or run post-commit alongside the event-append?

### 1.1 Decision

**Joins the pre-commit transaction** — the same `Repo.transaction/1` block that already
performs the version-pointer swap (`write_target_definition/4`, `promotion.ex:345-372`,
currently steps 7-8 of the moduledoc's algorithm) — as a new step 3, called with `Repo`
directly, the exact invocation shape `Letflow.Definitions`'s `activate_draft_row/4`
(`definitions.ex:2357-2377`) already uses: `Audit.insert_entry(Repo, attrs, prefix)`
called inside a `Repo.transaction/1` anonymous function, its result pattern-matched, and
`{:error, reason} -> Repo.rollback(reason)` on failure.

It does **not** run alongside or after `append_promotion_event/9` (step 9, post-commit).

### 1.2 Justification

1. **This is `Letflow.Audit`'s own already-decided capture mechanism, not a new choice
   being made here.** `lib/letflow/audit.ex`'s moduledoc, "Capture mechanism" section
   (AC8), states the module implements capture "inside the Elixir context-function
   boundary that already performs the mutation... as one more step in the same
   transaction as the mutation itself" and explicitly rejects a decoupled/trigger-style
   capture. Every existing call site (`definitions.ex:1859`, `:2369`, `:2445`) follows
   this. Running the new call site post-commit, alongside `event_appender`, would make
   `promotion.ex` the one call site in the codebase where `Letflow.Audit` is used in a
   way its own design doc already argued against — a real divergence, not a neutral
   third option.

2. **The mutation EO-004's "release" leg is actually about is the version-pointer swap**
   (deprecate-then-activate, steps 7-8), not the event-append. That swap is exactly the
   kind of before/after-state, single-transaction mutation `audit_entries` exists to
   record (`Audit.entry_attrs()`'s `before_state`/`after_state` fields). The event-append
   is a separate, independently-fallible side effect (this codebase's own event-type
   registry backfill history — ISS-0332 — already shows it can fail for reasons that have
   nothing to do with whether the definition itself was actually promoted).

3. **Tying the audit write to the event-append's success would reproduce ISS-0733's own
   symptom one layer up.** `do_apply_review/3` (`promotion.ex:517-531`) already treats an
   event-append failure as `{:error, {:promotion_failed, reason}}` and marks the review
   `:failed` — even though, per step 9's own moduledoc note, the version-pointer move
   already durably committed and is **not** rolled back. If the audit entry were written
   only alongside/after a successful event-append, a definition that was genuinely
   promoted (row is `:active` in the target tenant right now) could show **no** audit
   trail at all whenever the append fails for an unrelated reason — exactly the
   "did the write happen or not, this tool can't tell" gap ISS-0733 reports, just moved
   from the event store to the audit trail. Joining the pre-commit transaction makes the
   audit record track the actual database mutation, not the orchestration's own
   best-effort follow-up step.

4. **Consequence, stated openly:** the audit-entry write becomes a second thing that can
   roll back the version-pointer swap if it itself fails (a changeset error, a transient
   DB error). This is not a new risk class — `activate_draft_row/4` already accepts
   exactly this trade-off for `definition.activate` — so this is consistent with, not a
   deviation from, the codebase's already-accepted Audit-insertion risk.

5. **Does not touch `definitions.ex`'s own call sites at all.** This is a new call site
   inside `promotion.ex`; `Letflow.Audit.insert_entry/3`'s contract, `Letflow.Audit`
   module itself, and every existing caller are unchanged — satisfies the acceptance
   criterion "does not weaken any existing test-asserted behaviour of
   `lib/letflow/definitions.ex`'s own Audit call sites."

### 1.3 Call-site changes

`write_target_definition/4` needs three additional fields to build the audit entry's
`resource_id`/`details` shape that are not currently in its parameter list
(`review_id`, `source_tenant_id`, `target_tenant_id` — all three are already
`do_promote_definition/7`'s own arguments, so no new data needs to be threaded in from
further up the call chain). Widened to arity 5:

```
@spec write_target_definition(
        source_row :: ProcessDefinition.t(),
        process_key :: String.t(),
        actor_id :: Ecto.UUID.t(),
        target_prefix :: String.t(),
        audit_context :: %{
          review_id: Ecto.UUID.t() | nil,
          source_tenant_id: Ecto.UUID.t(),
          target_tenant_id: Ecto.UUID.t()
        }
      ) ::
        {:ok, ProcessDefinition.t()}
        | {:error, :duplicate_version | Ecto.Changeset.t() | term()}
```

`do_promote_definition/7`'s existing call to `write_target_definition/4` (currently
`promotion.ex:300-306`) passes the new 5th argument, built from its own
`review_id`/`source_tenant_id`/`target_tenant_id` parameters — no new function parameter
on `do_promote_definition/7` itself, no change to `promote_definition/3`'s or
`promote_active_definition/5`'s own public signatures.

Inside `write_target_definition/5`'s `Repo.transaction/1` body, the algorithm gains one
step, after step 8(b) (`activate_new_definition/2`) and before the function returns:

  8(c). `Audit.insert_entry(Repo, audit_attrs(...), target_prefix)` (§1.4 below for the
        exact `audit_attrs` shape). `{:ok, _entry} ->` the transaction's existing return
        value (`activated_row`, unchanged shape) is what the block still returns.
        `{:error, reason} -> Repo.rollback(reason)`, propagating as this function's own
        `{:error, reason}` — exactly `activate_draft_row/4`'s existing pattern, not a new
        one.

`promote_result()`'s public 3-key contract (`source_definition_id`,
`target_definition_id`, `process_key`) is unchanged — the audit insert is an added
internal step, not a new field on any public return value.

`promote_active_definition/5`'s R10 (`review_id: nil`) path goes through the same widened
`write_target_definition/5` and therefore gets an audit entry too — `review_id: nil` is
already an admitted value in `entry_attrs()`'s shape (`actor_id`, not `review_id`, is the
only identity-like optional field `Letflow.Audit.entry_attrs()` defines; see §1.4 for
where `review_id` actually lives in the written row).

### 1.4 `audit_entry` action/details shape — reusing `DEFINITION_PROMOTED`'s payload, not a second schema

`Letflow.Audit.entry_attrs()` has no generic "details" field — its two content-carrying
fields are `before_state` and `after_state` (each `map() | nil`). Per the acceptance
criterion ("reusing the `DEFINITION_PROMOTED` event payload's fields rather than
inventing a second schema"), the new call site's `attrs` map is:

```
%{
  actor_id: actor_id,
  action: "definition.promote",
  resource_type: "definition",
  resource_id: new_row.id,
  before_state: nil,
  after_state: %{
    event_type: "DEFINITION_PROMOTED",
    actor_id: actor_id,
    review_id: review_id,
    source_tenant_id: source_tenant_id,
    target_tenant_id: target_tenant_id,
    source_definition_id: source_row.id,
    target_definition_id: new_row.id,
    process_key: process_key
  },
  trace_id: nil
}
```

`after_state`'s map is **field-for-field identical** to `append_promotion_event/9`'s
existing `event_attrs` (`promotion.ex:422-431`) — the same 8 keys, same values, same
source variables (`source_row`, `new_row`, both already in scope in
`write_target_definition/5` after step 8(b)). No second event-shape is defined anywhere;
this is the one place both the audit row and the platform event derive their content
from, kept as one literal shape used twice, not copied and drifted.

- `action: "definition.promote"` — follows the existing `"definition.<verb>"` naming
  convention `definitions.ex`'s own actions use (`definition.create`,
  `definition.activate`, `definition.deprecate`, `definition.archive`).
- `resource_type: "definition"` / `resource_id: new_row.id` — matches every other
  `definitions.ex` audit call site: the resource being described is the target row this
  operation just created and activated, the same row `promote_result().target_definition_id`
  names.
- `before_state: nil` — deliberate, not an omission: this operation's mutation spans two
  rows in general (the newly-inserted target row, and whatever row
  `deprecate_previous_active/2` demoted, which that function does not currently `select:`
  and return). Rather than adding a second, less-well-established "before" concept
  (a different row's prior state) to this one entry, `before_state` stays `nil` — exactly
  how `definitions.ex:1859`'s own `record_definition_audit("definition.create", ...)` call
  already handles "no meaningful before-state" for a fresh row. `after_state` alone
  already carries every field EO-004's "what was approved... when it went live" wording
  needs (source/target ids, review linkage, actor, process key); the row's own
  `timestamp` column supplies "when."
- `trace_id: nil` — no trace-id concept threaded through the promotion pipeline today;
  matches `definitions.ex`'s own call sites, all of which pass `trace_id: nil`.

### 1.5 What this closes, and what it does not

Once this ships, `GET /api/v1/audit`, called by a caller scoped to the **target** tenant
(the schema `write_target_definition/5` transacts in), returns a `resource_type:
"definition"`, `action: "definition.promote"` row with a real `actor_id` and `timestamp`
for the release — closing EO-004's "release" leg. It does **not**, by itself, produce
rows for the "proposal" or "approval" legs (§0's scope note, and §4's open question) —
those remain unaddressed by this design.

## 2. GAP B — read path: dedicated platform-events endpoint, not a scoped exception in `timeline/3`

### 2.1 Decision

**(a) — a new, dedicated platform-events read endpoint.** Rejects (b), a scoped exception
in `Instances.timeline/3`/`ensure_instance_exists/2` for the `platform_instance_id`
sentinel.

### 2.2 Does `GET /api/v1/audit` alone (once §1 ships) satisfy EO-004? No — stated, not assumed

`audit_entries` is strictly tenant-scoped (`Letflow.Audit.list_entries/1` requires
`:prefix`; `Letflow.Routers.Audit`'s own moduledoc calls this "the sharpest INV-1 case in
this requirement" — no query parameter, header, or body field can widen it to another
tenant). A promotion event, by construction, names **two** tenants
(`source_tenant_id`/`target_tenant_id` in the very payload §1.4 defines). §1's new audit
row lives only in the **target** tenant's `audit_entries`. A source-tenant caller's own
`GET /api/v1/audit` — the tenant where the "proposal" and "approval" legs would live, if
`PromotionReviewStore` ever writes them — will **never** show the release entry, and a
target-tenant caller's `GET /api/v1/audit` will never show the proposal/approval entries.
EO-004's own wording ("the change history for **this process**... in that order") reads
as one coherent timeline, not "query two different tenants' `/audit` feeds and merge them
client-side" — no code in this codebase does such a merge, and this design does not invent
one. So §1 alone narrows the gap but does not close it end-to-end, and a second, explicit
read surface is still warranted independent of whether proposal/approval audit entries are
ever designed.

Separately: the raw `events`-table row `PlatformEvents.append_definition_promoted/2`
writes is the actual source-of-truth record ISS-0733's own pilot needed and could not find
("this pilot could not distinguish 'the event was appended somewhere not yet checked' from
'the append silently failed'"). `Letflow.Audit`'s own moduledoc is explicit that
`audit_entries` is a **derived** compliance trail, deliberately decoupled from any other
side effect's own success/failure (see §1.2 point 3) — so the event-store row and the
audit row are not interchangeable even where their tenant scope happens to coincide; only
the event-store row proves what `EventStore.append_platform_event/2` itself actually
persisted.

### 2.3 Why not (b), a scoped exception in `Instances.timeline/3`

1. **`platform_instance_id/0` never having an `instance_projections` row is a documented
   invariant, not an oversight** (`event_store.ex:871-879`: "Never inserted into
   `instance_projections`"). Special-casing `ensure_instance_exists/2` to bypass that
   check for one specific UUID either (a) requires inserting a real
   `instance_projections` row for the sentinel — contradicting the documented
   invariant — or (b) requires a second code path through `ensure_instance_exists/2`
   that the acceptance criterion "does not weaken any existing test-asserted behaviour of
   ... `GET /api/v1/instances/:id/timeline` for a real (non-platform) instance id"
   directly warns against touching. A new, separate endpoint carries zero risk of
   regressing that path at all — it is not reachable from
   `Letflow.Routers.Instances`/`Letflow.Instances.timeline/3` in any way.

2. **The authorization boundary is not the same, and conflating the routes would make it
   easy to get that wrong.** `GET /instances/:id/timeline` is gated by `:InstancesRead`
   (`routers/instances.ex:367`) — a broad, ordinary per-tenant read permission. A
   platform-promotion event's payload names another tenant by id (`source_tenant_id`) —
   disclosing that to every role holding `:InstancesRead` would be a new cross-tenant
   disclosure through a permission that was never scoped with that in mind. A dedicated
   route makes the (deliberately stricter — §2.5) authz decision a first-class, visible
   choice instead of inheriting `:InstancesRead`'s existing, broader grant by accident.

3. **Architectural fit**: `Letflow.Routers.Promotions`'s own moduledoc already documents
   a `:Unknown`/PLATFORM_ADMIN-only gate for every promotion-pipeline route, "a
   considered decision... not an unhandled fallthrough." A platform-events read is a
   promotion-pipeline concern (today, the only event type it would ever surface is
   `DEFINITION_PROMOTED`; `PlatformEvents` also owns
   `append_promotion_assertion_teardown_failed/2`, so this is naturally an
   extensible family, not a one-off), so it belongs beside that router's other seven
   routes, not layered onto the instance-timeline surface as a special case.

### 2.4 New route: `GET /promotions/platform-events` (R11)

Added to `Letflow.Routers.Promotions` (full path `/api/v1/promotions/platform-events`),
using the same `:Unknown`/plain-macro (no `:policy_key`) declaration every other route in
that module already uses — PLATFORM_ADMIN-only, per that router's own already-established
§4 decision, not a new permission.

```
get "/platform-events" do
  handle_platform_events(conn)
end
```

Declared **before** `get "/:id"` (same ordering discipline the moduledoc's route table
already documents for `/plan`) so the literal `platform-events` segment is never captured
by the `:id` wildcard.

Scoped exactly like every other route on this router and like `GET /audit`: reads
`conn.assigns.scoped_opts`'s `:prefix`, derived solely from the caller's own
`auth_context.tenant_id` — no tenant-selecting query parameter or body field. A caller
scoped to the target tenant sees that tenant's own platform-sentinel event stream
(including any `DEFINITION_PROMOTED` row landed there as a promotion target); a caller
scoped to the source tenant does not, by the same INV-1 boundary `GET /audit` already
enforces. This is a deliberate consequence, not a gap this design leaves open: it mirrors
exactly how §1's new audit row is *also* only visible to a target-tenant-scoped caller,
so the two read surfaces (derived audit row, raw event row) agree on which tenant can see
"the release" without this design introducing any new cross-tenant read path.

### 2.5 New context function: `Letflow.EventStore.list_platform_events/1`

Lives in `lib/letflow/event_store.ex` (already owns `platform_instance_id/0` and the
REQ-026 read functions `read/2`, `read_global/1`, `point_in_time/3` — the natural home for
one more platform-scoped read, not a new module).

```
@type platform_event_item :: %{
        event_id: Ecto.UUID.t(),
        event_type: String.t(),
        actor_id: Ecto.UUID.t() | nil,
        timestamp: DateTime.t(),
        sequence_num: integer(),
        payload: map()
      }

@type list_platform_events_params :: %{
        required(:prefix) => String.t(),
        required(:page_size) => pos_integer(),
        optional(:cursor) => {integer(), Ecto.UUID.t()} | nil,
        optional(:event_type) => String.t() | nil
      }

@spec list_platform_events(list_platform_events_params()) ::
        {:ok, %{items: [platform_event_item()], next_cursor: String.t() | nil}}
```

Query shape: `Event` `where: e.instance_id == ^platform_instance_id()`, optional
`e.event_type == ^event_type` predicate when `:event_type` is present (mirrors
`Routers.Audit`'s `resource_type` filter — narrows only, never widens), ordered
`asc: e.sequence_number` (same ordering `Instances.timeline/2` already uses for its own
per-instance event page, and consistent with `uq_event_sequence`'s
`(instance_id, sequence_number)` uniqueness — the sentinel's own sequence is
gap-tolerant-monotone exactly like any real instance's), same `page_size + 1`/drop-the-
extra-row cursor idiom `Instances`/`Audit`/`ServiceCatalog` already share. `payload` is
returned decoded (`Jason.decode!/1` of the stored `:map`-typed column — already a decoded
map at the Ecto level, no further decode needed at the context layer; stated here only to
confirm it is **not** re-encoded to a JSON string for the response).

No `process_key`/`review_id`/tenant filter at the context-function level: those fields
live inside `payload`, not as their own `events` columns (§1.4's shape), so filtering on
them would require a JSON-path predicate this design does not introduce — page-size-bounded
listing plus client-side inspection of `payload` is sufficient for EO-004's stated need
("shows... in order with timestamps"), and matches `Routers.Audit`'s own precedent of not
building a filter for every field embedded in a JSON column.

### 2.6 Router handler and response shape

```
@spec handle_platform_events(Plug.Conn.t()) :: Plug.Conn.t()
```

Query-parameter handling mirrors `Routers.Audit`'s `handle_list/1`: `page_size`
(`Letflow.Api.Pagination`), `cursor` (a new, distinct cursor-endpoint prefix, e.g. `"PE:"`
— must not collide with `"A:"`/`"IL:"`/`"IH:"`/`"IT:"`/`"T:"`/`"U:"` already in use
elsewhere, so `decode_cursor/4`'s `{:error, :wrong_endpoint}` still rejects a
cursor minted by another endpoint), optional `event_type` — same 400/422 error-mapping
convention `Routers.Audit` already establishes for `:invalid_cursor`/`:invalid_page_size`.

Response body (hand-built allowlist, same discipline as `Routers.Audit`'s `audit_item/1`
and `Instances`' `timeline_item_map/1` — never a raw struct/`Jason.Encoder` derivation):

```
%{
  "items" => [
    %{
      "event_id" => ...,
      "event_type" => ...,
      "actor_id" => ...,
      "timestamp" => iso8601(...),
      "sequence_num" => ...,
      "payload" => ...
    },
    ...
  ],
  "next_cursor" => ... | nil
}
```

No `"count"` key (unlike `/audit`) unless a later requirement asks for one — not needed to
satisfy EO-004 and not invented speculatively here.

### 2.7 Confirms the untouched acceptance criterion

`Letflow.Instances.timeline/3`, `ensure_instance_exists/2`, and
`Letflow.Routers.Instances`'s `/:id/timeline` route are **not modified anywhere in this
design** — GAP B is closed entirely by new code in `Letflow.Routers.Promotions` and
`Letflow.EventStore`, so the acceptance criterion "does not weaken any existing
test-asserted behaviour of ... `GET /api/v1/instances/:id/timeline` for a real
(non-platform) instance id" holds by construction (nothing in that path changes).

## 3. Files touched by this design

| File | Change |
|---|---|
| `lib/letflow/definitions/promotion.ex` | `write_target_definition/4` → `/5` (new `audit_context` param); new internal step 8(c) inside its existing `Repo.transaction/1`; `do_promote_definition/7`'s call site passes the widened argument. No public-function signature changes (`promote_definition/3`, `promote_active_definition/5`, `apply_review/4` all unchanged). |
| `lib/letflow/event_store.ex` | New `list_platform_events/1` (§2.5), alongside the existing platform-sentinel accessors and REQ-026 read functions. |
| `lib/letflow/routers/promotions.ex` | New route `GET /platform-events` (R11), `handle_platform_events/1`, response-shaping helpers (§2.6). `:Unknown`-gated, matching every existing route in this module — no `Letflow.Api.Authorization` change. |

`lib/letflow/audit.ex` and `lib/letflow/instances.ex` are **not modified** by this design
— both are read-only inputs the fix reuses as-is (`Audit.insert_entry/3`'s existing
contract; `Instances.timeline/3` untouched per §2.7).

## 4. Open questions (explicit, not silently resolved)

- **OQ-1 (scope, carried from §0):** EO-004 asks for "proposal, approval, release" in
  order. This design closes only "release" (GAP A) plus a raw-event verification surface
  for it (GAP B). `PromotionReviewStore.insert_review/2`/`approve_review/4`/
  `reject_review/3` call `Letflow.Audit` nowhere today — whether the "proposal"/"approval"
  legs need their own audit-write design (a `PromotionReviewStore` change, structurally
  the same shape as §1 but against `promotion_reviews`, not `process_definitions`) is a
  real, unresolved question this artefact does not answer. Recommend routing to
  REQ-ANALYST/ISSUE-FIXER as a follow-up once this fix is verified, rather than assuming
  it is covered.
- **OQ-2:** `deprecate_previous_active/2` does not currently `select:` the row it
  deprecates, so §1.4's `before_state: nil` decision is partly a consequence of that —
  if a future requirement wants the previously-active row's own before/after state
  captured too (a second, distinct audit entry, resource_id = the demoted row's own id),
  that is a separate design, not folded into this one.
- **OQ-3:** §2.4's new route inherits the same `permission_checker`-is-always-true gap
  `Routers.Promotions`'s own moduledoc already escalates to SECURITY-REVIEWER (§7.9,
  "not resolved here") for every other route in this module — not a new gap introduced
  by this design, but SECURITY-REVIEWER should confirm this route doesn't need its own,
  narrower treatment given it now also surfaces `source_tenant_id` in a payload to a
  target-tenant-scoped caller.

## 5. Acceptance-criteria mapping

| Handoff acceptance criterion | Design element covering it |
|---|---|
| States and justifies the GAP A transactionality decision, with `@spec`-level description of the new/changed call site(s) | §1.1, §1.2, §1.3 |
| Specifies the exact `audit_entry` action/details shape, reusing `DEFINITION_PROMOTED`'s payload fields | §1.4 |
| States and justifies the GAP B read-path decision, with the authz boundary named explicitly if a new/changed route is designed | §2.1, §2.2, §2.3, §2.4 (authz), §2.5-§2.6 |
| No `.ex` function bodies | Entire document — signatures/`@spec`s/data shapes/prose only |
| Does not weaken any existing test-asserted behaviour of `definitions.ex`'s own Audit call sites or of `GET /api/v1/instances/:id/timeline` for a real instance id | §1.2 point 5, §2.7, §3 (files-touched table) |
