# Design: REQ-203 — Per-tenant artifact activation, atomic multi-artifact groups, and activation history (REPO-08/09/10)

**Requirement:** REQ-203 (`docs/requirements.yaml:11304-11392`, stage S6,
`depends_on: [REQ-202, REQ-072, REQ-067]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ203-20260831`, WF-02 Step 1
**This document produces:** three Ecto schema shapes, one migration's full
table/index/constraint spec, the `Ecto.Multi` shape for atomic multi-artifact
activation, the concurrency/observability argument for REPO-08's acceptance
criterion, the resolution function's contract, and the REQ-195 disambiguation
statement. **No implementation code** — no function bodies, no `.ex`/`.exs` file
contents, no literal SQL. ELIXIR-DEV writes those from this document at Step 2a.

**Convention basis:** direct structural sibling of
`lib/letflow/design/req202-artifact-repository.md` (REQ-202, now on `main`) — this
design reuses its placement-decision method, its moduledoc-cross-reference
discipline, and its `Repository`/`Repository.Artifact`/`Repository.ArtifactVersion`
naming precedent, extended into a fourth module (`Repository.Activation` et al.) in
the same `lib/letflow/repository/` namespace REQ-202 opened. Also draws on
`lib/letflow/design/req195-audit-entry-storage.md` (DB-level immutability trigger
precedent, `Ecto.Multi`-as-transaction-boundary precedent) and `lib/letflow/audit.ex`
(the shipped module this design's §7 disambiguates against).

---

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-203's full entry, read in full: description and all
  11 acceptance criteria (`depends_on: [REQ-202, REQ-072, REQ-067]`).
- `lib/letflow/design/req202-artifact-repository.md` in full — the direct precedent
  this design extends: §1 (placement-decision method and reasoning), §2 (migration
  shape/index conventions), §5 (DB-level immutability trigger mechanism), §6
  (REQ-067 cursor-contract reuse), §8 (scope-discipline table), §9 (open-question
  discipline).
- `lib/letflow/repository.ex`, `lib/letflow/repository/artifact.ex`,
  `lib/letflow/repository/artifact_version.ex` — REQ-202's **shipped**
  implementation on `main`, read directly rather than through the design doc's
  paraphrase, specifically to confirm:
  - `ArtifactVersion`'s real column list/types: `version_id` (`:binary_id` PK,
    autogenerate), `tenant_id` (`:binary_id`), `artifact_id` (`:binary_id`,
    server-generated per OQ-4's shipped resolution), `artifact_kind` (`Ecto.Enum`,
    `[:definition, :form, :schema, :service_catalog, :script, :module, :scenario]`),
    `artifact_name` (`:string`), `version_number` (`:integer` in the Ecto schema —
    note: the requirement's schema text calls this `bigint`; Ecto's `:integer` maps
    to Postgres `integer` unless the migration declares `:bigint` explicitly, so
    §2.1 below states the FK column type must match whatever
    `artifact_versions.version_number`'s **migration-level** Postgres type actually
    is, not assume `bigint` from the requirement text alone — flagged as **OQ-A**
    below since this design does not have the migration file's column-type
    declaration in hand, only the schema module's Ecto type), `content_hash`
    (`:binary`, FK to `repository_artifacts`), `parent_version_id` (`:binary_id`,
    nullable self-FK), `created_by` (`:binary_id`), `description` (`:string`,
    nullable), `inserted_at` only (`timestamps(updated_at: false)`).
  - `Letflow.Repository`'s exact `create/2`/`create_with_retries/7` transaction
    shape: a **plain `Repo.transaction/1` closure**, not `Ecto.Multi` — REQ-202
    shipped with a bare transaction function, retried up to 5 times on a unique-
    constraint conflict (`unique_version_conflict?/1`), using `lock("FOR UPDATE")`
    on the latest-version-row read (`next_version/3`) as the concurrency
    discipline for sequencing, not `Ecto.Multi.run/3` steps. This is the "REQ-202's
    create/2 transaction pattern" this requirement's own framing (via ORCH's task
    brief) points at — **the actual shipped pattern is a bare `Repo.transaction/1`
    fun**, not an `Ecto.Multi` pipeline. §4 below explains why this design still
    recommends `Ecto.Multi` for REQ-203 specifically (N steps, one per artifact in
    the group, plus one history row and one group-envelope row, is exactly
    `Ecto.Multi`'s composition shape — REQ-202's `create/2` never needed to
    compose more than one write of each kind, so a bare transaction closure was
    the simpler tool there; REQ-203's multi-artifact group is the first place in
    this pair genuinely needing `Ecto.Multi`'s named-step/partial-result
    composition, matching `Letflow.Audit.append_multi/4`'s and R-Co's own audit
    `Multi`-step precedent cited in `req195`).
  - Tenant-scoping convention: every public function takes an explicit
    `prefix :: String.t()` and derives `tenant_id` via
    `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` — never a
    caller-supplied `tenant_id`. This design's functions follow the identical
    convention (§3, §4).
  - REQ-202's cursor idiom for list endpoints (`@list_versions_cursor_prefix
    "RV:"`, `Pagination.build_raw_cursor_timestamp_key/4`,
    `Pagination.decode_cursor/3`, the `page_size + 1`-fetch/split idiom) — reused
    verbatim in shape for activation-history listing (§6), with a distinct cursor
    prefix per REQ-067's own AC3 (a cursor minted by one endpoint rejected by
    another on prefix mismatch).
- `lib/letflow/design/req195-audit-entry-storage.md` in full (already read this
  session for REQ-202's own precedent) — reused here specifically for: §2's
  DB-level immutability trigger mechanism (per-tenant-schema-qualified function,
  `BEFORE UPDATE`/`BEFORE DELETE`, unconditional raise, fixed message text); §3.1's
  Elixir-context-function-boundary-capture-vs-Postgres-trigger decision, cited in
  §7 below to state precisely how activation history's capture mechanism relates
  to (but is not identical in purpose to) `audit_entries`'; §4's `Ecto.Multi`-as-
  same-transaction-guarantee precedent, reused directly for REPO-08's atomicity
  (§4 below).
- `lib/letflow/audit.ex` — the **shipped** module, read in full (not the design
  doc's paraphrase), for §7's disambiguation: confirmed `Letflow.Audit.Entry`'s
  actual field set (`id`, `tenant_id`, `actor_id`, `action`, `resource_type`,
  `resource_id`, `timestamp`, `before_state`, `after_state`, `trace_id`,
  `chain_hash`, `prev_chain_hash`), confirmed `append_multi/4`'s signature
  (`Ecto.Multi.t(), atom(), entry_attrs(), String.t() -> Ecto.Multi.t()`) as the
  exact shape this design's §4/§7 call sites reuse without modification, and
  confirmed the module's own moduledoc already carries a "two separate trails
  exist deliberately" precedent (the `lua_script_execution_audit` disambiguation)
  this design's §7 mirrors in structure for `artifact_activation_history` vs.
  `audit_entries`.
- `lib/letflow/api/pagination.ex` — read for the exact reusable cursor contract
  (`Cursor.t()`'s single opaque `inner` field — INV-1/INV-5 — no tenant-scoping
  slot anywhere in a decoded cursor; `Page.t()`; `decode_cursor/4`'s wrong-endpoint/
  expired/invalid-cursor error atoms; `encode_cursor/1`;
  `build_raw_cursor_timestamp_key/4`). §6 below reuses this contract verbatim,
  the same way REQ-202's `list_versions/4` does.
- `docs/migration/decisions/0003-ecto-schema-strategy.md` in full — Decision A
  (Ecto-idiomatic redesign), Decision B (schema-per-tenant via `:prefix`,
  intra-schema `tenant_id` retained as a query-predicate discipline, chosen for its
  blast-radius-containment property), Decision C (event-table immutability is an
  *application*-layer concern for event tables specifically — considered and set
  aside for `artifact_activation_history` in §5 below, the same way REQ-202's
  design set it aside for `repository_artifacts`/`artifact_versions`, for the same
  reason: this table's own semantics, not Decision C's event-table carve-out,
  govern its immutability treatment).
- `lib/letflow/design/req-055-concurrent-instance-isolation.md` (§0 sources list) —
  read for its precedent on testing real cross-process concurrency in this
  codebase: `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` (not the
  `Letflow.DataCase` default `{:shared, self()}` mode) is the established
  mechanism this codebase already uses whenever a test needs two genuinely
  separate database connections/transactions interleaving, which is exactly
  what REPO-08's observability acceptance criterion requires (§4.3 below) — this
  is not a new testing pattern REQ-203 introduces, it is the one existing
  precedent for it.
- `lib/letflow/repo.ex` — confirmed `Letflow.Repo` is a plain
  `Ecto.Adapters.Postgres`-backed repo with no isolation-level override
  configured anywhere in `init/2` or `config/*.exs` (grepped this session for
  `isolation`/`serializable`/`read_committed`/`SET TRANSACTION` across
  `lib/letflow/*.ex` and `config/*.exs` — no hit anywhere in this codebase). This
  confirms the isolation-level assumption §4.3 below states explicitly: every
  transaction in this codebase, including this requirement's, runs at Postgres's
  server-default isolation level, **READ COMMITTED**, unless a future call site
  explicitly opts into a stronger level via `Repo.transaction(fun, mode: ...)`\*
  (Ecto's own mechanism for this) or a raw `SET TRANSACTION ISOLATION LEVEL`
  inside the transaction body — this design does not need either, per §4.3's
  argument.

---

## 1. Placement decision — per-tenant, following REQ-202's precedent, no divergence

**Decision: all three tables (`artifact_activations`, `artifact_activation_history`,
`artifact_activation_groups`) are per-tenant-schema tables (`prefix: prefix()`,
Decision B), matching REQ-202's decided placement for `repository_artifacts`/
`artifact_versions`. No REVIEWER sign-off flag is raised.**

### 1.1 Why this is the easy half of the placement question

Unlike REQ-202's content store (where a real tension existed — content-hash dedup
only spans tenants if the store is global), **no comparable tension exists here at
all**. There is no dedup mechanism on any of these three tables — an activation
pointer, a history row, and a group envelope are all inherently per-tenant *facts*
("tenant A's active version for artifact X"), not shared content. R-Co's own schema
for this subsystem already carries `tenant_id` as a column on its activation table
(the requirement's own text notes this explicitly: "R-Co's own activation table
carries `tenant_id` as a column while the artifact tables do not" — REQ-202's design
§1.1), so even R-Co's actual implementation, which made the *content* store
effectively global, scoped *activation* to the tenant. There is no R-Co-grounded (or
any other) reason to consider global placement for these three tables at all.

### 1.2 Consistency argument, stated per the requirement's own instruction

The requirement's text states: "Placement follows REQ-202's decided placement for
consistency; if REQ-202 went global for the content store, these three still carry
`tenant_id` as the scoping column and this requirement must state whether they are
per-tenant-schema or global, with the reason." REQ-202 in fact went **per-tenant**
(not global — confirmed directly from the shipped `Letflow.Repository.Artifact`
moduledoc, §0 above), so the conditional clause about a global content store does
not apply; this design simply follows REQ-202's actual placement, per-tenant, for
all three of this requirement's tables. This is symmetry with REQ-202, `req195`
(`audit_entries`), and every other S6 per-tenant table — not a new decision this
design is making independently.

### 1.3 REVIEWER sign-off

**Not needed.** The sign-off requirement (both in REQ-202's text and this
requirement's own "if global... flag it" framing) is conditioned on choosing
*global* placement in divergence from Decision B's default. This design chooses
per-tenant, the *default*, for all three tables — there is no divergence to flag.

### 1.4 All three tables carry `tenant_id`

Per Decision B and REQ-202's own established pattern (§1.4 of that design), all
three tables retain an intra-schema `tenant_id` column even though the Postgres
schema (`:prefix`) is the actual isolation boundary. `tenant_id` is derived at
write time from the resolved `:prefix` via
`Letflow.TenantProvisioning.tenant_id_for_schema_name/1`, never accepted as a
separately-trusted caller-supplied field — identical discipline to
`Letflow.Repository`'s `create/2` and `Letflow.Audit`'s `insert_entry/3`.

---

## 2. Migration — three tables, one migration file (or three adjacent ones — ELIXIR-DEV's choice)

Per-tenant schema (`prefix: prefix()`), guarded the same way every other per-tenant
migration in this codebase is (`if prefix() do ... end`, following `req195`/
`req202`'s pattern), and — per `req195`'s own note (§1 of that design) — this is a
**new manifest entry**: ELIXIR-DEV must add `{version, __MODULE__, filename}` to
`@tenant_scoped_migration_manifest` in `lib/letflow/tenant_provisioning.ex`, or these
three tables never exist in any tenant schema provisioned after this migration
lands (existing tenants additionally need the standard one-off replay, out of this
design's scope, same as every prior tenant-scoped-table addition).

### 2.1 `artifact_activations` — the current pointer

| Column | Type | Constraints |
|---|---|---|
| `activation_id` | `:binary_id` | Primary key, `autogenerate: true`. |
| `tenant_id` | `:binary_id` | `null: false` — Decision B discipline (§1.4). |
| `artifact_kind` | `Ecto.Enum`, same value set as `Letflow.Repository.ArtifactVersion.artifact_kind()` (`[:definition, :form, :schema, :service_catalog, :script, :module, :scenario]`) | `null: false` — reuses REQ-202's exact enum, not a redeclared parallel one; ELIXIR-DEV should share the type via a common `@type`/`Ecto.Enum` values list rather than hand-copying the seven-atom list into a second place that can drift (see OQ-B below — this design flags the sharing mechanism as open, not the value set itself, which must be identical). |
| `artifact_name` | `:string, size: 255` | `null: false` — matches `artifact_versions.artifact_name`'s declared size. |
| `active_version_id` | `:binary_id` | `null: false` — **FK to `artifact_versions.version_id`, `on_delete: :restrict`** (REPO-09's DB-enforced half of "an active version cannot be deleted," AC9). |
| `activated_at` | `utc_datetime_usec` | `null: false` — when this pointer was last set. |
| `activator_user_id` | `:binary_id` | `null: false` — the acting user; unlike REQ-195's `actor_id`, REQ-203's own schema spec lists this as a plain required field with no nullable/system-actor case described, so this design does not introduce a nullable variant absent from the requirement's own text (see OQ-C — whether a system/scheduler-driven activation with no human actor is ever a real call path is left open, matching `req195`'s own OQ-4/OQ-5 treatment of the analogous question for its own tables, since REQ-203's text states no such call path exists today either). |
| `inserted_at`/`updated_at` | `utc_datetime_usec` | via `timestamps/1` — **`updated_at` is real here** (not `updated_at: false` as REQ-202's tables use), because `artifact_activations` is the one table in this trio that *is* legitimately updated in place: activating a new version for an already-activated `(tenant, kind, name)` triple **updates** the existing row's `active_version_id`/`activated_at`/`activator_user_id` rather than inserting a new row — see §4.2 step 3. This is a structural difference from REQ-202's `repository_artifacts`/`artifact_versions` (immutable-by-trigger) and from this table's own sibling `artifact_activation_history` (append-only, §5): `artifact_activations` is the mutable *current-pointer* half of this schema, `artifact_activation_history` is the immutable *trail* half — the requirement's own schema spec structurally distinguishes them this way (one row per active artifact vs. one row per activation event), and no acceptance criterion asks for `artifact_activations` itself to be update-rejected. |

**Unique constraint:** `unique_index(:artifact_activations, [:tenant_id, :artifact_kind, :artifact_name], prefix: prefix())` — **this is REPO-09's real, DB-level enforcement mechanism** (AC4): "exactly one active version per artifact per tenant" is not an application convention checked by a `SELECT` before an `INSERT`, it is a constraint Postgres itself rejects a violation of, regardless of what application code path reaches this table. AC4's test issues a raw insert attempt (a second row for the same `(tenant_id, artifact_kind, artifact_name)`) and asserts the database — not application logic — rejects it.

**Index:** `index(:artifact_activations, [:active_version_id], prefix: prefix())` — supports the `ON DELETE RESTRICT` FK's reverse lookup and any future "which artifacts have this version active" query, defense-in-depth, matching REQ-202's own `content_hash` index reasoning (§2.2 of that design).

### 2.2 `artifact_activation_history` — the append-only trail

| Column | Type | Constraints |
|---|---|---|
| `history_id` | `:binary_id` | Primary key, `autogenerate: true`. |
| `tenant_id` | `:binary_id` | `null: false`. |
| `artifact_kind` | same `Ecto.Enum` as §2.1 | `null: false`. |
| `artifact_name` | `:string, size: 255` | `null: false`. |
| `previous_version_id` | `:binary_id`, nullable | **FK to `artifact_versions.version_id`, `on_delete: :restrict`** — nullable because the first activation of a given `(tenant, kind, name)` triple has no prior version (§4.2 step 2's "null on first activation," matching AC5's own wording). `:restrict`, not `:nilify_all`, because a history row's `previous_version_id` is a factual record of what was active before — nilifying it on a later, unrelated version deletion would silently corrupt the historical record; restricting means a version that appears anywhere in this trail (as either `previous_version_id` or `new_version_id`) can never be deleted, which is the stronger, correct guarantee for an audit-adjacent trail (consistent with `artifact_versions` itself already having no delete path in this codebase's scope, per REQ-202 §8). |
| `new_version_id` | `:binary_id` | `null: false` — **FK to `artifact_versions.version_id`, `on_delete: :restrict`** (same reasoning). |
| `new_version_number` | matches `artifact_versions.version_number`'s actual migration-level Postgres column type exactly (see OQ-A) | `null: false` — denormalized copy of the activated version's own `version_number`, so a history-row reader does not need a join back to `artifact_versions` to know which version number was activated (REPO-10's own schema spec lists this explicitly). |
| `activator_user_id` | `:binary_id` | `null: false`. |
| `activated_at` | `utc_datetime_usec` | `null: false`. |
| `rationale` | `:text` | **`null: false`, AND a changeset-level `validate_required/2` AND a DB-level `CHECK` constraint rejecting the empty string** — see §2.4 below for why both layers are used, not either alone. |
| `inserted_at` | `utc_datetime_usec` | via `timestamps/1`, `updated_at: false` — this table is append-only (§5), so there is never a legitimate update, matching REQ-202's `repository_artifacts`/`artifact_versions` reasoning for the identical column choice. |

**Indexes**, following REQ-202/`req195`'s keyset-pagination tiebreak convention:

1. `index(:artifact_activation_history, [:tenant_id, :artifact_kind, :artifact_name, desc: :activated_at, desc: :history_id], prefix: prefix())` — per-artifact chronological history (AC7's "chronological order," and a natural per-artifact drill-down).
2. `index(:artifact_activation_history, [desc: :activated_at, desc: :history_id], prefix: prefix())` — tenant-wide chronological listing (AC7's own "activation history is returned in chronological order," read as covering the whole-tenant listing shape, not only the per-artifact one — see §6's resolution of which shape `list_history/*` actually returns).

### 2.3 `artifact_activation_groups` — the multi-artifact envelope

| Column | Type | Constraints |
|---|---|---|
| `group_id` | `:binary_id` | Primary key, `autogenerate: true`. |
| `tenant_id` | `:binary_id` | `null: false`. |
| `activated_at` | `utc_datetime_usec` | `null: false`. |
| `activator_user_id` | `:binary_id` | `null: false`. |
| `rationale` | `:text` | `null: false` — same non-empty enforcement as §2.4 (a group-level activation is still "an activation" for REPO-10's purposes; the requirement's schema spec lists `rationale` on the group envelope too, and this design does not read that as a second, independently-validated rationale distinct from the one recorded per-history-row — see §4.2 step 4's resolution of how the group's one rationale text propagates to every history row the group produces, rather than requiring N separately-typed rationales for one atomic operation). |
| `inserted_at` | `utc_datetime_usec` | via `timestamps/1`, `updated_at: false`. |

**No unique constraint** on this table — a tenant may issue any number of activation
groups over time; nothing about "one group" is a per-tenant singleton the way "one
active version per artifact" is.

**FK from `artifact_activation_history` to `artifact_activation_groups`:** an
**optional** `group_id` column, nullable, added to `artifact_activation_history`
(§2.2's table above did not list it to keep that table's core column list aligned
exactly with the requirement's own field enumeration, but it belongs on that table,
not a separate join table) — **FK to `artifact_activation_groups.group_id`,
`on_delete: :restrict`**, populated for every history row produced by a
group activation (§4.2) and left `nil` for a single-artifact activation issued
outside any group (§3, the single-artifact convenience path — see §4.4). This is
what "the envelope that makes a multi-artifact activation one observable unit"
(the requirement's own words) actually means structurally: the group row exists,
and every history row it produced points back at it, so "which history rows
belong to this one atomic activation" is a plain FK lookup, not an
`activated_at`-timestamp-proximity heuristic.

### 2.4 `rationale`'s "rejected rather than stored with an empty string" enforcement — two layers, stated explicitly

AC6 requires: "an activation submitted with no rationale is REJECTED rather than
stored with an empty rationale." This design uses **both** of the two mechanisms
this codebase has for enforcing a non-empty-string invariant, for two different
and non-overlapping reasons — mirroring this project's general preference (stated
in this run's own task brief, and consistent with REQ-202's DB-level-immutability
precedent for a criterion phrased as "rejected... rather than...") for DB-level
enforcement wherever an acceptance criterion uses that exact rejection framing:

1. **Changeset-level:** `validate_required(:rationale)` catches the `nil`/missing
   case *and* — critically — Ecto's `validate_required/2` alone does **not** reject
   an empty string (`""` is a present, non-nil value, and `validate_required/2`'s
   own documented behavior only fails on `nil` or a value considered "empty" by its
   own narrow definition, which for a `:text`/`:string` field is `nil` or an
   all-whitespace string trimmed — this is worth stating explicitly because it is
   the exact gap this design's second layer exists to close: a changeset-only
   implementation that assumes `validate_required/2` alone rejects `""` is
   correct for the whitespace-only case but easy to get wrong for a caller that
   submits a literal empty string with no surrounding text — ELIXIR-DEV should
   verify `validate_required/2`'s exact `""`-handling behavior in the Ecto version
   this codebase pins, per OQ-D below, since this design does not have that
   confirmed from source this session). Regardless of that confirmation, this
   design adds an explicit `validate_length(:rationale, min: 1)` (or equivalent
   "not blank" check) at the changeset level as the **primary, fast-fail, no-DB-
   round-trip** rejection path — the normal path every valid caller hits.
2. **DB-level `CHECK` constraint:** `CHECK (rationale <> '')` (via `execute/1` in
   the migration, the same DSL escape hatch REQ-202/`req195` use for the mutation-
   rejecting trigger) on both `artifact_activation_history.rationale` and
   `artifact_activation_groups.rationale`. This is the layer that makes the
   invariant survive a write path that bypasses the context module's changeset
   entirely (a future raw `Repo.insert_all/3`, or an operator's direct SQL) — the
   same "changeset alone is an application convention, a DB constraint is a real
   invariant" reasoning REQ-202's design applies to immutability (§5 of that
   design) and `req195` applies to `audit_entries`'s triggers. **This design
   judges DB-level enforcement warranted here** specifically because AC6's own
   wording ("REJECTED rather than stored with an empty string") uses the same
   rejection-framing this project's other DB-level-invariant acceptance criteria
   use (REQ-202's AC7 "rejected by the DATABASE, not merely absent from the
   context API"; this requirement's own AC4 for the UNIQUE constraint) — a
   two-layer defense (fast changeset rejection for the normal path, DB `CHECK` as
   the structural backstop) rather than relying on the changeset alone.

---

## 3. The resolution function — not-found semantics

`Letflow.Repository.Activation.resolve(artifact_kind :: artifact_kind(), artifact_name :: String.t(), prefix :: String.t()) :: {:ok, ArtifactVersion.t()} | {:error, :not_activated} | {:error, :invalid_schema_name}`

- Looks up the single `artifact_activations` row for `(tenant_id, artifact_kind,
  artifact_name)` (the UNIQUE index from §2.1 guarantees at most one exists), and
  if found, resolves and returns the full `Letflow.Repository.ArtifactVersion`
  struct its `active_version_id` points at (a join, not merely the raw activation
  row — the requirement's own AC8 asks for "the currently active **version**," and
  the read path's whole purpose per the requirement's scope item 5 is to be "the
  read path everything else would consume," which needs the version's own content
  fields, not just its id).
- **Not-found semantics (AC8):** when no `artifact_activations` row exists for the
  triple — this artifact has never been activated in this tenant — returns
  `{:error, :not_activated}`, an explicit tagged error, **never** an arbitrary
  version (e.g. never silently falling back to "the latest version by
  `version_number`," which AC8's own wording explicitly rules out: "returns a
  not-found result rather than an arbitrary version"). This is a structural
  guarantee, not a convention to remember: the function's only two outcomes for a
  successful lookup are "the one row the UNIQUE index permits" or "no row," with
  no third code path that substitutes a different version.
- Tenant scoping is `prefix`-derived, identical discipline to every other function
  in this pair.

---

## 4. Atomic multi-artifact activation (REPO-08) — the transactional shape

### 4.1 Signature

`Letflow.Repository.Activation.activate_group(activations :: [%{artifact_kind: artifact_kind(), artifact_name: String.t(), version_id: Ecto.UUID.t()}], activator_user_id :: Ecto.UUID.t(), rationale :: String.t(), prefix :: String.t()) :: {:ok, %{group: ActivationGroup.t(), activations: [Activation.t()], history: [ActivationHistory.t()]}} | {:error, :empty_rationale} | {:error, :empty_group} | {:error, {atom(), Ecto.Changeset.t()}}`

`activations` is a non-empty list (`{:error, :empty_group}` for a zero-length
list — a "group" of zero artifacts is not a meaningful atomic unit and this design
does not silently accept it as a no-op). A single-artifact activation (§4.4) is the
`length(activations) == 1` case of this same function, not a structurally separate
code path — REQ-203's scope item 5 ("a resolution function") plus items 2-4 (group
activation, isolation, history) do not separately ask for a distinct
"activate one artifact, no group envelope" entry point, and this design does not
invent one: every activation, single or multi, produces one
`artifact_activation_groups` row (§2.3) and at least one `artifact_activation_history`
row, keeping "every activation is part of exactly one group" a uniform invariant
rather than a special-cased one.

### 4.2 Steps, as an `Ecto.Multi` pipeline (stated as a sequence, not as code)

1. Validate `rationale` is non-blank (§2.4's changeset-level check, applied once
   at the group level before building the `Multi` at all — a cheap, no-DB-round-
   trip fail-fast for the common "forgot to pass a rationale" caller mistake,
   *and* per §2.4 there is still a DB-level `CHECK` backstop on the two tables
   this reaches even if this pre-check were ever bypassed).
2. Insert one `artifact_activation_groups` row (`Multi.insert/3`, step name
   `:group`) — `tenant_id`, `activated_at` (stamped once, shared by every
   activation in the group — see §4.5 for why one timestamp, not N), `activator_user_id`,
   `rationale`.
3. **For each artifact in `activations`, in the order supplied** (order is not
   semantically significant to correctness — the UNIQUE index means each
   `(artifact_kind, artifact_name)` in the input list must be distinct or the
   `Multi` itself would attempt two conflicting upserts in one transaction and
   fail; a caller submitting a duplicate `(kind, name)` pair in one group is a
   caller error, not a case this design silently resolves — see OQ-E), add one
   `Multi.run/3` step (step name derived from the artifact's own
   `(artifact_kind, artifact_name)`, e.g. `{:activation, artifact_kind,
   artifact_name}`, so a failure identifies exactly which artifact in the group
   failed) that:
   a. Locks (or upserts under) the existing `artifact_activations` row for this
      `(tenant_id, artifact_kind, artifact_name)`, if one exists — via
      `Repo.get_by(..., lock: "FOR UPDATE")` or an equivalent locked read,
      **inside this same transaction**, matching `Letflow.Repository.next_version/3`'s
      own established `lock("FOR UPDATE")` idiom (§0 above) for "read the current
      state, then decide whether to insert or update, without racing a concurrent
      writer for the same key." This lock is what makes two *concurrent*
      `activate_group/4` calls that both touch the same `(tenant, kind, name)`
      serialize against each other correctly (one blocks until the other commits
      or rolls back) rather than both reading a stale "no row yet" state and both
      attempting a conflicting insert — the UNIQUE index (§2.1) is the DB-level
      backstop for that race exactly the way `artifact_versions`' unique index is
      REQ-202's backstop for its own version-sequencing race (REQ-202 design §4.4).
   b. Records `previous_version_id` = the locked row's `active_version_id` if a
      row existed, or `nil` if this is the artifact's first-ever activation in
      this tenant (AC5's "null on the first activation").
   c. Either **inserts** a new `artifact_activations` row (first activation) or
      **updates** the existing one's `active_version_id`/`activated_at`/
      `activator_user_id` (subsequent activation) — this is the one legitimate
      update path on this table, per §2.1's note that `artifact_activations` is
      the mutable current-pointer half of this schema.
   d. Appends one `Multi.insert/3` step (or folds into the same `Multi.run/3`)
      for the corresponding `artifact_activation_history` row: `tenant_id`,
      `artifact_kind`, `artifact_name`, `previous_version_id` (from 3b),
      `new_version_id` (= this artifact's `version_id` from the input),
      `new_version_number` (resolved by reading `artifact_versions.version_number`
      for `new_version_id` — a join, not caller-supplied, so a caller cannot lie
      about which version number a given `version_id` corresponds to),
      `activator_user_id`, `activated_at` (the group's shared timestamp, §4.5),
      `rationale` (the group's shared rationale text, §2.3's note), `group_id`
      (the `:group` step's inserted id, §2.3).
4. Submit the fully-built `Multi` to `Repo.transaction/1` **once**, for the whole
   group — this is REPO-08's "ONE transaction" requirement satisfied structurally
   by `Ecto.Multi`'s own composition (identical to how `req195`'s design uses one
   `Multi`/one `Repo.transaction/1` call per audited mutation, §4 of that design):
   any step's failure (a changeset error, a DB-level `CHECK`/FK/UNIQUE violation)
   aborts and rolls back every prior step already in the `Multi`, including every
   already-processed artifact in the group and the `:group` envelope row itself —
   this is what AC1's "a forced failure part-way through leaves ALL THREE at their
   previous versions with no history rows written" reduces to: `Ecto.Multi`'s
   existing all-or-nothing guarantee, the same one REQ-202/`req195` already rely
   on for their own transactions, applied to N artifact-steps instead of one.

### 4.3 REPO-08's observability criterion — the core technical risk, addressed directly

**The acceptance criterion, restated precisely:** "a concurrent read issued while a
multi-artifact activation is in flight observes either every artifact at its old
version or every artifact at its new version, never a mix." This is a claim about
what a **separate, concurrent transaction** can observe while `activate_group/4`'s
own transaction is still open (uncommitted).

**Isolation-level assumption, stated explicitly (per this run's own instruction not
to hand-wave this):** `Letflow.Repo` (`lib/letflow/repo.ex`, confirmed §0 above) sets
no isolation-level override anywhere — every transaction in this codebase, including
`activate_group/4`'s, runs at Postgres's server default, **READ COMMITTED**. This
design does **not** require bumping to `REPEATABLE READ`/`SERIALIZABLE` for this
acceptance criterion, and the reasoning is the load-bearing part of this section:

1. **Postgres's transaction-visibility model (MVCC) never exposes an in-progress,
   uncommitted transaction's writes to any other transaction, at *any* isolation
   level Postgres offers — including READ COMMITTED, the weakest one.** This is
   not an isolation-level-dependent property; it is a floor every Postgres
   isolation level provides (the isolation levels differ in what a transaction
   sees *across multiple of its own statements* relative to *other transactions'
   commits made in between* — READ COMMITTED re-takes a fresh snapshot per
   statement, REPEATABLE READ/SERIALIZABLE take one snapshot for the whole
   transaction — but none of them ever let a reader see another transaction's
   *uncommitted* rows; that would be a "dirty read," which Postgres has never
   implemented at any isolation level, unlike some other RDBMSes' READ
   UNCOMMITTED).
2. **A transaction's writes become visible to other transactions atomically, at
   COMMIT — not incrementally as each statement inside it executes.** Because
   `activate_group/4`'s entire group (every `artifact_activations` upsert, every
   `artifact_activation_history` insert, the `:group` row) is one `Ecto.Multi`
   submitted to exactly one `Repo.transaction/1` call (§4.2 step 4), there is
   **no window in which a committed, externally-visible database state reflects
   only some of the group's updates.** Before commit, every concurrent reader
   (at any isolation level) sees the *entire prior state* — every artifact still
   at its old version, including whichever ones this transaction has already
   internally updated but not yet committed. After commit, every concurrent
   reader sees the *entire new state* — every artifact at its new version. There
   is no third, intermediate state a reader can ever observe, because Postgres
   does not expose one, regardless of how many individual `UPDATE`/`INSERT`
   statements the transaction issued internally or in what order.
3. **Consequence: REPO-08's observability property is a direct, structural
   consequence of "N writes inside ONE transaction," not something that requires
   an additional isolation-level bump or an explicit table-level lock beyond the
   per-row `FOR UPDATE` locks §4.2 step 3a already takes for the separate
   concurrency-correctness concern (serializing two concurrent activators of the
   same artifact against each other).** Bumping to `SERIALIZABLE` would add
   protection against a different class of anomaly (e.g. write skew across
   multiple *separate* transactions each reading and then writing based on a
   stale snapshot) that is not what REPO-08's own wording asks for — REPO-08 is
   entirely about one transaction's atomic visibility to outside readers, which
   READ COMMITTED already guarantees.

**What this means the test must actually do, to be a real test of this claim (not
a vacuous one):** a naive test — commit the whole group, then read — proves
nothing about the *in-flight* window, since after commit there is nothing left to
observe going wrong. The test must **hold `activate_group/4`'s transaction open
across multiple of its internal steps while a second, independent connection
reads**, which requires two genuinely separate database connections/transactions
interleaving in real time — the same requirement `req-055`'s design already
identified and solved for a different concurrency property (§0 above): use
`Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` (not `Letflow.DataCase`'s
default `{:shared, self()}` sandbox mode, which routes every process's queries
through one shared connection and would make "a genuinely separate concurrent
transaction" impossible to construct), spawn the activation as a `Task` that
pauses mid-`Multi` at a test-only synchronization point (e.g. a
`Multi.run/3` step that blocks on a message/`Agent` signal after processing the
first artifact in the group and before processing the second), have the main test
process issue `resolve/3` reads for **every** artifact in the group during that
pause and assert every one of them still returns its **old** version (never a mix
of old-for-some/new-for-others), signal the paused transaction to continue and
commit, then issue the same reads again and assert every one now returns its
**new** version. This is the concrete test shape TEST-DESIGNER must build from
this section — flagged here because "the test must be a concurrent read against a
partially-applied activation, not merely a rollback check" is the requirement's
own explicit instruction, and a rollback-only test would not exercise this
section's claim at all.

### 4.4 Single-artifact activation

Calling `activate_group/4` with a one-element `activations` list is the
single-artifact path — no separate function, no separate schema shape (§4.1). The
group envelope (§2.3) still gets one row, and the one history row still carries
that group's `group_id`. This keeps "every activation belongs to exactly one
group, atomic by construction" uniform rather than introducing a second, ungrouped
activation shape whose atomicity would need to be independently re-argued.

### 4.5 One shared `activated_at`/`rationale` per group — stated explicitly

`activated_at` is stamped **once**, before the `Multi`'s steps are built (§4.2
step 2), and that single value is reused for the group row and every history row
the group produces — not re-stamped per artifact. This matches the requirement's
own framing of the group as "one observable unit": if each artifact's history row
carried its own `DateTime.utc_now/0` call, two history rows from the same atomic
activation could carry different (if extremely close) timestamps, which would
falsely suggest they were not part of one atomic operation to a reader sorting
purely by `activated_at`. `rationale` is likewise the group's single free-text
value, copied onto every history row the group produces (§2.3's note) — REQ-203's
schema spec lists `rationale` on both `artifact_activation_history` and
`artifact_activation_groups`, and this design reads that as "the same rationale
text, recorded redundantly on both the per-artifact history row and the group
envelope for query convenience," not as two independently-supplied reasons for
one atomic call.

---

## 5. Activation history's append-only nature — judgment call, stated explicitly

**Decision: no DB-level (trigger-enforced) immutability on
`artifact_activation_history` or `artifact_activation_groups`. Both tables are
append-only by construction (no `update/1`/`delete/1` function is exposed by this
module's context API, §8), matching Decision 0003-C's application-layer treatment
for event-shaped tables — not REQ-202/`req195`'s DB-trigger treatment.**

**Reasoning, since the requirement's own text does not settle this and explicitly
asks for judgment:**

1. **REQ-202/`req195`'s DB-trigger precedent exists because their own acceptance
   criteria used the specific "rejected by the DATABASE, not merely absent from
   the context API" framing** (REQ-202's AC7, verbatim; `req195`'s AC1 uses the
   equivalent "going around the Ecto schema" framing). **REQ-203's own acceptance
   criteria never use this framing for `artifact_activation_history`'s
   immutability** — AC6 uses that framing for the *rationale non-empty*
   invariant specifically (§2.4 above, which this design does give DB-level
   `CHECK` enforcement to, precisely because AC6 does use the framing), but no
   acceptance criterion in this requirement's list asks for an UPDATE/DELETE
   attempt against `artifact_activation_history` to be tested and rejected at
   the database level the way REQ-202's AC7 and `req195`'s AC1 explicitly do.
   Absent that explicit instruction, this design does not add a mechanism no
   acceptance criterion checks for.
2. **This table's semantics differ from `audit_entries`/`repository_artifacts` in
   a way that matters for the tamper-evidence argument specifically.**
   `audit_entries`' DB-trigger immutability exists in service of its
   hash-chain's tamper-evidence property (`req195` §2/§6): a chain is only
   meaningful if entries cannot be silently altered after the fact, and `req195`
   goes further and builds a whole recompute-based verification function around
   that property. `artifact_activation_history` has **no hash chain, no
   `verify_chain/2`-equivalent function, and no acceptance criterion asking for
   one** — it is a queryable lineage table, not a tamper-evidence mechanism. The
   *reason* REQ-202/`req195` reach for a DB trigger (defending a
   cryptographic-integrity property against out-of-band tampering) does not
   apply here, because there is no cryptographic property to defend.
3. **The FK-based protection already in place (§2.2) covers the concrete risk
   that matters most:** `previous_version_id`/`new_version_id`'s `on_delete:
   :restrict` FKs mean a version referenced anywhere in the activation history
   can never be deleted out from under it (whether or not the history row
   itself could theoretically be updated), which is the same "the data this row
   points at cannot disappear" guarantee REQ-202's design gives
   `artifact_versions` rows generally.
4. **Symmetry check against this codebase's actual convention, not just this one
   pair's precedent:** Decision 0003-C's own stated default for insert-only/
   event-shaped tables is *application*-layer enforcement (no update path
   exposed), with DB-level triggers as the exception REQ-202/`req195` opted into
   because *their own acceptance criteria demanded it*. `artifact_activation_history`
   is exactly the kind of insert-only/event-shaped table Decision 0003-C's
   default already covers, so following that default here (rather than
   REQ-202/`req195`'s exception) is the codebase's own general rule, not a
   deviation this design has to separately justify beyond noting that the
   exception's trigger condition (an explicit "rejected by the DATABASE"
   acceptance criterion) is absent for this specific table.

**If a future requirement's acceptance criteria demand DB-level rejection for
this table** (mirroring REQ-202/`req195`), the mechanism to add is identical to
§5 of REQ-202's design (a per-tenant-schema trigger function, `BEFORE UPDATE`/
`BEFORE DELETE`, fixed message text) — this design does not rule that out, it
states why it is not built now, absent from this requirement's own acceptance
criteria.

**`artifact_activation_groups`** gets the identical treatment and identical
reasoning — no acceptance criterion in this requirement's list names it directly
at all beyond its schema spec, and it is exactly as insert-only/event-shaped as
`artifact_activation_history`.

---

## 6. Activation history listing — REQ-067's cursor contract

`Letflow.Repository.Activation.list_history(artifact_kind :: artifact_kind() | nil, artifact_name :: String.t() | nil, prefix :: String.t(), opts :: keyword()) :: {:ok, Pagination.Page.t(ActivationHistory.t())} | {:error, :invalid_schema_name} | {:error, :page_size_too_large} | {:error, :wrong_endpoint} | {:error, :expired} | {:error, :invalid_cursor}`

- **Two call shapes, both backed by §2.2's two indexes:** `artifact_kind`/
  `artifact_name` both `nil` lists the **whole tenant's** activation history,
  chronologically (AC7's literal wording, "activation history is returned in
  chronological order," read at the tenant-wide granularity by default — since
  AC7 does not scope "activation history" to one artifact); both non-`nil` lists
  history for exactly that one `(artifact_kind, artifact_name)` pair, still
  chronologically. This mirrors REQ-202's `list_versions/4`, which is
  necessarily per-`(kind, name)` since that is a version history; this table's
  history is naturally both per-artifact **and** tenant-wide-meaningful (an
  activator wants to see "everything I've activated recently" as much as "this
  one artifact's activation history"), so both shapes are offered rather than
  forcing every caller through a per-artifact-only query and reconstructing a
  tenant-wide view by fanning out.
- `opts` accepts `:cursor`/`:page_size`, identical validation discipline to
  REQ-202's `list_versions/4` (`Pagination.validate_page_size/1`, rejected not
  clamped).
- Ordering: `(activated_at desc, history_id desc)` — matching §2.2's indexes,
  newest-first, the same "list newest-first" convention `req195`'s
  `list_entries/1` and REQ-202's `list_versions/4` both already establish.
- Cursor minted via `Pagination.build_raw_cursor_timestamp_key/4` with a prefix
  distinct from every other endpoint's (e.g. `"AH:"` — distinct from REQ-202's
  `"RV:"` and any REQ-196 audit-listing prefix), per REQ-067's AC3.
- **The decoded cursor carries no `tenant_id`/schema/prefix field** (REQ-067's
  INV-1) — identical structural argument to REQ-202's `list_versions/4` (§6 of
  that design): tenant scoping is exclusively `prefix`, and because each
  tenant's `artifact_activation_history` table is a physically separate schema,
  a query scoped to one tenant's `prefix` structurally cannot return another
  tenant's rows regardless of what a replayed cursor decodes to.
- Response shape: `Pagination.page_response/2`, identical to every other S4+
  list endpoint.

---

## 7. Activation history vs. REQ-195's `audit_entries` — the required disambiguation

**Required verbatim-in-substance in `Letflow.Repository.Activation`'s (or wherever
this schema's context module lands) moduledoc, per this requirement's own
acceptance criterion and R-Co's own REPO-10/OBS-03 cross-reference ("activations
are also audited").**

**Both exist, deliberately, and record the same real-world event from two
different angles — this is not duplication to later delete:**

| | `artifact_activation_history` (this requirement) | `audit_entries` (REQ-195, `Letflow.Audit`) |
|---|---|---|
| **Scope** | Subsystem-specific: only artifact activations. | Tenant-wide: definition/instance/task/identity mutations (`req195` §3.2's covered-operation table) — a general compliance trail, not artifact-specific. |
| **Shape** | A denormalized, purpose-built row: `previous_version_id`/`new_version_id`/`new_version_number` as first-class typed columns, directly queryable/joinable against `artifact_versions` with no JSON parsing. | A generic `resource_type`/`resource_id`/`before_state`/`after_state` shape (`jsonb` blobs) — deliberately generic so one schema covers every resource type this codebase audits, at the cost of not being directly joinable/typed the way a purpose-built column is. |
| **Mandatory field unique to this table** | `rationale` — **required, non-empty** (§2.4), because REPO-10 specifically demands a human-readable justification for *why* an activation happened. `audit_entries` has no equivalent required-free-text field for any of its covered operations (`req195`'s own per-operation table, §3.2, never requires a caller-supplied rationale string). |
| **Tamper-evidence** | None — no hash chain, no `verify_chain/2` equivalent (§5). | Hash-chained (`chain_hash`/`prev_chain_hash`), with a dedicated `verify_chain/2` recompute-based verification function (`req195` §6) — a genuine tamper-evidence mechanism this table does not have and does not need, since its own protection is FK-based (§5 point 3) and query-shape-based, not cryptographic. |
| **Consumer** | `Letflow.Repository.Activation.resolve/3` and this subsystem's own callers — "the artifact subsystem's own queryable lineage." | `Letflow.Routers.Audit` (REQ-196) — the tenant-wide compliance/audit-log surface a compliance officer or incident responder queries across every resource type at once. |

**Both are populated by the same real-world activation event, independently,
neither reading nor writing the other.** An artifact activation is expected (per
R-Co's own REPO-10/OBS-03 cross-reference) to *also* append one `audit_entries`
row via `Letflow.Audit.append_multi/4` — `action: "artifact.activate"` (or
per-group `"artifact.activate_group"`), `resource_type: "artifact"`,
`resource_id`: the artifact's stable identity (this design uses
`artifact_versions.artifact_id`, REQ-202 OQ-4's server-generated per-`(kind,
name)` handle, as the natural `resource_id` value — not `activation_id`, since
`resource_id` should identify *the artifact*, not this particular activation
event), `before_state`/`after_state`: the pre/post `artifact_activations` row
(allowlisted field map, `Letflow.Audit.struct_state/2`), `actor_id:
activator_user_id`. **This design adds this `Letflow.Audit.append_multi/4` call
as one more `Multi.run/3` step inside §4.2's same `Multi`** (per artifact in the
group, or once for the whole group — ELIXIR-DEV's choice, flagged as OQ-F below
since REQ-203's acceptance criteria do not test `audit_entries` population
directly, only requiring the moduledoc to state the relationship) — same
same-transaction guarantee reasoning `req195` §4 gives its own audit steps: if
the audit insert fails, the whole activation (including every artifact in the
group) rolls back with it, consistent with `req195`'s own AC3-equivalent
same-transaction discipline, even though no acceptance criterion in *this*
requirement names an audit-insert-failure test directly (§9 OQ-F covers this
gap explicitly).

**Neither table is ever read, written, or deleted by the other's context
module** — `Letflow.Repository.Activation` never queries `audit_entries`, and
`Letflow.Audit` never queries `artifact_activation_history`. A later reader must
not delete either as "redundant with the other" — they serve different
consumers (a compliance officer's tenant-wide audit view vs. this subsystem's own
typed lineage query) and only one of the two (`audit_entries`) carries
tamper-evidence.

---

## 8. Functions deliberately NOT built (scope discipline)

| Function | Why not |
|---|---|
| `update/1`/`delete/1` on `artifact_activation_history`/`artifact_activation_groups` | Append-only by construction (§5) — no acceptance criterion demands a DB-level block, so no trigger is added either, but the context API itself exposes no mutation path for either table. |
| A general `update/1` on `artifact_activations` outside `activate_group/4`'s own internal upsert step | The only legitimate way to change an activation is to activate a (possibly different) version through the full transactional path (§4), which also produces the required history row — a bare `update/1` that changed `active_version_id` without a corresponding history row would violate REPO-10 (every activation must be historied) by construction, so no such function is exposed. |
| Any route/controller (`/repository/activations` or similar HTTP surface) | Explicitly out of scope, per this requirement's own text — REQ-202's own recorded finding that R-Co's REPO-11..14 routes were specified but never built, and Letflow has no SPA consumer, applies identically here; named in the stage doc's not-covered list. |
| Changes to REQ-202's tables or canonicaliser | Explicitly out of scope per this requirement's own text — this design reads `artifact_versions`/`Canonicaliser` but modifies neither. |
| Form-schema indexing (REPO-05) | Deferred, independent of this pair, per the stage doc's not-covered list. |

---

## 9. Open questions (stated explicitly, not silently resolved)

- **OQ-A — `artifact_versions.version_number`'s actual migration-level Postgres
  type.** `Letflow.Repository.ArtifactVersion`'s Ecto schema declares
  `field(:version_number, :integer)` (confirmed from source, §0), but Ecto's
  `:integer` type does not by itself confirm whether the underlying migration
  declared the Postgres column as `integer` (32-bit) or `bigint` (64-bit) — REQ-202's
  own requirement text calls for `bigint`, but this design has not read
  REQ-202's actual shipped migration file to confirm which was used. ELIXIR-DEV
  must check `priv/repo/migrations/20260830030001_create_repository_artifacts.exs`
  (or wherever `artifact_versions`' migration lives) directly and declare
  `artifact_activation_history.new_version_number`'s column type to match exactly
  — a mismatch (e.g. this design's table using `bigint` against a `version_number`
  that is actually 32-bit `integer`) is harmless for small values but is a latent
  inconsistency worth avoiding outright.
- **OQ-B — sharing `artifact_kind`'s `Ecto.Enum` value list across four schema
  modules.** `Letflow.Repository.ArtifactVersion` already declares this seven-atom
  list inline (§0); this design's three new schemas (§2.1/§2.2) need the identical
  list. Whether ELIXIR-DEV extracts a shared `@artifact_kinds` module attribute/
  function (e.g. on `Letflow.Repository` itself) or hand-copies the literal list
  into each schema module is left to Step 2a — this design requires the **values**
  to be identical (a drift here would silently make some artifact kinds
  activatable-but-not-creatable or vice versa) but does not mandate the specific
  Elixir-level sharing mechanism.
- **OQ-C — whether a system/scheduler-driven activation with no human actor is a
  real call path.** REQ-203's schema spec lists `activator_user_id` as an
  unqualified required field with no nullable case described, and this design's
  §2.1 follows that literally (`null: false`, no nullable variant). If a future
  requirement introduces an automated/scheduled activation trigger with no human
  actor, that would need either a synthetic system-actor UUID convention or a
  schema change to make the column nullable — out of this design's scope to
  pre-resolve, since REQ-203's own text describes no such call path today (mirrors
  `req195`'s OQ-4/OQ-5 treatment of the analogous "no real system-driven caller
  today" question for its own tables).
- **OQ-D — `validate_required/2`'s exact empty-string behavior in this codebase's
  pinned Ecto version.** §2.4 point 1 flags that this design does not have direct
  source confirmation this session of whether `Ecto.Changeset.validate_required/2`
  alone rejects a literal `""` value for a `:text`/`:string` field (as opposed to
  only `nil`) in the Ecto version this codebase depends on. This does not change
  §2.4's conclusion (an explicit `validate_length(:rationale, min: 1)`-or-equivalent
  check plus a DB-level `CHECK` constraint are both added regardless, so the
  invariant holds either way), but ELIXIR-DEV should confirm this detail at Step 2a
  so the changeset-level check is not accidentally redundant-and-harmless in a way
  that masks a real gap if the assumption is wrong.
- **OQ-E — a caller submitting a duplicate `(artifact_kind, artifact_name)` pair
  within one `activate_group/4` call.** §4.2 step 3 notes this is a caller error
  this design does not silently resolve (e.g. by de-duplicating or by taking "the
  last one wins"). ELIXIR-DEV should decide at Step 2a whether to reject this
  up front with an explicit `{:error, :duplicate_artifact_in_group}` (preferred,
  since it fails fast with a clear reason rather than surfacing as an opaque
  `Ecto.Multi` step-collision error) or let the `Multi`'s own internal step-name
  collision or a same-transaction unique-index self-conflict surface it — this
  design flags the case as real (worth an explicit test) without mandating which
  of those two shapes the rejection takes.
- **OQ-F — whether the `audit_entries` cross-write (§7) is one call per artifact
  in the group or one call for the whole group.** §7 adds a
  `Letflow.Audit.append_multi/4` step inside `activate_group/4`'s own `Multi`
  (same-transaction, so a failure there rolls back the whole activation), but
  does not mandate whether this is N audit rows (one per artifact activated) or
  one audit row summarizing the whole group. No acceptance criterion in this
  requirement tests `audit_entries` population directly (only the moduledoc
  statement of the *relationship* between the two tables is checked, per §7's
  own opening note), so this granularity choice is left to ELIXIR-DEV at Step 2a,
  with a preference stated but not mandated: one audit row per artifact (matching
  `artifact_activation_history`'s own one-row-per-artifact granularity) is more
  consistent with `req195`'s own per-resource-instance audit-row convention
  (§3.2 of that design never audits a "batch" as one row) than a single
  group-level summary row would be.

---

## 10. Traceability — acceptance criteria to design elements

| AC (paraphrased) | Design element |
|---|---|
| AC1 — group activation atomic; forced failure leaves all at prior state, no history rows | §4.2 (Multi steps), §4.2 step 4 (Ecto.Multi all-or-nothing) |
| AC2 — REPO-08 observability: concurrent read never sees a mix | §4.3 (isolation-level argument + required test shape) |
| AC3 — REPO-09 per-tenant isolation, two explicit tests | §1 (per-tenant placement), §2.1 (UNIQUE scoped by tenant_id) |
| AC4 — UNIQUE (tenant_id, artifact_kind, artifact_name) enforced by the DATABASE | §2.1 (unique index) |
| AC5 — every activation appends one history row, previous_version_id null-then-populated | §2.2, §4.2 steps 3b/3d |
| AC6 — activation with no rationale REJECTED, not stored empty | §2.4 (changeset + DB CHECK, both layers) |
| AC7 — activation history chronological, REQ-067 pagination | §6 |
| AC8 — resolution function returns active version or not-found, never arbitrary | §3 |
| AC9 — ON DELETE RESTRICT prevents deleting an active version | §2.1 (`active_version_id` FK), §2.2 (history FKs) |
| AC10 — moduledoc states activation-history vs. audit_entries distinction | §7 |
| AC11 — no route/controller added | §8 |
| AC12 — mix test / mix compile --warnings-as-errors pass | Step 2a/3 execution gate, not a design-stage artifact |
