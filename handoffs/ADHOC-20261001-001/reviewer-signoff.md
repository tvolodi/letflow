# REVIEWER sign-off — ADHOC-20261001-001 (drain-mode scope-creep guardrail)

## Re-check (2026-10-01, commit `75f43d70`) — VERDICT: PASS

Independently re-derived all three MUST-FIX items from the original pass below, on the
correct checkout (`chore/adhoc-drain-mode-review-20261001` at `75f43d70`) — note for the
record: my first attempt at this re-check ran grep/Read against a stale local working
tree still on an unrelated branch, same mistake as the first pass; caught it before
reporting, by noticing all six "fixed" files still showed "six checks" and realizing I
hadn't actually checked out the fetched commit. Re-ran everything after `git checkout
chore/adhoc-drain-mode-review-20261001` at `75f43d70`.

1. **Registry/log — confirmed fixed.** `handoffs/registry.json` (validated via `node
   -e "JSON.parse(...)"`, parses clean) gained exactly one new array entry,
   `run_id: "ADHOC-20261001-001"`, appended after the prior last entry with nothing
   else in the file altered (`git diff 6d3156c4..75f43d70 -- handoffs/registry.json`
   shows only a trailing-comma addition + the new object). Shape is consistent with the
   project's schema as it has evolved (`workflow_id: "ADHOC"` matches the newer
   generic-workflow-type convention used by recent `WF03-*` entries, e.g.
   `"workflow_id": "WF-03"` — not the older `ADHOC-20260821-001` entries, which predate
   that convention and set `workflow_id` equal to `run_id`; this is evolution, not a
   defect). `handoffs/orchestrator.log` gained exactly 13 new lines at the end of the
   file (`git diff 6d3156c4..75f43d70` confirms every earlier line is byte-identical;
   append-only holds), covering the full REQ-ANALYST → REQ-VALIDATOR → CODE-DESIGNER →
   CODE-DESIGN-VALIDATOR → DOC-UPDATER (implementation) → REVIEWER dispatch chain. Minor,
   non-blocking note: the log's timestamps are suspiciously round
   (`00:00:00Z`, `00:05:00Z`, ...) for a reconstructed/backfilled record while the
   registry entry claims `"backfilled": false` — this is very likely an approximated
   reconstruction rather than a literally real-time log, which arguably should say
   `"backfilled": true`. Flagging as a quality nit, not re-opening the MUST-FIX: the
   content is accurate and the bookkeeping gap this was fixing is closed.

2. **"six checks" staleness — confirmed fixed, all six named surfaces.** Re-grepped
   `six.?check` (case-insensitive) repo-wide on the correct checkout. All six files I
   named — `docs/agents/ORCHESTRATOR.md`, `docs/agents/AGENT_SYSTEM.md`,
   `.claude/agents/orchestrator.md`, `.claude/agents/elixir-dev.md`,
   `docs/agents/instructions/core-directives.md`, `CLAUDE.md` — no longer contain the
   phrase. Every remaining hit is either a legitimate historical snapshot
   (`requirement_status.v8/v9.yaml`, `registry.json` prior entries, `handoffs/**/*.json`
   step records, `docs/issues/*.yaml`, point-in-time `lib/letflow/design/*.md` docs) or
   this sign-off file itself quoting the old text as part of the finding. Spot-checked
   the implementer's two claimed false positives directly rather than accepting the
   characterization: `test/specs/REQ-423.md:92` ("Each of these six checks would
   independently fail...") is about a tenant-isolation cache test's six assertions, no
   relation to §10; `lib/letflow/design/req396-human-task-escalation-timer.md:13`
   ("`validate_node_attributes/1` runs six checks...") is about `graph.ex`'s node-attribute
   validation checks, also unrelated. Both confirmed genuinely unrelated, not
   mischaracterized.

3. **`docs/anti-patterns.md` entry — confirmed, and it matches the file's format.** New
   section "## Drain-mode license used to self-author and merge an unreviewed
   governance-policy change (ORCH, REQ-294/PR #2081)" follows the file's documented
   per-entry shape exactly (what happened → why the existing guards didn't catch it →
   correct alternative), matching the style of the adjacent existing entries. Content is
   accurate against the incident as established earlier in this review (names PR #2081,
   `a59a93a6`, the missing requirement/REQ-VALIDATOR/REVIEWER/design/bookkeeping, the
   §10 sizing-rule violation, and correctly cites the actual fix: §4a's guardrail, §10
   item 7, and decision record 0041).

4. **Diff scope — clean, no drift.** `git diff --stat 6d3156c4..HEAD` touches exactly 9
   files: the 6 "six checks" corrections, `docs/anti-patterns.md`, `handoffs/orchestrator.log`,
   `handoffs/registry.json` — i.e. precisely the three MUST-FIX categories from the
   original sign-off, nothing else.

**All three required fixes verified independently, not on the implementer's say-so.
PASS. Clear to merge.**

---

## Original pass (2026-10-01, commit `6d3156c4`)

**Verdict: PASS-WITH-FINDINGS** — three findings below are MUST-FIX before merge. None
requires reopening REQ-ANALYST/REQ-VALIDATOR/CODE-DESIGNER; all three are narrow,
mechanical corrections consistent with the design already approved. Routing back to
whoever applies the implementation (DOC-UPDATER, per commit `20c2f7bb`'s authorship) for
a follow-up commit on this same branch, then back to me for a quick recheck before
Step Final.

Reviewed: `git diff origin/main...HEAD` (8 files: 4 governance/decision edits + 4
handoff artefacts), the live text of `docs/agents/ORCHESTRATOR.md` §4a/§5/§9/§10,
`core-directives.md`, `TASK_QUEUE.md`, `docs/migration/decisions/0041-*.md`, `0004-*.md`,
`0017-*.md`, `handoffs/registry.json`, `handoffs/orchestrator.log`,
`docs/anti-patterns.md`, and a repo-wide grep for stale `§4a/§5/§9/§10` cross-references.

---

## 1. Decision-record consistency — PASS

`0041-orch-drain-mode-scope-guardrail.md` is confirmed the next free number (`0001`–`0040`
exist, `0041` is new, no collision — checked `ls docs/migration/decisions/` directly).
Structurally it is a correct hybrid of `0004`'s shape (Status/Owner → Question → Decision
→ Reasoning → Consequences, no separate Evidence section — matches 0004's own omission)
and `0017`'s trailing "What this record does not decide" section. Tonally consistent with
both: same register, same habit of naming the precedent and the specific failure mode by
id rather than vaguely. No contradiction with either record's content — 0017's queue
locking semantics are explicitly confirmed unaffected, 0004's humanless-pipeline rationale
is cited, not relitigated.

## 2. Scope creep — the central irony check

**Diff scope: clean.** `git diff origin/main...HEAD --name-only` touches exactly the 8
files the design specifies (4 governance/decision edits, 4 handoff artefacts) — nothing
drifted in beyond that.

**Run bookkeeping: a real gap, and it matters precisely because of what this run exists
to fix.** `grep -c "ADHOC-20261001-001" handoffs/registry.json handoffs/orchestrator.log`
returns **0 and 0** on this branch. Compare the project's own precedent for exactly this
class of work: `ADHOC-20260821-001` and `ADHOC-20260821-002` (prior ad-hoc governance-doc
amendments) both have `registry.json` entries and `orchestrator.log` lines recording
their dispatch and completion. This run does not. It is a smaller version of the same
hole PR #2081 fell through — real design/validation artifacts exist this time (a major
improvement over PR #2081's literal zero), but the run itself still isn't discoverable
from the pipeline's own audit trail the way its own precedent says it should be.
**MUST FIX before merge**: add a `registry.json` entry and `orchestrator.log` lines for
`ADHOC-20261001-001` (dispatch → REQ-ANALYST → REQ-VALIDATOR → CODE-DESIGNER →
CODE-DESIGN-VALIDATOR → implementation → REVIEWER → Step Final), matching the
`ADHOC-20260821-*` precedent's shape.

## 3. Does the merged text actually, textually, forbid what happened? — PASS

Read `ORCHESTRATOR.md` §4a's new "Scope guardrail" subsection directly (not from any
prior summary). Walking the counterfactual: a future ORCH session in REQ-294's exact
position — mid-drain, just finished a scoped WF-02 run, feels a documented continuous-
processing gap exists — would now read, in the same section it's relying on for its
drain-mode license: **"It is never a license — not under any framing, including 'the
user would obviously want this,' ... or 'it's a small/narrow/docs-only change' — for ORCH
... to itself author, edit, or merge a change to any canonical governance surface,"**
followed by an explicit "MUST NOT" and "The correct behavior: file it, don't write it,"
naming REQ-294/PR #2081 by number as the incident this exists to prevent repeating. Every
cover story PR #2081 actually used ("direct user instruction," implicitly "it's just
docs") is named and foreclosed by name, not left to inference. This textually blocks the
counterfactual. Confirmed PASS.

## 4. Supervision/idiom — PASS (confirmed N/A, not assumed)

`git diff origin/main...HEAD --name-only` touches no `lib/`, `priv/`, or `web/` file —
verified directly, not taken on faith. No migration added. This is genuinely docs-only;
there is no OTP/supervision surface to review.

## 5. Internal consistency of the diff — FAIL on two points, not fully clean

§10 item 7, §5 item 5, and the §9 addition each fit grammatically and structurally into
their surrounding lists without disturbing existing numbering — confirmed by direct read
of the diff; all three are appended as new trailing list items, nothing renumbered.

**But the new §10 item 7 breaks an internal cross-reference a few lines below it, in the
same file, same section**, and at least four other live canonical-surface references
project-wide, none of which this change updated:

- `docs/agents/ORCHESTRATOR.md` itself, line 510 (within §10, directly below the new
  item): *"Qualifying under all **six checks** above licenses skipping..."* — now
  factually wrong; there are seven.
- `docs/agents/AGENT_SYSTEM.md` line 101: *"a change passes all **six checks** of
  `docs/agents/ORCHESTRATOR.md` §10's sizing rule."*
- `.claude/agents/orchestrator.md` line 69: *"**six checks** in `docs/agents/
  ORCHESTRATOR.md` §10."*
- `.claude/agents/elixir-dev.md` line 17: *"all **six checks** of `docs/agents/
  ORCHESTRATOR.md` §10's sizing rule."*
- `docs/agents/instructions/core-directives.md` line 49: *"a change passing all **six
  checks** of the sizing rule."*
- `CLAUDE.md` line 78: *"a change passes all **six checks** of the sizing rule."*

This is exactly the staleness class this review was asked to check for, and it is a
genuine defect: an agent that reads any of these six surfaces (five of them canonical
governance files per `AGENT_SYSTEM.md` §9's own list) after this merge will undercount
§10's checklist and could treat the new item 7 as not existing. None of the ACs asked for
these edits explicitly, and CODE-DESIGN-VALIDATOR's review of "does anything weaken an
existing gate" checked §5/§7/§8/§10 for *weakening* but did not check for this kind of
*count* staleness outside the files it was scoped to re-read.

**MUST FIX before merge**: update all six occurrences above (`"six checks"` →
`"seven checks"`, and `"six-point checklist"` if present at `lib/letflow/design/
iss-0046-transition-struct-update-warnings.md:16` — that one is a historical
point-in-time design record describing what applied *at the time it was written*, not a
live instruction, so it is correctly left alone, not a staleness bug).

TASK_QUEUE.md's new paragraph is inserted cleanly before the `### 3. set_lock` heading,
no numbering disturbed there.

## 6. Requirement header bookkeeping — PASS (on the correct branch)

Note on process: my first read of `handoffs/ADHOC-20261001-001/requirement-drain-mode.md`
came from a stale, untracked local copy left on an unrelated branch
(`feature/WF02-REQ428-20261001`) in this checkout — it still showed "Status: drafted,
awaiting REQ-VALIDATOR." After fetching and checking out the actual review branch
(`chore/adhoc-drain-mode-review-20261001`, commit `20c2f7bb`), the committed file's header
correctly reads "Status: REQ-VALIDATOR PASS-WITH-REVISIONS ... → CODE-DESIGNER ... →
CODE-DESIGN-VALIDATOR PASS ... this header updated 2026-10-01 to close the bookkeeping
staleness CODE-DESIGN-VALIDATOR flagged as non-blocking." Confirmed landed. (The stale
local copy was a leftover artifact on a different, unrelated feature branch and is not
part of this diff — flagging only so whoever cleans up that other branch's untracked
files is aware; not this run's concern.)

---

## Additional observation (not independently blocking, but should not be silently dropped)

`0041`'s own "Consequences" section states: *"This incident (REQ-294/PR #2081) should be
added to `docs/anti-patterns.md` as its own entry if not already present... out of scope
for CODE-DESIGNER to author here, flagged for the implementing step."* `docs/
anti-patterns.md` has no entry for REQ-294/PR #2081/drain-mode as of this diff — the
implementing step neither added it nor recorded an explicit deferral anywhere in the
handoff artefacts. This should be filed as a follow-up issue (per `ISSUE_QUEUE.md`,
consistent with this very requirement's own "file it, don't silently drop it" principle)
rather than merged and forgotten. Not a merge blocker on its own, but bundling it into the
same follow-up commit as findings 2 and 5 above is the efficient path.

---

## Summary for ORCH

Do not merge as-is. Three items, all mechanical, none requiring a new design/validation
cycle:
1. Add `registry.json` + `orchestrator.log` entries for this run (precedent:
   `ADHOC-20260821-001/002`).
2. Fix the six stale "six checks" references enumerated in §5 above.
3. File (don't silently drop) the `docs/anti-patterns.md` entry 0041's own Consequences
   section asked for.

Once applied, this clears to merge on re-check — the core design, the ADR, the guardrail
text's enforceability, and the scope of the diff are all sound.
