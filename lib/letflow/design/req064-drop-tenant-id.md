# REQ-064 — Drop `tenant_id` from schema-isolated tables (Decision 0006 D2)

Status: design. Executes Decision 0006
(`docs/migration/decisions/0006-identity-tables-schema-per-tenant.md`) D2, now
that D1 (REQ-063, PR #177) is merged. Read alongside Decision 0003
(`docs/migration/decisions/0003-ecto-schema-strategy.md`) Dimension B and its
Addendum — §6 below restates exactly what of 0003 this supersedes and what
stands.

## 0. Module-ownership verification (mandatory first step, done against real `lib/` state)

The requirement text was written before REQ-063 shipped and named
`Engine.Token` for the tokens-table schema. Verified directly against
`lib/letflow/engine/` this session:

| Requirement text's name | Actual current module | File | Owns tokens-table `tenant_id`? |
|---|---|---|---|
| `Engine.Token` | **`Letflow.Engine.TokenRecord`** | `lib/letflow/engine/token_record.ex` | **Yes** — `schema "tokens"`, `field(:tenant_id, Ecto.UUID)`, cast in both changesets |
| (n/a — REQ-044's struct) | `Letflow.Engine.Token` | `lib/letflow/engine/token.ex` | No — plain `defstruct`, zero `Ecto`/`Repo` dependency, no `tenant_id` field at all, not touched by this requirement |

`token_record.ex`'s own moduledoc documents the rename explicitly ("post-hoc
integration rename" section): REQ-044 claimed `Engine.Token` first for its
pure in-memory struct, so REQ-043's schema module ships as `TokenRecord`.
**§4 and §5 below use `Letflow.Engine.TokenRecord`, not `Engine.Token`,
throughout.**

The other nine named modules were independently re-confirmed by direct read
this session; all match the requirement text's names exactly, no further
corrections needed:

| Table | Module | File | Confirmed |
|---|---|---|---|
| `events` | `Letflow.EventStore.Event` | `lib/letflow/event_store/event.ex` | yes |
| `events_archive` | `Letflow.EventStore.ArchivedEvent` | `lib/letflow/event_store/archived_event.ex` | yes |
| `instance_projections` | `Letflow.EventStore.InstanceProjection` | `lib/letflow/event_store/instance_projection.ex` | yes |
| `process_definitions` | `Letflow.Definitions.ProcessDefinition` | `lib/letflow/definitions/process_definition.ex` | yes |
| `tasks` | `Letflow.Engine.Task` | `lib/letflow/engine/task.ex` | yes (this one genuinely IS `Engine.Task`, unaffected by the Token/TokenRecord rename) |
| `promotion_reviews` | `Letflow.Definitions.PromotionReview` | `lib/letflow/definitions/promotion_review.ex` | yes |
| `promotion_assertion_runs` | `Letflow.Definitions.PromotionAssertionRun` | `lib/letflow/definitions/promotion_assertion_run.ex` | yes |
| `users` | `Letflow.Identity.User` | `lib/letflow/identity/user.ex` | yes (now per-tenant-schema per REQ-063) |
| `groups` | `Letflow.Identity.Group` | `lib/letflow/identity/group.ex` | yes (now per-tenant-schema per REQ-063) |

**Corrected module list for §4 (ten modules, one name corrected from the
requirement text):** `Letflow.Engine.Task`, `Letflow.Engine.TokenRecord`,
`Letflow.EventStore.Event`, `Letflow.EventStore.ArchivedEvent`,
`Letflow.EventStore.InstanceProjection`, `Letflow.Definitions.ProcessDefinition`,
`Letflow.Definitions.PromotionReview`, `Letflow.Definitions.PromotionAssertionRun`,
`Letflow.Identity.User`, `Letflow.Identity.Group`.

## 1. Untouched tables — Decision 0006 D3 (stated explicitly, not silently omitted)

**`tenant_schemas`, `solution_pack_installs`, `solution_pack_artefact_bases`,
`pack_update_resolutions` are NOT touched by this requirement, in any way —
no migration, no schema-module edit, no moduledoc edit.** On these four,
`tenant_id` is a real `references(:tenants, type: :binary_id)` foreign key on
a structurally-global public-schema table — it is the only scoping the row
has, not a redundant copy of a schema boundary. Dropping it there would be a
data-model break, not a cleanup (0006 §D3, §R1). ELIXIR-DEV must not touch
their migrations or schema modules under this requirement; if any file for
these four tables appears in a later diff for this requirement, that is scope
creep and REVIEWER must reject it.

`tenant_role` never had the column (0006, stated directly) — nothing to drop
there either.

`TenantProvisioning.tenant_id_for_schema_name/1` **itself is NOT deleted** —
only its *stamping* call sites (§3 below). REQ-063's data-copy step already
used it and D4's future cross-tenant reporting mechanism may need it again;
deleting the function is out of this requirement's scope and would be a
defect, not a cleanup.

## 2. Migrations — dropping `tenant_id` from the ten confirmed tables

### 2.1 Shape and guard (applies to every `DROP COLUMN` below)

One migration per table (ten total), each tenant-scoped via the same
mechanism REQ-022 §4 and every migration since has used — `if prefix() do`
guarding the real branch, so a plain `mix ecto.migrate` (no `:prefix`) no-ops
and only `Letflow.TenantProvisioning.replay_migrations/2` against a real
tenant schema name executes it. Each migration is added to
`Letflow.TenantProvisioning.tenant_scoped_migrations/0`'s manifest — per
`tenant_provisioning.ex`'s own established three-element `{version, module,
filename}` form (see `tenant_scoped_migrations/0`'s moduledoc on why the bare
two-element form is a latent defect). ELIXIR-DEV may combine several of the
ten `DROP COLUMN`s into fewer migration files if it prefers (e.g. grouping
the three event-store tables into one file) — that is an implementation
choice this design does not mandate either way — but **every** `alter
table(...)` block, regardless of how many share a file, must be wrapped in
its own `if prefix() do` guard exactly like every existing tenant-scoped
migration. Within one migration file it is fine for multiple `alter
table(...)` blocks to sit inside the same top-level `if prefix() do ... end`;
what is not fine is a single migration *file* touching more than one table
without every one of those alters still being reached only through a
prefix()-truthy branch (each file is independently replayed via
`replay_migrations/2` and must be independently safe against a plain, no-op
`mix ecto.migrate` on its own).

Generic shape per table (`T` = table name):

```
if prefix() do
  alter table(:T, prefix: prefix()) do
    remove :tenant_id
  end
end
```

`remove/1` (not `remove/3` with a type) is sufficient — Ecto's migration DSL
does not require the column type on a plain drop, and no `:from` type
tracking is needed since this is a one-way forward migration with no
generated `down/0` body relying on the type (per this codebase's established
convention of `change/0`-only migrations with Ecto's auto-reversal, which for
`remove/1` requires the type — **note this differs from the general case**:
Ecto's `change/0` auto-reversal for `remove/1` alone cannot infer the
rollback column type, so if ELIXIR-DEV needs a *reversible* migration (this
project's own established pattern, since every prior migration in
`priv/repo/migrations/` uses `change/0` only, no separate `up/0`/`down/0`),
use `remove(:tenant_id, :binary_id)` instead of bare `remove(:tenant_id)` —
the three-argument form Ecto uses for its own reversal, matching this
codebase's stored-type convention (`:binary_id`, not `Ecto.UUID`, at the
migration-DSL layer, exactly as every existing migration's `add :tenant_id,
:binary_id` shows). **Design decision: use `remove(:tenant_id, :binary_id)`
on every one of the ten migrations**, for reversibility consistency with the
rest of this migration set.

### 2.2 The ten migrations, table by table

For each, `T` is the table, `M` is the Ecto migration module name ELIXIR-DEV
assigns (design does not mandate exact filenames/timestamps — ELIXIR-DEV
picks per this codebase's `YYYYMMDDHHMMSS_verb_description.exs` convention,
sorted after every existing migration and, where a same-file FK ordering
constraint exists — see below — internally consistent):

1. `events` (`Letflow.EventStore.Event`) — `remove(:tenant_id, :binary_id)`.
   No index depends solely on `tenant_id` (none exists per the current
   migration; `idx_events_global_seq`, the `(instance_id, created_at)` index,
   `idx_events_type`, and `uq_event_sequence` on `(instance_id,
   sequence_number)` are all `tenant_id`-free already).
2. `events_archive` (`Letflow.EventStore.ArchivedEvent`) —
   `remove(:tenant_id, :binary_id)`. Same: no `tenant_id`-bearing index
   exists on this table today (the current migration's header already notes
   R-Co's tenant-prefixed indexes were never ported, per 0003 Decision B).
3. `instance_projections` (`Letflow.EventStore.InstanceProjection`) —
   `remove(:tenant_id, :binary_id)`. No index carries `tenant_id`
   (`idx_proj_definition` is on `definition_id` alone,
   `uq_instance_correlation` is on `(definition_id, correlation_key)`, the
   `status` index is bare).
4. `process_definitions` (`Letflow.Definitions.ProcessDefinition`) —
   `remove(:tenant_id, :binary_id)`. No `tenant_id`-bearing index exists
   (the current migration's header already documents the tenant-prefixed
   `uq_definition_tenant_version`-family indexes as deliberately never
   built, per 0003 Decision B).
5. `tokens` (`Letflow.Engine.TokenRecord`) — `remove(:tenant_id, :binary_id)`.
   No `tenant_id`-bearing index (`idx_token_instance` on `instance_id` alone,
   `idx_token_parent` — actual name TBD by ELIXIR-DEV reading the shipped
   migration — on `parent_token_id` alone).
6. `tasks` (`Letflow.Engine.Task`) — `remove(:tenant_id, :binary_id)`. No
   `tenant_id`-bearing index (`idx_task_instance`, `idx_task_token`, both
   single-column on their FK target).
7. `promotion_reviews` (`Letflow.Definitions.PromotionReview`) — **combined
   with the index simplification, §2.3 below** — this migration both drops
   the column and replaces `uq_promotion_review_active_digest` and
   `idx_promotion_review_rollback_lookup`, since both currently lead with
   `tenant_id`.
8. `promotion_assertion_runs` (`Letflow.Definitions.PromotionAssertionRun`) —
   **combined with the index simplification, §2.3 below** — drops the column
   and replaces `uq_promotion_assertion_runs_idempotency` (currently leads
   with `tenant_id`). `idx_promotion_assertion_runs_review` (on `review_id`
   alone) and the `chk_promotion_assertion_run_status` CHECK are untouched —
   neither references `tenant_id`.
9. `users` (`Letflow.Identity.User`) — `remove(:tenant_id, :binary_id)`, plus
   drop **`index(:users, [:tenant_id, :status, :inserted_at])`** (unnamed,
   Ecto's default-name form — actual index name is
   `users_tenant_id_status_inserted_at_index`, Ecto's standard
   `<table>_<cols>_index` convention; ELIXIR-DEV must confirm the exact
   generated name against the shipped `20260819000003_create_users_tenant_scoped.exs`
   before writing the `drop index(...)` call, or use `drop_if_exists
   index(:users, [:tenant_id, :status, :inserted_at])` to sidestep exact-name
   risk). **This index is not named in the requirement text's "two composite
   indexes simplify" list — it is a third, found during this design's direct
   read of the shipped `users` migration.** It has no non-tenant-prefixed
   value to preserve (unlike the promotion tables' indexes, `[:status,
   :inserted_at]` alone was never an established query shape named by any
   REQ-018/019/063 acceptance criterion) — **decision: drop it outright, do
   not replace it with `index(:users, [:status, :inserted_at])`**, since no
   consumer of that shape has been found in `lib/letflow/identity.ex` or
   elsewhere this session (see §3 — no site queries `users` filtered by
   `status`+`inserted_at` without also already being inside one tenant's
   `:prefix`, where a plain `status`/`inserted_at` index would still be
   useful only if such a query existed, and none does). Flagged as an open
   question in §7 rather than silently resolved either way beyond this
   default.
   `unique_index(:users, [:username])` and
   `users_external_identity_partial_index` are untouched — neither
   references `tenant_id`.
10. `groups` (`Letflow.Identity.Group`) — `remove(:tenant_id, :binary_id)`,
    plus **drop `index(:groups, [:tenant_id])`** (the table's only index,
    per `20260819000001_create_groups_tenant_scoped.exs` and Decision 0006
    §5's own text: "`groups` likewise (its only index is
    `index(:groups, [:tenant_id])`, which D2 simply drops)"). No replacement
    index — the column carried no other value, and 0006 states this
    explicitly.

### 2.3 Composite-index simplifications (promotion_reviews, promotion_assertion_runs)

**`promotion_reviews`** (migration 7 above) — exact before/after:

```
# BEFORE (20260816200001_create_promotion_reviews.exs, currently shipped):
create unique_index(:promotion_reviews, [:tenant_id, :plan_digest],
         name: :uq_promotion_review_active_digest,
         where: "status IN ('pending_review', 'approved')",
         prefix: prefix()
       )

create index(:promotion_reviews, [:tenant_id, :status],
         name: :idx_promotion_review_rollback_lookup,
         where: "status IN ('applied', 'superseded')",
         prefix: prefix()
       )

# AFTER (this migration):
drop index(:promotion_reviews, [:tenant_id, :plan_digest],
       name: :uq_promotion_review_active_digest,
       prefix: prefix()
     )

drop index(:promotion_reviews, [:tenant_id, :status],
       name: :idx_promotion_review_rollback_lookup,
       prefix: prefix()
     )

alter table(:promotion_reviews, prefix: prefix()) do
  remove :tenant_id, :binary_id
end

create unique_index(:promotion_reviews, [:plan_digest],
         name: :uq_promotion_review_active_digest,
         where: "status IN ('pending_review', 'approved')",
         prefix: prefix()
       )

create index(:promotion_reviews, [:status],
         name: :idx_promotion_review_rollback_lookup,
         where: "status IN ('applied', 'superseded')",
         prefix: prefix()
       )
```

Index *names* are kept identical (`uq_promotion_review_active_digest`,
`idx_promotion_review_rollback_lookup`) — only the column list and, for the
unique index, the leading column drop; the partial `WHERE` predicates are
unchanged in both. `PromotionReview.insert_changeset/2`'s
`unique_constraint([:tenant_id, :plan_digest], name:
:uq_promotion_review_active_digest)` call (§4 below) becomes
`unique_constraint(:plan_digest, name: :uq_promotion_review_active_digest)` —
constraint matching is by index **name**, so this edit is required
independent of the column-list change, or the constraint match silently
stops firing.

**`promotion_assertion_runs`** (migration 8 above) — exact before/after:

```
# BEFORE (20260818090001_create_promotion_assertion_runs.exs, currently shipped):
create unique_index(:promotion_assertion_runs, [:tenant_id, :idempotency_key],
         name: :uq_promotion_assertion_runs_idempotency,
         prefix: prefix()
       )

# AFTER (this migration):
drop index(:promotion_assertion_runs, [:tenant_id, :idempotency_key],
       name: :uq_promotion_assertion_runs_idempotency,
       prefix: prefix()
     )

alter table(:promotion_assertion_runs, prefix: prefix()) do
  remove :tenant_id, :binary_id
end

create unique_index(:promotion_assertion_runs, [:idempotency_key],
         name: :uq_promotion_assertion_runs_idempotency,
         prefix: prefix()
       )
```

**Idempotency contract restated in the migration header (mandatory text for
ELIXIR-DEV to include, condensed from the shipped migration's own header and
from `Letflow.Definitions.claim_or_fetch_assertion_run/5`'s real call site):**

> This table's idempotency-anchor contract — one row per idempotency key,
> checked via `Repo.insert(changeset, on_conflict: :nothing, conflict_target:
> [...])` — is unchanged in *meaning* by this migration, only in *shape*.
> Before: at most one row per `(tenant_id, idempotency_key)` pair, checked
> via `conflict_target: [:tenant_id, :idempotency_key]`
> (`lib/letflow/definitions.ex`'s `claim_or_fetch_assertion_run/5`). After:
> at most one row per `idempotency_key` alone, checked via
> `conflict_target: [:idempotency_key]`. This is not a widening of the
> uniqueness guarantee — inside one tenant's Postgres schema, `tenant_id` had
> at most one distinct value already (0006 §R3, restated from the
> `events_archive`/`process_definitions` migration headers this table's own
> header already cites), so `(tenant_id, idempotency_key)` and
> `(idempotency_key)` alone were already equivalent constraints within any
> single schema — this migration only removes the now-redundant leading
> column from the index/conflict-target shape, it does not change which rows
> the constraint allows to coexist.

`Repo.get_by(PromotionAssertionRun, [tenant_id: tenant_id, idempotency_key:
idempotency_key], prefix: prefix)` in `fetch_existing_assertion_run/3`
(`lib/letflow/definitions.ex:1492`) is a **plain `WHERE`, not an index/
conflict-target reference** — it still compiles and runs correctly with
`tenant_id` removed from the schema struct and the keyword list correspondingly
trimmed to `[idempotency_key: idempotency_key]` (§3 below covers this call
site's edit explicitly, it is not a migration-layer concern).

## 3. Per-site decisions — `tenant_id_for_schema_name/1` call sites (14 total, corrected count)

The requirement text estimates "roughly 13" (8 + 4 + 1). Direct grep against
current `lib/` this session found **9 sites in `definitions.ex`** (not 8),
**4 in `event_store.ex`** (matches), **1 in `promotion_review_store.ex`**
(matches) — **14 total, corrected from the requirement text's ~13.** Every
site is listed below with an explicit removed/kept decision; none is a
blanket call.

### 3.1 `lib/letflow/definitions.ex` (9 sites)

| Line (current) | Function | What `tenant_id` is used for today | Decision |
|---|---|---|---|
| 405 | `create/2` | Stamps `ProcessDefinition.create_changeset/2` via `insert_definition/3`'s `Map.put(attrs, :tenant_id, tenant_id)` | **Call site REMOVED.** The `{:ok, tenant_id} <-` binding and its downstream `Map.put(:tenant_id, ...)` in `insert_definition/3` both go — see §4 for the changeset-level edit. Replace with a bare prefix-validity check (see below) if REQ-064 keeps the "reject an unprovisioned/malformed prefix early" behavior — decision: **kept as validation**, `{:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix)`, since `create/2` otherwise has no early prefix-validity guard before its multi-step `with` chain reaches `Repo.insert/2`, and losing it would change `create/2`'s error surface (a malformed/unprovisioned prefix would newly surface as a raw `Ecto.QueryError`/similar from `Repo.insert/2` instead of this function's own `{:error, :tenant_not_provisioned}`-shaped early return). The binding changes from `{:ok, tenant_id}` to `{:ok, _}`, and `insert_definition/3`'s second parameter (currently `tenant_id`) is dropped entirely (see §4). |
| 427 | `get_by_id/2` | `{:ok, _tenant_id} <-`, discarded | **Kept as validation.** Rename binding to `{:ok, _}` (no functional change — already discards the value; this is a cosmetic/clarity edit only, since `_tenant_id` naming implies a value that no longer exists conceptually). |
| 446 | `get_active_by_name/2` | `{:ok, _tenant_id} <-`, discarded | **Kept as validation**, same as 427. |
| 469 | `list/2` | `{:ok, _tenant_id} <-`, discarded | **Kept as validation**, same as 427. |
| 506 | `activate/2` | `{:ok, tenant_id} <-`, then passed to `run_activate_transaction/4` → `run_service_scope_validator(definition, tenant_id, validator)` | **Call site KEPT, unchanged in shape.** This is not a stamping site and not a discard-only validation site — `tenant_id` is a genuine functional input to `validator.(actor_id, tenant_id)` (the `opts[:service_scope_validator]` caller-supplied function), unrelated to the `process_definitions.tenant_id` column being dropped. `tenant_id_for_schema_name/1` remains the correct source for this value (it still resolves prefix → tenant UUID correctly; nothing about D2 makes the resolution itself wrong, only the *column write* moot). No edit to this call site. |
| 571 | `search/2` | `{:ok, _tenant_id} <-`, discarded | **Kept as validation**, same as 427. |
| 687 | `rollback_definition_version/4` | `{:ok, tenant_id} <-`, then passed to `do_rollback/5` for `permission_checker.(actor_id, tenant_id)` | **Call site KEPT, unchanged**, same reasoning as 506 — `permission_checker` is a genuine functional consumer of `tenant_id`, not a stamping path. |
| 811 | `apply_promotion_assertion_rerun/6` | `{:ok, tenant_id} <-`, then passed to `claim_or_fetch_assertion_run/5` which stamps `attrs.tenant_id` into `PromotionAssertionRun.insert_changeset/2`, AND passed to `fetch_existing_assertion_run/3`'s `Repo.get_by(..., tenant_id: tenant_id, ...)` | **Call site KEPT for prefix resolution, but its two downstream consumers both change** — see §4 (changeset stamping removed) and this table's note below (the `Repo.get_by` keyword list loses the `tenant_id:` key). The `with {:ok, tenant_id} <- ...` binding itself stays as-is at line 811; `tenant_id` is still needed as a parameter threaded to `claim_sandbox_and_proceed/6` etc. for other purposes unrelated to this cleanup (confirm no other use before deleting the binding — **open question, see §7**, since a full trace of every `tenant_id` downstream use inside `apply_promotion_assertion_rerun/6`'s call graph beyond `claim_or_fetch_assertion_run/5` and `fetch_existing_assertion_run/3` was not exhaustively completed this session). |
| 1131 | `transition/3` (private, used by `deprecate/2`/`archive/2`) | `{:ok, _tenant_id} <-`, discarded | **Kept as validation**, same as 427. |

`insert_definition/3`'s signature changes from `insert_definition(attrs,
tenant_id, prefix)` to `insert_definition(attrs, prefix)` (drops the
now-unused second parameter) — see §4.

`claim_or_fetch_assertion_run/5`'s signature is **unchanged**
(`claim_or_fetch_assertion_run(tenant_id, review_id, plan_digest,
idempotency_key, prefix)`) — `tenant_id` is still a real parameter, only its
*use inside the function body* changes: the `attrs` map passed to
`PromotionAssertionRun.insert_changeset/2` drops the `tenant_id: tenant_id`
key (see §4), and the `on_conflict: :nothing, conflict_target:
[:tenant_id, :idempotency_key]` becomes `conflict_target: [:idempotency_key]`
(matching §2.3's index simplification).

`fetch_existing_assertion_run/3`'s `Repo.get_by(PromotionAssertionRun,
[tenant_id: tenant_id, idempotency_key: idempotency_key], prefix: prefix)`
call (line ~1492) drops the `tenant_id:` key from the keyword list —
becomes `Repo.get_by(PromotionAssertionRun, [idempotency_key:
idempotency_key], prefix: prefix)`. The function's own `tenant_id` parameter
becomes unused after this edit inside `fetch_existing_assertion_run/3`
itself — ELIXIR-DEV must either drop the parameter (and update
`claim_or_fetch_assertion_run/5`'s one call site accordingly) or prefix it
`_tenant_id`; **design decision: drop the parameter**, `fetch_existing_assertion_run(idempotency_key,
prefix)`, for consistency with `insert_definition/3`'s parameter drop above —
don't leave a dead parameter that invites a future reader to wonder if it's
still load-bearing.

### 3.2 `lib/letflow/event_store.ex` (4 sites)

| Line (current) | Function | What `tenant_id` is used for today | Decision |
|---|---|---|---|
| 179 | `append/2` | `{:ok, tenant_id} <-`, then (a) passed to `Registry.validate_payload(event_type, payload, tenant_id)`, (b) placed into `ctx.tenant_id`, consumed by `insert_event/3` to stamp `Event.insert_changeset/2` | **Call site KEPT, binding unchanged.** `Registry.validate_payload/3`'s `tenant_id` argument is a genuine functional input (resolves `event_type_registry` rows, a table this requirement does not touch — see §0/§1, `event_type_registry` is not one of the ten D2 tables) — this use is completely independent of the `events.tenant_id` column. Only `ctx.tenant_id`'s *second* use (stamping `insert_event/3`'s attrs) goes away — see §4. `ctx` (the map built at the end of `append/2`, ~line 200) keeps its `tenant_id` key (still needed for the `Registry.validate_payload` call, which happens *before* `ctx` is built, and `ctx.tenant_id` — even though no longer forwarded into `Event.insert_changeset/2`'s attrs — costs nothing to leave in `ctx` unless ELIXIR-DEV prefers to trim it; **design decision: leave `ctx.tenant_id` as dead data in the map rather than restructuring `build_multi/1`'s `Multi.run` closures to selectively omit it**, since `insert_event/3`'s own `attrs` map (§4) is where the actual omission happens, and pruning `ctx` itself is cosmetic, not functional). |
| 699 | `read/2` | `{:ok, _tenant_id} <-`, discarded | **Kept as validation.** Rename to `{:ok, _}`. |
| 762 | `read_global/2` | `{:ok, _tenant_id} <-`, discarded | **Kept as validation**, same as 699. |
| 818 | `archive/2` | `{:ok, _tenant_id} <-`, discarded | **Kept as validation**, same as 699. Downstream, `archive_phase1_insert/2`'s `archived_event_entry/2` helper builds an `entries` map for `Repo.insert_all(ArchivedEvent, entries, ...)` that includes `tenant_id: event.tenant_id` (copying the source `events` row's value) — this key is **removed** from that map (§4), since `event.tenant_id` will not exist on the source `%Event{}` struct once `events.tenant_id` is dropped. |

### 3.3 `lib/letflow/definitions/promotion_review_store.ex` (1 site)

| Line (current) | Function | What `tenant_id` is used for today | Decision |
|---|---|---|---|
| 216 | `insert_review/2` | `{:ok, tenant_id} <-`, then placed into `attrs.tenant_id`, stamped into `PromotionReview.insert_changeset/2` | **Call site REMOVED** in the sense that its only use (stamping) goes away — **kept as validation**, `{:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix)`, for the same early-error-shape reason as `definitions.ex`'s `create/2` (line 405) — `insert_review/2` otherwise has no prefix-validity guard before `Repo.insert/2`. The `attrs` map's `tenant_id: tenant_id` key is dropped (§4). |

### 3.4 Summary — removed vs. kept-as-validation

- **Genuinely removed (was pure stamping, no other use):**
  `definitions.ex` line 405 changes from a *stamping* binding to a
  *validation-only* binding (not deleted outright — see decision above);
  `promotion_review_store.ex` line 216 likewise. Neither call site is
  deleted; both are downgraded from "resolve + stamp" to "resolve +
  validate-only."
- **Kept as validation (already discard-only, no functional change beyond a
  `_tenant_id` → `_` rename for clarity):** `definitions.ex` 427, 446, 469,
  571, 1131; `event_store.ex` 699, 762, 818.
- **Kept unchanged (genuine non-stamping functional consumer):**
  `definitions.ex` 506 (`activate/2`, service-scope validator),
  `definitions.ex` 687 (`rollback_definition_version/4`, permission checker),
  `event_store.ex` 179 (`append/2`, `Registry.validate_payload/3`).
- **Kept, downstream stamping use removed but the binding itself still
  threads a real value to another purpose:** `definitions.ex` 811
  (`apply_promotion_assertion_rerun/6`) — flagged in §7 as needing a fuller
  trace before ELIXIR-DEV deletes anything beyond the two confirmed edits
  (`claim_or_fetch_assertion_run/5`'s attrs map, `fetch_existing_assertion_run/3`'s
  `Repo.get_by` keyword list).

No site is deleted at the `with ... <- TenantProvisioning.tenant_id_for_schema_name(prefix)`
clause level — every site keeps calling the function (confirming §1's point
that the function itself is not deleted); only what happens to the *result*
changes per-site.

## 4. Schema-module field/cast/validate_required removal (ten modules, corrected list)

For every module below: remove the `field(:tenant_id, Ecto.UUID)` line from
the `schema/2` block, remove `:tenant_id` from every `cast/3` field list that
names it, and remove `:tenant_id` from every `validate_required/2` list that
names it. No other field, cast, or validation on any of these modules
changes.

1. **`Letflow.Engine.TokenRecord`** (`lib/letflow/engine/token_record.ex`) —
   remove `field(:tenant_id, Ecto.UUID)`; remove `:tenant_id` from
   `insert_changeset/2`'s `cast/3` list (`[:tenant_id, :instance_id, ...]` →
   `[:instance_id, ...]`) and from its `validate_required/2` list
   (`[:tenant_id, :instance_id, :node_id, :branch_id]` → `[:instance_id,
   :node_id, :branch_id]`). `advance_changeset/2` is untouched — it never
   cast `:tenant_id` in the first place (its moduledoc already states
   `tenant_id` is structurally not castable there).
2. **`Letflow.Engine.Task`** (`lib/letflow/engine/task.ex`) — remove
   `field(:tenant_id, Ecto.UUID)`; remove `:tenant_id` from
   `insert_changeset/2`'s `cast/3` list and `validate_required/2` list
   (`[:tenant_id, :instance_id, :token_id, :node_id, :node_name]` →
   `[:instance_id, :token_id, :node_id, :node_name]`). `complete_changeset/2`
   untouched (never cast `:tenant_id`).
3. **`Letflow.EventStore.Event`** (`lib/letflow/event_store/event.ex`) —
   remove `field(:tenant_id, Ecto.UUID)`; remove `:tenant_id` from
   `@cast_fields` and `@required_fields` module attributes (both currently
   list it last).
4. **`Letflow.EventStore.ArchivedEvent`** (`lib/letflow/event_store/archived_event.ex`) —
   remove `field(:tenant_id, Ecto.UUID)`; remove `:tenant_id` from
   `@cast_fields` and `@required_fields`.
5. **`Letflow.EventStore.InstanceProjection`** (`lib/letflow/event_store/instance_projection.ex`) —
   remove `field(:tenant_id, Ecto.UUID)`; remove `:tenant_id` from
   `insert_changeset/2`'s `cast/3` list (`[:instance_id, :tenant_id,
   :status, ...]` → `[:instance_id, :status, ...]`) and
   `validate_required/2` list (`[:instance_id, :tenant_id, :status,
   :definition_id]` → `[:instance_id, :status, :definition_id]`).
   `update_changeset/2` untouched (never cast `:tenant_id`; its own moduledoc
   note "`instance_id`, `tenant_id`, `definition_id` and `correlation_key`
   are structurally not castable here" needs the `tenant_id` mention removed
   too — folded into this module's moduledoc edit below).
6. **`Letflow.Definitions.ProcessDefinition`** (`lib/letflow/definitions/process_definition.ex`) —
   remove `field(:tenant_id, Ecto.UUID)`; remove `:tenant_id` from
   `create_changeset/2`'s `cast/3` list (`[:tenant_id, :name, :version,
   :description, :stage, :graph, :created_by]` → `[:name, :version,
   :description, :stage, :graph, :created_by]`) and `validate_required/2`
   list (`[:tenant_id, :name, :version, :graph, :created_by]` → `[:name,
   :version, :graph, :created_by]`). `update_changeset/2` untouched (never
   cast `:tenant_id`).
7. **`Letflow.Definitions.PromotionReview`** (`lib/letflow/definitions/promotion_review.ex`) —
   remove `field(:tenant_id, Ecto.UUID)`; remove `:tenant_id` from
   `insert_changeset/2`'s `cast/3` list (`[:tenant_id, :plan_digest,
   :def_type, :def_id, :serialised_plan, :requested_by]` → `[:plan_digest,
   :def_type, :def_id, :serialised_plan, :requested_by]`) and
   `validate_required/2` list (`[:tenant_id, :plan_digest, :def_id,
   :serialised_plan, :requested_by]` → `[:plan_digest, :def_id,
   :serialised_plan, :requested_by]`). **Also**: the
   `unique_constraint([:tenant_id, :plan_digest], name:
   :uq_promotion_review_active_digest)` call becomes
   `unique_constraint(:plan_digest, name: :uq_promotion_review_active_digest)`
   — required by §2.3's index-name-matching point, this is a schema-module
   edit, not just a migration edit.
8. **`Letflow.Definitions.PromotionAssertionRun`** (`lib/letflow/definitions/promotion_assertion_run.ex`) —
   remove `field(:tenant_id, Ecto.UUID)`; remove `:tenant_id` from
   `insert_changeset/2`'s `cast/3` list (`[:tenant_id, :review_id,
   :idempotency_key, :plan_digest]` → `[:review_id, :idempotency_key,
   :plan_digest]`) and `validate_required/2` list (`[:tenant_id, :review_id,
   :idempotency_key, :plan_digest]` → `[:review_id, :idempotency_key,
   :plan_digest]`). **Also**: `unique_constraint([:tenant_id,
   :idempotency_key], name: :uq_promotion_assertion_runs_idempotency)`
   becomes `unique_constraint(:idempotency_key, name:
   :uq_promotion_assertion_runs_idempotency)`. `update_changeset/2`
   untouched (never cast `:tenant_id`).
9. **`Letflow.Identity.User`** (`lib/letflow/identity/user.ex`) — remove
   `field(:tenant_id, Ecto.UUID)`; remove `:tenant_id` from
   `jit_changeset/2`'s `cast/3` list (`[:tenant_id, :external_realm,
   :external_id, :username, :display_name, :email, :status]` →
   `[:external_realm, :external_id, :username, :display_name, :email,
   :status]`) and `validate_required/2` list (same trim,
   `[:tenant_id, :external_realm, ...]` → `[:external_realm, ...]`).
10. **`Letflow.Identity.Group`** (`lib/letflow/identity/group.ex`) — remove
    `field(:tenant_id, Ecto.UUID)`. No changeset function exists on this
    module today (its own moduledoc states "No changeset function is defined
    here") — nothing to edit at the cast/validate_required layer.

## 5. Moduledoc text updates (every module whose moduledoc currently describes `tenant_id` as a real field)

Verified by direct read this session — exact current wording quoted, exact
replacement text specified.

### 5.1 `Letflow.Engine.TokenRecord` — "tenant_id is never caller-supplied" section

Current text (full section, to be **removed entirely** — the whole `##
\`tenant_id\` is never caller-supplied (design §6)` heading and its body):

> ## `tenant_id` is never caller-supplied (design §6)
>
> Neither changeset below is reachable from any built context-module function
> yet, but the contract every future caller must follow is fixed here: the
> value cast into `tenant_id` must always be
> `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`'s result, derived
> from the `:prefix` the write targets — never a value taken from external
> caller input. See `Letflow.EventStore.append/2` and
> `Letflow.Definitions.create/2` for the established shape of that contract.

Replace with a short note (new heading, same position in the moduledoc) so a
future reader who searches for "tenant_id" in this file finds the reason it's
gone rather than nothing at all:

> ## No `tenant_id` column (Decision 0006 D2)
>
> This table lived inside a per-tenant Postgres schema from the start
> (Decision 0003 Dimension B) — the schema boundary alone already made any
> `tenant_id` column here fully redundant. Decision 0006 D2
> (`docs/migration/decisions/0006-identity-tables-schema-per-tenant.md`)
> removes it. Do not re-add a `tenant_id` field to this schema without first
> re-reading that record.

### 5.2 `Letflow.Engine.Task` — identical section, same edit

Current text is byte-for-byte the same section (`## \`tenant_id\` is never
caller-supplied (design §6)`, same body, same closing sentence) — apply the
identical removal and the identical replacement note as §5.1.

### 5.3 `Letflow.Identity.User` — "intra-schema column per Decision B" sentence

Current text (in the moduledoc's second paragraph):

> `tenant_id` is an intra-schema column per Decision B
> (`docs/migration/decisions/0003-ecto-schema-strategy.md`) — it carries no
> database-level foreign key to `tenants.id` (see the `CreateUsers`
> migration's header comment for the full rationale).

Replace with:

> `tenant_id` was an intra-schema column per Decision B
> (`docs/migration/decisions/0003-ecto-schema-strategy.md`) until Decision
> 0006 D2 (`docs/migration/decisions/0006-identity-tables-schema-per-tenant.md`)
> dropped it — the per-tenant Postgres schema (Decision 0006 D1) already
> fully identifies which tenant this table's rows belong to, making the
> column redundant. See 0006 §R1-R3 for the full reasoning and the `users`
> per-tenant migration's own header for this table's specific history.

### 5.4 `Letflow.Identity.Group` — brief `tenant_id` mention

Current text (moduledoc, second paragraph):

> `tenant_id` carries no database-level foreign key to `tenants.id`, same
> rationale as `Letflow.Identity.User.tenant_id` (see the `CreateGroups`
> migration's header comment).

Replace with:

> `tenant_id` was carried on this table, with no database-level foreign key
> to `tenants.id`, until Decision 0006 D2 dropped it for the same reason it
> was dropped from `users` — the per-tenant Postgres schema already
> identifies the owning tenant. See
> `docs/migration/decisions/0006-identity-tables-schema-per-tenant.md`.

### 5.5 `Letflow.EventStore.Event`, `Letflow.EventStore.ArchivedEvent`, `Letflow.EventStore.InstanceProjection` — the shared `## \`tenant_id\` (design §2.5)` section

All three modules carry a nearly-identical section (verified: each says "This
table is one of three ... that carry `tenant_id` ... See the design doc §2.5
for the full asymmetry rationale before 'completing' it on another table.").
**Remove this section from all three**, replaced (in each module, same
position) with:

> ## No `tenant_id` column (Decision 0006 D2)
>
> This table carried `tenant_id` until Decision 0006 D2
> (`docs/migration/decisions/0006-identity-tables-schema-per-tenant.md`)
> dropped it from every event-store table — the per-tenant Postgres schema
> already identifies the owning tenant, and 0006 §R3 documents that this
> table's own original migration header already conceded the column carried
> at most one distinct value per schema. See `lib/letflow/design/req023-event-store-schema.md`
> §2.5 for the superseded asymmetry rationale (retained there for history,
> not as current guidance).

### 5.6 `Letflow.Definitions.ProcessDefinition` — no dedicated `tenant_id` section found

Direct read of this module's full moduledoc (this session) found no
dedicated `tenant_id` heading or paragraph comparable to §5.1-§5.5 — the
field is declared in the schema block and cast/required lists (§4 point 6)
but not separately narrated in prose. **No moduledoc text edit required for
this module beyond the schema/changeset edits already specified in §4.**

### 5.7 `Letflow.Definitions.PromotionReview`, `Letflow.Definitions.PromotionAssertionRun` — no dedicated `tenant_id` section found

Same finding as §5.6 — direct read found no dedicated prose section
describing `tenant_id` on either module; the field is declared plainly in
the schema block with no narrated rationale. No moduledoc text edit required
beyond §4's schema/changeset/constraint edits. (`PromotionReview`'s
moduledoc's "Two changesets, not one" and "No `belongs_to`" sections, and
`PromotionAssertionRun`'s equivalents, do not mention `tenant_id` and are
untouched.)

## 6. What this requirement supersedes/leaves standing in Decision 0003 (restated for consistency, per the handoff's own instruction)

Matches Decision 0006 §6 exactly — this design does not add to or narrow
that scoping:

- **Superseded**: Dimension B's clause retaining `tenant_id` "as an
  intra-schema invariant/query-predicate discipline," and the Addendum's
  write-time-derivation mechanism (`TenantProvisioning.tenant_id_for_schema_name/1`
  used *for stamping*) — moot for the ten D2 tables now that there is no
  column to populate. The function itself is not superseded; only its
  stamping *use* on these ten tables is.
- **Standing, not reopened**: Dimension B's schema-per-tenant isolation
  choice itself (unchanged, this design's own premise); Dimension A and C
  (untouched, no table this requirement touches has any Dimension-C-specific
  concern beyond what already shipped); the Addendum's rejection of
  caller-supplied `tenant_id` (D2 makes it unreachable rather than
  reversing the rejection); the deferred session-GUC tenant context (0006
  disfavours it further, this design does not build it — no code in this
  design introduces a GUC or connection-level tenant context of any kind).

No moduledoc or migration-header text written under §5/§2 may describe
Dimension B's *isolation* choice as reversed — every replacement text above
was checked against this constraint (each says "the schema boundary already
identifies the tenant," never "tenant isolation no longer uses schemas").

## 7. Open questions (not silently resolved)

1. **`definitions.ex` line 811's `apply_promotion_assertion_rerun/6`
   `tenant_id` binding** — confirmed two consumers this session
   (`claim_or_fetch_assertion_run/5`'s stamping, now removed;
   `fetch_existing_assertion_run/3`'s `Repo.get_by` filter, now trimmed) but
   the full call graph beyond those two (`claim_sandbox_and_proceed/6` and
   whatever it calls) was not exhaustively traced. ELIXIR-DEV must grep for
   every use of the `tenant_id` variable within `apply_promotion_assertion_rerun/6`'s
   own body and everything it calls before deciding whether the `{:ok,
   tenant_id} <-` binding at line 811 can be safely narrowed to `{:ok, _}`,
   or must remain a real binding because some other downstream use exists
   that this design session did not find.
2. **`users`'s third index, `index(:users, [:tenant_id, :status,
   :inserted_at])`** (§2.2 point 9) — this design defaults to dropping it
   outright with no replacement, on the grounds that no query shape
   consuming `[:status, :inserted_at]` alone was found in
   `lib/letflow/identity.ex`. This was not an exhaustive search of every
   `users` query in the codebase (only `identity.ex` and the schema module
   itself were read this session) — if REVIEWER or ELIXIR-DEV finds a real
   consumer of that shape, the correct fix is `index(:users, [:status,
   :inserted_at])` (drop only the leading `tenant_id`), not leaving the
   original three-column index in place.
3. **Migration file grouping** — §2.1 leaves ELIXIR-DEV free to combine
   several `DROP COLUMN`s into fewer files (e.g. one file per subsystem:
   event-store, engine, definitions, identity) versus ten separate files
   matching this codebase's usual one-migration-per-concern granularity.
   Both are consistent with `tenant_scoped_migrations/0`'s manifest
   mechanism; this design does not mandate one over the other.
4. **`ctx.tenant_id` in `event_store.ex`'s `append/2`** (§3.2, line 179) —
   this design chose to leave it as unused-but-present in the `ctx` map
   rather than trim `build_multi/1`'s closures to omit it. If REVIEWER
   prefers the stricter "no dead map key" reading, the alternative is
   restructuring `ctx` to exclude `tenant_id` after the
   `Registry.validate_payload/3` call consumes it and before `build_multi/1`
   runs — this design does not mandate that restructuring, flagging it as a
   legitimate alternative ELIXIR-DEV or REVIEWER may prefer.

## 8. Cross-module dependency summary

- `priv/repo/migrations/*` (ten new files, §2) depend on nothing this
  requirement adds elsewhere — pure DDL, ordered only by their own
  timestamp and the codebase's existing FK-ordering constraints already
  documented in the shipped migrations they alter (`tasks` sorts after
  `tokens`, `promotion_assertion_runs` sorts after `promotion_reviews` —
  unchanged by this requirement, since neither FK is touched).
- `Letflow.TenantProvisioning.tenant_scoped_migrations/0`'s manifest
  (`lib/letflow/tenant_provisioning.ex`) gains ten new `{version, module,
  filename}` entries, one per §2.2 migration.
- The ten schema modules (§4) depend on nothing new; their existing
  `Repo`/context-module callers (§3) are the only things that must change in
  lockstep, and §3 enumerates every one.
- No route/controller/API-contract file is touched — this requirement is
  entirely internal to `lib/letflow/` write/read paths already exercised by
  existing tests; no new external-facing behavior is introduced or removed
  (the `{:error, :tenant_not_provisioned}`/`{:error, :invalid_schema_name}`-shaped
  errors from the kept-as-validation call sites are unchanged in shape,
  since `tenant_id_for_schema_name/1`'s own error contract is untouched by
  this requirement).

## 9. Acceptance-criteria mapping

| Acceptance criterion | Design section |
|---|---|
| Tokens-table module ownership verified/corrected | §0 |
| Migrations for all ten tables, each with prefix() guard | §2.1, §2.2 |
| Both composite-index simplifications, exact before/after, idempotency contract restated | §2.3 |
| Per-site decision for each `tenant_id_for_schema_name/1` call site | §3 (14 sites, corrected count) |
| Field/cast/validate_required removal, corrected module list | §4 |
| Moduledoc text updates, every module describing tenant_id as real | §5 |
| `tenant_id_for_schema_name/1` itself not removed | §1 |
| Four D3 tables explicitly named as untouched | §1 |
