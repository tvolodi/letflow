# REQ-215 — SERVICE_TASK engine wiring (transition + lifecycle, closes ISS-0411 part 2)

Design for the engine-wiring half of ISS-0411/GH#807's fix, atop REQ-214's already-merged
dispatch core (`lib/letflow/engine/service_task_dispatcher.ex`,
`lib/letflow/engine/service_task_dispatcher/poller.ex`, both read in full for this design,
current on `main` as of commit `81e2dea8`). Mirrors REQ-187's own split from REQ-186
exactly, restated in the requirement text itself: REQ-214 built a subsystem (the dispatch
core), this requirement changes the engine's transition and lifecycle paths — disjoint
files, same shape as `lib/letflow/design/req187-timer-engine-wiring.md`.

**THE STUB THIS CLOSES.** `lib/letflow/engine/transition.ex:334-339`'s `dispatch_node/4`
catch-all clause currently returns `{:error, {:node_type_not_yet_implemented, :SERVICE_TASK,
node_id}}` for the one remaining `Letflow.Definitions.Graph.node_type()` variant with no
real dispatch clause. This design's §1 replaces that with a real `:SERVICE_TASK` clause.

## 0. Verified precedents (file:line, re-checked against current `main`, not paraphrased from the handoff)

| Precedent | Location | What REQ-215 mirrors from it |
|---|---|---|
| `dispatch_human_task/3`'s async-park shape | `lib/letflow/engine/transition.ex:387-390` | §1's `dispatch_service_task/4` — append to an `InstanceState` list field, return unchanged position |
| `dispatch_node/4` catch-all (the stub being replaced) | `lib/letflow/engine/transition.ex:334-339` | Confirms exact current line numbers and error shape |
| `dispatch_timer_arrival/3` / `{:timer_armed, ...}` | `lib/letflow/engine/transition.ex:568-584` | Closest existing precedent for a park-only dispatch clause that emits a `pending_event()` carrying no resolved config |
| `dispatch_timer_fired/4` / `{:token_not_at_timer, ...}` | `lib/letflow/engine/transition.ex:586-614` | §1's `{:token_not_at_service_task, ...}` defensive clause shape |
| `advance_off_completed_node/4` | `lib/letflow/engine/transition.ex:463-487` | Reused unmodified by §3's `advance_after_service_task_outcome/N` — the declared-order/default-last edge-selection algorithm `dispatch_task_completion/4` and `dispatch_sub_process_completion/4` already share |
| `pending_event()` type / `InstanceState` fields | `lib/letflow/engine/transition.ex:132-139`, `lib/letflow/engine/instance_state.ex:58-77` | §1's new `{:service_task_dispatch_requested, ...}` variant; `pending_task_nodes: [Token.t()]` is the only existing list-of-`Token.t()` field |
| `Letflow.Engine.advance_after_timer_fired/3` | `lib/letflow/engine.ex:1896-1916` | §3's direct structural mirror for `advance_after_service_task_outcome/N` |
| `Letflow.Scheduler.do_fire/2` calling `advance_after_timer_fired/3` inside `fire_timer/2`'s own transaction | `lib/letflow/scheduler.ex:262-292`, call at line 281 | §3.1's re-entry call-site decision — NOT mirrored (REQ-214's own scope boundary forbids the equivalent same-transaction call for SERVICE_TASK); see §3.1's own discussion and §7 Open Question 1 |
| `Letflow.Engine.cancel_instance/3`'s `:timer_cancellations` step calling `TaskActivation.cancel_pending_timers/5` | `lib/letflow/engine.ex:3247-3276` (call at 3269-3275) | §4's mirror for the new `:service_task_dispatch_cancellations` step |
| `TaskActivation.cancel_pending_timers/5` | `lib/letflow/engine/task_activation.ex:405-422` | §4's exact structural mirror (`update_all` on a `"pending"`-status table) |
| `Letflow.Engine.set_instance_error/2` | `lib/letflow/engine.ex:3565-3595` | §3's `:give_up` path, §2's empty-URL path |
| `Letflow.Engine.standalone_error_attrs()` type | `lib/letflow/engine.ex:3518-3527` | The exact map shape `build_empty_url_error_attrs/1` and `build_service_task_give_up_error_attrs/1` already produce |
| `ServiceTaskDispatcher.ServiceTaskDispatch.arm_changeset/2` | `lib/letflow/engine/service_task_dispatcher.ex:190-220` | §2's INSERT changeset — defined by REQ-214, called by REQ-215 (REQ-214's own moduledoc, line 141-145, states this explicitly) |
| `ServiceTaskDispatcher.attempt_dispatch/2` → `handle_success/3` / `handle_give_up/4` | `lib/letflow/engine/service_task_dispatcher.ex:571-765` | §3's caller-side contract: `{:advance, decoded_body}` / `{:give_up, standalone_error_attrs}` are already-built by REQ-214; REQ-215 never re-derives them |
| `ServiceTask.parse_config_from_node_attributes/1`, `validate_rendered_url/1`, `build_empty_url_error_attrs/1` | `lib/letflow/engine/service_task.ex:182-221, 296-327` | §2's parse/validate/error-attrs sequence, called unmodified |
| `VariableMerge.merge/3` | `lib/letflow/engine/variable_merge.ex:203-230` | §3's `:advance` path |
| `service_task_dispatches` table (already migrated) | `priv/repo/migrations/20260902010001_create_service_task_dispatches.exs` | §2's INSERT target, §4's UPDATE target — no new migration needed |
| `Graph.Node.t()` / `Graph.Edge.t()` | `lib/letflow/definitions/graph.ex:73-108` | Field shapes used throughout |
| `EventStore.platform_actor_id/0` | `lib/letflow/event_store.ex:807-808` | §3's `:give_up` `actor_id` when no real actor is available (mirrors REQ-214's own `handle_give_up/4` sentinel use, `service_task_dispatcher.ex:742`) |

## 0.1 A handoff factual premise that does NOT hold — verified absent, flagged rather than silently built around

The handoff's SCOPE item 2 says: "render its URL template against instance variables
(reuse an existing Letflow rendering mechanism, do not invent a new one)." **This
mechanism does not exist anywhere in this codebase.** Verified by direct search, not
assumed:

- No templating/mustache/liquid dependency in `mix.exs`/`mix.lock`.
- `lib/letflow/engine/service_task.ex`'s own `Config.url_template`/`body_template` fields
  are stored as opaque strings; `validate_rendered_url/1` (line 296) validates an
  *already*-rendered string's non-emptiness — it does not render.
- `lib/letflow/engine/service_task_dispatcher.ex` explicitly documents (moduledoc
  "URL freeze-at-INSERT" section, lines 77-89) that rendering is **REQ-215's** job and
  that REQ-214 "never renders a URL template."
- `lib/letflow/design/service_task_dispatcher.md:836-840` states plainly: "no function in
  this module has access to a template-rendering function ... so re-rendering ... is not
  an option this module has" — again pointing at REQ-215 as the not-yet-built renderer,
  not at an existing one.
- `lib/letflow/webhooks.ex` and everything under `lib/letflow/webhooks/` — grepped in
  full — contain no placeholder-substitution logic. REQ-183 (`webhook_delivery_dispatch`,
  the requirement the handoff cited by name) does not render templates at all; its own
  design doc (`lib/letflow/design/req183-webhook-delivery-dispatch.md`) never mentions
  `body_template`/rendering anywhere in its text.
- PROVENANCE (historical, not current decision authority):
  R-Co's own `src/engine/service_task.zig` (checked directly, since Letflow ports R-Co
  behavior) calls `validateRenderedUrl` on `cfg.url_template` with **no** intervening
  substitution step visible in that file either — R-Co's own design doc
  (`src/design/ext-01-service-task-node.md:137`, "At SERVICE_TASK activation, runtime
  renders templates against current instance variables") documents the *intent* but the
  actual renderer is not present in the R-Co source tree reachable from this session.
- Codebase-wide grep for `{{`, `${`, `EEx.eval*` used for placeholder substitution, and
  every `*template*`/`*render*`/`*interpolat*` test file name: no hits beyond the already-
  cited non-matches above.

**Per `docs/agents/shared/HANDOFF_PROTOCOL.md` §1.1 and `docs/anti-patterns.md`'s
"Inheriting a claim from a record instead of re-deriving it from the source,"** this design
does not silently build around the false premise (there is nothing to "reuse"), and does
not invent a general-purpose templating engine either — that would be new, undesigned
surface far exceeding what one `dispatch_service_task/4` clause needs, and the requirement
text's own "NOT IN THIS REQUIREMENT" list doesn't authorize adding a project-wide
templating subsystem. **Resolution adopted for this design (§2.2), stated explicitly, not
hidden:** the activation-time caller performs the smallest possible literal
`{{variables.KEY}}` substitution inline, scoped to exactly the syntax R-Co's own design doc
names (`src/design/ext-01-service-task-node.md:20`, `{{variables.order_id}}`) and to
`url_template` only (SCOPE item 2 names only URL rendering; `body_template` rendering is
out of this requirement's own SCOPE list and is deferred as Open Question 2, §7). **Flagged
for CODE-DESIGN-VALIDATOR: this is a real, load-bearing design decision the handoff's own
premise did not anticipate needing, not a rubber-stamp of the handoff's text.**

---

## 1. Transition layer (purity) — `lib/letflow/engine/transition.ex`

### 1.1 `InstanceState` field carrying the parked token

**Decision: add a new field, `pending_service_task_nodes: [Token.t()]`. Do NOT reuse
`pending_task_nodes`.**

Justification: `pending_task_nodes` (`lib/letflow/engine/instance_state.ex:64`,
`lib/letflow/engine/transition.ex:385-389`'s own comment) is explicitly documented as "the
guard for REQ-047's future tasks-row materialization" — every consumer of this field
(`TaskActivation.append_multi_from_existing_records/6`, `maybe_append_task_activation_multi/7`
at `lib/letflow/engine.ex:2683-2745`) assumes every entry becomes a `tasks` row (a
human-facing work item). A SERVICE_TASK dispatch is never a `tasks` row — REQ-214's own
`service_task_dispatches` table is a distinct schema with distinct lifecycle semantics
(pending/advanced/given_up, no human actor). Overloading `pending_task_nodes` with a
discriminating field (e.g. a `kind:` tag on each entry) would force every existing
`pending_task_nodes` consumer to add a filter/branch it does not otherwise need, and would
make `Token.t()` itself (currently a plain, kind-agnostic struct — verify against
`lib/letflow/engine/token.ex`) carry HUMAN_TASK-specific meaning implicitly. A second,
disjoint list field costs one struct field and keeps every existing `pending_task_nodes`
call site correct by construction (nothing new ever lands there), matching the "matches
REQ-187's own §4 requirement verbatim for TIMER" instruction the requirement text gives —
REQ-187 itself did NOT add a new `InstanceState` field for timers (a `:TIMER` node has no
tasks-row-shaped side effect at park time, so no such field was needed), but SERVICE_TASK's
own future write (§2, an INSERT into `service_task_dispatches`) is exactly parallel in
shape to HUMAN_TASK's `pending_task_nodes` write, not to TIMER's fully-config-free park —
hence a dedicated list field, not zero new fields.

`InstanceState` change (`lib/letflow/engine/instance_state.ex`):

```
defstruct [
  :instance_id,
  status: :active,
  tokens: [],
  variables: %{},
  pending_task_nodes: [],
  pending_service_task_nodes: [],   # NEW
  join_counters: %{}
]

@type t :: %__MODULE__{
        instance_id: String.t(),
        status: status(),
        tokens: [Token.t()],
        variables: map(),
        pending_task_nodes: [Token.t()],
        pending_service_task_nodes: [Token.t()],   # NEW
        join_counters: %{optional(String.t()) => JoinCounter.t()}
      }
```

No new moduledoc section is strictly required on `InstanceState` itself (its existing
"join_counters (REQ-051)" section is the precedent for documenting a field's own addition
inline) — add one, `## pending_service_task_nodes (REQ-215)`, one paragraph, cross-
referencing this design doc and stating the "never becomes a `tasks` row" distinction
above, so a future reader does not conflate the two lists.

### 1.2 New `pending_event()` variant

```
@type pending_event ::
        {:parallel_split, origin_token_id :: String.t(), gateway_node_id :: String.t(),
         branch_ids :: [String.t()]}
        | {:parallel_join_fired, join_node_id :: String.t(), origin_token_id :: String.t(),
           new_token_id :: String.t(), merge_events :: [VariableMerge.merge_event()]}
        | {:parallel_join_cancelled, join_node_id :: String.t(), origin_token_id :: String.t()}
        | {:sub_process_start, token_id :: String.t(), node_id :: String.t()}
        | {:timer_armed, token_id :: String.t(), node_id :: String.t()}
        | {:service_task_dispatch_requested, token_id :: String.t(), node_id :: String.t()}   # NEW
```

Carries no config and no HTTP detail (requirement text, verbatim) — same shape as
`{:timer_armed, ...}` and `{:sub_process_start, ...}`: `token_id`/`node_id` only, the
impure caller (§2) re-resolves everything else against its own already-loaded `Graph.t()`.

### 1.3 `dispatch_node/4`'s new `:SERVICE_TASK` clause (replaces the stub)

Insert alongside the existing 6 named clauses (`lib/letflow/engine/transition.ex:279-325`),
before the catch-all (`:334-339`, which then narrows to cover only a truly-unknown
`node_type`):

```
@spec dispatch_node(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
        {:ok, InstanceState.t(), [pending_event()]}
        | {:error, transition_error()}
```

New clause, matched on `%Node{node_type: :SERVICE_TASK}` (the `definition_snapshot` argument
unused, `_`-prefixed, matching every other named `dispatch_node/4` clause's own convention):
delegates its entire body to `dispatch_service_task(instance_state, token, node)` (§1.4) —
one-line pass-through, no logic of its own.

### 1.4 `dispatch_service_task/4` — the async-park write

Mirrors `dispatch_human_task/3` (`transition.ex:387-390`) exactly in shape; note the
requirement text's own function name says arity 4, but — matching `dispatch_human_task/3`'s
own real arity (it takes `instance_state`, `token`, `node` — 3 arguments, the `/3` in its
own name already excludes the leading `_definition_snapshot` `dispatch_node/4` always
passes) — the real arity is **3**, `dispatch_service_task/3`, called from `dispatch_node/4`
with `definition_snapshot` dropped exactly as `dispatch_human_task/3`'s own call site drops
it (`transition.ex:293`). **Flagged for CODE-DESIGN-VALIDATOR: the requirement text's own
"`dispatch_service_task/4`" is imprecise about arity; `/3` is what actually mirrors the
cited precedent and is what this design specifies as the real signature — not a silent
resolution of an ambiguity, a corrected one, with the correction's basis shown.**

```
@spec dispatch_service_task(InstanceState.t(), Token.t(), Node.t()) ::
        {:ok, InstanceState.t(), [pending_event()]}
```

Body: appends `token` to `instance_state.pending_service_task_nodes` (§1.1's new field),
returns the updated `InstanceState.t()` alongside a single-element `pending_event()` list
carrying `{:service_task_dispatch_requested, token.token_id, node.id}` (§1.2) — the exact
"append to a list field, emit one park event, unchanged token position" shape
`dispatch_human_task/3` itself has (§0 precedent table), with `pending_task_nodes` swapped
for `pending_service_task_nodes`.

Token position is NOT changed (no automatic outgoing traversal — same as `:HUMAN_TASK`/
`:TIMER`). No HTTP call, no `Repo`, no clock read, no `:httpc`/`HTTPoison`/`Req`/`File` call
anywhere in this function — satisfies the requirement's own AC6 grep check verbatim
(`grep -n "httpc\.\|HTTPoison\|Req\.\|File\." lib/letflow/engine/transition.ex` must return
zero matches — extends the module's own existing purity grep, `transition.ex:48-52`, with
these four additional terms; the existing grep already checks `Repo\.`/`Logger\.`/
`DateTime\.`/etc., not HTTP-client names specifically, since no prior node type ever needed
one).

### 1.5 Re-entry: `{:service_task_dispatch_outcome_advance, token_id}` — NOT added here

Unlike `{:complete_task, token_id}`/`{:timer_fired, token_id}` (which re-enter
`Transition.transition/3` via a new `transition_event()` variant dispatched by the
*caller*), REQ-215's re-entry path does not need a new `transition_event()` variant at all.
`advance_after_service_task_outcome/N` (§3) reuses **`advance_off_completed_node/4`
directly** — a private helper already shared, unmodified, by `dispatch_task_completion/4`
and `dispatch_sub_process_completion/4` (`transition.ex:463-487`) — rather than adding a
sixth `transition_event()` tag whose only purpose would be to route back into that same
shared helper through `Transition.transition/3`'s own outer `case` dispatcher. This is the
requirement text's own explicit instruction ("reusing `advance_off_completed_node/4`'s
existing algorithm"), and avoiding a needless new public entry point through
`Transition.transition/3` keeps the transition kernel's own event union
(`transition_event()`, `transition.ex:107-112`) unchanged — only `pending_event()` (§1.2)
gains a member, `transition_event()` does not.

`advance_off_completed_node/4` is `defp` (module-private) — §3's `advance_after_service_task_outcome/N`
lives in `Letflow.Engine`, a different module, so it cannot call it directly. Two options,
named rather than silently picked:

- (a) Widen `advance_off_completed_node/4`'s visibility to a `@doc false` `def` (matching
  `Letflow.Engine`'s own `advance_after_timer_fired/3` precedent for a technically-public-
  but-undocumented cross-module function, `engine.ex:1895`), OR
- (b) Add a new one-line `Transition` public wrapper, e.g. `advance_off_service_task/4`,
  that calls the private helper internally.

**Decision: (a).** `Transition.advance_off_completed_node/4`'s own existing `@spec` (already
fully typed, `transition.ex:463-467`) needs no change beyond dropping its `defp` for `def`
and adding a `@doc false` line — (b) would introduce a second, redundant public name for
the exact same behavior with no new logic, which is the kind of needless duplication
`docs/anti-patterns.md`'s SQL-fragment entry warns against in spirit (two names, one
algorithm, silent-drift risk if one is later updated and the other isn't). Flagged for
REVIEWER: this widens `Transition`'s public surface by one function; the module's own
"Purity"/"Single hop per call" moduledoc guarantees are unaffected since
`advance_off_completed_node/4`'s own body is untouched.

### 1.6 Moduledoc update (AC6's own explicit requirement)

`transition.ex`'s moduledoc "Purity (AC1)" section gains one sentence, matching the
existing REQ-187 TIMER-extension sentence's own shape (`transition.ex:38-43`):

> REQ-215 extends `pending_event()` with a fifth variant,
> `{:service_task_dispatch_requested, token_id, node_id}` — the token is appended to
> `InstanceState.pending_service_task_nodes`, a new list field disjoint from
> `pending_task_nodes` (§1.1 of `lib/letflow/design/req215-service-task-engine-wiring.md`).
> `dispatch_service_task/3` reads only its own already-supplied `token`/`node.id`
> arguments and never resolves `node.attributes`, renders a URL, or performs any HTTP/file
> call, so this extension adds no new impure dependency.

---

## 2. Impure activation-time caller

### 2.1 Where it lives

The requirement's own cross-reference ("whatever already turns `{:sub_process_start, ...}`
and `{:timer_armed, ...}` into real writes") resolves to **`Letflow.Engine`'s three
existing `pending_events`-consuming `Multi`-building call sites** — there is no single
named function; `{:sub_process_start, ...}` is consumed by
`prepare_sub_process_children/5` (`engine.ex:572`, `create/2`'s own call site) and
`prepare_sub_process_children_for_completion/8` (`engine.ex:2378`, `complete_task/3`'s and
`advance_after_timer_fired/3`'s shared call site); `{:timer_armed, ...}` is consumed by
`prepare_timer_arms/4` (`engine.ex:625`, shared by all three of `create/2`,
`complete_task/3`, and `advance_after_timer_fired/3`). Each hop-chain-producing entry point
(`run_complete_task/6`, `dispatch_task_completion_hop_chain/7`,
`build_snapshot_and_state_for_timer/4` + `persist_timer_fired_advance/7`, and `create/2`'s
own equivalent, not read in full for this design since it is unmodified) filters
`pending_events` for its own tag and prepares a `Multi` branch.

**Decision: add a fourth preparer, `prepare_service_task_dispatch/5`, following
`prepare_timer_arms/4`'s exact shape** (`Enum.filter` the hop-chain's `pending_events` for
`{:service_task_dispatch_requested, _, _}`, resolve each against `graph.nodes`, return
`{:ok, [...]}` or a typed `{:error, ...}`), called from the **same three sites**
`prepare_timer_arms/4` already is:

1. `run_complete_task/6`'s hop chain (`engine.ex:1613-1628` calls
   `dispatch_task_completion_hop_chain/7`, which at `engine.ex:2298-2299` already calls
   `prepare_timer_arms/4` — add `prepare_service_task_dispatch/5` alongside it, same
   `with` chain).
2. `advance_after_timer_fired/3`'s own hop chain
   (`persist_timer_fired_advance/7`, `engine.ex:2023-2024`, already calls
   `prepare_timer_arms/4` — same addition) — covers a `:TIMER → :SERVICE_TASK` outgoing
   edge.
3. `create/2`'s own hop chain (not read in full here; its own `prepare_timer_arms/4` call
   site, structurally identical to the two above per `prepare_timer_arms/4`'s own
   moduledoc comment "`shared unchanged by both start_instance/5's and complete_task/3's
   own call sites`," `engine.ex:611`) — covers a `:START → :SERVICE_TASK` first hop.

This is the same "shared unchanged by every hop-chain-producing entry point" pattern
`prepare_timer_arms/4` and `prepare_sub_process_children_for_completion/8` already
establish — not a new architectural shape, a fourth instance of an existing one.

### 2.2 `prepare_service_task_dispatch/5` — config-parse/render/validate sequence

```
@spec prepare_service_task_dispatch(
        [Transition.pending_event()],
        Graph.t(),
        instance_id :: Ecto.UUID.t(),
        variables :: map(),
        now :: DateTime.t()
      ) ::
        {:ok, [prepared_dispatch()]}
        | {:error, {:graph_structure_invalid, {:unknown_node_id, String.t()}}}
        | {:error, {:config_parse_failed, node_id :: String.t(), ServiceTask.config_parse_error()}}

@type prepared_dispatch :: %{
        token_id: String.t(),
        node_id: String.t(),
        arm_attrs: map()                      # ready for ServiceTaskDispatch.arm_changeset/2,
                                                # token_id filled in once the real TokenRecord
                                                # id is known -- mirrors prepared_timers' own
                                                # (token_id, arm_attrs) shape (engine.ex:621)
      }
      | {:empty_url_error, standalone_error_attrs :: Letflow.Engine.standalone_error_attrs()}
```

Per-event resolution (one `{:service_task_dispatch_requested, token_id, node_id}` at a
time, folded via `Enum.reduce_while` matching `prepare_timer_arms/4`'s own idiom):

1. `Enum.find(graph.nodes, &(&1.id == node_id))` — `nil` → `{:halt, {:error,
   {:graph_structure_invalid, {:unknown_node_id, node_id}}}}` (defensive; same
   unreachable-but-total discipline `prepare_timer_arms/4`'s own `resolve_timer_arm_attrs/4`
   uses).
2. `ServiceTask.parse_config_from_node_attributes(node)` (`service_task.ex:182-221`,
   called unmodified — REQ-056's own pure function, REQ-215 does not re-derive it). A
   `{:error, reason}` here (malformed `method`/`timeout_ms`/`retry_limit`, or neither
   `service_id` nor `endpoint` present) is a **graph-authoring-time defect** REQ-029's
   CHK-11-family validators are expected to have already caught at definition-approval
   time (mirroring `resolve_timer_arm_attrs/4`'s own `:invalid_timer_duration` defensive
   framing, `engine.ex:662-664`) — folds into `{:error, {:config_parse_failed, node_id,
   reason}}`, aborting the whole hop-chain's `Multi` (same "abort, don't half-commit"
   contract `prepare_timer_arms/4`'s own errors already have).
3. Only for `config.route_kind == :inline_url` (`route_kind: :catalog_service` is
   explicitly out of this requirement's scope per the handoff's own NOT-IN-THIS-
   REQUIREMENT line — "no change to the real `service_catalog`, still S6, unbuilt" — a
   `:catalog_service` config still reaches step 4 below with `rendered_url = nil`,
   which `validate_rendered_url/1` then rejects as `{:error, :empty_rendered_url}`,
   routing it through the SAME empty-URL error path as a genuinely-empty inline
   template; this is a deliberate, not silently-dropped, consequence — a
   `:catalog_service` row can never be usefully dispatched today regardless of which
   layer rejects it first, and REQ-214's own poller independently gives up on any
   `:catalog_service` row that *did* reach it (`service_task_dispatcher.ex:595-597`), so
   rejecting it one layer earlier, at activation, is strictly better UX (immediate
   `ERROR`, not a wasted pending row) and introduces no new failure mode): render
   `config.url_template` (§0.1's inline `{{variables.KEY}}` substitution — see §2.3).
4. `ServiceTask.validate_rendered_url(rendered_url)` (`service_task.ex:296-306`, called
   unmodified). `{:error, :empty_rendered_url}` → build the empty-URL error attrs (§2.4)
   and **halt this event's processing with `{:halt, {:empty_url_error, attrs}}`** — this
   is NOT folded into the same `{:error, ...}` shape as steps 1-2 above, because an empty-
   rendered-URL failure has its own named routing target (`set_instance_error/2`, not an
   aborted `Multi`) per the requirement's own AC4. The caller (§2.1's three call sites)
   branches on this tag exactly the way `dispatch_task_completion_hop_chain/7` already
   branches on `{:execution_error, error_args}` vs. a normal advance
   (`engine.ex:2249-2358`) — reusing that established two-outcome-tag pattern, not
   inventing a third.
5. `:ok` → build `arm_attrs` for `ServiceTaskDispatch.arm_changeset/2`
   (`service_task_dispatcher.ex:197-220`): `%{tenant_id: ..., instance_id: ..., token_id:
   <filled in later, same deferred-token_id pattern prepare_timer_arms/4 uses>, node_id:
   node_id, config_snapshot: config_snapshot_map(config, rendered_url), attempt_index: 0,
   next_attempt_at: now, created_at: now}` — `attempt_index`/`status` are not castable
   through `arm_changeset/2` (its own moduledoc, `service_task_dispatcher.ex:190-196`,
   states this), so `attempt_index: 0` here is documentation-only / defensive, matching
   the changeset's own forced default.

`config_snapshot_map/2` (new private helper, this module) — a plain map projection of
`ServiceTask.Config.t()` plus the one derived key `"rendered_url"`, matching exactly the
field set `config_from_snapshot/1` (`service_task_dispatcher.ex:630-648`) reads back:
`%{"route_kind" => to_string(config.route_kind), "url_template" => config.url_template,
"service_id" => config.service_id, "method" => to_string(config.method), "body_template" =>
config.body_template, "headers" => config.headers, "timeout_ms" => config.timeout_ms,
"retry_limit" => config.retry_limit, "rendered_url" => rendered_url}`. String-keyed,
matching `config_snapshot()`'s own `@type` (`service_task_dispatcher.ex:169-171`,
`required(String.t()) => ...`).

### 2.3 The inline URL-template renderer (§0.1's resolution, concretely specified)

New private function, this module (`Letflow.Engine`), NOT a new top-level module — its
whole surface is one function, scoped to exactly this call site, not a general subsystem:

```
@spec render_service_task_url(template :: String.t() | nil, variables :: map()) :: String.t() | nil
```

Behavior: `nil` → `nil` (passes through to `validate_rendered_url/1`'s own `nil` clause
unchanged). A non-`nil` template: `Regex.replace(~r/\{\{\s*variables\.([a-zA-Z0-9_]+)\s*\}\}/,
template, fn _match, key -> variables |> Map.get(key) |> to_rendered_string() end)` —
`to_rendered_string/1` stringifies a found value (`to_string/1` for a binary/number/atom;
`Jason.encode!/1` for a map/list, matching `Jason`'s own already-a-project-dependency
status — no new dependency added) and renders a **missing** variable key as the empty
string (not left as the literal `{{...}}` text) — this is the choice that lets AC4's "a URL
template that renders to an empty string" test scenario be constructed directly (a
template that is ENTIRELY one placeholder referencing an unset variable, e.g.
`"{{variables.missing}}"`, renders to `""` and is caught by `validate_rendered_url/1`,
exactly matching R-Co's own documented edge case,
`src/design/ext-01-service-task-node.md:142`, "rendered URL as empty string is rejected
immediately"). Scoped to `variables.KEY` syntax only (no nested-path, no filter/function
syntax, no HTML-escaping) — matching the ONE example R-Co's own design doc gives
(`ext-01-service-task-node.md:20`) and nothing beyond it; any richer syntax is explicitly
out of this requirement's scope (Open Question 2, §7) and MUST NOT be silently added here.

**Flagged prominently for CODE-DESIGN-VALIDATOR and REVIEWER: this is new pure-function
surface introduced by this design because §0.1 found no existing mechanism to reuse — not
a deviation the handoff authorized, a deviation its own false premise made unavoidable.**
Kept deliberately minimal (one `Regex.replace/3` call, no new module, no new dependency,
no untested syntax beyond R-Co's own one example) specifically so it does not become the
undesigned general templating subsystem the "NOT IN THIS REQUIREMENT" list implicitly
rules out. If a future requirement needs richer template syntax (nested variable paths,
literal `{{`/`}}` escaping, `body_template` rendering), it should replace this function
with a real one, not the other way around — this function's own `@doc` should say so
explicitly so a future reader does not mistake it for the intended long-term shape.

### 2.4 Empty-URL error path

```
@spec build_service_task_empty_url_error(
        instance_id :: Ecto.UUID.t(),
        node_id :: String.t(),
        variables :: map(),
        actor_id :: Ecto.UUID.t() | nil,
        idempotency_key :: String.t()
      ) :: Letflow.Engine.standalone_error_attrs()
```

Thin wrapper building `ServiceTask.empty_url_context()` (`service_task.ex:145-152`) from
the hop-chain's already-in-scope values (`projection.instance_id`, the resolved `node_id`,
`advanced_state.variables`, the hop-chain's own `actor_id`/`idempotency_key` — identical
in kind to `merge_output_variables/6`'s own `execution_error_event` construction,
`engine.ex:2321-2334`) and calling `ServiceTask.build_empty_url_error_attrs/1`
(`service_task.ex:314-327`) unmodified. `idempotency_key` uses
`ServiceTask.build_idempotency_key/4` (`service_task.ex:434-438`, REQ-056's own pure
function, called unmodified) with `attempt_index: 0` (no dispatch row exists yet at this
failure point).

**Routing (AC4):** the caller's `Multi` (§2.1) branches, on seeing `{:empty_url_error,
attrs}` from §2.2 step 4, into `ExecutionError.append_multi/3` — the SAME established
channel `dispatch_task_completion_hop_chain/7`'s own `{:execution_error, error_args}`
branch already uses (`build_complete_task_tail_multi/6`'s first clause,
`engine.ex:2468-2481`, `ExecutionError.append_multi(error_args, prefix: prefix,
locked_projection: projection)`) — NOT a second, standalone `set_instance_error/2` call
opening its own transaction, since this path already runs inside the hop-chain's own open
`Multi`. This satisfies AC4's "routes to `Letflow.Engine.set_instance_error/2`'s ERROR
path" in substance (same `ExecutionError.append_multi/3` sink `set_instance_error/2`
itself delegates to, `engine.ex:3586-3590`) without opening a redundant nested
transaction. **No `service_task_dispatches` row is ever inserted for this event** — step 4
of §2.2 halts before step 5's `arm_attrs` construction, satisfying AC4's "rather than ever
creating a dispatch row" clause structurally (there is no code path from an empty-URL
result to an INSERT).

### 2.5 One-transaction INSERT (AC3)

The caller's `Multi` (§2.1), for every successfully-prepared dispatch from §2.2, adds one
`Multi.insert/4` step per row — mirroring `build_timer_arms_multi/4`'s own
`Scheduler.create/2`-delegating shape (`engine.ex:698-703`) but calling
`ServiceTaskDispatch.arm_changeset/2` directly (no `Letflow.Engine.ServiceTaskDispatcher`
public "create" function exists or is needed — REQ-214's own moduledoc, line 143-145,
already documents `arm_changeset/2` as "called only by REQ-215's future activation-time
caller," i.e. THIS module, calling the changeset directly, not through an intermediary):

```
@spec build_service_task_dispatch_multi(
        Multi.t(),
        [prepared_dispatch()],
        id_map :: %{String.t() => String.t()},
        tenant_id :: Ecto.UUID.t(),
        prefix :: String.t()
      ) :: Multi.t()
```

Body: `Enum.reduce/3` over `prepared_dispatches`, folding into the incoming `multi`. Per
entry: resolves `token_record_id` from `id_map` (keyed by the event's own `token_id`,
mirroring `build_timer_arms_multi/4`'s own id-map lookup), generates a fresh `row_id`
(`Ecto.UUID.generate/0`), builds the INSERT `attrs` by merging `id`, `token_id` (the
resolved `token_record_id`), and `tenant_id` into the entry's own `arm_attrs` (§2.2 step 5),
and adds one `Multi.insert/4` step keyed `{:service_task_dispatch, token_record_id}` calling
`ServiceTaskDispatch.arm_changeset(%ServiceTaskDispatch{}, attrs)` with `prefix: prefix`.
Returns the accumulated `Multi.t()`.

Named step key `{:service_task_dispatch, token_record_id}` (a compound tuple key, mirroring
`{:hop_chain_token_records, instance_id}`'s own compound-key precedent,
`engine.ex:2713`/`2050`) rather than a bare atom — avoids `build_timer_arms_multi/4`'s own
single-timer-per-hop-chain restriction (`prepare_timer_arms/4`'s defensive "at most one
timer arm per hop chain" guard, `engine.ex:638-641`, exists only because
`Scheduler.create/2` itself hardcodes the bare step name `:scheduler_timer` — this
design's own `arm_changeset/2`-direct approach has no such restriction and does not need
an equivalent guard, since a `PARALLEL_GATEWAY` split reaching two SERVICE_TASK nodes in
one hop chain is a real, supportable case here).

**Same transaction as the state-transition event append (AC3):** this `Multi` step is
merged into the SAME `Multi.new() |> ... |> Repo.transaction()` pipeline every other
hop-chain step already shares (`run_complete_task/6`'s own top-level `Multi` pipe,
`engine.ex:1590-1639`; `persist_timer_fired_advance/7`'s own, `engine.ex:2038-2101`) —
specifically appended alongside `build_timer_arms_multi/4`'s own call site (§2.1's three
locations), so a later step's failure (e.g. the event-append step, `append_task_completed_event/5`
or `append_timer_fired_event/4`) rolls back this INSERT via `Ecto.Multi`'s own all-or-
nothing commit, exactly satisfying AC3's own test framing ("a test that forces the event
append to fail leaves no `service_task_dispatches` row behind").

---

## 3. Re-entry: `Letflow.Engine.advance_after_service_task_outcome/N`

### 3.1 Signature (mirroring `advance_after_timer_fired/3` exactly)

```
@doc false
@spec advance_after_service_task_outcome(
        dispatch_id :: Ecto.UUID.t(),
        instance_id :: Ecto.UUID.t(),
        token_id :: Ecto.UUID.t(),
        node_id :: String.t(),
        outcome :: ServiceTaskDispatcher.dispatch_outcome(),
        repo :: Ecto.Repo.t(),
        prefix :: String.t()
      ) :: {:ok, :advanced} | {:ok, :error_set} | {:error, {:instance_not_active, atom()}} | {:error, term()}
```

**Arity is `/7`, not a literally-unspecified `/N` guessed smaller.** `advance_after_timer_fired/3`'s
own 3 arguments (`timer :: Timer.t()`, `repo`, `prefix`) work because `Timer.t()` (REQ-186's
schema) already carries `instance_id`/`token_id`/`node_id` as struct fields the function
reads internally (`timer.instance_id`, `timer.token_id` via `find_token_for_timer/2`, etc.
— confirmed by reading `advance_after_timer_fired/3`'s own body, `engine.ex:1898-1916`).
REQ-215's caller (`ServiceTaskDispatcher.poll_and_dispatch/1`'s reduce loop, AFTER
`attempt_dispatch/2`'s own transaction has already committed and returned its typed
`dispatch_outcome()` — `service_task_dispatcher.ex:482-498`, §3's own call-site decision
below) does not itself hold a `%ServiceTaskDispatch{}` row (`attempt_dispatch/2` returns
only `dispatch_id`'s already-known value plus the typed outcome, not the row struct — the
row was loaded and updated inside `attempt_dispatch/2`'s own now-closed transaction,
`fetch_and_lock_dispatch/2` at `service_task_dispatcher.ex:564-569`). So the literal
"accept the row struct" mirror does not carry over as cleanly as `advance_after_timer_fired/3`'s
own case — this design instead has the reduce loop's caller pass the one scalar identifier
`poll_and_dispatch/1` already has in hand (`dispatch_id`, from its own
`claim_due_dispatch_ids/2` list), and the function re-fetches/re-locks the row itself,
internally, in its own transaction (see §3.2):

```
@doc false
@spec advance_after_service_task_outcome(
        dispatch_id :: Ecto.UUID.t(),
        outcome :: ServiceTaskDispatcher.dispatch_outcome(),
        repo :: Ecto.Repo.t(),
        prefix :: String.t()
      ) ::
        {:ok, :advanced}
        | {:ok, :error_set}
        | {:ok, :already_final}
        | {:error, {:instance_not_active, atom()}}
        | {:error, term()}
```

**This is `advance_after_service_task_outcome/4`** — the requirement text's own literal
"`advance_after_service_task_outcome/N`" already flags this as unresolved arity, resolved
here with its derivation shown rather than picked silently. It does NOT mirror
`advance_after_timer_fired/3`'s "accept the already-loaded row struct" shape, because (per
§3.1's call-site correction above) the caller does not have a loaded `%ServiceTaskDispatch{}`
struct to hand over — only `dispatch_id` (a plain scalar `poll_and_dispatch/1` already
iterates over) and the `dispatch_outcome()` `attempt_dispatch/2` already returned. The
function re-fetches the row itself, in its own transaction (§3.2), the same way
`fetch_and_lock_dispatch/2` does inside `attempt_dispatch/2` — a second lock-acquire on the
same row is required regardless, since `attempt_dispatch/2`'s own transaction (and its
`FOR UPDATE` lock) has already closed by the time this function runs. Four arguments:
`dispatch_id` (identifies the row to re-fetch), `outcome` (the already-decided
`:advance`/`:give_up` value REQ-214 hands over, per REQ-214's own design doc §5.6/§6,
`service_task_dispatcher.md:676-679`), `repo`, `prefix` — matching
`advance_after_timer_fired/3`'s own trailing `repo`/`prefix` pair exactly, differing only in
how the row is identified.

An additional `{:ok, :already_final}` outcome (not present on `advance_after_timer_fired/3`)
is added to the type: `poll_and_dispatch/1`'s reduce loop (§3's own call-site) may see a
`{:ok, :retry_scheduled}` or `{:ok, :already_final}` result from `attempt_dispatch/2` itself
— those two do not call `advance_after_service_task_outcome/4` at all (see §3's call-site
list below); `{:ok, :already_final}` is listed here only for the defensive/theoretical case
where the row's `instance_id` was independently concluded between `attempt_dispatch/2`'s
commit and this function's own re-fetch — see the `:advance` body (§3.2) for where it is
actually produced.

**Call site (§3.1's Open Question 1 resolution — see also §7 Open Question 1, retained as a
narrower question about the transaction-atomicity tradeoff, not the call-site location
itself, which this design now resolves concretely):** `ServiceTaskDispatcher.poll_and_dispatch/1`'s
own reduce loop (`service_task_dispatcher.ex:485-497`) gains the call, positioned in
`fold_attempt_result/2` (or inlined into the reduce body — implementation's choice) reading
the `dispatch_id` already in scope from `Enum.reduce(dispatch_ids, ..., fn dispatch_id, acc
-> ...)`:

- `{:ok, {:advance, decoded_body}}` → call `advance_after_service_task_outcome(dispatch_id,
  {:advance, decoded_body}, Repo, tenant_schema)`, fold its `{:ok, :advanced}` /
  `{:ok, :error_set}` / `{:ok, :already_final}` result into `acc.advanced`/`acc.given_up`/
  unchanged respectively (an `{:error, _}` result folds the same defensive way
  `fold_attempt_result/2`'s own existing `{:error, _reason}` clause already does — counted
  in neither, logged by the caller, not a new failure mode this design must design further).
- `{:ok, {:give_up, standalone_error_attrs}}` → same call, `{:give_up, standalone_error_attrs}`
  outcome, folds into `acc.given_up`.
- `{:ok, :retry_scheduled}` / `{:ok, :already_final}` (`attempt_dispatch/2`'s own two
  no-further-action outcomes) → `advance_after_service_task_outcome/4` is NOT called; folds
  exactly as `fold_attempt_result/2` already does today (`acc.retried + 1` / unchanged).
- `{:error, _reason}` → NOT called; folds exactly as today (unchanged `acc`).

**This does not touch `ServiceTaskDispatcher.attempt_dispatch/2`, `handle_success/3`, or
`handle_give_up/4`'s own bodies at all** — satisfying the requirement text's own "NOT IN
THIS REQUIREMENT: no change to REQ-214's dispatcher/poller internals" literally, not just in
spirit: `poll_and_dispatch/1` is the poller's own tick-entry orchestration function, already
designed (REQ-214's own design doc §5.5) as the caller that folds `attempt_dispatch/2`'s
per-row outcome into aggregate counts — adding one more thing it does with an
already-fully-resolved outcome is an extension of that existing orchestration role, not an
edit to `attempt_dispatch/2`/`handle_success/3`/`handle_give_up/4`'s own decision logic.
REQ-214's own design-doc line ("the re-entry function this module's poller calls into,"
`service_task_dispatcher.md:164`) is satisfied literally: `Poller` ticks call
`poll_and_dispatch/1`, and `poll_and_dispatch/1` — this module's own function — now calls
into `advance_after_service_task_outcome/4`.

### 3.2 Body — `:advance` outcome

**Transaction boundary, corrected and re-verified against the real TIMER precedent (not
merely re-asserted):** this function's `:advance` clause opens its OWN `Repo.transaction/1`,
separate from and running strictly after `attempt_dispatch/2`'s own (already-committed)
transaction — NOT nested inside it, since by the time `poll_and_dispatch/1`'s reduce loop
calls this function, `attempt_dispatch/2`'s transaction has already returned.

**This is a genuine divergence from the TIMER precedent, not merely a corrected citation of
it.** Re-reading `Letflow.Scheduler.do_fire/2` in full
(`lib/letflow/scheduler.ex:262-292`, `280-281`): `advance_after_timer_fired/3` is called
FROM INSIDE `do_fire/2`, which itself runs INSIDE `fire_timer/2`'s own single
`Repo.transaction/1` (`scheduler.ex:244-259`) — the call site's own inline comment says so
explicitly ("still inside this same `Repo.transaction/1` `fire_timer/2` already opened,"
`scheduler.ex:272-274`). So for TIMER, the row-status update, the `TIMER_FIRED` event
append, AND `advance_after_timer_fired/3`'s own advance logic are genuinely one atomic
transaction. SERVICE_TASK cannot mirror this, structurally: `Letflow.Scheduler` (the
TIMER-side poller/context module) has no rule against calling `Letflow.Engine.*` from
inside its own transaction, but `Letflow.Engine.ServiceTaskDispatcher`'s own moduledoc
explicitly forbids it ("this module never calls `Letflow.Engine.*` itself,"
`service_task_dispatcher.ex:13-22`) — a real, load-bearing scope boundary REQ-214 shipped
with, not an incidental difference. Given that boundary, `advance_after_service_task_outcome/4`
cannot be called from inside `attempt_dispatch/2`'s transaction at all; the only place left
that satisfies both "REQ-215 needs to act on the outcome" and "REQ-214's own scope boundary
stays intact" is `poll_and_dispatch/1`'s reduce loop, necessarily AFTER
`attempt_dispatch/2`'s transaction has already closed. This also diverges from REQ-214's own
design doc `service_task_dispatcher.md:656-662`'s framing of "the correct, and only
necessary, place" for the re-lock/re-check-`:active` step being inside a single
already-open transaction — here it is instead the first step of a NEW transaction this
function opens itself. **Flagged prominently: this is a real, load-bearing difference from
the TIMER precedent, caused by REQ-214's own scope boundary, not an oversight or a loose
mirroring of it.**

Steps, inside this function's own new transaction (`Repo.transaction/1`, opened at the top
of the `:advance` clause, wrapping every step below):

1. `fetch_and_lock_service_task_dispatch/3` (new private helper, mirrors
   `fetch_and_lock_dispatch/2`'s own `FOR UPDATE` shape, `service_task_dispatcher.ex:564-569`,
   but callable from `Letflow.Engine` — either a second, `Letflow.Engine`-local query
   against the same table, or a widened, `@doc false` export of
   `ServiceTaskDispatcher.fetch_and_lock_dispatch/2` itself, matching §1.5's own
   `@doc false`-widening precedent; not decided further here, left to ELIXIR-DEV as a
   mechanical choice with no behavioral difference) — re-locks the row by `dispatch_id`.
   `nil` or a row whose `status != "advanced-pending-apply"`-equivalent-already-terminal
   state (i.e. this exact re-entry already ran once, a redelivery/retry-at-this-layer case)
   → `{:ok, :already_final}`, short-circuiting the rest of this clause (this is where the
   type's `{:ok, :already_final}` member, noted in §3.1, is actually produced).
2. `fetch_and_lock_instance_projection/3` (`engine.ex:1749-1759`, called unmodified) — the
   SAME re-lock-and-re-check-`:active`-status step `advance_after_timer_fired/3`'s own
   design doc explicitly calls out as "the correct, and only necessary, place" for the
   SCH-03-style instance-terminal race to be caught (REQ-214's own design doc,
   `service_task_dispatcher.md:656-662`, quoted in §0's precedent table) — a
   `{:error, {:instance_not_active, status}}` here is this function's own version of the
   race REQ-214's poller-side transaction deliberately does NOT re-check (§5.7 of that same
   design doc). This step (not step 1's dispatch-row lock) is this design's own analogue of
   the race REQ-214's design doc discusses — the correction to the transaction-boundary
   claim above does not change WHICH step catches the race, only that it now happens inside
   this function's own separately-opened transaction rather than inside a transaction the
   caller already had open.
3. `merge_service_task_output/5` (new private helper) calls `VariableMerge.merge/3`
   (`variable_merge.ex:203-230`, unmodified) with `(projection.variables, decoded_body,
   nil)` — `variable_validations: nil` (equivalent to `%{}`, per `merge/3`'s own moduledoc,
   `variable_merge.ex:165-166`) since SERVICE_TASK output has no REQ-109
   `variable_schemas`-based validation wired in this requirement's own SCOPE (not named by
   any acceptance criterion; flagged as Open Question 3, §7, rather than silently assumed
   either way). A `{:rejected, ...}` `merge_result()` routes into the SAME
   `{:execution_error, error_args}` tagged-tuple channel `merge_output_variables/6`'s own
   REQ-049 rejection path already uses (`engine.ex`, the `complete_task/3` M4 step) —
   `dispatch_service_task_outcome_hop_chain/4` below short-circuits on this exactly as
   `dispatch_task_completion_hop_chain/7`'s own first clause does
   (`engine.ex:2249-2261`).
4. `dispatch_service_task_outcome_hop_chain/4` (new private helper) calls
   `Transition.advance_off_completed_node(graph, state_with_merged_variables, own_token,
   outgoing_edges)` **directly** (§1.5's decision — the widened, `@doc false`, now-public
   function), where `outgoing_edges = Enum.filter(graph.edges, &(&1.source ==
   own_token.node_id))` — the exact same edge-lookup line `dispatch_task_completion/4`
   itself performs before calling the same helper (`transition.ex:439-440`). Also clears
   `own_token` off `pending_service_task_nodes` first (mirroring `dispatch_sub_process_completion/4`'s
   own `cleared_token` step, `transition.ex:556`, adapted: reject from
   `pending_service_task_nodes` the entry whose `token_id` matches `own_token.token_id`) —
   `pending_service_task_nodes` (§1.1) must not still list a token that has already advanced
   off its SERVICE_TASK node, the same invariant `pending_task_nodes` upholds for
   `:HUMAN_TASK` via `TaskActivation`'s own reconciliation (out of this design's own scope
   to re-derive; this hop chain's own local removal is sufficient since REQ-215 introduces
   no persisted-row equivalent of `tasks` for this list). Result then feeds
   `advance_until_stable/4` exactly as every other hop chain does, covering a SERVICE_TASK's
   outgoing edge leading directly into another dispatch-needing node (e.g. `:SERVICE_TASK →
   :EXCLUSIVE_GATEWAY → :SERVICE_TASK`).
5. `persist_service_task_advance/6` (new private helper) — mirrors
   `persist_timer_fired_advance/7`'s own `Multi` shape (`engine.ex:2006-2112`) closely:
   `insert_hop_chain_new_token_records/5`, `TaskActivation.append_multi_from_existing_records/6`,
   `reconcile_token_records/5`, `prepare_timer_arms/4` + `build_timer_arms_multi/4` (a
   SERVICE_TASK's outgoing edge can lead into a `:TIMER` node), THIS design's own
   `prepare_service_task_dispatch/5` + `build_service_task_dispatch_multi/5` (§2 — a
   SERVICE_TASK's outgoing edge can lead into ANOTHER `:SERVICE_TASK` node),
   `prepare_sub_process_children_for_completion/8` + its own children-creation multi (a
   SERVICE_TASK's outgoing edge can lead into a `:SUB_PROCESS` node), and
   `reconcile_projection/5`.

   **This function does NOT re-update the dispatch row's own status.** REQ-214's own
   `ServiceTaskDispatcher.handle_success/3` (`service_task_dispatcher.ex:673-683`) already
   wrote this row's terminal status (`"advanced"`), inside `attempt_dispatch/2`'s own
   transaction, before `poll_and_dispatch/1` ever calls this function (§3.1's own
   caller-side contract, corrected transaction-boundary discussion above) — step 1's
   re-fetch (this clause, above) only re-reads and re-locks that already-"advanced" row, it
   does not flip its status a second time. Instead this function appends a
   `SERVICE_TASK_COMPLETED`-shaped domain event (mirrors `TIMER_FIRED`'s own "no new event
   needed beyond the domain event itself" framing, `persist_timer_fired_advance/7`'s own
   moduledoc comment, `engine.ex:1998-2000` — but UNLIKE the timer case, THIS requirement's
   own SCOPE item 3 explicitly requires `VariableMerge.merge/3`'s output to be persisted via
   a real event append, since a variable merge is exactly the kind of state change
   REQ-049's own precedent (`merge_output_variables/6`) always accompanies with an explicit
   event, not a bare projection write): one `EventStore.append/2` call, `event_type:
   "SERVICE_TASK_COMPLETED"`, payload carrying `{dispatch_id, node_id, decoded_body}`,
   `idempotency_key: "service_task_dispatch:#{dispatch_id}"`.

  **Registration path for `"SERVICE_TASK_COMPLETED"` (verified precedent, not left as an
  open question):** `EventStore.append/2` (`lib/letflow/event_store.ex:214-227`) calls
  `Registry.validate_payload/3` first, which requires the event type to already exist in
  the tenant-scoped `event_type_registry` table (`lib/letflow/event_store/registry.ex`) —
  there is no auto-registration, and no migration seeds individual event-type rows either
  (`priv/repo/migrations/20260816163103_create_event_type_registry.exs` creates only the
  table itself). The real, existing mechanism every other platform event type uses —
  `TIMER_FIRED` included (`lib/letflow/tenant_provisioning.ex:906-930`) — is a plain-map
  entry appended to the `@platform_event_type_seed_attrs` module attribute
  (`tenant_provisioning.ex:692-963`), seeded per-tenant at provisioning time by
  `maybe_seed_platform_event_types/2` (`tenant_provisioning.ex:967-975`) calling
  `Registry.register_type/2` (`tenant_provisioning.ex:969`) once per entry, tolerating
  `{:error, :duplicate_event_type_version}` as already-seeded-elsewhere-safe.

  **This design adds one entry to `@platform_event_type_seed_attrs`:**

  ```
  %{
    name: "SERVICE_TASK_COMPLETED",
    schema_version: 1,
    description:
      "Emitted by Letflow.Engine.advance_after_service_task_outcome/4 (REQ-215) when a " <>
        "SERVICE_TASK dispatch's :advance outcome is applied and its VariableMerge.merge/3 " <>
        "output is persisted.",
    json_schema: %{
      "type" => "object",
      "properties" => %{
        "dispatch_id" => %{"type" => "string"},
        "node_id" => %{"type" => "string"},
        "decoded_body" => %{"type" => "object"}
      },
      "required" => ["dispatch_id", "node_id", "decoded_body"]
    }
  }
  ```

  Field set matches this design's own §3.2 payload claim (`{dispatch_id, node_id,
  decoded_body}`) exactly, and the entry's shape (`name`/`schema_version`/`description`/
  `json_schema` keys, a `required(:required)` list of top-level property names) matches
  every neighboring entry in the same list (e.g. `TIMER_FIRED`'s own entry, cited above)
  field-for-field. **Flagged for REVIEWER:** this widens `tenant_provisioning.ex`'s own
  seed list by one entry — same class of touch every prior event-emitting requirement
  (REQ-186/TIMER_FIRED among them) has made to this same list, not a new pattern.
  **Caveat inherited from the existing mechanism, not introduced by this design:** per
  `tenant_provisioning.ex:840-850`'s own documented gap, this only seeds the type into
  tenants provisioned *after* this change ships — an already-provisioned tenant needs the
  same backfill gap every prior seed-list addition already has (out of this requirement's
  own scope to close; flagged, not silently assumed away).

  This function's own transaction is opened by this clause itself, NOT nested inside
  `ServiceTaskDispatcher.attempt_dispatch/2`'s own transaction — that transaction has
  already committed and returned by the time `poll_and_dispatch/1` calls this function
  (§3.1's corrected call-site/transaction-boundary discussion). This is a genuine, named
  divergence from `advance_after_timer_fired/3`'s own "nests as a real Postgres SAVEPOINT
  inside [the caller's already-open transaction]" contract (`engine.ex:1888`), which DOES
  hold for the real TIMER precedent (`Letflow.Scheduler.do_fire/2` calls
  `advance_after_timer_fired/3` from inside `fire_timer/2`'s own open transaction,
  `scheduler.ex:262-292`, re-verified in full for §3.2's own correction above) — the
  divergence exists because `ServiceTaskDispatcher`'s own moduledoc forbids it from ever
  calling `Letflow.Engine.*` from inside its transaction (§3.2's own fuller discussion),
  not because the TIMER precedent itself works this way.

### 3.3 Body — `:give_up` outcome

Signature: `advance_after_service_task_outcome(dispatch_id, {:give_up,
standalone_error_attrs}, repo, prefix)`. Calls `Letflow.Engine.set_instance_error/2`
**directly with REQ-214's already-built `standalone_error_attrs`** (requirement text,
verbatim) — no re-derivation, no re-building of the error map, and no re-fetch/re-lock of
the dispatch row (unlike the `:advance` clause's step 1 — this clause needs no row data
beyond what `standalone_error_attrs` already carries; `dispatch_id` is accepted for
signature uniformity with the `:advance` clause and future logging/tracing use only).

Result handling (prose, not a `case` body — see the outcome-branch table below):

- `set_instance_error/2` returning `{:ok, %{status: :error}}` → `{:ok, :error_set}` (the
  ordinary, successful path).
- `set_instance_error/2` returning `{:error, {:instance_terminal, _status}}` → `{:ok,
  :error_set}` — the instance independently reached `:completed`/`:cancelled` before this
  call landed; a benign SCH-03-style race, not a failure (REQ-214's own design doc's framing
  for the equivalent TIMER-side race, §0 precedent table).
- `set_instance_error/2` returning `{:error, {:instance_already_error, _error_detail}}` →
  `{:ok, :error_set}` — a second, equally benign race: the instance was independently
  already set to `ERROR` by a concurrent path (a different SERVICE_TASK dispatch on the same
  instance giving up first, or any other `set_instance_error/2` caller) before this call
  landed. `Letflow.Engine.set_instance_error/2`'s own `set_error_error()` union
  (`engine.ex:3538-3547`) lists this alongside `{:instance_terminal, _}` as a co-equal
  member — both are "someone else already reached a terminal-enough state first" races, and
  both are handled identically here (fold to `{:ok, :error_set}`, not a hard failure) rather
  than only the first being special-cased and the second falling through to the generic
  `{:error, reason}` clause below, which would misreport a benign, expected concurrent
  outcome as an implementation failure.
- Any other `{:error, reason}` → `{:error, reason}`, unchanged (an actual failure — e.g.
  `{:error, :missing_actor_id_or_idempotency_key}`, `{:error, Ecto.Changeset.t()}` — not a
  race this design has reason to treat as benign).

**Flagged as Open Question 1 (§7, load-bearing, not silently resolved) — narrowed to the
transaction-atomicity tradeoff only, since the call-site question itself is now resolved
(§3.1):** `set_instance_error/2`'s own public contract (`engine.ex:3565-3595`) always calls
`Repo.transaction/1` itself — it has no variant accepting a caller-supplied open
`Multi`/transaction the way `ExecutionError.append_multi/3` does (that lower-level function
IS composable into an already-open `Multi`, per its own moduledoc, `engine.ex:3510-3515` —
"`complete_task/3`'s own REQ-049/050 call sites... call `ExecutionError.append_multi/3`
directly instead, already inside their own open Multi"). Two ways to satisfy the
requirement's literal same-transaction wording, named rather than picked silently:

- (a) Call `ExecutionError.append_multi/3` directly (like `complete_task/3` does) instead
  of `set_instance_error/2`, composed into a `Multi` this function opens itself — but
  `handle_give_up/4` (`service_task_dispatcher.ex:722-765`) is itself inside
  `ServiceTaskDispatcher`, a module REQ-214 explicitly forbids from ever calling
  `ExecutionError.append_multi/3` or `set_instance_error/2` (its own moduledoc, "Scope
  boundary," `service_task_dispatcher.ex:13-22`, and the design doc's own §6, quoted in §0's
  precedent table) — irrelevant now that this design's own call site (§3.1) is
  `poll_and_dispatch/1`, not `handle_give_up/4` itself; the real obstacle to (a) is instead
  that `attempt_dispatch/2`'s own transaction (where the dispatch row's `"given_up"` status
  is written, inside `handle_give_up/4`) has ALREADY committed and closed by the time
  `poll_and_dispatch/1`'s reduce loop calls this function — so even composing
  `ExecutionError.append_multi/3` into a fresh `Multi` here would still be a SEPARATE
  transaction from the one that wrote `"given_up"`, not the same one. Satisfying the
  requirement's literal same-transaction wording would require abandoning §3.1's own
  call-site decision entirely and instead editing `handle_give_up/4`'s own body to call
  `advance_after_service_task_outcome/4` before its transaction closes — which is exactly
  the shape BLOCKER 2 of this design's own prior (rejected) draft specified, and exactly
  what REQ-214's moduledoc "Scope boundary" section and this requirement's own
  "NOT IN THIS REQUIREMENT: no change to REQ-214's dispatcher/poller internals" line rule
  out. (a) is therefore not available under this design's own call-site decision — named
  here for completeness, not as a live option.
- (b) Accept `set_instance_error/2`'s own separate transaction (as specified above) — the
  dispatch row's `"given_up"` status (already committed by REQ-214's own
  `handle_give_up/4`, inside `attempt_dispatch/2`'s own transaction, before this function is
  ever called — §3.1's corrected caller-side contract) and the instance's `ERROR` status
  become two separate commits instead of one atomic one. A crash between them leaves the
  dispatch row `"given_up"` but the instance still `:active` — recoverable (nothing
  currently re-derives instance status FROM dispatch-row status, unlike the reverse), but
  not literally atomic.

**This design specifies (b)** as the concrete, buildable answer — it is directly expressible
against `set_instance_error/2`'s existing, unmodified public contract, and it is now the
ONLY option consistent with §3.1's own call-site decision (`poll_and_dispatch/1`, strictly
after `attempt_dispatch/2`'s transaction has closed) — that same separation is also what the
`:advance` branch (§3.2) has, so `:advance` and `:give_up` are symmetric in this respect:
neither runs inside `attempt_dispatch/2`'s own transaction, both open their own. This
design flags the literal same-transaction wording as NOT met by (b) — a real, deliberate gap
between "the requirement text's literal wording" and "what REQ-214's own scope boundary and
this requirement's own NOT-IN-THIS-REQUIREMENT line jointly allow" — for
CODE-DESIGN-VALIDATOR/REVIEWER to weigh explicitly rather than discover after
implementation, not silently resolved in this design's own favor.

---

## 4. Cancellation wiring — `lib/letflow/engine.ex`'s `cancel_instance/3`

New `Multi` step, added to `run_cancel_instance/5`'s existing pipe
(`engine.ex:3247-3309`), positioned identically to `:timer_cancellations`
(`engine.ex:3252-3276`) — between `:open_tasks` and `:instance_projection`, for the
identical lock-ordering reason already documented there (acquire the
`service_task_dispatches` lock before the `instance_projections` lock, matching every
other code path's lock order, avoiding an AB-BA deadlock):

```
|> Multi.run(:service_task_dispatch_cancellations, fn repo, _changes ->
  ServiceTaskDispatcher.cancel_pending_dispatches(repo, instance_id, cancelled_at, prefix)
end)
```

New function, `lib/letflow/engine/service_task_dispatcher.ex` (this module already owns
the `ServiceTaskDispatch` schema and is where `TaskActivation.cancel_pending_timers/5`'s
own table-owning module places the equivalent function — REQ-214's module is the
`service_task_dispatches`-owning module the same way `TaskActivation` owns `timers`'
cancellation despite `Timer`'s own schema module being `Letflow.Scheduler`, so precedent
is mixed on WHICH module should own this; **this design places it on
`ServiceTaskDispatcher` itself, matching `TaskActivation.cancel_pending_timers/5`'s own
"the table-owning-adjacent module, not the schema's own defining module" placement** —
flagged as Open Question 4, §7, since the "NOT IN THIS REQUIREMENT: no change to REQ-214's
dispatcher/poller internals" line is in tension with adding a new function to
`ServiceTaskDispatcher.ex` at all, same shape as Open Question 1):

```
@spec cancel_pending_dispatches(
        repo :: Ecto.Repo.t(),
        instance_id :: Ecto.UUID.t(),
        cancelled_at :: DateTime.t(),
        prefix :: String.t()
      ) :: {:ok, non_neg_integer()}
```

Body: one `Ecto.Query` against `ServiceTaskDispatch`, filtered to `d.instance_id ==
instance_id and d.status == "pending"`, applied via `repo.update_all/3` (`prefix: prefix`)
setting `status: "given_up"`, `dispatched_at: cancelled_at`, `last_failure_kind:
"instance_cancelled"` — mirrors `TaskActivation.cancel_pending_timers/5`'s own
`update_all`-on-a-`"pending"`-status-filter shape (§0 precedent table) exactly, with the
three set-fields adapted to this table's own column names and the `"given_up"`/
`"instance_cancelled"` value choice justified below. Returns `{:ok, updated_count}` from
`update_all/3`'s own `{count, nil}` result tuple (`nil` select list, no `RETURNING`
requested — the caller only needs the count for logging/testing, matching
`cancel_pending_timers/5`'s own no-`RETURNING` shape).

**Deliberate divergence from `cancel_pending_timers/5`'s own literal shape, named
explicitly:** `timers.status` admits a real `"cancelled"` value (`chk_timers_status`'s own
4-value CHECK constraint) — `service_task_dispatches.status`'s own CHECK constraint
(`chk_service_task_dispatches_status`, `priv/repo/migrations/20260902010001_...`, quoted in
§0's precedent table) admits only `"pending"`/`"advanced"`/`"given_up"` — **no
`"cancelled"` value exists in this table's own domain** (REQ-214's own migration comment
says so explicitly: "no `cancelled` value exists in this table's own domain"). This design
therefore sets `status: "given_up"` (not `"cancelled"`) on cancellation, using the existing
`last_failure_kind` column (already nullable `:string`, no CHECK constraint on its own
values) carrying `"instance_cancelled"` as the distinguishing marker — mirroring
`cancel_task_rows/3`'s and `cancel_token_rows/3`'s own established `cancelled_at`-reuse
idiom (`engine.ex:3378-3395, 3410-3429`) but adapted to this table's own narrower status
domain. **This is a schema-shape constraint discovered while designing this section, not a
free choice** — flagged for CODE-DESIGN-VALIDATOR to confirm `"given_up"` (rather than a
new migration adding a `"cancelled"` value to the CHECK constraint) is acceptable, since
"NOT IN THIS REQUIREMENT" says nothing about migrations either way and the requirement
text's own wording ("marks that row cancelled") could be read as implying a real
`"cancelled"` status value that does not currently exist.

**"REQ-214's dispatcher never dispatches a cancelled row" (AC5):** already guaranteed
structurally without any change to `claim_due_dispatch_ids/2` — that query's own `WHERE`
clause already filters `d.status == "pending"` (`service_task_dispatcher.ex:447-449`), so a
row flipped to `"given_up"` by this section is excluded from claiming by the SAME condition
that already excludes every other terminal row, with zero new code in
`ServiceTaskDispatcher` needed for this half of AC5.

---

## 5. Documentation accuracy fix — `docs/migration/stage-7-simulation-uat-parity.md`

**Exact text to correct**, `docs/migration/stage-7-simulation-uat-parity.md:254-257`
(the "REVIEWER sign-off" section's "What was found broken" list, item (1)):

> (1) `join_counters: %{} `hardcoded on every `complete_task/3` call, preventing any
> `PARALLEL_GATEWAY` join from firing across two separate task-completion HTTP calls —
> blocked both Meridian loan-origination scenarios' committee-vote/quorum/disbursement
> paths (`ISS-0397`, resolved);

This sentence still attributes the Meridian committee-vote/quorum/disbursement gap to the
`join_counters` defect (`ISS-0397`) — stale, per the SAME document's own later, correct
item (d) (`stage-7-simulation-uat-parity.md:286-293`, already correctly naming
`ISS-0411`/the missing `SERVICE_TASK` dispatch as the real, current cause). Item (1)'s own
scope is properly "what `join_counters` itself blocked" (a real, correct, narrower claim
about the PARALLEL_GATEWAY join mechanism in isolation) — the error is specifically the
trailing clause naming the Meridian committee-vote/quorum/disbursement paths as *this*
defect's own consequence, when the corrected item (d) shows those specific paths remained
unreached for the SERVICE_TASK-dispatch reason even after `join_counters` was fixed.

**Correction (replace the quoted sentence above with):**

> (1) `join_counters: %{}` hardcoded on every `complete_task/3` call, preventing any
> `PARALLEL_GATEWAY` join from firing across two separate task-completion HTTP calls
> (`ISS-0397`, resolved) — this defect alone did not fully unblock the Meridian
> loan-origination scenarios' committee-vote/quorum/disbursement paths, since those paths
> sit behind `SERVICE_TASK` nodes; see item (d) below and `ISS-0411`/REQ-215 for the
> `SERVICE_TASK`-dispatch gap that was the real, remaining blocker (REQ-215, this stage's
> own follow-up work, closes it);

This keeps `join_counters`'/`ISS-0397`'s own real, correctly-scoped finding intact (it
genuinely was a real defect, genuinely resolved) while removing the specific
mis-attribution and forward-pointing to item (d) and this requirement, rather than
silently deleting the sentence (which would lose the historical record that this
mis-attribution existed and was corrected — matching this project's own
`docs/anti-patterns.md` "supersede rather than overwrite" discipline for correcting a
record).

**Also update, same file, item (d)'s own closing clause** (`stage-7-simulation-uat-parity.md:293`,
"re-running them to actually exercise those paths against the fixed Engine is not part of
REQ-210's own scope and is named as follow-up work below") — append one clause noting this
follow-up work is now REQ-215 itself (this requirement), since AC1/AC2 of REQ-215's own
acceptance criteria are exactly that re-run (`req208_meridian_test.exs`'s
committee-vote/quorum-2-of-3/disbursement paths reached and passing) — DOC-UPDATER's own
Step 6 should confirm this cross-reference is added, not silently left dangling once
REQ-215 ships.

---

## 6. Acceptance-criteria coverage map

| AC (handoff `context.acceptance_criteria`, in order) | Design element |
|---|---|
| 1. End-to-end SERVICE_TASK dispatch against a real test-server HTTPS endpoint, token parks then advances | §1.3-1.4 (park, no `:node_type_not_yet_implemented`), §2 (activation-time INSERT), REQ-214's already-shipped poller (unmodified) resolves it, §3.2 (`:advance` re-entry) |
| 2. `req208_meridian_test.exs`'s committee-vote/quorum-2-of-3/disbursement paths reached and pass | Same mechanism as AC1, exercised against the real Meridian scenario fixture — no separate design element; §5's doc fix records this closure |
| 3. Dispatch row + state-transition event in ONE transaction; forced event-append failure leaves no row | §2.5 (`Multi.insert/4` step merged into the same top-level `Multi.new() \|> ... \|> Repo.transaction()` pipeline every hop-chain step shares) |
| 4. Empty-rendered-URL rejected via `build_empty_url_error_attrs/1`, routes to `set_instance_error/2`'s ERROR path, never creates a dispatch row | §2.2 step 4, §2.4 |
| 5. Cancelling an instance with a pending dispatch row marks it cancelled in the same transaction as the instance's status flip; poller never dispatches a cancelled row | §4 |
| 6. `transition.ex` contains no `:httpc`/HTTPoison/Req/File call after this change; moduledoc names the new `pending_event()` variant and the parked-token field | §1.4 (purity, extended grep), §1.6 (moduledoc) |
| 7. `docs/migration/stage-7-simulation-uat-parity.md`'s REQ-210 sign-off no longer attributes the Meridian gap to `join_counters` | §5 |
| 8. `mix test` and `mix compile --warnings-as-errors` both pass, real output quoted | ELIXIR-DEV's own Step 2a responsibility — no separate design element; §1.5's `Transition.advance_off_completed_node/4` visibility change and §1.1's new `InstanceState` field are the two changes most likely to affect existing callers/tests, flagged so ELIXIR-DEV checks both explicitly |

---

## 7. Open questions (not silently resolved)

1. **Same-transaction atomicity for the `:give_up` outcome (call-site question itself is
   now resolved — see §3.1).** The requirement text's own wording ("in the SAME transaction
   as the dispatch row's own terminal-status update") is satisfied for the row-status write
   itself only in the sense that `handle_success/3`/`handle_give_up/4` (REQ-214's own,
   unmodified functions, `service_task_dispatcher.ex:673-765`) write `"advanced"`/
   `"given_up"` inside `attempt_dispatch/2`'s own transaction, and this design's own call
   site — `ServiceTaskDispatcher.poll_and_dispatch/1`'s reduce loop (§3.1), NOT
   `handle_success/3`/`handle_give_up/4`'s own bodies — calls
   `advance_after_service_task_outcome/4` strictly AFTER that transaction has already
   committed. This is a deliberate choice, not an oversight: it is the only call site
   consistent with REQ-214's own design doc ("the re-entry function this module's poller
   calls into," `service_task_dispatcher.md:164`) and moduledoc ("Scope boundary,"
   `service_task_dispatcher.ex:13-22`, "this module never calls `Letflow.Engine.*`
   itself") — `handle_success/3`/`handle_give_up/4` calling out to
   `Letflow.Engine.advance_after_service_task_outcome/4` themselves (the shape this design's
   own prior, rejected draft specified) would violate that boundary directly, and this
   requirement's own "NOT IN THIS REQUIREMENT: no change to REQ-214's dispatcher/poller
   internals" line independently forbids editing those two functions' bodies at all. The
   consequence: the dispatch row's own terminal-status write and this function's own
   `EventStore.append/2` (§3.2, `:advance`) or `set_instance_error/2` call (§3.3, `:give_up`)
   are ALWAYS two separate commits, never one atomic transaction, for both outcomes
   symmetrically — not only for `:give_up` as an earlier draft of this section framed it.
   §3.3 lists this same tradeoff and names why option (a) (composing into the same
   transaction) is not available under this design's own call-site decision.
   CODE-DESIGN-VALIDATOR/REVIEWER should confirm accepting this two-commit shape (recoverable
   via the same reasoning §3.3 gives — nothing re-derives instance status FROM dispatch-row
   status) rather than requiring literal same-transaction atomicity, which would require
   overriding REQ-214's own scope boundary and is therefore flagged here rather than decided
   unilaterally by this design.
2. **`body_template` rendering.** SCOPE item 2 names only URL-template rendering; whether
   `body_template` (also present in `ServiceTask.Config.t()`, also `{{variables...}}`-
   templated per R-Co's own design doc example) needs the SAME §2.3 renderer applied before
   REQ-214's poller reads `row.config_snapshot["body_template"]`
   (`service_task_dispatcher.ex:575`) is NOT addressed by this design — REQ-214's own
   `do_attempt_dispatch/2` reads it as a raw, unrendered string today. Left exactly as
   REQ-214 shipped it (raw), since no acceptance criterion of THIS requirement names body
   rendering — flagged rather than silently rendered or silently left broken.
3. **Variable-schema validation on SERVICE_TASK output merge.** §3.2 passes
   `variable_validations: nil` to `VariableMerge.merge/3` — REQ-109's `variable_schemas`-
   based validation (used by `complete_task/3`'s own M4 step) is NOT wired here. Not named
   by any AC; flagged so a future requirement doesn't assume it was silently included.
4. **Which module owns `cancel_pending_dispatches/4`.** §4 places it on
   `ServiceTaskDispatcher` (mirroring `TaskActivation.cancel_pending_timers/5`'s
   table-adjacent-module placement) — also in tension with the same
   NOT-IN-THIS-REQUIREMENT line as Open Question 1, for the same reason (it is a new
   function added to a REQ-214-owned file). If REVIEWER prefers, this function could
   instead live in `Letflow.Engine` itself (calling `ServiceTaskDispatcher.ServiceTaskDispatch`
   directly via its already-public schema module path) — a smaller-diff alternative not
   selected here because it would require `Letflow.Engine` to reach into
   `ServiceTaskDispatcher`'s nested schema module's `Ecto.Query` shape directly rather than
   through a named, documented function, which is a worse boundary, not a better one; named
   as the alternative in case REVIEWER weighs the "touch REQ-214's file" cost differently.
