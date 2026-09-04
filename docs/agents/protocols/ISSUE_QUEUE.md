# ISSUE_QUEUE Protocol

**Function:** `fn:enqueue-issue`
**Read by:** every agent
**Used in:** any step that discovers a defect outside its own current scope

## Purpose

A run does one job and does it completely: git-setup once, the run's own steps,
git-merge once. A defect discovered *incidentally* — not the thing the run was
dispatched to fix — is filed and forwarded to become its own later run, rather than
silently expanding the current run's scope or being dropped.

This is distinct from `core-directives.md`'s Unblock-Everything directive: that covers
defects that block *this run's own* acceptance criteria (fix them now, in this run).
This protocol covers defects that are merely adjacent — noticed, not blocking.

## Procedure

**Updated 2026-08-20 (ISS-0086/GH#303's own resolution run).** Steps 2-3 previously
had the discovering agent call `gh issue create` directly, with no `letflow-queue`
registration anywhere in this protocol. That was written before `letflow-queue`
existed and was never reconciled with `TASK_QUEUE.md` once it landed — the result was
that every issue filed this way (including ISS-0086 itself) entered the queue only
*opportunistically*, as a side effect of some later `get_next_task` call's GitHub-import
step, if at all. A WF-03 run resolving such an issue had no reliable way to find or lock
its queue task, meaning nothing actually prevented a second host from independently
claiming the same open GitHub issue and duplicating the fix — see
`docs/anti-patterns.md`'s matching entry. Steps 2-3 below now route through
`register_task` instead, per `TASK_QUEUE.md`'s "who calls what" division (only `ORCH`
calls the queue — the discovering agent reports the finding, it does not call `gh` or
the queue itself).

**Updated 2026-08-21 (ad-hoc run ADHOC-20260821-001).** Step 1 previously said to assign
the id by scanning `docs/issues/` for the highest existing `NNNN` and incrementing. **That
instruction is removed.** It was a read-then-write race with no lock between the halves,
and it collided eight times across concurrent sessions — see `docs/anti-patterns.md`'s two
`ISS-NNNN` collision entries and the update appended to the second of them. The id is now
allocated by `letflow-queue`, atomically, and returned as `issue_ref`. Do not scan, do not
increment, do not guess.

```
1. Do NOT derive the id. The discovering agent does not pick a number, and neither does
   ORCH. The id comes back from `register_task` in step 2a as the response field
   `issue_ref` (e.g. task id 187 -> "ISS-0187"), and the local record is written to
   docs/issues/<issue_ref>.yaml in step 3. Until step 2a has returned, this finding has
   no id — refer to it by title.

2. The discovering agent reports the finding to ORCH (title, description, severity,
   affected_files) — it does not call `gh` or letflow-queue itself. ORCH then:

   a. If letflow-queue is reachable ($QUEUE_AUTH_TOKEN via shell env or ./.env — see
      TASK_QUEUE.md's "Before concluding the token is unavailable" check; verify
      reachability with `GET /health`, never with `get_next_task` — see TASK_QUEUE.md's
      Reachability checks note):

      register_task(title, description, acceptance_criteria: ["See linked GitHub
        issue for full description"], task_type: "issue")

      The response carries `issue_ref` — "ISS-" plus the zero-padded task id (task 187
      -> "ISS-0187"). THAT IS THE ID. For issue-type tasks the service also rewrites the
      task title to carry that ref as a prefix, stripping and replacing any "ISS-NNNN:"
      the caller happened to supply; only a LEADING token is replaced, so an ISS-
      reference elsewhere in a title is treated as a genuine cross-reference and survives
      verbatim. (Verified live 2026-08-21: a call whose title deliberately began
      "ISS-0120:" came back as id 187, issue_ref "ISS-0187", title rewritten to
      "ISS-0187: ...".)

      This best-effort creates the mirrored GitHub Issue itself (per TASK_QUEUE.md's
      "GitHub Issues visibility" section's `register_task` bullet) — do NOT also call
      `gh issue create` separately, that would double-post. **That instruction still
      stands unchanged.** Record the response's `id` (queue task id) and
      `github_issue_number` into the yaml's `queue_task_id` and `github_issue` fields
      respectively; `id` and the number in `issue_ref` are the same integer.

      **Adoption path — an issue that genuinely was filed on GitHub first** (e.g. by a
      human, or by an agent under the pre-2026-08-21 order): pass the existing issue's
      number as the optional `github_issue_number` request field. The service adopts that
      issue instead of creating a second one. A number already linked to another task is
      rejected ("github_issue_number: has already been taken") rather than re-pointed at
      the new task — verified live 2026-08-21 against an already-linked number. This is
      the only sanctioned way an issue's GitHub record precedes its `register_task` call;
      it is not a licence to go back to calling `gh issue create` first.

   b. If letflow-queue is unreachable (genuinely, both token locations checked): there is
      no allocator, and therefore **no id** — a locally-derived number is exactly the
      thing this protocol just removed. Do not scan-and-increment to fill the gap. File
      the finding in your handoff's `result.issues` (severity as discovered) and report
      it to ORCH, which registers it once the queue is reachable and writes the record
      then; the finding is not lost, it is just not yet numbered. If ORCH judges the
      finding must be visible on GitHub before then, per core-directives.md's "No Issue
      Left Local-Only", `gh issue create --title "<title>" --body "<description>

      Discovered by <AGENT_ID> during <run-id>.
      Local record: not yet allocated — letflow-queue unreachable at filing time."` is
      the interim step, and the resulting issue number is later adopted via the
      `github_issue_number` field in 2a so it never becomes a duplicate.

3. Write docs/issues/<issue_ref>.yaml — the filename comes from step 2a's `issue_ref`,
   not from anything on disk:
   id: <issue_ref>          # e.g. ISS-0187, matching the filename exactly
   title: <one-line summary>
   discovered_by: <AGENT_ID>
   discovered_in_run: <run-id>
   discovered_at: <UTC timestamp from the clock>
   severity: BLOCKER | MAJOR | MINOR
   description: >
     <what's wrong, where, and why it matters>
   affected_files:
     - <path>
   queue_task_id: <id>   # from register_task's response per step 2a — the same integer
                         # as issue_ref's number (ISS-0187 <-> 187)
   github_issue: <n>     # from the same response's github_issue_number
   status: open

4. Commit docs/issues/<issue_ref>.yaml as part of the current step's normal commit.

5. Do NOT extend the current run to fix it. Do NOT launch a nested workflow. The
   current step's own PASS/FAIL verdict is unaffected by an incidentally-discovered
   issue — only issues that ARE the current step's own failure drive that step's
   rework.
```

## Where the id comes from (2026-08-21) — and what this supersedes

**The id is allocated, not chosen.** `letflow-queue`'s task `id` is an autoincrement
primary key, so it is handed out atomically by the one service every host shares. No two
hosts can receive the same one, which is precisely what a directory scan could never
guarantee: a scan reads state, it does not reserve it. The eighth collision
(`WF03-ISS0106-20260821`, records now at `docs/issues/ISS-0118.yaml` and
`ISS-0119.yaml`) is the proof — that run scanned `docs/issues/` across *every remote
branch* before choosing, which is exactly the mitigation `docs/anti-patterns.md`
prescribed, and it collided anyway, because the numbers it collided with did not exist on
any branch at the moment it looked.

**Two consequences worth stating outright.**

**1. The old "local record first, GitHub issue second" advice is superseded.**
`docs/anti-patterns.md`'s first ISS-collision entry says: *"File the local record before
opening the GitHub issue, and put the id in the GH title. A GH issue whose body cites a
local file that has since been overwritten is the worst end state."* Under this protocol
the order is inverted — `register_task` creates the GitHub issue as part of allocating the
id, so the GitHub issue exists *before* `docs/issues/<issue_ref>.yaml` is written (step 2a
then step 3, same agent turn). That is now the safer order, for three reasons, and the old
advice is not merely overridden by fiat:

- **The overwrite hazard it guarded against was a consequence of guessed numbering, not of
  ordering.** The local file could be silently overwritten only because two agents could
  pick the same filename. They can't any more — the filename comes from an allocated id.
  Remove the collision and the "worst end state" it described cannot arise.
- **The id can no longer be wrong.** Writing the local record first was a way of pinning a
  number down before publishing it. The number is now pinned by the allocator, and the
  local record is written *from* it rather than the other way around.
- **The id lands in the GitHub title automatically.** The old advice depended on an agent
  remembering to type the id into the GH title; the service now rewrites an issue-type
  task's title to carry `issue_ref` as a prefix, so the two records agree by construction
  rather than by diligence.

The historical entries in `docs/anti-patterns.md` stay as written — they are the record of
how this was learned. Only the *forward instruction* in them is superseded, and that is
recorded in the update appended to the second entry.

**2. `queue_task_id` and the issue id are the same integer.** `ISS-0187` is queue task
`187`. A later WF-03 run can therefore derive the `set_lock` target straight from the
filename, without needing the yaml open and without the `get_next_task`-and-hope fallback
in "Picking up a queued issue later" below. Keep recording `queue_task_id` in the file
anyway — it stays the explicit, machine-readable link, and it is what pre-2026-08-21
records rely on.

### Issue numbers are non-contiguous from here on — this is expected

The hand-numbered range ends at **ISS-0119**. Queue-allocated ids start in the **ISS-0186
and upward** range, so **there are no ISS-0120..ISS-0185 records and never were** — nothing
is lost or missing. Ids will stay non-contiguous thereafter, because the queue's id
sequence is shared with `task_type: "requirement"` tasks: every requirement registered
between two issues consumes a number that no `ISS-` file will ever carry. A gap in
`docs/issues/` is not evidence of a deleted or misplaced record. (Existing hand-numbered
records keep their numbers — nothing is retro-renumbered.)

## Issue status vocabulary

`docs/issues/ISS-NNNN.yaml`'s `status:` field. This is the canonical list — WF-03 and
every other reader point here rather than restating it.

- `open` — filed, not yet being worked.
- `in_progress` — a run has locked it and is working it.
- `resolved` — **a root cause was actually removed**, and a regression test proves it.
  Shipping useful, verified work is *not* the same thing. This registry is read by later
  runs as a factual record of what is and is not still broken, not as a progress report,
  so `resolved` on an issue whose defect still exists silently misinforms every run that
  cross-references it.
- `instrumented` — the run built and verified real improvements (typically diagnostic
  capability), and that run's own acceptance criteria were met, but the underlying
  defect's **root cause is not removed and the issue is not fixed**. An `instrumented`
  record MUST carry `superseded_by: ISS-NNNN` naming the successor issue that carries the
  remaining work, so it can never be a dead end; file that successor before transitioning
  the record. State plainly in the record what the shipped work does *not* close.
  Release the queue task with `release_lock(status: "blocked")`, not `"done"` and not
  no-status — see `TASK_QUEUE.md`'s release_lock section for why.

- `no_defect` — **the issue was investigated and measured, and there was no root cause
  there to remove.** Terminal, like `resolved`, but it asserts a different thing and must
  never be used in place of it: `resolved` says a defect existed and was removed, with a
  regression test proving it; `no_defect` says the investigation established that the
  defect the record alleged does not exist. Nothing here relaxes `resolved`'s bar by a
  hair — that definition stands exactly as written above, and this status exists so that a
  no-defect outcome stops being tempted to borrow it. `no_defect` is not "we found
  nothing"; it is a positive, falsifiable claim about reality — *checked, measured, not
  there* — and a `no_defect` record claimed without the measurement to back it misinforms
  every later run that cross-references this registry, exactly as a false `resolved` does.

  **The evidence bar is the same discipline as the other two, not a lower one.** A
  `no_defect` record MUST carry — in the issue file, citing the closing run's diagnosis
  handoff by path — all four of:

  1. the **first-hand measurement** that was run, with the producing code or command
     quoted and real figures given. Figures inherited from the issue's own filing, or from
     another run, do not count; `HANDOFF_PROTOCOL.md` §1.1 applies, and if the
     re-measurement disagrees with the filing, the measurement wins and the record says
     so.
  2. the **specific candidate mechanisms tested**, named individually, each with its
     result — *including* the ones the data did not support. A verdict that reports only
     what was checked, and not what was looked for and not found, is not this status.
  3. the **stated limitations of the method**, so a later reader can weigh the negative
     result instead of inheriting it as settled. A negative result that hides the weakness
     of the test that produced it is worth less than no record at all.
  4. the **run-id and timestamp** of the run that reached the verdict, recorded under the
     key pair `verdict_in_run:` / `verdict_at:` — **not** `resolved_in_run:` /
     `resolved_at:`, which assert a resolution that a `no_defect` record explicitly did
     not perform and would re-introduce the false claim this status exists to prevent, and
     **not** `closed_in_run:` / `closed_at:`, because `closed_at:` already carries a
     different meaning in this registry — the moment GitHub closed the mirrored issue
     (`ISS-0109.yaml`) — and one key name with two meanings distinguished only by nesting
     depth is not readable by the mechanical linter ISS-0191 specifies. `verdict_at:` is
     when the run reached its verdict, which is not the same event as the GitHub close.

  Release the queue task with `release_lock(status: "blocked")`, not `"done"` and not
  no-status — see `TASK_QUEUE.md`'s release_lock section for why.

  This is deliberately the hardest of the three to earn cheaply, because it is the one an
  uninvestigated issue would most like to take. An issue nobody investigated cannot reach
  `no_defect`: with nothing to quote under (1)–(3) there is nothing to write, and a record
  that says only "looked, seemed fine" has not reached a terminal status at all — it is
  still `open`.

  **WF-03 and this vocabulary now agree.** WF-03 Step 1 has always licensed a reasoned
  NO-CHANGE verdict as a legitimate outcome, and WF-03 Step 5 already points at this
  section as the canonical status list — but until now that list offered a NO-CHANGE run
  no legal terminal value: `resolved` would assert a removal that never happened, and
  `instrumented` would assert shipped work that does not exist. Both are false statements
  about a NO-CHANGE outcome, and a run forced to pick one of them corrupts the registry in
  order to close a ticket. That is the gap this closes.

Worked example: **ISS-0109** (`superseded_by: ISS-0116`). Run WF03-ISS0109-20260821 built
and verified real test instrumentation, but the design gate and REVIEWER independently
concluded the failure was instrumented, not fixed — the root cause remains unknown — so it
was transitioned to `instrumented` rather than `resolved`.

Worked example: **ISS-0200** (`status: no_defect`, run WF03-ISS0200-20260821) — the
precedent that forced this status into the vocabulary. The run asked whether
`result.summary` carries a redundancy defect distinct from justified length; it measured
605 handoff files across 60 runs first-hand, tested six candidate restatement mechanisms
and found none supported, recorded its own shingle method's under-power against paraphrase
as a stated limitation, and changed no rule. Nothing was removed, so `resolved` was false;
nothing shipped, so `instrumented` was false. The gap was found by that run's own
diagnosis and fixed in the same run rather than filed, because Step 5 could not legally
close the issue without a terminal status that told the truth.

## Closing an issue's GitHub mirror — evidence is mandatory

`WF-03_issue_resolving.md` Step 5 owns the close procedure itself; this section states
the rule that procedure implements, so a reader who lands here first (e.g. via a
cross-reference from a filing) doesn't have to guess whether it's optional.

**A `gh issue close` on any issue this protocol tracks — and any local status flip to
a terminal value (`resolved` / `instrumented` / `no_defect`) — MUST carry either:**

1. a `--comment` on the GitHub issue citing the resolving evidence (the run-id, the
   `docs/issues/ISS-NNNN.yaml` record, and — for `resolved` only — the regression test
   path), or
2. a genuinely linked/merged PR with a `Closes`/`Fixes` reference recorded in the
   issue's own GitHub timeline (visible as a non-empty
   `closedByPullRequestsReferences` in `gh issue view --json`).

A closure carrying neither is **undocumented, not merely under-documented** — it
cannot be checked against its own reasoning after the fact, because it states none.
This is not a hypothetical: GH#324 and GH#326 were both closed 2026-08-20 this way,
and the gap went undetected until an unrelated reconciliation audit
(`WF03-ISS0278-20260822`) caught it by chance (see `docs/issues/ISS-0279.yaml` — filed
from that finding).

`mix letflow.audit_issue_closures` (`lib/mix/tasks/letflow.audit_issue_closures.ex`)
mechanically re-checks every closed, `github_issue`-linked entry in `docs/issues/` for
this rule. It is a **standalone, on-demand tool** — see its own `@moduledoc` for why it
is not wired into `mix letflow.check` — run it periodically (e.g. as part of a
reconciliation pass) rather than relying on Step 5's prose compliance alone.

## Picking up a queued issue later

As of `letflow-queue` going live, task **selection** happens through `get_next_task`
only — see `TASK_QUEUE.md`'s Hard Rule. This section now covers the two remaining
cases: a queue-selected pickup, and a human naming a specific `ISS-NNNN`/GitHub issue
directly (which bypasses selection but not locking).

**Queue-selected pickup (the normal case):** `get_next_task` returns the task; its `id`
is the `queue_task_id` — cross-reference against `docs/issues/*.yaml` by
`github_issue_number` to find the matching local record (or, for a task that predates
this field, by title). Set `status: in_progress` in the issue file and backfill
`queue_task_id` if it was previously null. On resolution, `status: resolved` plus the
resolving run-id and timestamp, then `release_lock(status: "done")`.

**A human names a specific issue/GH-issue-number directly:** this is not "agent
discretion over selection" (see `TASK_QUEUE.md`'s Hard Rule exception) and may proceed
without `get_next_task` choosing it — but the task must still be locked before work
starts and released when done, or nothing stops a second host's own `get_next_task`
call from independently claiming the same still-open item. Concretely:

1. If the issue's `docs/issues/ISS-NNNN.yaml` already records a `queue_task_id`: call
   `set_lock` directly on that id. (It works on any currently-unlocked task you already
   know the id of, not only a task this same agent held before — see
   `TASK_QUEUE.md`'s `set_lock` section.)
2. If `queue_task_id` is null or the issue predates this field (filed under the
   pre-2026-08-20 version of this protocol, see "Updated" note above): make **exactly
   one** real `get_next_task` call (the run's real `agent_id` — never a disposable
   "probe" id). If the returned task's `github_issue_number` matches, proceed locked and
   backfill `queue_task_id` into the yaml immediately, closing this gap for next time. If
   it doesn't match, `release_lock` it back to `open` (no `status`) immediately, state
   the mismatch plainly, and do not chase further down the priority stack — repeated
   claim/release thrashes a shared service other hosts depend on. (What you got back
   instead is itself real, current information — a different open task exists at higher
   priority — surface it, don't just discard it.)
3. On completion, `release_lock(status: "done")` the task actually locked in step 1/2.
   If step 2 never found a match, note explicitly that the queue's mirror stayed out of
   sync for this item; this is bounded (not indefinite) risk once the GitHub issue is
   closed, since `get_next_task`'s import only pulls **open** issues — see
   `TASK_QUEUE.md`'s "GitHub Issues visibility" section's `get_next_task` bullet.

Never delete an issue file — it is the audit trail of what was found and when it was
fixed, same append/never-rewrite spirit as `docs/status/requirement_status.yaml`.
