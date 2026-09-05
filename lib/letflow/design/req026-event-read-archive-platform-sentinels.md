# Design: REQ-026 — Event read paths, archive, and platform sentinels
PROVENANCE (historical, not current decision authority):
(`Store.read`/`readGlobal`/`pointInTime`/`archive` + `platform.zig`)

**Requirement:** REQ-026 (`docs/requirements.yaml:1102-1191`, stage S2,
`depends_on: [REQ-025]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ026-20260817`, WF-02 Step 1
**This document produces:** function signatures for `read/2`, `read_global/1`,
`point_in_time/3`, `archive/1`, the three platform sentinel accessors, one new
migration + `Ecto.Schema` module for `event_retention_policies`, the exact
archive transaction shape, invariants, cross-module dependencies, open
questions — **no implementation code**. No function bodies, no `.ex`/`.exs`
files. Pseudocode/pseudo-SQL blocks below (matching the convention already
established in `req023-event-store-schema.md` §5.1 and `req025-event-append.md`)
describe shape only; ELIXIR-DEV writes the real version at Step 2a.

---

## 0. Sources read for this design, and a stated gap

**Letflow project docs, read in full:**

- `docs/requirements.yaml` — REQ-026's full entry (1102-1191), including both long
  inline notes (ISS-0013/GH#69 on `event_retention_policies`' ownership, ISS-0014/GH#70
  on `archive/1`'s row-level-move sourcing), re-read twice per this run's briefing.
  REQ-023 (898-974), REQ-025 (1042-1100) re-read for cross-referencing.
- `docs/agents/instructions/core-directives.md`, `docs/agents/workflows/WF-02_requirement_implementation.md`
  Step 1, `docs/anti-patterns.md` (no relevant prior entries), `.claude/agents/code-designer.md`.
- `docs/guides/backend_developer_guide.md` — §3.5 (error shapes stated in every `@spec`),
  §3.6 (SQL parameterization / no raw interpolation), §3.7 (migrations).
- `docs/migration/decisions/0003-ecto-schema-strategy.md` — Decision B (schema-per-tenant
  + intra-schema `tenant_id`), Decision C point 1 (append-only/immutability — this
  requirement adds **no** update path anywhere), Decision C point 2 (unpartitioned-first;
  directly governs §7's archive-as-row-level-move resolution).
- **`lib/letflow/design/req023-event-store-schema.md` — read in full (1221 lines).**
  Critically: §2.5 (only `events`/`events_archive`/`instance_projections` carry
  `tenant_id`), the six table specs (§3), the "functions deliberately NOT built" table
  style (§5.1) reused below, and **§9's OQ-1 and OQ-2**, both addressed explicitly to
  REQ-026:
  - **OQ-1**: "`event_retention_policies` has no owning requirement... Resolution needed
    before REQ-026 starts: either extend REQ-026's scope to create it, or file it as its
    own requirement." — resolved by ISS-0013/GH#69 in favour of the former, per
    `docs/requirements.yaml:1142-1158`. This design builds the table (§8).
  - **OQ-2**: "how do large payloads survive archival?" Three candidate resolutions
    listed there verbatim: (a) inline the payload bytes into `events_archive.payload` at
    archive time, dropping the `$ref` indirection for archived events; (b) a sibling
    `events_archive_payload_store` table; (c) re-point `event_payload_store` at the
    archive row. **Not resolved by any prior requirement — resolved by this design, §7.4.**
    This is load-bearing: `event_payload_store`'s FK to `events` is `ON DELETE RESTRICT`
    (`20260816120004_create_event_payload_store.exs`), so `archive/1`'s `DELETE FROM
    events` would raise a Postgres foreign-key-violation for any archived event that had
    an oversized payload, unless this is resolved. ISS-0013/GH#69's text in
    `requirements.yaml` does not mention OQ-2 by name — it is treated here as still open
    and in scope, since it is a direct precondition for `archive/1` working at all, not a
    separate feature.
- `lib/letflow/design/req025-event-append.md` — read in full (transaction/Multi
  conventions, `tenant_id` derivation via `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`,
  error-tuple shapes, the `$ref` split-payload mechanism this design reuses read-side).
- `lib/letflow/design/req041-pack-update-diff-schema.md` §2 — read in full as the direct
  **GLOBAL-table precedent** (structural template for §6's tenant-scoping analysis below):
  "these three tables are GLOBAL (public/default schema, no `:prefix`)," with
  `priv/repo/migrations/20260816090045_create_tenant_schemas.exs` as its own cited
  GLOBAL-table precedent.
- `lib/letflow/design/identity-schema.md` §2 — GLOBAL-vs-PER_TENANT precedent for
  `tenants`/`users`/`groups`.

**Letflow shipped code, read directly (not assumed):**

- `lib/letflow/event_store.ex` (582 lines, full file) — REQ-025's `append/2`. Confirmed
  the `tenant_id`-derivation pattern (`TenantProvisioning.tenant_id_for_schema_name/1`,
  never accepted from caller input), the `Ecto.Multi` step-naming convention, the
  `{:error, reason}` catch-all pass-through idiom, and — critically for §5 below — that
  `append/2`'s own moduledoc explicitly states: *"Only `append/2` is built here. `read/2`,
  `read_global/1`, `point_in_time/3`, `archive/1` belong to REQ-026."* This design extends
  `Letflow.EventStore`, it does not create a new module.
- `lib/letflow/event_store/event.ex`, `archived_event.ex`, `stored_payload.ex`,
  `instance_sequence.ex`, `instance_projection.ex` — full files. Confirmed exact field
  lists, confirmed `Event`/`ArchivedEvent` expose **no** update path (immutability, 0003
  Decision C point 1 — this design must not add one either), confirmed
  `StoredPayload`'s `uq_event_payload_event` is a **single-column** unique index on
  `event_id` (O(1) lookup per event, no `created_at` needed to resolve a `$ref`), and
  confirmed `ArchivedEvent.insert_changeset/2`'s cast/required-field list (§7.4 below
  builds directly against this, unchanged).
- `lib/letflow/event_store/registry.ex` — full file (267 lines). Read specifically to
  **verify `event_type_registry`'s actual tenant-scoping**, since this run's task
  briefing asserted it is "presumably also global" as a cross-check for
  `event_retention_policies`' own classification. **That premise is factually wrong —
  see §6 below; corrected, not silently followed.**
- `priv/repo/migrations/20260816163103_create_event_type_registry.exs` — confirmed
  directly at the DDL level: this migration is inside the `if prefix() do ... end` guard
  (PER_TENANT), matching every other event-store migration except `event_retention_policies`
  built here.
- `priv/repo/migrations/20260816120001_create_events.exs`,
  `..._create_event_payload_store.exs`, `..._create_events_archive.exs`,
  `..._create_event_idempotency.exs` — full files, read directly for exact column
  types/nullability/index names/FK shape (not re-derived from the schema modules alone —
  the migration is the DDL source of truth).
- `priv/repo/migrations/20260816090045_create_tenant_schemas.exs`,
  `20260817083801_create_solution_pack_installs.exs` — read directly as the two GLOBAL
  (no `if prefix() do`) migration precedents, confirming the exact structural difference
  from every PER_TENANT migration in this codebase (§6, §8).
- `lib/letflow/tenant_provisioning.ex` — confirmed `tenant_id_for_schema_name/1`'s exact
  signature and `{:error, :tenant_not_provisioned}` / `{:error, :invalid_schema_name}`
  error shape, reused unchanged by every function below that takes `prefix:`.

PROVENANCE (historical, not current decision authority):
**R-Co source (`src/event_store/store.zig`'s `read`/`readGlobal`/`pointInTime`/`archive`,
`src/event_store/platform.zig`, `src/design/event_store.md`'s ES-02/04/06/07 sections):
genuinely unreachable on this host**, confirmed freshly for this run (not assumed stale
from REQ-025/029/032's prior findings):

PROVENANCE (historical, not current decision authority):
```
$ find / -maxdepth 3 -iname "R-Co" 2>/dev/null
(no output)
$ find / -maxdepth 4 -iname "event_store.md" -o -iname "platform.zig" 2>/dev/null
(no output)
```

This design therefore works from `docs/requirements.yaml`'s REQ-026 entry (a detailed
paraphrase of the unreachable primary sources, per this run's own briefing) plus the
extensive direct quotations already embedded — with line numbers — in
`req023-event-store-schema.md`'s own citations, which this design treats as a reliable
secondary source since it was itself produced by reading the primary R-Co files
directly. Anywhere this design states a specific mechanism (the archive transaction
shape §7.3, the retention-policy CHECK-constraint predicates §8.4, the platform sentinel
UUID *values* §4) that is **not** directly quoted from `requirements.yaml` or one of
those secondary citations, it is flagged explicitly as this design's own construction —
see each section's own callout and §11's open questions.

---

## 1. Scope boundary

**In scope:** four new public functions on the existing `Letflow.EventStore` module
(`read/2`, `read_global/1`, `point_in_time/3`, `archive/1`), three platform sentinel
accessor functions on the same module, one new migration + one new `Ecto.Schema` module
for `event_retention_policies`, and the resolution of REQ-023's OQ-1 and OQ-2 (§0 above).

**Explicitly NOT in scope, not silently dropped:**

| Not built here | Owned by | Citation |
|---|---|---|
| A public CRUD/management API for `event_retention_policies` rows (create/update/delete a policy) | A later requirement | `requirements.yaml`'s REQ-026 text names only that the table exists and that `archive/1` *consults* it — no function to write a policy is named in any acceptance criterion. §8.5 states this explicitly; `RetentionPolicy.insert_changeset/2` alone is sufficient for TEST-DESIGNER to seed rows directly via `Repo.insert/2`, the same "schema only, CRUD deferred" pattern REQ-027 used for `process_definitions`. |
| Reading events *from* `events_archive` (a `read_archived/2`-equivalent) | Not named in any REQ-026 acceptance criterion | `archive/1` only *writes* to `events_archive`; nothing in REQ-026's text describes a read path back out of it. Flagged as §11 OQ-3. |
| Real emission of scheduler/platform events using the three sentinel constants | A later stage's engine work | `requirements.yaml:1119-1121`: "this requirement only needs the constants to exist" |
| Batching/chunking `archive/1`'s target-set computation for very large tenants | Not named in any acceptance criterion | §11 OQ-4 |
| A general GLOBAL-vs-PER_TENANT classification rule | REVIEWER / a future decision record | §6, following `req041`'s own precedent of flagging rather than resolving the general rule |

---

## 2. Module and file layout

| Module | File | Kind | Status |
|---|---|---|---|
| `Letflow.EventStore` | `lib/letflow/event_store.ex` | context module | **extended** — `read/2`, `read_global/1`, `point_in_time/3`, `archive/1`, `platform_instance_id/0`, `platform_actor_id/0`, `platform_tenant_id/0` added to the module `append/2` already lives in |
| `Letflow.EventStore.RetentionPolicy` | `lib/letflow/event_store/retention_policy.ex` | `Ecto.Schema` | **new** |
| — | `priv/repo/migrations/<ts>_create_event_retention_policies.exs` | migration | **new**, GLOBAL (§6) |

No new file for the platform sentinels: per `requirements.yaml:1114-1116`'s own
instruction ("port as module attributes/constants on the same context module, no
separate file needed unless ELIXIR-DEV judges otherwise"), and since three 0-arity
accessor functions add negligible surface to `event_store.ex`, this design does not
propose a separate file. ELIXIR-DEV may still split them out if the moduledoc becomes
unwieldy — that is implementation discretion, not a design requirement.

---

PROVENANCE (historical, not current decision authority):
## 3. Platform sentinel constants (`platform.zig` port)

**Accessibility, not raw module attributes.** REQ-026's acceptance criterion 7 requires
the three constants be "accessible from the context module." A bare `@platform_instance_id`
module attribute is compile-time-private to its defining module in Elixir — external
callers cannot read it. The design therefore specifies three public 0-arity accessor
functions, backed internally by module attributes (the standard Elixir sentinel-constant
idiom):

```
@spec platform_instance_id() :: Ecto.UUID.t()
@spec platform_actor_id() :: Ecto.UUID.t()
@spec platform_tenant_id() :: Ecto.UUID.t()
```

PROVENANCE (historical, not current decision authority):
Each must carry a one-line `@doc` citing `src/event_store/platform.zig` verbatim, per
acceptance criterion 7 — e.g. (illustrative wording, not a mandated literal string):
`"PLATFORM_INSTANCE_ID sentinel — ported from src/event_store/platform.zig. Never
inserted into instance_projections (per req023-event-store-schema.md §3.1.3's citation
of platform.zig:5)."`

PROVENANCE (historical, not current decision authority):
**Values — explicitly NOT decided here, flagged per this run's own instruction not to
invent.** `platform.zig`'s three literal UUID strings are unreachable (§0). This design
does not propose specific UUID literals as a design decision — see §11 OQ-1 for the
resolution path (ELIXIR-DEV must either locate the real values or pick documented
placeholders and flag the substitution explicitly, the same "flagged, not silently
worked around" discipline `req041`'s design used for its own unreachable-source gaps).
What **is** decided: all three are syntactically valid UUID strings (so `Ecto.UUID.cast/1`
accepts them wherever they're later written into a `tenant_id`/`actor_id`/`instance_id`
column), and the three values are pairwise distinct (three different sentinel concepts;
collapsing them to one shared value would make a future consumer unable to tell, from
the constant alone, which sentinel produced a given row — even though today nothing
reads them back, per this requirement's own explicit non-goal).

---

## 4. `read/2`

```
@spec read(instance_id :: Ecto.UUID.t(), opts :: [
        prefix: String.t(),
        up_to_sequence: pos_integer() | nil,
        up_to_timestamp: DateTime.t() | nil
      ]) ::
        {:ok, [Event.t()]}
        | {:error, :invalid_instance_id}
        | {:error, :tenant_not_provisioned}
        | {:error, :instance_not_found}
        | {:error, {:payload_resolution_failed, event_id :: Ecto.UUID.t()}}
        | {:error, term()}
```

### 4.1 Argument validation (pre-query, mirrors `append/2`'s pre-transaction phase)

1. `instance_id` must `Ecto.UUID.cast/1` successfully — `{:error, :invalid_instance_id}`
   otherwise. Unlike `append/2`'s `attrs`-map fetch, `instance_id` here is a required
   positional argument, so there is no `:missing_instance_id` case — a `nil` or
   non-UUID-shaped value is a cast failure, not a missing-key case.
2. `opts[:prefix]` resolves via `TenantProvisioning.tenant_id_for_schema_name/1`
   (`append/2`'s own established call, reused unchanged) — `{:error, :tenant_not_provisioned}`
   on failure. This is a validation-only call here: unlike `append/2`, nothing written by
   `read/2` needs the resolved `tenant_id` value (no I/O writes at all), but resolving it
   anyway catches a typo'd/unprovisioned `prefix` the same way every other tenant-scoped
   entry point does, rather than letting a bad prefix silently query an empty or
   nonexistent Postgres schema.

### 4.2 Not-found vs. empty-list — the exact lookup order (acceptance criterion 2)

**The distinguishing fact:** `instance_sequence` gets its one row for a given
`instance_id` **only** as part of `append/2`'s `assign_sequence/3` step
(`event_store.ex:345-357`), which is itself one step inside the single `Ecto.Multi`
transaction `append/2` runs. Because `Ecto.Multi`/`Repo.transaction/2` is atomic, that
row can only exist in a committed state if the `events` insert in the *same* transaction
also committed — so **an `instance_sequence` row's existence is proof this instance has
had at least one event appended**, ever. Conversely, **an `instance_sequence` row's
absence means this `instance_id` has never had a successful append** — this is
`event_store.md`'s `InstanceNotFound` case, per `requirements.yaml:1126-1127`.

This also explains why "instance exists but has zero events" is a real, distinct case
requiring a real empty-list result rather than being unreachable: once `archive/1` (§7)
has moved *every* one of an instance's events into `events_archive`, `events` legitimately
has zero rows for that `instance_id` even though its `instance_sequence` row still exists
(archive/1 never touches `instance_sequence` — §7.5, invariant 12). A query against
`events` alone, with no `instance_sequence` check first, cannot distinguish "never
existed" from "fully archived" — both return `[]`. The two-step lookup order below is
mandatory, not a stylistic choice:

```
STEP 1 — existence check (no ORDER BY / no filters):
  SELECT 1 FROM instance_sequence WHERE instance_id = $1 LIMIT 1
  (prefix: schema_name)
  -> no row: {:error, :instance_not_found}, STOP.
  -> row found: proceed to STEP 2.

STEP 2 — the real read, filters applied (§4.3), ordered by sequence_number ASC:
  SELECT * FROM events
  WHERE instance_id = $1 [AND <filter from §4.3>]
  ORDER BY sequence_number ASC
  (prefix: schema_name)
  -> {:ok, rows}  (rows MAY legitimately be [])
```

Both queries use `Ecto.Query` composition against `InstanceSequence`/`Event` (never a raw
SQL string — INV-7), both pass `prefix: schema_name` explicitly (INV-EV-8, no
`@schema_prefix` on either schema module).

### 4.3 `up_to_sequence` vs. `up_to_timestamp` precedence (ES-06, acceptance criterion 1)

Per `requirements.yaml:1122-1124`: "supports `up_to_sequence`/`up_to_timestamp` filters
(`up_to_sequence` takes precedence if both given, per ES-06)". This design reads
"precedence" as **exclusive selection of one filter, not a conjunction**:

```
filter =
  cond do
    opts[:up_to_sequence] != nil  -> {:sequence_number, :lte, opts[:up_to_sequence]}
    opts[:up_to_timestamp] != nil -> {:created_at,       :lte, opts[:up_to_timestamp]}
    true                          -> :none
  end
```

If both are given, only the `up_to_sequence` clause is applied to the query —
`up_to_timestamp` is silently ignored for that call, not additionally ANDed in. This
avoids a case where a caller-supplied `up_to_timestamp` that is inconsistent with
`up_to_sequence` (e.g. a timestamp older than the event at that sequence number) would
produce a *narrower* result than "at that sequence number" alone implies — "takes
precedence" is read as "wins outright," matching the single-filter framing
`GlobalReadOpts` uses for `read_global/1` (§5).

### 4.4 `$ref` resolution (acceptance criterion 1) — reused, not reinvented

See §9 for the full mechanism, shared verbatim by `read/2` and `read_global/1`. In
short: after STEP 2's query returns, any row whose `payload` field is exactly
`%{"$ref" => event_id}` (REQ-025's own oversized-payload marker,
`event_store.ex:454`/`event_store.ex:491`) has its `payload` field replaced, in the
returned list, with the real content from `Letflow.EventStore.StoredPayload`, resolved
by a single batched query (never N+1). `{:error, {:payload_resolution_failed, event_id}}`
is returned for the whole call if a `$ref`-pointing row's `StoredPayload` sidecar is
unexpectedly missing (a data-integrity violation — fail loud per INV-8, never silently
return the raw pointer or drop the row).

### 4.5 `point_in_time/3`

```
@spec point_in_time(
        instance_id :: Ecto.UUID.t(),
        timestamp :: DateTime.t(),
        opts :: [prefix: String.t(), up_to_sequence: pos_integer() | nil]
      ) ::
        {:ok, [Event.t()]}
        | {:error, :invalid_instance_id}
        | {:error, :tenant_not_provisioned}
        | {:error, :instance_not_found}
        | {:error, {:payload_resolution_failed, event_id :: Ecto.UUID.t()}}
        | {:error, term()}
```

A pure convenience wrapper, per `requirements.yaml:1132-1133`: calls `read/2` with
`opts` amended to set `up_to_timestamp: timestamp`. `opts` here still accepts
`up_to_sequence` (not stripped) — if a caller supplies it, §4.3's ordinary precedence
rule applies unchanged (`up_to_sequence` wins). No new logic beyond the delegation;
`point_in_time/3` introduces no filter-composition rule of its own.

---

## 5. `read_global/1`

```
@spec read_global(opts :: [
        prefix: String.t(),
        after_global_seq: pos_integer() | nil,
        limit: non_neg_integer() | nil
      ]) ::
        {:ok, %{
          events: [Event.t()],
          next_after_global_seq: pos_integer() | nil,
          has_more: boolean()
        }}
        | {:error, :tenant_not_provisioned}
        | {:error, {:payload_resolution_failed, event_id :: Ecto.UUID.t()}}
        | {:error, term()}
```

**Scope note, per REQ-023 §9 OQ-3 (informational, not this requirement's to resolve):**
"global" here means global *within one tenant's own Postgres schema* — across that
tenant's instances, ordered by that schema's own `global_seq` sequence
(`events.global_seq`, `:bigserial`, `20260816120001_create_events.exs`). It is **not** a
cross-tenant platform-wide stream; no such stream exists in this schema shape. This
matches `requirements.yaml:1128-1131`'s literal "ordered by global_seq ascending across
all instances" (instances, not tenants) and `event_store.md:213`'s ES-04 framing per
REQ-023's citation.

### 5.1 `after_global_seq` / cursor semantics (acceptance criterion 3)

```
after_global_seq == nil  -> no lower-bound filter (from the beginning)
after_global_seq == N    -> WHERE global_seq > N   (strictly greater — matches
                            acceptance criterion 3's literal wording)
```

### 5.2 `limit` clamping (`requirements.yaml:1129-1131`, GlobalReadOpts semantics)

```
raw_limit = opts[:limit]

effective_limit =
  cond do
    raw_limit == nil -> 100          # default
    raw_limit == 0   -> 100          # "0 treated as default 100 per GlobalReadOpts" -- literal
    raw_limit < 0    -> 1            # clamp to the stated floor; not literally required
                                      # by requirements.yaml's text (only 0's special case
                                      # is), but "clamped to 1..1000" implies no value below
                                      # 1 is ever used as-is -- flagged as this design's own
                                      # extrapolation, not a verified quotation (see §11 OQ-2)
    raw_limit > 1000 -> 1000         # clamp to the stated ceiling
    true             -> raw_limit    # 1..1000 inclusive, used as-is
  end
```

### 5.3 Query shape

```
SELECT * FROM events
WHERE [global_seq > $after_global_seq]
ORDER BY global_seq ASC
LIMIT $effective_limit
(prefix: schema_name)
```

No `instance_sequence` existence check here — `read_global/1` is not instance-scoped, so
§4.2's not-found distinction does not apply; an empty tenant schema (or one past the
given cursor) legitimately returns `events: []`.

### 5.4 Result shape (cursor pagination, acceptance criterion 3)

```
next_after_global_seq =
  case events do
    []    -> opts[:after_global_seq]   # unchanged -- nothing new to advance past
    list  -> List.last(list).global_seq  # ASC order, so the last row is the max
  end

has_more = length(events) == effective_limit
```

**`has_more` is a heuristic, not a proof** — flagged explicitly, not silently presented
as exact: if exactly `effective_limit` more rows exist and no others, `has_more` reports
`true` but the very next call returns zero new rows. This is the ordinary cursor-pagination
limitation (a caller must be prepared for one extra "empty" page at the boundary); it is
not a defect of this design. `$ref` resolution (§9) applies identically to `read_global/1`'s
result — a **design decision, not a literal requirement-text mandate** (`requirements.yaml`'s
`read_global/1` paragraph does not repeat `read/2`'s "$ref transparently resolved" clause),
made for consistency: no public read path should ever leak an internal `$ref` pointer.
Flagged so CODE-DESIGN-VALIDATOR/REVIEWER can weigh in if they read the omission in
`requirements.yaml`'s text as deliberate rather than incidental.

---

## 6. `event_retention_policies` tenant-scoping classification: GLOBAL — with a corrected
premise, stated explicitly

**What this run's task briefing assumed, and what is actually true.** The briefing
suggested cross-checking `event_retention_policies`' GLOBAL classification against
"`event_type_registry`'s own scoping, which is presumably also global." **That premise
is incorrect, confirmed by reading the shipped migration directly**:
`priv/repo/migrations/20260816163103_create_event_type_registry.exs` wraps its entire
`create table` call in `if prefix() do ... end` — the PER_TENANT guard pattern, not the
GLOBAL pattern. `event_type_registry` is schema-per-tenant, one copy per tenant schema,
exactly like `events`/`event_idempotency`/`instance_sequence`. This is reported here as
a factual correction, not silently followed — the task briefing's assumption does not
hold and this design does not build on it.

**Why this matters:** it removes the one piece of "supporting" precedent the briefing
offered for a GLOBAL classification. The classification below is therefore justified on
different, independently-checked grounds.

**Decision: GLOBAL (public/default schema, no `:prefix`), for these reasons:**

1. **Literal column list.** `requirements.yaml:1146-1150` states the column list
   matches "R-Co's current `003_event_archive.sql` shape" exactly: `id`, `event_type`
   (unique), `policy`, `keep_days`, `keep_count`, `created_at`, `updated_at` — **no**
   `tenant_id` column anywhere in that list. Every genuinely PER_TENANT event-store
   table that omits `tenant_id` (`instance_sequence`, `event_payload_store`,
   `event_idempotency`) still relies on the *Postgres schema itself* as the tenant
   boundary (`event_store.ex`'s own moduledoc: "Tenant isolation for those two tables'
   rows is enforced entirely by the Postgres schema (`:prefix`) boundary they are
   written into, not by a column value"). A PER_TENANT `event_retention_policies` would
   fit that same shape. A GLOBAL one fits it too, differently: one row, one schema,
   platform-wide. The column list alone is compatible with either reading — it does
   not settle this by itself, which is why points 2-3 below carry the actual weight.
2. **The archive/1 framing itself.** `requirements.yaml:1134-1136` calls `retention_days`
   "a global fallback" and says per-event-type policy rows "take precedence" over it.
   "Global fallback" language, applied to a value that itself must come from *somewhere*
   coherent for `retention_days` to mean anything as a single number, reads naturally as:
   retention configuration is a platform/ops-level concern (how long to keep a given
   event *type*, full stop), not a per-tenant business setting that could legitimately
   vary tenant-to-tenant for the same `event_type` string. This is a semantic/domain
   argument, not a structural one — flagged as such, not overstated as settled fact.
3. **Operational precedent.** `service_catalog` (cited by `req041`'s own design, §2, as
   "a public-schema routing/registry table") is the closest existing analogue: platform
   configuration data that is naturally singular per key, not per tenant. A retention
   *policy* keyed only by `event_type` is the same shape of thing — one authoritative
   row per key, not one per (tenant, key).

**What this decision does NOT resolve, flagged per §0/OQ discipline:** a real,
un-dismissed tension exists between "GLOBAL `event_retention_policies`" and "PER_TENANT
`event_type_registry`" — the same `event_type` string can be independently registered,
with independently different JSON schemas, by every tenant (§0's confirmed fact). A
single global retention policy for `"order.created"` would apply uniformly to every
tenant's own independently-registered `"order.created"` type, even though nothing
guarantees those are semantically the same kind of event across tenants. This is
analogous to, and in the same spirit as, `req041` §2's own explicitly-flagged general
GLOBAL-vs-PER_TENANT question — recorded here as **§11 OQ-2 (MAJOR)**, not silently
resolved by this design's GLOBAL pick. REVIEWER should read this section and `req041`
§2 together, per `req041`'s own note that these are independent data points on one
unresolved general question.

**Migration guard, following `req041`'s established GLOBAL structural pattern exactly:**
no `if prefix() do ... end` wrapper — `create table(:event_retention_policies, ...)` runs
unconditionally on a plain `mix ecto.migrate`, the same as `tenant_schemas` and
`solution_pack_installs`.

---

## 7. `archive/1`

```
@spec archive(opts :: [
        prefix: String.t(),
        retention_days: non_neg_integer()
      ]) ::
        {:ok, %{moved_count: non_neg_integer()}}
        | {:error, :missing_retention_days}
        | {:error, :tenant_not_provisioned}
        | {:error, term()}
```

`opts[:retention_days]` is **required**, not defaulted — `{:error, :missing_retention_days}`
if absent, matching `append/2`'s established "fetch a required field, typed error if
missing" idiom rather than silently assuming a value for a parameter this consequential.
`0` is a valid, meaningful value ("only explicit policies apply," `requirements.yaml:1134-1136`)
and must not be conflated with "absent."

### 7.1 Retention-policy precedence — the classification predicate (acceptance criteria
5, 6)

For each distinct `event_type` present in `events`, exactly one of these applies, in
this order:

```
1. An event_retention_policies row exists for this event_type, policy = 'keep_forever'
   -> NEVER eligible for archival, regardless of age or retention_days.

2. An event_retention_policies row exists, policy = 'keep_days'
   -> eligible iff created_at < (now() AT TIME ZONE 'utc') - keep_days days
      (that row's OWN keep_days, not the global retention_days parameter).

3. An event_retention_policies row exists, policy = 'keep_count'
   -> eligible iff this row is NOT among the keep_count most-recently-created
      rows of this event_type (ranked by created_at DESC, tie-broken by
      event_id DESC for determinism -- an arbitrary but stable secondary key,
      since two events of the same type can share a created_at timestamp).
      Scope: ranked across the WHOLE tenant schema (all instances), NOT
      per-instance -- event_retention_policies has no instance_id column to
      scope by, so "keep the N most recent" is read as "N most recent
      platform-wide for this tenant," per event_type. Flagged as this
      design's own interpretation, not a verified quotation (see §11 OQ-5).

4. NO event_retention_policies row exists for this event_type:
   a. retention_days > 0  -> eligible iff created_at < now() - retention_days days
                              (the global fallback).
   b. retention_days == 0 -> NEVER eligible ("0 retention_days means only
                              explicit policies apply," requirements.yaml:1134-1136).
```

**Illustrative pseudo-SQL for the classification query** (a CTE, since rule 3's ranking
needs a window function that cannot appear directly in a `WHERE` clause) — this
describes the eligibility *predicate* precisely; it is not a literal Ecto/Elixir
implementation and ELIXIR-DEV may express it as a raw `fragment/1`, a multi-query
Elixir-side computation, or any equivalent that produces the identical eligible set:

```sql
-- illustrative only -- describes predicate shape, not literal code
WITH ranked AS (
  SELECT
    e.event_id, e.created_at, e.event_type,
    p.policy, p.keep_days, p.keep_count,
    RANK() OVER (PARTITION BY e.event_type
                 ORDER BY e.created_at DESC, e.event_id DESC) AS rnk
  FROM events e
  LEFT JOIN event_retention_policies p ON p.event_type = e.event_type
)
SELECT event_id, created_at FROM ranked
WHERE
  CASE
    WHEN policy = 'keep_forever'        THEN false
    WHEN policy = 'keep_days'           THEN created_at < (now() AT TIME ZONE 'utc')
                                                            - (keep_days || ' days')::interval
    WHEN policy = 'keep_count'          THEN rnk > keep_count
    WHEN policy IS NULL AND :retention_days > 0
                                         THEN created_at < (now() AT TIME ZONE 'utc')
                                                            - (:retention_days || ' days')::interval
    ELSE false
  END
```

This result set is materialized once, up front, as the target set **T** = a list of
`(event_id, created_at)` pairs — the composite PK of both `events` and `events_archive`.
Every later step in §7.2-§7.4 operates against this fixed set T, **not** a freshly
re-evaluated predicate, for the reason §7.3 explains.

### 7.2 Why T is computed once and threaded through, not re-derived per phase

An earlier version of this reasoning considered re-running the classification predicate
independently in each transactional phase below. That is rejected: if an operator
changes an `event_retention_policies` row (e.g. `keep_days: 30` → `policy: keep_forever`)
in the gap between this call's two phases (§7.3), a freshly re-evaluated predicate in
phase 2 could stop matching rows phase 1 already committed to `events_archive`, leaving
them permanently duplicated (present in both `events` and `events_archive`, never
cleaned up, since they'd no longer look "eligible" under the new policy). Threading the
same concrete set T through both phases avoids this: T is a fact about *this call*, fixed
at the moment §7.1 ran, immune to a policy edit racing the two phases.

### 7.3 The idempotent insert-then-delete-confirmed transaction shape (invariant 11)

**Two separate top-level `Repo.transaction/2` calls, not one `Ecto.Multi` spanning both**
— a deliberate divergence from `append/2`'s single-Multi convention, for the reason
stated inline at each phase. This is this design's own construction (§0) — the two-phase
split is not directly quoted from any reachable source, but is required by invariant 11's
literal wording ("running twice produces the same final state") being stated as a
non-trivial design property: if insert+delete were one atomic transaction, this
invariant would hold automatically with no dedicated mechanism needed, so the invariant's
very existence as something to *design for* implies the two operations are not meant to
be one atomic unit — most plausibly because a single transaction spanning a
potentially-large `INSERT ... SELECT` and a large `DELETE` would hold row-level locks on
`events` for the combined duration of both, which the two-phase split bounds to one
operation's duration each.

**Phase 1 — archive-insert (also resolves OQ-2 via option (a), §7.4):**

```
BEGIN;
INSERT INTO events_archive (event_id, created_at, instance_id, event_type,
                             payload, actor_id, sequence_number,
                             idempotency_key, metadata, global_seq,
                             tenant_id, archived_at)
SELECT e.event_id, e.created_at, e.instance_id, e.event_type,
       COALESCE(eps.payload, e.payload) AS payload,  -- OQ-2 resolution, §7.4
       e.actor_id, e.sequence_number, e.idempotency_key, e.metadata,
       e.global_seq, e.tenant_id, (now() AT TIME ZONE 'utc')
FROM events e
LEFT JOIN event_payload_store eps ON eps.event_id = e.event_id
WHERE (e.event_id, e.created_at) IN (T)
ON CONFLICT (event_id, created_at) DO NOTHING;
COMMIT;
```

`ON CONFLICT DO NOTHING` on the archive table's own composite PK is what makes a
*re-run* of phase 1 (after a crash between phase 1 and phase 2, or a second `archive/1`
call before phase 2 of the first has run) a true no-op for rows already archived —
never a duplicate-key error, never a second `events_archive` row for the same event.

**Phase 2 — payload-sidecar cleanup + confirmed delete:**

```
BEGIN;
DELETE FROM event_payload_store
WHERE event_id IN (SELECT event_id FROM events WHERE (event_id, created_at) IN (T));
  -- must run BEFORE the DELETE below, in the SAME transaction: event_payload_store's
  -- FK to events is ON DELETE RESTRICT (20260816120004_create_event_payload_store.exs),
  -- so deleting the parent `events` row first would raise a foreign-key violation for
  -- any archived event that had an oversized payload. Doing both deletes in one
  -- transaction also means there is never a commit-visible window where an `events` row
  -- still exists but its `event_payload_store` sidecar is already gone (which would
  -- break read/2's $ref resolution, §4.4, for any not-yet-deleted row of an in-progress
  -- archive run) -- this is exactly why this cleanup step is NOT folded into phase 1.

DELETE FROM events
WHERE (event_id, created_at) IN (T)
  AND EXISTS (
    SELECT 1 FROM events_archive a
    WHERE a.event_id = events.event_id AND a.created_at = events.created_at
  );
  -- "confirmed" half of insert-then-delete-confirmed: only ever deletes a row this
  -- call (or a prior partial run) has ALREADY durably copied into events_archive --
  -- never derived from "T says it's eligible" alone.
COMMIT;
-- moved_count = the row count this DELETE actually affected.
```

**Idempotency walkthrough (acceptance criterion 4 — "calling archive/1 twice in a row
moves the same rows the first time and zero additional rows the second time"):**

- **Call 1** (nothing yet archived): T₁ = the full eligible set. Phase 1 inserts all of
  T₁. Phase 2 deletes all of T₁ (every row is now confirmed present in `events_archive`).
  `moved_count = |T₁|`.
- **Call 2**, immediately after (same `retention_days`, no time has meaningfully passed):
  §7.1's classification re-runs against `events` as it now stands — every row in T₁ has
  already been deleted from `events`, so it can no longer appear in any eligible set.
  T₂ = ∅. Phase 1 inserts nothing, phase 2 deletes nothing. `moved_count = 0`. Matches
  the acceptance criterion exactly.
- **Crash between phase 1 and phase 2** (any call): phase 1 already committed, so the
  affected rows exist in both `events` and `events_archive`. The *next* `archive/1` call
  (of any kind — a literal retry or just the next scheduled run) recomputes T from
  `events`, which still contains these rows (phase 2 never ran) — so they're
  re-identified, phase 1 re-runs as a guaranteed no-op (`ON CONFLICT DO NOTHING`), and
  phase 2 now runs for the first time and deletes them. Net effect: rows end up moved
  exactly once, regardless of how many partial re-runs occur in between.

### 7.4 OQ-2 resolution: option (a) — inline the payload at archive time

Per §0's citation of `req023-event-store-schema.md` §9 OQ-2, three candidates existed:
(a) inline into `events_archive.payload`, dropping `$ref` for archived events; (b) a
sibling `events_archive_payload_store` table; (c) re-point `event_payload_store` at the
archive row. **This design chooses (a)**, via phase 1's `LEFT JOIN
event_payload_store` + `COALESCE` (§7.3): every row landing in `events_archive` carries
its **fully resolved** payload directly, never a `$ref` pointer — regardless of whether
the source `events` row was inline or oversized.

**Reasoning:** (b) adds a seventh table with no simplification it buys in return —
scope creep beyond REQ-026's named acceptance criteria. (c) requires altering
`event_payload_store`'s already-shipped FK shape (REQ-023, already merged) — a
higher-blast-radius change to a table this requirement does not otherwise need to touch.
(a) is achieved entirely within phase 1's own `INSERT ... SELECT`, requires no schema
change to `events_archive` (`payload` is already `:map`/`jsonb`, §0's confirmed field
list), and directly unblocks phase 2's `DELETE FROM events` by construction (§7.3's
ordering: the `event_payload_store` sidecar row is deleted in phase 2 immediately before
its parent `events` row, in the same transaction, satisfying the `RESTRICT` FK).

**Resulting invariant, stated explicitly (§10, INV-AR-3):** `events_archive.payload`
**never** contains a `{"$ref": ...}` pointer — always the real, fully-resolved payload
content. A future "read from the archive" function (out of scope here, §1) never needs
`$ref` resolution at all, as a direct consequence.

### 7.5 Lock-scope statement (invariant 12 — must not lock `instance_projections`/`instance_sequence`)

**Neither phase's query references `instance_projections` or `instance_sequence` at
all** — not in a `JOIN`, not in a subquery, not in a `WHERE` clause. Invariant 12 is
satisfied **by construction/scope**, not by an active precaution against a lock that
would otherwise be taken: there is nothing in either phase's SQL that could acquire a
lock on those two tables even incidentally. This is stated as the explicit lock-scope
answer required by this run's task briefing: **what IS locked** is ordinary Postgres
row-level locking implied by phase 1's `INSERT ... SELECT` (shared read access to the
matched `events`/`event_payload_store` rows for the statement's duration — no explicit
`FOR UPDATE`/`FOR SHARE` clause is used anywhere in this design) and phase 2's `DELETE`
(exclusive row-level locks on exactly the rows being deleted, for that statement's
duration only). **What is NOT locked, at any point:** any row of `instance_projections`
or `instance_sequence`, and no table-level lock on `events` itself (no `LOCK TABLE`,
no `SELECT ... FOR UPDATE` sweeping the whole table).

---

## 8. `event_retention_policies` — migration + schema module

### 8.1 Table specification

| Column | Ecto migration type | DB type | Null / default | Notes |
|---|---|---|---|---|
| `id` | `:binary_id`, `primary_key: true` | `uuid` | `NOT NULL` (PK) | Decision A surrogate PK, matching every table in this codebase. |
| `event_type` | `:string` | `varchar(255)` | `NOT NULL` | The event type name this policy governs — same string domain as `event_type_registry.name`/`events.event_type`, but this table is GLOBAL (§6) so no FK to either (both are PER_TENANT). |
| `policy` | `:string` | `varchar(255)` | `NOT NULL`, `default: "keep_forever"` | `Ecto.Enum` over `[:keep_forever, :keep_days, :keep_count]` at the schema-module level (§8.3); plain `:string` at the migration/DDL level with a CHECK constraint (§8.4) — matches R-Co's plain-text-column-plus-CHECK shape per `requirements.yaml:1146-1150`, rather than a native Postgres `ENUM` type (no acceptance criterion requires one, and every other enum-shaped column in this codebase — `process_definitions.status`, `instance_projections.status` — already uses this same string+`Ecto.Enum` pattern, not a DB enum type). |
| `keep_days` | `:integer` | `integer` | nullable | Required (and `> 0`) **only** when `policy = 'keep_days'`, enforced by `chk_keep_days` (§8.4) — never a companion of any other policy value. |
| `keep_count` | `:integer` | `integer` | nullable | Required (and `> 0`) **only** when `policy = 'keep_count'`, enforced by `chk_keep_count` (§8.4). |
| `created_at` / `updated_at` | via `timestamps/1` | `timestamp` (precision 6) | `NOT NULL` | `timestamps(inserted_at: :created_at, type: :utc_datetime_usec)` — the literal column-name-preservation idiom already established by `process_definitions`/`instance_projections` (`req023`/`req027`'s own citation of this exact rename), used here because `requirements.yaml:1147-1150` names the columns `created_at`/`updated_at` literally (R-Co's own names on `003_event_archive.sql`'s retention table), not Ecto's default `inserted_at`. |

**Primary key:** `(id)`.

**Indexes:**

| Index name | Columns | Unique | Why |
|---|---|---|---|
| *(PK)* | `(id)` | yes | Decision A. |
| `uq_retention_policy_event_type` | `(event_type)` | **yes** | `requirements.yaml:1147`'s literal "event_type (unique)" — at most one policy row per event type, matching R-Co's `003_event_archive.sql` shape and making §7.1's `LEFT JOIN event_retention_policies p ON p.event_type = e.event_type` produce at most one matching row per event, never a fan-out. |

### 8.2 CHECK constraints (acceptance criterion 5) — exact predicates, a stated
interpretation

`requirements.yaml:1150` names three constraints by name
(`chk_retention_policy`/`chk_keep_days`/`chk_keep_count`) but does not give their literal
SQL. This design's own interpretation, following the standard "one active-policy value
gates exactly one required companion column, all others must be null" shape:

```
chk_retention_policy:
  CHECK (policy IN ('keep_forever', 'keep_days', 'keep_count'))

chk_keep_days:
  CHECK (
    (policy = 'keep_days' AND keep_days IS NOT NULL AND keep_days > 0)
    OR
    (policy <> 'keep_days' AND keep_days IS NULL)
  )

chk_keep_count:
  CHECK (
    (policy = 'keep_count' AND keep_count IS NOT NULL AND keep_count > 0)
    OR
    (policy <> 'keep_count' AND keep_count IS NULL)
  )
```

Effect: a `policy = 'keep_forever'` row must have both `keep_days` and `keep_count`
`NULL` (neither constraint's first branch matches `'keep_forever'`, so both fall to
their second branch, which requires `NULL`). A `policy = 'keep_days'` row must have a
positive `keep_days` and a `NULL` `keep_count`, and symmetrically for `keep_count`. This
is flagged as an interpretation (§0), not a literal quotation — CODE-DESIGN-VALIDATOR/
REVIEWER should treat the constraint *names* as required verbatim (`requirements.yaml`'s
own text) and the predicates above as this design's best-effort reconstruction of their
evident intent.

### 8.3 `Ecto.Schema` module — `Letflow.EventStore.RetentionPolicy`

```
# Letflow.EventStore.RetentionPolicy
#   @primary_key {:id, :binary_id, autogenerate: true}
#   schema "event_retention_policies" do
#     field :event_type, :string
#     field :policy, Ecto.Enum, values: [:keep_forever, :keep_days, :keep_count],
#                    default: :keep_forever
#     field :keep_days, :integer
#     field :keep_count, :integer
#     timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
#   end
#   NO @schema_prefix -- and unlike every other event-store schema module, this is not
#   because the table is per-tenant-schema-scoped -- it is because this table is GLOBAL
#   (§6) and lives in Ecto's single default/public schema, needing no prefix: at all,
#   the same reason Letflow.Identity.Tenant carries none.
#
#   insert_changeset/2 -- the ONLY changeset this module exposes (§1's scope boundary:
#   no update/delete API is built by this requirement):
#     cast: [:event_type, :policy, :keep_days, :keep_count]
#     validate_required: [:event_type, :policy]
#     validate_number(:keep_days, greater_than: 0)   -- when present; absent is valid
#     validate_number(:keep_count, greater_than: 0)  -- when present; absent is valid
#     unique_constraint(:event_type, name: :uq_retention_policy_event_type)
#     check_constraint(:policy, name: :chk_retention_policy)
#     check_constraint(:keep_days, name: :chk_keep_days)
#     check_constraint(:keep_count, name: :chk_keep_count)
```

`Ecto.Changeset.validate_number/3`'s app-level `keep_days`/`keep_count > 0` checks are
deliberately redundant with the DB-level CHECK constraints (§8.2) — the same
belt-and-suspenders shape `InstanceSequence.insert_changeset/2` already uses for
`next_seq`. The app-level check produces a typed `Ecto.Changeset` error for the common
case (e.g. a test seeding a policy with `keep_days: -1`); the DB constraint is the
non-bypassable backstop against any insert path that skips the changeset.

### 8.4 Migration file

`priv/repo/migrations/<UTC-timestamp>_create_event_retention_policies.exs`,
`Letflow.Repo.Migrations.CreateEventRetentionPolicies`. **GLOBAL — no `if prefix() do`
guard** (§6), matching `20260816090045_create_tenant_schemas.exs`'s and
`20260817083801_create_solution_pack_installs.exs`'s structural shape exactly:

```
# create table(:event_retention_policies, primary_key: false) do
#   add :id, :binary_id, primary_key: true
#   add :event_type, :string, null: false
#   add :policy, :string, null: false, default: "keep_forever"
#   add :keep_days, :integer
#   add :keep_count, :integer
#   timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
# end
#
# create unique_index(:event_retention_policies, [:event_type],
#          name: :uq_retention_policy_event_type)
#
# create constraint(:event_retention_policies, :chk_retention_policy,
#          check: "policy IN ('keep_forever', 'keep_days', 'keep_count')")
# create constraint(:event_retention_policies, :chk_keep_days,
#          check: "(policy = 'keep_days' AND keep_days IS NOT NULL AND keep_days > 0)
#                   OR (policy <> 'keep_days' AND keep_days IS NULL)")
# create constraint(:event_retention_policies, :chk_keep_count,
#          check: "(policy = 'keep_count' AND keep_count IS NOT NULL AND keep_count > 0)
#                   OR (policy <> 'keep_count' AND keep_count IS NULL)")
```

Reversibility (`backend_developer_guide.md` §3.7): `create table`/`create unique_index`/
`create constraint` are all auto-reversible by `change/0`; no `execute/1` needed anywhere
in this migration.

**Timestamp prefix:** ELIXIR-DEV generates a real UTC-clock value at implementation
time, subject to the one hard constraint that matters here: it must sort strictly after
`20260817083803` (the latest currently-shipped migration, `create_pack_update_resolutions.exs`)
so it applies last relative to everything already merged.

### 8.5 No CRUD API — restated from §1

PROVENANCE (historical, not current decision authority):
`RetentionPolicy.insert_changeset/2` is the only public write surface this requirement
adds for this table. No `Letflow.EventStore.upsert_retention_policy/2`-equivalent
function is built — R-Co's `Store.upsertRetentionPolicy()` (cited in `req023`'s OQ-1,
`store.zig:1240`) is not ported by this requirement. TEST-DESIGNER seeds policy rows
directly via `Repo.insert(RetentionPolicy.insert_changeset(%RetentionPolicy{}, attrs))`
to demonstrate acceptance criteria 5-6, the same "schema-module-only, no context-module
CRUD" pattern `req027-definition-core-schema.md` used for `process_definitions`.

---

## 9. `$ref` payload resolution — shared mechanism (reused from REQ-023/025, not reinvented)

Both `read/2` (§4.4) and `read_global/1` (§5.4) need this. One private helper,
conceptually:

```
resolve_payloads(events, schema_name) ::
  {:ok, [Event.t()]} | {:error, {:payload_resolution_failed, Ecto.UUID.t()}}

1. ref_event_ids = for e <- events, match?(%{"$ref" => _}, e.payload), do: e.payload["$ref"]
   (an empty list short-circuits to {:ok, events} unchanged -- the common case, no
   oversized payloads in this batch)

2. ONE batched query (never N+1):
     SELECT event_id, payload FROM event_payload_store
     WHERE event_id IN (ref_event_ids)
     (prefix: schema_name)
   using StoredPayload's own uq_event_payload_event single-column unique index
   (event_payload_store.ex's own moduledoc: "join is O(1) per row" -- event_id alone
   suffices, event_created_at is NOT needed to resolve a $ref, since the index is
   single-column).
   -> resolved_map = %{event_id => payload}

3. For each event in the original list:
     - payload is %{"$ref" => id} AND resolved_map has id -> substitute resolved payload
     - payload is %{"$ref" => id} AND resolved_map is missing id ->
         {:error, {:payload_resolution_failed, id}}  -- ABORTS THE WHOLE CALL, not a
         per-row skip. A missing sidecar for a referenced event is a data-integrity
         violation, not a normal "this one event has no payload" case.
     - payload is anything else (already inline) -> unchanged
```

This is the same split-payload contract REQ-025's `append/2` established
(`event_store.ex:450-455`: `%{"$ref" => event_id}` when `payload_bytes >
@payload_inline_max_bytes`) — REQ-026 is the read-side half of that same mechanism, not
a new one.

---

## 10. Invariants

| ID | Statement | Enforced by | Citation |
|---|---|---|---|
| INV-RD-1 | `read/2` returns `{:error, :instance_not_found}`, never `{:ok, []}`, when `instance_id` has no `instance_sequence` row. `{:ok, []}` is reserved for an instance that exists (has an `instance_sequence` row) but currently has zero matching `events` rows (e.g. fully archived, or filtered past). | §4.2's two-step lookup order | `requirements.yaml`'s acceptance criterion 2 |
| INV-RD-2 | `read/2`'s ordering is always `sequence_number ASC`; `read_global/1`'s is always `global_seq ASC`. Neither function ever exposes a caller-controlled sort order. | §4.2 STEP 2, §5.3 | `requirements.yaml`'s ES-02/ES-04 citations |
| INV-RD-3 | `up_to_sequence` and `up_to_timestamp` are mutually exclusive in effect — when both given, only `up_to_sequence` is applied. | §4.3 | `requirements.yaml:1122-1124`, ES-06 |
| INV-RD-4 | No public read function in this module ever returns a raw `{"$ref": ...}` payload pointer. `{:error, {:payload_resolution_failed, event_id}}` is returned instead of leaking one. | §9 | acceptance criterion 1; §5.4's stated extension to `read_global/1` |
| INV-AR-1 | `archive/1` is idempotent: calling it twice with the same `retention_days` and no elapsed time moves the eligible set once, then zero rows. | §7.3's two-phase, `ON CONFLICT DO NOTHING` + confirmed-delete shape | acceptance criterion 4; `event_store.md` invariant 11 (per `requirements.yaml:1137-1139`) |
| INV-AR-2 | `archive/1` never queries, joins, or locks `instance_projections` or `instance_sequence`. | §7.5 | acceptance criterion (implicit, `event_store.md` invariant 12, `requirements.yaml:1139-1140`) |
| INV-AR-3 | `events_archive.payload` never contains a `{"$ref": ...}` pointer — always the fully-resolved payload, inlined at archive time. | §7.3 phase 1's `LEFT JOIN`/`COALESCE`, §7.4 | This design's own resolution of REQ-023 §9 OQ-2 |
| INV-AR-4 | A `policy = 'keep_forever'` row makes its `event_type` permanently ineligible for archival, regardless of `retention_days`. | §7.1 rule 1 | `requirements.yaml`'s "policy default keep_forever" framing |
| INV-AR-5 | `retention_days = 0` archives nothing for event types with no explicit policy row (as opposed to being treated as "archive everything immediately," the opposite misreading of "0"). | §7.1 rule 4b | `requirements.yaml:1134-1136`, literal |
| INV-EV-1 (restated) | `Letflow.EventStore.Event`/`ArchivedEvent` remain append-only — this requirement adds no `update_changeset/2` to either. | Unchanged from REQ-023 | 0003 Decision C point 1 |
| INV-RP-1 | `event_retention_policies` carries no `tenant_id` column and no `:prefix` — it is GLOBAL, one row per `event_type` platform-wide. | §6, §8.1 | This design's own classification, §6 |

---

## 11. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` | `read/2`/`read_global/1`/`archive/1` → REQ-022 | Reused unchanged from `append/2`'s own established call — validates `prefix` resolves to a real tenant before any query runs. |
| `Letflow.EventStore.{Event, InstanceSequence, ArchivedEvent, StoredPayload}` | REQ-026 → REQ-023 | All four schema modules consumed as-is, no field/changeset changes. `ArchivedEvent.insert_changeset/2` is the one REQ-026 actually calls (phase 1, §7.3) — its cast/required-field list already accommodates the resolved (never-`$ref`) payload this design writes (§7.4). |
| `Letflow.EventStore.RetentionPolicy` | REQ-026 → REQ-026 (new, this design) | Read by `archive/1`'s classification query (§7.1); written only by direct `Repo.insert/2` calls (test seeding, §8.5) — no context-module function of this module's own writes it. |
| `Letflow.Repo` | REQ-026 → `lib/letflow/repo.ex` | Every query in this design passes `prefix: schema_name` explicitly (INV-EV-8) except `event_retention_policies` queries, which pass no prefix at all (GLOBAL, §6). |
| `event_store.ex`'s existing `append/2` | sibling, same module | This design extends the same module/file `append/2` already lives in — no new top-level module is created for `read/2`/`read_global/1`/`point_in_time/3`/`archive/1`/the sentinels. |

---

## 12. Open questions — explicitly listed, not silently resolved

PROVENANCE (historical, not current decision authority):
**OQ-1 (MAJOR): the three platform sentinel constants' exact UUID string values are
unknown.** `platform.zig` is unreachable (§0). This design specifies the accessor
function shape (§3) but not the literal values. ELIXIR-DEV must either (a) locate the
real R-Co source before Step 2a and port the literal values, or (b) pick three
syntactically-valid, pairwise-distinct placeholder UUIDs and flag the substitution
explicitly in the implementation's moduledoc/handoff (the same "flagged, not silently
worked around" discipline this design itself follows) — never silently invent values
that read as verified when they are not.

**OQ-2 (MAJOR): the GLOBAL classification of `event_retention_policies` against a
PER_TENANT `event_type_registry` is a real, unresolved tension**, restated from §6: a
single global policy per `event_type` string applies uniformly across every tenant's own
independently-registered type of that name, with no guarantee those are the same kind of
event. Not resolved here — flagged for REVIEWER, in the same spirit `req041` §2 flags its
own GLOBAL-vs-PER_TENANT general question, and should be read together with it.

**OQ-3 (MINOR): no function reads events back out of `events_archive`.** `archive/1`
writes it; nothing reads it. Not in scope per REQ-026's acceptance criteria (§1), but
recorded so a future requirement doesn't have to rediscover the gap.

**OQ-4 (MINOR): `archive/1`'s target-set T is computed and processed in one pass, with no
batching/chunking for very large tenants.** Not required by any acceptance criterion
(all are demonstrable with a handful of rows); flagged as a plausible future
enhancement, not a defect of this design.

**OQ-5 (MINOR): `keep_count` policy scope is this design's own interpretation** (§7.1
rule 3 — ranked tenant-schema-wide per `event_type`, not per-instance), since no
reachable source confirms this either way. If R-Co's real semantics differ (e.g.
per-instance `keep_count`), this is the specific rule to revisit.

**OQ-6 (MINOR): `read_global/1`'s negative-`limit` clamp-to-1 behavior (§5.2) is an
extrapolation**, not a literal quotation of `requirements.yaml`'s text (which only states
the `0 -> 100` and `1..1000` bounds explicitly, not what happens below `0`). Flagged so
CODE-DESIGN-VALIDATOR can confirm this reading rather than take it as settled.

---

## 13. Traceability — every acceptance criterion mapped to a concrete design element

PROVENANCE (historical, not current decision authority):
| # | Acceptance criterion (paraphrased) | Design element |
|---|---|---|
| 1 | `read/2` returns exactly N events for an instance, ascending `sequence_number`, `$ref` transparently resolved | §4.2 STEP 2 (ordering), §4.4 + §9 (`$ref` resolution) |
| 2 | `read/2` against an instance with no events returns an explicit not-found error, not `[]` | §4.2's two-step lookup order; INV-RD-1 |
| 3 | `read_global/1` with `after_global_seq` returns only strictly-greater-`global_seq` events, across ≥2 instances' interleaved events | §5.1 (`WHERE global_seq > N`), §5.3 (no `instance_id` filter — all instances) |
| 4 | `archive/1` called twice moves the same rows once, zero the second time | §7.3's full idempotency walkthrough; INV-AR-1 |
| 5 | `event_retention_policies` exists with the exact column list and three named CHECK constraints | §8.1 (columns/index), §8.2 (constraint predicates), §8.4 (migration) |
| 6 | `archive/1` against an event type with an explicit policy row uses that policy over the global fallback, demonstrated with a policy producing a different moved-row set | §7.1 (precedence rules 1-4), §7.3 (T computed from the classification that already applies this precedence) |
| 7 | The three platform sentinel constants exist, accessible from the context module, each documented citing `platform.zig` | §3 |

Additionally addressed, not named as a numbered acceptance criterion but load-bearing
for criteria 4/6 to be implementable at all: REQ-023 §9 OQ-1 (§8, table now exists) and
OQ-2 (§7.4, payload-survival resolved).
