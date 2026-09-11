# ISS-0613 — `REQ-NNN` id collision detection (design)

Status: design, not yet implemented. Owner of implementation: ELIXIR-DEV.

## 1. Root cause, restated precisely

`docs/requirements.yaml`'s own requirement id (`REQ-NNN`) is allocated by a session
scanning the file for the current highest `REQ-` number and incrementing — a
read-then-write race with no lock between the read and the write. Two sessions can both
read the same max before either pushes, and both pick the same next id. This is exactly
the same failure class `docs/agents/protocols/ISSUE_QUEUE.md` already documents and fixed
for `ISS-NNNN` ids (its "Updated 2026-08-21" section, and the "eighth collision" writeup
in `docs/anti-patterns.md`): a directory/file scan reads state, it does not reserve it,
and no amount of documenting the hazard closes it, because a warning is not a lock.

The `ISS-NNNN` fix was to stop deriving the id locally at all — `letflow-queue`'s
`register_task` allocates it atomically (its own autoincrement primary key) and returns
it as `issue_ref`. `REQ-NNN` never received the equivalent fix: `register_task`'s
`impl_order` *is* allocated atomically by the same queue, but the `REQ-NNN` string used
as the requirement's own identifier inside `docs/requirements.yaml` is a **separate**,
locally-scanned number, and nothing ties the two together. This is precisely the gap that
produced the 2026-09-11 collision: REQ-312 was independently picked by two sessions,
neither had pushed, one merged first, the other had to rename to REQ-321 and leave queue
task 605 permanently mislabeled and blocked (letflow-queue exposes no update/delete
endpoint — `TASK_QUEUE.md`'s four-endpoint design, confirmed by its README's stated
rationale).

## 2. Fix direction chosen: (b), a collision-detecting check task — not (a), not (c)

**(a) rejected as unnecessary, not merely "more disruptive."** Deriving `REQ-` ids from
the queue's own allocated task id would indeed close the race atomically (same mechanism
as the `ISS-NNNN` fix), but it is a bigger change than the problem requires: it would
make `REQ-` numbers large and sparse (matching queue task ids, 600+, instead of the
current small sequential range now at REQ-314), contradicting `TASK_QUEUE.md`'s own
description of the yaml as "authoritative for content" with the queue "authoritative for
claiming" as two deliberately distinct numbering domains. The actual defect here is not
that `REQ-` numbering is locally derived — REQ ids are cosmetic reference labels within a
document ORCH already treats as read-only-for-dispatch (`TASK_QUEUE.md`'s "Hard rule");
the queue task id, not the REQ- string, is what every other part of the pipeline
(`set_lock`, `release_lock`, `depends_on`) actually keys off of. The defect is that a
**duplicate write can land on `main` undetected**. A detection gate closes that without
touching what `REQ-` numbers mean or how they're chosen day to day. This mirrors this
session's own repeated preference (ISS-0578/0580/0590/0601) for the smallest fix that
closes the real gap over an architectural rewrite — here the "real gap" is exactly "an
undetected duplicate can merge," not "REQ- numbering is locally scoped," so a detector for
the former is the correctly-sized fix and a numbering-scheme change is over-fixing.

**(c) rejected as insufficient on its own.** A documented convention with no validating
step is exactly what `docs/migration/decisions/0004-humanless-pipeline.md` predicts will
drift, and it is the same shape of fix `docs/anti-patterns.md`'s "ISS-NNNN collisions keep
recurring because documenting the hazard doesn't reserve the number" entry already
declares a failure: this project tried "document it and rely on discipline" for the
`ISS-NNNN` case and it collided eight times anyway. There is no reason to expect
discipline to hold better for `REQ-NNN`.

**(b) chosen.** It is cheap, automatic, requires no numbering-convention change, and
catches the actual failure mode (a genuine content collision landing on `main`) rather
than a proxy for it. It is caught later than an atomic allocator (at PR/pre-push gate
time, not at draft time), which is a real, accepted trade-off: two sessions can still
draft against the same `REQ-NNN` simultaneously before either pushes, but neither can
**merge** past a colliding id undetected, and it is that gate — not the resolvability of
sub-collision scenarios that never reach an integration point — that closed the
2026-09-09 (ISS-0613's own referenced) analogue in `check_issue_refs`/
`check_requirements_registration` for its class of drift. A collision that both sessions
somehow *do* draft concurrently is resolved the same way `docs/anti-patterns.md` already
prescribes for the `ISS-NNNN` case: whichever session hits the gate second renumbers to
the next free id and pushes again — no data is lost, unlike the eighth `ISS-NNNN`
collision's overwritten-file failure mode, because `docs/requirements.yaml` entries are
appended/diffed as YAML list items in one shared file under normal git merge machinery,
not written to independent per-id files that silently overwrite each other.

## 3. Mechanism

### 3.1 Task name

`mix letflow.check_req_id_collision`, a new file
`lib/mix/tasks/letflow.check_req_id_collision.ex`, following the existing
`letflow.check_requirements_registration` / `letflow.check_issue_refs` conventions:
line-oriented parsing of `docs/requirements.yaml` (no YAML dependency — same reasoning
both existing tasks already state), a `@moduledoc` citing this design doc and ISS-0613,
`Mix.raise/1` on any violation naming every colliding id, `:ok` otherwise, and nothing
printed-but-non-gating needed here (unlike the registered/deferred split in
`check_requirements_registration`, every finding this task can produce is a hard
failure — there is no "documented, intentionally green" state for a genuine id
collision).

### 3.2 Detection logic (prose/pseudocode only)

Inputs:
- The **current, working-tree** copy of `docs/requirements.yaml` (read from disk, same
  as `check_requirements_registration` — this task's job is to catch a collision before
  it is pushed, so it must see uncommitted content too, not just `HEAD`).
- `origin/main`'s copy of the same file, read via `git show origin/main:docs/requirements.yaml`
  (`System.cmd/3`, mirroring the existing `git`-shelling precedent already in
  `lib/mix/tasks/letflow.lint_handoffs.ex`, e.g. its `git merge-base --is-ancestor` and
  `git show` calls). No `git fetch` is issued by the task itself — it trusts the local
  `origin/main` ref exactly as `lint_handoffs` already does, which is safe because CI's
  own checkout step already runs with `fetch-depth: 0` (`.github/workflows/ci.yml`) and a
  normal dev workflow keeps the ref current via `GIT_MERGE.md`'s existing rebase steps.
- The **merge base** of `HEAD` and `origin/main` (`git merge-base HEAD origin/main`), and
  that commit's copy of the file (`git show <merge-base>:docs/requirements.yaml`). This is
  what lets the task tell "an id newly introduced by this branch" apart from "an id that
  was already on both branches before they diverged" — comparing only current-vs-main
  directly would misreport every untouched pre-existing entry as needing a check, when
  only entries this branch actually *added* since the merge base are candidates for a
  fresh, independently-invented collision.

Detection steps:

1. Parse all three snapshots (current working tree, merge-base, origin/main HEAD) into
   the same `%{id => entry_text}` shape the existing check tasks already use internally
   (id extracted via the same `^  - id: (REQ-\d+)` anchor `check_requirements_registration`
   uses; `entry_text` is the full raw block of lines belonging to that id, indentation
   rule identical to that task's "4-or-more-spaces attribution" rule, so the two tasks
   stay consistent about what counts as "belonging to" an entry).
2. `added_by_this_branch = ids present in current but absent from merge-base map` — the
   set of `REQ-` ids this branch itself introduced since diverging from `main`.
3. For each id in `added_by_this_branch`:
   - If that id is **absent** from `origin/main`'s current map → no collision (normal
     case: this branch's new id hasn't been claimed by anyone else yet). No finding.
   - If that id is **present** in `origin/main`'s current map:
     - Normalize both entry texts (strip trailing whitespace per line, normalize line
       endings — same CRLF-normalization caution `docs/anti-patterns.md`'s "ISS-NNNN
       collisions keep recurring" entry already flags for exactly this class of
       comparison) and compare.
     - **Identical content** → not a collision, merely the same entry already landed on
       `main` (e.g. this branch is stale/already-merged, or was rebased after the fact).
       No finding.
     - **Different content** → **genuine collision**: this branch independently invented
       an id that `main` has already claimed for something else. Hard failure.
4. The task's exit is non-zero iff step 3 found at least one genuine collision; otherwise
   `:ok`, same pass/fail shape as the existing check tasks.

### 3.3 Failure message shape

One block per colliding id, in the same "name every violation, no aggregate-only verdict"
style `check_requirements_registration` and `check_issue_refs` already use:

```
REQ-ID COLLISION DETECTED

  REQ-312 is defined both on this branch and on origin/main, with different content.

  This branch's entry (docs/requirements.yaml, line <N>):
    title: "<this branch's title>"

  origin/main's entry (already merged, line <M>):
    title: "<main's title>"

  This is the exact read-then-write race documented in
  docs/agents/protocols/ISSUE_QUEUE.md's "Updated 2026-08-21" section for ISS-NNNN ids,
  now caught for REQ-NNN ids too (ISS-0613). Do not edit around this — pick the next
  REQ- id genuinely free on origin/main, renumber this branch's entry (and its
  `depends_on`/cross-references, and the matching queue registration's title if already
  registered), and re-run this check.

<repeat per colliding id>

<N> collision(s) found — fix and re-run `mix letflow.check_req_id_collision`.
```

Mirrors `Mix.raise/1`'s existing usage in the sibling tasks: one raise, full multi-id body,
not one raise per id (a single non-zero exit, full detail in the message).

### 3.4 Gate-suite wiring

Add to `mix.exs`'s `"letflow.check"` alias list, immediately after
`"letflow.check_requirements_registration"` and before `"letflow.check_deferral_staleness"`:
it shares a parse of the same file and the same "id" concept as
`check_requirements_registration` (same reasoning that task already gives for why
`check_deferral_staleness` sits right after it — cheap, no compile step, catch it before a
full compile+test cycle). It has no ordering dependency on `check_deferral_staleness`
itself (different concern entirely — deferral rationale text vs. id collision), so
slotting between the two is purely "group the requirements.yaml-parsing checks together,"
not a hard requirement.

```
"letflow.check": [
  "letflow.check_toolchain",
  "letflow.check_requirements_registration",
  "letflow.check_req_id_collision",   # NEW — ISS-0613
  "letflow.check_deferral_staleness",
  "letflow.lint_handoffs",
  "letflow.check_async_sandbox_reachability",
  "letflow.check_issue_refs",
  "format --check-formatted",
  "compile --warnings-as-errors",
  "letflow.check.test"
]
```

## 4. Does this need separate CI wiring?

**No.** `.github/workflows/ci.yml` invokes the backend gate as exactly one step,
`run: mix letflow.check` (confirmed at line 268), with a full-history checkout
(`fetch-depth: 0`) that guarantees `origin/main` is a valid, resolvable local ref inside
the CI runner. Since the new task is wired into the `letflow.check` alias itself (§3.4),
CI picks it up automatically with zero changes to `ci.yml`. This also matches the
project's own stated reasoning for why `mix letflow.check` is CI's only backend gate step
(`ci.yml`'s own comment block, lines ~15-25): "the existing alias already runs the full
local gate... hence exactly one `run: mix letflow.check` step." Adding a second, parallel
CI step for this one check would duplicate that reasoning's opposite.

One caveat worth stating explicitly (not a change needed, just a known boundary): a
first-time local clone that has never fetched `origin` will have no `origin/main` ref to
diff against. The task should treat `git show origin/main:...`/`git merge-base` failing
for "no such ref" as **non-fatal** — print a clear warning ("origin/main not resolvable
locally; skipping REQ- id collision check — run `git fetch origin main` and re-run") and
exit `0`, rather than hard-failing a developer environment that simply hasn't fetched yet.
This mirrors `lint_handoffs`'s own existing tolerance pattern for git-command
non-availability rather than inventing a new one. CI itself never hits this branch, since
its checkout always includes full history.

## 5. Queue task 605 — cleanup

**Nothing to clean up; "left blocked forever, documented" is the correct, permanent
end state**, for the same structural reason `TASK_QUEUE.md` (lines ~117-118) already
gives for the general case: `letflow-queue` exposes exactly four endpoints by deliberate
design (its own README's "Design" section) and none of them updates or deletes a task.
There is no operation that relabels task 605 as "605 (retitled, now REQ-321)" or removes
it from the queue's own listing. This is the same shape of "unfixable by design,
therefore documented and left" outcome this project has already accepted elsewhere — e.g.
`ISSUE_QUEUE.md`'s `instrumented` status requiring a permanent `superseded_by` pointer
rather than pretending the original record can be erased, and the non-contiguous
`ISS-NNNN` numbering gap (`ISS-0119` to `ISS-0186`) being explicitly declared "expected"
rather than something to backfill. Task 605 stays `blocked` with its existing
mislabeling; no new queue call, no new local file, is needed or possible. If not already
done, the one thing worth confirming (not part of this design's scope to perform — an
ORCH/administrative action, not a `lib/` change) is that task 605's `release_lock` call
recorded a `status: "blocked"` with a note pointing at REQ-321 as the actual successor,
mirroring the `superseded_by` discipline above, so a future reader of the queue's own
listing isn't left to guess why an apparently-abandoned task exists.

## 6. Decision record — not warranted

Considered and rejected. `docs/migration/decisions/` records are reserved for choices
that bind future work at the scale of `0018`'s branch-protection posture or
`0011`/`0012`'s ownership/stack calls — cross-cutting choices where a wrong call is
expensive to reverse and other agents need a durable, load-bearing citation before acting
against the grain of it. This fix is narrower and much easier to reverse than that bar:
it is one new local-only static-analysis check task, added to an alias list that already
holds seven siblings of the identical shape (`check_requirements_registration`,
`check_issue_refs`, `check_deferral_staleness`, `check_async_sandbox_reachability`,
`lint_handoffs`, none of which have their own decision record), gated the same way, with
no effect on any other agent's workflow beyond "the existing pre-push/CI gate now also
catches this one additional failure mode." `ISSUE_QUEUE.md`'s own "Updated 2026-08-21"
section is the precedent for how this project records exactly this class of change — a
dated update appended in-place to the protocol doc it affects, not a standalone decision
record — and this design doc plus a symmetrical update to `TASK_QUEUE.md`/`ISSUE_QUEUE.md`
(ELIXIR-DEV's or a follow-on DOC-UPDATER's job, not this design step's) is the right-sized
paper trail. REQ-312/313/314's own precedent (named directly in this task's brief as
"ordinary design work") supports treating this the same way, not elevating it further:
this issue is materially smaller in blast radius than any of those three, having no
schema, no API, and no cross-module dependency of its own.

## 7. Open questions

- Whether `check_req_id_collision` should also normalize/compare `depends_on` and
  `stage` fields specifically (beyond raw entry-text equality) when flagging "different
  content" — e.g. an id whose title matches byte-for-byte but whose `depends_on` differs
  is still a genuine collision. Raw normalized-text comparison (§3.2 step 3) already
  covers this correctly as an implementation detail (any field difference makes the
  normalized texts unequal), so no special-casing is needed; noted here only so
  ELIXIR-DEV doesn't second-guess and add field-by-field comparison logic that the
  whole-entry-text comparison already subsumes.
- Whether a parallel `depends_on` **integer** (queue task id) collision is a real risk
  worth its own check. Queue-allocated `impl_order`/task ids are atomic per `TASK_QUEUE.md`
  and cannot collide by construction, so this is out of scope — noted here only to record
  that it was considered and correctly excluded, not overlooked.
