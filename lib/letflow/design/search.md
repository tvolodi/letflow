PROVENANCE (historical, not current decision authority):

# Design: REQ-042 — Definition full-text search (`store.zig`'s `Store.search()`, PD-10)

**Requirement:** REQ-042 (`docs/requirements.yaml:2000-2050`, stage S2, `depends_on: [REQ-030]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ042-20260817`, WF-02 Step 1
**This document produces:** the public function signature (`@spec`-style types), the
Ecto.Query ranking/filter structure (fragment shape, not literal SQL text), the error
taxonomy, pagination behavior, invariants, and open questions — **no implementation
code**. No function bodies, no `.ex` files. Pseudocode/query-structure prose describes
shape only — ELIXIR-DEV writes the real version at Step 2a.

---

## 0. Sources read for this design

- `docs/requirements.yaml:2000-2050` — REQ-042's full entry (title, description, all 6
  acceptance criteria, `depends_on: [REQ-030]`).
- `docs/guides/backend_developer_guide.md` §3.1 (naming), §3.5 (error shapes), §3.6 (SQL
  parameterization — `Ecto.Query`/`fragment/1` with bound `^value`, never string-built
  SQL), §5 (multi-tenancy, schema-per-tenant via `:prefix`).
- `docs/migration/stage-2-event-store-definitions.md` — read; no PD-10-specific content
  found there (that stage doc predates REQ-042's expansion into `requirements.yaml`) —
  this design instead follows `req030-definition-store-crud.md`'s already-established
  conventions for this same module, per this task's explicit instruction.
- `docs/agents/instructions/security-invariants.md` — INV-1 (tenant isolation via
  `:prefix`), INV-7 (no raw-SQL interpolation of tenant/user data — `fragment/1` with a
  bound `^value`), INV-8 (typed `{:ok, _} | {:error, _}` results, no unresolved bare
  match on external-input paths).
- `docs/anti-patterns.md` — no entry directly applicable to this module's own
  construction.
- `lib/letflow/design/req030-definition-store-crud.md` — **read in full (959 lines)**.
  §1's scope-boundary table explicitly excludes `search/1` from REQ-030's own scope,
  assigning it to REQ-042 and citing "per PD-10's own design, no new table or index for
  it." §3's `tenant_id`-derivation contract (every function resolves `opts[:prefix]` via
  `TenantProvisioning.tenant_id_for_schema_name/1` as an early step, even when the
  resulting `tenant_id` value itself goes unused, purely for its format-validation side
  effect). §4.4's `list/2` — the closest structural sibling: a `(filters_map, opts)`
  signature, an `ILIKE '%<name>%'` substring filter built via
  `fragment("? ILIKE ?", d.name, ^pattern)` with the `%`-wildcards composed into the
  bound `^pattern` value (never spliced into the fragment's SQL text), a `limit`/`offset`
  contract, and an explicit "always `{:ok, list}`, empty list on no match, never an
  error" contract this design reuses verbatim.
- `lib/letflow/design/req027-definition-core-schema.md` — §0 and §1's scope table
  confirm directly (not assumed): REQ-027's shipped migration/schema created only
  `uq_definition_version`, `uq_active_definition`, `idx_def_status`, `idx_def_stage` —
  **no `idx_def_name` and no `idx_def_fts`/GIN index**, even though R-Co's own
  `migrations/004_definitions.sql` had both (§0's citation:
  `idx_def_name` (38), `idx_def_fts` (42-44)). REQ-027 deliberately did not port those
  two — consistent with PD-10's own "no dictionary config dependency, no GIN index
  required" rationale (`requirements.yaml:2024-2026`) and REQ-027's own boundary-table
  entry: *"`search/1` (PD-10) — and, per PD-10's own design, **no new table or index**
  for it | REQ-042 | `requirements.yaml:1942-1990`; `definition.md:3008-3022`"*
  (`req027-…md` §1). This is load-bearing for §5 below: this design's query runs a plain
  sequential-scan-eligible `ILIKE`, with no supporting index of any kind, by requirement.

**Letflow shipped code, read directly (not assumed):**

- `lib/letflow/definitions.ex` — **full file (819 lines)**. Confirmed the module's
  current public API (REQ-041's `compute_pack_update_plan/5`/`classify_artefact/3`,
  REQ-030's `create/2`/`get_by_id/2`/`get_active_by_name/2`/`list/2`/`activate/2`/
  `deprecate/2`/`archive/2`), the `opts :: [prefix: String.t()]` type, the
  `TenantProvisioning.tenant_id_for_schema_name/1` call-first pattern every function
  uses, and `list/2`'s exact `where_name/2` ILIKE-fragment helper (`definitions.ex:585-588`)
  this design's ranking query extends.
- `lib/letflow/definitions/export_import.ex` — **full file (137 lines)**, REQ-034's
  shipped read-only, delegation-style precedent. `export/2`'s shape (`(id, opts)`,
  delegates tenant resolution entirely to the function it calls, propagates that
  function's error shapes unchanged) is the read-only precedent this task named
  explicitly — but `search/2` (below, §2) does **not** delegate to `get_by_id/2` or
  `list/2`; it builds its own ranked query directly, since neither existing function's
  shape (single-row lookup; unranked substring filter) can express PD-10's ranking.
- `lib/letflow/definitions/process_definition.ex` — **full file (151 lines)**, REQ-027's
  shipped schema. Confirmed the exact field list this design's `SELECT`/`fragment`
  clauses reference: `id`, `tenant_id`, `name`, `version`, `description`, `status`
  (`Ecto.Enum`, stored lowercase), `stage` (nullable free text), `graph`, `created_by`,
  `archived_at`, `created_at`/`updated_at` (via `timestamps(inserted_at: :created_at,
  type: :utc_datetime_usec)`). No `@schema_prefix` — every query must pass `prefix:`
  explicitly at call time (moduledoc's "No `@schema_prefix`" section, INV-DEF-7).

---

## 1. Scope boundary

**In scope (this requirement):** one public function, `Letflow.Definitions.search/2`,
added to the existing `lib/letflow/definitions.ex` context module. No new Ecto schema,
no new migration, no new index.

**Explicitly NOT in scope, not silently dropped:**

| Not built here | Owned by | Why it's excluded |
|---|---|---|
| The `GET /api/v1/definitions/search` HTTP endpoint, `limit > 100` rejection (422) | S4 (api-surface) | REQ-042's own description: "this function itself does not need to reject an out-of-range limit, only apply the default" — validated at the HTTP handler layer, per PD-10's own validation-rules table (`requirements.yaml:2018-2021`). |
| A `tsvector`/`to_tsquery` full-text index or column | Not assigned — deliberately never built for this requirement | `definition.md`'s "Why ILIKE instead of tsvector" rationale (`requirements.yaml:2023-2026`); REQ-027 already omitted `idx_def_fts` (§0). |
| Any new migration or index (`idx_def_name`, a GIN index, etc.) | Not assigned — explicitly ruled out | REQ-042's description and `req027-…md`'s boundary-table entry both state this as a hard constraint, not an oversight (§6 INV-SR-1). |

---

## 2. Module and function placement

**Extends the existing `lib/letflow/definitions.ex` (`Letflow.Definitions`) — does not
create a new module.** Matches REQ-030/REQ-041's own established convention: one
context module aggregating every operation on `process_definitions` (§0's citation of
`req030-…md` §2's rejection of a separate `Letflow.Definitions.Store` module applies
identically here — `search/2` is a read operation on the exact same table REQ-030's
seven functions already operate on, not a distinct sub-domain deserving its own file,
unlike `Letflow.Definitions.ExportImport` or `Letflow.Definitions.Graph`, both of which
hold enough independent structure — a full document format, a full graph-validation
algorithm — to justify a submodule. Search has neither: it is one query with one
ranking rule).

| Module | File | Kind |
|---|---|---|
| `Letflow.Definitions` | `lib/letflow/definitions.ex` | **Edited** — 1 new public function (`search/2`), 1-2 new private query-building helpers, moduledoc extension (§7) |

---

## 3. Function signature — and the "search/1" vs. "search/2" naming tension, resolved explicitly

**This design implements `Letflow.Definitions.search/2`, not `search/1`, and that
divergence from the "search/1" label used in `requirements.yaml`'s REQ-030
boundary-table entry (`req030-…md` §1) and this task's own title is a deliberate,
reasoned decision — not a silent one.**

Two pieces of this exact task's instructions point in different directions on arity:

- PROVENANCE (historical, not current decision authority):
  **Naming precedent** (`req030-…md` §1, this task's title): calls it "`search/1`,"
  inherited from R-Co's `src/definition/store.zig`'s `Store.search(options:
  SearchOptions)` — a genuinely single-argument Zig call (one struct bundling `query`,
  `limit`, `offset`).
- **This task's own acceptance criterion** ("`search/1` signature specified: **input
  (query string, opts with limit/offset)**, output...") and its explicit instruction
  ("your `search/1` design **must follow the same tenant-scoping convention**...how
  `opts[:prefix]` is threaded through to `Repo` calls") both describe **two** distinct
  inputs — a bare query string, and an `opts`-shaped container carrying `limit`/`offset`
  (and, by the tenant-scoping instruction, `:prefix` too) — which is exactly the
  `(primary_arg, opts)` two-argument shape every other function in this module already
  uses (`create/2`, `get_by_id/2`, `get_active_by_name/2`, `list/2`, `activate/2`,
  `deprecate/2`, `archive/2` — **zero** of REQ-030's seven functions are arity 1).

**Resolution:** the "search/1" label is R-Co's Zig-side single-struct naming, carried
into Letflow's docs as shorthand without being updated for Elixir's idiomatic
`(business_args, opts)` two-argument tenant-scoping convention this module uses
everywhere else. This design follows the convention (matching every sibling function,
and matching this task's own literal "opts with limit/offset" phrasing) over the
inherited label. `opts` here is the same `opts :: [prefix: String.t()]` keyword-list
type reused unchanged from every sibling function, **extended** with two new optional
keys (`:limit`, `:offset`) — not a second, differently-shaped container.

```
@type search_opts :: [
  prefix: String.t(),
  limit: pos_integer() | nil,
  offset: non_neg_integer() | nil
]

@type search_result :: %{
  definition: Letflow.Definitions.ProcessDefinition.t(),
  rank: float()   # 3.0 | 2.0 | 1.0 -- see §5. Never any other value.
}

@type search_error ::
  {:error, :query_empty}
  | {:error, :query_too_long}
  | common_error()   # {:error, :invalid_schema_name} -- reused from definitions.ex's
                      # existing common_error() type (§4.0 of req030-…md), unchanged.

@spec search(query :: String.t(), opts :: search_opts()) ::
  {:ok, [search_result()]} | search_error()
```

**Return shape note:** a list of `%{definition: ..., rank: ...}` maps, not a bare list
of `ProcessDefinition.t()` structs and not a new `Ecto.Schema`/plain-struct module.
Mirrors `activate/2`'s own established "plain map bundling the schema struct with one
extra computed field" idiom (`req030-…md` §4.5's `%{definition: ..., already_active:
boolean()}`, reused here without inventing a third return-shape convention) rather than
adding `rank` as a virtual field on `ProcessDefinition` itself (which would require
`ProcessDefinition`'s schema to declare a `field(:rank, :float, virtual: true)` it has
no use for outside this one query — an unnecessary schema-module edit for a value that
only ever exists as this function's own computed output).

---

## 4. Validation phase — `query` shape, before tenant resolution

Order (deliberately: cheap, pure checks on the primary argument run before any
`TenantProvisioning` call, matching `create/2`'s own "cheapest checks first" ordering
rationale, `req030-…md` §4.1 step P3's citation of the same principle):

1. **V0 — empty query.** `byte_size(query) == 0` → `{:error, :query_empty}`. **No
   trimming/whitespace-stripping is performed** — a string of only whitespace (e.g.
   `"   "`) has `byte_size > 0` and is **not** rejected by this check. This mirrors
   `create/2`'s own `fetch_name/1`/`fetch_version/1` (`definitions.ex:489-503`), which
   also perform no trimming — a deliberate, stated choice for consistency with this
   module's existing sibling checks, not an oversight. (A whitespace-only query simply
   never `ILIKE`-matches any real `name`/`description` value in practice, so this
   doesn't silently misbehave — it falls through to the empty-list, no-match path,
   §6.)
2. **V1 — too-long query.** `byte_size(query) > 512` → `{:error, :query_too_long}`.
   **Byte length, not grapheme count** — matches `create_changeset/2`'s sibling manual
   checks (`fetch_name/1`, `fetch_version/1`), which use `byte_size/1` throughout, not
   `String.length/1`. A stated, deliberate choice: a query composed of multi-byte UTF-8
   characters could reach this 512-byte ceiling before 512 visible characters — flagged
   here explicitly (§9 OQ-1) rather than silently assumed equivalent to
   character-count.
3. **V2 — resolve `opts[:prefix]`.** `TenantProvisioning.tenant_id_for_schema_name(Keyword.get(opts,
   :prefix))` → `{:error, :invalid_schema_name}` on failure. The resulting `tenant_id`
   is **not used** by the query itself (§6's invariant explains why) — this call exists
   purely for its format-validation side effect, identical in purpose to
   `get_by_id/2`'s/`list/2`'s own use of the same call (`req030-…md` §3's documented
   "uniform contract, not an inconsistent per-function decision").

**`{:error, :query_empty}` and `{:error, :query_too_long}` are two distinct atoms in two
distinct tagged tuples** — satisfying the "distinct error shapes" requirement literally:
a caller pattern-matching on `{:error, :query_empty}` never accidentally also matches
`{:error, :query_too_long}` or vice versa, unlike (for example) a single
`{:error, :query_invalid}` shared atom that would require the caller to inspect a
secondary reason field to tell the two apart.

---

## 5. Ranking design — the `fragment/1` CASE structure

**Matching predicate (WHERE clause).** A row matches iff `name ILIKE '%query%'` **or**
`description ILIKE '%query%'` — combined with `OR`, both against the same
`"%" <> query <> "%"` pattern. Structurally: one bound `^pattern` value, computed once
(`pattern = "%" <> query <> "%"`), referenced twice inside a single `fragment/1` call
combining both `ILIKE` comparisons with an `OR`, added to the query via `where/3` —
mirroring `list/2`'s existing `where_name/2` helper (`definitions.ex:585-588`) but
extended to a second column and an `OR` rather than a single-column `AND`-joined
predicate. `description` is nullable (`ProcessDefinition.description :: String.t() |
nil`) — Postgres's `ILIKE` against a `NULL` column value evaluates to `NULL` (not
`true`), which the surrounding `OR` handles correctly with no special-case `IS NOT
NULL` guard needed (a `NULL` operand simply doesn't contribute a match, exactly as a
non-matching non-null string wouldn't).

**Ranking expression (rank field), computed in the same query via a `fragment/1` CASE
structure — not a second query, not an in-Elixir post-processing pass over `Repo.all/2`'s
result:**

```
CASE
  WHEN lower(name) = lower(<bound query>)   THEN 3.0   -- exact name match, case-insensitive
  WHEN name ILIKE <bound pattern>           THEN 2.0   -- partial name match
  ELSE                                            1.0   -- description-only match
END
```

Composed as a `fragment/1` call inside a `select/3` (or `select_merge/3`) clause
producing the `%{definition: d, rank: <fragment>}` map directly — e.g. structurally:
`select([d], %{definition: d, rank: fragment("CASE WHEN lower(?) = lower(?) THEN 3.0
WHEN ? ILIKE ? THEN 2.0 ELSE 1.0 END", d.name, ^query, d.name, ^pattern)})`. Both `^query`
and `^pattern` are the **same two bound values** already computed for the `WHERE`
clause (§ above) — reused, not recomputed with different casing/wildcarding logic, so
the ranking `CASE` and the matching `WHERE` can never disagree about what counts as a
"name match."

**Why the `ELSE` branch is safe as an unconditional 1.0, not a third explicit
condition:** the surrounding `WHERE` clause has already restricted every row reaching
this `SELECT`/`CASE` to one that matched on `name` **or** `description`. Any row that
falls through both the exact-name and partial-name `WHEN` branches therefore
necessarily matched via `description` alone — the `WHERE` clause's own predicate is
what makes the bare `ELSE → 1.0` correct, not an independent third `WHEN description
ILIKE <pattern> THEN 1.0` condition (which would be redundant, since no row reaching
the `CASE` at all can fail every one of the three cases).

**Ordering.** `ORDER BY rank DESC, created_at DESC` — the `rank` field computed above,
then `created_at` (the schema's `timestamps(inserted_at: :created_at, ...)` field) as
the deterministic tie-breaker among equal ranks, structurally
`order_by([d], desc: fragment(<same CASE expression>), desc: d.created_at)` (or,
equivalently, ordering by the already-aliased `rank` selected field, whichever
Ecto/Postgres construct ELIXIR-DEV's Step 2a finds cleaner — both produce the identical
`ORDER BY` semantics; this design does not mandate one Ecto spelling over the other,
since neither changes the observable ranking behavior any acceptance criterion checks).

**AC1 traceability** (`requirements.yaml:2044`, "a definition named exactly \"invoice\"
... ranked above ... \"invoice-approval\" ... which in turn ranks above one matched only
via its description"): the three-tier `CASE` above produces exactly `3.0 > 2.0 > 1.0`
for those three cases respectively, and `ORDER BY rank DESC` places them in that exact
order.

---

## 6. SQL-injection safety (INV-SR-2 — mirrors INV-7)

**The `%` wildcard characters are composed into the bound `^pattern` parameter's
*value* in Elixir (`pattern = "%" <> query <> "%"`), never string-interpolated into the
`fragment/1` call's SQL *text*.** The fragment's SQL shape
(`"? ILIKE ? OR ? ILIKE ?"`, `"lower(?) = lower(?) WHEN ? ILIKE ? ..."`) is a fixed
compile-time string literal in every case — only the `?`-placeholder *values*
(`d.name`, `^pattern`, `d.description`, `^query`) vary per call, and every one of those
is either a query-column reference or a `^`-pinned Elixir value, which Ecto compiles to
a genuine bound Postgres parameter (`$1`, `$2`, ...) — never `<>`/`"#{}"`-spliced into
the SQL string itself. This is the identical discipline `list/2`'s `where_name/2`
already established (`req030-…md` §4.4 step 4's citation) and INV-7's own literal
example of the forbidden pattern (`Repo.query!` built via string concatenation) — this
design introduces zero `Repo.query/2`/`Repo.query!/2` raw-SQL calls at all; everything
above is `Ecto.Query` composition (`fragment/1` used only for the `ILIKE`/`CASE`
*expression shape*, per §3.6/INV-7's own carve-out that `fragment/1` with bound `^value`
placeholders is the sanctioned mechanism, not a violation of it).

A query string containing literal `%`, `_`, or `'` characters is never a defect here:
`%`/`_` behave as ordinary `ILIKE` wildcard/single-char-match metacharacters (matching
R-Co's own PD-10 behavior — no escaping is introduced, since none is named by any
acceptance criterion), and `'` (or any other character) is safe regardless, because the
entire `query` value — including any `'` it contains — is carried as a single bound
parameter's *value*, never parsed as SQL syntax by Postgres in the first place.

---

## 7. Pagination

```
effective_limit  = case Keyword.get(opts, :limit),  do: (nil -> 20;  n -> n)
effective_offset = case Keyword.get(opts, :offset), do: (nil -> 0;   n -> n)
```

`limit(^effective_limit)`, `offset(^effective_offset)` — both applied on the query
composed in §5, after `ORDER BY`, before `Repo.all/2`.

**No upper-bound clamp is applied here, deliberately diverging from `list/2`'s own
`effective_limit/1` (`definitions.ex:578-581`, which clamps anything `> 200` down to
`200`).** REQ-042's own description is explicit that "values above 100 are the HTTP
handler's job to reject...this function itself does not need to reject an out-of-range
limit, only apply the default" — so a caller-supplied `:limit` of, say, `500` is passed
through to `Ecto.Query.limit/2` unclamped and unrejected by this function. This
divergence from the sibling `list/2` convention is intentional and stated here so
ELIXIR-DEV doesn't "fix" it into a clamp REQ-042 explicitly does not want at this layer.

**AC5 traceability** (`requirements.yaml:2048`, "respects limit (default 20) and
offset...demonstrated with more matching rows than fit in one page across two
successive calls"): calling `search(query, prefix: p)` (no `:limit`/`:offset` — default
20/0) and `search(query, prefix: p, offset: 20)` (still default `:limit` 20) against a
fixture with more than 20 matching rows returns two disjoint 20-row (or fewer, for the
tail page) pages in `rank DESC, created_at DESC` order, together covering every matching
row exactly once — the ordinary `LIMIT`/`OFFSET` contract, unchanged from `list/2`'s
(which already relies on the identical Postgres mechanism).

---

## 8. No-match and empty results

`{:ok, []}` — never an error — when the `WHERE` clause (§5) matches zero rows. No
special-case branch is needed: `Repo.all/2` on a query with no matching rows already
returns `[]`, and this design's `search/2` returns `{:ok, Repo.all(query, prefix:
schema_name)}` directly, exactly mirroring `list/2`'s own "always `{:ok, list}`" return
shape (`req030-…md` §4.4).

**AC4 traceability** (`requirements.yaml:2047`): a query with no matching name or
description anywhere produces a `WHERE` clause matching zero rows, and `Repo.all/2`'s
own empty-list behavior on zero matches satisfies this directly — no additional
`case`/`if` branch this design would need to add.

---

## 9. Invariants

- PROVENANCE (historical, not current decision authority):
  **INV-SR-1 — No new migration, table, or index.** This design adds zero
  `priv/repo/migrations/` files and zero indexes. The query is a plain sequential-scan
  `ILIKE` over the existing `process_definitions` table, with no `idx_def_name` or
  `idx_def_fts`/GIN index to accelerate it — matching `req027-…md`'s own scope-table
  entry (§0) and REQ-042's description ("Search lives inside the existing
  store.zig...No new Zig source file or SQL migration is required"). The moduledoc edit
  in §10 must state this explicitly, citing `definition.md`'s PD-10 section, per AC6.
- **INV-SR-2 — No raw SQL string interpolation.** §6. All `%`/query-value composition
  happens in Elixir, bound as Ecto query parameters, never spliced into a `fragment/1`
  SQL-text literal.
- **INV-SR-3 — Tenant scoping via `opts[:prefix]` only, never a caller-supplied
  `tenant_id`.** `search/2`'s `query`/`opts` never accept a `:tenant_id` key at all —
  unlike `create/2`, there is no `reject_key/4`-style explicit rejection needed, because
  this function's `opts` type (§3) simply has no `:tenant_id` field in its `search_opts()`
  type to begin with; a caller passing an unexpected extra key in the `opts` keyword
  list is inert (Elixir's `Keyword.get/3` on an unrecognized key returns the given
  default regardless of what other keys are present). Tenant isolation itself comes
  from `Repo.all(query, prefix: schema_name)`'s `:prefix` option, scoping every read to
  exactly the one tenant schema `opts[:prefix]` resolved to (§4 V2) — INV-1.
- **INV-SR-4 — Always `{:ok, list} | {:error, ...}`, never a raised exception on
  realistic input.** A read-only `SELECT` has no unique-constraint/changeset failure
  mode to convert — unlike `create/2`, this design needs no `try/rescue` wrapper for a
  `{:transaction_failed, ...}` shape, since there is no `Repo.transaction/1` call and no
  write. The only failure paths are the three typed ones in §3's `search_error()` (INV-8).
- **INV-SR-5 — Rank is always exactly `3.0`, `2.0`, or `1.0`.** No other float value is
  ever produced by the `CASE` expression in §5 — no partial/weighted scoring, no
  normalization by string length or match position. This is a closed, 3-valued domain by
  construction.

---

## 10. Required moduledoc edit (ELIXIR-DEV, Step 2a) — AC6

The existing `Letflow.Definitions` moduledoc's "## Scope" section (`definitions.ex:21-27`)
must gain a `search/2` mention alongside REQ-030's seven functions, plus a new
subsection stating the no-new-migration boundary explicitly. Required text (verbatim
enough to satisfy AC6's "explicitly citing definition.md's PD-10 section for that
boundary" — the exact prose is ELIXIR-DEV's to finalize, but it must state these three
facts together, in one place, not scattered):

PROVENANCE (historical, not current decision authority):

> `search/2` (REQ-042) adds definition full-text search over `process_definitions`'
> `name`/`description` columns via `ILIKE` ranking, ported from `store.zig`'s
> `Store.search()` per `src/design/definition.md`'s PD-10 section. **PD-10 states
> explicitly that search lives inside the existing store — no new Zig source file or SQL
> migration is required**, and this port adds zero new `priv/repo/migrations/` files and
> zero new indexes (no `idx_def_name`, no GIN/`tsvector` index) — the query runs against
> `process_definitions` exactly as REQ-027 shipped it.

**AC6 traceability:** the presence of this paragraph in the shipped moduledoc, verified
by TEST-DESIGNER/RELEASE-VALIDATOR reading the actual committed file rather than trusting
this design doc's own restatement of it.

---

## 11. Cross-module dependencies

| Dependency | Used for |
|---|---|
| `Letflow.Definitions.ProcessDefinition` (REQ-027, unchanged) | Base query source (`from(d in ProcessDefinition, ...)`), field references (`d.name`, `d.description`, `d.created_at`) |
| `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` (REQ-025, unchanged) | `opts[:prefix]` format validation (§4 V2), identical call every other `Letflow.Definitions` function already makes |
| `Letflow.Repo` (unchanged) | `Repo.all(query, prefix: schema_name)` |
| `Ecto.Query` (`import Ecto.Query`, already imported at the top of `definitions.ex`) | `from/2`, `where/3`, `select/3`, `order_by/3`, `limit/2`, `offset/2`, `fragment/1` |

No new dependency is introduced. No change to any other module.

---

## 12. Acceptance-criteria traceability (REQ-042's 6, `requirements.yaml:2044-2049`)

| # | Acceptance criterion | Design element |
|---|---|---|
| 1 | Exact name match ranks above partial-name match ranks above description-only match | §5's `CASE` expression (`3.0`/`2.0`/`1.0`) + `ORDER BY rank DESC` |
| 2 | Empty query → `QueryEmpty`-equivalent error, not an empty list | §4 V0 → `{:error, :query_empty}` |
| 3 | Query > 512 chars → `QueryTooLong`-equivalent error | §4 V1 → `{:error, :query_too_long}` |
| 4 | No match anywhere → empty list, not an error | §8 — `Repo.all/2`'s own zero-row behavior, no special branch |
| 5 | `limit` (default 20) / `offset` pagination, two successive calls covering more rows than one page | §7 — `effective_limit`/`effective_offset` defaults + `limit/2`/`offset/2` |
| 6 | Moduledoc states no new migration/table added, citing `definition.md`'s PD-10 section | §10 — required moduledoc text, §9 INV-SR-1 |

This task's own 11 acceptance criteria (handoff `step-01-code-designer.json`) are each
also addressed: signature (§3), two distinct validation-error shapes (§4), ILIKE
safety (§6), pagination behavior including the deliberate no-clamp divergence (§7),
no-match → empty list (§8), no-new-migration constraint (§9 INV-SR-1, §10),
tenant-scoping via the established `opts[:prefix]` pattern (§3, §4 V2, §9 INV-SR-3), and
no implementation code anywhere in this document (every code-shaped block above is
either a `@type`/`@spec` declaration or prose describing Ecto query *structure*, not a
literal executable pipeline).

---

## 13. Open questions

- **OQ-1 — Byte length vs. grapheme count for the 512-char limit (§4 V1).** This design
  uses `byte_size/1` (matching `fetch_name/1`/`fetch_version/1`'s existing precedent in
  the same module), so a query built from multi-byte UTF-8 characters hits the ceiling
  before 512 visible characters. REQ-042's description says "512 characters" without
  specifying byte-vs-grapheme — not resolved definitively here, flagged for
  TEST-DESIGNER/REVIEWER to confirm this interpretation matches R-Co's own Zig `.len`
  semantics (byte length in Zig for a `[]const u8` slice) if a stricter check turns out
  to matter.
- **OQ-2 — `:limit`/`:offset` of `0`, negative, or non-integer values.** §7 states these
  pass through to `Ecto.Query.limit/2`/`offset/2` unclamped and unvalidated by this
  function (REQ-042 explicitly assigns range rejection to S4). A negative integer would
  raise at the Postgres driver level (`Ecto.QueryError` or a raised Postgrex error) since
  `LIMIT`/`OFFSET` require non-negative integers — this design does not add a guard
  against that, since no acceptance criterion exercises it and REQ-042's own text frames
  out-of-range handling as S4's job. Flagged rather than silently assumed safe.
- **OQ-3 — Whitespace-only query (§4 V0).** Passes the `byte_size > 0` empty-check and
  proceeds to the DB query, where it will almost always produce a zero-row/no-match
  result (§8) rather than an error. Not treated as a defect here — flagged in case a
  future acceptance criterion specifically exercises `search("   ", ...)` and expects
  `:query_empty` rather than an empty list.
