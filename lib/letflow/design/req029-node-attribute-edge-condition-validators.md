PROVENANCE (historical, not current decision authority):
# Design: REQ-029 — Node-attribute and edge-condition validators (graph.zig, PD-05/PD-06)

**Requirement:** REQ-029 (`docs/requirements.yaml`, stage S2)
**Owner (implementer):** ELIXIR-DEV
**Extends:** `lib/letflow/definitions/graph.ex` (REQ-028, `status: done`, merged to `main`) —
this document adds two new public functions and one new public helper to that same file. It
does **not** modify `validate_graph/1` or any of REQ-028's 8 existing check functions
(CHK-01..CHK-08), and does not change the `Node`/`Edge` struct field lists.
**This document produces:** the two new public function signatures, the 9 new named checks'
exact trigger/violation semantics (CHK-09..CHK-17, continuing REQ-028's numbering), the
ISO-8601 duration scan-forward algorithm, the minimal-structural CEL syntax algorithm, the
`Violation.code` type extension, and the resolution of REQ-028 design §9.1's open question.
Signatures and type shapes only — no implementation code, no function bodies, no `.ex`/`.exs`
code blocks.

## 0. Sources read for this design, and an explicit access gap

- `docs/requirements.yaml` REQ-029's full entry (quoted in full below where load-bearing),
  and REQ-028/REQ-030's full entries for cross-reference.
- `lib/letflow/design/req028-graph-structural-validator.md` (full) — in particular §1 (module/
  file layout this design extends in place, not a new file), §2.1/§2.2 (`Node`/`Edge` struct
  field lists, confirming `condition`/`is_default` already exist on `Edge` and `attributes`
  already exists on `Node` — no struct changes needed here), §5 (the CHK-01..CHK-08 table and
  numbering convention this design continues from CHK-09), §8 (the zero-I/O purity contract
  this design must also satisfy), and §9.1/§9.2 (the two open questions REQ-028 explicitly
  deferred to this requirement).
- `lib/letflow/definitions/graph.ex` (full, current `main`) — the actual merged module this
  design extends; confirms the private helper `build_node_index/1` (id → first-occurrence
  index map) already exists in-file and is reusable without duplication (§5.2 below).
- `docs/guides/backend_developer_guide.md` §2/§3 (project structure, naming/error-shape
  conventions) and `docs/anti-patterns.md` (no entries currently relevant to this module).
- `docs/migration/stage-2-event-store-definitions.md` — the "Static-typing gap" finding
  (already cited by REQ-028's own design doc §9.2; re-confirmed still relevant here since
  this design's node-attribute checks are exactly the kind of larger validation surface that
  finding warns not to under-test).

PROVENANCE (historical, not current decision authority):
**Access gap, stated explicitly per this task's own instruction, not silently worked around:**
this environment does not have `R-Co/src/definition/graph.zig` or
`R-Co/src/design/definition.md` checked out anywhere reachable (searched the whole filesystem
for `graph.zig` and any `definition.md` under a `design` directory — no match, and no `R-Co`
directory exists on this host at all). Per the handoff's own fallback instruction, this design
is built from `docs/requirements.yaml`'s REQ-029 full text (itself described as "already a
faithful paraphrase of definition.md's PD-05/PD-06 sections, quoted directly") and
`req028-graph-structural-validator.md`'s own citations of `graph.zig`. Two consequences,
flagged inline where they occur rather than glossed over:

1. The exact wording/edge-cases of definition.md's "Implementation guidance" scan-forward
   ISO-8601 parser and its "CEL syntax validation" section could not be read directly. §4.3
   and §6 below reconstruct a concrete, testable algorithm for each from REQ-029's prose
   description alone, and flag every place a real algorithm read from source could plausibly
   diverge from this reconstruction (§9.1).
PROVENANCE (historical, not current decision authority):
2. Everywhere REQ-028's design doc already resolved a naming/typing/behavior question by
   reading `graph.zig` directly (e.g. exact CHK-04 per-type connectivity rule), this design
   defers to that already-approved resolution rather than re-deriving it, since REQ-028's
   design was gate-approved with direct source access this run doesn't have.

## 1. Function/module ownership — the central design decision this task calls out

REQ-029's own text says PD-06's edge-condition rules have "no separate function name given in
definition.md beyond the validateGraph() extension" and explicitly asks ELIXIR-DEV/this design
to decide where the check set lives, "noting which function owns it in the moduledoc." This
section states that decision and its reasoning, rather than leaving it implicit.

**Decision: two new public functions, both siblings of `validate_graph/1` in the same
`Letflow.Definitions.Graph` module — not folded into `validate_graph/1` itself.**

- `validate_node_attributes/1` — PD-05 only (the 4 per-node-type attribute checks, CHK-09..
  CHK-12).
- `validate_edge_conditions/1` — PD-06 only (the 5 edge-condition/CEL checks, CHK-13..CHK-17).

**Why not fold into `validate_graph/1`:** `validate_graph/1` is already gate-approved,
implemented, and merged to `main` with its own tested invariant ("all 8 checks run
unconditionally against the same, unmodified input graph," REQ-028 design doc §7.1) that has
no notion of "run only if a prior phase passed." REQ-029's own text is explicit that PD-05/PD-06
run **only after** `validate_graph/1` succeeds ("definition.md: 'If validateGraph() fails,
validateNodeAttributes() is NOT called'"), and this handoff's task frames that ordering as
applying to all three new pieces (node attributes, edge conditions, and the CEL check)
collectively. Appending CHK-09..17 into `validate_graph/1`'s own unconditional 8-check list
would make that function's ordering contract mean something different than what it means today
and would silently re-scope an already-shipped, already-tested function — exactly the kind of
change `docs/anti-patterns.md`'s spirit and `core-directives.md`'s "don't silently re-decide
what's already settled" principle warn against. Two new functions cost nothing extra to call
correctly (both take the same `t()` graph, same as `validate_graph/1`) and keep the ordering
contract *structurally visible* (three distinct function calls in the caller's own pipeline
code) rather than hidden inside one function's internal branching.

**Why two new functions rather than one combined new function:** PD-05 (node attributes) and
PD-06 (edge conditions, including CEL syntax) are two independent rule domains — a node's
attribute correctness has zero data dependency on any edge's condition/is_default state, and
vice versa. Splitting them mirrors this module's own established convention of one check
function per named rule (REQ-028 design doc §5's `check_*/1` functions), and lets
TEST-DESIGNER target each domain's tests independently without one function's bug masking the
other's coverage.

**Flagged explicitly for REQ-030 (not resolved here — REQ-030's own CODE-DESIGNER's job):**
REQ-030's current requirement text names only "REQ-029's validateNodeAttributes()" as the
second call after `validate_graph/1` in `create/1`'s pipeline. This design introduces **two**
new functions, not one — REQ-030's future `create/1` must call **both**
`validate_node_attributes/1` and `validate_edge_conditions/1` (in either order relative to each
other, since they're independent — see §5.1) after `validate_graph/1` succeeds, not just the
one REQ-030's text names by name. This is a real gap in REQ-030's current text, not a detail
this design can silently paper over; REQ-030's CODE-DESIGNER must read this section before
writing that pipeline.

**Ordering enforcement — caller's responsibility, stated in the moduledoc, not enforced by
this module:** neither `validate_node_attributes/1` nor `validate_edge_conditions/1` calls
`validate_graph/1` internally, and neither checks `graph`'s structural validity as a
precondition. Both are **total, defensive functions**: given any `t()` value, structurally
valid or not, they always return a `result()` and never raise (§5.2 states exactly how a
dangling-source edge is handled defensively by `validate_edge_conditions/1`). The "run only
after `validate_graph/1` passes" rule is a **contract enforced entirely by the caller**
(REQ-030's future `create/1`) — this module has no way to know, and does not attempt to detect,
whether `validate_graph/1` was already called on this exact `graph` value. Calling
`validate_node_attributes/1`/`validate_edge_conditions/1` internally re-running
`validate_graph/1`'s 8 checks was considered and rejected: it would silently double the work on
every valid call and, worse, would produce CHK-01..08 violations mixed into what's supposed to
be a "phase 2" result, which is exactly the redundant-work definition.md's "is NOT called"
wording is trying to avoid. **The `Letflow.Definitions.Graph` moduledoc must be extended (by
ELIXIR-DEV, when implementing) with a paragraph stating this precisely:** that
`validate_node_attributes/1` and `validate_edge_conditions/1` assume — but do not verify — that
`validate_graph/1` has already been called and returned `valid: true` on the same graph value,
that calling them out of order or on a structurally invalid graph will not crash but may
produce misleading/redundant violations, and that enforcing the actual ordering is the caller's
job (naming `Letflow.Definitions.create/1`, REQ-030, as that caller once it exists).

## 2. Resolving REQ-028 design doc §9.1 — `Node.attributes` typing

REQ-028 design doc §9.1 left `attributes :: map() | nil` as a **provisional** choice, explicitly
flagging that REQ-029 — the first requirement to actually read `attributes`' contents — must
confirm or override it rather than let it stand by default. This section does that.

**Resolution: `map() | nil` is confirmed, with one further pin this design adds that §9.1 did
not yet need to make — map keys are `String.t()`, not atoms.**

PROVENANCE (historical, not current decision authority):
- **Why `map() | nil` (not `String.t() | nil`, i.e. not the raw undecoded JSON string
  `graph.zig`'s `?[]const u8` uses) still holds:** REQ-028 §9.1's own reasoning stands —
  Elixir/`Jason` naturally decodes a `jsonb` column's contents to a map before any validator
  sees it, and there is no allocator-lifetime reason (unlike Zig) to keep `attributes` as an
  undecoded string in between. `validate_node_attributes/1` needs to read named keys
  (`"role"`, `"endpoint"`, `"timeout_ms"`, `"duration_iso8601"`) and their typed values
  directly — a decoded map is the only shape that lets it do so without embedding its own JSON
  parser, which would be actual implementation logic (and a second, redundant decode) this
  design has no reason to invent.
PROVENANCE (historical, not current decision authority):
- **Why keys must be `String.t()`, not atoms — a new pin, not previously decided:** a `Node`
  constructed from a request body's raw `attributes` JSON object has attacker/tenant-controlled
  key names. `String.to_atom/1` (or `Jason.decode!/1, keys: :atoms`) on untrusted input is a
  well-known Elixir/Erlang atom-table-exhaustion risk — atoms are never garbage-collected, so
  decoding arbitrarily many distinct external key strings into atoms over the node's lifetime
  is a memory-safety hazard with no equivalent in `graph.zig`'s Zig implementation (Zig has no
  atom table). This design therefore requires `attributes` to be a **string-keyed** map — the
  default, safe shape `Jason.decode/1` produces with no options — and every check below reads
  attributes via string key lookups (`Map.get(attributes, "role")`, not `attributes[:role]` or
  `Map.get(attributes, :role)`). This is stated as a documented contract on the `attributes`
  field (its `@type` stays `map() | nil` — Elixir has no first-class "string-keyed map" type
  distinct from `map()` — but the moduledoc/field doc for `Node.attributes` should note the
  string-key expectation explicitly), not a struct/type-signature change.
- **No struct field changes.** `Letflow.Definitions.Graph.Node`'s `defstruct`/`@enforce_keys`/
  `@type t` are unchanged from REQ-028 — `attributes: map() | nil` stays exactly as merged.
- **Value types per key, pinned here (not previously specified anywhere):**

  | Key | Required value type | Notes |
  |---|---|---|
  | `"role"` | `String.t()`, non-empty after `String.trim/1` | HUMAN_TASK only |
  | `"endpoint"` | `String.t()`, non-empty after `String.trim/1` | SERVICE_TASK only |
  | `"timeout_ms"` | `integer()` in `1..300_000` inclusive | SERVICE_TASK only; **no type
    coercion** — a JSON value that decodes to a float (`1000.0`, present in the source because
    it had a decimal point) or a numeric string (`"1000"`) is treated as absent/invalid, not
    silently converted. Coercion logic is real implementation behavior with its own edge cases
    (does `"1000"` count? does `1000.0` count?) that this design deliberately does not invent —
    `is_integer/1` is the exact, unambiguous test. |
  | `"duration_iso8601"` | `String.t()` | TIMER only; further validated by §4.3's parser |

  Any other key present in the map, on any node type, is never read by any check below — this
  is exactly what makes "undeclared extra attributes are silently ignored" (REQ-029 AC5) true
  by construction, not by an explicit allow-list/ignore-list mechanism.

## 3. `validate_node_attributes/1` — signature and composition

```
@spec validate_node_attributes(t()) :: result()
```

Same `result()` type as `validate_graph/1` (`%{valid: boolean(), violations: [Violation.t()]}`),
same never-short-circuit composition shape: iterate `graph.nodes`, run every applicable check
against every node **unconditionally** (no early return on the first violation, no skip after a
node's first failing check — a SERVICE_TASK node missing both `endpoint` and a valid
`timeout_ms` produces **two** violations for that one node, not one), concatenate all violations
across all nodes, return `%{valid: violations == [], violations: violations}` — identical
invariant shape to `validate_graph/1` (REQ-028 design doc §4), holding by the same
unconditional-concatenation construction (REQ-028 design doc §7.1).

## 4. CHK-09..CHK-12 — per-node-type attribute rules (PD-05)

| # | Check (private fn) | Applies to `node_type` | Trigger | Violation code | Message names |
|---|---|---|---|---|---|
| CHK-09 | `check_human_task_role/1` | `:HUMAN_TASK` | `attributes` is `nil`, or has no `"role"` key, or `attributes["role"]` is not a `String.t()`, or is a `String.t()` that is empty/whitespace-only after `String.trim/1` | `:missing_role` | the node id |
| CHK-10 | `check_service_task_endpoint/1` | `:SERVICE_TASK` | same absent/wrong-type/blank test as CHK-09, against `"endpoint"` — **unless `"service_id"` passes the same non-blank test instead** (§4.1a; fixed 2026-08-20, ISS-0104/GH#334) | `:missing_endpoint` | the node id |
| CHK-11 | `check_service_task_timeout/1` | `:SERVICE_TASK` | `attributes` is `nil`, or has no `"timeout_ms"` key, or `attributes["timeout_ms"]` is not `is_integer/1`, or is an integer outside `1..300_000` (i.e. `< 1` or `> 300_000`) | `:invalid_timeout` | the node id, and the offending value if present |
| CHK-12 | `check_timer_duration/1` | `:TIMER` | `attributes` is `nil`, or has no `"duration_iso8601"` key, or `attributes["duration_iso8601"]` is not a `String.t()`, or is a `String.t()` that fails §4.3's parser | `:invalid_duration` | the node id, and the offending value if present |

Every private check function's signature: `@spec check_*(t()) :: [Violation.t()]` — same
uniform-signature convention as REQ-028's `check_*/1` functions (whole graph in, only the
relevant node subset examined internally).

**CHK-09/CHK-10 run independently on a node of the wrong type — no-op, not a violation.** A
`:SERVICE_TASK` node is never examined by CHK-09 (`:HUMAN_TASK`-only), and a `:HUMAN_TASK` node
is never examined by CHK-10/CHK-11 — each check function filters `graph.nodes` to its own
`node_type` first (`Enum.filter(nodes, &(&1.node_type == :HUMAN_TASK))` or equivalent), so a
node outside a check's applicable type simply never enters that check's per-node loop at all
(not "enters and passes trivially" — a real distinction only if a future node type reuses one
of these keys with different rules, which none of the current 7 does).

**START/END/EXCLUSIVE_GATEWAY/PARALLEL_GATEWAY nodes: no check in this table applies to them at
all.** No CHK-09..12 filters ever selects a node of these 4 types, so they can carry `nil`
attributes, an empty map, or any arbitrary map — never a violation, regardless of content. This
directly satisfies REQ-029's "START/END/EXCLUSIVE_GATEWAY/PARALLEL_GATEWAY require nothing" and
AC1's "START/END/gateway types accepting no attributes."

**A node whose `node_type` is not one of the 7 known atoms at all** (REQ-028 design doc §9.2's
open question, inherited unchanged here — see §9 below): none of CHK-09..12's type filters
match it either, so it is treated the same as START/END/gateway — no attribute check applies.
This is a deliberate non-resolution, consistent with REQ-028's own stance of not inventing a new
"unknown type" check in this module (§9.2 explicitly left that decision for later); it is
flagged again here rather than silently inherited without comment.

### 4.1 CHK-09/CHK-10 detail — "non-empty" test, precisely

`attributes["role"]`/`attributes["endpoint"]` must be a `String.t()` and
`String.trim(value) != ""`. A value of `""`, `"   "` (whitespace-only), `nil` (key absent or
explicit JSON `null`), or any non-string JSON type (e.g. a number, a boolean, a nested object)
all trigger the violation — there is exactly one trigger condition, not a separate code per
sub-case, matching CHK-01..08's precedent of one code covering every way a check's single named
rule can fail (e.g. CHK-02's "missing END node" has one code regardless of *why* no END node
exists).

### 4.1a CHK-10's `"service_id"` alternative (fixed 2026-08-20, ISS-0104/GH#334)

PROVENANCE (historical, not current decision authority):
**A SERVICE_TASK node passes CHK-10 if *either* `"endpoint"` or `"service_id"` passes the §4.1
non-blank test — the violation fires only when *both* are blank/missing.** This mirrors
`Letflow.Engine.ServiceTask.parse_config_from_node_attributes/1`'s own routing (REQ-056 design
doc §5.1): `route_kind: :catalog_service` when `service_id` is non-blank, else
`route_kind: :inline_url` when `url_template`/`endpoint` is non-blank, else
`{:error, :missing_url_and_service_id}` only when neither is present — and R-Co's own
`parseConfigFromNodeAttributes` (`service_task.zig` lines 84-100), which treats `endpoint`/`url`
as fully optional whenever `service_id` is supplied.

Before this fix, CHK-10 required `"endpoint"` unconditionally regardless of `"service_id"`,
which made `route_kind: :catalog_service` (service-id-only) dispatch — REQ-056's own AC1 case —
unreachable via any graph that could pass validation: CHK-10 rejected it at graph-validation
time, before `parse_config_from_node_attributes/1` was ever reached. `check_service_task_endpoint/1`
now filters out nodes with a non-blank `"service_id"` before flagging a missing `"endpoint"`, so
only a node with *both* blank/missing is a violation — the same `{nil, nil}` condition
`parse_config_from_node_attributes/1` itself treats as the sole failure case.

### 4.2 CHK-11 detail — `timeout_ms` range, precisely

Boundary values `1` and `300_000` are both **valid** (inclusive range, per REQ-029's own
`[1, 300000]` notation). `0` and any negative integer are invalid (`< 1`). `300_001` and above
are invalid (`> 300_000`). This directly satisfies AC1's explicit "0 and >300000" test-case
pair. No upper bound on how large an out-of-range value can be (no separate "absurdly large"
code) — same single-code-per-rule convention as §4.1.

### 4.3 CHK-12 detail — the ISO-8601 duration scan-forward parser, precisely

**Flagged per §0: this algorithm is reconstructed from REQ-029's prose description alone
(direct source access to definition.md's "Implementation guidance" section was unavailable in
this environment) — concrete and testable, but not verified character-for-character against
the original scan-forward parser. See §9 for the explicit open-question flag.**

A `duration_iso8601` string is **valid** iff all of the following hold:

1. It contains no `.` or `,` character anywhere in the string. (This is the exact mechanism
   that satisfies REQ-029's "fractional components rejected" — ISO-8601 permits a decimal
   fraction on the smallest present unit in general, but this minimal parser rejects any
   fractional component outright, matching the requirement's explicit instruction rather than
   implementing full ISO-8601 fraction support.)
2. It starts with the literal character `P` (uppercase; case-sensitive — ISO-8601 designators
   are case-sensitive uppercase).
3. Splitting the remainder (everything after the leading `P`) on the first `T` character (if
   any) yields a `date_part` (before `T`, or the whole remainder if no `T` is present) and,
   only if `T` was present, a `time_part` (everything after that `T`). If `T` is present but
   `time_part` is the empty string (i.e. the input ends in `...T` with nothing after), the
   duration is **invalid**.
4. `date_part` is scanned left to right as zero or more `<digits><unit>` tokens, where each
   token's `<digits>` is one or more ASCII `0`-`9` characters (no sign, no leading `+`/`-`) and
   `<unit>` is exactly one of `Y`, `M`, `W`, `D`, and the units that do appear (zero or more of
   them are optional) must appear in that relative order with no repeats — e.g. `1Y2M3D` is
   valid ordering, `3D2M1Y` and `1Y1Y` are not. Any leftover, unconsumed characters in
   `date_part` after the last recognized token (a stray letter, an unrecognized unit, a digit
   sequence with no following unit letter) make the duration **invalid**.
5. `time_part` (only scanned if `T` was present) is scanned the same way against the ordered
   unit set `H`, `M`, `S` (note: this `M` is minutes, a different unit from `date_part`'s `M`
   for months — disambiguated purely by which side of `T` it's on, exactly as ISO-8601 itself
   does).
6. If `T` was **not** present, `date_part` alone (per rule 4) must contain **at least one**
   valid token — `P` with nothing after it at all is invalid (an empty duration has no valid
   ISO-8601 representation this parser accepts). If `T` **was** present, `time_part` (per rule
   5) must contain at least one valid token (already covered by rule 3's empty-`time_part`
   case), but `date_part` before it may legally be empty (e.g. `PT1H` — no date component, only
   a time component — is valid).

**`P0D` is explicitly valid** — `date_part = "0D"`, one token (`digits = "0"`, `unit = D`), no
`T`, rule 6's "at least one token" is satisfied by that single token. This directly satisfies
REQ-029's explicit "P0D explicitly permitted as a zero-delay timer" instruction and AC1's "TIMER
P0D explicitly accepted" test case.

**Examples for TEST-DESIGNER (both should be checked against §9's flagged uncertainty before
being treated as ground truth if real source ever becomes reachable):**
- Valid: `"P0D"`, `"P1D"`, `"P1Y2M3D"`, `"PT1H30M"`, `"P1DT12H"`.
- Invalid: `"P"` (no tokens at all), `"PT"` (T with empty time_part), `"1D"` (missing leading
  `P`), `"P1.5D"` (fractional — contains `.`), `"PT1,5S"` (fractional, comma variant), `"P3D2Y"`
  (wrong order), `"PXD"` (no digits before unit).

## 5. `validate_edge_conditions/1` — signature, composition, and node-type resolution

```
@spec validate_edge_conditions(t()) :: result()
```

Same `result()` type, same never-short-circuit unconditional-concatenation composition as §3 —
all 5 checks (CHK-13..CHK-17 below) run against every edge, results concatenated, no check
skipped because an earlier one already flagged the same edge (§5.1 states explicitly which
checks can legitimately co-fire on one edge, by design, not by oversight).

### 5.1 CHK-13..CHK-17 — the 5 named checks (PD-06)

| # | Check (private fn) | Trigger | Violation code |
|---|---|---|---|
| CHK-13 | `check_gateway_condition_presence/1` | edge's resolved source node has `node_type == :EXCLUSIVE_GATEWAY`, `edge.is_default != true`, **and** `edge.condition` is not a non-empty (after trim) string | `:missing_edge_condition` |
| CHK-14 | `check_non_gateway_condition_absence/1` | **not** (resolved source is `:EXCLUSIVE_GATEWAY` **and** `edge.is_default != true`) — i.e. source isn't an EXCLUSIVE_GATEWAY at all, **or** it is but this edge is the default one — **and** `edge.condition != nil` | `:unexpected_edge_condition` |
| CHK-15 | `check_default_condition_conflict/1` | `edge.is_default == true` **and** `edge.condition != nil` (checked regardless of source node type — see rationale below) | `:default_with_condition` |
| CHK-16 | `check_single_default_edge/1` | see §5.3 — more than one default outgoing edge from the same EXCLUSIVE_GATEWAY node | `:multiple_default_edges` |
| CHK-17 | `check_cel_syntax/1` | `edge.condition` is a non-nil, non-empty (after trim) string, **and** `valid_cel_syntax?(edge.condition) == false` (§6) — checked on **every** edge with a present condition, regardless of whether that edge was "allowed" to have one | `:invalid_cel_syntax` |

Every private check function's signature: `@spec check_*(t()) :: [Violation.t()]`, same
uniform-signature convention as §4 and REQ-028's `check_*/1` functions.

**These checks deliberately overlap and can co-fire on the same edge — this is intended, not a
bug, and mirrors REQ-028's own CHK-03 precedent (a doubly-dangling edge produces two
violations, not one).** Concretely:

- An `EXCLUSIVE_GATEWAY` edge with `is_default: true` **and** a non-null `condition` triggers
  **both** CHK-14 (it's "every other edge" since it's default, so its condition must be null)
  **and** CHK-15 (the general default/condition conflict rule) — **two** violations for one
  edge. This is exactly REQ-029 AC2's scenario; the design deliberately gives it two distinct
  codes rather than collapsing them into one, so a caller/test can distinguish "this edge has a
  condition it categorically shouldn't" from "this edge specifically conflates default-ness with
  a condition," matching how the requirement text states them as two separate sentences/rules.
- If that same edge's condition also happens to be syntactically invalid CEL, CHK-17 fires too
  — three violations total for one edge is a legal outcome of this design, not a defect.

**CHK-15 is checked regardless of the edge's source node type, not scoped to
`EXCLUSIVE_GATEWAY` sources only** — REQ-029's text states "`is_default` MUST NOT coexist with a
non-null condition" as a standalone, unscoped rule (distinct from the two sentences that are
explicitly scoped to `EXCLUSIVE_GATEWAY`). `is_default`/`condition` are fields on every `Edge`
regardless of source type (REQ-028 design doc §2.2), so a defensive, source-type-independent
check is the literal reading of the requirement text, and costs nothing extra to also apply to
a non-gateway edge that happens to have both fields set (which CHK-14 would likely also flag via
its "every other edge" branch, but CHK-15 makes the specific field-conflict explicit
regardless).

### 5.2 Resolving `edge.source`'s node type — reuse, not duplicate

CHK-13/CHK-14/CHK-16 need to know each edge's source node's `node_type`. This design reuses the
existing private `build_node_index/1` helper already in `lib/letflow/definitions/graph.ex`
(REQ-028, id → first-occurrence index map, §6.1 of REQ-028's design doc) rather than duplicating
its first-match-wins semantics — module-private functions are accessible anywhere in the same
file regardless of which requirement originally added them. Resolution algorithm, precisely:

1. Build `node_index = build_node_index(graph.nodes)` once (shared across all 5 checks in this
   function, not rebuilt per check — an implementation efficiency note, not a correctness
   requirement, since the map is immutable and cheap to rebuild if ELIXIR-DEV chooses not to
   thread it through).
2. For a given `edge`, resolve `Map.fetch(node_index, edge.source)`. On `{:ok, idx}`, the
   resolved node is `Enum.at(graph.nodes, idx)`, and its `node_type` is what CHK-13/CHK-14/CHK-16
   compare against `:EXCLUSIVE_GATEWAY`.
3. **On `:error` (the edge's `source` doesn't resolve to any node at all — a dangling edge,
   CHK-03's concern, not this function's):** treat the edge as **not** sourced from an
   `EXCLUSIVE_GATEWAY` (a safe default — an unresolvable source can never be confirmed a
   gateway). This routes an edge with a dangling source into CHK-14's "every other edge" bucket
   (its condition, if any, is still required to be null) rather than crashing or silently
   skipping it. This is the concrete instance of §1's "total, defensive, never raises" claim —
   `validate_edge_conditions/1` produces a sensible (if possibly redundant with a separately-
   reported CHK-03 dangling-edge violation) result even on a structurally invalid graph, exactly
   because the ordering contract (§1) is caller-enforced, not internally assumed.

### 5.3 CHK-16 detail — "at most one default edge per gateway," precisely

Mirrors REQ-028's CHK-05 "duplicate reported once per repeated occurrence" convention (REQ-028
design doc §5's CHK-05 detail) exactly, applied per-source-node instead of globally:

1. Group `graph.edges` by resolved source node index (§5.2), keeping only groups whose source
   resolves to an `:EXCLUSIVE_GATEWAY` node.
2. Within each such group, preserving the edges' original declaration order (same
   edge-declaration-order convention as REQ-028 design doc §6.1 point 2), scan left to right and
   collect the sub-list of edges where `is_default == true`.
3. The **first** edge in that sub-list (if any) produces no violation. **Every subsequent** edge
   in that same sub-list produces one `:multiple_default_edges` violation, naming the offending
   edge id and (for message clarity) the gateway node id it belongs to.

Concretely: a gateway with 3 outgoing edges all marked `is_default: true` produces **two**
violations (for the 2nd and 3rd), not one and not three — the identical "N occurrences produce
N-1 violations" shape as CHK-05. A gateway with exactly one default edge among several
non-default ones produces zero CHK-16 violations (that's the legal, required case — an
EXCLUSIVE_GATEWAY is allowed exactly one default edge). This directly satisfies REQ-029 AC3.

## 6. `valid_cel_syntax?/1` — minimal structural CEL check

```
@spec valid_cel_syntax?(String.t()) :: boolean()
```

**Public function** (not `defp`) — unlike the `check_*/1` private helpers, this is exposed
directly so TEST-DESIGNER can test it standalone against bare strings, per AC4's phrasing
("isValidCelSyntax-equivalent rejects... accepts...") which names the function itself as the
thing under test, not just its effect via `validate_edge_conditions/1`.

PROVENANCE (historical, not current decision authority):
**Flagged per §0: reconstructed from REQ-029's own framing alone** ("a minimal structural (CEL
syntax-only, no evaluation) check... R-Co's own comment notes vendor/cel/cel.zig is a stub, so
this is a minimal subset check, not a full CEL implementation") — definition.md's actual "CEL
syntax validation" section text was not directly readable in this environment. The algorithm
below is concrete and testable, but is this design's own reconstruction, not a verified port —
see §9's explicit flag.

**Algorithm, precisely — purely lexical/structural, evaluates nothing:**

1. `String.trim/1` the input. If the trimmed result is `""`, return `false` (an empty condition
   string is never valid CEL syntax).
2. Scan the trimmed string left to right, one character at a time, maintaining two pieces of
   state: a bracket stack (for `(` `)`, `[` `]`, `{` `}` matching) and a "currently inside a
   string literal" flag (tracking which quote character, `'` or `"`, opened the literal
   currently open, if any, honoring a `\` escape so `\"` inside a `"`-delimited literal does not
   close it).
   - While inside a string literal: bracket characters are not pushed/popped/matched — they're
     just literal text. Reaching the end of the input while still inside an unterminated string
     literal (a `'` or `"` never closed) → return `false`.
   - Outside a string literal: `(`/`[`/`{` push onto the bracket stack; `)`/`]`/`}` must match
     the top of the stack (same bracket family, correct nesting) — a mismatch, or a close with
     an empty stack, → return `false` immediately.
3. After the full scan, if the bracket stack is not empty (an unclosed open bracket) → return
   `false`.
4. Reject a syntactically empty-operand expression: if the trimmed string's first token or last
   token (whitespace-delimited, or immediately adjacent to a bracket) is one of the fixed binary/
   unary-infix operator spellings `&&`, `||`, `==`, `!=`, `<=`, `>=`, `<`, `>`, `+`, `-`, `*`,
   `/`, `.` — i.e. the expression starts or ends with an operator that requires an operand on
   the missing side — return `false`.
5. Otherwise, return `true`.

**No evaluation, stated explicitly and demonstrated:** this function never attempts to identify
variable names, look up a value, parse the expression into an AST, or determine what the
expression would evaluate to. A nonsense-but-well-formed expression like
`"this_variable_does_not_exist_anywhere == 42"` returns `true` — the function has no concept of
"exists anywhere," only balanced delimiters and non-empty start/end tokens. TEST-DESIGNER should
write exactly this case as the "no evaluation" demonstration AC4 asks for.

**Concrete examples (ready-made test fixtures):**
- Valid (accept): `"status == \"approved\""` (balanced quote pair, no brackets, doesn't start/
  end with a bare operator), `"amount > 100 && region in [\"US\", \"EU\"]"` (balanced brackets
  and quotes).
- Invalid (reject): `"status == "` (trimmed string ends in the operator `==` with nothing
  after), `"(status == \"approved\""` (unclosed `(`), `"\"unterminated"` (unterminated string
  literal).

## 7. `Violation.code` type extension

`Letflow.Definitions.Graph.Violation`'s `@type code` union (currently the 9 REQ-028 values) gains
9 new atoms, all following the same lowercase-`snake_case` convention as the existing 9 (REQ-028
design doc §2.3's rationale — pattern-matchable in ExUnit, predictable `Atom.to_string/1`
serialization — applies identically here, not re-litigated):

```
:missing_role | :missing_endpoint | :invalid_timeout | :invalid_duration
| :missing_edge_condition | :unexpected_edge_condition | :default_with_condition
| :multiple_default_edges | :invalid_cel_syntax
```

No other field of `Violation` (`code`, `message`, `@enforce_keys [:code, :message]`) changes.

## 8. Purity / zero-I/O invariant — unchanged contract, re-confirmed for the new code

`validate_node_attributes/1`, `validate_edge_conditions/1`, and `valid_cel_syntax?/1` all depend
on Elixir/Erlang stdlib only (`Enum`, `Map`, `MapSet`, `String`, `Kernel`) — same as REQ-028
design doc §8's contract, re-confirmed rather than silently assumed to still hold: no
`Letflow.Repo`, no `Ecto.Changeset`, no `Logger.*`, no clock read, no HTTP/file/process-mailbox
call anywhere in the new code. The same grep/`mix xref` verification method (REQ-028 design doc
§8) applies unchanged: `grep -n "Repo\.\|Logger\.\|DateTime\.\|System\.os_time\|HTTPoison\|Req\.\|File\." lib/letflow/definitions/graph.ex`
must still return zero matches after this extension lands.

REQ-029's text also asks whether `GraphError.OutOfMemory`'s Elixir-idiomatic equivalent is
reused anywhere in this extension — **it is not, for the same reason REQ-028 design doc §4
already gave**: Elixir has no allocator-failure return case to model, and neither
`validate_node_attributes/1` nor `validate_edge_conditions/1` nor `valid_cel_syntax?/1` can fail
in the `:ok | {:error, _}` sense — every one of them is total over its typed input, same as
`validate_graph/1`. This divergence is noted explicitly in the moduledoc addition (§1), not
silently dropped.

## 9. Open questions — not resolved here

### 9.1 ISO-8601 duration parser and CEL syntax algorithm — reconstructed, not verified against source

§4.3 and §6 give concrete, testable algorithms, but both were built from REQ-029's own prose
description alone — this environment had no access to `R-Co/src/design/definition.md`'s actual
"Implementation guidance"/"CEL syntax validation" text (§0). If R-Co source becomes reachable
before or during implementation, ELIXIR-DEV should diff §4.3/§6 against the real scan-forward
parser and CEL syntax section and flag any divergence to REVIEWER rather than silently
implementing the reconstruction as-is if it turns out to disagree with source. Not resolved here
— flagged so the gap is visible rather than papered over by confident-sounding prose.

### 9.2 Unknown/bogus `node_type` handling — inherited from REQ-028 §9.2, not newly resolved

As stated in §4: a `Node` whose `node_type` is not one of the 7 known atoms is not examined by
any of CHK-09..12 (none of their type filters match it), so it silently receives no attribute
validation at all, the same way it silently falls through REQ-028's CHK-04 "generic" branch.
This is the same open gap REQ-028 design doc §9.2 already flagged and left for "REQ-029 or a
future requirement to decide" — REQ-029 does not resolve it either; it remains open for
whichever future requirement adds the JSON-decoding-boundary validation REQ-028 §9.3 already
gestured at.

### 9.3 REQ-030 must call two new functions, not the one its current text names

Stated fully in §1 — REQ-030's requirement text as currently written names only
`validate_node_attributes/1`; this design's `validate_edge_conditions/1` is an equally required
second call REQ-030's text does not yet mention. Flagged for REQ-030's CODE-DESIGNER to pick up
explicitly, not assumed to be automatically obvious from this file alone.

## 10. Cross-module dependencies

Unchanged from REQ-028 design doc §10 — still zero dependencies on any other `lib/letflow/`
module. `validate_node_attributes/1` and `validate_edge_conditions/1` depend only on this same
file's existing `Node`/`Edge`/`Violation`/`t()` types and the existing private
`build_node_index/1` helper (§5.2) — no new intra-`lib/letflow/` dependency is introduced.
Forward dependent: REQ-030's future `Letflow.Definitions.create/1` (§1, §9.3).

## 11. Acceptance-criteria traceability

| REQ-029 acceptance criterion | Concrete design element |
|---|---|
| "each of the 7 node types has at least one explicit test: HUMAN_TASK missing role, SERVICE_TASK missing endpoint, SERVICE_TASK invalid timeout (0 and >300000), TIMER missing/invalid duration, TIMER P0D explicitly accepted, and START/END/gateway types accepting no attributes" | §4's CHK-09..12 table (exact trigger per type) + §4.2 (explicit `0`/`300001+` boundary cases) + §4.3 (parser algorithm + explicit `P0D`-valid rule + invalid examples) + §4's "no check in this table applies" statement for START/END/EXCLUSIVE_GATEWAY/PARALLEL_GATEWAY |
| "an EXCLUSIVE_GATEWAY edge with both a non-null condition and is_default: true is rejected" | §5.1 CHK-15 (`:default_with_condition`, unscoped by source type) + §5.1's explicit note that CHK-14 also co-fires on this exact scenario (two violations, by design) |
| "an EXCLUSIVE_GATEWAY with two edges both marked is_default: true is rejected" | §5.3 CHK-16, full "N defaults → N-1 violations" algorithm mirroring CHK-05 |
| "isValidCelSyntax-equivalent rejects at least one structurally invalid expression and accepts at least one structurally valid one, with an explicit test noting it performs no evaluation" | §6's full algorithm + concrete valid/invalid example pairs + the explicit "no evaluation" paragraph with a ready-made nonsense-variable test case |
| "extra undeclared attributes on a node do not cause a violation, demonstrated by an explicit test" | §2's "any other key present in the map... is never read by any check" (true by construction — no allow-list/ignore-list logic needed) |
