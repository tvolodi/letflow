# ISS-0724 — keep random/manual resolved-question blocks structurally separate through persistence

CODE-DESIGNER, WF-03 Step 2 (fix design) for `docs/issues/ISS-0724.yaml` (queue
Q-722, GH#1565, severity MINOR). Diagnosis: ISSUE-FIXER (Step 1, same run).

## 0. Scope

`materialize_session/5` (`lib/letflow/exam/session.ex:711-761`) and
`persist_session_questions/4` (`lib/letflow/exam/session.ex:868-882`) are the only two
functions this design touches. `QuestionSetResolver` (`lib/letflow/exam/question_set_resolver.ex`)
is **not** touched — see §1 for why, since that was the alternative on the table.

## 1. Chosen approach: list separation through `persist_session_questions/5`, not origin-tagging in `QuestionSetResolver`

**Following ISSUE-FIXER's recommendation, not diverging from it.** Independently
re-derived reasoning, not a rubber stamp:

- Tagging `QuestionSetResolver.resolved_question()` with an `origin: :random | :manual`
  field would require the resolver's own public type to carry a value it has no
  opinion about and never produces itself (`:manual` never originates inside
  `resolve/5` — only `Session` constructs manual rows). That widens a module boundary
  `lib/letflow/design/iss0722-exam-manual-question-mode.md` §2 already drew on purpose
  ("resolver untouched, manual bypasses it entirely") for a concern that belongs to the
  caller, not the resolver.
- A tag on a map field is a **runtime** fact — nothing stops a future edit from doing
  `Enum.map(resolved, &Map.put(&1, :origin, :random))` or simply ignoring the tag while
  shuffling the merged list; it's only checkable after the fact, by a test asserting
  the tag's invariant continues to hold, or a runtime guard. AC1 asks for a bar this
  doesn't clear on its own ("fail to compile... rather than silently violate").
- Keeping `resolved_random` and `resolved_manual` as two distinct local bindings all
  the way through `materialize_session/5` and across the boundary into
  `persist_session_questions/5` (arity 4 → 5, see §3) means there is **no single
  variable named `resolved`** left anywhere in `Session` for a future edit to
  reorder/reshuffle as one blob without that edit being forced to either (a) shuffle
  only one of the two named bindings — visibly wrong in review, since nothing calls
  `Enum.shuffle/1` on `resolved_manual` today and any addition of one is a highly
  visible one-line diff — or (b) explicitly reintroduce a merge (`resolved_random ++
  resolved_manual`) and change `persist_session_questions/5`'s call arity back down to
  4, which is exactly the compile-time signal AC1 asks for (§4).

This is materially the same shape ISSUE-FIXER proposed; this design fixes the exact
arity, field layout, and body mechanics.

## 2. `materialize_session/5` — exact changes

Current body computes `resolved_random`, then `resolved_manual` (without `sort_order`),
then merges+reindexes into one `resolved` list (lines 736-739) passed to
`persist_session_questions/4`. New body:

1. `resolved_random` — **unchanged**: still `{:ok, resolved_random} <-
   QuestionSetResolver.resolve(rules, pool, fv(exam, "shuffle_questions") == true,
   shuffle_options?, seed)`. Its rows already carry `sort_order` `0..n-1` from the
   resolver's own internal `Enum.with_index/1` (question_set_resolver.ex:79) — untouched,
   per `iss0722-...md` §2/§4.
2. `resolved_manual_unindexed` — **unchanged** construction (session.ex:723-734): map
   `manual_questions` to `%{question_id: question_id, options_order: <shuffled-or-not>}`,
   no `sort_order` key yet.
3. **Changed**: replace the concatenate-then-reindex block (current lines 736-739) with
   assigning `sort_order` to the manual block alone, continuing the numbering where the
   random block's own indices leave off:

   ```
   resolved_manual =
     resolved_manual_unindexed
     |> Enum.with_index(length(resolved_random))
     |> Enum.map(fn {row, index} -> Map.put(row, :sort_order, index) end)
   ```

   `Enum.with_index/2`'s second argument is the starting offset — this is standard
   library behavior, not new logic. **Behavioral identity with today's output**: today,
   `(resolved_random ++ resolved_manual) |> Enum.with_index()` assigns index `0..n-1` to
   the random block (in its existing order) and `n..n+m-1` to the manual block (in its
   existing order), where `n = length(resolved_random)`. Because `resolved_random`'s
   *own* rows already carry `sort_order` `0..n-1` matching their list position exactly
   (resolver output is never reordered after its own `Enum.with_index/1`), reindexing
   the random block again would always be a no-op — the old code just happened to
   recompute the same values. The new code skips recomputing the random block's
   `sort_order` at all (it's already correct) and computes only the manual block's,
   starting at `length(resolved_random)`. Bit-for-bit identical `sort_order` values,
   for every row, in both blocks, versus current behavior.
4. `resolved_random` and `resolved_manual` are never concatenated anywhere in
   `materialize_session/5`. Both are passed, as two separate arguments, to
   `persist_session_questions/5` (§3):

   ```
   with {:ok, %{record: session_record}} <-
          write_record("session", session_attrs, candidate_id, prefix),
        :ok <-
          persist_session_questions(
            session_record.record_id,
            resolved_random,
            resolved_manual,
            candidate_id,
            prefix
          ) do
     {:ok, session_view(session_record)}
   end
   ```

No other line in `materialize_session/5` changes (session_attrs construction,
`write_record` call, `session_view` return — all untouched).

## 3. `persist_session_questions/4` → `persist_session_questions/5`

**Arity change: 4 → 5.** The old 4-arity clause is deleted, not kept as an overload or
fallback — there is exactly one `persist_session_questions` function in `Session` after
this change, and it takes two question lists, not one.

```
@spec persist_session_questions(
        session_id :: String.t(),
        resolved_random :: [QuestionSetResolver.resolved_question()],
        resolved_manual :: [QuestionSetResolver.resolved_question()],
        actor_id :: String.t(),
        prefix :: String.t()
      ) :: :ok | {:error, term()}
```

Body, in words: delegate each block to a new private helper `write_question_rows/4`
that is exactly today's `persist_session_questions/4` body (the
`Enum.reduce_while(resolved, :ok, fn resolved_question, :ok -> ... end)` loop building
`attrs` from `resolved_question.question_id` / `.sort_order` / `.options_order` and
calling `write_record("session_question", attrs, actor_id, prefix)`), unchanged
verbatim, called twice — random block first, then manual block, via `with`:

```
@spec write_question_rows(
        session_id :: String.t(),
        rows :: [QuestionSetResolver.resolved_question()],
        actor_id :: String.t(),
        prefix :: String.t()
      ) :: :ok | {:error, term()}
```

```
defp persist_session_questions(session_id, resolved_random, resolved_manual, actor_id, prefix) do
  with :ok <- write_question_rows(session_id, resolved_random, actor_id, prefix),
       :ok <- write_question_rows(session_id, resolved_manual, actor_id, prefix) do
    :ok
  end
end
```

`write_question_rows/4`'s own body is origin-blind by design — that's correct and safe
at this stage, because by the time either list reaches it, `sort_order` is already
fixed per row (assigned in `materialize_session/5`, §2) and DB insertion order has no
bearing on later read/display order (that's what the stored `sort_order` column is
for). The invariant ISS-0724 protects is "no future edit reorders/reshuffles the manual
block before its `sort_order` is assigned" — not "the two blocks must never touch the
same DB-write code path." Reusing one write helper for both blocks, called from two
separate call sites with two separately-named lists, does not reintroduce the
concatenation problem: nothing before either call reorders `resolved_manual` relative
to itself, and nothing merges the two lists into one iterable before random's rows have
already been fully persisted.

**Why the helper split (`write_question_rows/4`) instead of inlining `Enum.reduce_while`
twice in `persist_session_questions/5`:** avoids duplicating the `attrs`-building/
`write_record` logic verbatim in two places, which `docs/anti-patterns.md`-style DRY
concerns would otherwise flag; the helper's arity is 4 either way, so it carries none of
AC1's origin-separation burden itself — that burden lives entirely in
`persist_session_questions/5`'s arity and `materialize_session/5` never constructing a
merged list, both covered above.

## 4. How this satisfies AC1's "fail to compile or fail an obvious assertion" bar

**Exact mechanism: arity change, old shape deleted with no fallback.** Concretely: if a
future edit reverts to computing one merged `resolved` list in `materialize_session/5`
(e.g. re-adding `resolved_random ++ resolved_manual` before a shuffle, to "simplify") and
leaves the call site as `persist_session_questions(session_record.record_id, resolved,
candidate_id, prefix)` (4 arguments, matching the *pre-fix* shape), that call resolves to
`persist_session_questions/4` — which no longer exists anywhere in the module after this
fix (§3 deletes it outright, not conditionally). Elixir's compiler emits an "undefined
function `persist_session_questions/4`" diagnostic for that call at `mix compile` time.

This project's `mix letflow.check` alias (`mix.exs`, run by CI per
`.github/workflows/ci.yml`'s own inline comment: "`compile --warnings-as-errors`... `mix
letflow.check`") runs `compile --warnings-as-errors`, which promotes that
undefined-function diagnostic from a warning to a hard compile failure — i.e. the
literal "fail to compile" AC1 asks for, not a best-effort lint. There is no other
`persist_session_questions` clause of any other arity for such a call to silently
resolve to instead (Elixir does not do partial-application/currying dispatch across
different `defp` arities the way default-argument overloads might suggest) — so there is
no fallback merge path anywhere in the module for a future edit to accidentally take.

A future edit that keeps `resolved_random`/`resolved_manual` as two arguments but
reorders/reshuffles *within* one of them before the call (e.g. `Enum.shuffle(resolved_manual)`
inserted in `materialize_session/5`) would **not** be caught by the compiler — no design
in this shape category can catch a mutation to a single list's own contents at compile
time, only a wrong-shape/wrong-arity *merge*. This is the specific finding the issue
describes (concatenation-erases-origin), not the broader "no future logic bug is
possible" claim; TEST-DESIGNER already has an existing property/example test
(`iss0722-...md` §7) asserting manual-block order is preserved regardless of
`shuffle_questions?`, which remains the assertion-level backstop for that narrower
in-block case, per AC1's own "or fail an obvious assertion" alternative clause.

## 5. Unchanged (explicitly, for RELEASE-VALIDATOR/REVIEWER scan-ability)

- `QuestionSetResolver` — module, types (`resolved_question/0`, `rule/0`,
  `question_row/0`), `resolve/5` — byte-for-byte untouched.
- `fetch_question_pools/2`, `fetch_manual_rules/2`, `fetch_manual_questions/2`,
  `fetch_pool_questions/2`, `fetch_option_ids/2` — untouched.
- `session_attrs` construction, `write_record("session", ...)` call, `session_view/1`
  call in `materialize_session/5` — untouched.
- `write_record("session_question", attrs, actor_id, prefix)`'s own `attrs` shape
  (`session_id`, `question_id`, `sort_order`, `options_order`) — untouched, just now
  built inside `write_question_rows/4` instead of inline in
  `persist_session_questions/4`.
- Final `sort_order` values, `options_order` shuffling, block ordering
  (random-block-first per `iss0722-...md` §4.2) — all identical to current behavior
  (AC2).

## 6. Open questions

None. Every acceptance criterion maps to a concrete element above: AC1 → §3/§4 (arity
change, deleted fallback, `--warnings-as-errors` enforcement); AC2 → §2/§5 (sort_order
and shuffle-semantics equivalence argued explicitly, nothing else touched).
