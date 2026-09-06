# Design: REQ-202 — Content-addressed artifact repository and the REPO-04 canonicaliser

**Requirement:** REQ-202 (`docs/requirements.yaml:11158-11302`, stage S6,
`depends_on: [REQ-036, REQ-072, REQ-067]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ202-20260830`, WF-02 Step 1
**This document produces:** two Ecto schema shapes, one migration's full table/index/
constraint/trigger spec, a new canonicaliser module's public `@spec`s and canonical-form
rules, `create/2`'s contract, the DB-level immutability mechanism, and the version-history
pagination contract. **No implementation code** — no function bodies, no `.ex`/`.exs`
file contents, no literal SQL. ELIXIR-DEV writes those from this document at Step 2a.

**Convention basis:** structural sibling of `req195-audit-entry-storage.md` (DB-level
immutability via a per-tenant-schema trigger — copied directly, §5 below) and
`req041-pack-update-diff-schema.md` (global-vs-per-tenant placement reasoning discipline,
`Ecto.Enum`, cited migration precedent). Diverges from `req041` on placement: this design
concludes **per-tenant**, not global — see §2.

---

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-202's full entry, read in full (not paraphrased):
  description and all 14 acceptance criteria.
- `docs/agents/instructions/core-directives.md`, `docs/agents/workflows/WF-02_requirement_implementation.md`
  Step 1, `docs/anti-patterns.md`, `CLAUDE.md`.
- `docs/migration/decisions/0003-ecto-schema-strategy.md` in full — Decision A
  (Ecto-idiomatic redesign, `binary_id`, `Ecto.Enum`), Decision B (schema-per-tenant via
  `:prefix`, `tenant_id` retained intra-schema as a query-predicate discipline, chosen
  specifically for its blast-radius-containment property — "a bug that forgets a
  `tenant_id` predicate ... fails loudly ... instead of silently leaking rows across
  tenants"), Decision C (event-table immutability is an application-layer concern for
  event tables specifically — **not directly applicable here**: `repository_artifacts`
  is a content-addressed blob store, not an event-store table, and REQ-202's own AC7
  demands DB-level rejection "not merely absent from the context API," the same
  standard `req195-audit-entry-storage.md` applies to `audit_entries`, so this design
  follows req195's trigger precedent rather than Decision C's application-layer one).
- `lib/letflow/definitions/promotion_digest.ex` — read in full. Confirmed directly
  from source (not taken on the requirement's paraphrase alone): `canonicalize/1`
  (private, L87-104) sorts map keys via `Enum.sort/1` on `Map.keys/1`, rebuilds as
  `Jason.OrderedObject.new/1`, maps lists element-wise without sorting, stringifies
  non-boolean/non-nil atoms via `Atom.to_string/1`, and — the load-bearing fact —
  **passes every other value through unchanged at the final clause
  (`defp canonicalize(value), do: value`), including numbers.** There is no number
  normalization anywhere in this module: an integer-valued float (e.g. `2.0`) and the
  bare integer `2` are never unified, because `canonicalize/1` never inspects numeric
  values at all. This directly confirms the requirement's own claim (its description
  cites "L88-104... passes every number through UNCHANGED") — no contradiction found,
  so the requirement's paraphrase is corroborated rather than merely trusted. See §4.1
  for why this makes a shared module impossible without breaking REQ-036's INV-PRM-5.
- `docs/requirements.yaml` REQ-041's entry (`solution_pack_artefact_bases`) — confirmed
  GLOBAL, install-tracking, three-way-diff table; confirmed it neither reads nor writes
  `repository_artifacts`/`artifact_versions` and vice versa. See §7.
- `docs/requirements.yaml` REQ-067's entry (`Letflow.Api.Pagination`, done, S4) and
  `lib/letflow/api/pagination.ex` (shipped) — read for the exact cursor contract: module
  constants `max_page_size/0` (200), `default_page_size/0` (50), `min_page_size/0` (1),
  `cursor_expiry_us/0` (86_400_000_000); `Cursor`/`Page` sub-structs; `page_response/2`;
  `encode_cursor/1`/`decode_cursor/4`; `build_raw_cursor_timestamp_key/4` (the
  `(timestamp, key)`-keyed cursor shape used by every other list endpoint in this
  codebase, e.g. `Letflow.Definitions.list_paginated/2`). §6 below reuses this contract
  verbatim rather than inventing a parallel one.
- `lib/letflow/design/req195-audit-entry-storage.md` §2 — read in full as the direct
  precedent for DB-level immutability: a per-tenant-schema-qualified trigger function
  that unconditionally raises a fixed-text error, wired as both `BEFORE UPDATE` and
  `BEFORE DELETE` triggers, created inside the same `if prefix() do ... end`-guarded
  migration block as the table (no shared `public`-schema function, per Decision B's
  physical-isolation model — no cross-schema function reference). Copied into §5 with
  the artifact-specific message text.
- `lib/letflow/design/req041-pack-update-diff-schema.md` §0/§"placement" — read for the
  GLOBAL-table precedent shape (`solution_pack_installs.tenant_id` FK to `tenants.id`,
  no per-schema replication) as the contrasting option this design explicitly rejects
  in §2.
- PROVENANCE (historical, not current decision authority):
  **R-Co source (`migrations/045_repository_artifacts.sql`,
  `migrations/058_repo_artifacts_tenant_activation.sql`, `src/repository/artifacts.zig`,
  `canonicaliser.zig`) is unreachable from this drafting session** — same
  environment constraint every prior REQ-036/REQ-041/REQ-195 design records. This design
  relies entirely on REQ-202's own `description`/`acceptance_criteria` text, which the
  requirement's own header states was pre-verified against real R-Co source before
  drafting (line count, import graph, migration-058-vs-045 shape conflict, `canonicaliser.zig`
  L32/L121-123 number-normalization behavior). Flagged per this project's own
  citation-discipline convention (`req041`'s §0 sets this precedent) — CODE-DESIGN-VALIDATOR
  and REVIEWER should know this design's canonicalisation-rule and migration-058 claims
  are one level removed from the R-Co source file, verified only via the requirement
  text's own internal citations, not by this session reading `canonicaliser.zig` directly.

---

## 1. Placement decision — per-tenant, not global

**Decision: both `repository_artifacts` and `artifact_versions` are per-tenant-schema
tables (`prefix: prefix()`, Decision B), following the default rather than diverging
from it. No REVIEWER sign-off flag is raised.**

### 1.1 The tension, stated explicitly (per the requirement's own instruction)

`repository_artifacts.content_hash` is the dedup mechanism: identical content produces
one row by construction (primary key = content_hash). Dedup only spans tenants if the
table is global — a global table means tenant A's uploaded bytes and tenant B's
uploaded bytes physically share one row whenever their content happens to match.
R-Co's own schema effectively made the store global (`repository_artifacts` in R-Co's
045/058 migrations carries no `tenant_id` column at all; only R-Co's activation table
does), so R-Co's actual behavior is: identical artifact content across two unrelated
tenants is deduplicated into one shared physical row.

### 1.2 Why Letflow does not follow R-Co here

1. **No acceptance criterion in REQ-202 requires cross-tenant dedup.** AC1 (REPO-01's
   test) reads "creating two artifacts with byte-identical JSON content produces ONE
   repository_artifacts row and two artifact_versions rows referencing the same
   content_hash" — this is satisfiable entirely *within* one tenant's schema. Nothing
   in the 14 acceptance criteria exercises or asserts cross-tenant sharing. Choosing
   per-tenant placement does not fail any stated acceptance criterion.
2. **Decision 0003 Decision B's own stated reasoning is a physical-isolation argument,
   not a storage-efficiency one** — "a bug that forgets a `tenant_id` predicate ...
   fails loudly ... instead of silently leaking rows across tenants." A global content
   store built specifically so two tenants' bytes can occupy the same physical row is
   the isolation model Decision B's reasoning argues against, not a neutral variant of
   it: even though reading one's own artifact never returns another tenant's row (the
   version pointer is what a caller queries, and the content row is opaque bytes keyed
   by hash), the row-level fact "tenant A's content and tenant B's content are the same
   Postgres row" is a physical-isolation property Decision B was adopted specifically
   to avoid creating anywhere in the schema, and R-Co's own migration 058 (see §3)
   shows R-Co itself later moved toward tenant-scoping this subsystem (adding a
   tenant-scoped activation table on top of the global content store) rather than away
   from it — weak evidence that even R-Co's own trajectory was toward, not away from,
   tenant-scoping this area.
3. **Cross-tenant content collisions are not a realistic efficiency win for this
   artifact kind set** (`definition`, `form`, `schema`, `service_catalog`, `script`,
   `module`, `scenario` — R-Co's own enumerated values). These are tenant-authored
   configuration/business-logic artifacts, not commodity assets (e.g. stock images or
   shared libraries) where cross-tenant byte-identical collisions would be common and
   the storage savings material. Two tenants independently authoring byte-identical
   JSON process definitions is a coincidence, not a workload pattern this store needs
   to optimize for.
4. **Symmetry with every other S6 requirement's placement precedent.** `req195`
   (audit_entries), `req027` (definitions) and the REQ-072 tenant-resolution machinery
   this requirement depends on are all per-tenant. Going global here would be the S6
   batch's only unforced divergence from Decision B, and the requirement's own text
   frames global as something to justify with "an R-Co-grounded reason," not adopt by
   default merely because R-Co happened to land there once.

### 1.3 Consequence, stated explicitly (as the acceptance criterion requires)

Dedup (REPO-01) is **per-tenant only**: two tenants each submitting the same JSON
content each get their own `repository_artifacts` row (in their own schema), each
correctly deduplicated against their own prior submissions, but not against each
other's. This is a deliberate forfeiture of cross-tenant storage efficiency in favor of
preserving Decision B's isolation property uniformly across the schema. Because this
follows Decision B rather than diverging from it, **no REVIEWER sign-off flag is
raised** — the sign-off requirement in REQ-202's text is conditioned on going global,
which this design does not do.

### 1.4 Both tables carry `tenant_id`

Per Decision B, both tables retain a `tenant_id` column as the intra-schema
query-predicate/reporting discipline even though the Postgres schema (`:prefix`) is the
actual isolation boundary — same pattern every other per-tenant table in this codebase
follows (`req195`, `req027`). Per the 0003 addendum, the writing context module derives
`tenant_id` from the resolved `:prefix` it is already writing into (via
`Letflow.TenantProvisioning`'s reverse mapping), never accepted as a separately-trusted
caller-supplied field.

---

## 2. Migration — one shape only, migration-058's conflict recorded

PROVENANCE (historical, not current decision authority):
**Letflow ships exactly one shape for `repository_artifacts`: R-Co migration 045's
shape** — the one `src/repository/artifacts.zig` actually codes against, per the
requirement's own verification. R-Co's migration 058
(`058_repo_artifacts_tenant_activation.sql`) re-creates `repository_artifacts` with a
conflicting shape (`version_id` as primary key rather than `content_hash`,
`content_hash` typed `TEXT` rather than `BYTEA`, an inline `content_json` column, no
`byte_size`/`content_type` columns) guarded by `CREATE TABLE IF NOT EXISTS`, meaning
which shape a given R-Co database actually has depends on migration-application order
and prior database state — a real defect in R-Co's own migration history, not a design
choice to reproduce. **This must not be ported.** Letflow has one migration file
defining `repository_artifacts` once, in migration-045's shape, and the moduledoc for
whichever module owns this schema must state this divergence was found and which shape
was chosen, in these terms, so a later reader does not "helpfully" reconcile the two
R-Co shapes by re-adding 058's columns. (This moduledoc statement is AC11's own
requirement — see §3.2's parallel moduledoc-cross-reference discipline — and is
distinct from the migration-file comment required immediately below for AC10.)

**AC10's separate, migration-file-level requirement.** AC10 requires that "the two
tables' placement (per-tenant vs. global) is stated in the migration with its reason" —
this is a requirement on the migration file itself, checkable from the migration
source, not on this design document or on a module's moduledoc (that is AC11's
requirement, above, and it covers a different fact: the 058-vs-045 shape conflict, not
the placement decision). Accordingly: **the migration file that creates
`repository_artifacts` and `artifact_versions` must carry a comment, placed at the top
of the migration (SQL comment / Ecto-migration-level comment, exact mechanical form
left to ELIXIR-DEV at Step 2a), stating, in condensed form:**

- Both tables are created **per-tenant** (schema-per-tenant via `prefix()`), not global.
- The reason: Decision B's blast-radius-containment rationale (a per-tenant table means
  a query that forgets a `tenant_id`/schema-prefix predicate fails loudly rather than
  silently leaking rows across tenants — see `0003-ecto-schema-strategy.md` Decision B);
  no acceptance criterion of REQ-202 requires cross-tenant content deduplication, so
  Decision B's isolation argument is not outweighed by any requirement-driven need for a
  shared, global content-addressed store; see §1 of this design document for the full
  reasoning this comment condenses.

This comment is what makes AC10 satisfiable by inspecting the migration file alone,
independent of this design document's continued existence — §1 below states the full
reasoning that the migration comment must condense, not duplicate in full.

### 2.1 `repository_artifacts`

Per-tenant schema (`prefix: prefix()`), one migration file guarded the same way every
other per-tenant migration in this codebase is (`if prefix() do ... end`, following
`req195`/`req027`'s pattern).

| Column | Type | Constraints |
|---|---|---|
| `content_hash` | `:binary` | **Primary key** (not `binary_id`/autogenerate — this is the SHA-256 digest of the canonical content, 32 raw bytes, computed by the canonicaliser, not generated by Postgres). `null: false` implied by PK. |
| `tenant_id` | `:binary_id` | `null: false` — Decision B intra-schema discipline (§1.4), derived at write time, not caller-supplied. |
| `content_type` | `:string` | `null: false` — e.g. `"application/json"`, `"application/wasm"`. Plain string (open set), not `Ecto.Enum` — REQ-202's text does not enumerate a closed content-type list, and constraining it would reject legitimate binary artifact kinds this requirement doesn't enumerate. |
| `byte_size` | `:bigint` | `null: false` — byte length of the stored content exactly as hashed (canonical JSON bytes for JSON content, verbatim bytes for binary content per §4.3). |
| `inserted_at` | `utc_datetime_usec` | via `timestamps/1`, `updated_at: false` (this table is never updated — see §5; an `updated_at` column that can never legitimately change is a schema smell to avoid, matching `req195`'s same reasoning for `audit_entries`). |

No `tenant_id`-scoped uniqueness constraint is needed beyond the primary key itself:
`content_hash` is already globally unique *within the tenant's own schema* by virtue of
being the primary key of a per-tenant table — two rows with the same hash cannot exist
in one tenant's schema regardless.

### 2.2 `artifact_versions`

Same per-tenant schema, same migration file (or a directly adjacent one — ELIXIR-DEV's
choice at Step 2a, not a design-level decision).

| Column | Type | Constraints |
|---|---|---|
| `version_id` | `:binary_id` | Primary key, `autogenerate: true`. |
| `tenant_id` | `:binary_id` | `null: false` — Decision B discipline, same derivation as §2.1. |
| `artifact_id` | `:binary_id` | `null: false` — per REQ-202's schema spec, a stable per-artifact identifier distinct from `version_id`; see OQ-1 for the one thing this design does not resolve about it. |
| `artifact_kind` | `Ecto.Enum`, values `[:definition, :form, :schema, :service_catalog, :script, :module, :scenario]` | `null: false` — R-Co's own enumerated kind set, ported as a closed `Ecto.Enum` per Decision A (moves the constraint from a comment into an enforced type). |
| `artifact_name` | `:string, size: 255` | `null: false`. |
| `version_number` | `:bigint` | `null: false` — sequential per `(artifact_kind, artifact_name)`, see §4.4. |
| `content_hash` | `:binary` | `null: false` — **FK to `repository_artifacts.content_hash`, `on_delete: :restrict`** (a version can never point at content that has been removed from the store; and since the store has no delete path at all per §5, this FK's `:restrict` is a defense-in-depth statement of intent more than a reachable failure mode). |
| `parent_version_id` | `:binary_id`, nullable | **Self-referencing FK to `artifact_versions.version_id`, `on_delete: :nilify_all`** — REPO-03's lineage. Nullable because a version's first submission (or any version created without an explicit parent) has none. `:nilify_all` (not `:restrict`) because deleting a parent version should not be blocked by a child pointing at it, nor should it cascade-delete the child — the child's own content is independent of its parent's continued existence; the lineage pointer simply becomes unknown. (Note: §5 makes `artifact_versions` rows themselves never subject to deletion in the API surface this requirement builds, so this FK behavior is a schema-level statement of intent, not a path this requirement's own code triggers.) |
| `created_by` | `:binary_id` | `null: false` — the acting user id. |
| `description` | `:text`, nullable | Free-text, per REQ-202's schema spec. |
| `inserted_at` | `utc_datetime_usec` | via `timestamps/1`, `updated_at: false` — a version row is never updated once created (§5.2). |

**Unique constraint:** `unique_index(:artifact_versions, [:artifact_kind, :artifact_name, :version_number], prefix: prefix())` — the database-level enforcement of "version numbers for one artifact are a gapless, non-racing sequence," per REQ-202's own schema spec. This is what actually makes concurrent `create/2` calls for the same `(artifact_kind, artifact_name)` safe: a second writer computing the same next `version_number` for the same name loses the unique-constraint race and must retry rather than silently double-assign a version number (see §4.4).

**Indexes**, following this codebase's established keyset-pagination tiebreak
convention (`req195`'s three-index list, `Letflow.Definitions.list_paginated/2`):

1. `index(:artifact_versions, [:artifact_kind, :artifact_name, desc: :version_number], prefix: prefix())` — version-history listing (§6), newest-version-first.
2. `index(:artifact_versions, [:content_hash], prefix: prefix())` — resolving which versions reference a given content row (used by any future activation/reference-counting work, e.g. REQ-203; not itself an acceptance criterion of this requirement, added for the same defense-in-depth reasoning §2.2's `content_hash` FK states).

---

## 3. The canonicaliser — a separate module, not an extension of `PromotionDigest`

### 3.1 Module identity and location

**`Letflow.Repository.Canonicaliser`**, at `lib/letflow/repository/canonicaliser.ex` —
a new, standalone module, siblings-in-namespace with wherever REQ-202's schema/context
modules land (`lib/letflow/repository/` — a new top-level namespace, distinct from
`lib/letflow/definitions/` where `PromotionDigest` lives, underscoring that these are
two unrelated subsystems that happen to both do "hash some canonical bytes").

### 3.2 Why NOT extend `Letflow.Definitions.PromotionDigest` — stated normatively for the moduledoc

The two algorithms are **not the same algorithm with different call sites** — they
disagree on a specific, behavior-changing rule:

- PROVENANCE (historical, not current decision authority):
  REPO-04 (this requirement) requires **normalised number forms**: an integer-valued
  float must serialize identically to the corresponding bare integer, with no decimal
  point and no exponent form, per the R-Co `canonicaliser.zig` behavior REQ-202's own
  text cites (L32, L121-123).
- `PromotionDigest.canonicalize/1` (confirmed directly from source, §0 above) does
  **no numeric transformation at all** — its final clause passes every non-map,
  non-list, non-atom value through completely unchanged, so `2.0` and `2` canonicalize
  and hash differently today.

Adding number normalization to `PromotionDigest.canonicalize/1` would silently change
the digest of every promotion plan already computed and stored, breaking REQ-036's
INV-PRM-5 (`verify_digest/2`'s constant-time comparison against a previously stored
digest) for every existing stored digest the moment this code shipped — a correctness
regression with no error at the call site, since `verify_digest/2` would simply start
returning `false` for plans it previously verified as `true`. This is the concrete,
mechanical reason the two canonicalisers must be separate modules rather than one
parameterized one: parameterizing `PromotionDigest` with a "normalize numbers: y/n"
flag would still require every existing caller to pass `false` forever to preserve
old digests, which is functionally identical to "don't touch this module," so a
wrapper adds indirection without buying safety `PromotionDigest`'s own immutability
doesn't already provide by not touching it.

**Required moduledoc cross-reference (binding on ELIXIR-DEV at Step 2a, checked by
CODE-DESIGN-VALIDATOR / TEST-DESIGNER):**

- `Letflow.Repository.Canonicaliser`'s moduledoc must state: "A second, deliberately
  separate canonicaliser exists at `Letflow.Definitions.PromotionDigest`
  (`lib/letflow/definitions/promotion_digest.ex`, REQ-036). That module's
  `canonicalize/1` does NOT normalize numbers — an integer-valued float and its
  corresponding integer hash differently there. This module DOES normalize numbers.
  The two must never be merged into one shared canonicalization function: doing so
  would change `PromotionDigest`'s digest output for every plan whose digest is
  already stored, breaking `verify_digest/2` (INV-PRM-5) against those stored values."
- `Letflow.Definitions.PromotionDigest`'s moduledoc must be amended (an edit, not a
  rewrite of its existing content) to add the reciprocal statement: "A second,
  separate canonicaliser exists at `Letflow.Repository.Canonicaliser` (REQ-202), which
  DOES normalize numbers, for the artifact-repository content store. This module's
  `canonicalize/1` deliberately does not, to avoid changing already-stored promotion
  digests. The two must not be merged; see `Letflow.Repository.Canonicaliser`'s
  moduledoc for the full reasoning."

**This edit to `promotion_digest.ex` is required, not optional, and is settled —
resolved now rather than deferred.** AC5 has three clauses: (i) the canonicaliser is a
separate module; (ii) `promotion_digest.ex` "is NOT modified (confirmed by `git diff
--stat`)"; (iii) "BOTH moduledocs cross-reference each other." Since
`promotion_digest.ex`'s moduledoc today contains no reference to `Canonicaliser` at
all, satisfying clause (iii)'s "BOTH... cross-reference each other" is only possible by
editing `promotion_digest.ex`'s moduledoc — there is no way for both modules'
moduledocs to cross-reference each other without touching both files. Putting the
cross-reference only on the `Canonicaliser` side (leaving `promotion_digest.ex`
untouched) would satisfy clause (ii) alone while directly violating clause (iii), since
then only one of the two moduledocs (Canonicaliser's) would reference the other, not
both — that is not a safe fallback reading of AC5, it is a different, additional AC5
violation. The only reading under which all three clauses can be simultaneously true is:
edit both moduledocs (satisfying (i) and (iii)), and read clause (ii)'s "is NOT
modified" as **"no change to `canonicalize/1`, `compute_plan_digest/1`, or
`verify_digest/2`'s behavior or specs"** — i.e. a moduledoc-only, behavior-free diff.

Since this is a moduledoc-only textual addition, not a behavior change, `git diff
--stat` will still show `promotion_digest.ex` touched by one comment-only hunk. This is
**intentional and required by AC5's own "BOTH" clause**, not a violation of AC5's "not
modified" language read correctly (behaviorally). **The commit/PR description must
state this explicitly** — that `promotion_digest.ex`'s diff is a moduledoc-only,
behavior-free addition mandated by AC5 clause (iii), with no change to
`canonicalize/1`, `compute_plan_digest/1`, or `verify_digest/2` — so a reviewer or CI
check reading `git diff --stat` and seeing `promotion_digest.ex` listed understands this
is deliberate and AC5-compliant rather than a violation to flag.

### 3.3 Public interface

A type alias `canonical_form` denotes a raw byte sequence (`binary()`): canonical JSON
text for JSON content, or the verbatim submitted bytes for non-JSON content per §3.5.

- `canonicalize_content(content_type :: String.t(), raw_bytes :: binary()) :: {:ok, canonical_form()} | {:error, :invalid_json}`
  — content-type-dispatching entry point. If `content_type` is `"application/json"`
  (or any content type this module's contract designates as JSON — see OQ-3), decodes
  `raw_bytes` with `Jason.decode/1`, applies the canonicalization rules of §3.4, and
  re-encodes; a `raw_bytes` value that fails to decode as JSON under a JSON
  `content_type` is `{:error, :invalid_json}`. For any other `content_type`, returns
  `{:ok, raw_bytes}` unchanged (byte-identity, §3.5) — always `{:ok, _}` in that branch,
  since no decoding is attempted.
- `content_hash(canonical_form()) :: binary()` — `:crypto.hash(:sha256, canonical_form)`,
  returning the raw 32-byte digest (not hex-encoded — this is what `repository_artifacts.content_hash`, typed `:binary`, stores directly, unlike `PromotionDigest.compute_plan_digest/1`'s hex-string return, which serves a different consumer: a JSON-embeddable plan-digest field, not a binary primary key).

### 3.4 Canonicalization rules (normative — a test must be able to pin each one)

1. **Object keys sorted.** Recursively, every JSON object's keys are ordered (the same
   sort discipline `PromotionDigest.canonicalize/1` already establishes for its own
   purpose — `Enum.sort/1` on the key list, rebuilt in that order), so two JSON texts
   differing only in key order produce byte-identical canonical output.
2. **No insignificant whitespace.** The re-encoded JSON carries no whitespace between
   tokens beyond what JSON syntax requires (i.e., none) — matching `Jason.encode!/1`'s
   default compact output, the same default `PromotionDigest` relies on.
3. **Numbers normalised.** An integer-valued float (e.g. `2.0`, `3.0e2`) is serialised
   in its canonical form with **no decimal point and no exponent form** — i.e.
   identically to the equivalent bare integer (`2`, `300`). A non-integer-valued float
   (e.g. `2.5`) is serialised in a fixed, non-exponent decimal form (exact rule left to
   ELIXIR-DEV's Step-2a implementation of the numeric-formatting function, since
   REQ-202's own text and this design's available R-Co source citations specify only
   the integer-valued-float case explicitly — flagged as **OQ-1** below, not silently
   resolved). This is the rule that makes AC3 ("a document containing an integer-valued
   float and one containing the corresponding integer produce the documented outcome")
   testable: both inputs must produce byte-identical canonical output and therefore the
   same `content_hash`.
4. **Arrays are not reordered** — array element order is significant content, same
   principle `PromotionDigest.canonicalize/1` already applies to `entries` (a list is
   mapped over, never sorted).
5. **Binary (non-JSON) content is hashed by byte identity — see §3.5.**

### 3.5 Byte-identity for non-JSON content

PROVENANCE (historical, not current decision authority):
For any artifact whose `content_type` is not a JSON media type (e.g.
`"application/wasm"`), `canonicalize_content/2` performs **no transformation
whatsoever** — the canonical form is the submitted bytes, verbatim, and
`content_hash/1`'s output is therefore a plain SHA-256 of exactly what was submitted.
This is what AC4 asserts directly: "a binary artifact... is hashed by byte identity
with no canonicalisation applied, asserted by showing its hash equals a plain SHA-256
of the submitted bytes." Per the requirement's own cross-reference, this rule
originates in R-Co's `canonicaliser.zig` header and REPO-04 cross-references WASM-05
for it — Letflow's WASM-related work (out of this requirement's scope) inherits this
same rule rather than this design re-deriving it independently.

---

## 4. `create/2` — dedup and version sequencing

### 4.1 Signature

`Letflow.Repository.create(attrs :: %{artifact_kind: atom(), artifact_name: String.t(), content_type: String.t(), content: binary(), created_by: binary(), parent_version_id: binary() | nil, description: String.t() | nil}, tenant :: tenant_ref()) :: {:ok, ArtifactVersion.t()} | {:error, Ecto.Changeset.t()}`

(`tenant_ref()` — whatever REQ-072's resolved-tenant-context type already is; this
design does not redefine it, per the same reuse-not-reinvent discipline `req195`
follows for its own tenant-context parameter.)

### 4.2 Steps (stated as a sequence, not as code)

1. Canonicalise the submitted content per §3 (`canonicalize_content/2`), or reject with
   `{:error, :invalid_json}` mapped into the returned changeset/error shape if
   canonicalization fails.
2. Compute `content_hash/1` over the canonical form.
3. **Upsert** the `repository_artifacts` row keyed by `content_hash` — `content_hash`
   already existing in this tenant's schema means the same content was submitted
   before; no new row is written, `byte_size`/`content_type` are not re-validated
   against the existing row (a hash collision implies identical content by
   construction, so there is nothing to reconcile). `content_hash` not yet existing
   means insert `content_type`, `byte_size` (byte length of the canonical form), and
   `content_hash` as a new row.
4. Compute the next `version_number` for `(artifact_kind, artifact_name)` — see §4.4.
5. Insert the `artifact_versions` row referencing the (possibly just-created,
   possibly pre-existing) `content_hash`.
6. Return the inserted `ArtifactVersion` struct — "the returned descriptor carries the
   hash," per REQ-202's own text, meaning the returned version struct's `content_hash`
   field is populated, not that a separate descriptor type is introduced.

Submitting byte-identical content twice (REPO-01, AC1) is exactly step 3's upsert
branch: one `repository_artifacts` row, two `artifact_versions` rows (each a fresh
`version_number`) both pointing at that one row.

### 4.3 Immutability implication for `create/2`'s own semantics

There is no `update/2` in this module's public interface at all — not merely omitted
from a route surface but structurally absent from the context module. "Changing"
content means calling `create/2` again with the changed content, which computes a new
`content_hash` and a new `version_number`, per §4.4. This is the API-level half of
REPO-02; §5 covers the DB-level half.

### 4.4 Version-number sequencing

`version_number` for a fresh `(artifact_kind, artifact_name)` pair starts at `1`.
For an existing pair, the next value is `1 + ` the current maximum `version_number`
among rows sharing that `(artifact_kind, artifact_name)` — read inside the same
transaction as the insert, with the unique index from §2.2
(`(artifact_kind, artifact_name, version_number)`) as the concurrency backstop: if two
concurrent `create/2` calls for the same name race and both compute the same next
number, one insert succeeds and the other fails the unique constraint and must retry
(read-max, insert, retry-on-conflict — the standard pattern for a DB-enforced gapless
sequence without a dedicated sequence object, since a Postgres `SEQUENCE` cannot be
scoped to `(artifact_kind, artifact_name)` pairs without one sequence per pair). This
retry loop is Step-2a implementation detail; this design fixes the *contract*
(monotonic per-name, unique-constraint-enforced, retry-on-conflict), not the loop's
exact code shape.

---

## 5. Immutability (REPO-02) — enforced at the database

Ecto's migration DSL has no "reject UPDATE" primitive, and per Decision 0003-C this is
the event-table pattern (application-layer enforcement) — **not applicable here**,
because AC7 explicitly demands "rejected by the DATABASE, not merely absent from the
context API," the same standard `req195-audit-entry-storage.md` §2 already establishes
for `audit_entries`. This design copies that mechanism directly.

### 5.1 `repository_artifacts` — both UPDATE and DELETE rejected

Per tenant schema, created inside the same `if prefix() do ... end`-guarded migration
block as the table (no shared `public`-schema function, per Decision B — every tenant
schema gets its own copy of the trigger function):

- A trigger function, schema-qualified to the tenant's own schema, that unconditionally
  raises an exception with a fixed message: `"repository_artifacts is immutable"`.
- `BEFORE UPDATE ON repository_artifacts FOR EACH ROW EXECUTE FUNCTION <fn>()` —
  whole-row, no column exclusion (there is no column on this table for which an update
  would ever be legitimate — `content_hash` is the identity of the row, and every other
  column is a fact about the content at insert time).
- `BEFORE DELETE ON repository_artifacts FOR EACH ROW EXECUTE FUNCTION <fn>()` — same
  function, same message text (a delete is also an illegitimate mutation of a
  content-addressed store: any live `artifact_versions.content_hash` FK reference would
  break, and even an unreferenced content row is never deleted by this requirement's
  scope).

AC7's test issues a raw `Repo.query!/3` (or `Ecto.Adapters.SQL.query!/3`) `UPDATE`
against `repository_artifacts`, going around `Letflow.Repository`'s context API
entirely, and asserts the query raises/returns a Postgres error carrying
`"repository_artifacts is immutable"` — same test shape `req195`'s AC1 uses.

### 5.2 `artifact_versions` — UPDATE rejected, DELETE governed by FK behavior instead

A version row's content is fixed at creation the same way: no legitimate update ever
exists (a "changed" version is a new row per §4.3). The same trigger pattern applies:
`BEFORE UPDATE ON artifact_versions FOR EACH ROW EXECUTE FUNCTION <fn>()` (a second,
version-specific trigger function, message `"artifact_versions is immutable"` — a
distinct function from §5.1's, since it is schema-qualified to a different table and
Postgres trigger functions are not shared across tables in this pattern any more than
across schemas). `DELETE` on `artifact_versions` is deliberately **not** blanket-denied
by a trigger the way `repository_artifacts` is — instead, its `parent_version_id`
self-FK (`on_delete: :nilify_all`, §2.2) already defines what happens if a version row
is ever deleted (children's lineage pointer nils out, they are not cascade-deleted).
This requirement's own context API (§4) never exposes a delete path for either table,
so this distinction is a schema-level statement of intent for future requirements
(e.g. a retention-policy purge job, out of scope here) rather than a behavior this
requirement's own tests need to exercise; it is recorded here so a future reader does
not assume `artifact_versions` was given the identical blanket DELETE trigger
`repository_artifacts` has and then wonders why a retention job's DELETE mysteriously
fails.

---

## 6. Version history / listing — REQ-067's cursor contract

`Letflow.Repository.list_versions(artifact_kind :: atom(), artifact_name :: String.t(), tenant :: tenant_ref(), opts :: keyword()) :: Letflow.Api.Pagination.Page.t(ArtifactVersion.t())`

- `opts` accepts `:cursor` (an encoded cursor string, or `nil` for the first page) and
  `:page_size` (validated via `Letflow.Api.Pagination.validate_page_size/1`, same
  400-on-out-of-range behavior as every other list endpoint in this codebase — not a
  silent clamp, per REQ-067's own settled behavior).
- Ordering: `(artifact_kind, artifact_name, version_number desc)` — matching §2.2's
  index — newest version first, consistent with `req195`'s "list newest-first" listing
  convention for time-ordered data.
- The cursor is minted via `Letflow.Api.Pagination.build_raw_cursor_timestamp_key/4` (or
  the plain `build_raw_cursor/3` shape if a single sortable key suffices — Step-2a's
  choice, since `version_number` is itself the sort key and may not need the
  timestamp+key two-part form `inserted_at`-ordered lists use) with a prefix distinct
  from every other endpoint's cursor prefix (per REQ-067's AC3: "a cursor minted by one
  endpoint and submitted to a different endpoint is rejected on prefix mismatch") —
  e.g. `"repo_versions"`.
- **The decoded cursor carries no `tenant_id`/schema/prefix field**, per REQ-067's own
  structural invariant (INV-1) — tenant scoping for this listing comes exclusively from
  the `tenant` parameter (REQ-072's resolved context), never from the cursor. A cursor
  minted while listing tenant A's versions and replayed against a request scoped to
  tenant B must return tenant B's versions for that `(artifact_kind, artifact_name)`
  (or an empty/not-found result if that name doesn't exist in B), never tenant A's rows
  — structurally guaranteed here because each tenant's `artifact_versions` table is a
  physically separate schema (§1), so a query scoped to tenant B's `:prefix` cannot
  return tenant A's rows regardless of what the cursor decodes to.
- `parent_version_id` is included, unmodified, on every returned `ArtifactVersion`
  struct — REPO-03's lineage is exposed by simply not omitting the column, not by any
  additional resolution step.
- Response shape: `Letflow.Api.Pagination.page_response/2` — `%Page{items: [...],
  next_cursor: ...}`, the same shape every other S4+ list endpoint returns.

---

## 7. REQ-041 name-collision disambiguation

**`solution_pack_artefact_bases`** (REQ-041, done, S2) is a GLOBAL, install-tracking
table recording which artefact a given solution-pack install started from, for
three-way-diff computation during pack updates. It is **not** a content-addressed
artifact store, has no `content_hash`-keyed dedup mechanism, and this requirement
neither reads nor writes it. `repository_artifacts`/`artifact_versions` (this
requirement) and `solution_pack_artefact_bases` (REQ-041) are two unrelated tables that
happen to share the English word "artifact"/"artefact" — this must be stated in
`Letflow.Repository`'s (or wherever the context module lands) moduledoc, verbatim in
substance, so a later reader does not conflate the two subsystems or attempt to unify
them on the strength of the shared vocabulary.

---

## 8. Functions deliberately NOT built (scope discipline)

| Function | Why not |
|---|---|
| `update/2` on either schema | REPO-02 — no update path exists at all, structurally (§4.3, §5). |
| `delete/1` on `repository_artifacts` | Content-addressed store; nothing in this requirement's scope ever removes a content row. DB trigger also blocks it regardless (§5.1). |
| Any route/controller (`/repository/artifacts` HTTP surface) | Explicitly out of scope — REQ-202's own text records that R-Co's REPO-11..14 routes were specified but never actually built upstream, and Letflow has no SPA consumer for artifacts. Named in the stage doc's not-covered list. |
| Activation (`artifact_activations`, resolving "the currently active version") | REQ-203, the second half of this pair. |
| Form-schema indexing (REPO-05) | Deferred per the stage doc's not-covered list, independent of this pair. |

---

## 9. Open questions (stated explicitly, not silently resolved)

(The question of whether `PromotionDigest`'s moduledoc amendment conflicts with AC5's
"NOT modified" language — formerly listed here as OQ-2 — has been resolved, not
deferred: see §3.2's "This edit to `promotion_digest.ex` is required, not optional, and
is settled" discussion. It is not repeated here because it is no longer open.)

- **OQ-1 — exact canonical decimal form for non-integer-valued floats.** §3.4 rule 3
  fixes the integer-valued-float case (no decimal point, no exponent) per the
  requirement's own R-Co citation, but REQ-202's text and this design's available
  citations do not specify the exact serialization for a genuinely fractional number
  (e.g. how many significant digits, whether `2.50` and `2.5` must canonicalize
  identically). ELIXIR-DEV must pick one fixed, documented rule at Step 2a and state it
  in `Letflow.Repository.Canonicaliser`'s moduledoc; TEST-DESIGNER should pin it with an
  explicit test once chosen, since AC3 tests only the integer-valued case explicitly.
- **OQ-3 — the exact set of `content_type` values treated as "JSON" by
  `canonicalize_content/2`.** §3.3 assumes `"application/json"` is the sole JSON
  marker; REQ-202's text does not enumerate whether a parameterized form
  (`"application/json; charset=utf-8"`) or a `+json` structured-syntax suffix (e.g. a
  hypothetical `"application/schema+json"`) must also route through JSON
  canonicalization rather than byte-identity. ELIXIR-DEV should pick the narrowest
  reading (exact-match `"application/json"` only) absent further guidance, and state
  the choice in the moduledoc, since silently treating an unlisted content type as
  "JSON" risks canonicalizing content the submitter intended as opaque binary.
- **OQ-4 — `artifact_id`'s generation and semantics.** REQ-202's schema spec lists
  `artifact_versions.artifact_id` as a UUID field distinct from `version_id`, but does
  not state whether it is caller-supplied (grouping versions the caller declares as
  "the same logical artifact" across renames) or server-generated fresh per
  `(artifact_kind, artifact_name)` the first time that pair is seen (making it
  effectively derivable from the unique-constraint pair rather than carrying
  independent information). This design does not silently pick one — ELIXIR-DEV must
  decide and state the choice in the schema module's moduledoc at Step 2a, since it
  changes whether `artifact_id` needs its own lookup/uniqueness handling in `create/2`.

---

## 10. Traceability — acceptance criteria to design elements

| AC (paraphrased) | Design element |
|---|---|
| AC1 — byte-identical JSON → one content row, two version rows | §4.2 step 3 (upsert-by-hash), §2.1 (PK = content_hash) |
| AC2 — key-order/whitespace-insensitive hash | §3.4 rules 1–2 |
| AC3 — number normalization, canonical bytes asserted | §3.4 rule 3, OQ-1 |
| AC4 — binary content hashed by byte identity | §3.5 |
| AC5 — separate module, `PromotionDigest` unmodified, cross-referencing moduledocs | §3.1, §3.2 (resolved: reading (a) — moduledoc-only, behavior-free edit to `promotion_digest.ex` required by clause (iii), "NOT modified" read as no behavior change) |
| AC6 — existing promotion digest unchanged by this requirement | §3.2 (no shared code path; `PromotionDigest`'s own functions are untouched in behavior) |
| AC7 — DB-level UPDATE rejection on `repository_artifacts` | §5.1 |
| AC8 — changed content → new version, new hash, incremented number, prior row untouched | §4.2, §4.4, §5.1 (prior row physically cannot change) |
| AC9 — version history ordered, parent linkage, REQ-067 pagination | §6 |
| AC10 — placement stated with reason; REVIEWER flag if global | §2's "AC10's separate, migration-file-level requirement" (the migration-file comment ELIXIR-DEV must write) — condensing the reasoning §1 states in full (per-tenant chosen; no flag raised) |
| AC11 — migration-058-vs-045 conflict recorded, 045's shape shipped | §2 (opening paragraph) |
| AC12 — REQ-041 disambiguation stated | §7 |
| AC13 — no route/controller added | §8 |
| AC14 — `mix test`/`mix compile --warnings-as-errors` pass | Step 2a/3 (ELIXIR-DEV/TEST-RUNNER execution, not a design-stage artifact) |
