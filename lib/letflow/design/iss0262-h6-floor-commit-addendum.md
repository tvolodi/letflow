# Addendum: ISS-0262 H6 — commit-boundary floor replaces per-file grandfathering

**Run:** `WF03-ISS0262-20260822` · Step 8 CHANGE-APPROACH rework (rework_count 2) ·
**Author:** CODE-DESIGNER · **Status:** proposed — awaiting CODE-DESIGN-VALIDATOR

**Relationship to the original design
(`lib/letflow/design/iss0262-lint-handoffs-non-json-discovery.md`):** §§1, 2, 4.1-4.3,
4.5, 5, 6, 7 of that document are UNCHANGED and still govern (discovery glob,
`handoff_kind/1`, violation shape, moduledoc, backward compatibility, test-fixture
shape, files touched). **This addendum supersedes §3 and §3.1 only** — the "grandfather
the 10 files individually" ruling — and touches nothing in H1-H4's mechanism. Where the
two documents would otherwise disagree, **this addendum governs for H6**; the original
§3/§3.1 stays in place as a historical record of the ruling that Step Final's two FAILs
(`step-final-git-merge.json`, `step-final-git-merge-retry1.json`) proved insufficient,
not as a live rule. No implementation code appears below — `@spec` lines, one module
attribute declaration, git command literals, and pseudocode (`case`/`with` shapes) only.

---

## 0. Why the per-file list cannot work, restated precisely (not re-litigated)

Both Step Final FAILs are the same root cause with different files: H6 fires on every
non-JSON `step*.*` file that has *ever* existed under `handoffs/`, and `@grandfathered`
only exempts files enumerated at design time. Two unrelated, already-merged runs
(`WF03-ISS0261-20260822`, then `WF03-ISS0260-20260822`) each landed new non-JSON handoff
files on `main` *after* this branch's design/implementation, and *before* this branch's
own merge — because `main` is a moving target this branch does not control. A per-file
list is definitionally always exactly caught up to the moment it was last edited, never
to the moment the branch actually merges. Re-running "add N more entries, retry" is not
a fix; it recurs for as long as any other run can land a handoff-shaped non-JSON or
malformed file on `main` faster than this list is edited — which, per the two FAILs, is
"always," since editing the list requires a full ISSUE-FIXER → CODE-DESIGNER → ELIXIR-DEV
→ Step-Final round-trip that is itself slower than a single concurrent PR merge.

**The fix is structural, not enumerative: replace "is this exact path on a list" with
"did this path's content exist in git history before H6 started enforcing."** Everything
that predates H6's own activation is automatically exempt, with no list to fall behind;
everything introduced from H6's activation onward is not exempt, with no list to forget
to update.

---

## 1. The mechanism: `@h6_floor_commit` + git-history ancestry, not a path list

### 1.1 The module attribute (**RULING**)

```
@h6_floor_commit "TBD-AT-MERGE"  # see §2 for how/when this literal is set; the value
                                  # committed in the PR that actually lands successfully
                                  # is the only one that matters (§2.3)
```

Same shape and same resolution pattern as the existing `@artifacts_out_rule_commit`
(`lint_handoffs.ex:107`) — a literal sha, resolved once via git, cached per-run. **Not**
reused as the *same* constant: `@artifacts_out_rule_commit` names the commit that landed
a *different* rule (ISS-0202's WARN, in `48a4a55`, already merged and stable long before
H6 exists) and must not be repointed at H6's floor — the two checks have independent
floors because they were introduced at different times for different reasons. A second,
independent constant is added, not a shared one repurposed.

### 1.2 Determining "did this file's content already exist before the floor" — exact algorithm

```
@spec pre_floor_file?(path :: String.t(), floor :: String.t()) :: boolean()
```

Two git calls, in order:

**Step A — find the file's first-ever appearance in history:**

```
git log --follow --diff-filter=A --format=%H --reverse -- <path>
```

`--diff-filter=A` restricts to commits that *added* the path (not every commit that
touched it); `--follow` tracks the path across any rename; `--reverse` orders oldest
first, so the **first line of output** is `first_add_sha` — the earliest commit in
history that introduced this file's content at this path (or a prior name `--follow`
traced it back to). **Empty output** means the path is not in git history at all yet
(a new, uncommitted file, e.g. a fixture just created in a test's working tree, or a
handoff file staged but not yet committed) — treated as "does not predate the floor"
(§1.4's fail-safe direction), because a file with no recorded history cannot possibly
predate anything.

**Step B — is that first-appearance commit at or before the floor:**

```
git merge-base --is-ancestor <first_add_sha> <floor>
```

Exit code `0` → `first_add_sha` is `floor` itself or an ancestor of it (git's
`--is-ancestor` is reflexive: a commit is its own ancestor) → the file's content
**already existed at or before the floor** → `pre_floor_file?` returns `true`. Exit code
`1` → not an ancestor → the file was introduced strictly after the floor → returns
`false`. Any other exit status (git error, e.g. unresolvable sha) → **fail-safe to
`false`** (§1.4).

### 1.3 Where this replaces the old call — `lint_file/2`'s `:non_json` branch

The existing `:non_json` branch (original design §4.2) called
`grandfathered?("H6", path)` to decide the violation's `grandfathered:` field. That call
is **replaced**, not supplemented, by `pre_floor_file?(path, @h6_floor_commit)`:

```
:non_json ->
  pre_floor = pre_floor_file?(path, @h6_floor_commit)

  violation_msg =
    "non-JSON handoff-shaped file: #{path} has extension #{inspect(Path.extname(path))}, " <>
    "expected .json (pre-floor: #{pre_floor}, floor commit: #{@h6_floor_commit})"

  v = violation(path, "H6", violation_msg, pre_floor)

  %{path: path,
    hard_new:          (if pre_floor, do: [], else: [v]),
    hard_grandfathered: (if pre_floor, do: [v], else: []),
    advisory: %{path: path, warnings: [], size_info: %{desc_len: 0, summary_len: 0}},
    parse_error: nil}
```

`grandfathered?/2` (the `{rule, path} in @grandfathered` list lookup, `:167-168`) is
**untouched as a function** and keeps governing H1/H2/H3 exactly as before (§4, task's
explicit "does not touch or weaken H1-H4" requirement). It is simply never called with
`"H6"` as the rule argument any more, because no `{"H6", _}` tuples remain in
`@grandfathered` after §3 below.

### 1.4 Fail-safe direction on git error (**RULING**, and why it differs from the existing WARN check's direction)

If either git call in §1.2 errors (non-zero/non-one exit, unparseable output,
`git` unavailable), `pre_floor_file?/2` returns **`false`** — i.e., treat the file as
**not** pre-floor, so it **hard-fails**. This is the opposite fail-safe direction from
the existing `created_at_after_rule?/1` (`:540-549`), which returns `false` (meaning
"not subject to the WARN") on git failure. That difference is deliberate, not an
inconsistency to reconcile: `ARTIFACTS_OUT_SELF_REF` is advisory-only, so erring toward
*silence* on a git failure is the conservative choice for a WARN. **H6 is a hard,
gating rule** — erring toward *silence* here would mean a git malfunction silently
exempts a file that might genuinely be a new regression, which is the failure mode this
whole rework exists to eliminate. Erring toward *failure* on git malfunction is the
conservative choice for a hard gate: it surfaces loudly (a build failure investigators
will look at) rather than quietly waving a potential regression through.

### 1.5 Memoization (mirrors the existing single-value cache, extended to per-path)

`fetch_rule_commit_timestamp/0` (`:563-573`) memoizes one value via
`Process.get/put(:artifacts_out_rule_floor, ...)`. §1.2's Step A is per-*path* (a `git
log` call per distinct non-JSON file encountered in one `run/1` invocation, typically a
low double-digit count), so `pre_floor_file?/2` memoizes per `{path, floor}` pair the
same way — `Process.get/put({:h6_pre_floor, path, floor}, ...)` — so a given handoff
run's ~1-2 dozen non-JSON files each pay the `git log`/`git merge-base` cost once, not
once per potential caller.

---

## 2. The floor commit: exact choice, and why it needs no write-back

### 2.1 The choice (**RULING**): the pre-merge tip of `origin/main`, captured at the moment this run's Step Final actually fetches it — not this fix's own landing commit

`HANDOFF_PROTOCOL.md`'s `commit_sha_list` section (`:464-572`) is the load-bearing
precedent the task points at, and its core finding is: **a commit cannot record its own
sha**, because the sha is only assigned once the commit is written, and the commit's
content is fixed before that. The section's resolution for a field that lives *inside*
a handoff needing to reference *that same handoff's own landing commit* is a deliberate,
optional second commit — a write-back — that records the commit **before** it, never
itself (`:524`: "record only the commit before it, and do not record the write-back").

**That exact shape transfers to H6 with one simplification, and this addendum adopts
it:** H6 doesn't need the floor to *be* this fix's own landing (squash-merge) commit —
it only needs the floor to be a commit that is a **strict ancestor** of whatever
squash-merge commit eventually lands this fix, old enough that every file predating H6's
activation is at-or-before it, and new enough that nothing this fix's own squash-merge
commit introduces counts as pre-floor. **The pre-merge tip of `origin/main` — i.e., the
exact commit `origin/main` points to right before this branch's squash-merge lands on
top of it — satisfies both properties and, unlike the squash-merge commit's own sha, is
fully known and resolvable *before* the merge happens**, because it already exists on
`main`. This is precisely "record the commit before it, not itself," restated for a
floor instead of a list entry — so **no write-back commit is needed at all**: the
self-reference problem `commit_sha_list` solves with an extra commit doesn't arise here,
because H6's floor was never asking to name the commit containing it in the first place.

### 2.2 Why the self-containment problem doesn't transfer structurally (answering the acceptance criterion directly)

`commit_sha_list` lives *inside* the very handoff JSON file whose own landing commit it
would need to name — the field and the commit that creates it are the same artifact.
**`@h6_floor_commit` does not have this property.** It lives in
`lib/mix/tasks/letflow.lint_handoffs.ex`, a file with no relationship to *which handoff
files* are being classified by H6 — the files H6 evaluates live under `handoffs/`, a
disjoint set from the one file that carries the floor constant. There is therefore no
literal self-containment obstacle for H6 the way there is for `commit_sha_list`; the
only obstacle H6 has is **timing** — not knowing, at the moment code is written, which
future commit will be the successful squash-merge. §2.1's choice (use the ancestor
already on `main`, not the not-yet-existing squash commit) removes the timing obstacle
too, by never needing to name the not-yet-existing commit at all.

### 2.3 The operational step this requires at Step Final (exact mechanism for whoever executes `GIT_MERGE.md` on this branch)

`GIT_MERGE.md` step 4 (fetch `origin main`) already, in practice, produces a fetched tip
sha — both prior Step Final attempts recorded it in their own summaries verbatim
("fetched origin main (tip fb5c251)", then "fetched origin main (tip 96ac42f)" on the
retry). This addendum's operational requirement, to be carried out by whoever runs the
next Step Final attempt on this branch (ELIXIR-DEV, per the existing dispatch pattern):

1. **Step 4 (fetch):** record the fetched `origin/main` tip sha. Call it `FLOOR`.
2. **Before step 5's checks run** (i.e., as an ordinary content commit on the branch,
   which becomes part of the eventual squash): edit `@h6_floor_commit` in
   `lib/mix/tasks/letflow.lint_handoffs.ex` to the literal `FLOOR` value, and commit
   that edit normally.
3. Continue `GIT_MERGE.md` unchanged from there: rebase (already done by step 4/5 in
   the existing flow), format/compile/test/`mix letflow.lint_handoffs` (H6 now correctly
   passes on every handoff file that exists anywhere in history up to `FLOOR`, with zero
   per-file entries required — including whatever `WF03-ISS0260-20260822` and
   `WF03-ISS0261-20260822` already landed, and anything else that landed on `main`
   between this run's earlier attempts and now), push, PR, squash-merge, local cleanup.
4. **If the push/merge is rejected as non-fast-forward** (main moved again during this
   attempt — the exact race this rework exists to close), the retry redoes steps 1-2
   with a freshly fetched tip before its own push. This is not a new step shape; it is
   the same fetch-rebase-check-push loop already visible across
   `step-final-git-merge.json` → `step-final-git-merge-retry1.json`, with one line added
   (refresh `@h6_floor_commit` to the just-fetched tip) before the checks run each time.

**Why this is safe against the race, not merely convenient:** because `FLOOR` is
re-captured at the start of whichever attempt actually succeeds, `FLOOR` is *always* the
immediate parent of the squash-merge commit that finally lands — by construction, since
`origin/main`'s tip at fetch time is exactly what the rebase replays this branch onto,
and the eventual squash-merge commit's sole parent is that same tip. There is no window
in which `FLOOR` can end up *newer* than the actual merge base, and the only way it can
end up *stale* (older than the real, final pre-merge tip) is if yet another run lands
between this attempt's fetch and its own push — which `GIT_MERGE.md`'s existing
non-fast-forward rejection already detects and forces a retry for, at which point step 4
of a new attempt refreshes `FLOOR` again. The mechanism is self-correcting across
retries, which is the property the per-file list never had.

### 2.4 Re-verifying the acceptance criterion: a file added to `main` AFTER the floor must still hard-fail

Concretely: suppose, after this fix's squash-merge lands at commit `M` (parent `FLOOR`),
some later run `X` lands a new non-JSON `step-*.md` file on `main` at commit `N` (a
descendant of `M`, hence of `FLOOR`). For that file, §1.2 Step A finds
`first_add_sha = N`. Step B evaluates `git merge-base --is-ancestor N FLOOR` — `N` is a
*descendant* of `FLOOR`, not an ancestor of it (and `N ≠ FLOOR`), so `--is-ancestor`
exits `1` → `pre_floor_file?` returns `false` → the violation lands in `hard_new`, not
`hard_grandfathered` → **it fails the build**, exactly as H6 is supposed to for anything
new, with zero list maintenance. This is the property the per-file list could never
guarantee (it depended on someone remembering to *not* add a future file to the list;
under this mechanism there is no list to accidentally add it to).

---

## 3. Disposition of the 12 existing `{"H6", path}` `@grandfathered` entries (**RULING: remove, no overlap left in place**)

**Removed, not kept.** All 12 `"H6"`-tagged entries currently in `@grandfathered`
(`lint_handoffs.ex:153-164` — the original 10 `WF03-ISS0258-20260822` files plus the 2
`WF03-ISS0261-20260822` files added by the retry-1 rework) are **deleted from the list**
as part of this fix. The commit-boundary rule in §1-§2 subsumes them completely: every
one of those 12 files was committed to `main` long before whatever `FLOOR` this fix's
own successful Step Final attempt resolves to, so each is `pre_floor_file?/2 == true`
automatically, with no list entry needed. **No overlap is left silently in place** —
after this fix, `grandfathered?("H6", _)` is never called (§1.3), so a stale `"H6"`
entry left in the list would be simply dead data, not a second mechanism quietly
co-governing the same rule. Removing it is what keeps that statement true; leaving it
would misdescribe the mechanism to a future reader of the `@grandfathered` list, who
would otherwise reasonably conclude H6 is still list-governed.

**What stays, and why it's a strictly different thing:** the 6 pre-existing `"H1"`/`"H2"`/
`"H3"` entries (`:147-152`) are untouched, per the task's explicit instruction and
because they are a genuinely different mechanism this fix does not touch — H1-H4 have no
commit-boundary equivalent proposed here, and nothing about §1-§2 changes how they are
evaluated.

**The historical record is not lost:** it moves from being an *active* list entry to
being *prose* — §3 of the original design doc (this addendum's §0 restates why it
failed) plus this section, plus the two Step Final FAIL handoffs' `result.summary`
fields (already committed, immutable history per `HANDOFF_PROTOCOL.md`'s append-only
rule) together document exactly which files were involved and why, for anyone who later
wants to know "why doesn't `@grandfathered` mention `WF03-ISS0258-20260822` any more" —
the answer is discoverable, not silently erased.

### 3.1 Exact edit to `lib/mix/tasks/letflow.lint_handoffs.ex` (data, not code)

**Delete** these 12 lines from `@grandfathered` (currently `:153-164`):

```
{"H6", "handoffs/WF03-ISS0258-20260822/step-01-issue-fixer.md"},
{"H6", "handoffs/WF03-ISS0258-20260822/step-02-code-designer.md"},
{"H6", "handoffs/WF03-ISS0258-20260822/step-02b-code-design-validator.md"},
{"H6", "handoffs/WF03-ISS0258-20260822/step-03-elixir-dev-MISSING-RETRACTED.md"},
{"H6", "handoffs/WF03-ISS0258-20260822/step-03-elixir-dev.md"},
{"H6", "handoffs/WF03-ISS0258-20260822/step-03b-security-scope-test.md"},
{"H6", "handoffs/WF03-ISS0258-20260822/step-03c-reviewer.md"},
{"H6", "handoffs/WF03-ISS0258-20260822/step-04-test-designer.md"},
{"H6", "handoffs/WF03-ISS0258-20260822/step-04b-test-design-validator.md"},
{"H6", "handoffs/WF03-ISS0258-20260822/step-04c-test-design-validator-regate.md"},
{"H6", "handoffs/WF03-ISS0261-20260822/step-01-issue-fixer.md"},
{"H6", "handoffs/WF03-ISS0261-20260822/step-03c-reviewer.md"}
```

**Replace** the two comment blocks documenting them (`:132-145`, the 2026-08-22
ISS-0262 paragraphs) with one paragraph stating the supersession, in the same dated,
traced style the rest of the comment block already uses:

> 2026-08-22, ISS-0262 Step 8 change-approach rework (rework_count 2): H6 no longer uses
> per-file grandfathering. The 12 entries previously here (10 from
> `WF03-ISS0258-20260822`, 2 from `WF03-ISS0261-20260822`) are removed — H6 is now
> governed entirely by the `@h6_floor_commit` commit-boundary rule (a file whose content
> predates that floor in git history is automatically exempt; a file introduced at or
> after it always hard-fails). See
> `lib/letflow/design/iss0262-h6-floor-commit-addendum.md` for the mechanism and why the
> per-file list could not keep pace with `main`. H1-H3's grandfathering below is
> unaffected by this change.

**No entries are added** to `@grandfathered` for the 9 new violations
`step-final-git-merge-retry1.json` found under `WF03-ISS0260-20260822`
(7× H6, 1× H1, 1× H3) — those H6 hits are subsumed the same way as the 12 above once
`@h6_floor_commit` is set; the 1× H1 and 1× H3 hits on
`WF03-ISS0260-20260822/step-04d-test-design-validator-recheck.json` are **not** in this
fix's scope to grandfather (H1/H3's mechanism is untouched per the task's instruction) —
if they still reproduce on the next Step Final attempt, they route to ISSUE-FIXER as a
normal H1/H3 finding, on their own merits, separately from this H6 rework.

---

## 4. Moduledoc update (supersedes original design §4.5 for the H6 bullet specifically)

The "### Hard" list's H6 bullet (originally added per the first design's §4.5) is
restated to describe the commit-boundary mechanism instead of per-file grandfathering:

> * **H6** — every discovered handoff-shaped file (basename starts with `step`) is JSON.
>   A non-`.json` file is a discovery-completeness defect in its own right. **Unlike
>   H1-H4, H6 is not grandfathered by an explicit file list** — a file whose content
>   already existed in git history at or before `@h6_floor_commit` is automatically
>   exempt (reported, does not fail the build); a file introduced after that floor
>   always fails the build. See `@h6_floor_commit`'s own comment and
>   `lib/letflow/design/iss0262-h6-floor-commit-addendum.md` for why.

The surrounding paragraph ("This module contains no wildcard or pattern-based
grandfathering...") gains one clause noting H6 is the one exception to that statement,
governed by the commit-boundary rule instead — so the moduledoc does not misdescribe its
own mechanism to a reader who only reads the top-level prose.

---

## 5. Files touched (supersedes/extends original design §7 for this addendum's scope)

| File | Change |
|---|---|
| `lib/mix/tasks/letflow.lint_handoffs.ex` | New `@h6_floor_commit` attribute (§1.1); new `pre_floor_file?/2` (§1.2) with its two `System.cmd("git", ...)` calls and per-`{path, floor}` memoization (§1.5); `lint_file/2`'s `:non_json` branch calls `pre_floor_file?/2` instead of `grandfathered?("H6", path)` (§1.3); `@grandfathered`'s 12 `"H6"` entries deleted, comment block replaced (§3.1); moduledoc H6 bullet + surrounding paragraph restated (§4) |
| `test/mix/tasks/letflow.lint_handoffs_test.exs` | TEST-DESIGNER's new assertions for `pre_floor_file?/2` (§6) — existing H1-H4/PARSE tests remain green unchanged; any existing test asserting the old 12-entry `"H6"` grandfather behavior must be rewritten against the new mechanism, not deleted silently |
| **Operational, no file diff in this repo:** whoever runs the next Step Final attempt on `feature/WF03-ISS0262-20260822` | Must perform §2.3's fetch-then-set-`@h6_floor_commit` step before running post-rebase checks, each attempt, until one succeeds |

**Not touched:** everything the original design's §7 already scoped out (`mix.exs`,
`check_registry_coverage/1`, any other Mix task or `lib/letflow/*` application code).
**Also not touched by this addendum:** `docs/agents/protocols/GIT_MERGE.md` itself — §2.3
states the operational requirement precisely enough for ELIXIR-DEV to follow without a
protocol-doc edit, but whether `GIT_MERGE.md` should gain a generic clause for "refresh
any floor-commit constant a branch's diff introduces, using the fetched tip, before
running checks" (so a future floor-commit-style fix doesn't have to restate this) is left
to ORCH as a separate, smaller follow-up — raising it here would widen this rework past
H6's own mechanism, which is the same discipline the original design's OQ-2 already
applied to a different smaller question.

---

## 6. Test-fixture guidance for TEST-DESIGNER (supersedes original design §6 where it conflicts)

`pre_floor_file?/2` takes `floor` as an explicit parameter (§1.2's signature), which
means it is testable **without needing the real, still-unresolved `@h6_floor_commit`**
and without any synthetic git fixture tree — by pointing it at real, already-existing
commits in this repository's own history:

1. **Pre-floor case (`true`):** pick any long-stable, long-committed file (e.g.
   `mix.exs`) and a recent `floor` (e.g. the current `HEAD`, resolvable via
   `git rev-parse HEAD` in the test's setup). `mix.exs`'s first-add commit is far older
   than `HEAD`, so `pre_floor_file?("mix.exs", floor)` must be `true`.
2. **Post-floor case (`false`):** pick this very fix's own new file/content (e.g.
   `lib/mix/tasks/letflow.lint_handoffs.ex`'s `pre_floor_file?/2` addition, or simpler,
   this addendum document's own path) and a `floor` fixed to an early, well-known
   ancestor commit from long before this branch existed (e.g. resolve
   `git rev-list --max-parents=0 HEAD` for the repo's root commit, or any other commit
   from before ISS-0262's own run started — the fix's own new lines did not exist at
   that ancestor). `pre_floor_file?(path, old_floor)` must be `false`.
3. **The "added after floor, must still hard-fail" acceptance criterion (§2.4), proved
   directly:** using the same `old_floor` from case 2, call `lint_file/2` against
   `lib/mix/tasks/letflow.lint_handoffs.ex` itself is not meaningful (it's `.ex`, not a
   `handoffs/step*.*` file) — instead, TEST-DESIGNER points `lint_file/2` at a fixture
   under `test/fixtures/lint_handoffs/h6/` (original design §6.1's fixture, kept
   unchanged) with `pre_floor_file?`'s `floor` argument threaded through as `old_floor`:
   since that fixture file's own first-add commit (whenever it is committed as part of
   this fix) postdates `old_floor`, the assertion `result.hard_new` (not
   `hard_grandfathered`) holds — proving the "new file always hard-fails" property
   directly, deterministically, and independent of whatever the real
   `@h6_floor_commit` eventually resolves to.
4. **A real grandfathered-by-history case, replacing the old per-file-list test:** call
   `lint_file/2` against one of the 12 real paths named in §3 (e.g.
   `handoffs/WF03-ISS0258-20260822/step-01-issue-fixer.md`, still present on disk,
   unaffected by anything in this fix) with `floor = HEAD` (or any commit at least as
   new as when `WF03-ISS0258-20260822` merged) — `result.hard_grandfathered` holds,
   `result.hard_new == []`, proving the commit-boundary rule reproduces the exact
   grandfathering outcome the deleted list used to provide, for real files, without the
   list.

This lets `lint_file/2`'s `:non_json` branch either accept `floor` as a parameter too
(mirroring `handoff_files/1`'s `dir` default-argument pattern from the original design's
§2.3) or keep calling `pre_floor_file?(path, @h6_floor_commit)` at its production call
site while TEST-DESIGNER calls `pre_floor_file?/2` directly for cases 1-2 above and only
needs `lint_file/2` itself, unparameterized, for cases 3-4 (both of which use real,
already-resolvable commits, so the not-yet-final `@h6_floor_commit` placeholder value
does not need to be correct for those two assertions to pass — they only need *some*
git-resolvable value in the attribute, which `"TBD-AT-MERGE"` is not; **implementation
note for ELIXIR-DEV, not a design gap:** the placeholder must be a real, resolvable sha
from the moment code lands on the branch, e.g. the branch's own first commit, so tests
relying on the production call path never fail on an unresolvable literal before §2.3's
Step Final refresh overwrites it).

---

## 7. Acceptance-criteria traceability (this addendum's own six criteria)

| Acceptance criterion | Answered in |
|---|---|
| Exact mechanism for a file's git-history introduction point, concrete command/algorithm | §1.2 — `git log --follow --diff-filter=A --format=%H --reverse -- <path>` then `git merge-base --is-ancestor <first_add_sha> <floor>` |
| Exact floor-commit choice, justified against squash-merge timing, `commit_sha_list` reasoning reused or stated why it doesn't transfer | §2.1 (choice: pre-merge `origin/main` tip, captured at fetch time — no write-back needed), §2.2 (why the self-containment problem doesn't transfer: floor lives in a different file than the files it governs) |
| Disposition of the 12 existing `@grandfathered` H6 entries, no silent overlap | §3, §3.1 — removed, replaced with a dated comment pointing at this mechanism; `grandfathered?/2` is never called with `"H6"` again |
| New-after-floor file still hard-fails — checked, not assumed | §2.4 (worked example with commits `M`/`FLOOR`/`N`), §6 item 3 (concrete test construction proving it against real fixtures/commits) |
| No implementation code | This document contains one module-attribute declaration, `@spec` lines, two git command literals, and `case`/pseudocode control-flow shapes — no compilable function bodies |
| H1-H4's existing per-file `@grandfathered` mechanism not touched or weakened | §1.3 (`grandfathered?/2` function itself unedited), §3 ("What stays, and why"), §3.1 (deletion is scoped to exactly the 12 `"H6"`-tagged tuples, none of the 6 `H1`/`H2`/`H3` tuples) |
