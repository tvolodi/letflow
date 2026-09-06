PROVENANCE (historical, not current decision authority):
# Design: REQ-032 — Sub-process interface contract, definition-time half only (sub_process_interface.zig, SPC-02)

**Requirement:** REQ-032 (`docs/requirements.yaml`, stage S2)
**Owner (implementer):** ELIXIR-DEV
**Extends:** `lib/letflow/definitions/graph.ex` (REQ-028/029, `status: done`, merged to `main`)
— adds an 8th `node_type` variant, one new `Violation.code` group (6 codes), and one new
check function (CHK-18) to `validate_node_attributes/1`'s check list.
**Adds:** a new sibling module, `Letflow.Definitions.SubProcessInterface`
(`lib/letflow/definitions/sub_process_interface.ex`) — see §1 for why this is a separate
file rather than more private functions inside `graph.ex`.
**This document produces:** the `:SUB_PROCESS` node-type addition, the new sibling
module's full public/private function signatures, the interface-entry/parsed-interface
data shapes, the 6 named violation codes and their exact trigger conditions, the
JSON-Schema-of-schemas well-formedness algorithm (supported keyword table, inert-unknown-
keyword rule, 32-level recursion cap), the moduledoc-facing SPC-01-out-of-scope statement,
invariants, cross-module dependencies, and open questions. Signatures and type shapes
only — no implementation code, no function bodies, no `.ex`/`.exs` code blocks.

## 0. Sources read for this design, and an explicit access gap

- `docs/requirements.yaml` REQ-032's full entry (quoted throughout below where
  load-bearing), and REQ-029's full entry (the PD-05 hook point this requirement extends).
- `lib/letflow/design/req029-node-attribute-edge-condition-validators.md` (full) — the
  directly preceding design for the same file, whose conventions this design continues:
  the `check_*/1` uniform-signature pattern, the never-short-circuit
  collect-all-violations composition, the `Violation.t()` shape, the
  "reconstructed-from-requirements.yaml-prose, flagged explicitly" precedent for an
  algorithm this environment cannot read from R-Co source directly (§4.3/§6 of that
  document), and its own explicit open-question style (§9) — followed here rather than
  re-invented.
PROVENANCE (historical, not current decision authority):
- `lib/letflow/design/req028-graph-structural-validator.md` §0 — **directly relevant and
  load-bearing for §2 below**: REQ-028's own design doc states it read `graph.zig` directly
  and found `NodeType` already has **8** variants there, *including `SUB_PROCESS`, "added
  later for SPC-02"* — but that REQ-028's own description **explicitly overrides this**
  with `definition.md`'s 7-variant PD-05-authoritative set (no `SUB_PROCESS`), "so this
  design follows the requirement text, not the literal current `graph.zig` enum." That is a
  **firm, explicit decision to exclude `SUB_PROCESS`**, not a deferral — REQ-028 does not
  flag this as an open question anywhere in its own document. REQ-029 did not add it either
  (its design doc inherits the 7-variant type unchanged). §2 below names REQ-032's addition
  of `SUB_PROCESS` for what it is: an override of that prior decision, not the resolution of
  a previously-flagged item.
- `lib/letflow/definitions/graph.ex` (full, current `main`, post-REQ-029) — the actual
  module this design extends in place; confirms the exact current `node_type` union (7
  variants, line ~56), the `Violation.code` union (18 atoms post-REQ-029, line ~113), the
  `validate_node_attributes/1` check list (4 entries, line ~187), the `check_*/1` naming/
  signature convention, and that `attributes` stays `map() | nil` with string keys
  (REQ-029 design doc §2, re-confirmed unchanged here — see §2 below).
- `docs/guides/backend_developer_guide.md` §2/§3 (project structure, naming/error-shape
  conventions) and `docs/anti-patterns.md` (no entries currently relevant to this module).
- `docs/migration/stage-2-event-store-definitions.md` — re-confirms REQ-032 is in scope
  for S2 (pending → this run) and the "Static-typing gap" finding already cited by
  REQ-028/029's own design docs, re-confirmed still relevant (this is exactly the kind of
  larger validation surface — a recursive schema-of-schemas checker — that finding warns
  not to under-test).

PROVENANCE (historical, not current decision authority):
**Access gap, stated explicitly per this task's own instruction, not silently worked
around:** this environment does not have `R-Co/src/definition/sub_process_interface.zig`
or `R-Co/src/design/spc-01-sub-process-interface-contract.md` checked out anywhere
reachable — no `R-Co` directory exists on this host at all (same gap REQ-029's design doc
hit and documented). This design is built from `docs/requirements.yaml`'s REQ-032 entry,
which is itself described as directly quoting spc-01's field-semantics table, JSON-Schema-
of-schemas keyword table, and violation-code taxonomy. Two consequences, flagged inline
where they occur rather than glossed over:

1. Several structural details spc-01 itself would pin precisely — whether `inputs`/
   `outputs` keys are individually required inside a well-formed `interface` object,
   whether unknown keys on an entry tuple (beyond `name`/`json_schema`/`required`) are
   tolerated, whether `items` supports JSON Schema's array-of-schemas ("tuple validation")
   form, and whether `type`'s value must match an enumerated set of legal JSON Schema type
   names — are not stated in REQ-032's text at the level of detail needed to implement
   without a decision. §7's open questions list each one with this design's chosen default
   and the reasoning, rather than silently picking one.
2. Everywhere REQ-028/029's design already resolved a naming/typing/behavior question by
   reading source directly (e.g. `attributes` being a string-keyed decoded map, no atom
   keys from untrusted JSON), this design defers to that already-approved resolution
   rather than re-deriving it.

## 1. Module placement — sibling module, not more private functions in `graph.ex`

**Decision: a new sibling module, `Letflow.Definitions.SubProcessInterface`
(`lib/letflow/definitions/sub_process_interface.ex`), called from one new private check
function inside `graph.ex` — not implemented as private functions directly inside
`Letflow.Definitions.Graph`.**

Reasoning:

PROVENANCE (historical, not current decision authority):
- **R-Co's own file split is a real signal, not just a naming coincidence.** R-Co keeps
  `sub_process_interface.zig` as its own file, separate from `graph.zig`, even though
  `graph.zig`'s own `checkSubProcess` is the PD-05 hook point that calls into it (REQ-032's
  description: "hooked into REQ-029's PD-05 node-attribute validation pass since spc-01's
  own 'Hook point' section states checkSubProcess 'executes as part of the PD-05 node-type
  attribute validation'"). The hook point lives in the graph module; the interface-parsing/
  schema-validation *logic* lives in its own file. This design ports that same split.
- **Self-contained recursive algorithm with its own concern.** The JSON-Schema-of-schemas
  well-formedness check (§6) is a general-purpose recursive structural validator with no
  dependency on `Node`/`Edge`/graph-level concepts — it only needs a `json_schema` value and
  a depth counter. Bundling it into `graph.ex` (already ~980 lines post-REQ-029, the
  largest module in `lib/letflow/definitions/`) would make an already-large file larger with
  logic that has no real coupling to graph structure, edges, or the other 17 checks.
  `lib/letflow/design/req028-graph-structural-validator.md` §1 already established this
  codebase's precedent of both "root file + sibling files" (`identity.ex` +
  `identity/*.ex`) and "sibling files, no root aggregator" (`oidc/*.ex`) shapes existing
  side by side — a new focused sibling file for a self-contained algorithm is squarely
  within that established pattern, not a new one being invented.
- **Testability.** `validate_schema_shape/2` (§6) and `parse_interface/2` (§5) are directly
  unit-testable against bare schema/interface values with zero `Graph.t()` scaffolding —
  TEST-DESIGNER can write focused tests against `Letflow.Definitions.SubProcessInterface`
  without constructing a full graph, mirroring how REQ-029's `valid_cel_syntax?/1` was kept
  public specifically so it could be tested standalone (REQ-029 design doc §6).
- **One-directional dependency, no cycle.** `Letflow.Definitions.Graph`'s new check function
  calls into `Letflow.Definitions.SubProcessInterface`; the reverse never happens.
  `SubProcessInterface`'s violation-producing functions return
  `Letflow.Definitions.Graph.Violation.t()` directly (reusing the existing struct, not a
  parallel violation type + a translation step) — see §5's signatures. This is the one
  cross-module reference the sibling module carries; documented in full in §8.

## 2. `:SUB_PROCESS` — the 8th `node_type` variant

**Decision: add `:SUB_PROCESS` to `Letflow.Definitions.Graph.node_type/0`'s union,
becoming the 8th variant.** This is not a REQ-032 acceptance criterion by name, but is
structurally required for the requirement to mean anything (a SUB_PROCESS node's
`interface` attribute cannot be validated if no node can ever be constructed with
`node_type: :SUB_PROCESS` in the first place) — named explicitly here as a necessary
`graph.ex` extension, not a silent scope expansion, per this task's own framing.

```
@type node_type ::
        :START
        | :END
        | :HUMAN_TASK
        | :SERVICE_TASK
        | :EXCLUSIVE_GATEWAY
        | :PARALLEL_GATEWAY
        | :TIMER
        | :SUB_PROCESS
```

PROVENANCE (historical, not current decision authority):
**This overrides REQ-028's own prior decision — named explicitly as an override, not a
silent reversal, per `core-directives.md`'s "don't silently re-decide what a decision
record already settled" concern.** `req028-graph-structural-validator.md` §0 states
directly: `graph.zig`'s real `NodeType` enum already has 8 variants including
`SUB_PROCESS`, "added later for SPC-02," but that REQ-028's own description "explicitly
overrides this with definition.md's 7-variant PD-05-authoritative set (no `SUB_PROCESS`),
so this design follows the requirement text, not the literal current `graph.zig` enum."
That was a **firm, explicit decision to exclude `SUB_PROCESS`** — REQ-028 does not flag it
as deferred, open, or left to a future requirement anywhere in its own document. (REQ-028's
actual deferred/open item, §9.2, is a different, unrelated question — whether a 9th check
should reject a bogus/unknown `node_type` atom like `:BOGUS`; it never mentions
`SUB_PROCESS`.) REQ-029 inherited the 7-variant type unchanged, confirming REQ-028's
exclusion stood through the next requirement too.

REQ-032 overrides that decision by necessity, not by re-litigating it: a SUB_PROCESS node
cannot be constructed at all, and this requirement cannot mean anything, without the
variant existing in `node_type/0`'s union. This is a new, independent decision this design
is making — the reason is stated in the paragraph above (structurally required for REQ-032
to be meaningful), not an inherited resolution of something REQ-028 left open. Naming it
this way — override, with a stated reason — rather than as REQ-028 "closing a loop" it
never actually left open, is the point of this rework.

**No other structural-check changes are needed for this addition, confirmed against every
existing check that switches on `node_type`:**

- `check_start_node/1`, `check_end_node/1`: match on `:START`/`:END` specifically —
  unaffected.
- `check_isolated_nodes/1` (CHK-04): its `case node.node_type do :START -> ...; :END -> ...;
  _other -> ...; end` clause already treats every non-START/END type uniformly (requires
  both incoming and outgoing edges) — `:SUB_PROCESS` falls into `_other` automatically,
  requiring a SUB_PROCESS node to have both an incoming and outgoing edge like any
  HUMAN_TASK/SERVICE_TASK/gateway/TIMER node. This is the structurally correct default (a
  sub-process step sits inline in the flow, not a source/sink) and needs no code change.
- `check_cycles/1`'s `@gateway_types` `MapSet` (`:EXCLUSIVE_GATEWAY`, `:PARALLEL_GATEWAY`)
  is unaffected — `:SUB_PROCESS` is not a gateway type, so a cycle through a SUB_PROCESS
  node with no gateway elsewhere on the cycle is still correctly rejected as
  `:cycle_without_gateway`, unchanged behavior.
- CHK-09..17 (REQ-029's node-attribute/edge-condition checks): each filters `graph.nodes`/
  edges to its own specific type(s) (`:HUMAN_TASK`, `:SERVICE_TASK`, `:TIMER`,
  `:EXCLUSIVE_GATEWAY`-sourced edges) — none of their filters match `:SUB_PROCESS`, so a
  SUB_PROCESS node is silently exempt from all of CHK-09..17, the same "no check in this
  table applies" treatment REQ-029's design doc §4 already documents for START/END/
  gateways. Confirmed, not silently assumed.

**No `Node`/`Edge` struct field changes.** `Node.attributes` stays `map() | nil`, same as
REQ-029 design doc §2's resolution — `SUB_PROCESS`'s optional `interface` key is read the
same way `HUMAN_TASK`'s `"role"` or `SERVICE_TASK`'s `"endpoint"` are: a string-keyed lookup
on the existing `attributes` map, no new struct field, no new decode step.

## 3. `Violation.code` type extension — 6 new atoms

`Letflow.Definitions.Graph.Violation`'s `@type code` union (currently 18 atoms post-REQ-029)
gains 6 new atoms, same lowercase-`snake_case`, full-word (not truncated) naming convention
as the existing ones:

```
:sub_process_interface_not_object
| :sub_process_interface_inputs_not_array
| :sub_process_interface_outputs_not_array
| :sub_process_interface_entry_invalid
| :sub_process_interface_schema_invalid
| :sub_process_interface_duplicate_name
```

Mapping from REQ-032's SCREAMING_SNAKE_CASE names (the requirement text's own naming, taken
directly from spc-01's error taxonomy table) to these atoms:

| REQ-032 name | Atom |
|---|---|
| `SUB_PROCESS_INTERFACE_NOT_OBJECT` | `:sub_process_interface_not_object` |
| `SUB_PROCESS_INTERFACE_INPUTS_NOT_ARRAY` | `:sub_process_interface_inputs_not_array` |
| `SUB_PROCESS_INTERFACE_OUTPUTS_NOT_ARRAY` | `:sub_process_interface_outputs_not_array` |
| `SUB_PROCESS_INTERFACE_ENTRY_INVALID` | `:sub_process_interface_entry_invalid` |
| `SUB_PROCESS_INTERFACE_SCHEMA_INVALID` | `:sub_process_interface_schema_invalid` |
| `SUB_PROCESS_INTERFACE_DUPLICATE_NAME` | `:sub_process_interface_duplicate_name` |

No other field of `Violation` (`code`, `message`, `@enforce_keys [:code, :message]`)
changes — same struct, reused directly by `Letflow.Definitions.SubProcessInterface`'s
functions (§1, §5).

## 4. `graph.ex` hook point — CHK-18

`validate_node_attributes/1`'s check-function list (currently `check_human_task_role/1`,
`check_service_task_endpoint/1`, `check_service_task_timeout/1`, `check_timer_duration/1` —
CHK-09..12) gains a 5th entry, continuing REQ-029's numbering as **CHK-18** (REQ-029 used
CHK-09..17; 18 is next, not reused):

```
@spec check_sub_process_interface(t()) :: [Violation.t()]
```

Filters `graph.nodes` to `node_type == :SUB_PROCESS`, and for each such node calls
`Letflow.Definitions.SubProcessInterface.validate_node_interface/2` (§5) with the node's
`id` and `attributes`, concatenating the returned violation lists — same
`Enum.flat_map`-over-filtered-nodes shape as CHK-09/10/11, same "no-op on a node of any
other type" behavior (§2's confirmation).

**One check function producing up to 6 different codes, not 6 separate one-code-per-check
functions — a deliberate divergence from CHK-09..17's "one check, one code" convention,
stated explicitly rather than silently done.** REQ-029's checks were independent axes (a
node's role-check outcome has zero bearing on its timeout-check outcome). Here the 6 codes
form a dependency chain within a single parse: whether an entry can even be checked for
`_SCHEMA_INVALID` depends on it first passing the `_ENTRY_INVALID` shape check; whether
`_DUPLICATE_NAME` is checked at all depends on `inputs`/`outputs` first being confirmed as
arrays. Re-parsing the same `interface` value from scratch once per code, mirroring
CHK-09..17's independent-check shape, would mean repeating the same array-membership/
entry-shape work up to 6 times per node for no benefit — one pass that collects every
applicable violation (§5's `parse_interface/2`) is both more efficient and structurally
honest about the real dependency between these checks. All 6 codes remain independently
distinguishable in the output (§3), which is what AC2 actually requires — "one check
function" is an internal implementation-shape choice, not a change to what's observable.

**`validate_node_attributes/1`'s moduledoc entry (graph.ex, currently documents CHK-09..17)
must be extended** with one sentence: *"CHK-18 (`check_sub_process_interface/1`, REQ-032)
delegates to `Letflow.Definitions.SubProcessInterface` for the SUB_PROCESS node type's
optional `interface` attribute — see that module's moduledoc for the full SPC-02 contract
and the explicit SPC-01-out-of-scope statement (§8 below)."* This keeps `graph.ex`'s own
moduledoc as the single index of "which check owns what," consistent with how it already
documents CHK-09..17's addition (REQ-029 design doc precedent), while pointing the reader
at the sibling module for the actual SPC-02 substance rather than duplicating it.

## 5. `Letflow.Definitions.SubProcessInterface` — types and function signatures

File: `lib/letflow/definitions/sub_process_interface.ex`.

### 5.1 Data structures

```
@type entry :: %{name: String.t(), json_schema: map(), required: boolean()}

@type parsed_interface :: %{inputs: [entry()], outputs: [entry()]}
```

Plain maps with **atom** keys (`:name`, `:json_schema`, `:required`), not a `defstruct` and
not string keys. Two reasons, both worth stating rather than assuming:

- **Not a `defstruct`:** `entry`/`parsed_interface` are ephemeral, validation-internal data
  — never persisted (§5.4), never passed outside this module and `graph.ex`'s call site.
  This mirrors `validate_graph/1`'s own `result()` type (`%{valid: boolean(), violations:
  [...]}`), which is also a plain map, not a struct — same "no struct needed for a
  throwaway shape" precedent already in this file.
- **Atom keys are safe here, unlike `Node.attributes`:** REQ-029 design doc §2 pinned
  `attributes` as *string*-keyed specifically because its keys come from
  attacker/tenant-controlled JSON (`String.to_atom/1` on untrusted external strings is an
  atom-table-exhaustion risk). `entry`/`parsed_interface`'s keys (`:name`, `:json_schema`,
  `:required`, `:inputs`, `:outputs`) are **fixed, code-defined atoms this module's own
  source writes literally** — no external string is ever converted to an atom to produce
  them. This is the same reasoning that already justifies `result()`'s `:valid`/
  `:violations` atom keys elsewhere in `graph.ex`; re-confirmed here, not re-litigated.

### 5.2 `validate_node_interface/2` — the check-list entry point

```
@spec validate_node_interface(node_id :: String.t(), attributes :: map() | nil) ::
        [Letflow.Definitions.Graph.Violation.t()]
```

Called once per SUB_PROCESS node from `graph.ex`'s CHK-18 (§4). Extracts
`interface_value = if is_map(attributes), do: Map.get(attributes, "interface"), else: nil`,
calls `parse_interface/2` (§5.3) with `node_id` and `interface_value`, and returns just the
violations half of that function's `{parsed_interface() | nil, [Violation.t()]}` result
(the parsed data itself is discarded here — it exists only to drive the checks; see §5.4 on
why nothing downstream of validation consumes it in this requirement's scope). Total and
defensive: never raises, always returns a list (possibly `[]`).

### 5.3 `parse_interface/2` — public, standalone-testable parser

```
@spec parse_interface(node_id :: String.t(), interface_value :: term()) ::
        {parsed_interface() | nil, [Letflow.Definitions.Graph.Violation.t()]}
```

**Public, not private** — same rationale as REQ-029's `valid_cel_syntax?/1` (design doc §6):
exposed so TEST-DESIGNER can test the parse/validate logic directly against bare
`interface_value` terms, without constructing a `Graph.t()`/`Node.t()` first, per AC2's
"each of the 6 named violation codes has at least one explicit failing-example test."

**Arity/naming note — a deliberate divergence from R-Co's `parseInterface/1`, stated
explicitly:** REQ-032's text names `parseInterface/1`. This design uses arity 2
(`node_id`, `interface_value`) because every violation message in this codebase's
established convention (`graph.ex`'s CHK-01..17 precedent, unbroken) embeds the offending
node's id for a caller to locate the problem — Zig's `parseInterface` presumably receives
the node id via a wider call-site context this design doesn't have visibility into. Passing
`node_id` explicitly here keeps `parse_interface/2` itself total and self-contained (no
hidden dependency on being called from inside a larger node-iteration loop) while still
producing locatable violation messages when used standalone in a test.

**Algorithm, precisely:**

1. `interface_value == nil` → the `interface` attribute is absent entirely (optional, per
   REQ-032's "a SUB_PROCESS node's **optional** interface attribute") → return `{nil, []}`.
   **This is the first check in this validator (across CHK-01..18) whose "attribute
   entirely absent" case is valid, not a violation** — contrast explicitly with CHK-09..12
   (REQ-029), where `attributes == nil` or the specific key being absent is *always* the
   trigger condition for a violation, because `role`/`endpoint`/`timeout_ms`/
   `duration_iso8601` are required for their respective node types. `interface` is
   optional for `SUB_PROCESS` — flagged here so ELIXIR-DEV does not copy CHK-09..12's
   "absent ⇒ violation" pattern by habit.
2. `interface_value` is not a map (any other JSON-decoded type — string, number, boolean,
   list, or explicit JSON `null` already handled by step 1) → return `{nil, [%Violation{
   code: :sub_process_interface_not_object, message: "Node '<node_id>' has a SUB_PROCESS
   interface attribute that is not a JSON object"}]}`. **AC2's `SUB_PROCESS_INTERFACE_NOT_OBJECT`
   case — no further parsing is attempted once this fires** (nothing else can be checked
   about the shape of something that isn't an object at all).
3. Otherwise (`interface_value` is a map):
   a. `inputs_raw = Map.get(interface_value, "inputs", [])`; `outputs_raw =
      Map.get(interface_value, "outputs", [])` — an **absent** `"inputs"`/`"outputs"` key
      defaults to `[]` (empty list), not a violation (§7 open question 1 states this
      default explicitly as a design choice, not a literally-stated rule).
   b. If `inputs_raw` is not a list → emit
      `%Violation{code: :sub_process_interface_inputs_not_array, message: "Node
      '<node_id>' SUB_PROCESS interface's 'inputs' is not a JSON array"}`, and treat
      `parsed_inputs = []` for the rest of this parse (no entry-level or duplicate-name
      checking is attempted against a non-array `inputs` value). Symmetric handling for
      `outputs_raw` → `:sub_process_interface_outputs_not_array`, independently — both can
      fire on the same `interface_value` (an object with neither `inputs` nor `outputs` as
      an array triggers both codes, one violation each; never-short-circuit, same
      composition convention as every other check in this file).
   c. For each of `inputs_raw` (if it was a list) and `outputs_raw` (if it was a list),
      independently, call `parse_entries/3` (§5.3.1) with `node_id`, the list name
      (`"inputs"` or `"outputs"`, used only for message text), and the raw list — producing
      `{parsed_entries, entry_violations}` per list.
   d. For each of the two `parsed_entries` lists independently, call
      `check_duplicate_names/3` (§5.3.2) with `node_id`, the list name, and that list's
      entries whose `name` field parsed successfully (§5.3.1 point defines exactly which
      entries qualify) — producing `duplicate_violations` per list.
   e. Concatenate, in this order (order affects nothing observable — `Violation.t()` has no
      ordering guarantee elsewhere in this file either — stated for reproducibility only):
      `inputs_not_array/outputs_not_array` violations (if any) ++ inputs' entry violations
      ++ outputs' entry violations ++ inputs' duplicate-name violations ++ outputs'
      duplicate-name violations.
   f. Return `{%{inputs: parsed_inputs, outputs: parsed_outputs}, all_violations}` —
      `parsed_inputs`/`parsed_outputs` contain only the entries that passed
      `_ENTRY_INVALID`'s shape check (§5.3.1); entries with valid shape but an invalid
      `json_schema` (`_SCHEMA_INVALID`) **are** still included in the returned
      `parsed_interface()` (their shape is valid — only the nested schema failed a deeper
      check), consistent with `_ENTRY_INVALID` and `_SCHEMA_INVALID` being reported as
      exclusive alternatives (never both on the same entry — §5.3.1 states this precisely).

### 5.3.1 `parse_entries/3` — per-list entry parsing and shape/schema checks

```
@spec parse_entries(node_id :: String.t(), list_name :: String.t(), raw_entries :: [term()]) ::
        {[entry()], [Letflow.Definitions.Graph.Violation.t()]}
```

Private. For each element of `raw_entries` (order preserved, index used only for message
text on `_ENTRY_INVALID`, not part of any code's identity):

1. **`_ENTRY_INVALID` trigger (exclusive of `_SCHEMA_INVALID` — checked first, and if it
   fires, `_SCHEMA_INVALID` is never also checked for that same entry):** the raw element is
   not a map; **or** it has no `"name"` key, or `"name"`'s value is not a `String.t()`, or
   is a `String.t()` that is empty/whitespace-only after `String.trim/1` (same
   blank-string test convention as REQ-029 design doc §4.1's CHK-09/CHK-10); **or** it has
   no `"json_schema"` key, or `"json_schema"`'s value is not a map (top-level type check
   only at this point — deep well-formedness is §5.3's step 2 below, not this one); **or**
   it has a `"required"` key whose value is present but not a `boolean()`. Any one of these
   → one `%Violation{code: :sub_process_interface_entry_invalid, message: "Node '<node_id>'
   SUB_PROCESS interface's '<list_name>' entry at index <i> is invalid: <reason>"}` for that
   entry; **the entry is excluded from this list's returned `[entry()]`** (§5.3 point f).
2. **Only if step 1 did not fire** (the raw element is a map with a valid non-empty `name`
   string and a `json_schema` that is a map; `required`, if present, is a boolean): compute
   `required = Map.get(raw_entry, "required", false)` (REQ-032's explicit "required
   defaulting to false when absent" rule — AC1's "well-formed interface" wording and the
   requirement's own field-semantics citation), then call `validate_schema_shape(raw_entry
   ["json_schema"], 1)` (§6; depth `1` for the entry's own top-level schema — see §6's exact
   depth-numbering convention). If that returns `false` → one `%Violation{code:
   :sub_process_interface_schema_invalid, message: "Node '<node_id>' SUB_PROCESS
   interface's '<list_name>' entry '<name>' has a malformed json_schema"}`; the entry **is
   still included** in this list's returned `[entry()]` (§5.3 point f's rationale — its
   tuple shape is valid, only the nested schema failed).
   If `validate_schema_shape/2` returns `true` → no violation for this entry; it is
   included in the returned `[entry()]` as `%{name: name, json_schema: json_schema,
   required: required}`.

Returns `{parsed_entries, violations}` for this one list — `parsed_entries` in original
order, `violations` in original order, concatenated by `parse_interface/2` (§5.3 point e).

### 5.3.2 `check_duplicate_names/3` — per-list duplicate-name detection

```
@spec check_duplicate_names(node_id :: String.t(), list_name :: String.t(), entries :: [entry()]) ::
        [Letflow.Definitions.Graph.Violation.t()]
```

Private. Same "N occurrences of a repeated value → N-1 violations, reported on each
repeat, not on the first occurrence" convention already established twice in this file
(`check_duplicate_node_ids/1`'s CHK-05, and REQ-029's `check_single_default_edge/1`'s
CHK-16, REQ-029 design doc §5.3): for each `entries[i]` (`i > 0`) whose `name` exactly
equals some `entries[j]`'s `name` for `j < i`, emit one `%Violation{code:
:sub_process_interface_duplicate_name, message: "Node '<node_id>' SUB_PROCESS interface's
'<list_name>' has a duplicate entry name '<name>'"}`. Comparison is exact `String.t()`
equality — no `String.trim/1`, no case-folding (§7 open question 5 flags this as a design
choice, not a literally-stated rule). **Checked independently per list — `inputs` and
`outputs` do not share a duplicate-name namespace** (REQ-032's own text: "duplicate name
within inputs or within outputs" — two separate checks, not one across both), matching this
requirement's explicit wording directly.

**Operates on the `entries` list as already filtered by `parse_entries/3` to only those
whose `name` parsed successfully** (§5.3.1 point 1's `_ENTRY_INVALID` case excludes an
entry from `parsed_entries` if `name` itself is missing/blank/wrong-type — such an entry
has no reliable name to dedupe against and is correctly never a candidate here). An entry
that is present in `parsed_entries` because it passed the name/shape check but has an
invalid `json_schema` (`_SCHEMA_INVALID`, §5.3.1 point 2) **is** still a valid
duplicate-name candidate — its name is real and usable even though its schema is broken;
both violations (`_SCHEMA_INVALID` on that entry, `_DUPLICATE_NAME` if it repeats an
earlier name) can legitimately co-fire, same "these checks deliberately overlap" precedent
REQ-029 design doc §5.1 already established for CHK-14/15.

### 5.4 What this module does *not* do — no data-transformation side effect on persistence

**`parse_interface/2`'s `parsed_interface()` return value is a validation-internal
artifact only, in this requirement's scope — it is not returned to, or used by, any
persistence path.** AC1 states a well-formed interface "passes validation and is persisted
unchanged as part of the node's attributes" — i.e. the original JSON `attributes` map
(with its original `"interface"` sub-object, string keys, and whatever key ordering/
whitespace it had) is what gets written to the `process_definitions.graph` `jsonb` column
(REQ-027/030's concern, unaffected by this requirement), not a re-serialized version of
`parsed_interface()`'s atom-keyed maps. `validate_node_interface/2` (§5.2) — the only
function `graph.ex` calls — returns violations only, exactly like every other CHK-*
function in this file; it never returns or mutates the graph/node/attributes it was given.
This mirrors `validate_node_attributes/1`'s own top-level contract (`result()`, no graph
data in the return value) exactly.

## 6. `validate_schema_shape/2` — JSON-Schema-of-schemas well-formedness algorithm

```
@spec validate_schema_shape(schema :: term(), depth :: pos_integer()) :: boolean()
```

**Public** (not `defp`) — same standalone-testability rationale as `parse_interface/2`
(§5.3) and REQ-029's `valid_cel_syntax?/1`: AC3 and AC4 both name behavior of this specific
function ("an interface entry's json_schema containing an unsupported-but-recognized-as-
inert keyword ... is accepted," "a json_schema nested beyond the 32-level recursion cap is
rejected") that TEST-DESIGNER should be able to test directly against bare schema terms,
not only indirectly through a full node/interface fixture.

**Returns a `boolean()`, not a violation list — a deliberate, precedented divergence from
this file's usual violation-collecting convention, stated explicitly.** Every `check_*/1`
function in `graph.ex` collects every applicable violation without short-circuiting (Key
invariant, REQ-028/029). `validate_schema_shape/2` does not follow that shape, and should
not: it answers one yes/no structural-well-formedness question about one `json_schema`
value, called from exactly one place (`parse_entries/3`, §5.3.1 point 2), which itself
already reports the single `_SCHEMA_INVALID` code (not "N distinct schema-shape problems as
N distinct codes" — spc-01's own taxonomy has only one schema-shape code, unlike the 4
node-attribute codes or 6 interface-entry-level codes). Short-circuiting here costs nothing
observable and directly precedents `valid_cel_syntax?/1`, which is already public,
boolean-returning, and internally short-circuits via `cond`/`Enum.reduce_while` (REQ-029
design doc §6) — the same shape, reused rather than reinvented.

**Depth convention, precisely (load-bearing for AC4):** the entry's own top-level
`json_schema` value is passed at `depth = 1` (§5.3.1 point 2's call site). Each recursive
descent into a nested schema (via a `"properties"` value, `"items"`, or `"additionalProperties"`
when it is itself a schema object — see the table below) increments depth by 1 for that
nested call. **A call made with `depth > 32` returns `false` immediately, without
inspecting `schema` further.** Consequently: a schema nested exactly 32 levels deep (32
nested schema objects counting the entry's own top-level one) is the maximum *accepted*
depth; a 33rd level of nesting is what "nested beyond the 32-level cap" (AC4's wording)
concretely means, and is rejected. This is pinned precisely so TEST-DESIGNER can build an
exact 32-deep (valid) and 33-deep (invalid) fixture pair without ambiguity.

**Algorithm, precisely:**

1. If `depth > 32` → return `false`.
2. If `schema` is not a `map()` → return `false`. (A nested value reached via
   `"properties"`'s values, `"items"`, or `"additionalProperties"` that isn't itself a JSON
   object is malformed at that level — e.g. `"items": "not a schema"`.)
3. For each `{key, value}` pair in `schema`:
   - If `key` is **not** one of the 8 supported keywords (the table below) → **skip
     entirely** — not validated, not recursed into, regardless of `value`'s type or
     content. This is the literal mechanism implementing REQ-032's "unknown keywords like
     `$ref`/`allOf`/`pattern` are permitted-and-inert, not rejected" rule (AC3) — by
     construction (no allow-list/reject-list logic beyond "is this key in the supported
     set"), the same "silently ignored, not by an explicit ignore-list" shape REQ-029's
     "undeclared extra attributes" rule already uses (REQ-029 design doc §2).
   - If `key` **is** one of the 8 supported keywords, validate `value` per the table below.
     **Any single keyword failing its own rule makes the whole call return `false`
     immediately** (short-circuit — consistent with §6's opening statement that this
     function is boolean-returning and short-circuits by design, unlike the
     violation-collecting `check_*/1` functions elsewhere in this file).
4. If every supported key present passed its rule (step 3), and every unsupported key was
   skipped (never a failure condition on its own) → return `true`.

**The 8 supported keywords and their well-formedness rule:**

| Keyword | Value must be | Recurses? |
|---|---|---|
| `type` | a non-empty `String.t()` | No |
| `minimum` | a `number()` (integer or float) | No |
| `maximum` | a `number()` (integer or float) | No |
| `minLength` | a non-negative `integer()` | No |
| `maxLength` | a non-negative `integer()` | No |
| `enum` | a `list()` (any element types; elements themselves are not validated or recursed into) | No |
| `required` | a `list()` whose every element is a `String.t()` | No |
| `properties` | a `map()` whose every **value** is itself validated via `validate_schema_shape(value, depth + 1)` — every value must return `true` | **Yes**, once per value |
| `items` | a `map()`, itself validated via `validate_schema_shape(value, depth + 1)` | **Yes** |
| `additionalProperties` | a `boolean()` (no recursion — `true`/`false` alone is well-formed), **or** a `map()`, itself validated via `validate_schema_shape(value, depth + 1)` | Only if a `map()` |

(This is 8 keys in the table — `properties`/`items`/`additionalProperties` are the 3
recursive ones; `type`, `minimum`, `maximum`, `minLength`, `maxLength`, `enum`, `required`
are the 5 non-recursive ones. REQ-032's text lists them as "type, minimum/maximum,
minLength/maxLength, enum, required, properties, items, additionalProperties" — the same 8,
grouped by REQ-032's own `/`-pairing in its prose.)

**Important naming collision, flagged explicitly so it is never conflated:** the
`"required"` keyword in this table is the **JSON-Schema-of-schemas meta-keyword** — when a
`json_schema` describes an object type, its own `"required"` key (a list of property-name
strings) states which of *that object's* properties are mandatory. This is a completely
different `"required"` from the interface **entry tuple's** own `required` field (§5.1's
`entry().required`, defaulting to `false`, meaning "is this input/output itself mandatory
at sub-process invocation time"). Both are named `"required"`/`required` because that's
what REQ-032's own text and spc-01's field-semantics table call them — this design does not
rename either to avoid the collision, since doing so would diverge from the requirement's
own vocabulary, but states the distinction explicitly here so ELIXIR-DEV and TEST-DESIGNER
never conflate the two in code comments or test names.

**Worked example for TEST-DESIGNER, tying together AC1/AC3:**

```
%{
  "type" => "object",
  "properties" => %{
    "amount" => %{"type" => "number", "minimum" => 0},
    "note" => %{"type" => "string", "$ref" => "#/definitions/freeText", "pattern" => "^.*$"}
  },
  "required" => ["amount"],
  "additionalProperties" => false
}
```

is well-formed (`validate_schema_shape(schema, 1)` returns `true`): `"type"`,
`"properties"` (recursing into both nested schemas, each well-formed), `"required"`, and
`"additionalProperties"` (a plain `false`, no recursion) are all supported keywords passing
their rule; `"$ref"` and `"pattern"` on the nested `"note"` schema are unsupported keywords,
skipped entirely regardless of their (here, deliberately nonsensical/inert) values — the
concrete AC3 demonstration.

## 7. Open questions — not resolved here

### 7.1 Whether `"inputs"`/`"outputs"` are individually required keys on a well-formed `interface` object

§5.3 step 3a defaults an absent `"inputs"` or `"outputs"` key to `[]` (no violation) rather
than treating either as required. REQ-032's text does not state whether spc-01 requires
both keys to always be present (even as empty arrays) or treats an absent key as
equivalent to an empty array. This design picks the more permissive reading (absent ⇒
empty, not a violation) because REQ-032 explicitly names 6 violation codes and none of them
is a plausible "missing inputs/outputs key" code — if such a code existed in spc-01's real
taxonomy, it would very likely have been named alongside the other 6. Not silently
finalized — if R-Co source becomes reachable, ELIXIR-DEV should confirm against spc-01's
actual field-semantics table before treating this default as ground truth.

### 7.2 Whether unknown keys on an interface **entry** (beyond `name`/`json_schema`/`required`) are tolerated

§5.3.1 does not flag an entry as `_ENTRY_INVALID` for carrying an extra key beyond the 3
named ones — extra keys are silently ignored, the same forward-compatibility posture
REQ-029 established for node `attributes` (REQ-029 AC5) and this design's own §6 step 3
established for unsupported `json_schema` keywords (AC3). This is an **inference by
analogy**, not a literal statement in REQ-032's text about the entry-tuple level
specifically (REQ-032's text states the inert-unknown-keyword rule for `json_schema`
content explicitly, but is silent about the entry tuple's own key set). Flagged rather than
silently assumed identical.

### 7.3 Whether `"items"` supports JSON Schema's array-of-schemas ("tuple validation") form

§6's table treats `"items"` as accepting only a single schema object (`map()`) — a `list()`
value for `"items"` is rejected (fails the `map()` check, step 2 of the recursive call).
Full JSON Schema also permits `"items"` to be an array of per-position schemas (tuple
validation). REQ-032's text does not mention this distinction. This design deliberately
does not support the array form — flagged explicitly as a reconstruction gap (§0), not a
verified-against-source decision; ELIXIR-DEV should diff against real spc-01 text if it
becomes available and flag any divergence to REVIEWER rather than silently changing
behavior.

### 7.4 Whether `"type"`'s value must match an enumerated set of legal JSON Schema type names

§6's table requires `"type"`'s value to be "a non-empty `String.t()`" with no check against
the standard JSON Schema primitive-type name set (`"string"`, `"number"`, `"integer"`,
`"boolean"`, `"object"`, `"array"`, `"null"`). REQ-032's text lists `type` as a supported
keyword but does not state whether its value is validated against this set or accepted as
any non-empty string. This design picks the permissive reading (any non-empty string) —
consistent with this validator's overall "well-formedness of shape," not "semantic
correctness of content" scope (mirrored by `enum`'s elements and `required`'s referenced
property names also not being cross-checked against `properties`). Flagged, not finalized.

### 7.5 Duplicate-name comparison: exact string equality, no trim/case-fold

§5.3.2 uses exact `String.t()` equality for `_DUPLICATE_NAME` detection — `"amount"` and
`"Amount"`, or `"amount"` and `" amount "`, are treated as distinct names, not duplicates.
REQ-032's text says only "duplicate name," without specifying comparison semantics. This
mirrors CHK-05's/CHK-16's own precedent (`&1.id == node.id`, `Edge.id` exact equality, no
normalization) rather than inventing a new normalization rule not asked for. Flagged as a
choice, not a verified spc-01 rule.

### 7.6 R-Co source unreachable — §6/§5.3's algorithms are reconstructions, not verified ports

PROVENANCE (historical, not current decision authority):
Same shape as REQ-029 design doc §9.1's flag: §5's parse algorithm and §6's recursive
well-formedness algorithm are built entirely from REQ-032's own prose in
`docs/requirements.yaml`, since `sub_process_interface.zig` and spc-01's actual design doc
text were not reachable in this environment (§0). Concrete and testable, but not verified
character-for-character against R-Co's real implementation. If R-Co source becomes
reachable before or during implementation, ELIXIR-DEV should diff §5/§6 against it and flag
any divergence to REVIEWER rather than silently implementing this reconstruction as-is if
it turns out to disagree with source.

## 8. Moduledoc-facing statement — SPC-01 out of scope, belongs to S3 (AC5)

**`Letflow.Definitions.SubProcessInterface`'s own moduledoc must state, verbatim in
substance (ELIXIR-DEV may adjust exact phrasing, not the content) the following, satisfying
AC5 directly:**

PROVENANCE (historical, not current decision authority):
> This module ports only the SPC-02 (definition-time) half of R-Co's
> `src/definition/sub_process_interface.zig`, per `src/design/spc-01-sub-process-interface-
> contract.md` — the file's own header documents two halves: SPC-02 (definition-time
> interface parsing/validation, invoked from `graph.zig`'s `checkSubProcess`, hooked into
> PD-05 node-attribute validation) and SPC-01 (runtime activation/completion helpers,
> invoked from `src/engine/instance.zig`). **SPC-01 is explicitly out of this module's
> scope.** It belongs to Stage 3 (`src/engine/` port), since it requires a running
> instance/token model that does not exist yet in Letflow — `src/engine/instance.zig` is
> SPC-01's future integration point once S3 builds it. Nothing in this module activates,
> completes, or otherwise executes a sub-process at runtime; it only validates that a
> SUB_PROCESS node's optional `interface` attribute is well-formed at definition time.

This statement must appear in the module's moduledoc (not only in this design document) —
CODE-DESIGN-VALIDATOR and REVIEWER should both be able to find it there directly. `graph.ex`'s
own moduledoc addition (§4) cross-references this module rather than repeating the
statement, keeping one canonical location for it.

## 9. Invariants

- **Total and defensive — never raises.** `validate_node_interface/2`, `parse_interface/2`,
  `parse_entries/3`, `check_duplicate_names/3`, and `validate_schema_shape/2` all handle
  every `term()` input defensively (wrong type, missing key, `nil`) by producing a
  violation or `false`, never by pattern-match failure or an unhandled exception — same
  "total, defensive" contract REQ-029 design doc §1 established for
  `validate_edge_conditions/1`.
- **No I/O, pure functions only.** Same zero-I/O contract as the rest of `graph.ex`
  (moduledoc "Purity" section) — `Letflow.Definitions.SubProcessInterface` depends on
  Elixir/Erlang stdlib only (`Enum`, `Map`, `String`, `Kernel`); no `Letflow.Repo`, no
  `Ecto.Changeset`, no `Logger.*`, no clock read, no HTTP/file/process-mailbox call
  anywhere. Verifiable the same way REQ-028/029 verify it: `grep -n
  "Repo\.\|Logger\.\|DateTime\.\|System\.os_time\|HTTPoison\|Req\.\|File\."
  lib/letflow/definitions/sub_process_interface.ex` must return zero matches.
- **Never mutates or re-serializes what it validates.** §5.4 — `parsed_interface()` is
  validation-internal only; the original `attributes` map is what gets persisted,
  unchanged, exactly as AC1 states.
- **Never short-circuits at the violation-collection level** (§5.3's point e
  concatenation, §4's CHK-18 concatenation) — every applicable violation across `inputs`
  and `outputs`, and across all 6 codes, is collected before returning, same never-
  short-circuit contract as every other check in `graph.ex`. The one exception,
  `validate_schema_shape/2`'s internal boolean short-circuit (§6), is scoped and justified
  there — it does not violate this invariant at the CHK-18/`parse_interface/2` level, since
  it only ever contributes at most one `_SCHEMA_INVALID` violation per entry regardless of
  how many nested keywords inside that entry's schema are actually malformed (spc-01's own
  taxonomy has one schema-shape code, not one per malformed keyword).
- **Recursion terminates.** `validate_schema_shape/2`'s depth-cap check (`depth > 32 →
  false`, §6 step 1) is evaluated before any further recursion, guaranteeing termination
  even against a schema value with unbounded or maliciously deep `"properties"`/`"items"`/
  `"additionalProperties"` nesting — this is the concrete mechanism that makes AC4's
  "rejected as malformed" true by construction, not just by convention.
- **`:SUB_PROCESS` nodes are otherwise ordinary graph nodes.** §2 confirms no other
  CHK-01..17 check's behavior changes for a SUB_PROCESS node beyond CHK-18 itself — it
  participates in `check_isolated_nodes/1`'s generic incoming/outgoing-edge requirement,
  `check_cycles/1`'s generic (non-gateway) cycle rule, and CHK-05's generic duplicate-id
  rule exactly like any other non-START/END/gateway node type.

## 10. Cross-module dependencies

- `Letflow.Definitions.Graph` → `Letflow.Definitions.SubProcessInterface`: one call site,
  CHK-18 (§4), passing a node's `id`/`attributes` and receiving `[Violation.t()]` back.
- `Letflow.Definitions.SubProcessInterface` → `Letflow.Definitions.Graph.Violation`: reuses
  the existing `%Violation{code:, message:}` struct and its (now 24-atom) `code()` type
  directly — no parallel violation type, no translation step (§1).
- **No dependency in the reverse direction** — `SubProcessInterface` never calls back into
  `Graph`'s public functions (`validate_graph/1`, `validate_node_attributes/1`,
  `validate_edge_conditions/1`), and never constructs or inspects a `Graph.t()`/`Node.t()`/
  `Edge.t()` value. It operates purely on the `node_id :: String.t()` and `attributes ::
  map() | nil` (or, for `parse_interface/2`/`validate_schema_shape/2`, bare
  `interface_value`/`schema` terms) it is handed — no cycle.
- **No new dependency on any other `lib/letflow/` module.** Same "zero cross-module
  dependency beyond this file's own types" posture as REQ-028/029 (REQ-029 design doc §10),
  extended by exactly one new intra-`lib/letflow/definitions/` edge (the one above).
- **No DB/migration changes.** This requirement adds no persisted schema — it purely
  extends the pure in-memory `Graph`/`SubProcessInterface` validators, consistent with
  REQ-028/029's precedent. `process_definitions.graph` (REQ-027, `jsonb` column) is
  unaffected; a SUB_PROCESS node's `interface` attribute is just JSON content inside that
  same existing column, validated by this requirement's code, not a new column.
PROVENANCE (historical, not current decision authority):
- **Forward dependent:** REQ-030's future `Letflow.Definitions.create/1` — REQ-029 design
  doc §1/§9.3 already flagged that `create/1` must call both `validate_node_attributes/1`
  and `validate_edge_conditions/1`. This design adds no new top-level function `create/1`
  must call (CHK-18 rides inside the existing `validate_node_attributes/1` call, §4) — no
  new flag needed for REQ-030 beyond what REQ-029's design doc already raised.
  **Forward dependent, out of this requirement's scope:** SPC-01 (§8) — a future S3
  requirement building `src/engine/instance.zig`'s Letflow equivalent will be the first
  consumer of a SUB_PROCESS node's *parsed* interface at runtime (matching invocation-time
  inputs/outputs against the declared contract); nothing in this design commits that future
  requirement to reusing `parse_interface/2`'s exact shape, though it plausibly could.

## 11. Acceptance-criteria traceability

PROVENANCE (historical, not current decision authority):
| REQ-032 acceptance criterion | Concrete design element |
|---|---|
| "a SUB_PROCESS node with a well-formed interface (valid inputs/outputs, well-formed json_schema on each entry) passes validation and is persisted unchanged as part of the node's attributes" | §5.3's full parse algorithm (steps 1-3f) producing `{parsed, []}` when every entry is shape-valid and schema-valid; §5.4's explicit "no data-transformation side effect" statement (original `attributes` map persisted unchanged, `parsed_interface()` never touches the persistence path) |
| "each of the 6 named violation codes has at least one explicit failing-example test" | §3's full 6-atom `Violation.code` extension + mapping table; §5.3 step 2 (`_NOT_OBJECT`), step 3b (`_INPUTS_NOT_ARRAY`/`_OUTPUTS_NOT_ARRAY`), §5.3.1 point 1 (`_ENTRY_INVALID`) and point 2 (`_SCHEMA_INVALID`), §5.3.2 (`_DUPLICATE_NAME`) — each with an exact trigger condition and message shape `parse_interface/2`/`validate_schema_shape/2` being public (§5.3, §6) so each can be driven directly in a standalone test |
| "an interface entry's json_schema containing an unsupported-but-recognized-as-inert keyword (e.g. $ref or pattern) is accepted, not rejected, per spc-01's 'permitted and inert' rule" | §6 step 3's "skip entirely" rule for any key not in the 8-keyword supported set + the worked example in §6 using `$ref`/`pattern` on a nested schema, explicitly demonstrating acceptance |
| "a json_schema nested beyond the 32-level recursion cap is rejected as malformed" | §6's precise depth-numbering convention (entry's own schema = depth 1, `depth > 32` → `false` before inspecting `schema`) + the explicit "32-deep valid / 33-deep invalid" fixture-pair framing |
| "the moduledoc explicitly states SPC-01 (runtime activation/completion helpers) is out of this requirement's scope and belongs to S3, naming src/engine/instance.zig as SPC-01's future integration point" | §8's full verbatim-in-substance moduledoc paragraph, naming SPC-01, S3, and `src/engine/instance.zig` explicitly, plus `graph.ex`'s own cross-reference (§4) |
