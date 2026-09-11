# REQ-313 — Design attachments on an entity record (S10 gap 3)

Status: design only. No `lib/` implementation, no route mounted, no migration, no test.
Implements none of the modules named below — this document specifies the schema, context
module, route table, permission vocabulary, and security posture for a future ELIXIR-DEV
requirement to build from.

Per decision 0022 rule 1: this document uses no domain-vertical vocabulary. "entity
type", "entity record", "attachment" are this subsystem's own generic nouns (already
used by `Letflow.Repository.Attachments` and `Letflow.Routers.Entities`), not any one
vertical's objects. "S10 gap 3" appears only as stage bookkeeping.

## 0. Premises re-verified before designing

```
$ grep -n "instance_id" lib/letflow/repository/attachments.ex | head -5
131:          required(:instance_id) => Ecto.UUID.t(),
253:          instance_id: Map.fetch!(attrs, :instance_id),
302:          required(:instance_id) => Ecto.UUID.t(),
327:        instance_id = Map.fetch!(params, :instance_id)
333:        |> where([a], a.instance_id == ^instance_id)
```
Confirmed: `Letflow.Repository.Attachments`' four functions (`upload/2`, `list/2`, `get/2`,
`delete/2`) operate on `instance_attachments`, keyed by `instance_id` only — no
`(entity_type, record_id)` pair anywhere in the module.

```
$ grep -n "authz_.*attachments" lib/letflow/routers/instances.ex
378:  authz_post "/:id/attachments", :AttachmentsManage do
382:  authz_get "/:id/attachments", :AttachmentsRead do
386:  authz_get "/:id/attachments/:attachment_id", :AttachmentsRead do
390:  authz_delete "/:id/attachments/:attachment_id", :AttachmentsManage do
```
Confirmed: REQ-212's four routes are `POST`/`GET /instances/:id/attachments` and
`GET`/`DELETE /instances/:id/attachments/:attachment_id`, all under `/instances/:id`, not
`/entities/records/:entity_type/:record_id`.

```
$ grep -n "records/:entity_type" lib/letflow/routers/entities.ex
215:  authz_post "/records/:entity_type", :EntitiesRecordsWrite do
219:  authz_put "/records/:entity_type/:record_id", :EntitiesRecordsWrite do
223:  authz_delete "/records/:entity_type/:record_id", :EntitiesRecordsWrite do
```
Confirmed: `Letflow.Routers.Entities` (mounted at `/entities`, REQ-310/311) already owns the
`/entities/records/:entity_type/:record_id` path shape this design nests under, and is
"one router, three sub-resources under their own literal first path segment" (its own
moduledoc §"one-router-not-two", req308 design §2) — the same one-router precedent this
design follows for attachments (§3 below).

```
$ grep -n "schema \"entity_record_latest\"" -A 8 lib/letflow/entities/record/latest.ex
28:  schema "entity_record_latest" do
29:    field(:entity_type, :string)
30:    field(:record_id, Ecto.UUID)
31:    field(:field_values, :map, default: %{})
```
Confirmed via `Letflow.Entities.Record.Latest`'s moduledoc/schema and REQ-296/0023: entity
records are NOT one shared table — decision 0023's hybrid storage puts every record's
canonical identity row in `entity_record_latest` (keyed by `entity_type` + `record_id`,
`record_id :: Ecto.UUID`, a caller/system-chosen id distinct from the row's own internal
`id`), and a "promoted" entity type additionally gets its own per-entity-type table,
dual-written and joined on that SAME `record_id` (`lib/letflow/design/req297-entity-
promotion-executor.md` line 494: `ON CONFLICT (record_id) DO UPDATE` against the
per-entity-type table). `record_id` is therefore the one identifier stable across both the
promoted and unpromoted storage shapes — this governs §1 below.

## 1. The schema — new table, keyed by `(entity_type, record_id)`

**Decision: a new table, `entity_record_attachments`, not an extension of
`instance_attachments`.**

**Why not extend `instance_attachments` with a nullable/polymorphic owner column.**
`instance_attachments.instance_id` is `null: false` (REQ-211 migration) and every one of
`Letflow.Repository.Attachments`' four functions' `@type`s hard-require `instance_id` —
making it nullable and adding a second, also-nullable `(entity_type, record_id)` pair would
turn a single-owner-column table into a polymorphic-association table with an implicit
"exactly one of instance_id or (entity_type, record_id) is set" invariant that nothing in
Postgres enforces by construction (a `CHECK` constraint could, but the codebase has no
existing polymorphic-FK precedent to follow, and REQ-211/212's own design explicitly scoped
`instance_attachments` to one owner concept — see that module's own "Scope boundary"
moduledoc section). A new table keeps `Letflow.Repository.Attachments` and
`instance_attachments` completely unchanged — zero regression risk to REQ-211/212's shipped
code — and keeps each table's `NOT NULL` owner column a real, enforced invariant.

**Why `(entity_type, record_id)`, not the record's internal `entity_record_latest.id`.**
REQ-296's per-entity-type hybrid storage (0023) means a record's row lives in
`entity_record_latest` always, and ALSO in a per-entity-type promoted table once that
entity type is promoted — two different tables, each with its own internal `id` primary
key column, but both dual-written keyed by the SAME `record_id` (req297 design line 494's
`ON CONFLICT (record_id)`). `record_id` is consequently the one identifier that:
  (a) is known to the HTTP caller (it is the `:record_id` path segment on every
      `/entities/records/:entity_type/:record_id` route already, per `entities.ex`'s
      `create_record`/`update_record`/`delete_record` handlers), and
  (b) resolves correctly regardless of whether the entity type is promoted.
`entity_record_latest.id` (its own `binary_id` primary key) is never exposed to callers
today — no route returns it, no route accepts it — so keying attachments by it would
require inventing a new caller-facing identifier this design has no reason to add.
`entity_type` is carried alongside `record_id` (not derived from it) because `record_id`
alone is not guaranteed globally unique across different entity types — mirroring
`entity_record_latest`'s own choice to carry both columns rather than `record_id` alone.

**Correction to an earlier draft of this section.** A prior version of this design claimed
`record_id` has "no unique index stated in its own schema module" and used that as part of
its justification for no DB-level FK. That claim is **false** — re-verified directly:
`lib/letflow/entities/record/latest.ex`'s `insert_changeset/2` (lines 61-63) calls
`unique_constraint([:entity_type, :record_id], name:
:entity_record_latest_entity_type_record_id_idx)`, and the backing migration
`priv/repo/migrations/20260906010001_create_entity_record_latest.exs` confirms a real
`unique_index(:entity_record_latest, [:entity_type, :record_id], name:
:entity_record_latest_entity_type_record_id_idx, prefix: schema)`. A genuine composite
unique index on `(entity_type, record_id)` exists, per-tenant, in the same schema this new
table lives in. The FK decision below is re-derived from that corrected fact.

**Decision, re-derived: a real DB-level composite FK IS used.**
`entity_record_attachments(entity_type, record_id)` → `entity_record_latest(entity_type,
record_id)`, added via a raw `execute/1` statement in the migration (Ecto's `references/2`
helper only emits single-column FKs; a composite FK needs a literal, migration-authored
`ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY (entity_type, record_id) REFERENCES
entity_record_latest (entity_type, record_id)` — no interpolated tenant- or user-controlled
data, so INV-7 is unaffected). Postgres permits a FK to target any column set covered by a
unique index, not only a primary key, so the composite unique index above is sufficient to
back this FK.

Re-checking the two candidate reasons a real FK might still be *wrong* despite the index
existing, both against `lib/letflow/design/req297-entity-promotion-executor.md`:
  - **Multiple promotion write paths into `entity_record_latest` itself?** No — req297 §8
    step 4 (line 505) states plainly: "Never touches `entity_record_latest` — that table's
    write already happened in the preceding `:upsert_record_latest` step; this step is
    additive only." The promotion dual-write path (§8) only ever writes to the
    *per-entity-type promoted table*, via `Multi.insert`/`Multi.update` inside
    `Letflow.Entities.Records`' own command functions (`create_record/2` → `Multi.insert`,
    `update_record/2`/`delete_record/2` → `Multi.update`) — a single write path into
    `entity_record_latest`, never a delete-then-reinsert. `entity_type`/`record_id` are
    also stated as "structurally immutable after insert" by that schema's own moduledoc
    (`latest.ex` lines 66-71). So the composite key an FK would pin to is stable for the
    row's whole lifetime.
  - **Rows replaceable/mutable in a way that violates FK semantics?** No — `delete_record/2`
    is a soft/event-sourced delete (`entity_record_latest.deleted` flag, via
    `update_changeset/2`, never a row removal — see that schema's `@update_fields`). The row
    is never actually deleted by any documented write path, so a FK (default `ON DELETE
    RESTRICT`, unspecified — matching this table's own `content_hash` FK choice one column
    up) never has an opportunity to fire, and never blocks a legitimate delete.

Neither candidate reason survives against the corrected facts, so nothing remains to
justify a soft reference. `upload/2`'s changeset gains a
`foreign_key_constraint(:record_id, name: <constraint name>)` clause; a violation (caller
supplies an `(entity_type, record_id)` pair with no matching `entity_record_latest` row)
surfaces as `{:error, Ecto.Changeset.t()}` — already part of `upload/2`'s declared `@spec`
(§2), so no new error shape is introduced. This also closes half of former OQ-1: an
attachment can no longer be created against a nonexistent record at all (DB-enforced, not
just app-checked) — soft-delete's effect on *existing* attachments (whether they should
still be listable once the parent record reads as deleted) remains open, restated below.

**Migration — columns and indexes**, per-tenant placement (Decision B, matching
`instance_attachments`' own placement rationale — this is ordinary tenant business data,
never shared or looked up cross-tenant):

```
create table(:entity_record_attachments, primary_key: false, prefix: schema) do
  add :id, :binary_id, primary_key: true
  add :tenant_id, :binary_id, null: false
  add :entity_type, :string, null: false
  add :record_id, :binary_id, null: false

  add :content_hash,
      references(:repository_artifacts,
        column: :content_hash, type: :binary,
        on_delete: :restrict, prefix: schema),
      null: false

  add :file_name, :string, size: 255, null: false
  add :content_type, :string, null: false
  add :byte_size, :bigint, null: false
  add :uploaded_by, :binary_id, null: false
  add :description, :text
  add :scan_status, :string, null: false, default: "pending"

  timestamps(updated_at: false, inserted_at: :created_at, type: :utc_datetime_usec)
end

create index(:entity_record_attachments, [:entity_type, :record_id, desc: :created_at],
       name: :entity_record_attachments_type_record_created_at_idx, prefix: schema)

create index(:entity_record_attachments, [:content_hash], prefix: schema)

# Composite FK — Ecto's `references/2` only emits single-column FKs, so this is a
# literal, migration-authored statement (no interpolated tenant/user data, INV-7
# unaffected) backed by entity_record_latest's own composite unique index
# (entity_record_latest_entity_type_record_id_idx, confirmed in §0/§1 above).
execute("""
ALTER TABLE #{schema}.entity_record_attachments
  ADD CONSTRAINT entity_record_attachments_record_fkey
  FOREIGN KEY (entity_type, record_id)
  REFERENCES #{schema}.entity_record_latest (entity_type, record_id)
""")
```

Column-for-column identical to `instance_attachments` except `instance_id :binary_id`
replaced by `entity_type :string` + `record_id :binary_id` (mirroring
`entity_record_latest`'s own `entity_type :string` / `record_id Ecto.UUID` pair — `Ecto.UUID`
and `:binary_id` are the same underlying Postgres `uuid` column type, `entity_record_latest`
just names the Ecto type explicitly). `scan_status` is included from the start (not added by
a later addendum migration as `instance_attachments` needed) since ISS-0399's content-scan
gate is now a standing requirement on every new attachment table, not a retrofit — ELIXIR-
DEV should ship this table with the column REQ-211 originally lacked. The one index changes
shape from `[:instance_id, desc: :created_at]` to `[:entity_type, :record_id, desc:
:created_at]` — `list/2`'s primary access pattern (§2) filters by both columns together, so
both belong in the same composite index, leading columns first per the equality-then-sort
index-ordering convention `instance_attachments`' own index already follows.

## 2. The context module — `Letflow.Repository.EntityAttachments`

New module, sibling to `Letflow.Repository.Attachments`, same four-function shape
(`upload/2`, `list/2`, `get/2`, `delete/2`) plus the REQ-212-addendum `get_content/2`
(`INV-RT-1` — see §5) — no concrete reason to diverge from that shape surfaces anywhere in
this design, so it does not.

```
@type upload_attrs :: %{
        required(:entity_type)  => String.t(),
        required(:record_id)    => Ecto.UUID.t(),
        required(:raw_bytes)    => binary(),
        required(:file_name)    => String.t(),
        required(:content_type) => String.t(),
        required(:uploaded_by)  => Ecto.UUID.t(),
        optional(:description)  => String.t() | nil
      }
@spec upload(upload_attrs(), opts()) ::
        {:ok, EntityAttachment.t()}
        | {:error, :file_too_large}
        | {:error, :infected, verdict :: String.t()}
        | {:error, :scan_unavailable}
        | {:error, Ecto.Changeset.t()}
def upload(attrs, opts)

@type list_params :: %{
        required(:entity_type) => String.t(),
        required(:record_id)   => Ecto.UUID.t(),
        cursor: String.t() | nil,
        page_size: pos_integer()
      }
@spec list(list_params(), opts()) ::
        {:ok, %{items: [EntityAttachment.t()], next_cursor: String.t() | nil}}
        | {:error, :invalid_cursor | :wrong_endpoint | :expired | :page_size_too_large}
def list(params, opts)

@spec get(id :: String.t(), opts()) ::
        {:ok, EntityAttachment.t()} | {:error, :invalid_id | :not_found}
def get(id, opts)

@spec get_content(id :: String.t(), opts()) ::
        {:ok, EntityAttachment.t(), Artifact.t()}
        | {:error, :invalid_id | :not_found | :content_missing | :not_available}
def get_content(id, opts)

@spec delete(id :: String.t(), opts()) ::
        {:ok, EntityAttachment.t()} | {:error, :invalid_id | :not_found}
def delete(id, opts)
```

`opts :: [prefix: String.t()]`, identical threading convention to
`Letflow.Repository.Attachments` — `prefix` always caller-supplied (§5 INV-1), never decided
by this module.

**Behavior, mirrored 1:1 from `Letflow.Repository.Attachments`, with one substitution
throughout (`instance_id` → `entity_type` + `record_id`):**
  - `upload/2`: same `@max_upload_bytes` gate → hash → synchronous content-scan
    (`Letflow.Repository.AttachmentScanner`, same config key
    `Application.get_env(:letflow, :attachment_scanner, ...)` — **shared scanner
    configuration**, not a second config value, since the scan mechanism is content-level,
    not owner-level) → `Repository.upsert_content/6` → insert, all inside one
    `Repo.transaction/1`, `scan_status: :clean` the only value ever written here.
  - `list/2`: cursor-paginated (REQ-067 contract, `page_size + 1` fetch-and-drop-extra,
    `Pagination` module reused unchanged), `WHERE entity_type == ^entity_type AND record_id
    == ^record_id`, ordered `(created_at desc, id desc)` matching the new composite index.
    **No existence check against `entity_record_latest`** — `list/2` (like
    `Letflow.Repository.Attachments.list/2` against `instance_id`) does not verify the
    parent record exists before listing; an empty result set for a nonexistent
    `(entity_type, record_id)` pair is indistinguishable from an existing record with zero
    attachments, which is the correct behavior (no extra existence round-trip, no extra
    information disclosed either way).
  - `get/2` / `get_content/2` / `delete/2`: identical shape to
    `Letflow.Repository.Attachments`' own — `Ecto.UUID.cast/1` first
    (`{:error, :invalid_id}`, no DB round-trip), then prefix-scoped `Repo.get/3`.
    `get_content/2` exists for the same `INV-RT-1` reason (§5): the router layer must never
    issue a `Repo.*` call, so the second `repository_artifacts` lookup lives here, not in
    the route handler.
  - `delete/2`: metadata-only delete, same rationale as `Letflow.Repository.Attachments`'
    own (`repository_artifacts` row never deleted — `ON DELETE RESTRICT` FK plus REQ-202
    immutability already forbid it, and another row could share the same `content_hash`).

**`repository_artifacts` dedup: shared with `instance_attachments`, same table, same
tenant-schema scope, not kept separate.** `repository_artifacts` is a general-purpose
content-addressed byte store (REQ-202), already shared across multiple consumers within one
tenant schema (`Letflow.Repository.Attachments`, `Letflow.Definitions.ExportImport`'s
artifact versions, per Decision B) — nothing about "which owner table points at a content
row" is part of that store's own identity or dedup key (`content_hash` alone). Giving entity-
record attachments a second, separate content store would mean uploading byte-identical
content once under an instance and once under an entity record stores the bytes TWICE in the
same tenant's schema, contradicting REQ-202's whole reason for existing. Sharing is strictly
more space-efficient and requires zero new infrastructure — `Repository.upsert_content/6` is
called exactly as `Letflow.Repository.Attachments.upload/2` already calls it, unchanged.
Cross-tenant dedup remains impossible either way (Decision B's per-tenant-schema scope,
unchanged from `Letflow.Repository.Attachments`' own moduledoc statement).

**§4 (INV-a/INV-b) inheritance — see §6.**

## 3. The route shape

**Lives in `Letflow.Routers.Entities` itself, not a new router module.** Justified the same
way req308 §2 justified one-router-not-two for the definitions/records/query split: `Plug.
Router`'s `forward` mounts one module per path prefix, and `/entities/records/
:entity_type/:record_id/attachments...` is a strict sub-path of the SAME `/entities/records/
:entity_type/:record_id` prefix `create_record`/`update_record`/`delete_record` already
live under in this one module — there is no second, disjoint URL prefix here that would
justify (or even permit, without a second `forward` mount in `api_pipeline.ex`) a second
router. This also matches `Letflow.Routers.Instances`' own precedent: REQ-212's four
attachment routes were appended to the existing `Letflow.Routers.Instances` module, not
split into a separate `Letflow.Routers.InstanceAttachments`.

| Handler | Method/path | Delegate | Permission | Response |
|---|---|---|---|---|
| create_record_attachment | `POST /entities/records/:entity_type/:record_id/attachments` | `Letflow.Repository.EntityAttachments.upload/2` | `EntitiesAttachmentsManage` | 201 / 404 / 422 |
| list_record_attachments | `GET /entities/records/:entity_type/:record_id/attachments` | `Letflow.Repository.EntityAttachments.list/2` | `EntitiesAttachmentsRead` | 200 / 400 / 404 |
| get_record_attachment_content | `GET /entities/records/:entity_type/:record_id/attachments/:attachment_id` | `Letflow.Repository.EntityAttachments.get_content/2` | `EntitiesAttachmentsRead` | 200 (raw bytes) / 404 / 500 |
| delete_record_attachment | `DELETE /entities/records/:entity_type/:record_id/attachments/:attachment_id` | `Letflow.Repository.EntityAttachments.delete/2` | `EntitiesAttachmentsManage` | 204 / 404 |

Response bodies/status codes mirror REQ-212's own four routes exactly (`instances.ex`
moduledoc lines 160-192): create → 201 JSON metadata; list → 200 `{"items": [...],
"next_cursor": ...}` JSON metadata (never raw bytes, matching
`Letflow.Routers.Instances`' own "list returns JSON metadata" statement); get → 200 RAW
BYTES (the get-raw-bytes route in REQ-212's four-route shape, via `get_content/2`, `Content-
Type` set from the stored `content_type` field per INV-a's untrusted-metadata statement —
§6); delete → 204 No Content, matching `Letflow.Routers.Instances`' own delete route.

**Route ordering.** Declaring the four new attachment routes relative to the existing
`PUT`/`DELETE /records/:entity_type/:record_id` routes is NOT a collision risk here: unlike
the `/definitions/active/:name` vs `/definitions/:id` hazard (a wildcard segment vs a
literal one at the SAME path depth), `/records/:entity_type/:record_id` (2 segments after
`/records`) and `/records/:entity_type/:record_id/attachments...` (3+ segments) are
different path LENGTHS, and `Plug.Router` matches literal/wildcard segments position-by-
position — a 2-segment pattern cannot match a 3-or-4-segment request path regardless of
declaration order. So no ordering constraint is actually load-bearing here, unlike REQ-212's
own `/instances/:id/attachments` vs `/instances/:id` case (flagged there because
`Letflow.Routers.Instances` has other `/:id/...` routes at colliding depths). This design
still declares the four new routes after the three existing record routes, for readability,
matching this module's own existing convention of listing routes before their handler
section.

## 4. The permission vocabulary

```
$ grep -n ":EntitiesRecordsWrite\|:EntitiesRecordsRead\|:AttachmentsManage\|:AttachmentsRead" lib/letflow/api/authorization.ex
108:          | :AttachmentsManage
109:          | :AttachmentsRead
113:          | :EntitiesRecordsWrite
148:          | :AttachmentsManage
149:          | :AttachmentsRead
153:          | :EntitiesRecordsWrite
178:    :AttachmentsManage,
179:    :AttachmentsRead,
183:    :EntitiesRecordsWrite,
429:  def endpoint_policy_key("POST", "/instances/:id/attachments"), do: :AttachmentsManage
434:  def endpoint_policy_key("GET", "/instances/:id/attachments"), do: :AttachmentsRead
473:  def endpoint_policy_key("POST", "/entities/records/:entity_type"), do: :EntitiesRecordsWrite
580:  def required_permission(:AttachmentsManage), do: :AttachmentsManage
581:  def required_permission(:AttachmentsRead), do: :AttachmentsRead
586:  def required_permission(:EntitiesRecordsWrite), do: :EntitiesRecordsWrite
```
Confirmed: `:EntitiesRecordsWrite` exists (write-only — the module's own moduledoc, lines
78-80, states `Letflow.Entities.Records` exposes no read function, so `:EntitiesRecordsRead`
was deliberately never minted, "would be dead vocabulary"). `:AttachmentsManage`/
`:AttachmentsRead` exist and gate REQ-212's instance-scoped routes only.

**Decision: two NEW atoms, `:EntitiesAttachmentsManage` / `:EntitiesAttachmentsRead` — not
a reuse of either existing pair.**

  - **Not `:AttachmentsManage`/`:AttachmentsRead`.** Those atoms' own `authorization.ex`
    moduledoc section (lines 48-65, "genuinely new, not pre-ported") frames them
    specifically around `Letflow.Repository.Attachments`' `instance_id`-scoped table — a
    role granted `:AttachmentsManage` today is being granted "manage attachments on a
    workflow instance," and nothing states or implies "manage attachments on an entity
    record" as part of that grant. Reusing the atom would mean every existing role
    assignment silently gains entity-record-attachment authority the day this ships,
    with no requirement, review, or role-config change actually deciding that — an
    authorization-scope expansion by accident, exactly the failure mode a dedicated atom
    avoids.
  - **Not `:EntitiesRecordsWrite`/(a hypothetical `:EntitiesRecordsRead`).** Those gate
    the entity record's OWN field-value payload (`create_record`/`update_record`/
    `delete_record`, and `:EntitiesQuery` for reads) — a genuinely different capability
    from "upload/read/delete a binary file attached to that record." REQ-212 itself drew
    exactly this line for instances (`:InstancesStart`/`:InstancesCancel` vs.
    `:AttachmentsManage`/`:AttachmentsRead` are four separate atoms, not folded together)
    — this design follows that same precedent for entity records rather than diverging
    from it. A role that can edit a record's fields but should not be trusted to
    upload/delete arbitrary binary content for it (or vice versa) is a real, plausible
    split the R-Co/Letflow role model already draws for instances; collapsing it here
    would remove that granularity for entity records alone.
  - **Naming**: `Entities` prefix (matching `EntitiesDefinitionsRead/Write`,
    `EntitiesRecordsWrite`, `EntitiesQuery`'s own existing `Entities*` naming convention in
    this same file) + `Attachments` (matching REQ-212's own `Attachments*` naming) +
    `Manage`/`Read` (matching REQ-212's own manage/read split, not create/update/delete/
    list granularity — REQ-212's own moduledoc states `AttachmentsManage` gates
    upload/delete, `AttachmentsRead` gates get/list; this design's four routes split the
    same way: create+delete → Manage, list+get-content → Read).

`endpoint_policy_key/2` new clauses (added to the existing entity-records clause group,
lines ~473-479 in the current file):

```
def endpoint_policy_key("POST", "/entities/records/:entity_type/:record_id/attachments"),
  do: :EntitiesAttachmentsManage
def endpoint_policy_key("GET", "/entities/records/:entity_type/:record_id/attachments"),
  do: :EntitiesAttachmentsRead
def endpoint_policy_key("GET", "/entities/records/:entity_type/:record_id/attachments/:attachment_id"),
  do: :EntitiesAttachmentsRead
def endpoint_policy_key("DELETE", "/entities/records/:entity_type/:record_id/attachments/:attachment_id"),
  do: :EntitiesAttachmentsManage
```

`required_permission/1` gains two matching identity clauses
(`def required_permission(:EntitiesAttachmentsManage), do: :EntitiesAttachmentsManage`, same
for `:EntitiesAttachmentsRead`), per the existing pattern every other atom in that function
already follows.

**Role-grant default — see §7 OQ-2 for the concrete table.** Which existing roles receive
`:EntitiesAttachmentsManage`/`:EntitiesAttachmentsRead` by default is a role-policy
judgment call, not a schema/route/permission-vocabulary one — §7 OQ-2 proposes a concrete
default (modeled on `authorization.ex`'s actual current role list and req308's own
Role/Grants precedent) rather than leaving it a bare unresolved question, but it is still
flagged there for REVIEWER sign-off, not silently decided.

## 5. Tenant scoping and the security boundary (INV-1/2/5/7)

**INV-1 (prefix sourced solely from `scoped_repo_opts/1`).** Satisfied by construction,
identical mechanism to every route in `Letflow.Routers.Entities` today (that module's own
moduledoc INV-1 section) and to `Letflow.Repository.Attachments`' own `opts[:prefix]`
threading (that module's own moduledoc "Tenant scoping" section): every one of the four new
routes calls `prefix!(conn)` (`Letflow.Api.AuthorizedRouter`'s existing helper, backed by
`conn.assigns.scoped_opts`) and passes it as `EntityAttachments`'s `opts[:prefix]` — never a
caller-supplied tenant id, schema name, or slug from path/query/body. `uploaded_by` is
`conn.assigns.auth_context.user_id`, never a body field, matching `create_record`'s own
`actor_id` sourcing one line above where this design's route table sits. `entity_type` and
`record_id` ARE caller-supplied (path segments) — that is correct and unavoidable (they are
what selects WHICH record within the tenant), and carries no separate tenant-scoping
authority: `EntityAttachments`'s query is `WHERE entity_type == ^et AND record_id == ^rid`
run against the ALREADY-prefix-scoped connection (`Repo.*(query, prefix: schema_name)`,
`Ecto`'s own prefix mechanism) — a caller cannot use those two fields to reach another
tenant's schema at all, only to select (or miss) a row within their own.

**INV-2 (field-level redaction, or route-permission-gated only — state which).**
**Decision: route-permission-gated only, no `FieldGrants`-style per-field redaction.**
Attachment metadata (`file_name`/`content_type`/`byte_size`/`uploaded_by`/`description`/
`scan_status`/timestamps) and raw byte content are not entity-record FIELD VALUES —
`Letflow.Entities.Query.FieldGrants` redacts per-field restrictions on a `field_values`
document (an entity DEFINITION's own declared fields), a concept this design's table has no
analog of: `entity_record_attachments` has a small, fixed, code-defined column set, not a
tenant-authored open schema. This exactly matches `Letflow.Repository.Attachments`' own
existing precedent — REQ-212's four routes apply no `FieldGrants` step either, gating purely
on `:AttachmentsManage`/`:AttachmentsRead` at the route layer — and this design does not
diverge from that precedent for the same reason it doesn't apply to instance attachments.

**INV-5 (not-found/cross-tenant indistinguishability).** `get/2`/`get_content/2`/`delete/2`
follow `Letflow.Repository.Attachments`' own two-stage shape (`Ecto.UUID.cast/1` first, no
DB round-trip on a malformed id → `{:error, :invalid_id}`; then a prefix-scoped `Repo.get/3`
→ `{:error, :not_found}` for both "row does not exist" and "row exists in another tenant's
schema") — both error atoms map to the SAME zero-detail `Response.not_found/1` at the router
layer, matching `Letflow.Routers.Entities`' own INV-5 section verbatim ("a malformed record
id takes the same zero-detail 404 a well-formed-but-absent id takes"). `list/2` against a
nonexistent or cross-tenant `(entity_type, record_id)` pair returns an EMPTY page (200, not
404) — no existence pre-check is added (§2), matching `Letflow.Repository.Attachments.
list/2`'s own behavior for a nonexistent `instance_id` and avoiding the exact "exists but
forbidden" signal INV-5 forbids (an existence check here would have to answer "does this
record exist in ANY tenant" to be meaningful, which is precisely the cross-tenant leak INV-5
exists to close). **No handler adds a cross-tenant existence pre-check against
`entity_record_latest`** before delegating to `EntityAttachments` — same explicit
prohibition `Letflow.Routers.Entities`' own moduledoc states for its record routes.

**INV-7 (no SQL string interpolation).** `EntityAttachments` uses `Ecto.Query`/`Repo.*`
exclusively (`where/3`, `order_by/3`, `limit/2`, `Repo.get/3`, `Repo.insert/2`,
`Repo.delete/2`, `Repo.transaction/1`) — the SAME parameterized-query mechanism
`Letflow.Repository.Attachments` already uses, zero `Repo.query`/raw SQL. `entity_type` and
`record_id` (both caller-influenced) are bound as `Ecto.Query` pin (`^`) values, never
string-interpolated into a query fragment — identical mechanism to `instance_id`'s own
binding in `Letflow.Repository.Attachments.list/2`.

## 6. Content-type and size trust — inherits INV-a/INV-b verbatim

This design inherits `Letflow.Repository.Attachments`' documented INV-a and INV-b
statements **verbatim, no divergence**:

  - **INV-a.** Caller-declared `content_type` remains untrusted metadata — no magic-byte
    or MIME-sniffing check anywhere in `EntityAttachments`. A caller declaring
    `content_type: "application/pdf"` for non-PDF bytes is accepted and stored exactly as
    declared, and no future consumer may read the stored value as a verified fact.
  - **INV-b.** `byte_size` is computed via `byte_size/1` over the actual `raw_bytes`
    parameter inside `upload/2` — `upload_attrs()` has no caller-declared-size field at
    all, structurally nothing to ignore, exactly matching
    `Letflow.Repository.Attachments.upload_attrs()`'s own shape.

No concrete reason to diverge surfaces anywhere in this design: entity-record attachments
are the same kind of object (an opaque, tenant-user-uploaded binary file) as instance
attachments, uploaded through the same content-scan gate (`Letflow.Repository.
AttachmentScanner`, same shared config resolution, §2), stored in the same
`repository_artifacts` byte store (§2) — there is nothing about "the owner is an entity
record instead of a workflow instance" that changes either trust boundary. `@max_upload_bytes`
(25 MiB) is likewise inherited unchanged — the same judgement-based, no-requirement-stated
number `Letflow.Repository.Attachments`' own moduledoc flags for REVIEWER (§4.4 there);
flagged again here for the same reason rather than silently re-deriving a different number.

## 7. Open questions

  - **OQ-1.** `Letflow.Entities.Records.delete_record/2` is a soft/event-sourced delete
    (`entity_record_latest.deleted` flag), never a row removal — §1's FK (re-derived) does
    not cascade or reject on this, since it never fires on a soft delete (the row is never
    actually removed). A "deleted" record's attachments therefore remain listable forever
    via direct `attachment_id` lookup (`get`/`get_content`) and via `list/2`
    (entity_type+record_id still resolves rows even though the parent record now reads as
    deleted through `POST /entities/query`). Whether that is the intended lifecycle
    (attachments outlive a soft-deleted record, matching how the record's own event history
    also isn't purged) or whether a future requirement should reject/soft-delete
    attachments when their parent record is soft-deleted is NOT decided by this design —
    flagged for ELIXIR-DEV/REVIEWER rather than resolved by assumption. (What §1's FK DOES
    now guarantee: an attachment can never be *created* against an `(entity_type,
    record_id)` pair that never existed in `entity_record_latest` in the first place — that
    narrower question is closed, not open.)
  - **OQ-2.** Which existing roles should be granted `:EntitiesAttachmentsManage`/
    `:EntitiesAttachmentsRead` by default (§4). **Resolved as a default proposal, still
    flagged as a judgment call for REVIEWER** — not silently decided — following the same
    discipline `lib/letflow/design/req308-entity-http-surface.md`'s own Role/Grants table
    (lines 200-218) used for the identical class of question on `:EntitiesDefinitionsRead`/
    `:EntitiesDefinitionsWrite`/`:EntitiesRecordsWrite`/`:EntitiesQuery`. Modeled directly
    on the actual current role list and grants in `lib/letflow/api/authorization.ex`
    (`role_allows?/2`, lines ~618-666):

    | Role | Grants | Reasoning |
    |---|---|---|
    | `PLATFORM_ADMIN` | both (existing catch-all: `role_allows?(:PLATFORM_ADMIN, _permission), do: true` — unchanged) | no change needed |
    | `PROCESS_DESIGNER` | `EntitiesAttachmentsRead` only | holds `EntitiesQuery`/`EntitiesDefinitionsRead`/`EntitiesDefinitionsWrite` but NOT `EntitiesRecordsWrite` (`authorization.ex` lines ~618-632) — a schema-authoring role, not the "operate on live tenant data" class §4 already draws the Manage/Read line around; mirrors req308's own reasoning for withholding write-class grants from this role (req308 lines 211-212) |
    | `PROCESS_OPERATOR` | `EntitiesAttachmentsManage`, `EntitiesAttachmentsRead` | holds `EntitiesRecordsWrite` (`authorization.ex` lines ~633-651) and both instance-scoped `AttachmentsManage`/`AttachmentsRead` already — tracks the same "operate on live tenant data" class req308 assigned `EntitiesRecordsWrite` to for this exact role (req308 lines 213-215) |
    | `TASK_WORKER` | `EntitiesAttachmentsRead` only | holds `EntitiesQuery` and instance-scoped `AttachmentsRead` but no write-class entity permission at all (`authorization.ex` lines ~653-663) — read-only in this subsystem, mirroring "every role that can read anything here also holds `EntitiesQuery`" (req308 line 216) |
    | `AGENT_RUNNER` | none (existing catch-all: `role_allows?(:AGENT_RUNNER, _permission), do: false` — unchanged) | no change needed |

    Implementation shape: two new permission atoms added to each of `PROCESS_DESIGNER`'s,
    `PROCESS_OPERATOR`'s, and `TASK_WORKER`'s `role_allows?/2` clause bodies per the table
    above — same three-edit shape (`@permissions`, `endpoint_policy_key/2`, `role_allows?/2`)
    req308 §3 already establishes for this permission pair's own siblings.
  - **OQ-3 (inherited, not new).** `Letflow.Repository.Attachments`' own `@max_upload_bytes`
    judgement call (§6) applies here unchanged and is re-flagged, not re-litigated.

## 8. Scope-fence confirmation

```
$ git diff --name-only
lib/letflow/design/req313-entity-record-attachments.md
```
Only the new design file — no file under `lib/letflow/routers/`, `lib/letflow/repository/`,
`lib/letflow/api/`, `priv/repo/migrations/`, or `test/` touched by this requirement. No
`docs/migration/decisions/` record is filed: §1's schema-shape reasoning and §4's
permission-vocabulary reasoning are both fully contained and justified within this design
document, and neither contradicts an existing decision record (0003/0022/0023 are all
followed, not diverged from) — so no new decision record is warranted per this agent's own
judgement call.

## 9. 0022 rule 1 — vocabulary check

```
$ grep -niE "\bquestion image\b|\bcertificate\b|\bexam\b|swiftroute|shipment|delivery.note|bilimbaga" lib/letflow/design/req313-entity-record-attachments.md
(no output)
```
Zero hits for the actual forbidden domain-vertical terms this requirement's own text names
("question image", "certificate", "exam") or any BilimBaga/SwiftRoute-specific noun. The
bare English word "question" appears four times in this document (§1, §4, §7) — every
occurrence is this agent's own generic usage ("open question", "role-grant question"), not
the forbidden vertical noun "[exam] question [image]"; confirmed by inspection of each of
the four lines cited by a broader `grep -n "question"` pass. Only the "S10 gap 3"
stage-bookkeeping citation in this document's own title line is a permitted exception under
the rule.
