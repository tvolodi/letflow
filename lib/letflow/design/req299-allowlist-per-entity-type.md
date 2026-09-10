# REQ-299 design — `Letflow.Entities.Query.Allowlist` becomes per-entity-type

Companion to `docs/migration/decisions/0023-entity-storage-hybrid.md` (the
promotion rule) and `lib/letflow/design/req296-entity-table-ddl-generator.md`
(the promoted-column enumeration this design reuses). Signatures and shapes
only — no implementation code.

## REWORK ITERATION 1 (2026-09-10) — resolving the AC4/AC5/AC6 conflict

**Trigger.** ELIXIR-DEV implemented §1–§5 below faithfully. `mix letflow.check`
then failed for real (confirmed via `git stash` as a genuine regression, not
pre-existing): 15 tests across `test/letflow/entities/query_test.exs` and
`test/letflow/entities/query_cursor_field_grants_test.exs` now raise
`KeyError` from `compiler.ex:333`/`cursor.ex`'s `Map.fetch!(Allowlist.typed_columns(),
name)` calls, triggered by the most ordinary fixture in the suite: a
`"customer"` entity type with plain `queried: true` fields (`"age"`,
`"customer_name"`), no FKs. §5.1 below (original iteration) had already
named this exact failure mode as the design's central open tension, but
misjudged it as dormant ("no deployment holds live entity records yet").
That judgment does not hold for `mix test` itself, which exercises this path
directly through `Compiler.compile/2`/`Cursor.paginate/5` for every ordinary
`queried: true` field in the suite — which is *every* promoted field there
is, since `DDL.promoted_columns/1`'s trigger 2 is `queried: true` with no
further gate (REQ-297/298's live-column existence check is explicitly out of
this requirement's scope, §5.2). So this is not an edge case sitting behind
some rare fixture; it is the mainline, and it broke on first contact.

**Investigated and rejected: a shared-helper swap (option (b)).** Read
`compiler.ex` and `cursor.ex` in full again (this iteration, in full, not by
memory). All four external call sites
(`compiler.ex:165`,`compiler.ex:333`,`cursor.ex:210`,`cursor.ex:386`) inline
the identical two-line pattern `{column_atom, _type} =
Map.fetch!(Allowlist.typed_columns(), field_name)` — there is no shared
helper function today to swap; each is written out separately at each call
site. Extracting one now and pointing it at a per-entity-type-aware lookup
does not clear AC5, because `build_filter_dynamic/2`/`build_order_by/2`
receive only `clause`/`sort_clause()` and an already-resolved
`allowlisted_field()` — no `entity_type`/`prefix`. Any fix routed through
those two functions requires either (i) threading `entity_type`/`prefix` (or
a pre-resolved atom) into their parameter lists — a signature/body change,
which is touching their dispatch logic, full stop, regardless of how the
change is dressed up — or (ii) making the *zero-arg* `Allowlist.typed_columns/0`
itself context-aware via some ambient/global channel (e.g. the process
dictionary, an `Agent`/ETS keyed by some other implicit context) so the two
functions' own source text stays byte-for-byte unchanged while their
*behavior* silently changes underneath them. (ii) technically threads a
needle in AC5's literal "`git diff` shows... unmodified" wording, but this
design rejects it outright: it is exactly the kind of hidden, ambient mutable
state this codebase's OTP-idiom standard and `INV-C` (no unsafe/implicit
resolution paths) argue against, it does not fix `cursor.ex`'s identical
problem (cursor.ex would need the same ambient channel independently wired,
doubling the hidden coupling), and it would satisfy AC5's letter while
gutting the reason AC5 exists (a compiler whose behavior for `:typed_column`
fields is verifiably unchanged). **(b) is rejected, not merely deferred.**

**Conclusion: this is a real, structural conflict, but it resolves against
AC4, not against AC5 or decision 0023.** AC5 and 0023's "Compiler needs no
change to its filter compilation" claim are both about `compiler.ex`'s own
code; AC6 ("`mix letflow.check` passes") is a whole-suite, unconditional gate
that this design has no authority to soften. Both survive unconditionally.
AC4, by contrast, is the one acceptance criterion whose literal wording
("resolved by `Allowlist.load/2` as `source: :typed_column`... for that
entity type") directly produces the `KeyError` the moment `load/2`'s actual
output is fed through the real `Compiler`/`Cursor` pipeline that every other
test in the suite already exercises — because no path exists today (short of
the rejected (b)) for those two modules to resolve a promoted field's column
atom. **This design chooses option (a): narrow `load/2`'s behavior so it
never marks a non-structural (i.e. promoted-only) field `:typed_column` yet,
while still building and exposing the correct per-entity-type computation
(`typed_columns/2`, §1.2–§1.3) as new, additive, currently-uncalled-by-`load/2`
machinery for REQ-300 to wire up once it also repoints `compile/2` at
per-entity-type tables and gives `build_filter_dynamic/2`/`build_order_by/2`
(or their REQ-300-era replacements) a real way to resolve a promoted atom.**
This means **AC4 as literally worded is not satisfiable by REQ-299 alone**,
stated plainly rather than worked around — see §6 for the honest test this
iteration substitutes, and the explicit escalation this finding requires.

**What actually changes in this iteration:** §1.5 (`load/2`) is revised
below — steps 4–7 no longer expand `entity_type_typed_column_names` to
include promoted, non-structural names; `load/2`'s typed-column set stays
exactly the structural 7, identical to `typed_columns/0`'s own key set,
which is what makes `load/2`'s *runtime behavior* provably identical to
pre-REQ-299 `load/2` (not just its function signature). §1.1–§1.4
(`typed_columns/0` unchanged, `typed_columns/2`, `entity_type_typed_columns/1`,
the new decoder) are **unchanged from the original iteration** — they were
never the problem; they are correct, tested in isolation, and exactly what
REQ-300 needs. §3's invariants and §6 (new) are updated accordingly.

## 0. Re-verification findings (per this task's mandatory step 1)

- `lib/letflow/entities/query/allowlist.ex` (176 lines) re-read in full.
  `typed_columns/0` today returns exactly the 7-entry map the requirement
  states (`entity_type`, `record_id`, `deleted`, `entity_def_version`,
  `last_event_global_seq`, `inserted_at`, `updated_at`), all mapped to
  `{atom(), Definition.field_type()}`. `load/2` merges this fixed table
  with `queried: true` JSON-field entries via `Map.merge(json_field_entries,
  typed_column_entries)` (typed wins on collision — AC3's rule, unchanged
  here). Confirmed accurate; REQ-296/297/298 (297/298 both still `pending`
  in `docs/requirements.yaml`, not merged) have not touched this file.
- `lib/letflow/entities/query/compiler.ex` (398 lines) re-read in full.
  `build_filter_dynamic/2` (two clauses, one per `source`) and
  `build_order_by/2` both call `Allowlist.typed_columns/0` (zero-arg) to
  resolve a `:typed_column` field's `column_atom` via
  `Map.fetch!(Allowlist.typed_columns(), field_name)`. Neither function
  receives `entity_type`/`prefix` — only `clause`/`sort_clause` and the
  already-resolved `allowlisted_field()`.
- `lib/letflow/entities/definition/ddl.ex` (298 lines, REQ-296, `status:
  done`) re-read in full. `promoted_columns/1` takes a
  `Definition.t()`-shaped map (`:fields`, `:foreign_keys`, both
  atom-keyed) and returns `[column_spec()]` — `%{name:, pg_type:,
  nullable:}` — one entry per promoted attribute, computed via
  `promotion_trigger/2` (fk-membership or `queried: true`) filtered again
  through `field_type_to_pg_type/1` returning `{:ok, _}` (excludes `:json`
  even if `queried: true` slipped past the Validator). This is the single
  enumeration AC2 requires this design share, not re-derive.
- **Grepped the whole `lib/` tree for every caller of `Allowlist.typed_columns/0`** —
  four call sites outside `allowlist.ex` itself, not just `compiler.ex`:
  - `lib/letflow/entities/query/compiler.ex:165` (`build_filter_dynamic/2`,
    `:typed_column` clause)
  - `lib/letflow/entities/query/compiler.ex:333` (`build_order_by/2`,
    `:typed_column` clause)
  - `lib/letflow/entities/query/cursor.ex:210` (`resolved_sort_term/2`,
    `:typed_column` clause)
  - `lib/letflow/entities/query/cursor.ex:386` (`read_sort_value/2`,
    `:typed_column` clause)
  - `lib/letflow/entities/query/allowlist.ex:106` (`load/2`, building
    `typed_column_entries`) — the one call site this design is allowed to
    change.
  All four external call sites share the identical pattern: `{column_atom,
  _type} = Map.fetch!(Allowlist.typed_columns(), name_or_field_name)`, used
  only when the already-resolved `allowlisted_field().source ==
  :typed_column`. **This pattern is load-bearing for the open question in
  §5 — read that section before implementing.**
- Neither `lib/letflow/entities/definition.ex`'s `Definition.t()` nor
  `Records.definition_document/1`/`Allowlist`'s own private `field_document/1`
  currently decode `foreign_keys` into an atom-keyed shape `DDL.promoted_columns/1`
  can consume (`Records.definition_document/1` only decodes `:name`,
  `:display_name`, `:fields`; `Allowlist`'s `field_document/1` decodes
  `:name`, `:type`, `:queried`, `:enum_values` per field, no
  `:foreign_keys` at all). This design adds the missing decode step inside
  `allowlist.ex` rather than editing either existing private decoder (both
  are `defp` in other modules, out of scope; duplicating a *decode*, not
  duplicating the *promotion rule*, is what AC2 actually forbids).
- `docs/requirements.yaml`'s REQ-299 entry confirms `depends_on: [REQ-296]`
  only, tightened during rework specifically because this requirement needs
  no live `ColumnPromotion`/`TenantProvisioning` state
  (`lib/letflow/design/req295-entity-promotion-ddl-execution.md` §2's
  `column_promotion_query_eligible?/3` gate is REQ-297/298 machinery, not a
  REQ-299 dependency) — confirmed no such call is added here. See §5.2.

## 1. Module: `Letflow.Entities.Query.Allowlist` (no new module)

Same file, same module. Three changes: a new private definition decoder
that includes `foreign_keys`, a new private pure helper that computes the
per-entity-type typed-column name→type map by calling `DDL.promoted_columns/1`,
and a new public `typed_columns/2` that exposes that helper with I/O
(schema/definition lookup). `typed_columns/0` and `load/2`'s public
contracts are unchanged in *shape*; `load/2`'s body changes to use the new
helper. `resolve_field/2` is unchanged.

```elixir
alias Letflow.Entities.Definition.DDL
```
(new alias; everything else in the existing `alias` list is unchanged)

### 1.1 `typed_columns/0` — UNCHANGED, kept exactly as-is

```
@spec typed_columns() :: %{String.t() => {atom(), Definition.field_type()}}
```

Returns the same fixed 7-entry structural map, byte-for-byte. **Not
touched by this requirement.** This is what keeps the four external call
sites in `compiler.ex`/`cursor.ex` compiling and behaving identically for
every structural field — see §5 for why this function's *shape* stays
fixed rather than gaining the `entity_type`/`prefix` parameters AC1's
prose might suggest belong on it directly.

### 1.2 `typed_columns/2` — NEW, the per-entity-type accessor AC1 names

```
@spec typed_columns(entity_type :: String.t(), prefix :: String.t()) ::
        {:ok, %{String.t() => Definition.field_type()}}
        | {:error, :invalid_schema_name}
        | {:error, :entity_type_not_found}
```

The direct embodiment of AC1 ("`typed_columns/0` (or its replacement)...
returns entity-type-specific... columns"). Deliberately a **different
arity of the same name**, not a rename — satisfies "keep the function name
if at all reasonably possible" while making room for `typed_columns/0` to
stay untouched. Returns the union of the structural 7 (names from
`typed_columns/0`, values taken from that same map's `type` half) and
every attribute `DDL.promoted_columns/1` reports as promoted for this
entity type's current active definition — name → `Definition.field_type()`
only, **no column atom** (see §5.3 for why this function never produces
one). Steps:

1. `TenantProvisioning.tenant_id_for_schema_name/1` — same
   `{:error, :invalid_schema_name}` short-circuit `load/2` already has.
2. `fetch_active_definition/2` (existing private helper, unchanged) —
   same `{:error, :entity_type_not_found}` remap `load/2` already has.
3. Decode into the `DDL.promoted_columns/1`-compatible document shape
   (§1.4) and call `entity_type_typed_columns/1` (§1.3), returning `{:ok,
   result}`.

### 1.2.1 AC4 fixture pair — concrete shapes the §6 item 4 test uses

Two entity-type fixtures, both consumed only through `typed_columns/2`
(§1.2)/`entity_type_typed_columns/1` (§1.3) — neither goes through `load/2`
or `Compiler`/`Cursor`, so INV-C/§5.3's "no atom fabrication" constraint is
irrelevant to this test and no `KeyError` risk exists.

- **Fixture `"order"`** (has both triggers). `Definition.t()` declares:
  - a `queried: true`, non-FK field named `"total_amount"` (`type: :decimal`
    or any non-`:json` `field_type()` — the specific type is immaterial,
    only its presence as a key matters), and
  - a `foreign_keys` entry `%{field: "customer_id"}` whose corresponding
    `fields` entry is `queried: false` (isolates the FK-derived trigger from
    the `queried: true` trigger — this field is promoted *only* because
    `DDL.promotion_trigger/2` treats FK membership as a trigger on its own,
    per REQ-296).
  - Expected: `Allowlist.typed_columns("order", prefix)` returns `{:ok,
    result}` where `Map.keys(result)` is a superset containing both
    `"total_amount"` and `"customer_id"` (alongside the structural 7).
- **Fixture `"tag"`** (has neither trigger). `Definition.t()` declares only
  plain, non-promoted fields — every `fields` entry has `queried: false`,
  and `foreign_keys` is `[]` (or the key absent). Expected:
  `Allowlist.typed_columns("tag", prefix)` returns `{:ok, result}` where
  `Map.keys(result)` equals exactly the structural 7 — in particular,
  neither `"total_amount"` nor `"customer_id"` (fixture `"order"`'s two
  promoted names) appears in `"tag"`'s result. This is the negative case:
  it proves `typed_columns/2` is scoped per-entity-type, not a global set
  that leaks one entity type's promoted columns into another's.

### 1.3 `entity_type_typed_columns/1` — NEW, private, pure

```
@spec entity_type_typed_columns(definition_document()) ::
        %{String.t() => Definition.field_type()}
```

Where `definition_document()` is the new decoded shape from §1.4. Pure
(no I/O) so it is independently testable against a bare fixture, and so
`typed_columns/2` and `load/2` (§1.5) share this one computation instead
of each re-deriving it — this is the function AC2's "not two
independently-hand-maintained lists" is actually about.

Body (shape, not code): start from `typed_columns/0`'s 7 keys, each mapped
to its existing `type` (discard the atom half). Compute `promoted =
DDL.promoted_columns(definition_document)` (REQ-296's own enumeration,
called directly — this is the reuse AC2 requires). For each `%{name:
promoted_name}` in `promoted`, look up the matching field in
`definition_document.fields` (by `.name`) to read its `Definition.field_type()`
(**not** `promoted.pg_type`, which is a Postgres type string, not a
`field_type()` atom — `DDL.promoted_columns/1`'s output tells us *which*
fields are promoted; the field's own type still comes from the
definition, exactly as `json_field_entries` already does for JSON-field
entries today). Merge: structural entries last (win on any name
collision, consistent with — not a change to — the existing
shadowing-precedence rule, since a promoted attribute should never
legitimately share a name with a structural column, but if the Validator
ever let one through, structural still must win, same as today).

### 1.4 `definition_document/1` (private decoder) and its `field_def`/`fk_def` shapes

```
@spec definition_document(EntityDefinition.t()) :: %{
        required(:fields) => [decoded_field_def()],
        required(:foreign_keys) => [decoded_fk_def()]
      }

@typedoc "Enough of Definition.field_def() for DDL.promoted_columns/1 and this module's own type lookup."
@type decoded_field_def :: %{
        name: String.t(),
        type: Definition.field_type(),
        queried: boolean(),
        enum_values: [String.t()] | nil
      }

@typedoc "Enough of Definition.fk_def() for DDL.promoted_columns/1's fk_field_names computation."
@type decoded_fk_def :: %{field: String.t()}
```

Decodes `entity_definition.definition_json`'s `"fields"` (same conversion
`field_document/1` already performs — `String.to_existing_atom/1` on
`"type"`'s value, safe for the same reason the existing moduledoc note
gives: the closed 8-`field_type()` atom set is already compiled into this
codebase, and `queried` defaults to `false`) plus, newly, `"foreign_keys"` →
`[%{field: Map.fetch!(fk, "field")}]`, defaulting to `[]` when the key is
absent (an entity type with no relationships). **No `decimal_precision`/
`decimal_scale` decode** — `DDL.field_type_to_pg_type/1` only needs those
to compute the *Postgres type string* for a `:decimal` column, and this
module only ever inspects `DDL.promoted_columns/1`'s result for *which
names* it returned (a `{:ok, _}` vs. `:never_promoted` filter already
applied internally by `DDL.promoted_columns/1`), never its `pg_type`
value — so their absence cannot change which fields are promoted, only
what a hypothetical Postgres type string would say, which this module
never reads. Existing `field_document/1` (private, used only by `load/2`
today) is **left as-is**; this decoder is new and separate, since
`field_document/1`'s output shape (no `:foreign_keys`, and used
per-field rather than per-definition) is not the right shape to extend
in place without touching `load/2`'s existing per-field iteration.

### 1.5 `load/2` — body changes, contract unchanged

```
@spec load(entity_type :: String.t(), prefix :: String.t()) ::
        {:ok, allowlist()}
        | {:error, :invalid_schema_name}
        | {:error, :entity_type_not_found}
```

Signature, success/error shapes, and the moduledoc's shadowing-precedence
section are **all unchanged**. **REWORK ITERATION 1: the body is now also
unchanged in behavior, not merely in contract** — see the rework section
above for why. Step order:

1. `tenant_id_for_schema_name/1` (unchanged).
2. `fetch_active_definition/2` (unchanged).
3. `definition_document/1` (§1.4) on the fetched `EntityDefinition` —
   **new step**, replacing today's per-field `field_document/1` mapping
   inline in `load/2`'s body (superseded by the new decoder, which
   already includes everything `field_document/1` gave `load/2` plus
   `foreign_keys`, needed so `load/2` and `typed_columns/2` can share one
   decode path — INV-B's "single source of truth," which is about the
   *decode and the promotion enumeration*, not about which of those
   promoted names `load/2` currently acts on). This step's presence is
   the one visible internal-implementation change from pre-REQ-299
   `load/2`; nothing it produces is new information `load/2` did not
   already have access to via `field_document/1` plus a `foreign_keys`
   decode.
4. **`typed_column_entries` — REWORK ITERATION 1: built from `typed_columns/0`'s
   own fixed 7 keys only, exactly as pre-REQ-299 `load/2` did** (`%{name:,
   source: :typed_column, type: <from typed_columns/0>, enum_values: nil}`
   for each of the 7). **Deliberately does NOT call
   `entity_type_typed_columns/1` (§1.3) here.** That function is computed
   and tested in isolation via `typed_columns/2` (§1.2) only; `load/2`
   does not consume it. This is the direct consequence of §"REWORK
   ITERATION 1" above: marking a promoted-but-non-structural field
   `:typed_column` here is exactly what raises `KeyError` in
   `compiler.ex`/`cursor.ex`, since neither module has any way today to
   resolve such a field's column atom (AC5, and the rejected option (b)
   analysis above). Until REQ-300 gives `compile/2`/`Cursor` that
   resolution path, `load/2` cannot honestly mark such a field
   `:typed_column` without breaking every query that touches it.
5. Build `json_field_entries` **exactly as today, pre-REQ-299** (`queried:
   true` fields from `definition_document.fields`) — **no filter against
   `entity_type_typed_column_names`**, because `load/2` no longer computes
   that broader set at all. A promoted, `queried: true`, non-structural
   field still resolves `source: :json_field` here, identically to
   pre-REQ-299 behavior — this is precisely the gap named in §6's AC4
   re-verification, stated there rather than hidden here.
6. `Map.merge(json_field_entries, typed_column_entries)` — **unchanged**,
   still "typed-column entries win on name collision," and since
   `typed_column_entries` is back to exactly the structural 7, this
   collision can in practice only ever be the same structural-vs-JSON-field
   case AC3 already covers — no promoted-name collision case exists in
   `load/2`'s output anymore (it would exist in `typed_columns/2`'s output,
   which is a different, new, additive accessor nothing calls yet).

## 2. Data structures

No changes to `allowlist()`, `allowlisted_field()`, or `field_source()` —
all three keep their current shape (see `allowlist.ex:34-53`). New types
added: `decoded_field_def()`, `decoded_fk_def()` (§1.4), both private to
this module (not part of its public `@type` surface, since they exist only
to feed `DDL.promoted_columns/1` and are not returned to any caller).

## 3. Invariants

- **INV-A (shadowing, AC3).** Unchanged from pre-REQ-299: a name present in
  `typed_columns/0`'s fixed 7 always resolves `source: :typed_column` in
  `load/2`'s output; a name present only via `queried: true` resolves
  `source: :json_field`. Never both. **REWORK ITERATION 1: this invariant's
  scope is `load/2`'s output only, and is now, again, over exactly the
  original 7-name set** — it is a separate, new invariant (INV-E, below)
  that governs the *broader* structural ∪ promoted set inside
  `typed_columns/2`'s own output.
- **INV-B (single source of truth, AC2).** The promoted half of
  `entity_type_typed_columns/1`'s result is *exactly*
  `MapSet.new(DDL.promoted_columns(doc), & &1.name)` — this module never
  re-implements `promotion_trigger/2` or `field_type_to_pg_type/1`'s
  `:json`-exclusion logic itself. If REQ-296's enumeration changes,
  `typed_columns/2`'s behavior changes with it automatically, by
  construction. **REWORK ITERATION 1: this invariant is about
  `entity_type_typed_columns/1`/`typed_columns/2` specifically — `load/2`
  no longer calls either, per §1.5, so this invariant no longer says
  anything about `load/2`'s output.**
- **INV-C (no atom fabrication, §5.3).** Unchanged. `typed_columns/2` and
  `entity_type_typed_columns/1` never call `String.to_atom/1` or
  `String.to_existing_atom/1` on a promoted attribute's `name` to produce a
  column reference. `String.to_existing_atom/1` is used only on a field's
  `"type"` string (closed 8-value set, existing precedent) — never on an
  open-ended, tenant-declared attribute *name*.
- **INV-D (compiler/cursor untouched, AC5).** Unchanged, and now
  unconditionally true rather than true-with-a-caveat: `typed_columns/0`'s
  exported shape and return value are byte-for-byte unchanged, AND (new
  this iteration) `load/2`'s output for any given entity type/prefix is
  byte-for-byte identical to what pre-REQ-299 `load/2` would have returned
  for the same inputs. Every existing caller (`compiler.ex:165,333`,
  `cursor.ex:210,386`) therefore compiles and behaves identically for
  *every* field `load/2` can produce, not merely for the fields that were
  already in the fixed 7 — because `load/2` no longer produces any
  `:typed_column` entry outside that fixed 7. **This is what closes the gap
  §5.1 (original iteration) flagged as merely "very likely not a live bug
  today": it is now provably not a bug at all, because the precondition
  that triggered it (`load/2` emitting a `:typed_column` entry
  `compiler.ex`/`cursor.ex` cannot resolve) no longer occurs.**
- **INV-E (new, REWORK ITERATION 1 — the promoted set is real but inert).**
  `typed_columns/2`'s and `entity_type_typed_columns/1`'s output correctly
  and completely describes the union of structural and promoted columns for
  an entity type (AC1/AC2 hold for these functions), but **nothing in this
  codebase calls either function yet** — `load/2` does not, and no caller of
  `load/2`'s output can observe a promoted field as anything other than
  `:json_field`. This is intentional and load-bearing: it is what lets AC1/
  AC2 be true, AC5/AC6 be true, and AC4 be honestly reported as *not* true,
  all at once, without any function lying about what it does. REQ-300 is the
  first requirement positioned to make `typed_columns/2`'s output actually
  observable through `load/2`, once it also gives `compiler.ex`/`cursor.ex`
  (or their REQ-300-era replacements) a resolution path for a promoted
  column's atom.

## 4. Cross-module dependencies

- `Letflow.Entities.Definition.DDL.promoted_columns/1` — called directly
  (new dependency; `allowlist.ex` did not depend on this module before).
  `DDL` has no dependency back on `Allowlist` — one-directional, no cycle.
- `Letflow.Entities.Definitions.get_active_definition_by_name/2` —
  unchanged, already a dependency.
- `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` — unchanged,
  already a dependency.
- `Letflow.Entities.Definition` — unchanged, already a dependency (for
  `@type` references only, no functions called on it — it has none).

## 5. Open questions (not silently resolved)

### 5.1 The compiler.ex/cursor.ex atom-lookup gap for promoted fields — flagged per this requirement's own escape valve

**This is the central design tension of this requirement, stated
explicitly rather than worked around.** `Allowlist.load/2` will now (per
AC4, correctly) resolve a `queried: true` promoted field as `source:
:typed_column`. If that resolved field is then fed into
`Compiler.build_filter_dynamic/2`, `Compiler.build_order_by/2`,
`Cursor.resolved_sort_term/2`, or `Cursor.read_sort_value/2` — all four
still call the **unchanged** zero-arg `Allowlist.typed_columns/0` (§1.1)
to translate the field name into a column atom via `Map.fetch!/2` — the
lookup will raise `KeyError`, because the promoted field's name is not one
of the fixed 7 keys `typed_columns/0` returns.

This is not accidental — it is the direct, necessary consequence of
satisfying AC5 (`compiler.ex`'s two dispatch functions must show zero diff)
together with INV-C (no unsafe atom fabrication from an open-ended
attribute name): the only way to hand `compiler.ex`/`cursor.ex` a safe
column atom for a promoted field, without editing either module, would be
for `typed_columns/0` itself to already contain that atom — which requires
`entity_type`/`prefix` context neither `build_filter_dynamic/2` nor
`build_order_by/2` receives today.

**Why this is very likely not a live bug today, stated so a reviewer does
not have to re-derive it:**

1. `Compiler.compile/2` builds its query against `Letflow.Entities.Record.Latest`
   (`entity_record_latest`, the pre-0023 shared table) — an Ecto schema
   module whose fields are exactly `typed_columns/0`'s own 7 (plus
   `field_values`/`id`). Even *with* a correct atom, `field(r, ^col)`
   against `Latest` for a promoted attribute would reference a column that
   does not exist on that schema/table at all — per-entity-type tables and
   their promoted columns are REQ-297/298's output (both still `pending`).
   So resolving the atom is necessary but not sufficient for an actual
   query to succeed against real data; making the whole path work requires
   also repointing `compile/2` at the correct per-entity-type table, which
   is `REQ-300`'s stated job (`depends_on: [REQ-298, REQ-299]`), not this
   requirement's.
2. 0023 itself: "No deployment is known to hold entity records today" —
   there is no live caller that could hit this path with a real promoted
   attribute before REQ-297/298/300 land.

**What this design does NOT do about it:** does not edit `compiler.ex` or
`cursor.ex` (AC5, and the requirement's explicit instruction to stop and
flag rather than quietly work around it), and does not weaken AC4 to avoid
exposing the gap (AC4's test targets `Allowlist.load/2`'s own output only —
it does not, and per this requirement's scope fence should not, drive the
result through `Compiler`/`Cursor`).

**RESOLVED, REWORK ITERATION 1 (see the section at the top of this file for
the full reasoning):** this was not a dormant gap — `mix test` hit it
immediately, on the suite's most ordinary fixture. Recommendation (a) from
the original iteration is adopted, but in its stronger form: rather than
accept the gap as live and merely document it, `load/2` is changed (§1.5)
to never produce the `:typed_column` marking for a promoted, non-structural
field in the first place, so the gap cannot be hit through `load/2` at all
until REQ-300 closes it properly. `typed_columns/2`/`entity_type_typed_columns/1`
stay exactly as designed — correct and ready for REQ-300 — but `load/2`
does not yet wire its output through to callers. See §6 for the resulting
AC4 status and the required escalation.

### 5.2 `column_promotion_query_eligible?/3` — confirmed out of scope, stated so it isn't silently re-litigated

`lib/letflow/design/req295-entity-promotion-ddl-execution.md` §3 states
Allowlist's per-entity-type builder "must call
`column_promotion_query_eligible?/3`... per 0024 §3–4" before treating a
candidate promoted attribute as `:typed_column`. This design does **not**
do that: REQ-299's own `docs/requirements.yaml` entry was deliberately
reworked to `depends_on: [REQ-296]` only, with an explicit note that
nothing this requirement needs depends on REQ-297/298's `ColumnPromotion`
machinery, and REQ-299's task description never mentions
`column_promotion_query_eligible?/3`. Treating req295's forward-looking
integration note as binding here would silently reintroduce a REQ-297/298
dependency the rework explicitly removed. Flagged as a cross-document
inconsistency (req295's design doc appears stale on this one point) rather
than resolved by picking a side — REVIEWER should confirm this reading
before REQ-297/298 are implemented, since **whichever of those two
requirements wires `Letflow.TenantProvisioning.run_column_promotion/1`
live** will need to decide then whether `Allowlist` should gain that gate
at that point (a later, additive change to `entity_type_typed_columns/1`,
not a blocker for this requirement).

### 5.3 Why `typed_columns/2` returns no column atom at all

Considered and rejected: returning `{atom() | nil, Definition.field_type()}`
per entry (matching `typed_columns/0`'s shape) with `nil` for every
promoted entry. Rejected because nothing in this requirement's scope
consumes that atom (`load/2` already discards the atom half of
`typed_columns/0`'s own entries today — see `allowlist.ex:106`'s existing
`{_atom, type}` pattern), and a `nil`-or-real-atom union return type would
invite a future caller to pattern-match assuming a real atom is always
present. Returning bare `Definition.field_type()` values makes the
"no atom exists yet for a promoted column" fact impossible to
accidentally ignore at the type level.

## 6. Acceptance-criteria re-verification, REWORK ITERATION 1

Re-checked against the real test-failure evidence from ELIXIR-DEV's
implementation report, not speculatively.

1. **"`typed_columns/0` (or its replacement) returns entity-type-specific
   promoted columns... proven by a test comparing two different entity-type
   fixtures with different promoted columns."** — **Met, by `typed_columns/2`
   (§1.2), not by `typed_columns/0`.** Test: call `Allowlist.typed_columns/2`
   for two entity-type fixtures whose definitions declare different
   `queried: true`/FK fields, assert the two returned maps' key sets differ
   exactly as expected (structural 7 identical in both, promoted halves
   differing). This function is new, pure-enough-to-fixture-test, and does
   not go through `load/2` or `Compiler`/`Cursor`, so it cannot raise the
   `KeyError` — it never produces a column atom (§5.3/INV-C).

2. **"the promoted-column set returned here matches REQ-296's DDL-generator's
   own promoted-column enumeration... not two independently-hand-maintained
   lists."** — **Met, by `entity_type_typed_columns/1` (§1.3) calling
   `DDL.promoted_columns/1` directly (INV-B).** Test: one definition fixture,
   assert `entity_type_typed_columns/1`'s promoted names (or
   `typed_columns/2`'s output, minus the structural 7) equal
   `MapSet.new(DDL.promoted_columns(doc), & &1.name)` exactly.

3. **"the shadowing precedence rule is unchanged and still covers the
   original structural-7 case... re-running the existing test(s)."** —
   **Met, and now unconditionally so.** Since `load/2`'s `typed_column_entries`
   (§1.5 step 4, this iteration) is built from `typed_columns/0`'s 7 keys
   only — identical to pre-REQ-299 — the existing shadowing test (a `"deleted"`
   field declared `queried: true` on a definition, asserting the structural
   `:typed_column` entry still wins) passes unmodified, because `load/2`'s
   relevant code path is unmodified in behavior, not merely re-verified by
   inspection.

4. **AC4 (amended text): "`Allowlist.typed_columns/2` (or equivalent)'s
   per-entity-type typed-column set includes both `queried:true` fields AND
   FK-derived (`foreign_keys`) promoted columns, proven by a test using a
   fixture with at least one of each, asserting both appear for that entity
   type and neither appears for a second fixture lacking them."** — **Met,
   by `Allowlist.typed_columns/2` (§1.2), using the two-fixture pair
   specified in §1.2.1.** Test, stated concretely:
   - Build fixture `"order"` (§1.2.1): a `Definition.t()` with one
     `queried: true` field `"total_amount"` (non-FK) and one FK-derived
     field `"customer_id"` (via a `foreign_keys` entry, `queried: false` on
     that field so the FK trigger is isolated from the `queried: true`
     trigger). Call `Allowlist.typed_columns("order", prefix)` and assert
     the returned map's keys include **both** `"total_amount"` **and**
     `"customer_id"`, alongside the structural 7.
   - Build fixture `"tag"` (§1.2.1): a `Definition.t()` with no `queried:
     true` fields and no `foreign_keys` entries. Call
     `Allowlist.typed_columns("tag", prefix)` and assert the returned map's
     keys equal **exactly** the structural 7 — in particular, neither
     `"total_amount"` nor `"customer_id"` (fixture `"order"`'s two promoted
     names) appears.
   - Together these two assertions are the "appear for that entity type /
     neither appears for a second fixture lacking them" shape AC4's amended
     text names, proven directly against `typed_columns/2`'s return value
     (no `Map.fetch!/2` atom resolution, no `Compiler`/`Cursor` involved, so
     nothing in this test can raise the `KeyError` described in the rework
     section above).
   - **Unchanged from the prior iteration, per this task's fix-scope
     instruction (do not weaken or remove):** this test does **not** assert
     anything about `Allowlist.load/2`'s `source` for either field.
     `load/2` (§1.5) still resolves a promoted, non-structural field as
     `source: :json_field`, identically to pre-REQ-299 behavior — routing
     `typed_columns/2`'s output through `load/2`'s `:typed_column` marking
     is REQ-300's job (§5.1, INV-E), not this requirement's, and remains
     out of scope for this test.

5. **"`git diff` shows `compiler.ex`'s `build_filter_dynamic/2` and
   `build_order_by/2` dispatch logic unmodified... per 0023's own claim."** —
   **Met, unconditionally.** `compiler.ex` is not touched at all in this
   iteration (nor was it in the original iteration). `git diff -- lib/letflow/entities/query/compiler.ex`
   is empty.

6. **"`mix letflow.check` passes, with real output quoted."** — **Expected
   met**, on the reasoning that `load/2`'s behavior is now provably identical
   to pre-REQ-299 `load/2` for every input (INV-D), which is exactly the
   precondition that was violated when the 15 failures were observed.
   ELIXIR-DEV must still run `mix letflow.check` for real after implementing
   this iteration and quote the actual output — this design does not claim
   AC6 as verified, only as no longer structurally blocked.
