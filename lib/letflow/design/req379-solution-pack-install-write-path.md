# REQ-379 — Solution-pack install-tracking write path: `solution_pack_artefact_bases` capture at real install time

Owner: `ELIXIR-DEV`. Stage S2. `depends_on: [REQ-041]`.

## 0. CRITICAL CORRECTION to this requirement's own premise — verify before building

REQ-379's `docs/requirements.yaml` description, and the GUI-review report it was filed
from (`test/uat-reports/gui-review-2026-09-20-template-update-conflict-resolution.md`),
both assert: *"Grepping lib/ confirms no caller anywhere ever inserts a
`SolutionPackInstall` ... row today; [the] table is permanently empty in every real
deployment."*

**This is false, and checkably so as of this design (2026-09-22).**
`Letflow.Definitions.SolutionPack.install/3` (`lib/letflow/definitions/solution_pack.ex`)
already inserts a `solution_pack_installs` row on every successful install, via
`insert_install_row/2` (private, lines 983-1003) →
`Letflow.Definitions.SolutionPackInstall.insert_changeset/2`. This landed under
**REQ-078** (commit `92fd7a6e`, "REQ-078: solution packs + the single shared
variable_schemas insert path", **2026-08-22** — four weeks before the 2026-09-20 review
that claimed the write path didn't exist). `Letflow.Routers.SolutionPacks`'s
`render_install/2` already has a live clause for `{:error, :duplicate_pack_install}` —
the exact conflict `uq_solution_pack_install_active` produces — which only exists
because the insert path is real and reachable.

Per `core-directives.md`'s "This chain governs what you are told to DO, not what you are
told IS TRUE" and `HANDOFF_PROTOCOL.md` §1.1 ("A handoff's factual premises are
checkable, and may be wrong"): the requirement's **acceptance criteria still bind** (they
describe required, testable behaviour, and AC1 happens to already hold), but the
requirement's **narrative description of what's missing is stale and must not be
inherited uncritically**. This finding must be reported to ORCH as a MINOR
`result.issues` entry against REQ-379/the GUI-review report — not silently corrected in
place — so `docs/requirements.yaml` and the review report get fixed at the source. This
design proceeds on the **re-verified** state below, not the requirement text's claim.

**What is actually true, re-verified by direct source read:**

| Claim | Verified state |
|---|---|
| `solution_pack_installs` row insert | **Already exists and is correct** — `insert_install_row/2` inserts `tenant_id` (derived), `pack_id`, `installed_version`, `installed_at` (`DateTime.utc_now/0` truncated to `:microsecond`) on every successful install. This already satisfies AC1's behavioural requirement. |
| `solution_pack_artefact_bases` row insert | **Confirmed absent.** `grep -n "artefact_base\|ArtefactBase" lib/letflow/definitions/solution_pack.ex` → zero hits. This table is genuinely never written by any caller today. **This is the real, sole functional gap this requirement closes.** |
| Migrations for both tables | **Already exist** (REQ-041, `priv/repo/migrations/20260817083801_create_solution_pack_installs.exs` and `..._083802_create_solution_pack_artefact_bases.exs`) — **no new migration is needed for this requirement.** |
| `Letflow.Definitions.SolutionPackArtefactBase` schema + changeset | **Already exists** (`lib/letflow/definitions/solution_pack_artefact_base.ex`) — `upsert_changeset/2` (structural cast/validate only, no I/O) casts and requires `tenant_id, pack_id, artefact_type, artefact_id, base_version, base_content, captured_at`, with `unique_constraint([:tenant_id, :pack_id, :artefact_type, :artefact_id], name: :uq_solution_pack_artefact_base)`. Reused as-is (see §4 for why its "wholesale-replace" write semantics are NOT what this requirement's own write call site uses). |
| `Letflow.Definitions.compute_pack_update_plan/5` | **Already exists and is correct** (REQ-041, `lib/letflow/definitions.ex:401-449`); its `fetch_base/4` private helper already queries `solution_pack_artefact_bases` by `(tenant_id, pack_id, artefact_type, artefact_id)` exactly as this design's writes key it. **No change to `definitions.ex` is needed** — AC4 is closed purely by this requirement finally producing real rows for that existing query to find. |

**Net scope of this requirement, corrected:** one new write step inside
`Letflow.Definitions.SolutionPack.install/3`'s existing transaction, capturing
`solution_pack_artefact_bases` rows for every process definition the install creates,
with insert-if-absent (never-overwrite) semantics. No migration, no schema-module
change, no `definitions.ex` change, no router change beyond nothing (the route already
calls `install/3`; this requirement changes what `install/3` does internally).

---

## 1. What "artefact" means for this requirement — scope decision, not silently guessed

The pack document (`SolutionPack.pack_document/0`) carries four content arrays:
`definitions` (process definitions), `variable_schemas`, `entity_definitions`, and the
always-empty `service_catalog_entries`. AC2 says "one `solution_pack_artefact_bases` row
per delivered artefact" without naming which array(s) count.

**Decision: this requirement captures a base snapshot for `definitions` (process
definitions) only** — `artefact_type: "process_definition"`. `variable_schemas` and
`entity_definitions` are explicitly **not** captured by this requirement. Reasoning,
stated rather than assumed:

1. The originating scenario (`template-update-conflict-resolution`,
   `test/fixtures/uat/scenarios/platform/template-update-conflict-resolution.yaml`) is
   about process **templates** — process definitions — not variable schemas or entity
   definitions. Every worked example in the GUI-review report and in REQ-041's own design
   doc's illustrative `artefact_type` list treats a definition's graph as the unit.
2. `classify_artefact/3` requires `base_content` to already be **canonical-JSON text**
   (`lib/letflow/definitions.ex:457-459`). A process definition's `graph` (a map) has an
   obvious, already-precedented canonicalization path (see §3). Neither
   `variable_schemas`' `schema_content` (already a JSON *string* in the pack document,
   §"packed_variable_schema" — a different canonicalization question: is the already-JSON
   string re-canonicalized, or trusted as-is?) nor `entity_definitions`' `definition_json`
   has an equivalent settled answer anywhere in the codebase. Guessing one here would be
   exactly the "silently resolve an open question" failure mode this role must not commit.
3. Every AC (1-4) is fully satisfiable — including AC4's four-classification proof —
   using process-definition artefacts alone; no AC requires a second artefact type.

**OPEN QUESTION (OQ-1, not resolved here, flag for REVIEWER/a future requirement):**
should `variable_schemas` and/or `entity_definitions` also get base-snapshot capture at
install time, and if so what is their canonical-JSON form? Left for a follow-up
requirement once REQ-380 (which consumes this data) or a later pack-format decision
states a concrete need. Not silently pulled into this requirement's scope.

---

## 2. `artefact_id` key choice — must anticipate REQ-380's future `theirs` lookup

`compute_pack_update_plan/5` keys `base`/`theirs`/`incoming` by the identical
`(artefact_type, artefact_id)` tuple (`lib/letflow/definitions.ex:411-420`). `theirs` (the
tenant's live current content) is explicitly **out of this requirement's schema** —
REQ-041's design says it is "read from wherever the tenant's live process/artefact
content already lives" — which for a process definition is
`Letflow.Definitions.ProcessDefinition`, keyed by that table's own `id` (a `binary_id`,
tenant-schema-local, i.e. `Ecto.UUID.t()`), not by the pack document's
`packed_definition.definition_id` (the **source** tenant's id, meaningless in the
installing tenant's own schema).

**Decision: `artefact_id` = the newly-created `ProcessDefinition.id` in the installing
tenant's own schema** (`created.id` from `create_packed_definitions/3`'s existing
`{packed, created}` accumulator), **not** `packed.definition_id` (the source id). This is
the only choice under which a future `theirs` lookup by this same key against the
installing tenant's own `process_definitions` table can ever resolve to a row — using
the source id would produce a `base` row whose `artefact_id` matches nothing the
installing tenant's own schema ever contains, permanently forcing every entry to the
`nil`-base `:conflict` classification regardless of true state. Stated as a decision with
its reasoning, not left as an unstated assumption for REQ-380 to discover the hard way.

---

## 3. `base_content` canonicalization — reuse the existing precedent algorithm, don't invent a new one

`SolutionPackArtefactBase`'s own moduledoc states `base_content` "MUST already be
canonical-JSON text (sorted keys, no insignificant whitespace) by the time it is
written — this [schema] module does not itself provide the canonicalization step."
`classify_artefact/3`'s moduledoc explicitly declines to "reimplement REQ-036's
canonicalization as a private duplicate" because REQ-036 (`compute_plan_digest`-style
canonicalization as a *public*, shared helper) is still `status: pending`.

A canonicalization algorithm already exists in this codebase, privately, in
`Letflow.Definitions.PromotionDigest.canonicalize/1`
(`lib/letflow/definitions/promotion_digest.ex:53-64`, four steps: recursively sort map
keys via `Enum.sort/1` on `Map.keys/1`, rebuild as `Jason.OrderedObject.new/1` so sorted
order survives encoding, map over lists without reordering them, convert atoms via
`Atom.to_string/1`, pass everything else through unchanged; then `Jason.encode!/1`, which
emits no insignificant whitespace by default). It is `defp`, so this requirement's code
cannot call it directly across modules.

**Decision: this requirement's write path uses the *identical* four-step algorithm**
(same key-sort, same `Jason.OrderedObject.new/1` rebuild, same list/atom/passthrough
rules, same `Jason.encode!/1` finish) as a new **private** helper local to
`Letflow.Definitions.SolutionPack`, applied to each packed definition's `graph` map
(the pack document's own delivered value — AC2 says base must match "the pack's own
delivered content exactly," so the canonicalization input is `packed.graph`, not a
re-read of the just-inserted `ProcessDefinition` row, even though the two are expected to
carry the same map). This is a second, independent implementation of the same algorithm,
not a shared call — flagged here as **OQ-2**: a third near-identical canonicalizer
appearing (after `PromotionDigest.canonicalize/1` and `Letflow.Repository.Canonicaliser`,
REQ-202, which is deliberately different — it also normalizes numbers) is exactly the
kind of drift `docs/anti-patterns.md` warns about; REVIEWER should judge whether this is
the point at which a shared `Letflow.Definitions.CanonicalJson.encode/1`-style extraction
becomes worth doing now rather than continuing to duplicate. Not resolved unilaterally
here because REQ-041's `classify_artefact/3` moduledoc already declined to make that call
once before, for a documented reason (avoiding coupling to REQ-036 before it exists) —
this design does not silently overrule that.

`base_version` = `parsed.version` (the pack's own installed version — identical to the
`installed_version` written into `solution_pack_installs` in the very same transaction),
matching REQ-041 design §3.2's stated meaning of that column.

`captured_at` = the same `DateTime.utc_now/0` (truncated `:microsecond`) instant computed
once at the top of `run_install/5` and reused for both `solution_pack_installs.installed_at`
and every artefact base row's `captured_at` in this install — not a fresh clock read per
row, so every row from one install shares one install timestamp exactly, and the two
tables' timestamps for the same install can never disagree by clock jitter.

---

## 4. The never-overwrite write: insert-if-absent, NOT `upsert_changeset/2`'s implied replace

**This is the crux of AC3, and it requires deliberately diverging from what
`SolutionPackArtefactBase.upsert_changeset/2`'s own moduledoc anticipated.** That
moduledoc (written by REQ-041) says: *"this row's whole reason for existing is to be
replaced wholesale ... each time a future install/update-application requirement
completes."* AC3 requires the **opposite** behaviour for install-time capture
specifically: *"re-installing the same version does NOT overwrite an existing base
snapshot for an artefact the tenant has since locally adapted."*

These are not actually in conflict once the two write *call sites* are told apart:

- **This requirement's call site (install-time capture):** must be insert-if-absent.
  The base snapshot is "what the pack delivered at the moment it first became this
  artefact's reference point" — it must never move just because the same content was
  installed again, precisely because a tenant may have since diverged from it (AC3's own
  wording — "the tenant has since locally adapted").
- **A hypothetical future call site (REQ-380's apply-a-resolved-update flow, not built
  here — SCOPE FENCE):** *would* legitimately want wholesale replace — after an update is
  applied and a conflict resolved, the base should advance to the new content so a later
  update-review doesn't re-flag the same already-resolved artefact (EO-005, REQ-380's own
  acceptance criteria). `upsert_changeset/2`'s moduledoc was written anticipating that
  future call site, not this one.

**Decision: this requirement adds a new function,
`Letflow.Definitions.SolutionPack.capture_artefact_bases/4` (see §5 for its `@spec`),
that reuses `SolutionPackArtefactBase.upsert_changeset/2` only for its structural
cast/validate behaviour, and calls `Repo.insert/2` with
`on_conflict: :nothing, conflict_target: [:tenant_id, :pack_id, :artefact_type, :artefact_id]`**
— i.e. it targets the existing `uq_solution_pack_artefact_base` unique index and, on a
conflict, writes nothing and reports the pre-existing row's content untouched. This is
the standard idempotent-insert Ecto pattern already established elsewhere in this
context module for exactly the same reason
(`register_variable_schemas/3`, REQ-078's moduledoc: `"ON CONFLICT (definition_id,
variable_key) DO NOTHING"`), so this is a precedented pattern in this same file's
neighbourhood, not a new one. **The changeset function is not renamed** (still
`upsert_changeset/2`, unchanged) — only this call site's chosen `Repo.insert/2` options
diverge from what its moduledoc originally anticipated; that moduledoc should be
corrected in the same change to state both call sites' semantics explicitly rather than
only the future one (flagged for ELIXIR-DEV / REVIEWER as a doc-accuracy fix, not a
behavioural one).

---

## 5. New/changed function signatures

### 5.1 `Letflow.Definitions.SolutionPack.capture_artefact_bases/4` — NEW, public

```
@spec capture_artefact_bases(
        tenant_id :: Ecto.UUID.t(),
        pack_id :: String.t(),
        base_version :: String.t(),
        artefact_snapshots :: [artefact_snapshot()]
      ) :: {:ok, [SolutionPackArtefactBase.t()]} | {:error, Ecto.Changeset.t()}
```

Where the new type:

```
@type artefact_snapshot :: %{
        artefact_type: String.t(),
        artefact_id: Ecto.UUID.t(),
        content: map()   # the artefact's own delivered content, pre-canonicalization
      }
```

Behaviour:
- Must run **inside the caller's already-open `Repo.transaction/1`** (called from
  `run_install/5`, itself already inside `Repo.transaction/1` per existing code at
  `solution_pack.ex:960`) — no transaction of its own, matching every other step in
  `run_install/5`.
- For each `artefact_snapshot` (order-preserving): canonicalize `content` per §3, build a
  `SolutionPackArtefactBase.upsert_changeset/2` with `tenant_id`, `pack_id`,
  `artefact_type`, `artefact_id`, `base_version`, the canonicalized `base_content`, and
  the single shared `captured_at` instant (passed in, not read per row — see §3), then
  `Repo.insert/2` with `on_conflict: :nothing, conflict_target: [:tenant_id, :pack_id, :artefact_type, :artefact_id]`.
- `on_conflict: :nothing` means a conflicting insert returns the struct **as attempted**
  (Ecto's documented behaviour: the returned struct reflects what was cast, not
  necessarily the row now in the DB) with no autogenerated `:id` populated when no row
  was actually inserted — callers must not rely on the returned struct's `base_content`
  to reflect "what is now in the DB" for a row that pre-existed; the function's own
  `{:ok, [SolutionPackArtefactBase.t()]}` result is therefore documented as "the
  attempted snapshots, in order," not "the current DB state," and no AC depends on the
  return value distinguishing a fresh insert from a no-op skip. (If a future caller needs
  that distinction, `Repo.insert/2`'s `returning:` option combined with a second read, or
  switching to `Repo.insert_all/3` with `on_conflict: :nothing` and a `RETURNING`-based
  count, would be the mechanism — not needed by any AC here, so not built here.)
- A genuine changeset error (e.g. a future `artefact_id`/`artefact_type` value exceeding
  the 255-byte column limits validated by `upsert_changeset/2`) returns
  `{:error, changeset}` and — per `run_install/5`'s existing `with`/`else` pattern
  (`{:error, reason} -> Repo.rollback(reason)`) — aborts and rolls back the entire
  install, consistent with every other step's all-or-nothing behaviour. In practice this
  is unreachable for `artefact_id` (always a fresh `Ecto.UUID.generate/0`-minted 36-char
  string from `create_packed_definitions/3`) and `artefact_type` (the fixed literal
  `"process_definition"`), so this error branch exists for defensive completeness, not
  because it is expected to fire.

### 5.2 `Letflow.Definitions.SolutionPack.run_install/5` — CHANGED (private)

New step inserted immediately after the existing step 6
(`create_packed_definitions/3`, which already accumulates
`{packed_definition, %ProcessDefinition{} = created}` pairs — `solution_pack.ex:1014-1030`)
and before step 6a (`seed_pack_specific_field_restrictions/2`) — ordering choice: base
capture is a property of the definitions just created, independent of entity
definitions/schema registration, so it runs as soon as its inputs (the `installed` list)
exist, not gated on later steps succeeding first; if a later step (schema registration)
fails, the whole transaction still rolls back including these inserts, so ordering
relative to steps 7-8 has no observable effect on AC1-4.

```
with {:ok, install} <- insert_install_row(parsed, tenant_id, captured_at),
     {:ok, installed} <- create_packed_definitions(parsed.definitions, actor_id, opts),
     {:ok, _bases} <- capture_artefact_bases(tenant_id, parsed.pack_id, parsed.version,
                        artefact_snapshots_from(installed), captured_at),
     {:ok, installed_entities} <- create_packed_entity_definitions(...),
     ...
```

`artefact_snapshots_from/1` (new, private) maps the existing `installed` accumulator
(`[{packed_definition, %ProcessDefinition{}}]`) to
`[%{artefact_type: "process_definition", artefact_id: created.id, content: packed.graph}]`
— pure, no I/O, §2's key-choice and §1's scope decision applied mechanically.

`insert_install_row/2` gains a third argument, `captured_at` (the shared instant computed
once in `run_install/5`, replacing its own internal `DateTime.utc_now/0` call) so
`solution_pack_installs.installed_at` and every `solution_pack_artefact_bases.captured_at`
row from the same install share one instant (§3). Behaviourally identical for AC1 (still
"a real installed-at timestamp") — this is a refactor of *where* the clock is read, not a
change to what is recorded.

### 5.3 No change to `install_result`, `pack_document`, or any router/response type

Per the requirement's own SCOPE FENCE ("Does not build ... any HTTP route beyond
whatever install route already exists"): `install_result`'s public shape
(`solution_pack.ex:252-261`) is **not extended** with an artefact-base count or list. No
AC requires the install response to surface this data, and adding a field would touch
`Letflow.Routers.SolutionPacks.install_result_map/1`'s hand-built allowlist (INV-2) for
no acceptance-criterion benefit — left out deliberately, not an oversight.

### 5.4 No change to `Letflow.Definitions.compute_pack_update_plan/5`, `classify_artefact/3`, or `fetch_base/4`

Already correct (§0's table). AC4 is closed purely by `capture_artefact_bases/4` finally
producing rows for `fetch_base/4`'s existing query to find — zero lines of
`lib/letflow/definitions.ex` change.

---

## 6. DB schema — none changed, existing tables only

No new migration. For completeness (per WF-02 Step 1's checklist), the two tables this
requirement writes into, exactly as they exist today (REQ-041,
`priv/repo/migrations/20260817083801_create_solution_pack_installs.exs` and
`..._083802_create_solution_pack_artefact_bases.exs`):

| Table | Columns this write path sets | Constraint this write path's error handling depends on |
|---|---|---|
| `solution_pack_installs` (GLOBAL/public schema) | `tenant_id` (derived via `TenantProvisioning.tenant_id_for_schema_name/1`, never caller-supplied — INV-1), `pack_id`, `installed_version`, `installed_at` | `uq_solution_pack_install_active` on `(tenant_id, pack_id)` where `status = 'active'` → `{:error, :duplicate_pack_install}` (already-existing behaviour, unchanged) |
| `solution_pack_artefact_bases` (GLOBAL/public schema) | `tenant_id` (same derivation, same variable already in scope in `run_install/5` — no new derivation needed), `pack_id`, `artefact_type` (`"process_definition"`), `artefact_id` (`created.id`), `base_version`, `base_content` (canonicalized JSON text, §3), `captured_at` | `uq_solution_pack_artefact_base` on `(tenant_id, pack_id, artefact_type, artefact_id)` → `on_conflict: :nothing` (§4) — this is the mechanism, not a caught error tuple; no new `install_error()` member is needed for this path |

Both tables are already confirmed GLOBAL (not tenant-schema-prefixed) by REQ-041's design
and moduledocs — this requirement writes to both using the plain (no `:prefix`) `Repo`
calls the existing `insert_install_row/2` already uses, consistent with that
classification. INV-1 is satisfied the same way `solution_pack_installs`' existing insert
already satisfies it: `tenant_id` is derived from `opts[:prefix]` via
`TenantProvisioning.tenant_id_for_schema_name/1` inside the transaction, never accepted
as a caller-supplied field on either row.

---

## 7. Invariants

- **INV-ARTB-1 (AC3's core guarantee):** for a fixed `(tenant_id, pack_id, artefact_type,
  artefact_id)`, the first successful `capture_artefact_bases/4` call's `base_content`
  for that key is permanent — no later call, regardless of what `content` it is given,
  ever changes an existing row's `base_content`, `base_version`, or `captured_at`.
  Mechanism: `on_conflict: :nothing` targeting `uq_solution_pack_artefact_base` (§4) —
  this is a DB-enforced guarantee (the unique index), not merely an application-level
  convention, so it holds even under concurrent installs racing on the same key.
- **INV-ARTB-2:** `base_content` is byte-for-byte canonical-JSON text of the pack's own
  delivered `graph` for that definition at the moment of first capture (AC2) — never a
  re-derivation from the tenant's live `process_definitions` row after any later edit.
- **INV-ARTB-3:** every row this write path inserts has `artefact_id` equal to a real
  `ProcessDefinition.id` that exists, in the same transaction, in the installing tenant's
  own schema — never the pack's source-tenant `definition_id` (§2). A future `theirs`
  lookup (REQ-380, not built here) keyed the same way is therefore guaranteed resolvable
  against `process_definitions` for any artefact this requirement captured.
- **INV-ARTB-4 (transactional atomicity, unchanged from existing `run_install/5`
  behaviour):** if any step after base capture fails, the whole transaction — including
  the newly-inserted `solution_pack_installs` row, every created `ProcessDefinition`, and
  every `solution_pack_artefact_bases` row this install attempted — rolls back. There is
  no state where a `solution_pack_installs` row exists with no matching artefact bases
  for the definitions it claims to have installed (barring the deliberate zero-definitions
  case: a pack whose `definitions` array is empty legitimately installs zero artefact
  bases, which is not a violation of this invariant).

---

## 8. Cross-module dependencies

- `Letflow.Definitions.SolutionPack` (this module) → `Letflow.Definitions.SolutionPackArtefactBase`
  (existing schema, `upsert_changeset/2` reused for cast/validate — §4).
- `Letflow.Definitions.SolutionPack` → `Letflow.Repo` (already an existing dependency of
  this module — no new alias needed beyond what's already `alias`ed at the top of
  `solution_pack.ex`).
- No new dependency on `Letflow.Definitions` (the context module hosting
  `compute_pack_update_plan/5`) — that module depends on `SolutionPackArtefactBase`
  already (§0's table); this requirement does not add a reverse dependency, avoiding any
  new cross-module coupling.
- `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` — already called by
  `install/3` (line 422) to produce `tenant_id`; `capture_artefact_bases/4` reuses that
  same already-resolved value, no second lookup.

---

## 9. Acceptance-criteria → design-element map

| AC | Design element |
|---|---|
| AC1 — exactly one `solution_pack_installs` row, real `installed_at` | **Already satisfied by existing `insert_install_row/2`** (§0). This requirement's only touch is threading the shared `captured_at` instant through as an argument (§5.2) instead of an internal clock read — behaviourally identical. Proven by a **regression test confirming existing behaviour still holds** (§10.1) — not new production code, but still a required test per the AC's own "proven by a test" wording. |
| AC2 — one `solution_pack_artefact_bases` row per delivered artefact, `base_content`/`base_version` matching the pack's own delivered content byte-for-byte | §1 (scope: process definitions), §3 (canonicalization = pack's own `packed.graph`, not a DB re-read), §5.1 (`capture_artefact_bases/4`), §5.2 (wiring into `run_install/5`) |
| AC3 — re-install of the same version never overwrites an existing base for a locally-adapted artefact | §4 (insert-if-absent via `on_conflict: :nothing` targeting `uq_solution_pack_artefact_base`), INV-ARTB-1 |
| AC4 — `compute_pack_update_plan/5` against real rows from this write path classifies all four outcomes end-to-end | §0 (no change needed to `compute_pack_update_plan/5`/`fetch_base/4` — already correct and already queries this exact table/key shape), §10.4 (test design: install once for real `base` rows, hand-supply `theirs`/`incoming` per REQ-041's own stated caller-supplied contract for those two) |
| AC5 — `mix letflow.check` passes, real output quoted | Process requirement, not a design element — ELIXIR-DEV runs it at Step 2a and quotes real output; TEST-RUNNER/RELEASE-VALIDATOR re-verify independently per WF-02. |

---

## 10. Test design (for TEST-DESIGNER — direction, not authored here)

All tests live under `test/letflow/definitions/solution_pack_test.exs` (existing file —
confirm exact path/module name against the current test tree; extend, don't duplicate,
its existing `install/3` test group) plus possibly a small dedicated
`capture_artefact_bases/4` unit-test block in the same file, since it is a function of
the same module.

### 10.1 AC1 regression test
Install a pack with ≥1 definition for a fresh tenant. Assert: exactly one
`solution_pack_installs` row exists for `(tenant_id, pack_id)` (`Repo.all` count == 1,
not merely "at least one" — AC1 says "exactly one"), `installed_version` equals the
pack's `version`, and `installed_at` is a real, non-nil, recent `DateTime` (e.g. within
the test's own execution window — assert it is not a hardcoded/sentinel value and is
`<=` `DateTime.utc_now/0` at assertion time). This exercises **existing** code
(`insert_install_row/2`) plus this requirement's threading refactor (§5.2) — a genuine
regression test, not a no-op.

### 10.2 AC2 test
Export (or hand-construct, matching `export/3`'s real output shape) a pack document with
≥2 definitions with distinct, non-trivial `graph` maps (nested objects, so key-sort order
actually matters — a flat single-key map would not distinguish "canonical" from "any
serialization"). Install it. Assert: exactly one `solution_pack_artefact_bases` row per
installed definition (count matches `length(parsed.definitions)`), each row's
`artefact_type == "process_definition"`, `artefact_id` equals that definition's real
`ProcessDefinition.id` from the install result's `installed_definitions` list (§2's key
choice, directly checkable), `base_version` equals the pack's `version`, and
`base_content` — when `Jason.decode!/1`'d back — is structurally equal to the original
`packed.graph`, AND is byte-identical to independently canonicalizing that same
`packed.graph` via the same sort-keys-then-`Jason.encode!/1` algorithm applied in the
test itself (proves canonical form, not just "some valid JSON encoding of the right
data" — a test that only round-trips through `Jason.decode!/1` would not catch a
key-ordering bug).

### 10.3 AC3 test — and why it cannot go through a second real HTTP/`install/3` call

**Architectural note, stated explicitly rather than glossed over:** under the *existing,
unchanged* `uq_solution_pack_install_active` partial-unique index (one active install per
`(tenant_id, pack_id)`, REQ-078) and the *existing, unchanged* fact that
`SolutionPackInstall` has no `update_changeset/2` (no way to move a row to
`status: :uninstalled`, per that schema's own moduledoc), **a literal second
`SolutionPack.install/3` call for the same `(tenant_id, pack_id)` always fails with
`{:error, :duplicate_pack_install}` before reaching any artefact-base code at all** — this
was true before this requirement and remains true after it; this requirement does not
change install-level idempotency, only artefact-base-level idempotency. So AC3's "re-installing
the same version" cannot be exercised as two real `install/3` round-trips in this
codebase today. Filing this as a **cross-requirement note for REQ-380 and for whoever
eventually builds true pack-reinstall/upgrade support**, not silently working around it.

The test therefore exercises `capture_artefact_bases/4` directly (it is `public` per
§5.1 specifically so this is possible without reaching into private functions):
1. Call `capture_artefact_bases/4` once with one artefact snapshot, content `A`. Assert
   one row exists with `base_content` = canonical(`A`).
2. Simulate "the tenant has since locally adapted the artefact" — this step touches
   **only** `process_definitions` (e.g. update the installed `ProcessDefinition`'s
   `graph` directly, or simply skip touching anything — `solution_pack_artefact_bases`
   itself is never touched by a local edit, per REQ-041's design, so this step is
   scene-setting/documentation in the test, not a required DB mutation for the assertion
   to be meaningful).
3. Call `capture_artefact_bases/4` again for the **same** `(tenant_id, pack_id,
   artefact_type, artefact_id)` key, same `base_version` (simulating "the same version"),
   but with **different** content `B` (simulating what a re-delivered pack would attempt
   to write). Assert: still exactly one row for that key, and its `base_content` is
   still canonical(`A`) — **not** canonical(`B`). This is the literal AC3 assertion.
4. Also assert the function's return value/status makes it possible for a caller to tell
   this happened without raising (per §5.1, the no-op case does not error) — confirms
   `run_install/5` would not spuriously roll back a real second install attempt.

### 10.4 AC4 test — real `base`, hand-supplied `theirs`/`incoming`
Install a real pack with **exactly four** definitions for a fresh tenant (or reuse the
four rows AC2's test already produced), so all four `solution_pack_artefact_bases` rows
come from this write path, not `insert`ed directly by the test. Then call
`Letflow.Definitions.compute_pack_update_plan/5` with `theirs_artefacts`/
`incoming_artefacts` hand-built per REQ-041's own documented contract (these two lists
are caller-supplied by design — "no real install/export path exists yet to source them
from," `definitions.ex:370-371` — unaffected by this requirement, which only ever
supplies `base`), constructed so each of the four real `artefact_id`s lands in a
different classification bucket:

| Real base row (from this write path) | `theirs` supplied | `incoming` supplied | Expected classification |
|---|---|---|---|
| artefact 1, `base_content` = canonical(A) | canonical(A) | canonical(A) | `:unchanged` |
| artefact 2, `base_content` = canonical(A) | canonical(A) | canonical(A2), A2 ≠ A | `:clean_update` |
| artefact 3, `base_content` = canonical(A) | canonical(A3), A3 ≠ A | canonical(A) | `:local_only` |
| artefact 4, `base_content` = canonical(A) | canonical(A4), A4 ≠ A | canonical(A5), A5 ≠ A, A5 ≠ A4 | `:conflict` |

Assert `plan.entries` contains all four with exactly these classifications, and
`plan.entries`' `base` field for each equals the real row's `base_content` (proves the
lookup actually hit the row this write path produced, not a coincidental match) —
e.g. deliberately using content for one artefact that would classify differently under a
wrong `artefact_id` join would catch a §2 key-choice regression.

### 10.5 `mix letflow.check` (AC5)
Run for real once ELIXIR-DEV implements this design; quote real output in the
implementation handoff. Not a design-time action.
