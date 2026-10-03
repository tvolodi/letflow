# ISS-0975 fix design — a hop-chain-local join token must be persisted before `Letflow.Engine.SubProcess`'s own reconciliation/dispatch-arming path sees it

**Status:** design, no implementation code. Written by CODE-DESIGNER from ISSUE-FIXER's
findings relayed in this run's own task instruction. Source issue: `docs/issues/ISS-0975.yaml`.
Branch: `fix/ISS-0975-subprocess-join-reentry-id-map`.

## 0. Recap of the confirmed diagnosis (not re-derived, restated as this design's starting point)

`Letflow.Engine.append_pending_event_arms_multi/7` (`lib/letflow/engine.ex:3224-3269`) is a
5th, textually-identical instance of the identity-id_map bug ISS-0974 fixed at 4 sibling
`Multi.merge/2` sites. Unlike those 4 sites, it takes a bare `multi` with no `changes` map
of its own to read a real id_map back out of — it is `Letflow.Engine.SubProcess`'s own public
entry point (ISS-0929), called from `build_completion_write_steps/13`
(`lib/letflow/engine/sub_process.ex:968-1033`) to arm timers/service-task dispatches for a
pending event reached right after a SUB_PROCESS's child completes and the parent advances.

As filed, the described crash is unreachable today: `build_completion_write_steps/13`'s own
earlier `Multi.run(reconciliation_key, ...)` step calls `reconcile_parent_tokens/5`
(`sub_process.ex:1235-1256`) — a local, admittedly-duplicated copy of
`Letflow.Engine`'s own `do_reconcile_token_records/5` guard — which rejects **any** final
token not already present in `token_records`' own ids with
`{:error, {:new_token_during_resume_not_supported, token_id}}`, firing before
`append_pending_event_arms_multi/7`'s own steps ever run in the same transaction. The
ISS-0929 design doc (`lib/letflow/design/q929-vortex-8d-corrective-action-subprocess.md`
§3.1) explicitly states the identity id_map there is "correct because
`reconcile_parent_tokens/5` already rejects any token not present in the original records" —
true at the time ISS-0929 was written (before ISS-0408's own fix pattern existed in this
codebase as a precedent to port here), **now stale**: this design closes that gap, which in
turn makes the identity-id_map bug this design doc is actually about become live and in need
of fixing in the same change.

This design is in two parts, A then B, **in that order** (B depends on A's Multi step
existing and running first in the same transaction):

- **Part A** — port ISS-0408's "insert a real `TokenRecord` for a hop-chain-local-new token,
  before any guard that rejects unknown tokens runs" treatment into
  `Letflow.Engine.SubProcess`'s own completion path, and widen
  `reconcile_parent_tokens/5`'s own notion of "already known" accordingly.
- **Part B** — convert `append_pending_event_arms_multi/7`'s two identity id_maps into real
  ones, read back from the Multi's accumulated `changes`, now that Part A guarantees that
  real mapping exists in `changes` by the time this function's own steps run.

## 1. Part A — reuse `Letflow.Engine.insert_hop_chain_new_token_records/5` directly, do not duplicate it

### 1.1 Reuse vs. a `sub_process.ex`-local analog — decision and why

**Decision: reuse `Letflow.Engine.insert_hop_chain_new_token_records/5` and
`Letflow.Engine.rewrite_token_ids/2` directly from `Letflow.Engine.SubProcess`, by changing
both from `defp` to `def`/`@doc false` in `lib/letflow/engine.ex`. No new,
`sub_process.ex`-local analog function is written.**

Investigated both options:

- **A sub_process.ex-local analog** (mirroring how `reconcile_parent_tokens/5` is already a
  deliberate, documented local duplicate of `do_reconcile_token_records/5` — its own comment
  at `sub_process.ex:1230-1234` states this was chosen because `Letflow.Engine`'s version
  "hardcodes a single, non-unique `:token_reconciliation` Multi step name that would collide
  across cascade levels," i.e. a real, narrow reason, not a style preference). This
  reasoning does **not** transfer to `insert_hop_chain_new_token_records/5`: that function
  takes its own Multi step's key as the **caller's** responsibility (the caller wraps it in
  its own `Multi.run(key, fn repo, _changes -> insert_hop_chain_new_token_records(...) end)`
  — the function itself never names a Multi step, it is a plain `(repo, instance_id,
  original_active_tokens, final_tokens, prefix) -> {:ok, {id_map, records}} | {:error,
  term()}` call). There is no hardcoded, collision-prone key inside it to duplicate away
  from — the collision-avoidance that justified duplicating `reconcile_parent_tokens/5` is
  moot here, so duplicating this function would be copying 35 lines of logic (the filter +
  `Enum.reduce_while` insert loop, `lib/letflow/engine.ex:4698-4740`) for zero benefit, and
  would recreate exactly the "same bug class in a sibling copy" risk ISS-0974/ISS-0975 are
  themselves about (ISS-0975 exists precisely because a function's own logic was correct in
  one place and un-ported to a textually-similar sibling).
- **Direct cross-module reuse.** `insert_hop_chain_new_token_records/5`'s signature is
  already expressed entirely in terms its caller already holds in `sub_process.ex`: a
  `repo`, an `instance_id` (here, `parent_token.instance_id` / `parent_instance_id`), an
  `original_active_tokens :: [TokenRecord.t()]` (here, `token_records` — the parent's own
  pre-hop-chain `TokenRecord` rows, already loaded by `load_parent_context/2` and threaded
  into `build_completion_write_steps/13` as its own `token_records` parameter), a
  `final_tokens :: [Token.t()]` (here, `final_instance_state.tokens`), and a `prefix`. No
  parameter needs a `sub_process.ex`-specific shape or meaning. This is exactly the same
  situation `append_pending_event_arms_multi/7` itself was already in (ISS-0929's own design
  doc §3.2 chose to expose it as `@doc false` `def` for the identical reason: "so
  `SubProcess` need not call six private helpers" / duplicate them) — this design follows
  that same established precedent, for the same reasoning, for these two functions.

**Mechanics of the `defp` → `def`/`@doc false` change:** both functions keep their exact
current `@spec`, name, arity, and body, unchanged. Only the visibility modifier changes, plus
one `@doc false` annotation each (matching `append_pending_event_arms_multi/7`'s own existing
annotation style, `lib/letflow/engine.ex:3224` area) and a one-line moduledoc-adjacent comment
on each noting the new cross-module caller (ISS-0975), mirroring the existing comment style
at the `append_pending_event_arms_multi/7` definition site itself ("ISS-0929 — public entry
point for `Letflow.Engine.SubProcess`'s completion path"). No call site of either function
inside `lib/letflow/engine.ex` itself needs to change.

### 1.2 Where the insert step goes in `build_completion_write_steps/13`'s own Multi pipe

**Current shape** (`sub_process.ex:985-1013`, restated for reference, not reproduced as
code): `reconciled_multi` is built by piping `multi` through
`TaskActivation.append_multi_from_existing_records/6` (closing over the as-built
`final_instance_state`, unmodified) and then a `Multi.run(reconciliation_key, ...)` step
calling `reconcile_parent_tokens(repo, token_records, final_instance_state.tokens,
completed_at, prefix)`.

**New shape:** both of those two existing steps move inside one new, leading
`Multi.merge/2` whose callback:

1. Runs `Multi.run(hop_chain_key, fn repo, _changes -> Letflow.Engine.
   insert_hop_chain_new_token_records(repo, parent_instance_id, token_records,
   final_instance_state.tokens, prefix) end)` as its own nested first step of a fresh
   `Multi.new()` — exactly §3.4's shape in the ISS-0408 design doc, substituting
   `parent_instance_id`/`token_records` for that design's `instance_id`/
   `original_active_tokens`.
2. Appends a second, nested `Multi.merge/2` that reads `{id_map, hop_chain_new_records} =
   Map.fetch!(changes, hop_chain_key)` back out, computes `resolved_final_instance_state =
   Letflow.Engine.rewrite_token_ids(final_instance_state, id_map)`, and — as **local
   values inside this one callback** — calls `TaskActivation.append_multi_from_existing_records/6`
   with `resolved_final_instance_state` in place of `final_instance_state`, and
   `reconcile_parent_tokens(repo, hop_chain_new_records ++ token_records,
   resolved_final_instance_state.tokens, completed_at, prefix)` in place of today's
   `reconcile_parent_tokens(repo, token_records, final_instance_state.tokens, ...)` call
   (still inside its own `Multi.run(reconciliation_key, ...)` wrapper, unchanged key).

**`hop_chain_key` — the exact key, and why it needs a 3rd, disambiguating element.**
`{:sub_process_hop_chain_token_records, parent_instance_id}` alone is **not** safe: this is
the identical collision hazard `TaskActivation.append_multi_from_existing_records/6`'s own
`key_disambiguator` parameter already exists to close (`task_activation.ex` comment,
restated in §0: "needed because `instance_id` alone is not unique enough when this function
is called once per sibling SUB_PROCESS child of the same parent instance within one
`Multi`" — `build_completion_write_steps/13` is exactly that function, called once per
sibling child completing in the same transaction, each call sharing the same
`parent_instance_id` but a distinct `parent_token.id`). The new insert step's key must
therefore be **`{:sub_process_hop_chain_token_records, parent_instance_id, parent_token.id}`**
— a 3-tuple, disambiguated by `parent_token.id` exactly as `{:task_records, instance_id,
key_disambiguator}` already is, for the identical reason. (No collision with
`Letflow.Engine`'s own `{:hop_chain_token_records, instance_id}` 2-tuple key used at its 4
sites — different leading atom, so the two naming schemes can never collide even if the
same `instance_id` value were to appear in both within one nested transaction, e.g. a future
change that makes a SUB_PROCESS parent's own completion itself go through both paths in one
`Multi` — not reachable today, but foreclosed by construction either way, same
collision-avoidance-costs-nothing reasoning as ISS-0408 design doc §3.3.)

**Why `reconciled_multi`'s own name and `Multi.run` key for the reconciliation step stay
unchanged:** `reconciliation_key = {:sub_process_parent_token_reconciliation, parent_token.id}`
is untouched — only the **arguments** passed to `reconcile_parent_tokens/5` change (widened
`original_tokens` argument, rewritten `final_tokens` argument), not the function's own
signature or the Multi step's own key.

### 1.3 `reconcile_parent_tokens/5` itself — unchanged signature and body; its *caller* widens what "already known" means

**Decision, mirroring `do_reconcile_token_records/5`'s own unchanged-body precedent (ISS-0408
design doc §5.2) exactly:** `reconcile_parent_tokens/5`'s own 5 parameters, its
`original_ids = MapSet.new(original_tokens, &to_string(&1.id))` computation, and its
`{:error, {:new_token_during_resume_not_supported, token_id}}` guard are **all unchanged**.
What changes is only what its **caller** (§1.2's new inner `Multi.merge/2` callback) passes
as its `original_tokens` argument: `hop_chain_new_records ++ token_records` instead of plain
`token_records` — the same "widen the known-token set by prepending the just-inserted
records" technique `build_task_activation_and_reconciliation_multi/4` already uses for
`reconcile_token_records/5`'s own equivalent call (`engine.ex` ~4617-4624, confirmed by
reading). This is the complete answer to the issue's own acceptance criterion #2
("reconcile_parent_tokens/5 ... needs to accept persisted-or-newly-inserted ids rather than
rejecting outright") — no new logic branch inside the function, only a different,
pre-widened input.

**Why this still type-checks as correct, restated for this call site specifically:** after
Part A, every `token_id` in `resolved_final_instance_state.tokens` is either (a) unchanged
from before the hop chain (already in `token_records`' own ids), or (b) a hop-chain-local-new
token whose synthetic id `rewrite_token_ids/2` has already replaced with the real,
just-inserted `TokenRecord.id` — and that same real id is, by construction, a member of
`hop_chain_new_records`' own ids (the function that inserted the row is the same function
that reports its id back in both the `id_map` and the `records` list). So `original_ids`,
computed from `hop_chain_new_records ++ token_records`, already contains every id
`resolved_final_instance_state.tokens` can possibly carry — the guard simply never fires on
the join-fire path anymore, for the identical structural reason ISS-0408's design doc §5.2
gives for `do_reconcile_token_records/5`.

**Reconciling the newly-inserted records themselves, not just widening the guard:** because
`hop_chain_new_records` is prepended to (not merged separately from) the list passed as
`original_tokens`, `reconcile_parent_tokens/5`'s own existing `Enum.reduce_while` (which
iterates `original_tokens`, not just `token_records`) also reconciles each newly-inserted
record against `final_by_id` in the same pass — `reconcile_one_parent_token/5` will find a
matching entry in `final_by_id` for each one (keyed by `to_string(record.id)`, which now
matches `resolved_final_instance_state.tokens`'s own rewritten `token_id` for that same
token, per `rewrite_token_ids/2`'s own stringification convention), compare `node_id`/
`waiting_child_instance_id`, and most commonly take its `{:ok, _unchanged}` branch (the
inserted row's own `node_id` already reflects the token's final hop-chain position, per
`insert_hop_chain_new_token_records/5`'s own insert-attrs construction) — this is not new
behavior requiring a design decision, it falls out of passing the widened list, and is
flagged here only so TEST-DESIGNER doesn't have to re-derive it.

### 1.4 Open question this design does NOT resolve by guessing — grandparent-cascade recursion ordering

`build_completion_write_steps/13`'s own tail (`append_completion_tail_steps/13`) can recurse
grandparent-ward (`maybe_cascade_to_grandparent/7`, `sub_process.ex:1089-1130`), itself
calling `append_completion_multi/5` again — which re-enters this same design's Part A/B for
a **different** `parent_instance_id`/`parent_token.id` pair, appended **later** in the same
outer `Multi`. §1.2's 3-tuple key already forecloses a literal key collision between the two
recursion levels (distinct `parent_token.id` values at each level). This design does **not**
further trace whether the grandparent level's own `token_records`/`final_instance_state` can
ever itself need to observe the child level's own rewritten ids before its own insert step
runs — not found reachable by this design's own read (`maybe_cascade_to_grandparent/7`
receives `final_instance_state.variables` only, not `.tokens`, from the completing level — no
token-id value crosses the recursion boundary at all) but flagged, not silently assumed, per
this project's "don't silently resolve an open question by guessing" rule. TEST-DESIGNER/
TEST-DESIGN-VALIDATOR judge whether a two-level-cascade-with-a-join-at-each-level scenario is
worth its own coverage.

## 2. Part B — `append_pending_event_arms_multi/7` reads the real id_map back out of `changes`

### 2.1 Why this function must itself become `Multi.merge`-shaped, not just take a new parameter

The naive-looking alternative — have `sub_process.ex` compute `hop_chain_id_map` as a plain
local inside §1.2's own inner `Multi.merge/2` callback, then pass that **value** straight
into `append_pending_event_arms_multi/7` as a new parameter — does **not** work structurally.
By the time `build_completion_write_steps/13`'s own code calls
`Letflow.Engine.append_pending_event_arms_multi/7` (today, immediately after `reconciled_multi`
is bound, `sub_process.ex:1013-1020`), `reconciled_multi` is already a **plain `Multi.t()`
value** — §1.2's `Multi.merge/2` callback that computes `hop_chain_id_map` has not run yet at
that point (a `Multi.merge/2` callback only executes later, inside the transaction, when
`Repo.transaction/1` actually runs the composed `Multi`) and its local variables are not
observable outside its own closure. The **only** place `hop_chain_id_map` is observable to
any later-appended step is via the transaction's own accumulated `changes` map, read inside
another `Multi.merge/2` (or `Multi.run/3`) callback — which is exactly the mechanism ISS-0974's
4 sites already use for the identical structural reason. So `append_pending_event_arms_multi/7`
must itself defer its own id_map-dependent work into a `Multi.merge/2` callback of its own, run
later in the same transaction, after Part A's insert step has already run and populated
`changes[hop_chain_key]`.

### 2.2 Precisely which part of the function's body moves into `Multi.merge/2`, and which stays eager

**Unchanged, still eager, still at Multi-build time (before any transaction runs):**

- The leading `with {:ok, prepared_timers} <- prepare_timer_arms(pending_events, graph,
  instance_id, now), {:ok, prepared_dispatches} <- prepare_service_task_dispatch_abort_on_empty_url(...),
  {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do ... end` chain
  — all three of these are pure/lookup computations whose own failure is a genuine,
  immediately-known build-time error (unknown node, empty rendered URL, catalog unresolved,
  invalid timer duration, multiple deadline timers, bad schema prefix), **not** anything that
  depends on the hop-chain id_map. These keep returning `{:error, reason}` from
  `append_pending_event_arms_multi/7` itself, exactly as today — `sub_process.ex`'s own
  `with {:ok, armed_multi} <- Letflow.Engine.append_pending_event_arms_multi(...) end`
  call site (`sub_process.ex:1014-1020`) needs **no change** to its own error-handling shape
  (still a plain `{:ok, multi} | {:error, reason}` contract at the point this function
  returns).
- `prepared_timers` and `prepared_dispatches` themselves (the lists), closed over as plain
  values into the new `Multi.merge/2` callbacks below — exactly as `build_complete_task_tail_multi/6`
  already closes over its own `prepared_timers`/`prepared_service_task_dispatches` (computed
  earlier, in plain Elixir, before any `Ecto.Multi` exists) into its own two `Multi.merge/2`
  calls, per §0's recap.

**Moved into two new, deferred `Multi.merge/2` steps** (replacing today's eager
`timer_id_map`/`dispatch_id_map` `Map.new(prepared, fn t -> {t, t} end)` lines and the
`Multi.new() |> then(&build_timer_arms_multi(...)) |> then(&build_service_task_dispatch_multi(...))`
pipe, `engine.ex:3251-3264`):

1. A first `Multi.merge/2` callback appended to `multi` that fetches the `{hop_chain_id_map,
   _hop_chain_new_records}` tuple out of `changes` at `hop_chain_token_records_key`, derives
   `timer_id_map` from `prepared_timers` using the same Map.get-with-identity-fallback pattern
   already described in §0/§1.2 (each prepared timer's own token id looked up in
   `hop_chain_id_map`, falling back to the token id itself when absent), and then calls the
   existing `build_timer_arms_multi/4` with that `timer_id_map` and `prefix`, same as today's
   call shape.
2. A second, separately-appended `Multi.merge/2` callback that performs the identical two
   steps for `prepared_dispatches`: fetches the same `{hop_chain_id_map,
   _hop_chain_new_records}` tuple back out of `changes` at `hop_chain_token_records_key` (both
   callbacks read the same key independently rather than one passing a value to the other),
   derives `dispatch_id_map` with the same fallback pattern, and calls the existing
   `build_service_task_dispatch_multi/5` with that `dispatch_id_map`, `tenant_id`, and
   `prefix`.

   — two **separate** `Multi.merge/2` calls, not one combined callback, matching the existing
   4-site precedent's own "one merge per prepared-list" shape exactly (keeps each merge's own
   failure mode independently attributable, and needs no restructuring if a future change adds
   a 3rd prepared-list kind).

`build_timer_arms_multi/4` and `build_service_task_dispatch_multi/5` themselves (private,
`engine.ex:825`/`1304`) are **unchanged** — same as ISS-0974's own fix left them; they were
always handed a wrong `id_map`, never themselves wrong.

**`tenant_id`** stays resolved eagerly (already was, via the outer `with`), simply closed over
by merge callback 2 — no `TenantProvisioning` call needed inside the deferred callback itself,
unlike `build_complete_task_tail_multi/6`'s own service-task-dispatch merge (which resolves
`tenant_id` lazily inside its own merge because its surrounding function has no equivalent
eager `with` already in scope at that point). This is a minor, intentional divergence in
*where* `tenant_id` is resolved, not in *what* `id_map` fallback logic does — flagged so
ELIXIR-DEV doesn't "fix" it to match the other 4 sites' shape unnecessarily.

### 2.3 `hop_chain_token_records_key` — new parameter, not a derived constant

**Decision:** `append_pending_event_arms_multi/7` gains an **8th parameter**,
`hop_chain_token_records_key :: term()`, becoming `append_pending_event_arms_multi/8`. Its
caller (`sub_process.ex`) passes the **exact same key value** it used for its own Part A
insert step (§1.2): `{:sub_process_hop_chain_token_records, parent_instance_id, parent_token.id}`.

**Why a passed-in key, not the function reconstructing
`{:sub_process_hop_chain_token_records, instance_id}` (or some fixed convention) itself:**

1. `append_pending_event_arms_multi/7` already receives `instance_id` as its 4th parameter,
   but **not** `parent_token.id` (today's signature has no such field — `pending_events`,
   `graph`, `instance_id`, `variables`, `now`, `prefix` only) — it would need a 9th
   parameter anyway to reconstruct the 3-tuple key itself, which is no simpler than passing
   the already-assembled key directly.
2. `Letflow.Engine` (where this function lives) and `Letflow.Engine.SubProcess` (the sole
   caller) would otherwise have to agree on a **naming convention** for this key across a
   module boundary, duplicated in both places — a passed-in key means
   `Letflow.Engine.append_pending_event_arms_multi/8` stays genuinely agnostic to which
   upstream step populated `changes` at that key, consistent with this function's own
   existing "pure of side effects until the returned Multi runs" contract (ISS-0929 design
   doc §3.2) — it does not need to know or assume anything about Part A's own naming
   scheme, only that *some* earlier step in the same `Multi` populated
   `{id_map, records}` at the key it's told to read.
3. This also keeps the function reusable for a hypothetical future caller whose own
   hop-chain-token-records insert step uses a differently-shaped key (e.g. a 2-tuple, if a
   future caller never needs the disambiguator) — the function doesn't hardcode an arity or
   shape assumption about the key, only that `Map.fetch!(changes, hop_chain_token_records_key)`
   resolves to a `{id_map, records}` pair, the same shape
   `insert_hop_chain_new_token_records/5` always returns regardless of caller.

**Signature, full, post-change:**

```
@spec append_pending_event_arms_multi(
        Multi.t(),
        [Transition.pending_event()],
        Graph.t(),
        instance_id :: Ecto.UUID.t(),
        variables :: map(),
        now :: DateTime.t(),
        prefix :: String.t(),
        hop_chain_token_records_key :: term()
      ) :: {:ok, Multi.t()} | {:error, term()}
```

Return type is **unchanged** (`{:ok, Multi.t()} | {:error, term()}`) — §2.2 already
established the eager `with` chain (the only source of a build-time `{:error, _}`) is
untouched; the two new `Multi.merge/2` calls always succeed at build time (any failure
inside them — there is none expected, `Map.fetch!/2` on a key Part A is guaranteed to have
populated by construction, per §2.4 — would raise, not return an error tuple, exactly as
`Map.fetch!(changes, {:hop_chain_token_records, instance_id})` already does, unguarded, at
all 4 ISS-0974 sites).

### 2.4 Is the identity fallback (`Map.get(hop_chain_id_map, token_id, token_id)`) still needed, or is every id now guaranteed covered?

**Answer: the fallback is still needed and correct — not every `token_id` reaching
`append_pending_event_arms_multi/8` is covered by `hop_chain_id_map`.**
`hop_chain_id_map` (Part A's own `id_map` return value) contains an entry **only** for
tokens that were hop-chain-local-new (absent from `token_records`' own ids) — the
overwhelmingly common case is a `pending_event`'s own `token_id` naming a token that
**already existed** before this hop chain started (e.g. the parent's own SUB_PROCESS token,
now advanced past the SUB_PROCESS node onto a plain SERVICE_TASK/TIMER/HUMAN_TASK, with no
join involved at all — ISS-0929's own E1/E2/E3 scenarios, §9's test E1-E3, are exactly this
un-joined case). For such a token, `hop_chain_id_map` simply has no key for it (it was never
inserted — it already existed), so `Map.get(hop_chain_id_map, token_id, token_id)` correctly
falls through to the identity branch, returning the same already-real id unchanged — same
reasoning, same conclusion, as ISS-0974's own design doc establishes for its 4 sites. This
design's own new E7/E8 test scenarios (§4) are specifically the join-fired case, to be
distinguished from E1-E3's own already-passing un-joined case, which must keep passing
unchanged (§4's negative-regression requirement, matching the issue's own 4th acceptance
criterion).

### 2.5 Confirming `hop_chain_token_records_key` is guaranteed present in `changes` by the time this function's merges run

`sub_process.ex`'s own call order (§1.2, §3 below) appends Part A's insert step (wrapped in
its own leading `Multi.merge/2`) strictly before the call to
`Letflow.Engine.append_pending_event_arms_multi/8` — both operate on the **same** `multi`
value, threaded sequentially through `build_completion_write_steps/13`'s own pipe. `Ecto.Multi`
accumulates `changes` from every step that has already run, in insertion order, regardless of
nesting depth (a `Multi.run/3` step nested inside an outer `Multi.merge/2` populates `changes`
under its own key exactly as a top-level step would — already relied on throughout this
codebase, e.g. `build_task_activation_and_reconciliation_multi/4`'s own nested-merge-reads-
sibling-nested-merge's-key pattern, confirmed by reading `engine.ex` ~4606-4624). So by the
time either of `append_pending_event_arms_multi/8`'s own two `Multi.merge/2` callbacks
actually runs (at `Repo.transaction/1` time), `changes[hop_chain_token_records_key]` is
already populated — `Map.fetch!/2` cannot raise here on the mainline path. (It remains a
defensive `Map.fetch!/2`, not a `Map.get/3` with some default, so a future change that
reorders these two calls incorrectly fails loudly with a `KeyError` rather than silently
reverting to a wrong identity map — same fail-closed reasoning as ISS-0974's own 4 sites.)

## 3. `sub_process.ex`'s own call-site update

`build_completion_write_steps/13`'s call to `Letflow.Engine.append_pending_event_arms_multi/7`
(`sub_process.ex:1014-1020`) becomes a call to `/8`, with the new 8th argument
`{:sub_process_hop_chain_token_records, parent_instance_id, parent_token.id}` — the **same**
literal key value used for Part A's own `Multi.run` key (§1.2), not re-derived or
reconstructed differently at the two use sites. (Design does not mandate whether
`build_completion_write_steps/13` binds this key to a named local once and uses it at both
call sites, versus writing the 3-tuple literal twice — ELIXIR-DEV's own style choice, since
both produce an identical value; binding it once is the less error-prone choice but is not a
correctness requirement.)

**Signatures changed, full list:**

- `Letflow.Engine.insert_hop_chain_new_token_records/5` — `defp` → `def`, `@doc false`.
  `@spec`/body unchanged.
- `Letflow.Engine.rewrite_token_ids/2` — `defp` → `def`, `@doc false`. `@spec`/body
  unchanged.
- `Letflow.Engine.append_pending_event_arms_multi/7` → `/8` — gains
  `hop_chain_token_records_key :: term()` as its final parameter (§2.3). Body restructured
  per §2.2 (two eager prepares unchanged; two deferred `Multi.merge/2` calls replace the
  former eager identity-map + `then/2` pipe).
- `Letflow.Engine.SubProcess.build_completion_write_steps/13` — body restructured per §1.2
  (new leading `Multi.merge/2` wrapping the insert step + the two existing sibling calls)
  and §3 (new 8th argument to `append_pending_event_arms_multi/8`). Its own public caller,
  `append_completion_multi/5`, and that function's own `@spec`, are **unchanged** — this is
  purely an internal restructuring, same as the ISS-0408 fix left
  `build_task_activation_and_reconciliation_multi/4`'s own outer signature alone.
- `Letflow.Engine.SubProcess.reconcile_parent_tokens/5` — **unchanged** (§1.3): neither its
  signature nor its body changes, only what its caller passes as the `original_tokens`
  argument.

**Explicitly unchanged, confirmed (not merely unmentioned):**

- `build_timer_arms_multi/4`, `build_service_task_dispatch_multi/5` (`engine.ex`) — reused
  as-is, same as ISS-0974 left them.
- `prepare_timer_arms/4`, `prepare_service_task_dispatch_abort_on_empty_url/6` — reused
  as-is.
- `TaskActivation.append_multi_from_existing_records/6`, `TaskActivation.cast_token_record_id/1`
  — unchanged; the former now receives `resolved_final_instance_state` (a value, not a
  signature change) exactly as `build_task_activation_and_reconciliation_multi/4` already
  does for its own equivalent call.
- `Letflow.Engine.Transition.fire_join/5` — zero changes, same decision as ISS-0408 design
  doc §2, not re-litigated here.

## 4. Test design (for TEST-DESIGNER)

**File:** new `describe` block(s) appended to
`test/letflow/engine/sub_process_service_task_after_test.exs` (ISS-0929's own E1-E6 file,
`lib/letflow/design/q929-vortex-8d-corrective-action-subprocess.md` §8.2) — reusing that
file's own fixture/helper idiom (no HTTP, no dispatcher/poller process, the test performs the
poller's own re-entry itself via `Engine.advance_after_service_task_outcome/4`, same as E1).

**Graph shape**, adapted from `test/letflow/iss0974_join_dispatch_id_map_test.exs`'s own
`graph_join_then_service_task/1`/`graph_join_then_timer/1` helpers (reused idiom, not reused
module — this file is self-contained per this codebase's own established per-file-fixture
discipline, same note `iss0974_join_dispatch_id_map_test.exs`'s own moduledoc states):

```
START -> SUB_PROCESS(child) -> END   (parent)
child: START -> PARALLEL_GATEWAY(split) -> HUMAN_TASK(a) / HUMAN_TASK(b)
       -> PARALLEL_GATEWAY(join) -> SERVICE_TASK|TIMER -> END
```

Distinguishing feature vs. `iss0974_join_dispatch_id_map_test.exs`'s own fixtures: the join
and its SERVICE_TASK/TIMER continuation live **inside the SUB_PROCESS's own child graph**, and
the join fires as part of the **child's own** completion (its own last `HUMAN_TASK` branch
completing) — `Engine.complete_task/3` on the child's own last branch task triggers the
child's `:completed` transition, which is what cascades into
`Letflow.Engine.SubProcess.append_completion_multi/5` → `build_completion_multi_from_merge/12`
→ `build_completion_write_steps/13`, i.e. reached via sub-process completion re-entry, not
`complete_task/3`'s own plain tail (which is what `iss0974_join_dispatch_id_map_test.exs`
exercises and does not cover this module's own, separately-filed bug).

**E7 — SERVICE_TASK variant:**

1. Provision tenant, define parent (`SUB_PROCESS -> END`) and child (the join graph above,
   SERVICE_TASK after the join), create the parent instance (spawns the child, child reaches
   `task_a`/`task_b` both pending).
2. Complete `task_a` — one join branch arrives, `:wait`, no join fires yet (same reasoning
   as ISS-0408 design doc §6 step 3).
3. **Pre-fix assertion (must FAIL on pre-fix code):** `Engine.complete_task/3` on `task_b`'s
   own id — this is the hop chain that fires the join inside the child's own
   `advance_until_stable/4` run, cascades the child's own `:completed` transition into the
   parent via `append_sub_process_completion_cascade_multi/6`
   (actually: the child completes, triggering `Letflow.Engine.SubProcess.append_completion_multi/5`
   for the **parent**'s own waiting token — restated precisely: it is the **child's**
   `complete_task/3` call whose own transaction cascades into the parent's
   `build_completion_write_steps/13`). TEST-DESIGNER confirms empirically, before writing
   the fail-first assertion, exactly what error reason surfaces from this call on
   pre-fix code — this design's own diagnosis (§0, ISSUE-FIXER's finding) predicts
   `{:error, {:new_token_during_resume_not_supported, token_id}}` (from
   `reconcile_parent_tokens/5`'s own guard, not a raw 422/`Ecto.UUID` cast error, because
   that guard fires first in the current, unfixed code) — TEST-DESIGNER must verify this
   against a real `mix test` run against the pre-fix tree rather than assume it, per this
   project's "No speculation" rule, and state the verbatim result in the test file's own
   moduledoc (matching `iss0974_join_dispatch_id_map_test.exs`'s own "Fail-then-pass proof"
   section style).
4. **Post-fix assertion (must PASS on post-fix code):** step 3's call succeeds; the child
   instance reaches the join, advances to its own SERVICE_TASK node; exactly one new
   `service_task_dispatches` row exists for that node, `token_id` resolving via FK to a
   real, newly-inserted `TokenRecord.id` (not the synthetic `"<origin>/<join_node>/joined"`
   string) — assert this directly by loading the dispatch row's own `token_id` and
   confirming a `TokenRecord` row with that id exists and has `node_id` equal to the
   SERVICE_TASK node.
5. Stub-advance the dispatch (`"advanced"` + `Engine.advance_after_service_task_outcome/4`,
   same idiom as E1); assert the child instance reaches `:completed`, and — since this
   is the *child's* own completion, not the parent's — assert the **parent**'s own
   instance also reaches `:completed` (parent's SUB_PROCESS → END, no further nodes),
   confirming the full cascade still closes correctly end to end.

**E8 — TIMER variant:** identical shape, join's own outgoing edge leads to a `:TIMER` node
inside the child graph instead of a `:SERVICE_TASK`; assert one pending `Scheduler.Timer` row
for the real, newly-inserted token id after step 3's call succeeds post-fix (mirrors E2's own
assertion style, substituting the join-reached case for E2's own plain un-joined case).

**Negative/regression requirement (issue's own 4th acceptance criterion — "No change to the
normal (non-join, non-sub-process) pending-event arming path"):** E1-E6 (already existing in
this file, ISS-0929) must stay green, unmodified, run as part of the same `mix test` pass —
these exercise `append_pending_event_arms_multi/8`'s own un-joined path (§2.4's identity-
fallback case) and are this design's own proof that the fallback logic, not just the
join-fired case, is exercised and correct.

**Mutation targets** (mirroring `iss0974_join_dispatch_id_map_test.exs`'s own mutation-proof
style): M-a revert §1.2's insert step (restore the pre-fix `reconcile_parent_tokens(repo,
token_records, ...)` call with no widening) — E7/E8 must fail with
`{:new_token_during_resume_not_supported, _}` again. M-b keep §1's insert step but revert
§2's `append_pending_event_arms_multi/8` to its own pre-fix identity id_map — E7/E8 must fail
with the real `Ecto.UUID` cast error this time (confirming Part B's own necessity
independently of Part A's). M-c revert only the TIMER half of §2.2's two merges — E8 fails,
E7 passes (confirms independent per-prepared-list coverage, same granularity
`iss0974_join_dispatch_id_map_test.exs`'s own ISS-0976 follow-up established for its own 4
sites).

## 5. Cross-references for DOC-UPDATER / later runs (not performed by this design doc itself beyond the one note below)

- **`docs/issues/ISS-0408.yaml`**: no field needs to change (its own `resolved`/`resolution`
  content remains accurate — ISS-0408's own fix is not altered by this design, only
  additionally *reused* from a new call site). Recommend DOC-UPDATER add
  `ISS-0975` to its `related:` list when ISS-0975 itself resolves, for discoverability
  (`insert_hop_chain_new_token_records/5` now has 5 call sites across 2 modules, not 4
  across 1) — not a blocking requirement, noted for completeness.
- **`test/letflow/iss0408_join_token_record_test.exs`**: no change needed — it tests the
  original 2 `Letflow.Engine`-only call sites' own behavior, unaffected by this design (the
  function's own `@spec`/body is unchanged, §1.1).
- **ISS-0929 design doc, `lib/letflow/design/q929-vortex-8d-corrective-action-subprocess.md`
  §3.1** — **does** need a correction note; applied directly by this design doc's own author
  as part of this run (see the inserted correction paragraph at that doc's §3.1, dated
  2026-10-03, citing ISS-0975): its stated reasoning ("Identity id_map ... is correct because
  `reconcile_parent_tokens/5` already rejects any token not present in the original records")
  is now explicitly superseded — `reconcile_parent_tokens/5` no longer rejects a
  hop-chain-local-new token (§1.3 of this doc), so the identity id_map it reasoned about is
  no longer vacuously safe by rejection and is replaced by the real, `changes`-sourced id_map
  this design specifies (§2).

## 6. Acceptance-criteria map

| Criterion (`docs/issues/ISS-0975.yaml`) | Design element |
|---|---|
| A join firing same-hop-chain via the sub-process/pending-event re-entry path into SERVICE_TASK/TIMER creates a real dispatch/timer row, not a 422 | §1 (Part A, persists the row) + §2 (Part B, real id_map) + E7/E8 |
| CODE-DESIGNER confirms the threading mechanism (no `changes` map available the way the 4 sites have it) | §2.1 (why a parameter-only approach fails structurally), §2.3 (the `hop_chain_token_records_key` parameter + deferred `Multi.merge/2` mechanism) |
| Regression test fails pre-fix with the REAL failure mode (confirmed empirically, not assumed) and passes post-fix, via sub-process re-entry specifically | §4, E7 step 3 |
| No change to the normal (non-join, non-sub-process) pending-event arming path | §2.4, §4's "E1-E6 must stay green" requirement |

## 7. Open questions (explicit — not resolved by guessing)

**OQ-1** — §1.4's grandparent-cascade-recursion ordering question, restated: not found
reachable by this design's own read, flagged rather than assumed, left to TEST-DESIGNER/
TEST-DESIGN-VALIDATOR to judge whether a two-level cascade with a join at each level needs
its own test.

**OQ-2** — whether `insert_hop_chain_new_token_records/5`'s own `MapSet.new(original_active_tokens,
&to_string(&1.id))` computation (now evaluated identically at 5 call sites across 2 modules)
is worth factoring into one shared private helper. Same status as ISS-0408 design doc's own
OQ-1 — left to ELIXIR-DEV, not a correctness question, not designed here as a hard
requirement.
