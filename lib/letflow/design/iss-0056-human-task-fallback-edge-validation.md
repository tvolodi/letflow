# Design: ISS-0056 — `:HUMAN_TASK` edge-condition permission + fallback-edge validation

**Issue:** `docs/issues/ISS-0056.yaml`, scoped per ISSUE-FIXER's diagnosis
(`handoffs/WF03-ISS0056-20260818/step-01-issue-fixer.json`'s `result`, read in full for
this design). **Owner (implementer):** ELIXIR-DEV. **Run:** `WF03-ISS0056-20260818`,
WF-03 Step 2. This document is design-only: `@spec`s, the `Violation.code` type
extension, and algorithm steps in prose/pseudocode-shape (`IF`/`CASE`-style, mirroring
this project's `iss-0048-sandbox-pool-owner-crash-reclaim.md` §5 convention). **No
implementation code** — no `.ex`/`.exs` function bodies.

---

## 0. Scope boundary — hard, restated from the handoff

**In scope, entirely:** `lib/letflow/definitions/graph.ex` and
`test/letflow/definitions/graph_test.exs` only.

**Explicitly out of scope, not silently dropped:**

| Not touched here | Why |
|---|---|
| `lib/letflow/engine/transition.ex` (any part, including `really_conditioned?/1`) | Owned by REQ-048's in-flight sibling worktree (`~/letflow-wt2`, `WF02-REQ048-20260818`), not merged to `main`; this run's `really_conditioned?/1`-mirroring obligation (§4.1) is a **read-only, one-way** copy of that function's predicate shape into `graph.ex`, not an edit to `transition.ex` itself |
| `CHK-16` (`check_single_default_edge/1`) extension to `:HUMAN_TASK` sources | ISSUE-FIXER flagged this as optional/non-blocking (adjacent invariant family, not required to close ISS-0056's stated gap). §7 below makes the explicit decision **not** to extend it in this run, to avoid scope creep beyond what ISS-0056 and the sibling REQ-048 dependency actually require — flagged as an open question for a future, separately-scoped requirement, not silently resolved either way |
| `CHK-13` (`check_gateway_condition_presence/1`) extension to `:HUMAN_TASK` sources | ISSUE-FIXER explicitly rejected this: a `:HUMAN_TASK` non-default edge with a blank/nil condition is legitimate (it's the implicit fallback case), unlike an `EXCLUSIVE_GATEWAY`'s non-default edge, which must always carry a condition. Requiring a condition on every `:HUMAN_TASK` edge would contradict REQ-048's own design |

**Confirmation this requires zero change outside `lib/letflow/definitions/graph.ex` (and
its test file):** every change below is a private-function body change, one private
helper rename, one new private helper, one new private check function, one new entry in
`validate_edge_conditions/1`'s dispatch list, and one `Violation.code` union extension —
all inside this one file. Nothing in this design calls, references, or requires a
signature from any module outside `Letflow.Definitions.Graph`. `really_conditioned?/1`'s
predicate shape is **copied by value** (as prose, in this document, and later as
literal-but-independent code by ELIXIR-DEV) into `graph.ex`, not imported, aliased, or
called cross-module — `Letflow.Engine.Transition` is never referenced by `graph.ex`
before or after this change (this module's zero-cross-module-dependency invariant,
`req029-node-attribute-edge-condition-validators.md` §10, is unchanged).

---

## 1. Root cause and fix shape (restated from ISSUE-FIXER's diagnosis)

Today, `check_non_gateway_condition_absence/1` (CHK-14, `graph.ex:920`) forbids a
non-nil `condition` on **any** edge whose source does not resolve to an
`:EXCLUSIVE_GATEWAY` node with `is_default != true` — this includes every `:HUMAN_TASK`
-sourced edge, unconditionally. This blocks REQ-048's entire conditioned-task-completion
feature outright, not just the narrow "multiple conditions, no fallback" case ISS-0056's
issue text names. Two changes close this, in order of dependency:

1. **Loosen CHK-14** so a `:HUMAN_TASK`-sourced edge is also a permitted
   condition-carrying source (§3). This is the load-bearing change — without it, no
   graph with a conditioned `:HUMAN_TASK` edge can ever validate, so the second check
   below would never have anything to protect against in practice.
2. **Add CHK-19**, a new check requiring that a `:HUMAN_TASK` node with at least one
   "really conditioned" outgoing edge also has at least one fallback-candidate outgoing
   edge (§4) — the actual ask in ISS-0056's filed description, and the part that
   prevents the runtime `{:error, {:no_matching_edge, ...}}` the issue is about.

`CHK-15` (`check_default_condition_conflict/1`) and `CHK-17` (`check_cel_syntax/1`) are
already source-independent (confirmed by reading `graph.ex:940-950` and `:984-996`) and
need **no** change.

---

## 2. Violation-code / numbering conventions confirmed before use

Grepped `lib/letflow/definitions/graph.ex` (`@type code`, `graph.ex:121-145`) and
`docs/requirements.yaml`'s REQ-029 entry directly:

- CHK numbering in-file: CHK-01..08 (REQ-028, `validate_graph/1`), CHK-09..12 + CHK-18
  (REQ-029/REQ-032, `validate_node_attributes/1`), CHK-13..17 (REQ-029,
  `validate_edge_conditions/1`). **CHK-18 is already taken** (`check_sub_process_interface/1`,
  REQ-032, confirmed at `graph.ex:753-754`). No CHK number above 18 exists in the file.
  **This design uses CHK-19** for the new check, confirming ISSUE-FIXER's suggestion by
  direct grep rather than trusting the diagnosis handoff's claim alone.
- Violation-code naming convention (REQ-029 design doc §7, unchanged): lowercase
  `snake_case`, pattern-matchable, no prefix/namespace. `:human_task_no_fallback_edge`
  (ISSUE-FIXER's suggestion) follows this convention and is adopted as-is — no existing
  code collides with it (confirmed against the 24-atom union at `graph.ex:121-145`).

---

## 3. Change 1 — CHK-14's guard, generalized to permit `:HUMAN_TASK` sources

### 3.1 New private helper: `human_task_source?/3`

```
@spec human_task_source?(
        [Node.t()],
        %{String.t() => non_neg_integer()},
        Edge.t()
      ) :: boolean()
```

Same shape and same defensive convention as the existing `exclusive_gateway_source?/3`
(`graph.ex:1008-1018`): resolves `edge.source` via the passed-in `node_index` (built
once per check function by `build_node_index/1`, reused exactly as `exclusive_gateway_source?/3`
is reused today — no new node-index-building logic). Returns `true` iff the resolved
node's `node_type == :HUMAN_TASK`; returns `false` if `edge.source` doesn't resolve to
any node at all (a dangling source, §5.2 of the REQ-029 design doc's precedent — an
unresolvable source is never confirmed to be any particular type). This is a **new**,
separate helper, not a generalization of `exclusive_gateway_source?/3` itself — keeping
the two helpers separate (rather than a single `node_type_at_source/3`-style helper
returning an atom) means CHK-13 and CHK-16's existing call sites (`graph.ex:904`,
`:961`) are untouched by this change, satisfying §0's "CHK-13/16 unchanged" scope
decision by construction — no risk of an accidental behavior change to either from a
shared-helper refactor.

### 3.2 `check_non_gateway_condition_absence/1` (CHK-14) — renamed and re-guarded

**Renamed to `check_unpermitted_edge_condition/1`.** The existing name
("non-gateway condition absence") becomes actively misleading once a non-gateway
(`:HUMAN_TASK`) source is also permitted to carry a condition — a private function, so
renaming has zero external-caller impact; only `validate_edge_conditions/1`'s own
dispatch list (`graph.ex:340-349`, the `&check_non_gateway_condition_absence/1` entry)
needs its reference updated to match. The `# CHK-14: ...` comment immediately above the
function (`graph.ex:916-918`) must be rewritten to state the new rule (below), not left
describing the old one.

```
@spec check_unpermitted_edge_condition(t()) :: [Violation.t()]
```

**New trigger, precisely:**

```
edge.condition != nil AND NOT (
  (exclusive_gateway_source?(nodes, node_index, edge) AND edge.is_default != true)
  OR human_task_source?(nodes, node_index, edge)
)
```

i.e. an edge is now **permitted** to carry a non-nil `condition` iff either:
(a) its source is an `:EXCLUSIVE_GATEWAY` and this edge is not that gateway's default
edge (**unchanged** from today — the existing CHK-13-paired case), **or**
(b) its source is a `:HUMAN_TASK` (regardless of `is_default`, §3.3 explains why).
Every other edge — sourced from `:START`/`:END`/`:PARALLEL_GATEWAY`/`:SERVICE_TASK`/
`:TIMER`/`:SUB_PROCESS`, from an `:EXCLUSIVE_GATEWAY`'s own default edge, from an
unresolvable/dangling source, or from any node type not in the 7 known atoms — remains
forbidden from carrying a condition at all, exactly as CHK-14 already enforces today for
those sources. **Violation code unchanged**: still `:unexpected_edge_condition` — no new
code needed for this half of the fix, only a broadened guard and (per REQ-028/029's own
never-short-circuit convention) an updated message.

**Message text, updated:** `"Edge '#{edge.id}' is not a non-default EXCLUSIVE_GATEWAY
outgoing edge or a HUMAN_TASK outgoing edge and must not have a condition"` — the exact
wording is ELIXIR-DEV's call as long as it accurately reflects the new two-source-type
permitted set; this is prose guidance, not a literal string this design mandates
byte-for-byte (unlike the violation `code` atom, which TEST-DESIGNER's tests will
pattern-match on and so must be exact).

### 3.3 Why `:HUMAN_TASK` permission is unconditional on `is_default`, unlike the gateway case

`:EXCLUSIVE_GATEWAY`'s permitted case is scoped to `is_default != true` because CHK-13
separately *requires* a condition on every non-default gateway edge, and the gateway's
own default edge must have a **null** condition (CHK-14's original, still-correct
behavior for that one edge) — a gateway's default-ness and condition-bearing-ness are
mutually exclusive by construction. A `:HUMAN_TASK` node has no equivalent
"exactly one designated default edge, condition required on all others" contract (CHK-13
is deliberately **not** extended to `:HUMAN_TASK`, §0) — instead, per REQ-048's
`really_conditioned?/1` semantics (ISSUE-FIXER's diagnosis, quoted in §4.1), a
`:HUMAN_TASK` edge's `is_default`/`condition` combination is governed only by the
already-source-independent CHK-15 (`is_default == true AND condition != nil` is always a
violation, regardless of source type — unchanged, still fires for a `:HUMAN_TASK` edge
that sets both). Scoping `human_task_source?/3`'s permission to `is_default != true`
would incorrectly forbid a `:HUMAN_TASK` edge from ever being marked `is_default: true`
while also (invalidly) carrying a condition — but that combination is already correctly
rejected by CHK-15 alone; CHK-14 does not need its own redundant carve-out for it. Making
CHK-14's `:HUMAN_TASK` permission unconditional on `is_default` is therefore both
simpler and correct: it relies on CHK-15 to catch the one combination that's actually
invalid, exactly mirroring how CHK-14's original gateway-scoped guard already relies on
CHK-15 (not itself) to catch the analogous gateway default+condition conflict (REQ-029
design doc §5.1's documented CHK-14/CHK-15 co-fire precedent, `graph.ex:937-939`'s own
comment).

---

## 4. Change 2 — CHK-19, the new fallback-edge requirement

### 4.1 The "really conditioned" predicate — mirrored literally from `transition.ex`, not reused via `blank_condition?/1`

ISSUE-FIXER's diagnosis quotes `dispatch_task_completion/4`'s (sibling worktree,
read-only) `really_conditioned?/1` predicate exactly: `is_default != true AND
is_binary(condition) AND condition != ""`. Per the diagnosis's own instruction ("mirror
... literally, to keep graph.ex and transition.ex from drifting on this definition
again"), this design defines a **new**, standalone predicate in `graph.ex` with this
exact shape — **not** a reuse of the existing `blank_condition?/1` helper
(`graph.ex:998-1001`), which additionally treats a whitespace-only string (`"   "`) as
blank via `String.trim/1`. `really_conditioned?/1`'s literal predicate does **not**
trim — `condition != ""` only.

```
@spec human_task_edge_really_conditioned?(Edge.t()) :: boolean()
```

Trigger: `edge.is_default != true AND is_binary(edge.condition) AND edge.condition != ""`.

```
@spec human_task_edge_fallback_candidate?(Edge.t()) :: boolean()
```

Trigger (the exact logical complement, stated separately rather than as `not
human_task_edge_really_conditioned?/1` for readability at the call site, §4.2):
`edge.is_default == true OR is_nil(edge.condition) OR edge.condition == ""`.

**Open question, flagged explicitly per this project's "don't silently resolve" rule —
not resolved here:** this introduces a real, narrow semantic gap between
`human_task_edge_really_conditioned?/1` (non-trimming, mirrors `transition.ex` literally)
and the rest of this module's `blank_condition?/1` (trimming) used by CHK-13/14/17. A
`:HUMAN_TASK` edge whose `condition` is exactly `"   "` (whitespace-only) is
**"really conditioned"** under CHK-19's new predicate (so it counts toward requiring a
fallback edge) but is treated as **blank** by CHK-17's CEL-syntax check
(`blank_condition?/1` short-circuits it out of CHK-17 entirely, `graph.ex:986-987`) and
would be **permitted** (not forbidden) by §3.2's updated CHK-14 either way, since it's
`:HUMAN_TASK`-sourced. This inconsistency is inherited directly from the instruction to
mirror `really_conditioned?/1` literally rather than reconcile it with `graph.ex`'s own
trim-aware convention, and is **not** resolved by this design — whether `transition.ex`'s
`really_conditioned?/1` should itself become trim-aware (making the two modules
consistent) is out of this run's scope (`lib/letflow/engine/` is untouched, §0) and is
left for whoever next touches either module's condition-blankness semantics to reconcile,
flagged here rather than silently papered over.

### 4.2 `check_human_task_fallback_edge/1` (CHK-19)

```
@spec check_human_task_fallback_edge(t()) :: [Violation.t()]
```

Algorithm, per `:HUMAN_TASK` node (never short-circuits across nodes — same
unconditional-concatenation composition as every other check in this module,
REQ-028 design doc §7.1's convention, restated and still binding):

```
FOR EACH node IN graph.nodes WHERE node.node_type == :HUMAN_TASK:
  outgoing = edges from graph.edges WHERE edge.source == node.id

  IF Enum.any?(outgoing, &human_task_edge_really_conditioned?/1)
     AND NOT Enum.any?(outgoing, &human_task_edge_fallback_candidate?/1):
    EMIT %Violation{
      code: :human_task_no_fallback_edge,
      message: "HUMAN_TASK node '#{node.id}' has at least one really-conditioned " <>
               "outgoing edge but no fallback edge (is_default: true, or a " <>
               "blank/nil condition) to resolve to if every condition evaluates false"
    }
  END
END
```

- Iteration is over `graph.nodes` filtered to `:HUMAN_TASK` (matching CHK-09's own
  `check_human_task_role/1` node-filtering idiom, `graph.ex:678-692`) — **not** grouped
  by resolved source index the way CHK-16 groups gateway edges (§5.3 of the REQ-029
  design doc), because this check's unit of concern is one violation **per node**, not
  per edge — a node either has a fallback among its outgoing edges or it doesn't; there
  is no "Nth occurrence" counting analogous to CHK-05/CHK-16's convention here.
- `outgoing` is found by a direct `edge.source == node.id` string-equality filter over
  `graph.edges` — no `build_node_index/1`/`node_index` lookup is needed for this
  direction (unlike CHK-13/14/16, which resolve an edge's source *node* from its id);
  here the *node* id is already known (the loop variable) and edges are filtered
  directly by matching against it. A dangling edge whose `target` doesn't resolve to any
  node is irrelevant to this check (it still counts as one of `node`'s outgoing edges by
  `source`, exactly as it correctly should — CHK-19 only cares about the outgoing edge's
  own `condition`/`is_default` fields, never its `target`).
- **One violation per offending node, not per edge** — even if a `:HUMAN_TASK` node has
  three really-conditioned edges and zero fallback edges, this emits exactly one
  `:human_task_no_fallback_edge` violation naming the node, not three. This differs from
  CHK-13/14/17's per-edge violation granularity by design: the defect being reported
  ("this node, as a whole, has no fallback") is a node-level property, not a
  per-edge one — analogous to how CHK-01/CHK-02 (`missing_start_node`/`missing_end_node`,
  REQ-028) report once for the whole graph rather than once per missing thing, when the
  defect is inherently graph/node-scoped rather than edge-scoped.

### 4.3 Dispatch — added to `validate_edge_conditions/1`

`validate_edge_conditions/1`'s dispatch list (`graph.ex:342-349`) gains one entry:

```
[
  &check_gateway_condition_presence/1,
  &check_unpermitted_edge_condition/1,      # renamed, was check_non_gateway_condition_absence/1
  &check_default_condition_conflict/1,
  &check_single_default_edge/1,
  &check_cel_syntax/1,
  &check_human_task_fallback_edge/1         # NEW, CHK-19
]
```

**Not added to `validate_node_attributes/1`'s dispatch list** (`graph.ex:315-324`,
where CHK-18 lives) — CHK-19 is an edge-condition check (reads `Edge.condition`/
`Edge.is_default`), not a node-attribute check (`Node.attributes`), so it belongs in
`validate_edge_conditions/1` alongside CHK-13..17, matching the REQ-029 design doc §1's
own "edge conditions vs. node attributes are two independent rule domains" split — CHK-19
extends the edge-condition domain, not the node-attribute one, even though its trigger is
keyed by node type (`:HUMAN_TASK`) the same way CHK-13/14/16 already are.

`validate_edge_conditions/1`'s `@doc` (`graph.ex:329-338`, "Runs the 5
edge-condition/CEL checks (CHK-13..CHK-17...)") must be updated to say **6** checks,
**CHK-13..17 and CHK-19** (not "CHK-13..19" — CHK-18 is not in this function, §4.3
above), and the moduledoc's own "Node-attribute and edge-condition checks (CHK-09..
CHK-17, REQ-029)" heading (`graph.ex:39`) similarly needs a `CHK-19` mention added
(e.g. "CHK-09..CHK-17, CHK-19" or a follow-up sentence naming CHK-19 as ISS-0056's
addition) — a moduledoc-accuracy requirement, not merely a nice-to-have, since this
project's own convention (demonstrated throughout `graph.ex`'s existing moduledoc) is
that the "N named checks" count is load-bearing documentation other agents read instead
of the code.

---

## 5. `Violation.code` type extension

`graph.ex:121-145`'s `@type code` union gains exactly one new atom, appended at the end
(no reordering of existing atoms — REQ-029 design doc §7's own convention of pure
addition, never reordering, to avoid an unrelated diff on every existing line):

```
:human_task_no_fallback_edge
```

---

## 6. Edge cases considered (per the handoff's explicit ask)

| Scenario | Outcome | Why |
|---|---|---|
| `:HUMAN_TASK` node, exactly one outgoing edge, that edge has a real condition and `is_default != true` | **CHK-19 fires** — one violation for this node | The single edge is really-conditioned (§4.1) and there is no other edge to be a fallback candidate. §0/§4.2 note this has **no precedent in CHK-13/16** — neither existing check has an analogous "must have a fallback" concept for `:EXCLUSIVE_GATEWAY` at all (CHK-13 only requires each individual non-default gateway edge to carry *a* condition; nothing in CHK-13/15/16 requires a gateway to have a default/fallback edge to exist). CHK-19 is a genuinely new invariant category, intentionally scoped to `:HUMAN_TASK` only per ISS-0056's explicit ask (§0) |
| `:HUMAN_TASK` node, exactly one outgoing edge, blank/nil condition | No CHK-19 violation | Not really-conditioned (§4.1) — the common, legitimate single-unconditioned-edge case `really_conditioned?/1` already handles correctly at runtime per ISSUE-FIXER's diagnosis |
| `:HUMAN_TASK` node, zero outgoing edges | No CHK-19 violation | `Enum.any?([], ...)` is `false` for the really-conditioned test, so the check never fires; a zero-outgoing-edge node is a different structural concern (isolated/dead-end node), already CHK-04's (`check_isolated_nodes/1`, REQ-028) territory, not this check's |
| `:HUMAN_TASK` node, one really-conditioned edge + one edge with `is_default: true` **and** a non-null condition (itself invalid) | No CHK-19 violation for this node, but CHK-15 fires (`:default_with_condition`) on the second edge independently | `human_task_edge_fallback_candidate?/1`'s guard is `is_default == true OR ...` — it does not additionally require that edge's `condition` to be blank, so this edge still counts as "a fallback candidate present" for CHK-19's purposes even though it is itself separately malformed. This is a deliberate, disclosed overlap-tolerance choice, not an oversight: CHK-19's job is "does *some* edge look like a fallback," not "is every other edge on this node otherwise valid" — that's CHK-15/17's job, and they still fire independently on the malformed edge, exactly matching this module's established "checks deliberately overlap, co-fire, don't suppress each other" convention (REQ-029 design doc §5.1) |
| `:HUMAN_TASK` node, two really-conditioned edges, one `is_default: true` blank-condition fallback edge | No CHK-19 violation | Exactly the legal, intended shape — this is REQ-048's own target scenario (multiple conditions + one explicit fallback) |
| `:HUMAN_TASK` node, two really-conditioned edges, no `is_default: true` edge, but one edge's condition is `nil` (blank, non-default) | No CHK-19 violation | `human_task_edge_fallback_candidate?/1` treats `is_nil(condition)` as a fallback candidate regardless of `is_default` — an implicit (not explicitly `is_default: true`) blank-condition edge is still a legitimate fallback, matching `really_conditioned?/1`'s own implicit-fallback semantics (ISSUE-FIXER's diagnosis: "the single-edge, no-condition case ... is now handled correctly by `really_conditioned?/1`") |
| A dangling edge (`source` doesn't resolve to any node) whose `source` string happens to equal a real `:HUMAN_TASK` node's `id` | Cannot occur — if `edge.source == node.id` for a real node in `graph.nodes`, the edge is by definition not dangling *from that node's perspective* (dangling refers to an unresolvable `target`, or a `source` that matches no node at all — CHK-03's concern, REQ-028). CHK-19's `edge.source == node.id` filter only ever selects edges whose source *did* resolve, because it is matching against a node that is definitely in `graph.nodes` | Not a real edge case for this check — included in this table only to confirm it was considered, per the task's instruction not to leave anything silently assumed |

---

## 7. Explicitly deferred: CHK-16 (`check_single_default_edge/1`) is NOT extended to `:HUMAN_TASK`

Restated as its own section per the task's instruction to make this judgment call
explicit rather than silent. Today, CHK-16 only groups edges whose source resolves to
`:EXCLUSIVE_GATEWAY` (`Enum.filter(&exclusive_gateway_source?(nodes, node_index, &1))`,
`graph.ex:961`); a `:HUMAN_TASK` node with two edges both marked `is_default: true`
passes CHK-16 silently today, and **will continue to** after this fix. **Decision: leave
unextended in this run.** Reasons:

1. ISSUE-FIXER's own diagnosis frames this as "optional, non-blocking... could be scoped
   separately to avoid creep" — not part of what closes ISS-0056's stated gap (a node
   with two default-but-otherwise-conflicting edges is a different defect than "no
   fallback exists at all," and neither the filed issue nor REQ-048's own dependency on
   this fix requires it).
2. Extending it would require the same `exclusive_gateway_source?/3` →
   dual-source-type generalization question §3.1 already resolved for CHK-14, but for a
   check with a different violation shape (per-gateway-group counting, §5.3 of the
   REQ-029 design doc) — a second, non-trivial design decision (does a `:HUMAN_TASK`
   with two defaults get the same "N-1 violations" counting as a gateway, or does
   `human_task_edge_fallback_candidate?/1`'s already-broad "any fallback present"
   framing in CHK-19 make a strict "at most one default" rule too strong for
   `:HUMAN_TASK` — e.g. is two blank-condition non-default edges on one `:HUMAN_TASK`
   node, neither marked default, itself fine? CHK-19 says yes; a naive CHK-16 extension
   might not) that this design does not have a clear mandate to make on ISSUE-FIXER's or
   ISS-0056's authority alone.
3. `docs/agents/instructions/core-directives.md`'s "Unblock-Everything" scope-boundary
   rule: a defect merely *noticed*, not blocking this run's own acceptance criteria, is
   filed and forwarded, not fixed here — this is exactly that case, and mirrors the
   already-established `ISS-0042` precedent (referenced in the Step-1 diagnosis) of
   "diagnosed-and-deferred, no code change" for an adjacent-but-not-required
   type-safety gap.

**Left open, not silently dropped:** ELIXIR-DEV or a future issue-filer should file this
as its own `docs/issues/ISS-NNNN.yaml` entry ("CHK-16 does not detect multiple
`is_default: true` edges on a single `:HUMAN_TASK` node") if it is judged worth a
dedicated follow-up — this design does not do so itself, since filing a new issue is
outside CODE-DESIGNER's own role (design artefacts only), but names it here so it is not
lost.

---

## 8. What ELIXIR-DEV must NOT change

- `check_gateway_condition_presence/1` (CHK-13) — unchanged, still `:EXCLUSIVE_GATEWAY`
  -only (§0).
- `check_single_default_edge/1` (CHK-16) — unchanged (§7).
- `check_default_condition_conflict/1` (CHK-15), `check_cel_syntax/1` (CHK-17) —
  unchanged, already source-independent (§1).
- `exclusive_gateway_source?/3` — unchanged in both signature and body; `human_task_source?/3`
  (§3.1) is a new, separate helper, not a modification of this one.
- `blank_condition?/1` — unchanged; CHK-19's own predicates (§4.1) are new and separate,
  deliberately not reusing this helper (the trim-vs-no-trim distinction is load-bearing,
  §4.1's flagged open question).
- Everything under `lib/letflow/engine/` (§0).
- `validate_node_attributes/1`'s dispatch list, CHK-09..12/CHK-18, `Node.attributes`
  handling — untouched; this fix is entirely within the edge-condition domain.

---

## 9. Cross-module dependencies

Unchanged from REQ-029 design doc §10: zero dependencies on any other `lib/letflow/`
module, before or after this change. `check_unpermitted_edge_condition/1`,
`human_task_source?/3`, and `check_human_task_fallback_edge/1` depend only on this same
file's existing `Node`/`Edge`/`Violation`/`t()` types and `build_node_index/1` — no new
intra-`lib/letflow/` dependency introduced. **Forward dependent (not this run's
concern, stated for context only):** REQ-048's sibling worktree (`lib/letflow/engine/transition.ex`,
`really_conditioned?/1`) benefits from this fix once merged — a graph using its
conditioned-task-completion feature can now pass `validate_edge_conditions/1` — but that
worktree's own code is not modified by, and does not need to be reconciled with, this
change before or after merge (§0).

---

## 10. What TEST-DESIGNER will need (named for the next step, not built here)

Not this design's own deliverable — named so TEST-DESIGNER has a concrete starting
point, per this project's acceptance-criteria-traceability convention. Existing
`test/letflow/definitions/graph_test.exs` CHK-13/14/16 `describe` blocks
(`graph_test.exs:711-784`) use `graph/2`, `node/2`, `cond_edge/5` fixture builders
already in the file (`graph_test.exs:22-35`) — no new fixture builders should be needed,
only new fixture graphs built from the existing helpers:

1. A `:HUMAN_TASK`-sourced edge with a real, syntactically-valid condition, not marked
   default → `validate_edge_conditions/1` returns `valid: true` for that edge specifically
   (i.e. no `:unexpected_edge_condition` for it) — the regression test proving §3's fix
   actually unblocks the case ISSUE-FIXER reproduced.
2. `:HUMAN_TASK` node, two outgoing edges, both real non-empty conditions, neither
   `is_default: true` — the literal ISS-0056 reproduction scenario — asserts
   `:human_task_no_fallback_edge` fires (§4.2), naming the node id in the message.
3. Same shape as (2) but with a third edge added, `is_default: true`, `condition: nil`
   → asserts no `:human_task_no_fallback_edge` violation (the legal, fixed shape).
4. Same shape as (2) but the "fallback" edge has `condition: nil` and no explicit
   `is_default` field set at all (implicit fallback, not `is_default: true`) → asserts
   no `:human_task_no_fallback_edge` violation (§6's fifth row).
5. `:HUMAN_TASK` node, single outgoing edge, blank condition → no CHK-19 violation (§6's
   second row, the common case).
6. `:HUMAN_TASK` node, single outgoing edge, real condition, not default → CHK-19 fires
   (§6's first row, the "no precedent, new invariant" edge case, worth its own explicit
   test given how easy this boundary is to get backwards).
7. A non-`:HUMAN_TASK`, non-`:EXCLUSIVE_GATEWAY` source (e.g. `:SERVICE_TASK`) with a
   real condition still triggers `:unexpected_edge_condition` — a regression test
   confirming §3.2's broadened guard did not accidentally over-permit a third source
   type.
8. `valid_cel_syntax?/1`, CHK-15, CHK-17 existing `:EXCLUSIVE_GATEWAY` tests
   (`graph_test.exs:711-804`) — re-run as-is (no fixture changes needed) to confirm zero
   regression from the CHK-14 rename/re-guard.

---

## 11. Acceptance-criteria traceability

| Task acceptance criterion (from this run's handoff) | Concrete design element |
|---|---|
| "Loosen CHK-14 to also permit real conditions on :HUMAN_TASK-sourced edges" | §3.1 (`human_task_source?/3`), §3.2 (new guard, renamed function), §3.3 (why unconditional on `is_default`) |
| "Add a new CHK check... requires at least one fallback candidate if any outgoing edge is really conditioned" | §4 in full (CHK-19, `:human_task_no_fallback_edge`) |
| "Verify next unused CHK number yourself" | §2 (confirmed CHK-19 by direct grep of `graph.ex`'s existing CHK-01..18) |
| "Exact violation code/message shape for the new CHK check" | §4.2 (code + message template) |
| "Exactly which existing function(s) change and how their guard condition changes" | §3.2 (full before/after guard), §4.3 (dispatch list diff) |
| "Confirmation this requires zero change to any file outside lib/letflow/definitions/graph.ex (and its test file)" | §0's confirmation paragraph, §9 |
| "Edge cases... single outgoing conditioned non-default edge... precedent in CHK-13/16" | §6 (full table), §4.2's third bullet |
| "Design must not require any change to lib/letflow/engine/transition.ex" | §0, §1, §4.1 (literal-mirror-not-import), §9 |
