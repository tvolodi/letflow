# Design: instance-attachment history entries + approval-decision attachment attribution (REQ-391)

**Status:** design, pending CODE-DESIGN-VALIDATOR.
**Requirement:** REQ-391 (`docs/requirements.yaml`, letflow-queue task 751, GH-1639, stage S6).
**Filed from:** `test/uat-reports/gui-review-2026-09-20-shipment-attach-delivery-note.md` (PW-09),
EO-004 (history shows attach + removal, by whom) and EO-005 (approval record names the
document reviewed).
**Depends on:** REQ-211 (`lib/letflow/design/req211-instance-attachments-core.md`), REQ-212
(`lib/letflow/design/req212-instance-attachments-routes.md`) — both `status: done`.
**Sibling requirements (not in scope here):** REQ-389 (content-type allowlist), REQ-390
(storage-quota), REQ-392 (frontend rendering of everything this design adds).

## 0. What exists today (read in full before this design, not assumed)

- `Letflow.Repository.Attachments.upload/2` / `delete/2`
  (`lib/letflow/repository/attachments.ex`) — REQ-211's core lifecycle. Neither calls into
  any history/event mechanism today. `upload/2` already runs inside one
  `Repo.transaction(fn -> ... end)` (not an `Ecto.Multi`); `delete/2` is a bare
  `with {:ok, attachment} <- get(id, opts) do Repo.delete(attachment, prefix: prefix) end`,
  no transaction wrapper of its own.
- **The instance history/timeline mechanism is `Letflow.EventStore` (REQ-025/026) +
  `Letflow.Instances.history/3` and `.timeline/3` (REQ-080/200)**, backed by the single
  `events` table (`Letflow.EventStore.Event`) — there is no second, attachment-specific
  history store to build; this design reuses `EventStore.append/2` exactly as every other
  instance-mutating operation in this codebase does (`Letflow.Engine.complete_task/3`,
  `cancel_instance/3`, etc.).
- **Event types must be pre-registered per tenant** in `event_type_registry`
  (`Letflow.EventStore.Registry.register_type/2`) or `EventStore.append/2` fails closed with
  `{:error, :unknown_event_type}` (`Registry.validate_payload/3` → `get_type/2`). Registration
  happens at tenant-provisioning time via `Letflow.TenantProvisioning`'s
  `@platform_event_type_seed_attrs` list (`lib/letflow/tenant_provisioning.ex:843+`) — this is
  the established mechanism for adding a new platform event type, and widening it **only
  affects tenants provisioned from that point on**; already-provisioned tenants need a
  `Letflow.TenantProvisioning.Backfill.run/1` call (ISS-0332's own precedent, same module) to
  pick up a new/bumped type. This is *not* new code invented for this requirement — it is the
  project's one existing on-ramp for a new event type, reused verbatim.
- **`Letflow.Instances.timeline/3`** additionally renders a human-readable `description` per
  event type via a private, exhaustive-with-fallback `render_description/3` clause list
  (`lib/letflow/instances.ex:264-298`) — one clause per known `event_type`, trailing fallback
  for anything else (tenant Lua scripts can emit arbitrary `event_type`s via
  `emit_event`, so this must never raise).
- **There is no separate "decision record" schema.** The ops-manager's approve/reject action
  (this scenario's step 5) is an ordinary `Letflow.Engine.complete_task/3` call — REQ-391's
  premise text calls this "whatever mechanism records the ops-manager's approve/reject
  decision," and the answer, confirmed by reading `lib/letflow/engine.ex:1856-2003` (M9,
  `append_task_completed_event/5`, `lib/letflow/engine.ex:4092-4118`) is: **the `TASK_COMPLETED`
  event's own JSON payload**, whose `output_variables` field already carries whatever the
  completing form submitted (an "approve"/"reject" decision is just one more output variable,
  same as any other form field — there is no engine-level concept of "this task is an
  approval task"). This is the mechanism item 2 below extends. Confirmed via grep: zero hits
  for any schema/table referencing `instance_attachments`/`content_hash`/`attachment_id` from
  an approval/decision-recording path, matching the requirement text's own finding.
- `GET /instances/:id/history` and `/timeline` are gated by `InstancesRead`
  (`lib/letflow/routers/instances.ex:367-372`). `POST/GET/DELETE /instances/:id/attachments*`
  are gated by `AttachmentsManage`/`AttachmentsRead` (REQ-212) — a **different** permission.
  This is a real cross-permission-boundary question, not a formality — see §6.

## 1. Scope, restated

1. `upload/2` and `delete/2` each append one `Letflow.EventStore` event to the owning
   instance's stream, naming the action, `file_name`, and actor. `delete/2` gains a new
   required `deleted_by` parameter (§2, signature change, flagged for REVIEWER).
2. `Letflow.Engine.complete_task/3`'s existing `TASK_COMPLETED` event payload gains an
   `attachments_at_decision` field: a **snapshot** of the instance's currently-present
   attachments' `id`/`file_name`/`content_type`/`byte_size`/`uploaded_by`/`created_at`, taken
   at task-completion time (§4 — snapshot-vs-live-reference decision, with justification).

Out of scope (per the requirement text): any frontend rendering (REQ-392); which
existing approve/decision mechanism to hook into — resolved above (there is no dedicated
one; it's `complete_task/3`'s own `TASK_COMPLETED` event).

## 2. `upload/2` / `delete/2` — history-entry recording

### 2.1 New event types (seeded, not free-form)

Two new platform event types added to `Letflow.TenantProvisioning`'s
`@platform_event_type_seed_attrs` (same list `INSTANCE_STARTED`/`TASK_COMPLETED`/
`INSTANCE_CANCELLED`/etc. already live in), each `schema_version: 1`:

```
%{
  name: "ATTACHMENT_ATTACHED",
  schema_version: 1,
  description: "Emitted by Letflow.Repository.Attachments.upload/2 (REQ-391) when an " <>
    "attachment is added to an instance.",
  json_schema: %{
    "type" => "object",
    "properties" => %{
      "attachment_id" => %{"type" => "string"},
      "file_name" => %{"type" => "string"},
      "content_type" => %{"type" => "string"},
      "byte_size" => %{"type" => "integer"},
      "description" => %{"type" => ["string", "null"]}
    },
    "required" => ["attachment_id", "file_name", "content_type", "byte_size"]
  }
}
```

```
%{
  name: "ATTACHMENT_REMOVED",
  schema_version: 1,
  description: "Emitted by Letflow.Repository.Attachments.delete/2 (REQ-391) when an " <>
    "attachment is removed from an instance.",
  json_schema: %{
    "type" => "object",
    "properties" => %{
      "attachment_id" => %{"type" => "string"},
      "file_name" => %{"type" => "string"},
      "content_type" => %{"type" => "string"},
      "byte_size" => %{"type" => "integer"}
    },
    "required" => ["attachment_id", "file_name", "content_type", "byte_size"]
  }
}
```

`actor_id` (the `EventStore.append/2` field, not a payload field) carries `uploaded_by`
for attach and `deleted_by` for remove — matching every other event type's convention of
putting "who" in `actor_id`, not duplicated into the payload (`TASK_COMPLETED` does the
same: `output_variables` never repeats `actor_id`). **FLAGGED FOR REVIEWER (operational,
not code):** existing tenants provisioned before this requirement ships will not have these
two types registered until `Letflow.TenantProvisioning.Backfill.run/1` is invoked once per
new type against every existing `Registration` row — same ISS-0332 precedent already on
record for `DEFINITION_PROMOTED`/`TASK_COMPLETED`'s own schema bumps. This is an ops step
ELIXIR-DEV's handoff must call out explicitly (e.g. a one-time mix task or a note in the
implementation PR), not something this design silently assumes happens.

### 2.2 `idempotency_key` derivation

`EventStore.append/2` requires `idempotency_key` (unique per tenant schema, across *all*
event types — `uq_event_idempotency_key` is a single-column unique index, not scoped to
`event_type`). Both new call sites derive it from the attachment's own `id` (already a
fresh, tenant-schema-unique UUID by the time either call site runs):

- attach: `"attachment_attached:" <> attachment.id`
- remove: `"attachment_removed:" <> attachment.id`

Each attachment row can only be uploaded once (fresh UUID) and deleted once (hard delete,
`get/2` returns `{:error, :not_found}` on a second `delete/2` call for the same id before
any event-append is attempted) — so neither derived key can collide with itself. This
mirrors the existing self-derived-key precedent already used internally for
system-cascaded events (e.g. sub-process/timer-cascade call sites in `lib/letflow/engine.ex`
derive `idempotency_key` from an already-unique record id rather than accepting a
caller-supplied header, since neither `upload/2` nor `delete/2` currently accepts or plumbs
a client `Idempotency-Key` for this internal side-write).

### 2.3 Best-effort, post-commit placement (not a `Multi` step, not INSIDE the primary write's transaction)

**Decision: the event append is a best-effort side effect performed AFTER the primary DB
write (`instance_attachments` insert/delete) has already committed**, mirroring
`Letflow.Engine.complete_task/3`'s own `emit_task_completed_telemetry/3` pattern (called
after the `Multi`/transaction returns `{:ok, _}`, never inside it) — not the ISS-0784
audit-write pattern (which fires on the ROLLED-BACK branch; this is the opposite case, the
COMMITTED branch).

**Why not inside the same transaction:** `EventStore.append/2`'s M1 step
(`active_instance_guard`) rejects the append with `{:error, :instance_not_started}` or
`{:error, {:instance_terminated, :completed | :cancelled}}` if the owning instance is not
`ACTIVE`. Today, `upload/2`/`delete/2` carry **no** instance-state check at all — an
attachment can be added to or removed from a `COMPLETED`/`CANCELLED` instance (e.g.
attaching a signed delivery note as audit evidence after a shipment instance already
completed, which is exactly this scenario's own motivating use case). If the event-append
call were folded into the same transaction as the attachment write and its failure were
allowed to roll that transaction back, attaching/removing on a non-`ACTIVE` instance would
silently start failing — a real, unintended behavior regression this design must not
introduce. Nested `Repo.transaction/1` calls are otherwise safe in Ecto (a transaction
opened from inside another reuses the same connection/transaction rather than requiring a
savepoint), so nesting was considered and rejected specifically for this failure-coupling
reason, not for a mechanical limitation.

**Concretely:**
- `upload/2`: after `do_upload_after_scan/6`'s `Repo.transaction/1` call returns
  `{:ok, attachment}`, call the new private helper `record_attachment_attached_event/2`
  (below) with the committed `attachment` struct and `prefix`, before `upload/2` itself
  returns `{:ok, attachment}` to its caller.
- `delete/2`: after `Repo.delete(attachment, prefix: prefix)` returns `{:ok, deleted}`,
  call `record_attachment_removed_event/3` with the pre-delete `attachment` struct (already
  held in scope from the `get/2` call earlier in the `with`), `deleted_by`, and `prefix`.

A failure from either helper (unknown event type on an unbackfilled tenant, terminated
instance, a `{:error, {:sequence_conflict, _}}` race, or any other `EventStore.append/2`
error) is caught, logged via one `Logger.warning/2` call (same audit-log-on-reject idiom
`upload/2` already uses for `log_infected_upload_attempt/3`), and **does not change
`upload/2`'s/`delete/2`'s own return value** — the attachment write's success/failure
contract is unchanged from REQ-211's own shipped behavior. This is a deliberate
best-effort/fail-open choice for the history signal, the opposite of the scan's
fail-closed guarantee, and is explicitly flagged here as a monitoring gap (a missed history
entry is observable only via the `Logger.warning/2` line) rather than silently presented as
"can't happen."

### 2.4 New function surfaces (signatures only)

```
@spec record_attachment_attached_event(Attachment.t(), prefix :: String.t()) :: :ok
```
Builds `payload = Jason.encode!(%{attachment_id: ..., file_name: ..., content_type: ...,
byte_size: ..., description: ...})` from the given `%Attachment{}`, calls
`EventStore.append(%{instance_id: attachment.instance_id, event_type: "ATTACHMENT_ATTACHED",
payload: payload, actor_id: attachment.uploaded_by, idempotency_key: "attachment_attached:" <>
attachment.id}, prefix: prefix)`, logs+swallows any `{:error, _}`. Always returns `:ok`.

```
@spec record_attachment_removed_event(Attachment.t(), deleted_by :: Ecto.UUID.t(), prefix :: String.t()) :: :ok
```
Same shape, `event_type: "ATTACHMENT_REMOVED"`, `actor_id: deleted_by`,
`idempotency_key: "attachment_removed:" <> attachment.id`. Always returns `:ok`.

Both are private to `Letflow.Repository.Attachments`.

### 2.5 `delete/2`'s signature change — FLAGGED FOR REVIEWER

**Current (REQ-211, shipped, `status: done`):**
```
@spec delete(id :: String.t(), opts()) :: {:ok, Attachment.t()} | {:error, :invalid_id | :not_found}
```

**New:**
```
@spec delete(id :: String.t(), deleted_by :: Ecto.UUID.t(), opts()) ::
        {:ok, Attachment.t()} | {:error, :invalid_id | :not_found}
```

This is a breaking arity change to an already-`done` REQ-211 function, flagged for
REVIEWER the same way REQ-211's own design flagged its own cross-module changes (per this
requirement's own text). `deleted_by` is not independently validated (no UUID-cast check) —
same posture `complete_task/3`'s `attrs[:actor_id]` already has, plumbed straight through
to `EventStore.append/2`'s own validation (`fetch_uuid/3`, `{:error, :missing_actor_id}` on
a `nil`).

**Known caller to update (grepped, exhaustive):**
- `lib/letflow/routers/instances.ex:1435`, `handle_delete_attachment/3` — currently
  `Attachments.delete(raw_attachment_id, opts)`. The router already resolves the
  authenticated caller via its existing `actor_id(conn)` helper (used identically by
  `handle_upload_attachment/2` at line 1015) — becomes
  `Attachments.delete(raw_attachment_id, actor_id, opts)`, actor resolved before the delete
  call, same as upload's own `{:ok, actor_id} <- actor_id(conn)` step.
- `test/letflow/repository/attachments_test.exs:517` — every direct `Attachments.delete/2`
  call in this test file needs updating to the new 3-arity form (TEST-DESIGNER's job, not
  this design's, but named here so it isn't missed).
- **Not** `Letflow.Repository.EntityAttachments.delete/2` (`lib/letflow/repository/
  entity_attachments.ex`) — a structurally similar but entirely separate module/table
  (`entity_record_attachments`, REQ-313), out of scope; this requirement's text and
  acceptance criteria name only `Letflow.Repository.Attachments`.

### 2.6 Timeline `description` rendering (`Letflow.Instances`)

Two new clauses added to `render_description/3` (`lib/letflow/instances.ex:264-298`), same
shape as the existing `TASK_COMPLETED`/`INSTANCE_CANCELLED` clauses:

```
@spec render_description(Event.t(), actor :: String.t(), payload :: map()) :: String.t()
```
One new clause matches `%Event{event_type: "ATTACHMENT_ATTACHED"}` and produces
`"<file_name> attached by <actor>"`, reading `file_name` out of `payload`. A second new
clause matches `%Event{event_type: "ATTACHMENT_REMOVED"}` and produces the same shape with
"removed" in place of "attached". Both draw `file_name` and `actor` the same way the
existing `TASK_COMPLETED`/`INSTANCE_CANCELLED` clauses already do.

Without this, `GET /instances/:id/timeline` would still return a syntactically valid
`description` via the existing trailing fallback clause (`"Event ATTACHMENT_ATTACHED by
<actor>"`), so this is not strictly required to satisfy AC1/AC2's literal wording (both
ACs are stated against "the existing history/timeline read path," and `GET .../history`
already surfaces the raw `payload` — including `file_name` — verbatim via
`history_item_map/1`, REQ-391's AC1/AC2 test target). Adding these two clauses is included
anyway because leaving a real, known event type on the generic fallback would be a
readability regression the moment REQ-392's frontend renders `description` directly, and
matches this file's own stated convention ("one clause per real event type this codebase
can append").

## 3. `complete_task/3` — `attachments_at_decision` on `TASK_COMPLETED`

### 3.1 New read: current attachments for the instance, unpaginated

`Letflow.Repository.Attachments.list/2` is cursor-paginated (`page_size` capped by
`Letflow.Api.Pagination`) — wrong shape for "every attachment currently on this instance,"
which this snapshot needs in full, not one page. New function:

```
@spec list_all_for_instance(instance_id :: Ecto.UUID.t(), opts()) :: [Attachment.t()]
```
Added to `Letflow.Repository.Attachments`: `Repo.all(from a in Attachment, where:
a.instance_id == ^instance_id, order_by: [asc: a.created_at, asc: a.id]), prefix:
opts[:prefix])` — no pagination, no cursor, tenant-scoped via `opts[:prefix]` exactly like
every other query in this module (INV-1). Not exposed over HTTP — internal-use only,
called from `Letflow.Engine`, same "context module exposes a read `Letflow.Engine` needs
directly" shape `Letflow.ServiceCatalog.list_all/1` already established (REQ-191/192,
cited by this same file's own `get_content/2` moduledoc) for the identical
`Repo`-call-must-stay-inside-a-context-module reason (INV-RT-1-adjacent discipline, even
though `Letflow.Engine` is not itself route-layer code — this keeps the convention uniform
rather than letting `Letflow.Engine` issue a `Repo.*` call against a table it doesn't own).

Bounded by construction to "attachments actually on one instance," which this scenario's
own motivating use case (a handful of shipment documents) keeps small; no explicit cap is
added, flagged here as an open question for REVIEWER if a future tenant's usage pattern
makes an unbounded per-instance attachment count a real concern (REQ-390's storage-quota
work is the more natural place to bound this, not this requirement).

### 3.2 New call site: inside `complete_task/3`'s existing Multi, same transaction

Unlike §2.3's attach/remove events, this read-and-embed happens **inside**
`complete_task/3`'s own `Ecto.Multi`/transaction (in `append_task_completed_event/5`,
`lib/letflow/engine.ex:4092-4118`) — not as a post-commit best-effort step. This is
deliberate and different from §2.3's choice: `complete_task/3` already guarantees the
instance is `ACTIVE` at this point (M1's `active_instance_guard` already ran successfully
earlier in the same Multi, or the whole call would already have failed) — there is no
terminated-instance edge case to protect against here, so there is no reason to weaken the
existing all-or-nothing guarantee: if the attachment snapshot can't be read, the task
completion itself should not silently commit without it. `list_all_for_instance/2` is
called with the same `prefix` already threaded through the rest of this function; its
result is mapped into the new payload field before `Jason.encode!/1`.

### 3.3 `TASK_COMPLETED` schema bump: `schema_version` 2 → 3

New optional payload field, added the same way the 1→2 bump (REQ-292, already on record in
`tenant_provisioning.ex`) widened `merged_variable_events`:

```
"attachments_at_decision" => %{
  "type" => "array",
  "items" => %{
    "type" => "object",
    "properties" => %{
      "attachment_id" => %{"type" => "string"},
      "file_name" => %{"type" => "string"},
      "content_type" => %{"type" => "string"},
      "byte_size" => %{"type" => "integer"},
      "uploaded_by" => %{"type" => "string"},
      "created_at" => %{"type" => "string"}
    },
    "required" => ["attachment_id", "file_name"]
  }
}
```
`"required"` at the top level stays exactly `["task_id", "node_id", "output_variables",
"activated_nodes"]` — `attachments_at_decision` is always present (an instance with zero
attachments produces `[]`, per §3.1's unpaginated `Repo.all/2` returning `[]`, never
`nil`), but is not added to `"required"` for the same forward-compatibility reason
`merged_variable_events` itself isn't required: a pre-existing, unmigrated
`event_type_registry` row (schema_version 2, before this bump lands/backfills) must still
validate any TASK_COMPLETED payload appended against it during the rollout window — adding
a new required field would break that, not just widen it. **FLAGGED FOR REVIEWER (same
operational note as §2.1):** existing tenants need
`Letflow.TenantProvisioning.Backfill.run/1` invoked with this `schema_version: 3` attrs map
to pick it up; until then, `complete_task/3` still runs successfully against their
`schema_version: 2` row (the new field is additive/optional against the OLD schema too,
since `additionalProperties` is one of `JsonSchema`'s "permitted and inert" keywords per
its own moduledoc — an extra key a v2 schema doesn't declare is not rejected).

Field selection mirrors `attachment_json/1`'s existing INV-2 allowlist
(`lib/letflow/routers/instances.ex:1448-1458`) minus `instance_id`/`description` (redundant
at this scope) — **`content_hash` is deliberately excluded**, same reasoning as that
allowlist's own comment ("never included").

### 3.4 New cross-module dependency — FLAGGED FOR REVIEWER

`Letflow.Engine` (`append_task_completed_event/5`) gains a new call into
`Letflow.Repository.Attachments.list_all_for_instance/2`. This is a new coupling between
the workflow-completion path and the attachment subsystem that did not exist before this
requirement — noted explicitly rather than left implicit, per this requirement's own text
asking that cross-module changes be flagged the way REQ-211 flagged its own.

## 4. Snapshot vs. live reference — the decision AC4 requires, stated and justified

**Decision: snapshot.** `attachments_at_decision` embeds `attachment_id`, `file_name`,
`content_type`, `byte_size`, `uploaded_by`, `created_at` **directly into the immutable
`TASK_COMPLETED` event payload**, at the moment `complete_task/3` runs — not a bare
`attachment_id` requiring a later lookup.

**Why, concretely:**

1. **A live reference would go stale by construction, not by edge case.** `delete/2`
   (REQ-211 §4.5, confirmed by reading it directly) performs a **hard delete** of the
   `instance_attachments` row — there is no soft-delete/tombstone. A decision record
   holding only `attachment_id` would, after any subsequent `delete/2` call on that same
   attachment, resolve to `{:error, :not_found}` via `Attachments.get/2` — the exact
   scenario AC4 names ("a test demonstrates the chosen behavior across a subsequent removal
   of that same attachment"). A live reference is not merely weaker here; for this table's
   actual delete semantics it is a reference that is *guaranteed* to break the first time
   anyone exercises the removal path this same requirement (§2) adds history-tracking for.
2. **Matches this codebase's own established convention for "what a completed decision
   looked like."** `TASK_COMPLETED`'s existing `merged_variable_events` field already
   embeds full before/after values inline (`INV-EE48-5`, this module's own comment,
   `lib/letflow/engine.ex:4093-4096`: "embedded as informational metadata inside this one
   event's payload, never appended as their own separate rows") rather than pointing at a
   separate mutable table. `attachments_at_decision` follows the same already-decided
   convention, not a new one invented for this requirement.
3. **The event store itself is the append-only, immutable source of truth this platform
   already relies on for "what was true at time T."** Every other REQ-391-adjacent fact
   (who uploaded, who removed, when) is recorded the same way (§2) — a live-reference
   design for the approval record would be the only inconsistent piece, needing its own
   separate "what if the referent changed" story the rest of the event store never needs.
4. **Cost is bounded and one-time.** The snapshot is captured once, at decision time, from
   whatever attachments exist then (§3.1) — it does not need to track attachments added
   *after* the decision (out of scope; AC3 only asks about attachments "present ... at
   decision time"), and does not grow unboundedly since it is written once per
   `TASK_COMPLETED` event, not appended to.

**What this deliberately does NOT give a future reader:** if the *same* `content_hash`'s
bytes are later re-attached as a new `instance_attachments` row (a fresh `upload/2` call —
`repository_artifacts` content itself is never deleted, per `delete/2`'s own moduledoc), the
snapshot's `attachment_id` will not resolve to that new row — this is expected and correct
for a decision-time snapshot (the reviewed row, not the reviewed *bytes*, is what "the
attachment reviewed" means here), not a gap to close.

**Test requirement this implies (AC4):** a `complete_task/3` test that (a) uploads an
attachment, (b) completes a task while it is present (asserting
`attachments_at_decision` in the resulting `TASK_COMPLETED` event's payload names it), (c)
calls `delete/2` on that same attachment, (d) re-fetches the same historical `TASK_COMPLETED`
event via `Letflow.Instances.history/3` and asserts `attachments_at_decision` **still**
names the removed attachment's `file_name`/`attachment_id`, unchanged — demonstrating the
snapshot survived the removal exactly as designed. TEST-DESIGNER's job to write; named here
so the assertion shape is unambiguous.

## 5. Summary of all touched files (implementation surface, not code)

| File | Change |
|---|---|
| `lib/letflow/repository/attachments.ex` | `upload/2` calls new `record_attachment_attached_event/2` post-commit; `delete/2` gains `deleted_by` param (§2.5), calls new `record_attachment_removed_event/3` post-commit; new `list_all_for_instance/2` (§3.1) |
| `lib/letflow/tenant_provisioning.ex` | `@platform_event_type_seed_attrs` gains `ATTACHMENT_ATTACHED` v1, `ATTACHMENT_REMOVED` v1; `TASK_COMPLETED` bumped v2→v3 (§2.1, §3.3) |
| `lib/letflow/engine.ex` | `append_task_completed_event/5` reads `Attachments.list_all_for_instance/2` and adds `attachments_at_decision` to the `TASK_COMPLETED` payload (§3.2) |
| `lib/letflow/instances.ex` | `render_description/3` gains `ATTACHMENT_ATTACHED`/`ATTACHMENT_REMOVED` clauses (§2.6) |
| `lib/letflow/routers/instances.ex` | `handle_delete_attachment/3` resolves `actor_id(conn)` and passes it as `delete/2`'s new `deleted_by` arg (§2.5) |
| (ops, not code) | `Letflow.TenantProvisioning.Backfill.run/1` invoked twice (once per new/bumped event type) against existing tenants — named in the implementation handoff, not silently assumed |

## 6. SECURITY-REVIEWER determination: REQUIRED

**Yes, this requirement needs a SECURITY-REVIEWER pass**, for two distinct reasons:

1. **INV-1 (tenant data isolation).** Every new/changed write and read in this design
   threads `opts[:prefix]`/derives `tenant_id` the same way the code it's built on already
   does (`EventStore.append/2`, `Attachments.list_all_for_instance/2`, `complete_task/3`'s
   existing `prefix`) — no new caller-supplied `tenant_id` field is introduced anywhere.
   This should be a quick confirmation, not a real risk, but is exactly the kind of
   tenant-scoped write path INV-1's own "How to verify" section calls out as needing an
   explicit per-change check.
2. **INV-2 (server-side field authorisation) — a genuine, non-obvious cross-permission
   question, not a formality.** `GET /instances/:id/history` and `/timeline` are gated by
   `InstancesRead`. `POST/GET/DELETE /instances/:id/attachments*` are gated by a
   **different** permission, `AttachmentsRead`/`AttachmentsManage`. This design, exactly as
   the requirement text directs, makes attachment `file_name`/`content_type`/`byte_size`/
   `uploaded_by` visible through the `InstancesRead`-gated history/timeline routes (§2) and
   through `TASK_COMPLETED`'s payload (§3), which is itself also read via
   `InstancesRead`-gated routes. **A caller holding `InstancesRead` but not `AttachmentsRead`
   can now learn that an attachment exists, its file name, and who touched it — facts
   REQ-212's own permission gate was presumably meant to restrict to `AttachmentsRead`
   holders.** This design proceeds on the reading that REQ-391's own acceptance criteria
   explicitly mandate this (AC1/AC2/AC3 all require the fact be visible "over the existing
   history/timeline read path," which is unambiguously `InstancesRead`-gated) — i.e. the
   two permissions were never meant to be watertight against each other for
   already-attached-file *metadata* (as opposed to attachment *bytes*, which stay behind
   `AttachmentsRead`/signed-link mechanisms untouched by this design). This is stated here
   explicitly, not silently decided, because it is exactly the kind of permission-boundary
   question `security-invariants.md` INV-2 exists to catch, and SECURITY-REVIEWER's sign-off
   (or a documented, deliberate acceptance of this coupling) is this design's own
   recommended resolution — not a unilateral call by CODE-DESIGNER.

## 7. Open questions (not silently resolved)

- **OQ-1 (§6.2):** is `InstancesRead` learning attachment file names/uploader identity an
  accepted, intentional coupling, or does REQ-212's `AttachmentsRead` gate need to be
  additionally checked before a history/timeline event's payload is rendered? This design
  does not add such a check (REQ-391's own ACs don't ask for one, and doing so would need
  its own design/requirement), but flags it for SECURITY-REVIEWER rather than assuming.
- **OQ-2 (§2.1/§3.3, operational):** the exact mechanism/timing for invoking
  `Letflow.TenantProvisioning.Backfill.run/1` against already-provisioned tenants (a mix
  task run once at deploy time? invoked from a migration? left as a manual ops step per
  ISS-0332's own precedent, which itself doesn't answer this) is left to ELIXIR-DEV's
  implementation handoff — this design only establishes that the step is necessary and why.
- **OQ-3 (§3.1):** no cap on `list_all_for_instance/2`'s result size. Flagged for REVIEWER
  as a judgement call with no requirement-stated bound, same posture `@max_upload_bytes`
  and REQ-389's content-type allowlist both already carry as precedent for
  no-existing-requirement-value judgement calls in this subsystem.
