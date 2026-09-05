PROVENANCE (historical, not current decision authority):
# Design: REQ-034 — Definition export/import (`export_import.zig`, PD-09)

**Requirement:** REQ-034 (`docs/requirements.yaml`, stage S2, `depends_on: [REQ-030]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ034-20260817`, WF-02 Step 1
**This document produces:** module/file layout, the `ExportDocument` struct shape,
`export/2`/`import/3` signatures and error taxonomy, the graph round-trip-fidelity
mechanism, invariants, and open questions — **no implementation code**. No function
bodies, no `.ex` files. `@type`/`@spec` blocks below are type signatures only (the
convention `req025-event-append.md` §0 established and `req030-…md`/`req041-…md`
both reuse) — ELIXIR-DEV writes the real bodies at Step 2a.

---

## 0. Sources read for this design

**Letflow project docs, read in full:**

- `docs/requirements.yaml` — REQ-034's full entry (title, description, all 4
  acceptance criteria, `depends_on: [REQ-030]`), and REQ-030/028/029's entries for
  cross-reference.
- `docs/guides/backend_developer_guide.md` §3.1 (naming), §3.5 (error shapes — every
  `@spec` states its error shape explicitly), §3.6 (SQL parameterization — N/A here,
  no new query), §5 (multi-tenancy, schema-per-tenant, `docs/migration/decisions/
  0003-ecto-schema-strategy.md`).
- `docs/migration/decisions/0003-ecto-schema-strategy.md`'s 2026-08-17 addendum — the
  `tenant_id`-derivation mechanism (`tenant_id_for_schema_name/1`, never accept a
  caller-supplied `tenant_id`). This module never derives `tenant_id` itself — it has
  no direct DB access at all; `Letflow.Definitions.create/2` and `get_by_id/2` (both
  already shipped, REQ-030) own that derivation. Recorded here only to confirm this
  design doesn't need to re-derive it.
- `docs/migration/stage-2-event-store-definitions.md` — confirms REQ-034/PD-09's place
  in the S2 definition-store surface, no additional constraint beyond what REQ-030/
  028/029's own design docs already settled.
- `docs/anti-patterns.md` — no entry directly applicable to this module's own
  construction.
- `lib/letflow/design/req030-definition-store-crud.md` — **read in full (959
  lines)**. §4.0 (shared `opts()`/`common_error()` types, reused here by reference,
  not redefined), §4.1 (`create/2`'s exact 13-phase pipeline — P0 rejects
  `:tenant_id`, P1 rejects `:status`, P3/P4 validate name/version, P6/P7/P8/P9 run
  graph-structure/`validate_graph/1`/`validate_node_attributes/1`/
  `validate_edge_conditions/1` in that order, P10/P11 cast the **original, unmodified
  `attrs[:graph]` map** — never the struct-converted form — into the changeset and
  insert it). This last point is load-bearing for this design's round-trip-fidelity
  claim (§4.3 below). §4.2 `get_by_id/2`'s exact signature and `{:error, :not_found}`
  contract, reused verbatim by `export/2`.
- `lib/letflow/design/req028-graph-structural-validator.md` /
  `req029-node-attribute-edge-condition-validators.md` — confirm `create/2`'s
  delegate calls (`Graph.validate_graph/1`, `validate_node_attributes/1`,
  `validate_edge_conditions/1`) already re-run on every write through `create/2`
  with no caller-supplied bypass flag anywhere in `create_attrs()` — this is why
  `import/3` needs no validator calls of its own (§4.3, INV-EI-2).
- `docs/agents/instructions/security-invariants.md` — INV-1 (tenant isolation — this
  module never accepts or forwards a `tenant_id`), INV-8 (every external-I/O path
  returns a typed result — `export/2`/`import/3` both do, no unresolved `{:ok, _} =`
  match).

**Letflow shipped code, read directly (not assumed):**

- `lib/letflow/definitions.ex` — **read in full (819 lines)**. Confirms `create/2`
  (line 330), `get_by_id/2` (line 354), `create_attrs()`/`create_error()`/`opts()`/
  `common_error()` types (lines 90–130), and that `insert_definition/3` (line 536)
  casts `attrs[:graph]` — the caller-supplied map, never `graph_struct_from_map/1`'s
  output — directly into `ProcessDefinition.create_changeset/2`. This is the exact
  mechanism this design's `import/3` relies on for byte-for-byte graph fidelity.
- `lib/letflow/definitions/process_definition.ex` — **read in full (150 lines)**.
  Confirms the `process_definitions` schema's field list (`tenant_id`, `name`,
  `version`, `description`, `status`, `stage`, `graph`, `created_by`, `archived_at`,
  `created_at`/`updated_at`), and that `create_changeset/2`'s cast list has no `:id`
  (the `@primary_key {:id, :binary_id, autogenerate: true}` always assigns a fresh id
  — confirms AC2 is satisfiable with zero extra code in this module: simply never
  including `document.id` in the attrs passed to `create/2` is sufficient).
- `lib/letflow/definitions/graph.ex` — **read relevant sections (moduledoc,
  `Node`/`Edge`/`Violation` struct defs, `t()` type, `graph_struct_from_map/1`)**.
  Confirms `process_definitions.graph` (and therefore `create_attrs[:graph]`) is a
  **string-keyed** `%{"nodes" => [...], "edges" => [...]}` map — the same shape
  Postgres/Postgrex decodes jsonb into and the same shape `graph_struct_from_map/1`
  expects — never `Letflow.Definitions.Graph.t()`'s struct form. This is why
  `ExportDocument.graph`'s type is `map()`, not `Letflow.Definitions.Graph.t()`.

---

## 1. Scope boundary

**In scope (per REQ-034's description and 4 acceptance criteria):**
- `EXPORT_SCHEMA_VERSION` constant, `"bpm/definition/v1"`.
- `export/2`: reads one `process_definitions` row (via REQ-030's `get_by_id/2`) and
  serializes it into an `ExportDocument` struct.
- `import/3`: given an `ExportDocument`, generates a brand-new definition via REQ-030's
  `create/2` — re-running REQ-028/029's validators with no bypass — rejecting a
  schema-version mismatch with a distinct error before anything else happens.
- The `ExportDocument` struct type itself (a plain struct, not an `Ecto.Schema` — no
  new DB table backs it, mirroring `Letflow.Definitions.Graph`'s own plain-struct
  precedent for values that exist only in memory).

**Out of scope (not claimed by REQ-034's text, not built here — see §7 Open
questions for what this implies):**
- Any JSON (de)serialization of `ExportDocument` to/from a wire format (string, HTTP
  body, file). REQ-034's acceptance criteria describe an in-Elixir-term round trip
  (`export/2`'s return value compared against what `import/3` consumes) — no function
  named for "encode to JSON string" or "parse JSON string" appears anywhere in the
  requirement text.
- Any new `priv/repo/migrations/*.exs` file — REQ-034 reuses REQ-027's
  `process_definitions` table exactly as REQ-030 already reads/writes it. No new
  table, column, or index.
- Any HTTP/API route exposing export/import — no route requirement exists yet for
  this surface (S2 is DB/domain-logic only per `docs/migration/stage-2-…md`).

---

## 2. Module and file layout

```
lib/letflow/definitions/export_import.ex
  defmodule Letflow.Definitions.ExportImport do
    @export_schema_version "bpm/definition/v1"

    defmodule ExportDocument do
      # nested, per Letflow.Definitions.Graph's Node/Edge/Violation precedent —
      # has no meaning or reuse outside definition export/import.
    end

    # export/2, import/3, and their private pipeline helpers.
  end
```

One file, mirroring `graph.ex`'s single-file-with-nested-struct-modules shape rather
than `process_definition.ex`'s separate-file shape — `ExportDocument` is a transient,
in-memory value with no independent identity outside this module's two public
functions, same relationship `Graph.Node`/`Graph.Edge`/`Graph.Violation` have to
`Graph`.

---

## 3. `EXPORT_SCHEMA_VERSION`

```
@export_schema_version "bpm/definition/v1"
```

A module attribute, not a public function — nothing in REQ-034's acceptance criteria
requires it to be queryable from outside this module. `import/3`'s schema-version
check (§4.3 step 1) compares against this literal.

---

## 4. Function signatures

### 4.0 Shared types (reused by reference, not redefined)

```
@type opts :: Letflow.Definitions.opts()
  # [prefix: String.t()] -- REQ-030's own type, reused verbatim.

@type common_error :: Letflow.Definitions.common_error()
  # {:error, :invalid_schema_name} | {:error, {:transaction_failed, term()}}
```

### 4.1 `ExportDocument` — the struct itself

```
defmodule ExportDocument do
  @enforce_keys [:bpm_export_schema_version, :id, :name, :version, :graph, :exported_at]
  defstruct [
    :bpm_export_schema_version,
    :id,
    :name,
    :version,
    :description,
    :graph,
    :exported_at
  ]

  @type t :: %__MODULE__{
    bpm_export_schema_version: String.t(),
      # the value EXPORT_SCHEMA_VERSION had at export time -- "bpm/definition/v1"
      # for every document this module itself produces; a document constructed
      # elsewhere (a future JSON-decode boundary, out of scope here per §1) could
      # carry a different, stale, or malformed value -- exactly what import/3's
      # step 1 checks for.
    id: Ecto.UUID.t(),
      # the SOURCE definition's id. Informational only -- per REQ-034's own text,
      # "NOT reused as the imported row's primary key." import/3 never reads this
      # field when building create_attrs() (INV-EI-1).
    name: String.t(),
    version: String.t(),
    description: String.t() | nil,
    graph: map(),
      # string-keyed %{"nodes" => [...], "edges" => [...]} -- the EXACT value
      # read from process_definitions.graph, never converted to
      # Letflow.Definitions.Graph.t()'s struct form and never re-encoded. See §4.3
      # (export) and §4.4 (import) -- INV-EI-3 is this field's whole reason for
      # existing in this shape.
    exported_at: String.t()
      # ISO8601 UTC, e.g. "2026-08-17T20:31:20.123456Z" -- see §7 OQ-2 for the
      # precision question this design leaves open.
  }
end
```

**`stage` is deliberately absent from this struct.** REQ-034's description names
exactly 7 `ExportDocument` fields (`bpm_export_schema_version, id, name, version,
description, graph, exported_at`) — `stage` is not among them, even though
`process_definitions.stage` exists (REQ-027/030). This design does not add it
silently; see INV-EI-5 (§5) and §7 OQ-... — actually not an open question, this is a
literal requirement-text match, recorded as a deliberate, flagged omission, not
guessed.

### 4.2 `export/2` (PD-09 export path)

```
@type export_error :: {:error, :not_found} | common_error()

@spec export(id :: Ecto.UUID.t(), opts :: opts()) ::
  {:ok, ExportDocument.t()} | export_error()
```

Pipeline:

1. **E0 — fetch.** `Letflow.Definitions.get_by_id(id, opts)` →
   `{:ok, %Letflow.Definitions.ProcessDefinition{}}` | `{:error, :not_found}` |
   `common_error()`. Both error shapes propagate unchanged — this function invents no
   new error atom of its own on the read path.
2. **E1 — serialize (only on `{:ok, definition}`).** Build:
   ```
   %ExportDocument{
     bpm_export_schema_version: @export_schema_version,
     id: definition.id,
     name: definition.name,
     version: definition.version,
     description: definition.description,
     graph: definition.graph,       # passed through unmodified -- INV-EI-3
     exported_at: <current UTC instant, ISO8601-formatted>
   }
   ```
   `name`, `version`, `description` are copied verbatim — no trimming, casing, or
   normalization (AC1's "preserved exactly" extends to these three fields as well as
   `graph`, per the requirement's own description text).
3. Returns `{:ok, document}`.

`export/2` performs **zero writes** — read-only, same read-only contract
`get_by_id/2` itself already has.

### 4.3 `import/3` (PD-09 import path)

```
@type import_error ::
  {:error, {:unknown_schema_version, actual :: String.t()}}
  | Letflow.Definitions.create_error()
    # {:error, :tenant_id_not_accepted}
    # | {:error, :initial_status_not_draft}
    # | {:error, :name_invalid}
    # | {:error, :version_empty}
    # | {:error, :graph_structure_invalid}
    # | {:error, {:graph_validation_failed, [Letflow.Definitions.Graph.Violation.t()]}}
    # | {:error, :duplicate_name_version}
    # | {:error, Ecto.Changeset.t()}
    # | common_error()
    # -- the :tenant_id_not_accepted / :initial_status_not_draft branches are
    # structurally unreachable via THIS function (import/3's own attrs builder,
    # step 2 below, never includes a :tenant_id or :status key) but are retained in
    # the type because they are real variants of create/2's actual return type,
    # which this function passes through wholesale rather than narrowing --
    # narrowing here would require this module to duplicate create/2's own
    # reasoning about which branches are reachable, which is exactly the kind of
    # validation-logic duplication INV-EI-2 exists to avoid.

@spec import(document :: ExportDocument.t(), imported_by :: Ecto.UUID.t(), opts :: opts()) ::
  {:ok, Letflow.Definitions.ProcessDefinition.t()} | import_error()
```

**`imported_by` is this design's own addition — not named anywhere in REQ-034's
text.** `create/2`'s `create_attrs()` type requires `:created_by` (`Ecto.UUID.t()`,
`required`), and `ExportDocument` (§4.1) carries no creator-identity field at all (by
design — the importing actor is not the original definition's creator, and REQ-034
never discusses one). Without a caller-supplied identity, `import/3` would have no
value to satisfy `create/2`'s `required(:created_by)` key and would either have to
invent a sentinel UUID (a guess, forbidden) or fail unconditionally (defeats the
requirement). Adding a required third parameter is the only non-guessing resolution;
flagged explicitly here rather than silently added. See §7 OQ-3 for what remains open
about who supplies it.

Pipeline:

1. **I0 — schema-version gate, first, before anything else.** `document.
   bpm_export_schema_version == @export_schema_version` → else
   `{:error, {:unknown_schema_version, document.bpm_export_schema_version}}` and stop
   — no tenant resolution, no graph validation, no DB call happens (AC4: "rejected
   with a distinct unknown-schema-version error", kept structurally distinct from
   every `create_error()` variant by running before `create/2` is ever called).
2. **I1 — build `create_attrs()`.**
   ```
   %{
     name: document.name,
     version: document.version,
     description: document.description,
     graph: document.graph,        # passed through unmodified -- INV-EI-3
     created_by: imported_by
     # no :id key (INV-EI-1), no :stage key (§4.1's "stage absent" note), no
     # :tenant_id key, no :status key.
   }
   ```
3. **I2 — delegate.** `Letflow.Definitions.create(attrs, opts)` →
   `{:ok, ProcessDefinition.t()} | create_error()`. Returned to `import/3`'s own
   caller **unchanged** — this is the whole no-bypass mechanism (AC3): every one of
   `create/2`'s own P0–P12 phases (`req030-…md` §4.1, including P7/P8/P9's
   `validate_graph/1`/`validate_node_attributes/1`/`validate_edge_conditions/1` calls)
   runs exactly as it would for a hand-built `create/2` call. `import/3` adds no
   graph-related check of its own before or after this delegation.

**AC2 traceability:** step I1 never includes `document.id`. Combined with
`ProcessDefinition`'s `@primary_key {:id, :binary_id, autogenerate: true}` and
`create_changeset/2`'s cast list (which has no `:id` entry — confirmed directly, §0),
the imported row's `id` is always freshly assigned, with **zero dependency on whether
`document.id` happens to collide with an existing row's id in the target tenant** —
there is no code path by which `document.id` could ever reach the `INSERT`, so the
"even when it already exists" clause is unconditionally true, not merely tested for
the common case.

---

## 5. Invariants

- **INV-EI-1 (AC2).** `import/3` never reads `document.id` when constructing
  `create_attrs()`. The imported row's `id` is always freshly assigned by `create/2`'s
  autogenerated primary key.
- **INV-EI-2 (AC3, no bypass).** `import/3` calls no function from
  `Letflow.Definitions.Graph` directly, and performs no graph/attribute/edge
  validation of its own. 100% of structural validation is delegated to `create/2`'s
  existing, already-shipped pipeline (`req030-…md` §4.1 P6–P9). A document that would
  fail `create/2` if submitted directly fails `import/3` identically, via the same
  code path, not a re-implemented parallel one.
- **INV-EI-3 (AC1, byte-for-byte round trip).** Neither `export/2` nor `import/3`
  transforms the `graph` value at any point — no re-encoding, no key reordering, no
  conversion through `Letflow.Definitions.Graph.t()`'s struct form (that conversion
  happens only transiently inside `create/2`'s own P6–P9, and per `req030-…md` §4.1
  step P10/P11, "the original, unmodified `attrs[:graph]` map is what gets cast", not
  the struct). The round-trip claim is therefore: `definition.graph` (source row) `==`
  `document.graph` (`ExportDocument`, via `export/2`) `==` `create_attrs[:graph]`
  passed to `create/2` (via `import/3`) `==` the imported row's `graph` column, with
  every `==` here being Elixir's structural/deep map equality (order-independent —
  Elixir map equality does not depend on key insertion order, so this holds
  regardless of how Postgres/Postgrex orders jsonb keys internally). See §7 OQ-1 for
  the scope boundary this claim stops at (no JSON-text-byte-order guarantee is made,
  because no JSON encode/decode step exists in this module at all).
- **INV-EI-4 (AC4).** The schema-version check (I0) runs before any other step,
  including tenant resolution — a mismatched document never reaches `create/2` and
  never produces any `create_error()` variant; its error is always
  `{:error, {:unknown_schema_version, actual}}`, structurally distinct from every
  `create_error()` tuple shape.
- **INV-EI-5.** `stage` is not part of `ExportDocument` and is not preserved across
  export/import — an imported definition's `stage` is always `nil` regardless of the
  source row's `stage` value, because REQ-034's own description enumerates
  `ExportDocument`'s fields without `stage`. Recorded explicitly so this isn't
  mistaken for an oversight during implementation or later flagged as a "regression."
- **INV-EI-6.** `name`, `version`, `description` are forwarded byte-identical from
  `document` to `create_attrs()` — no trimming, casing, or normalization performed by
  this module (any failure on these fields, e.g. an empty `name`, surfaces as
  whichever `create_error()` variant `create/2` itself already produces for that
  input — `import/3` adds no pre-check of its own here either, same no-bypass
  reasoning as INV-EI-2 applied to name/version, not just graph).
- **INV-EI-7.** `export/2` performs no writes (read-only, delegates entirely to the
  already read-only `get_by_id/2`).

---

PROVENANCE (historical, not current decision authority):
## 6. Required moduledoc text

```
@moduledoc """
Definition export/import (`Letflow.Definitions.ExportImport`), REQ-034, PD-09.
Ported from `src/definition/export_import.zig`'s `ExportImportStore`.

`export/2` serializes one `process_definitions` row (fetched via
`Letflow.Definitions.get_by_id/2`) into an `ExportDocument`. `import/3` takes an
`ExportDocument` and creates a brand-new draft definition via
`Letflow.Definitions.create/2` -- re-running every one of REQ-028/029's graph
validators with no bypass, because create/2 is the only write path this module
uses. The imported row's id is always freshly assigned; `document.id` (the source
definition's id) is carried only for informational/audit purposes and is never
read when building the create/2 call.

## No independent validation (see design doc INV-EI-2)

This module intentionally implements zero structural/attribute/edge-condition
checks of its own. A document that would be rejected by `create/2` if its graph
were submitted directly is rejected by `import/3` identically -- there is no
parallel, potentially-diverging validation path here.

## Schema-version gate runs first

`import/3` checks `document.bpm_export_schema_version` against
`@export_schema_version` ("bpm/definition/v1") before touching tenant resolution,
graph validation, or the database -- a mismatch returns
`{:error, {:unknown_schema_version, actual}}`, never conflated with a generic
`create/2` validation failure.
"""
```

---

## 7. Cross-module dependencies

- **`Letflow.Definitions.get_by_id/2`** (REQ-030, shipped) — `export/2`'s sole read
  path.
- **`Letflow.Definitions.create/2`** (REQ-030, shipped) — `import/3`'s sole write
  path; transitively re-runs `Letflow.Definitions.Graph.validate_graph/1`,
  `validate_node_attributes/1`, `validate_edge_conditions/1` (REQ-028/029, shipped)
  with no bypass.
- **`Letflow.Definitions.ProcessDefinition`** (REQ-027, shipped) — the schema/type
  both `export/2`'s input (via `get_by_id/2`'s return) and `import/3`'s output (via
  `create/2`'s return) carry.
- **`Letflow.TenantProvisioning.tenant_id_for_schema_name/1`** — **not called
  directly by this module.** Both `get_by_id/2` and `create/2` already call it
  internally against `opts[:prefix]`; `ExportImport` only forwards `opts` unchanged.
- No dependency on `Letflow.Definitions.Graph` directly (INV-EI-2) — the only
  reference to it in this document is the `Graph.Violation.t()` type appearing
  inside the passed-through `create_error()` union.

---

## 8. Open questions — not silently resolved

- **OQ-1 (scope of "the document").** REQ-034's acceptance criteria describe an
  in-Elixir-term round trip only — `export/2`'s return value compared against what
  `import/3` consumes, both as `ExportDocument.t()` structs within the same running
  system (or at least the same Elixir term space). No function for encoding an
  `ExportDocument` to a JSON string, or parsing one back, is named anywhere in
  REQ-034's text, and this design does not add one. If a later requirement (e.g. an
  export/import HTTP route, S8-adjacent) needs `ExportDocument` to cross a process or
  network boundary as JSON text, that requirement will need to specify: (a) which
  JSON encoder/decoder, (b) whether `graph`'s nested string-keyed shape survives a
  decode with `keys: :atoms` vs `keys: :strings` cleanly (it must stay string-keyed
  to remain compatible with `create/2`'s `graph_struct_from_map/1` expectations —
  decoding the OUTER `ExportDocument` fields as atoms while leaving the INNER `graph`
  value string-keyed is a real, easy-to-get-wrong distinction), and (c) whether
  INV-EI-3's "byte-for-byte" claim needs re-verification against that encoder's
  determinism (Elixir map equality, which this design relies on, is order-independent
  and says nothing about serialized-JSON-text byte order). Left open — not guessed.
- **OQ-2 (`exported_at` precision).** REQ-034 says "ISO8601 UTC" but not what
  precision. This design uses `DateTime.utc_now/0`'s native precision (currently
  microsecond) formatted via `DateTime.to_iso8601/1`, un-truncated, since no
  acceptance criterion constrains it and `exported_at` is not part of the
  round-trip-fidelity claim (only `graph`, per AC1's literal wording, is). If
  TEST-DESIGNER needs deterministic comparison (e.g. injecting a fixed clock), that
  should be resolved before Step 2a, not decided ad hoc during implementation.
- **OQ-3 (`imported_by`'s source).** This design adds a required `imported_by ::
  Ecto.UUID.t()` parameter to `import/3` (§4.3) to satisfy `create/2`'s required
  `:created_by` key, since `ExportDocument` carries no creator identity and REQ-034's
  text never discusses one. Whether the eventual caller (a future API layer) always
  has a real authenticated user id available, or whether some import paths are
  system/automation-triggered with no natural `Ecto.UUID.t()` identity, is not
  addressed by REQ-034 and this design does not invent a default (e.g. a sentinel
  "system" UUID) — left for whichever requirement adds the calling layer.
- **OQ-4 (no extra duplicate-content check).** REQ-034's acceptance criteria ask only
  that `import/3` be rejected "the same way `create/2` rejects an invalid graph
  directly" — this design does not add any check beyond what `create/2` already
  performs (e.g. no attempt to detect "this content already exists under a different
  name/version" beyond `create/2`'s existing `uq_definition_version`-driven
  `{:error, :duplicate_name_version}`). Flagged so ELIXIR-DEV doesn't add one
  unprompted and TEST-DESIGNER doesn't look for coverage of a check that isn't part
  of this design.

---

## 9. DB tables/columns touched

**None new.** REQ-034 adds no migration. `export/2` reads, and `import/3`
transitively writes (via `create/2`), the `process_definitions` table exactly as
REQ-027 (`lib/letflow/design/req027-definition-core-schema.md`) defined it and REQ-030
already CRUDs it — no new column, index, or constraint.

---

## 10. Acceptance-criteria traceability

| REQ-034 acceptance criterion | Design element |
|---|---|
| "export/1 on an existing definition produces a document whose graph field round-trips byte-for-byte comparable back through import/1's graph field" | §4.2 step E1 (`graph: definition.graph`, unmodified) + §4.3 step I1 (`graph: document.graph`, unmodified) + INV-EI-3 (§5), backed by `req030-…md`'s confirmed P10/P11 (`create/2` casts the original unmodified map, never the struct form) |
| "import/1 always assigns a new id distinct from the source document's id field, even when the source id happens to already exist as a definition in the target tenant" | §4.3 step I1 (no `:id` key ever built into `create_attrs()`) + INV-EI-1 (§5), backed by `ProcessDefinition`'s `autogenerate: true` primary key and `create_changeset/2`'s `:id`-free cast list (confirmed §0) |
| "import/1 on a document with a graph that fails REQ-028's validateGraph() is rejected the same way REQ-030's create/1 rejects an invalid graph directly -- no bypass path" | §4.3 step I2 (unconditional delegation to `create/2`, error passed through unchanged) + INV-EI-2 (§5) — `import_error()`'s `create_error()` branch includes `{:error, {:graph_validation_failed, violations}}` verbatim |
| "import/1 on a document whose bpm_export_schema_version is not \"bpm/definition/v1\" is rejected with a distinct unknown-schema-version error" | §4.3 step I0 (`{:error, {:unknown_schema_version, actual}}`, checked first, before any `create/2` call) + INV-EI-4 (§5) |

Every acceptance criterion maps to a concrete, already-specified design element above
— no "TBD".
