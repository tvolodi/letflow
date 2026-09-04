# ISS-0439 — mapping the 1C taxonomy onto Letflow's existing machinery

**Author:** CODE-DESIGNER, dispatched in a design-exploration capacity for a
deliberately-DEFERRED issue. This is not an implementation design and produces no
requirements, no schema, no Elixir/Ecto/JSON-schema code. Its only job is to state,
concretely and against real modules read this session, what of the 1C
Directory/Document/Register/Report taxonomy is already reachable through Letflow's
shipped machinery and what would be genuinely new — the grounding artefact
`docs/migration/decisions/0019-defer-1c-typed-templates.md` cross-references.

**Sources actually read in full for this mapping**, not summarized from ISS-0439's own
filed text: `docs/issues/ISS-0439.yaml` (91 lines), `docs/issues/ISS-0438.yaml`,
`lib/letflow/design/iss0438-entity-subsystem-scoping.md` (the ISS-0438 scoping
recommendation, 508 lines), `lib/letflow/event_store/registry.ex` (307 lines),
`lib/letflow/repository.ex` (388 lines), `lib/letflow/repository/artifact_kind.ex` (28
lines), `lib/letflow/event_store/instance_projection.ex` (226 lines — the actual
projection module; located via `grep -ri projection lib/letflow/`, not assumed from
ISS-0438's own characterization), and `docs/requirements.yaml`'s REQ-225 through
REQ-231 entries (verified current `status:` field for each, see §5 below — as of this
run, 2026-09-05, all seven are `status: pending`; none is `done`).

---

## 1. The four concepts, one at a time

### 1.1 Directories — "relatively constant reference data"

**No existing Letflow mechanism serves this today.** The closest analogue is the
generic entity subsystem ISS-0438 scoped IN SCOPE for S6 (REQ-225..REQ-231) — but that
subsystem does not exist in `lib/letflow/` yet; it exists only as seven `pending`
requirements. There is no `Letflow.Entities`-namespaced module, no
`entity_definitions` table, nothing under `lib/letflow/` that currently lets a tenant
declare "a Customer is a typed record with these fields" and store/query instances of
it. Calling Directories "reuse" today would be describing a subsystem that has not been
built, not one that already exists.

Once REQ-225/REQ-226 land (entity definition schema + `entity_definitions`
persistence, per the ISS-0438 scoping doc §1's slices 1-2), a Directory-shaped need
would map onto an **untyped entity definition** — one flat concept, with no
Directory/Document/Register distinction baked into the definition schema itself.
"Directory-ness" (relatively-constant reference data, looked up rather than posted)
would be a *usage pattern* a tenant adopts on top of the generic entity subsystem, not
a distinct mechanism Letflow provides. That is exactly ISS-0439's own recorded
decision: let real workflows use the generic subsystem untyped and watch what tenants
actually build (§5 below).

**Verdict: genuinely new in both senses** — the generic substrate it would sit on
(REQ-225..231) is itself unbuilt, and even once built, a first-class "Directory" type
distinct from a generic entity definition does not exist and would need its own design
(schema markers for "reference data," lookup/autocomplete conventions, etc.) that
nothing in the current scope produces automatically.

### 1.2 Documents — "record an OPERATION/INTENT, typically with a posting step"

**Genuine, already-shipped reuse: the append-only event log.** Every event Letflow
appends via its event-store machinery already IS a record of intent/operation —
`instances`/`Letflow.Engine`, `Letflow.EventStore`, and the tenant-scoped event log
underneath them are the "document journal" ISS-0439's own filing claims, and this
session's reading confirms the shape holds: events are appended, never mutated, and
every state change flows through one.

**What `Letflow.EventStore.Registry` concretely provides toward this (read in full,
307 lines):** it is a **typed payload schema versioning** mechanism, not a posting
workflow. `register_type/2` lets a caller register a named event type
(`name`/`schema_version`/`json_schema`/`description`) scoped to a tenant, with a
monotonicity invariant on `schema_version` beyond what R-Co originally had.
`validate_payload/3` validates a raw JSON payload against an event type's
most-recently-registered schema, returning `(field_path, constraint, actual)`-shaped
failures via the module's own hand-rolled `JsonSchema` validator (deliberately not an
external library — see that module's own moduledoc). `get_type/2` fetches the current
registered version. This is real, general-purpose machinery any event type — including
a future `ENTITY_RECORD_CREATED`-style event, per the ISS-0438 scoping doc's §3 — would
register through. It gives a "Document" concept typed-payload validation and schema
evolution *for free*, the same way any other platform event type gets it today.

**What it explicitly does NOT provide, stated plainly (per this issue's own framing
that ISS-0439 not be diluted into false equivalence):** `Registry` has no concept of a
document *lifecycle* — no "draft → posted → cancelled" state machine, no distinction
between an event that has been "posted" (its consequences committed to registers) and
one that has not. 1C's Document concept carries a posting step as a first-class,
reversible operation with its own semantics (post, unpost, re-post deterministically
rebuilding registers). Letflow's event log has no posting concept at all — an appended
event is simply appended; whatever "posting" would mean is left entirely to whatever
projection/handler consumes that event. Nothing in `Letflow.EventStore.Registry` or
the append path implements or partially implements posting/unposting semantics.

**Verdict: substantial reuse for the append-only-journal-of-intent half** (the event
log itself, plus `Registry`'s typed-payload-schema-versioning), **genuinely new for the
posting-step half** (no reversible-posting state machine exists anywhere in the
codebase read this session).

### 1.3 Registers — "record the CONSEQUENCES of posting (balances, turnovers)"

**Genuine, already-shipped reuse: `instance_projections`, read in full
(`lib/letflow/event_store/instance_projection.ex`, 226 lines).** This is the actual
projection mechanism in the current codebase — located by grepping `projection`
case-insensitively under `lib/letflow/`, which surfaced 91 files, the overwhelming
majority using "projection" only in prose/design-doc cross-references; the one real
Ecto schema module is `Letflow.EventStore.InstanceProjection`. Its own moduledoc states
the invariant directly: "this is a projection table: rebuildable at any time from a
fold over `events`" (citing `docs/migration/decisions/0003-ecto-schema-strategy.md`
Decision C point 3), and it is explicitly *not* immutable the way other event-store
schemas are — it legitimately exposes an `update_changeset/2` because its correctness
boundary is "matches a fold over the event log," a runtime/test concern, not a
migration-time constraint.

That is precisely the Register concept: a table recording the **consequence** of
events (current instance status, `current_nodes`, `variables`, `join_counters`,
completion/cancellation timestamps), derived from — and rebuildable from — the event
log, never the source of truth itself. The mechanism (event-sourced, foldable,
rebuildable projection tables keyed for fast lookup) is real, shipped, and battle-
tested in production use for instance state.

**The caveat, stated concretely rather than glossed over:** `instance_projections` is
purpose-built for *engine instance state* — its columns (`status`, `current_nodes`,
`variables`, `join_counters`, `parent_instance_id`, etc., per the schema read above)
are BPM-engine-specific, not a generic "any tenant can define an arbitrary register
shape" mechanism. A 1C-style Register (e.g., an account-balance ledger with
dimensions/turnovers) would need its **own** projection table(s), built the same way
`instance_projections` was — folding a stream of typed events into a rebuildable
summary table — but nothing in the current codebase lets a tenant declare a
register-shape and have Letflow generate the fold/table automatically. That capability
is exactly the "record and replay" slice (REQ-229, ISS-0438 scoping doc §1 item 5) of
the still-unbuilt generic entity subsystem, and even REQ-229 as scoped produces one
fixed projection (`entity_record_latest`, a "current state" snapshot per entity
record), not a general balance/turnover ledger with the aggregation semantics 1C's
Registers imply (running totals, dimensional slicing over time).

**Verdict: the mechanism (event-sourced, rebuildable projection tables) is genuine,
proven reuse — Letflow already has and depends on this pattern. A generic, tenant-
definable Register abstraction with balance/turnover semantics is genuinely new and
not even fully covered by REQ-229 as currently scoped.**

### 1.4 Reports — "query/presentation over registers"

**No reporting layer exists over any projection today, and this must be stated
plainly rather than left ambiguous.** This session searched specifically for a
query/presentation layer over `instance_projections` or any other projection and found
none: no `Letflow.Reports`-shaped module, no read-model query DSL, no aggregation
layer. `Letflow.Repository.list_versions/4` is a pagination/listing function over
artifact version history (REPO-03) — a CRUD-history listing, not a Report in the 1C
sense of aggregating/summarizing register data for presentation.

The nearest thing on any build path is the entity subsystem's own **query subsystem**
(`query/` in R-Co, ported as REQ-230/REQ-231 per the ISS-0438 scoping doc's slice 6):
closed-enum filter/sort operators, a per-tenant field allowlist, a parameterised SQL
compiler with SQL-injection defences, keyset pagination, and field-grant row-level
redaction. This is itself unbuilt (`status: pending`, confirmed §5) and, even once
built, is a **filtered/paginated read API over entity records** — not an aggregation or
presentation layer (no grouping, summing, cross-tabulation, or the kind of
balance/turnover roll-up a 1C Report typically performs over a Register). The
ISS-0438 scoping doc's own §1 breakdown makes no mention of any reporting/aggregation
component at all.

**Verdict: entirely aspirational.** No reporting layer exists over any projection
today, on either the shipped side or the currently-scoped-but-unbuilt side. Even the
nearest planned capability (the entity query DSL) is a filtered-read mechanism, not a
Report in the 1C sense, and it is itself gated behind REQ-225..229 being built first.

---

## 2. Repository's role, stated explicitly (per ISS-0439's own AC3)

`Letflow.Repository` (388 lines, read in full) is **content-addressed artifact/version
storage** — canonicalise → SHA-256 hash → dedup-on-`content_hash` → version-sequence,
backing seven `artifact_kind` values today (`:definition`, `:form`, `:schema`,
`:service_catalog`, `:script`, `:module`, `:scenario`; `Letflow.Repository.ArtifactKind`,
read in full, 28 lines — a closed, hardcoded atom list with no `:entity` value yet).
Its role in this taxonomy is narrow and specific: it is where a **definition** (of an
entity type, a form, a process, etc.) is stored and versioned — the "template" a
Directory or Document instance would be created *against*, not where instances/records
themselves live. Per the ISS-0438 scoping doc §4, an entity **definition** (the schema
describing a Directory- or Document-shaped record) would become an eighth
`ArtifactKind` value and flow through `Repository.create/2`'s existing
canonicalise/hash/version pipeline and REQ-203's existing activation machinery — but
that extension has not been made (`ArtifactKind.values()` is still the seven-atom list
read above), and even once made, `Repository` stores and versions the *definition*, not
the record instances a Directory/Document would hold. Actual record data belongs to the
event log + projections (§1.2/§1.3), not `Repository`.

---

## 3. Summary table — reuse vs. genuinely new

| 1C concept | Already exists (reuse) | Genuinely new (a real gap) |
|---|---|---|
| **Directory** | Nothing shipped. `Letflow.Repository`/`ArtifactKind` could store a definition once `:entity` is added (unbuilt). | The entire generic entity subsystem (REQ-225..231, `pending`), plus a distinct "Directory" marker/semantics on top of it — neither exists. |
| **Document** | The append-only event log itself; `Letflow.EventStore.Registry`'s typed-payload schema versioning (`register_type/2`/`validate_payload/3`/`get_type/2`), shipped and in production use for every platform event type. | A posting/unposting lifecycle (draft → posted → reversible, deterministic register rebuild on re-post) — no such state machine exists anywhere read this session. |
| **Register** | The event-sourced, rebuildable-projection *pattern* itself: `Letflow.EventStore.InstanceProjection` (`instance_projections`), shipped, proven, explicitly documented as "rebuildable from a fold over `events`." | A generic, tenant-definable register abstraction with balance/turnover/dimensional aggregation semantics. `instance_projections` is engine-instance-specific; even REQ-229 (unbuilt) only plans a single fixed "current state" snapshot per entity record, not a ledger. |
| **Report** | Nothing. No query/aggregation/presentation layer exists over any projection today. | Everything — including the nearest planned building block (REQ-230/231's entity query DSL) is itself unbuilt, and even once built is a filtered-read API, not an aggregation/reporting layer. |

**Where the 2026-09-02 filing's characterization holds up vs. needs correction:**
ISS-0439's own description states the mapping "maps well onto machinery Letflow
ALREADY has: the append-only event log is a document journal, projections are
registers, and `Letflow.EventStore.Registry` already versions typed payload schemas."
That framing holds for the **mechanism-level** claim (event log ↔ document journal
shape; `instance_projections` ↔ rebuildable-projection shape; `Registry` ↔
typed-payload-versioning) — this session's direct reading confirms all three. It
should NOT be read as claiming Directories/Registers/Reports are ready to use today in
any *typed, tenant-facing* sense: the generic entity subsystem those types would sit on
(REQ-225..231) remains entirely unbuilt as of this run (all seven `pending`, §5), and
no reporting layer exists at any layer, planned or shipped. The filing itself already
carries this caveat in its "WHY DEFERRED ANYWAY" reason (1) — this artefact confirms
that caveat is still accurate, not stale, as of 2026-09-05.

---

## 4. Whether the taxonomy should be adopted — a plain verdict, not a neutral hedge

This artefact's own analysis reinforces, rather than second-guesses, ISS-0439's
recorded deferral — but it is worth stating a sharper, mechanism-grounded version of
*why*, rather than only restating the filing's own reasoning: **half of the taxonomy
(Directory, Report) currently has no real substrate to specialise at all** —
adopting typed templates today would mean designing the substrate and the
specialisation simultaneously, which is precisely the "second parallel data model"
risk the filing's reason (1) already names. The other half (Document, Register) does
have real, shipped substrate, but that substrate is Letflow's *general-purpose*
event-sourcing machinery, used today for BPM engine instance state — not yet exercised
by any tenant-defined business-object use case at all. There is no existing evidence,
from any tenant, of what shape a Directory or Register actually needs to take in this
platform's domain. Committing to 1C's specific four-type split now would be encoding
one ERP vendor's decades of accounting-domain traffic onto a general BPM platform with
zero data points of its own.

**This artefact does not recommend adoption at this time, and does not recommend
rejecting the taxonomy outright either — it recommends the sequencing ISS-0439 already
recorded.** The taxonomy is not being deferred for lack of merit (§1 shows real
structural fit for two of the four concepts); it is being deferred for lack of
*evidence*, and that evidence can only come from watching what gets built on the
generic substrate once it exists. See `docs/migration/decisions/0019-defer-1c-typed-
templates.md` for the formal decision record and its three review triggers.

---

## 5. ISS-0438 / REQ-225..231 dependency, current status

**No typed-template design should proceed while REQ-225 through REQ-231 remain
unbuilt.** Verified directly against `docs/requirements.yaml` this session (not
assumed from ISS-0439's 2026-09-02 filing text, which itself only claimed "none done"
without citing a live check):

| Requirement | Title (abbreviated) | `status` |
|---|---|---|
| REQ-225 | Entity definition JSON schema + structural validation | `pending` |
| REQ-226 | `entity_definitions` persistence + CRUD + `ArtifactKind :entity` | `pending` |
| REQ-227 | Entity record payload validation | `pending` |
| REQ-228 | Entity event registration + record commands | `pending` |
| REQ-229 | Entity record projection and replay | `pending` |
| REQ-230 | Entity query DSL — operators/allowlist/compiler | `pending` |
| REQ-231 | Entity query DSL — cursor + field-grant redaction | `pending` |

All seven are `pending`; none is `done`, `in_progress`, or otherwise advanced. This
confirms ISS-0439's 2026-09-02 "Status update" note is still accurate as of
2026-09-05: ISS-0438 itself resolved (IN SCOPE, tracked, seven requirements
registered), but the substrate those requirements would build remains entirely
unbuilt. Nothing in this session's reading changes that picture.
