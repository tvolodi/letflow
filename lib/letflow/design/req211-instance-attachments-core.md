# Design: REQ-211 — Instance-attachment schema and core upload/list/get/delete context module

**Requirement:** REQ-211 (`docs/requirements.yaml:11999-12142`, stage S6,
`depends_on: [REQ-202, REQ-072, REQ-067]`)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** one Ecto schema (`instance_attachments`), one migration's
full table/index/constraint spec, the context module's public `@spec`s and behavior,
the concrete upload-size ceiling and where it is enforced, and the required moduledoc
content per the acceptance criteria. **No implementation code** — no function bodies,
no `.ex`/`.exs` file contents, no literal SQL beyond the one raw-SQL check constraint
this table's shape requires. ELIXIR-DEV writes the actual code from this document at
Step 2a.

**NOT in this document:** no route/controller (REQ-212 — mirrors the REQ-176/178 and
REQ-181/182 core/route split already established in this codebase), no AV/
content-scanning pipeline (named as a deliberately deferred follow-up per the
requirement's own instruction, §8), no `web/` work.

**Revision note (this version):** CODE-DESIGN-VALIDATOR FAILED the prior version of
this document on OQ-4 (gate-blocking): `repository_artifacts` (REQ-202, shipped,
status `done`) has no column that stores raw content bytes anywhere —
`content_hash`/`tenant_id`/`content_type`/`byte_size` only, confirmed directly against
`priv/repo/migrations/20260830030001_create_repository_artifacts.exs` and
`lib/letflow/repository/artifact.ex`. `Letflow.Repository.create/2`
(`lib/letflow/repository.ex`) accepts `attrs.content` (raw bytes), canonicalises it,
hashes it, computes `byte_size(canonical)` — then its private `upsert_content/5`
writes only `content_hash`/`tenant_id`/`content_type`/`byte_size` into
`repository_artifacts`; the canonical bytes are never passed to
`Artifact.changeset/2` and are discarded once `create/2` returns. §4.3's `get/2` design
was built on the false premise that a route layer could "stream bytes back from
repository_artifacts" — there was nothing there to stream. **Per ORCH decision, this
gap is now closed by a migration addendum** (new §2A below) adding a `content :bytea`
column to the existing `repository_artifacts` table, **not** by introducing a
filesystem/object-store dependency or a new table. This is therefore now a change to
an already-`done` requirement's (REQ-202) shipped table, not merely a REQ-211-scoped
reuse of it — flagged explicitly for REVIEWER (§2A, §6) since REQ-202's own acceptance
criteria and `done` status are otherwise unaffected. §4.1 and §4.3 are revised
accordingly; OQ-4 is resolved (no longer an open question, §8). OQ-1/OQ-2/OQ-3 are
unchanged — validator confirmed those are legitimately deferrable.

---

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-211's full entry (lines 11999-12142), read in full —
  description and all 11 acceptance criteria.
- `docs/agents/instructions/core-directives.md`, `docs/agents/workflows/WF-02_requirement_implementation.md`
  Step 1, `docs/anti-patterns.md`, `docs/agents/instructions/security-invariants.md`,
  `docs/guides/backend_developer_guide.md`.
- `docs/migration/decisions/0003-ecto-schema-strategy.md` in full — Decision B
  (schema-per-tenant via `:prefix`, `tenant_id` retained intra-schema, derived from the
  resolved prefix at write time per the 2026-08-17 addendum, never caller-supplied).
- `lib/letflow/design/req202-artifact-repository.md` in full — the `repository_artifacts`
  design this requirement reuses as its byte store (§1 placement decision, §2.1 schema,
  §4.2 upsert-by-hash `create/2` steps, §5.1 DB-level immutability). REQ-211 does not
  reopen any of REQ-202's own design decisions; it only reuses the shipped table.
- `priv/repo/migrations/20260830030001_create_repository_artifacts.exs` — the actual
  shipped migration: confirms `repository_artifacts` is per-tenant-schema
  (`if prefix() do ... end` guard), `content_hash` is `:binary` primary key (no
  `autogenerate`), `BEFORE UPDATE`/`BEFORE DELETE` triggers reject all mutation, and
  the FK-from-elsewhere pattern used by `artifact_versions.content_hash`
  (`references(:repository_artifacts, column: :content_hash, type: :binary,
  on_delete: :restrict, prefix: schema)`) — this design's `instance_attachments.content_hash`
  FK copies that exact shape.
- `lib/letflow/repository/artifact.ex` — the shipped `Letflow.Repository.Artifact`
  schema module, confirming `@primary_key {:content_hash, :binary, autogenerate: false}`,
  its current field list (`tenant_id`, `content_type`, `byte_size`, `timestamps(updated_at:
  false)` — **no byte-content field**), and the `changeset/2` shape a structural insert
  changeset follows in this codebase (`@required_fields [:content_hash, :tenant_id,
  :content_type, :byte_size]`, `cast/3` + `validate_required/2` only).
- `lib/letflow/repository.ex` (full file, re-read for this revision) — confirms
  `Letflow.Repository.create/2`'s actual current signature: `create_attrs` requires
  `:content` (raw `binary()`); the function canonicalises it
  (`Canonicaliser.canonicalize_content/2`), computes `hash = Canonicaliser.content_hash(canonical)`
  and `byte_size = byte_size(canonical)`, then calls private `upsert_content(prefix,
  tenant_id, hash, content_type, byte_size)` — which builds `%{content_hash:, tenant_id:,
  content_type:, byte_size:}` and calls `Artifact.changeset/2` + `Repo.insert(prefix:,
  on_conflict: :nothing, conflict_target: :content_hash)`. **The canonical byte content
  itself (`canonical`, the local variable) is never passed into `upsert_content/5` and is
  discarded once `create/2` returns** — confirms OQ-4's suspicion exactly: REQ-202's
  shipped code computes bytes only to hash/measure them, never persists them anywhere.
- `lib/letflow/dlq.ex` (REQ-176, shipped) and `lib/letflow/webhooks.ex` (REQ-181,
  shipped) — read in full as the two most recent core-module (schema + context module,
  no route) precedents in this project, per the assigning agent's instruction. Both
  establish, and this design follows: (a) every public function takes `opts :: [prefix:
  String.t()]`, prefix always caller-supplied, never resolved by the context module
  itself; (b) `tenant_id` is never accepted from caller attrs, always derived from
  `opts[:prefix]` via `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`; (c) `id`/
  not-found handling is `Ecto.UUID.cast/1` first (`{:error, :invalid_id}`, no DB
  round-trip) then a prefix-scoped fetch (`{:error, :not_found}` on either "does not
  exist" or "exists in another tenant's schema" — the structural cross-tenant-404
  REQ-072 established, satisfying INV-5's shape even though INV-5 itself is not yet a
  live invariant per `security-invariants.md`'s applicability note); (d) `list/2`'s
  cursor-pagination idiom (`Letflow.Dlq.list/2`'s `@list_cursor_prefix`,
  `page_size + 1`-fetch-and-drop, `Letflow.Api.Pagination.build_raw_cursor/3` +
  `encode_cursor/1`) is copied directly for §5 below, substituting this module's own
  distinct cursor prefix.
- `lib/letflow/api/pagination.ex` — REQ-067's shipped cursor contract: `max_page_size/0`
  (200), `default_page_size/0` (50), `min_page_size/0` (1), `validate_page_size/1`
  (400-on-out-of-range, not a silent clamp), `encode_cursor/1`, `decode_cursor/4`
  (prefix-checked, so a cursor minted by one endpoint is rejected by another — INV-1 per
  that module's own moduledoc), `build_raw_cursor/3`. Reused verbatim, §5.
- `lib/letflow/plugs/api_pipeline.ex` — confirms the **only** existing body-size ceiling
  in this codebase is `Plug.Parsers`'s `length: 2_097_152` (2 MB), scoped to JSON request
  bodies on `Letflow.Plugs.ApiPipeline`. This does not apply to attachment uploads:
  REQ-212 (route layer, out of this requirement's scope) will need a `multipart` parser
  branch with its own, larger `:length` cap, since a 2 MB ceiling is unworkably small for
  the file-attachment use case this requirement exists to serve (REQ-206's
  swiftroute-shipment-attach-delivery-note scenario attaches a delivery-note document).
  Grepped this codebase for any existing multipart/`Plug.Upload` handling
  (`grep -rn "multipart\|Plug.Upload" lib/`) — zero hits. There is no existing
  file-upload precedent in this project to match; §4.4 below states this module's own
  ceiling as a fresh, explicit decision, independent of `Plug.Parsers`'s JSON cap.
- `lib/letflow/tenant_provisioning.ex` — `tenant_scoped_migrations/0`'s manifest
  mechanism (a `{version, module, filename}` list that must be extended when this
  requirement's migration ships) and `tenant_id_for_schema_name/1`'s reverse-mapping
  contract, reused unchanged.

---

## 1. Schema — `instance_attachments`

### 1.1 Placement

Per-tenant Postgres schema (`prefix: prefix()`, Decision B), `tenant_id` column
retained as the intra-schema query-predicate discipline — identical placement to
`dlq_entries` (REQ-176) and `webhook_subscriptions` (REQ-181), and explicitly named as
such by the requirement's own text. Not a candidate for global placement: an attachment
is tenant business data (a document a tenant's user attached to that tenant's own
workflow instance), unlike REQ-202's `repository_artifacts`, whose per-tenant-vs-global
question was genuinely debated (req202 design §1) because it is a content-addressed
store where cross-tenant dedup was at least a coherent question to raise. No such
question exists here: `instance_attachments` rows are never shared or looked up across
tenants under any circumstance, so this decision needs no analogous debate — stated
plainly, not silently assumed.

### 1.2 Columns

| Column | Type | Constraints |
|---|---|---|
| `id` | `:binary_id` | Primary key, `autogenerate: true`. |
| `tenant_id` | `:binary_id` | `null: false` — Decision B intra-schema discipline; derived at write time from `opts[:prefix]` via `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`, exactly as `Letflow.Dlq.enqueue/2` and `Letflow.Webhooks.create/2` already do. Never accepted as a separate caller-supplied field (0003 addendum). |
| `instance_id` | `:binary_id` | `null: false` — this table is instance-scoped only; no unattached/orphan uploads, per the requirement's own text. No FK to an `instances`/`instance_projections` table is added by this design (see OQ-1 below — not silently resolved). |
| `content_hash` | `:binary` | `null: false` — **FK to `repository_artifacts.content_hash`, `on_delete: :restrict`**, same shape as `artifact_versions.content_hash`'s FK in the shipped REQ-202 migration (`references(:repository_artifacts, column: :content_hash, type: :binary, on_delete: :restrict, prefix: schema)`). `:restrict` matters here in a way it does not (practically) for `artifact_versions`: `repository_artifacts` has no delete path anywhere in this codebase (REQ-202's own DB trigger blocks it unconditionally), so this FK's `on_delete: :restrict` is unreachable defense-in-depth, not a path this requirement's own code triggers — stated explicitly so a future reader does not go looking for a delete-cascade test that cannot exist. |
| `file_name` | `:string, size: 255` | `null: false` — the caller-supplied original filename. Never used to derive `content_type` or trusted for any security decision (§4.2). |
| `content_type` | `:string` | `null: false` — the caller-declared MIME type, e.g. `"application/pdf"`. **Stored as caller-supplied metadata only — see §6 INV-a: never trusted downstream as a validated fact.** Plain string (open set), matching `repository_artifacts.content_type`'s own choice in req202's design (no `Ecto.Enum` — this requirement does not enumerate a closed content-type list). |
| `byte_size` | `:bigint` | `null: false` — denormalized from `repository_artifacts` for cheap listing (no join needed to render a list row's size). **Independently measured from the actual uploaded bytes inside `upload/2` — never taken from a caller-supplied field.** See §4.3/§6 INV-b. |
| `uploaded_by` | `:binary_id` | `null: false` — the authenticated user id, supplied by the caller (REQ-212's future route layer resolves this from the request's auth context; this context module accepts it as a plain parameter and does not itself resolve "who is calling"). |
| `description` | `:text` | Nullable — free-text, per the requirement's own schema spec. |
| `created_at` | `utc_datetime_usec` | Via `timestamps/1`, `updated_at: false` — this table has no legitimate update path (§1.4), matching `req195`/`req202`'s "an `updated_at` column that can never legitimately change is a schema smell to avoid" reasoning. Second-precision is not required here (unlike `Letflow.Dlq.Entry`'s `created_at`, which is truncated to `:second` to match an existing R-Co-parity convention this requirement has no equivalent for) — `usec` precision keeps cursor-pagination tie-breaking simple without a compound `(created_at, id)` key collision concern; see §5's cursor shape for why plain `created_at` ordering is sufficient here without the two-column tie-break `Letflow.Dlq.list/2` needs (that module orders by `(created_at, id)` both `DESC` specifically because its `created_at` is truncated to second precision, making same-second collisions realistic; this table's `usec`-precision `created_at` makes an exact-timestamp collision between two distinct inserted rows practically unreachable, so §5 still includes `id` as a documented tie-break key for correctness, but the precision choice here is a deliberate, stated difference from `Letflow.Dlq.Entry`, not an oversight). |

No separate `updated_at`; no soft-delete/tombstone column (`delete/2` is a hard delete
of the `instance_attachments` row only, §4.5).

### 1.3 Indexes and constraints

1. `index(:instance_attachments, [:instance_id, desc: :created_at], prefix: schema)` —
   the primary access pattern (§4.2's AC5: `list/2` filtered by `instance_id`),
   newest-first.
2. `index(:instance_attachments, [:content_hash], prefix: schema)` — resolving which
   attachments reference a given content row, same defense-in-depth reasoning
   `req202`'s design gives its own analogous `content_hash` index on `artifact_versions`
   (§2.2 of that design) — not itself required by any acceptance criterion here, added
   for symmetry and because `delete/2`'s AC7 demonstration ("confirming the
   repository_artifacts row and the other attachment both survive") is exactly the query
   this index serves.
3. **No unique constraint** on `(instance_id, content_hash)` or any other column
   combination. Uploading byte-identical content twice under the same `instance_id` is
   not rejected by this design — the requirement's own AC2 demonstrates two *different*
   `instance_id` values producing two distinct `instance_attachments` rows sharing one
   `repository_artifacts` row, and nothing in the requirement text forbids the same
   `instance_id` from holding two attachments with identical content (e.g. the same PDF
   uploaded twice, perhaps with different `file_name`/`description`) — that is a
   legitimate use case (two different original filenames, or a deliberate duplicate
   note), not a defect to prevent. See OQ-2.

### 1.4 Immutability

No DB-level immutability trigger on `instance_attachments` (unlike `repository_artifacts`
itself). This table is ordinary tenant business data with a normal delete path
(`delete/2`, §4.5) — it is not a content-addressed store and REQ-202's REPO-02
immutability rule applies only to `repository_artifacts`/`artifact_versions`, not to
every table that references them. `Letflow.Repository.Attachment`'s (schema module
name, §2) `changeset/2` is used only for `upload/2`'s single insert — no `update/2` is
built in this module's public interface (see §7, functions deliberately not built), so
there is no code path that would ever call an update changeset, but this is an
API-level discipline, not a DB-enforced one, since nothing in the requirement demands
DB-level rejection for this table the way REQ-202's AC7 demanded it for
`repository_artifacts`.

---

## 2. Migration

One migration file, `if prefix() do ... end`-guarded exactly like every other per-tenant
migration in this codebase (`req195`/`req027`/`req202`'s pattern), registered in
`Letflow.TenantProvisioning.tenant_scoped_migrations/0`'s manifest (both the manifest
entry and the migration file itself are mandatory — see that module's own header
comment). Migration-file top comment must state (matching `req202`'s migration-file
comment convention, §2 of that design):

- This table is per-tenant (schema-per-tenant via `prefix()`), and why (Decision B,
  ordinary tenant business data — §1.1 above condensed).
- `content_hash` is a FK to `repository_artifacts.content_hash` (`on_delete: :restrict`,
  same shape as `artifact_versions`'s own FK in the REQ-202 migration) — this table
  reuses REQ-202's byte store rather than duplicating content storage, and does NOT
  modify `repository_artifacts`'s own schema.
- No SQL below interpolates tenant- or user-controlled data (INV-7) — every statement is
  a fixed, migration-authored literal, scoped only by the already-trusted `prefix()`
  schema-name value Ecto itself resolves for this migration run.

Table/column DSL shape (Ecto migration, not literal code, per this document's own
no-implementation-code rule):

- `create table(:instance_attachments, prefix: schema) do ... end` — `binary_id`
  primary key (Ecto's schema default via `@primary_key` on the corresponding schema
  module, or `primary_key: true` on the migration's own `:id` column — ELIXIR-DEV's
  mechanical choice at Step 2a, not a design-level decision, matching every other
  per-tenant table in this codebase that uses the default `binary_id` primary key
  shape, e.g. `dlq_entries`/`webhook_subscriptions`).
- Columns per §1.2's table above, in the same order.
- `add :content_hash, references(:repository_artifacts, column: :content_hash, type: :binary, on_delete: :restrict, prefix: schema), null: false`.
- The two indexes from §1.3, with explicit `name:` options if Ecto's default
  index-naming would exceed Postgres's 63-byte `NAMEDATALEN` limit or collide with
  another index's default name (the same hazard `req202`'s migration comment documents
  and works around) — ELIXIR-DEV must check both generated names at Step 2a the same
  way that migration's own comment shows the check being performed, not assume they are
  short enough by inspection alone.
- `timestamps(updated_at: false)`.

---

## 2A. Migration addendum — `repository_artifacts.content :bytea` (resolves OQ-4)

**This is an ALTER to REQ-202's existing shipped `repository_artifacts` table, not a
new table, and not part of `instance_attachments` (§1-§2 above).** It is a second,
separate migration file. Stated plainly per ORCH's decision: this does **not** change
REQ-202's own acceptance criteria and does **not** revert REQ-202's `done` status —
REQ-202's shape (`content_hash` PK, `tenant_id`, `content_type`, `byte_size`,
immutability triggers) is unchanged; one nullable-at-the-DB-DDL-level-but-`null:
false`-going-forward column is added. **Flagged explicitly for REVIEWER at Step 2d:
this is a schema change to an already-completed requirement's table and needs
explicit sign-off for that reason** — REVIEWER must confirm altering a `done`
requirement's migration set (by addendum, not by editing the original shipped
migration file) is the correct mechanism here rather than, e.g., requiring a new
REQ-202-numbered follow-up requirement to own this change formally.

**Why Postgres `bytea`, not filesystem/object-store:** per ORCH decision — keep it in
Postgres, no new infrastructure dependency. `repository_artifacts` is already the
canonical per-tenant, content-addressed home for this content; a `bytea` column keyed
by the existing `content_hash` PK requires no new store, no new supervision tree, no
new credential/config surface, and preserves REQ-202's existing tenant-schema
isolation and immutability-trigger guarantees (the `BEFORE UPDATE`/`BEFORE DELETE`
triggers on `repository_artifacts`, §0 above, apply to the whole row including this
new column with zero additional work — an UPDATE or DELETE touching `content` is
rejected exactly as any other column-touching UPDATE/DELETE already is).

**Migration shape** (DSL shape, not literal code, per this document's own
no-implementation-code rule):

- New file, e.g. `priv/repo/migrations/<timestamp>_add_content_to_repository_artifacts.exs`,
  `if prefix() do ... end`-guarded identically to every other per-tenant migration
  (same `schema = prefix()` pattern as the original REQ-202 migration) — this table is
  per-tenant, so the ALTER must run once per tenant schema exactly as the original
  `CREATE TABLE` did. **Registered in `Letflow.TenantProvisioning.tenant_scoped_migrations/0`'s
  manifest** — both the manifest entry and the migration file are mandatory, same
  discipline §2 above already states for the `instance_attachments` migration.
- `alter table(:repository_artifacts, prefix: schema) do add :content, :binary, null:
  false end`. Ecto's `:binary` migration type maps to Postgres `bytea` (matching
  `content_hash`'s own existing `:binary` → `bytea` mapping in the original migration —
  no new type-mapping precedent needed).
- **`null: false` is intentional, not an oversight requiring a backfill step**: at the
  time this addendum ships, no `repository_artifacts` rows exist yet anywhere in this
  codebase (REQ-202's `create/2` is not called by any shipped caller as of REQ-211's
  own dependency graph — REQ-211/`upload/2` is the first real caller, §4.1 below). If
  REVIEWER's Step 2d review finds `create/2` does have another live caller with rows
  already persisted before this addendum ships, ELIXIR-DEV must add a backfill
  strategy (or relax to nullable with a follow-up tightening migration) — **named here
  as a contingency, not resolved by this document**, since this design cannot verify
  runtime database state, only shipped source code.
- Migration-file top comment must state (matching the original REQ-202 migration's own
  comment convention): (a) this is an addendum to REQ-202's shipped migration, not a
  new table; (b) it does not change REQ-202's own acceptance criteria or `done`
  status; (c) why `bytea` in Postgres rather than filesystem/object-store (ORCH
  decision, condensed from above); (d) no SQL below interpolates tenant- or
  user-controlled data (INV-7) — the `alter table` call is pure Ecto DSL, no raw
  `execute/2` SQL is needed for this addendum (unlike the original migration's trigger
  functions).
- **Corresponding schema-module change**: `Letflow.Repository.Artifact` (§0,
  `lib/letflow/repository/artifact.ex`) must gain `field(:content, :binary)` in its
  `schema "repository_artifacts" do ... end` block and `:content` added to
  `@required_fields`/`changeset/2`'s cast+validate list — **named explicitly here since
  this is a change to REQ-202's existing shipped module, not new REQ-211 code,** so
  ELIXIR-DEV and REVIEWER both know this file is touched by this requirement's Step 2a
  despite living outside `instance_attachments`'/`Attachments`'s own namespace.

---

## 3. Schema module

**`Letflow.Repository.Attachment`**, at `lib/letflow/repository/attachment.ex` —
sibling-in-namespace with `Letflow.Repository.Artifact`/`Letflow.Repository.ArtifactVersion`
(REQ-202), since this table's whole purpose is to reference that store, even though it
is a structurally distinct, ordinary per-tenant business table (not part of the
content-addressed store itself).

- `@primary_key {:id, :binary_id, autogenerate: true}` (the Ecto default — stated
  explicitly here only because `Letflow.Repository.Artifact`'s own primary key is
  atypical, `{:content_hash, :binary, autogenerate: false}`, and this design does not
  want a reader assuming this module copies that shape).
- `schema "instance_attachments" do ... end` with the fields from §1.2 (excluding `id`,
  which the primary key declaration already covers).
- `@type t :: %__MODULE__{}`.
- `@spec changeset(t(), map()) :: Ecto.Changeset.t()` — a single structural insert
  changeset, casting/validating presence of every `§1.2` `null: false` field
  (`tenant_id`, `instance_id`, `content_hash`, `file_name`, `content_type`, `byte_size`,
  `uploaded_by`) plus a `max_length` validation on `file_name` (255, matching the
  column's `size: 255`) — `Letflow.Repository.create/2`'s own precedent (req202 design
  §2.1, `Letflow.Repository.Artifact.changeset/2`) supplies every field itself (the
  pre-computed hash, the derived `tenant_id`, the independently-measured `byte_size`);
  this changeset only casts/validates, it does not compute or derive anything. No
  `update_changeset/2` — matching §1.4's "no update path" discipline.

---

## 4. Context module — `Letflow.Repository.Attachments`

**Location:** `lib/letflow/repository/attachments.ex` — plural, distinguishing this
context module from the `Letflow.Repository.Attachment` schema module (§3) the same way
`Letflow.Dlq` (context) and `Letflow.Dlq.Entry` (schema) are distinguished, and the same
way `Letflow.Webhooks` (context) and `Letflow.Webhooks.Subscription` (schema) are
distinguished. Plain Ecto context module, no process — same shape as `Letflow.Dlq`/
`Letflow.Webhooks`.

### 4.0 Required moduledoc content (binding on ELIXIR-DEV at Step 2a; each item below is
traced to a specific acceptance criterion in §9)

1. Scope boundary: this module covers only the `instance_attachments` schema/migration
   and the four functions below. No route, no controller, no Plug module — that is
   REQ-212 (AC10).
2. Tenant scoping (INV-1), stated verbatim in substance from `Letflow.Dlq`'s own
   moduledoc: every function takes `opts :: [prefix: String.t()]`, prefix always
   caller-supplied; `tenant_id` is never accepted from caller attrs, always derived from
   `opts[:prefix]`.
3. **INV-a — `content_type` is caller-supplied metadata, never a validated fact.** The
   moduledoc must state explicitly that nothing in this module, and nothing any caller
   of this module may assume, treats the stored `content_type` value as verified against
   the actual byte content (e.g. no magic-byte/MIME-sniffing check is performed) — a
   caller declaring `content_type: "application/pdf"` for a file that is not actually a
   PDF is accepted and stored as declared. Any future consumer that needs a *trusted*
   content-type determination must not read this field as if it were one.
4. **INV-b — `byte_size` is independently measured, never caller-trusted.** The
   moduledoc must state that `upload/2` computes `byte_size` via `byte_size/1` (Elixir's
   own function, over the actual `raw_bytes` binary parameter) and this computed value
   is what both `repository_artifacts` (if a new row) and `instance_attachments` store —
   any `byte_size`-shaped value a caller might separately claim (e.g. in a multipart
   form field, at the REQ-212 route layer) is never read by this module at all, because
   this module's own `upload/2` signature has no parameter for a caller-declared size in
   the first place (§4.1) — there is structurally nothing to ignore, which is a stronger
   guarantee than "ignores it if present."
5. **The concrete upload size ceiling, §4.4** — named as an actual number
   (`@max_upload_bytes`), with the reasoning §4.4 states.
6. **Decision B cross-tenant statement (AC8)** — verbatim in substance: "`repository_artifacts`
   is per-tenant-schema-scoped (Decision B, `docs/migration/decisions/0003-ecto-schema-strategy.md`),
   so `content_hash` dedup happens only within one tenant's own schema. Two different
   tenants uploading byte-identical file content each get their own
   `repository_artifacts` row, in their own Postgres schema — never one shared row. This
   module deliberately does not, and cannot by construction, share content-hash rows
   across tenants."
7. **No-canonicalisation statement (AC8)**, verbatim in substance: "No canonicalisation
   is applied to attachment bytes before hashing — byte-identity hashing only, per
   REQ-202's existing binary-content rule (`Letflow.Repository.Canonicaliser`'s
   byte-identity branch for non-JSON content, req202 design §3.5). This applies
   regardless of an attachment's declared `content_type` — even an attachment declared
   `application/json` is hashed byte-identically here, NOT run through
   `Letflow.Repository.Canonicaliser`'s JSON canonicalization branch, because an
   attachment is an opaque user-uploaded document, not a versioned configuration
   artifact subject to REQ-202's dedup-by-canonical-form semantics." (This last sentence
   is a design decision this document is making explicitly, not merely restating the
   requirement — see §4.2 step 2's note.)
8. **Content-scanning deferral (AC9)**, stated as a named, deliberately deferred
   follow-up, verbatim in substance: "No antivirus/content-scanning pipeline exists for
   uploaded attachment bytes. This is a deliberately deferred follow-up, not an
   oversight — flag it for a future issue if malicious-upload risk becomes a concrete
   concern before S8." (ELIXIR-DEV files this as a queued follow-up issue per
   `ISSUE_QUEUE.md` at Step 2a if one does not already exist for it — that filing is
   Step 2a's job, not this design document's; this document only requires the moduledoc
   statement.)
9. `delete/2`'s metadata-only-delete rationale (§4.5), stated explicitly: `delete/2`
   removes the `instance_attachments` row only; the underlying `repository_artifacts`
   content row is never deleted by this module, both because REQ-202's own immutability
   rule and `ON DELETE RESTRICT` FK already forbid deleting a referenced content row, and
   because another attachment (or a REQ-202 `artifact_versions` row) could independently
   share the same `content_hash`.

### 4.1 `upload/2`

```
@type upload_attrs :: %{
        required(:instance_id) => Ecto.UUID.t(),
        required(:raw_bytes) => binary(),
        required(:file_name) => String.t(),
        required(:content_type) => String.t(),
        required(:uploaded_by) => Ecto.UUID.t(),
        optional(:description) => String.t() | nil
      }

@spec upload(upload_attrs(), opts()) ::
        {:ok, Attachment.t()}
        | {:error, :file_too_large}
        | {:error, Ecto.Changeset.t()}
```

Note the type shown above is a signature/shape specification per this design
document's own convention (matching req202's design §4.1's identical presentation) —
not implementation code; no function body is given.

**Steps (stated as a sequence, not as code), matching req202 design §4.2's presentation
convention:**

1. Compute `byte_size = byte_size(raw_bytes)` (Elixir's own `byte_size/1`, over the
   actual received binary — never a caller-supplied field, §4.0 item 4). If `byte_size >
   @max_upload_bytes` (§4.4), return `{:error, :file_too_large}` immediately — **before**
   any hashing, upsert, or insert is attempted. This ordering is what AC4 requires:
   "rejected before being persisted, with neither a `repository_artifacts` row nor an
   `instance_attachments` row created."
2. Compute `content_hash = :crypto.hash(:sha256, raw_bytes)` — **byte-identity hashing
   only, unconditionally, regardless of `content_type`.** This module never calls
   `Letflow.Repository.Canonicaliser.canonicalize_content/2` at all — not even for a
   `content_type` of `"application/json"` — per §4.0 item 7's moduledoc requirement.
   (This is a deliberate design choice this document makes explicitly: REQ-202's
   canonicaliser exists to make two *semantically equivalent* JSON documents hash
   identically for the purpose of artifact-version deduplication; an attachment is a
   literal uploaded document with no such equivalence-class semantics, and applying JSON
   canonicalization here would silently rewrite/re-encode a tenant's uploaded bytes
   before hashing them, which is not a transformation any acceptance criterion asks for
   and would make `content_hash` no longer a proof of exactly what was uploaded.)
3. **Upsert** the `repository_artifacts` row keyed by `content_hash`, in the same
   tenant's schema (`opts[:prefix]`) — `content_hash` already existing in this tenant's
   schema means identical content was submitted before (by any caller: a prior
   attachment upload, or a REQ-202 artifact version) and no new row is written;
   `content_hash` not yet existing means insert `content_type` (**the value being
   inserted into `repository_artifacts.content_type` here is this upload's own declared
   `content_type` — see OQ-3 below, not silently resolved**), `byte_size` (the same
   independently-measured value from step 1), `content_hash`, and **`content = raw_bytes`
   (the actual uploaded bytes, into the `content :bytea` column §2A adds)** as a new
   row. This mirrors req202 design §4.2 step 3's upsert-by-hash behavior, with one
   explicit correction this revision makes: **`Letflow.Repository.create/2` cannot be
   called as-is for this step.** `create/2`'s own signature (§0 above,
   `lib/letflow/repository.ex`) is tied to the `artifact_versions` write path — it
   requires `artifact_kind`/`artifact_name`/`parent_version_id` and always inserts an
   `artifact_versions` row in the same transaction as its `repository_artifacts`
   upsert (`create_with_retries/7`), none of which applies to an attachment upload
   (`instance_attachments` is a structurally different table from `artifact_versions`,
   §1.1). This module's `upload/2` must instead call the lower-level upsert path
   directly — REQ-202's existing private `upsert_content/5`
   (`lib/letflow/repository.ex`) is `defp`, not exported, so it is not callable from
   `Letflow.Repository.Attachments` as written today. **Two options, named explicitly,
   neither silently chosen by this document:** (a) `upsert_content/5` is changed from
   `defp` to a public, documented function (renamed/re-specced to also accept
   `content :: binary()` as a new required parameter, writing it into the new `content`
   column §2A adds) that both `Letflow.Repository.create/2` and this module's
   `upload/2` call; or (b) `Letflow.Repository.Attachments.upload/2` performs its own
   `Repo.insert(%Artifact{}, ..., on_conflict: :nothing, conflict_target: :content_hash)`
   directly against `Letflow.Repository.Artifact.changeset/2` (§2A's schema-module
   change already adds `:content` to that changeset's cast/validate list), duplicating
   the upsert shape rather than sharing REQ-202's private helper. **This document
   recommends (a)** — a single shared upsert path avoids two independently-maintained
   copies of "how to upsert a `repository_artifacts` row" ever drifting apart — but
   flags this as a genuine cross-module design decision for REVIEWER's Step 2d
   sign-off (§6), since (a) requires touching `Letflow.Repository`'s existing,
   already-`done` public/private API surface on REQ-211's behalf, which is exactly the
   kind of change `core-directives.md` asks to be surfaced rather than silently made.
   Either way, ELIXIR-DEV must name in code review which option was taken and why.
4. Derive `tenant_id` from `opts[:prefix]` via
   `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` (§4.0 item 2).
5. Insert the `instance_attachments` row: `instance_id`, `content_hash` (from step 2),
   `file_name`, `content_type` (the caller's declared value, stored as-is per INV-a),
   `byte_size` (from step 1), `uploaded_by`, `description`, `tenant_id` (from step 4).
6. Return `{:ok, attachment}` on success, or `{:error, changeset}` on any changeset
   validation failure from step 5 (e.g. `file_name` exceeding 255 characters).

**AC2's demonstration (byte-identical content, two different `instance_id` values) is
exactly steps 3+5 run twice**: the second call's step 3 hits the "already exists"
upsert branch (no second `repository_artifacts` row), while step 5 always inserts a
fresh `instance_attachments` row regardless of step 3's branch — so two calls
necessarily produce one `repository_artifacts` row and two `instance_attachments` rows,
by construction, not by a special-cased check.

### 4.2 `list/2`

```
@type list_params :: %{
        required(:instance_id) => Ecto.UUID.t(),
        cursor: String.t() | nil,
        page_size: pos_integer()
      }

@spec list(list_params(), opts()) ::
        {:ok, %{items: [Attachment.t()], next_cursor: String.t() | nil}}
        | {:error, :invalid_cursor | :wrong_endpoint | :expired}
```

Cursor-paginated per REQ-067's existing contract, copying `Letflow.Dlq.list/2`'s idiom
directly (§0 above): a module-level `@list_cursor_prefix` constant, distinct from every
other endpoint's cursor prefix per REQ-067's AC3 (e.g. `"IA:"` — the exact literal is
ELIXIR-DEV's Step-2a choice, constrained only to be distinct from `Letflow.Dlq`'s
`"D:"` and any other shipped cursor prefix; ELIXIR-DEV must grep existing
`@list_cursor_prefix`/`@cursor_prefix`-shaped constants across the codebase before
picking one, to avoid a collision REQ-067's own prefix-check would otherwise silently
mask as "wrong endpoint" errors on an unrelated module). Query: filter by `instance_id`
(required, not optional — unlike `Letflow.Dlq.list/2`'s several optional filters, this
module's `list/2` always scopes to one instance, per the requirement's own "filtered by
instance_id" text), order by `(created_at desc, id desc)` matching §1.3 index 1's shape
plus the `id` tie-break §1.2's `created_at` column note discusses, `limit(page_size + 1)`
fetch-and-drop-extra exactly as `Letflow.Dlq.list/2` does, `page_size` validated via
`Letflow.Api.Pagination.validate_page_size/1` (400-on-out-of-range, not a silent clamp).

**Tenant scoping (AC5's first clause):** `opts[:prefix]` alone scopes the query to one
tenant's Postgres schema — structurally, a `list/2` call scoped to tenant B's prefix
cannot return any row physically stored in tenant A's schema, the same
schema-per-tenant guarantee `Letflow.Webhooks.list/1`'s moduledoc states verbatim.
**Instance scoping (AC5's second clause):** the `instance_id` filter is a `WHERE`
predicate within that already-tenant-scoped query — an attachment uploaded under
`instance_id X` is absent from a `list/2` call for the same tenant's `instance_id Y`,
by the same predicate.

### 4.3 `get/2`

```
@spec get(id :: String.t(), opts()) :: {:ok, Attachment.t()} | {:error, :invalid_id | :not_found}
```

Tenant-scoped fetch of one attachment's metadata, mirroring `Letflow.Dlq.get/2`/
`Letflow.Webhooks.get/2`'s shared idiom exactly: `Ecto.UUID.cast/1` first
(`{:error, :invalid_id}`, no DB round-trip), then `Repo.get(Attachment, id, prefix:
prefix)` (`{:error, :not_found}` for both "does not exist anywhere" and "exists only in
another tenant's schema" — the same structural cross-tenant-404 mechanism).

**Returns metadata only, not byte content — corrected framing (this revision).** The
prior version of this section described `get/2` enabling a future route layer to
"stream bytes back from `repository_artifacts`" without stating a real mechanism for
doing so, because at that time `repository_artifacts` had no column capable of
satisfying that claim (OQ-4). §2A now adds `repository_artifacts.content :bytea`,
which makes the claim genuinely true, but the mechanism is now stated concretely
rather than left implicit:

`get/2` itself still returns `Attachment.t()` (metadata only — `content_hash` and
`byte_size` as ordinary fields, §1.2/§3) and still performs no `repository_artifacts`
read of its own; this module deliberately keeps `get/2` a cheap, single-table,
`instance_attachments`-only fetch (no join), consistent with `Letflow.Dlq.get/2`/
`Letflow.Webhooks.get/2`'s shared idiom (§0) and with keeping a metadata-list/detail
call cheap regardless of how large the referenced content is. **The real byte-retrieval
mechanism a future REQ-212 route handler uses is:** call `get/2` (or `list/2`) to
obtain `attachment.content_hash`, then perform a second, separate lookup —
`Repo.get(Letflow.Repository.Artifact, content_hash, prefix: prefix)` (or an
equivalent one-row `Ecto.Query`) — against `repository_artifacts`, now reading its
`content` field (§2A) directly, since that field genuinely holds the raw bytes as of
this revision. That second lookup is REQ-212's own route-layer responsibility, out of
this module's scope exactly as before — the only change from the prior version of this
document is that the mechanism REQ-212 will use is now named concretely and confirmed
to exist, rather than assumed. This module (`Letflow.Repository.Attachments`) adds no
new public function for this — `get/2`'s existing return shape (`attachment.content_hash`)
is sufficient for a caller to perform that second lookup itself, matching this
document's original intent, now made accurate.

### 4.4 The upload size ceiling — `@max_upload_bytes`

**Decision: `@max_upload_bytes 26_214_400` (25 MiB = 25 × 1024 × 1024 bytes), enforced
inside `upload/2` (§4.1 step 1) as this module's own module attribute — not derived
from, and not shared with, `Letflow.Plugs.ApiPipeline`'s existing `Plug.Parsers` cap.**

**Why not reuse the existing 2 MB (`2_097_152`) JSON body-size cap
(`lib/letflow/plugs/api_pipeline.ex:50`):** that cap exists specifically for
`Plug.Parsers`'s `:json` parser branch, sized "large enough for any single-workflow
payload" per its own comment — a JSON API request body, not a binary file attachment.
REQ-206's own motivating scenario is attaching a delivery-note document; a 2 MB ceiling
would reject a realistic PDF/scanned-document attachment. This module's ceiling is a
fresh, independent decision, stated explicitly here per the requirement's own
instruction ("name a concrete number... or a new explicit one if none exists").

**Why 25 MiB specifically:** no existing precedent in this codebase or in
`docs/migration/decisions/` fixes a file-attachment size limit, and grepping this
project's own R-Co source citations found nothing to port (the requirement's own text
confirms attachments are genuinely new functionality, not a missed port). 25 MiB is
chosen as a round, conservative number for a document-attachment use case
(delivery notes, signed forms, scanned receipts — realistic multi-page PDFs
comfortably fit; a video or bulk-data-export use case would not, and is not what this
requirement's scenario describes) — large enough for the motivating scenario, small
enough to bound per-request memory pressure meaningfully above the existing 2 MB JSON
cap without adopting an arbitrarily large ceiling. This is a Letflow-only choice
(matching the same "Letflow's own choice, not ported from R-Co" framing
`Letflow.Webhooks`'s moduledoc uses for its own `@auto_pause_threshold`/`@max_attempts`
constants) — **flagged for REVIEWER at Step 2d**, since this is a genuinely
judgement-based number with no requirement-stated value, exactly the kind of thing
`core-directives.md`'s "flag rather than silently pick" principle expects surfaced
rather than buried in a module attribute with no comment trail.

**Enforcement point:** entirely inside `upload/2` (§4.1 step 1), on the actual
`byte_size(raw_bytes)` this module computes — never on a caller-declared size field
(there is none in `upload_attrs()`, §4.0 item 4) and never relying solely on a
future REQ-212 route-layer `Plug.Parsers`/multipart `:length` option, since a caller of
this context module that is not the REQ-212 route (a future internal caller, a test) must
get the same rejection. **REQ-212's own route layer, when built, should additionally
configure its multipart parser's own `:length` option at or near this same ceiling** —
named here as a forward-looking consistency note for REQ-212's own design step, not a
requirement REQ-211's own acceptance criteria impose (REQ-211's AC4 only requires this
module's own rejection, demonstrated by an over-limit call to `upload/2` directly).

### 4.5 `delete/2`

```
@spec delete(id :: String.t(), opts()) :: {:ok, Attachment.t()} | {:error, :invalid_id | :not_found}
```

Tenant-scoped hard delete of the `instance_attachments` row **only** — mirrors
`Letflow.Webhooks.delete/2`'s shape exactly: reuses `get/2` (§4.3) for
id-validation/tenant-scoped-existence, then `Repo.delete/2` on the fetched struct. The
underlying `repository_artifacts` row referenced by `content_hash` is **never** deleted
by this function — no code path in this module calls `Repo.delete/2` (or any other
mutation) against `Letflow.Repository.Artifact`. This is enforced two ways
independently, both stated in the moduledoc (§4.0 item 9): (a) this module's own code
simply never attempts it, and (b) even if it did, REQ-202's `repository_artifacts`
table has an unconditional `BEFORE DELETE` trigger (`priv/repo/migrations/20260830030001_create_repository_artifacts.exs`)
that would reject the attempt at the database level regardless, and this
`instance_attachments.content_hash` column's own `on_delete: :restrict` FK would in any
case prevent a `repository_artifacts` row from being deleted while any
`instance_attachments` row still references it.

AC7's demonstration (two attachments sharing one hash; deleting one leaves the other
and the `repository_artifacts` row intact) requires no special-casing in `delete/2`'s
own logic — it follows automatically from `delete/2` only ever touching the
`instance_attachments` table, exactly as `upload/2`'s upsert-by-hash (§4.1 step 3) can
produce that two-attachments-one-hash state in the first place.

---

## 5. `opts()` type and tenant-scoping type alias

```
@typedoc "Threaded into every `Repo` call below — `:prefix` derived by the caller from `Letflow.Api.Context.scoped_repo_opts/1`, never from request data."
@type opts :: [prefix: String.t()]
```

Identical in shape and wording to `Letflow.Dlq.opts()`/`Letflow.Webhooks.opts()` —
reused verbatim as this codebase's established convention, not reinvented.

---

## 6. Security-relevant design decisions (SECURITY-REVIEWER's Step 2c gate)

Stated concretely here, per the assigning agent's instruction not to merely gesture at
these:

- **INV-a (content_type never trusted).** §4.0 item 3 / §1.2's `content_type` row. No
  function in this module inspects, validates, or sniffs the actual byte content
  against the declared `content_type`. This is a stated, deliberate scope boundary, not
  an omission SECURITY-REVIEWER should treat as a gap to fix here — content-type
  sniffing (or rejecting a mismatch) is not asked for by any REQ-211 acceptance
  criterion and is explicitly not this requirement's job; a future requirement may add
  it if a concrete need arises.
- **INV-b (byte_size independently measured).** §4.0 item 4 / §4.1 step 1. Structurally
  guaranteed by `upload_attrs()`'s own shape (§4.1) having no caller-declared-size field
  at all — there is nothing for this module to "trust" even if it wanted to.
- **Upload size ceiling (DoS surface).** §4.4 — `@max_upload_bytes 26_214_400`,
  enforced inside `upload/2` before any DB write, checked against the real measured byte
  count from step (b) above. Flagged for REVIEWER at Step 2d as a judgement-based
  number (§4.4's own final paragraph).
- **INV-1 (tenant isolation).** Every function takes `opts[:prefix]`; `tenant_id` is
  always derived, never caller-supplied (§4.0 item 2); `repository_artifacts` reuse
  crosses no tenant boundary because that table is itself per-tenant-schema (§4.0 item
  6) — confirmed directly from the shipped REQ-202 migration (§0 above), not merely
  from that requirement's design doc's stated intent.
- **INV-7 (no SQL string interpolation).** No raw `Repo.query`/`Ecto.Adapters.SQL.query`
  calls anywhere in this design — every operation is `Ecto.Query`/`Ecto.Changeset`/
  `Repo.insert`/`Repo.get`/`Repo.delete`, parameterised by construction. The migration
  (§2) uses no string-interpolated SQL either (unlike `req202`'s migration, which needed
  raw `execute/2` SQL for its trigger functions — this table needs no analogous trigger,
  §1.4).
- **INV-8 (no unhandled crashes on realistic failure paths).** Every function returns a
  tagged `{:ok, _} | {:error, _}` result; no bare `{:ok, x} = ...` match appears in any
  step description above on a path reachable from caller input.
- **§2A migration addendum — REVIEWER sign-off explicitly required.** Altering an
  already-`done` requirement's (REQ-202) shipped table is a change this pipeline does
  not make casually — §2A's own text states why (Postgres `bytea`, no new
  infrastructure, `null: false` with no backfill needed since no rows predate this
  addendum) and names the contingency if that last assumption is wrong. REVIEWER must
  also confirm REQ-202's own immutability triggers (`repository_artifacts_no_update`/
  `_no_delete`, §0) correctly cover the new `content` column with no additional
  migration work (this document's own analysis: they do, since both triggers are
  unconditional `BEFORE UPDATE`/`BEFORE DELETE` row-level triggers, not column-scoped).
- **§4.1 step 3 — cross-module change to `Letflow.Repository` flagged for REVIEWER.**
  Whichever option (a)/(b) is taken, this document treats a REQ-211 requirement
  reaching into REQ-202's existing module as a decision REVIEWER must sign off on
  explicitly, not something ELIXIR-DEV should resolve silently at Step 2a purely by
  local convenience.

---

## 7. Functions deliberately NOT built (scope discipline)

| Function | Why not |
|---|---|
| `update/2` | Not requested by any acceptance criterion; §1.4/§3 — no update changeset exists. A "changed" attachment is a new `upload/2` call (a new row), matching the immutable-content spirit of the store it references, though not itself DB-trigger-enforced (§1.4). |
| Content-hash-level `delete/1` against `repository_artifacts` | REQ-202's own scope; blocked at the DB level regardless (§4.5). |
| Any route/controller | REQ-212's scope, explicitly (AC10). |
| AV/content-scanning | Named, deliberately deferred follow-up (§4.0 item 8, AC9). |
| Byte-content streaming/download helper | REQ-212's route-layer job — `get/2` returns the `content_hash`/`byte_size` a route handler needs (§4.3); this module does not itself read `repository_artifacts.content` (§2A) into memory, by design (keeps `get/2` cheap and single-table). |

---

## 8. Open questions (stated explicitly, not silently resolved)

- **OQ-1 — no FK from `instance_attachments.instance_id` to an instance-identifying
  table.** This design does not add a foreign key from `instance_id` to
  `instance_projections`/`tokens`/wherever an authoritative "does this instance exist"
  table lives, because REQ-211's own scope is the attachment subsystem in isolation and
  the requirement text does not ask for this join. A consequence: `upload/2` will
  happily create an attachment for a nonexistent `instance_id` — no referential check
  exists at this layer. ELIXIR-DEV/REQ-212 should decide whether the future route layer
  validates `instance_id` existence before calling `upload/2` (likely, since the route
  resolves `:id` from the URL path and presumably already needs to confirm the instance
  exists for authorization purposes) — this document does not resolve that here, since
  it is a REQ-212-layer concern, not this module's.
- **OQ-2 — no uniqueness constraint on repeated identical uploads to the same
  instance.** §1.3 item 3 states this is deliberate, but flags it as worth confirming
  with TEST-DESIGNER/REVIEWER: if a future UX requirement wants "don't let a user
  accidentally attach the same file twice to the same instance," that would need either
  an application-level check in `upload/2` or a new unique index — not built here since
  no acceptance criterion asks for it and it would contradict AC2's own two-different-
  instance_id framing if misapplied to the single-instance case.
- **OQ-3 — which upload's `content_type`/`byte_size` "wins" in `repository_artifacts` on
  a hash collision.** §4.1 step 3: when `content_hash` already exists in
  `repository_artifacts`, this design (following req202 design §4.2 step 3's own
  precedent verbatim) does not re-validate or overwrite the existing row's
  `content_type`/`byte_size` — "a hash collision implies identical content by
  construction, so there is nothing to reconcile" (quoting req202's own reasoning). This
  means if two attachments with genuinely identical bytes are uploaded with two
  *different* declared `content_type` values (e.g. one caller says
  `"application/pdf"`, another says `"application/octet-stream"` for the same bytes),
  the stored `repository_artifacts.content_type` reflects whichever upload happened
  first, while each `instance_attachments` row still independently stores its own
  caller's declared `content_type` (§1.2 — `instance_attachments.content_type` is a
  separate column from `repository_artifacts.content_type`, not read back from it).
  This is inherited from REQ-202's existing upsert semantics, not a new decision this
  requirement introduces, and is not silently glossed over here.
- **OQ-4 — RESOLVED in this revision, no longer open.** Prior versions of this document
  flagged that `repository_artifacts` had no column storing raw bytes, making `get/2`'s
  "stream bytes back" framing unsatisfiable. Per ORCH decision, §2A now adds
  `repository_artifacts.content :bytea` (a migration addendum to REQ-202's shipped
  table, keyed by the existing `content_hash` PK), and §4.1 step 3 / §4.3 are revised to
  describe the real write and read paths against that column. Two follow-on decisions
  this resolution introduces are themselves now named explicitly rather than left
  implicit (not new open questions in the same sense as OQ-1/2/3 — both require a
  REVIEWER sign-off, not a "defer" judgment call): (a) §2A's schema change to an
  already-`done` REQ-202's table, and (b) §4.1 step 3's choice between making
  `Letflow.Repository`'s private `upsert_content/5` public-and-shared vs. this module
  duplicating the upsert against `Letflow.Repository.Artifact.changeset/2` directly.

---

## 9. Traceability — acceptance criteria to design elements

| AC (paraphrased) | Design element |
|---|---|
| AC1 — per-tenant schema, `tenant_id` retained, `instance_id` required not-nullable | §1.1, §1.2 (`instance_id` row), §2 |
| AC2 — `upload/2` hashes independently, upserts `repository_artifacts` (including real bytes into `content`, §2A), one hash row / two attachment rows across two instances | §4.1 steps 1-3, 5; §2A |
| AC3 — `byte_size` independently measured, mismatched declared size ignored | §4.0 item 4, §4.1 step 1 (structural: no caller-size field exists) |
| AC4 — upload ceiling named, rejected before persistence, no rows created | §4.4 (25 MiB), §4.1 step 1 |
| AC5 — `list/2` tenant-scoped + instance_id-filtered | §4.2 |
| AC6 — `list/2` REQ-067 cursor pagination, no repeat/skip | §4.2 (cursor prefix, `page_size+1` fetch-and-drop) |
| AC7 — `delete/2` metadata-only, `repository_artifacts` row and sibling attachment survive | §4.5 |
| AC8 — moduledoc: per-tenant-schema dedup boundary + no-canonicalisation statement | §4.0 items 6-7 |
| AC9 — moduledoc: content-scanning named as deferred follow-up | §4.0 item 8 |
| AC10 — no route/controller file | §7 (functions deliberately not built) |
| AC11 — `mix test`/`mix compile --warnings-as-errors` pass | Step 2a/4 execution, not a design-stage artifact |
