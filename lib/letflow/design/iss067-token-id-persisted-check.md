# ISS-0067: replace UUID-cast heuristic with a real persisted-token-id membership check

## Problem (ISSUE-FIXER's diagnosis, restated for design scope)

`lib/letflow/engine.ex`'s `cast_parent_token_record_id/1` (lines 1736-1741)
decides whether a `token_id` reaching a `SUB_PROCESS` node mid-hop-chain
refers to an already-persisted `tokens` row (the normal case: a task
completion whose own token is the parent) or a derived split/join branch
token minted in-memory during this same hop chain (the unsupported case,
`{:sub_process_after_split_join_not_supported, token_id}`) by calling
`Ecto.UUID.cast/1` and treating cast failure as proof of "derived":

```
defp cast_parent_token_record_id(token_id) do
  case Ecto.UUID.cast(token_id) do
    {:ok, uuid} -> {:ok, uuid}
    :error -> {:error, {:sub_process_after_split_join_not_supported, token_id}}
  end
end
```

This works today only because of an *incidental coincidence*: persisted
token ids happen to be UUID-shaped (`to_pure_token/1`, line 1453-1460, sets
`token_id: to_string(record.id)` for every genuinely persisted token), and
`transition.ex`'s parallel-split (line 658,
`token.token_id <> "/" <> index`) and parallel-join (line 832,
`origin_token_id <> "/" <> node.id <> "/joined"`) branch-id minting happens
to never produce UUID-shaped strings. Nothing enforces that pairing — a
future change to how split/join mints branch ids (e.g. switching to a
UUID-shaped derived id, or embedding a UUID substring) could silently make
`Ecto.UUID.cast/1` succeed on a derived id and misclassify it as persisted,
or vice versa, with no compiler or test signal.

`do_reconcile_token_records/4` (engine.ex:1983-2005) already solves the same
persisted-vs-not question the correct way: it builds a real
`MapSet.new(original_tokens, &to_string(&1.id))` from the actual persisted
`TokenRecord` rows loaded for this hop chain, and does `MapSet.member?`
against it. `original_active_tokens` (the raw `[TokenRecord.t()]` list
`do_reconcile_token_records/4` is called with) is already computed once per
hop chain in `build_snapshot_and_state/4` (engine.ex:1407-1425,
`active_token_records = load_active_tokens(repo, task.instance_id, prefix)`)
and stored under the `:original_active_tokens` key of the `snapshot_and_state`
map that flows through the whole `complete_task` `Multi` pipeline. It is
already present in that map when `dispatch_task_completion_hop_chain/6`
receives it (engine.ex:1302-1309 passes the full `snapshot_and_state` map as
the function's first argument) — that function's own head just doesn't
destructure the `:original_active_tokens` key today (engine.ex:1596-1597,
`%{graph: graph, seed_instance_state: seed_state, own_token_id: own_token_id}`),
so it isn't available one level deeper in
`prepare_sub_process_children_for_completion/7`, which is where the
UUID-cast heuristic is used instead.

Confirmed by ISSUE-FIXER: zero existing tests reference
`cast_parent_token_record_id`, `sub_process_after_split_join_not_supported`,
or `new_token_during_resume_not_supported` by name — only the externally
observable reject/accept outcome for the SUB_PROCESS-after-split/join case
is under test, not the classification mechanism itself.

## Scope

**In scope:** `lib/letflow/engine.ex` only —

- `dispatch_task_completion_hop_chain/6`'s second clause (engine.ex:1596),
  to destructure and thread one more value.
- `prepare_sub_process_children_for_completion/7` (engine.ex:1685), which
  becomes `/8` (new parameter added).
- `cast_parent_token_record_id/1` (engine.ex:1736), renamed and re-typed to
  `resolve_parent_token_record_id/2`.

**Out of scope, explicitly:**

- `transition.ex` — not touched. Branch-id minting at line 658 (parallel
  split) and line 832 (parallel join) is unchanged; this design does not
  alter how derived token ids are shaped, only how the engine classifies a
  given id as persisted vs. derived.
- `do_reconcile_token_records/4` and `reconcile_one_token_record/5` — not
  touched. They already use the correct mechanism (real `MapSet` membership
  against actual `TokenRecord` rows); this design brings
  `prepare_sub_process_children_for_completion/7`'s check in line with them,
  not the reverse. See "Is `do_reconcile_token_records/4` affected?" below.
- No `Token` struct, schema, or serialization change — REJECTED in
  ISSUE-FIXER's diagnosis as disproportionate blast radius (63+ call sites
  in engine.ex, 48+ in transition.ex) relative to this issue's narrow root
  cause.
- No migration, no new DB column, no new index.
- `dispatch_task_completion_hop_chain/6`'s *other* (first) clause
  (engine.ex:1583, the `{:execution_error, error_args}` pass-through clause)
  is unchanged — it never reaches `prepare_sub_process_children_for_completion/7`.
- The other call site of `dispatch_task_completion_hop_chain` mentioned in
  its own comments (`dispatch_task_completion_hop_chain/5`, referenced in
  comments at engine.ex:462, 616, 1333 as a *different*, `create/2`-side
  function — not the `/6`-arity function this design touches) is untouched;
  it is a distinct function with its own snapshot-building path
  (`prepare_sub_process_children/5`, not `_for_completion/7`) not implicated
  by ISSUE-FIXER's diagnosis or this design.

## New parameter threading

### 1. `dispatch_task_completion_hop_chain/6` — destructure one more key

Current head (engine.ex:1596-1603):

```
defp dispatch_task_completion_hop_chain(
       %{graph: graph, seed_instance_state: seed_state, own_token_id: own_token_id},
       projection,
       actor_id,
       idempotency_key,
       {:merged, %{new_variables: merged_variables}},
       prefix
     )
```

New head — add `original_active_tokens: original_active_tokens` to the
existing map pattern (no arity change; the first argument is still one map,
matched with one more key):

```
defp dispatch_task_completion_hop_chain(
       %{
         graph: graph,
         seed_instance_state: seed_state,
         own_token_id: own_token_id,
         original_active_tokens: original_active_tokens
       },
       projection,
       actor_id,
       idempotency_key,
       {:merged, %{new_variables: merged_variables}},
       prefix
     )
```

`original_active_tokens :: [Letflow.Engine.TokenRecord.t()]` — the same
value already produced by `build_snapshot_and_state/4` and already keyed
into the `snapshot_and_state` map today; this design adds no new producer,
only a new consumer of an existing map key. No change to
`build_snapshot_and_state/4` itself.

### 2. `prepare_sub_process_children_for_completion/7` → `/8`

Current head (engine.ex:1685-1693):

```
defp prepare_sub_process_children_for_completion(
       advanced_state,
       graph,
       pending_events,
       projection,
       actor_id,
       idempotency_key,
       prefix
     )
```

New head — one new parameter, inserted immediately after `advanced_state`
(placement choice: adjacent to the other "hop-chain snapshot" data rather
than at the end, since it is conceptually part of the same snapshot as
`advanced_state`; any position is mechanically equivalent, but call sites
below assume this one):

```
defp prepare_sub_process_children_for_completion(
       advanced_state,
       original_active_tokens,
       graph,
       pending_events,
       projection,
       actor_id,
       idempotency_key,
       prefix
     )
```

`original_active_tokens :: [Letflow.Engine.TokenRecord.t()]` — passed
through unchanged from `dispatch_task_completion_hop_chain/6`'s newly
destructured value (see call-site table below; the only call site of this
private function is engine.ex:1618-1626).

Inside the function body, build the membership set **once**, before the
`Enum.reduce_while/3` over `sub_process_starts` (not once per iteration —
avoids rebuilding the same set on every `sub_process_start` pending event in
the same hop chain). Construct `persisted_token_ids` by mirroring
`do_reconcile_token_records/4`'s own existing idiom at engine.ex:1984 for
building its persisted-id set: a `MapSet` built from `original_active_tokens`
whose members are each record's `id` field normalized through `to_string/1`
— i.e. the same "map each `TokenRecord` to the string form of its `id`, then
collect into a `MapSet`" shape already present in that function, applied
here to the same `original_active_tokens` source value.

The `with` clause inside the `reduce_while` callback changes at exactly one
point: the call to `cast_parent_token_record_id(token_id)` is replaced by a
call to `resolve_parent_token_record_id/2`, invoked with `token_id` and the
newly constructed `persisted_token_ids` set as its two arguments, in that
order. The clause's arrow (`<-`) and its bound variable
(`parent_token_record_id`) are unchanged; only the function name and its new
second argument differ from today's single-argument call.

No other line in `prepare_sub_process_children_for_completion/7`'s body
changes — the `Enum.find(graph.nodes, ...)`, `SubProcess.prepare_child_activation/4`
call, and both `else` branches (`:unknown_node`, the
`{:sub_process_after_split_join_not_supported, _token_id} = reason}` halt,
and the generic `{:error, failure}` → `SubProcess.to_error_args/6` branch)
are byte-for-byte unchanged, since `resolve_parent_token_record_id/2`
preserves the exact `{:ok, term} | {:error, {:sub_process_after_split_join_not_supported, token_id}}`
return contract those branches already pattern-match against.

### 3. `cast_parent_token_record_id/1` → `resolve_parent_token_record_id/2`

Current (engine.ex:1736-1741):

```
defp cast_parent_token_record_id(token_id) do
  case Ecto.UUID.cast(token_id) do
    {:ok, uuid} -> {:ok, uuid}
    :error -> {:error, {:sub_process_after_split_join_not_supported, token_id}}
  end
end
```

New:

```
@spec resolve_parent_token_record_id(
        token_id :: String.t(),
        persisted_token_ids :: MapSet.t(String.t())
      ) :: {:ok, String.t()} | {:error, {:sub_process_after_split_join_not_supported, String.t()}}
```

`resolve_parent_token_record_id/2` replaces `cast_parent_token_record_id/1`
as a `defp` taking two arguments (`token_id`, `persisted_token_ids`) instead
of one. Its body is a single membership check: it tests whether `token_id`
is a member of the `persisted_token_ids` set and returns one of exactly two
outcomes based on that test, described precisely in "Exact semantics" below
— no `Ecto.UUID` call, no string-shape inspection, and no branch beyond the
member/non-member split.

**Exact semantics:**

- `token_id` is a real member of `persisted_token_ids` (string equality,
  same `to_string/1`-normalized form `do_reconcile_token_records/4` already
  uses) → `{:ok, token_id}`. The `:ok` payload is the input `token_id`
  itself, unchanged — no casting, no re-encoding.
- `token_id` is not a member → `{:error, {:sub_process_after_split_join_not_supported, token_id}}`,
  identical error tuple shape to today, `token_id` unchanged (not the
  attempted-but-failed cast result — today's `:error` branch already returns
  the original `token_id`, not a cast artifact, so this is unchanged).
- No `Ecto.UUID` call anywhere in the new function. Classification is a pure
  `MapSet.member?/2` check, not a string-shape inspection.

## Byte-identical-output justification (why this preserves every existing decision)

For a **genuinely persisted** `token_id` reaching this code path: it always
originates from `own_token_id` or from a `Token.t()` built by
`to_pure_token/1` (engine.ex:1453-1460), which sets
`token_id: to_string(record.id)` — i.e. the *exact* canonical string form of
a `TokenRecord`'s `id` field, with no transformation. `persisted_token_ids`
is built the same way (`MapSet.new(original_active_tokens, &to_string(&1.id))`,
mirroring `do_reconcile_token_records/4`). So for any `token_id` that is
actually the id of one of this hop chain's own persisted `TokenRecord` rows,
`MapSet.member?/2` is `true` — same outcome as today's
`Ecto.UUID.cast/1` succeeding on that same already-canonical string (casting
an already-canonical Ecto UUID string is idempotent: `Ecto.UUID.cast/1`
returns it unchanged). `{:ok, token_id}` is returned in both old and new
code for this case, and the value returned is textually identical (old
code's `{:ok, uuid}` was already the same string as `token_id`, since
`Ecto.UUID.cast/1` does not alter an already-canonical input).

For a **genuinely derived** `token_id` (a split/join branch id minted by
`transition.ex` lines 658/832, e.g. `"<uuid>/0"` or
`"<uuid>/<node_id>/joined"`): it is never equal to any string in
`persisted_token_ids` (no `TokenRecord.id` is ever assigned that literal
value — persisted ids come only from `Ecto.UUID` primary-key generation, not
from string concatenation), so `MapSet.member?/2` is `false` — same outcome
as today's `Ecto.UUID.cast/1` failing on that same non-UUID-shaped string
(confirmed by ISSUE-FIXER: these concatenated forms are not UUID-shaped
today).

Net: **for every `token_id` value reachable under today's actual minting
scheme** (persisted ids from `Ecto.UUID` generation, derived ids from the
two `transition.ex` concatenation sites), the new predicate returns the
exact same `{:ok, token_id} | {:error, {:sub_process_after_split_join_not_supported, token_id}}`
value as the old predicate, for the same input. This is a mechanism swap,
not a behavior change, for every real input — the two mechanisms only
diverge for hypothetical inputs that are UUID-shaped *and* not persisted
(or non-UUID-shaped *and* persisted), and no such input exists in the
codebase today. That divergence is exactly the "incidental coincidence"
risk ISS-0067 flags, and this design removes it going forward: see next
section.

## What this fixes going forward

After this change, classification no longer depends on `token_id`'s string
*shape* at all — only on whether it is a real member of this hop chain's
persisted `TokenRecord` ids. If `transition.ex`'s split/join minting scheme
ever changes (e.g. switching to UUID-shaped derived ids, or embedding a
UUID substring in a branch id), `resolve_parent_token_record_id/2` still
classifies correctly, because a derived id — however it is shaped — is
still never a member of `persisted_token_ids` (it is never written to a
`tokens` row before this check runs). The `Ecto.UUID.cast/1`-based heuristic
this design replaces would have silently misclassified such a future
derived id as persisted; the new mechanism cannot, by construction.

## Is `do_reconcile_token_records/4` affected?

**No.** Per ISSUE-FIXER's diagnosis, confirmed here: `do_reconcile_token_records/4`
(engine.ex:1983-2005) already builds and checks membership against a real
`MapSet` of persisted ids — it is not changed by this design at all, in
signature or body. This design's `persisted_token_ids` set inside
`prepare_sub_process_children_for_completion/7` (now `/8`) is built
independently, from the same `original_active_tokens` source value, using
the same `MapSet.new(tokens, &to_string(&1.id))` idiom — deliberately
mirroring `do_reconcile_token_records/4`'s existing code rather than
extracting a shared helper both call, since the two call sites are one
`Multi.run/3` step apart in the same transaction and a shared helper would
be a larger refactor than this issue's scope warrants (not requested by
ISSUE-FIXER; flagged here as a considered-and-declined option, not an open
question).

## Call-site summary table

| Call site | Before | After |
|---|---|---|
| `dispatch_task_completion_hop_chain/6`'s 2nd clause head, engine.ex:1596 | matches `%{graph:, seed_instance_state:, own_token_id:}` | matches `%{graph:, seed_instance_state:, own_token_id:, original_active_tokens:}` |
| Inside that clause, calling `prepare_sub_process_children_for_completion/7`, engine.ex:1618-1626 | args: `advanced_state, graph, pending_events, projection, actor_id, idempotency_key, prefix` | args: `advanced_state, original_active_tokens, graph, pending_events, projection, actor_id, idempotency_key, prefix` |
| `prepare_sub_process_children_for_completion/7` head, engine.ex:1685 | params: `advanced_state, graph, pending_events, projection, actor_id, idempotency_key, prefix` | params: `advanced_state, original_active_tokens, graph, pending_events, projection, actor_id, idempotency_key, prefix` (now `/8`) |
| Inside its body, before the `reduce_while` | (no set built) | `persisted_token_ids = MapSet.new(original_active_tokens, &to_string(&1.id))` |
| Inside the `reduce_while`'s `with`, engine.ex:1698 | `{:ok, parent_token_record_id} <- cast_parent_token_record_id(token_id)` | `{:ok, parent_token_record_id} <- resolve_parent_token_record_id(token_id, persisted_token_ids)` |
| Helper definition, engine.ex:1736-1741 | `defp cast_parent_token_record_id(token_id)` doing `Ecto.UUID.cast/1` | `defp resolve_parent_token_record_id(token_id, persisted_token_ids)` doing `MapSet.member?/2` |

No other call site of `prepare_sub_process_children_for_completion/7` exists
in the codebase (single caller, confirmed by the surrounding code read for
this design). No other call site of `cast_parent_token_record_id/1` exists
either (grepped as part of ISSUE-FIXER's diagnosis).

## Acceptance criteria

1. **Persisted ids still classify as persisted.** For every `token_id` that
   is a genuine member of the current hop chain's `original_active_tokens`
   (i.e. `to_string(record.id)` for some `%TokenRecord{}` in that list),
   `resolve_parent_token_record_id/2` returns `{:ok, token_id}` — same as
   `cast_parent_token_record_id/1` did.
2. **Derived ids still classify as derived.** For every `token_id` shaped
   like a `transition.ex` split branch id (`"<parent>/<index>"`) or join
   branch id (`"<origin>/<node_id>/joined"`) under today's minting scheme,
   `resolve_parent_token_record_id/2` returns
   `{:error, {:sub_process_after_split_join_not_supported, token_id}}` —
   same as today.
3. **No behavior change for `prepare_sub_process_children_for_completion/7`'s
   three outcomes** (`{:ok, {:advanced, advanced_state, prepared_children}}`,
   `{:ok, {:execution_error, error_args}}`, `{:error, reason}`) for any
   input reachable under today's actual token-minting scheme — verified by
   the full existing `mix test` suite (particularly any SUB_PROCESS +
   PARALLEL_GATEWAY interaction tests) passing with the same pass/fail
   counts as before this change.
4. `do_reconcile_token_records/4` and `reconcile_one_token_record/5` are
   byte-for-byte unchanged (no diff in `git diff` for those two function
   bodies).
5. `transition.ex` is untouched (no diff in `git diff` for that file).
6. `mix compile --warnings-as-errors` exits 0 (no unused-parameter or
   unused-variable warnings from the added `original_active_tokens`
   threading).
7. `mix format --check-formatted` passes on `lib/letflow/engine.ex`.
8. Full `mix test` suite passes with the same pass/fail counts as before
   this change — no regression, no newly-skipped test. Per ISSUE-FIXER,
   no test names `cast_parent_token_record_id` or
   `resolve_parent_token_record_id` directly, so no test file changes are
   expected; if TEST-RUNNER finds a test that now fails, treat that as
   evidence the mechanism swap diverged from criteria 1-3 above (a real
   behavior change), not a reason to update the test to match new output.

## Security/scope note (for SECURITY-REVIEWER and REVIEWER)

- No supervision-tree code touched — this is plain function-body logic
  inside the existing `Letflow.Engine` module, not a `GenServer`/
  `gen_statem` callback or process-lifecycle change.
- No migration, no schema change, no new DB column or index.
- No tenant-data-path change: `original_active_tokens` is already loaded
  (by `load_active_tokens/3`, itself `prefix`-scoped) and already flows
  through this same transaction today via `do_reconcile_token_records/4`'s
  own use of the same source value; this design adds a second, independent
  read of a value already loaded once per hop chain — it does not add a new
  DB query, new `prefix:` usage, or new tenant-scoped read/write.
- Pure in-process token-id classification logic: the change replaces one
  pure function (`Ecto.UUID.cast/1`-based) with another pure function
  (`MapSet.member?/2`-based), both `defp`, both with the same
  `{:ok, _} | {:error, {:sub_process_after_split_join_not_supported, _}}`
  return contract. No new public API surface.
- No new string interpolation into SQL, no new external input trust
  boundary crossed — `token_id` was already attacker-non-influenceable
  engine-internal data (sourced from `Token.t()` structs built from DB rows
  or from `transition.ex`'s own deterministic minting), both before and
  after this change.

## Invariants

- `resolve_parent_token_record_id/2`'s return contract
  (`{:ok, token_id} | {:error, {:sub_process_after_split_join_not_supported, token_id}}`)
  is identical in shape to `cast_parent_token_record_id/1`'s, so the
  `with`/`else` clauses in `prepare_sub_process_children_for_completion/7`
  (now `/8`) that pattern-match on it require no other changes.
- `persisted_token_ids` is built exactly once per
  `prepare_sub_process_children_for_completion/8` call (outside the
  `reduce_while`), not once per `sub_process_start` pending event.
- `original_active_tokens` has exactly one producer in this pipeline
  (`build_snapshot_and_state/4`, unchanged by this design) and gains exactly
  one new consumer (`prepare_sub_process_children_for_completion/8`, via
  `dispatch_task_completion_hop_chain/6`) in addition to its existing
  consumer (`do_reconcile_token_records/4`, via
  `build_complete_task_tail_multi`/`build_token_reconciliation_step`, unchanged).
- No call site of `resolve_parent_token_record_id/2` exists outside
  `prepare_sub_process_children_for_completion/8`; it stays `defp`.

## Open questions

None. ISSUE-FIXER's diagnosis fully identifies the source of
`original_active_tokens`, its existing consumer's correct idiom
(`do_reconcile_token_records/4`), and the single call site needing the new
parameter threaded through — there is no unresolved design decision left
for ELIXIR-DEV to guess at. One considered-and-declined alternative is
recorded above (extracting a shared `persisted_token_ids`-building helper
used by both `do_reconcile_token_records/4` and
`prepare_sub_process_children_for_completion/8`) — declined as
out-of-proportion to this issue's scope, not because it's a bad idea; a
future cleanup issue could revisit it if the duplication becomes a
maintenance problem.
