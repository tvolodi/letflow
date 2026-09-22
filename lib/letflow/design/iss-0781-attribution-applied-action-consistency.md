# ISS-0781 — attribution row and applied action must agree for an already-resolved artefact

Fixes `docs/issues/ISS-0781.yaml` (MINOR, GH-1714, Q-780). Amends REQ-380's design
(`lib/letflow/design/req380-pack-update-review-apply-api.md` §4.3, §9 OQ-3) — this
document does not re-litigate REQ-380 in full, only the specific inconsistency ISS-0781
names.

## 1. The defect, restated precisely

`Letflow.Definitions.SolutionPack.apply_pack_update/6` runs, per call, inside one
transaction (`run_apply_update/8`):

1. `insert_submitted_resolutions/6` — insert-if-absent (`on_conflict: :nothing`,
   conflict target `[:tenant_id, :pack_id, :target_version, :artefact_type,
   :artefact_id]`) every resolution this call submitted. **Correctly immutable**: a
   second call submitting a different `resolution` for an already-resolved tuple is a
   silent no-op on the row.
2. `Definitions.compute_pack_update_plan/5`, re-run inside the same transaction, so it
   read-your-writes step 1's inserts. For each `:conflict`-classified entry, `resolved`
   is set by `resolution_exists?/5` (`lib/letflow/definitions.ex:513-521`), which is a
   **fresh `Repo.get_by/2` against the persisted row** — it does not consult this call's
   own `resolutions` argument at all.
3. `apply_plan_entries/6` → `apply_entry/6`. For a `:conflict` entry, `apply_entry/6`
   (the clause at `solution_pack.ex:757-783`) calls `find_submitted_resolution/2`
   (`solution_pack.ex:785-787`) — **this call's own `resolutions` list, checked first**
   — and only falls back to reading the persisted row
   (`apply_from_persisted_resolution/5`, `solution_pack.ex:789-812`) when the artefact
   is absent from this call's own submission.

Step 2 and step 3 disagree about *which* resolution determines outcome for an
already-resolved artefact revisited with a different submission on a later call: step 2
(the thing that decided the entry counts as "resolved" at all, per `resolution_exists?/5`)
already uses the persisted row as sole source of truth; step 3 (the thing that decides
what the call actually *does* to the tenant's base content) uses the call's own
just-submitted, not-actually-persisted value instead. The persisted attribution row (who
resolved it, how, when) and the actual state mutation performed under that entry
disagree, even though both nominally exist because of "the same" resolved conflict.

This is the inconsistency to close — not a new design decision floated independently of
REQ-380, but restoring agreement between two paths (§4.3 step 4's `resolved` computation
and step 6's action computation) that were supposed to be reading the same fact and
silently aren't.

## 2. Decision: option (a) — applied action always follows the persisted row

**Chosen.** Once a `pack_update_resolutions` row exists for
`(tenant_id, pack_id, target_version, artefact_type, artefact_id)`, it is the *sole*
source of truth for both (i) whether the artefact counts as resolved (already true today,
via `resolution_exists?/5`) and (ii) what applied action results (currently wrong, via
`find_submitted_resolution/2`). A later call's differing submission for that same tuple
continues to no-op at the DB layer (unchanged from today — REQ-380 OQ-3's
immutability-of-first-attribution stands) **and now also has no effect on the applied
action**: the base is advanced (or left unchanged) according to the *first* resolution
ever persisted for that tuple, never a later call's differing one.

### Why this is the right fix, not just the safest guess

REQ-380's own design (§9 OQ-3) already committed to immutability-of-first-attribution as
the deliberate, disclosed choice for the row, precisely because "immutable attribution is
the safer default for an audit trail." Making the *action* diverge from that same
attribution defeats the reason immutability was chosen in the first place — an immutable
row is only trustworthy as a record of what happened if it actually is a record of what
happened. Option (a) is the minimal change that removes the divergence introduced by
`apply_entry/6` reading a different source of truth than `resolution_exists?/5` already
reads, rather than a new behavioural surface.

### Rejected: option (b) — allow supersession, update the row

Rejected. This is a materially larger change than ISS-0781's MINOR severity and REQ-380's
own scope justify: it requires (i) switching `insert_submitted_resolutions/6` from
`on_conflict: :nothing` to a replace strategy, (ii) deciding whether overwriting
`resolved_by`/`resolved_at` in place destroys forensic value (a later auditor could no
longer tell a correction happened, or who made the original call, without a separate
history table), and (iii) very likely a new `pack_update_resolution_history`-shaped table
plus migration to preserve that forensic value — which turns a MINOR consistency bug into
a new schema surface requiring its own REQ, SECURITY-REVIEWER pass on the new table
(INV-1 scoping), and design review. Nothing in ISS-0781 or REQ-380's AC set asks for a
"change your mind" flow; inventing one to fix a consistency bug is scope creep the issue
itself doesn't justify. If product later wants real resolution correction, that's a new
REQ built on top of a now-consistent baseline, not bundled into this fix.

### Rejected: option (c) — reject a later differing submission outright

Rejected. It is a legitimate alternative in the abstract, but it changes the *external*
API contract (a new `{:error, ...}` outcome from `apply_pack_update/6` /
`update-apply` HTTP-visible failure mode) for a case REQ-380's AC set never exercises,
and it does not actually need to change anything about the module's current row
immutability — it would only add a new failure branch in front of the exact same
persisted-row read option (a) already needs. It also forces a caller to distinguish
"differing resubmission" from "identical resubmission" (the latter must keep succeeding
silently — resubmitting your own already-applied `keep_local` decision is not an error
today and there's no reason to make it one), meaning `apply_entry/6`'s `:conflict` branch
would still need to compare the current call's submission against the persisted row byte-
for-byte to decide error-vs-no-op — strictly more logic than option (a), for a behavior
nothing currently requires. If a future requirement wants a hard-reject UX (e.g. to
surface "someone else already resolved this differently" to the caller as an explicit
error rather than silently applying the first decision), that can be layered on top of
option (a)'s now-consistent baseline without contradicting it.

## 3. Exact behavioural change

### 3.1 `apply_entry/6` — `:conflict` clause (`lib/letflow/definitions/solution_pack.ex:757-783`)

Current shape (prose, not code): on a `:conflict` entry, check `find_submitted_resolution/2`
against this call's own `resolutions` argument first; only when that returns `nil` (the
artefact absent from this call's submission), fall back to
`apply_from_persisted_resolution/5` (a fresh `Repo.get_by/2` against
`PackUpdateResolution`).

New shape: on a `:conflict` entry, always resolve action via a persisted-row read —
`apply_from_persisted_resolution/5`, unconditionally, dropping the
`find_submitted_resolution/2` branch entirely. This is sound because
`insert_submitted_resolutions/6` (step 1, §1 above) always runs earlier in the same
transaction, so by the time `apply_entry/6` runs:

- **First-ever submission for the tuple**: step 1 just inserted the row (this call's own
  values) inside this same transaction. The persisted-row read sees it immediately
  (read-your-writes within one transaction — no isolation-level concern, same reasoning
  REQ-380 design §4.3 step 4 already relies on for `resolution_exists?/5`). Net effect:
  identical observable behavior to today for the first-ever call — the action still
  reflects what this call submitted, because what this call submitted is now what's
  persisted.
- **Later, differing submission for an already-resolved tuple**: step 1's insert is a
  silent `on_conflict: :nothing` no-op (unchanged). The persisted-row read returns the
  *original* row (first actor's resolution). Net effect: the action now matches the
  first-ever call's decision, not this call's differing one — closing ISS-0781.
- **Later, identical (re-)submission for an already-resolved tuple**: no observable
  change — the persisted row already held that value, so reading it back yields the same
  action as before.

`find_submitted_resolution/2` (`solution_pack.ex:785-787`) becomes dead code once this
lands and should be deleted, not left unreferenced. The `resolutions` parameter threaded
into `apply_entry/6`'s `:conflict` clause and `apply_plan_entries/6` becomes unused for
that clause; rename to `_resolutions` there (the other three `apply_entry/6` clauses —
`:unchanged`, `:local_only`, `:clean_update` — already ignore it, consistent with this
change). Do not remove the parameter from the function head — `apply_plan_entries/6`
calls all four clauses positionally with the same argument list, and REQ-380's design
already established that shape; changing arity is unrelated churn ISS-0781 doesn't
require.

No other function in `solution_pack.ex` changes. `insert_submitted_resolutions/6` is
untouched — its `on_conflict: :nothing` immutability is correct and stays exactly as
REQ-380 OQ-3 decided; this fix does not touch write semantics of the row itself, only
which row the *action* consults.

### 3.2 `apply_from_persisted_resolution/5` — unchanged in shape, now the only path

No change to this function's body. It already does exactly the right thing (reads the
persisted row, dispatches on `resolution`/`resolved_content`); it simply becomes the
unconditional path for every `:conflict` entry instead of a fallback reached only when
the current call submitted nothing for that artefact. Its existing `@spec` (if any) and
error handling (via `advance_base/6`'s own `with`) need no change.

### 3.3 `@spec`/typedoc changes

`apply_entry/6`'s typedoc/comment above the `:conflict` clause (currently: "Guaranteed
`resolved == true`... either among this call's own `resolutions`... or from an earlier
call") must be updated to state plainly: the applied action is always determined by the
persisted resolution row, which by construction already reflects either this call's
just-inserted submission (first-ever case) or an earlier call's (already-resolved case) —
never this call's own submission when it differs from an earlier persisted one. No
`@spec` type signature changes — `apply_pack_update/6`'s public contract
(`apply_result()`, `applied_entry_map/2`'s shape) is unaffected; this is purely an
internal control-flow fix, not an API shape change.

## 4. Existing regression test — required changes

`test/letflow/routers/solution_packs_update_test.exs:439-551`
(`describe "Regression: a resolved artefact's attribution is immutable (on_conflict:
:nothing)"`) currently documents and asserts the OLD, buggy contract at lines 531-550: it
explicitly asserts `entry["action"] == "advanced_to_incoming"` (line 546),
`base_after.base_content == incoming_content` (line 549), **and**
`base_after.base_version == target_version` (line 550) for the SECOND call, i.e. it
asserts the second call's differing submission governs the action — exactly the
behavior ISS-0781 says must stop. All three assertions belong to the same buggy-contract
block and all three must change together; line 550 is not a separate, unrelated
assertion and is explicitly in scope alongside lines 546 and 549.

Required change: replace the "what the immutability claim does NOT cover" block
(lines 531-550 inclusive, from the comment through all three closing assertions) with
assertions matching the corrected contract — action, base content, AND base version must
now all track the **first** call's `keep_local` resolution, not the second call's
`take_incoming` submission:

- `entry["action"]` (from `second_body_json`, same `entry_for(second_body_json,
  artefact_id)` lookup already used) must now assert `== "left_unchanged"` (the FIRST
  call's `keep_local` resolution's action), not `"advanced_to_incoming"`.
- `fetch_base(tenant.tenant_id, pack_id, artefact_type, artefact_id)` must now assert
  `base_after.base_content == theirs_content` (unchanged from whatever the base held
  going into this test — since `keep_local` performs no write per `apply_entry/6`'s
  `:unchanged`-classification/`left_unchanged`-action path, the base's `base_content`
  stays whatever `insert_base!/6` set it to at line 455, i.e. `base_content`, the
  original fixture variable — **not** `theirs_content`; re-check against the actual base
  row the test seeds, `insert_base!(tenant.tenant_id, pack_id, artefact_type,
  artefact_id, "1.0.0", base_content)` at line 455, so the correct assertion is
  `base_after.base_content == base_content`, the untouched original, since `keep_local`
  never calls `advance_base/6` at all).
- `base_after.base_version` must now assert `== "1.0.0"` (the literal version string
  `insert_base!/6` seeded at line 455), **not** `target_version` (`"2.0.0"`).
  `advance_base/6` is the only place `base_version` is ever written
  (`solution_pack.ex`, `advance_base/6`'s `attrs` map sets `base_version:
  target_version`), and under the corrected contract `advance_base/6` is never called at
  all across either the first call (`keep_local` → `:left_unchanged`, no write) or the
  second call (now also resolved via the persisted `keep_local` row →
  `:left_unchanged`, no write) — so the base row's `base_version` column is never
  touched by this test's two apply calls and stays exactly what `insert_base!/6` set it
  to before either call ran. Asserting `target_version` here (as the current test does)
  is only true under the OLD buggy contract, where the second call's own
  `take_incoming` submission drove an `advance_base/6` call that stamped
  `base_version: target_version` — that write path no longer executes at all once the
  fix lands, so this assertion is not merely wrong-value but wrong-code-path, and must
  change together with the other two, not independently.
- The comment block explaining this (lines 531-544) must be rewritten to state the
  corrected contract: the second call's differing submission has **no effect on the
  applied action either**, not just no effect on the persisted row — attribution and
  applied action (including every field `advance_base/6` would otherwise have written:
  `base_content` and `base_version` alike) are now both governed by the first-ever
  persisted resolution, consistently.
- The `describe` block's own title (line 439, `"Regression: a resolved artefact's
  attribution is immutable (on_conflict: :nothing)"`) should be widened, e.g.
  `"Regression: a resolved artefact's attribution AND applied action are both immutable
  (first-decision-wins)"` — the old title undersells what's now guaranteed.
- The test name itself (line 440) stays accurate as-is (it only claims the row-level
  guarantee) but a second `test` in the same `describe` (§4.2 below) is needed to name
  the action-level guarantee explicitly, since ISS-0781 was found precisely because that
  half wasn't under its own assertion with an unmistakable name.

Everything else in the existing test (lines 441-530: fixture setup, first call, the
row-immutability assertions themselves) is unaffected and stays as-is — those assertions
already describe the row-level contract this fix does not change.

### 4.1 Why the row-level assertions (lines 483-529) need no change

`insert_submitted_resolutions/6` is untouched by this fix (§3.1 above) — the row
produced by the first call, and the no-op on the second call's insert, behave identically
before and after. Only the *consumption* of that row by `apply_entry/6` changes.

### 4.2 New test coverage needed

Add one new `test` inside the same (retitled) `describe` block, distinct from the
existing test, that makes the actual defect ISS-0781 reports impossible to reintroduce
silently even if a future change re-touches `apply_entry/6`'s `:conflict` clause without
touching the row-level test:

- **Test name**: something naming the exact property, e.g. `"a second apply call
  submitting a DIFFERENT resolution for an already-resolved artefact applies the FIRST
  call's resolution, not its own"`.
- **Setup, corrected (REVIEWER, WF03-ISS0781-20260922 gate)**: the reverse pairing as
  originally specified here — `take_incoming` first, identical resubmission of the same
  `incoming` second, `keep_local` on the second call — is **not reachable**.
  `run_apply_update/8` re-runs `compute_pack_update_plan/5` from scratch on every call,
  and by the second call `advance_base/6` has already written
  `base_content == incoming_content` from the first call. Re-submitting the *same*
  `incoming` on the second call makes `Definitions.classify_artefact/3`
  (`lib/letflow/definitions.ex:487-491`) see `base == incoming` and reclassify the entry
  as `:local_only`, not `:conflict` — the entry never reaches `apply_entry/6`'s
  `:conflict` clause (or `apply_from_persisted_resolution/5`) on the second call at all,
  so the scenario as literally specified above cannot exercise the code path it was
  written to test. ELIXIR-DEV hit this while implementing and left a `NOTE` at the
  corresponding point in `test/letflow/routers/solution_packs_update_test.exs`
  documenting the same finding, confirmed independently by SECURITY-REVIEWER during its
  ISS-0781 pass and again by REVIEWER here. The reachable fixture for this exact
  ordering, if it were added, would need the second call's `incoming` to differ from
  *both* the new `base` (`incoming_content`, set by the first call) and `theirs` — a
  third distinct value, so `classify_artefact/3` still lands on `:conflict` on the
  second call.
- **Resolution — no separate reverse-pairing test required.** The concern the reverse
  pairing was meant to guard against — a future regression silently defaulting
  `apply_entry/6`'s `:conflict` clause to `:left_unchanged` (e.g. a swallowed exception
  falling through to a default branch) so that a `keep_local`-first test could pass for
  the wrong reason — is already fully covered by the `:merged` test below (§4.2, second
  bullet): its first call asserts `action == "advanced_to_merged"` (ruling out a
  silent default-to-`:left_unchanged`), and its second call asserts the action, content,
  and version *all* still match the first call's `:merged` resolution despite a
  differently-shaped second submission (`take_incoming`). Because the fixed
  `apply_entry/6` clause takes an unconditional `_resolutions`-ignoring path — it no
  longer dispatches on the current call's submitted resolution value at all — there is
  no code branch left that could distinguish a second submission of `keep_local` from
  one of `take_incoming`; both are equally ignored by construction. A dedicated
  `take_incoming`→`keep_local` test would add no additional branch coverage over what
  the existing (extended) `keep_local`→`take_incoming` test and the new `:merged` test
  already establish together — one proves a persisted no-write resolution survives a
  differing write-shaped resubmission, the other proves a persisted write-with-
  independent-content resolution survives one too. Do not add the reverse-pairing test;
  the two tests already present are sufficient coverage of the underlying property.
- **Also cover `:merged`**: a third resolution kind exists (`merged` with
  `resolved_content`). Add (or extend the pair above into a triple) a case where the
  first call resolves `merged` with specific `resolved_content`, and the second call
  submits a different resolution kind (e.g. `take_incoming`) for the same tuple — assert
  the second call's action is `"advanced_to_merged"` with the FIRST call's
  `resolved_content` **and** `base_after.base_version == target_version` (same
  reasoning as the reverse-pairing case above: `advance_base/6`'s `:merged` branch also
  stamps `base_version: target_version` on both the first call's original write and the
  second call's idempotent re-write), not the second call's `incoming_content`. This is
  the case most likely to regress silently, since `:merged`'s `resolved_content` is data
  carried on the resolution row itself (not derivable from `entry.incoming`), making it
  the clearest demonstration that the action must read the persisted row's full content,
  not just its resolution-kind tag.

**General rule for all three tests (the existing one and both new ones in §4.2), stated
explicitly so TEST-DESIGNER cannot omit it the way the pre-fix version of this design
did**: every assertion this design specifies for `entry["action"]` and
`base_after.base_content` must be paired with an assertion of `base_after.base_version`
in the same test, because `base_version` is written by exactly the same
`advance_base/6` call (or not written at all, when the action is `:left_unchanged`) that
determines `base_content` — the two fields are never allowed to be checked
independently of each other in this test file, and a test that asserts one without the
other is incomplete under this design.

All three new/extended tests belong in
`test/letflow/routers/solution_packs_update_test.exs`, in the same describe block as the
existing regression test (co-locating the row-level and action-level guarantees for this
same defect makes the file easier to audit against ISS-0781 later), using the same
helpers already present in that file (`build_conn/3`, `artefact_input/3`, `insert_base!/6`,
`resolution_rows/3`, `entry_for/2`, `fetch_base/4`, `cleanup_pack_update_tables!/1`,
`unique/1`) — no new test helpers are needed.

## 5. Security review carry-forward

SECURITY-REVIEWER's REQ-380 pass already established (per REQ-380's own design doc and
merge history) that both calls in the two-call scenario originate from the tenant's own
authenticated, permission-gated caller — no cross-tenant or unauthorized-actor path is
introduced by the two-call sequence itself. This fix does not add a new caller, a new
route, a new table, or a new field — it only changes which already-tenant-scoped,
already-`:prefix`-qualified row `apply_entry/6` reads to decide an action it was always
going to take for an already-classified `:conflict` entry within the same tenant. INV-1
(tenant data isolation): unaffected — `apply_from_persisted_resolution/5`'s
`Repo.get_by/2` already runs with the same tenant-scoping the rest of the module uses
(`tenant_id` is one of the lookup keys, per `PackUpdateResolution`'s composite key), and
this fix does not change that. INV-6 (new data-access paths prove scoping): does not
apply — no new data-access path is introduced; `apply_from_persisted_resolution/5`
already existed and was already an approved data-access path in REQ-380's own gate. No
BLOCKER-severity invariant is implicated. Confirmed as still holding, not re-derived from
scratch, since ISS-0781 itself states this is severity MINOR and not a
privilege-escalation finding, and nothing in this design contradicts that.

## 6. Open questions

None. Unlike REQ-380 §9 OQ-3 (which flagged the row's immutability as a disclosed,
unresolved-by-test design choice), this fix has an unambiguous target: make `apply_entry/6`
consult the same source of truth `resolution_exists?/5` already treats as canonical.
There is no remaining design choice for ELIXIR-DEV to make beyond following §3 above
mechanically.
